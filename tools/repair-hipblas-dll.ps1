# repair-hipblas-dll.ps1
# ROCm 7.x Windows ships "libhipblas.dll" but ggml-hip.dll imports it by the
# short name "hipblas.dll" — without a copy, llama-server fails to load with
# no obvious error. Run this after updating ANY prebuilt engine root
# (TurboTan, AtomicBot, LongCat, DFlash2, ...).
#
# Usage:
#   powershell -File tools\repair-hipblas-dll.ps1                    # all known engine roots
#   powershell -File tools\repair-hipblas-dll.ps1 -Target <dir>      # one specific root

param(
    # Directory that contains (or should contain) llama-server.exe / *.dll
    [string]$Target = "",
    [string]$RocmRoot = "C:\Program Files\AMD\ROCm\7.1"
)

$ErrorActionPreference = "Stop"

$source = Join-Path $RocmRoot "bin\libhipblas.dll"
if (-not (Test-Path $source)) {
    Write-Error "Source DLL not found: $source (adjust -RocmRoot)"
}

$roots = @()
if ($Target) {
    $roots += $Target
}
else {
    # Same candidate roots select-model.ps1 resolves engines from, including
    # the home-dir HIP builds behind ExpertsLaguna/TurboTan (L126-137 there).
    # (llama.cpp-vulkan is intentionally absent: Vulkan builds never load
    # hipblas.dll. build-rocm71-deprecated is skipped on purpose too.)
    $roots = @(
        "C:\llama-tq3\build-rocm71-fa\bin",
        "C:\llama-tq3\build-rocm71-ffn\bin",
        "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-hip\bin",
        "C:\Users\dai86\llama-cpp-turboquant\build-hip\bin",
        "C:\Users\dai86\Downloads\llama-b10536-rocm",
        "C:\Users\dai86\Downloads\turbo-tan-llama.cpp-tq3-check\build-rocm71\bin",
        "C:\Users\dai86\Downloads\longcat-llama.cpp\build-rocm71\bin",
        "C:\Users\dai86\Downloads\llama-dflash2\build-rocm71\bin"
    ) | Where-Object { Test-Path $_ }
}

foreach ($root in $roots) {
    $dest = Join-Path $root "hipblas.dll"
    if (Test-Path $dest) {
        Write-Host "OK (already present): $dest"
        continue
    }
    Copy-Item $source $dest
    Write-Host "Copied libhipblas.dll -> $dest" -ForegroundColor Green
}
