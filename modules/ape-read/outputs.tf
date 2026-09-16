output "pool" {
  description = "Quota state for the region, shaped for ape-placement's `pool` input."
  value       = local.pool
}

output "sku_access" {
  description = <<-EOT
    What this subscription may deploy in the region, shaped for
    ape-placement's `sku_access` input. Empty when the region is inaccessible,
    which the pool's `region_accessible` reports.
  EOT
  value       = local.sku_access
}

output "region_accessible" {
  description = "False when the subscription has no access to the region at all."
  value       = local.region_accessible
}
