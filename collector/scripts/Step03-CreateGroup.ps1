<#
    .SYNOPSIS
    Step 3. Creates a quota group, adds the two subscriptions, and turns
    enforcement on. WRITES TO AZURE.

    .DESCRIPTION
    UNTESTED. The AQV maintainers cannot create a quota group, so every write in
    this script is built from the API shapes their read-only probing returned
    and from Microsoft's documentation. Expect at least one call to be wrong.

    A wrong call here is a GOOD result. Record what came back and move on: a
    verbatim error is exactly what the findings file is for. Do not edit this
    script to make a call succeed.

    Reversed by step 8.

    .PARAMETER Enforce
    Also turn enforcement on. locationUsages refuses to read an unenforced
    group, so this is needed to answer section A. Leave it off for the first
    run if you would rather see an unenforced group first.
#>
[CmdletBinding()]
param(
    [switch]$Enforce,
    [switch]$SkipMembership
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 3 -Title 'Create the quota group' -Writes

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

Write-Host ("  Creating {0} under {1}" -f $g, $mg)
Write-Host ''

$summary = [ordered]@{ group_name = $g; management_group = $mg; region = $region }

# --- C1: create the group ------------------------------------------------
# The body mirrors what a live group returns. groupType and additionalAttributes
# were both present on a real object, and neither is in the documentation, so
# they are sent and the response is compared against what was asked for.
Write-Host '  Create' -ForegroundColor Cyan
$body = @{
    properties = @{
        displayName = 'AQV collector'
        additionalAttributes = @{
            groupId = @{ groupingIdType = 'BillingId'; value = 'aqv-collector' }
            environment = 'None'
        }
    }
}
$c = Invoke-AqvApi -Method PUT -Path $base -ApiVersion $v -Body $body -Purpose 'C1: create the group'
Write-Host ("    PUT groupQuotas/{0}  HTTP {1} ({2} ms)" -f $g, $c.Status, $c.DurationMs) `
    -ForegroundColor $(if ($c.Ok) { 'Green' } else { 'Red' })
$summary.create_status = $c.Status
$summary.create_response = $c.Body
$summary.create_request = $body

if (-not $c.Ok) {
    Write-Host '    Create failed. The response is the finding:' -ForegroundColor Yellow
    Write-Host ("    {0}" -f ($c.Body | ConvertTo-Json -Depth 8 -Compress))
    $null = Save-AqvCapture -Name '03-create-group' -Summary $summary
    Write-Host ''
    Write-Host '    Stopping. Do not edit this script to work around it.' -ForegroundColor Yellow
    Write-Host '    Send the capture: a refused create is an answer to C1.'
    return
}

# A 201 or 202 means it is still settling, so wait for the object to read back.
if ($c.Status -eq 202) {
    Write-Host '    202. Waiting for the group to appear.'
    $w = Wait-AqvOperation -Path $base -ApiVersion $v -TimeoutSeconds 300 -IntervalSeconds 10 `
        -Purpose 'C1: poll the new group'
    $summary.create_states = $w.States
    $summary.create_wait_ms = $w.DurationMs
}

# --- A5: what did it actually create? -----------------------------------
$read = Invoke-AqvApi -Method GET -Path $base -ApiVersion $v -Purpose 'A5: groupType of the new group'
$summary.group_type = Get-AqvProp $read.Body 'properties' 'groupType'
Write-Host ("    groupType: {0}" -f $summary.group_type)
if ($summary.group_type -ne 'AllocationGroup') {
    Write-Host '    Different from the AllocationGroup the maintainers read. Record it.' -ForegroundColor Yellow
}

