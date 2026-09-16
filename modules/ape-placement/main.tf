terraform {
  # 1.9 is the floor CI gates on. Below it, `&&` and `||` short-circuiting and
  # coalesce() with empty collections behave differently.
  required_version = ">= 1.9"
}

# The decision. No resources live here: this module reads a request, the quota
# state its caller fetched, and the platform team's rules, and returns what
# should happen. Applying it is somebody else's job, which is what makes it
# testable against fixtures with no subscription.

locals {
  # First matching rule wins. A rule with no `environments` matches everything,
  # so an unconditional catch-all belongs last.
  matching_rules = [
    for r in var.rules : r
    if r.environments == null ? true : contains(r.environments, var.request.environment)
  ]
  rule           = length(local.matching_rules) > 0 ? local.matching_rules[0] : null
  rule_name      = try(local.rule.name, "(none)")
  prefer         = try(coalesce(local.rule.prefer, "most_unused"), "most_unused")
  rule_allowlist = try(local.rule.family_allowlist, null)
  rule_denylist  = try(local.rule.family_denylist, null)

  # The region-wide cap bounds every family beneath it. Ranking on family
  # unused alone invents capacity that does not exist, because family limits
  # routinely sum to many times the regional cap.
  regional_unused = max(0, var.quota.regional_cores_limit - var.quota.regional_cores_used)

  # Candidates, narrowed in order: what the request asked for, then what the
  # rule permits.
  # Region access is the outermost gate -- ahead of lifecycle, access and quota,
  # because none of those mean anything in a region the subscription cannot
  # reach. Compute usages answers NoRegisteredProviderFound there, while
  # Microsoft.Compute/skus returns a full, unrestricted-looking catalogue: 796
  # of 866 VM SKUs in Germany North report no restriction whatsoever for a
  # subscription that cannot deploy there.
  region_accessible   = coalesce(try(var.quota.region_accessible, null), true)
  provider_registered = coalesce(try(var.quota.provider_registered, null), true)

  wanted_category = try(var.request.category, null)

  # Attribute filters. A null means "do not filter on this".
  want_arch         = try(var.request.architecture, null)
  want_burstable    = try(var.request.burstable, null)
  want_confidential = try(var.request.confidential_computing, null)

  attribute_matched = sort([
    for f, d in var.quota.families : f
    if(local.wanted_category == null || d.category == local.wanted_category)
    && (local.want_arch == null ? true : contains(try(d.architectures, []), local.want_arch))
    && (local.want_burstable == null || coalesce(d.burstable, false) == (local.want_burstable == "Required"))
    && (local.want_confidential == null || coalesce(d.confidential_computing, false) == (local.want_confidential == "Required"))
  ])

  filtering_on_attributes = local.wanted_category != null || local.want_arch != null || local.want_burstable != null || local.want_confidential != null

  # Narrowed most-specific first: an exact family, then a platform allowlist,
  # then the customer's workload class, then everything.
  requested_families = (
    var.request.family != null ? [var.request.family] :
    var.request.family_allowlist != null ? var.request.family_allowlist :
    local.filtering_on_attributes ? local.attribute_matched :
    sort(keys(var.quota.families))
  )

  # A class that matches nothing is worth saying out loud -- it means the quota
  # holds no quota for that kind of workload in this region, which is a
  # different problem from every candidate being blocked.
  class_unmatched = local.filtering_on_attributes && length(local.attribute_matched) == 0

  # Iterate the rule's allowlist rather than filtering by it, so its order
  # survives the intersection. `prefer = "listed_order"` is set on the rule, so
  # "listed" has to mean the order the rule listed -- filtering the other way
  # round silently substitutes whatever order the quota happened to enumerate in.
  rule_allowed = (
    local.rule_allowlist == null
    ? local.requested_families
    : [for f in local.rule_allowlist : f if contains(local.requested_families, f)]
  )

  rule_permitted = (
    local.rule_denylist == null
    ? local.rule_allowed
    : [for f in local.rule_allowed : f if !contains(local.rule_denylist, f)]
  )

  # A family the quota has never heard of cannot be reasoned about. Kept
  # separately so the decision can say so rather than silently dropping it.
  unknown_families = [for f in local.rule_permitted : f if !contains(keys(var.quota.families), f)]
  known_families   = [for f in local.rule_permitted : f if contains(keys(var.quota.families), f)]

  # --- Lifecycle gate ---------------------------------------------------
  #
  # The July 2026 capacity growth restrictions are not a preference and not a
  # retirement -- they are a hard eligibility rule whose answer differs by
  # whether the subscription is new:
  #
  #   new subscription        cannot deploy a restricted series AT ALL
  #   existing, within quota  fine
  #   existing, needs more    refused; this is the 400 DeprecatedQuotaType
  #
  # So a restricted family can serve a request that fits existing unused and
  # can never serve one that needs an increase. The module already draws that
  # line, so the rule lands exactly on it.

  new_subscription = coalesce(try(var.request.new_subscription, null), true)

  lifecycle_of = { for f, d in var.quota.families : f => coalesce(d.lifecycle, "current") }

  frozen_families = [for f, l in local.lifecycle_of : f if l == "growth_restricted"]

  # Denied outright: a new subscription cannot touch these at all.
  lifecycle_denied = !local.new_subscription ? [] : [
    for f in local.known_families : f if local.lifecycle_of[f] == "growth_restricted"
  ]

  lifecycle_permitted = [
    for f in local.known_families : f if !contains(local.lifecycle_denied, f)
  ]

  # --- Access gate -------------------------------------------------------
  #
  # Checked before quota, and kept separate from it. Quota groups explicitly do
  # not grant regional or zonal access, so these two gates fail independently
  # and have different remedies: a quota shortfall is an allocation, an access
  # gap is a support request with lead time.
  #
  # APE does not close access gaps. It refuses to allocate against them and
  # says what would lift them.

  placement_type = coalesce(try(var.request.placement.type, null), "regional")
  wanted_zones   = coalesce(try(var.request.placement.zones, null), [])
  wanted_zone_count = (
    local.placement_type == "zone_redundant"
    ? coalesce(try(var.request.placement.zone_count, null), 3)
    : 0
  )

  access_checked = length(keys(var.sku_access)) > 0

  # effective = published MINUS restricted, and nothing at all when the size is
  # restricted at Location level. The subtraction lives here rather than in the
  # caller because getting it wrong is the whole failure mode.
  size_access = {
    for f, fa in var.sku_access : f => [
      for name, sz in fa.sizes : {
        name   = name
        reason = sz.restriction_reason
        effective_zones = sz.location_restricted ? [] : sort(tolist(setsubtract(
          toset(try(sz.zones, [])),
          toset(try(sz.restricted_zones, [])),
        )))
        location_restricted = sz.location_restricted
      }
    ]
  }

  # Some regions have no availability zones at all. Telling someone to raise a
  # zone access request for one of those sends them after a ticket that cannot
  # be fulfilled -- West Central US reports 916 VM SKUs and not a single zone.
  # Computed from PUBLISHED zones, not effective ones. Whether a region has
  # availability zones is a property of the region; whether this subscription
  # may use them is a restriction on top. Deriving it from effective zones made
  # a perfectly zonal region look non-zonal as soon as every family examined was
  # fully restricted -- and then told the customer no ticket could help, which
  # is the opposite of the truth.
  region_zonal = anytrue(flatten([
    for f, sizes in var.sku_access : [
      for name, sz in sizes.sizes : length(try(sz.zones, [])) > 0
    ]
  ]))

  zonal_request = local.placement_type != "regional"

  # A family is deployable if at least ONE of its sizes satisfies the placement
  # type -- customers buy a family's worth of quota but deploy a specific size.
  #
  # CONFIRMED by deployment on 2026-09-16, not merely inferred: a Zone-type
  # restriction blocks zonal deployment and leaves regional deployment
  # available. Standard_DS1 in eastus, all published zones restricted -- a
  # zonal PUT returned SkuNotAvailable, a regional PUT was accepted.
  # See knowledge/zone-restrictions.yaml.
  family_deployable = {
    for f, sizes in local.size_access : f => (
      local.placement_type == "regional"
      ? length([for sz in sizes : sz if !sz.location_restricted]) > 0
      : local.placement_type == "zonal"
      ? length([for sz in sizes : sz if length(setsubtract(toset(local.wanted_zones), toset(sz.effective_zones))) == 0]) > 0
      : length([for sz in sizes : sz if length(sz.effective_zones) >= local.wanted_zone_count]) > 0
    )
  }

  # QuotaId means the subscription's offer excludes the SKU and no support
  # ticket will change it. NotAvailableForSubscription is an entitlement gap and
  # is requestable. Reporting the first as requestable wastes the customer's time.
  family_reasons = {
    for f, sizes in local.size_access : f => distinct(compact([for sz in sizes : sz.reason]))
  }

  # A family absent from the region's SKU data is not merely unverified -- it
  # is not offered. Microsoft.Compute/skus lists every SKU Azure has in the
  # region INCLUDING the restricted ones, so absence means there are no sizes
  # to deploy at all.
  #
  # Quota for such a family still exists and reads perfectly normally. On a
  # live subscription, 14 of 97 families holding quota in East US had no SKUs
  # there -- NC v1, H, basicA, the Promo families -- and treating absence as
  # "unknown but allowed" let the module rank and CHOOSE one of them.
  not_offered = !local.access_checked ? [] : [
    for f in local.lifecycle_permitted : f if !contains(keys(local.size_access), f)
  ]

  # try() rather than a contains() guard: `&&` does not short-circuit, so the
  # index is evaluated even when the family is absent from the SKU data.
  # Absent means not offered, which is neither permitted nor denied -- it is
  # reported separately as not_offered.
  access_permitted = !local.access_checked ? local.lifecycle_permitted : [
    for f in local.lifecycle_permitted : f if try(local.family_deployable[f], false)
  ]

  access_denied = !local.access_checked ? [] : [
    for f in local.lifecycle_permitted : f if !try(local.family_deployable[f], true)
  ]

  # Only meaningful when the check was skipped entirely. With SKU data present,
  # nothing is unverified -- a family is offered and assessed, or it is not
  # offered.
  access_unverified = local.access_checked ? [] : local.lifecycle_permitted

  # Per-family arithmetic.
  #
  #   unused  -- deployable right now, with no quota change at all
  #   allocatable -- what the quota could add on top. A null `available` means
  #                there is no quota behind this subscription, so nothing is
  #                proven; it is deliberately NOT treated as unlimited.
  assessed = [
    for f in local.access_permitted : {
      family          = f
      limit           = var.quota.families[f].limit
      used            = var.quota.families[f].used
      unused          = max(0, var.quota.families[f].limit - var.quota.families[f].used)
      allocatable     = var.quota.families[f].available == null ? 0 : max(0, var.quota.families[f].available)
      has_group_quota = var.quota.families[f].available != null
    }
  ]

  # Ceiling on what any single family can deliver, whatever its own numbers say.
  reachable = [
    for a in local.assessed : merge(a, {
      # Quota above the regional cap is unusable, so cap the claim there.
      reachable_vcpus           = min(a.unused + a.allocatable, local.regional_unused + a.allocatable)
      satisfied_now             = a.unused >= var.request.vcpus
      satisfied_with_allocation = (a.unused + a.allocatable) >= var.request.vcpus
    })
  ]

  rule_cap = try(local.rule.max_vcpus, null)
  # A conditional, not `&&`: Terraform type checks both sides of `&&`, so
  # comparing against a null rule_cap fails even when the guard is false.
  over_rule_cap = local.rule_cap == null ? false : var.request.vcpus > local.rule_cap

  # A growth-restricted family on an existing subscription is usable only
  # within quota it already has. Quota increases for these are refused, so an
  # ask that needs one is infeasible on that family however much unused the
  # quota reports.
  eligible = local.over_rule_cap ? [] : [
    for r in local.reachable : r
    if r.satisfied_with_allocation && (local.lifecycle_of[r.family] != "growth_restricted" || r.satisfied_now)
  ]

  # Ranking. HCL has no sort-by-key, so the sort key is padded into the string
  # and split back off.
  #
  # The unused is INVERTED for most_unused rather than reversing the sorted
  # list, so the tiebreak stays ascending by family name either way. Reversing
  # the whole list reversed the name order too, which made the result differ
  # from the PowerShell implementation whenever two families had equal unused.
  ranked_keys = (
    local.prefer == "listed_order"
    ? [for f in local.rule_permitted : f if contains([for e in local.eligible : e.family], f)]
    : [
      for s in sort([
        for e in local.eligible : format(
          "%09d|%s",
          local.prefer == "most_unused" ? 999999999 - (e.unused + e.allocatable) : e.unused + e.allocatable,
          e.family,
        )
      ]) : split("|", s)[1]
    ]
  )

  chosen        = length(local.ranked_keys) > 0 ? local.ranked_keys[0] : null
  chosen_detail = local.chosen == null ? null : one([for e in local.eligible : e if e.family == local.chosen])

  # `limit` is absolute in Microsoft.Quota, never a delta, so the target is a
  # value not an increment -- and never below what is already there, or a
  # placement would quietly shrink someone's quota.
  target_limit = local.chosen_detail == null ? null : max(
    local.chosen_detail.limit,
    local.chosen_detail.used + var.request.vcpus,
  )

  regional_increase_required = var.request.vcpus > local.regional_unused
  regional_target = max(
    var.quota.regional_cores_limit,
    var.quota.regional_cores_used + var.request.vcpus,
  )

  # Whether the request can be met without asking Azure for anything new, and
  # therefore whether the answer can be relied on. A request needing a limit
  # increase is not a promise: increases are evaluated and can be refused when
  # regional capacity is short.
  all_blocked_by_lifecycle = length(local.lifecycle_permitted) == 0 && length(local.lifecycle_denied) > 0

  suggested_successors = distinct(flatten([
    for f in local.lifecycle_denied : try(var.quota.families[f].successors, [])
  ]))

  all_blocked_by_access = local.access_checked && length(local.access_permitted) == 0 && (length(local.access_denied) > 0 || length(local.not_offered) > 0)

  status = (
    !local.provider_registered ? "not_ready" :
    !local.region_accessible ? "blocked_by_region" :
    local.class_unmatched ? "infeasible" :
    local.over_rule_cap ? "blocked_by_rule" :
    local.all_blocked_by_lifecycle ? "blocked_by_lifecycle" :
    local.all_blocked_by_access ? "blocked_by_access" :
    local.chosen == null ? "infeasible" :
    local.chosen_detail.satisfied_now && !local.regional_increase_required ? "satisfied" :
    local.chosen_detail.has_group_quota && !local.regional_increase_required ? "needs_allocation" :
    "needs_increase"
  )

  # Whether an access gap is worth raising a ticket over, or is simply final.
  # Nothing to request when the region simply has no zones.
  requestable = (
    local.zonal_request && local.access_checked && !local.region_zonal
    ? false
    : contains(flatten([for f in local.access_denied : local.family_reasons[f]]), "NotAvailableForSubscription")
  )

  # The three access requests are different tickets with different forms, so
  # naming the wrong one sends someone down the wrong queue. A denial where
  # every size is Location-restricted is about the region or the SKU; anything
  # else is about zones.
  denied_by_location = length(local.access_denied) > 0 && alltrue([
    for f in local.access_denied : alltrue([for sz in local.size_access[f] : sz.location_restricted])
  ])

  reason = (
    !local.provider_registered ? "Microsoft.Compute is not registered on this subscription yet; this resolves on its own shortly after vending and is not an access problem" :
    !local.region_accessible ? format(
      "the subscription has no access to %s; this needs a region access request and no amount of quota will help",
      var.request.region,
    ) :
    local.class_unmatched ? format(
      "the subscription holds no quota in %s matching %s",
      var.request.region,
      join(", ", compact([
        local.wanted_category,
        local.want_arch,
        local.want_burstable == null ? "" : "burstable ${local.want_burstable}",
        local.want_confidential == null ? "" : "confidential ${local.want_confidential}",
      ])),
    ) :
    local.over_rule_cap ? format("rule %q caps requests at %d vCPUs", local.rule_name, local.rule_cap) :
    local.all_blocked_by_lifecycle ? format(
      "every candidate family is under the capacity growth restriction, which a new subscription cannot deploy at all%s",
      length(local.suggested_successors) > 0 ? format("; use %s instead", join(", ", local.suggested_successors)) : "",
    ) :
    local.all_blocked_by_access && local.zonal_request && !local.region_zonal ? format(
      "%s has no availability zones, so a %s placement is impossible there -- deploy regionally or choose a zonal region",
      var.request.region,
      local.placement_type == "zonal" ? "zonal" : "zone-redundant",
    ) :
    local.all_blocked_by_access && length(local.access_denied) == 0 ? format(
      "no candidate family is offered in %s; quota for them exists but Azure has no sizes to deploy there",
      var.request.region,
    ) :
    local.all_blocked_by_access ? format(
      "no candidate family has %s access on this subscription; %s",
      local.placement_type == "regional" ? "regional" : "zonal",
      local.requestable ? "requestable via a SKU access request" : "the subscription offer excludes it, which no support ticket will change",
    ) :
    length(local.known_families) == 0 ? "no candidate family is present in the quota" :
    local.chosen == null ? format("no candidate family can reach %d vCPUs", var.request.vcpus) :
    local.status == "satisfied" ? "existing quota covers the request" :
    local.status == "needs_allocation" ? "the quota can cover the shortfall without a limit increase" :
    "a quota limit increase is required, and increases are evaluated rather than granted"
  )
}
