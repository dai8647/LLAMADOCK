# select-model.ps1 - LlamaDock local GGUF workspace launcher

param(
    [switch]$DryRun,
    [int]$ModelIndex = 0,
    [int]$ContextIndex = 0,
    [int]$KvIndex = 0,
    [int]$KCacheIndex = 0,
    [int]$VCacheIndex = 0,
    [int]$CacheRamMiB = -1,
    [ValidateSet("Prompt", "Manual", "ClineCoding", "OpenCodeCoding", "OpenCodeHarness", "OpenClaudeCoding", "LlamaAgentResearch", "DeepResearchLight", "DeepResearchStandard", "DeepResearchHeavy", "WebUIChat")]
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
    [ValidateSet("Prompt", "Off", "MtpNextN", "DSpark")]
    [string]$SpecMode = "Prompt",
    [ValidateSet("Prompt", "Auto", "2", "3", "4", "6", "8", "Custom")]
    [string]$MoeExpertsMode = "Prompt",
    [string]$MoeExpertsCount = "",
    [ValidateSet("Prompt", "UseExisting", "StartNew", "Quit")]
    [string]$ExistingServerMode = "Prompt",
    [ValidateSet("Prompt", "WebUI", "Cline", "OpenCode", "OpenClaude", "DeepResearch", "LlamaAgent", "ComfyUI")]
    [string]$ClientMode = "Prompt",
    [ValidateSet("Auto", "AtomicBot", "TurboTan", "OfficialVulkan", "OfficialHIP", "OfficialCPU", "DeepSeekDS4", "PrismBonsai", "ExpertsLaguna", "LongCat")]
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
elseif (Test-Path "C:\llama-tq3\build-rocm71\bin\llama-server.exe") {
    "C:\llama-tq3\build-rocm71\bin\llama-server.exe"
}
else {
    "C:\llama-tq3\build\bin\llama-server.exe"
}$TurboTanServerPath = if ($env:LLAMA_TQ3_TURBOTAN_SERVER) {
    $env:LLAMA_TQ3_TURBOTAN_SERVER
}
elseif (Test-Path "C:\Users\dai86\Downloads\turbo-tan-llama.cpp-tq3-check\build-rocm71\bin\llama-server.exe") {
    "C:\Users\dai86\Downloads\turbo-tan-llama.cpp-tq3-check\build-rocm71\bin\llama-server.exe"
}
elseif (Test-Path "C:\llama-tq3-turbotan\build\bin\llama-server.exe") {
    "C:\llama-tq3-turbotan\build\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\turbo-tan-llama.cpp-tq3-check\build-rocm\bin\llama-server.exe"
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
$Ds4Root = if ($env:LLAMADOCK_DS4_ROOT) { $env:LLAMADOCK_DS4_ROOT } else { "C:\Users\dai86\Downloads\ds4-for-reaped" }
$Ds4ServerPath = if ($env:LLAMADOCK_DS4_SERVER) { $env:LLAMADOCK_DS4_SERVER } else { Join-Path $Ds4Root "ds4-server" }
# PrismML-Eng llama.cpp fork for Ternary/Bonsai Q2_0 (group 128) GGUF models.
# HIP build first (RX 7800 XT gfx1101), Vulkan/CPU fallback comme pour OfficialVulkan/OfficialCPU.
$PrismBonsaiServerPath = if ($env:LLAMA_TQ3_PRISM_BONSAI_SERVER) {
    $env:LLAMA_TQ3_PRISM_BONSAI_SERVER
}
elseif (Test-Path "C:\Users\dai86\Downloads\prism-llama.cpp\build-rocm71\bin\llama-server.exe") {
    "C:\Users\dai86\Downloads\prism-llama.cpp\build-rocm71\bin\llama-server.exe"
}
elseif (Test-Path "C:\Users\dai86\Downloads\prism-llama.cpp\build-win-vulkan\bin\llama-server.exe") {
    "C:\Users\dai86\Downloads\prism-llama.cpp\build-win-vulkan\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\Downloads\prism-llama.cpp\build\bin\llama-server.exe"
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
$ModelsBase = "C:\Users\dai86\.lmstudio\models"
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
$OdysseusRoot = "C:\Users\dai86\Downloads\odysseus"
$OdysseusPort = 7000
$OdysseusBaseUrl = "http://127.0.0.1:$OdysseusPort"
$LegacyDeepResearchPort = 5000
$ModelNotesPath = Join-Path $PSScriptRoot "model-notes.json"
$RunResultsPath = Join-Path $PSScriptRoot "mcp-data\run-results.json"
$script:ClineDataDir = if ($env:LLAMADOCK_CLINE_DATA_DIR) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_CLINE_DATA_DIR)
}
else {
    Join-Path $PSScriptRoot "mcp-data\cline"
}
$LlamaAgentPath = "C:\Users\dai86\llama-agent\build\bin\llama-agent.exe"
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

    if ($isDs4Engine) {
        $script:ClientBaseUrl = $ServerBaseUrl
        return $script:ClientBaseUrl
    }
    if (Test-GatewayReady -ExpectedModelId $ExpectedModelId) {
        $script:ClientBaseUrl = $GatewayBaseUrl
        return $script:ClientBaseUrl
    }

    $script:ClientBaseUrl = $ServerBaseUrl
    return $script:ClientBaseUrl
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)

    if ($WindowsPath -match "^([A-Za-z]):\\(.*)$") {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace "\\", "/"
        return "/mnt/$drive/$rest"
    }

    return $WindowsPath
}

function Quote-WslArg {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
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
        [double]$RamGB,
        [bool]$IsDs4
    )

    if ($IsDs4) {
        return 32768
    }
    if ($RamGB -le 0) {
        return 131072
    }

    $reserveGB = 10
    $availableForKv = [math]::Max(0, $RamGB - $reserveGB - $ModelSizeGB)
    $kvPer32kGB = [math]::Max(4, $ModelSizeGB * 0.22)
    $maxTokens = [math]::Floor(($availableForKv / $kvPer32kGB) * 32768)

    if ($maxTokens -lt 8192) { return 8192 }
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
    # Ternary/Bonsai Q2_0 (group 128) GGUF: needs PrismML-Eng/llama.cpp fork.
    # Mainline llama.cpp cannot load these. Match before DeepSeek/TQ3.
    if ($modelText -match "(?i)Ternary|Bonsai") {
        return "PrismBonsai"
    }

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

