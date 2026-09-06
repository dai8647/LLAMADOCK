# update-sdcpp.ps1 - stable-diffusion.cpp を本家 upstream から最新版に更新
# 使い方:
#   powershell -ExecutionPolicy Bypass -File tools\update-sdcpp.ps1           (最新版チェック → 差分あれば更新)
#   powershell -ExecutionPolicy Bypass -File tools\update-sdcpp.ps1 -Force    (最新版に強制更新)
#   powershell -ExecutionPolicy Bypass -File tools\update-sdcpp.ps1 -Check   (チェックのみ、DL しない)
#   powershell -ExecutionPolicy Bypass -File tools\update-sdcpp.ps1 -Backend rocm    (ROCm/HipBLAS 版を使う)
#
# デフォルトは Vulkan。RX 7800 XT (gfx1101) + Win11 24H2 環境では ROCm 7.14.0 ビルドが
# api-ms-win-core-delayload-l1-1-1.dll 欠損で起動しない (2026-09-04 確認)。Vulkan 版は動作する。
# ROCm 版は将来 Win11 が l-1-1 を提供するか、ROCm 公式パッケージングで解決したら切替可。
#
# 配置構造:
#   tools/sd.cpp/sd-cli.exe, sd-server.exe, stable-diffusion.dll    (現行)
#   tools/sd.cpp/VERSION                                            (現バージョンタグ)
#   tools/sd.cpp/old/YYYYMMDD-HHMMSS/                              (アプデ前退避)
#
# 動作:
#   1. GitHub Releases API で latest tag を取得
#   2. tools/sd.cpp/VERSION と比較 → 同じなら何もしない
#   3. 差分あれば win-{backend}-{VERSION}.zip を DL
#   4. 現行を tools/sd.cpp/old/{timestamp}/ に mv
#   5. 新しいバイナリを展開 → VERSION を更新

param(
    [switch]$Force,        # バージョン同じでも強制更新
    [switch]$Check,        # チェックのみ
    [ValidateSet("vulkan", "rocm", "cpu")]
    [string]$Backend = "vulkan"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdDir = Join-Path $here "sd.cpp"
$versionFile = Join-Path $sdDir "VERSION"
$oldDir = Join-Path $sdDir "old"

# Asset は Backend で決まるパターンで release assets から実名検索する
# (asset 名のハッシュ部分が tag と異なる形式のためテンプレート組立は不可:
#  tag=master-841-6b3edaa / asset=sd-master-6b3edaa-bin-win-vulkan-x64.zip)
$assetPattern = switch ($Backend) {
    "rocm"   { "bin-win-rocm-7.14.0-x64.zip" }
    "vulkan" { "bin-win-vulkan-x64.zip" }
    default  { throw "unknown backend: $Backend" }
}

function Get-LatestRelease {
    $api = "https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest"
    return Invoke-RestMethod -Uri $api -TimeoutSec 15
}

function Get-CurrentVersion {
    if (Test-Path -LiteralPath $versionFile) {
        return (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }
    return ""
}

# 1. 現バージョンと latest を取得
Write-Host "[update-sdcpp] Checking latest release..." -ForegroundColor Cyan
try {
    $release = Get-LatestRelease
}
catch {
    Write-Host "ERROR: failed to query GitHub: $_" -ForegroundColor Red
    exit 1
}
$latest = $release.tag_name
$current = Get-CurrentVersion
Write-Host "  current: '$current'"
Write-Host "  latest:  '$latest'"
Write-Host "  backend: $Backend"

if ($latest -eq $current -and -not $Force) {
    Write-Host "[update-sdcpp] Already up to date." -ForegroundColor Green
    exit 0
}

if ($Check) {
    Write-Host "[update-sdcpp] Update available (current=$current, latest=$latest). Re-run without -Check to apply." -ForegroundColor Yellow
    exit 0
}

# 2. DL — assets から Backend パターン一致の実名を探す
$assetObj = $release.assets | Where-Object name -like "*$assetPattern" | Select-Object -First 1
if (-not $assetObj) {
    Write-Host "ERROR: asset matching '*$assetPattern' not found in release $latest" -ForegroundColor Red
    exit 1
}
$asset = $assetObj.name
$url = $assetObj.browser_download_url
$zipPath = Join-Path $env:TEMP $asset
Write-Host "[update-sdcpp] Downloading $url ..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 600
}
catch {
    Write-Host "ERROR: download failed: $_" -ForegroundColor Red
    exit 1
}

# 3. 旧版を退避
if (-not (Test-Path -LiteralPath $oldDir)) { New-Item -ItemType Directory -Path $oldDir -Force | Out-Null }
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $oldDir $ts
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach ($f in "sd-cli.exe", "sd-server.exe", "stable-diffusion.dll") {
    $src = Join-Path $sdDir $f
    if (Test-Path -LiteralPath $src) {
        Move-Item -LiteralPath $src -Destination $backup -Force
    }
}

# 4. 展開
Write-Host "[update-sdcpp] Extracting to $sdDir ..." -ForegroundColor Cyan
Expand-Archive -LiteralPath $zipPath -DestinationPath $sdDir -Force
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

# 5. VERSION 更新
Set-Content -LiteralPath $versionFile -Value $latest -NoNewline
Write-Host "[update-sdcpp] Updated to $latest. Backup at $backup" -ForegroundColor Green

# 6. 動作確認 (--version)
Write-Host "[update-sdcpp] Verifying sd-cli.exe --version ..." -ForegroundColor Cyan
$env:PATH = "$sdDir;$env:PATH"
try {
    $ver = & (Join-Path $sdDir "sd-cli.exe") --version 2>&1
    Write-Host "  $ver" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: --version failed: $_" -ForegroundColor Yellow
}
