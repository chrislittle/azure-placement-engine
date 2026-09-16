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

variable "apply_writes" {
  description = "False evaluates the decision without writing quota."
  type        = bool
  default     = false
}

locals {
request_doc= yamldecode(file("${path.module}/${var.request_file}"))
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
  source = "../../modules/ape-read"

  subscription_id = var.subscription_id
  region          = local.compute.region
}

module "placement" {
  source = "../../modules/ape-placement"

  request    = local.request
  quota       = module.read.quota
  sku_access = module.read.sku_access

  # Business rules the platform team owns, not the customer. First match wins.
  rules = [
    {
      name            = "devtest stays off GPU and stays small"
      environments    = ["devtest"]
      family_denylist = ["standardNCSv3Family", "standardNVSv4Family"]
      max_vcpus       = 32
    },
  ]
}

module "apply" {
  source = "../../modules/ape-apply"

  subscription_id = var.subscription_id
  region          = local.compute.region
  writes_required = module.placement.writes_required
  enabled         = var.apply_writes
}

output "decision" { value = module.placement.decision }
output "writes_required" { value = module.placement.writes_required }
output "applied" { value = module.apply.applied }
