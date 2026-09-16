"""The engine end to end: resolve, constrain, score, record."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from placement.contracts import load_requirements
from placement.contracts.requirements import Requirements, Topology
from placement.engine import decide
from placement.engine.resolve import derive_topology, parse_duration, resolve
from placement.engine import score
from placement.snapshot.ingest import capabilities as cap
from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.ingest import services as services_ingest
from placement.snapshot.model import WorldSnapshot

FIXTURES = Path(__file__).parent / "fixtures"
SCENARIOS = sorted((Path(__file__).parent.parent / "scenarios").glob("*.yaml"))
AS_OF = datetime(2026, 8, 26, tzinfo=timezone.utc)


@pytest.fixture
def snapshot() -> WorldSnapshot:
    locations = json.loads((FIXTURES / "arm-locations-sample.json").read_text(encoding="utf-8"))
    providers = json.loads((FIXTURES / "arm-providers-sample.json").read_text(encoding="utf-8"))
    snap = regions_ingest.ingest(WorldSnapshot(version="test"), locations, as_of=AS_OF)
    snap = services_ingest.ingest(snap, providers, as_of=AS_OF)
    return cap.ingest_region_capabilities(snap, as_of=AS_OF)


def requirements(**overrides) -> Requirements:
    base = {
        "workload": "w",
        "components": [
            {"name": "api", "service": "Microsoft.ContainerService/managedClusters"},
        ],
    }
    return Requirements.model_validate({**base, **overrides})


# --------------------------------------------------------------------------
# Duration parsing and topology derivation
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "text,minutes", [("5m", 5), ("1h", 60), ("24h", 1440), ("0", 0), ("15m", 15)]
)
def test_durations_parse(text, minutes):
    assert parse_duration(text) == minutes


def test_unparseable_duration_is_none_not_zero():
    """Treating an unreadable RTO as instant would silently upgrade a component
    to the most expensive topology."""
    assert parse_duration("as soon as possible") is None
    assert parse_duration(None) is None


def test_topology_is_derived_from_the_strictest_flow():
    """The point of flows: a component inherits the strictest recovery target
    among the flows it serves, so a reporting store never pays for the checkout
    path's RTO."""
    req = Requirements.model_validate(
        {
            "workload": "w",
            "components": [
                {"name": "db", "service": "Microsoft.DBforPostgreSQL/flexibleServers"},
                {"name": "reporting", "service": "Microsoft.Synapse/workspaces"},
            ],
            "flows": [
                {"name": "checkout", "criticality": "high", "path": ["db"], "rto": "5m"},
                {"name": "nightly", "criticality": "low", "path": ["db", "reporting"], "rto": "24h"},
            ],
        }
    )
    by_name = {c.name: c for c in resolve(req)}

    assert by_name["db"].rto_minutes == 5
    assert by_name["db"].driving_flow == "checkout"
    assert derive_topology(by_name["db"], min_zones=3) is Topology.ACTIVE_ACTIVE

    assert by_name["reporting"].rto_minutes == 1440
    assert derive_topology(by_name["reporting"], min_zones=3) is Topology.ZONAL


def test_explicit_topology_overrides_derivation():
    req = Requirements.model_validate(
        {
            "workload": "w",
            "components": [
                {
                    "name": "db",
                    "service": "Microsoft.DBforPostgreSQL/flexibleServers",
                    "topology": "single",
                }
            ],
            "flows": [{"name": "f", "criticality": "high", "path": ["db"], "rto": "1m"}],
        }
    )
    component = resolve(req)[0]
    assert derive_topology(component, min_zones=3) is Topology.SINGLE


def test_residency_inherits_down_a_flow_path():
    req = Requirements.model_validate(
        {
            "workload": "w",
            "residency": {"jurisdictions": ["eu"]},
            "components": [
                {"name": "api", "service": "Microsoft.ContainerService/managedClusters"},
                {"name": "logs", "service": "Microsoft.Storage/storageAccounts"},
            ],
            "flows": [
                {
                    "name": "clinical",
                    "criticality": "high",
                    "path": ["api"],
                    "residency": {"jurisdictions": ["de"]},
                    "compliance": ["c5"],
                },
                {"name": "logging", "criticality": "low", "path": ["logs"]},
            ],
        }
    )
    by_name = {c.name: c for c in resolve(req)}
    assert set(by_name["api"].residency.jurisdictions) == {"eu", "de"}
    assert "c5" in by_name["api"].compliance
    # The logging path does not inherit the clinical flow's envelope.
    assert by_name["logs"].residency.jurisdictions == ["eu"]


