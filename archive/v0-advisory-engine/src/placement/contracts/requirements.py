"""The input contract: a normalized statement of what a workload needs.

Structured around **WAF flows** rather than a flat component list. A flow is a
defined Well-Architected concept — *"the sequence of actions that performs a
specific function... the movement of data and the running of processes between
components of the workload"* — and WAF already asks customers to inventory them,
rate their criticality, and attach RTO/RPO to each (RE:02, CO:09).

That single choice does most of the work here:

* **Co-location is derived, not declared.** A latency-sensitive, high-criticality
  flow wants its components together; the engine works that out.
* **Per-component topology is derived.** A component inherits the strictest
  RTO/RPO of the flows it serves, so a reporting store that only sits on a
  24-hour flow doesn't pay for active-passive.
* **Residency inherits down a flow path.** A flow carrying regulated data
  imposes its envelope on every component it touches.
* **Over-constrained problems produce advice, not errors.** Criticality tells the
  engine what to sacrifice first.

Where no flows are declared, `effective_flows()` synthesises a single implicit
flow spanning every component, so the fallback behaviour is sane.

Deliberately a *subset ancestor* of the `outcome.yaml` grammar in the Azure Next
thesis: where that file says `hub: eu`, this says `residency.jurisdictions: [eu]`
and the engine resolves the concrete regions.
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict, Field, model_validator

API_VERSION = "placement/v0"


class Strict(BaseModel):
    """Reject unknown keys. A typo in a residency rule must fail loudly rather
    than silently widening the candidate set."""

    model_config = ConfigDict(extra="forbid", frozen=True)


# --------------------------------------------------------------------------
# Enumerations
# --------------------------------------------------------------------------


class Cloud(str, Enum):
    PUBLIC = "public"
    US_GOV = "usgov"
    CHINA = "china"


class CapabilityClass(str, Enum):
    """Coarse compute classes, used as a pre-filter over real VM families.
    Narrower needs go in `sku_hints`, which shrinks the qualifying pool."""

    GENERAL = "general"
    COMPUTE = "compute-intensive"
    MEMORY = "memory-heavy"
    STORAGE = "storage-optimised"
    CONFIDENTIAL = "confidential"
    ACCELERATOR = "accelerator"


class Archetype(str, Enum):
    """Optional 'help me choose' path.

    The primary way to name a component is its ARM resource type — that's what
    people already know and it's unambiguous. An archetype is only for the case
    where the service genuinely hasn't been chosen yet and the engine should
    pick (e.g. Postgres Flexible Server vs Azure SQL DB vs SQL MI).
    """

    CONTAINER_PLATFORM = "container-platform"
    SERVERLESS_COMPUTE = "serverless-compute"
    VIRTUAL_MACHINES = "virtual-machines"
    BATCH_COMPUTE = "batch-compute"
    AI_TRAINING = "ai-training"
    AI_INFERENCE = "ai-inference"
    RELATIONAL_DB = "relational-transactional"
    DOCUMENT_DB = "document-store"
    CACHE = "cache"
    OBJECT_STORAGE = "object-storage"
    EVENT_STREAM = "event-stream"
    MESSAGE_QUEUE = "message-queue"
    SEARCH = "search"
    ANALYTICS = "analytics"
    CDN_EDGE = "cdn-edge"
    SECRETS = "secrets"


class DataClassification(str, Enum):
    PUBLIC = "public"
    INTERNAL = "internal"
    CONFIDENTIAL = "confidential"
    RESTRICTED = "restricted"


class FlowType(str, Enum):
    """WAF distinguishes the two; they score differently.

    A user flow's latency is measured from a demand origin; a system flow's is
    measured between components.
    """

    USER = "user"
    SYSTEM = "system"


class Criticality(str, Enum):
    """WAF RE:02 flow criticality rating. Drives what the engine sacrifices when
    the constraints can't all be met."""

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class Sensitivity(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class Topology(str, Enum):
    """Normally an engine *output*, derived from flow RTO/RPO.

    Accepted as an input only as an override, for cases where a customer has a
    standing mandate rather than a requirement.
    """

    SINGLE = "single"
    ZONAL = "zonal"
    ACTIVE_PASSIVE = "active-passive"
    ACTIVE_ACTIVE = "active-active"


# --------------------------------------------------------------------------
# Constraint envelope
# --------------------------------------------------------------------------


class Residency(Strict):
    """Hard containment rules. Declarable at three levels — workload (the
    default), flow (inherited by every component on the path), and component
    (an explicit override). The engine resolves a component's effective envelope
    as the intersection of all three."""

    cloud: Cloud = Cloud.PUBLIC
    jurisdictions: list[str] = Field(
        default_factory=list,
        description="Jurisdiction codes the data must stay inside, e.g. ['eu'], ['de'].",
    )
    boundaries: list[str] = Field(
        default_factory=list, description="Named regulatory boundaries, e.g. ['eu-data-boundary']."
    )
    allowed_regions: list[str] = Field(
        default_factory=list,
        description=(
            "Explicit whitelist — nothing outside it is ever a candidate. Usually populated from "
            "the landing zone's allowedLocations policy assignment rather than by hand."
        ),
    )
    excluded_regions: list[str] = Field(default_factory=list)


class DemandSource(Strict):
    """Where the users are. CAF's second region-selection step is proximity to
    users; this is the input for it."""

    geography: str = Field(description="Demand origin key, e.g. 'eu-west', 'us-east'.")
    share: float = Field(ge=0.0, le=1.0, description="Fraction of total demand from this origin.")
    latency_p99_ms: int | None = Field(
        default=None, description="Target p99 round-trip from this origin. Scored, not enforced."
    )
    latency_budget_hard_ms: int | None = Field(
        default=None, description="Absolute ceiling. Regions above it are eliminated."
    )


# --------------------------------------------------------------------------
# Components
# --------------------------------------------------------------------------


class CapacityRequest(Strict):
    """Declared compute demand.

    Deliberately absent: any notion of reservation or savings-plan lock-in.
    Azure savings plans apply across regions and families, so commitment is
    effectively placement-neutral and doesn't belong in a placement decision.
    """

    capability_class: CapabilityClass = CapabilityClass.GENERAL
    sku_hints: list[str] = Field(
        default_factory=list,
        description=(
            "Concrete VM SKUs, e.g. ['Standard_ND96isr_H100_v5']. Narrowing here shrinks the "
            "qualifying pool and lowers capacity confidence."
        ),
    )
    vcpu: int | None = None
    memory_gb: int | None = None
    instances: int | None = None
    accelerators: int | None = None
    interconnect: str | None = Field(
        default=None, description="Accelerator fabric requirement, e.g. 'infiniband'."
    )
    growth: str | None = Field(
        default=None,
        description="Expected growth over the workload's horizon, e.g. '3x/12mo'. Scored against "
        "projected demand, not just current.",
    )
    spot_tolerant: bool = False


class Component(Strict):
    """One deployable piece of the workload.

    Named by ARM resource type wherever the service is already chosen — that is
    the primary path. `archetype` is the optional alternative for when it isn't.
    """

    name: str
    service: str | None = Field(
        default=None,
        description="ARM resource type, e.g. 'Microsoft.DBforPostgreSQL/flexibleServers'. Preferred.",
    )
    archetype: Archetype | None = Field(
        default=None, description="Used only when the concrete service hasn't been chosen yet."
    )
    capabilities: list[str] = Field(
        default_factory=list,
        description=(
            "Per-region service capabilities this component needs — the level below 'is the "
            "service in the region', e.g. ['zone-redundant-ha', 'customer-managed-key']. Named "
            "after Azure's own `locations/{location}/capabilities` APIs, which is where most of "
            "these facts come from."
        ),
    )
    classification: DataClassification = DataClassification.INTERNAL
    capacity: CapacityRequest | None = None
    residency: Residency | None = Field(
        default=None, description="Override. Intersected with the workload and flow envelopes."
    )
    topology: Topology | None = Field(
        default=None,
        description="Override for a standing mandate. Normally the engine derives this from the "
        "RTO/RPO of the flows this component serves.",
    )
    required: bool = Field(
        default=True, description="False marks the component as droppable if it alone blocks a region."
    )

    @model_validator(mode="after")
    def _named_somehow(self) -> Component:
        if self.service is None and self.archetype is None:
            raise ValueError(
                f"component '{self.name}': set `service` (ARM resource type) or, if the service "
                f"isn't chosen yet, `archetype`"
            )
        return self


# --------------------------------------------------------------------------
# Flows — the structural core
# --------------------------------------------------------------------------


class Flow(Strict):
    """A WAF flow: a sequence of actions across components that performs a
    function, carrying its own criticality, recovery targets, and constraints.

    This is where resiliency and latency requirements actually live, because
    that is where the business states them — a checkout flow and a nightly
    reporting flow in the same workload have genuinely different RTOs.
    """

    name: str
    type: FlowType = FlowType.SYSTEM
    criticality: Criticality = Criticality.MEDIUM
    path: list[str] = Field(
        min_length=1, description="Component names, in order. A user flow starts at its entry point."
    )
    latency_sensitivity: Sensitivity = Sensitivity.MEDIUM
    rto: str | None = Field(default=None, description="Recovery time objective, e.g. '5m', '24h'.")
    rpo: str | None = Field(default=None, description="Recovery point objective, e.g. '1m', '24h'.")
    compliance: list[str] = Field(
        default_factory=list,
        description="Compliance scope carried by this flow, e.g. ['pci-dss']. Inherited by its path.",
    )
    residency: Residency | None = Field(
        default=None, description="Residency envelope carried by this flow. Inherited by its path."
    )
    classification: DataClassification | None = None
    origins: list[str] = Field(
        default_factory=list,
        description="For user flows: which demand origins drive it, by `demand[].geography`. "
        "Empty means all of them.",
    )
    data_volume_gb_month: float | None = Field(
        default=None,
        description="Approximate data moved along this path per month. Used to price the egress "
        "penalty when a flow has to be split across regions.",
    )
    splittable: bool = Field(
        default=True,
        description="False forbids the engine from placing this flow's components in different "
        "regions, whatever the latency maths says.",
    )


# --------------------------------------------------------------------------
# Resiliency constraints, landing zone, weighting
# --------------------------------------------------------------------------


class ResiliencyConstraints(Strict):
    """Constraints on *how* the engine may satisfy flow recovery targets.

    Note this holds no topology field — topology is derived per component from
    flow RTO/RPO. What lives here is the boundary the engine must work inside.
    """

    min_availability_zones: int = Field(default=0, ge=0, le=3)
    require_paired_region: bool = Field(
        default=False,
        description=(
            "Force the secondary to be the Azure-designated paired region. Off by default: CAF now "
            "states that favouring paired regions is 'no longer mandatory' and that regions should "
            "be chosen on latency, compliance and resiliency needs. Set this only for a service "
            "that genuinely depends on pairing, or a standing customer mandate."
        ),
    )
    max_regions: int | None = Field(
        default=None, description="Cap on total regions, e.g. to bound operational surface."
    )


class LandingZone(Strict):
    """The customer's existing estate. CAF's landing-zone region guidance treats
    adding a region as real work — a new hub or vWAN hub in the Connectivity
    subscription, gateways, DNS forwarders, identity expansion, workspace
    placement. That cost is scored, not assumed away."""

    context: str | None = Field(
        default=None, description="Path to a tenant context JSON, or 'live' to collect from ARM."
    )
    existing_regions: list[str] = Field(default_factory=list)
    network_anchors: list[str] = Field(
        default_factory=list,
        description="Fixed attachment points, e.g. ['expressroute:amsterdam', 'vwan-hub:westeurope'].",
    )
    subscription_id: str | None = None


class Priorities(Strict):
    """Weights for ranking the regions that survive the hard filters.

    Each maps to a criterion CAF names in 'Select Azure regions'. CAF prescribes
    the criteria and their sequence but not a ranking method, so the weighting
    is ours — and the decision record says so rather than implying Microsoft
    prescribed it.

    Sustainability is deliberately absent: it appears nowhere in CAF's region
    guidance.
    """

    latency: float = Field(default=0.30, ge=0.0, description="CAF: choose regions close to your users.")
    cost: float = Field(default=0.25, ge=0.0, description="CAF: compare pricing.")
    capacity_confidence: float = Field(
        default=0.20,
        ge=0.0,
        description="CAF: plan for capacity constraints. Proven restrictions eliminate a region "
        "outright; this weight covers the inferred signals.",
    )
    region_category: float = Field(
        default=0.10,
        ge=0.0,
        description="Azure's own Recommended vs Alternate classification — broadest service "
        "coverage and AZ support.",
    )
    landing_zone_expansion: float = Field(
        default=0.15, ge=0.0, description="Cost of standing up platform footprint in a new region."
    )

    @model_validator(mode="after")
    def _nonzero(self) -> Priorities:
        if self.weights_total() <= 0:
            raise ValueError("priorities: at least one weight must be greater than zero")
        return self

    def weights_total(self) -> float:
        return sum(self.model_dump().values())

    def normalised(self) -> dict[str, float]:
        total = self.weights_total()
        return {k: v / total for k, v in self.model_dump().items()}


# --------------------------------------------------------------------------
# Root
# --------------------------------------------------------------------------

IMPLICIT_FLOW_NAME = "implicit"


class Requirements(Strict):
    api_version: str = Field(default=API_VERSION, alias="apiVersion")
    workload: str
    owner: str | None = None
    description: str | None = None

    residency: Residency = Field(default_factory=Residency)
    compliance: list[str] = Field(
        default_factory=list,
        description="Workload-wide compliance scope, e.g. ['iso-27001']. Flows may add their own.",
    )
    demand: list[DemandSource] = Field(default_factory=list)
    components: list[Component] = Field(min_length=1)
    flows: list[Flow] = Field(
        default_factory=list,
        description="WAF flow inventory. If empty, one implicit flow spanning every component is "
        "assumed — see `effective_flows()`.",
    )
    resiliency: ResiliencyConstraints = Field(default_factory=ResiliencyConstraints)
    horizon: str | None = Field(
        default=None,
        description="Planning window for capacity and cost, e.g. '24mo'. Without it the decision "
        "is point-in-time.",
    )
    landing_zone: LandingZone = Field(default_factory=LandingZone, alias="landingZone")
    priorities: Priorities = Field(default_factory=Priorities)

    model_config = ConfigDict(extra="forbid", frozen=True, populate_by_name=True)

    @model_validator(mode="after")
    def _coherent(self) -> Requirements:
        if self.api_version != API_VERSION:
            raise ValueError(f"unsupported apiVersion {self.api_version!r}; expected {API_VERSION!r}")

        names = [c.name for c in self.components]
        if len(names) != len(set(names)):
            raise ValueError("component names must be unique")
        known = set(names)

        flow_names = [f.name for f in self.flows]
        if len(flow_names) != len(set(flow_names)):
            raise ValueError("flow names must be unique")

        for flow in self.flows:
            unknown = sorted(set(flow.path) - known)
            if unknown:
                raise ValueError(f"flow '{flow.name}' references unknown components: {unknown}")

        if self.demand:
            total = sum(d.share for d in self.demand)
            if abs(total - 1.0) > 0.01:
                raise ValueError(f"demand shares must sum to 1.0 (got {total:.3f})")

            origins = {d.geography for d in self.demand}
            for flow in self.flows:
                unknown_origins = sorted(set(flow.origins) - origins)
                if unknown_origins:
                    raise ValueError(
                        f"flow '{flow.name}' references unknown demand origins: {unknown_origins}"
                    )

        orphans = sorted(known - {c for f in self.flows for c in f.path}) if self.flows else []
        if orphans:
            raise ValueError(
                f"components appear in no flow: {orphans}. Add them to a flow, or remove them — "
                f"a component with no flow has no stated purpose to place it against."
            )

        return self

    def component(self, name: str) -> Component:
        for c in self.components:
            if c.name == name:
                return c
        raise KeyError(name)

    def effective_flows(self) -> list[Flow]:
        """Declared flows, or a single implicit flow over every component.

        The fallback keeps the engine usable for a customer with no flow
        inventory: behaviour degrades to treating the workload as one unit,
        which is roughly what a co-location-rules model would have done anyway.
        """
        if self.flows:
            return list(self.flows)
        return [
            Flow(
                name=IMPLICIT_FLOW_NAME,
                type=FlowType.SYSTEM,
                criticality=Criticality.HIGH,
                path=[c.name for c in self.components],
                latency_sensitivity=Sensitivity.MEDIUM,
            )
        ]

    def flows_for(self, component: str) -> list[Flow]:
        """Every flow a component participates in. The engine derives that
        component's topology from the strictest RTO/RPO among these."""
        return [f for f in self.effective_flows() if component in f.path]
