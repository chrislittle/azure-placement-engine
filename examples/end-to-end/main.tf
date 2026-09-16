# The whole thing in Terraform: read live Azure state, decide, report.
# No Python, no pipeline step, no generated tfvars.
#
#   terraform init
#   terraform apply -var subscription_id=... -var region=eastus \
#     -var 'request={region="eastus",vcpus=8,class="general_purpose"}'

terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0"
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
}

variable "subscription_id" { type = string }
variable "region" { type = string }
variable "request" { type = any }

module "read" {
  source = "../../modules/ape-read"

  subscription_id = var.subscription_id
  region          = var.region
}

module "placement" {
  source = "../../modules/ape-placement"

  request    = var.request
  pool       = module.read.pool
  sku_access = module.read.sku_access

  rules = [
    {
      name            = "dev stays off GPU"
      environments    = ["dev"]
      family_denylist = ["standardNCSv3Family", "standardNVSv4Family"]
    },
  ]
}

# Writing is off by default here so the example can be run against a real
# subscription without changing anything. Set apply_writes = true to let it.
variable "apply_writes" {
  type    = bool
  default = false
}

module "apply" {
  source = "../../modules/ape-apply"

  subscription_id = var.subscription_id
  region          = var.region
  writes_required = module.placement.writes_required
  enabled         = var.apply_writes
}

output "applied" { value = module.apply.applied }
output "status" { value = module.placement.decision.status }
output "reason" { value = module.placement.decision.reason }
output "family" { value = module.placement.decision.family }
output "class" { value = module.placement.decision.class }
output "writes_required" { value = module.placement.writes_required }
output "region_accessible" { value = module.read.region_accessible }
output "pool_summary" {
  value = {
    families          = length(module.read.pool.families)
    regional_cores    = module.read.pool.regional_cores_limit
    growth_restricted = length([for f, d in module.read.pool.families : f if d.lifecycle == "growth_restricted"])
    sku_families      = length(module.read.sku_access)
  }
}
