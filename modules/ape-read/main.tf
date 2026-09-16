# Reads live Azure state and projects it into the shapes ape-placement wants.
#
# Separate module because reading and deciding are separate concerns: this one
# talks to Azure and holds no logic worth testing, while ape-placement holds all
# the logic and talks to nothing.

terraform {
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0"
    }
  }
}

# Which regions this subscription may use at all.
#
# This is the region-access probe, and it has to come first. Asking Compute
# usages about a region the subscription lacks returns HTTP 400
# NoRegisteredProviderFound, which a Terraform data source cannot catch -- it
# fails the whole plan. Reading the provider registration instead is one small
# call that answers the same question without erroring.
data "azapi_resource_action" "compute_provider" {
  type                   = "Microsoft.Resources/subscriptions@2021-04-01"
  resource_id            = "/subscriptions/${var.subscription_id}"
  action                 = "providers/Microsoft.Compute"
  method                 = "GET"
  response_export_values = ["*"]
}

locals {
  usage_locations = [
    for rt in try(data.azapi_resource_action.compute_provider.output.resourceTypes, []) :
    [for l in try(rt.locations, []) : lower(replace(l, " ", ""))]
    if try(rt.resourceType, "") == "locations/usages"
  ]

  region_accessible = contains(
    length(local.usage_locations) > 0 ? local.usage_locations[0] : [],
    lower(replace(var.region, " ", "")),
  )
}

# Both reads are gated on access, so an unreachable region yields an empty pool
# and a clean `region_accessible = false` rather than a failed plan.
data "azapi_resource_action" "usages" {
  count                  = local.region_accessible ? 1 : 0
  type                   = "Microsoft.Compute/locations@2021-07-01"
  resource_id            = "/subscriptions/${var.subscription_id}/providers/Microsoft.Compute/locations/${var.region}"
  action                 = "usages"
  method                 = "GET"
  response_export_values = ["*"]
}

data "azapi_resource_list" "skus" {
  count                  = local.region_accessible ? 1 : 0
  type                   = "Microsoft.Compute/skus@2021-07-01"
  parent_id              = "/subscriptions/${var.subscription_id}"
  query_parameters       = { "$filter" = ["location eq '${var.region}'"] }
  response_export_values = ["*"]
}
