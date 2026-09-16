# Azure models burstable, confidential compute and architecture as ATTRIBUTES
# rather than categories. That is the better model: a burstable family is also
# general-purpose shaped, so making it a category would hide it from anyone
# asking for general purpose.
#
# Split from class.tftest.hcl because a `.tftest.hcl` file cannot declare
# `variable` blocks -- only `variables` value blocks -- so a shared fixture has
# to be the file's own top-level `variables`.

variables {
  quota = {
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
    request = { region = "eastus", vcpus = 8, architecture = "Arm64" }
  }

  assert {
    condition     = output.decision.family == "standardDpsv6Family"
    error_message = "only one family in the quota is Arm64"
  }
}

run "confidential_computing_can_be_required" {
  command = plan

  variables {
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
    request = { region = "eastus", vcpus = 8, category = "MemoryOptimized", architecture = "Arm64" }
  }

  assert {
    condition     = output.decision.status == "infeasible"
    error_message = "no Arm64 memory-optimised family is in this quota"
  }
  assert {
    condition     = strcontains(output.decision.reason, "MemoryOptimized, Arm64")
    error_message = "the reason should name every attribute that was filtered on"
  }
}
