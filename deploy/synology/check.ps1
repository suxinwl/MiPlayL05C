param(
    [string]$NasIp = "192.168.8.3"
)

$ErrorActionPreference = "Stop"

function Test-HttpEndpoint([string]$Name, [string]$Url) {
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
        Write-Host ("[OK] {0} {1}" -f $Name, $response.StatusCode)
        return $true
    } catch {
        Write-Host ("[FAIL] {0} {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

$ok = $true
$ok = (Test-HttpEndpoint "oo-music health" "http://$NasIp`:8787/healthz") -and $ok
$ok = (Test-HttpEndpoint "gateway health" "http://$NasIp`:58092/healthz") -and $ok

if (-not $ok) {
    exit 1
}

Write-Host "基础服务可达。下一步请在 oo-music 管理页绑定 QQ 音乐账号，再执行网关设备和播放地址验收。"
