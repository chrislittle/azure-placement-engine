# Applies the quota writes a placement decision asked for.
#
# `azapi_update_resource` rather than `azapi_resource` on purpose: a quota limit
# is a property of something Azure already owns, not a resource with a
# lifecycle. Microsoft.Quota has no DELETE, so a managed resource would fail on
# `terraform destroy`; this one simply stops managing the property.
#
# `limit` is absolute, never a delta, which is what makes this expressible as
# desired state at all.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0"
    }
  }
}

locals {
  quota_base = "/subscriptions/${var.subscription_id}/providers/Microsoft.Compute/locations/${var.region}/providers/Microsoft.Quota/quotas"

  regional_writes = [for w in var.writes_required : w if w.scope == "regional"]
  family_writes   = [for w in var.writes_required : w if w.scope == "family"]
}

# The regional vCPU cap first. A family limit above it is unusable, so raising
# the family without raising the cap buys nothing.
resource "azapi_update_resource" "regional" {
  count = var.enabled && length(local.regional_writes) > 0 ? 1 : 0

  type        = "Microsoft.Quota/quotas@2025-09-01"
  resource_id = "${local.quota_base}/${local.regional_writes[0].name}"

  body = {
    properties = {
      name  = { value = local.regional_writes[0].name }
      limit = { limitObjectType = "LimitValue", value = local.regional_writes[0].limit }
    }
  }

  response_export_values = ["*"]
}

resource "azapi_update_resource" "family" {
  count = var.enabled && length(local.family_writes) > 0 ? 1 : 0

  type        = "Microsoft.Quota/quotas@2025-09-01"
  resource_id = "${local.quota_base}/${local.family_writes[0].name}"

  body = {
    properties = {
      name  = { value = local.family_writes[0].name }
      limit = { limitObjectType = "LimitValue", value = local.family_writes[0].limit }
    }
  }

  response_export_values = ["*"]

  depends_on = [azapi_update_resource.regional]
}
