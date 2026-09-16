<#
    .SYNOPSIS
    Runs every conformance scenario through the PowerShell placement logic.

    .DESCRIPTION
    The same scenarios that conformance/terraform runs. The decision logic
    exists twice -- once in HCL for the Terraform path, once in PowerShell for
    the Bicep path -- and this is what stops the two drifting apart.

    Exits non-zero on any mismatch, so it can gate a pipeline.
#>
[CmdletBinding()]
param(
    [string]$ScenarioPath = (Join-Path $PSScriptRoot '..' 'scenarios'),
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' '..' 'powershell' 'AqvDecide.psm1') -Force

# Scenario key -> how to pull the same value off a decision.
$checks = [ordered]@{
    'status'                     = { param($d) $d.status }
    'family'                     = { param($d) $d.family }
    'writes_required'            = { param($d) @($d.writes_required).Count }
    'considered'                 = { param($d) @($d.considered).Count }
    'target_limit'               = { param($d) $d.target_limit }
    'regional_increase_required' = { param($d) $d.regional.increase_required }
    'requestable'                = { param($d) $d.access.requestable }
    'region_zonal'               = { param($d) $d.access.region_zonal }
    'not_offered'                = { param($d) @($d.access.not_offered).Count }
    'sizes'                      = { param($d) @($d.sizes).Count }
    'size_names'                 = { param($d) (@($d.sizes) | ForEach-Object name) -join ',' }
    'rule_applied'               = { param($d) $d.rule_applied }
}

$failed = 0
$run = 0

foreach ($file in Get-ChildItem -Path $ScenarioPath -Filter '*.json' | Sort-Object Name) {
    $run++
    $name = $file.BaseName
    $s = Get-Content $file.FullName -Raw | ConvertFrom-Json

    try {
        $d = Get-AqvDecision -Request $s.request -Quota $s.quota -SkuAccess $s.sku_access -Rules $s.rules
    }
    catch {
        $failed++
        Write-Host ("  FAIL  {0}" -f $name) -ForegroundColor Red
        Write-Host ("          threw: {0}" -f $_.Exception.Message) -ForegroundColor Red
        continue
    }

    $problems = foreach ($key in $checks.Keys) {
        if (-not $s.expect.PSObject.Properties[$key]) { continue }
        $want = $s.expect.$key
        $got = & $checks[$key] $d
        if ($got -ne $want) {
            "{0}: expected '{1}', got '{2}'" -f $key, $want, $got
        }
    }
    $problems = @($problems)

    if ($problems.Count -gt 0) {
        $failed++
        Write-Host ("  FAIL  {0}" -f $name) -ForegroundColor Red
        $problems | ForEach-Object { Write-Host ("          {0}" -f $_) -ForegroundColor Red }
    }
    elseif ($Detailed) {
        Write-Host ("  ok    {0,-54} {1}" -f $name, $d.status) -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host ("Success! {0} scenarios passed." -f $run) -ForegroundColor Green
    exit 0
}

Write-Host ("Failure! {0} passed, {1} failed." -f ($run - $failed), $failed) -ForegroundColor Red
exit 1
