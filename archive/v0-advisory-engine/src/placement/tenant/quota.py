"""Extract vCPU quota from `Microsoft.Compute/locations/{region}/usages`.

Quota is the constraint that most often turns an apparently fine region into a
failed deployment, and GPU families are the worst case: on a live subscription,
**22 of 28 GPU families reported a limit of zero** in West Europe. Ordinary
families do too on a subscription with no history.

So an absent SKU restriction says nothing on its own. Access and quota are
separate gates with separate remedies — you cannot raise quota in a region you
have no entitlement to, and entitlement does not grant you cores.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from placement.tenant.model import QuotaEntry, normalise_family

ENDPOINT = (
    "https://management.azure.com/subscriptions/{subscription_id}"
    "/providers/Microsoft.Compute/locations/{location}/usages"
)
API_VERSION = "2021-07-01"

#: Regional totals rather than a VM family. Kept, because a per-family quota is
#: useless if the regional core cap is already exhausted, but flagged so callers
#: do not mistake them for families.
REGIONAL_TOTALS = {"cores", "lowprioritycores", "virtualmachines", "virtualmachinescalesets"}


class QuotaError(ValueError):
    pass


def parse_usages(payload: dict[str, Any], region: str) -> list[QuotaEntry]:
    """Parse one region's usages response."""
    if not isinstance(payload, dict) or "value" not in payload:
        raise QuotaError("expected a Compute usages response with a `value` array")

    entries: list[QuotaEntry] = []
    for item in payload["value"]:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or {}
        raw = name.get("value") if isinstance(name, dict) else None
        if not raw:
            continue

        limit = item.get("limit")
        if not isinstance(limit, (int, float)):
            continue

        entries.append(
            QuotaEntry(
                family=normalise_family(raw),
                display_name=(name.get("localizedValue") if isinstance(name, dict) else None) or raw,
                region=region,
                limit=int(limit),
                current=int(item.get("currentValue") or 0),
            )
        )
    return entries


def collect(per_region: dict[str, dict[str, Any]]) -> tuple[list[QuotaEntry], list[str]]:
    """Parse many regions, returning entries and the regions that failed.

    Failures are returned rather than swallowed: a region with no quota entries
    is indistinguishable from a region with zero quota everywhere, and those mean
    opposite things.
    """
    entries: list[QuotaEntry] = []
    failures: list[str] = []

    for region, payload in sorted(per_region.items()):
        try:
            entries.extend(parse_usages(payload, region))
        except QuotaError:
            failures.append(region)

    return entries, failures


def regional_core_limit(entries: list[QuotaEntry], region: str) -> QuotaEntry | None:
    """The region-wide vCPU cap, which bounds every family beneath it."""
    for entry in entries:
        if entry.region == region and entry.family == "cores":
            return entry
    return None
