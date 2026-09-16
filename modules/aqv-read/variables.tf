variable "subscription_id" {
  description = "Subscription to read quota and SKU availability for."
  type        = string
}

variable "region" {
  description = "Azure region, e.g. eastus."
  type        = string
}

variable "knowledge_dir" {
  description = <<-EOT
    Path to the repository's `knowledge/` directory. The curated facts are read
    from the YAML directly rather than copied into HCL, so the list of
    growth-restricted families has exactly one home.

    Defaults to the copy alongside this module. Set it only when consuming the
    module from somewhere the relative path does not reach.
  EOT
  type        = string
  default     = null
}
