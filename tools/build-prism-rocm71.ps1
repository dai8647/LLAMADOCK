param(
    [string]$SourceRoot = "C:\Users\dai86\Downloads\prism-llama.cpp",
    [string]$BuildDir = "build-rocm71",
    [string]$RocmRoot = "C:\Program Files\AMD\ROCm\7.1",
    [string]$GpuTarget = "gfx1101",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

# build-prism-rocm71.ps1
# Builds the PrismML-Eng/llama.cpp fork (Ternary/Bonsai Q2_0_a128 support)
# with the same ROCm 7.1 HIP configuration LlamaDock uses for AtomicBot.
# Result: <SourceRoot>/build-rocm71/bin/llama-server.exe
# LlamaDock's select-model.ps1 picks this up automatically as the "PrismBonsai" engine.

if (-not (Test-Path $SourceRoot)) {
    Write-Error "PrismML-Eng/llama.cpp source not found: $SourceRoot"
    Write-Host "Clone it first:  git clone https://github.com/PrismML-Eng/llama.cpp.git `"$SourceRoot`""
    exit 1
}

$clang   = Join-Path $RocmRoot "bin\clang.exe"
$clangxx = Join-Path $RocmRoot "bin\clang++.exe"
$llvmRc  = Join-Path $RocmRoot "bin\llvm-rc.exe"
foreach ($t in @($clang, $clangxx, $llvmRc)) {
    if (-not (Test-Path $t)) { Write-Error "Missing ROCm tool: $t"; exit 1 }
}

$buildPath = Join-Path $SourceRoot $BuildDir
if ($Clean -and (Test-Path $buildPath)) {
    Write-Host "Removing existing build dir: $buildPath"
    Remove-Item -LiteralPath $buildPath -Recurse -Force
}

# HIP device libraries are found via HIP_PATH / ROCM_PATH, exactly like AtomicBot.
$env:HIP_PATH      = $RocmRoot
$env:ROCM_PATH     = $RocmRoot
$env:HIP_CLANG_PATH = Join-Path $RocmRoot "bin"
$env:PATH          = "$($env:HIP_CLANG_PATH);$env:PATH"

Write-Host "Configuring Prism llama.cpp HIP build ($GpuTarget)..."
$cfgArgs = @(
    "-S", $SourceRoot,
    "-B", $buildPath,
    "-G", "Ninja",
    "-DCMAKE_C_COMPILER=$clang",
    "-DCMAKE_CXX_COMPILER=$clangxx",
    "-DCMAKE_RC_COMPILER=$llvmRc",
    "-DCMAKE_PREFIX_PATH=$RocmRoot",
    "-Dhip_DIR=$(Join-Path $RocmRoot 'lib\cmake\hip')",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DGGML_HIP=ON",
    "-DAMDGPU_TARGETS=$GpuTarget",
    "-DGGML_HIP_GRAPHS=ON",
    "-DGGML_HIP_MMQ_MFMA=ON",
    "-DGGML_HIP_NO_VMM=ON",
    "-DGGML_HIP_RCCL=OFF",
    "-DGGML_OPENMP=ON"
)
& cmake @cfgArgs
if ($LASTEXITCODE -ne 0) { Write-Error "CMake configure failed"; exit $LASTEXITCODE }

Write-Host "Building llama-server (HIP)..."
& cmake --build $buildPath --target llama-server
if ($LASTEXITCODE -ne 0) { Write-Error "Build failed"; exit $LASTEXITCODE }

$server = Join-Path $buildPath "bin\llama-server.exe"
if (Test-Path $server) {
    Write-Host "OK: PrismBonsai llama-server built at $server" -ForegroundColor Green
    Write-Host "LlamaDock now auto-selects PrismBonsai for any Ternary/Bonsai GGUF."
}
else {
    Write-Error "Build reported success but llama-server.exe not found at $server"
    exit 1
}
