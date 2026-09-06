# update-all.ps1 - ComfyUI スタック一括アップデート
#
# 使い方:
#   powershell -ExecutionPolicy Bypass -File tools\update-all.ps1           (全更新)
#   powershell -ExecutionPolicy Bypass -File tools\update-all.ps1 -Check    (更新確認のみ、何もしない)
#   powershell -ExecutionPolicy Bypass -File tools\update-all.ps1 -SkipPip  (pip 依存更新を省略)
#
# 対象:
#   1. ComfyUI 本体            git pull (master)
#   2. custom_nodes (git 管理)  git pull — ComfyUI-GGUF / Spectrum-MiniMax-H3 / ClipProj
#      (ComfyUI-LlamaDock はローカル手作りノードなので対象外)
#   3. pip 依存                 .venv の requirements.txt 再インストール (差分のみ)
#   4. sd.cpp                   update-sdcpp.ps1 を呼び出し (GitHub Releases)
#
# 注意:
#   - ComfyUI が稼働中だと更新ファイルがロックされる事がある。実行前に ComfyUI を
#     落としておくのが安全 (h3-chat UI のシャットダウン、またはタスクマネージャ)。
#   - llama-server (企画 LLM) は ComfyUI 更新と無関係なのでそのままで OK。

param(
    [switch]$Check,    # 更新の有無を確認するだけ (何も変更しない)
    [switch]$SkipPip   # pip 依存の更新をスキップ
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComfyRoot = "C:\Users\dai86\Documents\ComfyUI"

$script:updated = @()
$script:uptodate = @()
$script:failed = @()

function Update-GitRepo {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) {
        Write-Host "  [$Name] git repo ではないためスキップ" -ForegroundColor DarkGray
        return
    }
    if ($Check) {
        # fetch して差分だけ見る
        $null = & git -C $Path fetch origin --quiet 2>&1
        $local = & git -C $Path rev-parse HEAD 2>$null
        $remote = & git -C $Path rev-parse "@{u}" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $remote) {
            Write-Host "  [$Name] upstream 不明 (スキップ)" -ForegroundColor DarkGray
            return
        }
        if ($local -ne $remote) {
            $behind = (& git -C $Path rev-list --count "$local..$remote" 2>$null)
            Write-Host "  [$Name] 更新あり ($behind commit)" -ForegroundColor Yellow
        } else {
            Write-Host "  [$Name] 最新" -ForegroundColor Green
        }
        return
    }
    $before = & git -C $Path rev-parse HEAD 2>$null
    & git -C $Path pull --ff-only --quiet 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [$Name] git pull 失敗 (ローカル変更? 手動確認推奨)" -ForegroundColor Red
        $script:failed += $Name
        return
    }
    $after = & git -C $Path rev-parse HEAD 2>$null
    if ($before -ne $after) {
        Write-Host "  [$Name] 更新: $after" -ForegroundColor Green
        $script:updated += $Name
    } else {
        Write-Host "  [$Name] 最新" -ForegroundColor Green
        $script:uptodate += $Name
    }
}

function Test-ComfyRunning {
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return $true
    } catch { return $false }
}

Write-Host "=== LlamaDock stack update ===" -ForegroundColor Cyan
if ($Check) { Write-Host "(check mode: 何も変更しません)" -ForegroundColor Yellow }

$comfyRunning = Test-ComfyRunning
if ($comfyRunning -and -not $Check) {
    Write-Host "WARNING: ComfyUI が稼働中 (port 8188)。ファイルロックで更新が失敗する事があります。" -ForegroundColor Yellow
    Write-Host "  続行しますが、失敗したら ComfyUI を止めて再実行してください。" -ForegroundColor Yellow
}

# 1. ComfyUI 本体
Write-Host "[1/4] ComfyUI 本体" -ForegroundColor Cyan
Update-GitRepo -Path $ComfyRoot -Name "ComfyUI"

# 2. custom_nodes (git 管理のみ)
Write-Host "[2/4] custom_nodes" -ForegroundColor Cyan
$nodes = Get-ChildItem -Path (Join-Path $ComfyRoot "custom_nodes") -Directory -ErrorAction SilentlyContinue
foreach ($n in $nodes) {
    if ($n.Name -eq "ComfyUI-LlamaDock") { continue }   # ローカル手作り
    Update-GitRepo -Path $n.FullName -Name $n.Name
}

# 3. pip 依存
if (-not $SkipPip) {
    Write-Host "[3/4] pip 依存 (ComfyUI .venv)" -ForegroundColor Cyan
    $pip = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $pip) {
        $req = Join-Path $ComfyRoot "requirements.txt"
        if (Test-Path -LiteralPath $req) {
            if (-not $Check) {
                # PS 5.1 は stderr を 2>&1 で NativeCommandError 化して Stop するので
                # Start-Process 経由で実行 (exit code のみで成否判定)
                $p = Start-Process -FilePath $pip -ArgumentList @("-m","pip","install","-r",$req,"--quiet") -NoNewWindow -PassThru -Wait
                if ($p.ExitCode -eq 0) {
                    Write-Host "  pip 依存 OK" -ForegroundColor Green
                } else {
                    Write-Host "  pip install 失敗 (exit $($p.ExitCode)) (requirements 差分?)" -ForegroundColor Red
                    $script:failed += "pip"
                }
            } else {
                Write-Host "  (check mode: pip チェック省略)" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Host "  .venv python が見つからない: $pip" -ForegroundColor Yellow
    }
} else {
    Write-Host "[3/4] pip 依存 (スキップ指定)" -ForegroundColor DarkGray
}

# 4. sd.cpp
Write-Host "[4/4] sd.cpp" -ForegroundColor Cyan
$sdArgs = @()
if ($Check) { $sdArgs += "-Check" }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "update-sdcpp.ps1") @sdArgs
if ($LASTEXITCODE -ne 0) { $script:failed += "sd.cpp" }

# まとめ
Write-Host ""
if ($Check) {
    Write-Host "=== check 完了 (何も変更していません) ===" -ForegroundColor Cyan
} else {
    Write-Host "=== 結果 ===" -ForegroundColor Cyan
    if ($script:updated.Count -gt 0)   { Write-Host "  更新: $($script:updated -join ', ')" -ForegroundColor Green }
    if ($script:uptodate.Count -gt 0)  { Write-Host "  最新: $($script:uptodate -join ', ')" -ForegroundColor DarkGray }
    if ($script:failed.Count -gt 0) {
        Write-Host "  失敗: $($script:failed -join ', ') — 手動確認推奨" -ForegroundColor Red
        exit 1
    }
    Write-Host "  全て正常" -ForegroundColor Green
}
