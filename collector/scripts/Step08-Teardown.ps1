<#
    .SYNOPSIS
    Step 8. Puts the quota back and leaves the group as it found it.
    WRITES TO AZURE.

    .DESCRIPTION
    Safe to run at any point, including after a step failed halfway. It works
    from the baseline step 0 recorded, so it does not care which of steps 3 to 6
    actually ran.

    What it does, in reverse order of how it was built:
      1. Allocates every changed family back to its baseline limit.
      2. Removes ONLY the subscriptions step 3 added.

    What it does NOT do: delete your quota group. The collector joins a group
    you already have, so removing it would be destroying something it did not
    create. A sandbox group made with New-SandboxGroup.ps1 is deleted only when
    you pass -DeleteSandboxGroup.

    -WhatIf shows what it would do and changes nothing. Run that first.

    .PARAMETER KeepMembership
    Put the quota back but leave the subscriptions in the group. Use this
    between runs.

    .PARAMETER DeleteSandboxGroup
    Also delete the group. Only for a group this collector created with
    New-SandboxGroup.ps1. It refuses on a group it did not create.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$KeepMembership,
    [switch]$DeleteSandboxGroup
)

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

# --- 2. Membership ------------------------------------------------------
# Only the subscriptions step 3 added. A subscription that was in the group
# before this run stays in it, because taking it out would be a change nobody
# asked for.
$base = "/providers/Microsoft.Management/managementGroups/$($cfg.management_group_id)/providers/Microsoft.Quota/groupQuotas/$($cfg.group_name)"
$mine = @(Get-AqvProp $cfg 'members_added_by_collector')

if ($KeepMembership) {
    Write-Host ''
    Write-Host '  Membership kept, as asked.' -ForegroundColor DarkGray
}
elseif ($mine.Count -eq 0) {
    Write-Host ''
    Write-Host '  This run added no subscriptions to the group. Nothing to remove.' -ForegroundColor DarkGray
    $summary.membership = 'nothing was added by this run'
}
else {
    Write-Host ''
    Write-Host '  Membership' -ForegroundColor Cyan
    foreach ($sub in $mine) {
        $label = if ($sub -eq $cfg.donor_subscription_id) { 'donor' } else { 'target' }
        if ($PSCmdlet.ShouldProcess("$label ($sub)", 'remove from the quota group')) {
            $r = Invoke-AqvApi -Method DELETE -Path "$base/subscriptions/$sub" -ApiVersion '2025-09-01' `
                -Purpose "teardown: remove $label from the group"
            Write-Host ("    {0,-8} HTTP {1}" -f $label, $r.Status) `
                -ForegroundColor $(if ($r.Ok -or $r.Status -eq 404) { 'Green' } else { 'Yellow' })
            $actions += [ordered]@{ action = 'remove-member'; detail = $label; status = $r.Status }
        }
    }
}

# --- 3. The group -------------------------------------------------------
# Never by default. The collector joins a group someone else made.
if ($DeleteSandboxGroup) {
    $sandbox = Get-AqvProp $cfg 'group_created_by_collector'
    if (-not $sandbox) {
        Write-Host ''
        Write-Host ("  Refusing to delete '{0}'." -f $cfg.group_name) -ForegroundColor Red
        Write-Host '  run-config.json does not record this collector creating it, so it is'
        Write-Host '  someone else''s group. Delete it yourself if you are sure.'
        $summary.group_delete_refused = $cfg.group_name
    }
    elseif ($PSCmdlet.ShouldProcess($cfg.group_name, 'delete the sandbox quota group')) {
        Write-Host ''
        Write-Host '  Group' -ForegroundColor Cyan
        $r = Invoke-AqvApi -Method DELETE -Path $base -ApiVersion '2025-09-01' -Purpose 'teardown: delete the sandbox group'
        Write-Host ("    DELETE groupQuotas/{0}  HTTP {1}" -f $cfg.group_name, $r.Status) `
            -ForegroundColor $(if ($r.Ok -or $r.Status -eq 404) { 'Green' } else { 'Yellow' })
        $actions += [ordered]@{ action = 'delete-group'; detail = $cfg.group_name; status = $r.Status }
        if (-not ($r.Ok -or $r.Status -eq 404)) {
            Write-Host ("    {0}" -f ($r.Body | ConvertTo-Json -Depth 6 -Compress))
            Write-Host '    Delete refused. Record it: how a group is wound down is a finding.' -ForegroundColor Yellow
        }
    }
}
else {
    Write-Host ''
    Write-Host ("  Group '{0}' left alone. It is not this collector's to delete." -f $cfg.group_name) -ForegroundColor DarkGray
}

$summary.actions = $actions
if (-not $WhatIfPreference) {
    $null = Save-AqvCapture -Name '08-teardown' -Summary $summary
}

Write-Host ''
Write-Host '  Confirm with: ./Compare-Baseline.ps1' -ForegroundColor Cyan
Write-Host ''
