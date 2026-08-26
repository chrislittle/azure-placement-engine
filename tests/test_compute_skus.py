"""VM SKU ingester and the tenant-context split of the same payload."""

from __future__ import annotations

import json
from datetime import datetime, timezone

import pytest

from placement.contracts.decision import RemediationKind
from placement.snapshot.ingest import compute_skus as compute
from placement.snapshot.ingest.compute_skus import IngestError
from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.model import WorldSnapshot
from placement.tenant import compute_restrictions
from placement.tenant.compute_restrictions import ExtractError

from pathlib import Path

FIXTURES = Path(__file__).parent / "fixtures"
AS_OF = datetime(2026, 8, 26, tzinfo=timezone.utc)

VMSS = "Microsoft.Compute/virtualMachineScaleSets"


def sku(name, *, region="westeurope", zones=("1", "2", "3"), caps=None, restrictions=None,
        family="fam", resource_type="virtualMachines"):
    return {
        "resourceType": resource_type,
        "name": name,
        "family": family,
        "tier": "Standard",
        "size": name.replace("Standard_", ""),
        "locations": [region],
        "locationInfo": [{"location": region, "zones": list(zones), "zoneDetails": []}],
        "capabilities": [{"name": k, "value": v} for k, v in (caps or {}).items()],
        "restrictions": restrictions or [],
    }


H100 = "Standard_ND96isr_H100_v5"


def payload(region="westeurope", **kw):
    return {
        "value": [
            sku("Standard_D8s_v5", region=region, caps={"vCPUs": "8", "MemoryGB": "32",
                                                        "PremiumIO": "True", "RdmaEnabled": "False"}),
            sku(H100, region=region, zones=("1",),
                caps={"vCPUs": "96", "MemoryGB": "1900", "GPUs": "8", "RdmaEnabled": "True"}),
            sku("Standard_DC8as_v5", region=region,
                caps={"vCPUs": "8", "ConfidentialComputingType": "SNP"}),
            # Non-VM entries share the response and must be ignored.
            sku("P30", region=region, resource_type="disks"),
        ],
        **kw,
    }


@pytest.fixture
def snapshot() -> WorldSnapshot:
    locations = json.loads((FIXTURES / "arm-locations-sample.json").read_text(encoding="utf-8"))
    return regions_ingest.ingest(WorldSnapshot(version="test"), locations, as_of=AS_OF)


# --------------------------------------------------------------------------
# Projection
# --------------------------------------------------------------------------


def test_only_virtual_machines_are_kept(snapshot):
    compute.ingest(snapshot, {"westeurope": payload()}, as_of=AS_OF)
    assert "P30" not in snapshot.vm_skus
    assert set(snapshot.vm_skus) == {"Standard_D8s_v5", H100, "Standard_DC8as_v5"}


def test_capabilities_are_projected_and_typed(snapshot):
    compute.ingest(snapshot, {"westeurope": payload()}, as_of=AS_OF)
    gpu = snapshot.vm_sku(H100)
    assert gpu.vcpus == 96
    assert gpu.memory_gb == pytest.approx(1900.0)
    assert gpu.gpus == 8
    assert gpu.rdma is True
    assert gpu.is_accelerated

    general = snapshot.vm_sku("Standard_D8s_v5")
    assert general.rdma is False
    assert general.premium_io is True
    assert general.gpus is None


def test_sku_zones_are_finer_than_region_zones(snapshot):
    """A three-zone region may offer a scarce SKU in only one zone, and a zonal
    deployment depends on the SKU's zones, not the region's."""
    compute.ingest(snapshot, {"westeurope": payload()}, as_of=AS_OF)
    assert snapshot.region("westeurope").zone_count == 3
    assert snapshot.vm_sku(H100).zones_in("westeurope") == ["1"]
    assert snapshot.vm_sku("Standard_D8s_v5").zones_in("westeurope") == ["1", "2", "3"]


def test_lookup_is_case_insensitive(snapshot):
    compute.ingest(snapshot, {"westeurope": payload()}, as_of=AS_OF)
    assert snapshot.vm_sku("standard_nd96isr_h100_v5") is not None
    assert snapshot.sku_available("STANDARD_D8S_V5", "westeurope") is True


def test_merging_regions_accumulates_only_the_region_map(snapshot):
    compute.ingest(
        snapshot,
        {"westeurope": payload("westeurope"), "italynorth": payload("italynorth")},
        as_of=AS_OF,
    )
    gpu = snapshot.vm_sku(H100)
    assert gpu.regions == {"westeurope", "italynorth"}
    assert gpu.gpus == 8  # capabilities describe silicon, not region


