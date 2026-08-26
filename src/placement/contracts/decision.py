"""The output contract: an auditable record of what was chosen and why.

The analogue of the thesis's *resolution record* — authored by the engine, never
hand-edited. Four properties are non-negotiable:

* **Reproducible** — pins the snapshot version, so the same inputs against the
  same snapshot produce the same record.
* **Evidenced** — every elimination and every subscore cites the facts behind it,
  with source and as-of date.
* **Complete on the negative side** — records why regions *lost*. "Why not region
  X" is the question that actually gets asked.
* **Honest about provenance** — hard filters trace to CAF's region-selection
  criteria; the ranking weights are ours. The record distinguishes the two rather
  than implying Microsoft prescribed a scoring model, which it does not.
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
    """A single cited fact. Everything the engine asserts traces back to one."""

    source: str = Field(
        description="Fact source id, e.g. 'arm-locations', 'compute-skus', 'retail-prices', "
        "'postgres-capabilities'."
    )
    as_of: datetime = Field(description="When the fact was observed, not when this record was written.")
    ref: str | None = Field(default=None, description="Locator within the source — API path or row key.")
    detail: str | None = None
    confidence: float = Field(
        default=1.0,
        ge=0.0,
        le=1.0,
        description=(
            "1.0 for deterministic facts — a service is or is not in a region, a SKU is or is not "
            "restricted for this subscription. Below 1.0 for inferred signals such as capacity "
            "headroom, where no authoritative API exists."
        ),
    )


# --------------------------------------------------------------------------
# Eliminations
# --------------------------------------------------------------------------


class EliminationStage(str, Enum):
    """Hard-filter stages, in evaluation order. The first five map to CAF's
    'Select Azure regions' criteria."""

    RESIDENCY = "residency"                        # CAF: data residency and compliance
    COMPLIANCE = "compliance"                      # CAF: data residency and compliance
    SERVICE_AVAILABILITY = "service-availability"  # CAF: check service availability
    CAPABILITY_AVAILABILITY = "capability-availability"
    CAPACITY = "capacity"                          # CAF: plan for capacity constraints
    LATENCY_BUDGET = "latency-budget"
    RESILIENCY = "resiliency"
    FLOW_CONSTRAINT = "flow-constraint"
    POLICY = "landing-zone-policy"


class Elimination(Record):
    """Why a region never reached scoring."""

    region: str
    stage: EliminationStage
    rule: str = Field(description="The rule that fired, e.g. 'residency.jurisdictions'.")
    component: str | None = None
    flow: str | None = None
    reason: str
    evidence: list[Evidence] = Field(default_factory=list)


# --------------------------------------------------------------------------
# Candidates
# --------------------------------------------------------------------------


class Subscore(Record):
    """One scored dimension for one candidate. Weights come from the caller's
    `priorities` block — the reader can disagree with the weighting instead of
    disagreeing with the tool."""

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
    """The region-centric view: what lands where."""

    region: str
    role: RegionRole
    zones: list[str] = Field(default_factory=list)
    components: list[str] = Field(default_factory=list)


class ComponentDecision(Record):
    """The component-centric view, including the topology the engine *derived*.

    Topology is an output. A component inherits the strictest recovery targets
    among the flows it serves, so a reporting store sitting only on a 24-hour
    flow is not made to pay for active-passive.
    """

    component: str
    topology: str = Field(description="Derived topology, e.g. 'zonal', 'active-passive'.")
    regions: list[str]
    driving_flow: str | None = Field(
        default=None, description="The flow whose RTO/RPO set this topology."
    )
    derived_rto: str | None = None
    derived_rpo: str | None = None
    rationale: str
    overridden: bool = Field(
        default=False, description="True when the requirements pinned this topology rather than the engine."
    )


class FlowOutcome(Record):
    """How one WAF flow fares under a candidate.

    A flow split across regions is not necessarily wrong — but it must be
    visible, priced, and attributed to the flow's criticality.
    """

    flow: str
    criticality: str
    regions: list[str] = Field(description="Regions this flow's path spans.")
    split: bool = Field(description="True when the path crosses a region boundary.")
    meets_rto: bool | None = None
    meets_rpo: bool | None = None
    added_latency_ms: float | None = Field(
        default=None, description="Extra round-trip introduced by splitting the path."
    )
    egress_cost_monthly_usd: float | None = Field(
        default=None, description="Cross-region data transfer cost implied by the split."
    )
    notes: str | None = None


class Risk(Record):
    """Something true about a surviving recommendation that the reader must know.

    Distinct from an elimination: the candidate survived, but not cleanly. A thin
    capacity signal, a preview-stage capability, or a capability the snapshot
    could not confirm belongs here — unknown is never silently treated as
    available.
    """

    severity: str = Field(description="'low' | 'medium' | 'high'")
    category: str = Field(
        description="e.g. 'capacity', 'preview-capability', 'unconfirmed-capability', 'stale-data', "
        "'region-maturity', 'flow-split'."
    )
    detail: str
    mitigation: str | None = None
    evidence: list[Evidence] = Field(default_factory=list)


class Candidate(Record):
    """A complete, viable topology — never a bare region.

    Recovery requirements make the unit of answer a region *set*: a workload with
    a five-minute-RTO flow has no meaningful single-region answer.
    """

    rank: int
    placements: list[Placement]
    components: list[ComponentDecision]
    flows: list[FlowOutcome] = Field(default_factory=list)
    score: float = Field(ge=0.0, le=1.0)
    subscores: dict[str, Subscore]
    risks: list[Risk] = Field(default_factory=list)
    estimated_cost_monthly_usd: float | None = None
    summary: str | None = Field(default=None, description="One-line human-readable rationale.")

    @property
    def regions(self) -> list[str]:
        return [p.region for p in self.placements]


# --------------------------------------------------------------------------
# Relaxations — advice instead of an error
# --------------------------------------------------------------------------


class Relaxation(Record):
    """A specific, priced way to unstick an over-constrained problem.

    This is what flow criticality buys. Rather than returning 'infeasible', the
    engine can say which low-criticality flow to split, or which capability to
    drop, and what that opens up.
    """

    target: str = Field(description="The flow, component, or constraint to relax.")
    kind: str = Field(
        description="'split-flow' | 'relax-capability' | 'widen-residency' | 'drop-optional-component' "
        "| 'raise-quota' | 'relax-latency-budget'"
    )
    detail: str
    unlocks: list[str] = Field(default_factory=list, description="Regions or topologies this enables.")
    gives_up: str | None = Field(default=None, description="What the relaxation costs.")
    criticality_of_target: str | None = Field(
        default=None, description="Why this is a defensible thing to relax first."
    )


# --------------------------------------------------------------------------
# Provenance
# --------------------------------------------------------------------------


class SnapshotRef(Record):
    """Pins the world data a decision was made against. Without it, a decision is
    unreproducible and a re-run six months later is indistinguishable from a bug."""

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
    requirements_digest: str = Field(description="Hash of the requirements that produced this record.")

    recommended: Candidate | None = Field(
        default=None,
        description="None when every region was eliminated — a legitimate and important answer, "
        "and the case where `relaxations` earns its keep.",
    )
    alternatives: list[Candidate] = Field(default_factory=list)
    eliminations: list[Elimination] = Field(default_factory=list)
    relaxations: list[Relaxation] = Field(default_factory=list)
    warnings: list[str] = Field(
        default_factory=list,
        description="Anything the engine could not honour, e.g. a declared horizon it did not model. "
        "Never silently ignore a stated requirement.",
    )

    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    @property
    def feasible(self) -> bool:
        return self.recommended is not None

    def eliminations_for(self, region: str) -> list[Elimination]:
        """Answers the question customers actually ask: 'why not this region?'"""
        return [e for e in self.eliminations if e.region == region]
