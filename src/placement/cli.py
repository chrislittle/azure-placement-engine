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

from placement import __version__, collect as collect_mod, knowledge
from placement.contracts import load_requirements
from placement.snapshot import store
from placement.snapshot.ingest import PayloadError, read_payload
from placement.snapshot.ingest import capabilities as capabilities_ingest
from placement.snapshot.ingest import compute_skus as compute_ingest
from placement.snapshot.ingest import regions as regions_ingest
from placement.snapshot.ingest import services as services_ingest
from placement.snapshot.model import WorldSnapshot
from placement.tenant import compute_restrictions

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


COLLECT_HELP = r"""To collect offline, without this process holding a credential:

  [cyan]SUB=<subscription-id>
  az rest --method get --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" > locations.json
  az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers?api-version=2021-04-01" > providers.json
  az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Storage/skus?api-version=2024-01-01" > storage-skus.json[/cyan]

Postgres capabilities are per region, so collect them into a directory:

  [cyan]mkdir -p pg
  for R in $(ape snapshot regions); do
    az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.DBforPostgreSQL/locations/$R/capabilities?api-version=2024-08-01" > "pg/$R.json"
  done[/cyan]

VM SKUs are also per region, and large (~4.8 MB each):

  [cyan]mkdir -p compute
  for R in $(ape snapshot regions); do
    az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location eq '$R'" > "compute/$R.json"
  done[/cyan]
"""


def _load(path: Path) -> dict:
    try:
        payload, encoding = read_payload(path)
    except PayloadError as exc:
        err.print(f"[red]{exc}[/red]")
        raise typer.Exit(1) from exc
    if encoding not in ("utf-8", "utf-8-sig"):
        console.print(f"[yellow]Note:[/yellow] read {path.name} as {encoding}, not UTF-8.")
    return payload


@app.command()
def collect(
    out: Path = typer.Option(
        Path("payloads"), "--out", "-o", help="Directory to write raw API responses into."
    ),
    subscription: str = typer.Option(
        None, "--subscription", "-s", help="Defaults to the current `az` subscription."
    ),
    only: str = typer.Option(
        None, "--only", help="Comma-separated source names, e.g. 'locations,usages'."
    ),
    workers: int = typer.Option(8, "--workers", help="Concurrent requests."),
) -> None:
    """Collect every raw payload the snapshot is built from.

    Uses whatever `az` is already logged in as. Payloads are kept raw, so a
    projection bug can be fixed and replayed without re-downloading.
    """
    try:
        sub = subscription or collect_mod.current_subscription()
    except collect_mod.CollectError as exc:
        err.print(f"[red]{exc}[/red]")
        raise typer.Exit(1) from exc

    names = [n.strip() for n in only.split(",")] if only else None
    console.print(f"Collecting into {out} ...")

    done = {"n": 0}

    def progress(result: collect_mod.Result) -> None:
        done["n"] += 1
        if not result.ok and result.source == "locations":
            err.print(f"  [red]{result.source}: {result.detail}[/red]")
        elif done["n"] % 25 == 0:
            console.print(f"  {done['n']} responses...")

    try:
        results = collect_mod.collect(sub, out, only=names, workers=workers, on_progress=progress)
    except collect_mod.CollectError as exc:
        err.print(f"[red]{exc}[/red]")
        raise typer.Exit(1) from exc

    table = Table(header_style="bold")
    table.add_column("source")
    table.add_column("ok", justify="right")
    table.add_column("failed", justify="right")
    table.add_column("size", justify="right")
    for source, (ok, failed, size) in sorted(collect_mod.summarise(results).items()):
        table.add_row(source, str(ok), str(failed) if failed else "-", f"{size / 1048576:.1f} MB")
    console.print(table)
    console.print(
        "[dim]Failures are usually a service not being offered in that region, "
        "which is a real answer rather than an error.[/dim]"
    )
    console.print(f"Next: [cyan]ape snapshot build --payloads {out}[/cyan]")


