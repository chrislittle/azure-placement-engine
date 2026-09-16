# Fixtures modelled on a live PAYG subscription read on 2026-09-16: a regional
# cap of 10 vCPUs in East US sitting under 97 families each reporting 10 to 12.

variables {
  request = {
    region = "eastus"
    vcpus  = 8
  }
  pool = {
    regional_cores_limit = 100
    regional_cores_used  = 0
    families = {
      standardDSv3Family = { limit = 50, used = 10 }
      standardDSv5Family = { limit = 20, used = 0 }
      standardNCFamily   = { limit = 12, used = 0 }
    }
  }
}

run "existing_quota_covers_the_request" {
  command = plan

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "40 vCPUs of headroom should cover a request for 8"
  }
  assert {
    condition     = length(output.writes_required) == 0
    error_message = "a satisfied request must not write anything"
  }
}

run "picks_the_family_with_the_most_headroom" {
  command = plan

  assert {
    condition     = output.decision.family == "standardDSv3Family"
    error_message = "expected the 40-vCPU family, got ${coalesce(output.decision.family, "null")}"
  }
}

# The finding that matters most. Family headroom says yes; the regional cap
# says no. Ranking on family numbers alone would invent capacity.
run "regional_cap_binds_even_when_family_headroom_looks_sufficient" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 150 }
    pool = {
      regional_cores_limit = 100
      regional_cores_used  = 0
      families = {
        standardDSv3Family = { limit = 200, used = 0 }
      }
    }
  }

  assert {
    condition     = output.decision.regional.increase_required
    error_message = "150 vCPUs against a regional cap of 100 must flag a regional increase"
  }
  assert {
    condition     = output.decision.status == "needs_increase"
    error_message = "a request over the regional cap is not satisfied, whatever the family says"
  }
  assert {
    condition     = output.decision.regional.target == 150
    error_message = "regional target should be used + requested"
  }
  assert {
    condition     = length(output.writes_required) == 1 && output.writes_required[0].scope == "regional"
    error_message = "only the regional cap needs writing; the family limit already covers 150"
  }
}

run "pool_availability_turns_an_increase_into_an_allocation" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 60 }
    pool = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families = {
        standardDSv5Family = { limit = 20, used = 0, available = 100 }
      }
    }
  }

  assert {
    condition     = output.decision.status == "needs_allocation"
    error_message = "a pool with 100 spare should make this self-service, not an increase request"
  }
  assert {
    condition     = output.decision.target_limit == 60
    error_message = "target is absolute: used + requested, not a delta"
  }
}

# A null `available` means no pool behind the subscription. That is unproven
# capacity, never assumed-unlimited.
run "absent_pool_is_unproven_not_unlimited" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 60 }
    pool = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families = {
        standardDSv5Family = { limit = 20, used = 0 }
      }
    }
  }

  assert {
    condition     = output.decision.status == "infeasible"
    error_message = "without a pool, 20 vCPUs of limit cannot reach 60"
  }
}

run "target_limit_never_shrinks_an_existing_limit" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 5 }
    pool = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families = {
        standardDSv3Family = { limit = 50, used = 0, available = 10 }
      }
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "50 covers 5"
  }
  assert {
    condition     = output.decision.target_limit == 50
    error_message = "a small request must not pull a large limit down to it"
  }
}

run "records_why_every_other_family_lost" {
  command = plan

  assert {
    condition     = length(output.decision.considered) == 3
    error_message = "all three families should be accounted for"
  }
  assert {
    condition = length([
      for c in output.decision.considered : c if c.outcome == "eligible, outranked"
    ]) == 2
    error_message = "the two unchosen families should say they were outranked, not vanish"
  }
}

run "unknown_family_is_reported_not_dropped" {
  command = plan

  variables {
    request = {
      region           = "eastus"
      vcpus            = 4
      family_allowlist = ["standardDSv3Family", "standardTypoFamily"]
    }
  }

  assert {
    condition     = contains(output.decision.unknown_families, "standardTypoFamily")
    error_message = "a family the pool has never heard of must be surfaced"
  }
  assert {
    condition     = output.decision.family == "standardDSv3Family"
    error_message = "the known family should still be chosen"
  }
}
