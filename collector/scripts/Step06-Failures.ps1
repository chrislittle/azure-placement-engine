<#
    .SYNOPSIS
    Step 6. Asks for things Azure should refuse, and records how it refuses.
    WRITES TO AZURE, and every write is expected to fail.

    .DESCRIPTION
    UNTESTED against a live group. Answers F1, F2, F3, C2 and C3.

    A refusal AQV can predict becomes a clear answer at vending time. A refusal
    it cannot predict becomes a failed pipeline after the subscription was
    handed over. That is the whole reason for this step.

    Each case is expected to fail. A case that SUCCEEDS is the interesting
    result, and the script says so.

    .PARAMETER GrowthRestrictedFamily
    A family under the July 2026 capacity growth restrictions, from
    knowledge/vm-series-lifecycle.yaml. Answers F2: whether a quota group can
    route around a growth restriction. Skipped if not supplied.

    .PARAMETER ForeignSubscriptionId
    A subscription that is in a DIFFERENT quota group. Answers C3. Skipped if
    not supplied.
#>
[CmdletBinding()]
param(
    [string]$GrowthRestrictedFamily,
    [string]$ForeignSubscriptionId,
    [string]$UnreachableRegion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 6 -Title 'Record how Azure refuses' -Writes

$null = Assert-AqvBaseline
$cfg = Get-Content (Join-Path (Get-AqvOutputDir) 'run-config.json') -Raw | ConvertFrom-Json
$summary = [ordered]@{}
$cases = [ordered]@{}

function Invoke-AqvCase {
    param([string]$Id, [string]$What, [hashtable]$Args, [string]$ExpectedToFail = 'yes')
    Write-Host ''
    Write-Host ("  {0}: {1}" -f $Id, $What) -ForegroundColor Cyan
    $r = Invoke-AqvAllocation @Args -Purpose "$Id`: $What" -TimeoutSeconds 300
    $failed = -not $r.succeeded
    $colour = if ($failed) { 'Green' } else { 'Red' }
    Write-Host ("    HTTP {0}, final {1}" -f $r.status, $r.final_state) -ForegroundColor $colour
    if ($r.response) {
        Write-Host ("    {0}" -f ($r.response | ConvertTo-Json -Depth 8 -Compress))
    }
    if (-not $failed -and $ExpectedToFail -eq 'yes') {
        Write-Host '    It SUCCEEDED. That was not expected. Record it prominently.' -ForegroundColor Red
    }
    return [ordered]@{
        what              = $What
        expected_to_fail  = ($ExpectedToFail -eq 'yes')
        actually_failed   = $failed
        status            = $r.status
        final_state       = $r.final_state
        error             = $r.response
        request           = $r.request
    }
}

$common = @{
    ManagementGroupId = $cfg.management_group_id
    GroupName         = $cfg.group_name
    Region            = $cfg.region
    Family            = $cfg.family
}

# --- F1: more than the group holds --------------------------------------
# aqv-decide is meant to predict this rather than let the apply fail, so the
# error has to be distinguishable from the others.
$cases.F1 = Invoke-AqvCase -Id 'F1' -What 'allocate far more than the group holds' -Args (
    $common + @{ SubscriptionId = $cfg.target_subscription_id; Limit = 999999 })

# --- C2: a subscription that is not a member ----------------------------
# The READ works on a non-member and returns that subscription's own quota, so
# the read cannot be used as a membership check. Whether the WRITE refuses is
# what decides if AQV needs its own precondition.
if ($ForeignSubscriptionId) {
    $cases.C2 = Invoke-AqvCase -Id 'C2' -What 'allocate to a subscription that is not in the group' -Args (
        $common + @{ SubscriptionId = $ForeignSubscriptionId; Limit = ($cfg.cores + 2) })
}
else {
    Write-Host ''
    Write-Host '  C2 skipped: no -ForeignSubscriptionId supplied.' -ForegroundColor DarkGray
    $cases.C2 = 'not exercised'
}

# --- F2: a growth-restricted family -------------------------------------
# Significant either way. If group quota can grow a family that a
# per-subscription request cannot, the lifecycle gate in aqv-decide does not
# apply to this path, and that changes the decision logic.
if ($GrowthRestrictedFamily) {
    $f2 = $common.Clone()
    $f2.Family = $GrowthRestrictedFamily
    $f2.SubscriptionId = $cfg.target_subscription_id
    $f2.Limit = $cfg.cores + 2
    $cases.F2 = Invoke-AqvCase -Id 'F2' -What ("allocate a growth-restricted family ({0})" -f $GrowthRestrictedFamily) -Args $f2
}
else {
    Write-Host ''
    Write-Host '  F2 skipped: no -GrowthRestrictedFamily supplied.' -ForegroundColor DarkGray
    Write-Host '  Pick one from knowledge/vm-series-lifecycle.yaml. This answer matters.'
    $cases.F2 = 'not exercised'
}

# --- D7: a region the subscription cannot reach -------------------------
# AQV checks access before quota, on the assumption that group quota grants no
# regional access. This is what proves the assumption.
if ($UnreachableRegion) {
    $d7 = $common.Clone()
    $d7.Region = $UnreachableRegion
    $d7.SubscriptionId = $cfg.target_subscription_id
    $d7.Limit = 8
    $cases.D7 = Invoke-AqvCase -Id 'D7' -What ("allocate in a region the subscription cannot reach ({0})" -f $UnreachableRegion) -Args $d7
}
else {
    Write-Host ''
    Write-Host '  D7 skipped: no -UnreachableRegion supplied.' -ForegroundColor DarkGray
    $cases.D7 = 'not exercised'
}

# --- F3: is anything retryable? -----------------------------------------
# AQV treats every quota refusal as terminal. If a refusal here succeeds on a
# second attempt, that is wrong and the retry policy has to change.
Write-Host ''
Write-Host '  F3: retrying the F1 refusal' -ForegroundColor Cyan
$retry = Invoke-AqvAllocation @common -SubscriptionId $cfg.target_subscription_id -Limit 999999 `
    -Purpose 'F3: retry a known refusal' -TimeoutSeconds 300
$cases.F3 = [ordered]@{
    what            = 'the same over-allocation, a second time'
    status          = $retry.status
    final_state     = $retry.final_state
    same_as_first   = ($retry.status -eq $cases.F1.status)
    error           = $retry.response
}
Write-Host ("    HTTP {0}, same as the first attempt: {1}" -f $retry.status, $cases.F3.same_as_first)
if ($retry.succeeded) {
    Write-Host '    It succeeded on the retry. Refusals are NOT terminal. Record this.' -ForegroundColor Red
}

$summary.cases = $cases
$null = Save-AqvCapture -Name '06-failures' -Summary $summary

Write-Host ''
Write-Host '  Summary' -ForegroundColor Cyan
foreach ($k in $cases.Keys) {
    $c = $cases[$k]
    if ($c -is [string]) { Write-Host ("    {0,-4} {1}" -f $k, $c); continue }
    Write-Host ("    {0,-4} HTTP {1,-5} {2}" -f $k, $c.status, $c.what)
}
Write-Host ''
