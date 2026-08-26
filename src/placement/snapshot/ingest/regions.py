"""Ingester #1 — region metadata from the ARM locations API.

Fully deterministic, and it feeds more of the engine than its size suggests:

* `regionCategory` → the Recommended-vs-Alternate scoring dimension
* `geography` / `geographyGroup` → residency and jurisdiction filtering
* `pairedRegion` → the optional paired-secondary constraint
* `availabilityZoneMappings` → the minimum-AZ hard filter
* `latitude` / `longitude` → a fallback latency estimate until the measured
  round-trip matrix lands

**Parse is separate from fetch on purpose.** Parsing is pure and testable, and
it means anyone can feed the ingester an offline dump without credentials, an
SDK, or network access:

    az rest --method get \\
      --url "https://management.azure.com/subscriptions/<id>/locations?api-version=2022-12-01" \\
      > locations.json
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from placement.snapshot.model import (
    Region,
    RegionCategory,
    RegionType,
    SourceRef,
    WorldSnapshot,
    ZoneMapping,
)

SOURCE = "arm-locations"
API_VERSION = "2022-12-01"
ENDPOINT = "https://management.azure.com/subscriptions/{subscription_id}/locations"


class IngestError(ValueError):
    """Raised when a payload is not a recognisable ARM locations response.

    Deliberately loud. A silently empty region list would flow all the way
    through to an 'everything was eliminated' decision record, which is a much
    more confusing failure than one at the point of ingest.
    """


# --------------------------------------------------------------------------
# Parse
# --------------------------------------------------------------------------


def _paired_region_names(metadata: dict[str, Any]) -> list[str]:
    """Extract paired region names.

    ARM returns pairs as objects with `name` plus a full resource `id`. Only the
    name is kept — the id is subscription-scoped and would make the snapshot
    tenant-specific for no gain.
    """
    pairs = metadata.get("pairedRegion") or []
    names: list[str] = []
    for pair in pairs:
        if isinstance(pair, dict) and pair.get("name"):
            names.append(pair["name"])
    return names


def _zone_mappings(entry: dict[str, Any]) -> list[ZoneMapping]:
    mappings = entry.get("availabilityZoneMappings") or []
    zones: list[ZoneMapping] = []
    for mapping in mappings:
        if not isinstance(mapping, dict):
            continue
        logical, physical = mapping.get("logicalZone"), mapping.get("physicalZone")
        if logical and physical:
            zones.append(ZoneMapping(logical_zone=str(logical), physical_zone=str(physical)))
    return sorted(zones, key=lambda z: z.logical_zone)


def _enum_or_default(raw: Any, enum_cls: type, default: Any) -> Any:
    """Unrecognised values fall back rather than failing the whole ingest.

    Azure adds region categories and types over time; one unknown value should
    not cost us the other ~70 regions. The fallback is visible in the snapshot,
    so it can be spotted and the enum widened.
    """
    if raw is None:
        return default
    try:
        return enum_cls(str(raw))
    except ValueError:
        return default


def parse_region(entry: dict[str, Any]) -> Region:
    name = entry.get("name")
    if not name:
        raise IngestError(f"location entry has no `name`: {entry!r}")

    metadata = entry.get("metadata") or {}

    latitude = metadata.get("latitude")
    longitude = metadata.get("longitude")

    return Region(
        name=name,
        display_name=entry.get("displayName") or name,
        regional_display_name=entry.get("regionalDisplayName"),
        region_type=_enum_or_default(metadata.get("regionType"), RegionType, RegionType.PHYSICAL),
        region_category=_enum_or_default(
            metadata.get("regionCategory"), RegionCategory, RegionCategory.OTHER
        ),
        geography=metadata.get("geography"),
        geography_group=metadata.get("geographyGroup"),
        physical_location=metadata.get("physicalLocation"),
        # ARM returns these as strings.
        latitude=float(latitude) if latitude not in (None, "") else None,
        longitude=float(longitude) if longitude not in (None, "") else None,
        paired_regions=_paired_region_names(metadata),
        zones=_zone_mappings(entry),
    )


def parse_locations(payload: dict[str, Any]) -> list[Region]:
    """Parse an ARM `locations` list response into regions."""
    if not isinstance(payload, dict) or "value" not in payload:
        raise IngestError("expected an ARM locations response with a `value` array")

    entries = payload["value"]
    if not isinstance(entries, list):
        raise IngestError("`value` must be an array")
    if not entries:
        raise IngestError("`value` is empty — refusing to build a snapshot with no regions")

    regions = [parse_region(entry) for entry in entries]

    names = [r.name for r in regions]
    duplicates = sorted({n for n in names if names.count(n) > 1})
    if duplicates:
        raise IngestError(f"duplicate region names in payload: {duplicates}")

    return sorted(regions, key=lambda r: r.name)


# --------------------------------------------------------------------------
# Apply to a snapshot
# --------------------------------------------------------------------------


def ingest(
    snapshot: WorldSnapshot,
    payload: dict[str, Any],
    *,
    as_of: datetime | None = None,
    subscription_id: str | None = None,
    api_version: str = API_VERSION,
) -> WorldSnapshot:
    """Add or replace the region slice of a snapshot.

    `as_of` is collection time, not a value ARM reports — the API carries no
    freshness stamp, so this is the honest thing to record.
    """
    regions = parse_locations(payload)

    snapshot.regions = {r.name: r for r in regions}
    snapshot.sources[SOURCE] = SourceRef(
        source=SOURCE,
        as_of=as_of or datetime.now(timezone.utc),
        api_version=api_version,
        endpoint=ENDPOINT.format(subscription_id="{subscription_id}"),
        collected_via_subscription=subscription_id,
        notes=(
            "Region metadata is public, but the ARM locations API is subscription-scoped and the "
            "visible region set can vary by offer type."
        ),
    )
    return snapshot


# --------------------------------------------------------------------------
# Fetch (thin; optional dependency)
# --------------------------------------------------------------------------


def fetch_locations(subscription_id: str, *, api_version: str = API_VERSION) -> dict[str, Any]:
    """Call ARM directly using the ambient Azure credential.

    Requires the `azure` extra. Everything above this line works without it, so
    an offline dump is a first-class path rather than a fallback.
    """
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
        timeout=60.0,
    )
    response.raise_for_status()
    return response.json()
