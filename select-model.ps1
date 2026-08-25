# select-model.ps1 - LlamaDock local GGUF workspace launcher

param(
    [switch]$DryRun,
    [int]$ModelIndex = 0,
    [int]$ContextIndex = 0,
    [int]$KvIndex = 0,
    [int]$KCacheIndex = 0,
    [int]$VCacheIndex = 0,
    [int]$CacheRamMiB = -1,
    [ValidateSet("Prompt", "Manual", "ClineCoding", "OpenCodeCoding", "LlamaAgentResearch", "WebUIChat", "DeepSeekHarness")]
    [string]$PresetMode = "Prompt",
    [ValidateSet("Auto", "Light", "Standard", "Heavy")]
    [string]$ResearchMode = "Auto",
    [ValidateSet("Prompt", "Auto", "All", "CPU", "Custom")]
    [string]$OffloadMode = "Prompt",
    [string]$OffloadLayers = "",
    [string]$ChatTemplateKwargs = "",
    [ValidateSet("Prompt", "None", "Light")]
    [string]$McpMode = "Prompt",
    [ValidateSet("Prompt", "On", "Off")]
    [string]$FlashAttentionMode = "Prompt",
    [ValidateSet("Prompt", "Off", "MtpNextN", "DSpark", "DFlash2")]
    [string]$SpecMode = "Prompt",
    [ValidateSet("Prompt", "Auto", "2", "3", "4", "6", "8", "Custom")]
    [string]$MoeExpertsMode = "Prompt",
    [string]$MoeExpertsCount = "",
    # CPU MoE layers (--n-cpu-moe): Auto / 0-99 / Custom. Empty = interactive picker.
    [string]$CpuMoeMode = "",
    # Dense FFN CPU offload (--n-cpu-ffn N / --cpu-ffn). Empty = off (default).
    # "" = off, "all" = --cpu-ffn, digits = --n-cpu-ffn N. Requires a build with
    # PR ggml-org/llama.cpp#26622; probed at launch and refused otherwise.
    # Measured 2026-08-22: TG -65..-91% — for long-context VRAM freeing only.
    [string]$CpuFfnLayers = "",
    # Force an explicit GPU layer count instead of "auto" fitting. 0 = auto.
    # Auto places layers from FREE VRAM at launch time; a crowded desktop or
    # a just-stopped previous instance can silently degrade to CPU-heavy
    # placement (observed 2026-08-22: 132 s per Cline request).
    [int]$NglLayers = 0,
    # Skip the post-launch GPU offload speed probe.
    [switch]$SkipGpuProbe,
    # Opt-in: make the supervisor respawn llama-server after an unexpected
    # exit. Default OFF so a manually killed server stays stopped; the
    # supervisor then closes the gateway and exits cleanly instead of
    # backoff-respawning it up to the circuit-breaker limit.
    [switch]$AutoRestart,
    # Physical micro-batch for prompt processing (-ub). 1024/2048 can raise
    # prefill throughput on GPU-bound workloads at the cost of bigger compute
    # buffers (VRAM). 0 = llama.cpp default (512).
    [int]$Ubatch = 0,
    [ValidateSet("Prompt", "UseExisting", "StartNew", "Quit")]
    [string]$ExistingServerMode = "Prompt",
    [ValidateSet("Prompt", "WebUI", "Cline", "OpenCode", "LlamaAgent", "ComfyUI", "DeepSeekHarness")]
    [string]$ClientMode = "Prompt",
    [ValidateSet("Auto", "AtomicBot", "TurboTan", "OfficialVulkan", "OfficialHIP", "OfficialCPU", "ExpertsLaguna", "LongCat", "DFlash2")]
    [string]$EngineMode = "Auto",
    [switch]$SkipClineAuth,
    [switch]$SkipClineOpen,
    [switch]$SkipOpenBrowser,
    [string]$ComfyUIFlags = ""
)

$ErrorActionPreference = "Continue"
$utf8Helper = Join-Path $PSScriptRoot "tools\llamadock-utf8.ps1"
if (Test-Path -LiteralPath $utf8Helper) {
    . $utf8Helper
}

$AtomicBotServerPath = if ($env:LLAMA_TQ3_ATOMICBOT_SERVER) {
    $env:LLAMA_TQ3_ATOMICBOT_SERVER
}
# FA-fixed rebuild is the only supported on-disk candidate (2026-08-24).
# The old build-rocm71 was renamed to build-rocm71-deprecated: it shipped
# with FLASH_ATTN_EXT mostly unsupported (7831/22454 probes NOT SUPPORTED)
# and must not be silently picked up as a fallback. If this path is missing,
# rebuild with tools/build-atomicbot-rocm71-fa.ps1.
elseif (Test-Path "C:\llama-tq3\build-rocm71-fa\bin\llama-server.exe") {
    "C:\llama-tq3\build-rocm71-fa\bin\llama-server.exe"
}
else {
    # Report the expected FA-fixed path so the generic missing-engine check
    # below can print a useful message instead of failing on $null.
    "C:\llama-tq3\build-rocm71-fa\bin\llama-server.exe"
}

$TurboTanServerPath = if ($env:LLAMA_TQ3_TURBOTAN_SERVER) {
    $env:LLAMA_TQ3_TURBOTAN_SERVER
}
elseif (Test-Path "C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe") {
    "C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe"
}
elseif (Test-Path "C:\llama-tq3-turbotan\build\bin\llama-server.exe") {
    "C:\llama-tq3-turbotan\build\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe"
}
$ServerPath = $AtomicBotServerPath
$OfficialVulkanServerPath = if ($env:LLAMADOCK_OFFICIAL_VULKAN_SERVER) {
    $env:LLAMADOCK_OFFICIAL_VULKAN_SERVER
}
elseif (Test-Path "C:\llama.cpp-vulkan\llama-server.exe") {
    "C:\llama.cpp-vulkan\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\llama.cpp-vulkan\llama-server.exe"
}
$OfficialHIPServerPath = if ($env:LLAMADOCK_OFFICIAL_HIP_SERVER) {
    $env:LLAMADOCK_OFFICIAL_HIP_SERVER
}
elseif (Test-Path "C:\llama.cpp-hip\llama-server.exe") {
    "C:\llama.cpp-hip\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\llama.cpp-hip\llama-server.exe"
}
$OfficialCPUServerPath = if ($env:LLAMADOCK_OFFICIAL_CPU_SERVER) {
    $env:LLAMADOCK_OFFICIAL_CPU_SERVER
}
elseif (Test-Path "C:\llama.cpp-cpu\llama-server.exe") {
    "C:\llama.cpp-cpu\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\llama.cpp-cpu\llama-server.exe"
}
$ExpertsLagunaServerPath = if ($env:LLAMA_TQ3_EXPERTS_LAGUNA_SERVER) {
    $env:LLAMA_TQ3_EXPERTS_LAGUNA_SERVER
}
elseif (Test-Path "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-hip\bin\llama-server.exe") {
    "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-hip\bin\llama-server.exe"
}
elseif (Test-Path "C:\Users\dai86\llama-cpp-turboquant\build-hip\bin\llama-server.exe") {
    "C:\Users\dai86\llama-cpp-turboquant\build-hip\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\llama-cpp-turboquant\build-hip\bin\llama-server.exe"
}
# InquiringMinds-AI llama.cpp fork (longcat-flash-ngram branch) for
# LongCat-Flash / LongCat-Flash-Lite GGUF models (arch longcat-flash-ngram).
$LongCatServerPath = if ($env:LLAMA_TQ3_LONGCAT_SERVER) {
    $env:LLAMA_TQ3_LONGCAT_SERVER
}
elseif (Test-Path "C:\Users\dai86\Downloads\longcat-llama.cpp\build-rocm71\bin\llama-server.exe") {
    "C:\Users\dai86\Downloads\longcat-llama.cpp\build-rocm71\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\longcat-llama.cpp\build\bin\llama-server.exe"
}
# DFlash2 llama.cpp fork (z-lab/llama.cpp-fork dflash2 branch) for
# DFlash2 speculative decoding (grouped dynamic depthwise convolution).
# Built with ROCm 7.1 HIP for RX 7800 XT (gfx1101).
$DFlash2ServerPath = if ($env:LLAMA_TQ3_DFLASH2_SERVER) {
    $env:LLAMA_TQ3_DFLASH2_SERVER
}
elseif (Test-Path "C:\Users\dai86\Downloads\llama-dflash2\build-rocm71\bin\llama-server.exe") {
    "C:\Users\dai86\Downloads\llama-dflash2\build-rocm71\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\llama-dflash2\build-rocm71\bin\llama-server.exe"
}
$ModelsBase = if ($env:LLAMADOCK_MODELS_BASE) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_MODELS_BASE)
}
else {
    "C:\Users\dai86\.lmstudio\models"
}
$ComfyRoot = if ($env:LLAMADOCK_COMFY_ROOT) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_COMFY_ROOT)
}
else {
    "C:\Users\dai86\Documents\ComfyUI"
}
$ServerBaseUrl = "http://127.0.0.1:8080"
$GatewayPort = 8090
$GatewayBaseUrl = "http://127.0.0.1:$GatewayPort"
# Clients use the recovery gateway when a native server is managed by
# LlamaDock.  Existing unmanaged servers fall back to the direct endpoint.
$ClientBaseUrl = $GatewayBaseUrl
$OpenWebUIPort = 3000
$OpenWebUIUrl = "http://127.0.0.1:$OpenWebUIPort"
$ComputerPort = 8000
$ComputerUrl = "http://127.0.0.1:$ComputerPort"
$ModelNotesPath = Join-Path $PSScriptRoot "model-notes.json"
$RunResultsPath = Join-Path $PSScriptRoot "mcp-data\run-results.json"
$script:ClineDataDir = if ($env:LLAMADOCK_CLINE_DATA_DIR) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_CLINE_DATA_DIR)
}
else {
    Join-Path $PSScriptRoot "mcp-data\cline"
}
$LlamaAgentPath = if ($env:LLAMADOCK_LLAMA_AGENT_SERVER) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_LLAMA_AGENT_SERVER)
}
else {
    "C:\Users\dai86\llama-agent\build\bin\llama-agent.exe"
}
$LlamaAgentBinPath = Split-Path -Parent $LlamaAgentPath
$LlamaAgentResearchSystemPath = Join-Path $PSScriptRoot "llama-agent-research-system.txt"
$script:ResearchExtractionConcurrency = 2
$script:ResearchSearchResultCount = 5
$script:ResearchMaxTokens = 6144
$script:ResearchExtractionMaxTokens = 1536
$script:ResearchExtractionTimeoutSeconds = 60
$script:ResearchPlanningTimeoutSeconds = 60
$script:ResearchQueryTimeoutSeconds = 60
$script:ResearchRunTimeoutSeconds = 900

function Resolve-RocmBinPath {
    $rocmRoot = "C:\Program Files\AMD\ROCm"
    if (-not (Test-Path $rocmRoot)) {
        return $null
    }

    $rocmDir = Get-ChildItem $rocmRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object {
            try { [version]$_.Name }
            catch { [version]"0.0" }
        } -Descending |
        Select-Object -First 1

    if (-not $rocmDir) {
        return $null
    }

    $binPath = Join-Path $rocmDir.FullName "bin"
    if (Test-Path $binPath) {
        return $binPath
    }

    return $null
}

$script:RocmBinPath = Resolve-RocmBinPath
if ($script:RocmBinPath) {
    # Add ROCm to PATH for HIP DLLs used by thin launcher builds.
    $env:PATH = "$script:RocmBinPath;" + $env:PATH
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Show-LlamaDockBanner {
    Write-Host ""
    Write-Host "      __    __                         ____             __" -ForegroundColor Cyan
    Write-Host "     / /   / /___ _____ ___  ____ _   / __ \____  _____/ /__" -ForegroundColor Cyan
    Write-Host "    / /   / / __ ``/ __ ``__ \/ __ ``/  / / / / __ \/ ___/ //_/" -ForegroundColor Cyan
    Write-Host "   / /___/ / /_/ / / / / / / /_/ /  / /_/ / /_/ / /__/ ,<" -ForegroundColor Cyan
    Write-Host "  /_____/_/\__,_/_/ /_/ /_/\__,_/  /_____/\____/\___/_/|_|" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Local GGUF workspace launcher" -ForegroundColor Green
    Write-Host "  Coding / Chat / Agents / Research" -ForegroundColor DarkGray
    Write-Host ""
}

function Test-ServerReady {
    param(
        [string]$ExpectedModelId = ""
    )

    # /health can become 200 before llama-server has finished loading.  A
    # usable server must pass both the health and model-list checks.
    $healthOk = $false
    $modelsOk = $false
    try {
        $health = Invoke-WebRequest -Uri "$ServerBaseUrl/health" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $healthOk = ($health.StatusCode -eq 200)
    }
    catch {
        return $false
    }

    try {
        $models = Invoke-RestMethod -Uri "$ServerBaseUrl/v1/models" -TimeoutSec 5 -ErrorAction Stop
        $rows = @($models.data | Where-Object { $_.id })
        $modelsOk = $rows.Count -gt 0
        if ($modelsOk -and -not [string]::IsNullOrWhiteSpace($ExpectedModelId)) {
            $modelsOk = @($rows | Where-Object { [string]$_.id -eq $ExpectedModelId }).Count -gt 0
        }
    }
    catch {
        return $false
    }

    return ($healthOk -and $modelsOk)
}

function Test-GatewayReady {
    param(
        [string]$ExpectedModelId = ""
    )

    try {
        $health = Invoke-WebRequest -Uri "$GatewayBaseUrl/health" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        if ($health.StatusCode -ne 200) { return $false }
        $models = Invoke-RestMethod -Uri "$GatewayBaseUrl/v1/models" -TimeoutSec 5 -ErrorAction Stop
        $rows = @($models.data | Where-Object { $_.id })
        if ($rows.Count -eq 0) { return $false }
        if (-not [string]::IsNullOrWhiteSpace($ExpectedModelId)) {
            return @($rows | Where-Object { [string]$_.id -eq $ExpectedModelId }).Count -gt 0
        }
        return $true
    }
    catch {
        return $false
    }
}

function Set-ClientBaseUrl {
    param([string]$ExpectedModelId = "")

    if (Test-GatewayReady -ExpectedModelId $ExpectedModelId) {
        $script:ClientBaseUrl = $GatewayBaseUrl
        return $script:ClientBaseUrl
    }

    # Never fall back to the raw upstream (8080): clients must go through the
    # recovery gateway so the single llama-server slot stays protected.
    throw "Recovery gateway $GatewayBaseUrl is not ready (upstream 8080 not healthy). Start LlamaDock first and wait for the server to become ready before opening a client."
}

function Get-SystemRamGB {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
    }
    catch {
        return 0
    }
}

function Get-NvidiaGpuInfo {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        return @()
    }

    try {
        $rows = & $smi.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        $gpus = @()
        foreach ($row in $rows) {
            $parts = $row -split ","
            if ($parts.Count -ge 2) {
                $name = $parts[0].Trim()
                $mb = 0
                if ([int]::TryParse($parts[1].Trim(), [ref]$mb)) {
                    $gpus += [PSCustomObject]@{
                        Name = $name
                        VramGB = [math]::Round($mb / 1024, 1)
                        Source = "nvidia-smi"
                        Confidence = "high"
                    }
                }
            }
        }
        return $gpus
    }
    catch {
        return @()
    }
}

function Get-WindowsGpuInfo {
    try {
        $controllers = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name })
        $gpus = @()
        foreach ($gpu in $controllers) {
            $vramGB = 0
            $confidence = "low"
            if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) {
                $vramGB = [math]::Round([double]$gpu.AdapterRAM / 1GB, 1)
                $confidence = "medium"
                if ($vramGB -ge 4 -and $gpu.Name -notmatch "(?i)Intel|UHD|Iris") {
                    # Win32_VideoController often caps modern GPU VRAM near 4GB.
                    $vramGB = 0
                    $confidence = "low"
                }
            }
            $gpus += [PSCustomObject]@{
                Name = [string]$gpu.Name
                VramGB = $vramGB
                Source = "Win32_VideoController"
                Confidence = $confidence
            }
        }
        return $gpus
    }
    catch {
        return @()
    }
}

function Get-HardwareEstimate {
    $ramGB = Get-SystemRamGB
    $gpuInfo = @(Get-NvidiaGpuInfo)
    if ($gpuInfo.Count -eq 0) {
        $gpuInfo = @(Get-WindowsGpuInfo)
    }

    $primary = $gpuInfo | Sort-Object @{ Expression = "VramGB"; Descending = $true } | Select-Object -First 1
    return [PSCustomObject]@{
        RamGB = $ramGB
        Gpus = $gpuInfo
        PrimaryGpu = $primary
    }
}

function Get-VramRiskLabel {
    param(
        [double]$ModelSizeGB,
        [double]$VramGB,
        [string]$OffloadMode
    )

    if ($VramGB -le 0) {
        return "unknown VRAM; GPU offload warning is conservative"
    }
    if ($OffloadMode -eq "0") {
        return "CPU mode selected; VRAM use should be low but generation will be slower"
    }
    if ($ModelSizeGB -lt ($VramGB * 0.65)) {
        return "GPU offload likely OK"
    }
    if ($ModelSizeGB -lt $VramGB) {
        return "tight VRAM; context/KV may spill or reduce offload"
    }
    return "partial offload likely; expect CPU/RAM speed"
}

