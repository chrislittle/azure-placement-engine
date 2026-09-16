output "quota" {
  description = "Quota state for the region, shaped for aqv-decide's `quota` input."
  value       = local.quota
}

output "sku_access" {
  description = <<-EOT
    What this subscription may deploy in the region, shaped for
    aqv-decide's `sku_access` input. Empty when the region is inaccessible,
    which the quota's `region_accessible` reports.
  EOT
  value       = local.sku_access
}

output "provider_registered" {
  description = <<-EOT
    False when Microsoft.Compute is not yet registered on the subscription.
    Transient -- a freshly vended subscription registers providers as part of
    vending, and registration is not instantaneous. Distinct from a region the
    subscription has not been granted, which no amount of waiting fixes.
  EOT
  value       = local.provider_registered
}

output "region_accessible" {
  description = "False when the subscription has no access to the region at all."
  value       = local.region_accessible
}
