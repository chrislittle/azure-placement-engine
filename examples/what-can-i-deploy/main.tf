# "What can I deploy?" — for the application team, not the platform team.
#
# Answers the question against a subscription's CURRENT state: which VM family
# to use, how many vCPUs it can run, and what would be refused.
#
# It writes nothing. `Reader` on the subscription is enough, because the read
# module only calls read APIs and the decide module holds no resources at all.
# An application team can therefore run this themselves, whenever they want, and
# get an answer that is true now rather than one recorded at hand-over.
#
#   terraform init
#   terraform apply -var subscription_id=$SUB -var region=eastus -var vcpus=64
#
# Narrow it the same way a request does:
#
#   -var category=MemoryOptimized -var architecture=Arm64

terraform {
  required_version = ">= 1.9"

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
  description = "The subscription to ask about."
  type        = string
}

variable "region" {
  description = "Azure region, for example eastus."
  type        = string
}

variable "vcpus" {
  description = "How many vCPUs the workload needs."
  type        = number
  default     = 8
}

variable "category" {
  description = "Optional. GeneralPurpose, MemoryOptimized, GpuAccelerated and so on."
  type        = string
  default     = null
}

variable "architecture" {
  description = "Optional. x64 or Arm64."
  type        = string
  default     = null
}

variable "rules_file" {
  description = <<-EOT
    Optional. The platform team's rules file.

    Without it, the answer is what AZURE permits. With it, the answer is what
    the PLATFORM would grant, which can be stricter. Point this at the same
    rules.yaml the pipeline uses and the two answers agree.
  EOT
  type        = string
  default     = null
}

variable "new_subscription" {
  description = <<-EOT
    Leave true for a freshly vended subscription. Set false for one that already
    holds quota: growth-restricted families can still be used within quota
    already granted, but cannot be grown.
  EOT
  type        = bool
  default     = false
}

module "read" {
  source = "../../modules/aqv-read"

  subscription_id = var.subscription_id
  region          = var.region
}

locals {
  rules = var.rules_file == null ? [] : [
    for r in try(yamldecode(file(var.rules_file)).rules, []) : {
      name             = r.name
      environments     = try(r.environments, null)
      family_allowlist = try(r.family_allowlist, null)
      family_denylist  = try(r.family_denylist, null)
      max_vcpus        = try(r.max_vcpus, null)
      prefer           = try(r.prefer, "most_unused")
    }
  ]
}

module "decide" {
  source = "../../modules/aqv-decide"

  rules = local.rules

  request = {
    region           = var.region
    vcpus            = var.vcpus
    category         = var.category
    architecture     = var.architecture
    new_subscription = var.new_subscription
  }

  quota      = module.read.quota
  sku_access = module.read.sku_access
}

output "answer" {
  description = "The short version."
  value = {
    rules_applied = var.rules_file == null ? "none — this is what Azure permits, not what the platform would grant" : module.decide.decision.rule_applied

    can_i_deploy = module.decide.decision.status == "satisfied"
    status       = module.decide.decision.status
    reason       = module.decide.decision.reason
    use_family   = module.decide.decision.family
  }
}

output "what_would_need_writing" {
  description = <<-EOT
    Empty means the quota is already there. Anything here needs the platform
    team, because raising quota needs more than Reader.
  EOT
  value       = module.decide.writes_required
}

output "why_not_the_others" {
  description = "Every family that was considered, and why it lost."
  value       = module.decide.decision.considered
}

output "blocked" {
  description = "Families that cannot be deployed here at all, and what would lift that."
  value = {
    growth_restricted = module.decide.decision.lifecycle.denied
    no_access         = module.decide.decision.access.denied
    not_offered       = module.decide.decision.access.not_offered
    remediation       = module.decide.decision.access.remediation
  }
}
