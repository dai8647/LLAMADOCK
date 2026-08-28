[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ServerPath,
    [Parameter(Mandatory = $true)]
    [string]$ArgumentsPath,
    [string]$Root = "",
    [int]$GatewayPort = 8090,
    [int]$UpstreamPort = 8080,
    [string]$LogDir = "",
    [switch]$AutoRestartServer,
    # Per-request output token cap applied to Cline requests by the recovery
    # gateway. 0 = leave the gateway's own default/env override untouched.
    [int]$ClineMaxTokens = 0,
    # Seconds after starting llama-server during which restart requests are
    # ignored while the model is still loading (port not open yet). A 35B MTP
    # model with a 64K context takes minutes to load; without this grace the
    # gateway's upstream_unreachable flags kill the loading server and the
    # stack never comes up.
    [int]$ServerLoadGraceSeconds = 120
)

# Resolve Root from PSCommandPath after param binding (same pattern as harness)
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}

$ErrorActionPreference = "Stop"
$controlDir = Join-Path $Root "mcp-data\server-supervisor"
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $Root "logs"
}
$flagPath = Join-Path $controlDir "restart-request.json"
$supervisorPidPath = Join-Path $controlDir "supervisor.pid"
$serverPidPath = Join-Path $controlDir "server.pid"
$gatewayPidPath = Join-Path $controlDir "gateway.pid"
$supervisorLogPath = Join-Path $LogDir "supervisor.log"
$proxyPath = Join-Path $Root "tools\llamadock-proxy.mjs"

New-Item -ItemType Directory -Path $controlDir, $LogDir -Force | Out-Null

# Circuit breaker / backoff state (harness design)
$statusPath = Join-Path $controlDir "status.json"
$script:restartCount = 0
$script:breakerOpen = $false
$script:backoffSeconds = @(2, 4, 8, 16, 30)
$script:backoffIndex = 0
$script:restartTimestamps = @()
$script:CIRCUIT_BREAKER_WINDOW = 120  # seconds
$script:CIRCUIT_BREAKER_LIMIT = 5
$script:lastExitCode = ""
$script:lastExitReason = ""

# The supervisor can also be started directly from a shortcut or a test
# shell.  Keep the native child independent of the caller's PATH so a missing
# ROCm DLL is reported in the server log instead of looking like a silent exit.
$rocmRoot = "C:\Program Files\AMD\ROCm"
if (Test-Path -LiteralPath $rocmRoot) {
    $rocmDir = Get-ChildItem -LiteralPath $rocmRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object { try { [version]$_.Name } catch { [version]"0.0" } } -Descending |
        Select-Object -First 1
    if ($rocmDir) {
        $rocmBin = Join-Path $rocmDir.FullName "bin"
        if (Test-Path -LiteralPath $rocmBin) {
            $env:PATH = "$rocmBin;$env:PATH"
        }
    }
}

function Write-SupervisorLog {
    param(
        [string]$Message,
        [string]$Level = "info"
    )

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "o"), $Level.ToUpperInvariant(), $Message
    Add-Content -LiteralPath $supervisorLogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-ListenConnection {
    param([int]$Port)

    return Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
}

function Stop-OwnedProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Label
    )

    if (-not $Process) { return }
    try {
        if (-not $Process.HasExited) {
            Write-SupervisorLog "Stopping $Label PID $($Process.Id)."
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            $Process.WaitForExit(10000)
        }
    }
    catch {
        Write-SupervisorLog "Could not stop $Label PID $($Process.Id): $($_.Exception.Message)" "warn"
    }
}

