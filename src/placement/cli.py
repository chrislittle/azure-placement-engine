"""Command line surface.

Output is kept ASCII-only: Windows consoles default to cp1252, and a stray
arrow glyph will crash the command rather than degrade.

Deliberately small for now: build and inspect snapshots, and validate a
requirements file. The placement command itself lands with the solver.
"""

from __future__ import annotations

from datetime import date
from pathlib import Path

import typer
from rich.console import Console
from rich.table import Table

from placement import __version__
from placement.contracts import load_requirements
from placement.snapshot import store
from placement.snapshot.ingest import PayloadError, read_payload
from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.model import WorldSnapshot

app = typer.Typer(help="Azure Placement Engine", no_args_is_help=True, add_completion=False)
snapshot_app = typer.Typer(help="Build and inspect pinned world snapshots.", no_args_is_help=True)
app.add_typer(snapshot_app, name="snapshot")

console = Console()
err = Console(stderr=True)


@app.command()
def version() -> None:
    """Print the engine version."""
    console.print(__version__)


# --------------------------------------------------------------------------
# snapshot
# --------------------------------------------------------------------------


@snapshot_app.command("build")
def snapshot_build(
    from_file: Path | None = typer.Option(
        None,
        "--from-file",
        exists=True,
        dir_okay=False,
        help="An ARM locations response collected offline with `az rest`. No credentials needed.",
    ),
    subscription: str | None = typer.Option(
        None, "--subscription", "-s", help="Fetch live from ARM using the ambient Azure credential."
    ),
    snapshot_version: str = typer.Option(
        None, "--version", "-v", help="Snapshot version id. Defaults to today's date."
    ),
) -> None:
    """Build (or extend) a snapshot from the ARM locations API."""
    if not from_file and not subscription:
        err.print(
            "[red]Provide --from-file or --subscription.[/red]\n\n"
            "To collect offline without credentials in this process:\n"
            "  [cyan]az rest --method get \\\n"
            '    --url "https://management.azure.com/subscriptions/<id>/locations'
            '?api-version=2022-12-01" > locations.json[/cyan]"'
        )
        raise typer.Exit(2)

    version_id = snapshot_version or date.today().isoformat()

    if from_file:
        try:
            payload, encoding = read_payload(from_file)
        except PayloadError as exc:
            err.print(f"[red]{exc}[/red]")
            raise typer.Exit(1) from exc
        if encoding not in ("utf-8", "utf-8-sig"):
            console.print(f"[yellow]Note:[/yellow] read {from_file.name} as {encoding}, not UTF-8.")
    else:
        payload = regions_ingest.fetch_locations(subscription)  # type: ignore[arg-type]

    try:
        existing = store.load(version_id, verify=False)
    except store.SnapshotError:
        existing = WorldSnapshot(version=version_id)

    snapshot = regions_ingest.ingest(existing, payload, subscription_id=subscription)
    path = store.save(snapshot)

    candidates = snapshot.placement_candidates()
    internal = snapshot.internal_regions()

    console.print(
        f"[green]Wrote[/green] {path.relative_to(store.repo_root())}\n"
        f"  {len(snapshot.regions)} locations returned, "
        f"{len(snapshot.physical_regions())} physical\n"
        f"  [bold]{len(candidates)} placement candidates[/bold], "
        f"{len(snapshot.with_zones(3))} with 3+ availability zones\n"
        f"  digest {snapshot.digest()}"
    )
    if internal:
        # Worth surfacing every time: these look like ordinary regions in the
        # API, and eastus2euap reports more zones than any production region.
        console.print(
            f"  [yellow]{len(internal)} internal canary/staging regions excluded:[/yellow] "
            + ", ".join(sorted(r.name for r in internal))
        )


@snapshot_app.command("list")
def snapshot_list() -> None:
    """List available snapshot versions."""
    versions = store.list_versions()
    if not versions:
        console.print("[yellow]No snapshots yet.[/yellow] Run `ape snapshot build`.")
        raise typer.Exit(0)
    for v in versions:
        console.print(v)


@snapshot_app.command("show")
def snapshot_show(
    snapshot_version: str = typer.Argument(None, help="Defaults to the newest snapshot."),
    geography_group: str = typer.Option(
        None, "--geo", "-g", help="Filter to a geography group, e.g. 'Europe'."
    ),
) -> None:
    """Show the regions in a snapshot."""
    try:
        snapshot = store.load(snapshot_version or store.latest())
    except store.SnapshotError as exc:
        err.print(f"[red]{exc}[/red]")
        raise typer.Exit(1) from exc

    rows = snapshot.placement_candidates()
    if geography_group:
        rows = [r for r in rows if r.geography_group == geography_group]
    rows.sort(key=lambda r: (r.geography_group or "", r.name))

    table = Table(title=f"snapshot {snapshot.version}", header_style="bold")
    table.add_column("Region")
    table.add_column("Geography")
    table.add_column("Category")
    table.add_column("AZs", justify="right")
    table.add_column("Paired with")

    for region in rows:
        table.add_row(
            region.name,
            region.geography or "-",
            region.region_category.value,
            str(region.zone_count) if region.has_availability_zones else "-",
            ", ".join(region.paired_regions) or "-",
        )

    console.print(table)
    for source, ref in sorted(snapshot.sources.items()):
        console.print(f"[dim]{source}: as of {ref.as_of.isoformat()}[/dim]")


# --------------------------------------------------------------------------
# validate
# --------------------------------------------------------------------------


@app.command()
def validate(
    path: Path = typer.Argument(..., exists=True, dir_okay=False, help="A requirements YAML file.")
) -> None:
    """Validate a requirements file and summarise how the engine reads it."""
    try:
        req = load_requirements(path)
    except Exception as exc:
        err.print(f"[red]Invalid:[/red] {exc}")
        raise typer.Exit(1) from exc

    flows = req.effective_flows()
    implicit = not req.flows

    console.print(f"[green]Valid[/green] - {req.workload}")
    console.print(f"  {len(req.components)} components, {len(flows)} flows" + (" (implicit)" if implicit else ""))

    table = Table(header_style="bold")
    table.add_column("Flow")
    table.add_column("Criticality")
    table.add_column("RTO")
    table.add_column("RPO")
    table.add_column("Path")
    for flow in flows:
        table.add_row(
            flow.name,
            flow.criticality.value,
            flow.rto or "-",
            flow.rpo or "-",
            " -> ".join(flow.path) + ("  [dim](unsplittable)[/dim]" if not flow.splittable else ""),
        )
    console.print(table)

    weights = req.priorities.normalised()
    console.print("  weights: " + ", ".join(f"{k}={v:.2f}" for k, v in sorted(weights.items())))


if __name__ == "__main__":
    app()
