# Workload class is the intake a customer can actually fill in.
# See knowledge/vm-series-classes.yaml.

variables {
  pool = {
    regional_cores_limit = 500
    regional_cores_used  = 0
    families = {
      standardDSv5Family  = { limit = 100, used = 0, class = "general_purpose" }
      standardESv5Family  = { limit = 80, used = 0, class = "memory_optimized" }
      standardFSv2Family  = { limit = 200, used = 0, class = "compute_optimized", lifecycle = "growth_restricted" }
      standardNCSv3Family = { limit = 48, used = 0, class = "gpu" }
    }
  }
}

run "class_narrows_to_the_right_families" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 16, class = "memory_optimized" }
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
    request = { region = "eastus", vcpus = 12, class = "gpu" }
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
    request = { region = "eastus", vcpus = 16, class = "compute_optimized" }
  }

  assert {
    condition     = output.decision.status == "blocked_by_lifecycle"
    error_message = "class selection must not bypass the capacity growth restrictions"
  }
}

run "a_class_with_no_quota_says_so_plainly" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 16, class = "hpc" }
  }

  assert {
    condition     = output.decision.status == "infeasible"
    error_message = "no HPC quota exists in this pool"
  }
  assert {
    condition     = strcontains(output.decision.reason, "holds no hpc quota")
    error_message = "the reason should name the missing class, not blame the candidates"
  }
}

run "an_explicit_family_overrides_the_class" {
  command = plan

  variables {
    request = {
      region = "eastus"
      vcpus  = 16
      class  = "memory_optimized"
      family = "standardDSv5Family"
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
    condition     = output.decision.class == null
    error_message = "the decision should report no class was given"
  }
}
