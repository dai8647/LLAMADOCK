param(
    [int]$Port = 3000,
    [string]$LlamaServerUrl = "http://127.0.0.1:8080/v1",
    [string]$SafeModelId = "",
    [switch]$EnableBackgroundTasks
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (Test-Path -LiteralPath $utf8Helper) {
    . $utf8Helper
}
$root = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $root "mcp-data\open-webui"
$siteDir = Join-Path $root "mcp-data\open-webui-venv\Lib\site-packages"
$bootstrap = Join-Path $PSScriptRoot "open-webui-bootstrap.py"

if (-not (Test-Path (Join-Path $siteDir "open_webui\__init__.py"))) {
    Write-Host "Open WebUI is not installed under: $siteDir" -ForegroundColor Red
    exit 1
}

$python = if (Test-Path "C:\Users\dai86\AppData\Local\Programs\Python\Python311\python.exe") {
    "C:\Users\dai86\AppData\Local\Programs\Python\Python311\python.exe"
}
else {
    (Get-Command python.exe -ErrorAction Stop).Source
}

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
Set-Location -LiteralPath $dataDir
$env:LLAMADOCK_OPEN_WEBUI_SITE = $siteDir
$env:PYTHONPATH = $siteDir
$env:DATA_DIR = $dataDir
$env:WEBUI_URL = "http://127.0.0.1:$Port"
$env:OPENAI_API_BASE_URLS = $LlamaServerUrl
$env:OPENAI_API_KEYS = "not-needed"
$env:LLAMADOCK_OPEN_WEBUI_SAFE_MODEL_ID = $SafeModelId
$env:LLAMADOCK_OPEN_WEBUI_BACKGROUND_TASKS = if ($EnableBackgroundTasks) { "True" } else { "False" }
$env:ENABLE_SIGNUP = "False"
$env:ENABLE_WEB_SEARCH = "True"
# The search toggle is already an explicit user request.  Letting the 1Q
# local model decide whether search is needed adds a slow task call and can
# incorrectly return an empty query.  Open WebUI falls back to the user's
# original message when query generation is disabled.
$env:ENABLE_SEARCH_QUERY_GENERATION = "False"
Write-Host "Open WebUI search-query generation: disabled; explicit search uses the user's text" -ForegroundColor Green
$env:WEB_SEARCH_ENGINE = "serper"
$env:ENABLE_CONTEXT_COMPACTION = "True"
$env:CONTEXT_COMPACTION_TOKEN_THRESHOLD = "24576"
$env:CONTEXT_COMPACTION_TOKEN_CAP = "24576"
$env:WEB_SEARCH_RESULT_COUNT = "3"
$env:WEB_FETCH_MAX_CONTENT_LENGTH = "6000"
$env:WEB_SEARCH_CONCURRENT_REQUESTS = "1"
$env:WEB_LOADER_CONCURRENT_REQUESTS = "2"
$env:WEB_SEARCH_TRUST_ENV = "True"

if ([string]::IsNullOrWhiteSpace($env:LLAMADOCK_OPEN_WEBUI_SAFE_MODEL_ID)) {
    try {
        $models = Invoke-RestMethod -Uri "$LlamaServerUrl/models" -TimeoutSec 3 -ErrorAction Stop
        $candidate = @($models.data | Where-Object { $_.id } | Select-Object -First 1)
        if ($candidate.Count -eq 1) {
            $env:LLAMADOCK_OPEN_WEBUI_SAFE_MODEL_ID = [string]$candidate[0].id
        }
    }
    catch {
        Write-Host "WARNING: Could not discover a local model for safe Web UI defaults." -ForegroundColor Yellow
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:LLAMADOCK_OPEN_WEBUI_SAFE_MODEL_ID)) {
    Write-Host "Web UI safe defaults: $($env:LLAMADOCK_OPEN_WEBUI_SAFE_MODEL_ID) | temperature 0 | max_tokens 512 | streaming on" -ForegroundColor Green
}

if ($EnableBackgroundTasks) {
    Write-Host "Open WebUI background title/tag/follow-up generation: enabled" -ForegroundColor Yellow
}
else {
    Write-Host "Open WebUI background title/tag/follow-up generation: disabled for local speed" -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($env:SERPER_API_KEY)) {
    Write-Host "WARNING: SERPER_API_KEY is not set; Open WebUI web search will need configuration in Admin Settings." -ForegroundColor Yellow
}
else {
    Write-Host "Serper search: enabled from Windows environment variable" -ForegroundColor Green
}

Write-Host "Open WebUI: http://127.0.0.1:$Port" -ForegroundColor Cyan
& $python $bootstrap serve --host 127.0.0.1 --port $Port
exit $LASTEXITCODE
