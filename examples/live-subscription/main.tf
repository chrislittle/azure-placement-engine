# Runs the decision module against pool state read from a real subscription.
#
#   python ../../scripts/read_pool.py <subscription-id> <region> > pool.auto.tfvars.json
#   terraform init && terraform apply -auto-approve
#
# There are no providers and no resources -- apply only evaluates the decision.

# All three are untyped on purpose. Restating the module's object types here
# has silently discarded fields three times -- Terraform drops attributes the
# local type does not declare, without warning. The module declares and
# validates them; the example must not shadow that.
variable "pool" { type = any }

variable "sku_access" {
  type    = any
  default = {}
}

variable "request" {
  type = any
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
output "lifecycle" { value = module.placement.decision.lifecycle }
output "writes_required" { value = module.placement.writes_required }
