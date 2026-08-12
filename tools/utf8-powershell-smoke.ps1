param(
    [string]$BaseUrl = "http://127.0.0.1:8080/v1",
    [string]$Model = "",
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"
$utf8Helper = Join-Path $PSScriptRoot "llamadock-utf8.ps1"
if (-not (Test-Path -LiteralPath $utf8Helper)) {
    throw "UTF-8 helper is missing: $utf8Helper"
}
. $utf8Helper

function New-CodePointString {
    param([int[]]$CodePoints)

    return -join ($CodePoints | ForEach-Object { [char]::ConvertFromUtf32($_) })
}

function Get-ResponseText {
    param([object]$Response)

    $content = $Response.choices[0].message.content
    if ($content -is [string]) { return $content }
    if ($content -is [System.Array]) {
        return -join @(
            $content | ForEach-Object {
                if ($_ -and $_.text -is [string]) { $_.text }
            }
        )
    }
    return [string]$content
}

function Test-ExpectedText {
    param(
        [string]$Text,
        [string[]]$Expected
    )

    if ($Text.IndexOf([char]0xFFFD) -ge 0) { return $false }
    if ($Text.Contains("???")) { return $false }
    foreach ($token in $Expected) {
        if (-not $Text.Contains($token)) { return $false }
    }
    return $true
}

if ([string]::IsNullOrWhiteSpace($Model)) {
    $models = Invoke-RestMethod -Uri "$($BaseUrl.TrimEnd('/'))/models" -TimeoutSec 5 -ErrorAction Stop
    $Model = [string]@($models.data | Where-Object { $_.id } | Select-Object -First 1)[0].id
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    throw "No local model was found at $BaseUrl"
}

$japaneseCapital = New-CodePointString @(0x65E5,0x672C,0x306E,0x9996,0x90FD,0x306F,0x3069,0x3053,0x3067,0x3059,0x304B,0x3002,0x7B54,0x3048,0x306F,0x90FD,0x5E02,0x540D,0x3060,0x3051,0x306B,0x3057,0x3066,0x304F,0x3060,0x3055,0x3044,0x3002)
$japaneseCapitalExpected = New-CodePointString @(0x6771,0x4EAC)
$mixedEcho = New-CodePointString @(0x6B21,0x306E,0x6587,0x5B57,0x5217,0x3092,0x305D,0x306E,0x307E,0x307E,0x4E00,0x5EA6,0x3060,0x3051,0x8FD4,0x3057,0x3066,0x304F,0x3060,0x3055,0x3044,0xFF1A,0x6771,0x4EAC,0x30FB,0x5927,0x962A,0x20,0x2F,0x20,0x4E2D,0x6587,0x20,0x2F,0x20,0xD55C,0xAD6D,0xC5B4,0x20,0x2F,0x20,0x1F600)
$mixedEchoExpected = @(
    (New-CodePointString @(0x6771,0x4EAC,0x30FB,0x5927,0x962A)),
    (New-CodePointString @(0x4E2D,0x6587)),
    (New-CodePointString @(0xD55C,0xAD6D,0xC5B4)),
    (New-CodePointString @(0x1F600))
)
$jsonPrompt = New-CodePointString @(0x6B21,0x306E,0x4A,0x53,0x4F,0x4E,0x3060,0x3051,0x3092,0x8FD4,0x3057,0x3066,0x304F,0x3060,0x3055,0x3044,0xFF1A,0x7B,0x22,0x90FD,0x5E02,0x22,0x3A,0x22,0x6771,0x4EAC,0x22,0x2C,0x22,0x56FD,0x22,0x3A,0x22,0x65E5,0x672C,0x22,0x7D)
$jsonExpected = @(
    (New-CodePointString @(0x90FD,0x5E02)),
    (New-CodePointString @(0x6771,0x4EAC)),
    (New-CodePointString @(0x56FD)),
    (New-CodePointString @(0x65E5,0x672C))
)

$cases = @(
    [PSCustomObject]@{ Name = "japanese_capital"; Prompt = $japaneseCapital; Expected = @($japaneseCapitalExpected); MaxTokens = 16 },
    [PSCustomObject]@{ Name = "cjk_echo"; Prompt = $mixedEcho; Expected = $mixedEchoExpected; MaxTokens = 48 },
    [PSCustomObject]@{ Name = "json_japanese"; Prompt = $jsonPrompt; Expected = $jsonExpected; MaxTokens = 48 },
    [PSCustomObject]@{ Name = "ascii_control"; Prompt = "Reply with exactly OK."; Expected = @("OK"); MaxTokens = 16 }
)

$failures = 0
foreach ($case in $cases) {
    $body = [ordered]@{
        model = $Model
        messages = @(@{ role = "user"; content = $case.Prompt })
        temperature = 0
        max_tokens = $case.MaxTokens
        chat_template_kwargs = @{ enable_thinking = $false }
        stream = $false
    }
    try {
        $response = Invoke-LlamaDockJsonPost -Uri "$($BaseUrl.TrimEnd('/'))/chat/completions" -Body $body -TimeoutSec $TimeoutSec
        $text = Get-ResponseText -Response $response
        $status = if (Test-ExpectedText -Text $text -Expected $case.Expected) { "PASS" } else { "FAIL" }
        if ($status -eq "FAIL") { $failures++ }
        # Keep this report ASCII-safe even when the host console is CP932.
        $codePoints = (($text.ToCharArray() | ForEach-Object { [int][char]$_ }) -join ",")
        Write-Output ("{0} model={1} case={2} codepoints={3}" -f $status, $Model, $case.Name, $codePoints)
    }
    catch {
        $failures++
        Write-Output ("ERROR model={0} case={1} type={2} message={3}" -f $Model, $case.Name, $_.Exception.GetType().Name, $_.Exception.Message)
    }
}

Write-Output ("SUMMARY model={0} cases={1} failures={2} transport=PowerShell5.1-UTF8-bytes" -f $Model, $cases.Count, $failures)
exit $(if ($failures -eq 0) { 0 } else { 1 })