def test_regions_outside_the_region_table_are_dropped(snapshot):
    compute.ingest(snapshot, {"qatarcentral": payload("qatarcentral")}, as_of=AS_OF)
    assert snapshot.vm_sku(H100).regions == set()


# --------------------------------------------------------------------------
# Availability semantics
# --------------------------------------------------------------------------


def test_unknown_before_ingest_false_after(snapshot):
    """Before the slice exists, a SKU question is unknown. After it exists, the
    slice enumerates every SKU the queried regions offer, so absence is a real
    negative."""
    assert snapshot.sku_available(H100, "westeurope") is None
    compute.ingest(snapshot, {"westeurope": payload()}, as_of=AS_OF)
    assert snapshot.sku_available(H100, "westeurope") is True
    assert snapshot.sku_available(H100, "italynorth") is False
    assert snapshot.sku_available("Standard_Nonexistent", "westeurope") is False


def test_unreadable_region_is_recorded_not_silently_empty(snapshot):
    compute.ingest(
        snapshot, {"westeurope": payload(), "italynorth": {"nope": []}}, as_of=AS_OF
    )
    note = snapshot.sources[compute.SOURCE].notes
    assert "Unreadable responses for: italynorth" in note


def test_rejects_when_nothing_usable(snapshot):
    with pytest.raises(IngestError, match="no VM SKUs found"):
        compute.ingest(snapshot, {"westeurope": {"value": []}})


# --------------------------------------------------------------------------
# Derived capabilities
# --------------------------------------------------------------------------


def test_infiniband_and_confidential_derive_from_sku_facts(snapshot):
    compute.ingest(snapshot, {"westeurope": payload()}, as_of=AS_OF)
    compute.derive_capabilities(snapshot)

    assert snapshot.capability_available(VMSS, "infiniband", "westeurope") is True
    assert snapshot.capability_available(VMSS, "confidential-compute", "westeurope") is True
    assert snapshot.capability_available(VMSS, "accelerator", "westeurope") is True
    assert snapshot.capability_available(VMSS, "infiniband", "italynorth") is False


# --------------------------------------------------------------------------
# The tenant split — restrictions are not world facts
# --------------------------------------------------------------------------


RESTRICTED = {
    "value": [
        sku(
            H100,
            restrictions=[
                {
                    "type": "Location",
                    "values": ["westeurope"],
                    "reasonCode": "NotAvailableForSubscription",
                    "restrictionInfo": {"locations": ["westeurope"], "zones": []},
                }
            ],
        ),
        sku(
            "Standard_D8s_v5",
            restrictions=[
                {
                    "type": "Zone",
                    "values": ["westeurope"],
                    "reasonCode": "NotAvailableForSubscription",
                    "restrictionInfo": {"locations": ["westeurope"], "zones": ["2", "3"]},
                }
            ],
        ),
        sku(
            "Standard_DC8as_v5",
            restrictions=[
                {
                    "type": "Location",
                    "values": ["westeurope"],
                    "reasonCode": "QuotaId",
                    "restrictionInfo": {"locations": ["westeurope"], "zones": []},
                }
            ],
        ),
    ]
}


def test_restrictions_stay_out_of_the_world_snapshot(snapshot):
    """The same payload feeds two places. A pinned world file must not become
    subscription-specific."""
    compute.ingest(snapshot, {"westeurope": RESTRICTED}, as_of=AS_OF)
    dumped = json.dumps(snapshot.model_dump(mode="json")["vm_skus"])
    assert "NotAvailableForSubscription" not in dumped
    assert "restrictions" not in dumped
    # The SKU is still recorded as existing - it does exist, it is just unreachable.
    assert snapshot.sku_available(H100, "westeurope") is True


def test_region_restriction_becomes_a_region_access_request():
    context = compute_restrictions.build({"westeurope": RESTRICTED}, collected_at=AS_OF)
    restriction = context.restriction_for(H100, "westeurope")
    assert restriction.is_whole_region
    assert not context.is_unrestricted(H100, "westeurope")

    remediation = restriction.remediation()
    assert remediation.kind is RemediationKind.REGION_ACCESS_REQUEST
    assert "Other Requests" in remediation.process


