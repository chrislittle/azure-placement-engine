<#
    .SYNOPSIS
    Step 0. Checks eligibility and records the baseline. Writes nothing to Azure.

    .DESCRIPTION
    Answers A1, A2 and A3, and records both subscriptions' current vCPU quota so
    every later write can be proved reversed.

    Nothing here changes anything. Every call is a GET.

    .PARAMETER DonorSubscriptionId
    The subscription quota will be moved OUT of in step 4. Needs spare quota.

    .PARAMETER TargetSubscriptionId
    The subscription quota will be allocated TO in step 5.

    .PARAMETER Region
    One Azure region. Everything in the run happens here.

    .EXAMPLE
    ./Step00-Preflight.ps1 -DonorSubscriptionId $donor -TargetSubscriptionId $target -Region westus2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DonorSubscriptionId,
    [Parameter(Mandatory)][string]$TargetSubscriptionId,
    [Parameter(Mandatory)][string]$Region
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AqvCollect.psm1') -Force

Write-AqvStep -Number 0 -Title 'Preflight and baseline'

$summary = [ordered]@{}

# --- A1: billing account type -------------------------------------------
# Quota groups need EA, MCA-Enterprise or Internal. Pay-as-you-go cannot create
# one, and finding that out here is much kinder than finding it out in step 3.
Write-Host '  Billing account' -ForegroundColor Cyan
$billing = Invoke-AqvApi -Method GET -Path '/providers/Microsoft.Billing/billingAccounts' `
    -ApiVersion '2024-04-01' -Purpose 'A1: billing account type'

$accounts = @()
if ($billing.Ok -and $null -ne (Get-AqvProp $billing.Body 'value')) {
    foreach ($a in $billing.Body.value) {
        $accounts += [ordered]@{
            name           = Get-AqvProp $a 'name'
            agreement_type = Get-AqvProp $a 'properties' 'agreementType'
            account_type   = Get-AqvProp $a 'properties' 'accountType'
            account_status = Get-AqvProp $a 'properties' 'accountStatus'
        }
    }
}
$summary.billing_accounts = $accounts

# The documented eligible set. Recorded rather than enforced, so a value nobody
# expected is reported instead of being treated as a failure.
$eligible = @('EnterpriseAgreement', 'MicrosoftCustomerAgreement', 'Internal')
$types = @($accounts | ForEach-Object { $_.agreement_type } | Where-Object { $_ })
$summary.eligible_agreement_found = @($types | Where-Object { $_ -in $eligible }).Count -gt 0
$summary.agreement_types_seen = $types

if ($accounts.Count -eq 0) {
    Write-Host '    No billing account returned.' -ForegroundColor Yellow
    Write-Host ("    Status {0}. You may not hold a billing role, which is not the same" -f $billing.Status)
    Write-Host '    as the account being ineligible. Record the status and continue.'
}
else {
    foreach ($a in $accounts) {
        Write-Host ("    {0,-28} {1}" -f $a.agreement_type, $a.account_type)
    }
}

# MCA has two shapes and only the Enterprise one qualifies. The agreement type
# alone does not tell them apart, so this is flagged rather than decided.
if ($types -contains 'MicrosoftCustomerAgreement') {
    Write-Host '    MCA found. Confirm it is MCA-Enterprise, not MCA-Online.' -ForegroundColor Yellow
}

# --- A2: the GroupQuota Request Operator role ---------------------------
Write-Host ''
Write-Host '  Roles' -ForegroundColor Cyan
# Role definitions are tenant-wide, so either subscription answers. Asking the
# target first and falling back matters because a subscription you cannot read
# returns 404, which would otherwise be reported as "the role does not exist".
$roleFilter = "`$filter=roleName eq 'GroupQuota Request Operator'"
$roles = $null
foreach ($sub in @($TargetSubscriptionId, $DonorSubscriptionId)) {
    $roles = Invoke-AqvApi -Method GET `
        -Path "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions?$roleFilter" `
        -ApiVersion '2022-04-01' -Purpose 'A2: does GroupQuota Request Operator exist'
    if ($roles.Ok) { break }
}

