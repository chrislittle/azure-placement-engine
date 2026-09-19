<#
    .SYNOPSIS
    Renders every diagram in this repository from HTML to PNG.

    .DESCRIPTION
    Same approach as ghcp-credit-visibility-azure: hand-written HTML rendered
    with headless Chrome. The palette is Fluent, the font is Segoe UI, the
    shared styling is in _style.css, and the icons are Microsoft's own.

    Each diagram writes {{style}} where the stylesheet goes and {{icon:name}}
    where an icon goes. Both are substituted at render time, so the PNG is
    self-contained and the HTML can be committed without the SVG files.

    It renders `docs/images/src` and `collector/docs/images/src` by default.

    .PARAMETER IconRoot
    Where the Azure architecture icons are unzipped. The SVG files are NOT in
    this repository: they are Microsoft's and are not covered by its MIT
    licence. Download them from learn.microsoft.com/azure/architecture/icons
    and point this at the `Icons` folder inside.

    Microsoft permits their use in architecture diagrams and documentation,
    which is what these are.

    .PARAMETER SourceDir
    Render only this folder. Defaults to every diagram folder in the repository.

    .EXAMPLE
    ./render.ps1 -IconRoot 'C:\icons\Azure_Public_Service_Icons\Icons'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IconRoot,
    [string[]]$SourceDir,
    [string]$ChromePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

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

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
if (-not $SourceDir) {
    $SourceDir = @(
        $PSScriptRoot
        Join-Path $repo 'collector' 'docs' 'images' 'src'
    ) | Where-Object { Test-Path $_ }
}

# Every icon any diagram uses. Adding one here and referencing {{icon:name}} is
# all a new diagram needs.
$icons = @{
    quotas    = 'other/02951-icon-service-Azure-Quotas.svg'
    mgroups   = 'general/10011-icon-service-Management-Groups.svg'
    subs      = 'general/10002-icon-service-Subscriptions.svg'
    vm        = 'compute/10021-icon-service-Virtual-Machine.svg'
    vmss      = 'compute/10034-icon-service-VM-Scale-Sets.svg'
    roles     = 'identity/10340-icon-service-Entra-Identity-Roles-and-Administrators.svg'
    location  = 'general/10818-icon-service-Location.svg'
    workflow  = 'general/10852-icon-service-Workflow.svg'
    templates = 'general/10009-icon-service-Templates.svg'
    guide     = 'general/10810-icon-service-Guide.svg'
    code      = 'general/10787-icon-service-Code.svg'
    toolbox   = 'general/10844-icon-service-Toolbox.svg'
    policy    = 'management + governance/10316-icon-service-Policy.svg'
    identity  = 'identity/10227-icon-service-Managed-Identities.svg'
    preview   = 'general/00456-icon-service-Preview-Features.svg'
}

$dataUris = @{}
foreach ($k in $icons.Keys) {
    $p = Join-Path $IconRoot $icons[$k]
    if (-not (Test-Path $p)) { throw "Icon not found: $p" }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p))
    $dataUris[$k] = "data:image/svg+xml;base64,$b64"
}

$style = Get-Content (Join-Path $PSScriptRoot '_style.css') -Raw

function Resize-ToContent {
    <#
        .SYNOPSIS
        Crops trailing white rows off the bottom of a PNG.

        .DESCRIPTION
        The window height is a guess, so every shot has white space under the
        content. Cropping here beats leaving it for someone to do by hand and
        forget.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $src = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        $w = $src.Width
        $h = $src.Height
        $pad = 64

        $last = 0
        for ($y = $h - 1; $y -ge 0; $y--) {
            $rowHasInk = $false
            # Every 4th column is enough to find a row of text, and is four
            # times faster on an image this size.
            for ($x = 0; $x -lt $w; $x += 4) {
                $c = $src.GetPixel($x, $y)
                if ($c.R -lt 250 -or $c.G -lt 250 -or $c.B -lt 250) { $rowHasInk = $true; break }
            }
            if ($rowHasInk) { $last = $y; break }
        }

        $newH = [Math]::Min($h, $last + $pad)
        if ($newH -ge $h) { return 'full height' }

        $dst = New-Object System.Drawing.Bitmap($w, $newH)
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.DrawImage($src, 0, 0, (New-Object System.Drawing.Rectangle(0, 0, $w, $newH)),
            [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
        $src.Dispose()
        $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $dst.Dispose()
        return "cropped to ${newH}px"
    }
    finally {
        if ($src) { try { $src.Dispose() } catch { } }
    }
}

foreach ($dir in $SourceDir) {
    $outDir = Split-Path $dir -Parent
    Write-Host ''
    Write-Host ("  {0}" -f $outDir.Replace($repo, '').TrimStart('\')) -ForegroundColor Cyan

    foreach ($html in Get-ChildItem $dir -Filter '*.html') {
        $text = Get-Content $html.FullName -Raw
        $text = $text.Replace('{{style}}', $style)
        foreach ($k in $dataUris.Keys) {
            $text = $text.Replace("{{icon:$k}}", $dataUris[$k])
        }
        if ($text -match '\{\{icon:([a-z]+)\}\}') {
            throw "Unresolved icon placeholder '$($Matches[1])' in $($html.Name). Add it to `$icons in render.ps1."
        }
        if ($text -match '\{\{style\}\}') {
            throw "Unresolved {{style}} in $($html.Name)."
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqv-" + $html.Name)
        $text | Set-Content -Path $tmp -Encoding utf8

        $png = Join-Path $outDir ($html.BaseName + '.png')

        # Generous, because the crop takes the slack back off. Too short is the
        # failure that costs a re-render; too tall costs nothing.
        $chromeArgs = @(
            '--headless'
            '--disable-gpu'
            '--hide-scrollbars'
            '--force-device-scale-factor=2'
            '--window-size=1180,2600'
            "--screenshot=$png"
            ('file:///' + ($tmp -replace '\\', '/'))
        )
        & $ChromePath @chromeArgs 2>$null | Out-Null

        if (Test-Path $png) {
            $trimmed = Resize-ToContent -Path $png
            Write-Host ("    {0,-34} {1,6:N0} KB   {2}" -f ($html.BaseName + '.png'),
                ((Get-Item $png).Length / 1KB), $trimmed) -ForegroundColor Green
        }
        else {
            Write-Host ("    {0} FAILED" -f $html.Name) -ForegroundColor Red
        }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host ''