# --- C1: membership ------------------------------------------------------
# Allocation is documented as needing the subscription in the group. Whether it
# is actually enforced is question C2, and step 5 answers that.
if (-not $SkipMembership) {
    Write-Host ''
    Write-Host '  Membership' -ForegroundColor Cyan
    $members = @{}
    foreach ($sub in @($cfg.donor_subscription_id, $cfg.target_subscription_id)) {
        $label = if ($sub -eq $cfg.donor_subscription_id) { 'donor' } else { 'target' }
        $m = Invoke-AqvApi -Method PUT -Path "$base/subscriptions/$sub" -ApiVersion $v `
            -Purpose "C1: add the $label subscription"
        Write-Host ("    {0,-8} HTTP {1,-5} {2,6} ms" -f $label, $m.Status, $m.DurationMs) `
            -ForegroundColor $(if ($m.Ok) { 'Green' } else { 'Yellow' })
        $members[$label] = [ordered]@{ status = $m.Status; response = $m.Body; headers = $m.Headers }

        # Membership is documented as async. Poll it rather than assume.
        if ($m.Status -eq 202) {
            $w = Wait-AqvOperation -Path "$base/subscriptions/$sub" -ApiVersion $v `
                -TimeoutSeconds 300 -IntervalSeconds 10 -Purpose "C1: poll $label membership"
            $members[$label].states = $w.States
            $members[$label].wait_ms = $w.DurationMs
        }
    }
    $summary.membership = $members

    $subs = Invoke-AqvApi -Method GET -Path "$base/subscriptions" -ApiVersion $v -Purpose 'C4: members after adding'
    $summary.members_after = @(Get-AqvProp $subs.Body 'value' | ForEach-Object { Get-AqvProp $_ 'name' })
    $summary.subscriptions_has_values_key = $null -ne (Get-AqvProp $subs.Body 'values')
    Write-Host ("    members now: {0}" -f (@($summary.members_after).Count))
}

# --- A1: enforcement -----------------------------------------------------
# The blocking unknown. Two body shapes are tried because nothing documents
# this one: the error message named "EnforcementStatus", and locationSettings is
# the resource type that holds it.
if ($Enforce) {
    Write-Host ''
    Write-Host '  Enforcement' -ForegroundColor Cyan
    $shapes = @(
        @{ n = 'enforcementEnabled'; b = @{ properties = @{ enforcementEnabled = 'Enabled' } } }
        @{ n = 'enforcementStatus';  b = @{ properties = @{ enforcementStatus = 'Enabled' } } }
    )
    $tried = @()
    foreach ($shape in $shapes) {
        $e = Invoke-AqvApi -Method PATCH -Path "$rp/locationSettings/$region" -ApiVersion $v `
            -Body $shape.b -Purpose ("A1: set enforcement, body shape '{0}'" -f $shape.n)
        Write-Host ("    {0,-22} HTTP {1,-5} {2,6} ms" -f $shape.n, $e.Status, $e.DurationMs) `
            -ForegroundColor $(if ($e.Ok) { 'Green' } else { 'Yellow' })
        $tried += [ordered]@{ shape = $shape.n; request = $shape.b; status = $e.Status; response = $e.Body }
        if ($e.Ok) { break }
    }
    $summary.enforcement_attempts = $tried

    # A2: whatever the accepted shape was, read back what it produced.
    $after = Invoke-AqvApi -Method GET -Path "$rp/locationSettings/$region" -ApiVersion $v `
        -Purpose 'A2: enforcement state after setting it'
    $summary.location_settings_after = $after.Body
    Write-Host ("    read back: HTTP {0}" -f $after.Status)

    # A3: does enforcement unlock the aggregate read?
    $lu = Invoke-AqvApi -Method GET -Path "$rp/locationUsages/$region" -ApiVersion $v `
        -Purpose 'A3: does locationUsages work once enforced'
    $summary.location_usages_after_enforce = [ordered]@{ status = $lu.Status; body = $lu.Body }
    Write-Host ("    locationUsages now: HTTP {0}" -f $lu.Status) `
        -ForegroundColor $(if ($lu.Ok) { 'Green' } else { 'Yellow' })
    if ($lu.Ok) {
        Write-Host '    Enforcement is what gated it. That answers A1 to A3.' -ForegroundColor Green
    }
}
else {
    Write-Host ''
    Write-Host '  Enforcement not requested. Re-run with -Enforce to answer section A.' -ForegroundColor DarkGray
}

$null = Save-AqvCapture -Name '03-create-group' -Summary $summary
Write-Host ''
Write-Host '  Step 8 deletes this group and puts the quota back.' -ForegroundColor DarkGray
Write-Host ''
