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
    [ValidateSet("Qwen3.5", "Qwen3.8-27B-GPU", "Qwen3.8-27B-GPU-Vision", "Qwen3.8-27B-Heretic-Vision", "Custom", "Off")]
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
    "Qwen3.8-27B-GPU" = @{
        Label = "Qwen3.8-27B Abliterated 12GB-MTP (GPU・企画フェーズのみ・視覚あり・mmproj同梱)"
        Path = "C:\Users\dai86\.lmstudio\models\soyaakinohara\qwen3.8-27b-abliterated-3.69bpw-12GB-MTP.gguf\qwen3.8-27b-abliterated-3.69bpw-12GB-MTP.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\soyaakinohara\qwen3.8-27b-abliterated-3.69bpw-12GB-MTP.gguf\mmproj-Q8_0.gguf"
        Gpu = $true
    }
    "Qwen3.8-27B-GPU-Vision" = @{
        Label = "Qwen3.8-27B ULTIMATE-UNCENSORED (GPU・企画フェーズのみ・視覚あり・KV q8/q4)"
        Path = "C:\Users\dai86\.lmstudio\models\lemonyins\Qwen3.8-27B-ULTIMATE-UNCENSORED-MTP-IQ4-GGUF-16GB\Qwen3.8-27B-ULTIMATE-UNCENSORED-MTP-IQ4-16GB.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\lemonyins\Qwen3.8-27B-ULTIMATE-UNCENSORED-MTP-IQ4-GGUF-16GB\mmproj-BF16.gguf"
        Gpu = $true
    }
    "Qwen3.8-27B-Heretic-Vision" = @{
        Label = "Qwen3.8-27B heretic-ara (GPU・企画フェーズのみ・視覚あり・i1-Q4_K_S)"
        Path = "C:\Users\dai86\.lmstudio\models\mradermacher\Qwen3.8-27B-heretic-ara-i1-GGUF\Qwen3.8-27B-heretic-ara.i1-Q4_K_S.gguf"
        Mmproj = "C:\Users\dai86\.lmstudio\models\mradermacher\Qwen3.8-27B-heretic-ara-i1-GGUF\mmproj-Q8_0.gguf"
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

# GPU planner（27B / Custom GPU）は 8191、CPU planner は 8190。
if ($PlanModel -eq "Qwen3.8-27B-GPU" -or $PlanModel -eq "Qwen3.8-27B-GPU-Vision" -or $PlanModel -eq "Qwen3.8-27B-Heretic-Vision" -or ($PlanModel -eq "Custom" -and $planModels["Custom"] -and $planModels["Custom"].Gpu)) {
    $planPort = 8191
}
$url = "http://127.0.0.1:$port"
$planUrl = "http://127.0.0.1:$planPort"

$planServer = "C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe"
if (-not (Test-Path -LiteralPath $planServer)) {
    $planServer = "C:\llama-tq3\build-rocm71\bin\llama-server.exe"
}

function Get-PlanEngineName {
    # 企画 LLM の llama-server 実体からエンジン名を判定（コーダー側のエンジン表記と揃える）。
    param([string]$ServerPath)
    if ($ServerPath -like "C:\llama-tq3\build-rocm71*") { return "AtomicBot (ROCm 7.1 HIP)" }
    if ($ServerPath -like "*llama.cpp-openPangu*") { return "openPangu (native CPU)" }
    if ($ServerPath -like "*turbo-tan*") { return "TurboTan (HIP)" }
    if ($ServerPath -like "*llama.cpp-vulkan*") { return "Official Vulkan" }
    if ($ServerPath -like "*llama.cpp-hip*") { return "Official HIP" }
    if ($ServerPath -like "*llama.cpp-cpu*") { return "Official CPU" }
    return "Unknown"
}
$planEngine = Get-PlanEngineName $planServer
# GPU 企画 LLM は h3-chat.py が起動する（PLAN_SERVER_BIN = AtomicBot rocm71）。
$planGpuEngine = "AtomicBot (ROCm 7.1 HIP)"

if (-not (Test-Path -LiteralPath $chatPy)) {
    Write-Host "ERROR: $chatPy not found" -ForegroundColor Red
    exit 1
}

# Is ComfyUI up?
$comfyUp = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $comfyUp = $true }
} catch { }

if (-not $comfyUp) {
    Write-Host "WARNING: ComfyUI (127.0.0.1:8188) is not running." -ForegroundColor Yellow
    $startComfy = Read-Host "Start ComfyUI now? (Y/n)"
    if ($startComfy -notmatch "^(n|no)$") {
        $repoRoot = Split-Path -Parent $here
        $comfyBat = Join-Path $repoRoot "comfyui.bat"
        if (Test-Path -LiteralPath $comfyBat) {
            # comfyui.bat opens its own console (tuning menu -> server). The
            # menu is answered there; this script only waits for :8188.
            Write-Host "Launching comfyui.bat (tuning menu opens in a new window) ..." -ForegroundColor Cyan
            Start-Process -FilePath $comfyBat -WorkingDirectory $repoRoot
        }
        else {
            Write-Host "comfyui.bat not found; please start ComfyUI manually." -ForegroundColor Yellow
        }
        Write-Host "Waiting for ComfyUI on 127.0.0.1:8188 (up to 150s) ..." -ForegroundColor Cyan
        for ($i = 0; $i -lt 50; $i++) {
            Start-Sleep -Seconds 3
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $comfyUp = $true; break }
            }
            catch { }
        }
        if ($comfyUp) {
            Write-Host "ComfyUI is up." -ForegroundColor Green
        }
        else {
            Write-Host "ComfyUI is still not ready; continuing anyway (generation will fail until it starts)." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Continuing without ComfyUI: chat works, but generation returns 503 until you start it (comfyui.bat)." -ForegroundColor Yellow
    }
}

