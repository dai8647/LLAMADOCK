#!/usr/bin/env pwsh
# Round 2: refine n-cpu-moe and try ngram speculative (no draft model needed).
param(
    [string]$Server = "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe",
    [string]$Model = "C:\Users\dai86\.lmstudio\models\Qwen3.8-Flash-Next-Uncensored-IQ2_XXS-00001-of-00002.gguf",
    [int]$Port = 8080,
    [int]$NPredict = 64,
    [int]$Ctx = 2048
)
$ErrorActionPreference = "Stop"
$env:GGML_ROCM_MAX_VRAM = "15360"
$env:PATH = "$(Split-Path $Server);$env:PATH"
$outJson = Join-Path $PSScriptRoot "flash-next-bench-r2.json"

function Wait-Server([int]$port, [int]$timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $h = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($h.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Stop-Server {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}
function Invoke-Bench([string]$label, [string[]]$extraArgs) {
    Stop-Server
    $log = Join-Path $PSScriptRoot "..\logs\b2-$label.log"
    $args = @(
        "-m", $Model, "--host", "127.0.0.1", "--port", "$Port",
        "-c", "$Ctx", "-np", "1", "-ctk", "q8_0", "-ctv", "q8_0", "-fa", "on",
        "--jinja", "--no-ui", "--lazy-mode", "on", "--reasoning", "off",
        "--cache-ram", "2048", "--prio", "2", "-t", "11", "-tb", "11"
    ) + $extraArgs
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan
    $p = Start-Process -FilePath $Server -ArgumentList $args `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    if (-not (Wait-Server -port $Port -timeoutSec 100)) {
        Write-Host "FAIL" -ForegroundColor Red
        $tail = if (Test-Path "$log.err") { (Get-Content "$log.err" -Tail 5) -join " | " } else { "" }
        return [PSCustomObject]@{ label = $label; ok = $false; error = $tail }
    }
    $warm = @{ prompt = "Hi"; n_predict = 2; temperature = 0 } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post `
            -Body ([Text.Encoding]::UTF8.GetBytes($warm)) -ContentType "application/json; charset=utf-8" -TimeoutSec 120
    } catch {}
    $body = @{ prompt = "The capital of France is"; n_predict = $NPredict; temperature = 0 } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -TimeoutSec 300
    $ws = [math]::Round((Get-Process llama-server).WorkingSet64 / 1GB, 2)
    $tg = [math]::Round($r.timings.predicted_per_second, 2)
    $pp = [math]::Round($r.timings.prompt_per_second, 2)
    Write-Host "tg=$tg pp=$pp WS=$ws" -ForegroundColor Green
    return [PSCustomObject]@{ label = $label; ok = $true; tg = $tg; pp = $pp; ws_gb = $ws; args = ($extraArgs -join " ") }
}

$results = @()
foreach ($n in @(4, 6, 8, 10, 14, 16, 20)) {
    $results += Invoke-Bench "ncmoe$n" @("-ngl", "auto", "--n-cpu-moe", "$n")
}
# best was 12; try 12 with ngl explicit
$results += Invoke-Bench "ncmoe12_ngl32" @("-ngl", "32", "--n-cpu-moe", "12")
$results += Invoke-Bench "ncmoe12_ngl48" @("-ngl", "48", "--n-cpu-moe", "12")
# ngram speculative (self, no draft model)
$results += Invoke-Bench "ngram_mod" @("-ngl", "auto", "--n-cpu-moe", "12", "--spec-type", "ngram-mod")
$results += Invoke-Bench "ngram_simple" @("-ngl", "auto", "--n-cpu-moe", "12", "--spec-type", "ngram-simple")
$results += Invoke-Bench "ngram_cache" @("-ngl", "auto", "--n-cpu-moe", "12", "--spec-type", "ngram-cache")

Stop-Server
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outJson -Encoding UTF8
Write-Host ""
Write-Host "=== SUMMARY R2 ===" -ForegroundColor Yellow
$results | ForEach-Object {
    if ($_.ok) { "{0,-18} tg={1,6} pp={2,6} WS={3}  {4}" -f $_.label, $_.tg, $_.pp, $_.ws_gb, $_.args }
    else { "{0,-18} FAIL" -f $_.label }
}
