# Workload class is the intake a customer can actually fill in.
# See knowledge/vm-series-classes.yaml.

variables {
  pool = {
    regional_cores_limit = 500
    regional_cores_used  = 0
    families = {
      standardDSv5Family  = { limit = 100, used = 0, category = "GeneralPurpose" }
      standardESv5Family  = { limit = 80, used = 0, category = "MemoryOptimized" }
      standardFSv2Family  = { limit = 200, used = 0, category = "ComputeOptimized", lifecycle = "growth_restricted" }
      standardNCSv3Family = { limit = 48, used = 0, category = "GpuAccelerated" }
    }
  }
}

run "class_narrows_to_the_right_families" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 16, category = "MemoryOptimized" }
  }

  assert {
    condition     = output.decision.family == "standardESv5Family"
    error_message = "a memory-optimised ask must not land on a general-purpose family"
  }
  assert {
    condition     = length(output.decision.considered) == 1
    error_message = "only the matching class should be considered at all"
  }
}

run "gpu_class_is_selectable_without_naming_a_family" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 12, category = "GpuAccelerated" }
  }

  assert {
    condition     = output.decision.family == "standardNCSv3Family"
    error_message = "a GPU ask should resolve without the customer knowing the family name"
  }
}

# The compute-optimised family here has twice the quota of anything else and is
# growth-restricted, so a new subscription cannot use it.
run "class_still_respects_the_lifecycle_gate" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 16, category = "ComputeOptimized" }
  }

  assert {
    condition     = output.decision.status == "blocked_by_lifecycle"
    error_message = "class selection must not bypass the capacity growth restrictions"
  }
}

run "a_class_with_no_quota_says_so_plainly" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 16, category = "HighPerformanceCompute" }
  }

  assert {
    condition     = output.decision.status == "infeasible"
    error_message = "no HPC quota exists in this pool"
  }
  assert {
    condition     = strcontains(output.decision.reason, "matching HighPerformanceCompute")
    error_message = "the reason should name the missing class, not blame the candidates"
  }
}

run "an_explicit_family_overrides_the_class" {
  command = plan

  variables {
    request = {
      region   = "eastus"
      vcpus    = 16
      category = "MemoryOptimized"
      family   = "standardDSv5Family"
    }
  }

  assert {
    condition     = output.decision.family == "standardDSv5Family"
    error_message = "naming a family explicitly should win over the class"
  }
}

run "class_is_optional" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 16 }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "omitting class should consider everything, as before"
  }
  assert {
    condition     = output.decision.category == null
    error_message = "the decision should report no class was given"
  }
}

# Azure models burstable, confidential compute and architecture as attributes
# rather than categories. That is the better model: a burstable family is also
# general-purpose shaped, so making it a category would hide it from anyone
# asking for general purpose.
variable "attr_pool" {
  type = any
  default = {
    regional_cores_limit = 500
    regional_cores_used  = 0
    families = {
      standardDSv5Family = {
        limit = 100, used = 0, category = "GeneralPurpose", architectures = ["x64"]
      }
      standardBsv2Family = {
        limit = 100, used = 0, category = "GeneralPurpose", burstable = true, architectures = ["x64"]
      }
      standardDpsv6Family = {
        limit = 100, used = 0, category = "GeneralPurpose", architectures = ["Arm64"]
      }
      standardDCASv5Family = {
        limit = 100, used = 0, category = "GeneralPurpose", confidential_computing = true, architectures = ["x64"]
      }
    }
  }
}

run "a_burstable_family_is_still_general_purpose" {
  command = plan

  variables {
    pool    = var.attr_pool
    request = { region = "eastus", vcpus = 8, category = "GeneralPurpose" }
  }

  assert {
    condition     = length(output.decision.considered) == 4
    error_message = "burstable and confidential families are general-purpose shaped and must not be hidden"
  }
}

run "burstable_can_be_excluded_without_touching_the_category" {
  command = plan

  variables {
    pool    = var.attr_pool
    request = { region = "eastus", vcpus = 8, category = "GeneralPurpose", burstable = "Excluded" }
  }

  assert {
    condition     = !contains([for c in output.decision.considered : c.family], "standardBsv2Family")
    error_message = "excluding burstable should drop only the burstable family"
  }
  assert {
    condition     = length(output.decision.considered) == 3
    error_message = "the other three general-purpose families should remain"
  }
}

run "architecture_filters_to_arm" {
  command = plan

  variables {
    pool    = var.attr_pool
    request = { region = "eastus", vcpus = 8, architecture = "Arm64" }
  }

  assert {
    condition     = output.decision.family == "standardDpsv6Family"
    error_message = "only one family in the pool is Arm64"
  }
}

run "confidential_computing_can_be_required" {
  command = plan

  variables {
    pool    = var.attr_pool
    request = { region = "eastus", vcpus = 8, confidential_computing = "Required" }
  }

  assert {
    condition     = output.decision.family == "standardDCASv5Family"
    error_message = "only one family reports a ConfidentialComputingType"
  }
}

run "an_unsatisfiable_attribute_combination_says_what_it_wanted" {
  command = plan

  variables {
    pool    = var.attr_pool
    request = { region = "eastus", vcpus = 8, category = "MemoryOptimized", architecture = "Arm64" }
  }

  assert {
    condition     = output.decision.status == "infeasible"
    error_message = "no Arm64 memory-optimised family is in this pool"
  }
  assert {
    condition     = strcontains(output.decision.reason, "MemoryOptimized, Arm64")
    error_message = "the reason should name every attribute that was filtered on"
  }
}
