#!/usr/bin/env pwsh
# Confirm top n-cpu-moe values with 3 runs each.
param(
    [string]$Server = "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe",
    [string]$Model = "C:\Users\dai86\.lmstudio\models\Qwen3.8-Flash-Next-Uncensored-IQ2_XXS-00001-of-00002.gguf",
    [int]$Port = 8080
)
$ErrorActionPreference = "Stop"
$env:GGML_ROCM_MAX_VRAM = "15360"
$env:PATH = "$(Split-Path $Server);$env:PATH"

function Wait-Server([int]$port, [int]$timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { return $true } } catch {}
        Start-Sleep -Milliseconds 400
    }
    return $false
}
function Stop-Server { Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 2 }

function Start-One([string]$label, [string[]]$extra) {
    Stop-Server
    $log = "C:\Users\dai86\Downloads\llama-tq3\logs\c-$label.log"
    $args = @("-m",$Model,"--host","127.0.0.1","--port","$Port","-c","2048","-np","1",
        "-ctk","q8_0","-ctv","q8_0","-fa","on","--jinja","--no-ui","--lazy-mode","on",
        "--reasoning","off","--cache-ram","2048","--prio","2","-t","11","-tb","11") + $extra
    $null = Start-Process -FilePath $Server -ArgumentList $args -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -NoNewWindow
    if (-not (Wait-Server -port $Port)) { return $null }
    $warm = @{ prompt="Hi"; n_predict=2; temperature=0 } | ConvertTo-Json
    try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($warm)) -ContentType "application/json; charset=utf-8" -TimeoutSec 120 } catch {}
    return $true
}

function Measure-One {
    $body = @{ prompt="The capital of France is"; n_predict=64; temperature=0 } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" -TimeoutSec 300
    return [PSCustomObject]@{ tg=[math]::Round($r.timings.predicted_per_second,2); pp=[math]::Round($r.timings.prompt_per_second,2); ws=[math]::Round((Get-Process llama-server).WorkingSet64/1GB,2) }
}

foreach ($ncmoe in @(4, 10, 12, 16)) {
    $label = "ncmoe$ncmoe"
    if (-not (Start-One $label @("-ngl","auto","--n-cpu-moe","$ncmoe"))) { Write-Host "$label start FAIL"; continue }
    $tgs = @(); $pps = @(); $ws = 0
    for ($i = 0; $i -lt 3; $i++) {
        $m = Measure-One
        $tgs += $m.tg; $pps += $m.pp; $ws = $m.ws
        Write-Host ("  {0} run{1}: tg={2} pp={3} WS={4}" -f $label, ($i+1), $m.tg, $m.pp, $m.ws)
    }
    $avg = [math]::Round((($tgs | Measure-Object -Average).Average), 2)
    Write-Host ("{0} AVG tg={1}  runs=[{2}]  WS={3}" -f $label, $avg, ($tgs -join ","), $ws) -ForegroundColor Yellow
}
Stop-Server
