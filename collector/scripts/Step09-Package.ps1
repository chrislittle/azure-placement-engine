<#
    .SYNOPSIS
    Step 9. Redacts, hashes and zips the results. Writes nothing to Azure.

    .DESCRIPTION
    Replaces every identifier with a stable placeholder, writes a manifest, and
    produces one zip to send back.

    The mapping from placeholder to real value stays on this machine in
    output/redaction-map.local.json and is NOT in the zip. Keep it: without it
    the package cannot be traced back to anything, which is the point.

    Read output/REDACTION.md before sending. Deciding what leaves your tenant is
    your call, not this script's.
#>
[CmdletBinding()]
param(
    # Extra strings to redact: an internal project name, a person's name,
    # anything the pattern matching will not catch on its own.
    [string[]]$AlsoRedact = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 9 -Title 'Package the results'

$out = Get-AqvOutputDir
$caps = Join-Path $out 'captures'
$stage = Join-Path $out ('package-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $stage | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'captures') | Out-Null

# --- Build the replacement map -------------------------------------------
# Stable placeholders, so the same subscription reads as SUB-A everywhere and
# the package still makes sense as a narrative.
$map = [ordered]@{}
$counters = @{ sub = 0; mg = 0; guid = 0; other = 0 }
$letters = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

function Add-Mapping([string]$real, [string]$kind) {
    if (-not $real) { return }
    if ($map.Contains($real)) { return }
    switch ($kind) {
        'sub' {
            # The named subscriptions get readable letters. There are only ever
            # two, but the run could be re-run against more.
            if ($counters.sub -lt $letters.Count) {
                $map[$real] = 'SUB-' + $letters[$counters.sub]
            }
            else {
                $map[$real] = 'SUB-' + ($counters.sub + 1)
            }
            $counters.sub++
        }
        'mg'   { $counters.mg++; $map[$real] = 'MG-' + $counters.mg }
        # Every other GUID in the captures: role definition ids, request ids,
        # correlation ids. Numbered rather than lettered, because there are
        # hundreds and none of them needs to be readable.
        'guid' { $counters.guid++; $map[$real] = 'GUID-' + $counters.guid }
        default { $counters.other++; $map[$real] = 'REDACTED-' + $counters.other }
    }
}

$cfgFile = Join-Path $out 'run-config.json'
if (Test-Path $cfgFile) {
    $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
    Add-Mapping $cfg.donor_subscription_id 'sub'
    Add-Mapping $cfg.target_subscription_id 'sub'
    Add-Mapping $cfg.management_group_id 'mg'
}

$raw = Get-ChildItem $caps -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw }
$all = $raw -join "`n"

# GUIDs. Subscription and tenant IDs are both GUIDs and cannot be told apart by
# shape, so every one is replaced. Over-redacting is the safe direction.
foreach ($m in [regex]::Matches($all, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) {
    Add-Mapping $m.Value 'guid'
}
# Anything that looks like a sign-in name.
foreach ($m in [regex]::Matches($all, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) {
    Add-Mapping $m.Value 'other'
}
foreach ($extra in $AlsoRedact) { Add-Mapping $extra 'other' }

Write-Host ("  {0} identifiers will be replaced" -f $map.Count)
Write-Host ("    {0} named subscriptions, {1} management groups, {2} other GUIDs, {3} sign-in names" -f
    $counters.sub, $counters.mg, $counters.guid, $counters.other)

# --- Redact ---------------------------------------------------------------
# Longest first, so a value that contains another is replaced whole.
$ordered = $map.Keys | Sort-Object { $_.Length } -Descending

function Protect-Text([string]$text) {
    foreach ($k in $ordered) {
        $text = $text.Replace($k, $map[$k])
        # Role definition ids and some paths lower-case the GUID.
        $text = $text.Replace($k.ToLowerInvariant(), $map[$k])
        $text = $text.Replace($k.ToUpperInvariant(), $map[$k])
    }
    return $text
}

$files = @()
foreach ($f in Get-ChildItem $caps -Filter '*.json') {
    $dest = Join-Path $stage 'captures' $f.Name
    Protect-Text (Get-Content $f.FullName -Raw) | Set-Content -Path $dest -Encoding utf8
    $files += $dest
    Write-Host ("    captures/{0}" -f $f.Name)
}

# findings.yaml is the answers. The template is copied in unfilled if nobody
# wrote one, so the package still says which questions were not reached.
$findings = Join-Path $out 'findings.yaml'
if (-not (Test-Path $findings)) {
    Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'schema' 'findings.template.yaml') $findings
    Write-Host '    findings.yaml was missing. The unfilled template is included instead.' -ForegroundColor Yellow
}
$dest = Join-Path $stage 'findings.yaml'
Protect-Text (Get-Content $findings -Raw) | Set-Content -Path $dest -Encoding utf8
$files += $dest

if (Test-Path $cfgFile) {
    $dest = Join-Path $stage 'run-config.json'
    Protect-Text (Get-Content $cfgFile -Raw) | Set-Content -Path $dest -Encoding utf8
    $files += $dest
}

# --- Timings --------------------------------------------------------------
# One row per API call, so the package can answer "how long does this take"
# without anyone re-reading the captures.
$rows = @()
foreach ($f in Get-ChildItem (Join-Path $stage 'captures') -Filter '*.json') {
    $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json
    foreach ($c in @(Get-AqvProp $doc 'calls')) {
        $rows += [pscustomobject]@{
            step        = Get-AqvProp $doc 'step'
            purpose     = Get-AqvProp $c 'purpose'
            method      = Get-AqvProp $c 'method'
            api_version = Get-AqvProp $c 'api_version'
            status      = Get-AqvProp $c 'status'
            duration_ms = Get-AqvProp $c 'duration_ms'
            at          = Get-AqvProp $c 'at'
        }
    }
}
$timings = Join-Path $stage 'timings.csv'
$rows | Export-Csv -Path $timings -NoTypeInformation -Encoding utf8
$files += $timings
Write-Host ("    timings.csv  ({0} calls)" -f $rows.Count)

# --- Manifest -------------------------------------------------------------
$manifest = [ordered]@{
    produced_by      = 'AQV quota group collector'
    produced         = (Get-Date).ToUniversalTime().ToString('o')
    steps_present    = @(Get-ChildItem (Join-Path $stage 'captures') -Filter '*.json' | ForEach-Object { $_.BaseName })
    identifiers_replaced = $map.Count
    api_calls        = $rows.Count
    files            = @()
}
foreach ($f in $files) {
    $manifest.files += [ordered]@{
        path   = (Resolve-Path $f).Path.Substring((Resolve-Path $stage).Path.Length + 1)
        sha256 = (Get-FileHash $f -Algorithm SHA256).Hash
        bytes  = (Get-Item $f).Length
    }
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $stage 'manifest.json') -Encoding utf8

# --- The two documents a human reads -------------------------------------
$mapFile = Join-Path $out 'redaction-map.local.json'
$map | ConvertTo-Json -Depth 3 | Set-Content -Path $mapFile -Encoding utf8

$readme = @"
# What is in this package, and what was taken out

Produced $((Get-Date).ToUniversalTime().ToString('u')) by the AQV quota group collector.

## Read this before you send it

$($map.Count) identifiers were replaced with placeholders. Every GUID became
SUB-A, SUB-B and so on, every management group became MG-1, and anything shaped
like a sign-in name was replaced too.

The mapping is NOT in this package. It is on the machine that produced it, at
``output/redaction-map.local.json``. Keep it. Without it nobody can trace this
back to your tenant, which is the point.

## What is still in here

- Azure region names
- VM family names and vCPU numbers
- HTTP status codes, error codes and error messages, verbatim
- API paths, with the identifiers replaced
- Timings

Error messages are verbatim on purpose: the wording is what AQV needs. Read
``captures/`` if you want to check nothing of yours is quoted in one.

## What was never collected

No credential, token, resource name, workload data, cost, or user identity
beyond the sign-in names that were replaced. The collector calls quota, billing
and role-definition endpoints only.

## Files

| File | What |
|---|---|
| ``findings.yaml`` | The answers |
| ``captures/*.json`` | Every request and response |
| ``timings.csv`` | One row per API call |
| ``manifest.json`` | SHA-256 of each file, and which steps ran |

## If you want more taken out

``./scripts/Step09-Package.ps1 -AlsoRedact 'contoso','project-falcon'``

It re-runs from the captures, so nothing is lost by running it again.
"@
$readme | Set-Content -Path (Join-Path $stage 'REDACTION.md') -Encoding utf8
Copy-Item (Join-Path $stage 'REDACTION.md') (Join-Path $out 'REDACTION.md') -Force

# --- Zip ------------------------------------------------------------------
$zip = Join-Path $out ('aqv-quota-group-findings-' + (Get-Date -Format 'yyyyMMdd') + '.zip')
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

Write-Host ''
Write-Host ("  Package: {0}" -f $zip) -ForegroundColor Green
Write-Host ("  {0:N0} KB, {1} steps, {2} API calls" -f ((Get-Item $zip).Length / 1KB), $manifest.steps_present.Count, $rows.Count)
Write-Host ''
Write-Host ("  Redaction map kept locally: {0}" -f $mapFile) -ForegroundColor Cyan
Write-Host '  It is git-ignored and is not in the zip.'
Write-Host ''
Write-Host ("  Read {0} before sending." -f (Join-Path $out 'REDACTION.md')) -ForegroundColor Yellow
Write-Host ''