function Write-HardwareSummary {
    param([object]$Hardware)

    Write-Host "Hardware estimate:" -ForegroundColor Green
    if ($Hardware.RamGB -gt 0) {
        Write-Host (" RAM  {0}GB" -f $Hardware.RamGB) -ForegroundColor DarkGray
    }
    else {
        Write-Host " RAM  unknown" -ForegroundColor DarkGray
    }

    if ($Hardware.PrimaryGpu) {
        $vramText = if ($Hardware.PrimaryGpu.VramGB -gt 0) { "~$($Hardware.PrimaryGpu.VramGB)GB" } else { "unknown" }
        Write-Host (" GPU  {0}" -f $Hardware.PrimaryGpu.Name) -ForegroundColor DarkGray
        Write-Host (" VRAM {0} ({1}, {2} confidence)" -f $vramText, $Hardware.PrimaryGpu.Source, $Hardware.PrimaryGpu.Confidence) -ForegroundColor DarkGray
    }
    else {
        Write-Host " GPU  not detected" -ForegroundColor DarkGray
        Write-Host " VRAM unknown" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Write-RuntimeAvailability {
    param([array]$Runtimes)

    Write-Host "Runtime availability:" -ForegroundColor Green
    foreach ($runtime in $Runtimes) {
        $state = if (Test-Path $runtime.Path) { "found" } else { "not installed" }
        Write-Host (" {0,-15} {1}" -f $runtime.Name, $state) -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Get-RunResults {
    if (-not (Test-Path $RunResultsPath)) {
        return @()
    }

    try {
        $data = Get-Content -LiteralPath $RunResultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($data) { return @($data) }
    }
    catch {}
    return @()
}

function Save-RunResult {
    param(
        [object]$Model,
        [string]$Engine,
        [string]$Preset,
        [string]$Client,
        [int]$ContextTokens,
        [string]$KCache,
        [string]$VCache,
        [string]$Offload,
        [string]$FlashAttention,
        [int]$CacheRamMiB,
        [string]$Status,
        [string]$Message
    )

    $dir = Split-Path -Parent $RunResultsPath
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $results = @(Get-RunResults)
    $entry = [PSCustomObject]@{
        timestamp = (Get-Date).ToString("o")
        model_name = $Model.Name
        model_path = $Model.FullName
        model_size_mb = $Model.SizeMB
        engine = $Engine
        preset = $Preset
        client = $Client
        context_tokens = $ContextTokens
        k_cache = $KCache
        v_cache = $VCache
        offload = $Offload
        flash_attention = $FlashAttention
        cache_ram_mib = $CacheRamMiB
        status = $Status
        message = $Message
        ram_gb = $hardware.RamGB
        gpu = if ($hardware.PrimaryGpu) { $hardware.PrimaryGpu.Name } else { "" }
        vram_gb = if ($hardware.PrimaryGpu) { $hardware.PrimaryGpu.VramGB } else { 0 }
        vram_confidence = if ($hardware.PrimaryGpu) { $hardware.PrimaryGpu.Confidence } else { "unknown" }
    }

    $results = @($results + $entry | Select-Object -Last 200)
    Write-Utf8NoBom -Path $RunResultsPath -Value ($results | ConvertTo-Json -Depth 8)
}

function Show-LastRunResult {
    param([object]$Model)

    $last = @(Get-RunResults | Where-Object { $_.model_path -eq $Model.FullName } | Select-Object -Last 1)
    if ($last.Count -eq 0) {
        return
    }

    $r = $last[-1]
    Write-Host "Last run for this model:" -ForegroundColor Green
    Write-Host (" {0} / {1} / ctx={2} / K={3} / V={4} / {5}" -f $r.status, $r.engine, $r.context_tokens, $r.k_cache, $r.v_cache, $r.timestamp) -ForegroundColor DarkGray
    if ($r.message) {
        Write-Host (" {0}" -f $r.message) -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Get-ContextRiskLabel {
    param(
        [int]$Tokens,
        [double]$ModelSizeGB,
        [double]$RamGB
    )

    if ($RamGB -le 0) {
        return "unknown RAM"
    }

    $reserveGB = 10
    $availableForModelAndKv = [math]::Max(0, $RamGB - $reserveGB)
    $estimatedKvGB = [math]::Round(($Tokens / 32768.0) * [math]::Max(4, $ModelSizeGB * 0.22), 1)
    $estimatedTotalGB = [math]::Round($ModelSizeGB + $estimatedKvGB, 1)

    if ($estimatedTotalGB -lt ($availableForModelAndKv * 0.75)) {
        return "safe-ish, est ${estimatedTotalGB}GB"
    }
    if ($estimatedTotalGB -lt $availableForModelAndKv) {
        return "watch RAM, est ${estimatedTotalGB}GB"
    }
    return "risky, est ${estimatedTotalGB}GB"
}

function Test-ContextFitsRam {
    param(
        [int]$Tokens,
        [double]$ModelSizeGB,
        [double]$RamGB
    )

    if ($RamGB -le 0) {
        return $true
    }

    $reserveGB = 10
    $availableForModelAndKv = [math]::Max(0, $RamGB - $reserveGB)
    $estimatedKvGB = [math]::Round(($Tokens / 32768.0) * [math]::Max(4, $ModelSizeGB * 0.22), 1)
    $estimatedTotalGB = [math]::Round($ModelSizeGB + $estimatedKvGB, 1)
    return ($estimatedTotalGB -lt $availableForModelAndKv)
}

function Get-MaxContextTokensForRam {
    param(
        [double]$ModelSizeGB,
        [double]$RamGB
    )

    if ($RamGB -le 0) {
        return 131072
    }

    $reserveGB = 10
    $availableForKv = [math]::Max(0, $RamGB - $reserveGB - $ModelSizeGB)
    $kvPer32kGB = [math]::Max(4, $ModelSizeGB * 0.22)
    $maxTokens = [math]::Floor(($availableForKv / $kvPer32kGB) * 32768)

    if ($maxTokens -lt 16384) { return 8192 }
    if ($maxTokens -lt 32768) { return 16384 }
    if ($maxTokens -lt 65536) { return 32768 }
    if ($maxTokens -lt 131072) { return 65536 }
    if ($maxTokens -lt 262144) { return 131072 }
    return 262144
}

function Test-PortBusy {
    $conn = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    if ($conn) { return $true }

    $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Get-RequiredEngine {
    param([object]$Model)

    $modelText = "$($Model.Name) $($Model.FullName)"
    # DeepSeek-family GGUFs use the native experts-laguna fork. This includes
    # REAP and MXFP4 variants; do not let a TQ3 marker route them to TurboTan.
    if ($modelText -match "(?i)DeepSeek|ds4-compact|REAP[-_ ]?K128|Laguna") {
        return "ExpertsLaguna"
    }

    if ($modelText -match "(?i)TQ3_4S|TQ3") {
        return "TurboTan"
    }

    # LongCat-Flash / LongCat-Flash-Lite GGUF: needs InquiringMinds-AI longcat
    # fork (arch longcat-flash-ngram); mainline/AtomicBot cannot load these.
    if ($modelText -match "(?i)LongCat") {
        return "LongCat"
    }

    # DFlash2 checkpoints: needs the DFlash2 fork build (z-lab/llama.cpp-fork).
    # AtomicBot/TurboTan do not support the DFlash2 grouped-dynamic-convolution arch.
    if ($modelText -match "(?i)DFlash2") {
        return "DFlash2"
    }

    # Default non-special GGUFs use the AtomicBot TurboQuant runtime.
    return "AtomicBot"
}

function Get-ModelNote {
    param([object]$Model)

    if (-not (Test-Path $ModelNotesPath)) {
        return $null
    }

    try {
        $rules = Get-Content -LiteralPath $ModelNotesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Host "WARNING: Could not parse model-notes.json" -ForegroundColor Yellow
        return $null
    }

    $modelText = "$($Model.Name) $($Model.FullName)"
    foreach ($rule in @($rules)) {
        if ($rule.pattern -and $modelText -match $rule.pattern) {
            return $rule
        }
    }

    return $null
}

function Test-IsLlamaDockServerProcess {
    # Only kill processes that LlamaDock actually manages. A port can be owned
    # by an unrelated app (e.g. another llama-server the user started by hand,
    # or an entirely different service); blindly Stop-Process -Force on those
    # would be destructive. Command-line inspection mirrors the old port-owner pattern.
    param([int]$ProcessId)

    $procInfo = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $procInfo) { return $false }
    if ($procInfo.ProcessName -notmatch "^(llama-server|node|python|pythonw|powershell|pwsh)$") {
        return $false
    }
    try {
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $cimProc) { return $false }
        return ([string]$cimProc.CommandLine -match "llama-server|llamadock|server-supervisor|gateway|mcp-server")
    }
    catch {
        return $false
    }
}

function Stop-ServerOnPort {
    param([int]$Port = 8080)

    $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    $processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })

    if ($processIds.Count -eq 0) {
        return $true
    }

    Write-Host "Stopping existing server on port $Port..." -ForegroundColor Yellow
    foreach ($serverPid in $processIds) {
        try {
            $procInfo = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
            if ($procInfo) {
                if (-not (Test-IsLlamaDockServerProcess -ProcessId $serverPid)) {
                    Write-Host " Port $Port is used by PID $serverPid ($($procInfo.ProcessName)); not a LlamaDock server, leaving it running." -ForegroundColor Yellow
                    return $false
                }
                Write-Host " Stop PID $serverPid ($($procInfo.ProcessName))" -ForegroundColor Yellow
                Stop-Process -Id $serverPid -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Host "WARNING: Could not stop PID $serverPid" -ForegroundColor Yellow
        }
    }

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
            return $true
        }
    }

    Write-Host "ERROR: Port $Port is still in use. Not starting another server." -ForegroundColor Red
    return $false
}

function Stop-LlamaDockSupervisor {
    $controlDir = Join-Path $PSScriptRoot "mcp-data\server-supervisor"
    $pidPath = Join-Path $controlDir "supervisor.pid"
    $childPidPaths = @(
        (Join-Path $controlDir "server.pid"),
        (Join-Path $controlDir "gateway.pid")
    )
    if (-not (Test-Path -LiteralPath $pidPath)) { return $true }

    $supervisorPid = 0
    try { $supervisorPid = [int](Get-Content -LiteralPath $pidPath -Raw -ErrorAction Stop).Trim() }
    catch { return $true }
    if ($supervisorPid -le 0) { return $true }

    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $supervisorPid" -ErrorAction SilentlyContinue
    if (-not $processInfo -or [string]$processInfo.CommandLine -notmatch "llamadock-server-supervisor\.ps1") {
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
        # Supervisor is gone but its children (gateway/llama-server) may still
        # occupy the listen ports. Sweep them so the next LlamaDock launch can
        # rebind 8080/8090 cleanly instead of inheriting a ghost gateway that
        # only returns fetch-failed 502s.
        if (-not (Clear-LlamaDockGhostPorts -ChildPidPaths $childPidPaths)) {
            return $false
        }
        return $true
    }

    Write-Host "Stopping the existing LlamaDock server supervisor (PID $supervisorPid)..." -ForegroundColor Yellow
    Stop-Process -Id $supervisorPid -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Id $supervisorPid -ErrorAction SilentlyContinue)) {
            break
        }
    }
    foreach ($childPidPath in $childPidPaths) {
        if (-not (Test-Path -LiteralPath $childPidPath)) { continue }
        $childPid = 0
        try { $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw -ErrorAction Stop).Trim() }
        catch { continue }
        $childInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $childPid" -ErrorAction SilentlyContinue
        if ($childInfo -and [string]$childInfo.CommandLine -match "llamadock-proxy\.mjs|llama-server\.exe") {
            Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 1
    if (Get-Process -Id $supervisorPid -ErrorAction SilentlyContinue) {
        Write-Host "ERROR: LlamaDock server supervisor did not stop." -ForegroundColor Red
        return $false
    }
    # Windows PowerShell 5.1 binds -LiteralPath as a scalar here; passing the
    # parent path and child-path array together raises a conversion error after
    # the supervisor has already been stopped. Clean each marker explicitly.
    foreach ($cleanupPath in @($pidPath) + $childPidPaths) {
        Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# Sweep any orphaned LlamaDock server/gateway processes that still hold the
# 8080/8090 listen sockets after the supervisor has died. Returns $true when
# the bound ports are reusable (or were already clear), $false when a port is
# still occupied after the soft kill. This is the fallback path; when PID
# markers and the supervisor process are intact the normal Stop flow above is
# used unchanged.
function Clear-LlamaDockGhostPorts {
    param(
        [string[]]$ChildPidPaths = @()
    )

    $ports = @(8080, 8090)
    $candidatePids = New-Object System.Collections.Generic.List[int]
    foreach ($port in $ports) {
        $listener = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if (-not $listener) { continue }
        foreach ($owner in @($listener | Select-Object -ExpandProperty OwningProcess -Unique)) {
            if ($owner -and -not $candidatePids.Contains([int]$owner)) {
                $candidatePids.Add([int]$owner)
            }
        }
    }

    if ($candidatePids.Count -eq 0 -and $ChildPidPaths.Count -eq 0) {
        return $true
    }

    Write-Host "Cleaning orphaned LlamaDock server / gateway processes..." -ForegroundColor Yellow
    foreach ($childPidPath in $ChildPidPaths) {
        if (-not (Test-Path -LiteralPath $childPidPath)) { continue }
        $childPid = 0
        try { $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw -ErrorAction Stop).Trim() }
        catch { continue }
        if ($childPid -gt 0 -and -not $candidatePids.Contains($childPid)) {
            $candidatePids.Add($childPid)
        }
    }

    foreach ($procId in $candidatePids) {
        $procInfo = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $procInfo) { continue }
        if (-not (Test-IsLlamaDockServerProcess -ProcessId $procId)) {
            Write-Host " Skip PID $procId ($($procInfo.ProcessName)): not a LlamaDock server process." -ForegroundColor Yellow
            continue
        }
        try {
            Write-Host " Stop PID $procId ($($procInfo.ProcessName))" -ForegroundColor Yellow
            Stop-Process -Id $procId -Force -ErrorAction Stop
        }
        catch {
            Write-Host "WARNING: Could not stop PID $procId ($($procInfo.ProcessName)): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $stillBusy = $false
        foreach ($port in $ports) {
            if (Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
                $stillBusy = $true
                break
            }
        }
        if (-not $stillBusy) { break }
    }

    foreach ($port in $ports) {
        if (Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
            Write-Host "ERROR: Port $port is still in use after ghost sweep." -ForegroundColor Red
            return $false
        }
    }

    return $true
}

function Test-PortBusyAt {
    param([int]$Port)

    return [bool](Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Get-ExistingServerModel {
    try {
        $modelsResponse = Invoke-RestMethod -Uri "$ServerBaseUrl/v1/models" -TimeoutSec 3 -ErrorAction Stop
        if ($modelsResponse.data -and $modelsResponse.data.Count -gt 0 -and $modelsResponse.data[0].id) {
            return [string]$modelsResponse.data[0].id
        }
    }
    catch {}

    return ""
}

function ConvertTo-FormBody {
    param([hashtable]$Fields)

    $parts = @()
    foreach ($key in $Fields.Keys) {
        $value = [string]$Fields[$key]
        $parts += "{0}={1}" -f [uri]::EscapeDataString([string]$key), [uri]::EscapeDataString($value)
    }
    return ($parts -join "&")
}

function Set-ClineLocalModel {
    param([string]$ModelName)

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        Write-Host "WARNING: Could not read model name from /v1/models" -ForegroundColor Yellow
        Write-Host "Cline auth was not changed." -ForegroundColor Yellow
        return
    }

    if ($SkipClineAuth) {
        Write-Host "SKIP: Cline auth would use model $ModelName" -ForegroundColor Yellow
        Set-ClineLightweightTools
        Set-ClineLocalMcpConfig
        return
    }

    Write-Host "Configuring Cline CLI..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $script:ClineDataDir -Force | Out-Null
    cline auth --data-dir $script:ClineDataDir -p openai-compatible -k dummy -b "$ClientBaseUrl/v1" -m $ModelName -c $PSScriptRoot 2>&1 | Write-Host
    Set-ClineLightweightTools
    Set-ClineLocalMcpConfig
}

function Set-ClineLightweightTools {
    if ($env:LLAMADOCK_CLINE_FULL_TOOLS -eq "1") {
        Write-Host "Cline full tool catalog requested; keeping optional tools enabled." -ForegroundColor Yellow
        return
    }

    $settingsDir = Join-Path $script:ClineDataDir "settings"
    $settingsPath = Join-Path $settingsDir "global-settings.json"
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $loaded = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
        }
        catch {
            Write-Host "WARNING: Cline global settings could not be parsed; optional tools were not changed." -ForegroundColor Yellow
            return
        }
    }
    $disabled = @($settings["disabledTools"] | ForEach-Object { [string]$_ } | Where-Object { $_ })
    foreach ($tool in @("ask_question", "skills", "spawn_agent", "teams")) {
        if ($tool -notin $disabled) { $disabled += $tool }
    }
    $settings["disabledTools"] = @($disabled | Sort-Object -Unique)
    Write-Utf8NoBom -Path $settingsPath -Value ($settings | ConvertTo-Json -Depth 10)
    Write-Host "Cline lightweight mode: disabled optional skills/agent-team tools; core file, shell, editor, and web tools remain." -ForegroundColor Green
}

function Set-ClineLocalMcpConfig {
    $settingsDir = Join-Path $script:ClineDataDir "settings"
    $settingsPath = Join-Path $settingsDir "cline_mcp_settings.json"
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    if (Test-Path -LiteralPath $settingsPath) {
        $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
    }

    $servers = [ordered]@{}
    $mcpEntries = @(@{ Name = "web_search"; Port = 3100 })
    if ($env:LLAMADOCK_CLINE_MCP_ALL -eq "1") {
        $mcpEntries += @(
            @{ Name = "filesystem"; Port = 3101 },
            @{ Name = "memory"; Port = 3102 }
        )
    }
    foreach ($entry in $mcpEntries) {
        $servers[$entry.Name] = [ordered]@{
            transport = [ordered]@{
                type = "streamableHttp"
                url = "http://127.0.0.1:$($entry.Port)/mcp"
            }
        }
    }
    Write-Utf8NoBom -Path $settingsPath -Value (([ordered]@{ mcpServers = $servers }) | ConvertTo-Json -Depth 10)
    Write-Host "Cline MCP configured through isolated Streamable HTTP settings." -ForegroundColor Green
}

function Open-ClineClient {
    if ($SkipClineOpen) {
        Write-Host "SKIP: Cline would open" -ForegroundColor Yellow
        return
    }

    Write-Host "Opening Cline in PowerShell..." -ForegroundColor Cyan
    $clientShell = Join-Path $PSScriptRoot "tools\llamadock-client-shell.ps1"
    return Start-Process -FilePath "powershell.exe" -WorkingDirectory $PSScriptRoot -PassThru -ArgumentList @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", $clientShell,
        "-Client", "Cline",
        "-ModelName", $ModelName,
        "-BaseUrl", $ClientBaseUrl,
        "-DataDir", $script:ClineDataDir,
        "-Workspace", $PSScriptRoot
    )
}

function New-LocalOpenCodeConfig {
    param([string]$ModelName)

    $configDir = Join-Path $PSScriptRoot "mcp-data"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $configPath = Join-Path $configDir "opencode-local.json"
    $models = [ordered]@{}
    $models[$ModelName] = [ordered]@{
        name = $ModelName
    }

    $config = [ordered]@{
        '$schema' = "https://opencode.ai/config.json"
        model = "llamadock/$ModelName"
        default_agent = "coding"
        share = "disabled"
        shell = "pwsh"
        permission = [ordered]@{ edit = "allow"; bash = "ask"; webfetch = "ask" }
        tools = [ordered]@{ write = $true; edit = $true; bash = $true }
        agent = [ordered]@{
            coding = [ordered]@{
                description = "LlamaDock coding agent with user-approved shell operations"
                prompt = "Work on the local project. Explain changes, keep edits scoped, and ask before destructive shell commands."
                tools = [ordered]@{ write = $true; edit = $true; bash = $true }
            }
        }
        provider = [ordered]@{
            llamadock = [ordered]@{
                npm = "@ai-sdk/openai-compatible"
                name = "LlamaDock local"
                options = [ordered]@{
                    baseURL = "$ClientBaseUrl/v1"
                    apiKey = "not-needed"
                }
                models = $models
            }
        }
    }

    Write-Utf8NoBom -Path $configPath -Value ($config | ConvertTo-Json -Depth 10)
    return $configPath
}

function Open-OpenCodeClient {
    param([string]$ModelName)

    $configPath = New-LocalOpenCodeConfig -ModelName $ModelName
    $clientShell = Join-Path $PSScriptRoot "tools\llamadock-client-shell.ps1"

    Write-Host "Opening OpenCode in PowerShell..." -ForegroundColor Cyan
    $shellArgs = @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", $clientShell,
        "-Client", "OpenCode",
        "-ModelName", $ModelName,
        "-ConfigPath", $configPath,
        "-BaseUrl", $ClientBaseUrl,
        "-Workspace", $PSScriptRoot
    )
    return Start-Process -FilePath "powershell.exe" -PassThru -ArgumentList $shellArgs
}

