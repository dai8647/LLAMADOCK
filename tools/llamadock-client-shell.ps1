param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Cline", "OpenCode")]
    [string]$Client,
    [Parameter(Mandatory = $true)]
    [string]$ModelName,
    [string]$BaseUrl = "http://127.0.0.1:8090/v1",
    [string]$ConfigPath = "",
    [string]$DataDir = "",
    [string]$Workspace = ""
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
        & opencode -m "llamadock/$ModelName" (Get-Location).Path
    }
}

exit $LASTEXITCODE
