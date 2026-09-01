param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root "mcp-data\runtime-inventory.json"
}
$candidates = @(
    @{ name = "Unsloth HIP/ROCm"; path = "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe"; backend = "HIP" }
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
