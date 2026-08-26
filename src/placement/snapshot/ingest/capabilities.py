"""Ingester #3 — capability-level availability.

The level below "is the service in this region", and the level where deployments
actually fail. Three sources, three different shapes, one output type:

* **Region table** — `availability-zones` is just the zone count, already in the
  snapshot. No API call needed.
* **`Microsoft.Storage/skus`** — capabilities are encoded in *SKU names*.
  `Standard_ZRS` present in a region means zone-redundant storage is available
  there; `Premium_LRS` with kind `BlockBlobStorage` means premium block blob.
* **`Microsoft.DBforPostgreSQL/locations/{loc}/capabilities`** — explicit
  per-region flags. One call per region.

That variety is the answer to a question deferred during scoping: a capability is
neither a free string nor a typed field, it is a **named rule with a
source-specific resolver**.

A note on what the Postgres flags mean, because it is easy to get backwards.
Against a live subscription, `westeurope` reports `zoneRedundantHaSupported:
Disabled` — which looks wrong, since West Europe plainly supports zone-redundant
HA. The docs resolve it: the regions table marks West Europe as supported *but*
with "new zone-redundant HA deployments are temporarily blocked". **The API
reports what you can deploy today; the docs table reports nominal support.** For
a placement decision, deployability today is exactly the right answer, so the API
is the authority here and is deliberately allowed to disagree with the docs.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Iterable

from placement.snapshot.model import CapabilityFact, Region, SourceRef, WorldSnapshot

REGION_SOURCE = "region-capabilities"
STORAGE_SOURCE = "storage-skus"
POSTGRES_SOURCE = "postgres-capabilities"

STORAGE_TYPE = "Microsoft.Storage/storageAccounts"
POSTGRES_TYPE = "Microsoft.DBforPostgreSQL/flexibleServers"

POSTGRES_ENDPOINT = (
    "https://management.azure.com/subscriptions/{subscription_id}"
    "/providers/Microsoft.DBforPostgreSQL/locations/{location}/capabilities"
)
POSTGRES_API_VERSION = "2024-08-01"
STORAGE_ENDPOINT = (
    "https://management.azure.com/subscriptions/{subscription_id}/providers/Microsoft.Storage/skus"
)
STORAGE_API_VERSION = "2024-01-01"


class IngestError(ValueError):
    pass


def _enabled(value: Any) -> bool:
    """ARM capability flags are the strings 'Enabled' / 'Disabled', not booleans."""
    return isinstance(value, str) and value.strip().lower() == "enabled"


def _record(
    snapshot: WorldSnapshot,
    *,
    capability: str,
    resource_type: str,
    regions: Iterable[str],
    source: str,
    detail: str,
) -> None:
    # Confine to regions the snapshot knows. Storage SKU metadata references
    # regions absent from the locations response for this subscription, and
    # carrying those through would report more regions than the region table has.
    known = {r for r in regions if r in snapshot.regions}
    fact = CapabilityFact(
        capability=capability,
        resource_type=resource_type,
        regions=sorted(known),
        source=source,
        detail=detail,
    )
    snapshot.capabilities[CapabilityFact.key(resource_type, capability)] = fact


# --------------------------------------------------------------------------
# Region-derived
# --------------------------------------------------------------------------

#: `availability-zones` is asked for against many services, but it is a property
#: of the region, so it resolves once and applies to any resource type.
ANY_RESOURCE_TYPE = "*"


def ingest_region_capabilities(
    snapshot: WorldSnapshot, *, as_of: datetime | None = None, minimum_zones: int = 3
) -> WorldSnapshot:
    """Derive region-level capabilities from the region table. No API call."""
    if not snapshot.regions:
        raise IngestError("region capabilities need the region slice first")

    zoned = [
        r.name
        for r in snapshot.regions.values()
        if r.is_placement_candidate and r.zone_count >= minimum_zones
    ]
    _record(
        snapshot,
        capability="availability-zones",
        resource_type=ANY_RESOURCE_TYPE,
        regions=zoned,
        source=REGION_SOURCE,
        detail=f"region reports {minimum_zones} or more availability zones",
    )
    snapshot.sources[REGION_SOURCE] = SourceRef(
        source=REGION_SOURCE,
        as_of=as_of or datetime.now(timezone.utc),
        notes="Derived from the region table; no separate API call.",
    )
    return snapshot


# --------------------------------------------------------------------------
# Storage SKUs
# --------------------------------------------------------------------------


def _storage_regions(entries: list[dict[str, Any]], predicate) -> set[str]:
    regions: set[str] = set()
    for entry in entries:
        if predicate(entry):
            regions.update(entry.get("locations") or [])
    return {r.lower() for r in regions}


def ingest_storage_skus(
    snapshot: WorldSnapshot,
    payload: dict[str, Any],
    *,
    as_of: datetime | None = None,
    subscription_id: str | None = None,
) -> WorldSnapshot:
    """Derive storage capabilities from `Microsoft.Storage/skus`.

    Capabilities live in the SKU *name* — `Standard_ZRS`, `Standard_GZRS`,
    `PremiumV2_ZRS` all denote zone redundancy — so they are matched on the
    redundancy suffix rather than an enumerated list, which would go stale as new
    SKU generations appear.
    """
    if not isinstance(payload, dict) or "value" not in payload:
        raise IngestError("expected a Microsoft.Storage/skus response with a `value` array")
    entries = [e for e in payload["value"] if isinstance(e, dict)]
    if not entries:
        raise IngestError("`value` is empty - refusing to record capabilities from nothing")

    def name(entry: dict[str, Any]) -> str:
        return str(entry.get("name") or "")

    _record(
        snapshot,
        capability="zone-redundant-storage",
        resource_type=STORAGE_TYPE,
        regions=_storage_regions(entries, lambda e: name(e).endswith(("ZRS",))),
        source=STORAGE_SOURCE,
        detail="a zone-redundant storage SKU (*_ZRS / *_GZRS / *_RAGZRS) is offered in the region",
    )
    _record(
        snapshot,
        capability="geo-redundant-storage",
        resource_type=STORAGE_TYPE,
        regions=_storage_regions(entries, lambda e: "GRS" in name(e) or "GZRS" in name(e)),
        source=STORAGE_SOURCE,
        detail="a geo-redundant storage SKU (*_GRS / *_RAGRS / *_GZRS) is offered in the region",
    )
    _record(
        snapshot,
        capability="premium-block-blob",
        resource_type=STORAGE_TYPE,
        regions=_storage_regions(
            entries, lambda e: e.get("kind") == "BlockBlobStorage" and e.get("tier") == "Premium"
        ),
        source=STORAGE_SOURCE,
        detail="a Premium BlockBlobStorage SKU is offered in the region",
    )

    snapshot.sources[STORAGE_SOURCE] = SourceRef(
        source=STORAGE_SOURCE,
        as_of=as_of or datetime.now(timezone.utc),
        api_version=STORAGE_API_VERSION,
        endpoint=STORAGE_ENDPOINT.format(subscription_id="{subscription_id}"),
        collected_via_subscription=subscription_id,
        notes=(
            "Capabilities are derived from SKU names. `restrictions` on each SKU is deliberately "
            "not recorded - it is subscription-specific and belongs to tenant context."
        ),
    )
    return snapshot


# --------------------------------------------------------------------------
# Postgres per-region capabilities
# --------------------------------------------------------------------------


def parse_postgres_capabilities(payload: dict[str, Any]) -> dict[str, bool]:
    """Reduce one region's Postgres capabilities response to the flags we use."""
    if not isinstance(payload, dict) or not payload.get("value"):
        raise IngestError("expected a Postgres capabilities response with a non-empty `value`")

    entry = payload["value"][0]
    if not isinstance(entry, dict):
        raise IngestError("unexpected shape for the first `value` entry")

    zone_redundant = _enabled(entry.get("zoneRedundantHaSupported")) or _enabled(
        entry.get("zoneRedundantHaAndGeoBackupSupported")
    )
    return {
        # Either flag means a new zone-redundant deployment is possible: one is
        # ZR HA on its own, the other is ZR HA together with geo-redundant backup.
        "zone-redundant-ha": zone_redundant,
        "geo-backup": _enabled(entry.get("geoBackupSupported")),
        "online-resize": _enabled(entry.get("onlineResizeSupported")),
    }


