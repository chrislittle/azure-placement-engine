# The decision. No resources live here: this module reads a request, the pool
# state its caller fetched, and the platform team's rules, and returns what
# should happen. Applying it is somebody else's job, which is what makes it
# testable against fixtures with no subscription.

locals {
  # First matching rule wins. A rule with no `environments` matches everything,
  # so an unconditional catch-all belongs last.
  matching_rules = [
    for r in var.rules : r
    if r.environments == null || contains(r.environments, var.request.environment)
  ]
  rule      = length(local.matching_rules) > 0 ? local.matching_rules[0] : null
  rule_name = local.rule == null ? "(none)" : local.rule.name
  prefer    = local.rule == null ? "most_headroom" : coalesce(local.rule.prefer, "most_headroom")

  # The region-wide cap bounds every family beneath it. Ranking on family
  # headroom alone invents capacity that does not exist, because family limits
  # routinely sum to many times the regional cap.
  regional_headroom = max(0, var.pool.regional_cores_limit - var.pool.regional_cores_used)

  # Candidates, narrowed in order: what the request asked for, then what the
  # rule permits.
  requested_families = (
    var.request.family != null ? [var.request.family] :
    var.request.family_allowlist != null ? var.request.family_allowlist :
    sort(keys(var.pool.families))
  )

  # Iterate the rule's allowlist rather than filtering by it, so its order
  # survives the intersection. `prefer = "listed_order"` is set on the rule, so
  # "listed" has to mean the order the rule listed -- filtering the other way
  # round silently substitutes whatever order the pool happened to enumerate in.
  rule_allowed = (
    local.rule == null || local.rule.family_allowlist == null
    ? local.requested_families
    : [for f in local.rule.family_allowlist : f if contains(local.requested_families, f)]
  )

  rule_permitted = (
    local.rule == null || local.rule.family_denylist == null
    ? local.rule_allowed
    : [for f in local.rule_allowed : f if !contains(local.rule.family_denylist, f)]
  )

  # A family the pool has never heard of cannot be reasoned about. Kept
  # separately so the decision can say so rather than silently dropping it.
  unknown_families = [for f in local.rule_permitted : f if !contains(keys(var.pool.families), f)]
  known_families   = [for f in local.rule_permitted : f if contains(keys(var.pool.families), f)]

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
          toset(coalesce(sz.zones, [])),
          toset(coalesce(sz.restricted_zones, [])),
        )))
        location_restricted = sz.location_restricted
      }
    ]
  }

  # A family is deployable if at least ONE of its sizes satisfies the placement
  # type -- customers buy a family's worth of quota but deploy a specific size.
  #
  # ASSUMPTION, not documented by Microsoft: a Zone-type restriction blocks
  # zonal deployment but leaves regional deployment available, which is why the
  # API distinguishes Zone from Location at all. If that turns out false, the
  # regional branch below is the line to change. See knowledge/zone-restrictions.yaml.
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

  access_permitted = !local.access_checked ? local.known_families : [
    for f in local.known_families : f
    if !contains(keys(local.size_access), f) || local.family_deployable[f]
  ]

  access_denied = !local.access_checked ? [] : [
    for f in local.known_families : f
    if contains(keys(local.size_access), f) && !local.family_deployable[f]
  ]

  # Present in the pool, absent from the SKU data. Permitted, but never
  # reported as verified -- silence is not evidence of access.
  access_unverified = !local.access_checked ? local.known_families : [
    for f in local.known_families : f if !contains(keys(local.size_access), f)
  ]

  # Per-family arithmetic.
  #
  #   headroom  -- deployable right now, with no quota change at all
  #   grantable -- what the pool could add on top. A null `available` means
  #                there is no pool behind this subscription, so nothing is
  #                proven; it is deliberately NOT treated as unlimited.
  assessed = [
    for f in local.access_permitted : {
      family    = f
      limit     = var.pool.families[f].limit
      used      = var.pool.families[f].used
      headroom  = max(0, var.pool.families[f].limit - var.pool.families[f].used)
      grantable = var.pool.families[f].available == null ? 0 : max(0, var.pool.families[f].available)
      pooled    = var.pool.families[f].available != null
    }
  ]

  # Ceiling on what any single family can deliver, whatever its own numbers say.
  reachable = [
    for a in local.assessed : merge(a, {
      # Quota above the regional cap is unusable, so cap the claim there.
      reachable_vcpus = min(a.headroom + a.grantable, local.regional_headroom + a.grantable)
      satisfied_now   = a.headroom >= var.request.vcpus
      satisfied_pool  = (a.headroom + a.grantable) >= var.request.vcpus
    })
  ]

  rule_cap      = local.rule == null ? null : local.rule.max_vcpus
  over_rule_cap = local.rule_cap != null && var.request.vcpus > local.rule_cap

  eligible = local.over_rule_cap ? [] : [for r in local.reachable : r if r.satisfied_pool]

  # Ranking. HCL has no sort-by-key, so pad the sort key into the string and
  # split it back off.
  ranked_keys = (
    local.prefer == "listed_order"
    ? [for f in local.rule_permitted : f if contains([for e in local.eligible : e.family], f)]
    : [
      for s in(local.prefer == "most_headroom"
        ? reverse(sort([for e in local.eligible : format("%09d|%s", e.headroom + e.grantable, e.family)]))
        : sort([for e in local.eligible : format("%09d|%s", e.headroom + e.grantable, e.family)])
      ) : split("|", s)[1]
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

  regional_increase_required = var.request.vcpus > local.regional_headroom
  regional_target = max(
    var.pool.regional_cores_limit,
    var.pool.regional_cores_used + var.request.vcpus,
  )

  # Whether the request can be met without asking Azure for anything new, and
  # therefore whether the answer can be relied on. A request needing a limit
  # increase is not a promise: increases are evaluated and can be refused when
  # regional capacity is short.
  all_blocked_by_access = local.access_checked && length(local.access_permitted) == 0 && length(local.access_denied) > 0

  status = (
    local.over_rule_cap ? "blocked_by_rule" :
    local.all_blocked_by_access ? "blocked_by_access" :
    local.chosen == null ? "infeasible" :
    local.chosen_detail.satisfied_now && !local.regional_increase_required ? "satisfied" :
    local.chosen_detail.pooled && !local.regional_increase_required ? "needs_allocation" :
    "needs_increase"
  )

  # Whether an access gap is worth raising a ticket over, or is simply final.
  requestable = contains(flatten([for f in local.access_denied : local.family_reasons[f]]), "NotAvailableForSubscription")

  reason = (
    local.over_rule_cap ? format("rule %q caps requests at %d vCPUs", local.rule_name, local.rule_cap) :
    local.all_blocked_by_access ? format(
      "no candidate family has %s access on this subscription; %s",
      local.placement_type == "regional" ? "regional" : "zonal",
      local.requestable ? "requestable via a SKU access request" : "the subscription offer excludes it, which no support ticket will change",
    ) :
    length(local.known_families) == 0 ? "no candidate family is present in the pool" :
    local.chosen == null ? format("no candidate family can reach %d vCPUs", var.request.vcpus) :
    local.status == "satisfied" ? "existing quota covers the request" :
    local.status == "needs_allocation" ? "the pool can cover the shortfall without a limit increase" :
    "a quota limit increase is required, and increases are evaluated rather than granted"
  )
}
