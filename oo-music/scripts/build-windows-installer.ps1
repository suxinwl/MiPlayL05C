[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [Parameter(Mandatory = $true)][string]$ApiBaseUrl,
    [string]$InnoCompiler,
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$desktop = Join-Path $root 'apps\desktop'

& (Join-Path $PSScriptRoot 'build-windows.ps1') `
    -Flutter $Flutter `
    -ApiBaseUrl $ApiBaseUrl `
    -SkipChecks:$SkipChecks `
    -Package

$versionLine = Select-String -LiteralPath (Join-Path $desktop 'pubspec.yaml') `
    -Pattern '^version:\s*([^+]+)\+([0-9]+)\s*$'
if ($null -eq $versionLine) { throw 'Unable to read version from pubspec.yaml.' }
$appVersion = $versionLine.Matches[0].Groups[1].Value.Trim()
$appBuild = $versionLine.Matches[0].Groups[2].Value.Trim()

if (-not $InnoCompiler) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) {
        $InnoCompiler = $command.Source
    } else {
        $candidates = @(
            Get-ChildItem -Path "${env:ProgramFiles(x86)}\Inno Setup *\ISCC.exe" -ErrorAction SilentlyContinue
            Get-ChildItem -Path "$env:ProgramFiles\Inno Setup *\ISCC.exe" -ErrorAction SilentlyContinue
        ) | Sort-Object FullName -Descending
        if ($candidates.Count -gt 0) { $InnoCompiler = $candidates[0].FullName }
    }
}
if (-not $InnoCompiler -or -not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
    throw 'Inno Setup ISCC.exe not found. Install Inno Setup or pass -InnoCompiler.'
}

$release = Join-Path $desktop 'build\windows\x64\runner\Release'
$distribution = Join-Path $desktop 'build\windows\distribution'
$installerScript = Join-Path $desktop 'windows\installer\oo-music.iss'
$setupIcon = Join-Path $desktop 'windows\runner\resources\app_icon.ico'
foreach ($required in @(
    (Join-Path $release 'oo_music.exe'),
    (Join-Path $release 'flutter_windows.dll'),
    (Join-Path $release 'data\app.so')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Incomplete Windows release: missing $required"
    }
}

New-Item -ItemType Directory -Path $distribution -Force | Out-Null
& $InnoCompiler `
    "/DAppVersion=$appVersion" `
    "/DAppBuild=$appBuild" `
    "/DReleaseDir=$release" `
    "/DOutputDir=$distribution" `
    "/DSetupIcon=$setupIcon" `
    $installerScript
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }

$installer = Join-Path $distribution "oo-music-$appVersion-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Installer was not created: $installer"
}
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($installer))" |
    Set-Content -LiteralPath "$installer.sha256" -Encoding ASCII

Write-Host "Windows installer: $installer"
Write-Host "SHA256: $hash"
Write-Host 'This no-certificate build may trigger Windows SmartScreen on first download.'