# --------------------------------------------------------------------------
# Filters
# --------------------------------------------------------------------------


def test_residency_filters_on_geography_not_datacentre_location(snapshot):
    """westeurope's datacentres are in the Netherlands but its residency
    commitment is 'Europe'. Filtering a country ask on physical_location would
    promise more than Microsoft does."""
    record = decide(requirements(residency={"jurisdictions": ["de"]}), snapshot)
    surviving = {p.region for c in [record.recommended] if c for p in c.placements}
    assert "westeurope" not in surviving
    assert any(
        "geography 'Europe' is outside" in e.reason
        for e in record.eliminations_for("westeurope")
    )


def test_internal_regions_never_reach_a_recommendation(snapshot):
    record = decide(requirements(), snapshot)
    regions = {p.region for c in [record.recommended, *record.alternatives] if c for p in c.placements}
    assert "eastus2euap" not in regions


def test_unknown_capability_is_a_risk_not_an_elimination(snapshot):
    """Most providers expose no capabilities API, so unknown is common. It must
    not eliminate."""
    req = requirements(
        components=[
            {
                "name": "api",
                "service": "Microsoft.ContainerService/managedClusters",
                "capabilities": ["private-cluster"],
            }
        ]
    )
    record = decide(req, snapshot)
    assert record.feasible
    assert any(
        r.category == "unconfirmed-capability" for r in record.recommended.risks
    )
    assert not any(e.rule.startswith("capability:") for e in record.eliminations)


def test_service_absent_from_a_region_eliminates_it(snapshot):
    req = requirements(
        components=[{"name": "db", "service": "Microsoft.DBforPostgreSQL/flexibleServers"}]
    )
    record = decide(req, snapshot)
    # The fixture offers Postgres in westeurope but not northeurope.
    assert any(
        e.stage.value == "service-availability" for e in record.eliminations_for("northeurope")
    )


def test_infeasible_is_a_legitimate_answer(snapshot):
    record = decide(requirements(residency={"jurisdictions": ["antarctica"]}), snapshot)
    assert not record.feasible
    assert record.recommended is None
    assert record.eliminations


# --------------------------------------------------------------------------
# Scoring honesty
# --------------------------------------------------------------------------


def test_unscored_dimensions_are_excluded_not_defaulted(snapshot):
    """A zero would drag every ranking and a one would flatter it. Both would be
    invented, so they carry zero weight and a warning instead."""
    record = decide(requirements(), snapshot)
    for dimension in score.UNSCORED:
        sub = record.recommended.subscores[dimension]
        assert sub.weight == 0.0
        assert "not yet scored" in sub.rationale
        assert any(dimension in w for w in record.warnings)


def test_score_is_renormalised_over_live_dimensions(snapshot):
    """Without renormalising, every candidate is scaled down by the missing
    weight and scores look uniformly poor rather than simply incomplete."""
    record = decide(requirements(), snapshot)
    assert 0.0 < record.recommended.score <= 1.0


def test_missing_tenant_context_is_warned_about(snapshot):
    record = decide(requirements(), snapshot)
    assert any("no tenant context" in w for w in record.warnings)


def test_declared_horizon_is_warned_about_when_unmodelled(snapshot):
    record = decide(requirements(horizon="24mo"), snapshot)
    assert any("horizon" in w for w in record.warnings)


# --------------------------------------------------------------------------
# Determinism and provenance
# --------------------------------------------------------------------------


def test_same_inputs_produce_the_same_record(snapshot):
    """A placement decision gets challenged in review and has to survive being
    re-run."""
    req = requirements()
    first = decide(req, snapshot, now=AS_OF)
    second = decide(req, snapshot, now=AS_OF)
    assert first.model_dump_json() == second.model_dump_json()


def test_record_pins_the_snapshot_it_was_made_against(snapshot):
    record = decide(requirements(), snapshot)
    assert record.snapshot.version == snapshot.version
    assert record.snapshot.digest == snapshot.digest()
    assert record.snapshot.sources