function Set-DeepResearchModeDefaults {
    param([string]$Mode)

    if ($Mode -eq "Auto") {
        return
    }

    if ($Mode -eq "Light") {
        $script:ResearchExtractionConcurrency = 1
        $script:ResearchSearchResultCount = 3
        $script:ResearchMaxTokens = 4096
        $script:ResearchExtractionMaxTokens = 1024
        $script:ResearchExtractionTimeoutSeconds = 45
        $script:ResearchPlanningTimeoutSeconds = 45
        $script:ResearchQueryTimeoutSeconds = 45
        $script:ResearchRunTimeoutSeconds = 420
    }
    elseif ($Mode -eq "Heavy") {
        $script:ResearchExtractionConcurrency = 1
        $script:ResearchSearchResultCount = 6
        $script:ResearchMaxTokens = 8192
        $script:ResearchExtractionMaxTokens = 2048
        $script:ResearchExtractionTimeoutSeconds = 90
        $script:ResearchPlanningTimeoutSeconds = 90
        $script:ResearchQueryTimeoutSeconds = 90
        $script:ResearchRunTimeoutSeconds = 1200
    }
    else {
        $script:ResearchExtractionConcurrency = 1
        $script:ResearchSearchResultCount = 5
        $script:ResearchMaxTokens = 6144
        $script:ResearchExtractionMaxTokens = 1536
        $script:ResearchExtractionTimeoutSeconds = 60
        $script:ResearchPlanningTimeoutSeconds = 60
        $script:ResearchQueryTimeoutSeconds = 60
        $script:ResearchRunTimeoutSeconds = 900
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

function Invoke-OdysseusForm {
    param(
        [string]$Path,
        [hashtable]$Fields
    )

    $body = ConvertTo-FormBody -Fields $Fields
    return Invoke-RestMethod -Uri "$OdysseusBaseUrl$Path" -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body -TimeoutSec 30 -ErrorAction Stop
}

function Invoke-OdysseusDelete {
    param([string]$Path)

    return Invoke-RestMethod -Uri "$OdysseusBaseUrl$Path" -Method Delete -TimeoutSec 30 -ErrorAction Stop
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
    param(
        [string]$ModelName,
        [ValidateSet("coding", "research-readonly")]
        [string]$Mode = "coding"
    )

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
        default_agent = if ($Mode -eq "research-readonly") { "research-readonly" } else { "coding" }
        share = "disabled"
        shell = "pwsh"
        permission = if ($Mode -eq "research-readonly") {
            [ordered]@{ edit = "deny"; bash = "deny"; webfetch = "allow" }
        }
        else {
            [ordered]@{ edit = "allow"; bash = "ask"; webfetch = "ask" }
        }
        tools = if ($Mode -eq "research-readonly") {
            [ordered]@{ write = $false; edit = $false; bash = $false }
        }
        else {
            [ordered]@{ write = $true; edit = $true; bash = $true }
        }
        agent = [ordered]@{
            coding = [ordered]@{
                description = "LlamaDock coding agent with user-approved shell operations"
                prompt = "Work on the local project. Explain changes, keep edits scoped, and ask before destructive shell commands."
                tools = [ordered]@{ write = $true; edit = $true; bash = $true }
            }
            "research-readonly" = [ordered]@{
                description = "Read-only web research agent; never edit files or run shell commands"
                prompt = "Research using web evidence and return cited findings. Do not modify files, run shell commands, or claim unverified facts."
                tools = [ordered]@{ write = $false; edit = $false; bash = $false; webfetch = $true }
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

    if ($Mode -eq "research-readonly") {
        $config.mcp = [ordered]@{
            web_search = [ordered]@{
                type = "remote"
                url = "http://127.0.0.1:3100/mcp"
                enabled = $true
            }
        }
    }

    Write-Utf8NoBom -Path $configPath -Value ($config | ConvertTo-Json -Depth 10)
    return $configPath
}

function Open-OpenCodeClient {
    param(
        [string]$ModelName,
        [switch]$Harness
    )

    $openCodeMode = if ($PresetMode -like "DeepResearch*") { "research-readonly" } else { "coding" }
    $configPath = New-LocalOpenCodeConfig -ModelName $ModelName -Mode $openCodeMode
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
    if ($Harness) { $shellArgs += "-Harness" }
    return Start-Process -FilePath "powershell.exe" -PassThru -ArgumentList $shellArgs
}

function Open-OpenClaudeClient {
    param([string]$ModelName)

    $clientShell = Join-Path $PSScriptRoot "tools\llamadock-client-shell.ps1"
    Write-Host "Opening OpenClaude in PowerShell..." -ForegroundColor Cyan
    return Start-Process -FilePath "powershell.exe" -PassThru -ArgumentList @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", $clientShell,
        "-Client", "OpenClaude",
        "-ModelName", $ModelName,
        "-BaseUrl", "$ClientBaseUrl/v1",
        "-Workspace", $PSScriptRoot
    )
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

function Get-ComfyUITritonVersion {
    # Returns the triton version installed in the ComfyUI venv, or $null.
    # comfy-kitchen's ROCm INT8 Triton kernels need triton >= 3.7; older HIP
    # builds (e.g. triton-windows 3.5.1) hard-crash ComfyUI when
    # --enable-triton-backend forces them on (missing libdevice.rint /
    # register allocation errors). Gates the `triton` profile accordingly.
    try {
        $comfyPython = "C:\Users\dai86\Documents\ComfyUI\.venv\Scripts\python.exe"
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
    if (-not [string]::IsNullOrWhiteSpace($ComfyUIFlags) -or $env:LLAMADOCK_COMFY_FLAGS -or $env:LLAMADOCK_COMFY_PROFILE) {
        return
    }
    if ([Console]::IsInputRedirected) {
        return
    }
    Write-Host ""
    Write-Host "ComfyUI tuning (MiniMax H3), fastest first:" -ForegroundColor Green
    Write-Host " [1] super   - all-in fast config (ck attention; fastest)"
    Write-Host " [2] ck      - default + --use-ck-attention (measured 17m19s vs default 19m26s; needs ComfyUI >= 0.33)"
    Write-Host " [3] fast    - default + --fast fp16_accumulation --force-non-blocking (untested; quality risk, benchmark first)"
    Write-Host " [4] default - --reserve-vram 1.0 (measured baseline 19m26s; 1GB stays free for the desktop)"
    Write-Host " [5] bench   - no extra flags (A/B baseline)"
    Write-Host " [6] custom  - type raw ComfyUI flags"
    Write-Host ""
    do {
        $tuningInput = Read-Host "Select ComfyUI tuning (1-6), or press Enter for default"
        $tuningValid = $true
        if ([string]::IsNullOrWhiteSpace($tuningInput)) {
            $script:ComfyProfileChoice = "default"
        }
        else {
            switch ($tuningInput) {
                "1" { $script:ComfyProfileChoice = "super" }
                "2" { $script:ComfyProfileChoice = "ck" }
                "3" { $script:ComfyProfileChoice = "fast" }
                "4" { $script:ComfyProfileChoice = "default" }
                "5" { $script:ComfyProfileChoice = "bench" }
                "6" {
                    $rawFlags = Read-Host "Raw ComfyUI flags (e.g. --reserve-vram 0.5 --force-non-blocking)"
                    $script:ComfyProfileChoice = "custom"
                    $script:ComfyFlagsChoice = $rawFlags
                }
                default { $tuningValid = $false }
            }
        }
    } while (-not $tuningValid)
}

function Open-ComfyUIClient {
    # ComfyUI workspace: local ComfyUI server for MiniMax H3 video/audio gen.
    # Runs from Documents\ComfyUI (venv + extra_model_paths.yaml point at
    # .lmstudio\models\MiniMax-H3).
    $comfyRoot = "C:\Users\dai86\Documents\ComfyUI"
    $comfyPort = 8188
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
            if ($SkipOpenBrowser) {
                Write-Host "SKIP: Browser would open $comfyUrl" -ForegroundColor Yellow
            }
            else {
                Start-Process $comfyUrl
            }
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
    if ($SkipOpenBrowser) {
        Write-Host "SKIP: Browser would open $comfyUrl" -ForegroundColor Yellow
    }
    else {
        Start-Process $comfyUrl
    }
    Write-Host "h3-chat: テキストで動画生成するなら tools\h3-chat.ps1 を実行 → http://127.0.0.1:8189" -ForegroundColor Cyan
    return $process
}

function Open-WorkspaceClient {
    param([string]$Mode, [string]$ModelPath, [string]$ModelName)

    switch ($Mode) {
        "WebUI" { return Open-OpenWebUIClient }
        "ComfyUI" { return Open-ComfyUIClient }
        "DeepResearch" { Open-DeepResearch; return $null }
        "LlamaAgent" { return Open-LlamaAgentClient -ModelPath $ModelPath }
        "OpenCode" {
            $harnessFlag = ($PresetMode -eq "OpenCodeHarness")
            return Open-OpenCodeClient -ModelName $ModelName -Harness:$harnessFlag
        }
        "OpenClaude" { return Open-OpenClaudeClient -ModelName $ModelName }
        default {
            Set-ClineLocalModel -ModelName $ModelName
            return Open-ClineClient
        }
    }
}

function Select-WorkspaceForSession {
    Write-Host ""
    Write-Host "LlamaDock session" -ForegroundColor Cyan
    Write-Host " [1] Relaunch same workspace"
    Write-Host " [2] Change workspace, keep this model loaded"
    Write-Host " [3] Change model - stop this server and return to selector"
    Write-Host " [4] Stop server and exit"
    Write-Host " [5] Leave server running and exit"
    $choice = Read-Host "Select session action (1-5)"
    if ($choice -eq "1") { return @("relaunch", "") }
    if ($choice -eq "2") {
        Write-Host " [1] Computer  [2] Cline  [3] OpenCode  [4] OpenClaude  [5] Deep Research  [6] Llama Agent  [7] ComfyUI"
        $workspace = Read-Host "Select workspace"
        $modes = @("WebUI", "Cline", "OpenCode", "OpenClaude", "DeepResearch", "LlamaAgent", "ComfyUI")
        $index = 0
        if ([int]::TryParse($workspace, [ref]$index) -and $index -ge 1 -and $index -le $modes.Count) {
            return @("switch", $modes[$index - 1])
        }
        return @("relaunch", "")
    }
    if ($choice -eq "3") { return @("change-model", "") }
    if ($choice -eq "4") { return @("stop", "") }
    return @("leave", "")
}

function Test-OdysseusReady {
    try {
        $r = Invoke-WebRequest -Uri $OdysseusBaseUrl -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Stop-LegacyLocalDeepResearch {
    $connections = Get-NetTCPConnection -LocalPort $LegacyDeepResearchPort -State Listen -ErrorAction SilentlyContinue
    $processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })

    foreach ($ldrPid in $processIds) {
        $procInfo = Get-Process -Id $ldrPid -ErrorAction SilentlyContinue
        if (-not $procInfo) { continue }

        $commandLine = ""
        try {
            $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$ldrPid" -ErrorAction SilentlyContinue
            if ($cimProc) { $commandLine = [string]$cimProc.CommandLine }
        }
        catch {}

        $looksLikeLdr = ($procInfo.ProcessName -match "^(ldr-web|python|pythonw)$" -and $commandLine -match "local_deep_research|ldr-web")
        if ($looksLikeLdr) {
            Write-Host "Stopping legacy Local Deep Research on port $LegacyDeepResearchPort..." -ForegroundColor Yellow
            Stop-Process -Id $ldrPid -Force -ErrorAction SilentlyContinue
        }
    }
}

function Stop-OdysseusOnPort {
    $connections = Get-NetTCPConnection -LocalPort $OdysseusPort -State Listen -ErrorAction SilentlyContinue
    $processIds = @($connections | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })

    foreach ($odyPid in $processIds) {
        $procInfo = Get-Process -Id $odyPid -ErrorAction SilentlyContinue
        if (-not $procInfo) { continue }

        $commandLine = ""
        try {
            $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$odyPid" -ErrorAction SilentlyContinue
            if ($cimProc) { $commandLine = [string]$cimProc.CommandLine }
        }
        catch {}

        $looksLikeOdysseus = ($procInfo.ProcessName -match "^(python|pythonw|powershell|pwsh)$" -and $commandLine -match "odysseus|uvicorn app:app")
        if ($looksLikeOdysseus) {
            Write-Host "Restarting Odysseus to refresh local settings..." -ForegroundColor Yellow
            Stop-Process -Id $odyPid -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "Port $OdysseusPort is already used by PID $odyPid ($($procInfo.ProcessName)); not stopping it." -ForegroundColor Yellow
            return $false
        }
    }

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-NetTCPConnection -LocalPort $OdysseusPort -State Listen -ErrorAction SilentlyContinue)) {
            return $true
        }
    }

    Write-Host "ERROR: Port $OdysseusPort is still in use. Odysseus was not restarted." -ForegroundColor Red
    return $false
}

function Ensure-OdysseusInstalled {
    if (Test-Path (Join-Path $OdysseusRoot "app.py")) {
        return $true
    }

    Write-Host "Odysseus was not found. Cloning native Windows install..." -ForegroundColor Cyan
    $parent = Split-Path $OdysseusRoot -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    git clone --branch main --depth 1 https://github.com/pewdiepie-archdaemon/odysseus $OdysseusRoot
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $OdysseusRoot "app.py"))) {
        Write-Host "ERROR: Could not clone Odysseus." -ForegroundColor Red
        return $false
    }

    return $true
}

