<#
.SYNOPSIS
    MiniMax H3 acceleration status and apply helper for the ComfyUI workspace.

.DESCRIPTION
    Inspects the local ComfyUI install (default C:\Users\dai86\Documents\ComfyUI)
    and reports which MiniMax H3 accelerators are available on this GPU stack.
    Run without switches to get a status table plus the recommended launch flags.
    Optionally installs the missing nodes that are safe on AMD/ROCm:

      -InstallSpectrum   git clone xmarre/ComfyUI-Spectrum-MiniMax-H3
      -InstallKJNodes    git clone kijai/ComfyUI-KJNodes

    Notes on what is NOT auto-installed and why (details in
    docs/MiniMax-H3-Tuning.md):

      - SageAttention (--use-sage-attention, KJNodes "Patch Sage Attention" and
        "MiniMax H3 Memory Efficient Sage Attention Patch") is CUDA-only. The
        mem-eff H3 patch requires the latest SageAttention 2.x, which cannot run
        on this ROCm stack.
      - Sol-Attn (kijai/ComfyUI-SolAttn_triton) targets NVIDIA SM89+ kernels.
      - EasyCache (ComfyUI-MiniMaxH3-Cache) is generic PyTorch but is
        mutually exclusive with Spectrum and is reported to degrade quality.
      - comfy-kitchen INT8 Triton kernels (--enable-triton-backend) require
        triton in the ComfyUI venv. On ROCm Windows the only option is the
        triton-windows fork, and testing on 2026-08-14 showed it crashes
        ComfyUI during text-encoder processing (HIP codegen error), so this
        tool reports availability but does not enable or install it.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\comfyui-tune.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\comfyui-tune.ps1 -InstallSpectrum
#>
param(
    [string]$ComfyRoot = "C:\Users\dai86\Documents\ComfyUI",
    [switch]$InstallSpectrum,
    [switch]$InstallKJNodes,
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

function Write-Result {
    param([string]$Line, [string]$Color = "Gray")
    if (-not $Quiet) {
        Write-Host $Line -ForegroundColor $Color
    }
}

function Write-Section {
    param([string]$Line)
    if (-not $Quiet) {
        Write-Host ""
        Write-Host $Line -ForegroundColor Cyan
    }
}

$comfyPython = Join-Path $ComfyRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath (Join-Path $ComfyRoot "main.py"))) {
    Write-Host "ERROR: ComfyUI not found at $ComfyRoot" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $comfyPython)) {
    Write-Host "ERROR: ComfyUI venv python not found at $comfyPython" -ForegroundColor Red
    exit 1
}

# Windows PowerShell 5.1 mangles native -c arguments that contain embedded
# quotes, so probe the venv through a temp script file instead.
$probeFile = Join-Path $env:TEMP ("comfyui-probe-{0}.py" -f [guid]::NewGuid().ToString("N"))
$pyProbe = @'
import importlib.util, json
out = {}
for m in ("torch", "triton", "sageattention", "comfy_kitchen", "comfy_aimdo"):
    out[m] = importlib.util.find_spec(m) is not None
try:
    import torch
    out["torch_version"] = torch.__version__
    out["is_hip"] = torch.version.hip is not None
    try:
        out["gcn"] = torch.cuda.get_device_properties(torch.cuda.current_device()).gcnArchName
    except Exception:
        out["gcn"] = None
    try:
        from comfy_kitchen import int8_attention_is_available
        out["ck_attn"] = bool(int8_attention_is_available())
    except Exception:
        out["ck_attn"] = None
except Exception:
    pass
print(json.dumps(out))
'@
Set-Content -LiteralPath $probeFile -Value $pyProbe -Encoding UTF8
$probeJson = & $comfyPython $probeFile 2>$null | Select-Object -Last 1
Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
$info = $null
if ($probeJson) {
    try {
        $info = $probeJson | ConvertFrom-Json
    }
    catch {
    }
}

$comfyVersion = "unknown"
$versionFile = Join-Path $ComfyRoot "comfyui_version.py"
if (Test-Path -LiteralPath $versionFile) {
    $versionSource = Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8
    if ($versionSource -match '__version__\s*=\s*"([^"]+)"') {
        $comfyVersion = $Matches[1]
    }
}

