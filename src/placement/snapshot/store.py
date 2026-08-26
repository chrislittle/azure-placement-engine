"""Reading and writing pinned snapshots.

Snapshots live under `snapshots/<version>/snapshot.json` and are committed. They
are the reproducibility guarantee, not a cache — a decision record names the
version and digest it was made against, and that has to still resolve later.
"""

from __future__ import annotations

import json
from pathlib import Path

from placement.snapshot.model import WorldSnapshot

SNAPSHOT_DIR = "snapshots"
SNAPSHOT_FILE = "snapshot.json"


class SnapshotError(RuntimeError):
    pass


def repo_root() -> Path:
    """The project root, located from this module rather than the cwd so the
    CLI behaves the same wherever it's invoked from."""
    return Path(__file__).resolve().parents[3]


def snapshot_path(version: str, *, root: Path | None = None) -> Path:
    return (root or repo_root()) / SNAPSHOT_DIR / version / SNAPSHOT_FILE


def save(snapshot: WorldSnapshot, *, root: Path | None = None) -> Path:
    """Write a snapshot, with its digest recorded alongside it.

    The digest is written to a sibling file rather than into the snapshot, since
    a hash cannot cover a document that contains itself.
    """
    path = snapshot_path(snapshot.version, root=root)
    path.parent.mkdir(parents=True, exist_ok=True)

    payload = json.dumps(snapshot.canonical(), indent=2, sort_keys=True) + "\n"
    path.write_text(payload, encoding="utf-8")
    path.with_name("digest.txt").write_text(snapshot.digest() + "\n", encoding="utf-8")

    return path


def load(version: str, *, root: Path | None = None, verify: bool = True) -> WorldSnapshot:
    """Load a snapshot and, by default, verify it matches its recorded digest.

    A silently modified snapshot would make past decision records unreproducible
    while still appearing to resolve, which is the failure mode most worth
    catching.
    """
    path = snapshot_path(version, root=root)
    if not path.exists():
        available = list_versions(root=root)
        raise SnapshotError(
            f"no snapshot '{version}' at {path}."
            + (f" Available: {', '.join(available)}" if available else " No snapshots exist yet.")
        )

    snapshot = WorldSnapshot.model_validate_json(path.read_text(encoding="utf-8"))

    if verify:
        digest_file = path.with_name("digest.txt")
        if digest_file.exists():
            expected = digest_file.read_text(encoding="utf-8").strip()
            actual = snapshot.digest()
            if expected != actual:
                raise SnapshotError(
                    f"snapshot '{version}' does not match its recorded digest - it has been "
                    f"modified since it was written, or the snapshot model changed shape.\n"
                    f"  recorded: {expected}\n  actual:   {actual}\n"
                    f"Rebuild it from source payloads rather than editing it; pass verify=False "
                    f"only to inspect what changed."
                )

    return snapshot


def list_versions(*, root: Path | None = None) -> list[str]:
    base = (root or repo_root()) / SNAPSHOT_DIR
    if not base.is_dir():
        return []
    return sorted(d.name for d in base.iterdir() if (d / SNAPSHOT_FILE).exists())


def latest(*, root: Path | None = None) -> str:
    """The newest snapshot version.

    Versions are date-stamped, so lexical order is chronological order.
    """
    versions = list_versions(root=root)
    if not versions:
        raise SnapshotError("no snapshots exist yet — run `ape snapshot build` first")
    return versions[-1]
