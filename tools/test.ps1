param(
    [switch]$SkipDryRun,
    [switch]$RunUtf8Smoke
)

$root = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $root "select-model.ps1"
$notes = Join-Path $root "model-notes.json"
$openWebUIBootstrap = Join-Path $root "tools\open-webui-bootstrap.py"
$openWebUIStart = Join-Path $root "tools\open-webui-start.ps1"
$computerStart = Join-Path $root "tools\computer-start.ps1"
$computerConfigure = Join-Path $root "tools\computer-configure-local.ps1"
$computerConfigurePy = Join-Path $root "tools\computer-configure-local.py"
$runtimeInventory = Join-Path $root "tools\runtime-inventory.ps1"
$benchScript = Join-Path $root "tools\llamadock-bench.ps1"
$utf8Helper = Join-Path $root "tools\llamadock-utf8.ps1"
$utf8Smoke = Join-Path $root "tools\utf8-smoke.py"
$utf8PowerShellSmoke = Join-Path $root "tools\utf8-powershell-smoke.ps1"
$clientShell = Join-Path $root "tools\llamadock-client-shell.ps1"
$gateway = Join-Path $root "tools\llamadock-proxy.mjs"
$supervisor = Join-Path $root "tools\llamadock-server-supervisor.ps1"
$profiles = Join-Path $root "config\profiles.json"

& (Join-Path $PSScriptRoot "check-style.ps1") -Path $launcher
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$modelNotes = Get-Content -LiteralPath $notes -Raw -Encoding UTF8 | ConvertFrom-Json
$profileData = Get-Content -LiteralPath $profiles -Raw -Encoding UTF8 | ConvertFrom-Json
if ($profileData.schema_version -ne 1 -or -not $profileData.profiles -or $profileData.policy.docker -ne $false -or $profileData.policy.wsl -ne $false) {
    Write-Host "profiles.json policy/schema check failed" -ForegroundColor Red
    exit 1
}
Write-Host "profiles.json OK"
$validPresets = @(
    "Manual",
    "ClineCoding",
    "OpenCodeCoding",
    "OpenClaudeCoding",
    "LlamaAgentResearch",
    "WebUIChat",
    "DeepSeekHarness"
)
foreach ($note in $modelNotes) {
    if ($note.recommended_preset -and $note.recommended_preset -notin $validPresets) {
        Write-Host "model-notes.json has an unknown recommended_preset: $($note.recommended_preset)" -ForegroundColor Red
        exit 1
    }
}
Write-Host "model-notes.json OK"

