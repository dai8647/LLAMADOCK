param(
    [string]$InstallerPath = "C:\Users\dai86\Downloads\rocm-hip-sdk-7.1.1\AMD-Software-PRO-Edition-26.Q1-Win11-For-HIP.exe",
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Error "Run this script from an elevated PowerShell window."
}

if (-not (Test-Path $InstallerPath)) {
    Write-Error "Installer not found: $InstallerPath"
}

Write-Host "Installing AMD HIP SDK / ROCm 7.1.1..."
if (-not $SkipInstall) {
    $staleExtractPath = "C:\AMD\AMD-Software-Installer"
    if (Test-Path $staleExtractPath) {
        Write-Host "Removing stale AMD installer extraction folder..."
        Remove-Item -LiteralPath $staleExtractPath -Recurse -Force
    }

    Write-Host "Launching AMD installer GUI. Complete the install window, then this script will continue."
    $installProcess = Start-Process -FilePath $InstallerPath -PassThru -Wait
    Write-Host "Installer exit code: $($installProcess.ExitCode)"
}
else {
    Write-Host "Skipping installer launch."
}

$rocm71 = "C:\Program Files\AMD\ROCm\7.1"
if (-not (Test-Path $rocm71)) {
    Write-Warning "ROCm 7.1 folder was not found after install: $rocm71"
}

$hip64ProductCodes = @(
    "{1157FAF1-D29C-4729-8D48-525546330FE5}",
    "{49E039EE-70F6-4D07-8993-A93677F6326F}",
    "{5838FEB2-73F1-4434-987C-2C8B3939F232}",
    "{62C8EF2F-E90E-45C6-89C7-786AB7CF03C7}",
    "{8D3DD925-1DA8-457F-BEA5-7DDE41A9882F}",
    "{C77DFDDB-BB19-4EA4-B0F7-6BF89CD5F8FE}",
    "{FA78A764-BE06-48D4-9311-411BB0361AE4}"
)

Write-Host "Removing HIP SDK 6.4 MSI components if still registered..."
foreach ($productCode in $hip64ProductCodes) {
    $args = "/x $productCode /qn /norestart"
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -PassThru -Wait
    Write-Host "$productCode -> msiexec exit code $($p.ExitCode)"
}

$rocm64 = "C:\Program Files\AMD\ROCm\6.4"
if (Test-Path $rocm64) {
    $resolved = (Resolve-Path $rocm64).Path
    if ($resolved -ne $rocm64) {
        Write-Error "Resolved path mismatch. Refusing to delete: $resolved"
    }

    Write-Host "Deleting leftover ROCm 6.4 folder..."
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

Write-Host ""
Write-Host "Installed ROCm folders:"
Get-ChildItem "C:\Program Files\AMD\ROCm" -Directory -ErrorAction SilentlyContinue |
    Select-Object FullName, LastWriteTime |
    Format-Table -AutoSize
