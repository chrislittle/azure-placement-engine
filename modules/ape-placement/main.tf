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

  # Per-family arithmetic.
  #
  #   headroom  -- deployable right now, with no quota change at all
  #   grantable -- what the pool could add on top. A null `available` means
  #                there is no pool behind this subscription, so nothing is
  #                proven; it is deliberately NOT treated as unlimited.
  assessed = [
    for f in local.known_families : {
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
  status = (
    local.over_rule_cap ? "blocked_by_rule" :
    local.chosen == null ? "infeasible" :
    local.chosen_detail.satisfied_now && !local.regional_increase_required ? "satisfied" :
    local.chosen_detail.pooled && !local.regional_increase_required ? "needs_allocation" :
    "needs_increase"
  )

  reason = (
    local.over_rule_cap ? format("rule %q caps requests at %d vCPUs", local.rule_name, local.rule_cap) :
    length(local.known_families) == 0 ? "no candidate family is present in the pool" :
    local.chosen == null ? format("no candidate family can reach %d vCPUs", var.request.vcpus) :
    local.status == "satisfied" ? "existing quota covers the request" :
    local.status == "needs_allocation" ? "the pool can cover the shortfall without a limit increase" :
    "a quota limit increase is required, and increases are evaluated rather than granted"
  )
}
