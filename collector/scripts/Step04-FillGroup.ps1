<#
    .SYNOPSIS
    Step 4. Moves quota OUT of the donor subscription into the group.
    WRITES TO AZURE, and lowers the donor's limit.

    .DESCRIPTION
    UNTESTED against a live group. Answers E1, E2, E3, B3 and B4.

    This is the operation that makes quota groups worth having: an estate can
    reclaim quota nobody is using and hand it to a new subscription, without
    contacting Microsoft. If it needs a ticket, quota groups do not solve the
    problem AQV was built for.

    Reversed by step 8.

    .PARAMETER BelowUsed
    Also try to move quota out below what the donor is USING. Answers E2. Only
    meaningful when the donor has running vCPUs. Off by default, because on a
    donor with running workloads a success here would be a problem, not a result.
#>
[CmdletBinding()]
param([switch]$BelowUsed)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 4 -Title 'Move quota into the group' -Writes

$null = Assert-AqvBaseline
$cfg = Get-Content (Join-Path (Get-AqvOutputDir) 'run-config.json') -Raw | ConvertFrom-Json
$summary = [ordered]@{}

$before = Get-AqvFamilyLimit -SubscriptionId $cfg.donor_subscription_id -Region $cfg.region `
    -Family $cfg.family -Purpose 'E1: donor limit before'
if (-not $before.Found) { throw ("{0} is not reported on the donor in {1}." -f $cfg.family, $cfg.region) }

$target = $before.Limit - $cfg.cores
Write-Host ("  Donor {0}: limit {1}, used {2}" -f $before.Name, $before.Limit, $before.Used)
Write-Host ("  Moving {0} cores into the group, so the donor's limit becomes {1}" -f $cfg.cores, $target)
Write-Host ''

if ($target -lt $before.Used) {
    Write-Host '  That target is below what the donor is using. Stopping.' -ForegroundColor Red
    Write-Host '  Lower -Cores in step 1, or use -BelowUsed deliberately to answer E2.'
    if (-not $BelowUsed) { return }
}

$summary.before = [ordered]@{ name = $before.Name; limit = $before.Limit; used = $before.Used }
$summary.requested_limit = $target

# E1/E3: the same call as an allocation, with a lower number. Whether that is
# true is the question.
$a = Invoke-AqvAllocation -ManagementGroupId $cfg.management_group_id -GroupName $cfg.group_name `
    -SubscriptionId $cfg.donor_subscription_id -Region $cfg.region -Family $cfg.family `
    -Limit $target -Purpose 'E1/E3: move quota out of the donor into the group'

Write-Host ("  PATCH HTTP {0}, submit {1} ms, poll {2} ms, final {3}" -f
    $a.status, $a.submit_ms, $a.poll_ms, $a.final_state) `
    -ForegroundColor $(if ($a.succeeded) { 'Green' } else { 'Yellow' })
$summary.allocation = $a

if (-not $a.succeeded) {
    Write-Host '  It did not succeed. The response is the finding:' -ForegroundColor Yellow
    Write-Host ("  {0}" -f ($a.response | ConvertTo-Json -Depth 8 -Compress))
}

# B4/E1: did the donor's limit actually move, and did the group gain anything?
Write-Host ''
Write-Host '  After' -ForegroundColor Cyan
$after = Get-AqvFamilyLimit -SubscriptionId $cfg.donor_subscription_id -Region $cfg.region `
    -Family $cfg.family -Purpose 'E1: donor limit after'
$summary.after = [ordered]@{ limit = $after.Limit; used = $after.Used }
Write-Host ("    donor limit {0} -> {1}" -f $before.Limit, $after.Limit)

$base = "/providers/Microsoft.Management/managementGroups/$($cfg.management_group_id)/providers/Microsoft.Quota/groupQuotas/$($cfg.group_name)"
$rp = "$base/resourceProviders/Microsoft.Compute"

$gl = Invoke-AqvApi -Method GET -Path "$rp/groupQuotaLimits/$($cfg.region)" -ApiVersion '2025-09-01' `
    -Purpose 'B1/B2: what the group holds now'
$summary.group_quota_limits_after = $gl.Body
$glEmpty = ($null -eq $gl.Body) -or (@($gl.Body.PSObject.Properties).Count -eq 0)
Write-Host ("    groupQuotaLimits: {0}" -f $(if ($glEmpty) { 'still empty' } else { 'HOLDS SOMETHING - this is the case AQV has never read' })) `
    -ForegroundColor $(if ($glEmpty) { 'Yellow' } else { 'Green' })
if (-not $glEmpty) {
    Write-Host ("    {0}" -f ($gl.Body | ConvertTo-Json -Depth 8 -Compress))
}

# B3: shareableQuota read 0 on every family in an empty group. This is the first
# chance to see it carry a number.
$qa = Invoke-AqvApi -Method GET `
    -Path "/providers/Microsoft.Management/managementGroups/$($cfg.management_group_id)/subscriptions/$($cfg.donor_subscription_id)/providers/Microsoft.Quota/groupQuotas/$($cfg.group_name)/resourceProviders/Microsoft.Compute/quotaAllocations/$($cfg.region)" `
    -ApiVersion '2025-09-01' -Purpose 'B3/B4: shareableQuota and sign convention after the move'

$row = @(Get-AqvProp $qa.Body 'value' |
    Where-Object { (Get-AqvProp $_ 'properties' 'resourceName') -eq $cfg.family.ToLowerInvariant() })
if ($row.Count -gt 0) {
    $summary.allocation_row_after = Get-AqvProp $row[0] 'properties'
    Write-Host ("    quotaAllocations for {0}: {1}" -f $cfg.family, ($summary.allocation_row_after | ConvertTo-Json -Depth 5 -Compress))
    $sq = Get-AqvProp $row[0] 'properties' 'shareableQuota'
    if ($null -ne $sq -and $sq -lt 0) {
        Write-Host '    shareableQuota is NEGATIVE. That confirms the documented sign convention.' -ForegroundColor Green
    }
}

# E2: only when asked for, and only ever after the normal case is recorded.
if ($BelowUsed -and $after.Used -gt 0) {
    Write-Host ''
    Write-Host '  E2: moving below what is in use' -ForegroundColor Cyan
    $tooLow = [Math]::Max(0, $after.Used - 2)
    $b = Invoke-AqvAllocation -ManagementGroupId $cfg.management_group_id -GroupName $cfg.group_name `
        -SubscriptionId $cfg.donor_subscription_id -Region $cfg.region -Family $cfg.family `
        -Limit $tooLow -Purpose 'E2: move the donor below its used value'
    $summary.below_used = $b
    Write-Host ("    HTTP {0}, final {1}" -f $b.status, $b.final_state)
    $check = Get-AqvFamilyLimit -SubscriptionId $cfg.donor_subscription_id -Region $cfg.region `
        -Family $cfg.family -Purpose 'E2: donor limit after the below-used attempt'
    $summary.below_used_resulting_limit = $check.Limit
    Write-Host ("    donor limit is now {0}, used {1}" -f $check.Limit, $check.Used)
    if ($check.Limit -lt $check.Used) {
        Write-Host '    The limit is now BELOW usage. Azure allowed it. Record this prominently.' -ForegroundColor Red
    }
}
elseif ($BelowUsed) {
    Write-Host ''
    Write-Host '  E2 skipped: the donor is using 0 vCPUs, so there is nothing to strand.' -ForegroundColor DarkGray
    $summary.below_used = 'not exercised: donor usage is zero'
}

$null = Save-AqvCapture -Name '04-fill-group' -Summary $summary
Write-Host ''
