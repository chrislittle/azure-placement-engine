# Runs every conformance scenario through ape-placement and checks the result
# against the scenario's own `expect` block.
#
#   terraform init && terraform apply -auto-approve
#
# No providers and no resources: this is pure evaluation, so it needs no
# subscription and runs in CI in seconds.
#
# The same scenarios are run by the PowerShell implementation
# (../powershell/Invoke-Conformance.ps1). That is the whole point -- the
# decision logic exists twice, so the two are held to one set of answers.

locals {
  scenario_files = fileset("${path.module}/../scenarios", "*.json")

  scenarios = {
    for f in local.scenario_files :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/../scenarios/${f}"))
  }
}

module "placement" {
  source   = "../../modules/ape-placement"
  for_each = local.scenarios

  request    = each.value.request
  pool       = each.value.pool
  sku_access = each.value.sku_access
  rules      = each.value.rules
}

locals {
  # Each check yields a message when it fails and an empty string when it passes
  # or when the scenario does not assert on that field.
  results = {
    for name, s in local.scenarios : name => compact([
      !contains(keys(s.expect), "status") ? "" :
      module.placement[name].decision.status == s.expect.status ? "" :
      "status: expected ${s.expect.status}, got ${module.placement[name].decision.status}",

      !contains(keys(s.expect), "family") ? "" :
      module.placement[name].decision.family == try(s.expect.family, null) ? "" :
      "family: expected ${coalesce(try(s.expect.family, null), "null")}, got ${coalesce(module.placement[name].decision.family, "null")}",

      !contains(keys(s.expect), "writes_required") ? "" :
      length(module.placement[name].writes_required) == s.expect.writes_required ? "" :
      "writes_required: expected ${s.expect.writes_required}, got ${length(module.placement[name].writes_required)}",

      !contains(keys(s.expect), "considered") ? "" :
      length(module.placement[name].decision.considered) == s.expect.considered ? "" :
      "considered: expected ${s.expect.considered}, got ${length(module.placement[name].decision.considered)}",

      !contains(keys(s.expect), "target_limit") ? "" :
      module.placement[name].decision.target_limit == s.expect.target_limit ? "" :
      "target_limit: expected ${s.expect.target_limit}, got ${coalesce(module.placement[name].decision.target_limit, 0)}",

      !contains(keys(s.expect), "regional_increase_required") ? "" :
      module.placement[name].decision.regional.increase_required == s.expect.regional_increase_required ? "" :
      "regional.increase_required: expected ${s.expect.regional_increase_required}",

      !contains(keys(s.expect), "requestable") ? "" :
      module.placement[name].decision.access.requestable == s.expect.requestable ? "" :
      "access.requestable: expected ${s.expect.requestable}",

      !contains(keys(s.expect), "region_zonal") ? "" :
      module.placement[name].decision.access.region_zonal == s.expect.region_zonal ? "" :
      "access.region_zonal: expected ${s.expect.region_zonal}",

      !contains(keys(s.expect), "not_offered") ? "" :
      length(module.placement[name].decision.access.not_offered) == s.expect.not_offered ? "" :
      "access.not_offered: expected ${s.expect.not_offered}, got ${length(module.placement[name].decision.access.not_offered)}",

      !contains(keys(s.expect), "rule_applied") ? "" :
      module.placement[name].decision.rule_applied == s.expect.rule_applied ? "" :
      "rule_applied: expected ${s.expect.rule_applied}, got ${module.placement[name].decision.rule_applied}",
    ])
  }

  failures = { for name, msgs in local.results : name => msgs if length(msgs) > 0 }
}

output "scenarios_run" {
  value = length(local.scenarios)
}

output "failures" {
  value = local.failures
}

# The actual decisions, so the PowerShell run can be diffed against them rather
# than only against the expectations.
output "decisions" {
  value = {
    for name, s in local.scenarios : name => {
      status          = module.placement[name].decision.status
      family          = module.placement[name].decision.family
      category        = module.placement[name].decision.category
      target_limit    = module.placement[name].decision.target_limit
      rule_applied    = module.placement[name].decision.rule_applied
      considered      = length(module.placement[name].decision.considered)
      writes_required = length(module.placement[name].writes_required)
    }
  }
}

check "all_scenarios_pass" {
  assert {
    condition     = length(local.failures) == 0
    error_message = "conformance failures: ${jsonencode(local.failures)}"
  }
}