function Open-LlamaAgentClient {
    param(
        [string]$ModelPath
    )

    if (-not (Test-Path $LlamaAgentPath)) {
        Write-Host "ERROR: llama-agent.exe was not found:" -ForegroundColor Red
        Write-Host $LlamaAgentPath -ForegroundColor Red
        return
    }

    $mcpServerScript = Join-Path $PSScriptRoot "mcp-server.js"
    $mcpServerModel = if (-not [string]::IsNullOrWhiteSpace($modelShort)) { $modelShort } else { "local-model" }
    # Escape any single quotes in path/string values that will be spliced
    # into the nested powershell.exe -Command string. The inner powershell
    # will re-expand $ModelPath/etc., so an unescaped single quote in a
    # filename would terminate the quoted string early and let following
    # characters be parsed as code (e.g. "evil'; rm -rf C:\'`).
    $safeModelPath = $ModelPath -replace "'", "''"
    $safeLlamaAgentPath = $LlamaAgentPath -replace "'", "''"
    $safeLlamaAgentResearchSystemPath = $LlamaAgentResearchSystemPath -replace "'", "''"
    $safeClientBaseUrl = $ClientBaseUrl -replace "'", "''"
    $safeModelShort = $modelShort -replace "'", "''"
    $safeMcpServerModel = $mcpServerModel -replace "'", "''"
    $safeMcpServerScript = $mcpServerScript -replace "'", "''"
    $safePSScriptRoot = $PSScriptRoot -replace "'", "''"
    $agentCommand = @"
Set-Location -LiteralPath '$safePSScriptRoot'
chcp 65001 | Out-Null
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$OutputEncoding = [System.Text.Encoding]::UTF8
if ('$script:RocmBinPath' -ne '') { `$env:PATH='$script:RocmBinPath;' + `$env:PATH }
`$env:PATH='$LlamaAgentBinPath;' + `$env:PATH

# --- Auto-start MCP Web Search server (port 3100) if not running ---
`$mcpPort = 3100
`$mcpRunning = `$false
try {
    `$conn = New-Object Net.Sockets.TcpClient
    `$iar = `$conn.BeginConnect('127.0.0.1', `$mcpPort, `$null, `$null)
    if (`$iar.AsyncWaitHandle.WaitOne(1000, `$false)) {
        `$conn.EndConnect(`$iar)
        `$conn.Close()
        `$mcpRunning = `$true
    } else {
        `$conn.Close()
    }
} catch {}
if (-not `$mcpRunning) {
    Write-Host "Starting MCP Web Search server on port `$mcpPort..." -ForegroundColor Yellow
    `$env:RESEARCH_LLM_BASE_URL = '$safeClientBaseUrl/v1'
    `$env:RESEARCH_LLM_MODEL = '$safeMcpServerModel'
    `$env:RESEARCH_MODE = 'standard'
    Start-Process -FilePath 'node.exe' -ArgumentList @('$safeMcpServerScript') -WindowStyle Hidden -PassThru | Out-Null
    Start-Sleep -Seconds 2
    try {
        `$check = New-Object Net.Sockets.TcpClient
        `$iar2 = `$check.BeginConnect('127.0.0.1', `$mcpPort, `$null, `$null)
        if (`$iar2.AsyncWaitHandle.WaitOne(3000, `$false)) {
            `$check.EndConnect(`$iar2)
            `$check.Close()
            Write-Host "MCP Web Search server ready." -ForegroundColor Green
        } else {
            `$check.Close()
            Write-Host "WARNING: MCP server may not have started." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "WARNING: Could not verify MCP server startup." -ForegroundColor Yellow
    }
} else {
    Write-Host "MCP Web Search server already running on port `$mcpPort." -ForegroundColor Green
}
# --- End MCP auto-start ---

& '$safeLlamaAgentPath' --help > `$null 2>&1
if (`$LASTEXITCODE -ne 0) {
    Write-Host "ERROR: llama-agent failed to start. Exit code: `$LASTEXITCODE" -ForegroundColor Red
    Write-Host "Check ROCm/HIP runtime DLLs under: $LlamaAgentBinPath" -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit `$LASTEXITCODE
}
`$researchQuery = Read-Host 'Deep research query (Enter for normal llama-agent)'
if (-not [string]::IsNullOrWhiteSpace(`$researchQuery)) {
    `$shareDir = Join-Path '$safePSScriptRoot' 'mcp-share'
    if (-not (Test-Path `$shareDir)) { New-Item -ItemType Directory -Path `$shareDir -Force | Out-Null }
    `$researchJson = Join-Path `$shareDir 'llama-agent-research-latest.json'
    `$promptFile = Join-Path `$shareDir 'llama-agent-research-prompt.txt'
    `$serverModel = ''
    try {
        `$models = Invoke-RestMethod -Uri '$safeClientBaseUrl/v1/models' -TimeoutSec 5 -ErrorAction Stop
        if (`$models.data -and `$models.data.Count -gt 0) { `$serverModel = [string]`$models.data[0].id }
    }
    catch {}
    if ([string]::IsNullOrWhiteSpace(`$serverModel)) { `$serverModel = '$safeModelShort' }
    Write-Host 'Research depth:' -ForegroundColor Green
    Write-Host ' [1] Light - lower local LLM load'
    Write-Host ' [2] Standard - balanced'
    Write-Host ' [3] Heavy - broader search'
    do {
        `$researchDepthInput = Read-Host 'Select research depth (1-3), or press Enter for Standard'
        if ([string]::IsNullOrWhiteSpace(`$researchDepthInput)) {
            `$researchDepthSelection = 2
            `$researchDepthValid = `$true
        }
        else {
            `$researchDepthSelection = 0
            `$researchDepthValid = [int]::TryParse(`$researchDepthInput, [ref]`$researchDepthSelection)
        }
    } while (-not `$researchDepthValid -or `$researchDepthSelection -lt 1 -or `$researchDepthSelection -gt 3)
    if (`$researchDepthSelection -eq 1) { `$researchDepth = 'light' }
    elseif (`$researchDepthSelection -eq 3) { `$researchDepth = 'heavy' }
    else { `$researchDepth = 'standard' }
    `$env:RESEARCH_MODE = `$researchDepth
    `$env:RESEARCH_LLM_BASE_URL = '$safeClientBaseUrl/v1'
    `$env:RESEARCH_LLM_MODEL = `$serverModel
    Remove-Item Env:\RESEARCH_PAGE_CHARS -ErrorAction SilentlyContinue
    Write-Host 'Running iterative deep research harness before llama-agent starts...' -ForegroundColor Cyan
    & node (Join-Path '$safePSScriptRoot' 'tools\deep-research-harness.mjs') `$researchQuery | Out-File -LiteralPath `$researchJson -Encoding utf8
    `$researchData = Get-Content -LiteralPath `$researchJson -Raw -Encoding UTF8
    `$hasEvidence = -not [string]::IsNullOrWhiteSpace(`$researchData) -and `$researchData -notmatch '"evidence":\s*\[\s*\]'
    if (`$hasEvidence) {
        `$prompt = @(
            'User research question:',
            `$researchQuery,
            '',
            'Pre-collected web research evidence:',
            `$researchData,
            '',
            'Instructions:',
            '- Answer in Japanese.',
            '- Use the evidence pack above as a starting point.',
            '- If the evidence pack is insufficient, use MCP tools (search_web, search_and_fetch, fetch_url) to search for more information.',
            '- Do NOT fabricate or infer facts. Only state facts supported by evidence.',
            '- Cite source URLs.',
            '- Keep the answer concise and practical.',
            '- Separate confirmed points from uncertain points.',
            '- Do not call update_plan.',
            '- Do not read skills or instruction files.',
            '- Do not stop after planning. Write the final answer directly.'
        ) -join [Environment]::NewLine
    }
    else {
        `$prompt = @(
            'User research question:',
            `$researchQuery,
            '',
            'No pre-collected evidence is available.',
            'Use MCP tools (search_web, search_and_fetch, fetch_url) to search the web and gather information.',
            'Search 3-8 times, collect sufficient information, then answer.',
            '',
            'Instructions:',
            '- Answer in Japanese.',
            '- Do NOT fabricate or infer facts. Only state facts supported by evidence.',
            '- Cite source URLs.',
            '- Keep the answer concise and practical.',
            '- Do not call update_plan.',
            '- Do not stop after planning. Write the final answer directly.'
        ) -join [Environment]::NewLine
    }
    `$prompt | Out-File -LiteralPath `$promptFile -Encoding utf8
    & '$safeLlamaAgentPath' --yolo --backend http --server-url '$safeClientBaseUrl' --reasoning off --max-iterations 8 --system-prompt-file '$safeLlamaAgentResearchSystemPath' -m '$safeModelPath' -f `$promptFile
    `$agentExit = `$LASTEXITCODE
}
else {
    & '$safeLlamaAgentPath' --yolo --backend http --server-url '$safeClientBaseUrl' --reasoning off --max-iterations 8 --system-prompt-file '$safeLlamaAgentResearchSystemPath' -m '$safeModelPath'
    `$agentExit = `$LASTEXITCODE
}
if (`$agentExit -ne 0) {
    Write-Host "ERROR: llama-agent exited with code `$agentExit" -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit `$agentExit
}
"@

    Write-Host "Opening llama-agent Deep Research..." -ForegroundColor Cyan
    return Start-Process -FilePath "powershell.exe" -PassThru -ArgumentList @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-Command", $agentCommand
    )
}

function Open-OpenWebUIClient {
    # WebUI mode now points to native Open WebUI Computer. The legacy Python
    # Open WebUI launcher remains available as a rollback path, but is no
    # longer the visible front door.
    $launcher = Join-Path $PSScriptRoot "tools\computer-start.ps1"
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-Host "ERROR: Computer launcher was not found: $launcher" -ForegroundColor Red
        return $null
    }

    # Avoid leaving a new -NoExit PowerShell wrapper behind when the Computer
    # service is already healthy.  The child launcher also reuses the service,
    # but it cannot remove the wrapper that started it.
    try {
        $existingComputerHealth = Invoke-WebRequest -Uri "$ComputerUrl/api/config" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($existingComputerHealth.StatusCode -eq 200) {
            Write-Host "Computer UI is already running on $ComputerUrl; reusing the existing instance." -ForegroundColor Green
            if ($SkipOpenBrowser) {
                Write-Host "SKIP: Browser would open $ComputerUrl" -ForegroundColor Yellow
            }
            else {
                Start-Process $ComputerUrl
            }
            return $null
        }
    }
    catch {
    }

    Write-Host "Starting native Open WebUI Computer on $ComputerUrl..." -ForegroundColor Cyan
    $computerArgs = @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", $launcher,
        "-Port", $ComputerPort,
        "-LlamaServerUrl", "$ClientBaseUrl/v1"
    )
    if ($SkipOpenBrowser) {
        # Forward this switch.  Without it the child opens a token URL and
        # the parent opens a second unauthenticated root URL.
        $computerArgs += "-SkipOpenBrowser"
    }
    $process = Start-Process -FilePath "powershell.exe" -PassThru -ArgumentList $computerArgs
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            $health = Invoke-WebRequest -Uri "$ComputerUrl/api/config" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($health.StatusCode -eq 200) {
                $ready = $true
                break
            }
        }
        catch {
        }
    }
    if (-not $ready) {
        Write-Host "WARNING: Computer did not become ready within 30s; opening the browser anyway." -ForegroundColor Yellow
    }
    if ($SkipOpenBrowser) {
        Write-Host "SKIP: Browser would open $ComputerUrl" -ForegroundColor Yellow
    }
    else {
        Start-Process $ComputerUrl
    }
    return $process
}

$script:ComfyProfileChoice = $null
$script:ComfyFlagsChoice = ""
$script:PlanModeChoice = $false
$script:PlanModelChoice = "Qwen3.5"
$script:StopAllOnExit = $false

function Get-ComfyUITritonVersion {
    # Returns the triton version installed in the ComfyUI venv, or $null.
    # comfy-kitchen's ROCm INT8 Triton kernels need triton >= 3.7; older HIP
    # builds (e.g. triton-windows 3.5.1) hard-crash ComfyUI when
    # --enable-triton-backend forces them on (missing libdevice.rint /
    # register allocation errors). Gates the `triton` profile accordingly.
    try {
        $comfyPython = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
        $v = & $comfyPython -c "import triton; print(triton.__version__)" 2>$null
        if ($v -match '^(\d+)\.(\d+)') {
            return [version]("$($Matches[1]).$($Matches[2])")
        }
    }
    catch {
    }
    return $null
}

function Get-TritonBackendFlags {
    # Returns @("--enable-triton-backend") only when the user opts in with
    # $env:LLAMADOCK_COMFY_TRITON=1 AND triton >= 3.7 is installed. Default off:
    # comfy-kitchen's ROCm INT8 Triton kernels still hard-crash ComfyUI on this
    # GPU even with triton 3.7.1 ("couldn't allocate input reg for constraint
    # 'r'" while loading the H3 text encoder; the standalone kernel test passes
    # but the real nvfp4/int8 path does not). The HIP backend is the working
    # path, so the `triton` and `super` profiles fall back to ck/default.
    if ($env:LLAMADOCK_COMFY_TRITON -ne "1") {
        Write-Host "WARNING: --enable-triton-backend omitted (triton 3.7.x still crashes ComfyUI on the H3 INT8 path on this GPU)." -ForegroundColor Yellow
        Write-Host "         Set LLAMADOCK_COMFY_TRITON=1 to force it on and test a newer build." -ForegroundColor Yellow
        return @()
    }
    $tritonVersion = Get-ComfyUITritonVersion
    if ($null -ne $tritonVersion -and $tritonVersion -ge [version]"3.7") {
        return @("--enable-triton-backend")
    }
    if ($null -ne $tritonVersion) {
        Write-Host ("WARNING: triton {0} is too old for comfy-kitchen's ROCm INT8 path (needs >= 3.7);" -f $tritonVersion) -ForegroundColor Yellow
        Write-Host "         --enable-triton-backend omitted (older HIP builds crash ComfyUI)." -ForegroundColor Yellow
    }
    else {
        Write-Host "WARNING: triton is not installed in the ComfyUI venv; --enable-triton-backend omitted." -ForegroundColor Yellow
    }
    return @()
}

function Get-ComfyUILaunchArgs {
    # Researched MiniMax H3 / ROCm tuning for the ComfyUI workspace. Sources and
    # the reasoning behind each profile live in docs/MiniMax-H3-Tuning.md.
    #
    # Precedence: -ComfyUIFlags parameter > $env:LLAMADOCK_COMFY_FLAGS >
    #             interactive picker (custom flags) > profile
    #             (env LLAMADOCK_COMFY_PROFILE > interactive picker > default).
    #
    # Profiles:
    #   default - reserve 1 GB VRAM for the OS/desktop and let DynamicVRAM fill
    #             the rest of the card. No --lowvram: it forces the text encoder
    #             onto the CPU and offloads the DiT unnecessarily.
    #   fast    - default + --fast fp16_accumulation --force-non-blocking. The
    #             flags are marked "untested / quality deteriorating" upstream;
    #             benchmark against default before adopting.
    #   triton  - default + --enable-triton-backend so comfy-kitchen can run its
    #             INT8 Triton kernels (the H3 DiT is int8). Only useful after
    #             installing triton into the ComfyUI venv; see comfyui-tune.ps1.
    #             Off by default: 3.7.x still crashes the H3 text encoder on this
    #             GPU, so the flag is only added with LLAMADOCK_COMFY_TRITON=1.
    #   super   - ck + triton combined. On this machine triton falls back to the
    #             HIP backend (opt-in with LLAMADOCK_COMFY_TRITON=1), so super ==
    #             ck + the working kernels; pair with h3_workflow_super.json
    #             (Turbo LoRA + ClipProj, 8 steps).
    #   ck      - default + --use-ck-attention (comfy-kitchen attention, needs
    #             ComfyUI >= 0.33.0). Works on ROCm/hip; big win for H3 DiT.
    #   bench   - no extras; pair with LLAMADOCK_COMFY_FLAGS for A/B runs.
    param([int]$Port = 8188)
    $base = @("main.py", "--port", "$Port", "--listen", "127.0.0.1")
    $profile = "default"
    if ($env:LLAMADOCK_COMFY_PROFILE) {
        $profile = $env:LLAMADOCK_COMFY_PROFILE
    }
    elseif ($script:ComfyProfileChoice) {
        $profile = $script:ComfyProfileChoice
    }
    switch ($profile.ToLowerInvariant()) {
        "fast" { $extra = @("--reserve-vram", "1.0", "--fast", "fp16_accumulation", "--force-non-blocking") }
        "triton" { $extra = @("--reserve-vram", "1.0") + (Get-TritonBackendFlags) }
        "super" { $extra = @("--reserve-vram", "1.0", "--use-ck-attention") + (Get-TritonBackendFlags) }
        "ck" { $extra = @("--reserve-vram", "1.0", "--use-ck-attention") }
        "bench" { $extra = @() }
        default { $extra = @("--reserve-vram", "1.0") }
    }
    $override = ""
    if (-not [string]::IsNullOrWhiteSpace($ComfyUIFlags)) {
        $override = $ComfyUIFlags
    }
    elseif ($env:LLAMADOCK_COMFY_FLAGS) {
        $override = $env:LLAMADOCK_COMFY_FLAGS
    }
    elseif (-not [string]::IsNullOrWhiteSpace($script:ComfyFlagsChoice)) {
        $override = $script:ComfyFlagsChoice
    }
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $extra = @($override -split "\s+" | Where-Object { $_ })
    }
    return @($base + $extra)
}

function Select-ComfyUITuning {
    # Interactive tuning picker for the ComfyUI workspace (MiniMax H3). Shown
    # only when ComfyUI is about to start and the flags were not pinned through
    # -ComfyUIFlags / LLAMADOCK_COMFY_FLAGS / LLAMADOCK_COMFY_PROFILE. Skipped
    # when stdin is redirected so scripted/bench launches keep working.
    # The menu is trimmed to 4 options (ck / plan / default / custom); the
    # super, fast, triton and bench profiles remain available for scripted use
    # via LLAMADOCK_COMFY_PROFILE (see Get-ComfyUILaunchArgs).
    if (-not [string]::IsNullOrWhiteSpace($ComfyUIFlags) -or $env:LLAMADOCK_COMFY_FLAGS -or $env:LLAMADOCK_COMFY_PROFILE) {
        return
    }
    if ([Console]::IsInputRedirected) {
        return
    }
    Write-Host ""
    Write-Host "ComfyUI tuning (MiniMax H3): フローはどれも同じ。変わるのは「生成速度」と「企画LLM」" -ForegroundColor Green
    Write-Host " [1] plan    - 高速化 + 企画LLMを自分で選ぶ【推奨】(Enter)"
    Write-Host " [2] ck      - 高速化 + 企画LLMは自動（CPU 4B・Qwen3.5）"
    Write-Host " [3] default - 高速化なし（互換・19分26秒）+ 企画LLMは自動（CPU 4B）"
    Write-Host " [4] custom  - 生のComfyUIフラグ + 企画LLMは自動（CPU 4B）"
    Write-Host " ※高速化(ck)=comfy-kitchen attention。画質そのまま生成が約11%速い（ComfyUI 0.33+）" -ForegroundColor DarkGray
    Write-Host ""
    do {
        $tuningInput = Read-Host "Select ComfyUI tuning (1-4), or press Enter for plan"
        $tuningValid = $true
        if ([string]::IsNullOrWhiteSpace($tuningInput)) {
            $script:ComfyProfileChoice = "ck"
            $script:PlanModeChoice = $true
            $script:PlanModelChoice = Select-PlanModel
        }
        else {
            switch ($tuningInput) {
                "1" {
                    $script:ComfyProfileChoice = "ck"
                    $script:PlanModeChoice = $true
                    $script:PlanModelChoice = Select-PlanModel
                }
                "2" { $script:ComfyProfileChoice = "ck"; $script:PlanModeChoice = $false }
                "3" { $script:ComfyProfileChoice = "default"; $script:PlanModeChoice = $false }
                "4" {
                    $rawFlags = Read-Host "Raw ComfyUI flags (e.g. --reserve-vram 0.5 --force-non-blocking)"
                    $script:ComfyProfileChoice = "custom"
                    $script:ComfyFlagsChoice = $rawFlags
                    $script:PlanModeChoice = $false
                }
                default { $tuningValid = $false }
            }
        }
    } while (-not $tuningValid)
}

function Get-PlanModelCandidates {
    # .lmstudio\models を再帰スキャンして、企画 LLM として使えそうな GGUF を
    # 自動検出する。mmproj（視覚プロジェクタ）と分割ファイル（-of-）は
    # 本体モデルではないので除外。ファイル名のパラメータ数（13B 以上）または
    # サイズ（6GB 超）で GPU 候補と判定し、同ディレクトリの mmproj を自動ペアリング。
    $scanRoot = "C:\Users\dai86\.lmstudio\models"
    if (-not (Test-Path -LiteralPath $scanRoot)) { return @() }
    $files = Get-ChildItem -Path $scanRoot -Filter "*.gguf" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notmatch "(?i)mmproj" -and
            $_.Name -notmatch "-of-" -and
            $_.Name -notmatch "(?i)DSpark" -and
            $_.Name -notmatch "(?i)DFlash2"
        }
    $list = @()
    foreach ($f in $files) {
        $gpu = $false
        if ($f.Name -match "(?i)(\d+)\s*B" -and [int]$Matches[1] -ge 13) { $gpu = $true }
        elseif ($f.Length -gt 6GB) { $gpu = $true }
        # 同ディレクトリの mmproj を視覚用として自動ペアリング
        $mmproj = Get-ChildItem -LiteralPath $f.DirectoryName -Filter "mmproj*.gguf" -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        # ラベル: LM Studio の models\<org>\<model-name>\ 構成からモデル名を拾う
        $label = $f.Directory.Name
        if ($label -match "^[A-Za-z0-9._-]+$" -and $f.Directory.Parent -and $f.Directory.Parent.Name -ne "models") {
            $label = "$($f.Directory.Parent.Name)/$label"
        }
        if ($label.Length -gt 44) { $label = $label.Substring(0, 44) + "…" }
        $list += [PSCustomObject]@{
            Path   = $f.FullName
            Mmproj = if ($mmproj) { $mmproj.FullName } else { $null }
            Gpu    = $gpu
            SizeGB = [math]::Round($f.Length / 1GB, 1)
            Label  = $label
        }
    }
    # CPU 候補（小さい順）→ GPU 候補（小さい順）、自動検出は最大8件
    return @($list | Sort-Object { $_.Gpu }, { $_.SizeGB } | Select-Object -First 8)
}

function Get-PlanModelMenu {
    # Planning LLM メニューの実エントリ一覧。既知モデル（特別な起動キーを持つ
    # もの）はファイルが実在するときだけ先頭に並べ、削除済みモデルがメニューに
    # 残り続けることがないようにする。残りはディスク走査（Get-PlanModelCandidates）
    # からの自動検出分。返却トークン契約:
    #   Qwen3.5 / Qwen3.8-27B-GPU / Qwen3.8-27B-GPU-Vision /
    #   Qwen3.8-27B-Heretic-Vision / Custom (+ $script:PlanModelCustom)
    $known = @(
        @{
            Key  = "Qwen3.5"
            Path = "C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica.i1-Q6_K.gguf"
            Gpu  = $false
        },
        @{
            Key  = "Qwen3.8-27B-GPU"
            Path = "C:\Users\dai86\.lmstudio\models\finex666\Qwen3.8-27B-Abliterated-IQ4-MIX-MTP-GGUF\Qwen3.8-27B-Abliterated-IQ4-MIX-MTP.gguf"
            Gpu  = $true
        },
        @{
            Key  = "Qwen3.8-27B-GPU-Vision"
            Path = "C:\Users\dai86\.lmstudio\models\lemonyins\Qwen3.8-27B-ULTIMATE-UNCENSORED-MTP-IQ4-GGUF-16GB\Qwen3.8-27B-ULTIMATE-UNCENSORED-MTP-IQ4-16GB.gguf"
            Gpu  = $true
        },
        @{
            Key  = "Qwen3.8-27B-Heretic-Vision"
            Path = "C:\Users\dai86\.lmstudio\models\mradermacher\Qwen3.8-27B-heretic-ara-i1-GGUF\Qwen3.8-27B-heretic-ara.i1-Q4_K_S.gguf"
            Gpu  = $true
        }
    )
    $descByKey = @{
        "Qwen3.5"                    = "Qwen3.5-4B - CPU・常駐・視覚対応（既定）"
        "Qwen3.8-27B-GPU"            = "Qwen3.8-27B - GPU・企画フェーズのみ・高品質（視覚なし）"
        "Qwen3.8-27B-GPU-Vision"     = "Qwen3.8-27B Vision - GPU・企画フェーズのみ・視覚 + KV q8/q4"
        "Qwen3.8-27B-Heretic-Vision" = "Qwen3.8-27B heretic-ara - GPU・企画フェーズのみ・視覚あり"
    }

    $menu = @()
    foreach ($k in $known) {
        if (-not (Test-Path -LiteralPath $k.Path)) { continue } # deleted models vanish
        $mmproj = Get-ChildItem -LiteralPath (Split-Path -Parent $k.Path) -Filter "mmproj*.gguf" -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $menu += [PSCustomObject]@{
            Key    = $k.Key
            Path   = $k.Path
            Mmproj = if ($mmproj) { $mmproj.FullName } else { $null }
            Gpu    = $k.Gpu
            SizeGB = [math]::Round((Get-Item -LiteralPath $k.Path).Length / 1GB, 1)
            Label  = $descByKey[$k.Key]
        }
    }
    $knownPaths = @($menu | ForEach-Object { $_.Path.ToLowerInvariant() })
    foreach ($c in Get-PlanModelCandidates) {
        if ($knownPaths -contains $c.Path.ToLowerInvariant()) { continue }
        $menu += [PSCustomObject]@{
            Key    = $null
            Path   = $c.Path
            Mmproj = $c.Mmproj
            Gpu    = $c.Gpu
            SizeGB = $c.SizeGB
            Label  = $c.Label
        }
    }
    return ,$menu
}

