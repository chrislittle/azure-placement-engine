# Projection. The subtractions and classifications live in ape-placement where
# they are tested; this file only reshapes what Azure returned.

locals {
  # --- quota ---------------------------------------------------------------
  raw_usages = try(data.azapi_resource_action.usages[0].output.value, [])

  usage_entries = [
    for u in local.raw_usages : {
      name  = try(u.name.value, "")
      limit = tonumber(try(u.limit, 0))
      used  = tonumber(try(u.currentValue, 0))
    }
  ]

  regional_cores = one([for u in local.usage_entries : u if lower(u.name) == "cores"])

  # Families reporting a limit of zero are omitted: absent is not the same as
  # unavailable, and a zero-limit family is not a candidate.
  quota_families = {
    for u in local.usage_entries : u.name => { limit = u.limit, used = u.used }
    if endswith(lower(u.name), "family") && u.limit > 0
  }

  # --- curated knowledge ---------------------------------------------------
  # `file()` resolves against the ROOT module's directory, so the path has to be
  # anchored on path.module or it breaks the moment anyone calls this from
  # elsewhere.
  knowledge = coalesce(var.knowledge_dir, "${path.module}/../../knowledge")

  lifecycle_doc = yamldecode(file("${local.knowledge}/vm-series-lifecycle.yaml"))
  growth_restricted = toset(flatten([
    for _, families in try(local.lifecycle_doc.growth_restricted_families, {}) : families
  ]))

  # --- SKUs ----------------------------------------------------------------
  raw_skus = try(data.azapi_resource_list.skus[0].output.value, [])

  vm_skus = [
    for s in local.raw_skus : {
      name   = s.name
      family = try(s.family, "")
      zones  = sort(distinct(flatten([for li in try(s.locationInfo, []) : try(li.zones, [])])))
      restricted_zones = sort(distinct(flatten([
        for r in try(s.restrictions, []) : try(r.restrictionInfo.zones, []) if try(r.type, "") == "Zone"
      ])))
      location_restricted = anytrue([for r in try(s.restrictions, []) : try(r.type, "") != "Zone"])
      restriction_reason  = try(s.restrictions[0].reasonCode, null)
      memory              = tonumber(try([for c in s.capabilities : c.value if c.name == "MemoryGB"][0], 0))
      vcpus               = tonumber(try([for c in s.capabilities : c.value if c.name == "vCPUs"][0], 0))
      gpus                = tonumber(try([for c in s.capabilities : c.value if c.name == "GPUs"][0], 0))
    }
    if try(s.resourceType, "") == "virtualMachines" && try(s.family, "") != ""
  ]

  vm_families = distinct([for s in local.vm_skus : s.family])

  sku_access = {
    for f in local.vm_families : f => {
      sizes = {
        for s in local.vm_skus : s.name => {
          zones               = s.zones
          restricted_zones    = s.restricted_zones
          location_restricted = s.location_restricted
          restriction_reason  = s.restriction_reason
        } if s.family == f
      }
    }
  }

  # --- workload class ------------------------------------------------------
  # Mirrors knowledge/vm-series-classes.yaml. Sorted as zero-padded strings
  # because HCL has no median; the middle element of the sorted list is it.
  classes_doc     = yamldecode(file("${local.knowledge}/vm-series-classes.yaml"))
  class_overrides = try(local.classes_doc.overrides, {})

  family_ratios = {
    for f in local.vm_families : f => sort([
      for s in local.vm_skus : format("%09.3f", s.memory / max(s.vcpus, 1))
      if s.family == f && s.vcpus > 0
    ])
  }

  family_gpu = {
    for f in local.vm_families : f => anytrue([for s in local.vm_skus : s.gpus > 0 if s.family == f])
  }

  family_override = {
    for f in local.vm_families : f => try([
      for name, pattern in local.class_overrides : name
      if length(regexall("(?i)${pattern}", f)) > 0
    ][0], null)
  }

  family_class = {
    for f in local.vm_families : f => (
      local.family_override[f] != null ? local.family_override[f] :
      local.family_gpu[f] ? "gpu" :
      length(local.family_ratios[f]) == 0 ? null :
      tonumber(local.family_ratios[f][floor(length(local.family_ratios[f]) / 2)]) < 3 ? "compute_optimized" :
      tonumber(local.family_ratios[f][floor(length(local.family_ratios[f]) / 2)]) <= 6 ? "general_purpose" :
      "memory_optimized"
    )
  }

  pool = {
    region_accessible    = local.region_accessible
    provider_registered  = local.provider_registered
    regional_cores_limit = try(local.regional_cores.limit, 0)
    regional_cores_used  = try(local.regional_cores.used, 0)
    families = {
      for f, q in local.quota_families : f => {
        limit     = q.limit
        used      = q.used
        class     = try(local.family_class[f], null)
        lifecycle = contains(local.growth_restricted, f) ? "growth_restricted" : "current"
      }
    }
  }
}
