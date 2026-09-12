# h3-chat.ps1 - Launch the MiniMax H3 chat-to-video UI.
# Requires ComfyUI to be running first (comfyui.bat / llamadock.bat -> [1] super
# or [2] ck), then run this to get the chat page:
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1
#
# Planning mode optionally starts a local planning LLM. Choose the model with
# -PlanModel:
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel Qwen3.5
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel Qwen3.8-27B-GPU
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel Custom
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel Off
#
# Qwen3.5 runs on CPU (-ngl 0) and stays resident. Qwen3.8-27B-GPU runs on the
# GPU during the planning phase only: h3-chat.py starts it on demand (port
# 8191) and kills it before every generation so the video model gets the VRAM.
# Custom = select-model.ps1 が .lmstudio\models から自動検出したモデル。
# パスは環境変数 LLAMADOCK_PLAN_MODEL / LLAMADOCK_PLAN_MMPROJ / LLAMADOCK_PLAN_GPU
# で渡される（select-model.ps1 の Start-H3Chat が設定）。

param(
    [ValidateSet("Qwen3.5", "Qwen3.8-27B-GPU", "Qwen3.8-27B-GPU-Vision", "Qwen3.5-A35B-GPU-Vision", "Custom", "Off")]
    [string]$PlanModel = "Qwen3.5",
    # Used by select-model.ps1 (plan mode): start the planning LLM and the
    # chat server but let the caller open the browser.
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$chatPy = Join-Path $here "h3-chat.py"
$port = 8189
$planPort = 8190

$planModels = @{
    "Qwen3.5" = @{
        Label = "Qwen3.5-4B NSFW Literotica (えろ特化・視覚は mmproj 流用)"
        Path = "C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica.i1-Q6_K.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\mmproj-Qwen3.5-4B-NSFW-Literotica-BF16.gguf"
    }
    # GPU エントリは「今インストール済みのモデル」を指す。モデルを入れ替えた
    # ときはここを更新するか、UI の企画 LLM モデル選択（/api/plan-models）か
    # select-model.ps1 の自動検出（Custom）を使う。
    "Qwen3.8-27B-GPU" = @{
        Label = "Qwen3.8-27B Uncensored HauhauCS IQ3_M (GPU・企画フェーズのみ・視覚あり・11.9GB)"
        Path = "C:\Users\dai86\.lmstudio\models\HauhauCS\Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF\Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-IQ3_M.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\HauhauCS\Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF\mmproj-Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-BF16.gguf"
        Gpu = $true
    }
    "Qwen3.8-27B-GPU-Vision" = @{
        Label = "Qwen3.8-27B Uncensored HauhauCS IQ4_XS (GPU・企画フェーズのみ・視覚あり・14.6GB・高品質)"
        Path = "C:\Users\dai86\.lmstudio\models\HauhauCS\Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF\Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\HauhauCS\Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF\mmproj-Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-BF16.gguf"
        Gpu = $true
    }
    "Qwen3.5-A35B-GPU-Vision" = @{
        Label = "Huihui-Qwen3.5-A35B-Ablit-Small TQ3_4S (GPU・企画フェーズのみ・視覚あり・12.4GB・MoE)"
        Path = "C:\Users\dai86\.lmstudio\models\YTan2000\Huihui-Qwen35-A35B-Ablit-Small-TQ3_4S\Huihui-Qwen35-A35B-Ablit-Small-TQ3_4S.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\YTan2000\Huihui-Qwen35-A35B-Ablit-Small-TQ3_4S\mmproj-Qwen35-A35B-f16.gguf"
        Gpu = $true
    }
}

# Custom: select-model.ps1 が自動検出したモデル。パス等は環境変数で届く。
# 環境変数が無ければ企画モードを無効化して Qwen3.5 相当の扱いにフォールバック。
if ($PlanModel -eq "Custom") {
    $customPath = $env:LLAMADOCK_PLAN_MODEL
    if ([string]::IsNullOrWhiteSpace($customPath) -or -not (Test-Path -LiteralPath $customPath)) {
        Write-Host "WARNING: -PlanModel Custom だが LLAMADOCK_PLAN_MODEL が未設定/見つからないため、企画モードを無効化します。" -ForegroundColor Yellow
        $PlanModel = "Off"
    }
    else {
        $customMmproj = $env:LLAMADOCK_PLAN_MMPROJ
        if ($customMmproj -and -not (Test-Path -LiteralPath $customMmproj)) { $customMmproj = $null }
        $customGpu = ($env:LLAMADOCK_PLAN_GPU -eq "1")
        $planModels["Custom"] = @{
            Label = "自動検出モデル ($([System.IO.Path]::GetFileName($customPath)))"
            Path = $customPath
            Mmproj = $customMmproj
            Gpu = $customGpu
        }
    }
}

# GPU planner（.Gpu フラグ付きエントリ / Custom GPU）は 8191、CPU planner は 8190。
if ($planModels[$PlanModel] -and $planModels[$PlanModel].Gpu) {
    $planPort = 8191
}
$url = "http://127.0.0.1:$port"
$planUrl = "http://127.0.0.1:$planPort"

# ROCm PATH 注入は GPU 切り替え（2026-09-11, RTX 3080 / CUDA）後は不要。
# 残していても ROCm が無い限り何もしない。CUDA DLL は llama-server.exe 隣に
# select-model.ps1 の Ensure-UnslothCudaRuntime が配置する。
$rocmBin = if ($env:LLAMADOCK_ROCM_BIN) { $env:LLAMADOCK_ROCM_BIN } else {
    $amdRoot = "C:\Program Files\AMD\ROCm"
    if (Test-Path -LiteralPath $amdRoot) {
        $latest = Get-ChildItem -LiteralPath $amdRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) { Join-Path $latest.FullName "bin" }
    }
}
if ($rocmBin -and (Test-Path -LiteralPath $rocmBin) -and ($env:PATH -notlike "*$rocmBin*")) {
    $env:PATH = "$rocmBin;$env:PATH"
}

