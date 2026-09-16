# Stage 2 of subscription vending: quota and placement.
#
# Stage 1 creates the subscription with avm-ptn-sub-vending and outputs its id.
# Stage 2 runs afterwards, against a subscription that already exists, which is
# why the decision is visible in `terraform plan` before anything is written.
#
#   terraform apply \
#     -var subscription_id="$(terraform -chdir=../stage-1 output -raw subscription_id)" \
#     -var request_file=request.example.yaml
#
# The two stages share the subscription request file and nothing else. `subscription_id` is
# the entire handoff contract.

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

variable "subscription_id" {
  description = "From stage 1: avm-ptn-sub-vending's `subscription_id` output."
  type        = string
}

variable "request_file" {
  description = "The subscription request both stages read."
  type        = string
  default     = "request.example.yaml"
}

variable "rules_file" {
  description = <<-EOT
    Business rules, owned by the platform team. One file for the platform, not
    one per request. The application team never edits this.
  EOT
  type        = string
  default     = "rules.example.yaml"
}

variable "apply_writes" {
  description = "False evaluates the decision without writing quota."
  type        = bool
  default     = false
}

locals {
  # Two inputs, two owners. The request comes from the application team, one per
  # subscription. The rules come from the platform team, one per platform.
  # Accept either an absolute path or one relative to this directory. A pipeline
  # may well hand over an absolute path, and silently failing on it is unkind.
  request_path = can(regex("^([A-Za-z]:|/)", var.request_file)) ? var.request_file : "${path.module}/${var.request_file}"
  rules_path   = can(regex("^([A-Za-z]:|/)", var.rules_file)) ? var.rules_file : "${path.module}/${var.rules_file}"

  request_doc = yamldecode(file(local.request_path))
  rules_doc   = yamldecode(file(local.rules_path))

  compute = local.request_doc.compute

  request = {
    region                 = local.compute.region
    vcpus                  = local.compute.vcpus
    category               = try(local.compute.category, null)
    architecture           = try(local.compute.architecture, null)
    burstable              = try(local.compute.burstable, null)
    confidential_computing = try(local.compute.confidential_computing, null)
    family                 = try(local.compute.family, null)
    family_allowlist       = try(local.compute.family_allowlist, null)
    placement              = try(local.compute.placement, {})

    # DevTest and prod land on different rules; the subscription request already says which.
    environment = local.request_doc.subscription.environment

    # A vended subscription is by definition new, and new subscriptions cannot
    # deploy growth-restricted series at all.
    new_subscription = true
  }
}

module "read" {
  source = "../../modules/aqv-read"

  subscription_id = var.subscription_id
  region          = local.compute.region
}

module "decide" {
  source = "../../modules/aqv-decide"

  request    = local.request
  quota      = module.read.quota
  sku_access = module.read.sku_access

  rules = [
    for r in try(local.rules_doc.rules, []) : {
      name             = r.name
      environments     = try(r.environments, null)
      family_allowlist = try(r.family_allowlist, null)
      family_denylist  = try(r.family_denylist, null)
      max_vcpus        = try(r.max_vcpus, null)
      prefer           = try(r.prefer, "most_unused")
    }
  ]
}

module "apply" {
  source = "../../modules/aqv-apply"

  subscription_id = var.subscription_id
  region          = local.compute.region
  writes_required = module.decide.writes_required
  enabled         = var.apply_writes
}

output "decision" { value = module.decide.decision }
output "writes_required" { value = module.decide.writes_required }
output "applied" { value = module.apply.applied }