def ingest_postgres_capabilities(
    snapshot: WorldSnapshot,
    per_region: dict[str, dict[str, Any]],
    *,
    as_of: datetime | None = None,
    subscription_id: str | None = None,
) -> WorldSnapshot:
    """Record Postgres capabilities from a `{region: payload}` mapping."""
    if not per_region:
        raise IngestError("no Postgres capability payloads supplied")

    supported: dict[str, set[str]] = {}
    failures: list[str] = []

    for region, payload in per_region.items():
        try:
            flags = parse_postgres_capabilities(payload)
        except IngestError:
            # One region's malformed response must not silently become "not
            # supported" for that region, which would be an invented elimination.
            failures.append(region)
            continue
        for capability, available in flags.items():
            if available:
                supported.setdefault(capability, set()).add(region)
            else:
                supported.setdefault(capability, set())

    if not supported:
        raise IngestError("no usable Postgres capability payloads")

    detail = {
        "zone-redundant-ha": (
            "zoneRedundantHaSupported or zoneRedundantHaAndGeoBackupSupported is Enabled - "
            "reflects what can be deployed today, which can differ from the docs table where new "
            "deployments are temporarily blocked"
        ),
        "geo-backup": "geoBackupSupported is Enabled",
        "online-resize": "onlineResizeSupported is Enabled",
    }
    for capability, regions in supported.items():
        _record(
            snapshot,
            capability=capability,
            resource_type=POSTGRES_TYPE,
            regions=regions,
            source=POSTGRES_SOURCE,
            detail=detail.get(capability, capability),
        )

    notes = (
        f"Collected per region ({len(per_region)} queried). `restricted` is deliberately not "
        "recorded - it varies by subscription and belongs to tenant context."
    )
    if failures:
        notes += f" Unreadable responses for: {', '.join(sorted(failures))} - treated as unknown."

    snapshot.sources[POSTGRES_SOURCE] = SourceRef(
        source=POSTGRES_SOURCE,
        as_of=as_of or datetime.now(timezone.utc),
        api_version=POSTGRES_API_VERSION,
        endpoint=POSTGRES_ENDPOINT.format(subscription_id="{subscription_id}", location="{location}"),
        collected_via_subscription=subscription_id,
        notes=notes,
    )
    return snapshot


