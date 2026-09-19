<#
    Shared helpers for the quota group collector.

    Everything the collector sends to Azure goes through Invoke-AqvApi, so every
    request and response lands in a capture file without the caller having to
    remember. A finding that cannot be traced to a capture does not go in the
    findings file.

    Authentication comes from `az login`. No credential is read, stored or
    written by anything here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Arm = 'https://management.azure.com'
$script:Captures = [System.Collections.Generic.List[object]]::new()

# StrictMode throws on an unset variable rather than returning null, so the
# token cache has to exist before the first read of it.
$script:Token = $null
$script:TokenExpires = [datetime]::MinValue

function Get-AqvProp {
    <#
        .SYNOPSIS
        Reads a nested property, returning $null when any level is absent.

        .DESCRIPTION
        StrictMode throws on a missing property rather than returning null, and
        the whole point of this collector is that we do not know which
        properties a response carries. A missing field is a finding, not a
        crash.

        .EXAMPLE
        Get-AqvProp $response 'properties' 'limit' 'value'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()]$Object,
        [Parameter(Mandatory, Position = 1, ValueFromRemainingArguments)][string[]]$Path
    )
    $cur = $Object
    foreach ($name in $Path) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($name)) { return $null }
            $cur = $cur[$name]
            continue
        }
        if (-not $cur.PSObject.Properties[$name]) { return $null }
        $cur = $cur.$name
    }
    return $cur
}

function Get-AqvOutputDir {
    <#
        .SYNOPSIS
        The output directory, created if it is not there.
    #>
    [CmdletBinding()]
    param()
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'output'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $cap = Join-Path $dir 'captures'
    if (-not (Test-Path $cap)) { New-Item -ItemType Directory -Path $cap | Out-Null }
    return $dir
}

function Get-AqvToken {
    <#
        .SYNOPSIS
        An ARM access token from the current az login.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:Token -or (Get-Date) -gt $script:TokenExpires) {
        $raw = az account get-access-token --resource $script:Arm -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "az account get-access-token failed. Run 'az login --tenant <tenant-id>' first.`n$raw"
        }
        $t = $raw | ConvertFrom-Json
        $script:Token = $t.accessToken
        # Refresh a couple of minutes early rather than mid-poll.
        $script:TokenExpires = (Get-Date).AddMinutes(45)
    }
    return $script:Token
}

function Invoke-AqvApi {
    <#
        .SYNOPSIS
        One ARM call, captured.

        .DESCRIPTION
        Returns an object carrying the status code, headers, parsed body and
        elapsed milliseconds. A non-2xx response is NOT thrown: a refusal is
        evidence, and this collector exists to record refusals accurately.

        .PARAMETER Path
        The ARM path, starting with a slash. No host, no api-version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'PATCH', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApiVersion,
        [object]$Body,
        # Why this call is being made. Goes into the capture so the package
        # reads as a narrative rather than as a log.
        [string]$Purpose = ''
    )

    $sep = if ($Path.Contains('?')) { '&' } else { '?' }
    $uri = "{0}{1}{2}api-version={3}" -f $script:Arm, $Path, $sep, $ApiVersion

    $headers = @{
        Authorization  = "Bearer $(Get-AqvToken)"
        'Content-Type' = 'application/json'
    }

    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 12 } else { $null }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = $null
    $respHeaders = @{}
    $respBody = $null
    $raw = $null

    try {
        $params = @{
            Method                  = $Method
            Uri                     = $uri
            Headers                 = $headers
            SkipHttpErrorCheck      = $true
            MaximumRedirection      = 0
            ErrorAction             = 'Stop'
        }
        if ($json) { $params.Body = $json }

        $resp = Invoke-WebRequest @params
        $status = [int]$resp.StatusCode
        $raw = $resp.Content
        foreach ($k in $resp.Headers.Keys) { $respHeaders[$k] = ($resp.Headers[$k] -join ', ') }
    }
    catch {
        # A transport failure, not an HTTP error. SkipHttpErrorCheck handles the
        # latter, so anything here is DNS, TLS or a cancelled request.
        $status = -1
        $raw = $_.Exception.Message
    }
    $sw.Stop()

    if ($raw) {
        try { $respBody = $raw | ConvertFrom-Json } catch { $respBody = $raw }
    }

    $record = [ordered]@{
        purpose     = $Purpose
        method      = $Method
        path        = $Path
        api_version = $ApiVersion
        request     = if ($null -ne $Body) { $Body } else { $null }
        status      = $status
        # Only the headers that carry meaning for a long-running operation. The
        # rest is noise and some of it is a token hint.
        headers     = @{
            'location'       = $respHeaders['Location']
            'azure-asyncoperation' = $respHeaders['Azure-AsyncOperation']
            'retry-after'    = $respHeaders['Retry-After']
            'x-ms-request-id' = $respHeaders['x-ms-request-id']
        }
        response    = $respBody
        duration_ms = [int]$sw.ElapsedMilliseconds
        at          = (Get-Date).ToUniversalTime().ToString('o')
    }
    $script:Captures.Add($record)

    return [pscustomobject]@{
        Status     = $status
        Ok         = ($status -ge 200 -and $status -lt 300)
        Headers    = $respHeaders
        Body       = $respBody
        DurationMs = [int]$sw.ElapsedMilliseconds
        Raw        = $raw
    }
}

