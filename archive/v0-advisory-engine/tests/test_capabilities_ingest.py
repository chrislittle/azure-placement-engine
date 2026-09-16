"""Capability-level ingester: region-derived, storage SKUs, Postgres flags."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from placement.snapshot.ingest import capabilities as cap
from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.ingest.capabilities import IngestError
from placement.snapshot.model import WorldSnapshot

FIXTURES = Path(__file__).parent / "fixtures"
AS_OF = datetime(2026, 8, 26, tzinfo=timezone.utc)

STORAGE = cap.STORAGE_TYPE
POSTGRES = cap.POSTGRES_TYPE


@pytest.fixture
def snapshot() -> WorldSnapshot:
    locations = json.loads((FIXTURES / "arm-locations-sample.json").read_text(encoding="utf-8"))
    return regions_ingest.ingest(WorldSnapshot(version="test"), locations, as_of=AS_OF)


def storage_payload() -> dict:
    def sku(name, kind, tier, locations):
        return {"name": name, "kind": kind, "tier": tier, "locations": locations, "restrictions": []}

    return {
        "value": [
            sku("Standard_LRS", "StorageV2", "Standard", ["westeurope", "germanynorth", "italynorth"]),
            sku("Standard_ZRS", "StorageV2", "Standard", ["westeurope", "italynorth"]),
            sku("Standard_GRS", "StorageV2", "Standard", ["westeurope", "germanynorth"]),
            sku("Premium_LRS", "BlockBlobStorage", "Premium", ["westeurope"]),
            # References a region absent from the locations response.
            sku("Standard_ZRS", "StorageV2", "Standard", ["qatarcentral"]),
        ]
    }


def pg(zone_redundant=None, zr_and_geo=None, geo=None):
    entry = {"name": "FlexibleServerCapabilities"}
    if zone_redundant is not None:
        entry["zoneRedundantHaSupported"] = zone_redundant
    if zr_and_geo is not None:
        entry["zoneRedundantHaAndGeoBackupSupported"] = zr_and_geo
    if geo is not None:
        entry["geoBackupSupported"] = geo
    return {"value": [entry]}


# --------------------------------------------------------------------------
# Region-derived
# --------------------------------------------------------------------------


def test_availability_zones_excludes_the_canary_region(snapshot):
    """`eastus2euap` reports four zones. A capability derived from the region
    table must use placement candidates, or the canary leaks back in here after
    being filtered everywhere else."""
    cap.ingest_region_capabilities(snapshot, as_of=AS_OF)
    fact = snapshot.capability(cap.ANY_RESOURCE_TYPE, "availability-zones")
    assert "eastus2euap" not in fact.regions
    assert "westeurope" in fact.regions
    assert "germanynorth" not in fact.regions  # zero zones


def test_region_capabilities_need_the_region_slice():
    with pytest.raises(IngestError, match="need the region slice"):
        cap.ingest_region_capabilities(WorldSnapshot(version="test"))


# --------------------------------------------------------------------------
# Storage SKUs — capability encoded in the SKU name
# --------------------------------------------------------------------------


def test_zone_redundancy_comes_from_sku_names(snapshot):
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    assert snapshot.capability_available(STORAGE, "zone-redundant-storage", "westeurope") is True
    assert snapshot.capability_available(STORAGE, "zone-redundant-storage", "italynorth") is True
    # Has Standard_LRS and Standard_GRS but no ZRS SKU.
    assert snapshot.capability_available(STORAGE, "zone-redundant-storage", "germanynorth") is False


def test_geo_and_premium_block_blob(snapshot):
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    assert snapshot.capability_available(STORAGE, "geo-redundant-storage", "germanynorth") is True
    assert snapshot.capability_available(STORAGE, "geo-redundant-storage", "italynorth") is False
    assert snapshot.capability_available(STORAGE, "premium-block-blob", "westeurope") is True
    assert snapshot.capability_available(STORAGE, "premium-block-blob", "italynorth") is False


def test_regions_outside_the_region_table_are_dropped(snapshot):
    """Storage SKU metadata references regions the locations response never
    returned. Carrying those through would report more regions than exist."""
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    fact = snapshot.capability(STORAGE, "zone-redundant-storage")
    assert "qatarcentral" not in fact.regions
    assert set(fact.regions) <= set(snapshot.regions)


def test_storage_restrictions_are_not_recorded(snapshot):
    """Per-SKU restrictions are subscription-specific and belong to tenant context."""
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    assert "restrictions" not in json.dumps(snapshot.model_dump(mode="json")["capabilities"])


def test_rejects_empty_storage_payload(snapshot):
    with pytest.raises(IngestError, match="refusing to record capabilities"):
        cap.ingest_storage_skus(snapshot, {"value": []})


# --------------------------------------------------------------------------
# Postgres — flags mean "deployable now"
# --------------------------------------------------------------------------


def test_either_zone_redundant_flag_counts():
    """One flag is ZR HA alone, the other is ZR HA together with geo-redundant
    backup. Either means a new zone-redundant deployment is possible."""
    assert cap.parse_postgres_capabilities(pg(zone_redundant="Enabled"))["zone-redundant-ha"]
    assert cap.parse_postgres_capabilities(pg(zr_and_geo="Enabled"))["zone-redundant-ha"]
    assert not cap.parse_postgres_capabilities(
        pg(zone_redundant="Disabled", zr_and_geo="Disabled")
    )["zone-redundant-ha"]


def test_flags_are_enabled_disabled_strings_not_booleans():
    assert cap.parse_postgres_capabilities(pg(geo="Enabled"))["geo-backup"] is True
    assert cap.parse_postgres_capabilities(pg(geo="Disabled"))["geo-backup"] is False


def test_blocked_region_reports_unsupported(snapshot):
    """Observed against live data: westeurope has three zones and nominal ZR HA
    support, but the API reports Disabled because new ZR HA deployments are
    temporarily blocked. For a placement decision, deployable-now is the right
    answer, so the API is allowed to disagree with the docs table."""
    cap.ingest_postgres_capabilities(
        snapshot,
        {
            "westeurope": pg(zone_redundant="Disabled", zr_and_geo="Disabled", geo="Enabled"),
            "italynorth": pg(zone_redundant="Enabled", zr_and_geo="Disabled", geo="Disabled"),
        },
        as_of=AS_OF,
    )
    assert snapshot.capability_available(POSTGRES, "zone-redundant-ha", "westeurope") is False
    assert snapshot.capability_available(POSTGRES, "zone-redundant-ha", "italynorth") is True
    assert snapshot.region("westeurope").zone_count == 3  # zones alone are not the answer


def test_unreadable_region_response_is_unknown_not_unsupported(snapshot):
    """A malformed response must not silently become "not supported", which
    would be an invented elimination."""
    cap.ingest_postgres_capabilities(
        snapshot,
        {"italynorth": pg(zone_redundant="Enabled"), "germanynorth": {"value": []}},
        as_of=AS_OF,
    )
    fact = snapshot.capability(POSTGRES, "zone-redundant-ha")
    assert "germanynorth" not in fact.regions
    note = snapshot.sources[cap.POSTGRES_SOURCE].notes
    assert "Unreadable responses for: germanynorth" in note
    assert "treated as unknown" in note


def test_rejects_no_payloads(snapshot):
    with pytest.raises(IngestError, match="no Postgres capability payloads"):
        cap.ingest_postgres_capabilities(snapshot, {})


# --------------------------------------------------------------------------
# Unknown stays unknown
# --------------------------------------------------------------------------


def test_uningested_capability_is_none(snapshot):
    """Capability coverage is uneven by nature - most services expose no
    capabilities API. Unknown is a risk on the candidate, never an elimination."""
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    assert (
        snapshot.capability_available(
            "Microsoft.ContainerService/managedClusters", "private-cluster", "westeurope"
        )
        is None
    )
    assert snapshot.capability_available(STORAGE, "immutable-storage", "westeurope") is None


def test_known_capabilities_lists_what_was_resolved(snapshot):
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    assert snapshot.known_capabilities(STORAGE) == {
        "zone-redundant-storage",
        "geo-redundant-storage",
        "premium-block-blob",
    }


# --------------------------------------------------------------------------
# Digest stability across schema growth
# --------------------------------------------------------------------------


def test_empty_slices_do_not_change_the_digest(snapshot):
    """Adding a slice to the model must not retroactively invalidate snapshots
    that never used it - the digest proves content, not schema shape."""
    before = snapshot.digest()
    assert snapshot.capabilities == {}
    assert before == WorldSnapshot.model_validate(snapshot.model_dump()).digest()


def test_populating_a_slice_does_change_the_digest(snapshot):
    before = snapshot.digest()
    cap.ingest_storage_skus(snapshot, storage_payload(), as_of=AS_OF)
    assert snapshot.digest() != before


def test_region_zones_do_not_imply_zonal_deployability(snapshot):
    """Physical topology and deployability are different facts, and they diverge
    in real data: westeurope reports three zones while the Postgres capabilities
    API reports no zone-redundant HA there. The region-derived capability is a
    necessary condition, never a sufficient one."""
    cap.ingest_region_capabilities(snapshot, as_of=AS_OF)
    cap.ingest_postgres_capabilities(
        snapshot,
        {"westeurope": pg(zone_redundant="Disabled", zr_and_geo="Disabled", geo="Enabled")},
        as_of=AS_OF,
    )
    assert snapshot.capability_available(cap.ANY_RESOURCE_TYPE, "availability-zones", "westeurope")
    assert snapshot.capability_available(POSTGRES, "zone-redundant-ha", "westeurope") is False

    detail = snapshot.capability(cap.ANY_RESOURCE_TYPE, "availability-zones").detail
    assert "physical topology" in detail
