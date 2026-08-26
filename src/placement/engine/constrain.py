"""Stage 3 — hard filters, in CAF's order, producing evidenced eliminations.

Every filter here must be defensible from a deterministic fact. A region that
loses at this stage lost on evidence, not on judgement; scoring is where
judgement lives. Keeping those apart is what lets a customer tell whether their
region was ruled out or merely ranked low.

Three rules run through all of it:

* **Unknown is never a negative.** A capability the snapshot cannot confirm
  produces a risk on the surviving candidate, not an elimination.
* **Every elimination carries the fact that produced it**, with its source and
  as-of date.
* **Eliminations that a request would lift are marked as such.** Region access
  and quota are not open by default, and reporting an entitlement gap as
  "unavailable" sends customers to a worse region than they could have had.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from placement.contracts.decision import (
    Elimination,
    EliminationStage,
    Evidence,
    Remediation,
    Risk,
)
from placement.contracts.requirements import Requirements
from placement.engine.resolve import ResolvedComponent
from placement.snapshot.model import Region, WorldSnapshot
from placement.tenant.model import TenantContext


@dataclass
class Verdict:
    """What survived, why the rest didn't, and what remains uncertain."""

    candidates: list[str] = field(default_factory=list)
    eliminations: list[Elimination] = field(default_factory=list)
    risks: dict[str, list[Risk]] = field(default_factory=dict)

    def eliminate(self, elimination: Elimination) -> None:
        self.eliminations.append(elimination)

    def risk(self, region: str, risk: Risk) -> None:
        self.risks.setdefault(region, []).append(risk)


def _evidence(
    snapshot: WorldSnapshot, source: str, detail: str, confidence: float = 1.0
) -> Evidence | None:
    """Cite a fact, or cite nothing.

    Returns None when the snapshot has no such source. Inventing an as-of date
    would both break reproducibility and attribute a claim to a source that did
    not make it - and evidence nobody can check is worse than none.
    """
    ref = snapshot.sources.get(source)
    if ref is None:
        return None
    return Evidence(
        source=source,
        as_of=ref.as_of,
        ref=ref.endpoint,
        detail=detail,
        confidence=confidence,
    )


def _cite(*evidence: Evidence | None) -> list[Evidence]:
    return [e for e in evidence if e is not None]


# --------------------------------------------------------------------------
# Filters
# --------------------------------------------------------------------------


def _residency_ok(region: Region, component: ResolvedComponent) -> tuple[bool, str]:
    """Residency is evaluated on `geography`, Azure's actual commitment boundary.

    Never on `physical_location`: `westeurope` sits in Frankfurt-adjacent
    Netherlands but commits residency at 'Europe', so filtering a country
    requirement on the datacentre location would promise more than Microsoft
    does.
    """
    residency = component.residency

    if residency.allowed_regions and region.name not in residency.allowed_regions:
        return False, "not in the landing zone's allowed locations"

    if region.name in residency.excluded_regions:
        return False, "explicitly excluded"

    if residency.jurisdictions:
        geography = (region.geography or "").lower()
        group = (region.geography_group or "").lower()
        wanted = {j.lower() for j in residency.jurisdictions}

        # 'eu' is a grouping rather than an Azure geography name.
        matched = any(
            j == geography
            or j == group
            or (j in {"eu", "europe"} and group == "europe")
            or (j in {"us", "usa"} and group == "us")
            or _country_matches(j, geography)
            for j in wanted
        )
        if not matched:
            return False, (
                f"geography '{region.geography}' is outside "
                f"{sorted(residency.jurisdictions)}"
            )

    return True, ""


_COUNTRY_CODES = {
    "de": "germany",
    "fr": "france",
    "it": "italy",
    "es": "spain",
    "pl": "poland",
    "se": "sweden",
    "no": "norway",
    "ch": "switzerland",
    "at": "austria",
    "be": "belgium",
    "dk": "denmark",
    "uk": "united kingdom",
    "gb": "united kingdom",
    "ie": "ireland",
    "nl": "netherlands",
    "jp": "japan",
    "kr": "korea",
    "in": "india",
    "au": "australia",
    "br": "brazil",
    "ca": "canada",
    "za": "south africa",
}


def _country_matches(code_or_name: str, geography: str) -> bool:
    if not geography:
        return False
    return _COUNTRY_CODES.get(code_or_name, code_or_name) == geography


