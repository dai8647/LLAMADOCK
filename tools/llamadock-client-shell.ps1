param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Cline", "OpenCode", "OpenClaude")]
    [string]$Client,
    [Parameter(Mandatory = $true)]
    [string]$ModelName,
    [string]$BaseUrl = "http://127.0.0.1:8090/v1",
    [string]$ConfigPath = "",
    [string]$DataDir = "",
    [string]$Workspace = "",
    [string]$Prompt = "",
    [int]$MaxMinutes = 90,
    [int]$MaxResumes = 3,
    [int]$StallSeconds = 300,
    [switch]$Harness
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (-not (Test-Path -LiteralPath $utf8Helper)) {
    throw "Shared UTF-8 helper is missing: $utf8Helper"
}
. $utf8Helper
Set-LlamaDockUtf8Environment

if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    Set-Location -LiteralPath $Workspace
}

switch ($Client) {
    "Cline" {
        if ([string]::IsNullOrWhiteSpace($DataDir)) {
            throw "Cline data directory is required."
        }
        $env:CLINE_DATA_DIR = $DataDir
        $env:CLINE_MCP_SETTINGS_PATH = Join-Path $DataDir "settings\cline_mcp_settings.json"
        & cline --data-dir $DataDir --thinking none --compaction basic --timeout 900
    }
    "OpenCode" {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            throw "OpenCode config path is required."
        }
        $env:OPENCODE_CONFIG = $ConfigPath
        $env:OPENAI_API_KEY = "not-needed"
        if ($Harness) {
            # Route to the harness runner
            $harnessPath = Join-Path $PSScriptRoot "llamadock-opencode-harness.ps1"
            $harnessArgs = @{
                Workspace = if (-not [string]::IsNullOrWhiteSpace($Workspace)) { $Workspace } else { (Get-Location).Path }
                ModelName = $ModelName
                Prompt = if ([string]::IsNullOrWhiteSpace($Prompt)) {
                    $entered = Read-Host "Enter the coding task for harness mode"
                    if ([string]::IsNullOrWhiteSpace($entered)) { throw "Prompt is required for harness mode. Provide via -Prompt parameter or enter a task when prompted." }
                    $entered
                } else { $Prompt }
                MaxMinutes = $MaxMinutes
                MaxResumes = $MaxResumes
                StallSeconds = $StallSeconds
                Root = Split-Path -Parent $PSScriptRoot
            }
            & $harnessPath @harnessArgs
        }
        else {
            & opencode -m "llamadock/$ModelName" (Get-Location).Path
        }
    }
    "OpenClaude" {
        $env:CLAUDE_CODE_USE_OPENAI = "1"
        $env:OPENAI_BASE_URL = $BaseUrl
        $env:OPENAI_API_KEY = "not-needed"
        & openclaude --provider openai --model $ModelName
    }
}

exit $LASTEXITCODE
