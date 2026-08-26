"""Input and output contracts for the placement engine.

`requirements` is the hand-authored (or agent-authored) input; `decision` is the
engine-authored output. Both are versioned independently of the engine so a
decision record stays readable after the engine moves on.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

from placement.contracts.decision import DecisionRecord
from placement.contracts.requirements import Requirements

__all__ = ["DecisionRecord", "Requirements", "load_requirements", "parse_requirements"]


def parse_requirements(data: dict[str, Any]) -> Requirements:
    return Requirements.model_validate(data)


def load_requirements(path: str | Path) -> Requirements:
    """Load and validate a requirements file.

    YAML and JSON both parse here — YAML is a superset, and the input format is
    deliberately left to the caller's taste since agents will emit JSON and
    humans will write YAML.
    """
    text = Path(path).read_text(encoding="utf-8")
    data = yaml.safe_load(text)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a mapping at the document root, got {type(data).__name__}")
    return parse_requirements(data)
