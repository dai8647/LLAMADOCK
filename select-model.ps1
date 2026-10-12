# select-model.ps1 - LlamaDock local GGUF workspace launcher

param(
    [switch]$DryRun,
    [int]$ModelIndex = 0,
    [int]$ContextIndex = 0,
    [int]$KvIndex = 0,
    [int]$KCacheIndex = 0,
    [int]$VCacheIndex = 0,
    [int]$CacheRamMiB = -1,
    [ValidateSet("Prompt", "Manual", "ClineCoding", "OpenCodeCoding", "LlamaAgentResearch", "PiCoding", "DeepSeekHarness", "ARTEX")]
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
    [ValidateSet("Prompt", "Off", "MtpNextN", "NgramSimple", "NgramMod", "MtpNgramMod")]
    [string]$SpecMode = "Prompt",
    # MTP draft tokens (--spec-draft-n-max). Unsloth starts at 2; Flash-Next
    # guide used 5. Try 1..6 on this hardware. 0 = engine default only.
    [int]$SpecDraftNMax = 2,
    # PLE n-gram / per-layer embedding lazy disk read (--lazy-mode).
    # Qwen3.8-Flash-Next (qwen4exp) marks the huge PLE table TENSOR_READ_LAZY;
    # "on" streams rows from the GGUF on demand (FreeToken PR #311 equivalent)
    # instead of pinning tens of GiB in host RAM. Requires mmap (default).
    # Empty/"Prompt" = auto: "on" for Flash-Next/qwen4exp, else leave engine default.
    [ValidateSet("Prompt", "On", "Auto", "Off")]
    [string]$LazyMode = "Prompt",
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
    [ValidateSet("Prompt", "Pi", "Cline", "OpenCode", "LlamaAgent", "ComfyUI", "DeepSeekHarness", "ARTEX")]
    [string]$ClientMode = "Prompt",
    # Engine picker. Prompt = interactive menu (default for full launches).
    # Auto = Unsloth, except Flash-Next/qwen4exp which defaults to Laguna
    # hot-expert (measured ~13.5 t/s vs ~5 t/s Unsloth n-cpu-moe path).
    # Explicit Laguna/Unsloth/Strata skip the menu. Strata = Niko1221/Strata
    # on Windows HIP (win-hip-0131), served by its own serve/server.py.
    [ValidateSet("Prompt", "Auto", "Unsloth", "Laguna", "Strata")]
    [string]$EngineMode = "Prompt",
    [switch]$SkipClineAuth,
    [switch]$SkipClineOpen,
    [switch]$SkipOpenBrowser,
    [string]$ComfyUIFlags = "",
    # Per-request output token cap the recovery gateway applies to Cline
    # requests (thinking tokens count against it). 0 = gateway default (16384
    # or LLAMADOCK_CLINE_MAX_TOKENS). Raise it if Cline frequently reports
    # "maximum output token limit" mid-turn.
    [int]$ClineMaxTokens = 0,
    # Reasoning / thinking control, mapped to the native llama.cpp flags
    # --reasoning, --reasoning-effort and --reasoning-budget. Empty = show the
    # interactive menu (or fall back to the engine default). Values:
    #   off              no thinking (fastest; best for agentic tool calls)
    #   on               unrestricted thinking
    #   low|medium|high  bounded thinking via --reasoning-effort
    #   budget           cap thinking tokens via --reasoning-budget
    [string]$ReasoningMode = "",
    # Thinking token cap used with -ReasoningMode budget. 0 = default 2048.
    [int]$ReasoningBudget = 0,
    # Repeat penalty for repetition loops (--repeat-penalty / --repeat-last-n).
    # Default "" = llama.cpp default (1.0 = no penalty). 1.1 recommended for
    # degenerated loops (text like "待待待...").
    [string]$RepeatPenalty = "",
    # Repeat penalty window (--repeat-last-n). 0 = llama.cpp default (256).
    [int]$RepeatLastN = 0,
    # Sampler preset bundling the native llama.cpp output-quality flags.
    # Empty = show the interactive menu (or default to "qwen-code" on
    # quick launches). Values:
    #   qwen-code     Qwen3.6 official coding recs + repeat guard (recommended)
    #   chat          softer general-chat sampler
    #   repeat-only   llama.cpp defaults + repeat-penalty 1.1 only
    #   off           pure llama.cpp defaults
    [string]$SamplerPreset = "",
    # Individual sampler overrides (0 / empty = use the preset or default).
    # These take precedence over the selected preset.
    [double]$Temperature = 0,
    [int]$TopK = 0,
    [double]$TopP = 0,
    [double]$MinP = 0,
    # Prompt-cache KV reuse (--cache-reuse N). Min chunk size (tokens) to
    # reuse from the prompt cache via KV shifting. -1 = optimal default (512),
    # 0 = disabled. Coding agents (Cline) resend the same long system prompt +
    # tool definitions every turn; reuse skips re-prefilling the shared prefix.
    [int]$CacheReuse = -1,
    # Process/thread priority (--prio): low(-1) / normal(0) / medium(1) /
    # high(2) / realtime(3). Empty = optimal default "high". Realtime (3) can
    # starve the OS; avoid it.
    [string]$Priority = ""
)

$ErrorActionPreference = "Continue"
$utf8Helper = Join-Path $PSScriptRoot "tools\llamadock-utf8.ps1"
if (Test-Path -LiteralPath $utf8Helper) {
    . $utf8Helper
}

# Single engine since 2026-09-11: Unsloth llama.cpp build (b10909) with
# bundled ROCm/HIP runtime (amdhip64_7 / hipblas / ggml-hip). Works on
# RX 7800 XT without a system-wide ROCm install. Engine history: on the same
# day 2026-09-11 the stack briefly ran a CUDA/RTX 3080 build and came back to
# ROCm/HIP about three days later; comments claiming CUDA after ~09-14 are stale.
# Override with LLAMADOCK_UNSLOTH_SERVER if the path ever moves.
$UnslothServerPath = if ($env:LLAMADOCK_UNSLOTH_SERVER) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_UNSLOTH_SERVER)
}
elseif (Test-Path "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe") {
    "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe"
}
else {
    "C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe"
}

# Expert Laguna (llama-cpp-turboquant-experts-laguna) — FreeToken-style
# --moe-hot-expert. Measured Flash-Next decode: ~13.5 t/s @2k ctx on
# RX 7800 XT vs ~5 t/s on the Unsloth n-cpu-moe path. Uses the same
# llama-server-impl.dll as llama-cli; path override via LLAMADOCK_LAGUNA_SERVER.
$LagunaServerPath = if ($env:LLAMADOCK_LAGUNA_SERVER) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_LAGUNA_SERVER)
}
elseif (Test-Path "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-stage1\bin\llama-server.exe") {
    "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-stage1\bin\llama-server.exe"
}
elseif (Test-Path "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-stage1\bin\llama-cli.exe") {
    # Fallback: CLI stub is not used for server mode, but keep a stable hint path.
    "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-stage1\bin\llama-server.exe"
}
else {
    "C:\Users\dai86\llama-cpp-turboquant-experts-laguna\build-stage1\bin\llama-server.exe"
}

# Laguna HIP builds need the wheel-restored ROCm tree (not Program Files).
$LagunaRocmRoot = if ($env:LLAMADOCK_LAGUNA_ROCM) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_LAGUNA_ROCM)
}
else {
    "C:\Users\dai86\rocm-sdk-core\_rocm_sdk_core"
}

# Strata engine (2026-10-01): Niko1221/Strata built for Windows HIP / gfx1101 on the
# win-hip-0131 branch (engine 0.1.40.3 as of 2026-10-08; see
# C:\Users\dai86\Strata\STRATA-HANDOFF.md). Not a llama-server: its own
# serve/server.py fronts the engine on :8080 and speaks /v1/chat/completions, so the
# gateway (tools/llamadock-proxy.mjs) works unchanged in front of it.
$StrataRoot = if ($env:LLAMADOCK_STRATA_ROOT) {
    [Environment]::ExpandEnvironmentVariables($env:LLAMADOCK_STRATA_ROOT)
}
else {
    "C:\Users\dai86\Strata"
}
$StrataExe = Join-Path $StrataRoot "build-hip\strata.exe"
$StrataConfig = Join-Path $StrataRoot "strata-iq3.json"  # 2026-10-08: Q2_0 pack was deleted; IQ3 is the canonical serve config (traffic expert-profile + FP16 prefill)
$StrataPython = Join-Path $StrataRoot ".venv\Scripts\python.exe"

function Set-LagunaRocmEnvironment {
    # Handoff env: HOST_BANK=1 pins every expert at load → CPU~95% / Disk 100%.
    # HOST_PIN off unless explicitly overridden. PATH must include the wheel ROCm.
    if (-not (Test-Path -LiteralPath $LagunaRocmRoot)) { return }
    $env:ROCM_PATH = $LagunaRocmRoot
    $env:HIP_PATH = $LagunaRocmRoot
    $env:HIP_PLATFORM = "amd"
    if ([string]::IsNullOrWhiteSpace($env:HCC_AMDGPU_TARGET)) {
        $env:HCC_AMDGPU_TARGET = "gfx1101"
    }
    $env:HIP_VISIBLE_DEVICES = "0"
    $rocmBin = Join-Path $LagunaRocmRoot "bin"
    $llvmBin = Join-Path $LagunaRocmRoot "lib\llvm\bin"
    $prepend = @($rocmBin, $llvmBin) | Where-Object { Test-Path -LiteralPath $_ }
    if ($prepend.Count -gt 0) {
        $env:PATH = (($prepend -join ";") + ";" + $env:PATH)
    }
    if ([string]::IsNullOrWhiteSpace($env:LLAMA_MOE_HOST_BANK) -or $env:LLAMA_MOE_HOST_BANK -eq "1") {
        $env:LLAMA_MOE_HOST_BANK = "0"
    }
    if ([string]::IsNullOrWhiteSpace($env:LLAMA_MOE_HOST_PIN)) {
        $env:LLAMA_MOE_HOST_PIN = "0"
    }
    # Engine reply 2026-09-18: hit/miss in llama-server via llama.dll stats.
    if ([string]::IsNullOrWhiteSpace($env:LLAMA_MOE_SLOT_STATS)) {
        $env:LLAMA_MOE_SLOT_STATS = "1"
    }
    # Bank precreate is OFF by default on ffdcc41+; pin it off so a leftover
    # env cannot re-enable the 8K memory blow-up path.
    if ([string]::IsNullOrWhiteSpace($env:LLAMA_MOE_GPU_BANK_PRECREATE)) {
        $env:LLAMA_MOE_GPU_BANK_PRECREATE = "0"
    }
}

$ServerPath = $UnslothServerPath
$script:ActiveEngineName = "Unsloth"
$script:LagunaHotExpert = $false

function Ensure-UnslothCudaRuntime {
    # ggml-cuda.dll imports cublas64_13 / nvcudart_hybrid64. Unsloth's Release
    # folder does not ship them; without them --list-devices is empty and every
    # model silently runs on CPU. Drop the CUDA 13 DLLs from the bundled torch
    # next to llama-server.exe when missing (nvcudart_hybrid64 is an alias of
    # cudart64_13).
    param([string]$ServerExe = $ServerPath)
    if ([string]::IsNullOrWhiteSpace($ServerExe) -or -not (Test-Path -LiteralPath $ServerExe)) {
        return
    }
    $rel = Split-Path -Parent $ServerExe
    $cudaDll = Join-Path $rel "ggml-cuda.dll"
    if (-not (Test-Path -LiteralPath $cudaDll)) {
        return
    }
    if (Test-Path -LiteralPath (Join-Path $rel "cublas64_13.dll")) {
        return
    }
    $torchLibCandidates = @(
        "C:\Users\dai86\.unsloth\studio\unsloth_studio\Lib\site-packages\torch\lib",
        "C:\Users\dai86\Documents\ComfyUI\.venv\Lib\site-packages\torch\lib"
    )
    $torchLib = $torchLibCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $torchLib) {
        return
    }
    $copies = @(
        @{ Src = "cublas64_13.dll"; Dst = "cublas64_13.dll" },
        @{ Src = "cublasLt64_13.dll"; Dst = "cublasLt64_13.dll" },
        @{ Src = "cudart64_13.dll"; Dst = "cudart64_13.dll" },
        @{ Src = "cudart64_13.dll"; Dst = "nvcudart_hybrid64.dll" },
        @{ Src = "nvrtc64_130_0.dll"; Dst = "nvrtc64_130_0.dll" },
        @{ Src = "nvrtc-builtins64_130.dll"; Dst = "nvrtc-builtins64_130.dll" }
    )
    foreach ($c in $copies) {
        $src = Join-Path $torchLib $c.Src
        $dst = Join-Path $rel $c.Dst
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host ("Installed CUDA runtime DLL for llama-server: {0}" -f $c.Dst) -ForegroundColor DarkGray
        }
    }
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

    # The gateway may simply not be up yet: a serve started outside this launcher
    # (a manual restore, a reboot, a kill) leaves 8080 healthy but 8090 dead.
    # Start the recovery gateway once, exactly like the engine start block does,
    # and re-test before giving up.
    try {
        $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
        $gatewayArgs = @(
            (Join-Path $PSScriptRoot "tools\llamadock-proxy.mjs"),
            "--host", "127.0.0.1",
            "--port", "$GatewayPort",
            "--upstream", "http://127.0.0.1:8080",
            "--log-dir", (Join-Path $PSScriptRoot "logs")
        )
        $null = Start-Process -FilePath $nodeExe -ArgumentList $gatewayArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden
        for ($i = 0; $i -lt 10; ++$i) {
            Start-Sleep -Seconds 2
            if (Test-GatewayReady -ExpectedModelId $ExpectedModelId) {
                $script:ClientBaseUrl = $GatewayBaseUrl
                return $script:ClientBaseUrl
            }
        }
    }
    catch { }

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

    Write-Host "ハードウェア構成:" -ForegroundColor Green
    if ($Hardware.RamGB -gt 0) {
        Write-Host (" RAM  {0}GB" -f $Hardware.RamGB) -ForegroundColor DarkGray
    }
    else {
        Write-Host " RAM  不明" -ForegroundColor DarkGray
    }

    if ($Hardware.PrimaryGpu) {
        $vramText = if ($Hardware.PrimaryGpu.VramGB -gt 0) { "~$($Hardware.PrimaryGpu.VramGB)GB" } else { "不明" }
        Write-Host (" GPU  {0}" -f $Hardware.PrimaryGpu.Name) -ForegroundColor DarkGray
        Write-Host (" VRAM {0} ({1}, 信頼度 {2})" -f $vramText, $Hardware.PrimaryGpu.Source, $Hardware.PrimaryGpu.Confidence) -ForegroundColor DarkGray
    }
    else {
        Write-Host " GPU  未検出" -ForegroundColor DarkGray
        Write-Host " VRAM 不明" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Write-RuntimeAvailability {
    param([array]$Runtimes)

    Write-Host "ランタイム状態:" -ForegroundColor Green
    foreach ($runtime in $Runtimes) {
        $state = if (Test-Path $runtime.Path) { "あり" } else { "未インストール" }
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
    Write-Host "このモデルの前回の起動:" -ForegroundColor Green
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

function Resolve-AutoContextTokens {
    # Auto context: the safest ladder value that still buys headroom.
    # cap 65536 (64K ceiling) keeps KV mostly out of the swap-risk zone a
    # 128K+ window opens on a 16 GB card; overflow past the wall is absorbed
    # by the gateway's reactive compaction (tools/llamadock-proxy.mjs).
    # DeepSeek caps at 16K (measured: 32K drops t/s from ~6.4 to ~4) and
    # Laguna hot-expert at 4K (8K+ had a memory incident: WS~61GB).
    param(
        [double]$ModelSizeGB,
        [double]$RamGB,
        [switch]$DeepSeek,
        [switch]$LagunaHotExpert
    )

    if ($LagunaHotExpert) { return 4096 }

    $capTokens = if ($DeepSeek) { 16384 } else { 65536 }
    $ramCeiling = Get-MaxContextTokensForRam -ModelSizeGB $ModelSizeGB -RamGB $RamGB
    $target = [math]::Min($capTokens, $ramCeiling)

    foreach ($step in @(65536, 32768, 16384, 8192)) {
        if ($target -ge $step) { return $step }
    }
    return 8192
}

function Read-MenuInt {
    # Shared reader for every numbered menu / numeric prompt in the launcher.
    # Re-prompts until an integer inside [Min..Max] is typed. Empty input
    # returns $Default when one is supplied (Enter = recommended choice);
    # without $Default an empty line simply asks again. $InvalidMessage, when
    # set, is shown in yellow after each rejected line.
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][int]$Max,
        [int]$Min = 1,
        [int]$Default = [int]::MinValue,
        [string]$InvalidMessage = ""
    )
    do {
        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw) -and $Default -ne [int]::MinValue) { return $Default }
        $value = 0
        $valid = [int]::TryParse($raw, [ref]$value)
        if (($valid -and ($value -lt $Min -or $value -gt $Max)) -or (-not $valid -and -not [string]::IsNullOrWhiteSpace($raw))) {
            if ($InvalidMessage) { Write-Host $InvalidMessage -ForegroundColor Yellow }
        }
        $valid = $valid -and $value -ge $Min -and $value -le $Max
    } while (-not $valid)
    return $value
}

