[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$ApiBaseUrl = 'http://127.0.0.1:8787',
    [ValidateSet('debug', 'release')][string]$Mode = 'debug',
    [ValidateSet('android-arm64', 'android-arm', 'android-x64')]
    [string]$TargetPlatform = 'android-arm64',
    [switch]$SkipChecks,
    [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'
$desktop = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\desktop'
$uri = $null
if (-not [Uri]::TryCreate($ApiBaseUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
    throw 'ApiBaseUrl must be an HTTP(S) backend URL without credentials/query/fragment.'
}
if ($uri.Scheme -eq 'http' -and $uri.Host -notin @('127.0.0.1', 'localhost', '10.0.2.2')) {
    throw 'HTTP is allowed only for loopback/Android emulator development. Use HTTPS for a remote backend.'
}

function Invoke-Flutter {
    param([string[]]$Arguments)
    & $Flutter --suppress-analytics --no-version-check @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed: $($Arguments -join ' ')" }
}

# No global Flutter/Java/Android settings are modified. Reuse the project's
# downloaded Gradle artifacts, but keep all environment overrides command-local.
$oldGradleHome = $env:GRADLE_USER_HOME
if (-not $env:GRADLE_USER_HOME) {
    $env:GRADLE_USER_HOME = Join-Path $desktop 'build\android-tools\gradle'
}
Push-Location -LiteralPath $desktop
try {
    if ($Mode -eq 'release') {
        $keyProperties = Join-Path $desktop 'android\key.properties'
        $environmentReady = $env:ANDROID_KEYSTORE_PATH -and
            $env:ANDROID_KEYSTORE_PASSWORD -and
            $env:ANDROID_KEY_ALIAS -and
            $env:ANDROID_KEY_PASSWORD
        if (-not (Test-Path -LiteralPath $keyProperties -PathType Leaf) -and
            -not $environmentReady) {
            throw 'Release builds require android/key.properties or ANDROID_KEYSTORE_* environment variables.'
        }
    }
    if (-not $SkipPubGet) {
        Invoke-Flutter -Arguments @('pub', 'get')
    }
    if (-not $SkipChecks) {
        Invoke-Flutter -Arguments @('analyze')
        Invoke-Flutter -Arguments @('test')
    }
    $buildArguments = @('build', 'apk', "--$Mode", '--target-platform', $TargetPlatform,
        "--dart-define=API_BASE_URL=$ApiBaseUrl")
    if ($SkipPubGet) {
        $buildArguments += '--no-pub'
    }
    Invoke-Flutter -Arguments $buildArguments
    $apk = Join-Path $desktop "build\app\outputs\flutter-apk\app-$Mode.apk"
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw 'Build returned no APK.' }
    $distribution = Join-Path $desktop 'build\android\distribution'
    New-Item -ItemType Directory -Path $distribution -Force | Out-Null
    $target = Join-Path $distribution "oo-music-$TargetPlatform-$Mode.apk"
    Copy-Item -LiteralPath $apk -Destination $target -Force
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($target))" |
        Set-Content -LiteralPath "$target.sha256" -Encoding ASCII
    @"
oo music Android test build
Mode: $Mode; architecture: $TargetPlatform; backend: $ApiBaseUrl

The Go backend is separate. For USB loopback testing, use the project's
install-android.ps1 -UsbBackend, which forwards only tcp:8787 with adb reverse.
Keep the USB connection and host backend running. This does not copy desktop
accounts; use your own authorization in the Android client.

Release mode requires a stable Android release keystore. Debug builds remain
available for local testing. Never distribute a debug-key APK and never
uninstall or clear app data to work around a signature mismatch.
Background/notification playback, QQ CDN rights, OEM battery management and
download save dialogs still need device testing. Android floating lyrics are
not implemented. See apps/desktop/docs/android.md.
"@ | Set-Content -LiteralPath (Join-Path $distribution 'README-Android.txt') -Encoding UTF8
    Write-Host "Android APK: $target"
    Write-Host "SHA256: $hash"
}
finally {
    Pop-Location
    $env:GRADLE_USER_HOME = $oldGradleHome
}
