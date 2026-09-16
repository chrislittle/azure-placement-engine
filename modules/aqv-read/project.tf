# Projection. The subtractions and classifications live in aqv-decide where
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
      rdma                = lower(try([for c in s.capabilities : c.value if c.name == "RdmaEnabled"][0], "false")) == "true"
      confidential        = try([for c in s.capabilities : c.value if c.name == "ConfidentialComputingType"][0], "") != ""
      architecture        = try([for c in s.capabilities : c.value if c.name == "CpuArchitectureType"][0], null)
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

          # The workload team deploys a SIZE, not a family, so the size
          # carries its own vCPU count through to the decision.
          vcpus = s.vcpus
        } if s.family == f
      }
    }
  }

  # --- category and attributes ---------------------------------------------
  # Categories are Azure Compute Fleet's vmCategories names; see
  # knowledge/vm-series-classes.yaml for the rules and why the order matters.
  # Ratios are sorted as zero-padded strings because HCL has no median -- the
  # middle element of the sorted list is it.
  family_ratios = {
    for f in local.vm_families : f => sort([
      for s in local.vm_skus : format("%09.3f", s.memory / max(s.vcpus, 1))
      if s.family == f && s.vcpus > 0
    ])
  }

  family_gpu = {
    for f in local.vm_families : f => anytrue([for s in local.vm_skus : s.gpus > 0 if s.family == f])
  }
  family_rdma = {
    for f in local.vm_families : f => anytrue([for s in local.vm_skus : s.rdma if s.family == f])
  }
  family_confidential = {
    for f in local.vm_families : f => anytrue([for s in local.vm_skus : s.confidential if s.family == f])
  }
  family_architectures = {
    for f in local.vm_families : f => sort(distinct(compact([
      for s in local.vm_skus : try(s.architecture, "") if s.family == f
    ])))
  }

  family_category = {
    for f in local.vm_families : f => (
      # NP reports a GPUs capability although its accelerators are FPGAs, so
      # this must be tested before the GPU check.
      length(regexall("(?i)^standardNP", f)) > 0 ? "FpgaAccelerated" :
      local.family_gpu[f] ? "GpuAccelerated" :
      local.family_rdma[f] ? "HighPerformanceCompute" :
      length(regexall("(?i)^standardL", f)) > 0 ? "StorageOptimized" :
      length(local.family_ratios[f]) == 0 ? null :
      tonumber(local.family_ratios[f][floor(length(local.family_ratios[f]) / 2)]) < 3 ? "ComputeOptimized" :
      tonumber(local.family_ratios[f][floor(length(local.family_ratios[f]) / 2)]) <= 6 ? "GeneralPurpose" :
      "MemoryOptimized"
    )
  }

  quota = {
    region_accessible    = local.region_accessible
    provider_registered  = local.provider_registered
    regional_cores_limit = try(local.regional_cores.limit, 0)
    regional_cores_used  = try(local.regional_cores.used, 0)
    families = {
      for f, q in local.quota_families : f => {
        limit     = q.limit
        used      = q.used
        lifecycle = contains(local.growth_restricted, f) ? "growth_restricted" : "current"

        category = try(local.family_category[f], null)
        # Flags rather than categories, matching how Azure models them.
        burstable              = length(regexall("(?i)^standardB", f)) > 0
        confidential_computing = try(local.family_confidential[f], false)
        architectures          = try(local.family_architectures[f], [])
      }
    }
  }
}