function Wait-AqvOperation {
    <#
        .SYNOPSIS
        Polls a long-running quota operation to a terminal state.

        .DESCRIPTION
        Records every poll, so the findings can report the real state sequence
        and the real elapsed time rather than an estimate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApiVersion,
        [int]$TimeoutSeconds = 900,
        [int]$IntervalSeconds = 15,
        [string]$Purpose = 'poll'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $states = [System.Collections.Generic.List[string]]::new()
    $terminal = @('Succeeded', 'Failed', 'Canceled', 'Cancelled')

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $r = Invoke-AqvApi -Method GET -Path $Path -ApiVersion $ApiVersion -Purpose $Purpose

        $state = $null
        if ($r.Body) {
            foreach ($candidate in @('provisioningState', 'status')) {
                if ($r.Body.PSObject.Properties[$candidate]) { $state = $r.Body.$candidate; break }
                if ($r.Body.PSObject.Properties['properties'] -and
                    $r.Body.properties.PSObject.Properties[$candidate]) {
                    $state = $r.Body.properties.$candidate; break
                }
            }
        }

        if ($state) { $states.Add($state) }

        if ($state -in $terminal) {
            $sw.Stop()
            return [pscustomobject]@{
                State      = $state
                Succeeded  = ($state -eq 'Succeeded')
                States     = @($states)
                DurationMs = [int]$sw.ElapsedMilliseconds
                Body       = $r.Body
                TimedOut   = $false
            }
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    $sw.Stop()
    return [pscustomobject]@{
        State      = 'TIMEOUT'
        Succeeded  = $false
        States     = @($states)
        DurationMs = [int]$sw.ElapsedMilliseconds
        Body       = $null
        TimedOut   = $true
    }
}

function Invoke-AqvAllocation {
    <#
        .SYNOPSIS
        One quota allocation PATCH, polled to a terminal state.

        .DESCRIPTION
        Moving quota INTO the group and OUT to a subscription are documented as
        the same call with a different number, so steps 4, 5 and 6 all come
        through here. Whether that is true is question E3, and this is what
        proves it either way.

        `Limit` is sent as the subscription's new ABSOLUTE limit, which is what
        Microsoft.Quota means by limit elsewhere. Question D2 is whether the
        group API agrees.

        UNTESTED against a live group. The path and body come from Microsoft's
        documentation and from the shape the read APIs return.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManagementGroupId,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][int]$Limit,
        [string]$ApiVersion = '2025-09-01',
        [string]$Purpose = 'allocation',
        [int]$TimeoutSeconds = 900
    )

    $path = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId" +
            "/subscriptions/$SubscriptionId/providers/Microsoft.Quota/groupQuotas/$GroupName" +
            "/resourceProviders/Microsoft.Compute/quotaAllocations/$Region"

    $body = @{
        properties = @{
            value = @(
                @{
                    properties = @{
                        resourceName = $Family
                        limit        = $Limit
                    }
                }
            )
        }
    }

    $r = Invoke-AqvApi -Method PATCH -Path $path -ApiVersion $ApiVersion -Body $body -Purpose $Purpose

    $result = [ordered]@{
        request      = $body
        status       = $r.Status
        response     = $r.Body
        headers      = $r.Headers
        submit_ms    = $r.DurationMs
        poll_states  = @()
        poll_ms      = 0
        final_state  = $null
        succeeded    = $r.Ok
    }

    # 202 means accepted for processing, not granted. The per-subscription quota
    # path has already produced a 202 that later failed, and a 412 on the poll
    # for a write that Azure recorded as succeeded, so the poll is the answer
    # and the submit is not.
    if ($r.Status -eq 202) {
        $pollPath = $null
        foreach ($h in @('Azure-AsyncOperation', 'Location')) {
            if ($r.Headers[$h]) {
                # Strip the host and the api-version; Invoke-AqvApi adds both.
                $pollPath = ($r.Headers[$h] -replace '^https://management\.azure\.com', '') -replace '[?&]api-version=[^&]*', ''
                break
            }
        }
        if ($pollPath) {
            $w = Wait-AqvOperation -Path $pollPath -ApiVersion $ApiVersion `
                -TimeoutSeconds $TimeoutSeconds -Purpose "$Purpose (poll)"
            $result.poll_states = $w.States
            $result.poll_ms = $w.DurationMs
            $result.final_state = $w.State
            $result.succeeded = $w.Succeeded
        }
        else {
            # No poll header. Record it rather than guessing an endpoint.
            $result.final_state = 'NO_POLL_HEADER'
            $result.succeeded = $false
        }
    }

    return [pscustomobject]$result
}

function Get-AqvFamilyLimit {
    <#
        .SYNOPSIS
        One family's limit and usage from Microsoft.Compute, which is the API
        AQV actually reads.

        .DESCRIPTION
        Matched case insensitively on purpose. The group APIs lower-case every
        name while Microsoft.Compute uses camel case, and 231 of 232 names
        differ by case alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Family,
        [string]$Purpose = 'read a family limit'
    )
    $r = Invoke-AqvApi -Method GET `
        -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Region/usages" `
        -ApiVersion '2024-07-01' -Purpose $Purpose

    foreach ($v in @(Get-AqvProp $r.Body 'value')) {
        $n = Get-AqvProp $v 'name' 'value'
        if ($n -and $n.ToLowerInvariant() -eq $Family.ToLowerInvariant()) {
            return [pscustomobject]@{
                Name    = $n
                Limit   = Get-AqvProp $v 'limit'
                Used    = Get-AqvProp $v 'currentValue'
                Found   = $true
            }
        }
    }
    return [pscustomobject]@{ Name = $Family; Limit = $null; Used = $null; Found = $false }
}

function Save-AqvCapture {
    <#
        .SYNOPSIS
        Writes everything captured so far to output/captures/<Name>.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Summary = @{}
    )
    $dir = Get-AqvOutputDir
    $file = Join-Path $dir 'captures' "$Name.json"

    $doc = [ordered]@{
        step     = $Name
        captured = (Get-Date).ToUniversalTime().ToString('o')
        summary  = $Summary
        calls    = @($script:Captures)
    }
    $doc | ConvertTo-Json -Depth 20 | Set-Content -Path $file -Encoding utf8
    $script:Captures.Clear()

    Write-Host ''
    Write-Host ("  Capture written: {0}" -f $file) -ForegroundColor Green
    return $file
}