@snapshot_app.command("build")
def snapshot_build(
    payloads: Path | None = typer.Option(
        None,
        "--payloads",
        exists=True,
        file_okay=False,
        help="A directory written by `ape collect`. Infers every source beneath it.",
    ),
    locations: Path | None = typer.Option(
        None, "--locations", exists=True, dir_okay=False, help="An offline ARM locations response."
    ),
    providers: Path | None = typer.Option(
        None, "--providers", exists=True, dir_okay=False, help="An offline ARM providers response."
    ),
    storage_skus: Path | None = typer.Option(
        None,
        "--storage-skus",
        exists=True,
        dir_okay=False,
        help="An offline Microsoft.Storage/skus response.",
    ),
    postgres_dir: Path | None = typer.Option(
        None,
        "--postgres-dir",
        exists=True,
        file_okay=False,
        help="A directory of <region>.json Postgres capability responses, one per region.",
    ),
    compute_dir: Path | None = typer.Option(
        None,
        "--compute-dir",
        exists=True,
        file_okay=False,
        help="A directory of <region>.json Microsoft.Compute/skus responses, one per region.",
    ),
    usages_dir: Path | None = typer.Option(
        None,
        "--usages-dir",
        exists=True,
        file_okay=False,
        help="A directory of <region>.json Compute usages responses. vCPU quota per family.",
    ),
    tenant_out: Path | None = typer.Option(
        None,
        "--tenant-out",
        dir_okay=False,
        help="Write subscription-specific SKU restrictions here as tenant context. Never committed.",
    ),
    subscription: str | None = typer.Option(
        None, "--subscription", "-s", help="Fetch live from ARM using the ambient Azure credential."
    ),
    snapshot_version: str = typer.Option(
        None, "--version", "-v", help="Snapshot version id. Defaults to today's date."
    ),
) -> None:
    """Build or extend a snapshot.

    Slices are additive, so a snapshot can be built up over several runs. Regions
    must land before services, since resolving provider metadata needs the region
    table to join against.
    """
    if payloads:
        # Individual flags still win, so a single slice can be rebuilt in place.
        def _if(path: Path, *, is_dir: bool = False) -> Path | None:
            return path if (path.is_dir() if is_dir else path.is_file()) else None

        locations = locations or _if(payloads / "locations.json")
        providers = providers or _if(payloads / "providers.json")
        storage_skus = storage_skus or _if(payloads / "storage-skus.json")
        postgres_dir = postgres_dir or _if(payloads / "pg", is_dir=True)
        compute_dir = compute_dir or _if(payloads / "compute", is_dir=True)
        usages_dir = usages_dir or _if(payloads / "usages", is_dir=True)

    if not any((locations, providers, storage_skus, postgres_dir, compute_dir, subscription)):
        err.print("[red]Provide --subscription, or one or more offline payloads.[/red]\n")
        err.print(COLLECT_HELP)
        raise typer.Exit(2)

    version_id = snapshot_version or date.today().isoformat()

    try:
        snapshot = store.load(version_id, verify=False)
    except store.SnapshotError:
        snapshot = WorldSnapshot(version=version_id)

    if locations or subscription:
        payload = _load(locations) if locations else regions_ingest.fetch_locations(subscription)  # type: ignore[arg-type]
        snapshot = regions_ingest.ingest(snapshot, payload, subscription_id=subscription)

    if providers or subscription:
        if not snapshot.regions:
            err.print(
                "[red]Build the region slice first[/red] - service availability is stored as ARM "
                "region names, and resolving provider metadata needs the region table to join "
                "against."
            )
            raise typer.Exit(2)
        payload = _load(providers) if providers else services_ingest.fetch_providers(subscription)  # type: ignore[arg-type]
        try:
            snapshot = services_ingest.ingest(snapshot, payload, subscription_id=subscription)
        except services_ingest.IngestError as exc:
            err.print(f"[red]{exc}[/red]")
            raise typer.Exit(1) from exc

    if storage_skus or subscription:
        payload = (
            _load(storage_skus) if storage_skus else capabilities_ingest.fetch_storage_skus(subscription)  # type: ignore[arg-type]
        )
        try:
            snapshot = capabilities_ingest.ingest_storage_skus(
                snapshot, payload, subscription_id=subscription
            )
        except capabilities_ingest.IngestError as exc:
            err.print(f"[red]{exc}[/red]")
            raise typer.Exit(1) from exc

    if postgres_dir or subscription:
        if postgres_dir:
            per_region = {p.stem: _load(p) for p in sorted(postgres_dir.glob("*.json"))}
        else:
            per_region = capabilities_ingest.fetch_postgres_capabilities(
                subscription, snapshot.placement_candidates()  # type: ignore[arg-type]
            )
        try:
            snapshot = capabilities_ingest.ingest_postgres_capabilities(
                snapshot, per_region, subscription_id=subscription
            )
        except capabilities_ingest.IngestError as exc:
            err.print(f"[red]{exc}[/red]")
            raise typer.Exit(1) from exc

    if compute_dir:
        payloads = {p.stem: _load(p) for p in sorted(compute_dir.glob("*.json"))}
        try:
            snapshot = compute_ingest.ingest(snapshot, payloads, subscription_id=subscription)
            snapshot = compute_ingest.derive_capabilities(snapshot)
        except compute_ingest.IngestError as exc:
            err.print(f"[red]{exc}[/red]")
            raise typer.Exit(1) from exc

        if tenant_out:
            # Same payload, different destination: SKUs and zones are world facts,
            # restrictions describe what this subscription may deploy.
            usages = (
                {p.stem: _load(p) for p in sorted(usages_dir.glob('*.json'))} if usages_dir else {}
            )
            context = compute_restrictions.build(
                payloads, usages=usages, subscription_id=subscription
            )
            tenant_out.parent.mkdir(parents=True, exist_ok=True)
            tenant_out.write_text(
                context.model_dump_json(indent=2, exclude_none=True), encoding="utf-8"
            )
            console.print(
                f"[green]Wrote[/green] {tenant_out} "
                f"({len(context.sku_restrictions)} SKU restrictions across "
                f"{len(context.restricted_regions())} regions, "
                f"{len(context.quotas)} quota entries)"
            )

    if snapshot.regions:
        # Derived from the region table, so it costs nothing and always refreshes.
        snapshot = capabilities_ingest.ingest_region_capabilities(snapshot)

    path = store.save(snapshot)

    console.print(f"[green]Wrote[/green] {path.relative_to(store.repo_root())}")

    if snapshot.has(regions_ingest.SOURCE):
        internal = snapshot.internal_regions()
        console.print(
            f"  {len(snapshot.regions)} locations returned, "
            f"{len(snapshot.physical_regions())} physical\n"
            f"  [bold]{len(snapshot.placement_candidates())} placement candidates[/bold], "
            f"{len(snapshot.with_zones(3))} with 3+ availability zones"
        )
        if internal:
            # Surfaced every time: these look like ordinary regions in the API,
            # and eastus2euap reports more zones than any production region.
            console.print(
                f"  [yellow]{len(internal)} internal canary/staging regions excluded:[/yellow] "
                + ", ".join(sorted(r.name for r in internal))
            )

    if snapshot.has(services_ingest.SOURCE):
        regional = [s for s in snapshot.services.values() if not s.global_only]
        console.print(
            f"  [bold]{len(snapshot.services)} resource types[/bold], "
            f"{len(regional)} with a regional footprint"
        )

    if snapshot.vm_skus:
        accelerated = [s for s in snapshot.vm_skus.values() if s.is_accelerated]
        rdma = [s for s in snapshot.vm_skus.values() if s.rdma]
        console.print(
            f"  [bold]{len(snapshot.vm_skus)} VM SKUs[/bold], "
            f"{len(accelerated)} with accelerators, {len(rdma)} RDMA-capable"
        )

    if snapshot.capabilities:
        console.print(f"  [bold]{len(snapshot.capabilities)} capability facts[/bold]")
        for key in sorted(snapshot.capabilities):
            fact = snapshot.capabilities[key]
            scope = fact.resource_type.split("/")[-1] if "/" in fact.resource_type else "any service"
            console.print(
                f"    {fact.capability:24s} {len(fact.regions):3d} regions  "
                f"[dim]{scope} <- {fact.source}[/dim]"
            )

    stale = knowledge.stale_files()
    if stale:
        console.print(
            "  [yellow]curated knowledge past its review window:[/yellow] "
            + ", ".join(f.name for f in stale)
        )

    console.print(f"  digest {snapshot.digest()}")


@snapshot_app.command("list")
def snapshot_list() -> None:
    """List available snapshot versions."""
    versions = store.list_versions()
    if not versions:
        console.print("[yellow]No snapshots yet.[/yellow] Run `ape snapshot build`.")
        raise typer.Exit(0)
    for v in versions:
        console.print(v)


@snapshot_app.command("regions")
def snapshot_regions(
    snapshot_version: str = typer.Argument(None, help="Defaults to the newest snapshot."),
) -> None:
    """Print placement-candidate region names, one per line.

    Intended for shell loops that collect per-region payloads.
    """
    try:
        snapshot = store.load(snapshot_version or store.latest())
    except store.SnapshotError as exc:
        err.print(f"[red]{exc}[/red]")
        raise typer.Exit(1) from exc
    for region in sorted(r.name for r in snapshot.placement_candidates()):
        print(region)


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