function Wait-PortClosed {
    param(
        [int]$Port,
        [int]$Attempts = 120
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        if (-not (Get-ListenConnection -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Save-SupervisorStatus {
    param(
        [string]$ServerPid,
        [string]$GatewayPid,
        [string]$State = "running"
    )
    $status = @{
        supervisor_pid = [string]$PID
        server_pid = $ServerPid
        gateway_pid = $GatewayPid
        restart_count = $script:restartCount
        breaker_open = $script:breakerOpen
        breaker_window_seconds = $script:CIRCUIT_BREAKER_WINDOW
        breaker_limit = $script:CIRCUIT_BREAKER_LIMIT
        state = $State
        updated_at = (Get-Date -Format "o")
    }
    if ($script:lastExitCode) { $status["last_exit_code"] = $script:lastExitCode }
    if ($script:lastExitReason) { $status["last_exit_reason"] = $script:lastExitReason }
    $json = $status | ConvertTo-Json -Depth 5
    # Atomic write: write to temp then move
    $tempPath = "$statusPath.tmp"
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $statusPath -Force
}

function Get-BackoffDelay {
    $delay = $script:backoffSeconds[$script:backoffIndex]
    $script:backoffIndex = [Math]::Min($script:backoffIndex + 1, $script:backoffSeconds.Count - 1)
    return $delay
}

function Test-CircuitBreaker {
    param([string]$EventType)
    $now = Get-Date
    $script:restartTimestamps += $now
    # Remove timestamps outside the window
    $cutoff = $now.AddSeconds(-$script:CIRCUIT_BREAKER_WINDOW)
    $script:restartTimestamps = @($script:restartTimestamps | Where-Object { $_ -gt $cutoff })
    $script:restartCount = $script:restartTimestamps.Count
    if ($script:restartCount -gt $script:CIRCUIT_BREAKER_LIMIT) {
        $script:breakerOpen = $true
        Write-SupervisorLog "Circuit breaker OPEN: $($script:restartCount) restarts in $($script:CIRCUIT_BREAKER_WINDOW) seconds. Halting auto-restart." "error"
        Save-SupervisorStatus -ServerPid $(if ($server -and -not $server.HasExited) { [string]$server.Id } else { "" }) -GatewayPid $(if ($gateway -and -not $gateway.HasExited) { [string]$gateway.Id } else { "" }) -State "breaker_open"
        return $true
    }
    Save-SupervisorStatus -ServerPid $(if ($server -and -not $server.HasExited) { [string]$server.Id } else { "" }) -GatewayPid $(if ($gateway -and -not $gateway.HasExited) { [string]$gateway.Id } else { "" }) -State "running"
    return $false
}

function Record-SupervisorEvent {
    param(
        [string]$Type,
        [string]$Detail = ""
    )
    $event = @{
        timestamp = (Get-Date -Format "o")
        type = $Type
        detail = $Detail
        restart_count = $script:restartCount
        breaker_open = $script:breakerOpen
    }
    $eventLogPath = Join-Path $controlDir "events.jsonl"
    $line = $event | ConvertTo-Json -Compress -Depth 5
    try { Add-Content -LiteralPath $eventLogPath -Value $line -Encoding UTF8 } catch {}
}

function Start-ServerChild {
    $serverArguments = @(Get-Content -LiteralPath $ArgumentsPath -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { [string]$_ })
    if ($serverArguments.Count -eq 0) {
        throw "Server arguments are empty: $ArgumentsPath"
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $stdout = Join-Path $LogDir "llama-server-$stamp.stdout.log"
    $stderr = Join-Path $LogDir "llama-server-$stamp.stderr.log"
    Write-SupervisorLog "Starting llama-server: $ServerPath $($serverArguments -join ' ')"
    # This is intentionally visible. The supervisor console is the manual
    # control surface for llama-server; Ctrl+C there runs the cleanup finally
    # block instead of leaving a hidden backend process behind.
    $process = Start-Process -FilePath $ServerPath -ArgumentList $serverArguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Normal
    Set-Content -LiteralPath $serverPidPath -Value ([string]$process.Id) -Encoding ASCII
    return $process
}

function Start-GatewayChild {
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    if (-not (Test-Path -LiteralPath $proxyPath)) {
        throw "LlamaDock gateway is missing: $proxyPath"
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $stdout = Join-Path $LogDir "gateway-$stamp.stdout.log"
    $stderr = Join-Path $LogDir "gateway-$stamp.stderr.log"
    $gatewayArguments = @(
        $proxyPath,
        "--host", "127.0.0.1",
        "--port", [string]$GatewayPort,
        "--upstream", "http://127.0.0.1:$UpstreamPort",
        "--restart-flag", $flagPath,
        "--log-dir", $LogDir
    )
    if ($ClineMaxTokens -gt 0) {
        $gatewayArguments += "--cline-max-tokens", [string]$ClineMaxTokens
    }
    Write-SupervisorLog "Starting LlamaDock gateway on 127.0.0.1:$GatewayPort."
    $process = Start-Process -FilePath $node -ArgumentList $gatewayArguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
    Set-Content -LiteralPath $gatewayPidPath -Value ([string]$process.Id) -Encoding ASCII
    return $process
}

if (-not (Test-Path -LiteralPath $ServerPath)) {
    throw "Server executable was not found: $ServerPath"
}
if (-not (Test-Path -LiteralPath $ArgumentsPath)) {
    throw "Server arguments file was not found: $ArgumentsPath"
}
if (Get-ListenConnection -Port $UpstreamPort) {
    throw "Upstream port $UpstreamPort is already in use."
}
if (Get-ListenConnection -Port $GatewayPort) {
    throw "Gateway port $GatewayPort is already in use."
}

Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $supervisorPidPath -Value ([string]$PID) -Encoding ASCII
Save-SupervisorStatus -ServerPid "" -GatewayPid "" -State "starting"
$server = $null
$gateway = $null
$stopping = $false
$serverStartTime = $null

try {
    $gateway = Start-GatewayChild
    Save-SupervisorStatus -ServerPid "" -GatewayPid ([string]$gateway.Id) -State "starting"
    $server = Start-ServerChild
    $serverStartTime = Get-Date
    Save-SupervisorStatus -ServerPid ([string]$server.Id) -GatewayPid ([string]$gateway.Id) -State "running"

    while ($true) {
        if (Test-Path -LiteralPath $flagPath) {
            $request = Get-Content -LiteralPath $flagPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $flagPath -Force -ErrorAction SilentlyContinue
            Write-SupervisorLog "Restart requested by gateway: $request" "warn"
            Record-SupervisorEvent -Type "requested_restart" -Detail $request
            if (Test-CircuitBreaker -EventType "requested_restart") {
                # #8 - On breaker for requested restart, stop/break instead of
                #      recounting forever.
                Write-SupervisorLog "Circuit breaker tripped for requested restart. Stopping supervisor." "error"
                break
            }
            # While the model is still loading the port is not open yet, so
            # the gateway reports every client request as upstream_unreachable.
            # Killing the server here restarts the load from scratch and the
            # stack never comes up. Ignore restart requests during the grace
            # window; the server will be ready shortly.
            if ($server -and -not $server.HasExited -and $serverStartTime) {
                $serverAgeSeconds = [math]::Round(((Get-Date) - $serverStartTime).TotalSeconds)
                if ($serverAgeSeconds -lt $ServerLoadGraceSeconds -and -not (Get-ListenConnection -Port $UpstreamPort)) {
                    Write-SupervisorLog "Restart request ignored: llama-server started ${serverAgeSeconds}s ago and port $UpstreamPort is not open yet (grace ${ServerLoadGraceSeconds}s)." "warn"
                    continue
                }
            }
            $delay = Get-BackoffDelay
            try {
                Stop-OwnedProcess -Process $server -Label "llama-server"
                if (-not (Wait-PortClosed -Port $UpstreamPort)) {
                    Write-SupervisorLog "Upstream port $UpstreamPort did not close after the 60-second restart wait; retrying the stop." "error"
                    Stop-OwnedProcess -Process $server -Label "llama-server (retry)"
                    if (-not (Wait-PortClosed -Port $UpstreamPort -Attempts 60)) {
                        Write-SupervisorLog "Upstream port $UpstreamPort is still open; keeping the gateway alive and retrying later." "error"
                        $server = $null
                        Start-Sleep -Seconds 5
                        continue
                    }
                }
                Start-Sleep -Seconds $delay
                try {
                    $server = Start-ServerChild
                    $serverStartTime = Get-Date
                    Save-SupervisorStatus -ServerPid ([string]$server.Id) -GatewayPid ([string]$gateway.Id) -State "running"
                }
                catch {
                    Write-SupervisorLog "Could not restart llama-server after client disconnect: $($_.Exception.Message)" "error"
                    $server = $null
                    Start-Sleep -Seconds 5
                }
            }
            catch {
                Write-SupervisorLog "Server recovery loop failed but the supervisor will continue: $($_.Exception.Message)" "error"
                $server = $null
                Start-Sleep -Seconds 5
            }
        }

        if ($server -and $server.HasExited) {
            $serverExitCode = $server.ExitCode
            if ($null -eq $serverExitCode) { $serverExitCode = "<null>" }
            $displayedExitCode = if ([string]::IsNullOrWhiteSpace([string]$serverExitCode)) { "<crashed-no-exitcode>" } else { [string]$serverExitCode }
            $script:lastExitCode = $displayedExitCode
            $script:lastExitReason = "unexpected_exit"
            Record-SupervisorEvent -Type "unexpected_exit" -Detail "exit_code=$displayedExitCode"
            if (-not $AutoRestartServer) {
                Write-SupervisorLog "llama-server exited with code $displayedExitCode; automatic restart is disabled. Stopping the visible server session." "warn"
                break
            }
            if (Test-CircuitBreaker -EventType "unexpected_exit") {
                # #8 - On breaker for an exited server, stop/break instead of
                #      recounting forever.
                Write-SupervisorLog "Circuit breaker tripped for exited server. Stopping supervisor." "error"
                break
            }
            $delay = Get-BackoffDelay
            Write-SupervisorLog "llama-server exited with code $serverExitCode; restarting it after ${delay}s backoff." "warn"
            Start-Sleep -Seconds $delay
            try {
                $server = Start-ServerChild
                $serverStartTime = Get-Date
                Save-SupervisorStatus -ServerPid ([string]$server.Id) -GatewayPid ([string]$gateway.Id) -State "running"
            }
            catch {
                Write-SupervisorLog "Could not restart an exited llama-server: $($_.Exception.Message)" "error"
                $server = $null
                Start-Sleep -Seconds 5
            }
        }
        if ($gateway -and $gateway.HasExited) {
            Write-SupervisorLog "gateway exited with code $($gateway.ExitCode); restarting it." "warn"
            Record-SupervisorEvent -Type "gateway_restart" -Detail "exit_code=$($gateway.ExitCode)"
            try {
                $gateway = Start-GatewayChild
                Save-SupervisorStatus -ServerPid $(if ($server) { [string]$server.Id } else { "" }) -GatewayPid ([string]$gateway.Id) -State "running"
            }
            catch {
                Write-SupervisorLog "Could not restart gateway: $($_.Exception.Message)" "error"
                $gateway = $null
                Start-Sleep -Seconds 5
            }
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    $stopping = $true
    Stop-OwnedProcess -Process $server -Label "llama-server"
    Stop-OwnedProcess -Process $gateway -Label "gateway"
    Save-SupervisorStatus -ServerPid "" -GatewayPid "" -State "stopped"
    Remove-Item -LiteralPath $serverPidPath, $gatewayPidPath, $supervisorPidPath, $flagPath -Force -ErrorAction SilentlyContinue
    Write-SupervisorLog "Supervisor stopped."
}
