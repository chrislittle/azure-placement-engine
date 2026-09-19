<#
    .SYNOPSIS
    Step 1. Finds the management groups and any existing quota groups. Writes
    nothing to Azure.

    .DESCRIPTION
    Also writes output/run-config.json, which every later step reads. That file
    is the only place the subscription IDs, region and family are named, so no
    later step can be pointed at the wrong thing by a typo.

    .PARAMETER ManagementGroupId
    The management group your quota group sits under.

    .PARAMETER Family
    The VM family to move quota for, exactly as Microsoft.Compute reports it,
    for example StandardDsv6Family. Step 0 printed the donor's families with
    room.

    .PARAMETER Cores
    How many vCPUs to move. Keep it small. 8 or 10 is enough to prove the
    mechanism.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DonorSubscriptionId,
    [Parameter(Mandatory)][string]$TargetSubscriptionId,
    [Parameter(Mandatory)][string]$Region,
    [Parameter(Mandatory)][string]$ManagementGroupId,
    [Parameter(Mandatory)][string]$Family,
    [int]$Cores = 8,
    # The EXISTING quota group to use. The collector joins one; it does not
    # create one. Run without it to list what is there and be told the names.
    [string]$GroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 1 -Title 'Discover management groups and quota groups'

if ($DonorSubscriptionId -eq $TargetSubscriptionId) {
    throw 'The donor and the target must be different subscriptions. Moving quota from a subscription to itself proves nothing.'
}

$null = Assert-AqvBaseline
$summary = [ordered]@{}