$customNodes = @()
$customNodesDir = Join-Path $ComfyRoot "custom_nodes"
if (Test-Path -LiteralPath $customNodesDir) {
    $customNodes = Get-ChildItem -LiteralPath $customNodesDir -Directory | Where-Object { $_.Name -notmatch "^__" } | ForEach-Object { $_.Name } | Sort-Object
}

Write-Section "ComfyUI environment"
Write-Result ("  Root:           {0}" -f $ComfyRoot)
Write-Result ("  Version:        {0}" -f $comfyVersion)
if ($info) {
    Write-Result ("  torch:          {0}" -f $info.torch_version)
    Write-Result ("  backend:        {0}" -f ($(if ($info.is_hip) { "ROCm/HIP" } else { "CUDA" })))
    if ($info.gcn) {
        Write-Result ("  GPU arch:       {0}" -f $info.gcn)
    }
    Write-Result ("  triton:         {0}" -f ($(if ($info.triton) { "installed" } else { "NOT installed" })))
    Write-Result ("  sageattention:  {0}" -f ($(if ($info.sageattention) { "installed" } else { "NOT installed" })))
    Write-Result ("  comfy-kitchen:  {0}" -f ($(if ($info.comfy_kitchen) { "installed" } else { "NOT installed" })))
    Write-Result ("  comfy-aimdo:    {0}" -f ($(if ($info.comfy_aimdo) { "installed" } else { "NOT installed" })))

$ckFlagSupported = $false
$cliArgsFile = Join-Path $ComfyRoot "comfy\cli_args.py"
if (Test-Path -LiteralPath $cliArgsFile) {
    if ((Get-Content -LiteralPath $cliArgsFile -Raw -Encoding UTF8) -match "use-ck-attention") {
        $ckFlagSupported = $true
    }
}
$turboLora = Join-Path $ComfyRoot "models\loras\minimax_h3_turbo_4step_ckpt600_ema_V4.safetensors"
$clipProjMatrix = Join-Path $ComfyRoot "models\clip_projections\mmh3-4b-ClipProj-celeb-mlp.safetensors"
$smallEncoder = Join-Path $ComfyRoot "models\text_encoders\qwen3vl_4b_fp8_scaled.safetensors"
}
else {
    Write-Result "  torch probe failed; cannot classify the GPU stack." -Color Yellow
}
if ($customNodes.Count -gt 0) {
    Write-Result ("  custom nodes:   {0}" -f ($customNodes -join ", "))
}
else {
    Write-Result "  custom nodes:   (none)"
}

$isRocm = $false
if ($info) {
    $isRocm = [bool]$info.is_hip
}
$isNvidia = (-not $isRocm) -and $info -and $info.torch_version -match "cu"

$spectrumInstalled = $customNodes -contains "ComfyUI-Spectrum-MiniMax-H3"
$kjInstalled = $customNodes -contains "ComfyUI-KJNodes"
$clipProjInstalled = $customNodes -contains "ComfyUI-ClipProj"

