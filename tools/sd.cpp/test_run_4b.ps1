# test_run_4b.ps1 - sd.cpp Klein 4B GGUF 実行ラッパー
# h3-chat.py の _kimg_sdcpp から以下 env で呼ばれる:
#   SDCPP_OUT    出力 PNG フルパス (未指定なら sdcpp_klein_4b.png)
#   SDCPP_PROMPT プロンプトファイルパス (未指定なら prompt_test.txt)
#
# VRAM 解放ポリシー:
#   1. sd-cli は正常終了時に ggml_backend_release を呼んでから main() return する
#      (sdcpp_klein_4b.log に "model manager releasing params backend buffer" が
#       出ていれば OK)。Vulkan driver はプロセス終了で context 破棄する仕様。
#   2. 万一 VRAM が残っても、ps1 側で sd-cli の正常終了後に 1.5秒 idle を入れて
#      Vulkan driver の GC を待ってから power shell 自体も終了する。
#   3. h3-chat.py 側の _kimg_sdcpp は次の処理 (ComfyUI 起動 or h3 起動) を
#      走らせる前に、vram を要する側の _free_comfy() 等で再確保する。
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDir = Join-Path $here "models"
$sdCli = Join-Path $here "sd-cli.exe"
$klein = Join-Path $modelsDir "klein-4b-q4_0.gguf"
$llm   = Join-Path $modelsDir "qwen3-4b-q4_k_m.gguf"
$vae   = "C:\Users\dai86\Documents\ComfyUI\models\vae\flux2-vae.safetensors"
$prompt = if ($env:SDCPP_PROMPT) { $env:SDCPP_PROMPT } else { Join-Path $here "prompt_test.txt" }
$out   = if ($env:SDCPP_OUT)    { $env:SDCPP_OUT }    else { "C:\Users\dai86\Documents\ComfyUI\output\sdcpp_klein_4b.png" }

Write-Host "klein=$klein"
Write-Host "llm=$llm"
Write-Host "prompt=$prompt"
Write-Host "out=$out"

# 単一文字列で渡す (PowerShell 5 の @() 配列渡しは env 込みでトラブる事がある)
$args = @(
  "--diffusion-model `"$klein`""
  "--llm `"$llm`""
  "--vae `"$vae`""
  "--vae-format flux"
  "--prompt-file `"$prompt`""
  "-H 1024 -W 1024"
  "--steps 4 --cfg-scale 1 -s 42"
  "-o `"$out`""
  "--sampling-method euler --scheduler simple"
  "--diffusion-conv-direct --vae-tiling"
  "--diffusion-fa"
) -join " "

$proc = Start-Process -FilePath $sdCli -ArgumentList $args -NoNewWindow -PassThru -Wait

# sd-cli 終了確認 (1行 if で parser バグ回避)
if ($proc.ExitCode -ne 0) { Write-Host "sd-cli exit code: $($proc.ExitCode)" -ForegroundColor Red; exit $proc.ExitCode }

# VRAM 解放待ち: Vulkan driver の deferred free を待つ。
# Windows の AMD proprietary driver (Vulkan) はプロセス exit 時に context を
# 破棄するが、内部 allocation の free が 100ms ~ 1s 遅延することがある。
Write-Host "sd-cli exited. Waiting 1.5s for Vulkan driver VRAM release..."
Start-Sleep -Seconds 1.5

# 結果 PNG の存在確認 (1行 if)
if (-not (Test-Path -LiteralPath $out)) { Write-Host "ERROR: output PNG not found at $out" -ForegroundColor Red; exit 2 }
Write-Host "OK: $out"
exit 0
