# Reads live Azure state for the Bicep path.
#
# The PowerShell twin of modules/aqv-read. Same three reads, same projections,
# same output shape -- because the decision logic downstream is held to the same
# conformance scenarios in both languages.
#
# Uses Invoke-AzRestMethod rather than az CLI so the Bicep path needs only the
# Az module a Bicep shop already has.

Set-StrictMode -Version Latest

$script:ComputeApi = '2021-07-01'
$script:ProviderApi = '2021-04-01'

$script:RegionalTotals = @('cores', 'lowprioritycores', 'virtualmachines', 'virtualmachinescalesets')

function Invoke-Arm {
    param([string]$Path)
    $r = Invoke-AzRestMethod -Path $Path -Method GET
    if ($r.StatusCode -ge 400) {
        throw "ARM $($r.StatusCode) for $Path : $($r.Content)"
    }
    return ($r.Content | ConvertFrom-Json)
}

function Get-AqvRegionAccess {
    <#
        .SYNOPSIS
        Whether the subscription can use the region at all.

        .DESCRIPTION
        Reads the Microsoft.Compute provider registration, which is the only
        clean probe for this. Asking Compute usages about a region the
        subscription lacks returns HTTP 400 NoRegisteredProviderFound -- and
        Microsoft.Compute/skus cannot see the gap at all: for Germany North it
        returns 866 VM SKUs of which 796 carry no restriction whatsoever, for a
        subscription that cannot deploy there.

        Registration state and region grant are reported separately because one
        resolves by waiting and the other needs a support ticket.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region
    )

    $p = Invoke-Arm "/subscriptions/$SubscriptionId/providers/Microsoft.Compute?api-version=$script:ProviderApi"

    $registered = $p.registrationState -eq 'Registered'
    $usageType = @($p.resourceTypes | Where-Object { $_.resourceType -eq 'locations/usages' })
    $locations = if ($usageType.Count -gt 0) {
        @($usageType[0].locations | ForEach-Object { $_.ToLower().Replace(' ', '') })
    }
    else { @() }

    [pscustomobject]@{
        provider_registered = $registered
        region_granted      = $Region.ToLower().Replace(' ', '') -in $locations
        region_accessible   = $registered -and ($Region.ToLower().Replace(' ', '') -in $locations)
    }
}

function Get-AqvVmCategory {
    <#
        Azure vmCategory for a family. Order matters -- see
        knowledge/vm-series-classes.yaml. Mirrors the same function in
        scripts/read_quota.py and modules/aqv-read/project.tf.
    #>
    param([string]$Family, [double[]]$Ratios, [bool]$HasGpu, [bool]$HasRdma)

    # NP reports a GPUs capability although its accelerators are FPGAs, so this
    # must be tested before the GPU check.
    if ($Family -match '(?i)^standardNP') { return 'FpgaAccelerated' }
    if ($HasGpu) { return 'GpuAccelerated' }
    if ($HasRdma) { return 'HighPerformanceCompute' }
    if ($Family -match '(?i)^standardL') { return 'StorageOptimized' }
    if ($Ratios.Count -eq 0) { return $null }

    $sorted = @($Ratios | Sort-Object)
    $median = $sorted[[int][Math]::Floor($sorted.Count / 2)]
    if ($median -lt 3) { return 'ComputeOptimized' }
    if ($median -le 6) { return 'GeneralPurpose' }
    return 'MemoryOptimized'
}

function Get-AqvQuota {
    <#
        .SYNOPSIS
        Quota state for a region, shaped for Get-AqvDecision's -Quota.

        .DESCRIPTION
        Families reporting a limit of zero are omitted: absent is not the same
        as unavailable, and a zero-limit family is not a candidate. Growth-
        restricted families are annotated rather than filtered, because an
        EXISTING subscription can still deploy them within quota it already
        holds -- only the decision module knows whether the target is new.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region,
        [string]$KnowledgeDir = (Join-Path $PSScriptRoot '..' 'knowledge'),
        $Access
    )

    if (-not $Access) { $Access = Get-AqvRegionAccess -SubscriptionId $SubscriptionId -Region $Region }

    $quota = [ordered]@{
        region_accessible    = $Access.region_accessible
        provider_registered  = $Access.provider_registered
        regional_cores_limit = 0
        regional_cores_used  = 0
        families             = [ordered]@{}
    }
    if (-not $Access.region_accessible) { return [pscustomobject]$quota }

    $usages = Invoke-Arm "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Region/usages?api-version=$script:ComputeApi"
    $restricted = Get-AqvGrowthRestricted -KnowledgeDir $KnowledgeDir

    foreach ($u in $usages.value) {
        $name = $u.name.value
        if (-not $name) { continue }
        if ($name.ToLower() -eq 'cores') {
            $quota.regional_cores_limit = [int]$u.limit
            $quota.regional_cores_used = [int]$u.currentValue
        }
        elseif ($name.ToLower().EndsWith('family') -and [int]$u.limit -gt 0) {
            $quota.families[$name] = [ordered]@{
                limit     = [int]$u.limit
                used       = [int]$u.currentValue
                lifecycle = if ($name -in $restricted) { 'growth_restricted' } else { 'current' }
            }
        }
    }

    return [pscustomobject]$quota
}