function Test-PortBusy {
    $conn = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    if ($conn) { return $true }

    $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Get-RequiredEngine {
    param([object]$Model)
    # Default engine by model family. Flash-Next (qwen4exp) is expert-heavy:
    # Laguna --moe-hot-expert is the measured fastest path (~13.5 t/s).
    # Everything else stays on Unsloth HIP (stable, lazy-mode, general GGUF).
    $text = "$($Model.Name) $($Model.FullName)"
    if ($text -match "(?i)qwen4exp|Flash[-_ ]?Next|qwen3\.8[-_ ]?flash") {
        return "Laguna"
    }
    return "Unsloth"
}

function Resolve-EnginePaths {
    param([string]$Engine)
    switch ($Engine) {
        "Laguna" {
            if (-not (Test-Path -LiteralPath $LagunaServerPath)) {
                Write-Host "ERROR: Laguna llama-server not found:" -ForegroundColor Red
                Write-Host "  $LagunaServerPath" -ForegroundColor Red
                Write-Host "Build tools\\server (llama-server) in llama-cpp-turboquant-experts-laguna\\build-stage1," -ForegroundColor Yellow
                Write-Host "or set LLAMADOCK_LAGUNA_SERVER to llama-server.exe." -ForegroundColor Yellow
                exit 1
            }
            Set-LagunaRocmEnvironment
            $script:ActiveEngineName = "Laguna"
            $script:LagunaHotExpert = $true
            return $LagunaServerPath
        }
        "Strata" {
            foreach ($p in @($StrataExe, $StrataConfig, $StrataPython)) {
                if (-not (Test-Path -LiteralPath $p)) {
                    Write-Host "ERROR: Strata engine component not found:" -ForegroundColor Red
                    Write-Host "  $p" -ForegroundColor Red
                    Write-Host "Build C:\\Users\\dai86\\Strata (branch win-hip-0131) per STRATA-HANDOFF.md section 5," -ForegroundColor Yellow
                    Write-Host "or set LLAMADOCK_STRATA_ROOT to the Strata checkout." -ForegroundColor Yellow
                    exit 1
                }
            }
            $script:ActiveEngineName = "Strata"
            $script:LagunaHotExpert = $false
            return $StrataExe
        }
        default {
            $script:ActiveEngineName = "Unsloth"
            $script:LagunaHotExpert = $false
            return $UnslothServerPath
        }
    }
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
    if ($procInfo.ProcessName -notmatch "^(llama-server|node|python|pythonw|powershell|pwsh|strata)$") {
        return $false
    }
    try {
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $cimProc) { return $false }
        # serve/server.py must match BOTH spellings: our own Strata launches pass the slash form
        # ("python serve/server.py --engine strata --config strata-*.json"), which made the switch
        # path refuse to stop the serve it had started itself (2026-10-09).
        return ([string]$cimProc.CommandLine -match "llama-server|llamadock|server-supervisor|gateway|mcp-server|serve\.server|serve.server\.py|--config.{0,40}strata-|strata\.exe")
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

function Stop-ActiveServerStack {
    # $proc only exists on the llama-server supervisor path. Strata launches and
    # keep-alive runs never assign it, so `$proc.HasExited` there dereferences
    # $null and Stop-Process gets a null Id (the session then "stops" nothing).
    # Fall back to the supervisor pid markers, then to port ownership, both of
    # which already refuse to kill processes LlamaDock does not manage.
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Stop-LlamaDockSupervisor | Out-Null
    Stop-ServerOnPort -Port 8080 | Out-Null
    Stop-ServerOnPort -Port 8090 | Out-Null
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
    # Optional so existing no-arg callers (workspace dispatch, reuse path)
    # keep working: without a default, the script-scope call resolves $ModelName
    # to $null and Start-Process rejects the ArgumentList outright.
    param([string]$ModelName = "")

    if ($SkipClineOpen) {
        Write-Host "SKIP: Cline would open" -ForegroundColor Yellow
        return
    }
    if ([string]::IsNullOrWhiteSpace($ModelName)) { $ModelName = $modelShort }

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

function Get-LiveContextTokens {
    # Read the running llama-server's actual n_ctx from /props so client
    # configs (OpenCode limit) match the real server instead of a guess.
    # The gateway is tried second: it proxies the OpenAI paths but may not
    # forward the native /props endpoint.
    foreach ($base in @($ServerBaseUrl, $GatewayBaseUrl)) {
        try {
            $props = Invoke-RestMethod -Uri "$base/props" -TimeoutSec 3 -ErrorAction Stop
            $n = [int]$props.default_generation_settings.n_ctx
            if ($n -gt 0) { return $n }
        }
        catch {
        }
    }
    return 0
}

function New-LocalOpenCodeConfig {
    param(
        [string]$ModelName,
        [int]$ContextTokens = 0
    )

    $configDir = Join-Path $PSScriptRoot "mcp-data"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $configPath = Join-Path $configDir "opencode-local.json"
    # Model limit metadata: OpenCode reads limit.context/output to decide when
    # to compact or cap output. Without it the client assumes 128K-class
    # windows and overruns the real server context mid-conversation.
    $contextTokens = if ($ContextTokens -gt 0) { $ContextTokens } else { Get-LiveContextTokens }
    if ($contextTokens -le 0) { $contextTokens = 32768 }
    # Output cap mirrors the recovery gateway's max_tokens default so a long
    # turn cannot blow past the server window (thinking tokens count against
    # it). Never larger than the context itself.
    $outputTokens = [math]::Max(1024, [math]::Min(16384, $contextTokens))
    $models = [ordered]@{}
    $models[$ModelName] = [ordered]@{
        name  = $ModelName
        limit = [ordered]@{
            context = $contextTokens
            output  = $outputTokens
        }
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

function Open-PiClient {
    param([string]$ModelName = "")

    # Pi (pi.dev) is a terminal coding agent, so it reuses the same client
    # shell as Cline / OpenCode. The shell registers the running model under
    # the 'llamadock' provider in ~/.pi/agent/models.json (OpenAI-compatible
    # base URL pointing at the LlamaDock recovery gateway) and starts pi with
    # that model preselected.
    if ([string]::IsNullOrWhiteSpace($ModelName)) { $ModelName = $modelShort }
    $clientShell = Join-Path $PSScriptRoot "tools\llamadock-client-shell.ps1"

    Write-Host "Opening Pi (pi.dev) in PowerShell..." -ForegroundColor Cyan
    return Start-Process -FilePath "powershell.exe" -WorkingDirectory $PSScriptRoot -PassThru -ArgumentList @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", $clientShell,
        "-Client", "Pi",
        "-ModelName", $ModelName,
        "-BaseUrl", $ClientBaseUrl,
        "-Workspace", $PSScriptRoot
    )
}

$script:ComfyProfileChoice = $null
$script:ComfyFlagsChoice = ""
$script:PlanModeChoice = $false
$script:PlanModelChoice = "Qwen3.8-27B-GPU"
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

function Test-ComfyUICuda {
    # True when the ComfyUI venv torch is a CUDA build (NVIDIA).
    try {
        $comfyPython = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
        $out = & $comfyPython -c "import torch; print(int(torch.version.cuda is not None and torch.cuda.is_available()))" 2>$null
        return ($out -match "^1")
    }
    catch {
        return $false
    }
}

function Test-ComfyUISage {
    # True when sageattention imports in the ComfyUI venv (CUDA path).
    try {
        $comfyPython = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
        $out = & $comfyPython -c "import importlib.util; print(int(importlib.util.find_spec('sageattention') is not None))" 2>$null
        return ($out -match "^1")
    }
    catch {
        return $false
    }
}

function Get-TritonBackendFlags {
    # Returns @("--enable-triton-backend") only when the user opts in with
    # $env:LLAMADOCK_COMFY_TRITON=1 AND triton >= 3.7 is installed.
    # On ROCm this was crash-prone on the H3 INT8 path. On CUDA it is still
    # opt-in until bench-tested, so the `triton`/`super` profiles do not force it.
    if ($env:LLAMADOCK_COMFY_TRITON -ne "1") {
        Write-Host "NOTE: --enable-triton-backend omitted (opt-in via LLAMADOCK_COMFY_TRITON=1)." -ForegroundColor Yellow
        return @()
    }
    $tritonVersion = Get-ComfyUITritonVersion
    if ($null -ne $tritonVersion -and $tritonVersion -ge [version]"3.7") {
        return @("--enable-triton-backend")
    }
    if ($null -ne $tritonVersion) {
        Write-Host ("WARNING: triton {0} is too old (needs >= 3.7);" -f $tritonVersion) -ForegroundColor Yellow
        Write-Host "         --enable-triton-backend omitted." -ForegroundColor Yellow
    }
    else {
        Write-Host "WARNING: triton is not installed in the ComfyUI venv; --enable-triton-backend omitted." -ForegroundColor Yellow
    }
    return @()
}

function Get-ComfyUILaunchArgs {
    # Researched MiniMax H3 tuning for the ComfyUI workspace. Sources and
    # the reasoning behind each profile live in docs/MiniMax-H3-Tuning.md.
    # GPU stack: AMD RX 7800 XT / torch ROCm hip 7.2 (verified 2026-10-08).
    # sage/triton profiles stay dormant here (sageattention wants a CUDA
    # torch); the gated checks below keep them future-proof.
    #
    # Precedence: -ComfyUIFlags parameter > $env:LLAMADOCK_COMFY_FLAGS >
    #             interactive picker (custom flags) > profile
    #             (env LLAMADOCK_COMFY_PROFILE > interactive picker > default).
    #
    # Profiles:
    #   default - reserve VRAM for the OS/desktop and let DynamicVRAM fill
    #             the rest of the card. No --lowvram: it forces the text encoder
    #             onto the CPU and offloads the DiT unnecessarily.
    #   sage    - default + --use-sage-attention (CUDA + sageattention installed).
    #             Community-default for MiniMax H3 on NVIDIA (~2x attention).
    #   ck      - default + --use-ck-attention (comfy-kitchen attention, needs
    #             ComfyUI >= 0.33.0). Fallback when sageattention is missing.
    #   fast    - default + --fast fp16_accumulation --force-non-blocking.
    #   triton  - default + optional --enable-triton-backend (LLAMADOCK_COMFY_TRITON=1).
    #   super   - ck + optional triton; pair with h3_workflow_super.json.
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
        "fast" { $extra = @("--reserve-vram", "6.0", "--fast", "fp16_accumulation", "--force-non-blocking") }
        "triton" { $extra = @("--reserve-vram", "6.0") + (Get-TritonBackendFlags) }
        "super" { $extra = @("--reserve-vram", "6.0", "--use-ck-attention") + (Get-TritonBackendFlags) }
        "ck" { $extra = @("--reserve-vram", "6.0", "--use-ck-attention") }
        "sage" {
            if (Test-ComfyUISage) {
                $extra = @("--reserve-vram", "6.0", "--use-sage-attention")
            }
            else {
                Write-Host "WARNING: sageattention not installed; falling back to --use-ck-attention." -ForegroundColor Yellow
                $extra = @("--reserve-vram", "6.0", "--use-ck-attention")
            }
        }
        "bench" { $extra = @() }
        default { $extra = @("--reserve-vram", "6.0") }
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
    $isCuda = Test-ComfyUICuda
    $hasSage = Test-ComfyUISage
    $fastProfile = if ($isCuda -and $hasSage) { "sage" } else { "ck" }
    $fastLabel = if ($fastProfile -eq "sage") { "sageattention（CUDA・約2倍）" } else { "comfy-kitchen attention（約11%）" }

    Write-Host ""
    Write-Host "ComfyUI tuning (MiniMax H3): フローはどれも同じ。変わるのは「生成速度」と「企画LLM」" -ForegroundColor Green
    Write-Host " [1] plan    - 高速化 + 企画LLMを自分で選ぶ【推奨】(Enter)"
    Write-Host (" [2] {0}      - 高速化 + 企画LLMは既定（27B・GPU）" -f $fastProfile)
    Write-Host " [3] default - 高速化なし（互換）+ 企画LLMは既定（27B・GPU）"
    Write-Host " [4] custom  - 生のComfyUIフラグ + 企画LLMは既定（27B・GPU）"
    Write-Host (" ※高速化({0})={1}（ComfyUI 0.33+ / torch CUDA）" -f $fastProfile, $fastLabel) -ForegroundColor DarkGray
    Write-Host ""
    $tuningSelection = Read-MenuInt -Prompt "ComfyUI チューニングを選択 (1-4)、または Enter で plan" -Min 1 -Max 4 -Default 1
    switch ($tuningSelection) {
        1 {
            $script:ComfyProfileChoice = $fastProfile
            $script:PlanModeChoice = $true
            $script:PlanModelChoice = Select-PlanModel
        }
        2 {
            $script:ComfyProfileChoice = $fastProfile
            $script:PlanModeChoice = $true
            $script:PlanModelChoice = "Qwen3.8-27B-GPU"
        }
        3 {
            $script:ComfyProfileChoice = "default"
            $script:PlanModeChoice = $true
            $script:PlanModelChoice = "Qwen3.8-27B-GPU"
        }
        4 {
            $rawFlags = Read-Host "生の ComfyUI フラグ (例: --reserve-vram 0.5 --force-non-blocking)"
            $script:ComfyProfileChoice = "custom"
            $script:ComfyFlagsChoice = $rawFlags
            $script:PlanModeChoice = $true
            $script:PlanModelChoice = "Qwen3.8-27B-GPU"
        }
    }
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
            $_.Name -notmatch "(?i)DFlash2" -and
            $_.Name -notmatch "(?i)^mtp-" -and
            $_.Name -notmatch "(?i)nextn" -and
            $_.Name -notmatch "(?i)-draft-"
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
    #   Qwen3.8-27B-GPU / Custom (+ $script:PlanModelCustom)
    #   （Qwen3.5-4B / IQ4_XS / A35B キーは GGUF 削除に伴い 2026-10-08 廃止）
    $known = @(
        @{
            Key  = "Qwen3.8-27B-GPU"
            Path = "C:\Users\dai86\.lmstudio\models\RentedNoodle\Qwen3.8-27B-OrcaRouter-GSQ-RCO-IQ3_XXS-Uncensored\Qwen3.8-27B-OrcaRouter-GSQ-RCO-IQ3_XXS-v2.0-qatfa.gguf"
            Gpu  = $true
        }
    )
    $descByKey = @{
        "Qwen3.8-27B-GPU"            = "Qwen3.8-27B OrcaRouter IQ3_XXS - GPU・企画フェーズのみ・視覚あり（9.7GB・既定）"
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
    # Pick the planning LLM for plan mode. GPU models (the 27B default) run
    # during the planning phase only and are killed before every generation
    # so the video model gets the VRAM back. The menu lists only files that
    # actually exist: known models with dedicated launch keys first, then
    # auto-detected GGUFs from .lmstudio\models (Get-PlanModelMenu).
    $menu = Get-PlanModelMenu
    Write-Host ""
    Write-Host "Planning LLM:" -ForegroundColor Green
    if ($menu.Count -eq 0) {
        Write-Host " (GGUF モデルが見つかりません。企画モードなしで起動します)" -ForegroundColor Yellow
        return "Off"
    }
    $idx = 1
    $defaultIdx = 1
    foreach ($e in $menu) {
        if ($e.Key) {
            Write-Host (" [{0}] {1}" -f $idx, $e.Label)
            if ($e.Key -eq "Qwen3.8-27B-GPU") { $defaultIdx = $idx }
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
    $planSelection = Read-MenuInt -Prompt "企画 LLM を選択 (1-$max)、または Enter で既定" -Min 1 -Max $max -Default $defaultIdx
    $chosen = $menu[$planSelection - 1]
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
}

function Test-H3ChatTabOpen {
    # h3-chat (8189) にブラウザが接続中なら True。確立済み接続が無ければ
    # タブは閉じていると判断し、False を返す。
    $conns = Get-NetTCPConnection -LocalPort 8189 -State Established -ErrorAction SilentlyContinue
    return ($null -ne $conns -and @($conns).Count -gt 0)
}

function Get-LivePlanStatus {
    # 稼働中 h3-chat (8189) の企画 LLM 設定（GPU/CPU + モデルパス）を取得する。
    # リポジトリ世代で API が異なるため /api/plan-status → /api/plan-models の順に試す。
    try {
        $s = Invoke-RestMethod -Uri "http://127.0.0.1:8189/api/plan-status" -TimeoutSec 5 -ErrorAction Stop
        if ($null -ne $s) { return @{ Gpu = [bool]$s.gpu; Model = [string]$s.model } }
    }
    catch { }
    try {
        $s = Invoke-RestMethod -Uri "http://127.0.0.1:8189/api/plan-models" -TimeoutSec 5 -ErrorAction Stop
        if ($s -and $s.current) { return @{ Gpu = [bool]$s.current.gpu; Model = [string]$s.current.path } }
    }
    catch { }
    return $null
}

function Test-TcpPort {
    # ポートのリスナーへの TCP 接続可否を 2 秒で判定する。/api/queue 等の
    # HTTP プローブは ComfyUI 停止中に 503 を返して偽陰性になるため、
    # h3-chat の生存確認はこの TCP プローブで行う。
    param([int]$Port)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(2000)
        if ($ok) { $tcp.EndConnect($async) }
        $tcp.Close()
        return $ok
    }
    catch { return $false }
}

function Stop-LlamaDockPlanStack {
    # h3-chat (8189) と企画 llama-server (8190/8191) だけをポートのリスナー PID で
    # 的確に停止する（ComfyUI 8188 やコーダー 8080 は巻き込まない）。
    param([switch]$IncludeChat)
    $ports = @(8190, 8191)
    if ($IncludeChat) { $ports = @(8189) + $ports }
    foreach ($p in $ports) {
        try {
            $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
            foreach ($ownerPid in @($conns | Select-Object -ExpandProperty OwningProcess -Unique)) {
                if ($ownerPid -and $ownerPid -ne 0) { Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue }
            }
        }
        catch { }
    }
    if ($IncludeChat) {
        # 二重起動の片割れなどポートを握らない h3-chat.py も掃除する
        try {
            Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'h3-chat\.py' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        catch { }
    }
    Start-Sleep -Milliseconds 800
}

function Start-H3Chat {
    # Starts the text-to-video chat UI (tools\h3-chat.py, port 8189) if it is
    # not already running, then opens it in the default browser. This is what
    # the user actually wants to see: a text box, not the ComfyUI node graph.
    # With plan mode ([1] plan in the tuning menu, or Enter) it delegates to
    # h3-chat.ps1,
    # which also starts the planning LLM (llama-server, GPU 27B on demand) so the
    # conversation-to-video flow works out of the box.
    param([switch]$SkipOpenBrowser)
    $chatUrl = "http://127.0.0.1:8189"
    $chatPy = Join-Path $PSScriptRoot "tools\h3-chat.py"
    if ($script:PlanModeChoice) {
        $h3chatPs1 = Join-Path $PSScriptRoot "tools\h3-chat.ps1"
        if (Test-Path -LiteralPath $h3chatPs1) {
            # Double-launch guard + selection reconcile. h3-chat.py fixes the
            # planning LLM (GPU/CPU + model path) from its startup env, so an
            # already-running chat silently ignores a different -PlanModel.
            # Compare the live stack's plan status with the selection: match
            # → reuse; differ → stop the old chat + planners and fall through
            # to a fresh start with the chosen model.
            $chatUpNow = Test-TcpPort 8189
            if (-not $chatUpNow) {
                # 8189 にリスナーが残っているのに TCP 接続できないのはスタック
                # した旧 h3-chat。そのまま新規起動するとポート競合するため、
                # 掃除してから続行する。
                $stuckChat = Get-NetTCPConnection -LocalPort 8189 -State Listen -ErrorAction SilentlyContinue
                if ($stuckChat) {
                    Write-Host "8189 の旧 h3-chat が応答していないため停止して再起動します..." -ForegroundColor Yellow
                    Stop-LlamaDockPlanStack -IncludeChat
                }
            }
            if ($chatUpNow) {
                # 選択モデルの Gpu フラグ/パス（Custom は $script:PlanModelCustom）。
                $desiredGpu = $false
                $desiredPath = ""
                if ($script:PlanModelChoice -eq "Custom" -and $script:PlanModelCustom) {
                    $desiredGpu = [bool]$script:PlanModelCustom.Gpu
                    $desiredPath = [string]$script:PlanModelCustom.Path
                }
                else {
                    $wantEntry = Get-PlanModelMenu | Where-Object { $_.Key -eq $script:PlanModelChoice } | Select-Object -First 1
                    if ($wantEntry) {
                        $desiredGpu = [bool]$wantEntry.Gpu
                        $desiredPath = [string]$wantEntry.Path
                    }
                }
                $selectionOk = $false
                $live = Get-LivePlanStatus
                if ($live) {
                    $selectionOk = ($live.Gpu -eq $desiredGpu)
                    if ($selectionOk -and $desiredPath) {
                        $liveLeaf = if ($live.Model) { Split-Path -Leaf ($live.Model -replace '/', '\') } else { "" }
                        $wantLeaf = Split-Path -Leaf $desiredPath
                        if (-not $liveLeaf -or -not ($liveLeaf -ieq $wantLeaf)) { $selectionOk = $false }
                    }
                }
                if ($selectionOk) {
                    Write-Host "h3-chat is already running with the selected planning LLM; opening the UI." -ForegroundColor Green
                }
                else {
                    Write-Host "Running h3-chat uses a different planning LLM; restarting it with the selection..." -ForegroundColor Yellow
                    Stop-LlamaDockPlanStack -IncludeChat
                    $chatUpNow = $false
                }
            }
            if (-not $chatUpNow) {
                # 企画 LLM のエンジン: CPU / GPU とも Unsloth 同梱の llama-server
                # (HIP / RX 7800 XT) で起動する ※2026-09-11〜09-14 の 3 日間だけ
                # CUDA/RTX 3080 ビルドだった時期がある。
                $planEngineHint = "Unsloth (HIP)"
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
            # Wait for the chat UI (and, behind it, the planning LLM) to come
            # up before opening the browser, so the user lands on a live page.
            $chatReady = $false
            for ($i = 0; $i -lt 45; $i++) {
                Start-Sleep -Seconds 2
                try {
                    $h = Invoke-WebRequest -Uri "$chatUrl/api/queue" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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
            elseif ($chatUpNow -and (Test-H3ChatTabOpen)) {
                Write-Host "h3-chat UI は既に開いているため新しいタブは開きません: $chatUrl (planning mode)" -ForegroundColor DarkGray
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
        $h = Invoke-WebRequest -Uri "$chatUrl/api/queue" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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
    elseif ($chatUp -and (Test-H3ChatTabOpen)) {
        Write-Host "h3-chat UI は既に開いているため新しいタブは開きません: $chatUrl" -ForegroundColor DarkGray
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
        $existingComfyHealth = Invoke-WebRequest -Uri "$comfyUrl/system_stats" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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
            $health = Invoke-WebRequest -Uri "$comfyUrl/system_stats" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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


function Stop-StaleDeepSeekHarness {
    # DeepSeek Harness (dsh web) owns port 3080 and must be a single fresh
    # instance: every launch prints a new one-time ?token= URL, and an instance
    # left over from an older dsh version (tools/dsh-update.ps1 swaps the npm
    # package beneath it) keeps serving the stale boot page ("Failed to load
    # plugins" / "client-modules: boot manifest batches must be an array").
    # Kill any dsh listener on 3080 before (re)starting the harness; unrelated
    # processes on the port are left alone (same pattern as Stop-H3Stack).
    $listeners = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
    foreach ($ownerPid in @($listeners | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })) {
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $cmd = ""
        try {
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
            if ($cim) { $cmd = [string]$cim.CommandLine }
        }
        catch { }
        if ($cmd -match "dsh" -and $cmd -match "web") {
            Write-Host " Stop stale DeepSeek Harness PID $ownerPid ($($proc.ProcessName)) [port 3080]" -ForegroundColor Yellow
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host " Skip PID $ownerPid ($($proc.ProcessName)) on port 3080: not the DeepSeek Harness." -ForegroundColor Yellow
        }
    }

    # Wait for the port to free so the fresh instance can bind it.
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "WARNING: port 3080 is still in use; the new DeepSeek Harness may not start." -ForegroundColor Yellow
}

function Open-DeepSeekHarnessClient {
    # DeepSeek Harness — agent harness framework.  The Windows desktop app
    # (%LOCALAPPDATA%\Programs\DeepSeek Harness) is the preferred form: it
    # self-updates through its own updater and does not depend on the npm CLI.
    # The harness's llm-deepseek adapter reads DEEPSEEK_BASE_URL / DEEPSEEK_API_KEY
    # from its launch environment. Pointing them at the LlamaDock gateway makes the
    # harness run on the local llama.cpp model instead of the DeepSeek cloud API,
    # and the env key also satisfies the web UI's "Add an API key" onboarding gate
    # (credentials-local reports source:env as configured).

    # Clear any stale dsh on 3080 (old version / leftover session) first, so
    # whatever we start actually serves the UI instead of a stale boot page.
    Stop-StaleDeepSeekHarness

    $env:DEEPSEEK_BASE_URL = "$ClientBaseUrl/v1"
    $env:DEEPSEEK_API_KEY = "not-needed"

    # ---- the Windows desktop app (preferred; all Web-GUI launches use it) --
    $dshApp = $env:LLAMADOCK_DSH_APP
    if ([string]::IsNullOrWhiteSpace($dshApp)) {
        $candidates = @( (Join-Path $env:LOCALAPPDATA "Programs\DeepSeek Harness\DeepSeek Harness.exe") )
        $candidates += Get-ChildItem (Join-Path $env:LOCALAPPDATA "Programs") -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'deepseek.?harness' } |
            ForEach-Object { Get-ChildItem $_.FullName -Filter '*.exe' -ErrorAction SilentlyContinue } |
            Where-Object { $_.Name -notmatch 'Uninstall|updater' } |
            Select-Object -First 1 -ExpandProperty FullName
        $dshApp = @($candidates) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    }
    if ($dshApp -and (Test-Path -LiteralPath $dshApp)) {
        Write-Host "DeepSeek Harness (Windows app): $dshApp" -ForegroundColor Cyan
        Write-Host "LLM backend: $ClientBaseUrl/v1 (ローカル / APIキー不要)" -ForegroundColor Cyan
        $proc = Start-Process -FilePath $dshApp -WorkingDirectory $PSScriptRoot -PassThru
        Write-Host "DeepSeek Harness を起動しました (Windows アプリ版)" -ForegroundColor Green
        return $proc
    }

    # ---- the npm CLI (fallback when the desktop app is not installed) ------
    $dshCheck = Join-Path $PSScriptRoot "tools\dsh-update.ps1"
    if (Test-Path -LiteralPath $dshCheck) {
        # Run update check in background (non-blocking)
        Start-Job -ScriptBlock { param($p) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p } -ArgumentList $dshCheck | Out-Null
    }
    Write-Host "DeepSeek Harness を起動しています..." -ForegroundColor Cyan
    Write-Host "LLM backend: $ClientBaseUrl/v1 (ローカル llama.cpp / APIキー不要)" -ForegroundColor Cyan

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


function Open-ARTEXClient {
    # ARTEX workspace: AI autonomous penetration-testing console (English
    # build of hongvincent/ARTEX, installed at C:\Users\dai86\ARTEX).
    # Same launcher as the desktop shortcut: it starts the bundled portable
    # PostgreSQL (:5433), the artex.exe web console (:8787) if not already
    # up, then opens the browser. ARTEX talks to LlamaDock through its
    # System -> LLM card "LlamaDock Local (abliterated)" pointing at the
    # gateway, so no per-launch env wiring is needed here.
    $artexBat = "C:\Users\dai86\ARTEX\ARTEX-launch.bat"
    if (-not (Test-Path -LiteralPath $artexBat)) {
        Write-Host "ERROR: ARTEX launcher not found: $artexBat" -ForegroundColor Red
        return $null
    }
    Start-Process -FilePath $artexBat -WindowStyle Minimized
    Write-Host "ARTEX 起動中... コンソール: http://localhost:8787" -ForegroundColor Green
    return $null
}

function Open-WorkspaceClient {
    param([string]$Mode, [string]$ModelPath, [string]$ModelName)

    switch ($Mode) {
        "Pi" { return Open-PiClient -ModelName $ModelName }
        "ComfyUI" { return Open-ComfyUIClient }
        "LlamaAgent" { return Open-LlamaAgentClient -ModelPath $ModelPath }
        "OpenCode" { return Open-OpenCodeClient -ModelName $ModelName }
        "DeepSeekHarness" { return Open-DeepSeekHarnessClient }
        "ARTEX" { return Open-ARTEXClient }
        default {
            Set-ClineLocalModel -ModelName $ModelName
            return Open-ClineClient -ModelName $ModelName
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
    Write-Host "LlamaDock セッション" -ForegroundColor Cyan
    Write-Host " [1] 同じワークスペースを再起動"
    Write-Host " [2] モデルを維持したままワークスペースを変更"
    Write-Host " [3] モデルを変更 - サーバーを停止してセレクターへ戻る"
    Write-Host " [4] サーバーを停止して終了"
    Write-Host " [5] サーバーを起動したまま終了"
    $choice = Read-MenuInt -Prompt "セッション操作を選択 (1-5)" -Min 1 -Max 5 -InvalidMessage "選択が不正です。1 から 5 の数字を入力してください。"
    if ($choice -eq 1) { return @("relaunch", "") }
    if ($choice -eq 2) {
        Write-Host " [1] Pi  [2] Cline  [3] OpenCode  [4] Llama Agent  [5] ComfyUI  [6] DeepSeek Harness  [7] ARTEX"
        $workspace = Read-Host "ワークスペースを選択"
        $modes = @("Pi", "Cline", "OpenCode", "LlamaAgent", "ComfyUI", "DeepSeekHarness", "ARTEX")
        $index = 0
        if ([int]::TryParse($workspace, [ref]$index) -and $index -ge 1 -and $index -le $modes.Count) {
            return @("switch", $modes[$index - 1])
        }
        return @("relaunch", "")
    }
    if ($choice -eq 3) { return @("change-model", "") }
    if ($choice -eq 4) {
        # Ask whether to also shut down the video stack (ComfyUI / h3-chat /
        # planning LLM) that keeps holding GPU and RAM after the session.
        $stopStack = Read-Host "動画スタック (ComfyUI / h3-chat / planning LLM) も停止して GPU+RAM を解放しますか? (y/N)"
        if ($stopStack -match "^(y|yes)$") { $script:StopAllOnExit = $true }
        return @("stop", "")
    }
    return @("leave", "")
}

Show-LlamaDockBanner

$hardware = Get-HardwareEstimate

$runtimeCandidates = @(
    [PSCustomObject]@{ Name = "Unsloth"; Path = $UnslothServerPath }
    [PSCustomObject]@{ Name = "Laguna (hot-expert)"; Path = $LagunaServerPath }
)

# ComfyUI is a model-independent workspace. Keep it at the front door so a
# ComfyUI launch never makes the user pick an unrelated GGUF or start a
# llama-server first.
$comfyOnly = $ClientMode -eq "ComfyUI"
if (-not $DryRun -and -not $comfyOnly -and $ClientMode -eq "Prompt") {
    Write-Host "起動ターゲット:" -ForegroundColor Green
    Write-Host " [1] LLM ワークスペース - モデルとクライアントを選択"
    Write-Host " [2] ComfyUI - 動画/音声ワークスペース（GGUF 選択なし）"
    Write-Host " [3] Web GUI - ブラウザで起動/停止/計測"
    Write-Host ""
    $targetSelection = Read-MenuInt -Prompt "起動するワークスペースを選択 (1-3、Enter=LLM)" -Min 1 -Max 3 -Default 1

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

# Build model list (all models except mmproj). Multi-part GGUFs
# (name-00001-of-0000N.gguf) are offered once as the first shard; SizeMB is
# the sum of every sibling so VRAM/RAM fit math sees the real footprint.
$models = @()
foreach ($f in $allFiles) {
    if ($f.Name -notmatch "mmproj" -and $f.Name -notmatch "(?i)DFlash2") {
        if ($f.Name -match "^(?<base>.+)-(?<idx>\d{5})-of-(?<total>\d{5})\.gguf$") {
            $partIdx = [int]$Matches.idx
            $partTotal = $Matches.total
            $partBase = $Matches.base
            if ($partIdx -ne 1) { continue }
            $basePattern = "^$([regex]::Escape($partBase))-\d{5}-of-$partTotal\.gguf$"
            $siblings = @($allFiles | Where-Object { $_.Name -match $basePattern })
            $totalBytes = ($siblings | Measure-Object -Property Length -Sum).Sum
            $isTQ3 = $f.Name -match "TQ3"
            $models += [PSCustomObject]@{
                Name = "$partBase [$($siblings.Count)-part GGUF]"
                FullName = $f.FullName
                SizeMB = [math]::Round($totalBytes / 1MB, 1)
                IsTQ3 = $isTQ3
                IsSplit = $true
                PartCount = $siblings.Count
            }
            continue
        }
        $isTQ3 = $f.Name -match "TQ3"
        $models += [PSCustomObject]@{
            Name = $f.Name
            FullName = $f.FullName
            SizeMB = [math]::Round($f.Length / 1MB, 1)
            IsTQ3 = $isTQ3
            IsSplit = $false
            PartCount = 1
        }
    }
}

if ($models.Count -eq 0) {
    Write-Host "エラー: .gguf モデルが見つかりません!" -ForegroundColor Red
    Read-Host "終了するには Enter"
    exit 1
}

# Sort by size (TQ3 models first)
$models = @($models | Sort-Object -Property @{ Expression = "IsTQ3"; Descending = $true }, @{ Expression = "SizeMB"; Descending = $true })

# Keep the detailed front door visible: model, engine, workflow, and runtime
# choices are part of the launch contract and must not be hidden behind a
# secondary menu.
$tq3Count = @($models | Where-Object { $_.IsTQ3 }).Count
Write-Host "モデル一覧" -ForegroundColor Green
Write-Host "GGUF $($models.Count)件 / TQ3 $($tq3Count)件 を検出" -ForegroundColor DarkGray
Write-Host ""
for ($i = 0; $i -lt $models.Count; $i++) {
    $m = $models[$i]
    $sizeStr = if ($m.SizeMB -ge 1024) { "{0:N1} GB" -f ($m.SizeMB / 1024) } else { "{0:N0} MB" -f $m.SizeMB }
    $tq3Tag = if ($m.IsTQ3) { "TQ3" } else { "GGUF" }
    Write-Host (" [{0}] {1}  {2}  {3}" -f ($i + 1), $m.Name, $sizeStr, $tq3Tag)
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
        $modelInput = Read-Host "モデルを選択 (1-$($models.Count))、または q で終了"
        if ($modelInput -eq 'q') { exit 0 }
        $selection = 0
        $valid = [int]::TryParse($modelInput, [ref]$selection)
    } while (-not $valid -or $selection -lt 1 -or $selection -gt $models.Count)
}

$selected = $models[$selection - 1]
$selectedModelSizeGB = [math]::Round($selected.SizeMB / 1024, 1)
$requiredEngine = Get-RequiredEngine -Model $selected
$selectedModelText = "$($selected.Name) $($selected.FullName)"
$isLikelyMoeModel = $selectedModelText -match "(?i)MOE|Mixtral|8X4B|4X7B|8x4B|4x7B|expert|DeepSeek|Laguna|Flash[-_ ]?Next"
$isDeepSeek = $selectedModelText -match "(?i)DeepSeek"
# qwen4exp (Qwen3.8-Flash-Next): huge PLE n-gram table marked TENSOR_READ_LAZY.
$isQwen4Exp = $selectedModelText -match "(?i)qwen4exp|Flash[-_ ]?Next|qwen3\.8[-_ ]?flash"

# Engine selection: explicit param wins; Prompt shows a menu; Auto uses
# Get-RequiredEngine (Laguna for Flash-Next, else Unsloth).
if ($EngineMode -eq "Unsloth" -or $EngineMode -eq "Laguna" -or $EngineMode -eq "Strata") {
    $requiredEngine = $EngineMode
}
elseif ($EngineMode -eq "Auto") {
    # keep Get-RequiredEngine result
}
elseif (-not $DryRun -and -not $isQuickLaunch -and $EngineMode -eq "Prompt") {
    $defaultEngineLabel = $requiredEngine
    $lagunaOk = Test-Path -LiteralPath $LagunaServerPath
    $unslothOk = Test-Path -LiteralPath $UnslothServerPath
    $strataOk = (Test-Path -LiteralPath $StrataExe) -and (Test-Path -LiteralPath $StrataConfig) -and (Test-Path -LiteralPath $StrataPython)
    Write-Host ""
    Write-Host "ランタイムエンジン (Enter = $defaultEngineLabel):" -ForegroundColor Green
    Write-Host " [1] Laguna hot-expert  — Flash-Next 最速 (実測 ~13.5 t/s @2k)  $(if ($lagunaOk) { 'OK' } else { 'MISSING' })" -ForegroundColor Cyan
    Write-Host " [2] Unsloth HIP        — 従来パス (lazy-mode / 一般 GGUF / MTP 試験)  $(if ($unslothOk) { 'OK' } else { 'MISSING' })" -ForegroundColor Cyan
    Write-Host " [3] Strata 0.1.40.3    — Windows HIP ネイティブ (win-hip-0131 / serve 独自API)  $(if ($strataOk) { 'OK' } else { 'MISSING' })" -ForegroundColor Cyan
    $engineDefaultNum = if ($requiredEngine -eq "Laguna") { 1 } else { 2 }
    $engineSelection = Read-MenuInt -Prompt "エンジンを選択 (1-3)、Enter=$engineDefaultNum" -Min 1 -Max 3 -Default $engineDefaultNum
    $requiredEngine = switch ($engineSelection) { 1 { "Laguna" } 2 { "Unsloth" } 3 { "Strata" } }
}

$ServerPath = Resolve-EnginePaths -Engine $requiredEngine

$modelNote = Get-ModelNote -Model $selected

if ($PresetMode -eq "Prompt") {
    Write-Host ""
    Write-Host "ランタイムエンジン: $requiredEngine" -ForegroundColor Green
    Write-Host "エンジンパス    : $ServerPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "ワークフロープリセット:" -ForegroundColor Green
    Write-Host " [1] Manual - 全設定を手動選択"
    Write-Host " [2] Code - Cline 向けの安定設定"
    Write-Host " [3] Code - OpenCode 向けの安定設定"
    Write-Host " [4] Agent Research - llama-agent と反復Web証拠収集"
    Write-Host " [5] Pi - pi.dev コーディングエージェント（ローカルLLM接続）"
    Write-Host " [6] DeepSeek Harness - エージェントハーネス（ローカルLLM接続・APIキー不要）"
    Write-Host " [7] ARTEX - AI自律ペネトレーションテストコンソール（ローカルLLM接続）"
    Write-Host ""

    $presetSelection = Read-MenuInt -Prompt "プリセットを選択 (1-7)、または Enter で Manual" -Min 1 -Max 7 -Default 1

    $presetValues = @("Manual", "ClineCoding", "OpenCodeCoding", "LlamaAgentResearch", "PiCoding", "DeepSeekHarness", "ARTEX")
    $PresetMode = $presetValues[$presetSelection - 1]
}

$isQuickLaunch = $PresetMode -in @("PiCoding", "OpenCodeCoding")
if ($isQuickLaunch) {
    if ($KCacheIndex -eq 0) { $KCacheIndex = 1 }
    if ($VCacheIndex -eq 0) {
        if ($selectedModelSizeGB -ge 20) { $VCacheIndex = 4 }
        else { $VCacheIndex = 1 }
    }
}

if ($PresetMode -eq "ClineCoding") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "Cline" }
    if ($ContextIndex -eq 0) { $ContextIndex = 1 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "OpenCodeCoding") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "OpenCode" }
    if ($ContextIndex -eq 0) { $ContextIndex = 1 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "LlamaAgentResearch") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "LlamaAgent" }
    if ($ContextIndex -eq 0) { $ContextIndex = 1 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "PiCoding") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "Pi" }
    if ($ContextIndex -eq 0) { $ContextIndex = 1 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "DeepSeekHarness") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "DeepSeekHarness" }
    if ($ContextIndex -eq 0) { $ContextIndex = 1 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}
elseif ($PresetMode -eq "ARTEX") {
    if ($ClientMode -eq "Prompt") { $ClientMode = "ARTEX" }
    if ($ContextIndex -eq 0) { $ContextIndex = 1 }
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
}

# ---- Strata engine: it is served from a strata-*.json config in the Strata
# ---- checkout, so the llama.cpp model/vision/context/KV menus below do not
# ---- apply. Each config binds one GGUF pair (its --native); the config whose
# ---- bound model matches the selection is picked, and the context comes from
# ---- that config's --max-context (Strata mmaps its experts, so the pinned-RAM
# ---- ceiling the llama.cpp flow computes does not apply).
if ($requiredEngine -eq "Strata") {
    $strataCfgs = Get-ChildItem -LiteralPath $StrataRoot -Filter "strata-*.json" -File -ErrorAction SilentlyContinue
    if (-not $strataCfgs) {
        Write-Host "ERROR: no strata-*.json config found in $StrataRoot" -ForegroundColor Red
        exit 1
    }
    $StrataConfig = $null
    $strataNativeName = ""
    foreach ($sc in $strataCfgs) {
        try { $cfg = Get-Content -LiteralPath $sc.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $nativeIdx = [array]::IndexOf(@($cfg.args), "--native")
        if ($nativeIdx -lt 0) { continue }
        $nativeName = [IO.Path]::GetFileName([string]$cfg.args[$nativeIdx + 1])
        $modelKey = $nativeName -replace "-0000[0-9]-of-0000[0-9]\.gguf$", ""
        if ($modelKey -and "$($selected.Name)" -match [regex]::Escape($modelKey)) {
            $StrataConfig = $sc.FullName
            $strataNativeName = $nativeName
            $strataMaxCtx = 32768
            $ctxArgIdx = [array]::IndexOf(@($cfg.args), "--max-context")
            if ($ctxArgIdx -ge 0) { $null = [int]::TryParse([string]$cfg.args[$ctxArgIdx + 1], [ref]$strataMaxCtx) }
            break
        }
    }
    if (-not $StrataConfig) {
        Write-Host ""
        Write-Host "ERROR: no Strata config binds the selected model '$($selected.Name)'." -ForegroundColor Red
        Write-Host "Available Strata configs and the models they serve:" -ForegroundColor Yellow
        foreach ($sc in $strataCfgs) {
            try {
                $cfg = Get-Content -LiteralPath $sc.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $nativeIdx = [array]::IndexOf(@($cfg.args), "--native")
                if ($nativeIdx -ge 0) { Write-Host ("  {0}  ->  {1}" -f $sc.Name, [IO.Path]::GetFileName([string]$cfg.args[$nativeIdx + 1])) -ForegroundColor DarkGray }
            }
            catch { }
        }
        Write-Host "Pick one of those models, or add a pack + config (see C:\Users\dai86\Strata\STRATA-HANDOFF.md)." -ForegroundColor Yellow
        exit 1
    }
    # Context choice for Strata: the config's --max-context is the default.  A shorter context
    # frees VRAM for expert slots (same decode speed); 64K is experimental on 16 GB.  The override
    # lands in a runtime COPY of the config (_strata-runtime.json) so the shipped files stay untouched.
    Write-Host ""
    Write-Host "Context size (Enter = the config's $([int]($strataMaxCtx / 1024))K):" -ForegroundColor Cyan
    Write-Host " [1] 8K   [2] 16K   [3] 32K   [4] 64K (experimental) - config default: $([int]($strataMaxCtx / 1024))K" -ForegroundColor DarkGray
    # Both shipped configs sit on the ladder (32768/65536), so Enter maps back
    # to the config value and the $wantCtx -ne $strataMaxCtx check below keeps it.
    $ctxDefault = if ([int]$strataMaxCtx -eq 65536) { 4 } else { 3 }
    $ctxPick = Read-MenuInt -Prompt "コンテキストを選択 (1-4、Enter=維持)" -Min 1 -Max 4 -Default $ctxDefault
    $wantCtx = switch ($ctxPick) { 1 { 8192 } 2 { 16384 } 3 { 32768 } 4 { 65536 } }
    if ($wantCtx -and $wantCtx -ne $strataMaxCtx) {
        $rtCfgPath = Join-Path $StrataRoot "_strata-runtime.json"
        $cfgObj = Get-Content -LiteralPath $StrataConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $ci = [array]::IndexOf(@($cfgObj.args), "--max-context")
        if ($ci -ge 0) {
            $cfgObj.args[$ci + 1] = "$wantCtx"
            [IO.File]::WriteAllText($rtCfgPath, ($cfgObj | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            $StrataConfig = $rtCfgPath
            $strataMaxCtx = $wantCtx
            Write-Host "Runtime config written: $rtCfgPath (ctx $wantCtx)" -ForegroundColor DarkGray
        }
    }
    $selectedContext = [PSCustomObject]@{
        Label = "$([int]($strataMaxCtx / 1024))K"
        Tokens = $strataMaxCtx
        Note = "from $(Split-Path -Leaf $StrataConfig)"
    }
    $visionEnabled = $false
    # llama-server-only menus: take silent defaults, their flags never reach Strata
    if ($OffloadMode -eq "Prompt") { $OffloadMode = "Auto" }
    if ($MoeExpertsMode -eq "Prompt") { $MoeExpertsMode = "Auto" }
    if ($FlashAttentionMode -eq "Prompt") { $FlashAttentionMode = "On" }
    if ($SpecMode -eq "Prompt") { $SpecMode = "Off" }
    if ($McpMode -eq "Prompt") { $McpMode = "None" }
    if ($KCacheIndex -eq 0) { $KCacheIndex = 1 }
    if ($VCacheIndex -eq 0) { $VCacheIndex = 1 }
}

if (-not $isQuickLaunch) {
    Write-Host ""
    Write-HardwareSummary -Hardware $hardware
    Write-RuntimeAvailability -Runtimes $runtimeCandidates
    Write-Host "ランタイムエンジン: $requiredEngine" -ForegroundColor Green
    Write-Host "エンジンパス    : $ServerPath" -ForegroundColor DarkGray
}

if ($modelNote -and -not $isQuickLaunch -and $requiredEngine -ne "Strata") {
    Write-Host ""
    Write-Host "モデルメモ: $($modelNote.note)" -ForegroundColor Cyan
    if ($modelNote.recommended_preset) {
        Write-Host "推奨プリセット: $($modelNote.recommended_preset)" -ForegroundColor Cyan
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
    $launchLabel = if ($PresetMode -eq "PiCoding") { "Coding -> Pi (pi.dev)" } elseif ($PresetMode -eq "OpenCodeCoding") { "Coding -> OpenCode" } else { "Manual" }
}
else {
    Write-Host "選択中: $($selected.Name)" -ForegroundColor Green
    Write-Host "エンジン: $requiredEngine" -ForegroundColor Green
    Write-Host "プリセット: $PresetMode" -ForegroundColor Green
}
Write-Host ""

if (-not (Test-Path $ServerPath)) {
    Write-Host "エラー: $requiredEngine の llama-server が見つかりません:" -ForegroundColor Red
    Write-Host $ServerPath -ForegroundColor Red
    if ($requiredEngine -eq "Laguna") {
        Write-Host "Laguna: build-stage1 に llama-server.exe を置くか、LLAMADOCK_LAGUNA_SERVER を設定してください。" -ForegroundColor Yellow
        Write-Host "  例: build-stage1\bin\llama-server.exe (Unsloth の stub + Laguna llama-server-impl.dll でも可)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "Unsloth Desktop をインストールするか、LLAMADOCK_UNSLOTH_SERVER に llama-server.exe のパスを設定してください。" -ForegroundColor Yellow
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
        Write-Host "ビジョン: 有効 (LLAMADOCK_VISION=on, $($visionMmprojPath.Name) $mmprojSizeGB GB)" -ForegroundColor Green
    }
    elseif ($envVision -eq "off") {
        Write-Host "ビジョン: 無効 (アダプタ検出済み、LLAMADOCK_VISION=off で無効化)" -ForegroundColor DarkGray
    }
    elseif ($requiredEngine -eq "Strata") {
        Write-Host "ビジョン: 無効 (Strata 設定はテキスト専用。--mmproj は llama-server のフラグ)" -ForegroundColor DarkGray
    }
    elseif (-not $DryRun -and -not $isQuickLaunch) {
        Write-Host ""
        Write-Host "ビジョンアダプタ検出: $($visionMmprojPath.Name) ($mmprojSizeGB GB)" -ForegroundColor Green
        Write-Host " [1] テキストのみ (既定 - VRAM をコンテキストに回す)"
        Write-Host " [2] 画像入力を有効化 (--mmproj、追加 VRAM を使用)"
        $visionSelection = Read-MenuInt -Prompt "ビジョンを有効にしますか? (1-2)、または Enter で 1" -Min 1 -Max 2 -Default 1
        $visionEnabled = ($visionSelection -eq 2)
    }
}
elseif ($envVision -eq "on") {
    # LLAMADOCK_VISION=on was requested but this model ships no adapter next
    # to it — say so instead of silently continuing text-only.
    Write-Host "ビジョン: LLAMADOCK_VISION=on を指定しましたが、'$($selected.Name)' の隣に mmproj*.gguf が見つかりません — テキストのみで続行します。" -ForegroundColor Yellow
}

# Prompt context size selection
$systemRamGB = $hardware.RamGB
$primaryVramGB = if ($hardware.PrimaryGpu) { [double]$hardware.PrimaryGpu.VramGB } else { 0 }
$maxContextTokensForRam = Get-MaxContextTokensForRam -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB
$autoContextTokens = Resolve-AutoContextTokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB -DeepSeek:$isDeepSeek -LagunaHotExpert:$script:LagunaHotExpert

$contextOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Tokens = -1; Note = "RAM ceiling +64K cap から自動選択 (溢れはゲートウェイが自動間引き)" },
    [PSCustomObject]@{ Label = "8K"; Tokens = 8192; Note = "最小メモリ、起動テスト向け" },
    [PSCustomObject]@{ Label = "16K"; Tokens = 16384; Note = "大型モデルの安全な既定値" },
    [PSCustomObject]@{ Label = "32K"; Tokens = 32768; Note = "コーディングの既定値" },
    [PSCustomObject]@{ Label = "64K"; Tokens = 65536; Note = "長文コンテキスト、RAM を確認" },
    [PSCustomObject]@{ Label = "128K"; Tokens = 131072; Note = "超長文、RAM/KV が重い" },
    [PSCustomObject]@{ Label = "256K"; Tokens = 262144; Note = "極端、RAM/KV は非常に重い" },
    [PSCustomObject]@{ Label = "カスタム"; Tokens = 0; Note = "トークン数を手動入力" }
)

if (-not $isQuickLaunch -and $requiredEngine -ne "Strata") {
    Write-Host "コンテキストサイズ:" -ForegroundColor Green
    if ($systemRamGB -gt 0) {
        Write-Host ("検出 RAM: {0}GB / 選択モデル: {1:N1}GB" -f $systemRamGB, $selectedModelSizeGB) -ForegroundColor DarkGray
        Write-Host ("このモデル/RAM の推奨上限: {0} tokens" -f $maxContextTokensForRam) -ForegroundColor DarkGray
    }
    for ($i = 0; $i -lt $contextOptions.Count; $i++) {
        $ctx = $contextOptions[$i]
        if ($ctx.Tokens -eq -1) {
            $autoRisk = Get-ContextRiskLabel -Tokens $autoContextTokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB
            Write-Host " [$($i+1)] $($ctx.Label) (現在の構成では $($autoContextTokens) tokens) - $($ctx.Note); $autoRisk [推奨]"
        }
        elseif ($ctx.Tokens -gt 0) {
            $risk = Get-ContextRiskLabel -Tokens $ctx.Tokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB
            Write-Host " [$($i+1)] $($ctx.Label) ($($ctx.Tokens) tokens) - $($ctx.Note); $risk"
        }
        else {
            Write-Host " [$($i+1)] $($ctx.Label) - $($ctx.Note)"
        }
    }
    Write-Host ""
}
elseif ($requiredEngine -eq "Strata" -and -not $isQuickLaunch) {
    Write-Host "コンテキストサイズ:" -ForegroundColor Green
    Write-Host (" {0} ({1} tokens) - $(Split-Path -Leaf $StrataConfig) 由来 (Strata は experts を mmap するため llama.cpp の RAM ラダーは適用外)" -f $selectedContext.Label, $selectedContext.Tokens) -ForegroundColor DarkGray
    Write-Host ""
}

if ($requiredEngine -ne "Strata" -and $ContextIndex -gt 0) {
    $ctxSelection = $ContextIndex
    if ($ctxSelection -lt 1 -or $ctxSelection -gt $contextOptions.Count) {
        Write-Host "ERROR: ContextIndex out of range" -ForegroundColor Red
        exit 1
    }
}
elseif ($requiredEngine -ne "Strata") {
    $ctxSelection = Read-MenuInt -Prompt "コンテキストサイズを選択 (1-$($contextOptions.Count))、または Enter で Auto" -Min 1 -Max $contextOptions.Count -Default 1
}

if ($requiredEngine -ne "Strata") {
    $selectedContext = $contextOptions[$ctxSelection - 1]
    if ($selectedContext.Tokens -eq -1) {
        $selectedContext = [PSCustomObject]@{
            Label = "Auto"
            Tokens = $autoContextTokens
            Note = "auto (RAM ceiling + 64K cap)"
        }
    }
}
if ($requiredEngine -ne "Strata" -and $selectedContext.Tokens -eq 0) {
    $customContextTokens = Read-MenuInt -Prompt "コンテキストトークン数を入力 (例: 32768, 65536, 131072)" -Min 512 -Max $maxContextTokensForRam -InvalidMessage "エラー: 512〜$maxContextTokensForRam tokens の整数を入力してください (モデルの RAM 安全上限)。小さい値か、小さいモデルを選んでください。"

    $selectedContext = [PSCustomObject]@{
        Label = "$customContextTokens"
        Tokens = $customContextTokens
        Note = "custom"
    }
}
if (-not $isQuickLaunch) {
    Write-Host ""
    Write-Host "コンテキスト: $($selectedContext.Label) ($($selectedContext.Tokens) tokens)" -ForegroundColor Green
    if ($systemRamGB -gt 0 -and $requiredEngine -ne "Strata") {
        Write-Host "コンテキストリスク: $(Get-ContextRiskLabel -Tokens $selectedContext.Tokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB)" -ForegroundColor Yellow
    }
}
if ($requiredEngine -ne "Strata" -and ($selectedContext.Tokens -gt $maxContextTokensForRam -or -not (Test-ContextFitsRam -Tokens $selectedContext.Tokens -ModelSizeGB $selectedModelSizeGB -RamGB $systemRamGB))) {
    Write-Host "エラー: 選択したコンテキストはこのモデルでは RAM を超過する可能性があります。" -ForegroundColor Red
    Write-Host "選択: $($selectedContext.Tokens) tokens; 上限: $maxContextTokensForRam tokens." -ForegroundColor Red
    Write-Host "小さいコンテキストか、小さい/軽いモデルを使ってください。" -ForegroundColor Red
    exit 1
}
if (-not $isQuickLaunch) { Write-Host "" }

# Prompt KV cache quantization selection
$kvOptions = @(
    [PSCustomObject]@{ Label = "Q8"; Type = "q8_0"; Note = "大きいが安定、K の既定" },
    [PSCustomObject]@{ Label = "Q5_1"; Type = "q5_1"; Note = "K で使える中間、Q4 より安全" },
    [PSCustomObject]@{ Label = "Q5_0"; Type = "q5_0"; Note = "使える中間のコンパクト設定" },
    [PSCustomObject]@{ Label = "Q4"; Type = "q4_0"; Note = "コンパクト、K は画質リスク大" },
    [PSCustomObject]@{ Label = "f16"; Type = "f16"; Note = "非圧縮、互換フォールバック" },
    [PSCustomObject]@{ Label = "bf16"; Type = "bf16"; Note = "非圧縮フォールバック、f32 より省メモリ" }
)

# Unsloth mainline build supports standard cache types only (no turbo KV).
# No engine-specific probe needed.

if (-not $isQuickLaunch) {
    Write-Host "KV キャッシュ K 型:" -ForegroundColor Green
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
    $defaultKType = "q8_0"
    $defaultKLabel = $defaultKType
    $defaultKIndex = [array]::IndexOf(@($kvOptions | Select-Object -ExpandProperty Type), $defaultKType) + 1
    if ($defaultKIndex -le 0) { $defaultKIndex = 1 }
    $kSelection = Read-MenuInt -Prompt "K キャッシュ型を選択 (1-$($kvOptions.Count))、または Enter で $defaultKLabel" -Min 1 -Max $kvOptions.Count -Default $defaultKIndex
}

$selectedKCache = $kvOptions[$kSelection - 1]
if (-not $isQuickLaunch) {
    Write-Host ""
    Write-Host "KV キャッシュ K: $($selectedKCache.Label) ($($selectedKCache.Type))" -ForegroundColor Green
    Write-Host ""
}

if (-not $isQuickLaunch) {
    Write-Host "KV キャッシュ V 型:" -ForegroundColor Green
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
        Write-Host "KV キャッシュ V: $($selectedVCache.Label) ($($selectedVCache.Type)) (対称 — DeepSeek は K==V を要求)" -ForegroundColor Green
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
        $defaultVLabel = $defaultVType
        $defaultVIndex = [array]::IndexOf(@($kvOptions | Select-Object -ExpandProperty Type), $defaultVType) + 1
        if ($defaultVIndex -le 0) { $defaultVIndex = 1 }
        $vSelection = Read-MenuInt -Prompt "V キャッシュ型を選択 (1-$($kvOptions.Count))、または Enter で $defaultVLabel" -Min 1 -Max $kvOptions.Count -Default $defaultVIndex
    }

    $selectedVCache = $kvOptions[$vSelection - 1]
    if (-not $isQuickLaunch) {
        Write-Host ""
        Write-Host "KV キャッシュ V: $($selectedVCache.Label) ($($selectedVCache.Type))" -ForegroundColor Green
        Write-Host ""
    }
}

if ($ClientMode -eq "Prompt") {
    Write-Host "ワークスペース:" -ForegroundColor Green
    Write-Host " [1] Cline - コーディングエージェント"
    Write-Host " [2] OpenCode - ターミナルコーディングエージェント"
    Write-Host " [3] Pi - pi.dev コーディングエージェント"
    Write-Host " [4] Llama Agent - ターミナルエージェントと詳細Web証拠収集"
    Write-Host " [5] ComfyUI - MiniMax H3 動画・音声生成"
    Write-Host " [6] DeepSeek Harness - エージェントハーネス（ローカルLLM接続）"
    Write-Host " [7] ARTEX - AI自律ペネトレーションテストコンソール"
    Write-Host ""

    $clientSelection = Read-MenuInt -Prompt "ワークスペースを選択 (1-7)、または Enter で Cline" -Min 1 -Max 7 -Default 1

    if ($clientSelection -eq 1) { $ClientMode = "Cline" }
    elseif ($clientSelection -eq 2) { $ClientMode = "OpenCode" }
    elseif ($clientSelection -eq 3) { $ClientMode = "Pi" }
    elseif ($clientSelection -eq 4) { $ClientMode = "LlamaAgent" }
    elseif ($clientSelection -eq 5) { $ClientMode = "ComfyUI" }
    elseif ($clientSelection -eq 6) { $ClientMode = "DeepSeekHarness" }
    else { $ClientMode = "ARTEX" }
}

if (-not $isQuickLaunch) {
    Write-Host "ワークスペース: $ClientMode" -ForegroundColor Green
    Write-Host ""
}

$offloadOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Value = "auto"; Note = "llama.cpp が GPU レイヤー数を決定" },
    [PSCustomObject]@{ Label = "All"; Value = "all"; Note = "全レイヤーのオフロードを試行" },
    [PSCustomObject]@{ Label = "CPU"; Value = "0"; Note = "CPU のみ" },
    [PSCustomObject]@{ Label = "カスタム"; Value = "custom"; Note = "レイヤー数を入力" }
)

if ($OffloadMode -eq "Prompt") {
    Write-Host "GPU オフロード:" -ForegroundColor Green
    for ($i = 0; $i -lt $offloadOptions.Count; $i++) {
        $offload = $offloadOptions[$i]
        Write-Host " [$($i+1)] $($offload.Label) - $($offload.Note)"
    }
    Write-Host ""

    $offloadSelection = Read-MenuInt -Prompt "GPU オフロードを選択 (1-$($offloadOptions.Count))、または Enter で Auto" -Min 1 -Max $offloadOptions.Count -Default 1

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
        $offloadLayersValue = Read-MenuInt -Prompt "GPU レイヤー数を入力" -Min 0 -Max 2147483647
        $selectedOffload = [string]$offloadLayersValue
    }
    else {
        $selectedOffload = $OffloadLayers
    }
}

$serverOffload = if ($selectedOffload -eq "auto") { "auto" } elseif ($selectedOffload -eq "all") { "all" } else { $selectedOffload }
if ($NglLayers -gt 0) {
    $serverOffload = [string]$NglLayers
    Write-Host "GPU レイヤー上書き: -ngl $NglLayers (-NglLayers)" -ForegroundColor Yellow
}
if (-not $isQuickLaunch) {
    Write-Host "GPU オフロード: $selectedOffload" -ForegroundColor Green
    Write-Host "GPU オフロード見積り: $(Get-VramRiskLabel -ModelSizeGB $selectedModelSizeGB -VramGB $primaryVramGB -OffloadMode $selectedOffload)" -ForegroundColor Yellow
    Write-Host "llama-server へ渡す GPU レイヤー: $serverOffload" -ForegroundColor Yellow
    Write-Host ""
}
$moeExpertOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Value = "Auto"; Note = "モデル既定、最安全" },
    [PSCustomObject]@{ Label = "2"; Value = "2"; Note = "よく使われる高速 MoE 設定" },
    [PSCustomObject]@{ Label = "3"; Value = "3"; Note = "バランス型の手動設定" },
    [PSCustomObject]@{ Label = "4"; Value = "4"; Note = "重い品質テスト" },
    [PSCustomObject]@{ Label = "6"; Value = "6"; Note = "8-expert モデルのみ、重い" },
    [PSCustomObject]@{ Label = "8"; Value = "8"; Note = "8-expert モデルのみ、非常に重い" },
    [PSCustomObject]@{ Label = "カスタム"; Value = "Custom"; Note = "エキスパート数を入力" }
)

if ($MoeExpertsMode -eq "Prompt") {
    Write-Host "MoE エキスパート数:" -ForegroundColor Green
    for ($i = 0; $i -lt $moeExpertOptions.Count; $i++) {
        $moe = $moeExpertOptions[$i]
        Write-Host " [$($i+1)] $($moe.Label) - $($moe.Note)"
    }
    Write-Host ""

    $moeSelection = Read-MenuInt -Prompt "MoE エキスパート数を選択 (1-$($moeExpertOptions.Count))、または Enter で Auto" -Min 1 -Max $moeExpertOptions.Count -Default 1

    $MoeExpertsMode = $moeExpertOptions[$moeSelection - 1].Value
}

$selectedMoeExperts = ""
if ($MoeExpertsMode -eq "Custom") {
    if ([string]::IsNullOrWhiteSpace($MoeExpertsCount)) {
        $moeCustomValue = Read-MenuInt -Prompt "MoE エキスパート数を入力" -Min 1 -Max 2147483647
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
        Write-Host "MoE エキスパート数: Auto" -ForegroundColor Green
    }
    else {
        Write-Host "MoE エキスパート数: $selectedMoeExperts" -ForegroundColor Green
        Write-Host "警告: 手動の MoE エキスパート数は、この数をサポートする MoE モデルでのみ使用してください。" -ForegroundColor Yellow
    }
    Write-Host ""
}

# --- CPU MoE Layers (--n-cpu-moe) ---
$selectedCpuMoe = ""
$cpuMoeOptions = @(
    [PSCustomObject]@{ Label = "Auto"; Value = "Auto"; Note = "モデルサイズと VRAM から自動計算" },
    [PSCustomObject]@{ Label = "オフ (0)"; Value = "0"; Note = "MoE 重みを全て GPU に" },
    [PSCustomObject]@{ Label = "軽 (10)"; Value = "10"; Note = "先頭 10 レイヤーの MoE を CPU に" },
    [PSCustomObject]@{ Label = "中 (20)"; Value = "20"; Note = "先頭 20 レイヤーの MoE を CPU に" },
    [PSCustomObject]@{ Label = "重 (44)"; Value = "44"; Note = "AJ の 3060 設定" },
    [PSCustomObject]@{ Label = "全て (99)"; Value = "99"; Note = "MoE 重みを全て CPU に" },
    [PSCustomObject]@{ Label = "カスタム"; Value = "Custom"; Note = "レイヤー数を入力" }
)

if ($isLikelyMoeModel -and -not $isQuickLaunch -and [string]::IsNullOrWhiteSpace($CpuMoeMode) -and $requiredEngine -ne "Strata") {
    Write-Host "CPU MoE レイヤー (--n-cpu-moe):" -ForegroundColor Green
    for ($i = 0; $i -lt $cpuMoeOptions.Count; $i++) {
        $opt = $cpuMoeOptions[$i]
        Write-Host " [$($i+1)] $($opt.Label) - $($opt.Note)"
    }
    Write-Host ""

    # qwen4exp (Qwen3.8-Flash-Next) measured best at 44 (4 of 48 expert
    # layers on GPU); deeper GPU offload loses to CPU/DDR4 on this box.
    # Kept as reference; the model itself no longer switches engines.
    $defaultCpuMoeLabel = if ($isDeepSeek) { "全て (99)" } else { "Auto" }
    $defaultCpuMoeIndex = if ($isDeepSeek) { 6 } else { 1 }
    $cpuMoeSelection = Read-MenuInt -Prompt "CPU MoE レイヤーを選択 (1-$($cpuMoeOptions.Count))、または Enter で $defaultCpuMoeLabel" -Min 1 -Max $cpuMoeOptions.Count -Default $defaultCpuMoeIndex

    $cpuMoeMode = $cpuMoeOptions[$cpuMoeSelection - 1].Value
}
elseif ($isLikelyMoeModel) {
    # Quick launch / -CpuMoeMode override: no interactive picker.
    $cpuMoeMode = if ([string]::IsNullOrWhiteSpace($CpuMoeMode)) { "Auto" } else { $CpuMoeMode }
}

# Auto-calculate CPU MoE layers
if ($script:LagunaHotExpert -and $isQwen4Exp) {
    # hot-expert owns expert placement (RAM + VRAM hot bank). Do not also
    # emit --n-cpu-moe / --cpu-moe — those fight the FreeToken-style layout.
    $selectedCpuMoe = "0"
    if (-not $isQuickLaunch) {
        Write-Host "CPU MoE レイヤー: オフ — Laguna --moe-hot-expert が配置を担当" -ForegroundColor Green
    }
}
elseif ($cpuMoeMode -eq "Auto") {
    # Prefer the VRAM detected at startup (nvidia-smi / Win32_VideoController);
    # fall back to engine-based estimates only when detection failed.
    $detectedVramGB = if ($hardware.PrimaryGpu -and $hardware.PrimaryGpu.VramGB -gt 0) { [double]$hardware.PrimaryGpu.VramGB } else { 0 }
    if ($detectedVramGB -gt 0) {
        # Reserve headroom for KV cache, compute buffers and the OS compositor.
        $vramGB = [math]::Max(4, [math]::Floor($detectedVramGB - 1.5))
    }
    elseif ($env:HIP_PATH) {
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
                Write-Host "CPU MoE レイヤー: Auto (99) — DeepSeek 最速設定は全 experts を CPU に固定" -ForegroundColor Yellow
            }
        }
        elseif ($isQwen4Exp -and -not $script:LagunaHotExpert) {
            # Size is dominated by the 51B PLE n-gram table (lazy disk), not MoE
            # experts. Ratio-based auto produced ~39 and measured 3.2 t/s on
            # RX 7800 XT; 4 layers CPU-MoE measured 5.3 t/s (2026-09-15).
            # Laguna hot-expert is handled above and never reaches this branch.
            $selectedCpuMoe = "4"
            if (-not $isQuickLaunch) {
                Write-Host "CPU MoE レイヤー: Auto (4) — Unsloth Flash-Next 経路 (PLE はディスク lazy)" -ForegroundColor Yellow
            }
        }
        else {
            $ratio = ($modelSizeGB - $vramGB) / $modelSizeGB
            $selectedCpuMoe = [math]::Min(99, [math]::Max(1, [math]::Ceiling($ratio * 48)))
            if (-not $isQuickLaunch) {
                Write-Host "CPU MoE レイヤー: Auto ($selectedCpuMoe) — モデル ${modelSizeGB}GB > VRAM ${vramGB}GB" -ForegroundColor Yellow
            }
        }
    }
    else {
        $selectedCpuMoe = "0"
        if (-not $isQuickLaunch) {
            Write-Host "CPU MoE レイヤー: 0 (モデル ${modelSizeGB}GB は VRAM ${vramGB}GB に収まる)" -ForegroundColor Green
        }
    }
}
elseif ($cpuMoeMode -eq "Custom") {
    $customValue = Read-MenuInt -Prompt "CPU MoE レイヤー数を入力" -Min 0 -Max 2147483647
    $selectedCpuMoe = [string]$customValue
}
else {
    $selectedCpuMoe = $cpuMoeMode
}

if (-not $isQuickLaunch -and $selectedCpuMoe -ne "0") {
    Write-Host "CPU MoE レイヤー: $selectedCpuMoe" -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($ChatTemplateKwargs) -and -not $DryRun -and -not $isQuickLaunch -and $requiredEngine -ne "Strata") {
    $kwargsDefaultLabel = "none"
    $kwargsInput = Read-Host "chat-template-kwargs JSON、または Enter で $kwargsDefaultLabel"
    if (-not [string]::IsNullOrWhiteSpace($kwargsInput)) {
        $ChatTemplateKwargs = $kwargsInput
    }
}

# Reasoning / thinking control (all models). Uses the native llama.cpp flags
# --reasoning, --reasoning-effort and --reasoning-budget (no JSON kwargs).
$effectiveReasoningMode = ""
$effectiveReasoningEffort = ""
$effectiveReasoningBudget = 0
$selectedReasoningValue = ""
$selectedReasoningBudget = 0

$reasoningOptions = @(
    [PSCustomObject]@{ Label = "Off    - 思考なし (最速、ツール呼び出しに最適)"; Value = "off" },
    [PSCustomObject]@{ Label = "Low    - 軽い思考 (--reasoning-effort low)"; Value = "low" },
    [PSCustomObject]@{ Label = "Medium - 中程度の思考 (--reasoning-effort medium)"; Value = "medium" },
    [PSCustomObject]@{ Label = "High   - 深い思考 (--reasoning-effort high)"; Value = "high" },
    [PSCustomObject]@{ Label = "Budget - 思考トークンを上限指定 (--reasoning-budget N)"; Value = "budget" },
    [PSCustomObject]@{ Label = "On     - 制限なしの思考"; Value = "on" }
)

if (-not [string]::IsNullOrWhiteSpace($ReasoningMode)) {
    # Non-interactive: -ReasoningMode (and optional -ReasoningBudget) supplied.
    $selectedReasoningValue = $ReasoningMode.Trim().ToLower()
    $selectedReasoningBudget = $ReasoningBudget
}
elseif (-not $DryRun -and -not $isQuickLaunch -and $requiredEngine -ne "Strata") {
    Write-Host "推論 (thinking) モード:" -ForegroundColor Green
    for ($i = 0; $i -lt $reasoningOptions.Count; $i++) {
        Write-Host " [$($i+1)] $($reasoningOptions[$i].Label)"
    }
    Write-Host ""
    # Coding clients default to thinking off: the Cline CLI already forces
    # --thinking none and agentic tool loops only slow down when the model
    # spends tokens reasoning first. Pick any other option to override.
    $defaultReasoning = if ($script:LagunaHotExpert -and $isQwen4Exp) { "off" }
    elseif ($ClientMode -in @("Cline", "OpenCode")) { "off" }
    else { "low" }
    $defaultReasoningIndex = [array]::IndexOf(@($reasoningOptions.Value), $defaultReasoning) + 1
    $reasoningSelection = Read-MenuInt -Prompt "推論モードを選択 (1-$($reasoningOptions.Count))、または Enter で $defaultReasoning" -Min 1 -Max $reasoningOptions.Count -Default $defaultReasoningIndex

    $selectedReasoningValue = $reasoningOptions[$reasoningSelection - 1].Value
    if ($selectedReasoningValue -eq "budget") {
        $selectedReasoningBudget = Read-MenuInt -Prompt "思考トークン上限、または Enter で 2048" -Min 1 -Max 2147483647 -Default 2048
    }
}

# Map the selected reasoning mode to the native llama.cpp flags.
if (-not [string]::IsNullOrWhiteSpace($selectedReasoningValue)) {
    switch ($selectedReasoningValue) {
        "off"    { $effectiveReasoningMode = "off" }
        "on"     { $effectiveReasoningMode = "on" }
        "low"    { $effectiveReasoningMode = "on"; $effectiveReasoningEffort = "low" }
        "medium" { $effectiveReasoningMode = "on"; $effectiveReasoningEffort = "medium" }
        "high"   { $effectiveReasoningMode = "on"; $effectiveReasoningEffort = "high" }
        "budget" {
            $effectiveReasoningMode = "on"
            if ($selectedReasoningBudget -gt 0) { $effectiveReasoningBudget = $selectedReasoningBudget } else { $effectiveReasoningBudget = 2048 }
        }
        default  { Write-Host "警告: 不明な推論モード '$selectedReasoningValue' は無視します。" -ForegroundColor Yellow }
    }
    # Laguna engine reply (2026-09-18): --reasoning-effort works on the new
    # stage1 server build; chat-template-kwargs may be used alongside.
    # Only strip effort when the live binary's --help lacks the flag.
    if ($script:LagunaHotExpert) {
        $engineHelpReasoning = ""
        try {
            if (Test-Path -LiteralPath $ServerPath) {
                $engineHelpReasoning = (& $ServerPath --help 2>&1 | Out-String)
            }
        }
        catch { $engineHelpReasoning = "" }
        if ($effectiveReasoningEffort -and $engineHelpReasoning -and $engineHelpReasoning -notmatch "reasoning-effort") {
            $effectiveReasoningEffort = ""
        }
    }
    if ($effectiveReasoningMode) {
        $reasoningSummary = "--reasoning $effectiveReasoningMode"
        if ($effectiveReasoningEffort) { $reasoningSummary += " --reasoning-effort $effectiveReasoningEffort" }
        if ($effectiveReasoningBudget -gt 0) { $reasoningSummary += " --reasoning-budget $effectiveReasoningBudget" }
        Write-Host "推論モード: $selectedReasoningValue ($reasoningSummary)" -ForegroundColor Green
        Write-Host ""
    }
}

# Advanced（詳細設定）gate. Rarely-touched knobs (sampler preset, prompt-cache
# reuse, process priority, ubatch) are collapsed behind one prompt and default
# to the researched optimal values; entering the gate reveals the per-option
# menus below. Everything is still reachable manually.
$advancedSettingsMenu = $false
if (-not $DryRun -and -not $isQuickLaunch -and $requiredEngine -ne "Strata") {
    Write-Host "詳細設定:" -ForegroundColor Green
    Write-Host " [Enter] 最適設定のまま（推奨）"
    Write-Host " [1] 詳細設定を変更する"
    Write-Host ""
    $advancedInput = Read-Host "詳細設定を変更しますか? (Enter = 最適設定のまま, 1 = 変更)"
    if ($advancedInput.Trim() -eq "1") {
        $advancedSettingsMenu = $true
    }
    Write-Host ""
}

# Sampler / output-quality preset. Server-side defaults (clients may still
# override per request). Presets bundle native llama.cpp sampler flags;
# individual params (-Temperature/-TopK/-TopP/-MinP/-RepeatPenalty/
# -RepeatLastN) take precedence. Research 2026-08-29 (Qwen3.6-35B-A3B
# model card + llama.cpp issues): coding works best at temp 0.6 / top-k 20
# / top-p 0.95 / min-p 0.05; a 512-token repeat window covers phrase loops
# that 256 misses.
$samplerPresetOptions = @()
if ($isQwen4Exp) {
    # Unsloth Qwen3.8-Flash-Next recommended settings
    # https://unsloth.ai/docs/models/qwen3.8-next — hybrid thinking model.
    $samplerPresetOptions += [PSCustomObject]@{
        Label = "Flash-Next THINK (Unsloth) - temp 1.0 / top-p 0.95 / top-k 20 / min-p 0 / presence 0 / rep 1.0"
        Value = "flash-next-think"
    }
    $samplerPresetOptions += [PSCustomObject]@{
        Label = "Flash-Next INSTRUCT (Unsloth) - temp 0.7 / top-p 0.80 / top-k 20 / min-p 0 / presence 1.5 / rep 1.0"
        Value = "flash-next-instruct"
    }
}
$samplerPresetOptions += @(
    [PSCustomObject]@{ Label = "Qwen 推奨（コード向け）- temp 0.6 / top-k 20 / top-p 0.95 / min-p 0.05 + repeat 1.1 (window 512)"; Value = "qwen-code" },
    [PSCustomObject]@{ Label = "チャット向け - temp 0.8 / top-p 0.95 / min-p 0.05 + repeat 1.1 (window 512)"; Value = "chat" },
    [PSCustomObject]@{ Label = "繰り返し対策のみ - repeat 1.1 (window 512)"; Value = "repeat-only" },
    [PSCustomObject]@{ Label = "Off（llama.cpp デフォルト）"; Value = "off" }
)

# Flash-Next hybrid-thinking default (Unsloth): thinking ON → think sampler;
# thinking OFF → instruct sampler (presence_penalty 1.5). qwen-code is for
# older Qwen coding cards, not Flash-Next.
$flashNextThinking = $isQwen4Exp -and $effectiveReasoningMode -and $effectiveReasoningMode -ne "off"

$effectiveSamplerPreset = ""
if (-not [string]::IsNullOrWhiteSpace($SamplerPreset)) {
    $effectiveSamplerPreset = $SamplerPreset.Trim().ToLower()
}
elseif ($isQwen4Exp -and -not $advancedSettingsMenu) {
    $effectiveSamplerPreset = if ($flashNextThinking) { "flash-next-think" } else { "flash-next-instruct" }
}
elseif (-not $DryRun -and $advancedSettingsMenu) {
    Write-Host "サンプラー (出力調整) プリセット:" -ForegroundColor Green
    for ($i = 0; $i -lt $samplerPresetOptions.Count; $i++) {
        Write-Host " [$($i+1)] $($samplerPresetOptions[$i].Label)"
    }
    Write-Host ""
    $defaultSampler = if ($isQwen4Exp) { $(if ($flashNextThinking) { "flash-next-think" } else { "flash-next-instruct" }) } else { "qwen-code" }
    $defaultSamplerIndex = 1
    for ($i = 0; $i -lt $samplerPresetOptions.Count; $i++) {
        if ($samplerPresetOptions[$i].Value -eq $defaultSampler) { $defaultSamplerIndex = $i + 1; break }
    }
    $samplerSelection = Read-MenuInt -Prompt "サンプラープリセットを選択 (1-$($samplerPresetOptions.Count))、または Enter で $defaultSampler" -Min 1 -Max $samplerPresetOptions.Count -Default $defaultSamplerIndex
    $effectiveSamplerPreset = $samplerPresetOptions[$samplerSelection - 1].Value
}
elseif (-not $DryRun) {
    # Quick launch: default to the recommended preset.
    $effectiveSamplerPreset = if ($isQwen4Exp) { $(if ($flashNextThinking) { "flash-next-think" } else { "flash-next-instruct" }) } else { "qwen-code" }
}

# Resolve effective sampler values (preset values, overridden by explicit params).
# min-p: $null = omit flag; numeric (including 0.0) = pass explicitly.
# presence_penalty: only pass when > 0 (Unsloth Flash-Next instruct uses 1.5).
$presetTemp = 0; $presetTopK = 0; $presetTopP = 0; $presetMinP = $null
$presetRepeat = ""; $presetRepeatLastN = 0; $presetPresence = 0
switch ($effectiveSamplerPreset) {
    "flash-next-think" {
        # Unsloth thinking-mode recs for Qwen3.8-Flash-Next
        $presetTemp = 1.0; $presetTopK = 20; $presetTopP = 0.95; $presetMinP = 0.0
        $presetPresence = 0.0; $presetRepeat = "1.0"; $presetRepeatLastN = 0
    }
    "flash-next-instruct" {
        # Unsloth non-thinking recs: tighter top_p + presence_penalty 1.5
        $presetTemp = 0.7; $presetTopK = 20; $presetTopP = 0.80; $presetMinP = 0.0
        $presetPresence = 1.5; $presetRepeat = "1.0"; $presetRepeatLastN = 0
    }
    "qwen-code"   { $presetTemp = 0.6; $presetTopK = 20; $presetTopP = 0.95; $presetMinP = 0.05; $presetRepeat = "1.1"; $presetRepeatLastN = 512 }
    "chat"        { $presetTemp = 0.8;                       $presetTopP = 0.95; $presetMinP = 0.05; $presetRepeat = "1.1"; $presetRepeatLastN = 512 }
    "repeat-only" {                                                                                     $presetRepeat = "1.1"; $presetRepeatLastN = 512 }
    "off"         { }
    default       { if ($effectiveSamplerPreset) { Write-Host "警告: 不明なサンプラープリセット '$effectiveSamplerPreset' は無視します。" -ForegroundColor Yellow } }
}
$effectiveTemperature = if ($Temperature -gt 0) { $Temperature } else { $presetTemp }
$effectiveTopK = if ($TopK -gt 0) { $TopK } else { $presetTopK }
$effectiveTopP = if ($TopP -gt 0) { $TopP } else { $presetTopP }
$effectiveMinP = if ($MinP -gt 0) { $MinP } else { $presetMinP }
$effectiveRepeatPenalty = if (-not [string]::IsNullOrWhiteSpace($RepeatPenalty)) { $RepeatPenalty } else { $presetRepeat }
$effectiveRepeatLastN = if ($RepeatLastN -gt 0) { $RepeatLastN } else { $presetRepeatLastN }
$effectivePresencePenalty = $presetPresence
if ($null -ne $effectiveRepeatPenalty -and [string]::IsNullOrWhiteSpace($effectiveRepeatPenalty)) { $effectiveRepeatPenalty = "" }

$samplerSummary = @()
if ($effectiveSamplerPreset) { $samplerSummary += "preset=$effectiveSamplerPreset" }
if ($effectiveTemperature -gt 0) { $samplerSummary += "temp=$effectiveTemperature" }
if ($effectiveTopK -gt 0) { $samplerSummary += "top-k=$effectiveTopK" }
if ($effectiveTopP -gt 0) { $samplerSummary += "top-p=$effectiveTopP" }
if ($null -ne $effectiveMinP) { $samplerSummary += "min-p=$effectiveMinP" }
if ($effectivePresencePenalty -gt 0) { $samplerSummary += "presence=$effectivePresencePenalty" }
if ($effectiveRepeatPenalty) { $samplerSummary += "repeat=$effectiveRepeatPenalty$(if ($effectiveRepeatLastN -gt 0) { "/w$effectiveRepeatLastN" })" }

# Prompt-cache KV reuse (--cache-reuse). Coding-agent workloads resend the
# same long prefix every turn; KV shifting reuses it instead of re-prefilling.
$effectiveCacheReuse = $CacheReuse
if ($effectiveCacheReuse -lt 0) { $effectiveCacheReuse = 512 }
if (-not $DryRun -and $advancedSettingsMenu -and $CacheReuse -lt 0) {
    $effectiveCacheReuse = Read-MenuInt -Prompt "プロンプトキャッシュ再利用 (--cache-reuse)、Enter で 512 (0 = オフ)" -Min 0 -Max 2147483647 -Default 512
}

# Process priority (--prio). high = optimal on Windows (small decode win, less
# latency jitter); realtime (3) can starve the OS.
$priorityMap = @{ "low" = -1; "normal" = 0; "medium" = 1; "high" = 2; "realtime" = 3 }
$effectivePriorityValue = 2
if (-not [string]::IsNullOrWhiteSpace($Priority)) {
    $prioKey = $Priority.Trim().ToLower()
    if ($priorityMap.ContainsKey($prioKey)) { $effectivePriorityValue = $priorityMap[$prioKey] }
    else {
        $parsedPrio = 0
        if ([int]::TryParse($Priority, [ref]$parsedPrio) -and $parsedPrio -ge -1 -and $parsedPrio -le 3) { $effectivePriorityValue = $parsedPrio }
        else { Write-Host "警告: 不明な優先度 '$Priority' のため high (2) を使用します。" -ForegroundColor Yellow }
    }
}
if (-not $DryRun -and $advancedSettingsMenu -and [string]::IsNullOrWhiteSpace($Priority)) {
    $priorityInput = Read-Host "プロセス優先度 (--prio)、Enter で high (2) [low/normal/medium/high/realtime]"
    if (-not [string]::IsNullOrWhiteSpace($priorityInput)) {
        $prioKey = $priorityInput.Trim().ToLower()
        if ($priorityMap.ContainsKey($prioKey)) { $effectivePriorityValue = $priorityMap[$prioKey] }
        else {
            $parsedPrio = 0
            if ([int]::TryParse($priorityInput, [ref]$parsedPrio) -and $parsedPrio -ge -1 -and $parsedPrio -le 3) { $effectivePriorityValue = $parsedPrio }
        }
    }
}

# Ubatch (--ubatch-size). 1024 is the recommended default with MTP (faster
# prefill; also avoids a known MTP collapse at very large context). Resolved
# here so the interactive prompt lives in the 詳細 settings flow; the emission
# section below re-resolves from param/env when this stays 0.
$effectiveUbatch = 0
if (-not $DryRun -and $advancedSettingsMenu -and $Ubatch -le 0) {
    $effectiveUbatch = Read-MenuInt -Prompt "Ubatch (--ubatch-size)、Enter で 1024" -Min 1 -Max 2147483647 -Default 1024
}

if ($effectiveCacheReuse -gt 0) { $samplerSummary += "cache-reuse=$effectiveCacheReuse" }
if ($effectivePriorityValue -ne 2) { $samplerSummary += "prio=$effectivePriorityValue" }
if ($effectiveUbatch -gt 0) { $samplerSummary += "ubatch=$effectiveUbatch" }
if ($samplerSummary) {
    Write-Host "出力・速度設定: $($samplerSummary -join ' ')" -ForegroundColor Green
    Write-Host ""
}

# Merge with user-provided chat-template-kwargs (reasoning kwargs take precedence if no custom input)
if ([string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs)) {
    $effectiveChatTemplateKwargs = $ChatTemplateKwargs
}

# Flash-Next / hybrid thinking: Unsloth recommends controlling reasoning depth
# via chat-template-kwargs reasoning_effort, NOT --reasoning-effort (Laguna
# rejects that flag). Map low/medium/high -> kwargs; leave off/on as --reasoning.
if ($isQwen4Exp -and [string]::IsNullOrWhiteSpace($ChatTemplateKwargs)) {
    $effortKwargs = $null
    switch ($selectedReasoningValue) {
        "low"    { $effortKwargs = '{"reasoning_effort":"low"}' }
        "medium" { $effortKwargs = '{"reasoning_effort":"medium"}' }
        "high"   { $effortKwargs = '{"reasoning_effort":"xhigh"}' }
        default  { }
    }
    if ($effortKwargs) {
        $effectiveChatTemplateKwargs = $effortKwargs
        $effectiveReasoningEffort = ""
        $effectiveReasoningMode = "on"
        if (-not $isQuickLaunch) {
            Write-Host "Reasoning effort: chat-template-kwargs $effortKwargs（--reasoning-effort は使わない）" -ForegroundColor Green
            Write-Host ""
        }
    }
}
if ([string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs) -and $ClientMode -eq "LlamaAgent") {
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
        Write-Host "エラー: chat-template-kwargs は有効な JSON である必要があります" -ForegroundColor Red
        exit 1
    }
}

# Coding clients (Cline / OpenCode / Pi) default to server-side thinking OFF
# when no reasoning mode was resolved above (quick-launch OpenCode / PiCoding
# skip the menu, and DryRun never prompts). The clients force thinking off
# client-side, so leaving the server default means thought tokens can still
# eat the gateway's max_tokens cap and slow every turn down.
if ([string]::IsNullOrWhiteSpace($effectiveReasoningMode) -and $ClientMode -in @("Cline", "OpenCode", "Pi")) {
    $effectiveReasoningMode = "off"
    if (-not $DryRun) {
        Write-Host "推論モード: オフ (コーディング既定)" -ForegroundColor Green
        Write-Host ""
    }
}

$effectiveKCacheType = $selectedKCache.Type
$effectiveVCacheType = $selectedVCache.Type

# KV type notes
# - Unsloth HIP + Flash-Next: FA has no kernel for q8_0+q4_0 and silently
#   converts both to f16 (slow). Force V=q8_0 on that engine only.
# - Laguna (TurboQuant fork): supports q8_0 / q4_0 / f16 and turbo2/3/4.
#   KV quantization works; handoff measured turbo2+FA slightly worse on the
#   hot-expert path (~11.5 t/s) so q8_0 stays the safe default.
if ($isQwen4Exp -and -not $script:LagunaHotExpert -and $effectiveVCacheType -eq "q4_0") {
    $effectiveVCacheType = "q8_0"
    if (-not $isQuickLaunch) {
        Write-Host "KV cache V: q8_0 (Unsloth では Flash-Next の q8_0+q4_0 で FA が f16 変換になるため)" -ForegroundColor Yellow
    }
}
elseif ($script:LagunaHotExpert -and $isQwen4Exp -and -not $isQuickLaunch) {
    Write-Host "KV cache: Laguna は量子化 KV 対応（q8_0/q4_0/turbo2-3-4）。既定は q8_0。turbo は長ctx省VRAM用（速度はほぼ同等〜やや低下）" -ForegroundColor DarkGray
}

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
    Write-Host "プロンプトキャッシュ RAM: $effectiveCacheRamMiB MiB" -ForegroundColor Green
    Write-Host ""
}

if ($FlashAttentionMode -eq "Prompt") {
    Write-Host "Flash Attention モード:" -ForegroundColor Green
    Write-Host " [1] On - 対応時は最速"
    Write-Host " [2] Off - ヘッドサイズ非対応モデル向けの互換フォールバック"
    Write-Host ""

    $faSelection = Read-MenuInt -Prompt "Flash Attention を選択 (1-2)、または Enter で On" -Min 1 -Max 2 -Default 1

    if ($faSelection -eq 1) { $FlashAttentionMode = "On" }
    else { $FlashAttentionMode = "Off" }
}

if ($FlashAttentionMode -eq "Off") { $flashAttention = "off" }
else { $flashAttention = "on" }

if (-not $isQuickLaunch) {
    Write-Host "Flash Attention: $flashAttention" -ForegroundColor Green
    $visionSummary = if ($visionMmprojPath) { if ($visionEnabled) { "on ($($visionMmprojPath.Name))" } else { "off (アダプタ検出済み)" } } else { "なし (モデル隣に mmproj なし)" }
    Write-Host "ビジョン: $visionSummary" -ForegroundColor Green
    Write-Host ""
}

if ($flashAttention -eq "off" -and $effectiveVCacheType -notin @("f16", "bf16", "f32")) {
    Write-Host "エラー: V キャッシュ量子化には Flash Attention が必要です。" -ForegroundColor Red
    Write-Host "Flash Attention On を選ぶか、V キャッシュを f16/bf16/f32 にしてください。" -ForegroundColor Red
    exit 1
}

# External MTP draft (Unsloth shared-Q8_0 etc.) sitting next to the main GGUF.
# Flash-Next GSQ-RCO bodies often have no built-in NextN tensors; -md still works
# when a shared MTP file is present.
$mtpDraftPath = $null
try {
    $mtpDraftPath = Get-ChildItem -LiteralPath (Split-Path -Parent $selected.FullName) -Filter "mtp-*.gguf" -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
}
catch { $mtpDraftPath = $null }
$modelIsMtpBuiltIn = $selected.Name -match "(?i)MTP"
$modelHasMtpDraft = [bool]$mtpDraftPath
$modelCanMtp = $modelIsMtpBuiltIn -or $modelHasMtpDraft

if ($SpecMode -eq "Prompt") {
    Write-Host "投機的デコードモード:" -ForegroundColor Green
    Write-Host " [1] Off - 通常デコード"
    if ($modelCanMtp) {
        Write-Host " [2] MTP/NextN --spec-type draft-mtp (Unsloth: n-max 2〜5)  【MTP あり】" -ForegroundColor Cyan
        if ($mtpDraftPath) { Write-Host "     draft: $($mtpDraftPath.Name)" -ForegroundColor DarkGray }
    }
    else {
        Write-Host " [2] MTP/NextN - MTP テンソル/draft GGUF が見つかりません"
    }
    Write-Host " [3] ngram-simple - 文脈 n-gram 投機（draft 不要・短文では効果小）"
    Write-Host " [4] ngram-mod - Unsloth Desktop の Ngram 系に相当（--spec-type ngram-mod）" -ForegroundColor Cyan
    if ($modelCanMtp) {
        Write-Host " [5] MTP + ngram-mod - --spec-type draft-mtp,ngram-mod（Strix Halo 実測スタック）" -ForegroundColor Cyan
    }
    Write-Host ""

    $specChoices = [ordered]@{
        1 = "Off"
        2 = "MtpNextN"
        3 = "NgramSimple"
        4 = "NgramMod"
        5 = "MtpNgramMod"
    }
    $maxSpecChoice = if ($modelCanMtp) { 5 } else { 4 }
    $defaultSpecChoice = if ($modelIsMtpBuiltIn) { 2 } elseif ($isQwen4Exp) { 4 } else { 1 }
    $defaultSpecLabel = $specChoices[[int]$defaultSpecChoice]
    $specSelection = Read-MenuInt -Prompt "投機モードを選択 (1-$maxSpecChoice)、または Enter で $defaultSpecLabel" -Min 1 -Max $maxSpecChoice -Default $defaultSpecChoice

    if (-not $specChoices.Contains($specSelection)) { $specSelection = 1 }
    $SpecMode = $specChoices[[int]$specSelection]
    if ($SpecMode -eq "MtpNgramMod" -and -not $modelCanMtp) { $SpecMode = "NgramMod" }
    if ($SpecMode -eq "MtpNextN" -and -not $modelCanMtp) { $SpecMode = "Off" }
}

if (-not $isQuickLaunch) {
    Write-Host "投機的デコードモード: $SpecMode" -ForegroundColor Green
    if ($SpecMode -in @("MtpNextN", "MtpNgramMod")) {
        Write-Host "  注意: MTP は短いプロンプトに有効。5K トークン超のコンテキストでは Off 推奨" -ForegroundColor Yellow
        Write-Host "  (長文プロンプトのデコードは大きく落ちることがある)。大ファイルのコーディングは Off。" -ForegroundColor Yellow
        if ($SpecDraftNMax -gt 0) { Write-Host "  draft n-max: $SpecDraftNMax (Unsloth start=2, Flash-Next guide=5)" -ForegroundColor DarkGray }
    }
    if ($SpecMode -in @("NgramSimple", "NgramMod", "MtpNgramMod")) {
        Write-Host "  ngram: draft 不要。再現性のあるコード/長文より、繰り返しの多い出力で効きやすい" -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($SpecMode -in @("MtpNextN", "MtpNgramMod") -and -not $modelCanMtp) {
    Write-Host "エラー: MTP モードには組み込み *_MTP.gguf か、隣接する mtp-*.gguf draft が必要です。" -ForegroundColor Red
    Write-Host "選択中: $($selected.Name)" -ForegroundColor Red
    if ($mtpDraftPath) { Write-Host "draft 検出: $($mtpDraftPath.FullName)" -ForegroundColor Yellow }
    exit 1
}

# Prompt MCP helper selection
$mcpOptions = @(
    [PSCustomObject]@{ Label = "None"; Value = "None"; Note = "Cline の安定性のため推奨" },
    [PSCustomObject]@{ Label = "Light"; Value = "Light"; Note = "Web 検索、ファイルシステム、メモリ" }
)

if ($ClientMode -notin @("Cline", "Pi")) {
    $selectedMcp = "None"
}
elseif ($McpMode -eq "Prompt") {
    Write-Host "MCP ヘルパーサーバー:" -ForegroundColor Green
    for ($i = 0; $i -lt $mcpOptions.Count; $i++) {
        $mcp = $mcpOptions[$i]
        Write-Host " [$($i+1)] $($mcp.Label) - $($mcp.Note)"
    }
    Write-Host ""

    $defaultMcpLabel = "None"
    $mcpSelection = Read-MenuInt -Prompt "MCP モードを選択 (1-2)、または Enter で $defaultMcpLabel" -Min 1 -Max 2 -Default 1

    $selectedMcp = $mcpOptions[$mcpSelection - 1].Value
}
else {
    $selectedMcp = $McpMode
}

if ($isQuickLaunch) {
    Write-Host ""
    Write-Host "  READY TO LAUNCH (起動準備完了)" -ForegroundColor Green
    Write-Host "  $launchLabel" -ForegroundColor Cyan
    Write-Host "  $($selectedContext.Label) context | KV K:$($selectedKCache.Label) / V:$($selectedVCache.Label) | GPU:$serverOffload" -ForegroundColor DarkGray
    Write-Host "  $requiredEngine | Flash Attention:$flashAttention | Cache RAM:$effectiveCacheRamMiB MiB" -ForegroundColor DarkGray
    Write-Host ""
}
else {
    Write-Host "MCP ヘルパー: $selectedMcp" -ForegroundColor Green
    Write-Host ""
}

# Planned memory budget (estimate only; no benchmark, no dry-run).
# Auto GPU fit is decided by the engine at launch, so this stays a TOTALLY static planning aid based on handled model + context.
$estimatedKvGb = [math]::Round(($selectedContext.Tokens / 32768.0) * [math]::Max(4, $selectedModelSizeGB * 0.22), 1)
$estimatedModelPlusKvGb = [math]::Round($selectedModelSizeGB + $estimatedKvGb, 1)
$estimatedTotalRamGb = [math]::Round($estimatedModelPlusKvGb + ($effectiveCacheRamMiB / 1024.0) + 1.0, 1)
$gpuBudgetText = if ($selectedOffload -eq "0") { "none forced (CPU-heavy, VRAM should stay small)" } elseif ($serverOffload -match '^[0-9]+$') { "explicit -ngl=$serverOffload" } else { "auto fit from free VRAM, cap about $($primaryVramGB)GB" }
Write-Host "想定メモリ (概算、実測ではありません):" -ForegroundColor Green
Write-Host (" model=$selectedModelSizeGB GB + KV=$estimatedKvGb GB (context=$($selectedContext.Tokens), K=$($effectiveKCacheType)/V=$($effectiveVCacheType)) = RAM本体 約{0}GB" -f $estimatedModelPlusKvGb) -ForegroundColor DarkGray
Write-Host (" + prompt cache RAM 約$([math]::Round($effectiveCacheRamMiB / 1024.0,1))GB + OS/compute 予備 1GB => RAM 約{0}GB" -f $estimatedTotalRamGb) -ForegroundColor DarkGray
Write-Host (" VRAM オフロード: {0}; エンジン実行時は compute buffer / reserve で ±数GB ずれます。" -f $gpuBudgetText) -ForegroundColor DarkGray
Write-Host " note: tight VRAM なら context ふたたび小さくするか KV (q8_0 -> q4_0) を先に下げてください。" -ForegroundColor Yellow
Write-Host ""

# Get model short name for -a flag. Split models display as
# "Base [N-part GGUF]"; use the on-disk first-shard name so -a stays a
# clean identifier.
$modelLeaf = [System.IO.Path]::GetFileNameWithoutExtension($selected.FullName)
$modelShort = $modelLeaf -replace "-\d{5}-of-\d{5}$", "" -replace "-", "_"

# PLE / per-layer n-gram lazy disk read (--lazy-mode). FreeToken PR #311
# equivalent already in Unsloth llama.cpp: TENSOR_READ_LAZY on per_layer_tok_embd
# streams the huge Qwen3.8-Flash-Next table from the GGUF instead of pinning
# it in host RAM. "on" forces it (even below the 4 GiB auto threshold);
# "auto" lets the engine decide; "off" loads everything eagerly.
$effectiveLazyMode = "auto"
if ($script:LagunaHotExpert) {
    # Laguna hot-expert path: leave PLE on SSD mmap (handoff rule). Do not
    # force --lazy-mode (flag may be absent) and never mlock/-ot pin shard2.
    $effectiveLazyMode = "off"
    Write-Host "PLE n-gram: SSD mmap (Laguna hot-expert; do not mlock / -ot PLE=CPU)" -ForegroundColor Green
}
elseif (-not [string]::IsNullOrWhiteSpace($LazyMode) -and $LazyMode -ne "Prompt") {
    $effectiveLazyMode = $LazyMode.Trim().ToLower()
}
elseif ($isQwen4Exp) {
    $effectiveLazyMode = "on"
}
if (-not $script:LagunaHotExpert -and $isQwen4Exp -and $effectiveLazyMode -ne "off") {
    Write-Host "PLE n-gram: lazy disk read (--lazy-mode $effectiveLazyMode) — テーブルは GGUF 上に置き、参照行だけ読み込み" -ForegroundColor Green
    Write-Host "  既定の mmap を維持すること。--no-mmap は PLE を RAM に全ロードしディスク100%の原因になる" -ForegroundColor DarkGray
}

# Laguna + Flash-Next: force dense GPU offload and no thinking unless user set them.
# Handoff fastest: --moe-hot-expert -ngl 99 -c 2048 -t 16 --reasoning off
if ($script:LagunaHotExpert -and $isQwen4Exp) {
    if ($NglLayers -le 0) {
        $serverOffload = "99"
    }
    # Default thinking OFF for Laguna Flash-Next unless user explicitly chose On/Budget.
    if ($selectedReasoningValue -in @("low", "medium", "high") -or [string]::IsNullOrWhiteSpace($selectedReasoningValue)) {
        if ($selectedReasoningValue -ne "on" -and $selectedReasoningValue -ne "budget") {
            $effectiveReasoningMode = "off"
            $effectiveReasoningEffort = ""
        }
    }
    if ($selectedContext -and $selectedContext.Tokens -gt 4096 -and -not $isQuickLaunch) {
        Write-Host "WARN: Laguna hot-expert + ctx>$($selectedContext.Tokens) はメモリ事故の実績あり（8K で WS~61GB / FreeRAM 逼迫）。2K–4K 推奨。" -ForegroundColor Yellow
        Write-Host "  FreeRAM が急減したら llama-server を即 kill（自動再起動しない）。" -ForegroundColor Yellow
    }
    Write-Host "Engine flags: Laguna --moe-hot-expert (HOST_BANK=0, dense→VRAM, expert RAM+hot bank)" -ForegroundColor Green
}

# Start server
$startFilePath = $ServerPath
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

if ($script:LagunaHotExpert -and $isQwen4Exp) {
    $args += "--moe-hot-expert"
}

$args += "--no-ui"

# Lazy PLE / per-layer embedding disk read. Probe once: builds without -lzm
# abort on unknown flags, so skip when the engine is too old. "auto" is the
# engine default and needs no flag.
if ($effectiveLazyMode -and $effectiveLazyMode -ne "auto") {
    if (-not $script:UnslothHelpText) {
        $oldProbePath = $env:PATH
        try {
            $script:UnslothHelpText = (& $ServerPath --help 2>&1 | Out-String)
        }
        finally {
            $env:PATH = $oldProbePath
        }
    }
    if ($script:UnslothHelpText -match "--lazy-mode") {
        $args += @("--lazy-mode", $effectiveLazyMode)
    }
    elseif ($effectiveLazyMode -eq "on" -and -not $isQuickLaunch) {
        Write-Host "WARNING: engine has no --lazy-mode; PLE table will load fully into RAM." -ForegroundColor Yellow
    }
}

# CPU threads. Laguna hot-expert handoff used -t 16 (H2D / remap). Unsloth
# Flash-Next measured +0.6 t/s at -t 11 (2026-09-15).
if ($isQwen4Exp) {
    if ($script:LagunaHotExpert) {
        $threadN = 16
    }
    else {
        $logical = [Environment]::ProcessorCount
        $threadN = [math]::Max(4, $logical - 1)
    }
    $args += @("-t", "$threadN", "-tb", "$threadN")
}

# Opt-in vision: image input via the mmproj adapter picked during setup.
if ($visionEnabled -and $visionMmprojPath) {
    $args += @("--mmproj", $visionMmprojPath.FullName)
}

# Prefill micro-batch override (see param comment). VRAM headroom is tight on
# 16 GB cards, so this stays opt-in; verify placement with the GPU probe.
# Default 1024 (optimal with MTP); already resolved interactively above.
if ($effectiveUbatch -le 0) {
    $ubatchRaw = "$env:LLAMADOCK_UBATCH".Trim()
    $envUbatch = if ($ubatchRaw -match "^\d+$") { [int]$Matches[0] } else { 0 }
    $effectiveUbatch = if ($Ubatch -gt 0) { $Ubatch } elseif ($envUbatch -gt 0) { $envUbatch } else { 1024 }
}
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
if ($effectiveReasoningEffort) {
    $args += @("--reasoning-effort", $effectiveReasoningEffort)
}
if ($effectiveReasoningBudget -gt 0) {
    $args += @("--reasoning-budget", "$effectiveReasoningBudget")
}

# Final safety pass: drop flags the live engine does not accept. Laguna
# rejects --reasoning-effort at argv parse time (exit before bind), which
# looked like "stuck waiting for server".
function Get-EngineHelpCache {
    param([string]$Exe)
    if (-not (Test-Path -LiteralPath $Exe)) { return "" }
    if (-not $script:EngineHelpCache) { $script:EngineHelpCache = @{} }
    $key = $Exe.ToLowerInvariant()
    if ($script:EngineHelpCache.ContainsKey($key)) { return $script:EngineHelpCache[$key] }
    $oldPath = $env:PATH
    try {
        if ($script:LagunaHotExpert -and (Test-Path -LiteralPath $LagunaRocmRoot)) {
            $env:PATH = "$LagunaRocmRoot\bin;$LagunaRocmRoot\lib\llvm\bin;$env:PATH"
        }
        $script:EngineHelpCache[$key] = (& $Exe --help 2>&1 | Out-String)
    }
    catch {
        $script:EngineHelpCache[$key] = ""
    }
    finally {
        $env:PATH = $oldPath
    }
    return $script:EngineHelpCache[$key]
}

function Remove-UnsupportedEngineArgs {
    param([string[]]$ArgList, [string]$Exe)
    $help = Get-EngineHelpCache -Exe $Exe
    if ([string]::IsNullOrWhiteSpace($help)) { return ,$ArgList }
    $dropFlags = @()
    foreach ($flag in @("--reasoning-effort", "--lazy-mode", "--spec-draft-n-max", "--moe-gpu-expert-global-lru")) {
        if ($help -notmatch [regex]::Escape($flag)) { $dropFlags += $flag }
    }
    if ($dropFlags.Count -eq 0) { return ,$ArgList }
    $out = New-Object System.Collections.Generic.List[string]
    $skipNext = $false
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        if ($skipNext) { $skipNext = $false; continue }
        $a = $ArgList[$i]
        $drop = $false
        foreach ($flag in $dropFlags) {
            if ($a -eq $flag) { $drop = $true; $skipNext = $true; break }
            if ($a.StartsWith("$flag=")) { $drop = $true; break }
        }
        if ($drop) {
            Write-Host "NOTE: エンジン未対応フラグを除去: $a" -ForegroundColor Yellow
            continue
        }
        $out.Add($a)
    }
    return ,$out.ToArray()
}

$args += @("--cache-ram", "$effectiveCacheRamMiB")

if (-not [string]::IsNullOrWhiteSpace($selectedMoeExperts)) {
    $args += @("--override-kv", "llama.expert_used_count=int:$selectedMoeExperts")
}

if (-not [string]::IsNullOrWhiteSpace($selectedCpuMoe) -and $selectedCpuMoe -ne "0") {
    $args += @("--n-cpu-moe", "$selectedCpuMoe")
}

if ($isDeepSeek) {
    $args += "--no-mmap"
}

# Sampler / output-quality flags (server defaults; clients like Cline and
# h3-chat may still override temperature per request). repeat-penalty breaks
# degenerated loops like "待待待..." (llama.cpp default = 1.0, no effect); a
# 512-token window also covers phrase-level loops that 256 misses.
if ($effectiveTemperature -gt 0) { $args += @("--temp", "$effectiveTemperature") }
if ($effectiveTopK -gt 0) { $args += @("--top-k", "$effectiveTopK") }
if ($effectiveTopP -gt 0) { $args += @("--top-p", "$effectiveTopP") }
# min-p 0.0 is intentional for Flash-Next — pass when preset set a value.
if ($null -ne $effectiveMinP) { $args += @("--min-p", "$effectiveMinP") }
if ($effectivePresencePenalty -gt 0) { $args += @("--presence-penalty", "$effectivePresencePenalty") }
if (-not [string]::IsNullOrWhiteSpace($effectiveRepeatPenalty) -and $effectiveRepeatPenalty -ne "1.0") {
    $args += @("--repeat-penalty", $effectiveRepeatPenalty)
    if ($effectiveRepeatLastN -gt 0) { $args += @("--repeat-last-n", "$effectiveRepeatLastN") }
}
# Prompt-cache KV reuse + process priority (speed knobs; see the 詳細 settings).
if ($effectiveCacheReuse -gt 0) { $args += @("--cache-reuse", "$effectiveCacheReuse") }
$args += @("--prio", "$effectivePriorityValue")

if ($SpecMode -ne "Off") {
    $specArgs = @()
    switch ($SpecMode) {
        "MtpNextN" {
            $specArgs += @("--spec-type", "draft-mtp")
            if ($SpecDraftNMax -gt 0) {
                $specArgs += @("--spec-draft-n-max", "$SpecDraftNMax", "--spec-draft-n-min", "1")
            }
        }
        "NgramSimple" {
            # Unsloth/llama.cpp ngram self-spec: no draft model required.
            $specArgs += @("--spec-type", "ngram-simple")
        }
        "NgramMod" {
            $specArgs += @("--spec-type", "ngram-mod")
        }
        "MtpNgramMod" {
            # Community Flash-Next stack (Unsloth Desktop "MTP / Ngram").
            $specArgs += @("--spec-type", "draft-mtp,ngram-mod")
            if ($SpecDraftNMax -gt 0) {
                $specArgs += @("--spec-draft-n-max", "$SpecDraftNMax", "--spec-draft-n-min", "2")
            }
        }
    }
    # Built-in NextN models need no -md; shared external draft (Flash-Next) does.
    if ($SpecMode -in @("MtpNextN", "MtpNgramMod") -and -not $modelIsMtpBuiltIn -and $mtpDraftPath) {
        $specArgs += @("-md", $mtpDraftPath.FullName)
    }
    # Only append flags the live engine actually supports (Laguna/Unsloth probe).
    $engineHelp = Get-EngineHelpCache -Exe $startFilePath
    $supported = @()
    $skipNext = $false
    for ($i = 0; $i -lt $specArgs.Count; $i++) {
        if ($skipNext) { $skipNext = $false; $supported += $specArgs[$i]; continue }
        $a = $specArgs[$i]
        $flag = ($a -split "=")[0]
        if ($engineHelp -and $engineHelp -notmatch [regex]::Escape($flag) -and $flag -like "--*") {
            Write-Host "NOTE: speculative flag not in engine help, skipping: $a" -ForegroundColor Yellow
            if ($i + 1 -lt $specArgs.Count -and $specArgs[$i + 1] -notlike "-*") { $skipNext = $true }
            continue
        }
        $supported += $a
    }
    if ($supported.Count -gt 0) { $args += $supported }
    if (-not $isQuickLaunch) {
        Write-Host "Speculative args: $($supported -join ' ')" -ForegroundColor DarkGray
    }
}

if ($CpuFfnLayers -ne "") {
    # Dense FFN CPU offload (PR ggml-org/llama.cpp#26622). Probe the binary
    # first: unknown flags abort llama-server at startup.
    # Off by default — measured TG -65..-91%; the use case is
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
    elseif ($ClientMode -eq "ARTEX") {
        Write-Host "DRY RUN: ARTEX console would open at http://localhost:8787 (bundled portable PostgreSQL auto-started)" -ForegroundColor Yellow
        Write-Host "DRY RUN: ARTEX LLM card points at $ClientBaseUrl/v1 (System -> LLM)" -ForegroundColor Yellow
    }
    else {
        Write-Host "DRY RUN: Pi (pi.dev) would open with model:" -ForegroundColor Yellow
        Write-Host $modelShort
        Write-Host "DRY RUN: Pi would connect to $ClientBaseUrl/v1" -ForegroundColor Yellow
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

            $serverSelection = Read-MenuInt -Prompt "サーバー操作を選択 (1-3)、または Enter で切り替え" -Min 1 -Max 3 -Default 1

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
            elseif ($ClientMode -eq "DeepSeekHarness") {
                # the DSH preset must open the DeepSeek Harness web UI (3080),
                # not fall through to the Pi TUI (the reuse-path dispatch predates
                # the DSH preset and fell into the Pi default)
                $lastClientProcess = Open-DeepSeekHarnessClient
            }
            elseif ($ClientMode -eq "ARTEX") {
                # ARTEX connects through its own saved LLM card, not per-launch
                # env vars — just start the console (same path as the fresh-boot
                # dispatch in Open-WorkspaceClient).
                $lastClientProcess = Open-ARTEXClient
            }
            else {
                Open-PiClient -ModelName $existingModel
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

            $busySelection = Read-MenuInt -Prompt "サーバー操作を選択 (1-2)、または Enter で終了" -Min 1 -Max 2 -Default 1

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

Wait-VramRelease -TimeoutSec 50
Ensure-UnslothCudaRuntime -ServerExe $ServerPath

# ---- Strata engine: start its own serve/server.py + the shared gateway, then
# ---- skip the llama-server supervisor flow entirely below.
$skipLlamaServerFlow = $false
# The final readiness check below runs for every engine, including the
# Strata keep-alive path (which starts no new process), so the flags must
# exist before the engine dispatch or -not $ready reads $null.
$ready = $false
$maxWait = 0
if ($requiredEngine -eq "Strata") {
    $skipLlamaServerFlow = $true
    $SkipGpuProbe = $true   # the GPU offload probe speaks llama-server's API
    # LlamaDock model selection switches quants: each strata-*.json IS the fastest
    # setting for its quant, and the config was already picked above by --native.
    # If a Strata serve already runs on :8080 with the SAME quant, keep it; otherwise
    # replace it, so the new config can bind :8080 instead of dying on it.
    $strataQuant = ($strataNativeName -replace '-0000[0-9]-of-0000[0-9]\.gguf$', '') -replace '.*-', ''
    $needStart = $true
    try {
        $live = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 3
        $liveQuant = [string](@($live.data)[0].id) -replace '.*-', ''
        $liveCtx = @($live.data)[0].meta.n_ctx
        if ($liveQuant -and $liveQuant -eq $strataQuant -and $liveCtx -eq $strataMaxCtx) { $needStart = $false }
    }
    catch { }
    if (-not $needStart) {
        Write-Host "Strata is already serving the $strataQuant model on :8080 - keeping it." -ForegroundColor Green
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$GatewayPort/health" -TimeoutSec 3
        }
        catch {
            $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
            $gatewayArgs = @(
                (Join-Path $PSScriptRoot "tools\llamadock-proxy.mjs"),
                "--host", "127.0.0.1",
                "--port", "$GatewayPort",
                "--upstream", "http://127.0.0.1:8080",
                "--log-dir", (Join-Path $PSScriptRoot "logs")
            )
            $null = Start-Process -FilePath $nodeExe -ArgumentList $gatewayArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden
        }
        $script:ClientBaseUrl = $GatewayBaseUrl
        # No new process to wait on: the live Strata already answered /v1/models
        # above, so mark ready or the tail check exits 1 every keep-alive run.
        $ready = $true
    }
    if ($needStart) {
        $old8080 = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($old8080) { Stop-Process -Id $old8080.OwningProcess -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
        Get-Process strata -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep 1
    }
    if ($needStart) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $strataOut = Join-Path $PSScriptRoot "logs\strata-$stamp.stdout.log"
        $strataErr = Join-Path $PSScriptRoot "logs\strata-$stamp.stderr.log"
        Write-Host "Starting Strata (serve/server.py on :8080)..." -ForegroundColor Blue
        $strataProc = Start-Process -FilePath $StrataPython `
            -ArgumentList @("serve\server.py", "--engine", "strata", "--config", $StrataConfig, "--port", "8080") `
            -WorkingDirectory $StrataRoot -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $strataOut -RedirectStandardError $strataErr
        Write-Host "Starting the LlamaDock gateway (:8090 -> :8080)..." -ForegroundColor Blue
        $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
        $gatewayArgs = @(
            (Join-Path $PSScriptRoot "tools\llamadock-proxy.mjs"),
            "--host", "127.0.0.1",
            "--port", "$GatewayPort",
            "--upstream", "http://127.0.0.1:8080",
            "--log-dir", (Join-Path $PSScriptRoot "logs")
        )
        $null = Start-Process -FilePath $nodeExe -ArgumentList $gatewayArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden
        Write-Host "Waiting for Strata to be ready..." -NoNewline -ForegroundColor Yellow
        $ready = $false
        for ($i = 0; $i -lt 90; $i++) {
            Start-Sleep -Seconds 2
            if ($strataProc.HasExited) {
                Write-Host ""
                Write-Host "ERROR: the Strata server exited (code $($strataProc.ExitCode)). Check $strataErr" -ForegroundColor Red
                break
            }
            try {
                $null = Invoke-RestMethod -Uri "http://127.0.0.1:8080/health" -TimeoutSec 5
                $ready = $true
                $script:ClientBaseUrl = $GatewayBaseUrl
                Write-Host " Done!" -ForegroundColor Green
                Write-Host "Strata engine console output: $strataOut" -ForegroundColor DarkGray
                break
            }
            catch { }
            if ($i % 5 -eq 4) { Write-Host "." -NoNewline -ForegroundColor Yellow }
        }
        if (-not $ready) {
            Get-Process strata -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Save-RunResult -Model $selected -Engine "Strata" -Preset $PresetMode -Client $ClientMode -ContextTokens $selectedContext.Tokens -KCache $effectiveKCacheType -VCache $effectiveVCacheType -Offload $selectedOffload -FlashAttention $flashAttention -CacheRamMiB $effectiveCacheRamMiB -Status "fail" -Message "Strata server did not become ready"
            exit 1
        }
    }
}

Write-Host "Starting llama-server under the LlamaDock supervisor..." -ForegroundColor Blue
if (-not $skipLlamaServerFlow) {
    if (-not [string]::IsNullOrWhiteSpace($effectiveChatTemplateKwargs)) {
        $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = $effectiveChatTemplateKwargs
    }
    else {
        Remove-Item Env:\LLAMA_ARG_CHAT_TEMPLATE_KWARGS -ErrorAction SilentlyContinue
    }
    $proc = $null
    # Drop flags the live engine rejects (e.g. Laguna has no --reasoning-effort).
    # Must run after the full argv is assembled — llama-server exits on unknown
    # args before binding :8080, which used to look like "stuck waiting".
    $args = Remove-UnsupportedEngineArgs -ArgList $args -Exe $startFilePath
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
    if ($ClineMaxTokens -gt 0) {
        $supervisorArgs += "-ClineMaxTokens", $ClineMaxTokens
    }
    # Opt-in resilience: without -AutoRestart a manually killed llama-server
    # stays down and the supervisor shuts the gateway and itself cleanly.
    if ($AutoRestart) {
        $supervisorArgs += "-AutoRestartServer"
    }
    # Keep the supervisor in a normal console so the user can see and control
    # the server session. Ctrl+C in that console reaches the supervisor's
    # finally block, which stops llama-server and the gateway cleanly.
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $supervisorArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Normal
    Write-Host "LlamaDock サーバーコンソールを開きました (supervisor PID $($proc.Id))。あそこのウィンドウで Ctrl+C を押すと llama-server を停止します。" -ForegroundColor Cyan

    Write-Host "Waiting for server to be ready..." -NoNewline -ForegroundColor Yellow
    # A 50+ GiB MoE can need several minutes to map weights, fit VRAM, and
    # publish /v1/models. Keep the normal path quick, but do not make the user
    # think a heavy model failed while it is still loading.
    $maxWait = if ($selectedModelSizeGB -ge 50) { 180 } elseif ($selectedModelSizeGB -ge 20) { 120 } else { 60 }
    # Laguna Flash-Next is ~70GB multi-part: allow a longer load window.
    if ($script:LagunaHotExpert -and $isQwen4Exp -and $maxWait -lt 240) { $maxWait = 240 }
    $ready = $false
    for ($i = 0; $i -lt $maxWait; $i++) {
        Start-Sleep -Seconds 2
        # Supervisor died (argv error / crash) — stop waiting instead of spinning.
        if ($proc -and $proc.HasExited) {
            Write-Host ""
            Write-Host "ERROR: supervisor exited (code $($proc.ExitCode)). Check logs\supervisor.log and the latest llama-server-*.stderr.log" -ForegroundColor Red
            $stderr = Get-ChildItem (Join-Path $PSScriptRoot "logs") -Filter "llama-server-*.stderr.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($stderr) {
                Write-Host "Last server stderr ($($stderr.Name)):" -ForegroundColor Yellow
                Get-Content -LiteralPath $stderr.FullName -Tail 20
            }
            break
        }
        # llama-server publishes the -a alias as the model id, so we can verify the
        # freshly started server is actually serving the selected model.
        $expectedReadyModel = $modelShort
        $directReady = Test-ServerReady -ExpectedModelId $expectedReadyModel
        $gatewayReady = Test-GatewayReady -ExpectedModelId $expectedReadyModel
        if ($directReady -and $gatewayReady) {
            $ready = $true
            # Set-ClientBaseUrl re-tests the gateway and throws on a transient
            # miss; the ready check above just passed, so retry briefly and fall
            # back to the gateway URL instead of killing the whole launch.
            $clientUrlSet = $false
            for ($retry = 0; $retry -lt 5 -and -not $clientUrlSet; $retry++) {
                try {
                    Set-ClientBaseUrl -ExpectedModelId $expectedReadyModel | Out-Null
                    $clientUrlSet = $true
                }
                catch {
                    Start-Sleep -Seconds 2
                }
            }
            if (-not $clientUrlSet) {
                $script:ClientBaseUrl = $GatewayBaseUrl
            }
            Write-Host " Done!" -ForegroundColor Green
            break
        }
        if ($i % 5 -eq 4) { Write-Host "." -NoNewline -ForegroundColor Yellow }
    }
}   # end of the llama-server supervisor flow (Strata started its own server above)

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
Write-Host "起動設定" -ForegroundColor Cyan
Write-Host "--------" -ForegroundColor Cyan
Write-Host " エンドポイント     $ClientBaseUrl" -ForegroundColor Green
if ($ClientBaseUrl -ne $ServerBaseUrl) {
    Write-Host " 上流サーバー       $ServerBaseUrl" -ForegroundColor DarkGray
}
Write-Host " ワークスペース     $ClientMode" -ForegroundColor Green
Write-Host " モデル             $($selected.Name)" -ForegroundColor Green
Write-Host " エンジン           $requiredEngine" -ForegroundColor Green
Write-Host " コンテキスト       $($selectedContext.Label) ($($selectedContext.Tokens) トークン)" -ForegroundColor Green
Write-Host " KVキャッシュ       K=$effectiveKCacheType, V=$effectiveVCacheType" -ForegroundColor Green
Write-Host " プロンプトキャッシュ $effectiveCacheRamMiB MiB" -ForegroundColor Green
Write-Host " Flash Attention    $flashAttention" -ForegroundColor Green
Write-Host " 推測デコード       $SpecMode" -ForegroundColor Green
Write-Host " PLE レイジー読込   $effectiveLazyMode" -ForegroundColor Green
Write-Host " GPUオフロード      $selectedOffload" -ForegroundColor Green
Write-Host " MCP                $selectedMcp" -ForegroundColor Green
Write-Host ""

while ($true) {
    if ($lastClientProcess) {
        Write-Host "ワークスペースのウィンドウが閉じるのを待っています…" -ForegroundColor DarkGray
        Wait-Process -Id $lastClientProcess.Id -ErrorAction SilentlyContinue
    }
    else {
        Read-Host "Enter を押すと LlamaDock に戻ります" | Out-Null
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
            Stop-ActiveServerStack
            if ($lastClientProcess -and -not $lastClientProcess.HasExited) { Stop-Process -Id $lastClientProcess.Id -Force -ErrorAction SilentlyContinue }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
            exit $LASTEXITCODE
        }
        "stop" {
            Stop-ActiveServerStack
            if ($lastClientProcess -and -not $lastClientProcess.HasExited) { Stop-Process -Id $lastClientProcess.Id -Force -ErrorAction SilentlyContinue }
            # Killing the launcher shim can orphan the dsh web node child; stop it by port.
            Stop-StaleDeepSeekHarness
            if ($script:StopAllOnExit) { Stop-H3Stack }
            exit 0
        }
        default { exit 0 }
    }
}