# 単一エンジン (Unsloth llama.cpp CUDA ビルド / RTX 3080) を企画 LLM にも使う。
$planServer = "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe"
if (-not (Test-Path -LiteralPath $planServer) -and $env:LLAMADOCK_UNSLOTH_SERVER) {
    $planServer = [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_UNSLOTH_SERVER)
}

function Get-PlanEngineName {
    # 企画 LLM の llama-server 実体からエンジン名を判定（コーダー側のエンジン表記と揃える）。
    param([string]$ServerPath)
    if ($ServerPath -like "*\.unsloth\*") { return "Unsloth (CUDA)" }
    return "Unknown"
}
$planEngine = Get-PlanEngineName $planServer
# GPU 企画 LLM も h3-chat.py が PLAN_SERVER_BIN（Unsloth CUDA ビルド）で起動する。
$planGpuEngine = "Unsloth (CUDA)"

function Get-LivePlanStatus {
    # 稼働中 h3-chat (8189) の企画 LLM 設定（GPU/CPU + モデルパス）を取得する。
    # リポジトリ世代で API が異なるため /api/plan-status → /api/plan-models の順に試す。
    try {
        $s = Invoke-RestMethod -Uri "http://127.0.0.1:8189/api/plan-status" -TimeoutSec 5 -ErrorAction Stop
        if ($null -ne $s) { return @{ Gpu = [bool]$s.gpu; Model = [string]$s.model } }
    }
    catch { }
    try {
        $s = Invoke-RestMethod -Uri "http://127.0.0.1:8189/api/plan-models" -TimeoutSec 5 -ErrorAction Stop
        if ($s -and $s.current) { return @{ Gpu = [bool]$s.current.gpu; Model = [string]$s.current.path } }
    }
    catch { }
    return $null
}

function Test-TcpPort {
    # ポートのリスナーへの TCP 接続可否を 2 秒で判定する。/api/queue 等の
    # HTTP プローブは ComfyUI 停止中に 503 を返して偽陰性になるため、
    # h3-chat の生存確認はこの TCP プローブで行う。
    param([int]$Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(2000)
        if ($ok) { $tcp.EndConnect($async) }
        $tcp.Close()
        return $ok
    }
    catch { return $false }
}