function Select-PlanModel {
    # Pick the planning LLM for plan mode. Qwen3.5-4B runs on CPU and stays
    # resident (VRAM stays free, has vision). GPU models run during the
    # planning phase only and are killed before every generation so the video
    # model gets the VRAM back. The menu lists only files that actually exist:
    # known models with dedicated launch keys first, then auto-detected GGUFs
    # from .lmstudio\models (Get-PlanModelMenu).
    $menu = Get-PlanModelMenu
    Write-Host ""
    Write-Host "Planning LLM:" -ForegroundColor Green
    if ($menu.Count -eq 0) {
        Write-Host " (GGUF モデルが見つかりません。既定の Qwen3.5 を使用します)" -ForegroundColor Yellow
        return "Qwen3.5"
    }
    $idx = 1
    $defaultIdx = 1
    foreach ($e in $menu) {
        if ($e.Key) {
            Write-Host (" [{0}] {1}" -f $idx, $e.Label)
            if ($e.Key -eq "Qwen3.5") { $defaultIdx = $idx }
        }
        else {
            $tag = if ($e.Gpu) { "GPU" } else { "CPU" }
            $vis = if ($e.Mmproj) { "視覚あり" } else { "視覚なし" }
            Write-Host (" [{0}] {1} ({2}・{3}・{4}GB)" -f $idx, $e.Label, $tag, $vis, $e.SizeGB)
        }
        $idx++
    }
    Write-Host ""
    $max = $menu.Count
    do {
        $planInput = Read-Host "Select planning LLM (1-$max), or press Enter for the default"
        $n = 0
        if ([string]::IsNullOrWhiteSpace($planInput)) {
            $n = $defaultIdx
        }
        elseif (-not [int]::TryParse($planInput, [ref]$n) -or $n -lt 1 -or $n -gt $max) {
            continue
        }
        $chosen = $menu[$n - 1]
        if ($chosen.Key) {
            return $chosen.Key
        }
        $script:PlanModelCustom = @{
            Path   = $chosen.Path
            Mmproj = $chosen.Mmproj
            Gpu    = $chosen.Gpu
            Label  = $chosen.Label
        }
        return "Custom"
    } while ($true)
}

function Start-H3Chat {
    # Starts the text-to-video chat UI (tools\h3-chat.py, port 8189) if it is
    # not already running, then opens it in the default browser. This is what
    # the user actually wants to see: a text box, not the ComfyUI node graph.
    # With plan mode ([1] plan in the tuning menu, or Enter) it delegates to
    # h3-chat.ps1,
    # which also starts the planning LLM (llama-server, CPU-only) so the
    # conversation-to-video flow works out of the box.
    param([switch]$SkipOpenBrowser)
    $chatUrl = "http://127.0.0.1:8189"
    $chatPy = Join-Path $PSScriptRoot "tools\h3-chat.py"
    if ($script:PlanModeChoice) {
        $h3chatPs1 = Join-Path $PSScriptRoot "tools\h3-chat.ps1"
        if (Test-Path -LiteralPath $h3chatPs1) {
            # Double-launch guard: if the chat UI (and, for the resident CPU
            # planner, the planning LLM) is already up there is nothing to
            # start, just open the browser. The GPU planner is started on
            # demand by h3-chat.py, so only the chat UI is checked for it.
            $chatUpNow = $false
            $planUpNow = $false
            try {
                $h = Invoke-WebRequest -Uri "$chatUrl/api/queue" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                if ($h.StatusCode -eq 200) { $chatUpNow = $true }
            }
            catch { }
            if ($script:PlanModelChoice -eq "Qwen3.8-27B-GPU" -or
                $script:PlanModelChoice -eq "Qwen3.8-27B-GPU-Vision" -or
                $script:PlanModelChoice -eq "Qwen3.8-27B-Heretic-Vision" -or
                ($script:PlanModelChoice -eq "Custom" -and $script:PlanModelCustom -and $script:PlanModelCustom.Gpu)) {
                $planUpNow = $true
            }
            else {
                try {
                    $h = Invoke-WebRequest -Uri "http://127.0.0.1:8190/v1/models" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                    if ($h.StatusCode -eq 200) { $planUpNow = $true }
                }
                catch { }
            }
            if (-not ($chatUpNow -and $planUpNow)) {
                # 企画 LLM のエンジン: GPU プランナーは AtomicBot（h3-chat.py が PLAN_SERVER_BIN で起動）、
                # CPU プランナーは openPangu ネイティブ CPU ビルド（h3-chat.ps1 が選択）。
                $planEngineHint = if ($script:PlanModelChoice -eq "Qwen3.8-27B-GPU" -or $script:PlanModelChoice -eq "Qwen3.8-27B-GPU-Vision" -or $script:PlanModelChoice -eq "Qwen3.8-27B-Heretic-Vision" -or ($script:PlanModelChoice -eq "Custom" -and $script:PlanModelCustom -and $script:PlanModelCustom.Gpu)) { "AtomicBot (ROCm 7.1 HIP)" } else { "openPangu (native CPU)" }
                Write-Host "Planning mode: starting the planning LLM (h3-chat.ps1, engine: $planEngineHint)..." -ForegroundColor Cyan
                # 自動検出モデル（Custom）は環境変数でパスを渡す。Start-Process の
                # 子プロセスは現在の環境を継承するため、ここで設定すれば届く。
                if ($script:PlanModelChoice -eq "Custom" -and $script:PlanModelCustom) {
                    $env:LLAMADOCK_PLAN_MODEL = $script:PlanModelCustom.Path
                    $env:LLAMADOCK_PLAN_MMPROJ = if ($script:PlanModelCustom.Mmproj) { $script:PlanModelCustom.Mmproj } else { "" }
                    if ($script:PlanModelCustom.Gpu) { $env:LLAMADOCK_PLAN_GPU = "1" } else { $env:LLAMADOCK_PLAN_GPU = "" }
                    Write-Host ("  custom planner: {0} ({1})" -f $script:PlanModelCustom.Label, $(if ($script:PlanModelCustom.Gpu) { "GPU" } else { "CPU" })) -ForegroundColor Cyan
                }
                Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $h3chatPs1 -PlanModel $script:PlanModelChoice -NoBrowser" -WindowStyle Hidden
            }
            else {
                Write-Host "h3-chat and planning LLM are already running; opening the UI." -ForegroundColor Green
            }
            # Wait for the chat UI (and, behind it, the planning LLM) to come
            # up before opening the browser, so the user lands on a live page.
            $chatReady = $false
            for ($i = 0; $i -lt 45; $i++) {
                Start-Sleep -Seconds 2
                try {
                    $h = Invoke-WebRequest -Uri "$chatUrl/api/queue" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                    if ($h.StatusCode -eq 200) { $chatReady = $true; break }
                }
                catch { }
            }
            if (-not $chatReady) {
                Write-Host "WARNING: h3-chat UI did not become ready; check tools\h3-chat.ps1." -ForegroundColor Yellow
            }
            if ($SkipOpenBrowser) {
                Write-Host "SKIP: Browser would open the h3-chat UI at $chatUrl (planning mode)" -ForegroundColor Yellow
            }
            else {
                Write-Host "h3-chat UI: $chatUrl (planning mode)  (ComfyUI graph: http://127.0.0.1:8188)" -ForegroundColor Cyan
                Start-Process $chatUrl
            }
            return
        }
        Write-Host "WARNING: tools\h3-chat.ps1 not found; starting chat UI without plan mode." -ForegroundColor Yellow
    }
    $chatUp = $false
    try {
        $h = Invoke-WebRequest -Uri "$chatUrl/api/queue" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($h.StatusCode -eq 200) { $chatUp = $true }
    }
    catch { }
    if (-not $chatUp -and (Test-Path -LiteralPath $chatPy)) {
        $comfyRoot = $ComfyRoot
        $comfyPython = Join-Path $comfyRoot ".venv\Scripts\python.exe"
        if (Test-Path -LiteralPath $comfyPython) {
            Write-Host "Starting h3-chat UI on $chatUrl ..." -ForegroundColor Cyan
            Start-Process -FilePath $comfyPython -ArgumentList $chatPy -WindowStyle Hidden
            Start-Sleep -Seconds 2
        }
    }
    if ($SkipOpenBrowser) {
        Write-Host "SKIP: Browser would open the h3-chat UI at $chatUrl" -ForegroundColor Yellow
    }
    else {
        Write-Host "h3-chat UI: $chatUrl  (ComfyUI graph: http://127.0.0.1:8188)" -ForegroundColor Cyan
        Start-Process $chatUrl
    }
}

function Open-ComfyUIClient {
    # ComfyUI workspace: local ComfyUI server for MiniMax H3 video/audio gen.
    # Runs from Documents\ComfyUI (venv + extra_model_paths.yaml point at
    # .lmstudio\models\MiniMax-H3).
    # The root and port are overridable (LLAMADOCK_COMFYUI_ROOT /
    # LLAMADOCK_COMFYUI_PORT) so the CLI launcher and the Web GUI
    # (web-ui/client-manager.js) can never diverge: both use the same env
    # override for the launch --port and the health probe.
    $comfyRoot = if ($env:LLAMADOCK_COMFYUI_ROOT) { $env:LLAMADOCK_COMFYUI_ROOT } else { "C:\Users\dai86\Documents\ComfyUI" }
    $comfyPort = if ($env:LLAMADOCK_COMFYUI_PORT -match "^\d+$") { [int]$env:LLAMADOCK_COMFYUI_PORT } else { 8188 }
    $comfyUrl = "http://127.0.0.1:$comfyPort"
    $comfyPython = Join-Path $comfyRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py")) -or -not (Test-Path -LiteralPath $comfyPython)) {
        Write-Host "ERROR: ComfyUI is not set up at $comfyRoot" -ForegroundColor Red
        return $null
    }
    try {
        $existingComfyHealth = Invoke-WebRequest -Uri "$comfyUrl/system_stats" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($existingComfyHealth.StatusCode -eq 200) {
            Write-Host "ComfyUI is already running on $comfyUrl; reusing the existing instance." -ForegroundColor Green
            Start-H3Chat -SkipOpenBrowser:$SkipOpenBrowser
            return $null
        }
    }
    catch {
    }
    Select-ComfyUITuning
    Write-Host "Starting ComfyUI on $comfyUrl..." -ForegroundColor Cyan
    $comfyArgs = Get-ComfyUILaunchArgs -Port $comfyPort
    Write-Host ("ComfyUI flags: {0}" -f ($comfyArgs -join " ")) -ForegroundColor DarkGray
    $process = Start-Process -FilePath $comfyPython -ArgumentList $comfyArgs -WorkingDirectory $comfyRoot -PassThru
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if ($process.HasExited) { break }
        try {
            $health = Invoke-WebRequest -Uri "$comfyUrl/system_stats" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            if ($health.StatusCode -eq 200) {
                $ready = $true
                break
            }
        }
        catch {
        }
    }
    if (-not $ready) {
        Write-Host "WARNING: ComfyUI did not become ready within 60s; opening the browser anyway." -ForegroundColor Yellow
    }
    else {
        # ComfyUI is reachable; verify the MiniMax-H3 native nodes are loaded.
        # Without these, /prompt would reject our workflows as soon as the
        # user actually tries to generate.
        $h3Markers = @(
            "MiniMaxH3ImageToVideo",
            "MiniMaxH3SigmaShift",
            "EmptyMiniMaxH3LatentAV",
            "MiniMaxH3ReferenceToVideo"
        )
        $h3Found = $false
        try {
            $objectInfo = Invoke-RestMethod -Uri "$comfyUrl/object_info" -TimeoutSec 5 -ErrorAction Stop
            foreach ($marker in $h3Markers) {
                if ($objectInfo.PSObject.Properties.Name -contains $marker) {
                    $h3Found = $true
                    break
                }
            }
        }
        catch {
        }
        if (-not $h3Found) {
            Write-Host "WARNING: ComfyUI is up but no MiniMax-H3 native nodes were detected." -ForegroundColor Yellow
            Write-Host "         Install MiniMaxAI/MiniMax-H3 and restart ComfyUI before generating." -ForegroundColor Yellow
        }
        else {
            Write-Host "MiniMax-H3 native nodes detected." -ForegroundColor Green
        }
    }
    Start-H3Chat -SkipOpenBrowser:$SkipOpenBrowser
    return $process
}


function Open-DeepSeekHarnessClient {
    # DeepSeek Harness — agent harness framework (npx auto-install + auto-update).
    # https://deepseek.com/harness/en/
    # The harness's llm-deepseek adapter reads DEEPSEEK_BASE_URL / DEEPSEEK_API_KEY
    # from its launch environment. Pointing them at the LlamaDock gateway makes the
    # harness run on the local llama.cpp model instead of the DeepSeek cloud API,
    # and the env key also satisfies the web UI's "Add an API key" onboarding gate
    # (credentials-local reports source:env as configured).
    $dshCheck = Join-Path $PSScriptRoot "tools\dsh-update.ps1"
    if (Test-Path -LiteralPath $dshCheck) {
        # Run update check in background (non-blocking)
        Start-Job -ScriptBlock { param($p) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p } -ArgumentList $dshCheck | Out-Null
    }
    Write-Host "DeepSeek Harness を起動しています..." -ForegroundColor Cyan
    Write-Host "LLM backend: $ClientBaseUrl/v1 (ローカル llama.cpp / APIキー不要)" -ForegroundColor Cyan

    $env:DEEPSEEK_BASE_URL = "$ClientBaseUrl/v1"
    $env:DEEPSEEK_API_KEY = "not-needed"

    # Prefer the globally installed CLI (kept current by tools/dsh-update.ps1)
    # over npx. npx re-downloads the full ~450-package tree into a fresh _npx
    # cache on every launch, which can hang for minutes on first boot.
    $dshCmd = Join-Path $env:APPDATA "npm\dsh.cmd"
    if (Test-Path -LiteralPath $dshCmd) {
        $proc = Start-Process -FilePath $dshCmd -WorkingDirectory $PSScriptRoot -PassThru -ArgumentList @("web")
        Write-Host "DeepSeek Harness を起動しました: http://127.0.0.1:3080" -ForegroundColor Green
        return $proc
    }

    $npx = if ($IsWindows -or $env:OS -eq "Windows_NT") { "npx.cmd" } else { "npx" }
    $proc = Start-Process -FilePath $npx -WorkingDirectory $PSScriptRoot -PassThru -ArgumentList @(
        "--yes",
        "@deepseek-ai/dsh@latest",
        "web"
    )
    Write-Host "DeepSeek Harness を起動しました: http://127.0.0.1:3080" -ForegroundColor Green
    return $proc
}

function Open-WorkspaceClient {
    param([string]$Mode, [string]$ModelPath, [string]$ModelName)

    switch ($Mode) {
        "WebUI" { return Open-OpenWebUIClient }
        "ComfyUI" { return Open-ComfyUIClient }
        "LlamaAgent" { return Open-LlamaAgentClient -ModelPath $ModelPath }
        "OpenCode" { return Open-OpenCodeClient -ModelName $ModelName }
        "DeepSeekHarness" { return Open-DeepSeekHarnessClient }
        default {
            Set-ClineLocalModel -ModelName $ModelName
            return Open-ClineClient
        }
    }
}

function Stop-H3Stack {
    # Stops the video-stack sidecar processes that hold GPU/RAM after a
    # session: ComfyUI (8188), h3-chat (8189), the CPU planning LLM (8190)
    # and the GPU planning LLM (8191).
    # Only kills processes whose command line matches the expected LlamaDock
    # services, so unrelated apps on those ports are left alone.
    $targets = @(
        @{ Port = 8188; Match = "main.py" },
        @{ Port = 8189; Match = "h3-chat.py" },
        @{ Port = 8190; Match = "llama-server" },
        @{ Port = 8191; Match = "llama-server" }
    )
    foreach ($t in $targets) {
        $listeners = Get-NetTCPConnection -LocalPort $t.Port -State Listen -ErrorAction SilentlyContinue
        foreach ($ownerPid in @($listeners | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })) {
            $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            if (-not $proc) { continue }
            $cmd = ""
            try {
                $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
                if ($cim) { $cmd = [string]$cim.CommandLine }
            }
            catch { }
            if ($cmd -match [regex]::Escape($t.Match) -or ($t.Port -in @(8190, 8191) -and $proc.ProcessName -eq "llama-server")) {
                Write-Host " Stop PID $ownerPid ($($proc.ProcessName)) [port $($t.Port)]" -ForegroundColor Yellow
                Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Host " Skip PID $ownerPid ($($proc.ProcessName)) on port $($t.Port): not the LlamaDock service." -ForegroundColor Yellow
            }
        }
    }
}

function Select-WorkspaceForSession {
    Write-Host ""
    Write-Host "LlamaDock session" -ForegroundColor Cyan
    Write-Host " [1] 同じワークスペースを再起動"
    Write-Host " [2] モデルを維持したままワークスペースを変更"
    Write-Host " [3] モデルを変更 - サーバーを停止してセレクターへ戻る"
    Write-Host " [4] サーバーを停止して終了"
    Write-Host " [5] サーバーを起動したまま終了"
    do {
        $choice = Read-Host "Select session action (1-5)"
        if ($choice -notin @("1", "2", "3", "4", "5")) {
            Write-Host "Invalid choice '$choice'. Enter a number from 1 to 5." -ForegroundColor Yellow
        }
    } while ($choice -notin @("1", "2", "3", "4", "5"))
    if ($choice -eq "1") { return @("relaunch", "") }
    if ($choice -eq "2") {
        Write-Host " [1] Computer  [2] Cline  [3] OpenCode  [4] Llama Agent  [5] ComfyUI  [6] DeepSeek Harness"
        $workspace = Read-Host "Select workspace"
        $modes = @("WebUI", "Cline", "OpenCode", "LlamaAgent", "ComfyUI", "DeepSeekHarness")
        $index = 0
        if ([int]::TryParse($workspace, [ref]$index) -and $index -ge 1 -and $index -le $modes.Count) {
            return @("switch", $modes[$index - 1])
        }
        return @("relaunch", "")
    }
    if ($choice -eq "3") { return @("change-model", "") }
    if ($choice -eq "4") {
        # Ask whether to also shut down the video stack (ComfyUI / h3-chat /
        # planning LLM) that keeps holding GPU and RAM after the session.
        $stopStack = Read-Host "Also stop the video stack (ComfyUI / h3-chat / planning LLM) to free GPU+RAM? (y/N)"
        if ($stopStack -match "^(y|yes)$") { $script:StopAllOnExit = $true }
        return @("stop", "")
    }
    return @("leave", "")
}

Show-LlamaDockBanner

$hardware = Get-HardwareEstimate

$runtimeCandidates = @(
    [PSCustomObject]@{ Name = "AtomicBot"; Path = $AtomicBotServerPath }
    [PSCustomObject]@{ Name = "TurboTan"; Path = $TurboTanServerPath },
    [PSCustomObject]@{ Name = "ExpertsLaguna"; Path = $ExpertsLagunaServerPath },
    [PSCustomObject]@{ Name = "LongCat"; Path = $LongCatServerPath },
    [PSCustomObject]@{ Name = "DFlash2"; Path = $DFlash2ServerPath },
    [PSCustomObject]@{ Name = "OfficialVulkan"; Path = $OfficialVulkanServerPath },
    [PSCustomObject]@{ Name = "OfficialHIP"; Path = $OfficialHIPServerPath },
    [PSCustomObject]@{ Name = "OfficialCPU"; Path = $OfficialCPUServerPath }
)

