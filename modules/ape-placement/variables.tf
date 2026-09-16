variable "request" {
  description = <<-EOT
    What the vended subscription needs, in one region. `family` fixes the VM
    family outright; `family_allowlist` narrows the candidates without fixing
    one; neither means "anything the pool offers".
  EOT

  type = object({
    region           = string
    vcpus            = number
    family           = optional(string)
    family_allowlist = optional(list(string))
    environment      = optional(string, "prod")

    # How the workload will be placed. This is not a preference -- it changes
    # which families are eligible at all, because zone access is granted per
    # SKU size and per zone.
    #
    #   regional        no zone pinned; Azure places it in the region
    #   zonal           pinned to `zones`; every one must be usable
    #   zone_redundant  spread across `zone_count` distinct zones
    placement = optional(object({
      type       = optional(string, "regional")
      zones      = optional(list(string))
      zone_count = optional(number)
    }), {})
  })

  validation {
    condition     = var.request.vcpus > 0
    error_message = "request.vcpus must be greater than zero."
  }

  validation {
    condition     = contains(["regional", "zonal", "zone_redundant"], coalesce(try(var.request.placement.type, null), "regional"))
    error_message = "request.placement.type must be regional, zonal or zone_redundant."
  }

  validation {
    condition     = coalesce(try(var.request.placement.type, null), "regional") != "zonal" || length(coalesce(try(var.request.placement.zones, null), [])) > 0
    error_message = "request.placement.zones must name at least one zone when type is zonal."
  }
}

variable "sku_access" {
  description = <<-EOT
    Which SKU sizes this subscription may actually deploy, keyed by VM family,
    as read from `Microsoft.Compute/skus` for the region. Access is a separate
    gate from quota: a quota group grants neither regional nor zonal access, so
    allocating quota for a family that cannot deploy buys a guaranteed failure.

    Pass the API's fields raw. The module does the subtraction, because the
    subtraction is where the trap is: `restricted_zones` is NOT constrained to
    be a subset of `zones`. Standard_D1 in East US publishes zones 2 and 3 while
    restricting 1, 2 and 3 -- reading `zones` alone says "two zones available"
    when the answer is none.

    Leave empty to skip the access check entirely. The decision then reports
    `access.verified = false` rather than implying the check passed.
  EOT

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

variable "pool" {
  description = <<-EOT
    Current quota state for `request.region`, read by the caller rather than by
    this module.

    `regional_cores_limit` is the region-wide vCPU cap. It is not the sum of the
    family limits and is usually far smaller -- a live PAYG subscription shows a
    regional cap of 10 alongside 97 families each reporting 10 to 12. Every
    family sits underneath it.

    `families[*].available` is what the pool can still grant on top of a
    family's own limit, from a quota group's `availableLimit`. Leave it null
    when there is no pool behind the subscription: the module then treats extra
    capacity as unproven rather than assuming a limit increase will be granted.
  EOT

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

variable "rules" {
  description = <<-EOT
    Business rules, evaluated in order -- the first whose `environments` matches
    wins, and a rule with no `environments` matches everything. Put the specific
    rules first.
  EOT

  type = list(object({
    name             = string
    environments     = optional(list(string))
    family_allowlist = optional(list(string))
    family_denylist  = optional(list(string))
    max_vcpus        = optional(number)
    prefer           = optional(string, "most_headroom")
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.rules : contains(["most_headroom", "least_headroom", "listed_order"], coalesce(r.prefer, "most_headroom"))
    ])
    error_message = "rules[*].prefer must be most_headroom, least_headroom or listed_order."
  }
}
