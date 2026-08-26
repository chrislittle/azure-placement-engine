"""Every scenario must parse against the requirements schema.

These four scenarios are the acceptance set, not a roadmap: they exist to force
the schema to express all four constraint families from day one.
"""

from pathlib import Path

import pytest

from placement.contracts import load_requirements

SCENARIOS = sorted((Path(__file__).parent.parent / "scenarios").glob("*.yaml"))


def test_scenarios_exist():
    assert SCENARIOS, "no scenario fixtures found"


@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_scenario_parses(path):
    req = load_requirements(path)
    assert req.workload
    assert req.components
    assert abs(sum(req.priorities.normalised().values()) - 1.0) < 1e-9