def test_zone_restriction_becomes_a_zonal_access_request():
    """Restricted in two of three zones is not the same as unavailable."""
    context = compute_restrictions.build({"westeurope": RESTRICTED}, collected_at=AS_OF)
    restriction = context.restriction_for("Standard_D8s_v5", "westeurope")
    assert restriction.zones == ["2", "3"]
    assert not restriction.is_whole_region
    assert context.is_unrestricted("Standard_D8s_v5", "westeurope")
    assert restriction.remediation().kind is RemediationKind.ZONAL_ACCESS_REQUEST


def test_quota_id_is_not_liftable_by_a_request():
    """QuotaId means the subscription's offer excludes the SKU. A support ticket
    will not change it, and saying otherwise would waste the customer's time."""
    context = compute_restrictions.build({"westeurope": RESTRICTED}, collected_at=AS_OF)
    remediation = context.restriction_for("Standard_DC8as_v5", "westeurope").remediation()
    assert remediation.kind is RemediationKind.NONE
    assert "different offer" in remediation.detail


def test_unrestricted_sku_has_no_access_block():
    context = compute_restrictions.build({"westeurope": RESTRICTED}, collected_at=AS_OF)
    assert context.is_unrestricted("Standard_Anything", "westeurope")


def test_restrictions_are_deduped_across_regions():
    context = compute_restrictions.build(
        {"westeurope": RESTRICTED, "italynorth": RESTRICTED}, collected_at=AS_OF
    )
    keys = {(r.sku, r.region) for r in context.sku_restrictions}
    assert len(keys) == len(context.sku_restrictions)


def test_rejects_non_compute_payload():
    with pytest.raises(ExtractError, match="`value` array"):
        compute_restrictions.parse_restrictions({"skus": []})


# --------------------------------------------------------------------------
# Quota — the second gate, and the one that actually bites on GPU
# --------------------------------------------------------------------------


def usages(region="westeurope", families=None):
    families = families or {}
    return {
        "value": [
            {
                "name": {"value": family, "localizedValue": family},
                "limit": limit,
                "currentValue": current,
                "unit": "Count",
            }
            for family, (limit, current) in families.items()
        ]
    }


H100_FAMILY = "standardNDSH100v5Family"


def context_with_quota(**families):
    return compute_restrictions.build(
        {"westeurope": payload()},
        usages={"westeurope": usages(families=families)},
        collected_at=AS_OF,
    )


def test_zero_quota_is_not_deployable_despite_no_restriction():
    """The correction this whole slice exists for. On live data 22 of 28 GPU
    families reported a limit of zero, so an unrestricted SKU is routinely
    undeployable - that is the common case, not an edge case."""
    context = context_with_quota(**{H100_FAMILY: (0, 0)})
    assert context.is_unrestricted(H100, "westeurope")  # no access restriction...

    result = context.assess(H100, "westeurope", family=H100_FAMILY, vcpus_required=96)
    assert not result.deployable
    assert result.remediation.kind is RemediationKind.QUOTA_INCREASE
    assert "cores-vCPUs" in result.remediation.process


def test_sufficient_quota_is_deployable():
    context = context_with_quota(**{H100_FAMILY: (192, 0)})
    result = context.assess(H100, "westeurope", family=H100_FAMILY, vcpus_required=96)
    assert result.deployable
    assert result.quota_available == 192


def test_quota_accounts_for_current_usage():
    """Limit alone is not headroom."""
    context = context_with_quota(**{H100_FAMILY: (192, 160)})
    result = context.assess(H100, "westeurope", family=H100_FAMILY, vcpus_required=96)
    assert not result.deployable
    assert result.quota_available == 32


def test_access_restriction_takes_precedence_over_quota():
    """You cannot raise quota in a region you have no entitlement to, so the
    access remedy must be the one reported."""
    context = compute_restrictions.build(
        {"westeurope": RESTRICTED},
        usages={"westeurope": usages(families={H100_FAMILY: (0, 0)})},
        collected_at=AS_OF,
    )
    result = context.assess(H100, "westeurope", family=H100_FAMILY, vcpus_required=96)
    assert result.remediation.kind is RemediationKind.REGION_ACCESS_REQUEST


def test_missing_quota_data_says_so_rather_than_implying_a_clean_bill():
    context = compute_restrictions.build({"westeurope": payload()}, collected_at=AS_OF)
    result = context.assess(H100, "westeurope", family=H100_FAMILY, vcpus_required=96)
    assert result.deployable
    assert "quota not checked" in result.reason


