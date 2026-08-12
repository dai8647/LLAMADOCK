# Shared UTF-8 boundary helpers for Windows PowerShell 5.1.
# PowerShell 5.1 may encode a string Body with the active Windows code page.
# Local model APIs must receive explicit UTF-8 bytes for JSON requests.

function Set-LlamaDockUtf8Environment {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try { cmd.exe /d /c "chcp 65001>nul" | Out-Null } catch {}
    try { [Console]::InputEncoding = $utf8 } catch {}
    try { [Console]::OutputEncoding = $utf8 } catch {}
    $script:OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
}

function ConvertTo-LlamaDockUtf8JsonBytes {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [int]$Depth = 20
    )

    $json = $InputObject | ConvertTo-Json -Depth $Depth -Compress
    return [System.Text.Encoding]::UTF8.GetBytes($json)
}

function Invoke-LlamaDockJsonPost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [object]$Body,
        [int]$TimeoutSec = 120,
        [int]$Depth = 20
    )

    $bytes = ConvertTo-LlamaDockUtf8JsonBytes -InputObject $Body -Depth $Depth
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $content = New-Object System.Net.Http.ByteArrayContent(, $bytes)
    $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/json")
    $content.Headers.ContentType.CharSet = "utf-8"
    try {
        $response = $client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        $rawResponse = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $text = [System.Text.Encoding]::UTF8.GetString($rawResponse)
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode): $text"
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text | ConvertFrom-Json
    }
    finally {
        if ($content) { $content.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

Set-LlamaDockUtf8Environment
