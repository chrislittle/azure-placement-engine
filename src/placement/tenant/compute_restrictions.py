"""Extract SKU restrictions from `Microsoft.Compute/skus` into tenant context.

The same payload feeds two different places, and splitting it is the point. The
SKU list and its zones are world facts and go to the snapshot; `restrictions[]`
describes what *this* subscription may deploy and comes here.

`NotAvailableForSubscription` is the best machine-readable signal Azure gives for
"this exists but you cannot reach it yet" — which is a support request, not an
absence.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from placement.tenant.model import SkuRestriction, TenantContext


class ExtractError(ValueError):
    pass


def parse_restrictions(payload: dict[str, Any]) -> list[SkuRestriction]:
    """Pull every SKU restriction out of one `Microsoft.Compute/skus` response."""
    if not isinstance(payload, dict) or "value" not in payload:
        raise ExtractError("expected a Microsoft.Compute/skus response with a `value` array")

    found: list[SkuRestriction] = []
    for entry in payload["value"]:
        if not isinstance(entry, dict) or entry.get("resourceType") != "virtualMachines":
            continue
        sku = entry.get("name")
        if not sku:
            continue

        for restriction in entry.get("restrictions") or []:
            if not isinstance(restriction, dict):
                continue
            info = restriction.get("restrictionInfo") or {}
            # `values` holds the restricted locations for a Location restriction;
            # `restrictionInfo.locations` repeats them for a Zone restriction.
            locations = info.get("locations") or restriction.get("values") or []
            zones = [str(z) for z in (info.get("zones") or [])]

            for location in locations:
                found.append(
                    SkuRestriction(
                        sku=sku,
                        region=str(location).lower(),
                        zones=sorted(zones),
                        reason=str(restriction.get("reasonCode") or "Unknown"),
                        restriction_type=restriction.get("type"),
                    )
                )
    return found


def build(
    per_region: dict[str, dict[str, Any]],
    *,
    subscription_id: str | None = None,
    collected_at: datetime | None = None,
    existing_regions: list[str] | None = None,
    allowed_locations: list[str] | None = None,
) -> TenantContext:
    """Build tenant context from per-region compute SKU payloads."""
    if not per_region:
        raise ExtractError("no compute SKU payloads supplied")

    restrictions: list[SkuRestriction] = []
    for _region, payload in sorted(per_region.items()):
        try:
            restrictions.extend(parse_restrictions(payload))
        except ExtractError:
            # An unreadable region yields no restrictions, which would read as
            # "everything is deployable there". Skipping is the safer error, but
            # it must not be silent - the caller sees a short list and can tell.
            continue

    # The same restriction is reported once per region queried; dedupe on identity.
    unique = {
        (r.sku, r.region, tuple(r.zones), r.reason, r.restriction_type): r for r in restrictions
    }

    return TenantContext(
        subscription_id=subscription_id,
        collected_at=collected_at or datetime.now(timezone.utc),
        mode="offline",
        sku_restrictions=sorted(unique.values(), key=lambda r: (r.region, r.sku)),
        existing_regions=sorted(existing_regions or []),
        allowed_locations=sorted(allowed_locations or []),
    )
