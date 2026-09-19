<#
    .SYNOPSIS
    Step 5. Allocates quota from the group to the target subscription.
    WRITES TO AZURE. This is the operation vending depends on.

    .DESCRIPTION
    UNTESTED against a live group. Answers D1 to D6.

    Three things happen here, in order, and each one answers a question:

      1. Allocate. Records the body, the headers and the poll sequence.
      2. Allocate the SAME number again. If the limit doubles, `limit` is a
         delta and aqv-apply is the wrong shape. If it stays put, it is
         absolute, which is what AQV assumes.
      3. Poll Microsoft.Compute until it reports the new limit, and time it.
         AQV reads that API, not the group API, so a lag here decides whether
         stage 2 needs a retry loop.

    Reversed by step 8.
#>
[CmdletBinding()]
param(
    # Skip the second identical allocation. Only if the first one behaved badly
    # enough that repeating it would make the tenant harder to put back.
    [switch]$SkipIdempotencyCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 5 -Title 'Allocate quota to the target' -Writes

$null = Assert-AqvBaseline
$cfg = Get-Content (Join-Path (Get-AqvOutputDir) 'run-config.json') -Raw | ConvertFrom-Json
$summary = [ordered]@{}

$before = Get-AqvFamilyLimit -SubscriptionId $cfg.target_subscription_id -Region $cfg.region `
    -Family $cfg.family -Purpose 'D1: target limit before'
if (-not $before.Found) { throw ("{0} is not reported on the target in {1}." -f $cfg.family, $cfg.region) }

$newLimit = $before.Limit + $cfg.cores
Write-Host ("  Target {0}: limit {1}, used {2}" -f $before.Name, $before.Limit, $before.Used)
Write-Host ("  Asking for a new limit of {0}" -f $newLimit)
Write-Host ''
$summary.before = [ordered]@{ name = $before.Name; limit = $before.Limit; used = $before.Used }
$summary.requested_limit = $newLimit

# --- D1, D4, D5: the allocation -----------------------------------------
$a = Invoke-AqvAllocation -ManagementGroupId $cfg.management_group_id -GroupName $cfg.group_name `
    -SubscriptionId $cfg.target_subscription_id -Region $cfg.region -Family $cfg.family `
    -Limit $newLimit -Purpose 'D1/D4/D5: allocate to the target'

Write-Host ("  PATCH HTTP {0}, submit {1} ms, poll {2} ms, final {3}" -f
    $a.status, $a.submit_ms, $a.poll_ms, $a.final_state) `
    -ForegroundColor $(if ($a.succeeded) { 'Green' } else { 'Yellow' })
Write-Host ("  poll states: {0}" -f (@($a.poll_states) -join ' -> '))
$summary.allocation = $a
$summary.total_ms = $a.submit_ms + $a.poll_ms

if ($a.final_state -eq 'NO_POLL_HEADER') {
    Write-Host '  202 with no Location or Azure-AsyncOperation header.' -ForegroundColor Yellow
    Write-Host '  There is no documented way to poll this. Record it: it decides how aqv-apply waits.'
}

if (-not $a.succeeded) {
    Write-Host '  It did not succeed. The response is the finding:' -ForegroundColor Yellow
    Write-Host ("  {0}" -f ($a.response | ConvertTo-Json -Depth 8 -Compress))
    $null = Save-AqvCapture -Name '05-allocate' -Summary $summary
    return
}

# --- D6: when does Microsoft.Compute agree? -----------------------------
# The whole of AQV reads this API. If the group write lands but Microsoft.Compute
# lags, a pipeline that allocates and then reads gets stale numbers and decides
# on them.
Write-Host ''
Write-Host '  D6: waiting for Microsoft.Compute to report the new limit' -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$seen = $null
$polls = @()
while ($sw.Elapsed.TotalSeconds -lt 600) {
    $now = Get-AqvFamilyLimit -SubscriptionId $cfg.target_subscription_id -Region $cfg.region `
        -Family $cfg.family -Purpose 'D6: poll Microsoft.Compute for the new limit'
    $polls += [ordered]@{ at_ms = [int]$sw.ElapsedMilliseconds; limit = $now.Limit }
    Write-Host ("    {0,6} ms  limit {1}" -f [int]$sw.ElapsedMilliseconds, $now.Limit)
    if ($now.Limit -ge $newLimit) { $seen = [int]$sw.ElapsedMilliseconds; break }
    Start-Sleep -Seconds 20
}
$sw.Stop()
$summary.compute_lag_ms = $seen
$summary.compute_polls = $polls
if ($null -ne $seen) {
    Write-Host ("    Microsoft.Compute agreed after {0} ms." -f $seen) -ForegroundColor Green
}
else {
    Write-Host '    Microsoft.Compute never reported the new limit inside 10 minutes.' -ForegroundColor Red
    Write-Host '    That is a significant finding: AQV reads this API to decide.'
}

# --- D2, D3: absolute or delta, and is it idempotent? -------------------
if (-not $SkipIdempotencyCheck) {
    Write-Host ''
    Write-Host '  D2/D3: the same allocation again, same number' -ForegroundColor Cyan
    $b = Invoke-AqvAllocation -ManagementGroupId $cfg.management_group_id -GroupName $cfg.group_name `
        -SubscriptionId $cfg.target_subscription_id -Region $cfg.region -Family $cfg.family `
        -Limit $newLimit -Purpose 'D2/D3: repeat the identical allocation'
    $summary.repeat = $b
    Write-Host ("    HTTP {0}, final {1}" -f $b.status, $b.final_state)

    Start-Sleep -Seconds 30
    $after2 = Get-AqvFamilyLimit -SubscriptionId $cfg.target_subscription_id -Region $cfg.region `
        -Family $cfg.family -Purpose 'D2: limit after the repeat'
    $summary.limit_after_repeat = $after2.Limit

    Write-Host ("    limit after the repeat: {0}" -f $after2.Limit)
    if ($after2.Limit -eq $newLimit) {
        $summary.limit_semantics = 'absolute'
        Write-Host '    Unchanged. `limit` is ABSOLUTE, and the call is idempotent.' -ForegroundColor Green
        Write-Host '    That matches what AQV already assumes.'
    }
    elseif ($after2.Limit -gt $newLimit) {
        $summary.limit_semantics = 'delta'
        Write-Host '    It went UP. `limit` is a DELTA, not an absolute value.' -ForegroundColor Red
        Write-Host '    aqv-apply cannot be desired state against this. Record it prominently.'
    }
    else {
        $summary.limit_semantics = 'unclear'
        Write-Host '    It went down. Neither reading fits. Record the numbers.' -ForegroundColor Yellow
    }
}

$null = Save-AqvCapture -Name '05-allocate' -Summary $summary
Write-Host ''
Write-Host '  Step 8 puts this back.' -ForegroundColor DarkGray
Write-Host ''
