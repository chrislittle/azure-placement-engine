"""The world snapshot: pinned, versioned public facts about Azure.

A snapshot is committed to the repo rather than cached, because it is the
reproducibility guarantee — a decision record names the snapshot it was made
against, and re-running that decision must produce the same answer.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class Frozen(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


# --------------------------------------------------------------------------
# Provenance
# --------------------------------------------------------------------------


class SourceRef(Frozen):
    """Where one slice of the snapshot came from, and when.

    Held per source rather than per snapshot so partial staleness is visible —
    a snapshot whose pricing is a day old and whose latency matrix is a month
    old should say so, not average the two into a single date.
    """

    source: str = Field(description="Source id, e.g. 'arm-locations'.")
    as_of: datetime = Field(description="When the facts were collected.")
    api_version: str | None = None
    endpoint: str | None = None
    collected_via_subscription: str | None = Field(
        default=None,
        description=(
            "The ARM locations API is subscription-scoped even though the facts are public, and "
            "the visible region set can vary with offer type. Recorded so a surprising region list "
            "is traceable rather than mysterious."
        ),
    )
    notes: str | None = None


# --------------------------------------------------------------------------
# Regions
# --------------------------------------------------------------------------


class RegionType(str, Enum):
    PHYSICAL = "Physical"
    LOGICAL = "Logical"


class RegionCategory(str, Enum):
    """Azure's own classification. `Recommended` regions carry the broadest
    service coverage and availability-zone support, which is why this is a
    scored dimension rather than a coined notion of 'region maturity'."""

    RECOMMENDED = "Recommended"
    OTHER = "Other"
    EXTENDED = "Extended"


class ZoneMapping(Frozen):
    """Logical-to-physical zone mapping.

    Logical zone '1' is not the same datacentre for two different subscriptions.
    Observed in real ARM output: for `westeurope`, logical zone 1 maps to
    physical `westeurope-az3`. Anything reasoning about co-location across
    tenants has to use the physical zone, not the logical one.
    """

    logical_zone: str
    physical_zone: str


#: Suffixes Microsoft uses for internal canary and staging regions. These come
#: back from the ARM locations API looking like ordinary regions -- `eastus2euap`
#: even reports four availability zones, more than any production region -- so
#: without this they would score well and be recommended to a customer.
INTERNAL_REGION_SUFFIXES = ("stage", "stg", "euap")

#: Geography values that only ever appear on those internal regions. A secondary
#: check; the suffixes above are the primary signal.
INTERNAL_GEOGRAPHIES = frozenset({"Canary (US)", "Stage (US)", "usa", "asia"})


class Region(Frozen):
    name: str = Field(description="ARM region name, e.g. 'westeurope'.")
    display_name: str
    regional_display_name: str | None = None
    region_type: RegionType = RegionType.PHYSICAL
    region_category: RegionCategory = RegionCategory.OTHER

    geography: str | None = Field(
        default=None,
        description=(
            "Azure's data-residency geography — the boundary Microsoft actually commits to, and "
            "therefore the correct field for a residency hard filter. Its granularity varies by "
            "design: 'Germany' for germanywestcentral, but 'Europe' for westeurope, whose residency "
            "commitment genuinely is Europe-wide."
        ),
    )
    geography_group: str | None = Field(
        default=None, description="Coarser grouping, e.g. 'Europe', 'US', 'Asia Pacific'."
    )
    physical_location: str | None = Field(
        default=None,
        description=(
            "Where the datacentres actually are, e.g. 'Netherlands', 'Frankfurt'. **Informational "
            "only.** Azure's residency commitment is at `geography`, so filtering a country "
            "requirement on this field would promise something Microsoft does not."
        ),
    )
    latitude: float | None = None
    longitude: float | None = None

    paired_regions: list[str] = Field(
        default_factory=list,
        description=(
            "Azure-designated paired regions. Newer regions often have none — CAF no longer treats "
            "pairing as mandatory, so an empty list is normal, not missing data."
        ),
    )
    zones: list[ZoneMapping] = Field(default_factory=list)

    @property
    def has_availability_zones(self) -> bool:
        return len(self.zones) > 0

    @property
    def zone_count(self) -> int:
        return len(self.zones)

    @property
    def is_paired(self) -> bool:
        return len(self.paired_regions) > 0

    @property
    def is_production(self) -> bool:
        """False for Microsoft's internal canary and staging regions.

        They are returned by the ARM locations API indistinguishably from real
        ones and are never valid placement targets. Marked rather than dropped,
        so the snapshot stays a faithful record of what ARM returned and the
        engine does the excluding.
        """
        if self.geography in INTERNAL_GEOGRAPHIES:
            return False
        return not self.name.endswith(INTERNAL_REGION_SUFFIXES)

    @property
    def is_placement_candidate(self) -> bool:
        return self.region_type is RegionType.PHYSICAL and self.is_production


# --------------------------------------------------------------------------
# Snapshot
# --------------------------------------------------------------------------

SNAPSHOT_FORMAT = "placement.snapshot/v0"


class WorldSnapshot(BaseModel):
    """One pinned view of the Azure world.

    Grows a slice at a time as ingesters land: regions first, then service
    availability, capabilities, pricing, latency. Each slice carries its own
    `SourceRef`, so a half-built snapshot is usable and honest about what it
    does not yet contain.
    """

    format: str = SNAPSHOT_FORMAT
    version: str = Field(description="Snapshot version id, e.g. '2026-08-26'.")
    regions: dict[str, Region] = Field(default_factory=dict)
    sources: dict[str, SourceRef] = Field(default_factory=dict)

    model_config = ConfigDict(extra="forbid")

    # -- access ----------------------------------------------------------

    def region(self, name: str) -> Region:
        return self.regions[name]

    def physical_regions(self) -> list[Region]:
        """Logical regions (e.g. 'global') are not placement targets."""
        return [r for r in self.regions.values() if r.region_type is RegionType.PHYSICAL]

    def placement_candidates(self) -> list[Region]:
        """The only region set the engine may ever recommend from.

        Physical *and* production. Use this rather than `physical_regions()`
        anywhere a recommendation could reach a customer.
        """
        return [r for r in self.regions.values() if r.is_placement_candidate]

    def internal_regions(self) -> list[Region]:
        """Canary and staging regions, kept for transparency about what was excluded."""
        return [r for r in self.physical_regions() if not r.is_production]

    def in_geography_group(self, group: str) -> list[Region]:
        return [r for r in self.placement_candidates() if r.geography_group == group]

    def in_geography(self, geography: str) -> list[Region]:
        """Regions inside one Azure data-residency geography — the correct basis
        for a residency hard filter."""
        return [r for r in self.placement_candidates() if r.geography == geography]

    def with_zones(self, minimum: int = 3) -> list[Region]:
        return [r for r in self.placement_candidates() if r.zone_count >= minimum]

    def has(self, source: str) -> bool:
        """Whether a given slice has been ingested. The engine uses this to warn
        rather than silently score a dimension it has no data for."""
        return source in self.sources

    # -- identity --------------------------------------------------------

    def canonical(self) -> dict[str, Any]:
        return self.model_dump(mode="json", exclude_none=True)

    def digest(self) -> str:
        """Content hash, pinned into every decision record.

        Sorted keys and compact separators so the digest depends on content
        rather than serialisation order.
        """
        blob = json.dumps(self.canonical(), sort_keys=True, separators=(",", ":"))
        return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()
