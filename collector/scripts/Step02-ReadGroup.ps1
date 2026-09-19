<#
    .SYNOPSIS
    Step 2. Reads every group API there is. Writes nothing to Azure.

    .DESCRIPTION
    Runs the same reads the AQV maintainers ran on 2026-09-19 against an empty
    group, so the two can be compared. The interesting ones are the reads that
    failed there: locationUsages refused with "enforced groups only", and
    quotaAllocationRequests returned HTTP 500.

    If the group holds quota, this step answers most of section B on its own.

    .PARAMETER GroupName
    Which group to read. Defaults to the one in run-config.json. Point it at an
    EXISTING group with quota in it if you have one -- that is far better
    evidence than the empty one step 3 creates.
#>
[CmdletBinding()]
param(
    [string]$GroupName,
    [string]$ManagementGroupId,
    # Which member subscription to read allocations for. Defaults to the target
    # in run-config.json. Point it at a subscription that is actually in the
    # group: the allocation read returns 400 for a subscription ARM cannot see.
    [string]$SubscriptionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 2 -Title 'Read the group APIs'

$cfgFile = Join-Path (Get-AqvOutputDir) 'run-config.json'
if (-not (Test-Path $cfgFile)) { throw 'No run-config.json. Run step 1 first.' }
$cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json

if (-not $GroupName) { $GroupName = $cfg.group_name }
if (-not $ManagementGroupId) { $ManagementGroupId = $cfg.management_group_id }
$region = $cfg.region
$sub = if ($SubscriptionId) { $SubscriptionId } else { $cfg.target_subscription_id }

$base = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/Microsoft.Quota/groupQuotas/$GroupName"
$rp = "$base/resourceProviders/Microsoft.Compute"
$v = '2025-09-01'

Write-Host ("  Group {0} under {1}, region {2}" -f $GroupName, $ManagementGroupId, $region)
Write-Host ''

$summary = [ordered]@{
    group_name        = $GroupName
    management_group  = $ManagementGroupId
    region            = $region
    api_version       = $v
}

function Show([string]$label, $r) {
    $colour = if ($r.Ok) { 'Green' } elseif ($r.Status -ge 500) { 'Red' } else { 'Yellow' }
    Write-Host ("    {0,-34} HTTP {1,-5} {2,6} ms" -f $label, $r.Status, $r.DurationMs) -ForegroundColor $colour
}

# --- The group object ---------------------------------------------------
Write-Host '  Group object' -ForegroundColor Cyan
$g = Invoke-AqvApi -Method GET -Path $base -ApiVersion $v -Purpose 'A5: group object and groupType'
Show 'groupQuotas/{group}' $g
$summary.group_type = Get-AqvProp $g.Body 'properties' 'groupType'
$summary.provisioning_state = Get-AqvProp $g.Body 'properties' 'provisioningState'
$summary.additional_attributes = Get-AqvProp $g.Body 'properties' 'additionalAttributes'
if ($summary.group_type) {
    Write-Host ("      groupType: {0}" -f $summary.group_type)
}

# --- Enforcement --------------------------------------------------------
# The blocking unknown. An empty group 404s here with "EnforcementStatus is not
# found", which is the only place the concept surfaces at all.
Write-Host ''
Write-Host '  Enforcement' -ForegroundColor Cyan
$ls = Invoke-AqvApi -Method GET -Path "$rp/locationSettings/$region" -ApiVersion $v `
    -Purpose 'A1/A2: location settings, where enforcement lives'
Show 'locationSettings/{location}' $ls
$summary.location_settings = $ls.Body
$summary.enforcement_status = Get-AqvProp $ls.Body 'properties' 'enforcementEnabled'

$lsList = Invoke-AqvApi -Method GET -Path "$rp/locationSettings" -ApiVersion $v `
    -Purpose 'A2: location settings list'
Show 'locationSettings (list)' $lsList

# --- Limits and usage ---------------------------------------------------
Write-Host ''
Write-Host '  Limits and usage' -ForegroundColor Cyan
$gl = Invoke-AqvApi -Method GET -Path "$rp/groupQuotaLimits/$region" -ApiVersion $v `
    -Purpose 'B1: what the group holds'
Show 'groupQuotaLimits/{location}' $gl
$summary.group_quota_limits = $gl.Body

# An empty object is the empty-group answer, and it is a 200. Anything else
# means this group holds something, which is the case AQV has never seen.
$glEmpty = ($null -eq $gl.Body) -or (@($gl.Body.PSObject.Properties).Count -eq 0)
$summary.group_quota_limits_empty = $glEmpty
if ($glEmpty) {
    Write-Host '      Empty. This group holds no quota, so section B stays unanswered.' -ForegroundColor Yellow
    Write-Host '      Point this step at a group that holds cores if you have one.'
}
else {
    Write-Host '      NOT empty. This is the case AQV has never been able to read.' -ForegroundColor Green
}

$lu = Invoke-AqvApi -Method GET -Path "$rp/locationUsages/$region" -ApiVersion $v `
    -Purpose 'B5: aggregate usage, refused on unenforced groups'
Show 'locationUsages/{location}' $lu
$summary.location_usages = $lu.Body
$summary.location_usages_status = $lu.Status
if ($lu.Status -eq 405) {
    Write-Host '      405. Enforcement is off. The message names the gate:' -ForegroundColor Yellow
    Write-Host ("      {0}" -f ($lu.Body | Out-String).Trim())
}

# --- Allocations --------------------------------------------------------
Write-Host ''
Write-Host '  Allocations' -ForegroundColor Cyan
$qa = Invoke-AqvApi -Method GET `
    -Path "/providers/Microsoft.Management/managementGroups/$ManagementGroupId/subscriptions/$sub/providers/Microsoft.Quota/groupQuotas/$GroupName/resourceProviders/Microsoft.Compute/quotaAllocations/$region" `
    -ApiVersion $v -Purpose 'B3/B6: per-subscription allocation, and family name casing'
Show 'quotaAllocations/{location}' $qa
$summary.quota_allocations_count = @(Get-AqvProp $qa.Body 'value').Count

# B6. The join that AQV depends on. Comparing the two name lists directly is the
# whole answer, so it is computed here rather than left to a human to eyeball.
$groupNames = @(Get-AqvProp $qa.Body 'value' | ForEach-Object { Get-AqvProp $_ 'properties' 'resourceName' } | Where-Object { $_ })
$u = Invoke-AqvApi -Method GET `
    -Path "/subscriptions/$sub/providers/Microsoft.Compute/locations/$region/usages" `
    -ApiVersion '2024-07-01' -Purpose 'B6: the names Microsoft.Compute reports, for comparison'
$computeNames = @(Get-AqvProp $u.Body 'value' | ForEach-Object { Get-AqvProp $_ 'name' 'value' } | Where-Object { $_ })

$exact = @($groupNames | Where-Object { $computeNames -ccontains $_ }).Count
$insensitive = @($groupNames | Where-Object { $computeNames -contains $_ }).Count
$summary.name_match = [ordered]@{
    group_api_names       = $groupNames.Count
    compute_api_names     = $computeNames.Count
    match_case_sensitive  = $exact
    match_case_insensitive = $insensitive
    sample_group          = @($groupNames | Select-Object -First 5)
    sample_compute        = @($computeNames | Select-Object -First 5)
}
Write-Host ''
if ($groupNames.Count -eq 0 -or $computeNames.Count -eq 0) {
    Write-Host ("      No names to compare (allocations HTTP {0}, usages HTTP {1})." -f $qa.Status, $u.Status) -ForegroundColor Yellow
    Write-Host '      Re-run with -SubscriptionId pointing at a subscription in the group.'
}
Write-Host ("      names: {0} from the group API, {1} from Microsoft.Compute" -f $groupNames.Count, $computeNames.Count)
Write-Host ("      case sensitive match  : {0}" -f $exact) -ForegroundColor $(if ($exact -eq 0) { 'Red' } else { 'Green' })
Write-Host ("      case insensitive match: {0}" -f $insensitive) -ForegroundColor Green
# A handful of names are already lower case in both APIs, so an exact match
# count above zero does not mean the two agree. The comparison is between the
# two counts, not against zero.
$summary.name_match.casing_differs = ($insensitive -gt $exact)
if ($insensitive -gt $exact) {
    Write-Host ("      {0} of {1} names differ only by case. AQV must normalise." -f
        ($insensitive - $exact), $insensitive) -ForegroundColor Yellow
}
elseif ($insensitive -gt 0) {
    Write-Host '      Every name matches exactly. No normalisation needed.' -ForegroundColor Green
}

# --- Membership and requests -------------------------------------------
Write-Host ''
Write-Host '  Membership and requests' -ForegroundColor Cyan
$subs = Invoke-AqvApi -Method GET -Path "$base/subscriptions" -ApiVersion $v -Purpose 'C4: members'
Show 'subscriptions' $subs
$summary.members = @(Get-AqvProp $subs.Body 'value' | ForEach-Object { Get-AqvProp $_ 'name' })
# C4: an empty group returned both spellings. Record whether that survives.
$summary.subscriptions_has_values_key = $null -ne (Get-AqvProp $subs.Body 'values')

# The filter is mandatory here and the error says so.
$gqr = Invoke-AqvApi -Method GET -Path ("{0}/groupQuotaRequests?`$filter=location eq '{1}'" -f $base, $region) `
    -ApiVersion $v -Purpose 'D4: group quota requests, filter required'
Show 'groupQuotaRequests (filtered)' $gqr

# D4. This returned HTTP 500 for the maintainers on two api-versions. Whether it
# does so for everyone, or only on an empty group, decides how aqv-apply polls.
$qar = Invoke-AqvApi -Method GET -Path "$rp/quotaAllocationRequests" -ApiVersion $v `
    -Purpose 'D4: allocation requests list -- returned HTTP 500 for the maintainers'
Show 'quotaAllocationRequests' $qar
$summary.quota_allocation_requests_status = $qar.Status
if ($qar.Status -ge 500) {
    Write-Host '      Reproduced: the list form is a server error here too.' -ForegroundColor Red
}
elseif ($qar.Ok) {
    Write-Host '      Works here. It failed on an empty group, so the group state matters.' -ForegroundColor Green
}

# --- quotaTransfers, the other mechanism -------------------------------
Write-Host ''
Write-Host '  quotaTransfers (preview, undocumented)' -ForegroundColor Cyan
foreach ($t in @('quotaTransfers', 'incomingQuotaTransfers')) {
    $r = Invoke-AqvApi -Method GET -Path "/subscriptions/$sub/providers/Microsoft.Quota/$t" `
        -ApiVersion '2026-09-01-preview' -Purpose "G1/G4: $t availability"
    Show $t $r
    $summary["transfers_$t" + '_status'] = $r.Status
    $summary["transfers_$t" + '_body'] = $r.Body
}

$null = Save-AqvCapture -Name '02-read-group' -Summary $summary

Write-Host ''
Write-Host '  What this answered' -ForegroundColor Cyan
$b6 =
if ($insensitive -eq 0) { 'not answered, no names read' }
elseif ($insensitive -gt $exact) { "answered: $($insensitive - $exact) of $insensitive differ by case" }
else { 'answered: they agree exactly' }
Write-Host ("    B6 name casing        {0}" -f $b6)
Write-Host ("    B1 group holdings     {0}" -f $(if ($glEmpty) { 'not answered, group is empty' } else { 'answered' }))
Write-Host ("    A2 enforcement state  {0}" -f $(if ($ls.Ok) { 'answered' } else { "not answered, HTTP $($ls.Status)" }))
Write-Host ''