# --- Management groups ---------------------------------------------------
Write-Host '  Management groups' -ForegroundColor Cyan
$mgs = Invoke-AqvApi -Method GET -Path '/providers/Microsoft.Management/managementGroups' `
    -ApiVersion '2021-04-01' -Purpose 'list management groups'

$found = $false
$rows = @()
foreach ($m in @(Get-AqvProp $mgs.Body 'value')) {
    $id = Get-AqvProp $m 'name'
    $rows += [ordered]@{ id = $id; display_name = Get-AqvProp $m 'properties' 'displayName' }
    if ($id -eq $ManagementGroupId) { $found = $true }
}
$summary.management_groups = $rows
Write-Host ("    {0} visible" -f $rows.Count)

if (-not $found) {
    Write-Host ("    {0} was NOT in the list." -f $ManagementGroupId) -ForegroundColor Yellow
    Write-Host '    You may still be able to write to it. Step 3 is what proves that.'
}
else {
    Write-Host ("    {0} found." -f $ManagementGroupId) -ForegroundColor Green
}
$summary.target_mg_visible = $found

# --- Existing quota groups ----------------------------------------------
# A group that is already there is better evidence than one this run creates,
# because it has real allocations in it. Step 2 reads whatever turns up here.
Write-Host ''
Write-Host '  Existing quota groups' -ForegroundColor Cyan
$existing = @()
foreach ($mg in $rows) {
    $g = Invoke-AqvApi -Method GET `
        -Path ("/providers/Microsoft.Management/managementGroups/{0}/providers/Microsoft.Quota/groupQuotas" -f $mg.id) `
        -ApiVersion '2025-09-01' -Purpose ("list quota groups under {0}" -f $mg.id)

    foreach ($q in @(Get-AqvProp $g.Body 'value')) {
        $existing += [ordered]@{
            management_group = $mg.id
            name             = Get-AqvProp $q 'name'
            display_name     = Get-AqvProp $q 'properties' 'displayName'
            id               = Get-AqvProp $q 'id'
        }
    }
    # A 404 here is normal when no group exists. A 403 is not, and means the
    # roles are not in place yet.
    if ($g.Status -eq 403) {
        Write-Host ("    {0}: 403, no read access to group quotas here" -f $mg.id) -ForegroundColor Yellow
    }
}
$summary.existing_quota_groups = $existing

if ($existing.Count -gt 0) {
    Write-Host ("    {0} found:" -f $existing.Count) -ForegroundColor Green
    $existing | ForEach-Object { Write-Host ("      {0} under {1}" -f $_.name, $_.management_group) }
}
else {
    Write-Host '    None found in any management group you can read.' -ForegroundColor Yellow
    Write-Host '    This collector joins an EXISTING group. If the tenant genuinely has'
    Write-Host '    none, ./New-SandboxGroup.ps1 stands one up, deliberately outside the run.'
}

# Naming a group that is not there would only fail later, in a step that writes.
if (-not $GroupName) {
    Write-Host ''
    Write-Host '    No -GroupName given. Re-run naming one of the groups above.' -ForegroundColor Yellow
    Write-Host '    Nothing has been written and no run configuration was saved.'
    $null = Save-AqvCapture -Name '01-discover' -Summary $summary
    return
}

$chosen = @($existing | Where-Object { $_.name -eq $GroupName -and $_.management_group -eq $ManagementGroupId })
if ($chosen.Count -eq 0) {
    Write-Host ''
    Write-Host ("    '{0}' was not found under {1}." -f $GroupName, $ManagementGroupId) -ForegroundColor Red
    Write-Host '    Names are case sensitive. Pick one from the list above.'
    $summary.group_found = $false
    $null = Save-AqvCapture -Name '01-discover' -Summary $summary
    return
}
$summary.group_found = $true
Write-Host ("    Using {0}." -f $GroupName) -ForegroundColor Green

# --- Is either subscription already in a group? -------------------------
# A subscription can be in only one group, so this decides whether the run can
# use the subscriptions that were nominated.
Write-Host ''
Write-Host '  Group membership' -ForegroundColor Cyan
$membership = [ordered]@{}
foreach ($g in $existing) {
    $subs = Invoke-AqvApi -Method GET `
        -Path ("/providers/Microsoft.Management/managementGroups/{0}/providers/Microsoft.Quota/groupQuotas/{1}/subscriptions" -f $g.management_group, $g.name) `
        -ApiVersion '2025-09-01' -Purpose ("subscriptions in {0}" -f $g.name)
    $ids = @(Get-AqvProp $subs.Body 'value' | ForEach-Object { Get-AqvProp $_ 'name' })
    $membership[$g.name] = $ids
    foreach ($s in @($DonorSubscriptionId, $TargetSubscriptionId)) {
        if ($ids -contains $s) {
            Write-Host ("    {0} is already in group {1}." -f $s, $g.name) -ForegroundColor Yellow
            Write-Host '    A subscription can be in only one group. Pick another, or use this group for the run.'
        }
    }
}
$summary.group_membership = $membership

# --- The family this run will move --------------------------------------
Write-Host ''
Write-Host '  Family check' -ForegroundColor Cyan
$u = Invoke-AqvApi -Method GET `
    -Path "/subscriptions/$DonorSubscriptionId/providers/Microsoft.Compute/locations/$Region/usages" `
    -ApiVersion '2024-07-01' -Purpose "confirm $Family on the donor"

$row = @(Get-AqvProp $u.Body 'value' | Where-Object { (Get-AqvProp $_ 'name' 'value') -eq $Family })
if ($row.Count -eq 0) {
    Write-Host ("    {0} is not reported in {1} on the donor." -f $Family, $Region) -ForegroundColor Red
    Write-Host '    Family names are case sensitive and vary by region. Check step 0''s list.'
    $summary.family_ok = $false
}
else {
    $limit = Get-AqvProp $row[0] 'limit'
    $used = Get-AqvProp $row[0] 'currentValue'
    $spare = $limit - $used
    Write-Host ("    {0}: limit={1} used={2} spare={3}" -f $Family, $limit, $used, $spare)
    $summary.family_ok = ($spare -ge $Cores)
    $summary.donor_family = [ordered]@{ name = $Family; limit = $limit; used = $used; spare = $spare }
    if ($spare -lt $Cores) {
        Write-Host ("    Not enough spare for {0} cores. Lower -Cores or pick another family." -f $Cores) -ForegroundColor Yellow
    }
    else {
        Write-Host ("    Enough spare to move {0} cores." -f $Cores) -ForegroundColor Green
    }
}

# --- The run configuration ----------------------------------------------
# Written once, read by every later step. Nothing downstream takes a
# subscription ID on the command line, so a write cannot land on the wrong one.
$cfg = [ordered]@{
    donor_subscription_id  = $DonorSubscriptionId
    target_subscription_id = $TargetSubscriptionId
    region                 = $Region
    management_group_id    = $ManagementGroupId
    group_name             = $GroupName
    family                 = $Family
    cores                  = $Cores
    created                = (Get-Date).ToUniversalTime().ToString('o')
}
$cfgFile = Join-Path (Get-AqvOutputDir) 'run-config.json'
$cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgFile -Encoding utf8

$summary.run_config = $cfg
$null = Save-AqvCapture -Name '01-discover' -Summary $summary

Write-Host ''
Write-Host ("  Run configuration written: {0}" -f $cfgFile) -ForegroundColor Green
Write-Host '  Every later step reads it. To change the plan, run step 1 again.'
Write-Host ''
