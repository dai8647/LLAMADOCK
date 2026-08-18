#Requires -Version 5.1
<#
.SYNOPSIS
    Configure ZCode to connect to LlamaDock's local llama-server.

.DESCRIPTION
    Writes/updates ~/.zcode/v2/config.json to add a "LlamaDock" custom
    provider pointing at http://127.0.0.1:8090/v1.
    Safe to re-run: merges with existing config without clobbering other providers.

.PARAMETER BaseUrl
    llama-server gateway URL. Default: http://127.0.0.1:8090/v1

.PARAMETER ModelName
    Model ID to register. Default: auto-detect from llama-server /v1/models

.PARAMETER ShowConfig
    Dump the current config.json and exit (no writes).

.EXAMPLE
    .\tools\zcode-setup.ps1
    .\tools\zcode-setup.ps1 -ShowConfig
    .\tools\zcode-setup.ps1 -BaseUrl "http://127.0.0.1:8090/v1" -ModelName "my-model"
#>
param(
    [string]$BaseUrl = "http://127.0.0.1:8090/v1",
    [string]$ModelName = "",
    [switch]$ShowConfig
)

$ErrorActionPreference = "Stop"

# --- Resolve config path ---
$homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$configDir = Join-Path $homeDir ".zcode\v2"
$configPath = Join-Path $configDir "config.json"

if ($ShowConfig) {
    if (Test-Path -LiteralPath $configPath) {
        Write-Host "=== ZCode config.json ===" -ForegroundColor Cyan
        Write-Host "Path: $configPath" -ForegroundColor DarkGray
        Write-Host ""
        Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10
    } else {
        Write-Host "Config not found: $configPath" -ForegroundColor Yellow
        Write-Host "ZCode has not been launched yet, or is installed elsewhere." -ForegroundColor Yellow
    }
    exit 0
}

# --- Auto-detect model name from llama-server ---
if ([string]::IsNullOrWhiteSpace($ModelName)) {
    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/models" -Method Get -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($resp.data -and $resp.data.Count -gt 0) {
            $ModelName = $resp.data[0].id
            Write-Host "Auto-detected model: $ModelName" -ForegroundColor Green
        }
    } catch {
        # Server may not be running — that's fine, user can set model later
    }
}
if ([string]::IsNullOrWhiteSpace($ModelName)) {
    $ModelName = "local-model"
    Write-Host "Could not detect model. Using placeholder: $ModelName" -ForegroundColor Yellow
}

# --- Ensure directory exists ---
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

# --- Read existing config or create empty ---
$existing = @{}
if (Test-Path -LiteralPath $configPath) {
    try {
        $raw = Get-Content -LiteralPath $configPath -Raw
        $existing = $raw | ConvertFrom-Json -AsHashtable
        Write-Host "Read existing config: $configPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "Warning: could not parse existing config, starting fresh" -ForegroundColor Yellow
        $existing = @{}
    }
}

# --- Build LlamaDock provider entry ---
$llamadockProvider = [ordered]@{
    id        = "llamadock"
    name      = "LlamaDock"
    type      = "openai"
    enabled   = $true
    options   = [ordered]@{
        baseURL        = $BaseUrl
        apiKey         = "not-needed"
        apiKeyRequired = $false
    }
    models    = @(
        [ordered]@{
            id              = $ModelName
            name            = $ModelName
            context_window  = 32768
        }
    )
}

# --- Merge into existing config ---
# ZCode v2 config structure: { "providers": [...], ... }
$providers = @()
if ($existing.providers) {
    $providers = @($existing.providers)
}

# Remove old LlamaDock entry if present
$providers = @($providers | Where-Object { $_.id -ne "llamadock" })
$providers += $llamadockProvider

$existing.providers = $providers

# --- Write config ---
$existing | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
Write-Host ""
Write-Host "ZCode config updated!" -ForegroundColor Green
Write-Host "  Path:      $configPath" -ForegroundColor DarkGray
Write-Host "  Provider:  LlamaDock (id: llamadock)" -ForegroundColor DarkGray
Write-Host "  Base URL:  $BaseUrl" -ForegroundColor DarkGray
Write-Host "  Model:     $ModelName" -ForegroundColor DarkGray
Write-Host ""
Write-Host "ZCodeを再起動すると LlamaDock モデルが選択肢に表示されます。" -ForegroundColor Cyan
