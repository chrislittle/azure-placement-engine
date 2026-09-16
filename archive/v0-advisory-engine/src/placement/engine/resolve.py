"""Stage 2 — resolve requirements into the concrete facts the filters need.

Turns each component into the ARM resource type and capability set the snapshot
can be queried with, and resolves the flow inheritance the requirements grammar
promises: residency and compliance flow down a path onto every component that
serves it, and a component's recovery targets are the strictest among the flows
it participates in.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from placement.contracts.requirements import (
    Component,
    Criticality,
    Flow,
    Requirements,
    Residency,
    Sensitivity,
    Topology,
)

#: Rough ordering for recovery targets, used to pick the strictest among the
#: flows a component serves. Deliberately coarse: the exact minutes matter less
#: than which band a component lands in, and a false precision here would imply
#: the engine knows more than it does.
_RTO_BANDS: tuple[tuple[str, int], ...] = (
    ("0", 0),
    ("1m", 1),
    ("5m", 5),
    ("15m", 15),
    ("30m", 30),
    ("1h", 60),
    ("4h", 240),
    ("12h", 720),
    ("24h", 1440),
)


def parse_duration(value: str | None) -> int | None:
    """Minutes, or None when unparseable.

    Unparseable is not zero: treating an unreadable RTO as instant would silently
    upgrade a component to the most expensive topology.
    """
    if not value:
        return None
    text = str(value).strip().lower()
    for suffix, factor in (("mo", None), ("d", 1440), ("h", 60), ("m", 1), ("s", 1 / 60)):
        if factor is None:
            continue
        if text.endswith(suffix):
            try:
                return int(float(text[: -len(suffix)]) * factor)
            except ValueError:
                return None
    try:
        return int(float(text))
    except ValueError:
        return None


@dataclass
class ResolvedComponent:
    """One component with everything the filters need, inheritance applied."""

    component: Component
    resource_type: str
    capabilities: list[str]
    residency: Residency
    compliance: list[str]
    flows: list[Flow]

    #: Strictest recovery targets among the flows this component serves.
    rto_minutes: int | None = None
    rpo_minutes: int | None = None
    driving_flow: str | None = None
    criticality: Criticality = Criticality.MEDIUM
    latency_sensitivity: Sensitivity = Sensitivity.MEDIUM
    topology_override: Topology | None = None

    #: Compute demand, when the component declares any.
    vcpus_required: int | None = None
    sku_hints: list[str] = field(default_factory=list)

    @property
    def name(self) -> str:
        return self.component.name

    @property
    def needs_multi_region(self) -> bool:
        """Whether recovery targets imply more than one region.

        A component whose strictest RTO is under four hours cannot be served by a
        single region, because a regional outage exceeds that on its own.
        """
        return self.rto_minutes is not None and self.rto_minutes < 240


def _merge_residency(*envelopes: Residency | None) -> Residency:
    """Intersect residency envelopes.

    A component's effective envelope is the intersection of the workload
    default, every flow it serves, and its own override — narrowing only, since
    a flow carrying regulated data must not be able to widen the workload rule.
    """
    present = [e for e in envelopes if e is not None]
    if not present:
        return Residency()

    base = present[0]
    jurisdictions: list[str] = []
    boundaries: list[str] = []
    allowed: list[str] = []
    excluded: list[str] = []

    for envelope in present:
        for value in envelope.jurisdictions:
            if value not in jurisdictions:
                jurisdictions.append(value)
        for value in envelope.boundaries:
            if value not in boundaries:
                boundaries.append(value)
        for value in envelope.excluded_regions:
            if value not in excluded:
                excluded.append(value)

    # Whitelists intersect rather than union: two whitelists both apply.
    whitelists = [set(e.allowed_regions) for e in present if e.allowed_regions]
    if whitelists:
        common = set.intersection(*whitelists)
        allowed = sorted(common)

    return Residency(
        cloud=base.cloud,
        jurisdictions=jurisdictions,
        boundaries=boundaries,
        allowed_regions=allowed,
        excluded_regions=excluded,
    )


_CRITICALITY_ORDER = {Criticality.LOW: 0, Criticality.MEDIUM: 1, Criticality.HIGH: 2}
_SENSITIVITY_ORDER = {Sensitivity.LOW: 0, Sensitivity.MEDIUM: 1, Sensitivity.HIGH: 2}


def resolve(requirements: Requirements) -> list[ResolvedComponent]:
    """Apply flow inheritance and produce one resolved component per component."""
    resolved: list[ResolvedComponent] = []

    for component in requirements.components:
        flows = requirements.flows_for(component.name)

        rto = None
        rpo = None
        driving = None
        criticality = Criticality.LOW
        sensitivity = Sensitivity.LOW

        for flow in flows:
            candidate = parse_duration(flow.rto)
            if candidate is not None and (rto is None or candidate < rto):
                rto, driving = candidate, flow.name

            candidate_rpo = parse_duration(flow.rpo)
            if candidate_rpo is not None and (rpo is None or candidate_rpo < rpo):
                rpo = candidate_rpo

            if _CRITICALITY_ORDER[flow.criticality] > _CRITICALITY_ORDER[criticality]:
                criticality = flow.criticality
            if _SENSITIVITY_ORDER[flow.latency_sensitivity] > _SENSITIVITY_ORDER[sensitivity]:
                sensitivity = flow.latency_sensitivity

        compliance = list(requirements.compliance)
        for flow in flows:
            for scope in flow.compliance:
                if scope not in compliance:
                    compliance.append(scope)

        residency = _merge_residency(
            requirements.residency,
            *[f.residency for f in flows],
            component.residency,
        )

        capacity = component.capacity
        vcpus = None
        if capacity is not None:
            if capacity.vcpu is not None:
                vcpus = capacity.vcpu
            elif capacity.instances is not None:
                # Left unknown rather than guessed; the SKU's own vCPU count is
                # applied later, where the SKU is actually known.
                vcpus = None

        resolved.append(
            ResolvedComponent(
                component=component,
                resource_type=component.service or "",
                capabilities=list(component.capabilities),
                residency=residency,
                compliance=compliance,
                flows=flows,
                rto_minutes=rto,
                rpo_minutes=rpo,
                driving_flow=driving,
                criticality=criticality,
                latency_sensitivity=sensitivity,
                topology_override=component.topology,
                vcpus_required=vcpus,
                sku_hints=list(capacity.sku_hints) if capacity else [],
            )
        )

    return resolved


def derive_topology(component: ResolvedComponent, *, min_zones: int) -> Topology:
    """Choose a topology from recovery targets rather than accepting one.

    The customer states RTO/RPO; the engine states the shape. A reporting store
    on a 24-hour flow does not pay for what the checkout path needs.
    """
    if component.topology_override is not None:
        return component.topology_override

    rto = component.rto_minutes
    if rto is None:
        return Topology.ZONAL if min_zones else Topology.SINGLE

    if rto < 15:
        # Sub-15-minute recovery cannot survive a regional loss without another
        # region already serving.
        return Topology.ACTIVE_ACTIVE
    if rto < 240:
        return Topology.ACTIVE_PASSIVE
    return Topology.ZONAL if min_zones else Topology.SINGLE
