# The July 2026 capacity growth restrictions.
# See knowledge/vm-series-lifecycle.yaml.

variables {
  pool = {
    regional_cores_limit = 500
    regional_cores_used  = 0
    families = {
      standardDSv3Family = {
        limit      = 100
        used       = 0
        lifecycle  = "growth_restricted"
        successors = ["Dv5", "Dv6", "Dv7"]
      }
      standardDdsv6Family = { limit = 20, used = 0 }
    }
  }
}

# The first row of Microsoft's own matrix, and the one that reshapes vending:
# a new subscription cannot deploy a restricted series at all -- not even
# within quota it appears to hold.
run "new_subscription_cannot_use_a_restricted_family_even_with_headroom" {
  command = plan

  variables {
    request = {
      region = "eastus"
      vcpus  = 8
      family = "standardDSv3Family"
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_lifecycle"
    error_message = "100 vCPUs of headroom is irrelevant; a new subscription cannot deploy the series"
  }
  assert {
    condition     = strcontains(output.decision.reason, "Dv5, Dv6, Dv7")
    error_message = "the reason should name the successors rather than just refusing"
  }
}

run "existing_subscription_may_use_it_within_existing_quota" {
  command = plan

  variables {
    request = {
      region           = "eastus"
      vcpus            = 8
      family           = "standardDSv3Family"
      new_subscription = false
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "an existing subscription can deploy within already-approved quota"
  }
  assert {
    condition     = contains(output.decision.lifecycle.frozen, "standardDSv3Family")
    error_message = "the family should still be flagged as frozen"
  }
}

# The 400 DeprecatedQuotaType, predicted rather than discovered at write time.
run "existing_subscription_cannot_grow_a_restricted_family" {
  command = plan

  variables {
    request = {
      region           = "eastus"
      vcpus            = 150
      family           = "standardDSv3Family"
      new_subscription = false
    }
    pool = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families = {
        standardDSv3Family = {
          limit      = 100
          used       = 0
          available  = 400
          lifecycle  = "growth_restricted"
          successors = ["Dv6"]
        }
      }
    }
  }

  assert {
    condition     = output.decision.status == "infeasible"
    error_message = "quota increases are refused for restricted series, whatever the pool says"
  }
  assert {
    condition     = length(output.writes_required) == 0
    error_message = "must not attempt a write that Azure will refuse with DeprecatedQuotaType"
  }
}

run "a_current_family_is_chosen_over_a_restricted_one" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8 }
  }

  assert {
    condition     = output.decision.family == "standardDdsv6Family"
    error_message = "the restricted family has more headroom but is not deployable"
  }
  assert {
    condition     = contains(output.decision.lifecycle.denied, "standardDSv3Family")
    error_message = "the restricted family should be recorded as denied"
  }
}

run "lifecycle_defaults_to_current" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8, family = "standardDdsv6Family" }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "a family with no lifecycle set should be treated as current"
  }
  assert {
    condition     = length(output.decision.lifecycle.denied) == 0
    error_message = "nothing should be denied when only a current family is in play"
  }
}
