param(
    [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) "select-model.ps1")
)

$module = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1
if (-not $module) {
    Write-Host "PSScriptAnalyzer is not installed." -ForegroundColor Red
    Write-Host "Install it once with:" -ForegroundColor Yellow
    Write-Host "  Install-PackageProvider NuGet -Scope CurrentUser -Force"
    Write-Host "  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber"
    exit 1
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
# Read as UTF-8: on a Japanese-locale Windows PowerShell 5.1 the default (ANSI)
# read mis-decodes UTF-8 bytes and would corrupt non-ASCII comments on write.
$source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
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

$formatted = Invoke-Formatter -ScriptDefinition $source -Settings $settings
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Path, $formatted, $encoding)
Write-Host "Formatted $Path"
