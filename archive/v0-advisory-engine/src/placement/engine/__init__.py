"""The engine: resolve, constrain, compose, score, record.

Assembles a `DecisionRecord` from a requirements file, a pinned world snapshot,
and optionally a tenant context. Deterministic throughout — the same inputs
against the same snapshot must produce the same record, because a placement
decision gets challenged in a design review and has to survive being re-run.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone

from placement import __version__, knowledge
from placement.contracts.decision import (
    Candidate,
    ComponentDecision,
    DecisionRecord,
    FlowOutcome,
    Placement,
    RegionRole,
    Relaxation,
    Risk,
    SnapshotRef,
    TenantRef,
)
from placement.contracts.requirements import Criticality, Requirements, Topology
from placement.engine import constrain, score
from placement.engine.resolve import ResolvedComponent, derive_topology, resolve
from placement.snapshot.model import WorldSnapshot
from placement.tenant.model import TenantContext

__all__ = ["decide"]


def _digest(requirements: Requirements) -> str:
    blob = json.dumps(
        requirements.model_dump(mode="json", exclude_none=True), sort_keys=True, separators=(",", ":")
    )
    return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _needs_secondary(components: list[ResolvedComponent], min_zones: int) -> bool:
    return any(
        derive_topology(c, min_zones=min_zones)
        in (Topology.ACTIVE_PASSIVE, Topology.ACTIVE_ACTIVE)
        for c in components
    )


def _pick_secondary(
    primary: str, candidates: list[str], requirements: Requirements, snapshot: WorldSnapshot
) -> str | None:
    """Choose a secondary for a primary.

    Prefers a different geography group when one is available — a secondary
    sharing the primary's failure geography buys less than it appears to. Paired
    regions are honoured only when explicitly required, since CAF no longer
    treats pairing as mandatory.
    """
    others = [r for r in candidates if r != primary]
    if not others:
        return None

    if requirements.resiliency.require_paired_region:
        entry = snapshot.regions.get(primary)
        paired = [r for r in others if entry and r in entry.paired_regions]
        return paired[0] if paired else None

    entry = snapshot.regions.get(primary)
    group = entry.geography_group if entry else None
    different = [
        r
        for r in others
        if snapshot.regions.get(r) and snapshot.regions[r].geography_group != group
    ]
    return (different or others)[0]


def _relaxations(
    requirements: Requirements,
    verdict: constrain.Verdict,
    snapshot: WorldSnapshot,
) -> list[Relaxation]:
    """Priced ways to unstick an over-constrained problem.

    This is what flow criticality buys. Rather than returning "infeasible", the
    engine names the least valuable thing to give up first.
    """
    out: list[Relaxation] = []

    for region, remediations in sorted(verdict.remediations.items()):
        remediation = remediations[0]
        out.append(
            Relaxation(
                target=region,
                kind=remediation.kind.value,
                detail=remediation.detail,
                unlocks=[region],
                gives_up=(
                    "nothing in the design - this is a request, not a concession "
                    f"({remediation.tier.value})"
                ),
            )
        )

    low_value = [
        f
        for f in requirements.effective_flows()
        if f.criticality is Criticality.LOW and f.splittable
    ]
    for flow in low_value:
        out.append(
            Relaxation(
                target=flow.name,
                kind="split-flow",
                detail=(
                    f"'{flow.name}' is low-criticality and splittable; placing its components "
                    "separately would relax the co-location constraint"
                ),
                gives_up="added latency and cross-region transfer on a low-value path",
                criticality_of_target=flow.criticality.value,
            )
        )

    optional = [c for c in requirements.components if not c.required]
    for component in optional:
        blocking = {
            e.region for e in verdict.eliminations if e.component == component.name
        }
        if blocking:
            out.append(
                Relaxation(
                    target=component.name,
                    kind="drop-optional-component",
                    detail=f"'{component.name}' is marked optional and blocks {len(blocking)} regions",
                    unlocks=sorted(blocking),
                    gives_up=f"the {component.name} capability entirely",
                )
            )

    return out


def decide(
    requirements: Requirements,
    snapshot: WorldSnapshot,
    tenant: TenantContext | None = None,
    *,
    max_alternatives: int = 4,
    now: datetime | None = None,
) -> DecisionRecord:
    """Produce a decision record. Deterministic given the same inputs."""
    generated_at = now or datetime.now(timezone.utc)
    components = resolve(requirements)
    min_zones = requirements.resiliency.min_availability_zones

    verdict = constrain.apply(requirements, components, snapshot, tenant)

    warnings: list[str] = [
        f"'{d}' is not scored - no ingester exists for it yet, so it is excluded from the "
        f"ranking rather than defaulted"
        for d in score.UNSCORED
    ]
    if requirements.horizon:
        warnings.append(
            f"a planning horizon of {requirements.horizon} was declared but is not modelled; "
            "this decision is point-in-time"
        )
    if tenant is None:
        warnings.append(
            "no tenant context supplied - subscription access, quota and capacity-reservation "
            "gates were not evaluated, so surviving regions are not confirmed deployable"
        )
    for stale in knowledge.stale_files():
        warnings.append(f"{stale.provenance()}")

    sku_hints = sorted({s for c in components for s in c.sku_hints})

    # Ranked on fit, with readiness as a tiebreak only.
    #
    # Deliberately not readiness-first. Whether a quota ticket is worth raising
    # is the customer's call, not the engine's — sorting on it would bury a
    # region they already operate in beneath fifty they have never used, for a
    # condition that may lift on its own. The record makes readiness impossible
    # to miss; it does not decide it.
    scored = sorted(
        (
            (score.total(sub), not verdict.remediations.get(region), region, sub)
            for region, sub in (
                (r, score.score_region(requirements, snapshot, r, sku_hints))
                for r in verdict.candidates
            )
        ),
        key=lambda item: (-item[0], -item[1], item[2]),
    )

    candidates: list[Candidate] = []
    for rank, (value, _ready, region, subscores) in enumerate(
        scored[: max_alternatives + 1], start=1
    ):
        secondary = (
            _pick_secondary(region, verdict.candidates, requirements, snapshot)
            if _needs_secondary(components, min_zones)
            else None
        )

        placements = [
            Placement(
                region=region,
                role=RegionRole.PRIMARY,
                zones=[z.logical_zone for z in snapshot.regions[region].zones],
                components=[c.name for c in components],
            )
        ]
        if secondary:
            placements.append(
                Placement(
                    region=secondary,
                    role=RegionRole.SECONDARY,
                    zones=[z.logical_zone for z in snapshot.regions[secondary].zones],
                    components=[
                        c.name
                        for c in components
                        if derive_topology(c, min_zones=min_zones)
                        in (Topology.ACTIVE_PASSIVE, Topology.ACTIVE_ACTIVE)
                    ],
                )
            )

        decisions = [
            ComponentDecision(
                component=c.name,
                topology=derive_topology(c, min_zones=min_zones).value,
                regions=[region] + ([secondary] if secondary and c.needs_multi_region else []),
                driving_flow=c.driving_flow,
                derived_rto=f"{c.rto_minutes}m" if c.rto_minutes is not None else None,
                derived_rpo=f"{c.rpo_minutes}m" if c.rpo_minutes is not None else None,
                rationale=(
                    f"strictest recovery target among {len(c.flows)} flow(s)"
                    if c.driving_flow
                    else "no recovery target stated; zonal by default"
                ),
                overridden=c.topology_override is not None,
            )
            for c in components
        ]

        flow_outcomes = [
            FlowOutcome(
                flow=flow.name,
                criticality=flow.criticality.value,
                regions=[region],
                split=False,
                notes="path co-located in the primary region",
            )
            for flow in requirements.effective_flows()
        ]

        risks: list[Risk] = list(verdict.risks.get(region, []))
        remediations = list(verdict.remediations.get(region, []))
        if secondary:
            risks.extend(verdict.risks.get(secondary, []))
            remediations.extend(verdict.remediations.get(secondary, []))

        candidates.append(
            Candidate(
                rank=rank,
                placements=placements,
                components=decisions,
                flows=flow_outcomes,
                score=round(value, 4),
                subscores=subscores,
                risks=risks[:12],
                remediations=remediations,
                summary=(
                    f"{region}"
                    + (f" with {secondary} as secondary" if secondary else "")
                    + f" - scored {value:.2f} on "
                    + f"{sum(1 for s in subscores.values() if s.weight > 0)} declared dimensions"
                    + (
                        ""
                        if not remediations
                        else f"; needs {len(remediations)} action(s) before deployment"
                    )
                ),
            )
        )

    return DecisionRecord(
        workload=requirements.workload,
        generated_at=generated_at,
        engine_version=__version__,
        snapshot=SnapshotRef(
            version=snapshot.version,
            digest=snapshot.digest(),
            sources={name: ref.as_of for name, ref in snapshot.sources.items()},
        ),
        tenant=TenantRef(
            mode=tenant.mode if tenant else "none",
            collected_at=tenant.collected_at if tenant else None,
        ),
        requirements_digest=_digest(requirements),
        recommended=candidates[0] if candidates else None,
        alternatives=candidates[1:],
        eliminations=verdict.eliminations,
        relaxations=_relaxations(requirements, verdict, snapshot),
        warnings=warnings,
    )
