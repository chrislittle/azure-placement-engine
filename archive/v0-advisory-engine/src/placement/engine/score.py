"""Stage 5 — rank the regions that survived the filters.

CAF prescribes the criteria and their sequence but no ranking method, so the
weighting is ours. The decision record says so rather than implying otherwise,
and every subscore carries its weight so a reader can disagree with the
weighting instead of disagreeing with the tool.

Two dimensions have no data source yet — cost and latency. They are reported as
**unscored with an explicit warning** rather than silently defaulted, because a
zero would drag rankings and a one would flatter them, and both would be
invented.
"""

from __future__ import annotations

from placement.contracts.decision import Evidence, Subscore
from placement.contracts.requirements import Requirements
from placement.snapshot.model import RegionCategory, WorldSnapshot

#: Dimensions with no ingester yet. Named here so the engine warns about exactly
#: these rather than quietly ranking on four of six.
UNSCORED = ("latency", "cost")


def _evidence(
    snapshot: WorldSnapshot, source: str, detail: str, confidence: float = 1.0
) -> Evidence | None:
    """Cite a fact, or cite nothing.

    Returns None when the snapshot has no such source. Inventing an as-of date
    would both break reproducibility and attribute a claim to a source that did
    not make it.
    """
    ref = snapshot.sources.get(source)
    if ref is None:
        return None
    return Evidence(source=source, as_of=ref.as_of, detail=detail, confidence=confidence)


def _cite(*evidence: Evidence | None) -> list[Evidence]:
    return [e for e in evidence if e is not None]


def _region_category_score(snapshot: WorldSnapshot, region: str) -> tuple[float, str]:
    """Maturity, computed from service coverage rather than the binary flag.

    Azure's own `regionCategory` is only ever Recommended or Other, which puts
    `denmarkeast` and `westeurope` in the same bucket while they differ by more
    than fifty points of actual service coverage. Coverage is the better signal;
    the flag is a tiebreak.
    """
    coverage = snapshot.service_coverage(region)
    entry = snapshot.regions.get(region)
    bonus = 0.1 if entry and entry.region_category is RegionCategory.RECOMMENDED else 0.0
    return min(1.0, coverage + bonus), (
        f"{coverage:.0%} of regionally-deployable resource types available"
        + (" (Azure-Recommended region)" if bonus else "")
    )


def _expansion_score(
    requirements: Requirements, snapshot: WorldSnapshot, region: str
) -> tuple[float, str]:
    """Cost of standing up platform footprint in a region.

    Cheapest where the customer already operates: CAF's landing-zone guidance
    treats adding a region as real work — a hub or vWAN hub in the Connectivity
    subscription, gateways, DNS forwarders, identity, workspace placement.
    """
    existing = set(requirements.landing_zone.existing_regions)
    if not existing:
        return 0.5, "no existing footprint declared; expansion cost is uniform"

    if region in existing:
        return 1.0, "already operating here; no new platform footprint required"

    entry = snapshot.regions.get(region)
    same_geo = any(
        snapshot.regions.get(r) and snapshot.regions[r].geography_group == (entry.geography_group if entry else None)
        for r in existing
    )
    anchors = [a for a in requirements.landing_zone.network_anchors if region in a]
    if anchors:
        return 0.8, f"network anchor present ({', '.join(anchors)})"
    if same_geo:
        return 0.6, "new region, but within an existing geography group"
    return 0.3, "new geography; full platform footprint required"


def _capacity_score(
    snapshot: WorldSnapshot, region: str, sku_hints: list[str]
) -> tuple[float, str, float, str]:
    """Confidence that declared capacity is obtainable. Never a boolean.

    There is no API that answers "is there room". Proven restrictions eliminate
    upstream; what is left here is inference, so the evidence carries a
    confidence below 1.0 and the record shows the difference.
    """
    if not sku_hints:
        coverage = snapshot.service_coverage(region)
        # Attributed to the provider slice, which is where coverage comes from.
        return coverage, f"no specific SKU declared; region coverage {coverage:.0%}", 0.6, "arm-providers"

    zones: list[int] = []
    for name in sku_hints:
        sku = snapshot.vm_sku(name)
        zones.append(len(sku.zones_in(region)) if sku else 0)

    if not any(zones):
        return 0.2, "declared SKUs are offered in no availability zone here", 0.7, "compute-skus"

    # More zones is more places the scheduler can satisfy the request from.
    average = sum(zones) / len(zones)
    return (
        min(1.0, average / 3.0),
        f"declared SKUs offered across {average:.1f} availability zones on average",
        0.7,
        "compute-skus",
    )


def score_region(
    requirements: Requirements,
    snapshot: WorldSnapshot,
    region: str,
    sku_hints: list[str],
) -> dict[str, Subscore]:
    """Score one candidate across every weighted dimension."""
    weights = requirements.priorities.normalised()
    subscores: dict[str, Subscore] = {}

    for dimension in UNSCORED:
        subscores[dimension] = Subscore(
            value=0.0,
            weight=0.0,  # excluded from the total rather than counted as zero
            rationale=(
                f"{dimension} is not yet scored - no ingester exists for it. Excluded from the "
                "ranking rather than defaulted, which would invent a result."
            ),
        )

    value, rationale, confidence, source = _capacity_score(snapshot, region, sku_hints)
    subscores["capacity_confidence"] = Subscore(
        value=value,
        weight=weights["capacity_confidence"],
        rationale=rationale,
        evidence=_cite(_evidence(snapshot, source, rationale, confidence)),
    )

    value, rationale = _region_category_score(snapshot, region)
    subscores["region_category"] = Subscore(
        value=value,
        weight=weights["region_category"],
        rationale=rationale,
        evidence=_cite(_evidence(snapshot, "arm-providers", rationale)),
    )

    value, rationale = _expansion_score(requirements, snapshot, region)
    subscores["landing_zone_expansion"] = Subscore(
        value=value,
        weight=weights["landing_zone_expansion"],
        rationale=rationale,
    )

    return subscores


def total(subscores: dict[str, Subscore]) -> float:
    """Weighted total, renormalised over the dimensions that were actually scored.

    Without renormalisation every candidate would be scaled down by the missing
    dimensions' weight, making scores look uniformly poor rather than simply
    incomplete.
    """
    live = {k: s for k, s in subscores.items() if s.weight > 0}
    if not live:
        return 0.0
    weight_sum = sum(s.weight for s in live.values())
    return sum(s.value * s.weight for s in live.values()) / weight_sum
