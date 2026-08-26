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
    REGION_ACCESS_PROCESS,
    REGION_ACCESS_REFERENCE,
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
            )
        return Remediation(
            kind=RemediationKind.UNKNOWN,
            detail=f"{self.sku} is restricted in {self.region} (reason: {self.reason})",
        )


class TenantContext(BaseModel):
    """A read-only picture of one subscription's reach."""

    subscription_id: str | None = None
    collected_at: datetime
    mode: str = Field(default="offline", description="'offline' or 'live'.")

    sku_restrictions: list[SkuRestriction] = Field(default_factory=list)
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

    def can_deploy(self, sku: str, region: str) -> bool:
        """Whether this subscription may deploy a SKU in a region.

        Absence of a restriction is a positive: the SKU list enumerates every
        restriction the subscription has, so an unrestricted SKU is deployable.
        """
        restriction = self.restriction_for(sku, region)
        return restriction is None or not restriction.is_whole_region

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
