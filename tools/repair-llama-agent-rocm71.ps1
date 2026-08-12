param(
    [string]$LlamaAgentBin = "C:\Users\dai86\llama-agent\build\bin",
    [string]$RocmBin = "C:\Program Files\AMD\ROCm\7.1\bin"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $LlamaAgentBin)) {
    Write-Error "llama-agent bin folder not found: $LlamaAgentBin"
}
if (-not (Test-Path $RocmBin)) {
    Write-Error "ROCm bin folder not found: $RocmBin"
}

$agent = Join-Path $LlamaAgentBin "llama-agent.exe"
if (-not (Test-Path $agent)) {
    Write-Error "llama-agent.exe not found: $agent"
}

function Copy-CompatibleDll {
    param(
        [string]$Source,
        [string]$Destination
    )

    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        Write-Host "  [ok] $(Split-Path -Leaf $Destination)"
    }
    catch {
        if (Test-Path $Destination) {
            $srcHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
            if ($srcHash -eq $dstHash) {
                Write-Warning "Destination is in use, keeping existing compatible DLL: $Destination"
                return
            }
        }
        throw
    }
}

function Restore-Backup {
    param(
        [string]$BackupPath,
        [string]$TargetPath
    )

    if (-not (Test-Path $BackupPath)) {
        return
    }

    Write-Warning "Restoring llama-agent DLL backup: $BackupPath"
    Get-ChildItem -LiteralPath $BackupPath -File | ForEach-Object {
        $dst = Join-Path $TargetPath $_.Name
        try {
            Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
            Write-Warning "  restored $($_.Name)"
        }
        catch {
            Write-Warning "  failed to restore $($_.Name): $($_.Exception.Message)"
        }
    }
}

$backup = Join-Path $LlamaAgentBin ("backup-before-rocm71-compat-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $backup | Out-Null

foreach ($name in @(
    "amdhip64_6.dll",
    "hipblas.dll",
    "amd_comgr0701.dll",
    "amd_comgr_3.dll",
    "hiprtc0701.dll",
    "hiprtc-builtins0701.dll",
    "rocblas.dll",
    "rocsparse.dll",
    "hipsolver.dll",
    "rocsolver.dll"
)) {
    $existing = Join-Path $LlamaAgentBin $name
    if (Test-Path $existing) {
        Copy-Item -LiteralPath $existing -Destination (Join-Path $backup $name) -Force
    }
}

$copies = @{
    "amdhip64_7.dll" = "amdhip64_6.dll"
    "libhipblas.dll" = "hipblas.dll"
    "amd_comgr0701.dll" = "amd_comgr0701.dll"
    "amd_comgr_3.dll" = "amd_comgr_3.dll"
    "hiprtc0701.dll" = "hiprtc0701.dll"
    "hiprtc-builtins0701.dll" = "hiprtc-builtins0701.dll"
    "rocblas.dll" = "rocblas.dll"
    "rocsparse.dll" = "rocsparse.dll"
    "hipsolver.dll" = "hipsolver.dll"
    "rocsolver.dll" = "rocsolver.dll"
}

try {
    foreach ($entry in $copies.GetEnumerator()) {
        $src = Join-Path $RocmBin $entry.Key
        if (-not (Test-Path $src)) {
            Write-Warning "Missing ROCm DLL, skipping: $src"
            continue
        }

        Copy-CompatibleDll -Source $src -Destination (Join-Path $LlamaAgentBin $entry.Value)
    }

    $env:PATH = "$LlamaAgentBin;$RocmBin;" + $env:PATH
    $verifyOut = Join-Path $env:TEMP ("llama-agent-repair-help-" + [guid]::NewGuid().ToString("N") + ".log")
    $cmdLine = "`"$agent`" --help > `"$verifyOut`" 2>&1"
    & cmd.exe /c $cmdLine
    $verifyExit = $LASTEXITCODE
    Remove-Item -LiteralPath $verifyOut -Force -ErrorAction SilentlyContinue

    if ($verifyExit -ne 0) {
        throw "llama-agent still fails to start. Exit code: $verifyExit"
    }
}
catch {
    Restore-Backup -BackupPath $backup -TargetPath $LlamaAgentBin
    throw
}

Write-Host "llama-agent ROCm 7.1 compatibility OK"
Write-Host "Backup: $backup"
