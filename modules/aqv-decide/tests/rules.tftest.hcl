variables {
  quota = {
    regional_cores_limit = 500
    regional_cores_used  = 0
    families = {
      standardDSv3Family = { limit = 100, used = 0 }
      standardDSv5Family = { limit = 40, used = 0 }
      standardNCFamily   = { limit = 80, used = 0 }
    }
  }
  rules = [
    {
      name            = "dev keeps off GPU and stays small"
      environments    = ["dev"]
      family_denylist = ["standardNCFamily"]
      max_vcpus       = 16
    },
    {
      name             = "prod sticks to the approved families, in order"
      environments     = ["prod"]
      family_allowlist = ["standardDSv5Family", "standardDSv3Family"]
      prefer           = "listed_order"
    },
  ]
}

run "rule_caps_the_request_size" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 32, environment = "dev" }
  }

  assert {
    condition     = output.decision.status == "blocked_by_rule"
    error_message = "32 vCPUs should be refused by the dev cap of 16"
  }
  assert {
    condition     = output.decision.rule_applied == "dev keeps off GPU and stays small"
    error_message = "the decision should name the rule that refused it"
  }
  assert {
    condition     = length(output.writes_required) == 0
    error_message = "a blocked request must not write anything"
  }
}

run "rule_denylist_removes_a_family" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8, environment = "dev" }
  }

  assert {
    condition     = !contains([for c in output.decision.considered : c.family], "standardNCFamily")
    error_message = "a denied family should not even be considered"
  }
  assert {
    condition     = output.decision.family == "standardDSv3Family"
    error_message = "dev should land on the largest permitted family"
  }
}

# listed_order exists so a platform team can express "use up the cheap family
# first", which unused ranking would get backwards.
run "listed_order_beats_headroom_ranking" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8, environment = "prod" }
  }

  assert {
    condition     = output.decision.family == "standardDSv5Family"
    error_message = "listed_order should pick the first allowed family, not the roomiest"
  }
  assert {
    condition     = output.decision.preference == "listed_order"
    error_message = "the decision should say which preference it used"
  }
}

run "first_matching_rule_wins" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8, environment = "prod" }
    rules = [
      { name = "catch-all first, shadowing everything below", prefer = "least_unused" },
      { name = "never reached", environments = ["prod"], prefer = "most_unused" },
    ]
  }

  assert {
    condition     = output.decision.rule_applied == "catch-all first, shadowing everything below"
    error_message = "an unconditional rule placed first must shadow the ones after it"
  }
  assert {
    condition     = output.decision.family == "standardDSv5Family"
    error_message = "least_unused should pick the 40-vCPU family"
  }
}

run "no_rules_at_all_is_valid" {
  command = plan

  variables {
    request = { region = "eastus", vcpus = 8 }
    rules   = []
  }

  assert {
    condition     = output.decision.rule_applied == "(none)"
    error_message = "an empty rule set should be reported, not faked"
  }
  assert {
    condition     = output.decision.status == "satisfied"
    error_message = "no rules means no restrictions"
  }
}
