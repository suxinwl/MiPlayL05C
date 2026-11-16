[CmdletBinding()]
param(
    [string]$Adb,
    [string]$DeviceId,
    [string]$Apk,
    [switch]$UsbBackend
)

$ErrorActionPreference = 'Stop'
$desktop = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\desktop'
if (-not $Adb) {
    $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
        elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
        else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
    $Adb = Join-Path $sdk 'platform-tools\adb.exe'
}
if (-not (Test-Path -LiteralPath $Adb -PathType Leaf)) { throw 'ADB not found; supply -Adb with its full path.' }
if (-not $Apk) {
    $Apk = Join-Path $desktop 'build\android\distribution\oo-music-android-arm64-debug.apk'
}
$Apk = (Resolve-Path -LiteralPath $Apk).Path
if (-not (Test-Path -LiteralPath "$Apk.sha256")) {
    throw 'No SHA256 sidecar. Build with build-android.ps1 first.'
}
$expected = ((Get-Content -LiteralPath "$Apk.sha256" -Raw).Trim() -split '\s+')[0]
if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or
    (Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash -ne $expected) {
    throw 'APK checksum mismatch; refusing to install.'
}

function Invoke-Adb {
    param([string[]]$Arguments)
    & $Adb @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ADB failed: $($Arguments -join ' ')" }
}

$listed = @(& $Adb devices)
if ($LASTEXITCODE -ne 0) { throw 'Could not list Android devices.' }
$devices = @($listed | ForEach-Object {
    if ($_ -match '^([^\s]+)\s+device(?:\s|$)') { $Matches[1] }
})
if ($DeviceId) {
    if ($DeviceId -notin $devices) { throw 'Selected device is not connected/authorized. Confirm on the phone yourself.' }
} elseif ($devices.Count -eq 1) {
    $DeviceId = $devices[0]
} else {
    throw 'Connect exactly one authorized phone or supply -DeviceId. No device is selected automatically from multiple phones.'
}

if ($UsbBackend) {
    try {
        $health = Invoke-WebRequest -Uri 'http://127.0.0.1:8787/healthz' -TimeoutSec 5 -UseBasicParsing
        if ($health.StatusCode -ne 200) { throw 'Unexpected health status.' }
    } catch { throw 'Host backend is not available at http://127.0.0.1:8787/healthz. Start your existing backend first.' }
    Invoke-Adb -Arguments @('-s', $DeviceId, 'reverse', 'tcp:8787', 'tcp:8787')
}

# Replace only this application while preserving its data. Never uninstall,
# clear storage, grant permissions, disable verifiers or bypass device prompts.
Invoke-Adb -Arguments @('-s', $DeviceId, 'install', '-r', $Apk)
Invoke-Adb -Arguments @('-s', $DeviceId, 'shell', 'am', 'start', '-n',
    'com.yskj0864.oo_music/.MainActivity')
Write-Host 'oo music launched. Complete any phone install/authentication prompts manually.'
if ($UsbBackend) { Write-Host 'USB backend forwarding is active for tcp:8787; keep the cable and backend running.' }
