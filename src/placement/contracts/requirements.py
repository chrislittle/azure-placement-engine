"""The input contract: a normalized statement of what a workload needs.

Deliberately a *subset ancestor* of the `outcome.yaml` grammar in the Azure Next
thesis. Where that file says `hub: eu` and lets the platform decide everything
below it, this file says `residency.jurisdictions: [eu]` and the engine decides
the concrete regions. Same vocabulary, one abstraction level lower — so a
requirements file can be mechanically derived from an outcome file later.
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
    """Capability classes from the thesis, used here as a coarse pre-filter over
    real VM families. Narrower needs go in `sku_hints`, which the engine treats
    as a hard constraint that shrinks the qualifying pool."""

    GENERAL = "general"
    COMPUTE = "compute-intensive"
    MEMORY = "memory-heavy"
    STORAGE = "storage-optimised"
    CONFIDENTIAL = "confidential"
    ACCELERATOR = "accelerator"


class ComponentKind(str, Enum):
    """Outcome archetypes. The resolver maps these to concrete Azure services; a
    component may instead pin `service` directly when the choice is already made."""

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
    CDN_EDGE = "cdn-edge"
    SECRETS = "secrets"


class DataClassification(str, Enum):
    PUBLIC = "public"
    INTERNAL = "internal"
    CONFIDENTIAL = "confidential"
    RESTRICTED = "restricted"


class ResiliencyTopology(str, Enum):
    SINGLE = "single"                  # one region, no zonal guarantee
    ZONAL = "zonal"                    # one region, zone-redundant
    ACTIVE_PASSIVE = "active-passive"  # primary plus warm/cold secondary
    ACTIVE_ACTIVE = "active-active"    # two or more regions serving traffic


class AffinityRule(str, Enum):
    SAME_REGION = "same-region"
    SAME_GEOGRAPHY = "same-geography"
    SEPARATE_REGION = "separate-region"
    SEPARATE_GEOGRAPHY = "separate-geography"


# --------------------------------------------------------------------------
# Constraint envelope
# --------------------------------------------------------------------------


class Residency(Strict):
    """Hard containment rules. Evaluated before anything is scored."""

    cloud: Cloud = Cloud.PUBLIC
    jurisdictions: list[str] = Field(
        default_factory=list,
        description="Jurisdiction codes the workload must stay inside, e.g. ['eu'], ['us'], ['de'].",
    )
    boundaries: list[str] = Field(
        default_factory=list,
        description="Named regulatory boundaries, e.g. ['eu-data-boundary'].",
    )
    allowed_regions: list[str] = Field(
        default_factory=list,
        description=(
            "Explicit whitelist. When set, nothing outside it is ever a candidate. Usually "
            "populated from the landing zone's allowedLocations policy rather than by hand."
        ),
    )
    excluded_regions: list[str] = Field(default_factory=list)


class Compliance(Strict):
    scope: list[str] = Field(
        default_factory=list,
        description="Certification/regulation scope, e.g. ['pci-dss', 'iso-27001', 'hipaa', 'dora'].",
    )


class DemandSource(Strict):
    """Where the users are. Drives latency scoring; only a hard filter when
    `latency_budget_hard_ms` is set."""

    geography: str = Field(
        description="Demand origin key, e.g. 'eu-west', 'us-east', 'apac-southeast'."
    )
    share: float = Field(ge=0.0, le=1.0, description="Fraction of total demand from this origin.")
    latency_p99_ms: int | None = Field(
        default=None,
        description="Target p99 network latency from this origin. Scored, not enforced.",
    )
    latency_budget_hard_ms: int | None = Field(
        default=None,
        description="Absolute ceiling. Regions exceeding it are eliminated, not merely penalised.",
    )


# --------------------------------------------------------------------------
# What the workload is made of
# --------------------------------------------------------------------------


class CapacityRequest(Strict):
    """Declared demand for compute. `capability_class` is the abstract ask;
    `sku_hints` narrows it when the workload genuinely cares about silicon."""

    capability_class: CapabilityClass = CapabilityClass.GENERAL
    sku_hints: list[str] = Field(
        default_factory=list,
        description=(
            "Concrete VM SKUs, e.g. ['Standard_ND96isr_H100_v5']. Narrowing here shrinks the "
            "qualifying pool and lowers capacity confidence — specificity is priced."
        ),
    )
    vcpu: int | None = None
    memory_gb: int | None = None
    instances: int | None = None
    accelerators: int | None = Field(
        default=None, description="Total GPU/accelerator count required."
    )
    interconnect: str | None = Field(
        default=None,
        description="Accelerator fabric requirement, e.g. 'infiniband', 'nvlink-domain>=8'.",
    )
    spot_tolerant: bool = False


class Component(Strict):
    """One piece of the workload. Placement is solved for the component set as a
    whole, because affinity rules couple them."""

    name: str
    kind: ComponentKind | None = None
    service: str | None = Field(
        default=None,
        description=(
            "Optional pin to a concrete Azure resource type, e.g. "
            "'Microsoft.ContainerService/managedClusters'. When set, `kind` is advisory."
        ),
    )
    features: list[str] = Field(
        default_factory=list,
        description=(
            "Feature-level requirements — the granularity that actually breaks deployments, e.g. "
            "['availability-zones', 'zone-redundant-ha', 'customer-managed-key', 'private-link']."
        ),
    )
    classification: DataClassification = DataClassification.INTERNAL
    capacity: CapacityRequest | None = None
    required: bool = Field(
        default=True,
        description="False marks the component as droppable if it alone blocks an otherwise good region.",
    )

    @model_validator(mode="after")
    def _kind_or_service(self) -> Component:
        if self.kind is None and self.service is None:
            raise ValueError(f"component '{self.name}': one of `kind` or `service` is required")
        return self


class Affinity(Strict):
    components: list[str] = Field(min_length=2)
    rule: AffinityRule
    reason: str | None = None


# --------------------------------------------------------------------------
# Resiliency, landing zone, weighting
# --------------------------------------------------------------------------


class Resiliency(Strict):
    topology: ResiliencyTopology = ResiliencyTopology.ZONAL
    rto: str | None = Field(default=None, description="Recovery time objective, e.g. '15m', '4h'.")
    rpo: str | None = Field(default=None, description="Recovery point objective, e.g. '5m', '0'.")
    geo_pair_required: bool = Field(
        default=False,
        description=(
            "Require the secondary to be the Azure-designated paired region — sequential platform "
            "updates, paired-region recovery priority, and some service replication depend on it."
        ),
    )
    min_availability_zones: int = Field(default=0, ge=0, le=3)


class LandingZone(Strict):
    """The customer's existing reality. Normally sourced from a tenant context
    file or a live ARM read; the inline fields let a caller work without one."""

    context: str | None = Field(
        default=None,
        description="Path to a tenant context JSON, or the literal 'live' to collect from ARM.",
    )
    existing_regions: list[str] = Field(
        default_factory=list,
        description="Regions the customer already operates in. Scored as operational fit.",
    )
    network_anchors: list[str] = Field(
        default_factory=list,
        description="Fixed attachment points, e.g. ['expressroute:amsterdam', 'vwan-hub:westeurope'].",
    )
    subscription_id: str | None = None


class Priorities(Strict):
    """Weights for the scoring pass. Normalised before use, so relative magnitude
    is what matters, not the sum."""

    latency: float = Field(default=0.25, ge=0.0)
    cost: float = Field(default=0.20, ge=0.0)
    capacity_confidence: float = Field(default=0.25, ge=0.0)
    resiliency: float = Field(default=0.15, ge=0.0)
    operational_fit: float = Field(default=0.10, ge=0.0)
    sustainability: float = Field(default=0.05, ge=0.0)

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


class Requirements(Strict):
    api_version: str = Field(default=API_VERSION, alias="apiVersion")
    workload: str
    owner: str | None = None
    description: str | None = None

    residency: Residency = Field(default_factory=Residency)
    compliance: Compliance = Field(default_factory=Compliance)
    demand: list[DemandSource] = Field(default_factory=list)
    components: list[Component] = Field(min_length=1)
    affinity: list[Affinity] = Field(default_factory=list)
    resiliency: Resiliency = Field(default_factory=Resiliency)
    landing_zone: LandingZone = Field(default_factory=LandingZone, alias="landingZone")
    priorities: Priorities = Field(default_factory=Priorities)

    model_config = ConfigDict(extra="forbid", frozen=True, populate_by_name=True)

    @model_validator(mode="after")
    def _coherent(self) -> Requirements:
        if self.api_version != API_VERSION:
            raise ValueError(
                f"unsupported apiVersion {self.api_version!r}; expected {API_VERSION!r}"
            )

        names = [c.name for c in self.components]
        if len(names) != len(set(names)):
            raise ValueError("component names must be unique")

        known = set(names)
        for rule in self.affinity:
            unknown = sorted(c for c in rule.components if c not in known)
            if unknown:
                raise ValueError(f"affinity rule references unknown components: {unknown}")

        if self.demand:
            total = sum(d.share for d in self.demand)
            if abs(total - 1.0) > 0.01:
                raise ValueError(f"demand shares must sum to 1.0 (got {total:.3f})")

        return self

    def component(self, name: str) -> Component:
        for c in self.components:
            if c.name == name:
                return c
        raise KeyError(name)
