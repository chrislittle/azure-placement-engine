# The placement decision, in PowerShell, for the Bicep path.
#
# Bicep cannot read quota state -- see docs/GUIDE.md -- so on that path the
# reading and the deciding happen here and Bicep only writes. On the Terraform
# path all three happen in Terraform.
#
# That means this logic exists twice, which is a real cost and is guarded the
# only way it can be: both implementations are run against the same scenarios in
# conformance/scenarios, by conformance/terraform and Invoke-Conformance.ps1.
# If they ever disagree, a test fails rather than a customer getting a different
# answer from the Bicep path.
#
# Keep this file and modules/ape-placement/main.tf in step. The comments there
# explain WHY each gate exists; they are not repeated here.

Set-StrictMode -Version Latest

$script:AzureCategories = @(
    'GeneralPurpose', 'ComputeOptimized', 'MemoryOptimized', 'StorageOptimized',
    'GpuAccelerated', 'FpgaAccelerated', 'HighPerformanceCompute'
)

function Get-Prop {
    # Any dictionary or PSCustomObject; a missing key returns the default.
    #
    # IDictionary rather than [hashtable]: `[ordered]@{}` is an
    # OrderedDictionary and does NOT match [hashtable], so testing for the
    # concrete type silently misses every key in an ordered hashtable -- which
    # is what the readers build.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-Keys {
    # Key names of a hashtable or PSCustomObject. Going through PSObject
    # .Properties.Name directly throws under StrictMode when the object has no
    # properties at all, which an empty sku_access does.
    param($Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-EffectiveZones {
    <#
        Published zones MINUS restricted zones, and nothing at all when the size
        carries a Location-level restriction.

        The restricted list is not constrained to be a subset of the published
        one: Standard_D1 in East US publishes zones 2 and 3 while restricting 1,
        2 and 3, which nets to nothing deployable.
    #>
    param($Size)
    if (Get-Prop $Size 'location_restricted' $false) { return @() }
    $published = @(Get-Prop $Size 'zones' @())
    $restricted = @(Get-Prop $Size 'restricted_zones' @())
    return @($published | Where-Object { $_ -notin $restricted } | Sort-Object)
}

function Get-ApePlacement {
    <#
        .SYNOPSIS
        Decides which VM family a subscription should get and what its quota
        limit should be set to.

        .DESCRIPTION
        Mirrors modules/ape-placement. Takes the same four inputs and returns the
        same decision shape. Touches nothing in Azure -- reading is the caller's
        job, exactly as it is for the Terraform module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] $Quota,
        $SkuAccess = @{},
        $Rules = @()
    )

    $region = Get-Prop $Request 'region'
    $vcpus = [int](Get-Prop $Request 'vcpus' 0)
    if ($vcpus -le 0) { throw 'request.vcpus must be greater than zero.' }

    $wantedCategory = Get-Prop $Request 'category'
    if ($wantedCategory -and $wantedCategory -notin $script:AzureCategories) {
        throw "request.category must be an Azure vmCategories value; got '$wantedCategory'."
    }

    $families = Get-Prop $Quota 'families' @{}
    $familyNames = @(Get-Keys $families)

    # --- region gate -----------------------------------------------------
    $providerRegistered = [bool](Get-Prop $Quota 'provider_registered' $true)
    $regionAccessible = [bool](Get-Prop $Quota 'region_accessible' $true)

    # --- attribute narrowing ---------------------------------------------
    $wantArch = Get-Prop $Request 'architecture'
    $wantBurstable = Get-Prop $Request 'burstable'
    $wantConfidential = Get-Prop $Request 'confidential_computing'
    $filteringOnAttributes = [bool]($wantedCategory -or $wantArch -or $wantBurstable -or $wantConfidential)

    $attributeMatched = @($familyNames | Where-Object {
            $d = Get-Prop $families $_
            $ok = $true
            if ($wantedCategory) { $ok = $ok -and ((Get-Prop $d 'category') -eq $wantedCategory) }
            if ($wantArch) { $ok = $ok -and ($wantArch -in @(Get-Prop $d 'architectures' @())) }
            if ($wantBurstable) { $ok = $ok -and ([bool](Get-Prop $d 'burstable' $false) -eq ($wantBurstable -eq 'Required')) }
            if ($wantConfidential) { $ok = $ok -and ([bool](Get-Prop $d 'confidential_computing' $false) -eq ($wantConfidential -eq 'Required')) }
            $ok
        } | Sort-Object)

    $explicitFamily = Get-Prop $Request 'family'
    $requestAllowlist = Get-Prop $Request 'family_allowlist'

    if ($explicitFamily) { $requested = @($explicitFamily) }
    elseif ($requestAllowlist) { $requested = @($requestAllowlist) }
    elseif ($filteringOnAttributes) { $requested = $attributeMatched }
    else { $requested = @($familyNames | Sort-Object) }

    $classUnmatched = $filteringOnAttributes -and $attributeMatched.Count -eq 0

    # --- rules ------------------------------------------------------------
    $environment = Get-Prop $Request 'environment' 'prod'
    $rule = @($Rules | Where-Object {
            $envs = Get-Prop $_ 'environments'
            (-not $envs) -or ($environment -in @($envs))
        }) | Select-Object -First 1

    $ruleName = if ($rule) { Get-Prop $rule 'name' } else { '(none)' }
    $prefer = if ($rule) { Get-Prop $rule 'prefer' 'most_unused' } else { 'most_unused' }
    $ruleCap = if ($rule) { Get-Prop $rule 'max_vcpus' } else { $null }
    $overRuleCap = ($null -ne $ruleCap) -and ($vcpus -gt [int]$ruleCap)

    # Iterate the rule's allowlist rather than filtering by it, so its order
    # survives the intersection -- `prefer = listed_order` means the order the
    # rule listed.
    $ruleAllowlist = if ($rule) { Get-Prop $rule 'family_allowlist' } else { $null }
    $ruleAllowed = @(if ($ruleAllowlist) {
            @(@($ruleAllowlist) | Where-Object { $_ -in $requested })
        }
        else { $requested })

    $ruleDenylist = if ($rule) { Get-Prop $rule 'family_denylist' } else { $null }
    $rulePermitted = @(if ($ruleDenylist) {
            @($ruleAllowed | Where-Object { $_ -notin @($ruleDenylist) })
        }
        else { $ruleAllowed })

    $unknownFamilies = @($rulePermitted | Where-Object { $_ -notin $familyNames })
    $knownFamilies = @($rulePermitted | Where-Object { $_ -in $familyNames })

    # --- lifecycle gate ---------------------------------------------------
    $newSubscription = [bool](Get-Prop $Request 'new_subscription' $true)
    $lifecycleOf = @{}
    foreach ($f in $familyNames) { $lifecycleOf[$f] = Get-Prop (Get-Prop $families $f) 'lifecycle' 'current' }

    $lifecycleDenied = @(if ($newSubscription) {
            @($knownFamilies | Where-Object { $lifecycleOf[$_] -eq 'growth_restricted' })
        }
        else { @() })
    $lifecyclePermitted = @($knownFamilies | Where-Object { $_ -notin $lifecycleDenied })

    $suggestedSuccessors = @($lifecycleDenied | ForEach-Object {
            Get-Prop (Get-Prop $families $_) 'successors' @()
        } | Select-Object -Unique)

    # --- access gate -------------------------------------------------------
    $accessFamilies = @(Get-Keys $SkuAccess)
    $accessChecked = $accessFamilies.Count -gt 0

    $placement = Get-Prop $Request 'placement' @{}
    $placementType = Get-Prop $placement 'type' 'regional'
    $wantedZones = @(Get-Prop $placement 'zones' @())
    $wantedZoneCount = if ($placementType -eq 'zone_redundant') { [int](Get-Prop $placement 'zone_count' 3) } else { 0 }
    $zonalRequest = $placementType -ne 'regional'

    $sizeAccess = @{}
    foreach ($f in $accessFamilies) {
        $sizes = Get-Prop (Get-Prop $SkuAccess $f) 'sizes' @{}
        $sizeAccess[$f] = @(@(Get-Keys $sizes) | ForEach-Object {
                $sz = Get-Prop $sizes $_
                [pscustomobject]@{
                    name                = $_
                    effective_zones     = Get-EffectiveZones $sz
                    published_zones     = @(Get-Prop $sz 'zones' @())
                    location_restricted = [bool](Get-Prop $sz 'location_restricted' $false)
                    reason              = Get-Prop $sz 'restriction_reason'
                }
            })
    }

    # Published zones, not effective ones: whether a region HAS zones is a
    # property of the region, not of this subscription's restrictions.
    $regionZonal = [bool](@($sizeAccess.Values | ForEach-Object { $_ } |
            Where-Object { @($_.published_zones).Count -gt 0 }).Count -gt 0)

    $familyDeployable = @{}
    foreach ($f in $sizeAccess.Keys) {
        $sizes = @($sizeAccess[$f])
        # Deployable if at least ONE size satisfies the placement type -- a
        # customer buys a family's worth of quota and deploys a specific size.
        $familyDeployable[$f] = switch ($placementType) {
            'regional' {
                @($sizes | Where-Object { -not $_.location_restricted }).Count -gt 0
            }
            'zonal' {
                @($sizes | Where-Object {
                        $eff = $_.effective_zones
                        @($wantedZones | Where-Object { $_ -notin $eff }).Count -eq 0
                    }).Count -gt 0
            }
            default {
                @($sizes | Where-Object { @($_.effective_zones).Count -ge $wantedZoneCount }).Count -gt 0
            }
        }
    }

    $notOffered = @(if ($accessChecked) {
            @($lifecyclePermitted | Where-Object { $_ -notin $sizeAccess.Keys })
        }
        else { @() })
    $accessPermitted = @(if ($accessChecked) {
            @($lifecyclePermitted | Where-Object { ($_ -in $sizeAccess.Keys) -and $familyDeployable[$_] })
        }
        else { $lifecyclePermitted })
    $accessDenied = @(if ($accessChecked) {
            @($lifecyclePermitted | Where-Object { ($_ -in $sizeAccess.Keys) -and -not $familyDeployable[$_] })
        }
        else { @() })
    $accessUnverified = @(if ($accessChecked) { @() } else { $lifecyclePermitted })

    $deniedReasons = @($accessDenied | ForEach-Object { $sizeAccess[$_] | ForEach-Object { $_.reason } } | Where-Object { $_ })
    $requestable = if ($zonalRequest -and $accessChecked -and -not $regionZonal) { $false }
    else { 'NotAvailableForSubscription' -in $deniedReasons }

    $deniedByLocation = ($accessDenied.Count -gt 0) -and
    (@($accessDenied | Where-Object {
            @($sizeAccess[$_] | Where-Object { -not $_.location_restricted }).Count -gt 0
        }).Count -eq 0)

    # --- quota arithmetic --------------------------------------------------
    $regionalLimit = [int](Get-Prop $Quota 'regional_cores_limit' 0)
    $regionalUsed = [int](Get-Prop $Quota 'regional_cores_used' 0)
    $regionalHeadroom = [Math]::Max(0, $regionalLimit - $regionalUsed)

    $reachable = @($accessPermitted | ForEach-Object {
            $d = Get-Prop $families $_
            $limit = [int](Get-Prop $d 'limit' 0)
            $used = [int](Get-Prop $d 'used' 0)
            $available = Get-Prop $d 'available'
            $unused = [Math]::Max(0, $limit - $used)
            $allocatable = if ($null -eq $available) { 0 } else { [Math]::Max(0, [int]$available) }
            [pscustomobject]@{
                family         = $_
                limit          = $limit
                used           = $used
                unused       = $unused
                allocatable      = $allocatable
                has_group_quota         = $null -ne $available
                satisfied_now  = $unused -ge $vcpus
                satisfied_with_allocation = ($unused + $allocatable) -ge $vcpus
            }
        })

    $eligible = @(if ($overRuleCap) { @() }
        else {
            @($reachable | Where-Object {
                    $_.satisfied_with_allocation -and (($lifecycleOf[$_.family] -ne 'growth_restricted') -or $_.satisfied_now)
                })
        })

    # The same padded sort key the Terraform module builds, sorted with an
    # ORDINAL comparer. Sort-Object is case-insensitive and culture-aware, which
    # ordered `StandardDadsv7Family` and `standardDav6Family` differently from
    # Terraform and picked a different family on a unused tie.
    if ($prefer -eq 'listed_order') {
        $ranked = @($rulePermitted | Where-Object { $_ -in @($eligible | ForEach-Object family) })
    }
    else {
        [string[]]$keys = @($eligible | ForEach-Object {
                $h = $_.unused + $_.allocatable
                '{0:D9}|{1}' -f $(if ($prefer -eq 'most_unused') { 999999999 - $h } else { $h }), $_.family
            })
        if ($keys.Count -gt 0) { [Array]::Sort($keys, [System.StringComparer]::Ordinal) }
        $ranked = @($keys | ForEach-Object { $_.Substring($_.IndexOf('|') + 1) })
    }

    $chosen = if ($ranked.Count -gt 0) { $ranked[0] } else { $null }
    $chosenDetail = if ($chosen) { @($reachable | Where-Object family -EQ $chosen)[0] } else { $null }

    $targetLimit = if ($chosenDetail) { [Math]::Max($chosenDetail.limit, $chosenDetail.used + $vcpus) } else { $null }
    $regionalIncreaseRequired = $vcpus -gt $regionalHeadroom
    $regionalTarget = [Math]::Max($regionalLimit, $regionalUsed + $vcpus)

    $allBlockedByLifecycle = ($lifecyclePermitted.Count -eq 0) -and ($lifecycleDenied.Count -gt 0)
    $allBlockedByAccess = $accessChecked -and ($accessPermitted.Count -eq 0) -and
        (($accessDenied.Count -gt 0) -or ($notOffered.Count -gt 0))

    $status =
    if (-not $providerRegistered) { 'not_ready' }
    elseif (-not $regionAccessible) { 'blocked_by_region' }
    elseif ($classUnmatched) { 'infeasible' }
    elseif ($overRuleCap) { 'blocked_by_rule' }
    elseif ($allBlockedByLifecycle) { 'blocked_by_lifecycle' }
    elseif ($allBlockedByAccess) { 'blocked_by_access' }
    elseif (-not $chosen) { 'infeasible' }
    elseif ($chosenDetail.satisfied_now -and -not $regionalIncreaseRequired) { 'satisfied' }
    elseif ($chosenDetail.has_group_quota -and -not $regionalIncreaseRequired) { 'needs_allocation' }
    else { 'needs_increase' }

    $wantedDescription = @($wantedCategory, $wantArch,
        $(if ($wantBurstable) { "burstable $wantBurstable" }),
        $(if ($wantConfidential) { "confidential $wantConfidential" })) |
    Where-Object { $_ }

    $reason =
    if (-not $providerRegistered) { 'Microsoft.Compute is not registered on this subscription yet; this resolves on its own shortly after vending and is not an access problem' }
    elseif (-not $regionAccessible) { "the subscription has no access to $region; this needs a region access request and no amount of quota will help" }
    elseif ($classUnmatched) { "the subscription holds no quota in $region matching $($wantedDescription -join ', ')" }
    elseif ($overRuleCap) { "rule `"$ruleName`" caps requests at $ruleCap vCPUs" }
    elseif ($allBlockedByLifecycle) {
        $tail = if ($suggestedSuccessors.Count -gt 0) { "; use $($suggestedSuccessors -join ', ') instead" } else { '' }
        "every candidate family is under the capacity growth restriction, which a new subscription cannot deploy at all$tail"
    }
    elseif ($allBlockedByAccess -and $zonalRequest -and -not $regionZonal) {
        $kind = if ($placementType -eq 'zonal') { 'zonal' } else { 'zone-redundant' }
        "$region has no availability zones, so a $kind placement is impossible there -- deploy regionally or choose a zonal region"
    }
    elseif ($allBlockedByAccess -and $accessDenied.Count -eq 0) {
        "no candidate family is offered in $region; quota for them exists but Azure has no sizes to deploy there"
    }
    elseif ($allBlockedByAccess) {
        $kind = if ($placementType -eq 'regional') { 'regional' } else { 'zonal' }
        $tail = if ($requestable) { 'requestable via a SKU access request' } else { 'the subscription offer excludes it, which no support ticket will change' }
        "no candidate family has $kind access on this subscription; $tail"
    }
    elseif ($knownFamilies.Count -eq 0) { 'no candidate family is present in the quota' }
    elseif (-not $chosen) { "no candidate family can reach $vcpus vCPUs" }
    elseif ($status -eq 'satisfied') { 'existing quota covers the request' }
    elseif ($status -eq 'needs_allocation') { 'the quota can cover the shortfall without a limit increase' }
    else { 'a quota limit increase is required, and increases are evaluated rather than granted' }

    $remediation =
    if ($zonalRequest -and $accessChecked -and -not $regionZonal) {
        "$region has no availability zones. Deploy regionally, or pick a region that has them -- there is no ticket for this."
    }
    elseif ($accessDenied.Count -eq 0) { $null }
    elseif (-not $requestable) { 'QuotaId: the subscription offer excludes these SKUs. No support ticket will lift this -- choose a different family.' }
    elseif ($deniedByLocation) { 'Raise a region or SKU access request (quota type: Compute-VM subscription limit increases) for the denied families.' }
    else { 'Raise a zonal enablement request (quota type: Compute-VM, then Zone access) for the denied zones. Regional placement of the same families is unaffected.' }

    $writes = @()
    if ($chosen) {
        if ($regionalIncreaseRequired) {
            $writes += [pscustomobject]@{ scope = 'regional'; name = 'cores'; limit = $regionalTarget }
        }
        if ($targetLimit -gt $chosenDetail.limit) {
            $writes += [pscustomobject]@{ scope = 'family'; name = $chosen; limit = $targetLimit }
        }
    }

    [pscustomobject]@{
        status       = $status
        reason       = $reason
        region       = $region
        vcpus        = $vcpus
        category     = $wantedCategory
        family       = $chosen
        target_limit = $targetLimit

        regional     = [pscustomobject]@{
            limit             = $regionalLimit
            used              = $regionalUsed
            unused          = $regionalHeadroom
            increase_required = $regionalIncreaseRequired
            target            = if ($regionalIncreaseRequired) { $regionalTarget } else { $regionalLimit }
        }

        lifecycle    = [pscustomobject]@{
            new_subscription = $newSubscription
            denied           = $lifecycleDenied
            successors       = $suggestedSuccessors
            frozen           = @($accessPermitted | Where-Object { $lifecycleOf[$_] -eq 'growth_restricted' })
        }

        access       = [pscustomobject]@{
            checked             = $accessChecked
            verified            = $accessChecked -and $null -ne $chosen
            provider_registered = $providerRegistered
            region_accessible   = $regionAccessible
            region_zonal        = if ($accessChecked) { $regionZonal } else { $null }
            placement           = $placementType
            zones               = if ($placementType -eq 'zonal') { $wantedZones } else { @() }
            zone_count          = $wantedZoneCount
            denied              = $accessDenied
            not_offered         = $notOffered
            unverified          = $accessUnverified
            requestable         = $requestable
            remediation         = $remediation
        }

        rule_applied = $ruleName
        preference   = $prefer

        considered   = @($reachable | ForEach-Object {
                [pscustomobject]@{
                    family    = $_.family
                    limit     = $_.limit
                    used      = $_.used
                    unused  = $_.unused
                    allocatable = $_.allocatable
                    outcome   = if ($_.family -eq $chosen) { 'chosen' }
                    elseif (-not $_.satisfied_with_allocation) { "short by $($vcpus - ($_.unused + $_.allocatable)) vCPUs" }
                    else { 'eligible, outranked' }
                }
            })

        unknown_families = $unknownFamilies
        writes_required  = $writes
    }
}

Export-ModuleMember -Function Get-ApePlacement, Get-EffectiveZones, Get-Keys
