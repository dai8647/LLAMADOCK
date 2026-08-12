param(
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) "select-model.ps1")
)

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) {
    $errors | Format-List *
    exit 1
}
Write-Host "PowerShell syntax OK"

$module = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1
if (-not $module) {
    Write-Host "PSScriptAnalyzer is not installed, so formatter check cannot run." -ForegroundColor Red
    Write-Host "Install it once with:" -ForegroundColor Yellow
    Write-Host "  Install-PackageProvider NuGet -Scope CurrentUser -Force"
    Write-Host "  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber"
    exit 1
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$source = Get-Content -LiteralPath $Path -Raw
$settings = @{
    IncludeRules = @("PSPlaceOpenBrace", "PSPlaceCloseBrace", "PSUseConsistentIndentation")
    Rules = @{
        PSPlaceOpenBrace = @{
            Enable = $true
            OnSameLine = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace = @{
            Enable = $true
            NewLineAfter = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore = $false
        }
        PSUseConsistentIndentation = @{
            Enable = $true
            Kind = "space"
            PipelineIndentation = "IncreaseIndentationForFirstPipeline"
            IndentationSize = 4
        }
    }
}

$formatterSource = $source
$normalizedLineEndings = $false
try {
    $formatted = Invoke-Formatter -ScriptDefinition $formatterSource -Settings $settings
}
catch {
    if ($_.Exception.Message -notmatch "mixed line endings|determine line endings") {
        throw
    }
    # Do not rewrite the user's file just to make the formatter decide its
    # style. Compare a normalized copy in memory and preserve the worktree's
    # existing line-ending choices.
    $formatterSource = $source -replace "`r`n", "`n" -replace "`r", "`n"
    $normalizedLineEndings = $true
    $formatted = Invoke-Formatter -ScriptDefinition $formatterSource -Settings $settings
}
if ($formatterSource -ne $formatted) {
    Write-Host "Formatter check failed. Run tools\format.ps1 before committing." -ForegroundColor Red
    exit 1
}

if ($normalizedLineEndings) {
    Write-Host "Formatter check OK (line endings checked in memory)"
}
else {
    Write-Host "Formatter check OK"
}
exit 0
