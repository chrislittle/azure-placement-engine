# Fixtures taken verbatim from Microsoft.Compute/skus in East US, read against a
# live subscription on 2026-09-16.

variables {
  quota = {
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

# Quota for a family can exist in a region where Azure offers no sizes of it.
# On a live subscription, 14 of 97 families holding quota in East US had no
# SKUs there, and the module used to rank and choose one.
run "family_absent_from_sku_data_is_not_offered_not_merely_unknown" {
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
    condition     = output.decision.status == "blocked_by_access"
    error_message = "a family with no SKUs in the region has nothing to deploy"
  }
  assert {
    condition     = contains(output.decision.access.not_offered, "standardLsv2Family")
    error_message = "it should be reported as not offered, distinct from access-denied"
  }
  assert {
    condition     = strcontains(output.decision.reason, "no sizes to deploy")
    error_message = "the reason should not suggest a support ticket for this"
  }
}

# The regression that prompted the fix: an offered family must win over one
# that merely has quota.
run "an_offered_family_beats_a_phantom_one_with_more_quota" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 4 }
    quota = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families = {
        standardNVPromoFamily = { limit = 200, used = 0 }
        standardLsv2Family    = { limit = 20, used = 0 }
      }
    }
    sku_access = {
      standardLsv2Family = {
        sizes = { Standard_L8s_v2 = { zones = ["1", "2", "3"] } }
      }
    }
  }

  assert {
    condition     = output.decision.family == "standardLsv2Family"
    error_message = "the phantom family has ten times the quota and nothing to deploy"
  }
  assert {
    condition     = contains(output.decision.access.not_offered, "standardNVPromoFamily")
    error_message = "the phantom family should be named"
  }
}

# West Central US reports 916 VM SKUs and not a single availability zone.
# Telling someone to raise a zone access request there sends them after a
# ticket that cannot be fulfilled.
run "a_non_zonal_region_is_not_an_access_gap" {
  command = plan

  variables {
    request = {
      region    = "westcentralus"
      vcpus     = 4
      placement = { type = "zonal", zones = ["1"] }
    }
    quota = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families             = { standardDSv5Family = { limit = 100, used = 0 } }
    }
    sku_access = {
      standardDSv5Family = {
        sizes = { Standard_D8s_v5 = { zones = [] } }
      }
    }
  }

  assert {
    condition     = output.decision.status == "blocked_by_access"
    error_message = "a zonal placement in a non-zonal region cannot succeed"
  }
  assert {
    condition     = output.decision.access.region_zonal == false
    error_message = "the region should be reported as having no zones"
  }
  assert {
    condition     = !output.decision.access.requestable
    error_message = "there is no ticket that adds zones to a region"
  }
  assert {
    condition     = strcontains(output.decision.reason, "no availability zones")
    error_message = "the reason must say the region has no zones, not blame subscription access"
  }
}

run "regional_placement_in_a_non_zonal_region_is_fine" {
  command = plan

  variables {
    request = { region = "westcentralus", vcpus = 4 }
    quota = {
      regional_cores_limit = 500
      regional_cores_used  = 0
      families             = { standardDSv5Family = { limit = 100, used = 0 } }
    }
    sku_access = {
      standardDSv5Family = {
        sizes = { Standard_D8s_v5 = { zones = [] } }
      }
    }
  }

  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "no zones is irrelevant to a regional placement"
  }
}
