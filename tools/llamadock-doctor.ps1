param()
$root = Split-Path $PSScriptRoot -Parent
$checks = @(
    @{ Label="Profiles"; Path=(Join-Path $root "config\profiles.json") },
    @{ Label="Selector"; Path=(Join-Path $root "select-model.ps1") },
    @{ Label="MCP server"; Path=(Join-Path $root "mcp-server.js") },
    @{ Label="Computer launcher"; Path=(Join-Path $root "tools\computer-start.ps1") },
    @{ Label="Computer local connection"; Path=(Join-Path $root "tools\computer-configure-local.ps1") },
    @{ Label="Shared UTF-8 helper"; Path=(Join-Path $root "tools\llamadock-utf8.ps1") },
    @{ Label="UTF-8 client shell"; Path=(Join-Path $root "tools\llamadock-client-shell.ps1") },
    @{ Label="PowerShell UTF-8 smoke"; Path=(Join-Path $root "tools\utf8-powershell-smoke.ps1") },
    @{ Label="Python UTF-8 smoke"; Path=(Join-Path $root "tools\utf8-smoke.py") }
)
Write-Host "LlamaDock doctor" -ForegroundColor Cyan
foreach ($check in $checks) {
    $state = if (Test-Path $check.Path) { "OK" } else { "MISSING" }
    $color = if ($state -eq "OK") { "Green" } else { "Red" }
    Write-Host ("[{0}] {1}: {2}" -f $state, $check.Label, $check.Path) -ForegroundColor $color
}
try {
    $profiles = Get-Content (Join-Path $root "config\profiles.json") -Raw | ConvertFrom-Json
    Write-Host "[OK] Profile schema version: $($profiles.schema_version)" -ForegroundColor Green
    Write-Host "[OK] Docker policy: $($profiles.policy.docker)" -ForegroundColor Green
}
catch { Write-Host "[FAIL] profiles.json: $($_.Exception.Message)" -ForegroundColor Red }
try {
    node --check (Join-Path $root "mcp-server.js")
    if ($LASTEXITCODE -eq 0) { Write-Host "[OK] MCP JavaScript syntax" -ForegroundColor Green }
}
catch { Write-Host "[WARN] Node syntax check unavailable" -ForegroundColor Yellow }
try {
    $utf8Path = Join-Path $root "tools\llamadock-utf8.ps1"
    $utf8Source = Get-Content -LiteralPath $utf8Path -Raw -Encoding UTF8
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($utf8Source, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) { throw "PowerShell parse errors found" }
    foreach ($marker in @("ByteArrayContent", "application/json", "charset", "Set-LlamaDockUtf8Environment")) {
        if ($utf8Source -notmatch [regex]::Escape($marker)) { throw "missing UTF-8 marker: $marker" }
    }
    Write-Host "[OK] UTF-8 helper and transport markers" -ForegroundColor Green
}
catch { Write-Host "[FAIL] UTF-8 helper: $($_.Exception.Message)" -ForegroundColor Red }
