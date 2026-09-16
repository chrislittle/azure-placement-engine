output "decision" {
  description = <<-EOT
    The placement decision, and enough of the reasoning to argue with it.

    `status` is the load-bearing field:

      satisfied        existing quota already covers the request; no writes
      needs_allocation the pool can cover the shortfall; allocation is
                       self-service and will succeed
      needs_increase   a quota limit increase is required. Increases are
                       evaluated, not granted, and are refused when regional
                       capacity is short -- so this is NOT a promise
      blocked_by_rule  a business rule refused the request
      blocked_by_lifecycle every candidate is under the July 2026 capacity
                       growth restriction, which a NEW subscription cannot
                       deploy at all. Successors are named in the reason
      blocked_by_access no candidate family can deploy here at all. A quota
                       allocation would not help; this needs a SKU or region
                       access request, or is final if the offer excludes it
      infeasible       no candidate family can reach the requested size
  EOT

  value = {
    status = local.status
    reason = local.reason

    region = var.request.region
    vcpus  = var.request.vcpus
    family = local.chosen

    # Absolute, matching Microsoft.Quota semantics -- the value to write, not
    # an increment. Null when there is nothing to write.
    target_limit = local.target_limit

    # The regional vCPU cap is a separate gate from the family limit and has to
    # be raised separately when it binds.
    regional = {
      limit             = var.pool.regional_cores_limit
      used              = var.pool.regional_cores_used
      headroom          = local.regional_headroom
      increase_required = local.regional_increase_required
      target            = local.regional_increase_required ? local.regional_target : var.pool.regional_cores_limit
    }

    # The capacity growth restrictions. Not a retirement -- most affected
    # series remain fully supported under SLA; they just cannot grow.
    lifecycle = {
      new_subscription = local.new_subscription
      denied           = local.lifecycle_denied
      successors       = local.suggested_successors
      # Families usable only within the quota they already hold. Relevant to an
      # existing subscription, and fatal to a request that needs an increase.
      frozen = [for f in local.access_permitted : f if local.lifecycle_of[f] == "growth_restricted"]
    }

    # Access is a gate in its own right, and APE only reports on it -- closing
    # an access gap is a support request, not something a module can do.
    access = {
      checked   = local.access_checked
      verified  = local.access_checked && local.chosen != null
      placement = local.placement_type
      # False means the region has no availability zones at all, which no
      # access request can change.
      region_zonal = !local.access_checked ? null : local.region_zonal
      zones        = local.placement_type == "zonal" ? local.wanted_zones : []
      zone_count   = local.wanted_zone_count
      denied       = local.access_denied
      unverified   = local.access_unverified
      # Quota exists, but Azure offers no sizes of the family in this region.
      # Not a permissions problem and not fixable by a support ticket.
      not_offered = local.not_offered
      requestable = local.requestable
      # Portal path for both: Help + support -> Create a support request ->
      # Service and subscription limits (quotas) -> Compute-VM (cores-vCPUs).
      remediation = local.zonal_request && local.access_checked && !local.region_zonal ? format(
        "%s has no availability zones. Deploy regionally, or pick a region that has them -- there is no ticket for this.",
        var.request.region,
        ) : length(local.access_denied) == 0 ? null : (
        !local.requestable
        ? "QuotaId: the subscription offer excludes these SKUs. No support ticket will lift this -- choose a different family."
        : local.denied_by_location
        ? "Raise a region or SKU access request (quota type: Compute-VM subscription limit increases) for the denied families."
        : "Raise a zonal enablement request (quota type: Compute-VM, then Zone access) for the denied zones. Regional placement of the same families is unaffected."
      )
    }

    rule_applied = local.rule_name
    preference   = local.prefer

    # Why every other family lost. This is most of the value: a placement that
    # cannot say why it rejected the alternatives is not auditable.
    considered = [
      for r in local.reachable : {
        family    = r.family
        limit     = r.limit
        used      = r.used
        headroom  = r.headroom
        grantable = r.grantable
        outcome = (
          r.family == local.chosen ? "chosen" :
          !r.satisfied_pool ? format("short by %d vCPUs", var.request.vcpus - (r.headroom + r.grantable)) :
          "eligible, outranked"
        )
      }
    ]

    # Named but absent from the pool. Usually a typo or a family this
    # subscription has never been offered; either way it is not a silent drop.
    unknown_families = local.unknown_families
  }
}

output "writes_required" {
  description = <<-EOT
    What the apply layer should write, or an empty list when nothing is needed.
    Ordered: the regional cap first, since a family limit above it is unusable.

    Only differences appear. A family whose limit already covers the request is
    omitted even when the regional cap still has to be raised, so the apply
    layer never issues a PATCH that changes nothing.
  EOT

  value = local.chosen == null ? [] : concat(
    local.regional_increase_required ? [{
      scope = "regional"
      name  = "cores"
      limit = local.regional_target
    }] : [],
    local.target_limit > local.chosen_detail.limit ? [{
      scope = "family"
      name  = local.chosen
      limit = local.target_limit
    }] : [],
  )
}