# Already running?
$already = $false
try {
    $r = Invoke-WebRequest -Uri "$url/api/queue" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $already = $true }
} catch { }

# Double-launch guard: chat UI (and, for the resident CPU planner, the
# planning LLM) already running means there is nothing left to do here.
# The GPU planner is started on demand by h3-chat.py, so it is not checked.
# Use the model's .Gpu flag rather than enumerating names, so new GPU planners
# (e.g. Qwen3.8-27B-GPU-Vision) are picked up automatically.
$planIsGpuModel = [bool]($planModels[$PlanModel] -and $planModels[$PlanModel].Gpu)
if ($already -and -not $planIsGpuModel -and $PlanModel -ne "Off") {
    try {
        $r = Invoke-WebRequest -Uri "$planUrl/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            Write-Host "h3-chat and planning LLM are already running; nothing to start." -ForegroundColor Green
            if (-not $NoBrowser) { Start-Process $url }
            exit 0
        }
    } catch { }
}
elseif ($already -and $planIsGpuModel) {
    Write-Host "h3-chat is already running; nothing to start." -ForegroundColor Green
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
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
        Write-Host "WARNING: planning model not found: $($model.Path)" -ForegroundColor Yellow
        Write-Host "         Planning mode will be disabled. (Download it first in LM Studio.)" -ForegroundColor Yellow
        $planGpu = $false
        $planDisabled = $true
    }
    else {
        Write-Host "Planning LLM: $($model.Label) - started on demand by h3-chat.py (port $planPort, engine: $planGpuEngine)." -ForegroundColor Cyan
        $env:LLAMADOCK_PLAN_GPU = "1"
        # Pass the chosen model + mmproj to h3-chat.py so it launches THIS
        # model (its hardcoded default is the soyaakinohara 12GB-MTP 27B).
        $env:LLAMADOCK_PLAN_MODEL = $model.Path
        if ($model.Mmproj) { $env:LLAMADOCK_PLAN_MMPROJ = $model.Mmproj } else { $env:LLAMADOCK_PLAN_MMPROJ = "" }
        $skipPlanStart = $true
    }
}
if ($PlanModel -ne "Off" -and -not $planGpu -and -not $planDisabled) {
    $model = $planModels[$PlanModel]
    if (-not (Test-Path -LiteralPath $model.Path)) {
        Write-Host "WARNING: planning model not found: $($model.Path)" -ForegroundColor Yellow
        Write-Host "         Planning mode will be disabled. (Download it first in LM Studio.)" -ForegroundColor Yellow
        $planArgs = @()
    } elseif (-not (Test-Path -LiteralPath $planServer)) {
        Write-Host "WARNING: llama-server not found ($planServer); planning mode disabled." -ForegroundColor Yellow
    } else {
        # Reuse an already-running planning LLM instead of stacking a second
        # llama-server on the same port (double-instance guard).
        try {
            $planHealth = Invoke-WebRequest -Uri "$planUrl/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($planHealth.StatusCode -eq 200) {
                Write-Host "Planning LLM already running on $planUrl; reusing it." -ForegroundColor Green
                $planArgs = @("--plan-url", $planUrl)
                $planReady = $true
                $skipPlanStart = $true
            }
        }
        catch { }
        # CPU-only (-ngl 0) so ComfyUI keeps all VRAM. This 4B model is not a
        # reasoning model: with thinking enabled it re-reads its own system
        # prompt until the token budget runs out, then restarts thinking inside
        # the answer (measured: 200s, no clean output). --reasoning off makes
        # the chat template emit an empty think block so the model answers
        # directly (this build maps --reasoning off to enable_thinking=false;
        # the older --chat-template-kwargs form is deprecated).
        if (-not $skipPlanStart) {
        Write-Host "Starting planning LLM ($($model.Label)) on $planUrl (engine: $planEngine, $planServer) ..." -ForegroundColor Cyan
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
                $r = Invoke-WebRequest -Uri "$planUrl/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($r.StatusCode -eq 200) { $planReady = $true; break }
            } catch { }
        }
        if ($planReady) {
            $planArgs = @("--plan-url", $planUrl)
            Write-Host "Planning LLM ready." -ForegroundColor Green
        } else {
            Write-Host "WARNING: planning LLM did not become ready; planning mode disabled." -ForegroundColor Yellow
        }
        }
    }
}

if (-not $already) {
    $comfyRoot = if ($env:LLAMADOCK_COMFY_ROOT) { $env:LLAMADOCK_COMFY_ROOT } else { "C:\Users\dai86\Documents\ComfyUI" }
    $python = Join-Path $comfyRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { $python = "python" }
    Write-Host "Starting h3-chat on $url ..." -ForegroundColor Cyan
    Start-Process -FilePath $python -ArgumentList (@($chatPy) + $planArgs) -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

if (-not $NoBrowser) {
    Write-Host "Opening $url" -ForegroundColor Green
    Start-Process $url
}
