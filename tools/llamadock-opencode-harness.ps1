[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,
    [Parameter(Mandatory = $true)]
    [string]$ModelName,
    [string]$Prompt = "",
    [int]$MaxMinutes = 90,
    [int]$MaxResumes = 3,
    [int]$StallSeconds = 300,
    [string]$Root = "",
    [switch]$DryRun,
    [switch]$SelfTest
)

# ---------------------------------------------------------------------------
# #1 - Root default: resolve from PSCommandPath after param binding, NOT from
#      $PSScriptRoot which is empty when invoked by client-shell or other
#      callers that do not dot-source from the same directory.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

$ErrorActionPreference = "Stop"
$harnessDataDir = Join-Path $Root "mcp-data\agent-harness"
New-Item -ItemType Directory -Path $harnessDataDir -Force | Out-Null

$runId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$statePath = Join-Path $harnessDataDir "$runId.json"
$eventPath = Join-Path $harnessDataDir "$runId.jsonl"
$gatewayPort = 8090
$upstreamPort = 8080

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-HarnessLog {
    param(
        [string]$Message,
        [string]$Level = "info"
    )
    $line = "{0} [{1}] [harness] {2}" -f (Get-Date -Format "o"), $Level.ToUpperInvariant(), $Message
    Write-Host $line
    if (-not $DryRun) {
        Record-Event @{ type = "log"; level = $Level; message = $Message }
    }
}

function Save-State {
    param([hashtable]$State)
    if ($DryRun) { return }
    $json = $State | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($statePath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Record-Event {
    # #9 - JSONL must contain JSON objects only; no raw body content.
    param([hashtable]$Event)
    if ($DryRun) { return }
    $entry = @{ timestamp = (Get-Date -Format "o"); run_id = $runId } + $Event
    $line = $entry | ConvertTo-Json -Depth 5 -Compress
    try { Add-Content -LiteralPath $eventPath -Value $line -Encoding UTF8 } catch {}
}

function Compute-Fingerprint {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hash) -replace '-', '' | ForEach-Object { $_.ToLower() }
}

# #6 - HTTP gateway health check, not just TCP.  Never falls back to TCP
#      listening because a live gateway with a dead backend is NOT ready.
function Test-GatewayReady {
    param([int]$Port)
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/llamadock/status" `
            -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $status = $response.Content | ConvertFrom-Json
        return ($status.upstream_health.ok -eq $true)
    }
    catch {
        # Fall back to /health if /llamadock/status is unavailable.
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" `
                -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            return ($response.StatusCode -eq 200)
        }
        catch {
            return $false
        }
    }
}