Write-Section "MiniMax H3 acceleration status"
Write-Result ("  Spectrum Apply MiniMax H3:  {0}  (~15% fewer transformer evals, AMD-safe)" -f ($(if ($spectrumInstalled) { "installed" } else { "NOT installed" })))
Write-Result ("  KJNodes (sage patches):    {0}  (needs CUDA for sage; other nodes still useful)" -f ($(if ($kjInstalled) { "installed" } else { "NOT installed" })))
Write-Result ("  ClipProj (small encoder):  {0}  (qwen3vl 4B fp8 + projection; frees ~11 GB VRAM)" -f ($(if ($clipProjInstalled) { "installed" } else { "NOT installed" })))
Write-Result ("  Turbo LoRA (8 steps):      {0}  (Abiray pruned; h3_workflow_turbo.json)" -f ($(if (Test-Path -LiteralPath $turboLora) { "present" } else { "missing" })))
if ($clipProjInstalled) {
    Write-Result ("    encoder/matrix:           {0} / {1}" -f ($(if (Test-Path -LiteralPath $smallEncoder) { "present" } else { "missing" })), ($(if (Test-Path -LiteralPath $clipProjMatrix) { "present" } else { "missing" })))
}
Write-Result ("  --use-ck-attention:        {0}  (comfy-kitchen attention; needs ComfyUI >= 0.33)" -f ($(if ($ckFlagSupported) { "supported" } else { "NOT in this ComfyUI build" })))
if ($ckFlagSupported -and $info.ck_attn -eq $true) {
    Write-Result "    int8 attention kernels:   available on this GPU (RDNA3 WMMA) -> LLAMADOCK_COMFY_PROFILE=ck"
}
if ($isNvidia) {
    Write-Result "  GPU is NVIDIA/CUDA: install sageattention wheel + use --use-sage-attention or the KJNodes sage patch (~2x)."
}
elseif ($isRocm) {
    Write-Result "  GPU is AMD/ROCm: SageAttention 2.x is CUDA-only; the practical AMD path is --use-ck-attention (>= 0.33) + Spectrum + launch flags."
    if ($info.gcn -and ($info.gcn -match "gfx11" -or $info.gcn -match "gfx12")) {
        if ($info.triton) {
            Write-Result "  triton is installed but known-crashy on this stack: do NOT use LLAMADOCK_COMFY_PROFILE=triton"
            Write-Result "  (see docs/MiniMax-H3-Tuning.md; the hip backend already covers INT8)."
        }
        else {
            Write-Result "  triton is missing: comfy-kitchen INT8 kernels still run on the hip backend (already active)."
            Write-Result "  triton-windows can be installed, but testing shows it crashes ComfyUI with"
            Write-Result "  --enable-triton-backend; keep the default profile (see docs/MiniMax-H3-Tuning.md)."
        }
    }
}

Write-Section "Recommended launch flags (llamadock default already applies these)"
Write-Result "  main.py --port 8188 --listen 127.0.0.1 --reserve-vram 1.0"
if ($ckFlagSupported -and $info.ck_attn -eq $true) {
    Write-Result "  Best on this stack: add --use-ck-attention (LLAMADOCK_COMFY_PROFILE=ck) -> Comfy Kitchen attention."
}
Write-Result "  Overrides: -ComfyUIFlags on select-model.ps1, or env LLAMADOCK_COMFY_FLAGS (exact args),"
Write-Result "  or LLAMADOCK_COMFY_PROFILE=fast|ck|triton|bench (see docs/MiniMax-H3-Tuning.md)."

if ($spectrumInstalled) {
    Write-Result "  Spectrum is available: h3_workflow_fast.json in the LlamaDock repo uses it."
}
else {
    Write-Result "  Install Spectrum (AMD-safe, ~15%) with: -InstallSpectrum; then h3_workflow_fast.json works."
}

if ($InstallSpectrum -or $InstallKJNodes) {
    Write-Section "Applying installs"
    $gitOk = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitOk) {
        Write-Host "ERROR: git is required for node installs" -ForegroundColor Red
        exit 1
    }
    if ($InstallSpectrum -and -not $spectrumInstalled) {
        Write-Result "Installing ComfyUI-Spectrum-MiniMax-H3 ..."
        Push-Location $customNodesDir
        try {
            git clone --depth 1 https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3.git 2>&1 | ForEach-Object { Write-Result "  $_" }
            if ($LASTEXITCODE -eq 0) {
                Write-Result "Spectrum installed. Restart ComfyUI; the node appears under sampling/spectrum." -Color Green
                $spectrumInstalled = $true
            }
            else {
                Write-Host "Spectrum clone failed." -ForegroundColor Red
            }
        }
        finally {
            Pop-Location
        }
    }
    elseif ($InstallSpectrum) {
        Write-Result "Spectrum already installed; nothing to do." -Color Yellow
    }
    if ($InstallKJNodes -and -not $kjInstalled) {
        Write-Result "Installing ComfyUI-KJNodes ..."
        Push-Location $customNodesDir
        try {
            git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git 2>&1 | ForEach-Object { Write-Result "  $_" }
            if ($LASTEXITCODE -eq 0) {
                Write-Result "KJNodes installed. Restart ComfyUI." -Color Green
                $kjInstalled = $true
            }
            else {
                Write-Host "KJNodes clone failed." -ForegroundColor Red
            }
        }
        finally {
            Pop-Location
        }
    }
    elseif ($InstallKJNodes) {
        Write-Result "KJNodes already installed; nothing to do." -Color Yellow
    }
}

exit 0
