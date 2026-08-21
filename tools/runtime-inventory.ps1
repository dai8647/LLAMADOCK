param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root "mcp-data\runtime-inventory.json"
}
$candidates = @(
    @{ name = "AtomicBot HIP/ROCm"; path = "C:\llama-tq3\build-rocm71\bin\llama-server.exe"; backend = "HIP" },
    @{ name = "TurboTan HIP/ROCm"; path = "C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe"; backend = "HIP" },
    @{ name = "Official HIP"; path = "C:\llama.cpp-hip\llama-server.exe"; backend = "HIP" },
    @{ name = "Official Vulkan"; path = "C:\llama.cpp-vulkan\llama-server.exe"; backend = "Vulkan" },
    @{ name = "Official CPU"; path = "C:\llama.cpp-cpu\llama-server.exe"; backend = "CPU" }
)

$rows = foreach ($candidate in $candidates) {
    $exists = Test-Path -LiteralPath $candidate.path
    $hash = if ($exists) { (Get-FileHash -LiteralPath $candidate.path -Algorithm SHA256).Hash } else { "" }
    [PSCustomObject]@{
        name = $candidate.name
        backend = $candidate.backend
        path = $candidate.path
        available = $exists
        sha256 = $hash
        checked_at = (Get-Date).ToString("o")
    }
}

$dir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$rows | Format-Table name, backend, available, sha256 -AutoSize
Write-Host "Saved runtime inventory: $OutputPath" -ForegroundColor Cyan
