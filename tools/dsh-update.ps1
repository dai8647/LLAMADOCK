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

# Check currently installed version
$installed = & $npm list -g @deepseek-ai/dsh --depth=0 2>&1 | Select-String "@deepseek-ai/dsh"
$currentVersion = ""
if ($installed -match "(@deepseek-ai/dsh@)([\d.]+)") {
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
