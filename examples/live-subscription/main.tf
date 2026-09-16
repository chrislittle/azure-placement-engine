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

variable "request" {
  type = object({
    region           = string
    vcpus            = number
    family           = optional(string)
    family_allowlist = optional(list(string))
    environment      = optional(string, "prod")
  })
}

module "placement" {
  source = "../../modules/ape-placement"

  request = var.request
  pool    = var.pool

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
output "writes_required" { value = module.placement.writes_required }