# ComfyUI is a model-independent workspace. Keep it at the front door so a
# ComfyUI launch never makes the user pick an unrelated GGUF or start a
# llama-server first.
$comfyOnly = $ClientMode -eq "ComfyUI"
if (-not $DryRun -and -not $comfyOnly -and $ClientMode -eq "Prompt") {
    Write-Host "Launch target:" -ForegroundColor Green
    Write-Host " [1] LLM ワークスペース - モデルとクライアントを選択"
    Write-Host " [2] ComfyUI - 動画/音声ワークスペース（GGUF 選択なし）"
    Write-Host " [3] Web GUI - ブラウザで起動/停止/計測"
    Write-Host ""
    do {
        $targetInput = Read-Host "Select launch target (1-3), or press Enter for LLM"
        if ([string]::IsNullOrWhiteSpace($targetInput)) {
            $targetSelection = 1
            $targetValid = $true
        }
        else {
            $targetSelection = 0
            $targetValid = [int]::TryParse($targetInput, [ref]$targetSelection)
        }
    } while (-not $targetValid -or $targetSelection -lt 1 -or $targetSelection -gt 3)

    if ($targetSelection -eq 3) {
        # Same early-exit pattern as ComfyUI: the Web GUI is model-independent,
        # so it opens in its own console and this selector leaves the stage.
        Start-Process -FilePath (Join-Path $PSScriptRoot "webgui.bat") -WorkingDirectory $PSScriptRoot
        exit 0
    }

    if ($targetSelection -eq 2) {
        $ClientMode = "ComfyUI"
        $comfyOnly = $true
    }
}

if ($comfyOnly) {
    if ($DryRun) {
        # Effective ComfyUI port shared by the dry-run messages and by
        # Open-ComfyUIClient (which reads the same env override independently).
        $comfyLaunchPort = if ($env:LLAMADOCK_COMFYUI_PORT -match "^[0-9]+$") { [int]$env:LLAMADOCK_COMFYUI_PORT } else { 8188 }
        $comfyArgs = Get-ComfyUILaunchArgs -Port $comfyLaunchPort
        Write-Host "DRY RUN: ComfyUI-only launch; model selection and llama-server will be skipped." -ForegroundColor Yellow
        Write-Host "DRY RUN: ComfyUI would start on http://127.0.0.1:$comfyLaunchPort" -ForegroundColor Yellow
        Write-Host ("DRY RUN: ComfyUI flags: {0}" -f ($comfyArgs -join " ")) -ForegroundColor Yellow
        exit 0
    }

    $null = Open-ComfyUIClient
    exit 0
}

# Find all supported GGUF files. Retired Hy3/hy_v3 files stay on disk for
# optional manual cleanup, but must not be offered to a different runtime.
$allFiles = Get-ChildItem -Path $ModelsBase -Filter "*.gguf" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "mmproj" -and $_.Name -notmatch "(?i)(^|[\\/_. -])Hy3([\\/_. -]|$)|Hy[-_ ]?V3" -and $_.Name -notmatch "(?i)DSpark" }

# Build model list (all models except mmproj)
$models = @()
foreach ($f in $allFiles) {
    if ($f.Name -notmatch "mmproj" -and $f.Name -notmatch "(?i)DFlash2") {
        $isTQ3 = $f.Name -match "TQ3"
        $engine = Get-RequiredEngine -Model $f
        $models += [PSCustomObject]@{
            Name = $f.Name
            FullName = $f.FullName
            SizeMB = [math]::Round($f.Length / 1MB, 1)
            IsTQ3 = $isTQ3
            Engine = $engine
        }
    }
}

if ($models.Count -eq 0) {
    Write-Host "ERROR: No .gguf models found!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Sort by size (TQ3 models first)
$models = @($models | Sort-Object -Property @{ Expression = "IsTQ3"; Descending = $true }, @{ Expression = "SizeMB"; Descending = $true })

# Keep the detailed front door visible: model, engine, workflow, and runtime
# choices are part of the launch contract and must not be hidden behind a
# secondary menu.
$tq3Count = @($models | Where-Object { $_.IsTQ3 }).Count
Write-Host "Models" -ForegroundColor Green
Write-Host "Detected $($models.Count) GGUF model(s); $($tq3Count) TQ3 model(s)." -ForegroundColor DarkGray
Write-Host ""
for ($i = 0; $i -lt $models.Count; $i++) {
    $m = $models[$i]
    $sizeStr = if ($m.SizeMB -ge 1024) { "{0:N1} GB" -f ($m.SizeMB / 1024) } else { "{0:N0} MB" -f $m.SizeMB }
    $tq3Tag = if ($m.IsTQ3) { "TQ3" } else { "GGUF" }
    Write-Host (" [{0}] {1}  {2}  {3}  {4}" -f ($i + 1), $m.Name, $sizeStr, $tq3Tag, $m.Engine)
}
Write-Host ""

if ($ModelIndex -gt 0) {
    $selection = $ModelIndex
    if ($selection -lt 1 -or $selection -gt $models.Count) {
        Write-Host "ERROR: ModelIndex out of range" -ForegroundColor Red
        exit 1
    }
}
else {
    do {
        $modelInput = Read-Host "Select model (1-$($models.Count)), or 'q' to quit"
        if ($modelInput -eq 'q') { exit 0 }
        $selection = 0
        $valid = [int]::TryParse($modelInput, [ref]$selection)
    } while (-not $valid -or $selection -lt 1 -or $selection -gt $models.Count)
}

$selected = $models[$selection - 1]
$selectedModelSizeGB = [math]::Round($selected.SizeMB / 1024, 1)
$requiredEngine = Get-RequiredEngine -Model $selected
$selectedModelText = "$($selected.Name) $($selected.FullName)"
$isLikelyMoeModel = $selectedModelText -match "(?i)MOE|Mixtral|8X4B|4X7B|8x4B|4x7B|expert|DeepSeek|Laguna"
$isDeepSeek = $selectedModelText -match "(?i)DeepSeek"
if ($EngineMode -ne "Auto") {
    $requiredEngine = $EngineMode
}

# Engine selection prompt (skip for special engines and non-interactive mode)
$specialEngines = @('TurboTan', 'ExpertsLaguna', 'LongCat', 'DFlash2')
if ($EngineMode -eq 'Auto' -and $PresetMode -eq 'Prompt' -and $specialEngines -notcontains $requiredEngine -and -not $isQuickLaunch) {
    # Check which engines are actually available
    $availableEngines = @()
    if (Test-Path $AtomicBotServerPath) { $availableEngines += [PSCustomObject]@{ Label = 'AtomicBot (ROCm)'; Value = 'AtomicBot'; Note = 'GDN layers may fall back to CPU' } }
    if (Test-Path $OfficialVulkanServerPath) { $availableEngines += [PSCustomObject]@{ Label = 'Vulkan'; Value = 'OfficialVulkan'; Note = 'GDN layers GPU-accelerated' } }
    if (Test-Path $OfficialCPUServerPath) { $availableEngines += [PSCustomObject]@{ Label = 'CPU'; Value = 'OfficialCPU'; Note = 'Small models, no GPU needed' } }

    if ($availableEngines.Count -gt 1) {
        Write-Host ''
        Write-Host 'Runtime engine:' -ForegroundColor Green
        for ($i = 0; $i -lt $availableEngines.Count; $i++) {
            $eng = $availableEngines[$i]
            Write-Host " [$(($i+1))] $($eng.Label) - $($eng.Note)"
        }
        Write-Host ''
        $defaultEngineIdx = 0
        for ($i = 0; $i -lt $availableEngines.Count; $i++) {
            if ($availableEngines[$i].Value -eq 'OfficialVulkan') { $defaultEngineIdx = $i; break }
        }
        do {
            $engineInput = Read-Host "Select engine (1-$($availableEngines.Count)), or press Enter for $($availableEngines[$defaultEngineIdx].Label)"
            if ([string]::IsNullOrWhiteSpace($engineInput)) {
                $engineSelection = $defaultEngineIdx
                $engineValid = $true
            }
            else {
                $engineValid = [int]::TryParse($engineInput, [ref]$engineSelection)
                $engineSelection--
            }
        } while (-not $engineValid -or $engineSelection -lt 0 -or $engineSelection -ge $availableEngines.Count)

        $requiredEngine = $availableEngines[$engineSelection].Value
        Write-Host "Engine: $($availableEngines[$engineSelection].Label)" -ForegroundColor Green
        Write-Host ''
    }
}

if ($requiredEngine -eq "TurboTan") {
    $ServerPath = $TurboTanServerPath
}
elseif ($requiredEngine -eq "ExpertsLaguna") {
    $ServerPath = $ExpertsLagunaServerPath
}
elseif ($requiredEngine -eq "LongCat") {
    $ServerPath = $LongCatServerPath
}
elseif ($requiredEngine -eq "DFlash2") {
    $ServerPath = $DFlash2ServerPath
}
elseif ($requiredEngine -eq "OfficialVulkan") {
    $ServerPath = $OfficialVulkanServerPath
}
elseif ($requiredEngine -eq "OfficialHIP") {
    $ServerPath = $OfficialHIPServerPath
}
elseif ($requiredEngine -eq "OfficialCPU") {
    $ServerPath = $OfficialCPUServerPath
}
else {
    $ServerPath = $AtomicBotServerPath
}

$modelNote = Get-ModelNote -Model $selected

if ($PresetMode -eq "Prompt") {
    Write-Host ""
    Write-Host "Runtime engine: $requiredEngine" -ForegroundColor Green
    Write-Host "Runtime path  : $ServerPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Workflow preset:" -ForegroundColor Green
    Write-Host " [1] Manual - 全設定を手動選択"
    Write-Host " [2] Code - Cline 向けの安定設定"
    Write-Host " [3] Code - OpenCode 向けの安定設定"
    Write-Host " [4] Agent Research - llama-agent と反復Web証拠収集"
    Write-Host " [5] Chat - Open WebUI（Web検索・会話圧縮）"
    Write-Host " [6] DeepSeek Harness - エージェントハーネス（ローカルLLM接続・APIキー不要）"
    Write-Host ""

    do {
        $presetInput = Read-Host "Select preset (1-6), or press Enter for Manual"
        if ([string]::IsNullOrWhiteSpace($presetInput)) {
            $presetSelection = 1
            $presetValid = $true
        }
        else {
            $presetSelection = 0
            $presetValid = [int]::TryParse($presetInput, [ref]$presetSelection)
        }
    } while (-not $presetValid -or $presetSelection -lt 1 -or $presetSelection -gt 6)

    $presetValues = @("Manual", "ClineCoding", "OpenCodeCoding", "LlamaAgentResearch", "WebUIChat", "DeepSeekHarness")
    $PresetMode = $presetValues[$presetSelection - 1]
}

$isQuickLaunch = $PresetMode -in @("WebUIChat", "OpenCodeCoding")
if ($isQuickLaunch) {
    if ($KCacheIndex -eq 0) { $KCacheIndex = 1 }
    if ($VCacheIndex -eq 0) {
        if ($requiredEngine -eq "TurboTan") { $VCacheIndex = 4 }
        elseif ($selectedModelSizeGB -ge 20) { $VCacheIndex = 4 }
        else { $VCacheIndex = 1 }
    }
}

if ($PresetMode -eq "ClineCoding") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "Cline" }
    if ($ContextIndex -eq 0) { $ContextIndex = 3 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "OpenCodeCoding") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "OpenCode" }
    if ($ContextIndex -eq 0) { $ContextIndex = 3 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "LlamaAgentResearch") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "LlamaAgent" }
    if ($ContextIndex -eq 0) { $ContextIndex = 3 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "WebUIChat") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "WebUI" }
    if ($ContextIndex -eq 0) { $ContextIndex = 2 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "DeepSeekHarness") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "DeepSeekHarness" }
    if ($ContextIndex -eq 0) { $ContextIndex = 3 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}

if (-not $isQuickLaunch) {
    Write-Host ""
    Write-HardwareSummary -Hardware $hardware
    Write-RuntimeAvailability -Runtimes $runtimeCandidates
    Write-Host "Runtime engine: $requiredEngine" -ForegroundColor Green
    Write-Host "Runtime path  : $ServerPath" -ForegroundColor DarkGray
}

if ($modelNote -and -not $isQuickLaunch) {
    Write-Host ""
    Write-Host "Model note: $($modelNote.note)" -ForegroundColor Cyan
    if ($modelNote.recommended_preset) {
        Write-Host "Recommended preset: $($modelNote.recommended_preset)" -ForegroundColor Cyan
    }
    if ($modelNote.warning) {
        Write-Host "WARNING: $($modelNote.warning)" -ForegroundColor Yellow
    }
}
if ($modelNote -and $isQuickLaunch -and $modelNote.warning) {
    Write-Host "WARNING: $($modelNote.warning)" -ForegroundColor Yellow
}
if (-not $isQuickLaunch) {
    Show-LastRunResult -Model $selected
}

Write-Host ""
if ($isQuickLaunch) {
    $launchLabel = if ($PresetMode -eq "WebUIChat") { "Chat + Web -> Computer" } elseif ($PresetMode -eq "OpenCodeCoding") { "Coding -> OpenCode" } else { "Manual" }
}
else {
    Write-Host "Selected: $($selected.Name)" -ForegroundColor Green
    Write-Host "Engine: $requiredEngine" -ForegroundColor Green
    Write-Host "Preset: $PresetMode" -ForegroundColor Green
}
Write-Host ""

if (-not (Test-Path $ServerPath)) {
    Write-Host "ERROR: Required engine is not built:" -ForegroundColor Red
    Write-Host $ServerPath -ForegroundColor Red
    if ($requiredEngine -eq "TurboTan") {
        Write-Host "Build TurboTan first, or set LLAMA_TQ3_TURBOTAN_SERVER to its llama-server.exe." -ForegroundColor Red
    }
    elseif ($requiredEngine -eq "AtomicBot") {
        Write-Host "Rebuild with: tools\build-atomicbot-rocm71-fa.ps1 (see HANDOFF.md), or set LLAMA_TQ3_ATOMICBOT_SERVER." -ForegroundColor Red
    }
    elseif ($requiredEngine -eq "OfficialVulkan") {
        Write-Host "Install an official llama.cpp Vulkan Windows build, or set LLAMADOCK_OFFICIAL_VULKAN_SERVER." -ForegroundColor Red
    }
    elseif ($requiredEngine -eq "OfficialHIP") {
        Write-Host "Install an official llama.cpp HIP Windows build, or set LLAMADOCK_OFFICIAL_HIP_SERVER." -ForegroundColor Red
    }
    elseif ($requiredEngine -eq "OfficialCPU") {
        Write-Host "Install an official llama.cpp CPU Windows build, or set LLAMADOCK_OFFICIAL_CPU_SERVER." -ForegroundColor Red
    }
    exit 1
}

# --- Vision adapter (mmproj) opt-in --------------------------------------
# A mmproj GGUF sitting next to the selected model enables image input via
# --mmproj. Off by default: the vision encoder costs VRAM that a coding
# session may prefer to spend on KV cache. LLAMADOCK_VISION=on|off skips
# the prompt (quick-launch presets and DryRun honor it without asking).
$visionMmprojPath = Get-ChildItem -LiteralPath (Split-Path -Parent $selected.FullName) -Filter "mmproj*.gguf" -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending | Select-Object -First 1
$visionEnabled = $false
$envVision = $env:LLAMADOCK_VISION
if ($visionMmprojPath) {
    $mmprojSizeGB = [math]::Round($visionMmprojPath.Length / 1GB, 2)
    if ($envVision -eq "on") {
        $visionEnabled = $true
        Write-Host "Vision: on (LLAMADOCK_VISION=on, $($visionMmprojPath.Name) $mmprojSizeGB GB)" -ForegroundColor Green
    }
    elseif ($envVision -eq "off") {
        Write-Host "Vision: off (adapter found, disabled via LLAMADOCK_VISION=off)" -ForegroundColor DarkGray
    }
    elseif (-not $DryRun -and -not $isQuickLaunch) {
        Write-Host ""
        Write-Host "Vision adapter found: $($visionMmprojPath.Name) ($mmprojSizeGB GB)" -ForegroundColor Green
        Write-Host " [1] Text-only (default - saves VRAM for context)"
        Write-Host " [2] Enable image input (--mmproj, uses extra VRAM)"
        do {
            $visionInput = Read-Host "Enable vision? (1-2), or press Enter for 1"
            if ([string]::IsNullOrWhiteSpace($visionInput)) { $visionInput = "1" }
            $visionValid = $visionInput -in @("1", "2")
        } while (-not $visionValid)
        $visionEnabled = ($visionInput -eq "2")
    }
}
elseif ($envVision -eq "on") {
    # LLAMADOCK_VISION=on was requested but this model ships no adapter next
    # to it — say so instead of silently continuing text-only.
    Write-Host "Vision: LLAMADOCK_VISION=on requested, but no mmproj*.gguf found next to '$($selected.Name)' — continuing text-only." -ForegroundColor Yellow
}

# Prompt context size selection
$systemRamGB = $hardware.RamGB
$primaryVramGB = if ($hardware.PrimaryGpu) { [double]$hardware.PrimaryGpu.VramGB } else { 0 }
$maxContextTokensForRam = Get-MaxContextTokensForRam -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB
$recommendedDefaultTokens = if ($isDeepSeek) {
    # 16K: Cline-grade context at a measured ~6.4 tps; 32K drops to ~4 tps, 8K is too small.
    16384
}
else {
    # 32K flat default (2026-08-24): coder agents run auto-compaction, so a
    # larger default only risks KV spilling out of VRAM. The old model-size
    # ladder went up to 128K for small models, which on a 16 GB card meant
    # KV silently living in system RAM.
    $tokens = 32768
    if ($maxContextTokensForRam -gt 0 -and $tokens -gt $maxContextTokensForRam) {
        $tokens = $maxContextTokensForRam
    }
    $tokens
}

$contextOptions = @(
    [PSCustomObject]@{ Label = "8K"; Tokens = 8192; Note = "lowest memory, startup test" },
    [PSCustomObject]@{ Label = "16K"; Tokens = 16384; Note = "safe default for large models" },
    [PSCustomObject]@{ Label = "32K"; Tokens = 32768; Note = "coding default" },
    [PSCustomObject]@{ Label = "64K"; Tokens = 65536; Note = "long context, check RAM" },
    [PSCustomObject]@{ Label = "128K"; Tokens = 131072; Note = "very long context, high RAM/KV" },
    [PSCustomObject]@{ Label = "256K"; Tokens = 262144; Note = "extreme, expect high RAM/KV" },
    [PSCustomObject]@{ Label = "Custom"; Tokens = 0; Note = "enter token count manually" }
)

if (-not $isQuickLaunch) {
    Write-Host "Context size:" -ForegroundColor Green
    if ($systemRamGB -gt 0) {
        Write-Host ("Detected RAM: {0}GB; selected model: {1:N1}GB" -f $systemRamGB, $selectedModelSizeGB) -ForegroundColor DarkGray
        Write-Host ("Recommended ceiling for this model/RAM: {0} tokens" -f $maxContextTokensForRam) -ForegroundColor DarkGray
    }
    for ($i = 0; $i -lt $contextOptions.Count; $i++) {
        $ctx = $contextOptions[$i]
        if ($ctx.Tokens -gt 0) {
            $risk = Get-ContextRiskLabel -Tokens $ctx.Tokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB
            $defaultMark = if ($ctx.Tokens -eq $recommendedDefaultTokens) { " [recommended]" } else { "" }
            Write-Host " [$($i+1)] $($ctx.Label) ($($ctx.Tokens) tokens) - $($ctx.Note); $risk$defaultMark"
        }
        else {
            Write-Host " [$($i+1)] $($ctx.Label) - $($ctx.Note)"
        }
    }
    Write-Host ""
}

if ($ContextIndex -gt 0) {
    $ctxSelection = $ContextIndex
    if ($ctxSelection -lt 1 -or $ctxSelection -gt $contextOptions.Count) {
        Write-Host "ERROR: ContextIndex out of range" -ForegroundColor Red
        exit 1
    }
}
else {
    do {
        $defaultContextLabel = "$([int]($recommendedDefaultTokens / 1024))K"
        $ctxInput = Read-Host "Select context size (1-$($contextOptions.Count)), or press Enter for $defaultContextLabel"
        if ([string]::IsNullOrWhiteSpace($ctxInput)) {
            $ctxSelection = [array]::IndexOf(@($contextOptions | Select-Object -ExpandProperty Tokens), $recommendedDefaultTokens) + 1
            $ctxValid = $true
        }
        else {
            $ctxSelection = 0
            $ctxValid = [int]::TryParse($ctxInput, [ref]$ctxSelection)
        }
    } while (-not $ctxValid -or $ctxSelection -lt 1 -or $ctxSelection -gt $contextOptions.Count)
}

$selectedContext = $contextOptions[$ctxSelection - 1]
if ($selectedContext.Tokens -eq 0) {
    do {
        $customContextInput = Read-Host "Enter context tokens (example: 32768, 65536, 131072)"
        $customContextTokens = 0
        $customContextValid = [int]::TryParse($customContextInput, [ref]$customContextTokens)
        if ($customContextValid -and $customContextTokens -gt $maxContextTokensForRam) {
            Write-Host "ERROR: That context is above the RAM safety ceiling for this model." -ForegroundColor Red
            Write-Host "Ceiling: $maxContextTokensForRam tokens. Select a lower value or a smaller model." -ForegroundColor Red
            $customContextValid = $false
        }
    } while (-not $customContextValid -or $customContextTokens -lt 512)

    $selectedContext = [PSCustomObject]@{
        Label = "$customContextTokens"
        Tokens = $customContextTokens
        Note = "custom"
    }
}
if (-not $isQuickLaunch) {
    Write-Host ""
    Write-Host "Context: $($selectedContext.Label) ($($selectedContext.Tokens) tokens)" -ForegroundColor Green
    if ($systemRamGB -gt 0) {
        Write-Host "Context risk: $(Get-ContextRiskLabel -Tokens $selectedContext.Tokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB)" -ForegroundColor Yellow
    }
}
if ($selectedContext.Tokens -gt $maxContextTokensForRam -or -not (Test-ContextFitsRam -Tokens $selectedContext.Tokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB)) {
    Write-Host "ERROR: Selected context is likely to exceed available RAM for this model." -ForegroundColor Red
    Write-Host "Selected: $($selectedContext.Tokens) tokens; ceiling: $maxContextTokensForRam tokens." -ForegroundColor Red
    Write-Host "Use a lower context or a smaller/lighter model." -ForegroundColor Red
    exit 1
}
if (-not $isQuickLaunch) { Write-Host "" }