$roleFound = $false
if ($roles.Ok -and @(Get-AqvProp $roles.Body 'value').Count -gt 0) {
    $roleFound = $true
    $r = $roles.Body.value[0]
    $perms = @(Get-AqvProp $r 'properties' 'permissions')
    $summary.groupquota_role = [ordered]@{
        id            = Get-AqvProp $r 'name'
        role_name     = Get-AqvProp $r 'properties' 'roleName'
        description   = Get-AqvProp $r 'properties' 'description'
        actions       = @($perms | ForEach-Object { Get-AqvProp $_ 'actions' } | Where-Object { $_ })
        not_actions   = @($perms | ForEach-Object { Get-AqvProp $_ 'notActions' } | Where-Object { $_ })
        data_actions  = @($perms | ForEach-Object { Get-AqvProp $_ 'dataActions' } | Where-Object { $_ })
        assignable_at = @(Get-AqvProp $r 'properties' 'assignableScopes')
    }
    Write-Host ("    GroupQuota Request Operator: found, id {0}" -f (Get-AqvProp $r 'name')) -ForegroundColor Green
    foreach ($a in $summary.groupquota_role.actions) { Write-Host ("      {0}" -f $a) }
}
else {
    $summary.groupquota_role = $null
    Write-Host ("    GroupQuota Request Operator: NOT FOUND (HTTP {0})." -f $roles.Status) -ForegroundColor Yellow
    Write-Host '    A 404 here usually means the subscription could not be read, not that'
    Write-Host '    the role is missing. Check the subscription IDs before reading anything into it.'
}
$summary.groupquota_role_found = $roleFound

# Quota Request Operator is the per-subscription half and is already used by
# AQV's existing path, so its absence is a real blocker rather than a curiosity.
$qroFilter = "`$filter=roleName eq 'Quota Request Operator'"
$qro = $null
foreach ($sub in @($TargetSubscriptionId, $DonorSubscriptionId)) {
    $qro = Invoke-AqvApi -Method GET `
        -Path "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions?$qroFilter" `
        -ApiVersion '2022-04-01' -Purpose 'A2: Quota Request Operator definition'
    if ($qro.Ok) { break }
}
$summary.quota_request_operator_found = ($qro.Ok -and @(Get-AqvProp $qro.Body 'value').Count -gt 0)

