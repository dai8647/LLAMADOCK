#!/usr/bin/env pwsh
# Sweep llama-server configs for Qwen3.8-Flash-Next on RX 7800 XT.
# Writes results to tools/flash-next-bench-results.json
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
$outJson = Join-Path $PSScriptRoot "flash-next-bench-results.json"

function Wait-Server([int]$port, [int]$timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $h = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
            if ($h.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-Server {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Invoke-Bench([string]$label, [string[]]$extraArgs) {
    Stop-Server
    $log = Join-Path $PSScriptRoot "..\logs\bench-$label.log"
    $args = @(
        "-m", $Model,
        "--host", "127.0.0.1", "--port", "$Port",
        "-c", "$Ctx", "-np", "1",
        "-ctk", "q8_0", "-ctv", "q8_0", "-fa", "on",
        "--jinja", "--no-ui", "--lazy-mode", "on",
        "--reasoning", "off",
        "--cache-ram", "2048",
        "--prio", "2"
    ) + $extraArgs
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan
    Write-Host ($args -join " ")
    $p = Start-Process -FilePath $Server -ArgumentList $args `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    if (-not (Wait-Server -port $Port -timeoutSec 120)) {
        Write-Host "FAILED to become ready" -ForegroundColor Red
        $errTail = if (Test-Path "$log.err") { (Get-Content "$log.err" -Tail 8) -join " | " } else { "no log" }
        return [PSCustomObject]@{ label = $label; ok = $false; error = $errTail; args = ($args -join " ") }
    }
    # warmup
    $warm = @{ prompt = "Hi"; n_predict = 2; temperature = 0 } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post `
            -Body ([Text.Encoding]::UTF8.GetBytes($warm)) -ContentType "application/json; charset=utf-8" -TimeoutSec 180
    } catch { Write-Host "warmup err: $($_.Exception.Message)" }
    $body = @{ prompt = "The capital of France is"; n_predict = $NPredict; temperature = 0 } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -TimeoutSec 300
    $proc = Get-Process llama-server -ErrorAction SilentlyContinue
    $ws = if ($proc) { [math]::Round($proc.WorkingSet64 / 1GB, 2) } else { 0 }
    $tg = [math]::Round($r.timings.predicted_per_second, 2)
    $pp = [math]::Round($r.timings.prompt_per_second, 2)
    Write-Host "tg=${tg} t/s  pp=${pp} t/s  WS=${ws} GB" -ForegroundColor Green
    return [PSCustomObject]@{
        label = $label
        ok = $true
        tg = $tg
        pp = $pp
        ws_gb = $ws
        predicted_n = $r.timings.predicted_n
        args = ($args -join " ")
    }
}

$results = @()
# Baseline-ish: threads default, no n-cpu-moe, ngl auto
$results += Invoke-Bench "A_ngl_auto_t6" @("-ngl", "auto", "-t", "6")
# more threads
$results += Invoke-Bench "B_ngl_auto_t11" @("-ngl", "auto", "-t", "11", "-tb", "11")
# MTP speculative
$results += Invoke-Bench "C_mtp_t11" @("-ngl", "auto", "-t", "11", "--spec-type", "draft-mtp", "--spec-draft-n-max", "2", "--spec-draft-n-min", "1", "-ngld", "auto")
# fewer experts used
$results += Invoke-Bench "D_expert4_t11" @("-ngl", "auto", "-t", "11", "--override-kv", "llama.expert_used_count=int:4")
# expert2
$results += Invoke-Bench "E_expert2_t11" @("-ngl", "auto", "-t", "11", "--override-kv", "llama.expert_used_count=int:2")
# n-cpu-moe 12 (deeper GPU MoE)
$results += Invoke-Bench "F_ncmoe12_t11" @("-ngl", "auto", "-t", "11", "--n-cpu-moe", "12")
# all MoE GPU attempt
$results += Invoke-Bench "G_ncmoe0_t11" @("-ngl", "auto", "-t", "11", "--n-cpu-moe", "0")
# MTP + expert4
$results += Invoke-Bench "H_mtp_expert4_t11" @("-ngl", "auto", "-t", "11", "--override-kv", "llama.expert_used_count=int:4", "--spec-type", "draft-mtp", "--spec-draft-n-max", "2", "--spec-draft-n-min", "1")
# cpu-moe all + mtp
$results += Invoke-Bench "I_cpu_moe_mtp_t11" @("-ngl", "auto", "-t", "11", "--cpu-moe", "--spec-type", "draft-mtp", "--spec-draft-n-max", "2", "--spec-draft-n-min", "1")

Stop-Server
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $outJson -Encoding UTF8
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Yellow
$results | ForEach-Object {
    if ($_.ok) { "{0,-22} tg={1,6} pp={2,6} WS={3} GB" -f $_.label, $_.tg, $_.pp, $_.ws_gb }
    else { "{0,-22} FAIL {1}" -f $_.label, $_.error }
}
Write-Host "Saved: $outJson"
