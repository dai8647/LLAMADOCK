param(
    [Parameter(Mandatory=$true)][string]$ServerPath,
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [string]$ModelId = "bench-model",
    [string]$Backend = "unknown",
    [string]$KCache = "q8_0",
    [string]$VCache = "q8_0",
    [int]$Context = 16384,
    [string]$Offload = "auto",
    [int]$CacheRamMiB = 8192,
    [int]$Runs = 3,
    [int]$StartupTimeoutSeconds = 300,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (Test-Path -LiteralPath $utf8Helper) {
    . $utf8Helper
}
$env:PATH = "C:\Program Files\AMD\ROCm\7.1\bin;" + $env:PATH
$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $root "mcp-data\bench-results.jsonl" }
$logDir = Join-Path $root "logs\bench"
New-Item -ItemType Directory -Force -Path $logDir, (Split-Path -Parent $OutputPath) | Out-Null
$args = @("-m",$ModelPath,"-a",$ModelId,"--host","127.0.0.1","--port","8080","-ngl",$Offload,"-c",$Context,"-np","1","-ctk",$KCache,"-ctv",$VCache,"-fa","on","--cache-ram",$CacheRamMiB,"--jinja","--no-ui")
$outLog = Join-Path $logDir "$ModelId.out.log"
$errLog = Join-Path $logDir "$ModelId.err.log"
$started = Get-Date
$proc = Start-Process -FilePath $ServerPath -ArgumentList $args -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -WindowStyle Hidden
$ready = $false
for ($i=0; $i -lt ($StartupTimeoutSeconds * 2); $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $health = Invoke-WebRequest -Uri "http://127.0.0.1:8080/health" -UseBasicParsing -TimeoutSec 2
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:8080/v1/models" -TimeoutSec 3
        if ($health.StatusCode -eq 200 -and @($models.data | Where-Object { $_.id }).Count -gt 0) { $ready = $true; break }
    } catch {}
}
$startup = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
try {
    if (-not $ready) { throw "server did not become ready" }
    for ($run=1; $run -le $Runs; $run++) {
        $body = @{ model=$ModelId; messages=@(@{role="user";content="Reply with exactly OK."}); max_tokens=16; temperature=0; chat_template_kwargs=@{enable_thinking=$false} }
        $t0 = Get-Date
        $response = Invoke-LlamaDockJsonPost -Uri "http://127.0.0.1:8080/v1/chat/completions" -Body $body -TimeoutSec 120
        $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 3)
        $text = [string]$response.choices[0].message.content
        $timings = $response.timings
        $usage = $response.usage
        $row = [PSCustomObject]@{
            timestamp=(Get-Date).ToString("o")
            model=$ModelPath
            model_id=$ModelId
            backend=$Backend
            context=$Context
            k_cache=$KCache
            v_cache=$VCache
            offload=$Offload
            cache_ram_mib=$CacheRamMiB
            run=$run
            startup_seconds=$startup
            generation_seconds=$elapsed
            prompt_tokens=if($usage){$usage.prompt_tokens}else{0}
            completion_tokens=if($usage){$usage.completion_tokens}else{0}
            prompt_tokens_per_second=if($timings){$timings.prompt_per_second}else{0}
            completion_tokens_per_second=if($timings){$timings.predicted_per_second}else{0}
            text=$text
            status=if($text){"success"}else{"empty"}
        }
        ($row | ConvertTo-Json -Compress) | Add-Content -LiteralPath $OutputPath -Encoding UTF8
        Write-Output $row
    }
}
finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}
