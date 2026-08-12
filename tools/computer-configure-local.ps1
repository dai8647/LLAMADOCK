param(
    [string]$BaseUrl = "http://127.0.0.1:8080/v1",
    [string]$Name = "LlamaDock local"
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (Test-Path -LiteralPath $utf8Helper) {
    . $utf8Helper
}
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$dataDir = Join-Path $env:LOCALAPPDATA "LlamaDock\Computer\data"
$venvPython = Join-Path $env:LOCALAPPDATA "LlamaDock\Computer\venv-0.9.9\Scripts\python.exe"
$script = Join-Path $PSScriptRoot "computer-configure-local.py"
if (-not (Test-Path $venvPython)) { throw "Computer venv is missing: $venvPython" }
$env:CPTR_DATA_DIR = $dataDir
$env:LLAMADOCK_COMPUTER_BASE_URL = $BaseUrl
$env:LLAMADOCK_COMPUTER_CONNECTION_NAME = $Name
& $venvPython $script
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