$nodeTools = @(
    (Join-Path $root "tools\web-research.mjs"),
    (Join-Path $root "tools\deep-research-harness.mjs"),
    (Join-Path $root "tools\mcp-smoke.mjs"),
    $gateway,
    (Join-Path $root "web-ui\server.js"),
    (Join-Path $root "web-ui\app.js"),
    (Join-Path $root "web-ui\arg-builder.js"),
    (Join-Path $root "web-ui\launch-manager.js"),
    (Join-Path $root "web-ui\results-store.js"),
    (Join-Path $root "web-ui\client-manager.js"),
    (Join-Path $root "web-ui\mock-llama-server.mjs")
)
foreach ($nodeTool in $nodeTools) {
    node --check $nodeTool | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Node syntax check failed: $nodeTool" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Node tools syntax OK"
$gatewaySource = Get-Content -LiteralPath $gateway -Raw -Encoding UTF8
foreach ($check in @("isClineToolSet", "compactClineTool", "original_tool_bytes", "client_disconnect", "expect")) {
    if ($gatewaySource -notmatch [regex]::Escape($check)) {
        Write-Host "LlamaDock gateway check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "LlamaDock gateway checks OK"

$secretPatterns = @(
    ("194" + "b059"),
    "sk-[A-Za-z0-9]{12,}",
    "github_pat_[A-Za-z0-9_]{20,}",
    "hf_[A-Za-z0-9]{20,}",
    "bearer\s+[A-Za-z0-9._-]{12,}"
)
$secretHits = @()
$scanFailed = $false
$rgCmd = Get-Command rg -ErrorAction SilentlyContinue
if ($rgCmd) {
    $secretHits = @(& $rgCmd.Source -n -i ($secretPatterns -join "|") $root -g "!data/**" -g "!logs/**" -g "!.git/**" -g "!node_modules/**" 2>$null)
    if ($LASTEXITCODE -gt 1) {
        $scanFailed = $true
    }
}
else {
    Write-Host "rg not found; using Select-String fallback for the secret scan." -ForegroundColor Yellow
    # Mirror rg defaults: skip node_modules and any hidden (dot-prefixed) path
    # segment.  Select-String does not skip hidden entries by itself.
    $scanFiles = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($root.Length)
            $rel -notmatch "\\(data|logs|node_modules)(\\|$)" -and
            $rel -notmatch "\\(\.[^\\/]+)(\\|$)" -and
            $_.Name -notmatch "^\.[^\\/]+"
        }
    $secretHits = @($scanFiles | Select-String -Pattern ($secretPatterns -join "|") -List -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.Path):$($_.LineNumber):$($_.Line.Trim())" })
}
if ($scanFailed) {
    Write-Host "Secret scan failed to run." -ForegroundColor Red
    exit 1
}
if ($secretHits.Count -gt 0) {
    Write-Host "Secret scan found suspicious values:" -ForegroundColor Red
    $secretHits
    exit 1
}
Write-Host "Secret scan OK"

foreach ($path in @($openWebUIBootstrap, $openWebUIStart, $computerStart, $computerConfigure, $computerConfigurePy, $runtimeInventory, $benchScript, $utf8Helper, $utf8Smoke, $utf8PowerShellSmoke, $clientShell, $gateway, $supervisor, $profiles)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Open WebUI launcher file missing: $path" -ForegroundColor Red
        exit 1
    }
}
$pythonCheck = & py -3.11 -c "compile(open(r'$openWebUIBootstrap', encoding='utf-8').read(), r'$openWebUIBootstrap', 'exec')" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Open WebUI bootstrap syntax check failed" -ForegroundColor Red
    $pythonCheck
    exit 1
}
$openWebUISite = Join-Path $root "mcp-data\open-webui-venv\Lib\site-packages"
if (Test-Path (Join-Path $openWebUISite "open_webui\__init__.py")) {
    Write-Host "Open WebUI files/package OK"
}
else {
    # The Python Open WebUI venv is a rollback-only path (the standard WebUI
    # entry is native Computer). A clean machine may not have it; warn instead
    # of blocking the whole suite.
    Write-Host "WARNING: Open WebUI package is not installed: $openWebUISite (rollback UI only; standard entry is Computer)." -ForegroundColor Yellow
}
$openWebUISource = Get-Content -LiteralPath $openWebUIBootstrap -Raw -Encoding UTF8
foreach ($check in @("OPENAI_API_BASE_URLS", "openai.api_base_urls", "recovery gateway")) {
    if ($openWebUISource -notmatch [regex]::Escape($check)) {
        Write-Host "Open WebUI endpoint sync check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Open WebUI endpoint sync OK"
$openWebUIStartSource = Get-Content -LiteralPath $openWebUIStart -Raw -Encoding UTF8
foreach ($check in @("ENABLE_SEARCH_QUERY_GENERATION", "explicit search uses the user's text")) {
    if ($openWebUIStartSource -notmatch [regex]::Escape($check)) {
        Write-Host "Open WebUI search fallback check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Open WebUI search fallback OK"
$utf8SmokeCheck = & py -3.11 -c "compile(open(r'$utf8Smoke', encoding='utf-8').read(), r'$utf8Smoke', 'exec')" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "UTF-8 smoke syntax check failed" -ForegroundColor Red
    $utf8SmokeCheck
    exit 1
}
$utf8Source = Get-Content -LiteralPath $utf8Helper -Raw -Encoding UTF8
foreach ($check in @("ByteArrayContent", "application/json", "charset", "Set-LlamaDockUtf8Environment")) {
    if ($utf8Source -notmatch [regex]::Escape($check)) {
        Write-Host "UTF-8 helper check failed: $check" -ForegroundColor Red
        exit 1
    }
}
if ($utf8Source -notmatch "PYTHONUTF8" -or $utf8Source -notmatch "PYTHONIOENCODING") {
    Write-Host "UTF-8 helper does not configure child CLI encoding" -ForegroundColor Red
    exit 1
}
Write-Host "UTF-8 transport files OK"
$computerPythonCheck = & py -3.11 -c "compile(open(r'$computerConfigurePy', encoding='utf-8').read(), r'$computerConfigurePy', 'exec')" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Computer configuration Python syntax check failed" -ForegroundColor Red
    $computerPythonCheck
    exit 1
}
Write-Host "Computer configuration files OK"
$utf8PowerShellSource = Get-Content -LiteralPath $utf8PowerShellSmoke -Raw -Encoding UTF8
try {
    [scriptblock]::Create($utf8PowerShellSource) | Out-Null
}
catch {
    Write-Host "PowerShell UTF-8 smoke syntax check failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host "PowerShell UTF-8 smoke syntax OK"
$clientShellSource = Get-Content -LiteralPath $clientShell -Raw -Encoding UTF8
try {
    [scriptblock]::Create($clientShellSource) | Out-Null
}
catch {
    Write-Host "Client UTF-8 shell syntax check failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host "Client UTF-8 shell syntax OK"
$supervisorSource = Get-Content -LiteralPath $supervisor -Raw -Encoding UTF8
try {
    [scriptblock]::Create($supervisorSource) | Out-Null
}
catch {
    Write-Host "LlamaDock supervisor syntax check failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Write-Host "LlamaDock supervisor syntax OK"
foreach ($check in @("WindowStyle Normal", "control surface", "finally", "AutoRestartServer", "automatic restart is disabled")) {
    if ($supervisorSource -notmatch [regex]::Escape($check)) {
        Write-Host "LlamaDock visible-console check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "LlamaDock visible-console checks OK"

# --- Gateway status endpoint checks ---
foreach ($check in @("/llamadock/status", "GATEWAY_STARTED_AT", "activeRequestCount", "computeFingerprint", "trackFingerprint", "possibleRetryLoops", "recordResult", "checkUpstreamHealth", "FINGERPRINT_MAX_ENTRIES", "upstreamOk", "possible_retry_loop")) {
    if ($gatewaySource -notmatch [regex]::Escape($check)) {
        Write-Host "Gateway status check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Gateway status endpoint checks OK"

# --- Supervisor circuit breaker checks ---
foreach ($check in @("CIRCUIT_BREAKER_WINDOW", "CIRCUIT_BREAKER_LIMIT", "Save-SupervisorStatus", "Get-BackoffDelay", "Test-CircuitBreaker", "Record-SupervisorEvent", "requested_restart", "unexpected_exit", "status.json", "breaker_open", "backoffSeconds", "PSCommandPath")) {
    if ($supervisorSource -notmatch [regex]::Escape($check)) {
        Write-Host "Supervisor circuit breaker check failed: $check" -ForegroundColor Red
        exit 1
    }
}
# Verify supervisor uses script: scope for breaker/backoff vars
foreach ($scriptVar in @('$script:restartCount', '$script:breakerOpen', '$script:backoffIndex', '$script:backoffSeconds', '$script:restartTimestamps', '$script:CIRCUIT_BREAKER_WINDOW', '$script:CIRCUIT_BREAKER_LIMIT')) {
    if ($supervisorSource -notmatch [regex]::Escape($scriptVar)) {
        Write-Host "Supervisor script-scope check failed: $scriptVar" -ForegroundColor Red
        exit 1
    }
}
# Verify supervisor does NOT reference unassigned $script:server or $script:gateway
# (live process objects are stored in script-scope $server/$gateway without qualifier)
if ($supervisorSource -match '\$script:server\b' -or $supervisorSource -match '\$script:gateway\b') {
    Write-Host "Supervisor must use `$server and `$gateway (not `$script:server/`$script:gateway) for live process objects" -ForegroundColor Red
    exit 1
}
Write-Host "Supervisor circuit breaker checks OK"

# --- Client shell harness removal check ---
foreach ($gone in @("-Harness", "harnessPath", "llamadock-opencode-harness.ps1", "harnessArgs")) {
    if ($clientShellSource -match [regex]::Escape($gone)) {
        Write-Host "Client shell still references the removed OpenCode harness: $gone" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Client shell harness references removed OK"
$launcherSource = Get-Content -LiteralPath $launcher -Raw -Encoding UTF8
foreach ($check in @("LlamaDock session", "モデルを維持したままワークスペースを変更", "モデルを変更 - サーバーを停止してセレクターへ戻る", "サーバーを起動したまま終了", "Open-WorkspaceClient", "Select-WorkspaceForSession")) {
    if ($launcherSource -notmatch [regex]::Escape($check)) {
        Write-Host "Managed session check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Managed session checks OK"
foreach ($check in @("Test-GatewayReady", "llamadock-server-supervisor", "--cache-ram", "--reasoning", "ClineCoding", "Code - Cline 向けの安定設定", "OpenCodeCoding", "Code - OpenCode 向けの安定設定", "OpenClaudeCoding", "Code - OpenClaude 向けの安定設定", "Select preset (1-7)", "KV cache K type:", "Flash Attention:", "server console opened", "Press Ctrl+C in that window")) {
    if ($launcherSource -notmatch [regex]::Escape($check)) {
        Write-Host "Launcher check failed: $check" -ForegroundColor Red
        exit 1
    }
}
if ($launcherSource -match "(?i)Hy3Rocm|Get-Hy3|LLAMADOCK_HY3|hy3-rocm") {
    Write-Host "Launcher still contains removed Hy3 integration" -ForegroundColor Red
    exit 1
}
foreach ($check in @("llamadock-client-shell.ps1", "CLINE_DATA_DIR", "CLINE_MCP_SETTINGS_PATH")) {
    if ($launcherSource -notmatch [regex]::Escape($check) -and (Get-Content -LiteralPath $clientShell -Raw -Encoding UTF8) -notmatch [regex]::Escape($check)) {
        Write-Host "Client UTF-8 shell check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Launcher checks OK"

# --- ComfyUI workspace checks ---
foreach ($check in @("Open-ComfyUIClient", "MiniMax-H3 native nodes", "MiniMaxH3ImageToVideo", "MiniMaxH3SigmaShift", "EmptyMiniMaxH3LatentAV", "comfyUrl", "8188", "$comfyUrl/system_stats", "$comfyUrl/object_info")) {
    if ($launcherSource -notmatch [regex]::Escape($check)) {
        Write-Host "ComfyUI workspace check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "ComfyUI workspace checks OK"

# ComfyUI branch must be reachable even when llama-server is already up
if ($launcherSource -notmatch '(?s)\$ExistingServerMode\s*-eq\s*"UseExisting".{0,2000}ClientMode\s*-eq\s*"ComfyUI"') {
    Write-Host "ComfyUI UseExisting branch missing in launcher" -ForegroundColor Red
    exit 1
}
Write-Host "ComfyUI UseExisting branch OK"

function Get-SweepModelIndex {
    # Mirrors select-model.ps1's model enumeration (non-mmproj GGUFs under
    # ModelsBase, sorted TQ3-first then by size descending) and returns the
    # 1-based index of a model that fits the RAM/context guard for preset dry
    # runs. Hard-coded indices drift whenever models are added/removed on disk
    # (e.g. a new 80GB+ model shifting which file lands at index 3).
    $modelsBase = $env:LLAMADOCK_MODELS_BASE
    if ([string]::IsNullOrWhiteSpace($modelsBase)) { $modelsBase = "C:\Users\dai86\.lmstudio\models" }
    $list = @(
        Get-ChildItem -Path $modelsBase -Filter "*.gguf" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "mmproj" } |
            ForEach-Object {
                [PSCustomObject]@{
                    Name = $_.Name
                    SizeMB = [math]::Round($_.Length / 1MB, 1)
                    IsTQ3 = ($_.Name -match "TQ3")
                }
            } |
            Sort-Object -Property @{ Expression = "IsTQ3"; Descending = $true }, @{ Expression = "SizeMB"; Descending = $true }
    )
    if ($list.Count -eq 0) { return 1 }
    # Prefer the largest model under 40GB: big enough to exercise the engine
    # routing, small enough that the launcher's "context exceeds RAM" guard
    # never hard-exits the dry run. Fall back to the smallest model.
    $candidates = @($list | Where-Object { $_.SizeMB -lt 40960 })
    if ($candidates.Count -eq 0) { $candidates = @($list) }
    $names = @($list | Select-Object -ExpandProperty Name)
    return [array]::IndexOf($names, $candidates[0].Name) + 1
}

if (-not $SkipDryRun) {
    $presets = $validPresets

    foreach ($preset in $presets) {
        $modelIndex = Get-SweepModelIndex
        $kIndex = 1
        $vIndex = 6

        $extra = @()
        if ($preset -eq "Manual") {
            $extra = @(
                "-ClientMode", "WebUI",
                "-ContextIndex", "1",
                "-OffloadMode", "Auto",
                "-MoeExpertsMode", "Auto",
                "-FlashAttentionMode", "On",
                "-SpecMode", "Off",
                "-McpMode", "None"
            )
        }

        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -DryRun -PresetMode $preset -ModelIndex $modelIndex -KCacheIndex $kIndex -VCacheIndex $vIndex -ExistingServerMode Quit @extra 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Dry run failed: $preset" -ForegroundColor Red
            $out | Select-Object -Last 80
            exit 1
        }

        $joined = $out -join "`n"
        if ($joined -notmatch "DRY RUN: llama-server would start with:") {
            Write-Host "Dry run did not produce command: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "Manual" -and ($joined -notmatch "Hardware estimate:" -or $joined -notmatch "Runtime availability:")) {
            Write-Host "Advanced dry run did not show hardware/runtime diagnostics: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -in @("WebUIChat", "OpenCodeCoding") -and $joined -notmatch "READY TO LAUNCH") {
            Write-Host "Quick launch did not show the compact launch card: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -notin @("WebUIChat", "OpenCodeCoding") -and $joined -notmatch "GPU offload estimate:") {
            Write-Host "Detailed dry run did not show VRAM/offload estimate: $preset" -ForegroundColor Red
            exit 1
        }
        if ($joined -notmatch "--no-ui" -and $joined -notmatch "Engine: LongCat") {
            Write-Host "llama-server UI was not disabled: $preset" -ForegroundColor Red
            exit 1
        }
        if ($joined -match "--no-ui" -and $joined -match "Engine: LongCat") {
            Write-Host "LongCat must not receive --no-ui (fork server rejects it): $preset" -ForegroundColor Red
            exit 1
        }
        if ($joined -notmatch "-ngl auto") {
            Write-Host "Auto GPU offload did not reach llama-server: $preset" -ForegroundColor Red
            exit 1
        }
        if ($joined -match "--no-warmup") {
            Write-Host "Deprecated no-warmup flag still present: $preset" -ForegroundColor Red
            exit 1
        }
        if ($joined -notmatch "--cache-ram") {
            Write-Host "Explicit prompt-cache RAM flag missing: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "WebUIChat" -and $joined -notmatch "native Computer") {
            Write-Host "WebUI preset did not identify native Computer: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "LlamaAgentResearch" -and $joined -notmatch 'LLAMA_ARG_CHAT_TEMPLATE_KWARGS=\{"enable_thinking":false\}') {
            Write-Host "LlamaAgent preset did not disable thinking: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "OpenCodeCoding" -and $joined -notmatch "llamadock/") {
            Write-Host "OpenCode preset did not pass the selected model." -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "OpenClaudeCoding" -and $joined -notmatch "OPENAI_BASE_URL=http://127.0.0.1:8090/v1") {
            Write-Host "OpenClaude preset did not pass the local endpoint." -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "DeepSeekHarness" -and $joined -notmatch "DEEPSEEK_BASE_URL=http://127.0.0.1:8090/v1") {
            Write-Host "DeepSeekHarness preset did not pass the local endpoint." -ForegroundColor Red
            exit 1
        }

        Write-Host "Dry run OK: $preset"
    }

    # ComfyUI does not consume the selected llama model, so it has its own
    # dry-run path that does not emit llama-server command lines.
    $comfyDryRun = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -DryRun -ClientMode ComfyUI -ExistingServerMode Quit 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ComfyUI dry run failed." -ForegroundColor Red
        $comfyDryRun | Select-Object -Last 40
        exit 1
    }
    $comfyJoined = $comfyDryRun -join "`n"
    if ($comfyJoined -notmatch "DRY RUN: ComfyUI would start on http" -or $comfyJoined -notmatch "8188") {
        Write-Host "ComfyUI dry run did not show its launch message." -ForegroundColor Red
        $comfyDryRun | Select-Object -Last 40
        exit 1
    }
    Write-Host "ComfyUI dry run OK"
}

if ($RunUtf8Smoke) {
    Write-Host "Running live UTF-8 smoke tests against the current local model server..." -ForegroundColor Cyan
    $utf8SmokeOutput = & py -3 $utf8Smoke --output-path (Join-Path $root "mcp-data\utf8-smoke-results.jsonl") 2>&1
    $utf8SmokeOutput
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Live UTF-8 smoke test failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Running the Windows PowerShell 5.1 byte-boundary smoke tests..." -ForegroundColor Cyan
    $utf8PowerShellOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $utf8PowerShellSmoke 2>&1
    $utf8PowerShellOutput
    if ($LASTEXITCODE -ne 0) {
        Write-Host "PowerShell UTF-8 smoke test failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host "All launcher tests OK"
