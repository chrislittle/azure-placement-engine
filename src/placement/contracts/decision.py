"""The output contract: an auditable record of what was chosen and why.

The analogue of the thesis's *resolution record* — "on every release the platform
writes back what it chose ... as a queryable record". Authored by the engine,
never hand-edited. Three properties are non-negotiable:

* **Reproducible** — it pins the snapshot version, so re-running the same inputs
  against the same snapshot must produce the same record.
* **Evidenced** — every hard elimination and every subscore cites the facts that
  produced it, with the source and its as-of date.
* **Complete on the negative side** — it records why regions *lost*, not only why
  one won. "Why not Region X" is the question that actually gets asked.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

API_VERSION = "placement/v0"


class Record(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --------------------------------------------------------------------------
# Evidence
# --------------------------------------------------------------------------


class Evidence(Record):
    """A single cited fact. Anything asserted by the engine traces back to one of these."""

    source: str = Field(description="Fact source id, e.g. 'products-by-region', 'compute-skus', 'retail-prices'.")
    as_of: datetime = Field(description="When the underlying fact was observed, not when this record was written.")
    ref: str | None = Field(default=None, description="Locator within the source — API path, row key, or document anchor.")
    detail: str | None = None
    confidence: float = Field(
        default=1.0,
        ge=0.0,
        le=1.0,
        description="1.0 for deterministic facts (a service is or is not in a region). Below 1.0 for "
        "inferred signals such as capacity, where no authoritative API exists.",
    )


# --------------------------------------------------------------------------
# Eliminations
# --------------------------------------------------------------------------


class EliminationStage(str, Enum):
    RESIDENCY = "residency"
    COMPLIANCE = "compliance"
    SERVICE_AVAILABILITY = "service-availability"
    FEATURE_AVAILABILITY = "feature-availability"
    CAPACITY = "capacity"
    LATENCY_BUDGET = "latency-budget"
    RESILIENCY = "resiliency"
    AFFINITY = "affinity"
    POLICY = "landing-zone-policy"


class Elimination(Record):
    """Why a region (or region pair) never made it to scoring."""

    region: str
    stage: EliminationStage
    rule: str = Field(description="The specific rule that fired, e.g. 'residency.jurisdictions'.")
    component: str | None = Field(default=None, description="Component that triggered it, when attributable.")
    reason: str
    evidence: list[Evidence] = Field(default_factory=list)


# --------------------------------------------------------------------------
# Candidates
# --------------------------------------------------------------------------


class Subscore(Record):
    """One scored dimension for one candidate."""

    value: float = Field(ge=0.0, le=1.0, description="Normalised 0-1, higher is better.")
    weight: float = Field(ge=0.0, le=1.0)
    rationale: str
    evidence: list[Evidence] = Field(default_factory=list)

    @property
    def contribution(self) -> float:
        return self.value * self.weight


class RegionRole(str, Enum):
    PRIMARY = "primary"
    SECONDARY = "secondary"
    TERTIARY = "tertiary"
    WITNESS = "witness"


class Placement(Record):
    """One region within a candidate topology, plus what lands there."""

    region: str
    role: RegionRole
    zones: list[str] = Field(default_factory=list)
    components: list[str] = Field(default_factory=list, description="Component names placed in this region.")


class Risk(Record):
    """Something true about the recommendation that the reader must know.

    Distinct from an elimination: the candidate survived, but not cleanly. A
    thin capacity signal or a preview-stage feature belongs here.
    """

    severity: str = Field(description="'low' | 'medium' | 'high'")
    category: str = Field(description="e.g. 'capacity', 'preview-feature', 'stale-data', 'single-point'.")
    detail: str
    mitigation: str | None = None
    evidence: list[Evidence] = Field(default_factory=list)


class Candidate(Record):
    """A complete, viable topology — never a bare region.

    Resiliency requirements make the unit of answer a region *set*: a workload
    asking for active-passive with a paired secondary has no meaningful
    single-region answer.
    """

    rank: int
    topology: str = Field(description="Echo of the requested resiliency topology.")
    placements: list[Placement]
    score: float = Field(ge=0.0, le=1.0)
    subscores: dict[str, Subscore]
    risks: list[Risk] = Field(default_factory=list)
    estimated_cost_monthly_usd: float | None = None
    summary: str | None = Field(default=None, description="One-line human-readable rationale.")

    @property
    def regions(self) -> list[str]:
        return [p.region for p in self.placements]


# --------------------------------------------------------------------------
# Provenance
# --------------------------------------------------------------------------


class SnapshotRef(Record):
    """Pins the world data a decision was made against.

    Without this, a decision is unreproducible and a re-run six months later is
    indistinguishable from a bug.
    """

    version: str = Field(description="Snapshot version id, e.g. '2026-08-01'.")
    digest: str | None = Field(default=None, description="Content hash of the snapshot as loaded.")
    sources: dict[str, datetime] = Field(
        default_factory=dict, description="Per-source as-of dates, so partial staleness is visible."
    )


class TenantRef(Record):
    """Pins the customer-specific context used, without embedding identifiers by default."""

    mode: str = Field(description="'offline' | 'live' | 'none'")
    collected_at: datetime | None = None
    subscription_id: str | None = None
    digest: str | None = None


# --------------------------------------------------------------------------
# Root
# --------------------------------------------------------------------------


class DecisionRecord(Record):
    api_version: str = Field(default=API_VERSION, alias="apiVersion")
    kind: str = "DecisionRecord"
    workload: str
    generated_at: datetime
    engine_version: str

    snapshot: SnapshotRef
    tenant: TenantRef

    requirements_digest: str = Field(description="Hash of the normalized requirements that produced this record.")

    recommended: Candidate | None = Field(
        default=None, description="None when every region was eliminated — a legitimate and important answer."
    )
    alternatives: list[Candidate] = Field(default_factory=list)
    eliminations: list[Elimination] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)

    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    @property
    def feasible(self) -> bool:
        return self.recommended is not None

    def eliminations_for(self, region: str) -> list[Elimination]:
        """Answers the question customers actually ask: 'why not this region?'"""
        return [e for e in self.eliminations if e.region == region]
