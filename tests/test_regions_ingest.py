"""Region-metadata ingester and snapshot store."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from placement.snapshot import store
from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.ingest.regions import IngestError
from placement.snapshot.model import RegionCategory, RegionType, WorldSnapshot

FIXTURE = Path(__file__).parent / "fixtures" / "arm-locations-sample.json"


@pytest.fixture
def payload() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


@pytest.fixture
def snapshot(payload) -> WorldSnapshot:
    return regions_ingest.ingest(
        WorldSnapshot(version="test"),
        payload,
        as_of=datetime(2026, 8, 26, tzinfo=timezone.utc),
        subscription_id="00000000-0000-0000-0000-000000000000",
    )


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------


def test_parses_every_location(payload):
    parsed = regions_ingest.parse_locations(payload)
    assert len(parsed) == len(payload["value"])
    assert [r.name for r in parsed] == sorted(r.name for r in parsed), "regions should be sorted"


def test_region_metadata(snapshot):
    region = snapshot.region("germanywestcentral")
    assert region.display_name == "Germany West Central"
    assert region.region_category is RegionCategory.RECOMMENDED
    assert region.geography == "Germany"
    assert region.geography_group == "Europe"
    assert region.physical_location == "Frankfurt"
    assert region.paired_regions == ["germanynorth"]
    assert region.zone_count == 3
    assert region.latitude == pytest.approx(50.1109)


def test_zone_mappings_are_logical_to_physical(snapshot):
    zones = snapshot.region("westeurope").zones
    assert [z.logical_zone for z in zones] == ["1", "2", "3"]
    assert zones[0].physical_zone == "westeurope-az1"


def test_region_without_zones(snapshot):
    """A pair target with no zones is normal, not missing data."""
    region = snapshot.region("germanynorth")
    assert not region.has_availability_zones
    assert region.zone_count == 0
    assert region.is_paired


def test_unpaired_region(snapshot):
    """Newer regions often ship without a designated pair. CAF no longer treats
    pairing as mandatory, so this must parse cleanly rather than warn."""
    region = snapshot.region("italynorth")
    assert region.paired_regions == []
    assert not region.is_paired
    assert region.zone_count == 3


def test_logical_regions_excluded_from_placement(snapshot):
    assert snapshot.region("global").region_type is RegionType.LOGICAL
    assert "global" not in {r.name for r in snapshot.physical_regions()}


def test_paired_region_ids_are_not_retained(snapshot):
    """Only the name is kept — the ARM id is subscription-scoped and would make
    the snapshot tenant-specific."""
    for region in snapshot.regions.values():
        for pair in region.paired_regions:
            assert "/subscriptions/" not in pair


# --------------------------------------------------------------------------
# Failure modes — loud, not silent
# --------------------------------------------------------------------------


def test_rejects_non_arm_payload():
    with pytest.raises(IngestError, match="`value` array"):
        regions_ingest.parse_locations({"regions": []})


def test_rejects_empty_payload():
    """An empty region list would flow through to 'everything was eliminated',
    which is a far more confusing failure than one at ingest."""
    with pytest.raises(IngestError, match="refusing to build a snapshot"):
        regions_ingest.parse_locations({"value": []})


def test_rejects_duplicate_regions():
    entry = {"name": "eastus", "displayName": "East US"}
    with pytest.raises(IngestError, match="duplicate region names"):
        regions_ingest.parse_locations({"value": [entry, dict(entry)]})


def test_rejects_entry_without_name():
    with pytest.raises(IngestError, match="no `name`"):
        regions_ingest.parse_locations({"value": [{"displayName": "Nowhere"}]})


def test_unknown_category_falls_back_rather_than_failing():
    """One unrecognised value should not cost us the other seventy regions."""
    parsed = regions_ingest.parse_locations(
        {
            "value": [
                {
                    "name": "futureregion",
                    "displayName": "Future Region",
                    "metadata": {"regionType": "Physical", "regionCategory": "SomethingNew"},
                }
            ]
        }
    )
    assert parsed[0].region_category is RegionCategory.OTHER


# --------------------------------------------------------------------------
# Provenance and snapshot identity
# --------------------------------------------------------------------------


def test_source_ref_records_collection_context(snapshot):
    assert snapshot.has(regions_ingest.SOURCE)
    ref = snapshot.sources[regions_ingest.SOURCE]
    assert ref.as_of == datetime(2026, 8, 26, tzinfo=timezone.utc)
    assert ref.api_version == regions_ingest.API_VERSION
    assert ref.collected_via_subscription == "00000000-0000-0000-0000-000000000000"


def test_snapshot_without_a_source_reports_it_missing(snapshot):
    assert not snapshot.has("retail-prices")


def test_digest_is_content_addressed_not_order_dependent(payload):
    first = regions_ingest.ingest(
        WorldSnapshot(version="v"), payload, as_of=datetime(2026, 8, 26, tzinfo=timezone.utc)
    )
    reordered = {"value": list(reversed(payload["value"]))}
    second = regions_ingest.ingest(
        WorldSnapshot(version="v"), reordered, as_of=datetime(2026, 8, 26, tzinfo=timezone.utc)
    )
    assert first.digest() == second.digest()


def test_digest_changes_when_content_changes(snapshot, payload):
    before = snapshot.digest()
    mutated = json.loads(json.dumps(payload))
    mutated["value"][0]["metadata"]["regionCategory"] = "Other"
    after = regions_ingest.ingest(
        WorldSnapshot(version="test"), mutated, as_of=datetime(2026, 8, 26, tzinfo=timezone.utc)
    ).digest()
    assert before != after


# --------------------------------------------------------------------------
# Store
# --------------------------------------------------------------------------


def test_round_trip(tmp_path, snapshot):
    store.save(snapshot, root=tmp_path)
    loaded = store.load("test", root=tmp_path)
    assert loaded.digest() == snapshot.digest()
    assert loaded.region("swedencentral").paired_regions == ["swedensouth"]


def test_tampered_snapshot_is_rejected(tmp_path, snapshot):
    """A silently modified snapshot would make past decision records
    unreproducible while still appearing to resolve."""
    path = store.save(snapshot, root=tmp_path)
    doc = json.loads(path.read_text(encoding="utf-8"))
    doc["regions"]["italynorth"]["region_category"] = "Other"
    path.write_text(json.dumps(doc, indent=2), encoding="utf-8")

    with pytest.raises(store.SnapshotError, match="does not match its recorded digest"):
        store.load("test", root=tmp_path)

    assert store.load("test", root=tmp_path, verify=False).region("italynorth")


def test_missing_snapshot_names_what_is_available(tmp_path, snapshot):
    store.save(snapshot, root=tmp_path)
    with pytest.raises(store.SnapshotError, match="Available: test"):
        store.load("2020-01-01", root=tmp_path)


def test_latest_is_chronological(tmp_path, payload):
    for version in ("2026-01-15", "2026-08-26", "2026-03-02"):
        store.save(
            regions_ingest.ingest(WorldSnapshot(version=version), payload), root=tmp_path
        )
    assert store.latest(root=tmp_path) == "2026-08-26"