def apply(
    requirements: Requirements,
    components: list[ResolvedComponent],
    snapshot: WorldSnapshot,
    tenant: TenantContext | None = None,
) -> Verdict:
    """Run every hard filter and return the surviving regions."""
    verdict = Verdict()
    min_zones = requirements.resiliency.min_availability_zones

    for region in sorted(snapshot.placement_candidates(), key=lambda r: r.name):
        eliminated = False

        for component in components:
            # -- residency and compliance (CAF step 1) ----------------------
            ok, reason = _residency_ok(region, component)
            if not ok:
                verdict.eliminate(
                    Elimination(
                        region=region.name,
                        stage=EliminationStage.RESIDENCY,
                        rule="residency",
                        component=component.name,
                        reason=reason,
                        evidence=_cite(
                            _evidence(
                                snapshot,
                                "arm-locations",
                                f"{region.name} geography={region.geography!r} "
                                f"group={region.geography_group!r}",
                            )
                        ),
                    )
                )
                eliminated = True
                break

            # -- service availability (CAF step 3.1) ------------------------
            available = snapshot.service_available(component.resource_type, region.name)
            if available is False:
                verdict.eliminate(
                    Elimination(
                        region=region.name,
                        stage=EliminationStage.SERVICE_AVAILABILITY,
                        rule="service-availability",
                        component=component.name,
                        reason=f"{component.resource_type} is not offered in {region.name}",
                        evidence=_cite(
                            _evidence(
                                snapshot,
                                "arm-providers",
                                "resource type absent from provider metadata for this region",
                            )
                        ),
                    )
                )
                eliminated = True
                break
            if available is None and component.resource_type:
                verdict.risk(
                    region.name,
                    Risk(
                        severity="medium",
                        category="unconfirmed-service",
                        detail=(
                            f"{component.resource_type} availability in {region.name} was not "
                            "established; the provider slice does not cover it"
                        ),
                        mitigation="Confirm before committing to this region.",
                    ),
                )

            # -- capability availability -----------------------------------
            for capability in component.capabilities:
                state = snapshot.capability_available(
                    component.resource_type, capability, region.name
                )
                if state is None:
                    state = snapshot.capability_available("*", capability, region.name)

                if state is False:
                    verdict.eliminate(
                        Elimination(
                            region=region.name,
                            stage=EliminationStage.CAPABILITY_AVAILABILITY,
                            rule=f"capability:{capability}",
                            component=component.name,
                            reason=(
                                f"{component.resource_type} does not support '{capability}' "
                                f"in {region.name}"
                            ),
                            evidence=_cite(
                                _evidence(
                                    snapshot,
                                    (
                                        snapshot.capability(component.resource_type, capability)
                                        or snapshot.capability("*", capability)
                                    ).source,
                                    (
                                        snapshot.capability(component.resource_type, capability)
                                        or snapshot.capability("*", capability)
                                    ).detail
                                    or capability,
                                )
                            ),
                        )
                    )
                    eliminated = True
                    break
                if state is None:
                    # Unknown never eliminates. Most providers expose no
                    # capabilities API at all, so this is common and honest.
                    verdict.risk(
                        region.name,
                        Risk(
                            severity="low",
                            category="unconfirmed-capability",
                            detail=(
                                f"'{capability}' on {component.resource_type} could not be "
                                f"confirmed for {region.name}"
                            ),
                            mitigation="No capability source covers this; verify manually.",
                        ),
                    )
            if eliminated:
                break

            # -- availability zones (CAF step 3.3) --------------------------
            if min_zones and region.zone_count < min_zones:
                verdict.eliminate(
                    Elimination(
                        region=region.name,
                        stage=EliminationStage.RESILIENCY,
                        rule="resiliency.min_availability_zones",
                        component=component.name,
                        reason=(
                            f"{region.name} reports {region.zone_count} availability zones, "
                            f"{min_zones} required"
                        ),
                        evidence=_cite(
                            _evidence(snapshot, "arm-locations", "availabilityZoneMappings"),
                        ),
                    )
                )
                eliminated = True
                break

            # -- SKU availability and reachability (CAF step 3.5) ----------
            for sku_name in component.sku_hints:
                exists = snapshot.sku_available(sku_name, region.name)
                if exists is False:
                    verdict.eliminate(
                        Elimination(
                            region=region.name,
                            stage=EliminationStage.CAPACITY,
                            rule="capacity.sku_hints",
                            component=component.name,
                            reason=f"{sku_name} is not offered in {region.name}",
                            evidence=_cite(
                                _evidence(snapshot, "compute-skus", f"{sku_name} absent"),
                            ),
                        )
                    )
                    eliminated = True
                    break

                if exists and tenant is not None:
                    sku = snapshot.vm_sku(sku_name)
                    required = component.vcpus_required
                    if required is None and sku and sku.vcpus:
                        instances = (
                            component.component.capacity.instances
                            if component.component.capacity
                            else None
                        )
                        required = sku.vcpus * (instances or 1)

                    assessment = tenant.assess(
                        sku_name,
                        region.name,
                        family=sku.family if sku else None,
                        vcpus_required=required,
                    )
                    if not assessment.deployable:
                        verdict.eliminate(
                            Elimination(
                                region=region.name,
                                stage=EliminationStage.CAPACITY,
                                rule="tenant.deployability",
                                component=component.name,
                                reason=assessment.reason,
                                remediation=assessment.remediation,
                                evidence=[
                                    Evidence(
                                        source="tenant-context",
                                        as_of=tenant.collected_at,
                                        detail=assessment.reason,
                                        # Tenant state changes under us; it was
                                        # true at collection time, not now.
                                        confidence=0.9,
                                    )
                                ],
                            )
                        )
                        eliminated = True
                        break

                    if sku and tenant.can_reserve(sku_name, region.name) is False:
                        verdict.risk(
                            region.name,
                            Risk(
                                severity="medium",
                                category="capacity-reservation",
                                detail=(
                                    f"{sku_name} cannot be capacity-reserved in {region.name} on "
                                    "this subscription, so capacity is not guaranteed ahead of "
                                    "deployment"
                                ),
                                mitigation="Quota alone does not guarantee capacity here.",
                            ),
                        )
            if eliminated:
                break

        if not eliminated:
            verdict.candidates.append(region.name)

    return verdict


def remediable(verdict: Verdict) -> dict[str, Remediation]:
    """Regions eliminated only by things a request would lift.

    A region blocked solely by an entitlement or quota gap is a different answer
    from one blocked on residency, and collapsing them loses the actionable half.
    """
    blocked: set[str] = set()
    liftable: dict[str, Remediation] = {}

    for elimination in verdict.eliminations:
        if elimination.is_final:
            blocked.add(elimination.region)
        elif elimination.remediation is not None:
            liftable.setdefault(elimination.region, elimination.remediation)

    return {region: rem for region, rem in liftable.items() if region not in blocked}