function Set-OdysseusLocalDefaults {
    $dataDir = Join-Path $OdysseusRoot "data"
    if (-not (Test-Path $dataDir)) {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
    }

    $settingsPath = Join-Path $dataDir "settings.json"
    $settings = [ordered]@{}
    if (Test-Path $settingsPath) {
        try {
            $loaded = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                $settings[$prop.Name] = $prop.Value
            }
        }
        catch {
            Write-Host "WARNING: Could not parse Odysseus settings.json; rewriting local-safe defaults." -ForegroundColor Yellow
        }
    }

    $settings["search_provider"] = "duckduckgo"
    $settings["search_fallback_chain"] = @("duckduckgo")
    $settings["search_url"] = ""
    $settings["search_result_count"] = $script:ResearchSearchResultCount
    $settings["research_search_provider"] = "duckduckgo"
    $settings["default_model"] = $modelShort
    $settings["research_model"] = $modelShort
    $settings["research_max_tokens"] = $script:ResearchMaxTokens
    $settings["research_extraction_max_tokens"] = $script:ResearchExtractionMaxTokens
    $settings["research_extraction_timeout_seconds"] = $script:ResearchExtractionTimeoutSeconds
    $settings["research_planning_timeout_seconds"] = $script:ResearchPlanningTimeoutSeconds
    $settings["research_query_timeout_seconds"] = $script:ResearchQueryTimeoutSeconds
    $settings["research_extraction_concurrency"] = $script:ResearchExtractionConcurrency
    $settings["research_run_timeout_seconds"] = $script:ResearchRunTimeoutSeconds

    Write-Utf8NoBom -Path $settingsPath -Value ($settings | ConvertTo-Json -Depth 8)

    $featuresPath = Join-Path $dataDir "features.json"
    $features = [ordered]@{}
    if (Test-Path $featuresPath) {
        try {
            $loadedFeatures = Get-Content -LiteralPath $featuresPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $loadedFeatures.PSObject.Properties) {
                $features[$prop.Name] = $prop.Value
            }
        }
        catch {}
    }
    $features["web_search"] = $true
    $features["web_fetch"] = $true
    $features["deep_research"] = $true
    $features["rag"] = $false
    Write-Utf8NoBom -Path $featuresPath -Value ($features | ConvertTo-Json -Depth 8)
}

