"""Service-availability ingester (ARM provider metadata)."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.ingest import services as services_ingest
from placement.snapshot.ingest.services import IngestError, normalise_location
from placement.snapshot.model import WorldSnapshot

FIXTURES = Path(__file__).parent / "fixtures"
AS_OF = datetime(2026, 8, 26, tzinfo=timezone.utc)

AKS = "Microsoft.ContainerService/managedClusters"
POSTGRES = "Microsoft.DBforPostgreSQL/flexibleServers"
STORAGE = "Microsoft.Storage/storageAccounts"


@pytest.fixture
def providers_payload() -> dict:
    return json.loads((FIXTURES / "arm-providers-sample.json").read_text(encoding="utf-8"))


@pytest.fixture
def snapshot(providers_payload) -> WorldSnapshot:
    locations = json.loads((FIXTURES / "arm-locations-sample.json").read_text(encoding="utf-8"))
    snap = regions_ingest.ingest(WorldSnapshot(version="test"), locations, as_of=AS_OF)
    return services_ingest.ingest(snap, providers_payload, as_of=AS_OF)


# --------------------------------------------------------------------------
# Normalisation — the join key
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "location,expected",
    [
        ("West Europe", "westeurope"),
        ("west europe", "westeurope"),
        ("westeurope", "westeurope"),
        ("italy north", "italynorth"),
        ("Uk West", "ukwest"),
        ("SouthEast Asia", "southeastasia"),
        ("Norway EAST", "norwayeast"),
        ("East US 2", "eastus2"),
    ],
)
def test_normalisation_folds_real_casing_variants(location, expected):
    """Provider metadata spells the same region several ways. Squeezing
    whitespace and lowercasing lands on the ARM region name."""
    assert normalise_location(location) == expected


# --------------------------------------------------------------------------
# Lookups
# --------------------------------------------------------------------------


def test_locations_resolve_to_arm_region_names(snapshot):
    assert snapshot.regions_for_service(AKS) == {
        "westeurope",
        "northeurope",
        "germanywestcentral",
        "germanynorth",
        "italynorth",
        "eastus",
    }


def test_inconsistent_casing_still_resolves(snapshot):
    """The payload spells regions three ways at once - 'italy north' (lowercased
    display name), 'swedencentral' (ARM name) and 'West Europe' (display name).
    All three must land, and none may show up as unmapped."""
    assert "italynorth" in snapshot.regions_for_service(AKS)
    storage = snapshot.regions_for_service(STORAGE)
    assert {"italynorth", "swedencentral", "westeurope"} <= storage


def test_lookup_is_case_insensitive(snapshot):
    """People type ARM resource types from memory."""
    assert snapshot.service_available("microsoft.storage/storageaccounts", "westeurope") is True
    assert snapshot.service("MICROSOFT.STORAGE/STORAGEACCOUNTS") is not None


def test_availability_is_true_and_false_where_known(snapshot):
    assert snapshot.service_available(POSTGRES, "germanywestcentral") is True
    assert snapshot.service_available(POSTGRES, "germanynorth") is False


def test_unknown_resource_type_is_none_not_false(snapshot):
    """Unknown must never be conflated with unavailable — one is a risk on the
    candidate, the other is an elimination."""
    assert snapshot.service_available("Microsoft.Nonexistent/things", "westeurope") is None


def test_global_only_types_never_eliminate_a_region(snapshot):
    entry = snapshot.service("Microsoft.Authorization/roleDefinitions")
    assert entry.global_only
    assert entry.regions == []
    assert snapshot.service_available("Microsoft.Authorization/roleDefinitions", "italynorth") is True


def test_registration_state_is_not_recorded(snapshot):
    """Postgres is NotRegistered in the fixture, yet its availability is
    unaffected: registration is a subscription fact and belongs to tenant
    context, not to a world snapshot."""
    assert snapshot.service_available(POSTGRES, "westeurope") is True
    services = snapshot.model_dump(mode="json")["services"]
    assert "registrationState" not in json.dumps(services)


# --------------------------------------------------------------------------
# Awkward real-world shapes
# --------------------------------------------------------------------------


def test_geography_strings_are_recorded_as_unmapped_not_dropped(snapshot):
    """'UK' and 'UAE' are geographies, not regions. They match nothing, and the
    source note must say so rather than losing them silently."""
    note = snapshot.sources[services_ingest.SOURCE].notes
    assert "Unmapped location strings" in note
    assert "'UK'" in note and "'UAE'" in note
    # ...and nothing that merely had odd casing.
    assert "italy north" not in note and "swedencentral" not in note


def test_type_available_only_in_a_canary_region_has_no_placement_footprint(snapshot):
    """`eastus2euap` parses as a region but is never a placement candidate, so a
    type offered only there must not appear deployable anywhere real."""
    entry = snapshot.service("Microsoft.Odd/canaryOnly")
    assert "eastus2euap" in entry.regions
    candidates = {r.name for r in snapshot.placement_candidates()}
    assert not set(entry.regions) & candidates


def test_logical_regions_are_excluded_from_service_regions(snapshot):
    for entry in snapshot.services.values():
        assert "global" not in entry.regions
        assert "centralusstage" not in entry.regions


# --------------------------------------------------------------------------
# Coverage signal
# --------------------------------------------------------------------------


def test_coverage_separates_thin_regions(snapshot):
    """Restricted-access regions report far thinner coverage than ordinary ones.
    Against real data this cleanly separated germanynorth (19%) from westeurope
    (89%)."""
    assert snapshot.service_coverage("westeurope") > snapshot.service_coverage("germanynorth")
    assert 0.0 <= snapshot.service_coverage("germanynorth") <= 1.0


def test_coverage_of_absent_region_is_zero(snapshot):
    assert snapshot.service_coverage("nowhere") == 0.0


# --------------------------------------------------------------------------
# Ordering and failure modes
# --------------------------------------------------------------------------


def test_requires_the_region_slice_first(providers_payload):
    """The join needs the region table; without it every location would look
    unmapped and the service table would be silently empty."""
    with pytest.raises(IngestError, match="build regions before providers"):
        services_ingest.ingest(WorldSnapshot(version="test"), providers_payload)


def test_rejects_non_provider_payload(snapshot):
    with pytest.raises(IngestError, match="`value` array"):
        services_ingest.parse_providers({"providers": []}, snapshot.regions)


def test_rejects_empty_payload(snapshot):
    with pytest.raises(IngestError, match="empty or not an array"):
        services_ingest.parse_providers({"value": []}, snapshot.regions)


def test_slices_are_additive(snapshot):
    """A snapshot built up over several runs keeps both slices and both dates."""
    assert snapshot.has(regions_ingest.SOURCE)
    assert snapshot.has(services_ingest.SOURCE)
    assert snapshot.regions and snapshot.services
