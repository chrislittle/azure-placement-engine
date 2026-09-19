<#
    .SYNOPSIS
    Step 8. Puts the quota back and removes the group. WRITES TO AZURE.

    .DESCRIPTION
    Safe to run at any point, including after a step failed halfway. It reads
    the baseline step 0 recorded and works towards it, so it does not care which
    of steps 3 to 6 actually ran.

    Order matters and is the reverse of how it was built:
      1. Allocate every changed family back to its baseline limit.
      2. Remove the subscriptions from the group.
      3. Delete the group.

    -WhatIf shows what it would do and changes nothing. Run that first.

    .PARAMETER KeepGroup
    Put the quota back but leave the group in place. Use this between runs.
#>
[CmdletBinding(SupportsShouldProcess)]
param([switch]$KeepGroup)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 8 -Title 'Put it back' -Writes

$baselineFile = Assert-AqvBaseline
$baseline = (Get-Content $baselineFile -Raw | ConvertFrom-Json).summary.baseline
$cfg = Get-Content (Join-Path (Get-AqvOutputDir) 'run-config.json') -Raw | ConvertFrom-Json

$summary = [ordered]@{}
$actions = @()

# --- 1. Quota back to baseline ------------------------------------------
Write-Host '  Comparing current quota against the step 0 baseline' -ForegroundColor Cyan
$drift = @()
foreach ($label in @('donor', 'target')) {
    $sub = if ($label -eq 'donor') { $cfg.donor_subscription_id } else { $cfg.target_subscription_id }
    $want = @(Get-AqvProp $baseline $label 'families')

    $now = Invoke-AqvApi -Method GET `
        -Path "/subscriptions/$sub/providers/Microsoft.Compute/locations/$($cfg.region)/usages" `
        -ApiVersion '2024-07-01' -Purpose "teardown: $label quota now"

    foreach ($v in @(Get-AqvProp $now.Body 'value')) {
        $name = Get-AqvProp $v 'name' 'value'
        $limitNow = Get-AqvProp $v 'limit'
        $was = @($want | Where-Object { $_.name -eq $name })
        if ($was.Count -eq 0) { continue }
        if ($was[0].limit -ne $limitNow) {
            $drift += [ordered]@{
                subscription = $label
                family       = $name
                baseline     = $was[0].limit
                now          = $limitNow
            }
        }
    }
}
$summary.drift = $drift

if ($drift.Count -eq 0) {
    Write-Host '    No drift. Quota already matches the baseline.' -ForegroundColor Green
}
else {
    Write-Host ("    {0} families differ from the baseline:" -f $drift.Count) -ForegroundColor Yellow
    $drift | ForEach-Object {
        Write-Host ("      {0,-8} {1,-30} {2} -> {3}" -f $_.subscription, $_.family, $_.baseline, $_.now)
    }

    foreach ($d in $drift) {
        $sub = if ($d.subscription -eq 'donor') { $cfg.donor_subscription_id } else { $cfg.target_subscription_id }
        $what = "{0}: {1} back to {2}" -f $d.subscription, $d.family, $d.baseline
        if ($PSCmdlet.ShouldProcess($what, 'allocate back to baseline')) {
            $r = Invoke-AqvAllocation -ManagementGroupId $cfg.management_group_id -GroupName $cfg.group_name `
                -SubscriptionId $sub -Region $cfg.region -Family $d.family -Limit $d.baseline `
                -Purpose "teardown: $what" -TimeoutSeconds 600
            Write-Host ("      {0}  HTTP {1} {2}" -f $what, $r.status, $r.final_state) `
                -ForegroundColor $(if ($r.succeeded) { 'Green' } else { 'Red' })
            $actions += [ordered]@{ action = 'restore'; detail = $what; status = $r.status; state = $r.final_state }
            if (-not $r.succeeded) {
                Write-Host '      It did not go back. Do NOT stop here.' -ForegroundColor Red
                Write-Host '      Run Compare-Baseline.ps1 and send the result with the package.'
            }
        }
    }
}

# --- 2 and 3. Membership and the group ----------------------------------
# Only ever removes the group THIS run created. A group that was already there
# is left alone, whatever else happened.
$mine = ($cfg.group_name -eq 'aqvcollector')
if ($KeepGroup) {
    Write-Host ''
    Write-Host '  Group kept, as asked.' -ForegroundColor DarkGray
}
elseif (-not $mine) {
    Write-Host ''
    Write-Host ("  Group '{0}' was not created by this collector. Leaving it alone." -f $cfg.group_name) -ForegroundColor Yellow
    Write-Host '  Remove it yourself if you want it gone.'
    $summary.group_left_alone = $cfg.group_name
}
else {
    $base = "/providers/Microsoft.Management/managementGroups/$($cfg.management_group_id)/providers/Microsoft.Quota/groupQuotas/$($cfg.group_name)"

    Write-Host ''
    Write-Host '  Membership' -ForegroundColor Cyan
    foreach ($label in @('donor', 'target')) {
        $sub = if ($label -eq 'donor') { $cfg.donor_subscription_id } else { $cfg.target_subscription_id }
        if ($PSCmdlet.ShouldProcess("$label ($sub)", 'remove from the quota group')) {
            $r = Invoke-AqvApi -Method DELETE -Path "$base/subscriptions/$sub" -ApiVersion '2025-09-01' `
                -Purpose "teardown: remove $label from the group"
            Write-Host ("    {0,-8} HTTP {1}" -f $label, $r.Status) `
                -ForegroundColor $(if ($r.Ok -or $r.Status -eq 404) { 'Green' } else { 'Yellow' })
            $actions += [ordered]@{ action = 'remove-member'; detail = $label; status = $r.Status }
        }
    }

    Write-Host ''
    Write-Host '  Group' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($cfg.group_name, 'delete the quota group')) {
        $r = Invoke-AqvApi -Method DELETE -Path $base -ApiVersion '2025-09-01' -Purpose 'teardown: delete the group'
        Write-Host ("    DELETE groupQuotas/{0}  HTTP {1}" -f $cfg.group_name, $r.Status) `
            -ForegroundColor $(if ($r.Ok -or $r.Status -eq 404) { 'Green' } else { 'Yellow' })
        $actions += [ordered]@{ action = 'delete-group'; detail = $cfg.group_name; status = $r.Status }
        if (-not ($r.Ok -or $r.Status -eq 404)) {
            Write-Host ("    {0}" -f ($r.Body | ConvertTo-Json -Depth 6 -Compress))
            Write-Host '    Delete refused. That is itself a finding: record how a group is wound down.' -ForegroundColor Yellow
        }
    }
}

$summary.actions = $actions
if (-not $WhatIfPreference) {
    $null = Save-AqvCapture -Name '08-teardown' -Summary $summary
}

Write-Host ''
Write-Host '  Confirm with: ./Compare-Baseline.ps1' -ForegroundColor Cyan
Write-Host ''