# --- A3: resource provider registration ---------------------------------
Write-Host ''
Write-Host '  Provider registration' -ForegroundColor Cyan
$regs = [ordered]@{}
foreach ($sub in @($DonorSubscriptionId, $TargetSubscriptionId)) {
    $label = if ($sub -eq $DonorSubscriptionId) { 'donor' } else { 'target' }
    $perSub = [ordered]@{}
    foreach ($rp in @('Microsoft.Quota', 'Microsoft.Compute')) {
        $p = Invoke-AqvApi -Method GET -Path "/subscriptions/$sub/providers/$rp" `
            -ApiVersion '2021-04-01' -Purpose "A3: $rp registration on $label"
        $state = if ($p.Ok) { Get-AqvProp $p.Body 'registrationState' } else { "HTTP $($p.Status)" }
        $perSub[$rp] = $state
        Write-Host ("    {0,-8} {1,-20} {2}" -f $label, $rp, $state)
    }
    $regs[$label] = $perSub
}
$summary.provider_registration = $regs

$unreadable = @($regs.Keys | Where-Object { "$($regs[$_].'Microsoft.Compute')" -like 'HTTP 4*' })
if ($unreadable.Count -gt 0) {
    Write-Host ''
    Write-Host ("    Could not read: {0}. Check the subscription ID and your access." -f ($unreadable -join ', ')) -ForegroundColor Yellow
    $summary.unreadable_subscriptions = $unreadable
}

# --- Baseline -----------------------------------------------------------
# The point of the whole step. Everything a later step changes is measured
# against this, so "did we put it back" is answerable rather than arguable.
Write-Host ''
Write-Host '  Baseline quota' -ForegroundColor Cyan
$baseline = [ordered]@{}
foreach ($sub in @($DonorSubscriptionId, $TargetSubscriptionId)) {
    $label = if ($sub -eq $DonorSubscriptionId) { 'donor' } else { 'target' }
    $u = Invoke-AqvApi -Method GET `
        -Path "/subscriptions/$sub/providers/Microsoft.Compute/locations/$Region/usages" `
        -ApiVersion '2024-07-01' -Purpose "baseline: $label vCPU usage in $Region"

    $rows = @()
    if ($u.Ok -and $null -ne (Get-AqvProp $u.Body 'value')) {
        foreach ($v in $u.Body.value) {
            $rows += [ordered]@{
                name    = Get-AqvProp $v 'name' 'value'
                limit   = Get-AqvProp $v 'limit'
                current = Get-AqvProp $v 'currentValue'
            }
        }
    }
    $baseline[$label] = [ordered]@{
        subscription_id = $sub
        region          = $Region
        families        = $rows
    }
    $spare = @($rows | Where-Object { $_.name -like '*Family' -and ($_.limit - $_.current) -ge 10 })
    Write-Host ("    {0,-8} {1} family entries, {2} with 10 or more spare vCPUs" -f $label, $rows.Count, $spare.Count)
}
$summary.baseline = $baseline

# A donor with nothing spare makes step 4 pointless, and it is better to know now.
$donorSpare = @($baseline.donor.families |
    Where-Object { $_.name -like '*Family' -and ($_.limit - $_.current) -ge 10 })
if ($donorSpare.Count -eq 0) {
    Write-Host ''
    Write-Host '    The donor has no family with 10 or more spare vCPUs.' -ForegroundColor Yellow
    Write-Host '    Step 4 moves quota out of it, so pick a donor with room, or expect step 4 to be skipped.'
}
else {
    Write-Host ''
    Write-Host '    Donor families with room, largest first:'
    $donorSpare |
        Sort-Object { - ($_.limit - $_.current) } |
        Select-Object -First 5 |
        ForEach-Object {
            Write-Host ("      {0,-30} limit={1,-6} used={2,-6} spare={3}" -f
                $_.name, $_.limit, $_.current, ($_.limit - $_.current))
        }
}

# --- Existing group membership ------------------------------------------
# A subscription can be in only one quota group. If either of these is already
# in one, the run needs different subscriptions, not a workaround.
Write-Host ''
Write-Host '  Environment' -ForegroundColor Cyan
$ver = az version -o json 2>$null | ConvertFrom-Json
$summary.az_cli_version = Get-AqvProp $ver 'azure-cli'
$acct = az account show -o json 2>$null | ConvertFrom-Json
$summary.tenant_id = Get-AqvProp $acct 'tenantId'
$summary.cloud = Get-AqvProp $acct 'environmentName'
Write-Host ("    az CLI {0}, cloud {1}" -f $summary.az_cli_version, $summary.cloud)

$file = Save-AqvCapture -Name '00-preflight' -Summary $summary

Write-Host ''
Write-Host '  Result' -ForegroundColor Cyan
if ($summary.eligible_agreement_found) {
    Write-Host '    Eligible agreement type found. Step 1 can run.' -ForegroundColor Green
}
else {
    Write-Host '    No eligible agreement type found.' -ForegroundColor Red
    Write-Host '    Quota groups need EA, MCA-Enterprise or Internal. Stop here and'
    Write-Host '    send this capture: knowing what an ineligible account returns is'
    Write-Host '    itself a finding AQV needs.'
}
Write-Host ''
