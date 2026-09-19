<#
    .SYNOPSIS
    Renders the collector diagrams from HTML to PNG.

    .DESCRIPTION
    Same approach as ghcp-credit-visibility-azure: hand-written HTML, rendered
    with headless Chrome. The palette is Fluent, the font is Segoe UI, and the
    icons are Microsoft's own.

    .PARAMETER IconRoot
    Where the Azure architecture icons are unzipped. The SVG files are NOT in
    this repository: they are Microsoft's and are not covered by its MIT
    licence. Download them from
    learn.microsoft.com/azure/architecture/icons and point this at the `Icons`
    folder inside.

    Microsoft permits their use in architecture diagrams and documentation,
    which is what these are.

    .EXAMPLE
    ./render.ps1 -IconRoot 'C:\icons\Azure_Public_Service_Icons\Icons'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IconRoot,
    [string]$ChromePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ChromePath) {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    $ChromePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $ChromePath) { throw 'No Chrome or Edge found. Pass -ChromePath.' }

# The icons each diagram uses. Inlined as data URIs so the rendered PNG is
# self-contained and the HTML can be checked in without the SVG files.
$icons = @{
    quotas      = 'other/02951-icon-service-Azure-Quotas.svg'
    mgroups     = 'general/10011-icon-service-Management-Groups.svg'
    subs        = 'general/10002-icon-service-Subscriptions.svg'
    vm          = 'compute/10021-icon-service-Virtual-Machine.svg'
    roles       = 'identity/10340-icon-service-Entra-Identity-Roles-and-Administrators.svg'
    location    = 'general/10818-icon-service-Location.svg'
    workflow    = 'general/10852-icon-service-Workflow.svg'
}

$dataUris = @{}
foreach ($k in $icons.Keys) {
    $p = Join-Path $IconRoot $icons[$k]
    if (-not (Test-Path $p)) { throw "Icon not found: $p" }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p))
    $dataUris[$k] = "data:image/svg+xml;base64,$b64"
}

Add-Type -AssemblyName System.Drawing

function Resize-ToContent {
    <#
        .SYNOPSIS
        Crops trailing white rows off the bottom of a PNG.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $src = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $w = $src.Width
        $h = $src.Height
        $pad = 64   # keep a margin below the last pixel of content

        $last = 0
        for ($y = $h - 1; $y -ge 0; $y--) {
            $rowHasInk = $false
            # Every 4th column is enough to find a row of text and is four times
            # faster on an image this size.
            for ($x = 0; $x -lt $w; $x += 4) {
                $c = $src.GetPixel($x, $y)
                if ($c.R -lt 250 -or $c.G -lt 250 -or $c.B -lt 250) { $rowHasInk = $true; break }
            }
            if ($rowHasInk) { $last = $y; break }
        }

        $newH = [Math]::Min($h, $last + $pad)
        if ($newH -ge $h) { return 'no crop needed' }

        $dst = New-Object System.Drawing.Bitmap($w, $newH)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.DrawImage($src, 0, 0, (New-Object System.Drawing.Rectangle(0, 0, $w, $newH)),
            [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
        $src.Dispose()
        $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $dst.Dispose()
        return "cropped ${h}px -> ${newH}px"
    }
    finally {
        if ($src) { try { $src.Dispose() } catch { } }
    }
}

foreach ($html in Get-ChildItem $PSScriptRoot -Filter '*.html') {
    $text = Get-Content $html.FullName -Raw
    foreach ($k in $dataUris.Keys) {
        $text = $text.Replace("{{icon:$k}}", $dataUris[$k])
    }
    if ($text -match '\{\{icon:([a-z]+)\}\}') {
        throw "Unresolved icon placeholder '$($Matches[1])' in $($html.Name)."
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqv-" + $html.Name)
    $text | Set-Content -Path $tmp -Encoding utf8

    $png = Join-Path (Split-Path $PSScriptRoot -Parent) ($html.BaseName + '.png')
    $size = if ($html.BaseName -eq 'collector-flow') { '1180,1500' } else { '1180,1200' }

    # Every flag is built as one string first. PowerShell splits an unquoted
    # --window-size=1180,1500 on the comma and passes two arguments, which
    # Chrome ignores, and the screenshot silently never appears.
    $chromeArgs = @(
        '--headless'
        '--disable-gpu'
        '--hide-scrollbars'
        '--force-device-scale-factor=2'
        "--window-size=$size"
        "--screenshot=$png"
        ('file:///' + ($tmp -replace '\\', '/'))
    )
    & $ChromePath @chromeArgs 2>$null | Out-Null

    if (Test-Path $png) {
        # The window height is a guess, so the shot always has white space under
        # the content. Crop to the last row that is not pure white, rather than
        # leaving it for someone to do by hand and forget.
        $trimmed = Resize-ToContent -Path $png
        Write-Host ("  {0,-34} {1:N0} KB   {2}" -f ($html.BaseName + '.png'),
            ((Get-Item $png).Length / 1KB), $trimmed) -ForegroundColor Green
    }
    else {
        Write-Host ("  {0} FAILED" -f $html.Name) -ForegroundColor Red
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

