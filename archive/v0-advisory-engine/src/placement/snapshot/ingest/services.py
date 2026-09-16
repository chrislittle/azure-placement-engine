"""Ingester #2 — service availability by region, from ARM provider metadata.

This is the first slice that can eliminate a region for a reason a customer
recognises: *"Microsoft.DBforPostgreSQL/flexibleServers is not in that region."*

Two things about the real payload shape the design:

**Locations are display names, in inconsistent casing.** Observed in a single
live response: `'Uk West'`, `'italy north'`, `'spain central'`, `'SouthEast
Asia'`, `'Norway EAST'`, `'Central Us'`, `'japan East'`. Squeezing whitespace and
lowercasing turns `"Italy North"` into `italynorth`, which *is* the ARM region
name — so that normalisation is the join key, applied to both sides.

**A few location strings are geographies, not regions** — `'UAE'`, `'UK'`. They
match nothing and are recorded as unmapped rather than silently dropped.

This ingester depends on the region slice already being present, since the join
needs the region table to resolve against.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from placement.snapshot.model import (
    Region,
    RegionType,
    ServiceAvailability,
    SourceRef,
    WorldSnapshot,
)

SOURCE = "arm-providers"
API_VERSION = "2021-04-01"
ENDPOINT = "https://management.azure.com/subscriptions/{subscription_id}/providers"


class IngestError(ValueError):
    pass


def normalise_location(location: str) -> str:
    """Fold a location string to its ARM region name form.

    `"West Europe"`, `"west europe"` and `"westeurope"` all collapse to
    `westeurope`, which is what makes the inconsistent casing in provider
    metadata harmless.
    """
    return "".join(location.split()).lower()


def build_location_index(regions: dict[str, Region]) -> dict[str, str]:
    """Normalised location string -> ARM region name.

    Indexed on both the region name and its display name, since the two
    normalise to the same key for almost every region and the redundancy costs
    nothing.
    """
    index: dict[str, str] = {}
    for region in regions.values():
        index[normalise_location(region.name)] = region.name
        if region.display_name:
            index.setdefault(normalise_location(region.display_name), region.name)
    return index


# --------------------------------------------------------------------------
# Parse
# --------------------------------------------------------------------------


def parse_providers(
    payload: dict[str, Any], regions: dict[str, Region]
) -> tuple[dict[str, ServiceAvailability], dict[str, int]]:
    """Parse an ARM providers response.

    Returns the availability table keyed by lowercased resource type, plus a
    count of location strings that resolved to no known region.
    """
    if not isinstance(payload, dict) or "value" not in payload:
        raise IngestError("expected an ARM providers response with a `value` array")
    if not regions:
        raise IngestError(
            "service availability needs the region slice first — build regions before providers"
        )

    providers = payload["value"]
    if not isinstance(providers, list) or not providers:
        raise IngestError("`value` is empty or not an array — refusing to build an empty service table")

    index = build_location_index(regions)
    physical = {name for name, r in regions.items() if r.region_type is RegionType.PHYSICAL}

    services: dict[str, ServiceAvailability] = {}
    unmapped: dict[str, int] = {}

    for provider in providers:
        namespace = provider.get("namespace")
        if not namespace:
            continue

        for entry in provider.get("resourceTypes") or []:
            name = entry.get("resourceType")
            if not name:
                continue

            resource_type = f"{namespace}/{name}"
            locations = entry.get("locations") or []

            resolved: set[str] = set()
            for location in locations:
                if not isinstance(location, str):
                    continue
                region_name = index.get(normalise_location(location))
                if region_name is None:
                    unmapped[location] = unmapped.get(location, 0) + 1
                elif region_name in physical:
                    resolved.add(region_name)

            services[resource_type.lower()] = ServiceAvailability(
                resource_type=resource_type,
                regions=sorted(resolved),
                # No physical footprint at all: a tenant- or global-scoped type,
                # not a data gap. Distinguishing the two matters, because one is
                # never a reason to eliminate a region and the other would be.
                global_only=not resolved,
            )

    if not services:
        raise IngestError("no resource types found in payload")

    return services, unmapped


# --------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------


def ingest(
    snapshot: WorldSnapshot,
    payload: dict[str, Any],
    *,
    as_of: datetime | None = None,
    subscription_id: str | None = None,
    api_version: str = API_VERSION,
) -> WorldSnapshot:
    """Add or replace the service-availability slice of a snapshot."""
    services, unmapped = parse_providers(payload, snapshot.regions)

    snapshot.services = services

    note = (
        "Provider `locations` are display names in inconsistent casing; normalised to ARM region "
        "names on ingest. `registrationState` is deliberately not recorded here - it is "
        "subscription-specific and belongs to tenant context."
    )
    if unmapped:
        listed = ", ".join(f"{k!r} ({v}x)" for k, v in sorted(unmapped.items(), key=lambda x: -x[1]))
        note += f" Unmapped location strings: {listed}."

    snapshot.sources[SOURCE] = SourceRef(
        source=SOURCE,
        as_of=as_of or datetime.now(timezone.utc),
        api_version=api_version,
        endpoint=ENDPOINT.format(subscription_id="{subscription_id}"),
        collected_via_subscription=subscription_id,
        notes=note,
    )
    return snapshot


# --------------------------------------------------------------------------
# Fetch
# --------------------------------------------------------------------------


def fetch_providers(subscription_id: str, *, api_version: str = API_VERSION) -> dict[str, Any]:
    """Call ARM directly using the ambient Azure credential."""
    try:
        from azure.identity import DefaultAzureCredential
    except ImportError as exc:  # pragma: no cover - depends on optional extra
        raise IngestError(
            "fetching requires the 'azure' extra (pip install -e '.[azure]'), or pass an offline "
            "dump collected with `az rest`"
        ) from exc

    import httpx

    credential = DefaultAzureCredential()
    token = credential.get_token("https://management.azure.com/.default")

    response = httpx.get(
        ENDPOINT.format(subscription_id=subscription_id),
        params={"api-version": api_version},
        headers={"Authorization": f"Bearer {token.token}"},
        timeout=120.0,
    )
    response.raise_for_status()
    return response.json()