# --------------------------------------------------------------------------
# Fetch
# --------------------------------------------------------------------------


def _token() -> str:
    try:
        from azure.identity import DefaultAzureCredential
    except ImportError as exc:  # pragma: no cover - depends on optional extra
        raise IngestError(
            "fetching requires the 'azure' extra (pip install -e '.[azure]'), or pass offline dumps"
        ) from exc
    return DefaultAzureCredential().get_token("https://management.azure.com/.default").token


def fetch_storage_skus(subscription_id: str) -> dict[str, Any]:
    import httpx

    response = httpx.get(
        STORAGE_ENDPOINT.format(subscription_id=subscription_id),
        params={"api-version": STORAGE_API_VERSION},
        headers={"Authorization": f"Bearer {_token()}"},
        timeout=120.0,
    )
    response.raise_for_status()
    return response.json()


def fetch_postgres_capabilities(
    subscription_id: str, regions: list[Region]
) -> dict[str, dict[str, Any]]:
    """One call per region. Regions that error are omitted, not recorded as
    unsupported — an unreachable region is unknown, not a negative."""
    import httpx

    headers = {"Authorization": f"Bearer {_token()}"}
    results: dict[str, dict[str, Any]] = {}

    with httpx.Client(timeout=60.0, headers=headers) as client:
        for region in regions:
            try:
                response = client.get(
                    POSTGRES_ENDPOINT.format(
                        subscription_id=subscription_id, location=region.name
                    ),
                    params={"api-version": POSTGRES_API_VERSION},
                )
                if response.status_code == 200:
                    results[region.name] = response.json()
            except httpx.HTTPError:
                continue

    if not results:
        raise IngestError("no Postgres capability responses succeeded")
    return results
