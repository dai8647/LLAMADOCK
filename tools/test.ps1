param(
    [switch]$SkipDryRun,
    [switch]$RunUtf8Smoke
)

$root = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $root "select-model.ps1"
$notes = Join-Path $root "model-notes.json"
$openWebUIBootstrap = Join-Path $root "tools\open-webui-bootstrap.py"
$openWebUIStart = Join-Path $root "tools\open-webui-start.ps1"
$runtimeInventory = Join-Path $root "tools\runtime-inventory.ps1"
$benchScript = Join-Path $root "tools\llamadock-bench.ps1"
$utf8Helper = Join-Path $root "tools\llamadock-utf8.ps1"
$utf8Smoke = Join-Path $root "tools\utf8-smoke.py"
$utf8PowerShellSmoke = Join-Path $root "tools\utf8-powershell-smoke.ps1"
$clientShell = Join-Path $root "tools\llamadock-client-shell.ps1"
$gateway = Join-Path $root "tools\llamadock-proxy.mjs"
$supervisor = Join-Path $root "tools\llamadock-server-supervisor.ps1"
$profiles = Join-Path $root "config\profiles.json"

# Decode the launcher's dry-run output as UTF-8 regardless of the console
# codepage. The launcher dot-sources llamadock-utf8.ps1, so its stdout is
# UTF-8; PowerShell decodes native stdout with [Console]::OutputEncoding,
# which defaults to the ANSI codepage (932 on a JP-locale box) and turns the
# Japanese headings (ハードウェア構成: / ランタイム状態:) into mojibake that
# then fails the -notmatch assertions below. Test must not depend on whether
# the caller ran chcp 65001 first.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

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
    "LlamaAgentResearch",
    "PiCoding",
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

