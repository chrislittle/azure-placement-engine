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
  })

  validation {
    condition     = var.request.vcpus > 0
    error_message = "request.vcpus must be greater than zero."
  }
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
