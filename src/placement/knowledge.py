"""Curated knowledge: the facts no API returns.

Three kinds of data run through this engine and they need different handling:

* **Observed facts** — regions, SKUs, quota. From APIs, refreshed by collection,
  pinned in a snapshot.
* **Curated knowledge** — which providers support a self-service quota PUT, that
  `Microsoft.Quota` is regional-only, that spot placement scores describe a
  different capacity pool from on-demand. **No API returns any of this.**
* **Derivation rules** — the code turning the first into capability facts.

The middle kind used to live in Python docstrings and module constants, which
meant it could not be reviewed, dated, or corrected without a code change — and
would rot invisibly. It now lives in `knowledge/*.yaml`, each file carrying a
`reviewed:` date and its source, so staleness is visible and a decision record
can cite a curated rule the same way it cites an API fact.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

#: How long curated knowledge is trusted before it should be re-checked. Not a
#: hard expiry — the rule still applies, but the decision record says it is old.
DEFAULT_MAX_AGE = timedelta(days=180)


class KnowledgeError(RuntimeError):
    pass


def knowledge_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "knowledge"


class KnowledgeFile:
    """One curated file, with its provenance."""

    def __init__(self, name: str, data: dict[str, Any]):
        self.name = name
        self.data = data

    @property
    def reviewed(self) -> date | None:
        value = self.data.get("reviewed")
        if isinstance(value, date):
            return value
        if isinstance(value, str):
            try:
                return datetime.fromisoformat(value).date()
            except ValueError:
                return None
        return None

    @property
    def source(self) -> str | None:
        value = self.data.get("source")
        return value.strip() if isinstance(value, str) else None

    @property
    def confidence(self) -> str:
        return str(self.data.get("confidence") or "unknown")

    def age(self, today: date | None = None) -> timedelta | None:
        reviewed = self.reviewed
        if reviewed is None:
            return None
        return (today or date.today()) - reviewed

    def is_stale(self, today: date | None = None, max_age: timedelta = DEFAULT_MAX_AGE) -> bool:
        """Whether this file is past its review window.

        Unknown review date counts as stale: knowledge with no date cannot be
        trusted to be current, and saying so is the honest default.
        """
        age = self.age(today)
        return age is None or age > max_age

    def provenance(self, today: date | None = None) -> str:
        """One line suitable for a decision record's evidence."""
        reviewed = self.reviewed.isoformat() if self.reviewed else "undated"
        stale = " (STALE - re-check)" if self.is_stale(today) else ""
        return f"curated knowledge '{self.name}', reviewed {reviewed}, confidence {self.confidence}{stale}"

    def get(self, key: str, default: Any = None) -> Any:
        return self.data.get(key, default)

    def __getitem__(self, key: str) -> Any:
        return self.data[key]


@lru_cache(maxsize=None)
def load(name: str) -> KnowledgeFile:
    """Load one curated file by stem, e.g. 'quota-adjustment'."""
    path = knowledge_dir() / f"{name}.yaml"
    if not path.exists():
        raise KnowledgeError(f"no curated knowledge file at {path}")

    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise KnowledgeError(f"{path}: expected a mapping at the document root")
    return KnowledgeFile(name, data)


def all_files() -> list[KnowledgeFile]:
    directory = knowledge_dir()
    if not directory.is_dir():
        return []
    return [load(p.stem) for p in sorted(directory.glob("*.yaml"))]


def stale_files(today: date | None = None) -> list[KnowledgeFile]:
    """Curated files past their review window. Surfaced as decision warnings."""
    return [f for f in all_files() if f.is_stale(today)]


# --------------------------------------------------------------------------
# Typed accessors
# --------------------------------------------------------------------------


def internal_region_suffixes() -> tuple[str, ...]:
    return tuple(load("internal-regions").get("name_suffixes") or ())


def internal_geographies() -> frozenset[str]:
    return frozenset(load("internal-regions").get("geographies") or ())


def quota_adjustment(provider: str) -> dict[str, Any] | None:
    """Adjustment methods for one ARM provider namespace, if known."""
    providers = load("quota-adjustment").get("providers") or {}
    lowered = provider.lower()
    for name, entry in providers.items():
        if name.lower() == lowered:
            return {"provider": name, **entry}
    return None


def adjustment_tier(provider: str, *, zonal: bool = False) -> str:
    """The tier for a regional or zonal ask against a provider.

    Unknown providers return 'unknown' rather than guessing — an optimistic
    default here would promise self-service where a ticket is required.
    """
    entry = quota_adjustment(provider)
    if entry is None:
        return "unknown"
    return str(entry.get("zonal" if zonal else "regional") or "unknown")


def capacity_signal(name: str) -> dict[str, Any] | None:
    """One entry from the capacity-signals file, e.g. 'spot-placement-score'."""
    signals = load("capacity-signals").get("signals") or {}
    return signals.get(name)


def signal_is_usable(name: str) -> bool:
    """Whether a capacity signal may be used as an on-demand capacity indicator.

    Guards against the spot-placement-score trap: it looks like a capacity
    signal, and describes a different pool.
    """
    signal = capacity_signal(name)
    return bool(signal and signal.get("use") is True)
