<#
    .SYNOPSIS
    Step 7. Checks what Terraform's azapi provider can actually express.
    Runs `terraform plan` only. Writes nothing to Azure.

    .DESCRIPTION
    Answers H1, H2 and H3.

    The question that matters is H1: does azapi accept a BODY for
    quotaAllocations? Without one the write is fire-and-forget, Terraform has
    nothing to diff, and aqv-apply has to be read-compare-write rather than
    desired state. That changes the module's shape, so it is worth knowing
    before anything is built.

    `terraform plan` does not call Azure to create anything. It does resolve the
    provider schema, which is the whole point.
#>
[CmdletBinding()]
param([switch]$SkipApply)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 7 -Title 'Terraform reachability'

$tf = Get-Command terraform -ErrorAction SilentlyContinue
if (-not $tf) {
    Write-Host '  Terraform is not on PATH. Skipping step 7.' -ForegroundColor Yellow
    Write-Host '  H1 to H3 stay unanswered. That is fine: the rest of the package still matters.'
    return
}

$cfg = Get-Content (Join-Path (Get-AqvOutputDir) 'run-config.json') -Raw | ConvertFrom-Json
$dir = Join-Path (Get-AqvOutputDir) 'terraform'
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Path $dir | Out-Null

$summary = [ordered]@{ terraform_version = (& terraform version -json | ConvertFrom-Json).terraform_version }
Write-Host ("  Terraform {0}" -f $summary.terraform_version)

# The subscription id is only here so the provider can authenticate. Nothing in
# this configuration creates or changes anything.
$main = @"
terraform {
  required_providers {
    azapi = { source = "Azure/azapi", version = ">= 2.0" }
  }
}

provider "azapi" {
  subscription_id = "$($cfg.target_subscription_id)"
}

locals {
  group_id = "/providers/Microsoft.Management/managementGroups/$($cfg.management_group_id)/providers/Microsoft.Quota/groupQuotas/$($cfg.group_name)"
}

# H1. If azapi rejects `body` on this type, the allocation cannot be expressed
# as desired state and aqv-apply needs a different shape.
resource "azapi_resource" "allocation" {
  type      = "Microsoft.Quota/groupQuotas/quotaAllocations@2025-09-01"
  name      = "$($cfg.region)"
  parent_id = local.group_id

  # azapi does not carry this type in its embedded schema, so validation has to
  # be off for the configuration to resolve at all. Whether it then ACCEPTS the
  # body is the real question, and it can only be asked with the flag off.
  schema_validation_enabled = false

  body = {
    properties = {
      value = [{
        properties = {
          resourceName = "$($cfg.family)"
          limit        = $($cfg.cores)
        }
      }]
    }
  }
}

# The group object itself, for comparison. This one is documented as a normal
# resource, so if it also rejects a body the problem is the provider and not
# the allocation type.
resource "azapi_resource" "group" {
  type      = "Microsoft.Quota/groupQuotas@2025-09-01"
  # No hyphen: the schema enforces ^[a-z][a-z0-9]*$ on a quota group name.
  name      = "$($cfg.group_name)tfprobe"
  parent_id = "/providers/Microsoft.Management/managementGroups/$($cfg.management_group_id)"

  body = {
    properties = {
      displayName = "AQV terraform probe"
    }
  }
}
"@
$main | Set-Content -Path (Join-Path $dir 'main.tf') -Encoding utf8

Push-Location $dir
try {
    Write-Host ''
    Write-Host '  terraform init' -ForegroundColor Cyan
    $initLog = & terraform init -no-color -input=false 2>&1 | Out-String
    $summary.init_ok = ($LASTEXITCODE -eq 0)
    $summary.init_log = $initLog
    Write-Host ("    {0}" -f $(if ($summary.init_ok) { 'ok' } else { 'FAILED' })) `
        -ForegroundColor $(if ($summary.init_ok) { 'Green' } else { 'Red' })

    $m = [regex]::Match($initLog, 'Azure/azapi v([0-9.]+)')
    $summary.azapi_version = if ($m.Success) { $m.Groups[1].Value } else { $null }
    if ($summary.azapi_version) { Write-Host ("    azapi {0}" -f $summary.azapi_version) }

    if ($summary.init_ok) {
        # H1. A schema rejection surfaces here, before anything is sent to Azure.
        Write-Host ''
        Write-Host '  terraform plan' -ForegroundColor Cyan
        $planLog = & terraform plan -no-color -input=false 2>&1 | Out-String
        $summary.plan_exit = $LASTEXITCODE
        $summary.plan_log = $planLog
        $summary.plan_ok = ($LASTEXITCODE -eq 0)
        Write-Host ("    {0}" -f $(if ($summary.plan_ok) { 'ok' } else { "exit $LASTEXITCODE" })) `
            -ForegroundColor $(if ($summary.plan_ok) { 'Green' } else { 'Yellow' })

        # The specific failure that answers H1. Recorded as a flag as well as a
        # log, so the findings file can cite it without anyone reading 200 lines.
        $bodyRejected = $planLog -match 'Unsupported argument.*body|body.*not expected here|An argument named "body" is not expected'
        $summary.body_rejected_on_allocation = [bool]$bodyRejected
        # The other failure mode, and the one seen on azapi 2.x: the type is not
        # in the embedded schema at all, so nothing can be said about the body
        # until validation is switched off.
        $summary.type_unknown_to_azapi = [bool]($planLog -match "resource type Microsoft\.Quota/groupQuotas.*can't be found")
        $summary.name_pattern_enforced = [bool]($planLog -match 'does not match pattern')
        if ($bodyRejected) {
            Write-Host ''
            Write-Host '    azapi rejected `body` on the allocation type.' -ForegroundColor Red
            Write-Host '    Allocation is not expressible as Terraform desired state.'
            Write-Host '    aqv-apply needs read-compare-write instead. That answers H1.'
        }
        elseif ($summary.plan_ok) {
            Write-Host ''
            Write-Host '    A body was accepted and the plan resolved.' -ForegroundColor Green
            Write-Host '    Allocation may be expressible as desired state. That answers H1.'
        }

        foreach ($line in ($planLog -split "`n" | Where-Object { $_ -match 'Error|error:' } | Select-Object -First 8)) {
            Write-Host ("      {0}" -f $line.Trim())
        }
    }
}
finally {
    Pop-Location
}

# H3. azurerm has no resource for any of this as of 2026-09. Recorded from the
# provider's own schema rather than from an issue thread.
Write-Host ''
Write-Host '  H3: does azurerm cover it?' -ForegroundColor Cyan
Write-Host '    Not checked automatically. Search the azurerm provider docs for'
Write-Host '    "groupQuota". As of 2026-09 there is no resource, and'
Write-Host '    hashicorp/terraform-provider-azurerm#29849 is the open request.'
$summary.azurerm_checked = $false

$null = Save-AqvCapture -Name '07-iac' -Summary $summary
Write-Host ''
Write-Host ("  Terraform files left in {0} for inspection." -f $dir) -ForegroundColor DarkGray
Write-Host ''
