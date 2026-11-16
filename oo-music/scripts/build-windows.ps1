[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$ApiBaseUrl,
    [switch]$SkipChecks,
    [switch]$SkipPubGet,
    [switch]$Package
)

$ErrorActionPreference = 'Stop'
$desktop = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\desktop'
$oldPath = $env:PATH
$cacheVariables = @('NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'NUGET_SCRATCH')
$oldCaches = @{}
foreach ($name in $cacheVariables) {
    $oldCaches[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Invoke-Flutter {
    param([string[]]$Arguments)
    & $Flutter --no-version-check @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter command failed: flutter $($Arguments -join ' ')"
    }
}

Push-Location -LiteralPath $desktop
try {
    if (-not $SkipPubGet) {
        Invoke-Flutter -Arguments @('pub', 'get')
    }
    if (-not $SkipChecks) {
        Invoke-Flutter -Arguments @('analyze')
        Invoke-Flutter -Arguments @('test')
    }

    # Reuse verified downloads when present. On a fresh checkout, Flutter and
    # the official plugins download their own dependencies as usual.
    $tools = Join-Path $desktop 'build\windows-tools'
    $cachedNuget = Join-Path $tools 'nuget.exe'
    if (Test-Path -LiteralPath $cachedNuget -PathType Leaf) {
        $expected = 'd5fce5185de92b7356ea9264b997a620e35c6f6c3c061e471e0dc3a84b3d74fd'
        if ((Get-FileHash -LiteralPath $cachedNuget -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
            throw 'Cached NuGet checksum mismatch; do not run this binary.'
        }
        $env:PATH = "$tools;$env:PATH"
    }
    $state = Join-Path $tools 'nuget-state'
    $env:NUGET_PACKAGES = Join-Path $state 'packages'
    $env:NUGET_HTTP_CACHE_PATH = Join-Path $state 'http-cache'
    $env:NUGET_SCRATCH = Join-Path $state 'scratch'

    $arguments = @('build', 'windows', '--release')
    if ($SkipPubGet) {
        $arguments += '--no-pub'
    }
    if ($ApiBaseUrl) {
        $uri = $null
        if (-not [Uri]::TryCreate($ApiBaseUrl, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) {
            throw 'ApiBaseUrl must be an HTTP(S) URL without credentials.'
        }
        $arguments += "--dart-define=API_BASE_URL=$ApiBaseUrl"
    }
    Invoke-Flutter -Arguments $arguments

    $buildRoot = Join-Path $desktop 'build\windows\x64'
    $release = Join-Path $buildRoot 'runner\Release'
    # Respect a temporary candidate output directory used to avoid replacing
    # a still-running app. Never package an old runner/Release by accident.
    $cache = Join-Path $buildRoot 'CMakeCache.txt'
    if (Test-Path -LiteralPath $cache) {
        $configuredOutput = @(Select-String -LiteralPath $cache -Pattern '^CMAKE_RUNTIME_OUTPUT_DIRECTORY:PATH=(.+)$')
        if ($configuredOutput.Count -eq 1) {
            $release = Join-Path $configuredOutput[0].Matches[0].Groups[1].Value 'Release'
        }
    }
    $required = @('oo_music.exe', 'flutter_windows.dll', 'sqlite3.dll',
        'audioplayers_windows_plugin.dll', 'media_kit_video_plugin.dll',
        'media_kit_libs_windows_video_plugin.dll', 'libmpv-2.dll',
        'libEGL.dll', 'libGLESv2.dll', 'msvcp140.dll', 'vcruntime140.dll',
        'vcruntime140_1.dll', 'data\app.so', 'data\icudtl.dat')
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $release $name) -PathType Leaf)) {
            throw "Incomplete Windows bundle: missing $name"
        }
    }
    Write-Host "Windows Release: $release"

    if ($Package) {
        $distribution = Join-Path $desktop 'build\windows\distribution'
        New-Item -ItemType Directory -Path $distribution -Force | Out-Null
        $readme = Join-Path $distribution 'README-Windows.txt'
        @'
oo music - Windows x64 free distribution

If using the setup EXE, run it and follow the wizard. It installs per-user and
does not require administrator privileges. The portable ZIP is also included.
For the ZIP, extract the WHOLE archive and keep DLLs and data/ together.
Use your own authorized QQ Music account. Playback respects service rights.
Windows 10/11 x64; Windows N/KN needs Microsoft's Media Feature Pack.
App-local Release VC runtime DLLs are included; no Visual Studio is needed.

This free build is not code-signed. Windows SmartScreen may show the first time
the setup is downloaded: choose "More info", then "Run anyway". If the file was
downloaded from the internet, you can also open Properties and check "Unblock".
Do not disable SmartScreen globally. Before public redistribution, review all
upstream binary licenses and source obligations.
Third-party package notices: data/flutter_assets/NOTICES.Z
libmpv/FFmpeg source and build information:
https://github.com/media-kit/libmpv-win32-video-build
ANGLE binaries and source information:
https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES
Project Windows guide: apps/desktop/docs/windows.md

This temporary Windows test build DEFAULTS to accessibility compatibility mode,
including when oo_music.exe is double-clicked. Its title shows the version/mode.
Flutter screen-reader/UI automation access is disabled for this run; mouse,
keyboard, songs, MV and desktop lyrics remain available. No OS setting changes.
Start-Compatibility.cmd explicitly selects the same compatibility mode.
Start-Normal.cmd restores Flutter accessibility but may reproduce the known
Flutter native AX-tree crash. Restart is required to change modes.
'@ | Set-Content -LiteralPath $readme -Encoding UTF8
        $launcher = Join-Path $distribution 'Start-Compatibility.cmd'
        @'
@echo off
echo Temporary workaround for the Flutter Windows accessibility crash.
echo This run disables Flutter screen-reader and UI automation access.
echo Mouse and keyboard playback remain available. This is also the default mode.
start "" "%~dp0oo_music.exe" --windows-accessibility-compat
'@ | Set-Content -LiteralPath $launcher -Encoding ASCII
        $normalLauncher = Join-Path $distribution 'Start-Normal.cmd'
        @'
@echo off
echo Restore Flutter screen-reader and UI automation support for this run.
echo WARNING: this mode may reproduce the known Flutter native AX-tree crash.
echo Close other oo music windows before starting to avoid confusing versions.
choice /c YN /n /m "Start in standard mode despite the known crash? [Y/N] "
if errorlevel 2 exit /b 0
start "" "%~dp0oo_music.exe" --windows-accessibility-normal
'@ | Set-Content -LiteralPath $normalLauncher -Encoding ASCII
        # The actual build folder has the same launchers/documentation as the ZIP.
        foreach ($file in @($readme, $launcher, $normalLauncher)) {
            Copy-Item -LiteralPath $file -Destination $release -Force
        }
        # Do not include stale debug zlib, PDBs, import libraries, logs, or caches.
        $files = @(Get-ChildItem -LiteralPath $release -File |
            Where-Object { $_.Name -eq 'oo_music.exe' -or
                ($_.Extension -eq '.dll' -and $_.Name -ne 'zlib.dll') } |
            ForEach-Object { $_.FullName })
        $files += Join-Path $release 'data'
        $files += $readme
        $files += $launcher
        $files += $normalLauncher
        $zip = Join-Path $distribution 'oo-music-windows-x64.zip'
        Compress-Archive -LiteralPath $files -DestinationPath $zip -Force
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  oo-music-windows-x64.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII
        Write-Host "Portable archive: $zip"
        Write-Host "SHA256: $hash"
    }
}
finally {
    $env:PATH = $oldPath
    foreach ($name in $cacheVariables) {
        [Environment]::SetEnvironmentVariable($name, $oldCaches[$name], 'Process')
    }
    Pop-Location
}