function Test-CacheTypeSupported {
    # Probe whether a llama-server binary accepts a KV cache type without
    # starting a server: "--help" exits 0 after argument parsing succeeds,
    # while an invalid -ctk/-ctv value aborts with exit 1 before that. ROCm
    # DLLs must be on PATH or HIP builds fail to launch at all, so prepend
    # the newest AMD ROCm bin directory first.
    param([string]$ServerPath, [string]$Flag, [string]$Value)
    if (-not (Test-Path -LiteralPath $ServerPath)) { return $true }
    $oldPath = $env:PATH
    try {
        $hipRoot = "C:\Program Files\AMD\ROCm"
        if (Test-Path -LiteralPath $hipRoot) {
            $latestHip = $null
            foreach ($d in (Get-ChildItem -LiteralPath $hipRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($null -eq $latestHip -or $d.Name -gt $latestHip.Name) { $latestHip = $d }
            }
            if ($latestHip) { $env:PATH = "$(Join-Path $latestHip.FullName 'bin');$env:PATH" }
        }
        $null = & $ServerPath $Flag $Value --help 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $true
    }
    finally {
        $env:PATH = $oldPath
    }
}

# Prompt KV cache quantization selection
$kvOptions = @(
    [PSCustomObject]@{ Label = "Q8"; Type = "q8_0"; Note = "larger, stable default for K" },
    [PSCustomObject]@{ Label = "Q5_1"; Type = "q5_1"; Note = "supported middle option for K, safer than Q4" },
    [PSCustomObject]@{ Label = "Q5_0"; Type = "q5_0"; Note = "supported compact middle option" },
    [PSCustomObject]@{ Label = "Q4"; Type = "q4_0"; Note = "compact, more quality risk for K" },
    [PSCustomObject]@{ Label = "turbo4"; Type = "turbo4"; Note = "TurboQuant 4.5bit" },
    [PSCustomObject]@{ Label = "turbo3"; Type = "turbo3"; Note = "TurboQuant 3.5bit" },
    [PSCustomObject]@{ Label = "f16"; Type = "f16"; Note = "uncompressed compatibility fallback" },
    [PSCustomObject]@{ Label = "bf16"; Type = "bf16"; Note = "uncompressed compatibility fallback, lower memory than f32" }
)

if ($requiredEngine -eq "TurboTan") {
    # Older TurboTan builds accepted tq3_0/turbo* KV caches; the current
    # b10536 build rejects them (instant startup crash when selected). Probe
    # the actual binary and keep only cache types it validates for BOTH K and
    # V, so the menu can never offer a combination that kills llama-server.
    $probedKv = @()
    foreach ($kv in $kvOptions) {
        $okK = Test-CacheTypeSupported -ServerPath $ServerPath -Flag "-ctk" -Value $kv.Type
        $okV = Test-CacheTypeSupported -ServerPath $ServerPath -Flag "-ctv" -Value $kv.Type
        if ($okK -and $okV) { $probedKv += $kv }
    }
    if ($probedKv.Count -gt 0) {
        $kvOptions = $probedKv
        if (-not $isQuickLaunch) {
            Write-Host "TurboTan KV probe: keeping $($kvOptions.Count) cache types accepted by this build." -ForegroundColor DarkGray
        }
    }
}
elseif ($requiredEngine -eq "OfficialVulkan" -or $requiredEngine -eq "OfficialHIP" -or $requiredEngine -eq "OfficialCPU" -or $requiredEngine -eq "LongCat" -or ($requiredEngine -eq "ExpertsLaguna" -and -not $isDeepSeek)) {
    $kvOptions = @($kvOptions | Where-Object { $_.Type -ne "turbo4" -and $_.Type -ne "turbo3" })
    if (-not $isQuickLaunch) {
        Write-Host "Current llama.cpp engine: TurboQuant KV types hidden; quality-first K/V default is Q8/Q8." -ForegroundColor Yellow
    }
}

if (-not $isQuickLaunch) {
    Write-Host "KV cache K type:" -ForegroundColor Green
    for ($i = 0; $i -lt $kvOptions.Count; $i++) {
        $kv = $kvOptions[$i]
        Write-Host " [$($i+1)] $($kv.Label) ($($kv.Type)) - $($kv.Note)"
    }
    Write-Host ""
}

if ($KCacheIndex -eq 0 -and $KvIndex -gt 0) {
    $KCacheIndex = $KvIndex
}

if ($KCacheIndex -gt 0) {
    $kSelection = $KCacheIndex
    if ($kSelection -lt 1 -or $kSelection -gt $kvOptions.Count) {
        Write-Host "ERROR: KCacheIndex out of range" -ForegroundColor Red
        exit 1
    }
}
else {
    $defaultKType = if ($isDeepSeek) { "turbo4" } else { "q8_0" }
    do {
        $defaultKLabel = $defaultKType
        $kInput = Read-Host "Select K cache type (1-$($kvOptions.Count)), or press Enter for $defaultKLabel"
        if ([string]::IsNullOrWhiteSpace($kInput)) {
            $kSelection = [array]::IndexOf(@($kvOptions | Select-Object -ExpandProperty Type), $defaultKType) + 1
            if ($kSelection -le 0) { $kSelection = 1 }
            $kValid = $true
        }
        else {
            $kSelection = 0
            $kValid = [int]::TryParse($kInput, [ref]$kSelection)
        }
    } while (-not $kValid -or $kSelection -lt 1 -or $kSelection -gt $kvOptions.Count)
}

$selectedKCache = $kvOptions[$kSelection - 1]
if (-not $isQuickLaunch) {
    Write-Host ""
    Write-Host "KV cache K: $($selectedKCache.Label) ($($selectedKCache.Type))" -ForegroundColor Green
    Write-Host ""
}

if (-not $isQuickLaunch) {
    Write-Host "KV cache V type:" -ForegroundColor Green
    for ($i = 0; $i -lt $kvOptions.Count; $i++) {
        $kv = $kvOptions[$i]
        Write-Host " [$($i+1)] $($kv.Label) ($($kv.Type)) - $($kv.Note)"
    }
    Write-Host ""
}

if ($isDeepSeek) {
    # DeepSeek V4 Flash (this fork) requires symmetric K/V cache types:
    # "model does not support different K and V cache types". V follows K.
    $selectedVCache = $selectedKCache
    if (-not $isQuickLaunch) {
        Write-Host ""
        Write-Host "KV cache V: $($selectedVCache.Label) ($($selectedVCache.Type)) (symmetric - DeepSeek requires K==V)" -ForegroundColor Green
        Write-Host ""
    }
}
else {
    if ($VCacheIndex -eq 0 -and $KvIndex -gt 0) {
        $VCacheIndex = $KvIndex
    }

    if ($VCacheIndex -gt 0) {
        $vSelection = $VCacheIndex
        if ($vSelection -lt 1 -or $vSelection -gt $kvOptions.Count) {
            Write-Host "ERROR: VCacheIndex out of range" -ForegroundColor Red
            exit 1
        }
    }
    else {
        $defaultVType = "q4_0"
        do {
            $defaultVLabel = $defaultVType
            $vInput = Read-Host "Select V cache type (1-$($kvOptions.Count)), or press Enter for $defaultVLabel"
            if ([string]::IsNullOrWhiteSpace($vInput)) {
                $vSelection = [array]::IndexOf(@($kvOptions | Select-Object -ExpandProperty Type), $defaultVType) + 1
                $vValid = $true
            }
            else {
                $vSelection = 0
                $vValid = [int]::TryParse($vInput, [ref]$vSelection)
            }
        } while (-not $vValid -or $vSelection -lt 1 -or $vSelection -gt $kvOptions.Count)
    }

    $selectedVCache = $kvOptions[$vSelection - 1]
    if (-not $isQuickLaunch) {
        Write-Host ""
        Write-Host "KV cache V: $($selectedVCache.Label) ($($selectedVCache.Type))" -ForegroundColor Green
        Write-Host ""
    }
}

if ($ClientMode -eq "Prompt") {
    Write-Host "Workspace:" -ForegroundColor Green
    Write-Host " [1] Cline - コーディングエージェント"
    Write-Host " [2] OpenCode - ターミナルコーディングエージェント"
    Write-Host " [3] Computer - チャット・Web検索・会話圧縮"
    Write-Host " [4] Llama Agent - ターミナルエージェントと詳細Web証拠収集"
    Write-Host " [5] ComfyUI - MiniMax H3 動画・音声生成"
    Write-Host " [6] DeepSeek Harness - エージェントハーネス（ローカルLLM接続）"
    Write-Host ""

    do {
        $clientInput = Read-Host "Select workspace (1-6), or press Enter for Cline"
        if ([string]::IsNullOrWhiteSpace($clientInput)) {
            $clientSelection = 1
            $clientValid = $true
        }
        else {
            $clientSelection = 0
            $clientValid = [int]::TryParse($clientInput, [ref]$clientSelection)
        }
    } while (-not $clientValid -or $clientSelection -lt 1 -or $clientSelection -gt 6)

    if ($clientSelection -eq 1) { $ClientMode = "Cline" }
    elseif ($clientSelection -eq 2) { $ClientMode = "OpenCode" }
    elseif ($clientSelection -eq 3) { $ClientMode = "WebUI" }
    elseif ($clientSelection -eq 4) { $ClientMode = "LlamaAgent" }
    elseif ($clientSelection -eq 5) { $ClientMode = "ComfyUI" }
    else { $ClientMode = "DeepSeekHarness" }
}

if (-not $isQuickLaunch) {
    Write-Host "Workspace: $ClientMode" -ForegroundColor Green
    Write-Host ""
}

$offloadOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Value = "auto"; Note = "llama.cpp decides GPU layer offload" },
    [PSCustomObject]@{ Label = "All"; Value = "all"; Note = "try to offload all layers" },
    [PSCustomObject]@{ Label = "CPU"; Value = "0"; Note = "CPU only" },
    [PSCustomObject]@{ Label = "Custom"; Value = "custom"; Note = "enter a layer count" }
)

if ($OffloadMode -eq "Prompt") {
    Write-Host "GPU offload:" -ForegroundColor Green
    for ($i = 0; $i -lt $offloadOptions.Count; $i++) {
        $offload = $offloadOptions[$i]
        Write-Host " [$($i+1)] $($offload.Label) - $($offload.Note)"
    }
    Write-Host ""

    do {
        $offloadInput = Read-Host "Select GPU offload (1-$($offloadOptions.Count)), or press Enter for Auto"
        if ([string]::IsNullOrWhiteSpace($offloadInput)) {
            $offloadSelection = 1
            $offloadValid = $true
        }
        else {
            $offloadSelection = 0
            $offloadValid = [int]::TryParse($offloadInput, [ref]$offloadSelection)
        }
    } while (-not $offloadValid -or $offloadSelection -lt 1 -or $offloadSelection -gt $offloadOptions.Count)

    $selectedOffload = $offloadOptions[$offloadSelection - 1].Value
}
elseif ($OffloadMode -eq "Auto") {
    $selectedOffload = "auto"
}
elseif ($OffloadMode -eq "All") {
    $selectedOffload = "all"
}
elseif ($OffloadMode -eq "CPU") {
    $selectedOffload = "0"
}
else {
    $selectedOffload = "custom"
}

if ($selectedOffload -eq "custom") {
    if ([string]::IsNullOrWhiteSpace($OffloadLayers)) {
        do {
            $offloadLayersInput = Read-Host "Enter GPU layer count"
            $offloadLayersValue = 0
            $offloadLayersValid = [int]::TryParse($offloadLayersInput, [ref]$offloadLayersValue)
        } while (-not $offloadLayersValid -or $offloadLayersValue -lt 0)
        $selectedOffload = [string]$offloadLayersValue
    }
    else {
        $selectedOffload = $OffloadLayers
    }
}

$serverOffload = if ($selectedOffload -eq "auto") { "auto" } elseif ($selectedOffload -eq "all") { "all" } else { $selectedOffload }
if ($NglLayers -gt 0) {
    $serverOffload = [string]$NglLayers
    Write-Host "GPU layers override: -ngl $NglLayers (-NglLayers)" -ForegroundColor Yellow
}
if (-not $isQuickLaunch) {
    Write-Host "GPU offload: $selectedOffload" -ForegroundColor Green
    Write-Host "GPU offload estimate: $(Get-VramRiskLabel -ModelSizeGB $selectedModelSizeGB -VramGB $primaryVramGB -OffloadMode $selectedOffload)" -ForegroundColor Yellow
    Write-Host "GPU layers passed to llama-server: $serverOffload" -ForegroundColor Yellow
    Write-Host ""
}
$moeExpertOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Value = "Auto"; Note = "model default, safest" },
    [PSCustomObject]@{ Label = "2"; Value = "2"; Note = "common fast MoE setting" },
    [PSCustomObject]@{ Label = "3"; Value = "3"; Note = "balanced manual setting" },
    [PSCustomObject]@{ Label = "4"; Value = "4"; Note = "heavier quality test" },
    [PSCustomObject]@{ Label = "6"; Value = "6"; Note = "8-expert models only, heavy" },
    [PSCustomObject]@{ Label = "8"; Value = "8"; Note = "8-expert models only, very heavy" },
    [PSCustomObject]@{ Label = "Custom"; Value = "Custom"; Note = "enter expert count" }
)

if ($MoeExpertsMode -eq "Prompt") {
    Write-Host "MoE expert count:" -ForegroundColor Green
    for ($i = 0; $i -lt $moeExpertOptions.Count; $i++) {
        $moe = $moeExpertOptions[$i]
        Write-Host " [$($i+1)] $($moe.Label) - $($moe.Note)"
    }
    Write-Host ""

    do {
        $moeInput = Read-Host "Select MoE experts (1-$($moeExpertOptions.Count)), or press Enter for Auto"
        if ([string]::IsNullOrWhiteSpace($moeInput)) {
            $moeSelection = 1
            $moeValid = $true
        }
        else {
            $moeSelection = 0
            $moeValid = [int]::TryParse($moeInput, [ref]$moeSelection)
        }
    } while (-not $moeValid -or $moeSelection -lt 1 -or $moeSelection -gt $moeExpertOptions.Count)

    $MoeExpertsMode = $moeExpertOptions[$moeSelection - 1].Value
}

$selectedMoeExperts = ""
if ($MoeExpertsMode -eq "Custom") {
    if ([string]::IsNullOrWhiteSpace($MoeExpertsCount)) {
        do {
            $moeCustomInput = Read-Host "Enter MoE expert count"
            $moeCustomValue = 0
            $moeCustomValid = [int]::TryParse($moeCustomInput, [ref]$moeCustomValue)
        } while (-not $moeCustomValid -or $moeCustomValue -lt 1)
        $selectedMoeExperts = [string]$moeCustomValue
    }
    else {
        $moeCustomValue = 0
        if (-not [int]::TryParse($MoeExpertsCount, [ref]$moeCustomValue) -or $moeCustomValue -lt 1) {
            Write-Host "ERROR: MoeExpertsCount must be a positive integer" -ForegroundColor Red
            exit 1
        }
        $selectedMoeExperts = [string]$moeCustomValue
    }
}
elseif ($MoeExpertsMode -ne "Auto") {
    $selectedMoeExperts = $MoeExpertsMode
}

if (-not $isQuickLaunch) {
    if ([string]::IsNullOrWhiteSpace($selectedMoeExperts)) {
        Write-Host "MoE expert count: Auto" -ForegroundColor Green
    }
    else {
        Write-Host "MoE expert count: $selectedMoeExperts" -ForegroundColor Green
        Write-Host "WARNING: Only use manual MoE expert count with MoE models that support this many experts." -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- CPU MoE Layers (--n-cpu-moe) ---
$selectedCpuMoe = ""
$cpuMoeOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Value = "Auto"; Note = "auto-calculate based on model size vs VRAM" },
    [PSCustomObject]@{ Label = "Off (0)"; Value = "0"; Note = "all MoE weights on GPU" },
    [PSCustomObject]@{ Label = "Light (10)"; Value = "10"; Note = "first 10 layers MoE on CPU" },
    [PSCustomObject]@{ Label = "Medium (20)"; Value = "20"; Note = "first 20 layers MoE on CPU" },
    [PSCustomObject]@{ Label = "Heavy (44)"; Value = "44"; Note = "AJ's 3060 setting" },
    [PSCustomObject]@{ Label = "All (99)"; Value = "99"; Note = "all MoE weights on CPU" },
    [PSCustomObject]@{ Label = "Custom"; Value = "Custom"; Note = "enter layer count" }
)

if ($isLikelyMoeModel -and -not $isQuickLaunch -and [string]::IsNullOrWhiteSpace($CpuMoeMode)) {
    Write-Host "CPU MoE layers (--n-cpu-moe):" -ForegroundColor Green
    for ($i = 0; $i -lt $cpuMoeOptions.Count; $i++) {
        $opt = $cpuMoeOptions[$i]
        Write-Host " [$($i+1)] $($opt.Label) - $($opt.Note)"
    }
    Write-Host ""

    do {
        $defaultCpuMoeLabel = if ($isDeepSeek) { "All (99)" } else { "Auto" }
        $defaultCpuMoeIndex = if ($isDeepSeek) { 6 } else { 1 }
        $cpuMoeInput = Read-Host "Select CPU MoE layers (1-$($cpuMoeOptions.Count)), or press Enter for $defaultCpuMoeLabel"
        if ([string]::IsNullOrWhiteSpace($cpuMoeInput)) {
            $cpuMoeSelection = $defaultCpuMoeIndex
            $cpuMoeValid = $true
        }
        else {
            $cpuMoeSelection = 0
            $cpuMoeValid = [int]::TryParse($cpuMoeInput, [ref]$cpuMoeSelection)
        }
    } while (-not $cpuMoeValid -or $cpuMoeSelection -lt 1 -or $cpuMoeSelection -gt $cpuMoeOptions.Count)

    $cpuMoeMode = $cpuMoeOptions[$cpuMoeSelection - 1].Value
}
elseif ($isLikelyMoeModel) {
    # Quick launch / -CpuMoeMode override: no interactive picker.
    $cpuMoeMode = if ([string]::IsNullOrWhiteSpace($CpuMoeMode)) { "Auto" } else { $CpuMoeMode }
}

# Auto-calculate CPU MoE layers
if ($cpuMoeMode -eq "Auto") {
    $modelSizeGB = [math]::Round($selected.SizeMB / 1024, 1)
    # Prefer the VRAM detected at startup (nvidia-smi / Win32_VideoController);
    # fall back to engine-based estimates only when detection failed.
    $detectedVramGB = if ($hardware.PrimaryGpu -and $hardware.PrimaryGpu.VramGB -gt 0) { [double]$hardware.PrimaryGpu.VramGB } else { 0 }
    if ($detectedVramGB -gt 0) {
        # Reserve headroom for KV cache, compute buffers and the OS compositor.
        $vramGB = [math]::Max(4, [math]::Floor($detectedVramGB - 1.5))
    }
    elseif ($env:HIP_PATH -or $requiredEngine -eq "OfficialHIP" -or $requiredEngine -eq "ExpertsLaguna") {
        $vramGB = 14  # RX 7800 XT estimate, minus headroom
    }
    else {
        $vramGB = 12
    }
    if ($modelSizeGB -gt $vramGB) {
        # Model doesn't fit in VRAM - offload excess layers to CPU
        # DeepSeek 150B: fastest measured config uses --cpu-moe (all experts on CPU)
        if ($isDeepSeek) {
            $selectedCpuMoe = "99"
            if (-not $isQuickLaunch) {
                Write-Host "CPU MoE layers: Auto (99) - DeepSeek fastest config keeps all experts on CPU" -ForegroundColor Yellow
            }
        }
        else {
            $ratio = ($modelSizeGB - $vramGB) / $modelSizeGB
            $selectedCpuMoe = [math]::Min(99, [math]::Max(1, [math]::Ceiling($ratio * 48)))
            if (-not $isQuickLaunch) {
                Write-Host "CPU MoE layers: Auto ($selectedCpuMoe) - model ${modelSizeGB}GB > VRAM ${vramGB}GB" -ForegroundColor Yellow
            }
        }
    }
    else {
        $selectedCpuMoe = "0"
        if (-not $isQuickLaunch) {
            Write-Host "CPU MoE layers: 0 (model ${modelSizeGB}GB fits in VRAM ${vramGB}GB)" -ForegroundColor Green
        }
    }
}
elseif ($cpuMoeMode -eq "Custom") {
    do {
        $customInput = Read-Host "Enter CPU MoE layer count"
        $customValue = 0
        $customValid = [int]::TryParse($customInput, [ref]$customValue)
    } while (-not $customValid -or $customValue -lt 0)
    $selectedCpuMoe = [string]$customValue
}
else {
    $selectedCpuMoe = $cpuMoeMode
}