function Get-AqvGrowthRestricted {
    <#
        Families frozen by the July 2026 capacity growth restrictions, read from
        knowledge/ rather than duplicated here so the list has one home. Scanned
        rather than YAML-parsed to keep this dependency-free; the block is a
        flat list of family names and nothing else in it looks like one.
    #>
    param([string]$KnowledgeDir)
    $text = Get-Content (Join-Path $KnowledgeDir 'vm-series-lifecycle.yaml') -Raw
    $block = ($text -split 'growth_restricted_families:')[1]
    $block = ($block -split 'naming_notes:')[0]
    return @([regex]::Matches($block, '\bstandard\w*Family\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
}

function Get-AqvSkuAccess {
    <#
        .SYNOPSIS
        What the subscription may deploy in the region, plus per-family
        attributes, shaped for Get-AqvDecision.

        .DESCRIPTION
        Published and restricted zones are returned side by side rather than
        subtracted here: the subtraction is decision logic and belongs where it
        is tested. The restricted list is NOT constrained to be a subset of the
        published one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region
    )

    $skus = Invoke-Arm ("/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=$script:ComputeApi" +
        "&`$filter=location eq '$Region'")

    $access = [ordered]@{}
    $agg = @{}

    foreach ($s in $skus.value) {
        if ($s.resourceType -ne 'virtualMachines') { continue }
        $family = $s.family
        if (-not $family) { continue }

        $zones = @()
        foreach ($li in @($s.locationInfo)) { $zones += @($li.zones) }
        $zones = @($zones | Where-Object { $_ } | Select-Object -Unique | Sort-Object)

        $restrictedZones = @()
        $locationRestricted = $false
        $reason = $null
        foreach ($r in @($s.restrictions)) {
            if (-not $reason) { $reason = $r.reasonCode }
            if ($r.type -eq 'Zone') { $restrictedZones += @($r.restrictionInfo.zones) }
            else { $locationRestricted = $true }
        }
        $restrictedZones = @($restrictedZones | Where-Object { $_ } | Select-Object -Unique | Sort-Object)

        $entry = [ordered]@{ zones = $zones; restricted_zones = $restrictedZones }
        if ($locationRestricted) { $entry.location_restricted = $true }
        if ($reason) { $entry.restriction_reason = $reason }

        if (-not $access.Contains($family)) { $access[$family] = [ordered]@{ sizes = [ordered]@{} } }
        $access[$family].sizes[$s.name] = $entry

        if (-not $agg.ContainsKey($family)) {
            $agg[$family] = @{ ratios = [System.Collections.Generic.List[double]]::new(); gpu = $false; rdma = $false; cc = $false; arch = @() }
        }
        $caps = @{}
        foreach ($c in @($s.capabilities)) { $caps[$c.name] = $c.value }

        $vcpus = if ($caps.ContainsKey('vCPUs')) { [double]$caps['vCPUs'] } else { 0 }

        # The workload team deploys a size, not a family, so the size carries
        # its own vCPU count through to the decision.
        $entry.vcpus = if ($vcpus -gt 0) { [int]$vcpus } else { $null }
        $memory = if ($caps.ContainsKey('MemoryGB')) { [double]$caps['MemoryGB'] } else { 0 }
        if ($vcpus -gt 0) { $agg[$family].ratios.Add($memory / $vcpus) }
        if ($caps.ContainsKey('GPUs') -and [double]$caps['GPUs'] -gt 0) { $agg[$family].gpu = $true }
        if ($caps.ContainsKey('RdmaEnabled') -and "$($caps['RdmaEnabled'])".ToLower() -eq 'true') { $agg[$family].rdma = $true }
        if ($caps.ContainsKey('ConfidentialComputingType')) { $agg[$family].cc = $true }
        if ($caps.ContainsKey('CpuArchitectureType')) { $agg[$family].arch += $caps['CpuArchitectureType'] }
    }

    $attributes = [ordered]@{}
    foreach ($family in $agg.Keys) {
        $a = $agg[$family]
        $attributes[$family] = [ordered]@{
            category               = Get-AqvVmCategory -Family $family -Ratios $a.ratios.ToArray() -HasGpu $a.gpu -HasRdma $a.rdma
            burstable              = [bool]($family -match '(?i)^standardB')
            confidential_computing = $a.cc
            architectures          = @($a.arch | Select-Object -Unique | Sort-Object)
        }
    }

    [pscustomobject]@{ sku_access = [pscustomobject]$access; attributes = [pscustomobject]$attributes }
}

function Get-AqvState {
    <#
        .SYNOPSIS
        Everything Get-AqvDecision needs, in one call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region,
        [string]$KnowledgeDir = (Join-Path $PSScriptRoot '..' 'knowledge')
    )

    $access = Get-AqvRegionAccess -SubscriptionId $SubscriptionId -Region $Region
    $quota = Get-AqvQuota -SubscriptionId $SubscriptionId -Region $Region -KnowledgeDir $KnowledgeDir -Access $access

    if (-not $access.region_accessible) {
        return [pscustomobject]@{ quota = $quota; sku_access = [pscustomobject]@{} }
    }

    $sku = Get-AqvSkuAccess -SubscriptionId $SubscriptionId -Region $Region

    # Category and attributes belong on the quota entry the decision ranks, not
    # on the access data.
    foreach ($f in $quota.families.Keys) {
        $attrs = $sku.attributes.PSObject.Properties[$f]
        if ($attrs -and $attrs.Value.category) {
            foreach ($k in @('category', 'burstable', 'confidential_computing', 'architectures')) {
                $quota.families[$f][$k] = $attrs.Value.$k
            }
        }
    }

    [pscustomobject]@{ quota = $quota; sku_access = $sku.sku_access }
}

Export-ModuleMember -Function Get-AqvState, Get-AqvQuota, Get-AqvSkuAccess, Get-AqvRegionAccess, Get-AqvVmCategory, Get-AqvGrowthRestricted
