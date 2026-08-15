# h3-chat.ps1 - Launch the MiniMax H3 chat-to-video UI.
# Requires ComfyUI to be running first (comfyui.bat / llamadock.bat -> [1] super
# or [2] ck), then run this to get the chat page:
#     powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$chatPy = Join-Path $here "h3-chat.py"
$port = 8189
$url = "http://127.0.0.1:$port"

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

if (-not $already) {
    $python = "C:\Users\dai86\Documents\ComfyUI\.venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $python)) { $python = "python" }
    Write-Host "Starting h3-chat on $url ..." -ForegroundColor Cyan
    Start-Process -FilePath $python -ArgumentList $chatPy -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

Write-Host "Opening $url" -ForegroundColor Green
Start-Process $url
