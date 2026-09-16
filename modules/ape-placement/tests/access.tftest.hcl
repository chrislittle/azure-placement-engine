# Fixtures taken verbatim from Microsoft.Compute/skus in East US, read against a
# live subscription on 2026-09-16.

variables {
  pool = {
    regional_cores_limit = 500
    regional_cores_used  = 0
    families = {
      standardDFamily    = { limit = 100, used = 0 }
      standardLsv2Family = { limit = 100, used = 0 }
    }
  }

  sku_access = {
    # The trap, exactly as Azure reports it: zones 2 and 3 published, zones
    # 1, 2 and 3 restricted. Reading `zones` alone says two zones are available.
    standardDFamily = {
      sizes = {
        Standard_D1 = {
          zones              = ["2", "3"]
          restricted_zones   = ["1", "2", "3"]
          restriction_reason = "NotAvailableForSubscription"
        }
        Standard_D2 = {
          zones              = ["2", "3"]
          restricted_zones   = ["1", "2", "3"]
          restriction_reason = "NotAvailableForSubscription"
        }
      }
    }
    # Partially reduced: publishes three zones, one of them restricted.
    standardLsv2Family = {
      sizes = {
        Standard_L16s_v2 = {
          zones              = ["1", "2", "3"]
          restricted_zones   = ["3"]
          restriction_reason = "NotAvailableForSubscription"
        }
      }
    }
  }
}

run "published_zones_alone_would_have_said_yes" {
  command = plan

  variables {
    request = {
      region    = "eastus"
      vcpus     = 4
      family    = "standardDFamily"
      placement = { type = "zonal", zones = ["2"] }
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_access"
    error_message = "zone 2 is published but restricted, so this must not be placeable"
  }
  assert {
    condition     = contains(output.decision.access.denied, "standardDFamily")
    error_message = "the family should be named as access-denied"
  }
  assert {
    condition     = output.decision.access.requestable
    error_message = "NotAvailableForSubscription is an entitlement gap and is requestable"
  }
}

# The assumption recorded in knowledge/zone-restrictions.yaml: a Zone-type
# restriction blocks zonal placement and leaves regional placement alone.
run "zone_restriction_does_not_block_regional_placement" {
  command = plan

  variables {
    request = {
      region = "eastus"
      vcpus  = 4
      family = "standardDFamily"
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "every zone is restricted, but nothing restricts the region"
  }
  assert {
    condition     = output.decision.access.placement == "regional"
    error_message = "placement should default to regional"
  }
}

run "a_location_restriction_blocks_regional_placement_too" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 4, family = "standardDFamily" }
    sku_access = {
      standardDFamily = {
        sizes = {
          Standard_D1 = {
            zones               = ["2", "3"]
            location_restricted = true
            restriction_reason  = "NotAvailableForSubscription"
          }
        }
      }
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_access"
    error_message = "a Location-type restriction removes the region entirely"
  }
}

run "partial_zone_reduction_admits_the_surviving_zones" {
  command = plan

  variables {
    request = {
      region    = "eastus"
      vcpus     = 4
      family    = "standardLsv2Family"
      placement = { type = "zonal", zones = ["1", "2"] }
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "zones 1 and 2 survive the restriction on zone 3"
  }
}

run "partial_zone_reduction_refuses_the_restricted_zone" {
  command = plan

  variables {
    request = {
      region    = "eastus"
      vcpus     = 4
      family    = "standardLsv2Family"
      placement = { type = "zonal", zones = ["3"] }
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_access"
    error_message = "zone 3 is restricted for the only size in this family"
  }
}

run "zone_redundant_needs_enough_distinct_zones" {
  command = plan

  variables {
    request = {
      region           = "eastus"
      vcpus            = 4
      family_allowlist = ["standardLsv2Family"]
      placement        = { type = "zone_redundant", zone_count = 3 }
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_access"
    error_message = "two usable zones cannot satisfy a three-zone spread"
  }
}

run "zone_redundant_two_is_satisfiable" {
  command = plan

  variables {
    request = {
      region           = "eastus"
      vcpus            = 4
      family_allowlist = ["standardLsv2Family"]
      placement        = { type = "zone_redundant", zone_count = 2 }
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "zones 1 and 2 satisfy a two-zone spread"
  }
}

# QuotaId means the offer excludes the SKU. Telling someone to raise a ticket
# for that wastes their time.
run "quotaid_is_final_not_requestable" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 4, family = "standardDFamily" }
    sku_access = {
      standardDFamily = {
        sizes = {
          Standard_D1 = {
            location_restricted = true
            restriction_reason  = "QuotaId"
          }
        }
      }
    }
  }

  assert {
    condition     = !output.decision.access.requestable
    error_message = "QuotaId is an offer exclusion, not an entitlement gap"
  }
  assert {
    condition     = strcontains(output.decision.reason, "no support ticket will change")
    error_message = "the reason should say a ticket is pointless, not suggest one"
  }
}

run "unchecked_access_is_never_reported_as_verified" {
  command = plan

  variables {
    request    = { region = "eastus", vcpus = 4, family = "standardDFamily" }
    sku_access = {}
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "skipping the check should not block placement"
  }
  assert {
    condition     = !output.decision.access.verified
    error_message = "an unchecked family must never read as verified"
  }
}

run "family_missing_from_sku_data_is_permitted_but_unverified" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 4, family = "standardLsv2Family" }
    sku_access = {
      standardDFamily = {
        sizes = { Standard_D1 = { zones = ["1"] } }
      }
    }
  }

  assert {
    condition     = contains(output.decision.access.unverified, "standardLsv2Family")
    error_message = "a family absent from the SKU data must be flagged, not assumed good"
  }
  assert {
    condition     = !output.decision.access.verified
    error_message = "silence is not evidence of access"
  }
}