function Write-AqvStep {
    <#
        .SYNOPSIS
        The step banner, so the transcript shows what ran.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Title, [switch]$Writes)
    Write-Host ''
    Write-Host ("  STEP {0} - {1}" -f $Number, $Title.ToUpper()) -ForegroundColor Cyan
    if ($Writes) {
        Write-Host '  This step WRITES to Azure.' -ForegroundColor Yellow
    }
    else {
        Write-Host '  This step writes nothing.' -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Assert-AqvBaseline {
    <#
        .SYNOPSIS
        Refuses to run a write step before step 0 recorded a baseline.

        .DESCRIPTION
        The baseline is what makes a write reversible and provable. Without it,
        drift afterwards cannot be told apart from what was already there.
    #>
    [CmdletBinding()]
    param()
    $f = Join-Path (Get-AqvOutputDir) 'captures' '00-preflight.json'
    if (-not (Test-Path $f)) {
        throw 'No baseline. Run step 0 first: it records both subscriptions'' quota before anything is touched.'
    }
    return $f
}

Export-ModuleMember -Function Get-AqvOutputDir, Get-AqvProp, Get-AqvToken, Invoke-AqvApi,
Wait-AqvOperation, Save-AqvCapture, Write-AqvStep, Assert-AqvBaseline,
Invoke-AqvAllocation, Get-AqvFamilyLimit
