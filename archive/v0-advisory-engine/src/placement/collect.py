"""Collect every raw payload the snapshot is built from, in one command.

Until this existed the pipeline was a set of hand-run shell loops — which meant
nobody could rebuild a snapshot from scratch, including the person who built the
last one. Collection has to be a command, not a runbook.

Payloads are written as a directory tree matching what `ape snapshot build`
consumes, and are deliberately kept as **raw API responses**. Projection happens
at ingest, so a projection bug can be fixed and replayed without re-downloading
~250 MB.

Authentication uses whatever `az` is already logged in as, via
`az account get-access-token`. That avoids a second credential path and an extra
dependency, and it is the same identity the offline `az rest` workflow used.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

import httpx

ARM = "https://management.azure.com"
RESOURCE = f"{ARM}/"


class CollectError(RuntimeError):
    pass


def _az() -> str:
    """Resolve the Azure CLI executable.

    On Windows `az` is a `.cmd` shim, so a bare "az" in an argv list is not
    findable by CreateProcess. `shutil.which` applies PATHEXT and returns the
    real path.
    """
    found = shutil.which("az")
    if not found:
        raise CollectError("the Azure CLI (`az`) is not on PATH")
    return found


def _run_az(args: list[str], *, timeout: int) -> str:
    try:
        result = subprocess.run(
            [_az(), *args], capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as exc:
        raise CollectError(f"`az {' '.join(args)}` timed out") from exc

    if result.returncode != 0:
        raise CollectError(f"`az {' '.join(args)}` failed: {result.stderr.strip()}")
    return result.stdout.strip()


def access_token() -> str:
    """Borrow the Azure CLI's token rather than opening a second auth path."""
    token = _run_az(
        ["account", "get-access-token", "--resource", ARM, "--query", "accessToken", "-o", "tsv"],
        timeout=120,
    )
    if not token:
        raise CollectError("no access token returned - is `az login` done?")
    return token


def current_subscription() -> str:
    subscription = _run_az(["account", "show", "--query", "id", "-o", "tsv"], timeout=60)
    if not subscription:
        raise CollectError("could not determine the current subscription - run `az login`")
    return subscription


# --------------------------------------------------------------------------
# Source definitions
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Source:
    """One payload to collect.

    `per_region` sources issue one call per placement-candidate region and write
    `<name>/<region>.json`; the rest write `<name>.json`.
    """

    name: str
    path: str
    api_version: str
    per_region: bool = False
    params: dict[str, str] | None = None
    filter_by_location: bool = False

    def target(self, root: Path, region: str | None = None) -> Path:
        if self.per_region:
            return root / self.name / f"{region}.json"
        return root / f"{self.name}.json"


SOURCES: tuple[Source, ...] = (
    Source("locations", "/subscriptions/{sub}/locations", "2022-12-01"),
    Source("providers", "/subscriptions/{sub}/providers", "2021-04-01"),
    Source(
        "storage-skus",
        "/subscriptions/{sub}/providers/Microsoft.Storage/skus",
        "2024-01-01",
    ),
    Source(
        "pg",
        "/subscriptions/{sub}/providers/Microsoft.DBforPostgreSQL/locations/{region}/capabilities",
        "2024-08-01",
        per_region=True,
    ),
    Source(
        "compute",
        "/subscriptions/{sub}/providers/Microsoft.Compute/skus",
        "2021-07-01",
        per_region=True,
        filter_by_location=True,
    ),
    Source(
        "usages",
        "/subscriptions/{sub}/providers/Microsoft.Compute/locations/{region}/usages",
        "2021-07-01",
        per_region=True,
    ),
)

#: Collected before anything per-region, because the region list comes from it.
BOOTSTRAP = "locations"


# --------------------------------------------------------------------------
# Collection
# --------------------------------------------------------------------------


@dataclass
class Result:
    source: str
    region: str | None
    ok: bool
    detail: str = ""
    bytes_written: int = 0


def _fetch(
    client: httpx.Client, source: Source, subscription: str, region: str | None
) -> dict[str, Any]:
    url = ARM + source.path.format(sub=subscription, region=region or "")
    params: dict[str, str] = {"api-version": source.api_version, **(source.params or {})}
    if source.filter_by_location and region:
        params["$filter"] = f"location eq '{region}'"

    response = client.get(url, params=params)
    response.raise_for_status()
    return response.json()


def _write(path: Path, payload: dict[str, Any]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(payload)
    path.write_text(text, encoding="utf-8")
    return len(text)


def collect_locations(client: httpx.Client, subscription: str, out: Path) -> list[str]:
    """Fetch the region list first; everything per-region depends on it."""
    source = next(s for s in SOURCES if s.name == BOOTSTRAP)
    payload = _fetch(client, source, subscription, None)
    _write(source.target(out), payload)

    from placement.snapshot.ingest.regions import parse_locations

    return sorted(r.name for r in parse_locations(payload) if r.is_placement_candidate)


def collect(
    subscription: str,
    out: Path,
    *,
    only: Iterable[str] | None = None,
    workers: int = 8,
    on_progress: Callable[[Result], None] | None = None,
) -> list[Result]:
    """Collect every payload into `out`.

    Individual failures are recorded and returned rather than aborting the run:
    Postgres is not offered in every region, and losing 50 good regions because
    the 51st has no endpoint would be absurd.
    """
    wanted = set(only) if only else {s.name for s in SOURCES}
    results: list[Result] = []
    headers = {"Authorization": f"Bearer {access_token()}"}

    def record(result: Result) -> None:
        results.append(result)
        if on_progress:
            on_progress(result)

    with httpx.Client(headers=headers, timeout=300.0) as client:
        regions: list[str] = []

        if BOOTSTRAP in wanted or any(s.per_region and s.name in wanted for s in SOURCES):
            try:
                regions = collect_locations(client, subscription, out)
                record(Result(BOOTSTRAP, None, True, f"{len(regions)} placement candidates"))
            except Exception as exc:  # noqa: BLE001 - reported, not swallowed
                record(Result(BOOTSTRAP, None, False, str(exc)))
                return results  # nothing per-region can proceed

        jobs: list[tuple[Source, str | None]] = []
        for source in SOURCES:
            if source.name not in wanted or source.name == BOOTSTRAP:
                continue
            if source.per_region:
                jobs.extend((source, region) for region in regions)
            else:
                jobs.append((source, None))

        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(_fetch, client, source, subscription, region): (source, region)
                for source, region in jobs
            }
            for future in as_completed(futures):
                source, region = futures[future]
                try:
                    payload = future.result()
                except httpx.HTTPStatusError as exc:
                    # A 404 usually means the service is not offered in that
                    # region. That is a real answer, and not an error.
                    record(Result(source.name, region, False, f"HTTP {exc.response.status_code}"))
                    continue
                except Exception as exc:  # noqa: BLE001
                    record(Result(source.name, region, False, str(exc)))
                    continue

                written = _write(source.target(out, region), payload)
                record(Result(source.name, region, True, bytes_written=written))

    return results


def summarise(results: list[Result]) -> dict[str, tuple[int, int, int]]:
    """Per source: successes, failures, bytes."""
    summary: dict[str, tuple[int, int, int]] = {}
    for result in results:
        ok, failed, size = summary.get(result.source, (0, 0, 0))
        summary[result.source] = (
            ok + (1 if result.ok else 0),
            failed + (0 if result.ok else 1),
            size + result.bytes_written,
        )
    return summary
