<#
    .SYNOPSIS
    Optional. Creates a quota group in a sandbox tenant. WRITES TO AZURE.

    .DESCRIPTION
    NOT part of the numbered collector run, and not for a partner tenant.

    The collector is built for someone who already has a quota group. If you
    have one, do not use this: run step 3 to join it instead. Creating a second
    group in a tenant that already has one is a change nobody asked for, and a
    subscription can belong to only one group at a time anyway.

    This exists for one case: a sandbox or personal tenant with no group at all,
    where you want to stand one up to try the collector end to end.

    Membership and enforcement are NOT done here. They are step 3, because
    joining a group is the same decision whether the group is new or not.

    UNTESTED against an eligible billing account. The body is built from the
    shape a real group returns.

    .PARAMETER GroupName
    Lower case letters and digits only, starting with a letter. The schema
    enforces ^[a-z][a-z0-9]*$ and a hyphen is rejected.

    .EXAMPLE
    ./New-SandboxGroup.ps1 -ManagementGroupId sandbox-mg -GroupName aqvsandbox
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManagementGroupId,
    [Parameter(Mandatory)][string]$GroupName,
    [string]$DisplayName = 'AQV sandbox'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-Host ''
Write-Host '  CREATE A SANDBOX QUOTA GROUP' -ForegroundColor Cyan
Write-Host '  This WRITES to Azure. It is not part of the numbered run.' -ForegroundColor Yellow
Write-Host ''

if ($GroupName -cnotmatch '^[a-z][a-z0-9]*$') {
    throw ("Group name '{0}' is invalid. Lower case letters and digits only, starting with a letter. No hyphens." -f $GroupName)
}

$v = '2025-09-01'
$base = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId/providers/Microsoft.Quota/groupQuotas/$GroupName"
$summary = [ordered]@{ group_name = $GroupName; management_group = $ManagementGroupId }

# Refuse to touch a group that is already there. Overwriting someone's group
# with this one's display name would be a silent change to something in use.
$existing = Invoke-AqvApi -Method GET -Path $base -ApiVersion $v -Purpose 'does the group already exist'
if ($existing.Ok) {
    Write-Host ("  {0} already exists under {1}." -f $GroupName, $ManagementGroupId) -ForegroundColor Yellow
    Write-Host '  Nothing to do. Run step 3 to join it instead.'
    return
}

# The body mirrors what a live group returns. groupType and additionalAttributes
# were both present on a real object and neither is documented, so they are sent
# and the response is compared against what was asked for.
$body = @{
    properties = @{
        displayName = $DisplayName
        additionalAttributes = @{
            groupId     = @{ groupingIdType = 'BillingId'; value = 'aqv-collector' }
            environment = 'None'
        }
    }
}

if (-not $PSCmdlet.ShouldProcess("$GroupName under $ManagementGroupId", 'create a quota group')) { return }

$c = Invoke-AqvApi -Method PUT -Path $base -ApiVersion $v -Body $body -Purpose 'C1: create the group'
Write-Host ("  PUT groupQuotas/{0}  HTTP {1} ({2} ms)" -f $GroupName, $c.Status, $c.DurationMs) `
    -ForegroundColor $(if ($c.Ok) { 'Green' } else { 'Red' })
$summary.create_request = $body
$summary.create_status = $c.Status
$summary.create_response = $c.Body

if (-not $c.Ok) {
    Write-Host '  Create failed. The response is the finding:' -ForegroundColor Yellow
    Write-Host ("  {0}" -f ($c.Body | ConvertTo-Json -Depth 8 -Compress))
    Write-Host '  Do not edit this script to work around it.' -ForegroundColor Yellow
    $null = Save-AqvCapture -Name 'sandbox-create-group' -Summary $summary
    return
}

# Creation is a long-running operation. The signed poll URL is used exactly as
# Azure returns it: rewriting any part of its query string fails the signature
# check with AuthorizationFailed, which reads like a permissions problem and is
# not one.
$poll = $null
foreach ($h in @('Azure-AsyncOperation', 'Location')) {
    if ($c.Headers[$h]) { $poll = $c.Headers[$h]; break }
}
if ($poll) {
    $w = Wait-AqvOperation -Url $poll -TimeoutSeconds 600 -IntervalSeconds 15 -Purpose 'C1: poll the create'
    $summary.create_states = $w.States
    $summary.create_ms = $w.DurationMs
    Write-Host ("  {0} after {1} ms" -f $w.State, $w.DurationMs)
}

$read = Invoke-AqvApi -Method GET -Path $base -ApiVersion $v -Purpose 'A5: groupType of the new group'
$summary.group_type = Get-AqvProp $read.Body 'properties' 'groupType'
$summary.provisioning_state = Get-AqvProp $read.Body 'properties' 'provisioningState'
Write-Host ("  groupType: {0}, provisioningState: {1}" -f $summary.group_type, $summary.provisioning_state)

$null = Save-AqvCapture -Name 'sandbox-create-group' -Summary $summary

Write-Host ''
Write-Host ("  Created. Run step 1 with -GroupName {0} to point the collector at it." -f $GroupName) -ForegroundColor Green
Write-Host '  Step 8 will NOT delete it unless you pass -DeleteSandboxGroup.' -ForegroundColor DarkGray
Write-Host ''
