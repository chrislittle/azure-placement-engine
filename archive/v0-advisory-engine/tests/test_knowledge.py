"""Curated knowledge: the facts no API returns."""

from __future__ import annotations

from datetime import date, timedelta

import pytest

from placement import knowledge
from placement.knowledge import KnowledgeError


def test_every_file_carries_provenance():
    """Undated curated knowledge cannot be trusted to be current. Every file must
    say when it was reviewed and where it came from."""
    files = knowledge.all_files()
    assert files, "no curated knowledge files found"
    for f in files:
        assert f.reviewed is not None, f"{f.name} has no reviewed date"
        assert f.source, f"{f.name} has no source"
        assert f.confidence != "unknown", f"{f.name} declares no confidence"


def test_undated_knowledge_counts_as_stale():
    undated = knowledge.KnowledgeFile("test", {"source": "x"})
    assert undated.is_stale()
    assert "undated" in undated.provenance()


def test_staleness_is_reported_not_enforced():
    """A stale rule still applies - the record says it is old rather than
    dropping it, because dropping a rule silently is worse than citing an old
    one."""
    old = knowledge.KnowledgeFile("test", {"reviewed": "2020-01-01", "confidence": "high"})
    assert old.is_stale()
    assert "STALE" in old.provenance()
    assert old.get("reviewed") == "2020-01-01"


def test_fresh_knowledge_is_not_flagged():
    recent = knowledge.KnowledgeFile(
        "test", {"reviewed": date.today().isoformat(), "confidence": "high"}
    )
    assert not recent.is_stale()
    assert "STALE" not in recent.provenance()


def test_internal_region_markers_come_from_curation():
    assert "euap" in knowledge.internal_region_suffixes()
    assert "Canary (US)" in knowledge.internal_geographies()


def test_region_model_uses_the_curated_markers():
    from placement.snapshot.model import INTERNAL_REGION_SUFFIXES

    assert set(INTERNAL_REGION_SUFFIXES) == set(knowledge.internal_region_suffixes())


# --------------------------------------------------------------------------
# Quota adjustment
# --------------------------------------------------------------------------


def test_compute_regional_is_self_service_zonal_is_a_ticket():
    assert knowledge.adjustment_tier("Microsoft.Compute") == "self-service"
    assert knowledge.adjustment_tier("Microsoft.Compute", zonal=True) == "support-ticket"


def test_case_insensitive_provider_lookup():
    assert knowledge.quota_adjustment("microsoft.compute") is not None


def test_unknown_provider_returns_unknown_not_a_guess():
    """An optimistic default would promise self-service where a ticket is
    required, which is the expensive direction to be wrong in."""
    assert knowledge.adjustment_tier("Microsoft.Nonexistent") == "unknown"
    assert knowledge.quota_adjustment("Microsoft.Nonexistent") is None


def test_compute_backed_services_are_flagged():
    """AKS node-pool zonal capacity draws on Compute vCPU quota, so the ask
    routes through Compute rather than the wrapping service."""
    aks = knowledge.quota_adjustment("Microsoft.ContainerService")
    assert aks["compute_backed"] is True
    assert aks["zonal_dimension"] is False


# --------------------------------------------------------------------------
# Capacity signals
# --------------------------------------------------------------------------


def test_spot_placement_score_is_marked_unusable_for_on_demand():
    """The trap this file exists to prevent: it looks like a capacity signal and
    describes a different pool."""
    assert not knowledge.signal_is_usable("spot-placement-score")
    assert "spot" in knowledge.capacity_signal("spot-placement-score")["scope"].lower()


def test_reservation_types_field_is_marked_unusable():
    assert not knowledge.signal_is_usable("supported-capacity-reservation-types")


def test_capacity_reservation_supported_is_the_usable_one():
    assert knowledge.signal_is_usable("capacity-reservation-supported")


def test_missing_file_raises():
    with pytest.raises(KnowledgeError, match="no curated knowledge file"):
        knowledge.load("does-not-exist")