def test_family_names_normalise_across_the_two_apis():
    """The SKU list and the usages API spell families differently -
    'standardNDSFamily' against 'Standard NCASv3_T4 Family'."""
    from placement.tenant.model import normalise_family

    assert normalise_family("Standard NCASv3_T4 Family") == "standardncasv3_t4family"
    assert normalise_family("standardNDSH100v5Family") == normalise_family(
        "StandardNDSH100v5Family"
    )


def test_regional_core_cap_is_kept_and_flagged():
    from placement.tenant.quota import REGIONAL_TOTALS, parse_usages, regional_core_limit

    entries = parse_usages(usages(families={"cores": (100, 20), H100_FAMILY: (0, 0)}), "westeurope")
    total = regional_core_limit(entries, "westeurope")
    assert total.limit == 100 and total.available == 80
    assert total.family in REGIONAL_TOTALS


# --------------------------------------------------------------------------
# Adjustment tiers and the capacity-reservation gate
# --------------------------------------------------------------------------


def test_regional_quota_is_self_service_zonal_is_a_ticket():
    """Microsoft.Quota is regional-only and cannot express a per-zone limit, so a
    zone-specific vCPU ask is a support ticket even where the regional equivalent
    is a programmatic PUT. Promising self-service for a zonal ask would be wrong."""
    from placement.contracts.decision import AdjustmentTier

    context = context_with_quota(**{H100_FAMILY: (0, 0)})

    regional = context.assess(H100, "westeurope", family=H100_FAMILY, vcpus_required=96)
    assert regional.remediation.tier is AdjustmentTier.SELF_SERVICE
    assert regional.remediation.is_programmatic

    zonal = context.assess(
        H100, "westeurope", family=H100_FAMILY, vcpus_required=96, zonal=True
    )
    assert zonal.remediation.tier is AdjustmentTier.SUPPORT_TICKET
    assert not zonal.remediation.is_programmatic
    assert "regional-only" in zonal.remediation.note


def test_access_requests_are_always_tickets():
    from placement.contracts.decision import AdjustmentTier

    context = compute_restrictions.build({"westeurope": RESTRICTED}, collected_at=AS_OF)
    remediation = context.restriction_for(H100, "westeurope").remediation()
    assert remediation.tier is AdjustmentTier.SUPPORT_TICKET


def test_offer_type_exclusion_is_not_adjustable():
    from placement.contracts.decision import AdjustmentTier

    context = compute_restrictions.build({"westeurope": RESTRICTED}, collected_at=AS_OF)
    remediation = context.restriction_for("Standard_DC8as_v5", "westeurope").remediation()
    assert remediation.tier is AdjustmentTier.NOT_ADJUSTABLE


def reservable(name, supported):
    return sku(name, caps={"CapacityReservationSupported": supported,
                           "SupportedCapacityReservationTypes": "Open,Targeted"})


def test_capacity_reservation_is_a_third_independent_gate():
    """A subscription can hold approved quota and still fail to reserve, so
    reservability is checked off CapacityReservationSupported rather than assumed
    from quota."""
    context = compute_restrictions.build(
        {"westeurope": {"value": [reservable("Standard_A", "True"),
                                  reservable("Standard_B", "False")]}},
        collected_at=AS_OF,
    )
    assert context.can_reserve("Standard_A", "westeurope") is True
    assert context.can_reserve("Standard_B", "westeurope") is False


def test_reservation_types_field_is_not_used_as_the_signal():
    """SupportedCapacityReservationTypes is a static series property that reads
    the same on every subscription and overstates availability."""
    context = compute_restrictions.build(
        {"westeurope": {"value": [reservable("Standard_B", "False")]}}, collected_at=AS_OF
    )
    # Advertises Open,Targeted yet is not reservable on this subscription.
    assert context.can_reserve("Standard_B", "westeurope") is False


def test_missing_capability_is_treated_as_unreservable():
    """A false positive here sends someone at a reservation that fails."""
    context = compute_restrictions.build(
        {"westeurope": {"value": [sku("Standard_C", caps={})]}}, collected_at=AS_OF
    )
    assert context.can_reserve("Standard_C", "westeurope") is False


def test_uncollected_region_is_unknown_not_false():
    context = compute_restrictions.build(
        {"westeurope": {"value": [reservable("Standard_A", "True")]}}, collected_at=AS_OF
    )
    assert context.can_reserve("Standard_A", "italynorth") is None
