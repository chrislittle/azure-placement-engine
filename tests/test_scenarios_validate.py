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