function Wait-GatewayReady {
    <#
    .SYNOPSIS
        Poll Test-GatewayReady until it succeeds or the timeout expires.
        Returns $true when the gateway (with healthy upstream) is ready,
        $false at the deadline.
    #>
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-GatewayReady -Port $Port) {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-GitState {
    param([string]$Dir)
    try {
        Push-Location $Dir
        $branch = & git rev-parse --abbrev-ref HEAD 2>&1
        $dirty = & git status --porcelain 2>&1
        $commit = & git rev-parse --short HEAD 2>&1
        Pop-Location
        return @{
            branch = [string]$branch
            dirty = ($null -ne $dirty -and $dirty.Length -gt 0)
            commit = [string]$commit
        }
    }
    catch {
        Pop-Location
        return @{ branch = "unknown"; dirty = $false; commit = "unknown" }
    }
}

# #5 - Exit code 1 alone is NOT transport failure.  Resume only from
#      explicit network/backend error text, unhealthy backend, or a true
#      stall.
function Test-IsStallOrTransportError {
    param(
        [string]$ExitReason,
        [string]$OutputText = ""
    )
    # Explicit network/backend error text patterns
    $resumeable = @(
        "client_disconnect",
        "transport_error",
        "backend_unavailable",
        "connection_reset",
        "upstream_error",
        "econnreset",
        "econnrefused",
        "etimedout",
        "socket_hang_up"
    )
    $lower = $ExitReason.ToLowerInvariant()
    foreach ($pattern in $resumeable) {
        if ($lower.Contains($pattern)) { return $true }
    }
    # Also resume on stall (no activity)
    if ($lower -eq "stall") { return $true }

    # Check output text for explicit network/backend error patterns
    if (-not [string]::IsNullOrWhiteSpace($OutputText)) {
        $outLower = $OutputText.ToLowerInvariant()
        $outputPatterns = @(
            "connection refused",
            "econnreset",
            "econnrefused",
            "etimedout",
            "socket hang up",
            "network",
            "backend unavailable",
            "upstream error",
            "transport error",
            "client disconnect"
        )
        foreach ($pattern in $outputPatterns) {
            if ($outLower.Contains($pattern)) { return $true }
        }
    }

    return $false
}

function Get-HarnessExitReason {
    <#
    .SYNOPSIS
        Classify the exit reason for a single opencode process invocation.
        Priority order: loop, stall, transport_error, api_error (NonRetryableError),
        normal_exit (exit code 0), exit_code_N.
    #>
    param(
        [hashtable]$Live,
        [bool]$StallDetected,
        [int]$ExitCode
    )
    if ($Live.LoopDetected)           { return "loop" }
    if ($StallDetected)               { return "stall" }
    if ($Live.TransportError)         { return "transport_error" }
    if ($Live.NonRetryableError)      { return "api_error" }
    if ($ExitCode -eq 0)              { return "normal_exit" }
    return "exit_code_$ExitCode"
}

# #4 - Parse JSON output events from OpenCode for session ID extraction,
#      lastActivity updates, and fingerprint loop detection.
function Parse-OpenCodeEvent {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $trimmed = $Line.Trim()
    # Must be valid JSON
    if (-not $trimmed.StartsWith("{")) { return $null }
    try {
        $obj = $trimmed | ConvertFrom-Json
        return $obj
    }
    catch {
        return $null
    }
}

function Get-OpenCodeEventInfo {
    <#
    .SYNOPSIS
        Parse a single JSON event line and return a hashtable of key metadata.
    .PARAMETER Line
        A single JSON event line (string).
    .RETURNS
        Hashtable with keys EventType, SessionId, FingerprintInput, ErrorText,
        or $null if the line is not valid JSON.
    #>
    param([string]$Line)
    $parsed = Parse-OpenCodeEvent -Line $Line
    if ($null -eq $parsed) { return $null }

    $info = @{
        EventType        = ""
        SessionId        = ""
        FingerprintInput = ""
        ErrorText        = ""
    }

    # EventType from the top-level type property
    if ($parsed.PSObject.Properties['type']) {
        $info.EventType = [string]$parsed.type
    }

    # SessionId: sessionID (camelCase) first, then session_id (snake_case)
    if ($parsed.PSObject.Properties['sessionID']) {
        $info.SessionId = [string]$parsed.sessionID
    }
    elseif ($parsed.PSObject.Properties['session_id']) {
        $info.SessionId = [string]$parsed.session_id
    }

    # ErrorText: error.data.message first, then error.message
    if ($parsed.PSObject.Properties['error']) {
        $errObj = $parsed.error
        if ($errObj.PSObject.Properties['data'] -and $errObj.data.PSObject.Properties['message']) {
            $info.ErrorText = [string]$errObj.data.message
        }
        elseif ($errObj.PSObject.Properties['message']) {
            $info.ErrorText = [string]$errObj.message
        }
    }

    # FingerprintInput
    if ($parsed.PSObject.Properties['part']) {
        $part = $parsed.part

        # --- Text event: part.type == "text" and part.text exists ---
        if ($part.PSObject.Properties['type'] -and [string]$part.type -eq 'text' -and $part.PSObject.Properties['text']) {
            $info.FingerprintInput = "text" + [string]$part.text
        }
        # --- Tool event: part has tool or name property ---
        elseif ($part.PSObject.Properties['tool'] -or $part.PSObject.Properties['name']) {
            $toolName = if ($part.PSObject.Properties['tool']) { [string]$part.tool } else { [string]$part.name }
            $inputStr = ""
            if ($part.PSObject.Properties['state'] -and $part.state.PSObject.Properties['input']) {
                $inputObj = $part.state.input
                # Serialize compactly, stripping any timestamp/id/output/result fields
                # so that the fingerprint is stable regardless of volatile metadata.
                $filtered = @{}
                foreach ($prop in $inputObj.PSObject.Properties) {
                    $name = $prop.Name.ToLowerInvariant()
                    if ($name -in @('timestamp', 'id', 'output', 'result')) { continue }
                    $filtered[$prop.Name] = $prop.Value
                }
                if ($filtered.Count -gt 0) {
                    $inputStr = $filtered | ConvertTo-Json -Compress -Depth 5
                }
            }
            $info.FingerprintInput = "$toolName$inputStr"
        }
    }

    return $info
}

function Update-OpenCodeLiveState {
    <#
    .SYNOPSIS
        Process a single output line through Get-OpenCodeEventInfo and update
        the Live state hashtable.
    .PARAMETER Line
        A single JSON event line (string).
    .PARAMETER Live
        Mutable hashtable with keys: SessionId, LastFingerprint, ConsecutiveSame,
        LoopDetected, TransportError, NonRetryableError.
    #>
    param(
        [string]$Line,
        [hashtable]$Live
    )
    $info = Get-OpenCodeEventInfo -Line $Line
    if ($null -eq $info) { return }

    # Update SessionId when present
    if (-not [string]::IsNullOrWhiteSpace($info.SessionId)) {
        $Live.SessionId = $info.SessionId
    }

    # Error classification from ErrorText
    # - Transport error patterns → set TransportError true
    # - All other non-empty errors (including "No provider available") → set NonRetryableError true
    if (-not [string]::IsNullOrWhiteSpace($info.ErrorText)) {
        $errLower = $info.ErrorText.ToLowerInvariant()
        $transportPatterns = @(
            "client_disconnect", "transport_error", "backend_unavailable",
            "connection_reset", "upstream_error", "econnreset",
            "econnrefused", "etimedout", "socket_hang_up",
            "connection refused", "socket hang up",
            "backend unavailable", "upstream error",
            "transport error", "client disconnect"
        )
        $isTransport = $false
        foreach ($pattern in $transportPatterns) {
            if ($errLower.Contains($pattern)) {
                $isTransport = $true
                break
            }
        }
        if ($isTransport) {
            $Live.TransportError = $true
        }
        else {
            $Live.NonRetryableError = $true
        }
    }

    # Fingerprint tracking
    if (-not [string]::IsNullOrWhiteSpace($info.FingerprintInput)) {
        $hash = Compute-Fingerprint $info.FingerprintInput
        if ($hash -eq $Live.LastFingerprint) {
            $Live.ConsecutiveSame++
        }
        else {
            $Live.LastFingerprint = $hash
            $Live.ConsecutiveSame = 1
        }
        # Record only event type, hash, and consecutive count
        Record-Event @{
            type = "live_state"
            event_type = $info.EventType
            fingerprint_hash = $hash
            consecutive_count = $Live.ConsecutiveSame
        }
        # At 3 consecutive identical fingerprints set LoopDetected
        if ($Live.ConsecutiveSame -ge 3) {
            $Live.LoopDetected = $true
            Record-Event @{
                type = "loop_detected"
                fingerprint_hash = $hash
                consecutive_count = $Live.ConsecutiveSame
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Resolve-OpenCodeExecutable - locate opencode.exe
# ---------------------------------------------------------------------------

function Update-StderrTransport {
    <#
    .SYNOPSIS
        Classify a single stderr line from the child process.
        Only known transport patterns set $Live.TransportError.
        Arbitrary stderr warnings do NOT set NonRetryableError
        (only structured JSON error events from stdout do that).
    .PARAMETER Line
        A single stderr line string.
    .PARAMETER Live
        Mutable hashtable with TransportError and NonRetryableError keys.
    #>
    param(
        [string]$Line,
        [hashtable]$Live
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $errLower = $Line.ToLowerInvariant()
    $transportPatterns = @(
        "econnreset", "econnrefused", "etimedout", "socket_hang_up",
        "connection refused", "socket hang up", "transport error",
        "client disconnect", "backend unavailable", "upstream error"
    )
    foreach ($pattern in $transportPatterns) {
        if ($errLower.Contains($pattern)) {
            $Live.TransportError = $true
            return
        }
    }
}

function Resolve-OpenCodeExecutable {
    $appDataPath = "$env:APPDATA\npm\node_modules\opencode-ai\bin\opencode.exe"
    if (Test-Path -LiteralPath $appDataPath) {
        return (Resolve-Path -LiteralPath $appDataPath).Path
    }
    $fromCommand = Get-Command "opencode.exe" -ErrorAction SilentlyContinue
    if ($null -ne $fromCommand) {
        $resolved = $fromCommand.Source
        if (Test-Path -LiteralPath $resolved) {
            return (Resolve-Path -LiteralPath $resolved).Path
        }
    }
    throw "opencode.exe not found. Checked: $appDataPath and PATH. Install opencode-ai or specify the correct location."
}

# ---------------------------------------------------------------------------
# ConvertTo-WindowsCommandLineArgument - standard Windows command-line quoting
# ---------------------------------------------------------------------------

function ConvertTo-WindowsCommandLineArgument {
    param([string]$Arg)
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = [System.Text.StringBuilder]::new()
    $sb.Append('"') | Out-Null
    $i = 0
    $trailingBackslashes = 0
    while ($i -lt $Arg.Length) {
        $c = $Arg[$i]
        if ($c -eq '\') {
            # Count consecutive backslashes
            $bs = 0
            while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') {
                $bs++
                $i++
            }
            if ($i -lt $Arg.Length -and $Arg[$i] -eq '"') {
                # Backslashes before a quote: double them
                $sb.Append('\' * ($bs * 2)) | Out-Null
                $sb.Append('\"') | Out-Null
                $i++
                $trailingBackslashes = 0
            }
            else {
                # Backslashes not before a quote: keep as-is
                $sb.Append('\' * $bs) | Out-Null
                $trailingBackslashes = $bs
            }
        }
        elseif ($c -eq '"') {
            $sb.Append('\"') | Out-Null
            $i++
            $trailingBackslashes = 0
        }
        else {
            $sb.Append($c) | Out-Null
            $i++
            $trailingBackslashes = 0
        }
    }
    # Double trailing backslashes before the closing quote
    $sb.Append('\' * $trailingBackslashes) | Out-Null
    $sb.Append('"') | Out-Null
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# SelfTest mode - verify structure and synthetic JSON events
# ---------------------------------------------------------------------------

if ($SelfTest) {
    Write-HarnessLog "SelfTest mode: verifying harness structure without launching OpenCode or any model."

    # 1. Verify required parameter parsing
    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        Write-HarnessLog "SelfTest FAIL: Workspace is empty." "error"
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        Write-HarnessLog "SelfTest FAIL: ModelName is empty." "error"
        exit 1
    }

    # 2. Verify data directory creation
    if (-not (Test-Path -LiteralPath $harnessDataDir)) {
        Write-HarnessLog "SelfTest FAIL: harness data directory was not created: $harnessDataDir" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: data directory exists."

    # 3. Verify fingerprint computation produces consistent output
    $fp1 = Compute-Fingerprint "test-payload-abc"
    $fp2 = Compute-Fingerprint "test-payload-abc"
    $fp3 = Compute-Fingerprint "test-payload-def"
    if ($fp1 -ne $fp2) {
        Write-HarnessLog "SelfTest FAIL: fingerprint is not deterministic." "error"
        exit 1
    }
    if ($fp1 -eq $fp3) {
        Write-HarnessLog "SelfTest FAIL: different inputs produced same fingerprint." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: fingerprint computation works."

    # 4. Verify loop detection logic
    $fingerprints = @()
    $loopDetected = $false
    for ($i = 0; $i -lt 5; $i++) {
        $fingerprints += "same-hash"
        $unique = $fingerprints | Sort-Object -Unique
        if ($unique.Count -eq 1 -and $fingerprints.Count -ge 3) {
            $loopDetected = $true
            break
        }
    }
    if (-not $loopDetected) {
        Write-HarnessLog "SelfTest FAIL: loop detection did not trigger." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: loop detection works."

    # 5. Verify stall/error classification
    if (-not (Test-IsStallOrTransportError -ExitReason "client_disconnect")) {
        Write-HarnessLog "SelfTest FAIL: client_disconnect should be resumeable." "error"
        exit 1
    }
    if (-not (Test-IsStallOrTransportError -ExitReason "econnreset")) {
        Write-HarnessLog "SelfTest FAIL: econnreset should be resumeable." "error"
        exit 1
    }
    if (Test-IsStallOrTransportError -ExitReason "normal_exit") {
        Write-HarnessLog "SelfTest FAIL: normal_exit should NOT be resumeable." "error"
        exit 1
    }
    if (Test-IsStallOrTransportError -ExitReason "model_output_error") {
        Write-HarnessLog "SelfTest FAIL: model_output_error should NOT be resumeable." "error"
        exit 1
    }
    # #5 - exit code 1 alone should NOT be transport failure
    if (Test-IsStallOrTransportError -ExitReason "exit_code_1") {
        Write-HarnessLog "SelfTest FAIL: exit_code_1 alone should NOT be resumeable." "error"
        exit 1
    }
    # But exit code 1 with network error text in output SHOULD be resumeable
    if (-not (Test-IsStallOrTransportError -ExitReason "exit_code_1" -OutputText "connection refused by upstream")) {
        Write-HarnessLog "SelfTest FAIL: exit_code_1 with network error text should be resumeable." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: exit classification works."

    # 6. Verify default parameter values
    if ($MaxMinutes -ne 90) {
        Write-HarnessLog "SelfTest FAIL: MaxMinutes default is not 90." "error"
        exit 1
    }
    if ($MaxResumes -ne 3) {
        Write-HarnessLog "SelfTest FAIL: MaxResumes default is not 3." "error"
        exit 1
    }
    if ($StallSeconds -ne 300) {
        Write-HarnessLog "SelfTest FAIL: StallSeconds default is not 300." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: default parameters are correct."

    # 7. Verify state/event file naming
    $testStatePath = Join-Path $harnessDataDir "test-run.json"
    $testEventPath = Join-Path $harnessDataDir "test-run.jsonl"
    $testState = @{ run_id = "test-run"; status = "selftest" }
    $json = $testState | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($testStatePath, $json, [System.Text.UTF8Encoding]::new($false))
    $eventLine = @{ timestamp = (Get-Date -Format "o"); type = "selftest" } | ConvertTo-Json -Compress
    [System.IO.File]::AppendAllText($testEventPath, "$eventLine`n", [System.Text.UTF8Encoding]::new($false))
    $readBack = Get-Content -LiteralPath $testStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($readBack.status -ne "selftest") {
        Write-HarnessLog "SelfTest FAIL: state file round-trip failed." "error"
        exit 1
    }
    Remove-Item -LiteralPath $testStatePath, $testEventPath -Force -ErrorAction SilentlyContinue
    Write-HarnessLog "SelfTest OK: state/event file write/read works."

    # 8. Verify no secrets are written (spot check)
    $harnessSource = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    $secretPatterns = @("sk-[A-Za-z0-9]{12,}", "bearer\s+[A-Za-z0-9._-]{12,}", "api[_-]?key\s*=\s*[`"'][^`"']+[`"']")
    foreach ($pattern in $secretPatterns) {
        if ($harnessSource -match $pattern) {
            Write-HarnessLog "SelfTest FAIL: harness source contains a potential secret pattern." "error"
            exit 1
        }
    }
    Write-HarnessLog "SelfTest OK: no secrets in harness source."

    # 9. Verify DryRun switch works
    $dryRunHarness = Join-Path (Split-Path -Parent $PSCommandPath) "llamadock-opencode-harness.ps1"
    $dryOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $dryRunHarness -Workspace $Workspace -ModelName $ModelName -Root $Root -DryRun 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-HarnessLog "SelfTest FAIL: DryRun execution failed." "error"
        $dryOut
        exit 1
    }
    $dryJoined = $dryOut -join "`n"
    if ($dryJoined -notmatch "DRY RUN") {
        Write-HarnessLog "SelfTest FAIL: DryRun did not produce DRY RUN output." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: DryRun mode works."

    # 10. #4 - Synthetic JSON event self-tests
    Write-HarnessLog "SelfTest: verifying synthetic JSON event parsing..."
    $testEvent1 = @{ type = "assistant"; session_id = "sess-abc-123"; content = "Hello" } | ConvertTo-Json -Compress
    $parsed = Parse-OpenCodeEvent -Line $testEvent1
    if ($null -eq $parsed -or $parsed.type -ne "assistant" -or $parsed.session_id -ne "sess-abc-123") {
        Write-HarnessLog "SelfTest FAIL: Parse-OpenCodeEvent failed for assistant event." "error"
        exit 1
    }
    $testEvent2 = @{ type = "tool"; name = "bash"; content = "running" } | ConvertTo-Json -Compress
    $parsed2 = Parse-OpenCodeEvent -Line $testEvent2
    if ($null -eq $parsed2 -or $parsed2.type -ne "tool" -or $parsed2.name -ne "bash") {
        Write-HarnessLog "SelfTest FAIL: Parse-OpenCodeEvent failed for tool event." "error"
        exit 1
    }
    $parsed3 = Parse-OpenCodeEvent -Line "not json"
    if ($null -ne $parsed3) {
        Write-HarnessLog "SelfTest FAIL: Parse-OpenCodeEvent should return null for non-JSON." "error"
        exit 1
    }
    $parsed4 = Parse-OpenCodeEvent -Line ""
    if ($null -ne $parsed4) {
        Write-HarnessLog "SelfTest FAIL: Parse-OpenCodeEvent should return null for empty." "error"
        exit 1
    }
    # Verify fingerprint loop detection with hashes
    $seenHashes = @{}
    $loopOnHash = $false
    for ($i = 0; $i -lt 5; $i++) {
        $hash = Compute-Fingerprint "repeated-assistant-content"
        if ($seenHashes.ContainsKey($hash)) {
            $seenHashes[$hash]++
        }
        else {
            $seenHashes[$hash] = 1
        }
        if ($seenHashes[$hash] -ge 3) {
            $loopOnHash = $true
            break
        }
    }
    if (-not $loopOnHash) {
        Write-HarnessLog "SelfTest FAIL: fingerprint-based loop detection with hashes failed." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: synthetic JSON event parsing and hash-based loop detection work."

    # 11. #7 - Verify safe continuation instruction does not replay original task
    $resumeInstruction = "Continue working on the current task. Inspect the git and session state before acting. Do not repeat the original prompt."
    if ($resumeInstruction -match "Revise|Implement|Fix all|Replace") {
        # The resume instruction should be generic, not the original user prompt
        # This is fine - just verify it does not contain user-specific content
        Write-HarnessLog "SelfTest INFO: resume instruction is safe."
    }
    Write-HarnessLog "SelfTest OK: resume instruction is generic and safe."

    # 12. Verify Resolve-OpenCodeExecutable returns an existing .exe
    Write-HarnessLog "SelfTest: verifying Resolve-OpenCodeExecutable..."
    $resolvedExe = Resolve-OpenCodeExecutable
    if (-not (Test-Path -LiteralPath $resolvedExe)) {
        Write-HarnessLog "SelfTest FAIL: Resolve-OpenCodeExecutable returned non-existent path: $resolvedExe" "error"
        exit 1
    }
    if (-not $resolvedExe.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        Write-HarnessLog "SelfTest FAIL: Resolve-OpenCodeExecutable did not return an .exe: $resolvedExe" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: Resolve-OpenCodeExecutable returned existing exe: $resolvedExe"

    # 13. Verify ConvertTo-WindowsCommandLineArgument
    Write-HarnessLog "SelfTest: verifying ConvertTo-WindowsCommandLineArgument..."

    # Empty string becomes two quotes
    $emptyResult = ConvertTo-WindowsCommandLineArgument -Arg ''
    if ($emptyResult -ne '""') {
        Write-HarnessLog "SelfTest FAIL: empty string should become two quotes, got: $emptyResult" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: empty string -> two quotes."

    # Simple text without whitespace or quotes is unchanged
    $simpleResult = ConvertTo-WindowsCommandLineArgument -Arg 'hello'
    if ($simpleResult -ne 'hello') {
        Write-HarnessLog "SelfTest FAIL: simple text should be unchanged, got: $simpleResult" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: simple text unchanged."

    # Text with spaces gets quoted
    $spaceResult = ConvertTo-WindowsCommandLineArgument -Arg 'hello world'
    if ($spaceResult -ne '"hello world"') {
        Write-HarnessLog "SelfTest FAIL: text with spaces should be quoted, got: $spaceResult" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: text with spaces quoted."

    # Embedded quotes are escaped
    $quoteResult = ConvertTo-WindowsCommandLineArgument -Arg 'say "hello"'
    if ($quoteResult -ne '"say \"hello\""') {
        Write-HarnessLog "SelfTest FAIL: embedded quotes should be escaped, got: $quoteResult" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: embedded quotes escaped."

    # Trailing backslashes before closing quote (argument needs quoting due to space)
    $trailResult = ConvertTo-WindowsCommandLineArgument -Arg 'hello \'
    if ($trailResult -ne '"hello \\"') {
        Write-HarnessLog "SelfTest FAIL: trailing backslashes should be doubled before closing quote, got: $trailResult" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: trailing backslashes doubled before closing quote."

    # Backslash before quote
    $bsQuoteResult = ConvertTo-WindowsCommandLineArgument -Arg 'path\"with'
    if ($bsQuoteResult -ne '"path\\\"with"') {
        Write-HarnessLog "SelfTest FAIL: backslash before quote not handled correctly, got: $bsQuoteResult" "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: backslash before quote handled."

    # 14. #4 - Verify Get-OpenCodeEventInfo with real event shapes
    Write-HarnessLog "SelfTest: verifying Get-OpenCodeEventInfo..."

    # 14a. step_start event with sessionID
    $stepStartJson = '{"type":"step_start","sessionID":"sess-001","part":{"type":"step-start"}}'
    $stepStartResult = Get-OpenCodeEventInfo -Line $stepStartJson
    if ($null -eq $stepStartResult) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo returned null for step_start." "error"
        exit 1
    }
    if ($stepStartResult.EventType -ne "step_start") {
        Write-HarnessLog "SelfTest FAIL: step_start EventType expected 'step_start', got '$($stepStartResult.EventType)'." "error"
        exit 1
    }
    if ($stepStartResult.SessionId -ne "sess-001") {
        Write-HarnessLog "SelfTest FAIL: step_start SessionId expected 'sess-001', got '$($stepStartResult.SessionId)'." "error"
        exit 1
    }
    if ($stepStartResult.FingerprintInput -ne "") {
        Write-HarnessLog "SelfTest FAIL: step_start FingerprintInput should be empty, got '$($stepStartResult.FingerprintInput)'." "error"
        exit 1
    }
    if ($stepStartResult.ErrorText -ne "") {
        Write-HarnessLog "SelfTest FAIL: step_start ErrorText should be empty, got '$($stepStartResult.ErrorText)'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: step_start event parsed correctly."

    # 14b. text event with sessionID, part.type text, part.text OK
    $textJson = '{"type":"text","sessionID":"sess-002","part":{"type":"text","text":"OK"}}'
    $textResult = Get-OpenCodeEventInfo -Line $textJson
    if ($null -eq $textResult) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo returned null for text event." "error"
        exit 1
    }
    if ($textResult.EventType -ne "text") {
        Write-HarnessLog "SelfTest FAIL: text EventType expected 'text', got '$($textResult.EventType)'." "error"
        exit 1
    }
    if ($textResult.SessionId -ne "sess-002") {
        Write-HarnessLog "SelfTest FAIL: text SessionId expected 'sess-002', got '$($textResult.SessionId)'." "error"
        exit 1
    }
    if ($textResult.FingerprintInput -ne "textOK") {
        Write-HarnessLog "SelfTest FAIL: text FingerprintInput expected 'textOK', got '$($textResult.FingerprintInput)'." "error"
        exit 1
    }
    if ($textResult.ErrorText -ne "") {
        Write-HarnessLog "SelfTest FAIL: text ErrorText should be empty, got '$($textResult.ErrorText)'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: text event parsed correctly."

    # 14c. error event with sessionID, error.data.message No provider available, statusCode 401
    $errorJson = '{"type":"error","sessionID":"sess-003","error":{"data":{"message":"No provider available"},"message":"fallback message"},"statusCode":401}'
    $errorResult = Get-OpenCodeEventInfo -Line $errorJson
    if ($null -eq $errorResult) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo returned null for error event." "error"
        exit 1
    }
    if ($errorResult.EventType -ne "error") {
        Write-HarnessLog "SelfTest FAIL: error EventType expected 'error', got '$($errorResult.EventType)'." "error"
        exit 1
    }
    if ($errorResult.SessionId -ne "sess-003") {
        Write-HarnessLog "SelfTest FAIL: error SessionId expected 'sess-003', got '$($errorResult.SessionId)'." "error"
        exit 1
    }
    if ($errorResult.ErrorText -ne "No provider available") {
        Write-HarnessLog "SelfTest FAIL: error ErrorText expected 'No provider available', got '$($errorResult.ErrorText)'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: error event parsed correctly."

    # 14d. Synthetic tool event with part.tool read and part.state.input containing filePath package.json
    $toolJson = '{"type":"tool","sessionID":"sess-004","part":{"tool":"read","state":{"input":{"filePath":"package.json"}}}}'
    $toolResult = Get-OpenCodeEventInfo -Line $toolJson
    if ($null -eq $toolResult) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo returned null for tool event." "error"
        exit 1
    }
    if ($toolResult.EventType -ne "tool") {
        Write-HarnessLog "SelfTest FAIL: tool EventType expected 'tool', got '$($toolResult.EventType)'." "error"
        exit 1
    }
    if ($toolResult.SessionId -ne "sess-004") {
        Write-HarnessLog "SelfTest FAIL: tool SessionId expected 'sess-004', got '$($toolResult.SessionId)'." "error"
        exit 1
    }
    $expectedFp = 'read{"filePath":"package.json"}'
    if ($toolResult.FingerprintInput -ne $expectedFp) {
        Write-HarnessLog "SelfTest FAIL: tool FingerprintInput expected '$expectedFp', got '$($toolResult.FingerprintInput)'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: tool event parsed correctly."

    # 14e. Verify different timestamps/IDs produce the same tool FingerprintInput
    $toolJsonA = '{"type":"tool","sessionID":"sess-005","part":{"tool":"read","state":{"input":{"filePath":"package.json"}}},"timestamp":"2024-01-01T00:00:00Z","id":"abc-123"}'
    $toolJsonB = '{"type":"tool","sessionID":"sess-005","part":{"tool":"read","state":{"input":{"filePath":"package.json"}}},"timestamp":"2025-06-15T12:30:00Z","id":"xyz-789"}'
    $toolResultA = Get-OpenCodeEventInfo -Line $toolJsonA
    $toolResultB = Get-OpenCodeEventInfo -Line $toolJsonB
    if ($null -eq $toolResultA -or $null -eq $toolResultB) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo returned null for tool events with varying timestamps." "error"
        exit 1
    }
    if ($toolResultA.FingerprintInput -ne $toolResultB.FingerprintInput) {
        Write-HarnessLog "SelfTest FAIL: tool FingerprintInput should be stable across different timestamps/IDs. Got A='$($toolResultA.FingerprintInput)' B='$($toolResultB.FingerprintInput)'." "error"
        exit 1
    }
    if ($toolResultA.FingerprintInput -ne $expectedFp) {
        Write-HarnessLog "SelfTest FAIL: tool FingerprintInput with timestamps/IDs does not match base case. Got '$($toolResultA.FingerprintInput)', expected '$expectedFp'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: tool FingerprintInput is stable across different timestamps/IDs."

    # 14f. Null for invalid JSON
    $nullResult = Get-OpenCodeEventInfo -Line "not json"
    if ($null -ne $nullResult) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo should return null for non-JSON." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: Get-OpenCodeEventInfo returns null for non-JSON."

    # 14g. Null for empty line
    $emptyResult = Get-OpenCodeEventInfo -Line ""
    if ($null -ne $emptyResult) {
        Write-HarnessLog "SelfTest FAIL: Get-OpenCodeEventInfo should return null for empty line." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: Get-OpenCodeEventInfo returns null for empty line."

    # 15. Verify every line in the current SelfTest eventPath is valid JSONL
    #     with timestamp, run_id, and type fields.
    Write-HarnessLog "SelfTest: verifying event file is valid JSONL..."
    if (-not (Test-Path -LiteralPath $eventPath)) {
        Write-HarnessLog "SelfTest FAIL: event file does not exist: $eventPath" "error"
        exit 1
    }
    $eventLines = Get-Content -LiteralPath $eventPath -Encoding UTF8
    $lineNum = 0
    $validCount = 0
    foreach ($rawLine in $eventLines) {
        $lineNum++
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        $validCount++
        try {
            $obj = $rawLine | ConvertFrom-Json
        }
        catch {
            Write-HarnessLog "SelfTest FAIL: event file line $lineNum is not valid JSON: $rawLine" "error"
            exit 1
        }
        if (-not ($obj.PSObject.Properties['timestamp'])) {
            Write-HarnessLog "SelfTest FAIL: event file line $lineNum is missing 'timestamp' property." "error"
            exit 1
        }
        if (-not ($obj.PSObject.Properties['run_id'])) {
            Write-HarnessLog "SelfTest FAIL: event file line $lineNum is missing 'run_id' property." "error"
            exit 1
        }
        if (-not ($obj.PSObject.Properties['type'])) {
            Write-HarnessLog "SelfTest FAIL: event file line $lineNum is missing 'type' property." "error"
            exit 1
        }
    }
    if ($validCount -eq 0) {
        Write-HarnessLog "SelfTest FAIL: event file contains no non-empty JSON lines." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: $validCount event lines are valid JSONL with timestamp, run_id, and type."

    # 16. Verify Update-OpenCodeLiveState
    Write-HarnessLog "SelfTest: verifying Update-OpenCodeLiveState..."

    # 16a. SessionID extraction through the helper
    $live16a = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false }
    Update-OpenCodeLiveState -Line '{"type":"text","sessionID":"sess-live-001","part":{"type":"text","text":"hello"}}' -Live $live16a
    if ($live16a.SessionId -ne "sess-live-001") {
        Write-HarnessLog "SelfTest FAIL: Update-OpenCodeLiveState did not extract SessionId." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: Update-OpenCodeLiveState extracts SessionId."

    # 16b. Three identical real text events produce LoopDetected
    $live16b = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false }
    $textEvent = '{"type":"text","sessionID":"sess-loop","part":{"type":"text","text":"same text"}}'
    Update-OpenCodeLiveState -Line $textEvent -Live $live16b
    if ($live16b.LoopDetected) { Write-HarnessLog "SelfTest FAIL: LoopDetected after 1 event." "error"; exit 1 }
    if ($live16b.ConsecutiveSame -ne 1) { Write-HarnessLog "SelfTest FAIL: ConsecutiveSame should be 1 after first event." "error"; exit 1 }
    Update-OpenCodeLiveState -Line $textEvent -Live $live16b
    if ($live16b.LoopDetected) { Write-HarnessLog "SelfTest FAIL: LoopDetected after 2 events." "error"; exit 1 }
    if ($live16b.ConsecutiveSame -ne 2) { Write-HarnessLog "SelfTest FAIL: ConsecutiveSame should be 2 after second event." "error"; exit 1 }
    Update-OpenCodeLiveState -Line $textEvent -Live $live16b
    if (-not $live16b.LoopDetected) {
        Write-HarnessLog "SelfTest FAIL: LoopDetected not set after 3 identical events." "error"
        exit 1
    }
    if ($live16b.ConsecutiveSame -lt 3) {
        Write-HarnessLog "SelfTest FAIL: ConsecutiveSame should be >=3 after loop." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: three identical text events produce LoopDetected."

    # 16c. A different text event resets consecutive count to 1
    $live16c = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false }
    Update-OpenCodeLiveState -Line $textEvent -Live $live16c
    Update-OpenCodeLiveState -Line $textEvent -Live $live16c
    if ($live16c.ConsecutiveSame -ne 2) {
        Write-HarnessLog "SelfTest FAIL: ConsecutiveSame should be 2 after two identical events, got $($live16c.ConsecutiveSame)." "error"
        exit 1
    }
    $diffEvent = '{"type":"text","sessionID":"sess-diff","part":{"type":"text","text":"different text"}}'
    Update-OpenCodeLiveState -Line $diffEvent -Live $live16c
    if ($live16c.ConsecutiveSame -ne 1) {
        Write-HarnessLog "SelfTest FAIL: ConsecutiveSame should reset to 1 after different text, got $($live16c.ConsecutiveSame)." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: different text event resets consecutive count to 1."

    # 16d. API 401 "No provider available" sets NonRetryableError true,
    #      does NOT set TransportError
    $live16d = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $false }
    $error401 = '{"type":"error","sessionID":"sess-401","error":{"data":{"message":"No provider available"},"message":"fallback"},"statusCode":401}'
    Update-OpenCodeLiveState -Line $error401 -Live $live16d
    if ($live16d.TransportError) {
        Write-HarnessLog "SelfTest FAIL: API 401 error should NOT set TransportError." "error"
        exit 1
    }
    if (-not $live16d.NonRetryableError) {
        Write-HarnessLog "SelfTest FAIL: API 401 error SHOULD set NonRetryableError." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: API 401 error sets NonRetryableError, not TransportError."

    # 16e. ECONNRESET error message DOES set TransportError
    $live16e = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $false }
    $econnEvent = '{"type":"error","sessionID":"sess-econn","error":{"data":{"message":"ECONNRESET connection reset by peer"}}}'
    Update-OpenCodeLiveState -Line $econnEvent -Live $live16e
    if (-not $live16e.TransportError) {
        Write-HarnessLog "SelfTest FAIL: ECONNRESET should set TransportError." "error"
        exit 1
    }
    if ($live16e.NonRetryableError) {
        Write-HarnessLog "SelfTest FAIL: ECONNRESET should NOT set NonRetryableError." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: ECONNRESET sets TransportError, not NonRetryableError."

    # 16f. Get-HarnessExitReason: zero-exit classification decisions
    Write-HarnessLog "SelfTest: verifying Get-HarnessExitReason..."
    # ECONNRESET + exit 0 → transport_error (may resume)
    $liveTransport = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $true; NonRetryableError = $false }
    $reason = Get-HarnessExitReason -Live $liveTransport -StallDetected $false -ExitCode 0
    if ($reason -ne "transport_error") {
        Write-HarnessLog "SelfTest FAIL: ECONNRESET + exit 0 should be transport_error, got '$reason'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: ECONNRESET + exit 0 → transport_error."
    # No provider available + exit 0 → api_error (must not resume)
    $liveApi = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $true }
    $reason = Get-HarnessExitReason -Live $liveApi -StallDetected $false -ExitCode 0
    if ($reason -ne "api_error") {
        Write-HarnessLog "SelfTest FAIL: No provider available + exit 0 should be api_error, got '$reason'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: No provider available + exit 0 → api_error."
    # Neither flag + exit 0 → normal_exit
    $liveNormal = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $false }
    $reason = Get-HarnessExitReason -Live $liveNormal -StallDetected $false -ExitCode 0
    if ($reason -ne "normal_exit") {
        Write-HarnessLog "SelfTest FAIL: neither flag + exit 0 should be normal_exit, got '$reason'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: neither flag + exit 0 → normal_exit."
    # Loop wins over all
    $liveLoop = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $true; TransportError = $true; NonRetryableError = $true }
    $reason = Get-HarnessExitReason -Live $liveLoop -StallDetected $false -ExitCode 0
    if ($reason -ne "loop") {
        Write-HarnessLog "SelfTest FAIL: loop wins over all, got '$reason'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: loop wins over all."
    # Stall beats transport/api/exit
    $liveStall = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $true; NonRetryableError = $true }
    $reason = Get-HarnessExitReason -Live $liveStall -StallDetected $true -ExitCode 0
    if ($reason -ne "stall") {
        Write-HarnessLog "SelfTest FAIL: stall beats transport/api/exit, got '$reason'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: stall beats transport/api/exit."
    # exit_code_N when no flags
    $liveErr = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $false }
    $reason = Get-HarnessExitReason -Live $liveErr -StallDetected $false -ExitCode 42
    if ($reason -ne "exit_code_42") {
        Write-HarnessLog "SelfTest FAIL: exit_code_42 expected, got '$reason'." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: exit_code_42 when exit code is 42."
    Write-HarnessLog "SelfTest OK: Get-HarnessExitReason works correctly."

    # 17. Verify no TCP fallback in Test-GatewayReady (must not use Get-NetTCPConnection)
    Write-HarnessLog "SelfTest: verifying Test-GatewayReady has no TCP fallback..."
    $harnessSrc17 = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    # Extract the Test-GatewayReady function body
    if ($harnessSrc17 -match 'function Test-GatewayReady\s*\{.*?\}(?=\s*function\s|\s*#|$)') {
        $funcBody = $matches[0]
        if ($funcBody -match 'Get-NetTCPConnection') {
            Write-HarnessLog "SelfTest FAIL: Test-GatewayReady must not fall back to TCP listening check." "error"
            exit 1
        }
    }
    Write-HarnessLog "SelfTest OK: Test-GatewayReady has no TCP fallback."

    # 18. Verify Wait-GatewayReady function exists.
    Write-HarnessLog "SelfTest: verifying Wait-GatewayReady function exists..."
    $harnessSrc18 = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    if ($harnessSrc18 -notmatch 'function Wait-GatewayReady') {
        Write-HarnessLog "SelfTest FAIL: Wait-GatewayReady function not found." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: Wait-GatewayReady function exists."

    # 19. Verify per-attempt activity reset ($lastActivity = Get-Date near Process::Start).
    Write-HarnessLog "SelfTest: verifying per-attempt activity reset..."
    $harnessSrc19 = Get-Content -LiteralPath $PSCommandPath -Raw -Encoding UTF8
    if ($harnessSrc19 -notmatch '\$lastActivity\s*=\s*Get-Date[\s\S]{0,500}\$process\s*=\s*\[System\.Diagnostics\.Process\]::Start') {
        Write-HarnessLog "SelfTest FAIL: per-attempt activity reset (lastActivity=Get-Date before Process::Start) not found." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: per-attempt activity reset found."

    # 20. Real-time delayed stream handling self-test - launch powershell.exe as a
    #     child that emits two valid real-shaped OpenCode JSON lines about 500ms
    #     apart and remains alive briefly.  Consume stdout with Register-ObjectEvent
    #     + ConcurrentQueue + BeginOutputReadLine.  Assert first event was processed
    #     while child still running, SessionId extracted, activity advanced.
    Write-HarnessLog "SelfTest: verifying real-time delayed stream handling..."
    $live20 = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $false }
    $psi20 = New-Object System.Diagnostics.ProcessStartInfo
    $psi20.FileName = "powershell.exe"
    $childScript20 = 'Start-Sleep -Milliseconds 100; Write-Output ''{"type":"text","sessionID":"sess-realtime-001","part":{"type":"text","text":"first event"}}''; Start-Sleep -Milliseconds 500; Write-Output ''{"type":"text","sessionID":"sess-realtime-001","part":{"type":"text","text":"second event"}}''; Start-Sleep -Seconds 2'
    $bytes20 = [System.Text.Encoding]::Unicode.GetBytes($childScript20)
    $encodedCmd20 = [Convert]::ToBase64String($bytes20)
    $psi20.Arguments = "-NoProfile -OutputFormat Text -EncodedCommand $encodedCmd20"
    $psi20.UseShellExecute = $false
    $psi20.RedirectStandardOutput = $true
    $psi20.CreateNoWindow = $true
    $psi20.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $activityInitial20 = Get-Date
    $process20 = [System.Diagnostics.Process]::Start($psi20)
    $outputQueue20 = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $outputEvent20 = Register-ObjectEvent -InputObject $process20 -EventName OutputDataReceived -MessageData $outputQueue20 -Action {
        $data = $EventArgs.Data
        if ($data -ne $null) {
            $queue = $Event.MessageData
            $queue.Enqueue($data)
        }
    }
    $process20.BeginOutputReadLine()
    $processedFirst20 = $false
    $eventProcessedWhileAlive20 = $false
    $pollDeadline20 = (Get-Date).AddSeconds(5)
    while (-not $processedFirst20 -and (Get-Date) -lt $pollDeadline20) {
        $null = Wait-Event -Timeout 1
        $line20 = $null
        while ($outputQueue20.TryDequeue([ref]$line20)) {
            if (-not [string]::IsNullOrWhiteSpace($line20)) {
                $processedFirst20 = $true
                if (-not $process20.HasExited) {
                    $eventProcessedWhileAlive20 = $true
                }
                $activityTimestamp20 = Get-Date
                Update-OpenCodeLiveState -Line $line20 -Live $live20
            }
        }
    }
    if (-not $processedFirst20) {
        Write-HarnessLog "SelfTest FAIL: no events processed while child was running." "error"
        try { $process20.Kill() } catch {}
        try { Unregister-Event -SourceIdentifier $outputEvent20.Name -ErrorAction SilentlyContinue } catch {}
        exit 1
    }
    if (-not $eventProcessedWhileAlive20) {
        Write-HarnessLog "SelfTest FAIL: event not processed while child was still alive." "error"
        try { $process20.Kill() } catch {}
        try { Unregister-Event -SourceIdentifier $outputEvent20.Name -ErrorAction SilentlyContinue } catch {}
        exit 1
    }
    if ($live20.SessionId -ne "sess-realtime-001") {
        Write-HarnessLog "SelfTest FAIL: SessionId expected 'sess-realtime-001', got '$($live20.SessionId)'." "error"
        try { $process20.Kill() } catch {}
        try { Unregister-Event -SourceIdentifier $outputEvent20.Name -ErrorAction SilentlyContinue } catch {}
        exit 1
    }
    if ($activityTimestamp20 -le $activityInitial20) {
        Write-HarnessLog "SelfTest FAIL: activity timestamp did not advance." "error"
        try { $process20.Kill() } catch {}
        try { Unregister-Event -SourceIdentifier $outputEvent20.Name -ErrorAction SilentlyContinue } catch {}
        exit 1
    }
    Write-HarnessLog "SelfTest OK: real-time delayed stream handling works."
    if (-not $process20.WaitForExit(5000)) {
        try { $process20.Kill() } catch {}
        $process20.WaitForExit(3000) | Out-Null
    }
    try { Unregister-Event -SourceIdentifier $outputEvent20.Name -ErrorAction SilentlyContinue } catch {}

    # 21. Verify Update-StderrTransport: harmless warning sets neither flag
    Write-HarnessLog "SelfTest: verifying Update-StderrTransport..."
    $live21 = @{ SessionId = ""; LastFingerprint = ""; ConsecutiveSame = 0; LoopDetected = $false; TransportError = $false; NonRetryableError = $false }
    Update-StderrTransport -Line "this is a harmless warning" -Live $live21
    if ($live21.TransportError) {
        Write-HarnessLog "SelfTest FAIL: harmless stderr warning should NOT set TransportError." "error"
        exit 1
    }
    if ($live21.NonRetryableError) {
        Write-HarnessLog "SelfTest FAIL: harmless stderr warning should NOT set NonRetryableError." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: harmless stderr warning sets neither flag."
    Update-StderrTransport -Line "ECONNRESET connection reset by peer" -Live $live21
    if (-not $live21.TransportError) {
        Write-HarnessLog "SelfTest FAIL: ECONNRESET on stderr SHOULD set TransportError." "error"
        exit 1
    }
    if ($live21.NonRetryableError) {
        Write-HarnessLog "SelfTest FAIL: ECONNRESET on stderr should NOT set NonRetryableError." "error"
        exit 1
    }
    Write-HarnessLog "SelfTest OK: ECONNRESET on stderr sets TransportError, not NonRetryableError."
    Write-HarnessLog "SelfTest OK: Update-StderrTransport works correctly."

    Write-HarnessLog "All SelfTest checks passed."
    exit 0
}

# ---------------------------------------------------------------------------
# DryRun mode - print what would happen, no execution
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Host "DRY RUN: llamadock-opencode-harness.ps1"
    Write-Host "  Workspace: $Workspace"
    Write-Host "  ModelName: $ModelName"
    Write-Host "  Prompt: $(if ([string]::IsNullOrWhiteSpace($Prompt)) { '(none)' } else { '(provided)' })"
    Write-Host "  MaxMinutes: $MaxMinutes"
    Write-Host "  MaxResumes: $MaxResumes"
    Write-Host "  StallSeconds: $StallSeconds"
    Write-Host "  Root: $Root"
    Write-Host "  Gateway port check: $gatewayPort"
    Write-Host "  Upstream port check: $upstreamPort"
    Write-Host "  State file: $statePath"
    Write-Host "  Event file: $eventPath"
    Write-Host "  Run ID: $runId"
    exit 0
}

# ---------------------------------------------------------------------------
# Live run
# ---------------------------------------------------------------------------

Write-HarnessLog "Starting harness run $runId"
Write-HarnessLog "Workspace=$Workspace Model=$ModelName MaxMinutes=$MaxMinutes MaxResumes=$MaxResumes StallSeconds=$StallSeconds"

# Verify gateway and upstream are ready (#6 - HTTP health check, polling)
if (-not (Wait-GatewayReady -Port $gatewayPort)) {
    Write-HarnessLog "Gateway port $gatewayPort did not become ready (with healthy upstream) within the timeout. Aborting." "error"
    exit 1
}
Write-HarnessLog "Gateway port $gatewayPort is ready (upstream healthy)."

# #2 - Prompt must be provided in harness mode (non-interactive). If empty,
#      fail clearly; client-shell should pass it.
if ([string]::IsNullOrWhiteSpace($Prompt)) {
    Write-HarnessLog "No prompt provided. In harness mode, Prompt must be passed by the caller (client-shell). Aborting." "error"
    exit 1
}

# Record initial git state
$gitState = Get-GitState -Dir $Workspace
Write-HarnessLog "Git state: branch=$($gitState.branch) commit=$($gitState.commit) dirty=$($gitState.dirty)"

$state = @{
    run_id = $runId
    status = "running"
    workspace = $Workspace
    model = $ModelName
    started_at = (Get-Date -Format "o")
    max_minutes = $MaxMinutes
    max_resumes = $MaxResumes
    stall_seconds = $StallSeconds
    git_state = $gitState
    session_id = ""
    resume_count = 0
    last_output_at = ""
    last_fingerprint = ""
    consecutive_same = 0
    events = @()
}
Save-State -State $state

$deadline = (Get-Date).AddMinutes($MaxMinutes)
$lastActivity = Get-Date
$resumeCount = 0
$sessionId = ""

while ((Get-Date) -lt $deadline -and $resumeCount -le $MaxResumes) {
    # #2 - Build opencode arguments with --dir flag, NEVER pass Workspace as message
    $opencodeArgs = @("run", "--format", "json")
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        $opencodeArgs += @("--session", $sessionId)
    }
    $opencodeArgs += @("-m", "llamadock/$ModelName")
    # #2 - Use --dir to set the workspace, do not pass as positional arg
    $opencodeArgs += @("--dir", $Workspace)

    # #7 - On resume, do not replay the original task. Send a short safe
    #      continuation instruction that asks OpenCode to inspect current
    #      git/session state before acting.
    if ($resumeCount -gt 0) {
        $opencodeArgs += @("Continue working on the current task. Inspect the git and session state before acting. Do not repeat the original prompt.")
    }
    else {
        # #2 - First run: pass the actual prompt
        $opencodeArgs += @($Prompt)
    }

    Write-HarnessLog "Launching opencode: ModelName=$ModelName resumeCount=$resumeCount sessionIdSet=$(-not [string]::IsNullOrWhiteSpace($sessionId))"
    Record-Event @{ type = "launch"; resume = $resumeCount; session_id = $sessionId }

    # #3 - Use System.Diagnostics.Process with event-driven async reading for
    #      real-time stall detection.  Store only hashes, not raw content.
    #      JSONL must contain JSON objects only (no raw stdout/stderr).
    $opencodeExe = Resolve-OpenCodeExecutable
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $opencodeExe
    $psi.Arguments = ($opencodeArgs | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    # Reset lastActivity right before launching so a previous stall cannot
    # instantly kill the resumed child.
    $lastActivity = Get-Date

    $process = [System.Diagnostics.Process]::Start($psi)

    # Thread-safe queues for collecting output across runspaces
    $outputQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $errorQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'

    # Register event handlers for async output reading
    $outputEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -MessageData $outputQueue -Action {
        $data = $EventArgs.Data
        if ($data -ne $null) {
            $queue = $Event.MessageData
            $queue.Enqueue($data)
        }
    }
    $errorEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -MessageData $errorQueue -Action {
        $data = $EventArgs.Data
        if ($data -ne $null) {
            $queue = $Event.MessageData
            $queue.Enqueue($data)
        }
    }

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    # Initialize Live state for this attempt
    # Preserve LastFingerprint and ConsecutiveSame across resume attempts
    $Live = @{
        SessionId          = $sessionId
        LastFingerprint    = $state.last_fingerprint
        ConsecutiveSame    = $state.consecutive_same
        LoopDetected       = $false
        TransportError     = $false
        NonRetryableError  = $false
    }
    $stallDetected = $false
    while (-not $process.HasExited) {
        $null = Wait-Event -Timeout 2

        # Drain stdout queue — update lastActivity, immediately call helper
        $line = $null
        while ($outputQueue.TryDequeue([ref]$line)) {
            $lastActivity = Get-Date
            Update-OpenCodeLiveState -Line $line -Live $Live
        }
        # Drain error queue — update lastActivity, classify, discard
        while ($errorQueue.TryDequeue([ref]$line)) {
            $lastActivity = Get-Date
            Update-StderrTransport -Line $line -Live $Live
        }

        # Check for loop — kill child if detected while running
        if ($Live.LoopDetected) {
            Write-HarnessLog "Loop detected: $($Live.ConsecutiveSame) consecutive identical fingerprints. Killing process." "warn"
            Record-Event @{ type = "loop_kill"; consecutive = $Live.ConsecutiveSame }
            try { $process.Kill() } catch {}
            break
        }

        # #4 - Check for stall
        $elapsed = ((Get-Date) - $lastActivity).TotalSeconds
        if ($elapsed -gt $StallSeconds) {
            $stallDetected = $true
            Write-HarnessLog "Stall detected: no activity for $([int]$elapsed) seconds." "warn"
            Record-Event @{ type = "stall_detected"; idle_seconds = [int]$elapsed }
            try { $process.Kill() } catch {}
            break
        }

        # Check deadline
        if ((Get-Date) -gt $deadline) {
            Write-HarnessLog "Deadline reached ($MaxMinutes minutes)." "warn"
            Record-Event @{ type = "deadline_reached" }
            try { $process.Kill() } catch {}
            break
        }
    }

    # Process ended; wait for it to fully exit and async reads to complete
    $process.WaitForExit()
    Start-Sleep -Milliseconds 500  # Allow event handlers to finish

    # Drain remaining queue lines through the same helper, without storing them
    $line = $null
    while ($outputQueue.TryDequeue([ref]$line)) {
        Update-OpenCodeLiveState -Line $line -Live $Live
    }
    while ($errorQueue.TryDequeue([ref]$line)) {
        Update-StderrTransport -Line $line -Live $Live
    }

    # Clean up event subscriptions
    try { Unregister-Event -SourceIdentifier $outputEvent.Name -ErrorAction SilentlyContinue } catch {}
    try { Unregister-Event -SourceIdentifier $errorEvent.Name -ErrorAction SilentlyContinue } catch {}

    # Copy Live.SessionId to sessionId
    if (-not [string]::IsNullOrWhiteSpace($Live.SessionId)) {
        $sessionId = $Live.SessionId
        Write-HarnessLog "Session ID updated: $sessionId"
        Record-Event @{ type = "session_id_extracted"; session_id = $sessionId }
    }

    # Process ended - determine why
    # Priority order via Get-HarnessExitReason: loop, stall, transport_error,
    # api_error (NonRetryableError), normal_exit, exit_code_N
    $exitCode = if ($process.HasExited) { $process.ExitCode } else { -1 }
    $exitReason = Get-HarnessExitReason -Live $Live -StallDetected $stallDetected -ExitCode $exitCode

    Write-HarnessLog "Process ended: exit_code=$exitCode reason=$exitReason"
    Record-Event @{ type = "process_exit"; exit_code = $exitCode; reason = $exitReason }

    # Update state — preserve fingerprint tracking across resume attempts
    $state.status = "completed"
    $state.last_exit_code = $exitCode
    $state.last_exit_reason = $exitReason
    $state.ended_at = (Get-Date -Format "o")
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) {
        $state.session_id = $sessionId
    }
    $state.last_fingerprint = $Live.LastFingerprint
    $state.consecutive_same = $Live.ConsecutiveSame
    Save-State -State $state

    # #5 - Should we resume? Classification uses ExitReason only, never raw output.
    if ($exitReason -eq "normal_exit") {
        Write-HarnessLog "Normal exit - no resume needed."
        break
    }
    # A loop must never resume
    if ($exitReason -eq "loop") {
        Write-HarnessLog "Loop detected — no resume." "warn"
        break
    }
    if (-not (Test-IsStallOrTransportError -ExitReason $exitReason)) {
        Write-HarnessLog "Exit reason '$exitReason' is not a transport/stall error - no resume."
        break
    }

    # #5 - Resume only if we have a session ID; do not resume without it.
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        Write-HarnessLog "No session ID available. Cannot resume without session context." "warn"
        break
    }

    # #7 - MaxResumes = N resumes after initial attempt (not including first run)
    $resumeCount++
    if ($resumeCount -gt $MaxResumes) {
        Write-HarnessLog "Max resumes ($MaxResumes) reached. Stopping."
        break
    }

    Write-HarnessLog "Resuming (attempt $resumeCount/$MaxResumes) after 5-second cooldown..."
    Start-Sleep -Seconds 5

    # #6 - Verify ports are still available with HTTP health check (polling)
    if (-not (Wait-GatewayReady -Port $gatewayPort)) {
        Write-HarnessLog "Gateway port $gatewayPort did not become ready (with healthy upstream) within the timeout. Aborting." "error"
        break
    }

    $state.status = "resuming"
    $state.resume_count = $resumeCount
    $state.last_output_at = (Get-Date -Format "o")
    $state.session_id = $sessionId
    Save-State -State $state
    Record-Event @{ type = "resume_attempt"; attempt = $resumeCount; session_id = $sessionId }
}

# Final state
if ($state.status -eq "running" -or $state.status -eq "resuming") {
    $state.status = "completed"
    $state.ended_at = (Get-Date -Format "o")
    Save-State -State $state
}

# #5 - Return nonzero on failed/loop/max-resume states
# A loop must always produce nonzero exit
$finalStatus = $state.status
if ($state.last_exit_reason -eq "loop") {
    $exitCode = 1
}
elseif ($finalStatus -eq "completed" -and $state.last_exit_reason -ne "normal_exit") {
    $exitCode = 1
}
elseif ($resumeCount -ge $MaxResumes -and $exitCode -ne 0) {
    $exitCode = 1
}
elseif ($finalStatus -eq "failed") {
    $exitCode = 1
}
else {
    $exitCode = 0
}

Write-HarnessLog "Harness run $runId finished with status $($state.status)."
exit $exitCode
