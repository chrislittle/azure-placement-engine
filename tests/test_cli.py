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


def test_snapshot_build_accepts_compute_dir_alone(tmp_path):
    """Every input path must be reachable on its own - slices are additive, so
    --compute-dir without the others has to be a valid invocation."""
    empty = tmp_path / "compute"
    empty.mkdir()
    result = runner.invoke(app, ["snapshot", "build", "--compute-dir", str(empty)])
    # Reaches the ingester (and fails there for lack of payloads) rather than
    # being rejected as "no input provided".
    assert result.exit_code != 2, result.output


# --------------------------------------------------------------------------
# collect
# --------------------------------------------------------------------------


def test_every_source_writes_where_build_reads_from(tmp_path):
    """`ape collect --out X` then `ape snapshot build --payloads X` has to line
    up, or the pipeline is two commands that only look connected."""
    from placement.collect import SOURCES

    expected = {
        "locations": tmp_path / "locations.json",
        "providers": tmp_path / "providers.json",
        "storage-skus": tmp_path / "storage-skus.json",
        "pg": tmp_path / "pg" / "westeurope.json",
        "compute": tmp_path / "compute" / "westeurope.json",
        "usages": tmp_path / "usages" / "westeurope.json",
    }
    assert {s.name for s in SOURCES} == set(expected)
    for source in SOURCES:
        region = "westeurope" if source.per_region else None
        assert source.target(tmp_path, region) == expected[source.name]


def test_compute_source_filters_by_location():
    """The unfiltered Microsoft.Compute/skus response is ~230 MB."""
    from placement.collect import SOURCES

    compute = next(s for s in SOURCES if s.name == "compute")
    assert compute.per_region and compute.filter_by_location


def test_locations_is_collected_before_anything_per_region():
    """Per-region sources need the region list, so it cannot be just another job
    in the pool."""
    from placement.collect import BOOTSTRAP, SOURCES

    bootstrap = next(s for s in SOURCES if s.name == BOOTSTRAP)
    assert not bootstrap.per_region


def test_payloads_directory_is_inferred(tmp_path):
    """A tree missing some sources must still build the ones present, since
    slices are additive."""
    (tmp_path / "locations.json").write_text("{}", encoding="utf-8")
    result = runner.invoke(app, ["snapshot", "build", "--payloads", str(tmp_path)])
    # Reaches ingest (and fails on the empty payload) rather than "no input".
    assert result.exit_code != 2, result.output


def test_az_is_resolved_through_which_not_bare_name():
    """On Windows `az` is a .cmd shim, so a bare "az" in an argv list is not
    findable by CreateProcess."""
    import inspect

    from placement import collect as collect_mod

    source = inspect.getsource(collect_mod)
    assert 'shutil.which("az")' in source
    assert '["az",' not in source
