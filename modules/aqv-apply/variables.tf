variable "subscription_id" {
  description = "Subscription whose quota is being written."
  type        = string
}

variable "region" {
  description = "Azure region the quota applies to."
  type        = string
}

variable "writes_required" {
  description = <<-EOT
    Straight from `aqv-decide`'s `writes_required` output. Empty means the
    decision needs nothing written, and this module then does nothing.

    Each `limit` is the ABSOLUTE new value, matching Microsoft.Quota semantics.
  EOT

  type = list(object({
    scope = string
    name  = string
    limit = number
  }))
  default = []

  validation {
    condition     = alltrue([for w in var.writes_required : contains(["regional", "family"], w.scope)])
    error_message = "writes_required[*].scope must be regional or family."
  }

  validation {
    condition     = length([for w in var.writes_required : w if w.scope == "regional"]) <= 1
    error_message = "at most one regional write per region."
  }
}

variable "enabled" {
  description = <<-EOT
    Set false to evaluate a decision without writing anything. Useful for
    seeing what a vending would do before letting it do it.
  EOT
  type        = bool
  default     = true
}
