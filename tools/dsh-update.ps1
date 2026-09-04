# tools/dsh-update.ps1 — DeepSeek Harness auto-update checker
# Runs in background (Start-Job) at launch. Silently updates if newer version exists.
# Exit codes: 0 = up-to-date or updated, 1 = npm not found

param()

$ErrorActionPreference = "SilentlyContinue"

# Find npm
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) {
    # Try common Windows locations
    $candidates = @(
        "$env:ProgramFiles\\nodejs\\npm.cmd",
        "$env:APPDATA\\npm\\npm.cmd",
        "$env:LOCALAPPDATA\\fnm\\multishells\\*\\npm.cmd"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $npm = $c; break }
    }
    if (-not $npm) {
        Write-Host "dsh-update: npm not found, skipping update check" -ForegroundColor DarkGray
        exit 1
    }
} else {
    $npm = $npm.Source
}

# Never replace the npm package while a dsh web server is running from it:
# a live instance can keep serving a stale boot page after the update or hit
# a half-replaced tree. dsh web listens on 3080 (same process check as
# select-model.ps1's Stop-StaleDeepSeekHarness); skip when it is up.
$running = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
foreach ($ownerPid in @($running | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })) {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
    if ($cim -and [string]$cim.CommandLine -match "dsh" -and [string]$cim.CommandLine -match "web") {
        Write-Host "dsh-update: dsh web is running on port 3080; skipping update until it is stopped" -ForegroundColor DarkGray
        exit 0
    }
}

# Check currently installed version
$installed = & $npm list -g @deepseek-ai/dsh --depth=0 2>&1 | Select-String "@deepseek-ai/dsh"
$currentVersion = ""
# Capture the full version incl. prerelease (0.1.2-rc.1); matching only the
# numeric prefix would reinstall on every launch and race the live server.
if ($installed -match "(@deepseek-ai/dsh@)([0-9][0-9A-Za-z.\-]+)") {
    $currentVersion = $Matches[2]
}

# Check latest version from registry
$latest = & $npm view @deepseek-ai/dsh version 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latest)) {
    Write-Host "dsh-update: could not reach npm registry" -ForegroundColor DarkGray
    exit 1
}

$latest = $latest.Trim()

if ($currentVersion -eq $latest) {
    # Already up to date
    exit 0
}

# Update needed
if ([string]::IsNullOrWhiteSpace($currentVersion)) {
    Write-Host "dsh-update: installing @deepseek-ai/dsh@$latest..." -ForegroundColor Cyan
} else {
    Write-Host "dsh-update: updating @deepseek-ai/dsh $currentVersion -> $latest..." -ForegroundColor Cyan
}

& $npm install -g @deepseek-ai/dsh@latest 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Host "dsh-update: @deepseek-ai/dsh updated to $latest" -ForegroundColor Green
} else {
    Write-Host "dsh-update: update failed (npm exit $LASTEXITCODE)" -ForegroundColor Yellow
}
