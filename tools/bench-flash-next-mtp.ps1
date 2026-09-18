#!/usr/bin/env pwsh
# MTP draft + Flash-Next target: VRAM placement sweep.
param(
    [string]$Server = "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe",
    [string]$Target = "C:\Users\dai86\.lmstudio\models\Qwen3.8-Flash-Next-Uncensored-IQ2_XXS-00001-of-00002.gguf",
    [string]$Draft  = "C:\Users\dai86\.lmstudio\models\Qwen3.8-Flash-Next-MTP-Q4_K_M.gguf",
    [int]$Port = 8080
)
$ErrorActionPreference = "Stop"
$env:GGML_ROCM_MAX_VRAM = "15360"
$env:PATH = "$(Split-Path $Server);$env:PATH"
$out = Join-Path $PSScriptRoot "flash-next-mtp-bench.json"

function Wait-Server([int]$timeoutSec = 120) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { return $true } } catch {}
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Stop-S { Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2 }

function Run-One([string]$label, [string[]]$extra) {
    Stop-S
    $log = "C:\Users\dai86\Downloads\llama-tq3\logs\mtp-$label.log"
    $args = @(
        "-m", $Target, "--host", "127.0.0.1", "--port", "$Port",
        "-c", "2048", "-np", "1", "-ctk", "q8_0", "-ctv", "q8_0", "-fa", "on",
        "--jinja", "--no-ui", "--lazy-mode", "on", "--reasoning", "off",
        "--cache-ram", "2048", "--prio", "2", "-t", "11", "-tb", "11"
    ) + $extra
    Write-Host ""
    Write-Host "=== $label ===" -ForegroundColor Cyan
    Write-Host ($args -join " ")
    $null = Start-Process -FilePath $Server -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    if (-not (Wait-Server 120)) {
        Write-Host "FAIL start" -ForegroundColor Red
        $tail = if (Test-Path "$log.err") { (Get-Content "$log.err" -Tail 12) -join " | " } else { "" }
        Write-Host $tail
        return [PSCustomObject]@{ label=$label; ok=$false; error=$tail; args=($extra -join " ") }
    }
    $warm = @{ prompt="Hi"; n_predict=4; temperature=0 } | ConvertTo-Json
    try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($warm)) -ContentType "application/json; charset=utf-8" -TimeoutSec 180 } catch { Write-Host "warm err" }
    $body = @{ prompt="The capital of France is"; n_predict=64; temperature=0 } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -TimeoutSec 300
    $ws = [math]::Round((Get-Process llama-server).WorkingSet64/1GB, 2)
    $tg = [math]::Round($r.timings.predicted_per_second, 2)
    $pp = [math]::Round($r.timings.prompt_per_second, 2)
    $draftN = if ($r.timings.draft_n) { $r.timings.draft_n } else { "n/a" }
    $acc = if ($r.timings.draft_n -and $r.timings.draft_n -gt 0) { [math]::Round(100*$r.timings.draft_accepted/$r.timings.draft_n,1) } else { "n/a" }
    Write-Host "tg=$tg pp=$pp WS=$ws draft=$draftN acc=$acc%" -ForegroundColor Green
    return [PSCustomObject]@{
        label=$label; ok=$true; tg=$tg; pp=$pp; ws_gb=$ws
        draft_n=$draftN; accept=$acc
        args=($extra -join " "); text=($r.content.Substring(0,[Math]::Min(60,$r.content.Length)))
    }
}

$results = @()
# 0) no MTP baseline for comparison (same as before best)
$results += Run-One "base_ncmoe4" @("-ngl","auto","--n-cpu-moe","4")
# 1) MTP, draft auto ngl, target ncmoe4
$results += Run-One "mtp_auto_ncmoe4" @("-ngl","auto","--n-cpu-moe","4","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","2","--spec-draft-n-min","1","-ngld","auto")
# 2) MTP draft fully GPU
$results += Run-One "mtp_draft_gpu" @("-ngl","auto","--n-cpu-moe","4","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","2","--spec-draft-n-min","1","-ngld","99")
# 3) MTP draft CPU
$results += Run-One "mtp_draft_cpu" @("-ngl","auto","--n-cpu-moe","4","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","2","--spec-draft-n-min","1","-ngld","0")
# 4) MTP + ncmoe0 (more experts GPU)
$results += Run-One "mtp_ncmoe0" @("-ngl","auto","--n-cpu-moe","0","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","2","--spec-draft-n-min","1","-ngld","99")
# 5) MTP + ncmoe10
$results += Run-One "mtp_ncmoe10" @("-ngl","auto","--n-cpu-moe","10","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","2","--spec-draft-n-min","1","-ngld","99")
# 6) MTP n_max 3
$results += Run-One "mtp_nmax3" @("-ngl","auto","--n-cpu-moe","4","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","3","--spec-draft-n-min","1","-ngld","99")
# 7) expert2 + MTP (less expert traffic)
$results += Run-One "mtp_expert2" @("-ngl","auto","--n-cpu-moe","4","--override-kv","llama.expert_used_count=int:2","-md",$Draft,"--spec-type","draft-mtp","--spec-draft-n-max","2","--spec-draft-n-min","1","-ngld","99")

Stop-S
$results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $out -Encoding UTF8
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Yellow
$results | ForEach-Object {
    if ($_.ok) { "{0,-18} tg={1,6} pp={2,6} WS={3,5} draft={4} acc={5}" -f $_.label, $_.tg, $_.pp, $_.ws_gb, $_.draft_n, $_.accept }
    else { "{0,-18} FAIL" -f $_.label }
}