if (-not $isQuickLaunch -and $selectedCpuMoe -ne "0") {
    Write-Host "CPU MoE layers: $selectedCpuMoe" -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($ChatTemplateKwargs) -and -not $DryRun -and -not $isQuickLaunch) {
    $kwargsDefaultLabel = if ($requiredEngine -eq "TurboTan") { "TQ3 default disables thinking" } else { "none" }
    $kwargsInput = Read-Host "chat-template-kwargs JSON, or press Enter for $kwargsDefaultLabel"
    if (-not [string]::IsNullOrWhiteSpace($kwargsInput)) {
        $ChatTemplateKwargs = $kwargsInput
    }
}

# Reasoning effort prompt (all models)
$effectiveReasoningMode = ""
if (-not $DryRun -and -not $isQuickLaunch) {
    $reasoningOptions = @(
        [PSCustomObject]@{ Label = "Off"; Value = "off"; ChatKwargs = '{"enable_thinking":false}' },
        [PSCustomObject]@{ Label = "Low"; Value = "low"; ChatKwargs = '{"reasoning_effort":"low"}' },
        [PSCustomObject]@{ Label = "Medium"; Value = "medium"; ChatKwargs = '{"reasoning_effort":"medium"}' },
        [PSCustomObject]@{ Label = "High"; Value = "high"; ChatKwargs = '{"reasoning_effort":"high"}' }
    )
    Write-Host "Reasoning (thinking) mode:" -ForegroundColor Green
    for ($i = 0; $i -lt $reasoningOptions.Count; $i++) {
        $ro = $reasoningOptions[$i]
        Write-Host " [$($i+1)] $($ro.Label) - $($ro.ChatKwargs)"
    }
    Write-Host ""
    $defaultReasoning = "low"
    do {
        $reasoningInput = Read-Host "Select reasoning mode (1-4), or press Enter for $defaultReasoning"
        if ([string]::IsNullOrWhiteSpace($reasoningInput)) {
            $reasoningSelection = if ($defaultReasoning -eq "off") { 1 } else { 2 }
            $reasoningValid = $true
        }
        else {
            $reasoningSelection = 0
            $reasoningValid = [int]::TryParse($reasoningInput, [ref]$reasoningSelection)
        }
    } while (-not $reasoningValid -or $reasoningSelection -lt 1 -or $reasoningSelection -gt $reasoningOptions.Count)

    $selectedReasoning = $reasoningOptions[$reasoningSelection - 1]
    # Map reasoning selection to --reasoning flag (on/off only) and chat-template-kwargs
    if ($selectedReasoning.Value -eq "off") {
        $effectiveReasoningMode = "off"
    }
    else {
        # low/medium/high → reasoning on + reasoning_effort in chat-template-kwargs
        $effectiveReasoningMode = "on"
    }
    # Set chat-template-kwargs from reasoning selection if user didn't provide custom kwargs
    if ([string]::IsNullOrWhiteSpace($ChatTemplateKwargs)) {
        $effectiveChatTemplateKwargs = $selectedReasoning.ChatKwargs
    }
    Write-Host "Reasoning mode: $($selectedReasoning.Value) (--reasoning $effectiveReasoningMode)" -ForegroundColor Green
    Write-Host ""
}

# Merge with user-provided chat-template-kwargs (reasoning kwargs take precedence if no custom input)
if ([string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs)) {
    $effectiveChatTemplateKwargs = $ChatTemplateKwargs
}
if ([string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs) -and ($requiredEngine -eq "TurboTan" -or $ClientMode -eq "LlamaAgent")) {
    $effectiveChatTemplateKwargs = '{"enable_thinking":false}'
    if ([string]::IsNullOrWhiteSpace($effectiveReasoningMode)) {
        $effectiveReasoningMode = "off"
    }
}

# If user provided custom chat-template-kwargs, parse effectiveReasoningMode from it
if (-not [string]::IsNullOrWhiteSpace($ChatTemplateKwargs) -and [string]::IsNullOrWhiteSpace($effectiveReasoningMode)) {
    try {
        $chatTemplateOptions = $ChatTemplateKwargs | ConvertFrom-Json -ErrorAction Stop
        if ($chatTemplateOptions.enable_thinking -eq $false) {
            $effectiveReasoningMode = "off"
        }
        elseif ($chatTemplateOptions.reasoning_effort) {
            $effectiveReasoningMode = [string]$chatTemplateOptions.reasoning_effort
        }
        if (-not $isQuickLaunch) {
            Write-Host "chat-template-kwargs: $ChatTemplateKwargs" -ForegroundColor Green
            if ($effectiveReasoningMode) {
                Write-Host "reasoning mode: $effectiveReasoningMode" -ForegroundColor Green
            }
            Write-Host ""
        }
    }
    catch {
        Write-Host "ERROR: chat-template-kwargs must be valid JSON" -ForegroundColor Red
        exit 1
    }
}

$effectiveKCacheType = $selectedKCache.Type
$effectiveVCacheType = $selectedVCache.Type

# Keep prompt-cache RAM explicit. Long-context and larger-model runs receive
# smaller host-side cache budgets unless the caller overrides this parameter.
# The prompt cache lives in host RAM, so scale the default with detected RAM:
# on a 96GB machine the old fixed 2048-8192 MiB budgets left prompt reuse on
# the table. Override any time with -CacheRamMiB / LLAMADOCK_CACHE_RAM_MIB.
$effectiveCacheRamMiB = $CacheRamMiB
if ($effectiveCacheRamMiB -lt 0 -and $env:LLAMADOCK_CACHE_RAM_MIB) {
    $effectiveCacheRamMiB = [int]$env:LLAMADOCK_CACHE_RAM_MIB
}
if ($effectiveCacheRamMiB -lt 0) {
    if ($systemRamGB -ge 96) {
        $effectiveCacheRamMiB = 16384
        if ($selectedContext.Tokens -ge 65536) { $effectiveCacheRamMiB = 8192 }
    }
    elseif ($systemRamGB -ge 48) {
        $effectiveCacheRamMiB = 12288
        if ($selectedContext.Tokens -ge 65536) { $effectiveCacheRamMiB = 8192 }
    }
    else {
        $effectiveCacheRamMiB = 8192
        if ($selectedContext.Tokens -ge 65536) { $effectiveCacheRamMiB = 4096 }
        if ($selectedModelSizeGB -ge 20) { $effectiveCacheRamMiB = 2048 }
    }
}
if (-not $isQuickLaunch) {
    Write-Host "Prompt cache RAM: $effectiveCacheRamMiB MiB" -ForegroundColor Green
    Write-Host ""
}

if ($FlashAttentionMode -eq "Prompt") {
    Write-Host "Flash Attention:" -ForegroundColor Green
    Write-Host " [1] On - 対応時は最速"
    Write-Host " [2] Off - ヘッドサイズ非対応モデル向けの互換フォールバック"
    Write-Host ""

    do {
        $faInput = Read-Host "Select Flash Attention (1-2), or press Enter for On"
        if ([string]::IsNullOrWhiteSpace($faInput)) {
            $faSelection = 1
            $faValid = $true
        }
        else {
            $faSelection = 0
            $faValid = [int]::TryParse($faInput, [ref]$faSelection)
        }
    } while (-not $faValid -or $faSelection -lt 1 -or $faSelection -gt 2)

    if ($faSelection -eq 1) { $FlashAttentionMode = "On" }
    else { $FlashAttentionMode = "Off" }
}

if ($FlashAttentionMode -eq "Off") { $flashAttention = "off" }
else { $flashAttention = "on" }

# ExpertsLaguna: force FA off (ROCm SWA layer crash) for non-DeepSeek models.
# DeepSeek V4 Flash runs FA on with turbo4/Q4 KV on this fork (verified 11 tps).
if ($requiredEngine -eq "ExpertsLaguna" -and -not $isDeepSeek) {
    if ($flashAttention -eq "on") {
        Write-Host "ExpertsLaguna: Flash Attention forced OFF (ROCm SWA compatibility)" -ForegroundColor Yellow
        $flashAttention = "off"
    }
    # FA off requires non-quantized V cache (server validation)
    if ($effectiveVCacheType -notin @("f16", "bf16", "f32")) {
        Write-Host "ExpertsLaguna: V cache $effectiveVCacheType -> f16 (FA off requires non-quantized V)" -ForegroundColor Yellow
        $effectiveVCacheType = "f16"
    }
}

if (-not $isQuickLaunch) {
    Write-Host "Flash Attention: $flashAttention" -ForegroundColor Green
    $visionSummary = if ($visionMmprojPath) { if ($visionEnabled) { "on ($($visionMmprojPath.Name))" } else { "off (adapter found)" } } else { "n/a (no mmproj next to model)" }
    Write-Host "Vision: $visionSummary" -ForegroundColor Green
    Write-Host ""
}

if ($requiredEngine -ne "ExpertsLaguna" -and $flashAttention -eq "off" -and $effectiveVCacheType -notin @("f16", "bf16", "f32")) {
    Write-Host "ERROR: V cache quantization requires Flash Attention." -ForegroundColor Red
    Write-Host "Select Flash Attention On, or use V cache f16/bf16/f32." -ForegroundColor Red
    exit 1
}

# External draft model used by DSpark speculative decoding. Defined before the
# SpecMode prompt so the prompt can suggest DSpark/DFlash2 only when the draft exists.
$dsparkDraftModel = if ($env:LLAMADOCK_DSPARK_DRAFT) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_DSPARK_DRAFT)
}
else {
    Join-Path $ModelsBase "erlidev\Qwen3.8-27B-DSpark-GGUF\Qwen3.8-27B-DSpark-Q8_0.gguf"
}

# DFlash2 draft model: Qwen3.8-27B architecture (incoai Q8_0 or Q4_K_M).
$dflash2DraftModel = if ($env:LLAMADOCK_DFLASH2_DRAFT) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_DFLASH2_DRAFT)
}
else {
    Join-Path $ModelsBase "incoai\Qwen3.8-27B-DFlash2-GGUF\Qwen3.8-27B-DFlash2-Q8_0.gguf"
}

if ($SpecMode -eq "Prompt") {
    # Default suggestion: MTP models -> MtpNextN, Qwen3.8-27B with an
    # installed DSpark draft -> DSpark, DFlash2 draft -> DFlash2, everything else -> Off.
    $modelIsMtp = $selected.Name -match "(?i)MTP"
    $modelIsQwen27B = $selected.Name -match "(?i)Qwen3\.8-27B"
    $draftExists = Test-Path -LiteralPath $dsparkDraftModel
    $dflash2DraftExists = Test-Path -LiteralPath $dflash2DraftModel

    Write-Host "Speculative decoding mode:" -ForegroundColor Green
    Write-Host " [1] Off - normal decoding"
    if ($modelIsMtp) {
        Write-Host " [2] MTP/NextN - combined *_MTP.gguf self-draft (recommended for this model)" -ForegroundColor Cyan
    }
    else {
        Write-Host " [2] MTP/NextN - combined *_MTP.gguf self-draft"
    }
    if ($draftExists -and $modelIsQwen27B) {
        Write-Host " [3] DSpark - external draft GGUF (requires TurboTan engine; recommended for this model)" -ForegroundColor Cyan
    }
    elseif ($draftExists) {
        Write-Host " [3] DSpark - external draft GGUF (requires TurboTan engine)"
    }
    else {
        Write-Host " [3] DSpark - external draft GGUF (draft model not found; requires TurboTan engine)"
    }
    if ($dflash2DraftExists -and $modelIsQwen27B) {
        Write-Host " [4] DFlash2 - grouped dynamic convolution (requires DFlash2 engine; recommended for this model)" -ForegroundColor Cyan
    }
    elseif ($dflash2DraftExists) {
        Write-Host " [4] DFlash2 - grouped dynamic convolution (requires DFlash2 engine)"
    }
    else {
        Write-Host " [4] DFlash2 - grouped dynamic convolution (draft model not found; requires DFlash2 engine)"
    }
    Write-Host ""

    do {
        $defaultSpecChoice = if ($modelIsMtp) { 2 } elseif ($dflash2DraftExists -and $modelIsQwen27B) { 4 } elseif ($draftExists -and $modelIsQwen27B) { 3 } else { 1 }
        $defaultSpecLabel = switch ($defaultSpecChoice) {
            2 { "MTP/NextN" }
            3 { "DSpark" }
            4 { "DFlash2" }
            default { "Off" }
        }
        $specInput = Read-Host "Select speculative mode (1-4), or press Enter for $defaultSpecLabel"
        if ([string]::IsNullOrWhiteSpace($specInput)) {
            $specSelection = $defaultSpecChoice
            $specValid = $true
        }
        else {
            $specSelection = 0
            $specValid = [int]::TryParse($specInput, [ref]$specSelection)
        }
    } while (-not $specValid -or $specSelection -lt 1 -or $specSelection -gt 4)

    if ($specSelection -eq 1) { $SpecMode = "Off" }
    elseif ($specSelection -eq 2) { $SpecMode = "MtpNextN" }
    elseif ($specSelection -eq 3) { $SpecMode = "DSpark" }
    else { $SpecMode = "DFlash2" }
}

