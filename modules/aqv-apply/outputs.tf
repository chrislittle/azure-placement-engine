output "applied" {
  description = "What was written, with the limit Azure reported back afterwards."
  value = concat(
    [for r in azapi_update_resource.regional : {
      scope     = "regional"
      name      = local.regional_writes[0].name
      requested = local.regional_writes[0].limit
      granted   = try(r.output.properties.limit.value, null)
    }],
    [for r in azapi_update_resource.family : {
      scope     = "family"
      name      = local.family_writes[0].name
      requested = local.family_writes[0].limit
      granted   = try(r.output.properties.limit.value, null)
    }],
  )
}

output "pending" {
  description = <<-EOT
    Writes Azure accepted but has not granted. A quota PUT can return 202 and
    then settle on Failed with error code ContactSupport, so a limit that comes
    back lower than requested means the self-service path was exhausted and a
    support ticket is the only remaining route -- NOT that the write was lost.
  EOT
  value = [
    for a in concat(
      [for r in azapi_update_resource.regional : {
        name    = local.regional_writes[0].name, requested = local.regional_writes[0].limit,
        granted = try(r.output.properties.limit.value, null)
      }],
      [for r in azapi_update_resource.family : {
        name    = local.family_writes[0].name, requested = local.family_writes[0].limit,
        granted = try(r.output.properties.limit.value, null)
      }],
    ) : a if a.granted != null && a.granted < a.requested
  ]
}