def test_eliminations_carry_evidence(snapshot):
    record = decide(requirements(residency={"jurisdictions": ["de"]}), snapshot)
    for elimination in record.eliminations:
        assert elimination.evidence, f"{elimination.region} eliminated without evidence"
        for evidence in elimination.evidence:
            assert evidence.source and evidence.as_of


# --------------------------------------------------------------------------
# The scenarios
# --------------------------------------------------------------------------


@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_every_scenario_produces_a_record(path, snapshot):
    """The acceptance set has to run end to end, whatever the verdict."""
    record = decide(load_requirements(path), snapshot)
    assert record.workload
    assert record.requirements_digest.startswith("sha256:")
    assert record.warnings


# --------------------------------------------------------------------------
# Three kinds of "no"
# --------------------------------------------------------------------------


def _pg_requirements(**overrides):
    base = {
        "workload": "w",
        "components": [
            {
                "name": "db",
                "service": "Microsoft.DBforPostgreSQL/flexibleServers",
                "capabilities": ["zone-redundant-ha"],
            }
        ],
    }
    return Requirements.model_validate({**base, **overrides})


def _with_pg_capability(snapshot, **regions):
    """Record zone-redundant-ha support explicitly for the given regions."""
    payloads = {
        region: {"value": [{"name": "F", "zoneRedundantHaSupported": "Enabled" if ok else "Disabled"}]}
        for region, ok in regions.items()
    }
    return cap.ingest_postgres_capabilities(snapshot, payloads, as_of=AS_OF)


def test_temporary_block_is_a_risk_not_an_elimination(snapshot):
    """westeurope reports zone-redundant HA as unsupported because new
    deployments are paused, not because it never worked there. A migration is
    permanent and the block is not, so eliminating would be bad advice."""
    snap = _with_pg_capability(snapshot, westeurope=False)
    record = decide(_pg_requirements(), snap)

    assert not record.eliminations_for("westeurope")
    regions = {p.region for c in [record.recommended, *record.alternatives] if c for p in c.placements}
    assert "westeurope" in regions

    candidate = next(
        c for c in [record.recommended, *record.alternatives] if c.placements[0].region == "westeurope"
    )
    assert any(r.category == "temporary-block" for r in candidate.risks)
    assert any(
        rem.kind.value == "wait-temporary-block" for rem in candidate.remediations
    )


def test_a_capability_absent_and_not_temporarily_blocked_still_eliminates(snapshot):
    """Only the curated list makes a block temporary. Everything else is a real
    absence — `geo-backup` appears in no block entry, so an unsupported region
    is eliminated as usual."""
    snap = cap.ingest_postgres_capabilities(
        snapshot,
        {"westeurope": {"value": [{"name": "F", "geoBackupSupported": "Disabled"}]}},
        as_of=AS_OF,
    )
    record = decide(
        _pg_requirements(
            components=[
                {
                    "name": "db",
                    "service": "Microsoft.DBforPostgreSQL/flexibleServers",
                    "capabilities": ["geo-backup"],
                }
            ]
        ),
        snap,
    )
    assert any(
        e.rule == "capability:geo-backup" for e in record.eliminations_for("westeurope")
    )


def test_temporary_block_remediation_has_nobody_to_ask(snapshot):
    snap = _with_pg_capability(snapshot, westeurope=False)
    record = decide(_pg_requirements(), snap)
    candidate = next(
        c for c in [record.recommended, *record.alternatives] if c.placements[0].region == "westeurope"
    )
    remediation = next(r for r in candidate.remediations if r.kind.value == "wait-temporary-block")
    assert remediation.tier.value == "not-adjustable"
    assert "lifts on its own" in remediation.note


def test_readiness_is_a_tiebreak_not_the_ranking(snapshot):
    """Whether a ticket is worth raising is the customer's call. Sorting on
    readiness would bury a region they already operate in beneath fifty they
    have never used."""
    snap = _with_pg_capability(snapshot, westeurope=False)
    record = decide(
        _pg_requirements(landingZone={"existing_regions": ["westeurope"]}),
        snap,
    )
    assert record.recommended.placements[0].region == "westeurope"
    assert not record.recommended.deployable_today


def test_deployable_today_is_visible_on_every_candidate(snapshot):
    record = decide(requirements(), snapshot)
    for candidate in [record.recommended, *record.alternatives]:
        assert candidate.deployable_today == (not candidate.remediations)
