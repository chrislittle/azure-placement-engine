<#
    .SYNOPSIS
    Step 3. Adds the two subscriptions to the quota group you already have.
    WRITES TO AZURE.

    .DESCRIPTION
    UNTESTED. Answers C1, C2, C3 and C4.

    This does NOT create a group. The collector is built for a partner who
    already has one, and creating a second one in a tenant that has one is both
    unnecessary and a change nobody asked for. See New-SandboxGroup.ps1 if you
    genuinely have no group and want to stand one up in a sandbox.

    Membership is the one write that has to happen before anything interesting
    can be tested, because a subscription can belong to only one group at a
    time.

    Reversed by step 8, which removes only the subscriptions this step added.

    .PARAMETER Enforce
    Also turn enforcement on for the region. The aggregate usage read refuses
    until it is set. Leave it off if the group is already enforced, or if you
    would rather not change a setting on a group you use for real work.
#>
[CmdletBinding()]
param([switch]$Enforce)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 3 -Title 'Join the group' -Writes

$null = Assert-AqvBaseline
$cfgFile = Join-Path (Get-AqvOutputDir) 'run-config.json'
if (-not (Test-Path $cfgFile)) { throw 'No run-config.json. Run step 1 first.' }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json

$mg = $cfg.management_group_id
$g = $cfg.group_name
$region = $cfg.region
$v = '2025-09-01'
$base = "/providers/Microsoft.Management/managementGroups/$mg/providers/Microsoft.Quota/groupQuotas/$g"
$rp = "$base/resourceProviders/Microsoft.Compute"

$summary = [ordered]@{ group_name = $g; management_group = $mg; region = $region }

# --- The group has to be there already ----------------------------------
# Refusing here is the point. Creating one silently would be exactly the
# behaviour this collector is not allowed to have.
Write-Host '  Confirming the group exists' -ForegroundColor Cyan
$grp = Invoke-AqvApi -Method GET -Path $base -ApiVersion $v -Purpose 'confirm the target group exists'
if (-not $grp.Ok) {
    Write-Host ("    {0} was not found under {1}. HTTP {2}." -f $g, $mg, $grp.Status) -ForegroundColor Red
    Write-Host '    This step joins an EXISTING group. It will not create one.'
    Write-Host '    Run step 1 again and name a group that exists, or use New-SandboxGroup.ps1.'
    return
}
$summary.group_type = Get-AqvProp $grp.Body 'properties' 'groupType'
Write-Host ("    {0} found, groupType {1}" -f $g, $summary.group_type) -ForegroundColor Green

# --- Who is in it now ---------------------------------------------------
# Recorded before the write so teardown can remove exactly what was added and
# nothing that was already there.
$before = Invoke-AqvApi -Method GET -Path "$base/subscriptions" -ApiVersion $v -Purpose 'C4: members before'
$membersBefore = @(Get-AqvProp $before.Body 'value' | ForEach-Object { Get-AqvProp $_ 'name' })
$summary.members_before = $membersBefore
$summary.subscriptions_has_values_key = $null -ne (Get-AqvProp $before.Body 'values')
Write-Host ("    {0} subscriptions already in it" -f $membersBefore.Count)

# --- Join ----------------------------------------------------------------
Write-Host ''
Write-Host '  Membership' -ForegroundColor Cyan
$added = @()
$members = [ordered]@{}
foreach ($sub in @($cfg.donor_subscription_id, $cfg.target_subscription_id)) {
    $label = if ($sub -eq $cfg.donor_subscription_id) { 'donor' } else { 'target' }

    if ($membersBefore -contains $sub) {
        Write-Host ("    {0,-8} already a member, nothing to do" -f $label) -ForegroundColor DarkGray
        $members[$label] = 'already a member'
        continue
    }

    $m = Invoke-AqvApi -Method PUT -Path "$base/subscriptions/$sub" -ApiVersion $v `
        -Purpose "C1: add the $label subscription"
    Write-Host ("    {0,-8} HTTP {1,-5} {2,6} ms" -f $label, $m.Status, $m.DurationMs) `
        -ForegroundColor $(if ($m.Ok) { 'Green' } else { 'Yellow' })

    $entry = [ordered]@{ status = $m.Status; response = $m.Body; headers = $m.Headers }

    # Documented as async. Poll rather than assume, and record the sequence:
    # question C1 is partly about what this operation actually returns.
    $poll = $null
    foreach ($h in @('Azure-AsyncOperation', 'Location')) {
        if ($m.Headers[$h]) { $poll = $m.Headers[$h]; break }
    }
    if ($m.Status -eq 202 -and $poll) {
        $w = Wait-AqvOperation -Url $poll -TimeoutSeconds 600 -Purpose "C1: poll $label membership"
        $entry.states = $w.States
        $entry.wait_ms = $w.DurationMs
        $entry.final_state = $w.State
        Write-Host ("             {0} after {1} ms" -f $w.State, $w.DurationMs)
    }

    $members[$label] = $entry
    if ($m.Ok) { $added += $sub }

    # C3. An ineligible billing account, or a subscription already in another
    # group, is refused here. The wording is what AQV would match on, so it is
    # recorded whole rather than summarised.
    if (-not $m.Ok) {
        Write-Host ("    {0}" -f ($m.Body | ConvertTo-Json -Depth 8 -Compress)) -ForegroundColor Yellow
    }
}
$summary.membership = $members

