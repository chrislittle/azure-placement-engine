<#
    .SYNOPSIS
    Asks a subscription what it can run right now.

    .DESCRIPTION
    The PowerShell twin of main.tf in this directory. For application teams on
    the Bicep path, or for anyone who wants an answer without running Terraform.

    There is no Bicep here. Bicep only writes, and this asks a question.

    It writes nothing. Reader on the subscription is enough, because AqvRead
    calls only read APIs and AqvDecide does not touch Azure at all.

    .EXAMPLE
    ./Get-WhatCanIDeploy.ps1 -SubscriptionId $sub -Region eastus -VCpus 64

    .EXAMPLE
    ./Get-WhatCanIDeploy.ps1 -SubscriptionId $sub -Region eastus -VCpus 64 `
        -Category MemoryOptimized -Architecture Arm64

    .EXAMPLE
    ./Get-WhatCanIDeploy.ps1 -SubscriptionId $sub -Region eastus -AsJson

    Returns the whole decision as JSON, for a pipeline to act on.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Region,

    [int]$VCpus = 8,

    [ValidateSet('GeneralPurpose', 'ComputeOptimized', 'MemoryOptimized', 'StorageOptimized',
        'GpuAccelerated', 'FpgaAccelerated', 'HighPerformanceCompute')]
    [string]$Category,

    [ValidateSet('x64', 'Arm64')]
    [string]$Architecture,

    [ValidateSet('Excluded', 'Required')]
    [string]$Burstable,

    # Leave false for a subscription that already holds quota. Growth-restricted
    # families can still be used within quota already granted, but not grown.
    [switch]$NewSubscription,

    # Optional. The platform team's rules file.
    #
    # Without it, the answer is what AZURE permits. With it, the answer is what
    # the PLATFORM would grant, which can be stricter.
    [string]$RulesFile,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Join-Path $PSScriptRoot '..' '..'
Import-Module (Join-Path $repo 'powershell' 'AqvRead.psm1') -Force
Import-Module (Join-Path $repo 'powershell' 'AqvDecide.psm1') -Force

$request = @{
    region           = $Region
    vcpus            = $VCpus
    new_subscription = [bool]$NewSubscription
}
if ($Category) { $request.category = $Category }
if ($Architecture) { $request.architecture = $Architecture }
if ($Burstable) { $request.burstable = $Burstable }

$rules = @()
if ($RulesFile) {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        throw 'powershell-yaml is required to read a rules file. Install-Module powershell-yaml'
    }
    Import-Module powershell-yaml -Force
    $doc = ConvertFrom-Yaml (Get-Content $RulesFile -Raw)
    $rules = @($doc.rules)
}

$state = Get-AqvState -SubscriptionId $SubscriptionId -Region $Region -KnowledgeDir (Join-Path $repo 'knowledge')
$decision = Get-AqvDecision -Request $request -Quota $state.quota -SkuAccess $state.sku_access -Rules $rules

if ($AsJson) {
    $decision | ConvertTo-Json -Depth 8
    exit 0
}

$ok = $decision.status -eq 'satisfied'
$colour = if ($ok) { 'Green' } elseif ($decision.status -in @('needs_allocation', 'needs_increase')) { 'Yellow' } else { 'Red' }

Write-Host ''
Write-Host ("  Can I deploy {0} vCPUs in {1}?" -f $VCpus, $Region)
Write-Host ("  {0}" -f $(if ($ok) { 'Yes' } else { 'Not yet' })) -ForegroundColor $colour
Write-Host ''
Write-Host ("  status     : {0}" -f $decision.status)
Write-Host ("  reason     : {0}" -f $decision.reason)

# Without a rules file this says what Azure permits. The platform may be
# stricter, and the pipeline applies those rules.
if ($RulesFile) {
    Write-Host ("  rule       : {0}" -f $decision.rule_applied)
}
else {
    Write-Host '  rule       : none applied — this is what Azure permits,' -ForegroundColor DarkYellow
    Write-Host '               not what the platform would grant' -ForegroundColor DarkYellow
}

if ($decision.family) {
    Write-Host ("  use family : {0}" -f $decision.family) -ForegroundColor Cyan
}

# Anything here needs the platform team. Raising quota needs more than Reader.
$writes = @($decision.writes_required)
if ($writes.Count -gt 0) {
    Write-Host ''
    Write-Host '  Needs the platform team to write:' -ForegroundColor Yellow
    $writes | ForEach-Object { Write-Host ("    {0} {1} -> {2}" -f $_.scope, $_.name, $_.limit) }
}

# Only when the request itself was refused. A remediation is populated whenever
# any family was denied, and showing it after a successful answer reads as
# though something is wrong.
# Only when ACCESS is what refused it. A rule refusal or a size refusal is not
# fixed by a SKU access request, and saying so sends someone to the wrong queue.
if ($decision.status -eq 'blocked_by_access' -and $decision.access.remediation) {
    Write-Host ''
    Write-Host ("  To lift it : {0}" -f $decision.access.remediation) -ForegroundColor Yellow
}

$denied = @($decision.lifecycle.denied)
if (-not $ok -and $denied.Count -gt 0) {
    Write-Host ''
    Write-Host ("  Growth-restricted, unavailable to a new subscription: {0}" -f ($denied -join ', '))
    $successors = @($decision.lifecycle.successors)
    if ($successors.Count -gt 0) {
        Write-Host ("  Use instead: {0}" -f ($successors -join ', '))
    }
}

$sizes = @($decision.sizes | Where-Object { $_.vcpus -and $_.vcpus -le $VCpus } | Sort-Object { -$_.vcpus })
if ($ok -and $sizes.Count -gt 0) {
    Write-Host ''
    Write-Host '  Sizes you can deploy:' -ForegroundColor Cyan
    $sizes | Select-Object -First 5 | ForEach-Object {
        Write-Host ("    {0,-26} {1,3} vCPU   deploy {2}" -f $_.name, $_.vcpus, $_.count_at)
    }
}

$considered = @($decision.considered)
if ($considered.Count -gt 1) {
    Write-Host ''
    Write-Host '  Why not the others:'
    $considered | Sort-Object { $_.outcome -ne 'chosen' } | Select-Object -First 8 | ForEach-Object {
        Write-Host ("    {0,-34} limit={1,-6} unused={2,-6} {3}" -f $_.family, $_.limit, $_.unused, $_.outcome)
    }
}
Write-Host ''
