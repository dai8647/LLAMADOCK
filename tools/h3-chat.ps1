# h3-chat.ps1 - Launch the MiniMax H3 chat-to-video UI.
# Requires ComfyUI to be running first (comfyui.bat / llamadock.bat -> [1] super
# or [2] ck), then run this to get the chat page:
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1
#
# Planning mode optionally starts a local planning LLM (CPU-only, VRAM stays
# free for ComfyUI). Choose the model with -PlanModel:
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel LFM
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel DirtyMuse
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1 -PlanModel Off

param(
    [ValidateSet("LFM", "DirtyMuse", "Off")]
    [string]$PlanModel = "LFM"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$chatPy = Join-Path $here "h3-chat.py"
$port = 8189
$planPort = 8190
$url = "http://127.0.0.1:$port"
$planUrl = "http://127.0.0.1:$planPort"

$planModels = @{
    LFM = @{
        Label = "LFM2.5-2.6B (軽量・汎用)"
        Path = "C:\Users\dai86\.lmstudio\models\nguyenthilaitrieulong\LFM2.5-2.6B-Heretic-Abliterated-GGUF\LFM2.5-2.6B-heretic-Q5_K_S.gguf"
    }
    DirtyMuse = @{
        Label = "Dirty-Muse-Writer (エロティカ特化)"
        Path = "C:\Users\dai86\.lmstudio\models\kizzet373\Dirty-Muse-Writer-v01-Uncensored-Erotica-NSFW-Q4_K_M-GGUF\dirty-muse-writer-v01-uncensored-erotica-nsfw-q4_k_m.gguf"
    }
}

$planServer = "C:\Users\dai86\Downloads\llama.cpp-openPangu-2.0-Flash\build-win-native\bin\llama-server.exe"
if (-not (Test-Path -LiteralPath $planServer)) {
    $planServer = "C:\llama-tq3\build-rocm71\bin\llama-server.exe"
}

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
    Write-Host "         Start it first (comfyui.bat -> [1] super), then re-run this script." -ForegroundColor Yellow
}

# Already running?
$already = $false
try {
    $r = Invoke-WebRequest -Uri "$url/api/queue" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $already = $true }
} catch { }

# ---- planning LLM (optional) ---------------------------------------

$planArgs = @()
if ($PlanModel -ne "Off") {
    $model = $planModels[$PlanModel]
    if (-not (Test-Path -LiteralPath $model.Path)) {
        Write-Host "WARNING: planning model not found: $($model.Path)" -ForegroundColor Yellow
        Write-Host "         Planning mode will be disabled. (Download it first in LM Studio.)" -ForegroundColor Yellow
        $planArgs = @()
    } elseif (-not (Test-Path -LiteralPath $planServer)) {
        Write-Host "WARNING: llama-server not found ($planServer); planning mode disabled." -ForegroundColor Yellow
    } else {
        # CPU-only (-ngl 0) so ComfyUI keeps all VRAM; reasoning off so the
        # tiny planning model answers immediately instead of thinking forever.
        Write-Host "Starting planning LLM ($($model.Label)) on $planUrl ..." -ForegroundColor Cyan
        Start-Process -FilePath $planServer -ArgumentList @(
            "-m", $model.Path,
            "--port", "$planPort",
            "-ngl", "0",
            "-c", "4096",
            "--no-webui",
            "--reasoning", "off",
            "--reasoning-budget", "0"
        ) -WorkingDirectory (Split-Path -Parent $planServer) -WindowStyle Hidden
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

if (-not $already) {
    $comfyRoot = if ($env:LLAMADOCK_COMFY_ROOT) { $env:LLAMADOCK_COMFY_ROOT } else { "C:\Users\dai86\Documents\ComfyUI" }
    $python = Join-Path $comfyRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { $python = "python" }
    Write-Host "Starting h3-chat on $url ..." -ForegroundColor Cyan
    Start-Process -FilePath $python -ArgumentList (@($chatPy) + $planArgs) -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

Write-Host "Opening $url" -ForegroundColor Green
Start-Process $url
