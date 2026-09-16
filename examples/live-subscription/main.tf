# Runs the decision module against pool state read from a real subscription.
#
#   python ../../scripts/read_pool.py <subscription-id> <region> > pool.auto.tfvars.json
#   terraform init && terraform apply -auto-approve
#
# There are no providers and no resources -- apply only evaluates the decision.

variable "pool" {
  type = object({
    regional_cores_limit = number
    regional_cores_used  = number
    families = map(object({
      limit     = number
      used      = number
      available = optional(number)
    }))
  })
}

variable "sku_access" {
  type = map(object({
    sizes = map(object({
      zones               = optional(list(string), [])
      restricted_zones    = optional(list(string), [])
      location_restricted = optional(bool, false)
      restriction_reason  = optional(string)
    }))
  }))
  default = {}
}

variable "request" {
  type = object({
    region           = string
    vcpus            = number
    family           = optional(string)
    family_allowlist = optional(list(string))
    environment      = optional(string, "prod")
    placement = optional(object({
      type       = optional(string, "regional")
      zones      = optional(list(string))
      zone_count = optional(number)
    }), {})
  })
}

module "placement" {
  source = "../../modules/ape-placement"

  request    = var.request
  pool       = var.pool
  sku_access = var.sku_access

  rules = [
    {
      name            = "dev stays off GPU"
      environments    = ["dev"]
      family_denylist = ["standardNCFamily", "standardNVFamily"]
    },
  ]
}

output "status" { value = module.placement.decision.status }
output "reason" { value = module.placement.decision.reason }
output "family" { value = module.placement.decision.family }
output "regional" { value = module.placement.decision.regional }
output "access" { value = module.placement.decision.access }
output "writes_required" { value = module.placement.writes_required }