function Stop-LlamaDockPlanStack {
    # h3-chat (8189) と企画 llama-server (8190/8191) だけをポートのリスナー PID で
    # 的確に停止する（ComfyUI 8188 やコーダー 8080 は巻き込まない）。
    param([switch]$IncludeChat)
    $ports = @(8190, 8191)
    if ($IncludeChat) { $ports = @(8189) + $ports }
    foreach ($p in $ports) {
        try {
            $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
            foreach ($ownerPid in @($conns | Select-Object -ExpandProperty OwningProcess -Unique)) {
                if ($ownerPid -and $ownerPid -ne 0) { Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue }
            }
        }
        catch { }
    }
    if ($IncludeChat) {
        # 二重起動の片割れなどポートを握らない h3-chat.py も掃除する
        try {
            Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'h3-chat\.py' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        catch { }
    }
    Start-Sleep -Milliseconds 800
}

if (-not (Test-Path -LiteralPath $chatPy)) {
    Write-Host "エラー: $chatPy が見つかりません" -ForegroundColor Red
    exit 1
}

# Is ComfyUI up?
$comfyUp = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $comfyUp = $true }
} catch { }

if (-not $comfyUp) {
    Write-Host "警告: ComfyUI (127.0.0.1:8188) が起動していません。" -ForegroundColor Yellow
    $startComfy = Read-Host "ComfyUI を今すぐ起動しますか？ (Y/n)"
    if ($startComfy -notmatch "^(n|no)$") {
        $repoRoot = Split-Path -Parent $here
        $comfyBat = Join-Path $repoRoot "comfyui.bat"
        if (Test-Path -LiteralPath $comfyBat) {
            # comfyui.bat opens its own console (tuning menu -> server). The
            # menu is answered there; this script only waits for :8188.
            Write-Host "comfyui.bat を起動しています（チューニングメニューは新しいウィンドウで開きます）…" -ForegroundColor Cyan
            Start-Process -FilePath $comfyBat -WorkingDirectory $repoRoot
        }
        else {
            Write-Host "comfyui.bat が見つかりません。手動で ComfyUI を起動してください。" -ForegroundColor Yellow
        }
        Write-Host "ComfyUI の起動を待っています (127.0.0.1:8188、最大150秒) …" -ForegroundColor Cyan
        for ($i = 0; $i -lt 50; $i++) {
            Start-Sleep -Seconds 3
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $comfyUp = $true; break }
            }
            catch { }
        }
        if ($comfyUp) {
            Write-Host "ComfyUI が起動しました。" -ForegroundColor Green
        }
        else {
            Write-Host "ComfyUI がまだ準備できていません。このまま続行します（起動するまで生成は失敗します）。" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "ComfyUI なしで続行します: チャットは使えますが、生成は ComfyUI を起動するまで 503 になります (comfyui.bat)。" -ForegroundColor Yellow
    }
}

# Already running?
$already = Test-TcpPort 8189
if (-not $already) {
    # 8189 にリスナーが残っているのに TCP 接続できないのはスタックした旧
    # h3-chat。そのまま新規起動するとポート競合するため、掃除してから続行する。
    $stuckChat = Get-NetTCPConnection -LocalPort 8189 -State Listen -ErrorAction SilentlyContinue
    if ($stuckChat) {
        Write-Host "8189 の旧 h3-chat が応答していないため停止して再起動します..." -ForegroundColor Yellow
        Stop-LlamaDockPlanStack -IncludeChat
    }
}

