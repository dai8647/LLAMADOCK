param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Cline", "OpenCode", "Pi")]
    [string]$Client,
    [Parameter(Mandatory = $true)]
    [string]$ModelName,
    [string]$BaseUrl = "http://127.0.0.1:8090/v1",
    [string]$ConfigPath = "",
    [string]$DataDir = "",
    [string]$Workspace = ""
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (-not (Test-Path -LiteralPath $utf8Helper)) {
    throw "Shared UTF-8 helper is missing: $utf8Helper"
}
. $utf8Helper
Set-LlamaDockUtf8Environment

if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    Set-Location -LiteralPath $Workspace
}

switch ($Client) {
    "Cline" {
        if ([string]::IsNullOrWhiteSpace($DataDir)) {
            throw "Cline data directory is required."
        }
        $env:CLINE_DATA_DIR = $DataDir
        $env:CLINE_MCP_SETTINGS_PATH = Join-Path $DataDir "settings\cline_mcp_settings.json"
        & cline --data-dir $DataDir --thinking none --compaction basic --timeout 900
    }
    "OpenCode" {
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            throw "OpenCode config path is required."
        }
        $env:OPENCODE_CONFIG = $ConfigPath
        $env:OPENAI_API_KEY = "not-needed"
        & opencode -m "llamadock/$ModelName" (Get-Location).Path
    }
    "Pi" {
        if ([string]::IsNullOrWhiteSpace($ModelName)) {
            throw "Pi model name is required."
        }
        # OpenAI-compatible endpoint of the LlamaDock recovery gateway.  The
        # Web GUI passes BaseUrl already ending in /v1; the CLI passes the bare
        # gateway origin - normalize both to one shape.
        $endpoint = $BaseUrl
        if ($endpoint -notmatch "/v1/?$") { $endpoint = $endpoint.TrimEnd("/") + "/v1" }

        # Match the running llama-server's real context window so pi never
        # assumes its 128K default and overruns the live KV cache mid-session.
        $liveContext = 0
        foreach ($probe in @("http://127.0.0.1:8080", $endpoint)) {
            try {
                $props = Invoke-RestMethod -Uri "$probe/props" -TimeoutSec 2 -ErrorAction Stop
                $nCtx = [int]$props.default_generation_settings.n_ctx
                if ($nCtx -gt 0) { $liveContext = $nCtx; break }
            }
            catch {
            }
        }
        if ($liveContext -le 0) { $liveContext = 16384 }
        $outputCap = [math]::Max(1024, [math]::Min(16384, $liveContext))

        # Register (or refresh) the 'llamadock' provider in the user's own pi
        # config, preserving every other provider already defined there.
        $piDir = Join-Path $HOME ".pi\agent"
        New-Item -ItemType Directory -Force -Path $piDir | Out-Null
        $piModelsPath = Join-Path $piDir "models.json"
        $provider = [ordered]@{
            baseUrl = $endpoint
            api     = "openai-completions"
            apiKey  = "not-needed"
            compat  = [ordered]@{
                supportsDeveloperRole    = $false
                supportsReasoningEffort  = $false
            }
            models  = @(
                [ordered]@{
                    id            = $ModelName
                    name          = "$ModelName (LlamaDock local)"
                    reasoning     = $false
                    contextWindow = $liveContext
                    maxTokens     = $outputCap
                }
            )
        }

        $config = [ordered]@{ providers = [ordered]@{ llamadock = $provider } }
        if (Test-Path -LiteralPath $piModelsPath) {
            try {
                $existing = Get-Content -LiteralPath $piModelsPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $merged = [ordered]@{}
                if ($null -ne $existing -and $null -ne $existing.providers) {
                    foreach ($p in $existing.providers.PSObject.Properties) {
                        $merged[$p.Name] = $p.Value
                    }
                }
                $merged["llamadock"] = $provider
                $config.providers = $merged
            }
            catch {
                Write-Host "WARNING: could not read $piModelsPath; keeping only the LlamaDock provider." -ForegroundColor Yellow
            }
        }

        $piJson = $config | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($piModelsPath, $piJson, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Pi provider 'llamadock' -> $endpoint (model: $ModelName, ctx: $liveContext)" -ForegroundColor Green
        Write-Host "Pi config: $piModelsPath" -ForegroundColor DarkGray

        # ---- Web search via the LlamaDock MCP server -----------------------
        # mcp-server.js (http://127.0.0.1:3100/mcp) exposes search_web /
        # search_and_fetch / fetch_url / deep_research (Serper when the key is
        # set, otherwise DuckDuckGo / Brave / Bing HTML). Auto-start it, then
        # register it in pi's MCP config so the tools are available.
        $mcpBase = "http://127.0.0.1:3100"
        $mcpUp = $false
        try {
            $null = Invoke-WebRequest -Uri "$mcpBase/mcp" -Method Post -ContentType "application/json" -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
            $mcpUp = $true
        }
        catch {
            if ($_.Exception.Response) { $mcpUp = $true }
        }
        if (-not $mcpUp) {
            $repoRoot = Split-Path $PSScriptRoot -Parent
            $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
            if ($nodeExe) {
                $logDir = Join-Path $repoRoot "logs"
                New-Item -ItemType Directory -Force -Path $logDir | Out-Null
                Start-Process -FilePath $nodeExe -ArgumentList @((Join-Path $repoRoot "mcp-server.js")) -WorkingDirectory $repoRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir "mcp-pi.stdout.log") -RedirectStandardError (Join-Path $logDir "mcp-pi.stderr.log") | Out-Null
                for ($i = 0; $i -lt 20 -and -not $mcpUp; $i++) {
                    Start-Sleep -Milliseconds 500
                    try {
                        $null = Invoke-WebRequest -Uri "$mcpBase/mcp" -Method Post -ContentType "application/json" -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
                        $mcpUp = $true
                    }
                    catch {
                        if ($_.Exception.Response) { $mcpUp = $true }
                    }
                }
            }
        }
        if ($mcpUp) {
            Write-Host "Web-search MCP ready: $mcpBase/mcp (tools appear as mcp_llamadock_*)" -ForegroundColor Green
        }
        else {
            Write-Host "WARNING: Web-search MCP (mcp-server.js on :3100) did not start; search tools unavailable." -ForegroundColor Yellow
        }

        # Register the server in pi's global MCP config, preserving any other
        # servers the user already configured.
        $piMcpPath = Join-Path $piDir "mcp.json"
        $mcpEntry = [ordered]@{
            transport = "streamable-http"
            url       = "$mcpBase/mcp"
            lifecycle = "eager"
        }
        $mcpConfig = [ordered]@{ mcpServers = [ordered]@{ llamadock = $mcpEntry } }
        if (Test-Path -LiteralPath $piMcpPath) {
            try {
                $existingMcp = Get-Content -LiteralPath $piMcpPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $mergedServers = [ordered]@{}
                if ($null -ne $existingMcp -and $null -ne $existingMcp.mcpServers) {
                    foreach ($s in $existingMcp.mcpServers.PSObject.Properties) {
                        $mergedServers[$s.Name] = $s.Value
                    }
                }
                $mergedServers["llamadock"] = $mcpEntry
                $mcpConfig.mcpServers = $mergedServers
            }
            catch {
                Write-Host "WARNING: could not read $piMcpPath; keeping only the LlamaDock MCP server." -ForegroundColor Yellow
            }
        }
        [System.IO.File]::WriteAllText($piMcpPath, ($mcpConfig | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))

        if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
            throw "pi CLI がインストールされていません。次のコマンドでインストールしてください: npm install -g @earendil-works/pi-coding-agent"
        }

        # pi ships without an MCP client; pi-mcp-extension bridges configured
        # MCP servers into Pi tools. Install it once when missing.
        $settingsPath = Join-Path $piDir "settings.json"
        $hasMcpExtension = $false
        if (Test-Path -LiteralPath $settingsPath) {
            try {
                $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
                foreach ($pkg in @($settings.packages)) {
                    if ($pkg -match "pi-mcp-extension") { $hasMcpExtension = $true; break }
                }
            }
            catch { }
        }
        if (-not $hasMcpExtension) {
            Write-Host "Installing pi-mcp-extension (bridges LlamaDock MCP servers into Pi)..." -ForegroundColor Cyan
            & pi install npm:pi-mcp-extension 2>&1 | Write-Host
        }
        Write-Host "Pi MCP config: $piMcpPath (web search = mcp_llamadock_search_web)" -ForegroundColor DarkGray

        # pi performs startup network operations (catalog/news refresh) that can
        # stall without a timeout on restricted networks. LlamaDock launches Pi
        # against the local model, so keep the startup offline; the local
        # llamadock provider (models.json) and extensions such as
        # pi-mcp-extension are unaffected.
        $env:PI_OFFLINE = "1"
        & pi --provider llamadock --model $ModelName
    }
}

exit $LASTEXITCODE
