"""Ingester #4 — VM SKU availability from `Microsoft.Compute/skus`.

The largest source by far: the unfiltered response is ~230 MB, roughly 4.8 MB and
1300 VM SKUs per region. It is therefore collected **per region** and projected
hard on the way in — the snapshot keeps the handful of fields a placement
decision uses and discards the rest, which is most of it.

What this makes answerable, none of which the coarser slices could:

* whether a named SKU (`Standard_ND96isr_H100_v5`) exists in a region at all
* `infiniband`, from the `RdmaEnabled` capability
* confidential compute, from `ConfidentialComputingType`
* accelerator presence and count, from `GPUs`
* which **zones** a SKU is actually offered in, which is finer than the region's
  zone count and is what a zonal deployment really depends on

**`restrictions` is deliberately not stored here.** It carries
`NotAvailableForSubscription`, which is the single best machine-readable signal
for "this exists but you cannot reach it yet" — the remediation signal. That is a
property of the subscription, not the world, so it is extracted separately into
tenant context. Merging it into the snapshot would make a pinned world file
subscription-specific and quietly wrong for anyone else.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from placement.snapshot.model import SourceRef, VmSku, WorldSnapshot

SOURCE = "compute-skus"
API_VERSION = "2021-07-01"
ENDPOINT = (
    "https://management.azure.com/subscriptions/{subscription_id}/providers/Microsoft.Compute/skus"
)

VM_RESOURCE_TYPE = "virtualMachines"

#: Everything else in `capabilities` is dropped. Each of these either answers a
#: capability the requirements grammar can express, or is needed to match a
#: capability class to real silicon.
KEPT_CAPABILITIES = {
    "vCPUs",
    "MemoryGB",
    "GPUs",
    "RdmaEnabled",
    "ConfidentialComputingType",
    "PremiumIO",
    "CpuArchitectureType",
    "EncryptionAtHostSupported",
    "AcceleratedNetworkingEnabled",
}


class IngestError(ValueError):
    pass


def _capabilities(entry: dict[str, Any]) -> dict[str, str]:
    return {
        c["name"]: c.get("value", "")
        for c in entry.get("capabilities") or []
        if isinstance(c, dict) and c.get("name") in KEPT_CAPABILITIES
    }


def _as_bool(value: str | None) -> bool:
    return isinstance(value, str) and value.strip().lower() == "true"


def _as_int(value: str | None) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def _as_float(value: str | None) -> float | None:
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return None


def _zones_by_region(entry: dict[str, Any]) -> dict[str, list[str]]:
    """Zones a SKU is offered in, per region.

    Finer than the region's own zone count: a region with three zones may offer a
    given SKU in only one of them, and a zonal deployment depends on the SKU's
    zones, not the region's.
    """
    result: dict[str, list[str]] = {}
    for info in entry.get("locationInfo") or []:
        if not isinstance(info, dict):
            continue
        location = info.get("location")
        if not location:
            continue
        zones = [str(z) for z in (info.get("zones") or [])]
        result[str(location).lower()] = sorted(zones)
    return result


def parse_vm_skus(payload: dict[str, Any]) -> dict[str, VmSku]:
    """Project one `Microsoft.Compute/skus` response into VM SKUs."""
    if not isinstance(payload, dict) or "value" not in payload:
        raise IngestError("expected a Microsoft.Compute/skus response with a `value` array")

    entries = payload["value"]
    if not isinstance(entries, list):
        raise IngestError("`value` must be an array")

    skus: dict[str, VmSku] = {}
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("resourceType") != VM_RESOURCE_TYPE:
            continue
        name = entry.get("name")
        if not name:
            continue

        caps = _capabilities(entry)
        skus[name] = VmSku(
            name=name,
            family=entry.get("family") or "",
            tier=entry.get("tier"),
            size=entry.get("size"),
            vcpus=_as_int(caps.get("vCPUs")),
            memory_gb=_as_float(caps.get("MemoryGB")),
            gpus=_as_int(caps.get("GPUs")),
            rdma=_as_bool(caps.get("RdmaEnabled")),
            confidential_computing=caps.get("ConfidentialComputingType") or None,
            premium_io=_as_bool(caps.get("PremiumIO")),
            cpu_architecture=caps.get("CpuArchitectureType"),
            encryption_at_host=_as_bool(caps.get("EncryptionAtHostSupported")),
            zones_by_region=_zones_by_region(entry),
        )
    return skus


def merge(into: dict[str, VmSku], addition: dict[str, VmSku]) -> dict[str, VmSku]:
    """Combine per-region projections.

    Capabilities are taken from the first region a SKU is seen in — they describe
    the silicon and do not vary by region. Only the region/zone map accumulates.
    """
    for name, sku in addition.items():
        existing = into.get(name)
        if existing is None:
            into[name] = sku
            continue
        combined = dict(existing.zones_by_region)
        combined.update(sku.zones_by_region)
        into[name] = existing.model_copy(update={"zones_by_region": combined})
    return into


def ingest(
    snapshot: WorldSnapshot,
    per_region: dict[str, dict[str, Any]],
    *,
    as_of: datetime | None = None,
    subscription_id: str | None = None,
) -> WorldSnapshot:
    """Record VM SKUs from a `{region: payload}` mapping."""
    if not per_region:
        raise IngestError("no compute SKU payloads supplied")

    skus: dict[str, VmSku] = {}
    failures: list[str] = []

    for region, payload in sorted(per_region.items()):
        try:
            merge(skus, parse_vm_skus(payload))
        except IngestError:
            # An unreadable region must not become "no SKUs here", which would be
            # an invented elimination for every capacity requirement.
            failures.append(region)

    if not skus:
        raise IngestError("no VM SKUs found in any payload")

    # Confine to regions the snapshot knows, as elsewhere.
    known = set(snapshot.regions)
    snapshot.vm_skus = {
        name: sku.model_copy(
            update={"zones_by_region": {r: z for r, z in sku.zones_by_region.items() if r in known}}
        )
        for name, sku in sorted(skus.items())
    }

    notes = (
        f"Projected from per-region responses ({len(per_region)} queried); only fields used by a "
        "placement decision are kept. `restrictions` is deliberately not recorded here - "
        "NotAvailableForSubscription is a property of the subscription, not the world, and is "
        "extracted into tenant context where it becomes a remediation signal."
    )
    if failures:
        notes += f" Unreadable responses for: {', '.join(sorted(failures))} - treated as unknown."

    snapshot.sources[SOURCE] = SourceRef(
        source=SOURCE,
        as_of=as_of or datetime.now(timezone.utc),
        api_version=API_VERSION,
        endpoint=ENDPOINT.format(subscription_id="{subscription_id}"),
        collected_via_subscription=subscription_id,
        notes=notes,
    )
    return snapshot


# --------------------------------------------------------------------------
# Derived capabilities
# --------------------------------------------------------------------------


def derive_capabilities(snapshot: WorldSnapshot, *, as_of: datetime | None = None) -> WorldSnapshot:
    """Turn VM SKU facts into the capability names the requirements grammar uses."""
    from placement.snapshot.ingest.capabilities import _record

    vmss = "Microsoft.Compute/virtualMachineScaleSets"
    vms = "Microsoft.Compute/virtualMachines"

    rules = [
        ("infiniband", lambda s: s.rdma, "an RDMA-enabled (InfiniBand) VM SKU is offered"),
        (
            "confidential-compute",
            lambda s: bool(s.confidential_computing),
            "a confidential-computing VM SKU is offered",
        ),
        ("accelerator", lambda s: bool(s.gpus), "a GPU-bearing VM SKU is offered"),
    ]

    for capability, predicate, detail in rules:
        regions = {
            region
            for sku in snapshot.vm_skus.values()
            if predicate(sku)
            for region in sku.zones_by_region
        }
        for resource_type in (vms, vmss):
            _record(
                snapshot,
                capability=capability,
                resource_type=resource_type,
                regions=regions,
                source=SOURCE,
                detail=detail + " in the region",
            )
    return snapshot


# --------------------------------------------------------------------------
# Fetch
# --------------------------------------------------------------------------


def fetch_compute_skus(subscription_id: str, region: str) -> dict[str, Any]:
    """One region at a time. The unfiltered call returns ~230 MB."""
    try:
        from azure.identity import DefaultAzureCredential
    except ImportError as exc:  # pragma: no cover - depends on optional extra
        raise IngestError(
            "fetching requires the 'azure' extra (pip install -e '.[azure]'), or pass offline dumps"
        ) from exc

    import httpx

    token = DefaultAzureCredential().get_token("https://management.azure.com/.default").token
    response = httpx.get(
        ENDPOINT.format(subscription_id=subscription_id),
        params={"api-version": API_VERSION, "$filter": f"location eq '{region}'"},
        headers={"Authorization": f"Bearer {token}"},
        timeout=180.0,
    )
    response.raise_for_status()
    return response.json()
