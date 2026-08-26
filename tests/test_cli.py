"""CLI surface checks."""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from typer.testing import CliRunner

from placement.cli import app

runner = CliRunner()
SCENARIOS = sorted((Path(__file__).parent.parent / "scenarios").glob("*.yaml"))
CLI_SOURCE = Path(__file__).parent.parent / "src" / "placement" / "cli.py"


def test_cli_output_is_ascii_only():
    """Windows consoles default to cp1252, where a stray arrow glyph crashes the
    command rather than degrading. Keep CLI output inside ASCII."""
    offenders = re.findall(r"[^\x00-\x7F]", CLI_SOURCE.read_text(encoding="utf-8"))
    assert not offenders, f"non-ASCII characters in CLI output: {sorted(set(offenders))}"


@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_validate_accepts_every_scenario(path):
    result = runner.invoke(app, ["validate", str(path)])
    assert result.exit_code == 0, result.output
    assert "Valid" in result.output


def test_validate_rejects_bad_file(tmp_path):
    bad = tmp_path / "bad.yaml"
    bad.write_text("workload: nothing-here\n", encoding="utf-8")
    result = runner.invoke(app, ["validate", str(bad)])
    assert result.exit_code == 1
    assert "Invalid" in result.output


def test_snapshot_build_requires_a_source():
    result = runner.invoke(app, ["snapshot", "build"])
    assert result.exit_code == 2
    assert "--subscription" in result.output
