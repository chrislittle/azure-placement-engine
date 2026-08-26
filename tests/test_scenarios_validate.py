"""Every scenario must parse against the requirements schema.

These four scenarios are the acceptance set, not a roadmap: they exist to force
the schema to express all four constraint families from day one.
"""

from pathlib import Path

import pytest

from placement.contracts import load_requirements
from placement.contracts.requirements import IMPLICIT_FLOW_NAME, Requirements

SCENARIOS = sorted((Path(__file__).parent.parent / "scenarios").glob("*.yaml"))


def test_scenarios_exist():
    assert SCENARIOS, "no scenario fixtures found"


@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_scenario_parses(path):
    req = load_requirements(path)
    assert req.workload
    assert req.components
    assert abs(sum(req.priorities.normalised().values()) - 1.0) < 1e-9


@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_every_component_serves_a_flow(path):
    """A component with no flow has no stated purpose to place it against."""
    req = load_requirements(path)
    for component in req.components:
        assert req.flows_for(component.name), f"{component.name} serves no flow"


@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_components_named_by_arm_resource_type(path):
    """ARM resource type is the primary way to name a component."""
    req = load_requirements(path)
    for component in req.components:
        assert component.service, f"{component.name} should carry an ARM resource type"
        assert "/" in component.service, f"{component.service!r} is not an ARM resource type"


def test_implicit_flow_fallback():
    """With no flow inventory, behaviour degrades to one flow over everything."""
    req = Requirements.model_validate(
        {
            "workload": "no-flow-inventory",
            "components": [
                {"name": "app", "service": "Microsoft.ContainerService/managedClusters"},
                {"name": "db", "service": "Microsoft.DBforPostgreSQL/flexibleServers"},
            ],
        }
    )
    flows = req.effective_flows()
    assert len(flows) == 1
    assert flows[0].name == IMPLICIT_FLOW_NAME
    assert flows[0].path == ["app", "db"]
    assert req.flows_for("db") == flows


def test_orphan_component_rejected():
    with pytest.raises(ValueError, match="appear in no flow"):
        Requirements.model_validate(
            {
                "workload": "orphan",
                "components": [
                    {"name": "app", "service": "Microsoft.ContainerService/managedClusters"},
                    {"name": "stray", "service": "Microsoft.Search/searchServices"},
                ],
                "flows": [{"name": "f", "path": ["app"], "criticality": "high"}],
            }
        )


def test_unknown_flow_component_rejected():
    with pytest.raises(ValueError, match="unknown components"):
        Requirements.model_validate(
            {
                "workload": "bad-path",
                "components": [{"name": "app", "service": "Microsoft.ContainerService/managedClusters"}],
                "flows": [{"name": "f", "path": ["app", "ghost"], "criticality": "high"}],
            }
        )


# --------------------------------------------------------------------------
# Eliminations that a support request could lift
# --------------------------------------------------------------------------


def _elimination(**kwargs):
    from placement.contracts.decision import Elimination, EliminationStage

    defaults = {
        "region": "germanynorth",
        "stage": EliminationStage.SERVICE_AVAILABILITY,
        "rule": "service-availability",
        "reason": "not available",
    }
    return Elimination(**{**defaults, **kwargs})


def test_elimination_without_remediation_is_final():
    assert _elimination().is_final


def test_restricted_region_elimination_is_not_final():
    """Region access is not open by default. A region ruled out only because
    access has not been requested must not read the same as one ruled out on
    residency - a customer told 'unavailable' will settle for a worse region
    rather than raise a ticket that would have succeeded."""
    from placement.contracts.decision import (
        REGION_ACCESS_PROCESS,
        REGION_ACCESS_REFERENCE,
        Remediation,
        RemediationKind,
    )

    elimination = _elimination(
        remediation=Remediation(
            kind=RemediationKind.REGION_ACCESS_REQUEST,
            detail="germanynorth is an access-restricted region",
            process=REGION_ACCESS_PROCESS,
            reference=REGION_ACCESS_REFERENCE,
        )
    )
    assert not elimination.is_final
    assert "Other Requests" in elimination.remediation.process
    assert elimination.remediation.reference.startswith("https://learn.microsoft.com")


def test_remediation_kind_none_still_counts_as_final():
    from placement.contracts.decision import Remediation, RemediationKind

    elimination = _elimination(
        remediation=Remediation(kind=RemediationKind.NONE, detail="service does not exist there")
    )
    assert elimination.is_final


def test_record_separates_actionable_from_blocked():
    from datetime import datetime, timezone

    from placement.contracts.decision import (
        DecisionRecord,
        EliminationStage,
        Remediation,
        RemediationKind,
        SnapshotRef,
        TenantRef,
    )

    record = DecisionRecord(
        workload="w",
        generated_at=datetime(2026, 8, 26, tzinfo=timezone.utc),
        engine_version="0.0.1",
        snapshot=SnapshotRef(version="2026-08-26"),
        tenant=TenantRef(mode="none"),
        requirements_digest="sha256:abc",
        eliminations=[
            _elimination(region="eastus", stage=EliminationStage.RESIDENCY, reason="outside eu"),
            _elimination(
                region="germanynorth",
                remediation=Remediation(
                    kind=RemediationKind.ZONAL_ACCESS_REQUEST, detail="zonal access not enabled"
                ),
            ),
        ],
    )
    assert [e.region for e in record.actionable_eliminations()] == ["germanynorth"]
    assert record.blocked_regions() == {"eastus"}