function Set-OdysseusSelectedModelDefaults {
    param(
        [string]$EndpointId,
        [string]$ModelName
    )

    $dataDir = Join-Path $OdysseusRoot "data"
    $settingsPath = Join-Path $dataDir "settings.json"
    $settings = [ordered]@{}
    if (Test-Path $settingsPath) {
        try {
            $loaded = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                $settings[$prop.Name] = $prop.Value
            }
        }
        catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($EndpointId)) {
        $settings["default_endpoint_id"] = $EndpointId
        $settings["research_endpoint_id"] = $EndpointId
    }
    $settings["default_model"] = $ModelName
    $settings["research_model"] = $ModelName
    $settings["search_provider"] = "duckduckgo"
    $settings["search_fallback_chain"] = @("duckduckgo")
    $settings["search_url"] = ""
    $settings["search_result_count"] = $script:ResearchSearchResultCount
    $settings["research_search_provider"] = "duckduckgo"
    $settings["research_max_tokens"] = $script:ResearchMaxTokens
    $settings["research_extraction_max_tokens"] = $script:ResearchExtractionMaxTokens
    $settings["research_extraction_timeout_seconds"] = $script:ResearchExtractionTimeoutSeconds
    $settings["research_planning_timeout_seconds"] = $script:ResearchPlanningTimeoutSeconds
    $settings["research_query_timeout_seconds"] = $script:ResearchQueryTimeoutSeconds
    $settings["research_extraction_concurrency"] = $script:ResearchExtractionConcurrency
    $settings["research_run_timeout_seconds"] = $script:ResearchRunTimeoutSeconds

    Write-Utf8NoBom -Path $settingsPath -Value ($settings | ConvertTo-Json -Depth 8)
}