foreach ($path in @($openWebUIBootstrap, $openWebUIStart, $runtimeInventory, $benchScript, $utf8Helper, $utf8Smoke, $utf8PowerShellSmoke, $clientShell, $gateway, $supervisor, $profiles)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Required launcher file missing: $path" -ForegroundColor Red
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
    # The Python Open WebUI venv is a rollback-only path (Open WebUI Computer
    # was retired and replaced by the Pi agent workspace). A clean machine may
    # not have it; warn instead of blocking the whole suite.
    Write-Host "WARNING: Open WebUI package is not installed: $openWebUISite (legacy rollback only)." -ForegroundColor Yellow
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
foreach ($check in @("LlamaDock セッション", "モデルを維持したままワークスペースを変更", "モデルを変更 - サーバーを停止してセレクターへ戻る", "サーバーを起動したまま終了", "Open-WorkspaceClient", "Select-WorkspaceForSession")) {
    if ($launcherSource -notmatch [regex]::Escape($check)) {
        Write-Host "Managed session check failed: $check" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Managed session checks OK"
foreach ($check in @("Test-GatewayReady", "llamadock-server-supervisor", "--cache-ram", "--reasoning", "ClineCoding", "Code - Cline 向けの安定設定", "OpenCodeCoding", "Code - OpenCode 向けの安定設定", "プリセットを選択 (1-7)", "KV キャッシュ K 型:", "Flash Attention:", "サーバーコンソールを開きました", "Ctrl+C を押すと llama-server を停止")) {
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

# --- Read-MenuInt helper unit checks (piped stdin) ---
# Dry runs never enter the interactive menus, so the shared menu reader that
# every front-door prompt uses gets exercised here directly: extract the
# function from the launcher and drive it with scripted stdin lines.
$menuIntMatch = [regex]::Match($launcherSource, '(?s)function Read-MenuInt \{.*?\n\}')
if (-not $menuIntMatch.Success) {
    Write-Host "Read-MenuInt helper missing in launcher" -ForegroundColor Red
    exit 1
}
$menuIntUnit = Join-Path $env:TEMP "llamadock-menuint-unit.ps1"
$menuIntBody = @'
$src = [System.IO.File]::ReadAllText($env:MU_LAUNCHER, [System.Text.Encoding]::UTF8)
$fn = [regex]::Match($src, '(?s)function Read-MenuInt \{.*?\n\}')
if (-not $fn.Success) { throw "Read-MenuInt not found" }
Invoke-Expression $fn.Value
if ($env:MU_DEFAULT -ne "none") {
    Write-Output ("RESULT=" + (Read-MenuInt -Prompt "PROMPT" -Max ([int]$env:MU_MAX) -Min ([int]$env:MU_MIN) -Default ([int]$env:MU_DEFAULT)))
}
else {
    Write-Output ("RESULT=" + (Read-MenuInt -Prompt "PROMPT" -Max ([int]$env:MU_MAX) -Min ([int]$env:MU_MIN)))
}
'@
[System.IO.File]::WriteAllText($menuIntUnit, $menuIntBody, [System.Text.UTF8Encoding]::new($false))
$env:MU_LAUNCHER = $launcher
$menuIntCases = @(
    @{ Name = "valid input";        Lines = @("5");              Max = "7";           Min = "1"; Default = "1";    Expect = "RESULT=5" },
    @{ Name = "Enter = default";    Lines = @("");               Max = "7";           Min = "1"; Default = "3";    Expect = "RESULT=3" },
    @{ Name = "retry after junk";   Lines = @("abc", "99", "4"); Max = "7";           Min = "1"; Default = "1";    Expect = "RESULT=4" },
    @{ Name = "retry out of range"; Lines = @("0", "2");         Max = "7";           Min = "1"; Default = "1";    Expect = "RESULT=2" },
    @{ Name = "empty retries";      Lines = @("", "", "6");      Max = "7";           Min = "1"; Default = "none"; Expect = "RESULT=6" },
    @{ Name = "zero allowed";       Lines = @("0");              Max = "2147483647";  Min = "0"; Default = "none"; Expect = "RESULT=0" },
    @{ Name = "numeric default";    Lines = @("");               Max = "2147483647";  Min = "1"; Default = "1024"; Expect = "RESULT=1024" }
)
foreach ($case in $menuIntCases) {
    $env:MU_MAX = $case.Max
    $env:MU_MIN = $case.Min
    $env:MU_DEFAULT = $case.Default
    $unitOut = $case.Lines | & powershell -NoProfile -ExecutionPolicy Bypass -File $menuIntUnit 2>&1
    $got = ($unitOut | Select-String -Pattern "^RESULT=").Line
    if ($got -ne $case.Expect) {
        Write-Host "Read-MenuInt check failed: $($case.Name) (expected $($case.Expect), got [$($unitOut -join ' | ')])" -ForegroundColor Red
        Remove-Item -LiteralPath $menuIntUnit -ErrorAction SilentlyContinue
        exit 1
    }
}
Remove-Item -LiteralPath $menuIntUnit -ErrorAction SilentlyContinue
Remove-Item Env:\MU_LAUNCHER, Env:\MU_MAX, Env:\MU_MIN, Env:\MU_DEFAULT -ErrorAction SilentlyContinue
Write-Host "Read-MenuInt helper checks OK"

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

# --- Web GUI entry point checks ---
$webguiBat = Join-Path $root "webgui.bat"
if (-not (Test-Path -LiteralPath $webguiBat)) {
    Write-Host "Web GUI entry point missing: webgui.bat" -ForegroundColor Red
    exit 1
}
$webguiSource = Get-Content -LiteralPath $webguiBat -Raw
if ($webguiSource -notmatch [regex]::Escape("web-ui\server.js")) {
    Write-Host "webgui.bat does not launch web-ui\server.js" -ForegroundColor Red
    exit 1
}
if ($launcherSource -notmatch [regex]::Escape("Web GUI")) {
    Write-Host "Front-door menu is missing the Web GUI entry" -ForegroundColor Red
    exit 1
}
Write-Host "Web GUI entry checks OK"

# --- Web GUI engine-arg filter checks ---
# The GUI spawns llama-server directly with schema-driven argv and has no
# second chance: a flag this build rejects (-t auto, --spec-type off, an
# unknown --moe-* option) kills the process before it binds the port. The
# filter must stay wired in, and the engine list must not offer engines the
# GUI cannot spawn (Strata is served by python serve/server.py, launcher only).
$serverSource = Get-Content -LiteralPath (Join-Path $root "web-ui\server.js") -Raw
if ($serverSource -notmatch [regex]::Escape("filterUnsupportedArgs")) {
    Write-Host "web-ui/server.js does not filter engine-rejected args" -ForegroundColor Red
    exit 1
}
$schemaSource = Get-Content -LiteralPath (Join-Path $root "config\params-schema.json") -Raw
if ($schemaSource -match '"Strata"') {
    Write-Host "params-schema engine list offers Strata, which the web GUI cannot launch" -ForegroundColor Red
    exit 1
}
Write-Host "Web GUI engine filter checks OK"

function Get-SweepModelIndex {
    # Mirrors select-model.ps1's model enumeration (non-mmproj GGUFs under
    # ModelsBase, multi-part GGUFs merged into their first shard with summed
    # size, sorted TQ3-first then by size descending) and returns the 1-based
    # index of a model that fits the RAM/context guard for preset dry runs.
    # Hard-coded indices drift whenever models are added/removed on disk
    # (e.g. a new 80GB+ model shifting which file lands at index 3), and the
    # merge matters: without it a 37GB first shard of a 70GB split model wins
    # the "<40GB" pick and the dry run fails on an engine the box lacks.
    $modelsBase = $env:LLAMADOCK_MODELS_BASE
    if ([string]::IsNullOrWhiteSpace($modelsBase)) { $modelsBase = "C:\Users\dai86\.lmstudio\models" }
    $allFiles = @(
        Get-ChildItem -Path $modelsBase -Filter "*.gguf" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "mmproj" -and $_.Name -notmatch "(?i)(^|[\\/_. -])Hy3([\\/_. -]|$)|Hy[-_ ]?V3" -and $_.Name -notmatch "(?i)DSpark" }
    )
    $list = @()
    foreach ($f in $allFiles) {
        if ($f.Name -match "(?i)DFlash2") { continue }
        if ($f.Name -match "^(?<base>.+)-(?<idx>\d{5})-of-(?<total>\d{5})\.gguf$") {
            if ([int]$Matches.idx -ne 1) { continue }
            $basePattern = "^$([regex]::Escape($Matches.base))-\d{5}-of-$($Matches.total)\.gguf$"
            $siblings = @($allFiles | Where-Object { $_.Name -match $basePattern })
            $totalBytes = ($siblings | Measure-Object -Property Length -Sum).Sum
            $list += [PSCustomObject]@{
                Name = "$($Matches.base) [$($siblings.Count)-part GGUF]"
                SizeMB = [math]::Round($totalBytes / 1MB, 1)
                IsTQ3 = ($f.Name -match "TQ3")
            }
            continue
        }
        $list += [PSCustomObject]@{
            Name = $f.Name
            SizeMB = [math]::Round($f.Length / 1MB, 1)
            IsTQ3 = ($f.Name -match "TQ3")
        }
    }
    $list = @($list | Sort-Object -Property @{ Expression = "IsTQ3"; Descending = $true }, @{ Expression = "SizeMB"; Descending = $true })
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
                "-ClientMode", "Pi",
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
        if ($preset -eq "Manual" -and ($joined -notmatch "ハードウェア構成:" -or $joined -notmatch "ランタイム状態:")) {
            Write-Host "Advanced dry run did not show hardware/runtime diagnostics: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -in @("PiCoding", "OpenCodeCoding") -and $joined -notmatch "READY TO LAUNCH") {
            Write-Host "Quick launch did not show the compact launch card: $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -notin @("PiCoding", "OpenCodeCoding") -and $joined -notmatch "GPU オフロード見積り:") {
            Write-Host "Detailed dry run did not show VRAM/offload estimate: $preset" -ForegroundColor Red
            exit 1
        }
        if ($joined -notmatch "--no-ui") {
            Write-Host "llama-server UI was not disabled: $preset" -ForegroundColor Red
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
        # Auto context (select-model.ps1 ContextIndex 1) must respect the 64K cap.
        $ctxMatch = [regex]::Match($joined, '(?<![\w-])-c (\d+)')
        if (-not $ctxMatch.Success -or [int]$ctxMatch.Groups[1].Value -gt 65536) {
            $ctxValue = if ($ctxMatch.Success) { $ctxMatch.Groups[1].Value } else { "<missing>" }
            Write-Host "Auto context cap violated (-c $ctxValue, max 65536): $preset" -ForegroundColor Red
            exit 1
        }
        if ($preset -eq "PiCoding" -and $joined -notmatch "Coding -> Pi") {
            Write-Host "Pi preset did not show the quick-launch label: $preset" -ForegroundColor Red
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