# Teardown reads this. Only these subscriptions are removed, so a member that
# was in the group before the run stays in it.
$summary.added_by_this_run = $added
$cfg | Add-Member -NotePropertyName 'members_added_by_collector' -NotePropertyValue $added -Force
$cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgFile -Encoding utf8

$after = Invoke-AqvApi -Method GET -Path "$base/subscriptions" -ApiVersion $v -Purpose 'C4: members after'
$summary.members_after = @(Get-AqvProp $after.Body 'value' | ForEach-Object { Get-AqvProp $_ 'name' })
Write-Host ("    members now: {0}" -f @($summary.members_after).Count)

# --- Enforcement ---------------------------------------------------------
if ($Enforce) {
    Write-Host ''
    Write-Host '  Enforcement' -ForegroundColor Cyan
    Write-Host '    locationUsages refuses to read until this is on.' -ForegroundColor DarkGray

    $e = Invoke-AqvApi -Method PUT -Path "$rp/locationSettings/$region" -ApiVersion $v `
        -Body @{ properties = @{ enforcementEnabled = 'Enabled' } } `
        -Purpose 'A1: turn enforcement on'
    Write-Host ("    PUT locationSettings/{0}  HTTP {1}" -f $region, $e.Status) `
        -ForegroundColor $(if ($e.Ok) { 'Green' } else { 'Yellow' })
    $summary.enforcement_request = [ordered]@{ status = $e.Status; response = $e.Body }

    # It is a long-running operation and the settings read 404s until it lands,
    # so polling is not optional here.
    $poll = $null
    foreach ($h in @('Azure-AsyncOperation', 'Location')) {
        if ($e.Headers[$h]) { $poll = $e.Headers[$h]; break }
    }
    if ($poll) {
        $w = Wait-AqvOperation -Url $poll -TimeoutSeconds 900 -IntervalSeconds 20 `
            -Purpose 'A1: poll the enforcement operation'
        $summary.enforcement_states = $w.States
        $summary.enforcement_ms = $w.DurationMs
        Write-Host ("    {0} after {1} ms" -f $w.State, $w.DurationMs)
    }
    else {
        Write-Host '    No poll header returned. Record that.' -ForegroundColor Yellow
    }

    # A2 and A3: what it produced, and whether it unlocked the read.
    $read = Invoke-AqvApi -Method GET -Path "$rp/locationSettings/$region" -ApiVersion $v -Purpose 'A2: settings after'
    $summary.location_settings_after = $read.Body
    Write-Host ("    locationSettings read back: HTTP {0}" -f $read.Status)

    $lu = Invoke-AqvApi -Method GET -Path "$rp/locationUsages/$region" -ApiVersion $v -Purpose 'A3: usages after'
    $summary.location_usages_after = [ordered]@{ status = $lu.Status; body = $lu.Body }
    Write-Host ("    locationUsages now: HTTP {0}" -f $lu.Status) `
        -ForegroundColor $(if ($lu.Ok) { 'Green' } else { 'Yellow' })
    if ($lu.Ok) {
        Write-Host '    Enforcement was the gate. That answers A1 to A3.' -ForegroundColor Green
    }
}
else {
    Write-Host ''
    Write-Host '  Enforcement not requested. Re-run with -Enforce to answer section A.' -ForegroundColor DarkGray
}

$null = Save-AqvCapture -Name '03-join-group' -Summary $summary
Write-Host ''
Write-Host '  Step 8 removes only the subscriptions this step added.' -ForegroundColor DarkGray
Write-Host '  It never deletes a group it did not create.' -ForegroundColor DarkGray
Write-Host ''