function Clear-OdysseusLlamaEndpoint {
    try {
        $endpoints = @(Invoke-RestMethod -Uri "$OdysseusBaseUrl/api/model-endpoints" -TimeoutSec 10 -ErrorAction Stop)
    }
    catch {
        return
    }

    foreach ($ep in $endpoints) {
        $base = [string]$ep.base_url
        $name = [string]$ep.name
        if (($base.TrimEnd("/") -in @("$ServerBaseUrl/v1", "$GatewayBaseUrl/v1")) -or ($name -eq "llama.cpp 8080")) {
            try {
                Write-Host "Refreshing Odysseus llama.cpp endpoint ($($ep.id))..." -ForegroundColor Yellow
                [void](Invoke-OdysseusDelete -Path "/api/model-endpoints/$($ep.id)")
            }
            catch {
                Write-Host "WARNING: Could not delete old Odysseus endpoint $($ep.id): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}

function Ensure-OdysseusChatSession {
    $odyModelName = ""
    for ($i = 0; $i -lt 10; $i++) {
        $odyModelName = Get-ExistingServerModel
        if (-not [string]::IsNullOrWhiteSpace($odyModelName)) {
            break
        }
        Start-Sleep -Seconds 1
    }
    if ([string]::IsNullOrWhiteSpace($odyModelName)) {
        $odyModelName = $modelShort
    }

    $endpointId = ""
    try {
        Clear-OdysseusLlamaEndpoint
        $endpoint = Invoke-OdysseusForm -Path "/api/model-endpoints" -Fields @{
            name = "llama.cpp 8080"
            base_url = "$ClientBaseUrl/v1"
            api_key = ""
            skip_probe = "false"
            require_models = "false"
            model_type = "llm"
            endpoint_kind = "openai"
            supports_tools = "false"
            pinned_models = $odyModelName
            shared = "true"
        }
        if ($endpoint.id) {
            $endpointId = [string]$endpoint.id
        }
        Set-OdysseusSelectedModelDefaults -EndpointId $endpointId -ModelName $odyModelName
    }
    catch {
        Write-Host "WARNING: Could not register Odysseus model endpoint: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        $sessionFields = @{
            name = "llama.cpp $odyModelName"
            endpoint_url = "$ClientBaseUrl/v1/chat/completions"
            model = $odyModelName
            rag = "false"
            skip_validation = "true"
            api_key = ""
        }
        if (-not [string]::IsNullOrWhiteSpace($endpointId)) {
            $sessionFields["endpoint_id"] = $endpointId
        }

        $session = Invoke-OdysseusForm -Path "/api/session" -Fields $sessionFields
        if ($session.id) {
            Write-Host "Odysseus chat session: $($session.id)" -ForegroundColor Green
            return "$OdysseusBaseUrl/#$($session.id)"
        }
    }
    catch {
        Write-Host "WARNING: Could not create Odysseus chat session: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $OdysseusBaseUrl
}

function Open-DeepResearch {
    Stop-LegacyLocalDeepResearch

    if (-not (Ensure-OdysseusInstalled)) {
        return
    }

    Set-OdysseusLocalDefaults

    if (Get-NetTCPConnection -LocalPort $OdysseusPort -State Listen -ErrorAction SilentlyContinue) {
        if (Test-OdysseusReady) {
            Write-Host "Odysseus is already running at $OdysseusBaseUrl" -ForegroundColor Green
        }
        elseif (-not (Stop-OdysseusOnPort)) {
            return
        }
    }

    if (-not (Test-OdysseusReady)) {
        Write-Host "Starting Odysseus native UI..." -ForegroundColor Cyan
        $odysseusCommand = @"
Set-Location -LiteralPath '$OdysseusRoot'
`$env:AUTH_ENABLED='false'
`$env:LOCALHOST_BYPASS='true'
`$env:OPENAI_API_KEY=''
`$env:ODYSSEUS_DISABLE_MCP='true'
`$env:ODYSSEUS_DISABLE_VECTOR_FEATURES='1'
`$env:ODYSSEUS_LOCAL_MODEL_DISCOVERY_ONLY='1'
`$env:ODYSSEUS_DISABLE_MODEL_KEEPALIVE='1'
`$env:ODYSSEUS_SKIP_ADMIN_PROMPT='1'
`$env:ODYSSEUS_INPROCESS_POLLERS='0'
`$env:LLM_HOST='127.0.0.1'
`$env:LLM_HOSTS='127.0.0.1,localhost'
`$env:RESEARCH_LLM_ENDPOINT='$ClientBaseUrl/v1/chat/completions'
`$env:SEARXNG_INSTANCE='http://127.0.0.1:8888'
`$venvPy = Join-Path (Get-Location) 'venv\Scripts\python.exe'
if (-not (Test-Path `$venvPy)) {
    py -3.11 -m venv venv
    if (`$LASTEXITCODE -ne 0) { py -3.12 -m venv venv }
}
& `$venvPy -m pip install --upgrade pip --quiet
& `$venvPy -m pip install -r requirements.txt
& `$venvPy setup.py
`$dataDir = Join-Path (Get-Location) 'data'
if (-not (Test-Path `$dataDir)) { New-Item -ItemType Directory -Path `$dataDir -Force | Out-Null }
`$settingsPath = Join-Path `$dataDir 'settings.json'
`$settings = [ordered]@{}
if (Test-Path `$settingsPath) {
    try {
        `$loaded = Get-Content -LiteralPath `$settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach (`$prop in `$loaded.PSObject.Properties) { `$settings[`$prop.Name] = `$prop.Value }
    }
    catch {}
}
`$settings['search_provider'] = 'duckduckgo'
`$settings['search_fallback_chain'] = @('duckduckgo')
`$settings['search_url'] = ''
`$settings['search_result_count'] = $($script:ResearchSearchResultCount)
`$settings['research_search_provider'] = 'duckduckgo'
`$settings['default_model'] = '$modelShort'
`$settings['research_model'] = '$modelShort'
`$settings['research_max_tokens'] = $($script:ResearchMaxTokens)
`$settings['research_extraction_max_tokens'] = $($script:ResearchExtractionMaxTokens)
`$settings['research_extraction_timeout_seconds'] = $($script:ResearchExtractionTimeoutSeconds)
`$settings['research_planning_timeout_seconds'] = $($script:ResearchPlanningTimeoutSeconds)
`$settings['research_query_timeout_seconds'] = $($script:ResearchQueryTimeoutSeconds)
`$settings['research_extraction_concurrency'] = $($script:ResearchExtractionConcurrency)
`$settings['research_run_timeout_seconds'] = $($script:ResearchRunTimeoutSeconds)
`$utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)
[System.IO.File]::WriteAllText(`$settingsPath, (`$settings | ConvertTo-Json -Depth 8), `$utf8NoBom)
`$featuresPath = Join-Path `$dataDir 'features.json'
`$features = [ordered]@{}
if (Test-Path `$featuresPath) {
    try {
        `$loadedFeatures = Get-Content -LiteralPath `$featuresPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach (`$prop in `$loadedFeatures.PSObject.Properties) { `$features[`$prop.Name] = `$prop.Value }
    }
    catch {}
}
`$features['web_search'] = `$true
`$features['web_fetch'] = `$true
`$features['deep_research'] = `$true
`$features['rag'] = `$false
[System.IO.File]::WriteAllText(`$featuresPath, (`$features | ConvertTo-Json -Depth 8), `$utf8NoBom)
& `$venvPy -m uvicorn app:app --host 127.0.0.1 --port $OdysseusPort
"@
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command", $odysseusCommand
        ) -WindowStyle Normal

        Write-Host "Waiting for Odysseus..." -NoNewline -ForegroundColor Yellow
        for ($i = 0; $i -lt 150; $i++) {
            Start-Sleep -Seconds 2
            if (Test-OdysseusReady) {
                Write-Host " Done!" -ForegroundColor Green
                break
            }
            if ($i % 5 -eq 4) { Write-Host "." -NoNewline -ForegroundColor Yellow }
        }
        Write-Host ""
    }

    $openUrl = Ensure-OdysseusChatSession

    if ($SkipOpenBrowser) {
        Write-Host "SKIP: Browser would open $openUrl" -ForegroundColor Yellow
    }
    else {
        Write-Host "Opening Odysseus..." -ForegroundColor Cyan
        Start-Process $openUrl
    }
}

Show-LlamaDockBanner

$hardware = Get-HardwareEstimate

$runtimeCandidates = @(
    [PSCustomObject]@{ Name = "AtomicBot"; Path = $AtomicBotServerPath }
    [PSCustomObject]@{ Name = "TurboTan"; Path = $TurboTanServerPath },
    [PSCustomObject]@{ Name = "PrismBonsai"; Path = $PrismBonsaiServerPath },
    [PSCustomObject]@{ Name = "OfficialVulkan"; Path = $OfficialVulkanServerPath },
    [PSCustomObject]@{ Name = "OfficialHIP"; Path = $OfficialHIPServerPath },
    [PSCustomObject]@{ Name = "OfficialCPU"; Path = $OfficialCPUServerPath },
    [PSCustomObject]@{ Name = "DeepSeekDS4"; Path = $Ds4ServerPath }
)

# ComfyUI is a model-independent workspace. Keep it at the front door so a
# ComfyUI launch never makes the user pick an unrelated GGUF or start a
# llama-server first.
$comfyOnly = $ClientMode -eq "ComfyUI"
if (-not $DryRun -and -not $comfyOnly -and $ClientMode -eq "Prompt") {
    Write-Host "Launch target:" -ForegroundColor Green
    Write-Host " [1] LLM workspace - select a model and client"
    Write-Host " [2] ComfyUI - video/audio workspace (no GGUF selection)"
    Write-Host ""
    do {
        $targetInput = Read-Host "Select launch target (1-2), or press Enter for LLM"
        if ([string]::IsNullOrWhiteSpace($targetInput)) {
            $targetSelection = 1
            $targetValid = $true
        }
        else {
            $targetSelection = 0
            $targetValid = [int]::TryParse($targetInput, [ref]$targetSelection)
        }
    } while (-not $targetValid -or $targetSelection -lt 1 -or $targetSelection -gt 2)

    if ($targetSelection -eq 2) {
        $ClientMode = "ComfyUI"
        $comfyOnly = $true
    }
}

if ($comfyOnly) {
    if ($DryRun) {
        $comfyArgs = Get-ComfyUILaunchArgs -Port 8188
        Write-Host "DRY RUN: ComfyUI-only launch; model selection and llama-server will be skipped." -ForegroundColor Yellow
        Write-Host "DRY RUN: ComfyUI would start on http://127.0.0.1:8188" -ForegroundColor Yellow
        Write-Host ("DRY RUN: ComfyUI flags: {0}" -f ($comfyArgs -join " ")) -ForegroundColor Yellow
        exit 0
    }

    $null = Open-ComfyUIClient
    exit 0
}

# Find all supported GGUF files. Retired Hy3/hy_v3 files stay on disk for
# optional manual cleanup, but must not be offered to a different runtime.
$allFiles = Get-ChildItem -Path $ModelsBase -Filter "*.gguf" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "mmproj" -and $_.Name -notmatch "(?i)(^|[\\/_. -])Hy3([\\/_. -]|$)|Hy[-_ ]?V3" }

# Build model list (all models except mmproj)
$models = @()
foreach ($f in $allFiles) {
    if ($f.Name -notmatch "mmproj") {
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

if ($requiredEngine -eq "TurboTan") {
    $ServerPath = $TurboTanServerPath
}
elseif ($requiredEngine -eq "PrismBonsai") {
    $ServerPath = $PrismBonsaiServerPath
}
elseif ($requiredEngine -eq "ExpertsLaguna") {
    $ServerPath = $ExpertsLagunaServerPath
}
elseif ($requiredEngine -eq "LongCat") {
    $ServerPath = $LongCatServerPath
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
elseif ($requiredEngine -eq "DeepSeekDS4") {
    $ServerPath = $Ds4ServerPath
}
else {
    $ServerPath = $AtomicBotServerPath
}

$isDs4Engine = $requiredEngine -eq "DeepSeekDS4"
if ($isDs4Engine) {
    Write-Host "ERROR: DeepSeekDS4's WSL launch path is disabled by the no-Docker/no-WSL policy." -ForegroundColor Red
    Write-Host "Use a native HIP/Vulkan/CPU runtime instead." -ForegroundColor Yellow
    exit 1
}

$modelNote = Get-ModelNote -Model $selected

if ($PresetMode -eq "Prompt") {
    Write-Host ""
    Write-Host "Runtime engine: $requiredEngine" -ForegroundColor Green
    Write-Host "Runtime path  : $ServerPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Workflow preset:" -ForegroundColor Green
    Write-Host " [1] Manual - choose every setting"
    Write-Host " [2] Code - Cline defaults"
    Write-Host " [3] Code - OpenCode"
    Write-Host " [4] Code - OpenCode + Harness"
    Write-Host " [5] Code - OpenClaude"
    Write-Host " [6] Agent Research - llama-agent with iterative web evidence"
    Write-Host " [7] Deep Research Light - Odysseus low load"
    Write-Host " [8] Deep Research Standard - Odysseus balanced"
    Write-Host " [9] Deep Research Heavy - Odysseus broader search"
    Write-Host " [10] Chat - Open WebUI with web search and compaction"
    Write-Host ""

    do {
        $presetInput = Read-Host "Select preset (1-10), or press Enter for Manual"
        if ([string]::IsNullOrWhiteSpace($presetInput)) {
            $presetSelection = 1
            $presetValid = $true
        }
        else {
            $presetSelection = 0
            $presetValid = [int]::TryParse($presetInput, [ref]$presetSelection)
        }
    } while (-not $presetValid -or $presetSelection -lt 1 -or $presetSelection -gt 10)

    $presetValues = @("Manual", "ClineCoding", "OpenCodeCoding", "OpenCodeHarness", "OpenClaudeCoding", "LlamaAgentResearch", "DeepResearchLight", "DeepResearchStandard", "DeepResearchHeavy", "WebUIChat")
    $PresetMode = $presetValues[$presetSelection - 1]
}

$isQuickLaunch = $PresetMode -in @("WebUIChat", "OpenCodeCoding", "OpenCodeHarness", "DeepResearchStandard")
if ($isQuickLaunch) {
    if ($KCacheIndex -eq 0) { $KCacheIndex = 1 }
    if ($VCacheIndex -eq 0) {
        if ($requiredEngine -eq "TurboTan") { $VCacheIndex = 9 }
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
elseif ($PresetMode -eq "OpenCodeHarness") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "OpenCode" }
    if ($ContextIndex -eq 0) { $ContextIndex = 3 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "OpenClaudeCoding") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "OpenClaude" }
    if ($ContextIndex -eq 0) { $ContextIndex = 3 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -like "DeepResearch*") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "DeepResearch" }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
    if ($PresetMode -eq "DeepResearchLight") {
        if ($ContextIndex -eq 0) { $ContextIndex = 2 }
        if ($ResearchMode -eq "Auto") { $ResearchMode = "Light" }
    }
    elseif ($PresetMode -eq "DeepResearchHeavy") {
        if ($ContextIndex -eq 0) { $ContextIndex = 4 }
        if ($ResearchMode -eq "Auto") { $ResearchMode = "Heavy" }
    }
    else {
        if ($ContextIndex -eq 0) { $ContextIndex = 3 }
        if ($ResearchMode -eq "Auto") { $ResearchMode = "Standard" }
    }
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
if ($isDs4Engine) {
    if (-not $PSBoundParameters.ContainsKey("ContextIndex")) { $ContextIndex = 1 }
    if (-not $PSBoundParameters.ContainsKey("OffloadMode")) { $OffloadMode = "CPU" }
    if (-not $PSBoundParameters.ContainsKey("MoeExpertsMode")) { $MoeExpertsMode = "Auto" }
    if (-not $PSBoundParameters.ContainsKey("FlashAttentionMode")) { $FlashAttentionMode = "Off" }
    if (-not $PSBoundParameters.ContainsKey("SpecMode")) { $SpecMode = "Off" }
    if (-not $PSBoundParameters.ContainsKey("McpMode")) { $McpMode = "None" }
}

Set-DeepResearchModeDefaults -Mode $ResearchMode

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
    $launchLabel = if ($PresetMode -eq "WebUIChat") { "Chat + Web -> Computer" } elseif ($PresetMode -eq "OpenCodeCoding") { "Coding -> OpenCode" } elseif ($PresetMode -eq "OpenCodeHarness") { "Coding -> OpenCode + Harness" } else { "Deep Research -> Odysseus" }
}
else {
    Write-Host "Selected: $($selected.Name)" -ForegroundColor Green
    Write-Host "Engine: $requiredEngine" -ForegroundColor Green
    Write-Host "Preset: $PresetMode" -ForegroundColor Green
}
if (($ClientMode -eq "DeepResearch" -or $PresetMode -like "DeepResearch*") -and -not $isQuickLaunch) {
    Write-Host "Deep Research mode: $ResearchMode (results=$($script:ResearchSearchResultCount), extraction concurrency=$($script:ResearchExtractionConcurrency))" -ForegroundColor Green
}
Write-Host ""

if (-not (Test-Path $ServerPath)) {
    Write-Host "ERROR: Required engine is not built:" -ForegroundColor Red
    Write-Host $ServerPath -ForegroundColor Red
    if ($requiredEngine -eq "TurboTan") {
        Write-Host "Build TurboTan first, or set LLAMA_TQ3_TURBOTAN_SERVER to its llama-server.exe." -ForegroundColor Red
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

# Prompt context size selection
$systemRamGB = $hardware.RamGB
$primaryVramGB = if ($hardware.PrimaryGpu) { [double]$hardware.PrimaryGpu.VramGB } else { 0 }
$maxContextTokensForRam = Get-MaxContextTokensForRam -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB -IsDs4 $isDs4Engine
if ($isDs4Engine) {
    $contextOptions = @(
        [PSCustomObject]@{ Label = "4K"; Tokens = 4096; Note = "DS4 smoke/default for 64-96GB RAM" },
        [PSCustomObject]@{ Label = "8K"; Tokens = 8192; Note = "DS4 practical test" },
        [PSCustomObject]@{ Label = "16K"; Tokens = 16384; Note = "higher RAM use" },
        [PSCustomObject]@{ Label = "32K"; Tokens = 32768; Note = "heavy; use after 4K/8K works" },
        [PSCustomObject]@{ Label = "Custom"; Tokens = 0; Note = "enter token count manually" }
    )
}
else {
    $recommendedDefaultTokens = if ($isDeepSeek) {
        # 16K: Cline-grade context at a measured ~6.4 tps; 32K drops to ~4 tps, 8K is too small.
        16384
    }
    elseif ($selectedModelSizeGB -ge 40) {
        16384
    }
    elseif ($selectedModelSizeGB -ge 24) {
        32768
    }
    elseif ($selectedModelSizeGB -ge 12) {
        65536
    }
    else {
        131072
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
}

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
            $defaultMark = if (-not $isDs4Engine -and $ctx.Tokens -eq $recommendedDefaultTokens) { " [recommended]" } elseif ($isDs4Engine -and $ctx.Tokens -eq 4096) { " [recommended]" } else { "" }
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
        $defaultContextLabel = if ($isDs4Engine) { "4K" } else { "$([int]($recommendedDefaultTokens / 1024))K" }
        $ctxInput = Read-Host "Select context size (1-$($contextOptions.Count)), or press Enter for $defaultContextLabel"
        if ([string]::IsNullOrWhiteSpace($ctxInput)) {
            if ($isDs4Engine) {
                $ctxSelection = 1
            }
            else {
                $ctxSelection = [array]::IndexOf(@($contextOptions | Select-Object -ExpandProperty Tokens), $recommendedDefaultTokens) + 1
            }
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

# Prompt KV cache quantization selection
if ($isDs4Engine) {
    $selectedKCache = [PSCustomObject]@{ Label = "DS4"; Type = "ds4-native" }
    $selectedVCache = [PSCustomObject]@{ Label = "DS4"; Type = "ds4-native" }
    Write-Host "KV cache: DS4 native runtime setting" -ForegroundColor Green
    Write-Host ""
}
else {
    $kvOptions = @(
        [PSCustomObject]@{ Label = "Q8"; Type = "q8_0"; Note = "larger, stable default for K" },
        [PSCustomObject]@{ Label = "Q5_1"; Type = "q5_1"; Note = "supported middle option for K, safer than Q4" },
        [PSCustomObject]@{ Label = "Q5_0"; Type = "q5_0"; Note = "supported compact middle option" },
        [PSCustomObject]@{ Label = "Q4"; Type = "q4_0"; Note = "compact, more quality risk for K" },
        [PSCustomObject]@{ Label = "turbo4"; Type = "turbo4"; Note = "TurboQuant 4.5bit" },
        [PSCustomObject]@{ Label = "turbo3"; Type = "turbo3"; Note = "TurboQuant 3.5bit, compact default for V" },
        [PSCustomObject]@{ Label = "f16"; Type = "f16"; Note = "uncompressed compatibility fallback" },
        [PSCustomObject]@{ Label = "bf16"; Type = "bf16"; Note = "uncompressed compatibility fallback, lower memory than f32" }
    )

    if ($requiredEngine -eq "TurboTan") {
        $kvOptions += [PSCustomObject]@{ Label = "tq3_0"; Type = "tq3_0"; Note = "TurboTan TQ3 cache, recommended for TQ3_4S V" }
    }
    elseif ($requiredEngine -eq "OfficialVulkan" -or $requiredEngine -eq "OfficialHIP" -or $requiredEngine -eq "OfficialCPU" -or $requiredEngine -eq "PrismBonsai" -or $requiredEngine -eq "LongCat" -or ($requiredEngine -eq "ExpertsLaguna" -and -not $isDeepSeek)) {
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
            $defaultVType = if ($requiredEngine -eq "TurboTan") { "tq3_0" } elseif ($requiredEngine -eq "ExpertsLaguna" -or $requiredEngine -eq "LongCat") { "q4_0" } elseif ($requiredEngine -eq "OfficialVulkan" -or $requiredEngine -eq "OfficialHIP" -or $requiredEngine -eq "OfficialCPU" -or $requiredEngine -eq "PrismBonsai") { "q4_0" } else { "turbo3" }
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
}

if ($ClientMode -eq "Prompt") {
    Write-Host "Workspace:" -ForegroundColor Green
    Write-Host " [1] Cline - coding agent"
    Write-Host " [2] OpenCode - terminal coding agent"
    Write-Host " [3] OpenClaude - terminal coding agent"
    Write-Host " [4] Computer - chat, web search, and compaction"
    Write-Host " [5] Deep Research - Odysseus research UI"
    Write-Host " [6] Llama Agent - terminal agent with deep web evidence"
    Write-Host " [7] ComfyUI - MiniMax H3 video and audio generation"
    Write-Host ""

    do {
        $clientInput = Read-Host "Select workspace (1-7), or press Enter for Cline"
        if ([string]::IsNullOrWhiteSpace($clientInput)) {
            $clientSelection = 1
            $clientValid = $true
        }
        else {
            $clientSelection = 0
            $clientValid = [int]::TryParse($clientInput, [ref]$clientSelection)
        }
    } while (-not $clientValid -or $clientSelection -lt 1 -or $clientSelection -gt 7)

    if ($clientSelection -eq 1) { $ClientMode = "Cline" }
    elseif ($clientSelection -eq 2) { $ClientMode = "OpenCode" }
    elseif ($clientSelection -eq 3) { $ClientMode = "OpenClaude" }
    elseif ($clientSelection -eq 4) { $ClientMode = "WebUI" }
    elseif ($clientSelection -eq 5) { $ClientMode = "DeepResearch" }
    elseif ($clientSelection -eq 6) { $ClientMode = "LlamaAgent" }
    else { $ClientMode = "ComfyUI" }
}

if (-not $isQuickLaunch) {
    Write-Host "Workspace: $ClientMode" -ForegroundColor Green
    Write-Host ""
}

if ($ClientMode -eq "DeepResearch" -and $ResearchMode -eq "Auto") {
    Write-Host "Deep Research mode:" -ForegroundColor Green
    Write-Host " [1] Light - lower local LLM load"
    Write-Host " [2] Standard - balanced"
    Write-Host " [3] Heavy - more results and extraction concurrency"
    Write-Host ""

    do {
        $researchInput = Read-Host "Select Deep Research mode (1-3), or press Enter for Standard"
        if ([string]::IsNullOrWhiteSpace($researchInput)) {
            $researchSelection = 2
            $researchValid = $true
        }
        else {
            $researchSelection = 0
            $researchValid = [int]::TryParse($researchInput, [ref]$researchSelection)
        }
    } while (-not $researchValid -or $researchSelection -lt 1 -or $researchSelection -gt 3)

    if ($researchSelection -eq 1) { $ResearchMode = "Light" }
    elseif ($researchSelection -eq 3) { $ResearchMode = "Heavy" }
    else { $ResearchMode = "Standard" }
    Set-DeepResearchModeDefaults -Mode $ResearchMode
    Write-Host "Deep Research mode: $ResearchMode (results=$($script:ResearchSearchResultCount), extraction concurrency=$($script:ResearchExtractionConcurrency))" -ForegroundColor Green
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

if ($isLikelyMoeModel -and $MoeExpertsMode -ne "Prompt") {
    if ($MoeExpertsMode -eq "Prompt") {
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
    else {
        $cpuMoeMode = "Auto"
    }

    # Auto-calculate CPU MoE layers
    if ($cpuMoeMode -eq "Auto") {
        $modelSizeGB = [math]::Round($selected.SizeMB / 1024, 1)
        # Detect VRAM from earlier device_info or use conservative 12GB
        $vramGB = 12
        if ($env:HIP_PATH -or $requiredEngine -eq "OfficialHIP" -or $requiredEngine -eq "ExpertsLaguna") {
            $vramGB = 16  # RX 7800 XT
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
}

if ([string]::IsNullOrWhiteSpace($ChatTemplateKwargs) -and -not $DryRun -and -not $isQuickLaunch) {
    $kwargsDefaultLabel = if ($requiredEngine -eq "TurboTan") { "TQ3 default disables thinking" } else { "none" }
    $kwargsInput = Read-Host "chat-template-kwargs JSON, or press Enter for $kwargsDefaultLabel"
    if (-not [string]::IsNullOrWhiteSpace($kwargsInput)) {
        $ChatTemplateKwargs = $kwargsInput
    }
}

$effectiveChatTemplateKwargs = $ChatTemplateKwargs
if ([string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs) -and ($requiredEngine -eq "TurboTan" -or $ClientMode -eq "DeepResearch" -or $ClientMode -eq "LlamaAgent")) {
    $effectiveChatTemplateKwargs = '{"enable_thinking":false}'
}

$effectiveReasoningMode = ""
if (-not [string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs)) {
    try {
        $chatTemplateOptions = $effectiveChatTemplateKwargs | ConvertFrom-Json -ErrorAction Stop
        if ($chatTemplateOptions.enable_thinking -eq $false) {
            $effectiveReasoningMode = "off"
        }
        if (-not $isQuickLaunch) {
            Write-Host "chat-template-kwargs: $effectiveChatTemplateKwargs" -ForegroundColor Green
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
$effectiveCacheRamMiB = $CacheRamMiB
if ($effectiveCacheRamMiB -lt 0) {
    $effectiveCacheRamMiB = 8192
    if ($selectedContext.Tokens -ge 65536) { $effectiveCacheRamMiB = 4096 }
    if ($selectedModelSizeGB -ge 20) { $effectiveCacheRamMiB = 2048 }
}
if (-not $isQuickLaunch) {
    Write-Host "Prompt cache RAM: $effectiveCacheRamMiB MiB" -ForegroundColor Green
    Write-Host ""
}

if ($FlashAttentionMode -eq "Prompt") {
    Write-Host "Flash Attention:" -ForegroundColor Green
    Write-Host " [1] On - fastest when supported"
    Write-Host " [2] Off - compatibility fallback for models with unsupported head sizes"
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
    Write-Host ""
}

if (-not $isDs4Engine -and $requiredEngine -ne "ExpertsLaguna" -and $flashAttention -eq "off" -and $effectiveVCacheType -notin @("f16", "bf16", "f32")) {
    Write-Host "ERROR: V cache quantization requires Flash Attention." -ForegroundColor Red
    Write-Host "Select Flash Attention On, or use V cache f16/bf16/f32." -ForegroundColor Red
    exit 1
}

if ($SpecMode -eq "Prompt") {
    Write-Host "Speculative decoding mode:" -ForegroundColor Green
    Write-Host " [1] Off - normal decoding"
    Write-Host " [2] MTP/NextN - for combined *_MTP.gguf models"
    Write-Host " [3] DSpark - DeepSeek V4 Flash fast draft"
    Write-Host ""

    do {
        $defaultSpecChoice = if ($isDeepSeek) { 3 } else { 1 }
        $defaultSpecLabel = if ($isDeepSeek) { "DSpark" } else { "Off" }
        $specInput = Read-Host "Select speculative mode (1-3), or press Enter for $defaultSpecLabel"
        if ([string]::IsNullOrWhiteSpace($specInput)) {
            $specSelection = $defaultSpecChoice
            $specValid = $true
        }
        else {
            $specSelection = 0
            $specValid = [int]::TryParse($specInput, [ref]$specSelection)
        }
    } while (-not $specValid -or $specSelection -lt 1 -or $specSelection -gt 3)

    if ($specSelection -eq 1) { $SpecMode = "Off" }
    elseif ($specSelection -eq 2) { $SpecMode = "MtpNextN" }
    else { $SpecMode = "DSpark" }
}

if (-not $isQuickLaunch) {
    Write-Host "Speculative decoding mode: $SpecMode" -ForegroundColor Green
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
if ($isDs4Engine) {
    $modelShort = "deepseek-v4-flash"
}

# Start server
$startFilePath = $ServerPath
$args = @()
$disableTurboAutoAsymmetric = $false

if ($isDs4Engine) {
    $ds4RootWsl = ConvertTo-WslPath $Ds4Root
    $modelPathWsl = ConvertTo-WslPath $selected.FullName
    $kvDirWsl = ConvertTo-WslPath (Join-Path $PSScriptRoot "mcp-data\ds4-kv")
    $ds4Command = @(
        "cd $(Quote-WslArg $ds4RootWsl)",
        "mkdir -p $(Quote-WslArg $kvDirWsl)",
        "./ds4-server --cpu -m $(Quote-WslArg $modelPathWsl) --host 127.0.0.1 --port 8080 --ctx $($selectedContext.Tokens) -n 4096 --kv-disk-dir $(Quote-WslArg $kvDirWsl) --kv-disk-space-mb 4096"
    ) -join " && "
    $startFilePath = "wsl.exe"
    $args = @("-d", "Ubuntu", "bash", "-lc", $ds4Command)
}
else {
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
        $args += @(
            "-md", $selected.FullName,
            "--spec-type", "draft-mtp",
            "--spec-draft-n-max", "2",
            "--spec-draft-n-min", "1",
            "-ngld", "$serverOffload",
            "-ctkd", "$effectiveKCacheType",
            "-ctvd", "$effectiveVCacheType"
        )
    }

    if ($SpecMode -eq "DSpark") {
        $args += @(
            "--spec-type", "draft-dspark",
            "--spec-draft-model", "C:\Users\dai86\.lmstudio\models\ggml-org\DeepSeek-V4-Flash-0731-GGUF\dspark-DeepSeek-V4-Flash-0731-MXFP4.gguf",
            "--spec-draft-n-max", "5",
            "-ngld", "99"
        )
    }

    $disableTurboAutoAsymmetric = $effectiveKCacheType -like "turbo*"
}

if ($selectedMcp -eq "Light" -and -not $isDs4Engine) {
    $args += "--webui-mcp-proxy"
}

if ($DryRun) {
    $dryRunServerLabel = if ($isDs4Engine) { "ds4-server would start with:" } else { "llama-server would start with:" }
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
        if ($PresetMode -eq "OpenCodeHarness") {
            Write-Host "DRY RUN: OpenCode Harness mode - will prompt for coding task and run external harness" -ForegroundColor Yellow
        }
        else {
            Write-Host "DRY RUN: OpenCode would open" -ForegroundColor Yellow
        }
    }
    elseif ($ClientMode -eq "OpenClaude") {
        Write-Host "DRY RUN: OpenClaude would use model:" -ForegroundColor Yellow
        Write-Host $modelShort
        Write-Host "DRY RUN: OpenClaude would open with OPENAI_BASE_URL=$ClientBaseUrl/v1" -ForegroundColor Yellow
    }
    elseif ($ClientMode -eq "DeepResearch") {
        Write-Host "DRY RUN: Odysseus would open:" -ForegroundColor Yellow
        Write-Host $OdysseusBaseUrl
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
            Write-Host " [1] Switch to selected model - stop existing server first"
            Write-Host " [2] Use existing server"
            Write-Host " [3] Quit"
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
                $harnessFlag = ($PresetMode -eq "OpenCodeHarness")
                Open-OpenCodeClient -ModelName $existingModel -Harness:$harnessFlag
                Write-Host ""
            }
            elseif ($ClientMode -eq "OpenClaude") {
                Open-OpenClaudeClient -ModelName $existingModel
                Write-Host ""
            }
            elseif ($ClientMode -eq "DeepResearch") {
                Open-DeepResearch
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
            Write-Host " [1] Quit - recommended"
            Write-Host " [2] Start selected model anyway"
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

if ($isDs4Engine) {
    Write-Host "Starting ds4-server through WSL..." -ForegroundColor Blue
}
else {
    Write-Host "Starting llama-server under the LlamaDock supervisor..." -ForegroundColor Blue
}
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
if ($isDs4Engine) {
    $proc = Start-Process -FilePath $startFilePath -ArgumentList $args -PassThru -WindowStyle Normal
}
else {
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
        "-LogDir", (Join-Path $PSScriptRoot "logs"),
        "-AutoRestartServer"
    )
    # Keep the supervisor in a normal console so the user can see and control
    # the server session. Ctrl+C in that console reaches the supervisor's
    # finally block, which stops llama-server and the gateway cleanly.
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $supervisorArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Normal
    Write-Host "LlamaDock server console opened (supervisor PID $($proc.Id)). Press Ctrl+C in that window to stop llama-server." -ForegroundColor Cyan
}

Write-Host "Waiting for server to be ready..." -NoNewline -ForegroundColor Yellow
# A 50+ GiB MoE can need several minutes to map weights, fit VRAM, and
# publish /v1/models. Keep the normal path quick, but do not make the user
# think a heavy model failed while it is still loading.
$maxWait = if ($selectedModelSizeGB -ge 50) { 180 } elseif ($selectedModelSizeGB -ge 20) { 120 } else { 60 }
$ready = $false
for ($i = 0; $i -lt $maxWait; $i++) {
    Start-Sleep -Seconds 2
    $expectedReadyModel = ""
    $directReady = Test-ServerReady -ExpectedModelId $expectedReadyModel
    $gatewayReady = $isDs4Engine -or (Test-GatewayReady -ExpectedModelId $expectedReadyModel)
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
            exit 0
        }
        default { exit 0 }
    }
}
