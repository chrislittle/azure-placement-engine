<#
    .SYNOPSIS
    Diffs current quota against the baseline step 0 recorded. Writes nothing.

    .DESCRIPTION
    Run this whenever you want to know whether the tenant is back where it
    started. It needs nothing but the baseline, so it works after a failed step,
    after a teardown, or days later.

    Exit code 0 means no drift. 1 means something differs.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

$baselineFile = Assert-AqvBaseline
$snapshot = Get-Content $baselineFile -Raw | ConvertFrom-Json
$baseline = $snapshot.summary.baseline
$cfgFile = Join-Path (Get-AqvOutputDir) 'run-config.json'

# Step 0 records the subscription ids in the baseline itself, so this works even
# when step 1 was never run.
$subs = [ordered]@{}
foreach ($label in @('donor', 'target')) {
    $id = Get-AqvProp $baseline $label 'subscription_id'
    if ($id) { $subs[$label] = $id }
}
$region = Get-AqvProp $baseline 'donor' 'region'

Write-Host ''
Write-Host ("  Baseline taken {0}" -f $snapshot.captured) -ForegroundColor Cyan
Write-Host ("  Region {0}" -f $region)
Write-Host ''

$drift = @()
foreach ($label in $subs.Keys) {
    $want = @(Get-AqvProp $baseline $label 'families')
    $now = Invoke-AqvApi -Method GET `
        -Path "/subscriptions/$($subs[$label])/providers/Microsoft.Compute/locations/$region/usages" `
        -ApiVersion '2024-07-01' -Purpose "compare: $label"

    foreach ($v in @(Get-AqvProp $now.Body 'value')) {
        $name = Get-AqvProp $v 'name' 'value'
        $was = @($want | Where-Object { $_.name -eq $name })
        if ($was.Count -eq 0) { continue }
        $limitNow = Get-AqvProp $v 'limit'
        if ($was[0].limit -ne $limitNow) {
            $drift += [pscustomobject]@{
                Subscription = $label
                Family       = $name
                Baseline     = $was[0].limit
                Now          = $limitNow
                Delta        = $limitNow - $was[0].limit
            }
        }
    }
}

if ($drift.Count -eq 0) {
    Write-Host '  No drift. Every family matches the baseline.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Write-Host ("  {0} families differ from the baseline:" -f $drift.Count) -ForegroundColor Yellow
Write-Host ''
$drift | Sort-Object Subscription, Family | Format-Table -AutoSize | Out-String -Width 120 | Write-Host

# Drift is not automatically a problem. A quota increase somebody else made, or
# a regional cap Azure moved on its own, both show up here.
Write-Host '  Drift is not always this collector''s doing. Azure raises the regional'
Write-Host '  cap on its own when a family limit goes up, and anyone with quota rights'
Write-Host '  can change these. Check the dates before assuming.'
Write-Host ''
Write-Host '  To put it back: ./Step08-Teardown.ps1 -WhatIf, then without -WhatIf.'
Write-Host ''
exit 1
