param(
    [int]$Port = 8000,
    [string]$LlamaServerUrl = "http://127.0.0.1:8080/v1",
    [switch]$SkipOpenBrowser
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (Test-Path -LiteralPath $utf8Helper) {
    . $utf8Helper
}
# Keep the HTTP/UI process UTF-8 capable, but do not force Python's Windows
# locale for child utilities.  cptr queries localized commands such as
# ipconfig; with PYTHONUTF8=1 those CP932 bytes become UnicodeDecodeError.
Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue
Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
$dataRoot = Join-Path $env:LOCALAPPDATA "LlamaDock\Computer"
$venv = Join-Path $dataRoot "venv-0.9.9"
$dataDir = Join-Path $dataRoot "data"
$python = "C:\Users\dai86\AppData\Local\Programs\Python\Python311\python.exe"
if (-not (Test-Path $python)) { $python = (Get-Command py.exe -ErrorAction Stop).Source }

New-Item -ItemType Directory -Force -Path $dataRoot, $dataDir | Out-Null
$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/config" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($health.StatusCode -eq 200) {
            Write-Host "Computer UI is already running on 127.0.0.1:$Port; reusing the existing instance." -ForegroundColor Green
            Write-Host "No second browser window was opened." -ForegroundColor DarkGray
            exit 0
        }
    }
    catch {}
}
if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) {
    Write-Host "Creating dedicated Computer Python environment..." -ForegroundColor Cyan
    if ((Split-Path $python -Leaf) -eq "py.exe") { & $python -3.11 -m venv $venv } else { & $python -m venv $venv }
    if ($LASTEXITCODE -ne 0) { throw "Could not create Computer virtual environment." }
}
$venvPython = Join-Path $venv "Scripts\python.exe"
$cptr = Join-Path $venv "Scripts\cptr.exe"
if (-not (Test-Path $cptr)) {
    Write-Host "Installing Open WebUI Computer 0.9.9 (native Windows)..." -ForegroundColor Cyan
    & $venvPython -m pip install --upgrade "cptr[mcp]==0.9.9"
    if ($LASTEXITCODE -ne 0) { throw "Computer installation failed." }
}

$env:CPTR_DATA_DIR = $dataDir
$env:CPTR_HOST = "127.0.0.1"
$env:CPTR_LLAMADOCK_BASE_URL = $LlamaServerUrl
$configScript = Join-Path $PSScriptRoot "computer-configure-local.ps1"
if (Test-Path $configScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $configScript -BaseUrl $LlamaServerUrl
    if ($LASTEXITCODE -ne 0) { throw "Could not configure the local LlamaDock connection." }
}
Write-Host "Computer: http://127.0.0.1:$Port" -ForegroundColor Cyan
Write-Host "Data: $dataDir" -ForegroundColor DarkGray
Write-Host "First run requires creating the local Computer admin account in the browser." -ForegroundColor Yellow
$logDir = Join-Path $dataDir "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stdoutLog = Join-Path $logDir "computer.stdout.log"
$stderrLog = Join-Path $logDir "computer.stderr.log"
# cptr prints a Unicode arrow in its startup URL.  The native Windows Python
# process otherwise inherits CP932 and can abort before binding the UI port.
# Set the encoding only for the cptr child; the launcher itself deliberately
# keeps the system locale for utilities that emit localized Windows output.
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$env:PYTHONIOENCODING = "utf-8"
$process = Start-Process -FilePath $cptr -ArgumentList @("run", "--host", "127.0.0.1", "--port", $Port) -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru -WindowStyle Normal
if ($null -eq $previousPythonIoEncoding) {
    Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
}
else {
    $env:PYTHONIOENCODING = $previousPythonIoEncoding
}
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/config" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($health.StatusCode -eq 200) { $ready = $true; break }
    }
    catch {}
}
if (-not $ready) { Write-Host "WARNING: Computer did not become ready within 30s. See $stderrLog" -ForegroundColor Yellow }
$browserUrl = "http://127.0.0.1:$Port"
$tokenMatch = Select-String -Path @($stdoutLog, $stderrLog) -Pattern ("http://127\.0\.0\.1:$Port/\?token=[A-Za-z0-9]+") -AllMatches -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($tokenMatch -and $tokenMatch.Matches.Count -gt 0) { $browserUrl = $tokenMatch.Matches[-1].Value }
if (-not $SkipOpenBrowser) { Start-Process $browserUrl }
Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
exit $process.ExitCode