if (-not $isQuickLaunch) {
    Write-Host "Speculative decoding mode: $SpecMode" -ForegroundColor Green
    if ($SpecMode -eq "MtpNextN") {
        # Measured 2026-08-22: draft-mtp is O(n^2) in prompt length. Fast for
        # short prompts (<300 tok: ~16-29 t/s) but degrades hard on long ones
        # (>5K tok: ~3-6 t/s). Acceptance also swings daily (0.36-0.78).
        Write-Host "  note: MTP helps short prompts; for >5K-token contexts turn it Off" -ForegroundColor Yellow
        Write-Host "  (long-prompt decode drops to ~3-6 t/s). Coding with big files: use Off." -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($SpecMode -eq "MtpNextN" -and $selected.Name -notmatch "(?i)MTP") {
    Write-Host "ERROR: MTP/NextN mode expects a combined *_MTP.gguf model." -ForegroundColor Red
    Write-Host "Selected model: $($selected.Name)" -ForegroundColor Red
    exit 1
}

if ($SpecMode -eq "MtpNextN" -and $requiredEngine -eq "TurboTan") {
    Write-Host "ERROR: TurboTan TQ3_4S engine mode is not used for MTP/NextN in this launcher." -ForegroundColor Red
    Write-Host "Use a non-TurboTan engine with a combined *_MTP.gguf model." -ForegroundColor Red
    exit 1
}

if ($SpecMode -eq "DSpark") {
    if (-not (Test-Path -LiteralPath $dsparkDraftModel)) {
        Write-Host "ERROR: DSpark draft model not found: $dsparkDraftModel" -ForegroundColor Red
        Write-Host "Set LLAMADOCK_DSPARK_DRAFT to a DSpark draft GGUF, or install the erlidev Qwen3.8-27B-DSpark draft." -ForegroundColor Red
        exit 1
    }
    # The bundled erlidev draft is Qwen3.8-27B-architecture; warn when the
    # selected main model is something else (arch mismatch will not work).
    if ($selected.Name -notmatch "(?i)Qwen3\.8-27B") {
        Write-Host "WARNING: $dsparkDraftModel is a Qwen3.8-27B draft; main model arch must match." -ForegroundColor Yellow
    }
    # draft-dspark exists only in the TurboTan build; AtomicBot rejects it.
    if ($requiredEngine -ne "TurboTan") {
        Write-Host "DSpark mode requires the TurboTan engine (draft-dspark). Switching engine..." -ForegroundColor Yellow
        $requiredEngine = "TurboTan"
        $ServerPath = $TurboTanServerPath
    }
    if (-not (Test-Path -LiteralPath $ServerPath)) {
        Write-Host "ERROR: TurboTan engine not found at $ServerPath" -ForegroundColor Red
        Write-Host "Install the TurboTan build to use DSpark speculative decoding." -ForegroundColor Red
        exit 1
    }
}

if ($SpecMode -eq "DFlash2") {
    if (-not (Test-Path -LiteralPath $dflash2DraftModel)) {
        Write-Host "ERROR: DFlash2 draft model not found: $dflash2DraftModel" -ForegroundColor Red
        Write-Host "Set LLAMADOCK_DFLASH2_DRAFT to a DFlash2 draft GGUF, or install incoai/Qwen3.8-27B-DFlash2-GGUF." -ForegroundColor Red
        exit 1
    }
    # The DFlash2 draft is Qwen3.8-27B-architecture; warn when the
    # selected main model is something else (arch mismatch will not work).
    if ($selected.Name -notmatch "(?i)Qwen3\.8-27B") {
        Write-Host "WARNING: $dflash2DraftModel is a Qwen3.8-27B DFlash2 draft; main model arch must match." -ForegroundColor Yellow
    }
    # DFlash2 speculative decoding requires the DFlash2 fork build.
    if ($requiredEngine -ne "DFlash2") {
        Write-Host "DFlash2 mode requires the DFlash2 engine (ROCm 7.1 HIP). Switching engine..." -ForegroundColor Yellow
        $requiredEngine = "DFlash2"
        $ServerPath = $DFlash2ServerPath
    }
    if (-not (Test-Path -LiteralPath $ServerPath)) {
        Write-Host "ERROR: DFlash2 engine not found at $ServerPath" -ForegroundColor Red
        Write-Host "Build the DFlash2 fork (z-lab/llama.cpp-fork dflash2 branch) with ROCm 7.1." -ForegroundColor Red
        exit 1
    }
}

# Prompt MCP helper selection
$mcpOptions = @(
    [PSCustomObject]@{ Label = "None"; Value = "None"; Note = "recommended for Cline stability" },
    [PSCustomObject]@{ Label = "Light"; Value = "Light"; Note = "web search, filesystem, memory" }
)

if ($ClientMode -notin @("Cline", "WebUI")) {
    $selectedMcp = "None"
}
elseif ($McpMode -eq "Prompt") {
    Write-Host "MCP helper servers:" -ForegroundColor Green
    for ($i = 0; $i -lt $mcpOptions.Count; $i++) {
        $mcp = $mcpOptions[$i]
        Write-Host " [$($i+1)] $($mcp.Label) - $($mcp.Note)"
    }
    Write-Host ""

    do {
        $defaultMcpLabel = if ($ClientMode -eq "WebUI") { "Light" } else { "None" }
        $mcpInput = Read-Host "Select MCP mode (1-2), or press Enter for $defaultMcpLabel"
        if ([string]::IsNullOrWhiteSpace($mcpInput)) {
            $mcpSelection = if ($ClientMode -eq "WebUI") { 2 } else { 1 }
            $mcpValid = $true
        }
        else {
            $mcpSelection = 0
            $mcpValid = [int]::TryParse($mcpInput, [ref]$mcpSelection)
        }
    } while (-not $mcpValid -or $mcpSelection -lt 1 -or $mcpSelection -gt $mcpOptions.Count)

    $selectedMcp = $mcpOptions[$mcpSelection - 1].Value
}
else {
    $selectedMcp = $McpMode
}

if ($isQuickLaunch) {
    Write-Host ""
    Write-Host "  READY TO LAUNCH" -ForegroundColor Green
    Write-Host "  $launchLabel" -ForegroundColor Cyan
    Write-Host "  $($selectedContext.Label) context | KV K:$($selectedKCache.Label) / V:$($selectedVCache.Label) | GPU:$serverOffload" -ForegroundColor DarkGray
    Write-Host "  $requiredEngine | Flash Attention:$flashAttention | Cache RAM:$effectiveCacheRamMiB MiB" -ForegroundColor DarkGray
    Write-Host ""
}
else {
    Write-Host "MCP helpers: $selectedMcp" -ForegroundColor Green
    Write-Host ""
}

# Get model short name for -a flag
$modelShort = $selected.Name -replace "\.gguf$", "" -replace "-", "_"

# Start server
$startFilePath = $ServerPath
$args = @()
$disableTurboAutoAsymmetric = $false

$args = @(
    "-m", $selected.FullName,
    "-a", $modelShort,
    "--host", "127.0.0.1",
    "--port", "8080",
    "-ngl", "$serverOffload",
    "-c", "$($selectedContext.Tokens)",
    "-np", "1",
    "-ctk", "$effectiveKCacheType",
    "-ctv", "$effectiveVCacheType",
    "-fa", "$flashAttention",
    "--jinja"
)

# The LongCat fork's server does not accept --no-ui.
if ($requiredEngine -ne "LongCat") {
    $args += "--no-ui"
}

# Opt-in vision: image input via the mmproj adapter picked during setup.
if ($visionEnabled -and $visionMmprojPath) {
    $args += @("--mmproj", $visionMmprojPath.FullName)
}

# Prefill micro-batch override (see param comment). VRAM headroom is tight on
# 16 GB cards, so this stays opt-in; verify placement with the GPU probe.
$ubatchRaw = "$env:LLAMADOCK_UBATCH".Trim()
$envUbatch = if ($ubatchRaw -match "^\d+$") { [int]$Matches[0] } else { 0 }
$effectiveUbatch = if ($Ubatch -gt 0) { $Ubatch } elseif ($envUbatch -gt 0) { $envUbatch } else { 0 }
if ($effectiveUbatch -gt 4096) {
    # llama-server rejects absurd micro-batch values; clamp so an env/param
    # typo cannot abort the whole launch.
    Write-Host "Ubatch: clamping $effectiveUbatch -> 4096" -ForegroundColor Yellow
    $effectiveUbatch = 4096
}
if ($effectiveUbatch -gt 0) {
    $args += @("-ub", "$effectiveUbatch")
}

if ($effectiveReasoningMode) {
    $args += @("--reasoning", $effectiveReasoningMode)
}

$args += @("--cache-ram", "$effectiveCacheRamMiB")

if ($ClientMode -eq "WebUI") {
    $args += @("--tools", "all")
}

if (-not [string]::IsNullOrWhiteSpace($selectedMoeExperts)) {
    $args += @("--override-kv", "llama.expert_used_count=int:$selectedMoeExperts")
}

if (-not [string]::IsNullOrWhiteSpace($selectedCpuMoe) -and $selectedCpuMoe -ne "0") {
    $args += @("--n-cpu-moe", "$selectedCpuMoe")
}

if ($isDeepSeek) {
    $args += "--no-mmap"
}

if ($SpecMode -eq "MtpNextN") {
    # MTP self-draft: do NOT pass -md (same model). The spec_mtp branch in
    # llama.cpp creates a lightweight draft context from model_tgt directly,
    # avoiding a second full model load that would double memory usage.
    $args += @(
        "--spec-type", "draft-mtp",
        "--spec-draft-n-max", "2",
        "--spec-draft-n-min", "1",
        "-ngld", "$serverOffload",
        "-ctkd", "$effectiveKCacheType",
        "-ctvd", "$effectiveVCacheType"
    )
}

if ($CpuFfnLayers -ne "") {
    # Dense FFN CPU offload (PR ggml-org/llama.cpp#26622). Probe the binary
    # first: unknown flags abort llama-server at startup (see turbo3/DSpark
    # history). Off by default — measured TG -65..-91%; the use case is
    # freeing VRAM for longer contexts, not speed.
    # HIP builds cannot even launch --help without the ROCm DLLs on PATH,
    # which would make the probe misread "no output" as "unsupported".
    $oldProbePath = $env:PATH
    try {
        $hipRoot = "C:\Program Files\AMD\ROCm"
        if (Test-Path -LiteralPath $hipRoot) {
            $latestHip = $null
            foreach ($d in (Get-ChildItem -LiteralPath $hipRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($null -eq $latestHip -or $d.Name -gt $latestHip.Name) { $latestHip = $d }
            }
            if ($latestHip) { $env:PATH = "$(Join-Path $latestHip.FullName 'bin');$env:PATH" }
        }
        $ffnHelp = & $ServerPath --help 2>&1 | Out-String
    }
    finally {
        $env:PATH = $oldProbePath
    }
    if ($LASTEXITCODE -ne 0 -or $ffnHelp -notmatch "--n-cpu-ffn") {
        Write-Host "ERROR: -CpuFfnLayers requires an engine build with PR ggml-org/llama.cpp#26622 (--n-cpu-ffn)." -ForegroundColor Red
        Write-Host "Engine: $ServerPath" -ForegroundColor Red
        exit 1
    }
    if ($CpuFfnLayers -eq "all") {
        $args += @("--cpu-ffn")
    }
    elseif ($CpuFfnLayers -match "^\d+$") {
        $args += @("--n-cpu-ffn", "$CpuFfnLayers")
    }
    else {
        Write-Host "ERROR: -CpuFfnLayers must be a number or 'all' (got: $CpuFfnLayers)." -ForegroundColor Red
        exit 1
    }
}

if ($SpecMode -eq "DSpark") {
    $args += @(
        "--spec-type", "draft-dspark",
        "--spec-draft-model", "$dsparkDraftModel",
        "--spec-draft-n-max", "7",
        "-ngld", "99"
    )
}

if ($SpecMode -eq "DFlash2") {
    $args += @(
        "--spec-type", "draft-dflash",
        "--spec-draft-model", "$dflash2DraftModel",
        "--spec-draft-n-max", "8",
        "-ngld", "99"
    )
}

$disableTurboAutoAsymmetric = $effectiveKCacheType -like "turbo*"

if ($selectedMcp -eq "Light") {
    $args += "--webui-mcp-proxy"
}

if ($DryRun) {
    $dryRunServerLabel = "llama-server would start with:"
    Write-Host "DRY RUN: $dryRunServerLabel" -ForegroundColor Yellow
    Write-Host "Engine: $requiredEngine" -ForegroundColor Yellow
    Write-Host $startFilePath
    Write-Host ($args -join " ")
    if (-not [string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs)) {
        Write-Host "DRY RUN: LLAMA_ARG_CHAT_TEMPLATE_KWARGS=$effectiveChatTemplateKwargs would be set." -ForegroundColor Yellow
    }
    if ($disableTurboAutoAsymmetric) {
        Write-Host "DRY RUN: TURBO_AUTO_ASYMMETRIC=0 would be set so the selected K cache is not silently changed to q8_0." -ForegroundColor Yellow
    }
    Write-Host ""
    if ($ClientMode -eq "Cline") {
        Write-Host "DRY RUN: Cline would be configured with model:" -ForegroundColor Yellow
        Write-Host $modelShort
        Write-Host "DRY RUN: Cline would open" -ForegroundColor Yellow
    }
    elseif ($ClientMode -eq "OpenCode") {
        Write-Host "DRY RUN: OpenCode would use model:" -ForegroundColor Yellow
        Write-Host "llamadock/$modelShort"
        Write-Host "DRY RUN: OpenCode would open" -ForegroundColor Yellow
    }
    elseif ($ClientMode -eq "LlamaAgent") {
        Write-Host "DRY RUN: llama-agent Deep Research would open with pre-collected web evidence:" -ForegroundColor Yellow
        Write-Host $LlamaAgentPath
        Write-Host "--backend http --server-url $ClientBaseUrl --reasoning off --max-iterations 8 --system-prompt-file $LlamaAgentResearchSystemPath -m $($selected.FullName)"
    }
    elseif ($ClientMode -eq "ComfyUI") {
        Write-Host "DRY RUN: ComfyUI would start on:" -ForegroundColor Yellow
        Write-Host "http://127.0.0.1:8188"
    }
    elseif ($ClientMode -eq "DeepSeekHarness") {
        Write-Host "DRY RUN: DeepSeek Harness would open with DEEPSEEK_BASE_URL=$ClientBaseUrl/v1 DEEPSEEK_API_KEY=not-needed" -ForegroundColor Yellow
        Write-Host "DRY RUN: http://127.0.0.1:3080 (dsh web)" -ForegroundColor Yellow
    }
    else {
        Write-Host "DRY RUN: native Computer would open:" -ForegroundColor Yellow
        Write-Host $ComputerUrl
    }
    exit 0
}

if (-not $DryRun) {
    $serverReady = Test-ServerReady
    $portBusy = Test-PortBusy

    if ($serverReady) {
        $existingModel = Get-ExistingServerModel
        Set-ClientBaseUrl -ExpectedModelId $existingModel | Out-Null
        $modelLabel = if ([string]::IsNullOrWhiteSpace($existingModel)) { "(unknown model)" } else { $existingModel }

        Write-Host "Existing llama-server is already running at $ServerBaseUrl" -ForegroundColor Yellow
        Write-Host "Existing model: $modelLabel" -ForegroundColor Yellow
        Write-Host "Selected model: $($selected.Name)" -ForegroundColor Yellow
        Write-Host ""

        if ($ExistingServerMode -eq "Prompt") {
            Write-Host "Server action:" -ForegroundColor Green
            Write-Host " [1] 選択したモデルに切り替え - 既存サーバーを先に停止"
            Write-Host " [2] 既存サーバーを使用"
            Write-Host " [3] 終了"
            Write-Host ""

            do {
                $serverInput = Read-Host "Select server action (1-3), or press Enter to Switch"
                if ([string]::IsNullOrWhiteSpace($serverInput)) {
                    $serverSelection = 1
                    $serverValid = $true
                }
                else {
                    $serverSelection = 0
                    $serverValid = [int]::TryParse($serverInput, [ref]$serverSelection)
                }
            } while (-not $serverValid -or $serverSelection -lt 1 -or $serverSelection -gt 3)

            if ($serverSelection -eq 1) { $ExistingServerMode = "StartNew" }
            elseif ($serverSelection -eq 2) { $ExistingServerMode = "UseExisting" }
            else { $ExistingServerMode = "Quit" }
        }

        if ($ExistingServerMode -eq "UseExisting") {
            if ($ClientMode -eq "Cline") {
                Set-ClineLocalModel -ModelName $existingModel
                Open-ClineClient
                Write-Host ""
            }
            elseif ($ClientMode -eq "OpenCode") {
                Open-OpenCodeClient -ModelName $existingModel
                Write-Host ""
            }
            elseif ($ClientMode -eq "LlamaAgent") {
                Open-LlamaAgentClient -ModelPath $selected.FullName
            }
            elseif ($ClientMode -eq "ComfyUI") {
                # ComfyUI runs its own server on :8188 and does not depend on the
                # llama-server that is already up — open it regardless of the
                # model that was selected so the workspace stays usable.
                $lastClientProcess = Open-ComfyUIClient
            }
            else {
                Open-OpenWebUIClient
            }
            Write-Host "Using existing server at $ClientBaseUrl (upstream $ServerBaseUrl)" -ForegroundColor Green
            exit 0
        }
        elseif ($ExistingServerMode -eq "Quit") {
            exit 0
        }

        Write-Host "Switching to selected model..." -ForegroundColor Yellow
        Write-Host ""
    }
    elseif ($portBusy) {
        Write-Host "Port 8080 is already in use, but $ServerBaseUrl/health is not responding." -ForegroundColor Yellow
        Write-Host "Starting the selected model on the same port will probably fail." -ForegroundColor Yellow
        Write-Host ""

        if ($ExistingServerMode -eq "Prompt") {
            Write-Host "Server action:" -ForegroundColor Green
            Write-Host " [1] 終了 - 推奨"
            Write-Host " [2] 選択したモデルを強制起動"
            Write-Host ""

            do {
                $busyInput = Read-Host "Select server action (1-2), or press Enter to Quit"
                if ([string]::IsNullOrWhiteSpace($busyInput)) {
                    $busySelection = 1
                    $busyValid = $true
                }
                else {
                    $busySelection = 0
                    $busyValid = [int]::TryParse($busyInput, [ref]$busySelection)
                }
            } while (-not $busyValid -or $busySelection -lt 1 -or $busySelection -gt 2)

            if ($busySelection -eq 1) { $ExistingServerMode = "Quit" }
            else { $ExistingServerMode = "StartNew" }
        }

        if ($ExistingServerMode -ne "StartNew") {
            exit 0
        }
    }
}

if (-not (Stop-LlamaDockSupervisor)) {
    exit 1
}

if (Test-PortBusyAt -Port $GatewayPort) {
    Write-Host "Gateway port $GatewayPort is occupied; attempting cleanup..." -ForegroundColor Yellow
    if (-not (Stop-ServerOnPort -Port $GatewayPort)) {
        exit 1
    }
}

if (Test-PortBusy) {
    if (-not (Stop-ServerOnPort -Port 8080)) {
        exit 1
    }
}

if ($selectedMcp -eq "Light") {
    Write-Host "Starting lightweight local MCP servers..." -ForegroundColor Cyan
    & "$PSScriptRoot\mcp-all-light.bat"
    Write-Host ""
}

function Wait-VramRelease {
    # After stopping a previous llama-server, give Windows/ROCm a moment to
    # release dedicated VRAM. The next launch's -ngl auto fit reads live free
    # VRAM, so starting too early can silently degrade placement to
    # CPU-heavy inference (observed 2026-08-22: 132 s per Cline request).
    param([int]$TimeoutSec = 20)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        $llama = Get-Process llama-server -ErrorAction SilentlyContinue
        if (-not $llama) { return }
        Start-Sleep -Seconds 1
    }
}

function Test-GpuOffloadProbe {
    # Quick sanity check after the server is ready: generate a few tokens and
    # estimate decode speed. A full-GPU dense-27B class model answers far
    # faster than the CPU-fallback placement that -ngl auto can quietly pick
    # when free VRAM was low at launch.
    param([int]$MaxTokens = 24)
    try {
        $prompt = '{"messages":[{"role":"user","content":"hi"}],"max_tokens":' + $MaxTokens + ',"temperature":0}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($prompt)
        $t0 = Get-Date
        $resp = Invoke-RestMethod "$ServerBaseUrl/v1/chat/completions" -Method Post `
            -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 120
        $wall = ((Get-Date) - $t0).TotalSeconds
        $toks = $resp.usage.completion_tokens
        if ($toks -gt 0) {
            return @{ tps = [math]::Round($toks / $wall, 1); wall = [math]::Round($wall, 1); tokens = $toks }
        }
    }
    catch {}
    return $null
}

Wait-VramRelease -TimeoutSec 20

Write-Host "Starting llama-server under the LlamaDock supervisor..." -ForegroundColor Blue
if (-not [string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs)) {
    $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = $effectiveChatTemplateKwargs
}
else {
    Remove-Item Env:\LLAMA_ARG_CHAT_TEMPLATE_KWARGS -ErrorAction SilentlyContinue
}
if ($disableTurboAutoAsymmetric) {
    $env:TURBO_AUTO_ASYMMETRIC = "0"
}
$proc = $null
$serverArgumentsPath = Join-Path $PSScriptRoot "mcp-data\server-supervisor\server-arguments.json"
New-Item -ItemType Directory -Path (Split-Path -Parent $serverArgumentsPath) -Force | Out-Null
Write-Utf8NoBom -Path $serverArgumentsPath -Value ($args | ConvertTo-Json -Compress)
$supervisorScript = Join-Path $PSScriptRoot "tools\llamadock-server-supervisor.ps1"
if (-not (Test-Path -LiteralPath $supervisorScript)) {
    Write-Host "ERROR: LlamaDock server supervisor was not found: $supervisorScript" -ForegroundColor Red
    exit 1
}
$supervisorArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $supervisorScript,
    "-ServerPath", $startFilePath,
    "-ArgumentsPath", $serverArgumentsPath,
    "-Root", $PSScriptRoot,
    "-GatewayPort", $GatewayPort,
    "-UpstreamPort", 8080,
    "-LogDir", (Join-Path $PSScriptRoot "logs")
)
# Opt-in resilience: without -AutoRestart a manually killed llama-server
# stays down and the supervisor shuts the gateway and itself cleanly.
if ($AutoRestart) {
    $supervisorArgs += "-AutoRestartServer"
}
# Keep the supervisor in a normal console so the user can see and control
# the server session. Ctrl+C in that console reaches the supervisor's
# finally block, which stops llama-server and the gateway cleanly.
$proc = Start-Process -FilePath "powershell.exe" -ArgumentList $supervisorArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Normal
Write-Host "LlamaDock server console opened (supervisor PID $($proc.Id)). Press Ctrl+C in that window to stop llama-server." -ForegroundColor Cyan

Write-Host "Waiting for server to be ready..." -NoNewline -ForegroundColor Yellow
# A 50+ GiB MoE can need several minutes to map weights, fit VRAM, and
# publish /v1/models. Keep the normal path quick, but do not make the user
# think a heavy model failed while it is still loading.
$maxWait = if ($selectedModelSizeGB -ge 50) { 180 } elseif ($selectedModelSizeGB -ge 20) { 120 } else { 60 }
$ready = $false
for ($i = 0; $i -lt $maxWait; $i++) {
    Start-Sleep -Seconds 2
    # llama-server publishes the -a alias as the model id, so we can verify the
    # freshly started server is actually serving the selected model.
    $expectedReadyModel = $modelShort
    $directReady = Test-ServerReady -ExpectedModelId $expectedReadyModel
    $gatewayReady = Test-GatewayReady -ExpectedModelId $expectedReadyModel
    if ($directReady -and $gatewayReady) {
        $ready = $true
        Set-ClientBaseUrl -ExpectedModelId $expectedReadyModel | Out-Null
        Write-Host " Done!" -ForegroundColor Green
        break
    }
    if ($i % 5 -eq 4) { Write-Host "." -NoNewline -ForegroundColor Yellow }
}

if (-not $ready) {
    Write-Host ""
    Write-Host "ERROR: Server did not become fully ready within $($maxWait*2)s" -ForegroundColor Red
    Write-Host "Check logs under $PSScriptRoot\logs and the supervisor state." -ForegroundColor Yellow
    Save-RunResult -Model $selected -Engine $requiredEngine -Preset $PresetMode -Client $ClientMode -ContextTokens $selectedContext.Tokens -KCache $effectiveKCacheType -VCache $effectiveVCacheType -Offload $selectedOffload -FlashAttention $flashAttention -CacheRamMiB $effectiveCacheRamMiB -Status "fail" -Message "Server did not become ready"
    exit 1
}
else {
    if ($ClientMode -eq "Cline") {
        Set-ClineLocalModel -ModelName $modelShort
    }
    Save-RunResult -Model $selected -Engine $requiredEngine -Preset $PresetMode -Client $ClientMode -ContextTokens $selectedContext.Tokens -KCache $effectiveKCacheType -VCache $effectiveVCacheType -Offload $selectedOffload -FlashAttention $flashAttention -CacheRamMiB $effectiveCacheRamMiB -Status "success" -Message "Server became ready"
}

if (-not $SkipGpuProbe) {
    Write-Host "GPU offload check..." -NoNewline -ForegroundColor Yellow
    $gpuProbe = Test-GpuOffloadProbe
    if ($null -eq $gpuProbe) {
        Write-Host " skipped (probe failed)" -ForegroundColor DarkGray
    }
    elseif ($gpuProbe.tps -lt 8) {
        Write-Host ""
        Write-Host "WARNING: decode speed is only $($gpuProbe.tps) t/s — GPU offload looks INEFFECTIVE." -ForegroundColor Red
        Write-Host "  '-ngl auto' placed layers from FREE VRAM at launch time. Close VRAM-heavy apps," -ForegroundColor Yellow
        Write-Host "  or relaunch with an explicit layer count: llamadock.bat ... -NglLayers <n>" -ForegroundColor Yellow
        Write-Host "  (e.g. -NglLayers 64 for a 64-layer model forces full-GPU placement)." -ForegroundColor Yellow
    }
    else {
        Write-Host " ok ($($gpuProbe.tps) t/s)" -ForegroundColor Green
    }
}

Write-Host ""
$lastClientProcess = Open-WorkspaceClient -Mode $ClientMode -ModelPath $selected.FullName -ModelName $modelShort

Write-Host ""
Write-Host "Launch summary" -ForegroundColor Cyan
Write-Host "--------------" -ForegroundColor Cyan
Write-Host " Endpoint     $ClientBaseUrl" -ForegroundColor Green
if ($ClientBaseUrl -ne $ServerBaseUrl) {
    Write-Host " Upstream      $ServerBaseUrl" -ForegroundColor DarkGray
}
Write-Host " Workspace    $ClientMode" -ForegroundColor Green
Write-Host " Model        $($selected.Name)" -ForegroundColor Green
Write-Host " Runtime      $requiredEngine" -ForegroundColor Green
Write-Host " Context      $($selectedContext.Label) ($($selectedContext.Tokens) tokens)" -ForegroundColor Green
Write-Host " Cache        K=$effectiveKCacheType, V=$effectiveVCacheType" -ForegroundColor Green
Write-Host " Prompt cache $effectiveCacheRamMiB MiB" -ForegroundColor Green
Write-Host " Flash Attn   $flashAttention" -ForegroundColor Green
Write-Host " Speculative  $SpecMode" -ForegroundColor Green
Write-Host " Offload      $selectedOffload" -ForegroundColor Green
Write-Host " MCP          $selectedMcp" -ForegroundColor Green
Write-Host ""

while ($true) {
    if ($lastClientProcess) {
        Write-Host "Waiting for the workspace window to close..." -ForegroundColor DarkGray
        Wait-Process -Id $lastClientProcess.Id -ErrorAction SilentlyContinue
    }
    else {
        Read-Host "Press Enter when you are ready to return to LlamaDock" | Out-Null
    }

    $sessionAction = Select-WorkspaceForSession
    switch ($sessionAction[0]) {
        "relaunch" {
            $lastClientProcess = Open-WorkspaceClient -Mode $ClientMode -ModelPath $selected.FullName -ModelName $modelShort
            continue
        }
        "switch" {
            $ClientMode = $sessionAction[1]
            $lastClientProcess = Open-WorkspaceClient -Mode $ClientMode -ModelPath $selected.FullName -ModelName $modelShort
            continue
        }
        "change-model" {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            if ($lastClientProcess -and -not $lastClientProcess.HasExited) { Stop-Process -Id $lastClientProcess.Id -Force -ErrorAction SilentlyContinue }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
            exit $LASTEXITCODE
        }
        "stop" {
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            if ($lastClientProcess -and -not $lastClientProcess.HasExited) { Stop-Process -Id $lastClientProcess.Id -Force -ErrorAction SilentlyContinue }
            if ($script:StopAllOnExit) { Stop-H3Stack }
            exit 0
        }
        default { exit 0 }
    }
}
