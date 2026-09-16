# Region access is a gate above everything else, and the only API that reveals
# it is the quota read. See knowledge/capacity-signals.yaml.

run "no_region_access_blocks_before_anything_else_is_considered" {
  command = plan

  variables {
    request = { region = "germanynorth", vcpus = 8 }
    pool = {
      region_accessible    = false
      regional_cores_limit = 0
      regional_cores_used  = 0
      families             = {}
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_region"
    error_message = "a region the subscription cannot reach is not an infeasible placement, it is an access gap"
  }
  assert {
    condition     = strcontains(output.decision.reason, "region access request")
    error_message = "the reason should name the remediation"
  }
  assert {
    condition     = strcontains(output.decision.reason, "no amount of quota will help")
    error_message = "it should say plainly that quota is not the problem"
  }
  assert {
    condition     = length(output.writes_required) == 0
    error_message = "must not try to write quota into a region it cannot reach"
  }
}

# The trap: SKU data for an unreachable region looks entirely healthy.
run "healthy_looking_sku_data_does_not_override_the_region_gate" {
  command = plan

  variables {
    request = { region = "germanynorth", vcpus = 8 }
    pool = {
      region_accessible    = false
      regional_cores_limit = 100
      regional_cores_used  = 0
      families = {
        standardDSv5Family = { limit = 100, used = 0, class = "general_purpose" }
      }
    }
    sku_access = {
      standardDSv5Family = {
        sizes = { Standard_D8s_v5 = { zones = ["1", "2", "3"] } }
      }
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_region"
    error_message = "quota and unrestricted SKUs must not outrank the region gate"
  }
  assert {
    condition     = output.decision.access.region_accessible == false
    error_message = "the decision should report the region as unreachable"
  }
}

run "region_accessible_defaults_to_true" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8 }
    pool = {
      regional_cores_limit = 100
      regional_cores_used  = 0
      families = {
        standardDSv5Family = { limit = 100, used = 0, class = "general_purpose" }
      }
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "omitting region_accessible should not block anything"
  }
}
