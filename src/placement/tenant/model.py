"""Tenant context: what *this* subscription can actually reach.

Kept strictly separate from the world snapshot, and the separation earns its
keep here rather than being hygiene. The snapshot says a SKU exists in a region.
Tenant context says whether this subscription may deploy it. **The gap between
the two is a remediation** — something that exists but is not yet reachable is a
support request, not an absence, and telling a customer "unavailable" when the
honest answer is "available on request" sends them to a worse region for no
reason.

Never committed by default (see `.gitignore`): it names a subscription and
describes an estate.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, ConfigDict, Field

from placement.contracts.decision import (
    COMPUTE_ZONAL_QUOTA_NOTE,
    REGION_ACCESS_PROCESS,
    REGION_ACCESS_REFERENCE,
    AdjustmentTier,
    Remediation,
    RemediationKind,
)


class Frozen(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class RestrictionReason(str, Enum):
    """`reasonCode` values from `Microsoft.Compute/skus` restrictions.

    The two mean materially different things and must not be flattened together:
    one is an entitlement that support can grant, the other is a property of the
    subscription offer that a support ticket will not change.
    """

    NOT_AVAILABLE_FOR_SUBSCRIPTION = "NotAvailableForSubscription"
    QUOTA_ID = "QuotaId"


class SkuRestriction(Frozen):
    """One SKU that this subscription cannot deploy in one region."""

    sku: str
    region: str
    zones: list[str] = Field(
        default_factory=list,
        description="Restricted zones. Empty means the restriction covers the whole region.",
    )
    reason: str = Field(description="Raw `reasonCode`, preserved even if unrecognised.")
    restriction_type: str | None = Field(default=None, description="'Location' or 'Zone'.")

    @property
    def is_whole_region(self) -> bool:
        return not self.zones or self.restriction_type == "Location"

    def remediation(self) -> Remediation:
        """What, if anything, would lift this restriction."""
        if self.reason == RestrictionReason.NOT_AVAILABLE_FOR_SUBSCRIPTION.value:
            zonal = not self.is_whole_region
            return Remediation(
                kind=(
                    RemediationKind.ZONAL_ACCESS_REQUEST
                    if zonal
                    else RemediationKind.REGION_ACCESS_REQUEST
                ),
                detail=(
                    f"{self.sku} is not available to this subscription in "
                    f"{self.region}{' zones ' + ', '.join(self.zones) if zonal else ''}"
                ),
                tier=AdjustmentTier.SUPPORT_TICKET,
                process=REGION_ACCESS_PROCESS,
                reference=REGION_ACCESS_REFERENCE,
            )
        if self.reason == RestrictionReason.QUOTA_ID.value:
            return Remediation(
                kind=RemediationKind.NONE,
                detail=(
                    f"{self.sku} is excluded by this subscription's offer type in {self.region}. "
                    "A quota request will not change this; it needs a different offer."
                ),
                tier=AdjustmentTier.NOT_ADJUSTABLE,
            )
        return Remediation(
            kind=RemediationKind.UNKNOWN,
            detail=f"{self.sku} is restricted in {self.region} (reason: {self.reason})",
        )


def normalise_family(name: str) -> str:
    """Fold a VM family name to a comparable key.

    The SKU list and the usages API spell families differently — `standardNDSFamily`
    against `Standard NCASv3_T4 Family` — so both sides are squeezed and lowercased.
    Matches 183 of 184 families against live data.
    """
    return "".join(str(name).split()).lower()


class QuotaEntry(Frozen):
    """vCPU quota for one VM family in one region.

    Quota is the constraint that catches people out, and GPU families especially:
    on a live subscription **22 of 28 GPU families had a limit of zero** in West
    Europe, and so did ordinary families like `standardDSv5Family`. A SKU with no
    restriction is still not deployable without quota, so treating an absent
    restriction as "deployable" is wrong in the common case, not the edge case.
    """

    family: str = Field(description="Normalised family key.")
    display_name: str = Field(description="Raw name as reported.")
    region: str
    limit: int
    current: int = 0

    @property
    def available(self) -> int:
        return max(0, self.limit - self.current)

    def covers(self, vcpus: int) -> bool:
        return self.available >= vcpus


class Deployability(Frozen):
    """Whether a SKU can actually be deployed, and what to do if not.

    Three independent conditions have to hold, and each failure has a different
    answer: the SKU must exist in the region (world snapshot), the subscription
    must not be restricted from it, and there must be quota for its family.
    """

    deployable: bool
    reason: str
    remediation: Remediation | None = None
    quota_available: int | None = None
    quota_required: int | None = None


class TenantContext(BaseModel):
    """A read-only picture of one subscription's reach."""

    subscription_id: str | None = None
    collected_at: datetime
    mode: str = Field(default="offline", description="'offline' or 'live'.")

    sku_restrictions: list[SkuRestriction] = Field(default_factory=list)
    quotas: list[QuotaEntry] = Field(default_factory=list)
    reservation_unsupported: dict[str, list[str]] = Field(
        default_factory=dict,
        description=(
            "Region -> SKUs this subscription cannot create an on-demand capacity reservation for, "
            "from `CapacityReservationSupported` on Microsoft.Compute/skus. Stored as the negative "
            "because it is the actionable set."
        ),
    )
    allowed_locations: list[str] = Field(
        default_factory=list,
        description="From `allowedLocations` policy assignments. When set, a hard whitelist.",
    )
    existing_regions: list[str] = Field(
        default_factory=list, description="Regions the subscription already has resources in."
    )

    model_config = ConfigDict(extra="forbid")

    # -- lookups ---------------------------------------------------------

    def restriction_for(self, sku: str, region: str) -> SkuRestriction | None:
        lowered = sku.lower()
        for restriction in self.sku_restrictions:
            if restriction.sku.lower() == lowered and restriction.region == region:
                return restriction
        return None

    def is_unrestricted(self, sku: str, region: str) -> bool:
        """Whether no *access* restriction blocks this SKU in this region.

        **Necessary, not sufficient** — the same trap as region zone count. An
        unrestricted SKU still needs quota, and quota for GPU families is
        routinely zero. Use `assess()` for the question people actually mean.
        """
        restriction = self.restriction_for(sku, region)
        return restriction is None or not restriction.is_whole_region

    def quota_for(self, family: str, region: str) -> QuotaEntry | None:
        key = normalise_family(family)
        for entry in self.quotas:
            if entry.family == key and entry.region == region:
                return entry
        return None

    def assess(
        self,
        sku: str,
        region: str,
        *,
        family: str | None = None,
        vcpus_required: int | None = None,
        zonal: bool = False,
    ) -> Deployability:
        """Can this subscription deploy this SKU here, and if not, what fixes it?

        Checks access first and quota second, because an access restriction makes
        the quota question moot — you cannot raise quota for a region you have no
        entitlement to.

        `zonal` marks an ask that names a specific availability zone, which
        changes the *remedy* rather than the verdict: regional vCPU quota is a
        self-service API call, a zone-specific one is a support ticket.
        """
        restriction = self.restriction_for(sku, region)
        if restriction is not None and restriction.is_whole_region:
            return Deployability(
                deployable=False,
                reason=f"{sku} is restricted for this subscription in {region}",
                remediation=restriction.remediation(),
            )

        if family is None or not self.quotas:
            # No quota data collected: say so rather than implying a clean bill.
            return Deployability(
                deployable=True,
                reason=(
                    f"no access restriction on {sku} in {region}; quota not checked"
                    if not self.quotas
                    else f"no access restriction on {sku} in {region}"
                ),
            )

        entry = self.quota_for(family, region)
        if entry is None:
            return Deployability(
                deployable=True,
                reason=f"no access restriction on {sku} in {region}; no quota entry for {family}",
            )

        required = vcpus_required if vcpus_required is not None else 1
        if entry.covers(required):
            return Deployability(
                deployable=True,
                reason=f"{entry.available} vCPUs available in {family}",
                quota_available=entry.available,
                quota_required=required,
            )

        return Deployability(
            deployable=False,
            reason=(
                f"quota for {entry.display_name} in {region} is {entry.limit} "
                f"({entry.available} available, {required} needed)"
            ),
            remediation=Remediation(
                kind=RemediationKind.QUOTA_INCREASE,
                detail=(
                    f"{sku} is available and unrestricted in {region}, but the {entry.display_name} "
                    f"vCPU quota is {entry.limit}. GPU families in particular default to zero, so "
                    "this is the usual case rather than an exception."
                ),
                # Microsoft.Compute vCPU quota is a self-service Microsoft.Quota
                # PUT at regional scope - no ticket, no human, no lead time.
                tier=(
                    AdjustmentTier.SUPPORT_TICKET if zonal else AdjustmentTier.SELF_SERVICE
                ),
                note=COMPUTE_ZONAL_QUOTA_NOTE if zonal else None,
                process=(
                    "Regional: raise it directly via the Microsoft.Quota API (no ticket). "
                    "Zone-specific: Azure portal > Help + support > New support request. Issue "
                    "type: 'Service and subscription Limit (quotas)'; Quota type: 'Compute-VM "
                    "(cores-vCPUs) subscription limit increases'. Name the zone, and note that the "
                    "vCPU count applies to each requested zone."
                ),
                reference=REGION_ACCESS_REFERENCE,
            ),
            quota_available=entry.available,
            quota_required=required,
        )

    def can_reserve(self, sku: str, region: str) -> bool | None:
        """Whether an on-demand capacity reservation is possible for this SKU here.

        A **third gate**, independent of access and quota. `CapacityReservationSupported`
        is scoped to subscription x region and is the real pre-check: a
        subscription can hold approved quota and still fail to reserve, which the
        common field guidance of "get quota, then reserve" does not cover.

        Do not confuse it with `SupportedCapacityReservationTypes`, which is a
        static property of the VM series, reads identically on every
        subscription, and overstates availability.

        None when the data was not collected for that region.
        """
        if region not in self.reservation_unsupported:
            return None
        return sku not in self.reservation_unsupported[region]

    def restricted_regions(self) -> set[str]:
        """Regions where at least one SKU is restricted.

        A weak signal on its own — most regions restrict *some* SKU — so use it
        alongside how much is restricted rather than as a boolean.
        """
        return {r.region for r in self.sku_restrictions}

    def restriction_ratio(self, region: str, total_skus: int) -> float:
        """Share of known SKUs restricted in a region.

        High values mark a region this subscription has not been granted access
        to, as opposed to one where a handful of scarce SKUs are gated.
        """
        if total_skus <= 0:
            return 0.0
        restricted = sum(1 for r in self.sku_restrictions if r.region == region and r.is_whole_region)
        return min(1.0, restricted / total_skus)