# Double-launch guard + selection reconcile. h3-chat.py fixes the planning
# LLM (GPU/CPU + model path) from its startup env, so an already-running chat
# silently ignores a different -PlanModel. Compare the live stack's plan
# status with the selection: match → reuse; differ → stop the old chat +
# planners and fall through to a fresh start with the chosen model.
$planIsGpuModel = [bool]($planModels[$PlanModel] -and $planModels[$PlanModel].Gpu)
if ($already) {
    $selectionOk = $false
    $live = Get-LivePlanStatus
    if ($live) {
        $selectionOk = ($live.Gpu -eq $planIsGpuModel)
        if ($selectionOk -and $planModels[$PlanModel] -and $planModels[$PlanModel].Path) {
            $liveLeaf = if ($live.Model) { Split-Path -Leaf ($live.Model -replace '/', '\') } else { "" }
            $wantLeaf = Split-Path -Leaf $planModels[$PlanModel].Path
            if (-not $liveLeaf -or -not ($liveLeaf -ieq $wantLeaf)) { $selectionOk = $false }
        }
    }
    if ($selectionOk) {
        Write-Host "h3-chat と企画 LLM は選択どおり起動しています。新しく起動するものはありません。" -ForegroundColor Green
        if (-not $NoBrowser) { Start-Process $url }
        exit 0
    }
    if ($PlanModel -eq "Off") {
        # Off は明示的な「企画 LLM なし」選択。稼働中チャットのプラナーが
        # 異なっていてもアクティブなセッションを殺さないためスタックは触らない。
        Write-Host "h3-chat は既に起動しています。新しく起動するものはありません。" -ForegroundColor Green
        if (-not $NoBrowser) { Start-Process $url }
        exit 0
    }
    Write-Host "稼働中の h3-chat は別の企画 LLM を使っています。停止して選択モデルで再起動します…" -ForegroundColor Yellow
    Stop-LlamaDockPlanStack -IncludeChat
    $already = $false
}

# ---- planning LLM (optional) ---------------------------------------

$planArgs = @()
$skipPlanStart = $false
# The GPU planner is launched on demand by h3-chat.py (LLAMADOCK_PLAN_GPU=1):
# it must not hold VRAM while ComfyUI may still be generating.
$planGpu = $planIsGpuModel
$planDisabled = $false
if ($planGpu) {
    $model = $planModels[$PlanModel]
    if (-not (Test-Path -LiteralPath $model.Path)) {
        Write-Host "警告: 企画 LLM のモデルが見つかりません: $($model.Path)" -ForegroundColor Yellow
        Write-Host "         企画モードは無効になります。（先に LM Studio でダウンロードしてください）" -ForegroundColor Yellow
        $planGpu = $false
        $planDisabled = $true
    }
    else {
        Write-Host "企画 LLM: $($model.Label) - h3-chat.py が必要時に起動します (ポート $planPort、エンジン: $planGpuEngine)。" -ForegroundColor Cyan
        $env:LLAMADOCK_PLAN_GPU = "1"
        # Pass the chosen model + mmproj to h3-chat.py so it launches THIS
        # model (without the env vars h3-chat.py auto-selects from the
        # installed GGUFs, but an explicit choice wins).
        $env:LLAMADOCK_PLAN_MODEL = $model.Path
        if ($model.Mmproj) { $env:LLAMADOCK_PLAN_MMPROJ = $model.Mmproj } else { $env:LLAMADOCK_PLAN_MMPROJ = "" }
        $skipPlanStart = $true
        # 旧セッションの企画 llama-server が別モデルで残っていないか掃除する
        # （h3-chat 未起動でも llama-server だけが残っていることがある）。
        foreach ($pp in @(8190, 8191)) {
            $oldId = ""
            try {
                $oldm = Invoke-RestMethod -Uri "http://127.0.0.1:$pp/v1/models" -TimeoutSec 5 -ErrorAction Stop
                if ($oldm -and $oldm.data) { $oldId = [string]$oldm.data[0].id }
            }
            catch { }
            if ($oldId) {
                $oldLeaf = Split-Path -Leaf ($oldId -replace '/', '\')
                if (-not ($oldLeaf -ieq (Split-Path -Leaf $model.Path))) {
                    try {
                        $oldConns = Get-NetTCPConnection -LocalPort $pp -State Listen -ErrorAction SilentlyContinue
                        foreach ($oldPid in @($oldConns | Select-Object -ExpandProperty OwningProcess -Unique)) {
                            if ($oldPid -and $oldPid -ne 0) { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue }
                        }
                    }
                    catch { }
                }
            }
        }
    }
}
if ($PlanModel -ne "Off" -and -not $planGpu -and -not $planDisabled) {
    $model = $planModels[$PlanModel]
    if (-not (Test-Path -LiteralPath $model.Path)) {
        Write-Host "警告: 企画 LLM のモデルが見つかりません: $($model.Path)" -ForegroundColor Yellow
        Write-Host "         企画モードは無効になります。（先に LM Studio でダウンロードしてください）" -ForegroundColor Yellow
        $planArgs = @()
    } elseif (-not (Test-Path -LiteralPath $planServer)) {
        Write-Host "警告: llama-server が見つかりません ($planServer)。企画モードを無効化します。" -ForegroundColor Yellow
    } else {
        # Reuse an already-running planning LLM instead of stacking a second
        # llama-server on the same port — but only when it serves the SAME
        # model. A different model means the selection changed: stop the old
        # server so the chosen model takes its place (double-instance guard
        # + selection reconcile).
        $reusePlan = $false
        try {
            $planHealth = Invoke-WebRequest -Uri "$planUrl/v1/models" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            if ($planHealth.StatusCode -eq 200) { $reusePlan = $true }
        }
        catch { }
        if ($reusePlan) {
            $liveId = ""
            try {
                $pm = Invoke-RestMethod -Uri "$planUrl/v1/models" -TimeoutSec 5 -ErrorAction Stop
                if ($pm -and $pm.data) { $liveId = [string]$pm.data[0].id }
            }
            catch { }
            $liveLeaf = if ($liveId) { Split-Path -Leaf ($liveId -replace '/', '\') } else { "" }
            $wantLeaf = Split-Path -Leaf $model.Path
            if ($liveLeaf -and ($liveLeaf -ieq $wantLeaf)) {
                Write-Host "企画 LLM は $planUrl で既に起動中です。これを再利用します。" -ForegroundColor Green
                $planArgs = @("--plan-url", $planUrl)
                $planReady = $true
                $skipPlanStart = $true
            }
            else {
                Write-Host "企画 LLM ($planUrl) は別モデル ($liveLeaf) を提供中です。$wantLeaf で再起動します。" -ForegroundColor Yellow
                Stop-LlamaDockPlanStack   # 8190/8191 の旧プラナーを掃除
            }
        }
        # CPU-only (-ngl 0) so ComfyUI keeps all VRAM. This 4B model is not a
        # reasoning model: with thinking enabled it re-reads its own system
        # prompt until the token budget runs out, then restarts thinking inside
        # the answer (measured: 200s, no clean output). --reasoning off makes
        # the chat template emit an empty think block so the model answers
        # directly (this build maps --reasoning off to enable_thinking=false;
        # the older --chat-template-kwargs form is deprecated).
        if (-not $skipPlanStart) {
        Write-Host "企画 LLM を起動しています ($($model.Label)) → $planUrl (エンジン: $planEngine、$planServer) …" -ForegroundColor Cyan
        $serverArgs = @(
            "-m", $model.Path,
            "--port", "$planPort",
            "-ngl", "0",
            "-c", "8192",
            "--no-webui",
            "-np", "1",
            "--mlock",
            "-ctk", "q8_0",
            "--reasoning", "off",
            "--temp", "0.8",
            "--top-p", "0.95",
            "--min-p", "0.05",
            "--repeat-penalty", "1.05"
        )
        # multimodal models (Qwen3.5 etc.): attach the vision projector so the
        # planning LLM can actually see the confirmed key image. Qwen-VL needs
        # >=1024 image tokens to resolve detail (server warns at startup).
        if ($model.Mmproj -and (Test-Path -LiteralPath $model.Mmproj)) {
            $serverArgs += @("--mmproj", $model.Mmproj, "--image-min-tokens", "1024")
        }
        Start-Process -FilePath $planServer -ArgumentList $serverArgs -WorkingDirectory (Split-Path -Parent $planServer) -WindowStyle Hidden
        # wait for the model to finish loading (up to ~60s)
        $planReady = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            try {
                $r = Invoke-WebRequest -Uri "$planUrl/v1/models" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $planReady = $true; break }
            } catch { }
        }
        if ($planReady) {
            $planArgs = @("--plan-url", $planUrl)
            Write-Host "企画 LLM の準備ができました。" -ForegroundColor Green
        } else {
            Write-Host "警告: 企画 LLM が準備できませんでした。企画モードを無効化します。" -ForegroundColor Yellow
        }
        }
    }
}

if (-not $already) {
    $comfyRoot = if ($env:LLAMADOCK_COMFY_ROOT) { $env:LLAMADOCK_COMFY_ROOT } else { "C:\Users\dai86\Documents\ComfyUI" }
    $python = Join-Path $comfyRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { $python = "python" }
    Write-Host "h3-chat を起動しています → $url …" -ForegroundColor Cyan
    Start-Process -FilePath $python -ArgumentList (@($chatPy) + $planArgs) -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

if (-not $NoBrowser) {
    Write-Host "ブラウザで開いています → $url" -ForegroundColor Green
    Start-Process $url
}
