# tools/strata-gpu.ps1 — Strata と ComfyUI(h3-chat) の間で GPU のあけわたしが 1 コマンド
#
#   .\tools\strata-gpu.ps1 release    … Strata を止めて GPU をあける（画像・動画生成の前）
#   .\tools\strata-gpu.ps1 restore    … Strata を戻す（生成が終わったら。起動に 1〜2 分）
#   .\tools\strata-gpu.ps1            … 状態だけ見る（Strata / ComfyUI / gateway）
#
# Strata は VRAM を約 8GB 常時確保したままなので、ComfyUI の生成が重くなります。
# release 中は dsh 側のフォールバック鎖（無料 API 経由）がそのまま/chat を引き受けます。
param(
    [ValidateSet('release', 'restore', 'status')]
    [string]$Action = 'status',
    [string]$Config = 'strata-iq3.json'   # restore 対象の config（例: strata-swift.json）
)

$Strata = 'C:\Users\dai86\Strata'

function Get-EnginePid {
    (netstat -ano | Select-String ':8080\s.*LISTENING') |
        ForEach-Object { ($_ -split '\s+')[-1] } | Select-Object -Unique
}

function Test-Port([int]$Port) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $Port)
        $c.Close()
        return $true
    } catch { return $false }
}

function Invoke-EngineProbe {
    try {
        $body = '{"model":"x","messages":[{"role":"user","content":"x"}],"max_tokens":1}'
        Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 8 | Out-Null
        return $true
    } catch { return $false }
}

switch ($Action) {
    'status' {
        Write-Host ("Strata  (8080) : {0}" -f $(if (Test-Port 8080) { '起動中 — GPU に約 8GB 常時' } else { '停止中 — GPU に空き' }))
        Write-Host ("ComfyUI (8188) : {0}" -f $(if (Test-Port 8188) { '起動中' } else { '停止中' }))
        Write-Host ("gateway (8090) : {0}" -f $(if (Test-Port 8090) { '起動中' } else { '停止中' }))
    }
    'release' {
        if (-not (Test-Port 8080)) { Write-Host 'Strata はもう止まっています（GPU は空いています）'; break }
        foreach ($pid_ in (Get-EnginePid)) {
            taskkill /PID $pid_ /T /F 2>&1 | Out-Null
        }
        taskkill /IM strata.exe /F 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds(20)
        while ((Test-Port 8080) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-Port 8080) { Write-Warning '8080 がまだ塞がっています — 手動確認が必要' }
        else { Write-Host 'Strata を停止しました ✅ GPU 約 8GB 解放。ComfyUI / h3-chat の生成をどうぞ。' }
        Write-Host '（生成が終わったら .\tools\strata-gpu.ps1 restore で戻します）'
    }
    'restore' {
        if (Invoke-EngineProbe) { Write-Host 'Strata はすでに起動済みです'; break }
        if (Test-Port 8080) { Write-Host '（serve は生きているがエンジン起動待ち… 完了を待ちます）' }
        else {
            $env:PATH = 'C:\Users\dai86\rocm-sdk-core\_rocm_sdk_core\bin;' + $env:PATH
            $env:PYTHONPATH = 'tools'
            $log = Join-Path $Strata 'probes\serve-gpu.log'
            Start-Process -FilePath (Join-Path $Strata '.venv\Scripts\python.exe') `
                -ArgumentList 'serve/server.py', '--engine', 'strata', '--config', $Config, '--port', '8080' `
                -WorkingDirectory $Strata -WindowStyle Hidden `
                -RedirectStandardOutput $log -RedirectStandardError "$log.err"
            Write-Host 'Strata を起動しました…（モデル読み込みに 1〜2 分）'
        }
        $deadline = (Get-Date).AddSeconds(300)
        while ((Get-Date) -lt $deadline) {
            if (Invoke-EngineProbe) { Write-Host 'Strata 復帰しました ✅ DSH / gateway（8090）もそのまま繋がります。'; break }
            Start-Sleep -Seconds 4
        }
        if (-not (Invoke-EngineProbe)) { Write-Warning "300 秒待っても応答なし — $log[.err] を見てください" }
    }
}
