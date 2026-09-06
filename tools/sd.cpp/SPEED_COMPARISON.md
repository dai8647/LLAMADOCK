# 画像生成エンジン速度比較 (RX 7800 XT 16GB / Win11 24H2)

計測日: 2026-09-04
プロンプト: `1girl, solo, nude, full body, detailed genitalia, vulva with visible labia majora and minora, natural skin texture, high quality, best quality`
seed: 42
解像度: 1024×1024

## サマリ表

| エンジン | モデル | 量子化 | バックエンド | 全体時間 | うち text enc | うち diffusion | うち VAE decode | VRAM |
|---|---|---|---|---|---|---|---|---|
| ComfyUI Klein 9B | Klein 9B bf16 | bf16 (mixed) | ROCm/HipBLAS | **90秒** | 約20秒 | 約55秒 | 約15秒 | ~13GB |
| ComfyUI Krea 2 | Krea 2 Turbo 12.9B | INT4 W4A4 native | ROCm/HipBLAS | **90秒** | 約20秒 | 約55秒 | 約15秒 | ~8GB |
| sd.cpp Klein 4B | Klein 4B + Qwen3 4B | Q4_0 GGUF | Vulkan (AMD) | **36.66秒** | 10.58秒 (cond graph) | 9.78秒 (4step合計) | 16.31秒 | ~5.9GB |

## 速度倍率

- **sd.cpp 4B は ComfyUI 9B の 2.46 倍速い** (90秒 → 36.66秒)
- 比率内訳: text encoder 1.9倍 / diffusion 5.6倍 / VAE 同じ

## なぜ速いのか

1. **Q4_0 GGUF 量子化**: 9B bf16 (18GB) → 4B Q4_0 (2.3GB) で重み load とメモリ帯域が大幅減
2. **Vulkan flash attention (`--diffusion-fa`)**: bf16 attention より高速
3. **graph cut 分割不要**: 5.9GB なので 16GB VRAM に余裕で全部乗る、CPU↔VRAM swap 発生せず
4. **`--diffusion-conv-direct`**: ggml_conv2d_direct で DiT の conv を直接実行

## 試したが失敗した構成

| 構成 | 失敗理由 |
|---|---|
| sd.cpp Klein 9B bf16 safetensors | **GGML_ASSERT** `scale_nelements == 1 \|\| scale_nelements == out_features` (Qwen3 8B の MoE per-channel scale 非対応) |
| sd.cpp Klein 9B bf16 + `--type f16` | 同じ assert (q8_0 layer 残る) |
| sd.cpp Klein 9B Q4_0 GGUF + Qwen 8B Q4_K_M | GGML_ASSERT 回避成功したが **VRAM 2.5GB buffer 確保失敗** → `--max-vram 12 --auto-fit` で graph cut 動作するが 1 step 160秒 (過分割) |
| sd.cpp Klein 9B + `--offload-to-cpu` | 同じ buffer 失敗 (offload 効かず) |
| ROCm 版 sd.cpp binary | **api-ms-win-core-delayload-l1-1-1.dll 欠損**で起動不可 (Win11 24H2 build 26100+ の UCRT 問題) |

## 推奨構成 (RX 7800 XT 16GB)

| 用途 | 推奨 | 理由 |
|---|---|---|
| 速度最優先 | sd.cpp Klein 4B | 36秒・VRAM 余裕・Q4_0 GGUF |
| 品質最優先 | ComfyUI Klein 9B | bf16 精度・LoRA 対応・Klein 系 NSFW LoRA 使える |
| アニメ・スタイル | ComfyUI Krea 2 Turbo | イラスト系得意・12.9B・INT4 W4A4 |

## ファイル配置

```
tools/sd.cpp/
├── sd-cli.exe                   # Vulkan binary
├── sd-server.exe
├── stable-diffusion.dll + ggml-*.dll + libwebp*.dll + webm.dll + libsharpyuv.dll
├── prompt_test.txt              # デフォルトテストプロンプト
├── test_run_4b.ps1              # 4B Klein 実行ラッパー
├── update-sdcpp.ps1             # 本家アップデート追跡 (Vulkan デフォルト)
├── VERSION                      # 現バージョン (master-841-6b3edaa)
└── models/
    ├── klein-4b-q4_0.gguf       # 2.3GB
    ├── qwen3-4b-q4_k_m.gguf    # 2.4GB
    ├── klein-9b-q4_0.gguf       # 5.3GB (将来 24GB+ VRAM 用)
    └── qwen3-8b-q4_k_m.gguf    # 4.7GB (将来 24GB+ VRAM 用)
```

## テスト実行コマンド

```bash
cd "C:/Users/dai86/Downloads/llama-tq3/tools/sd.cpp"
powershell -ExecutionPolicy Bypass -File test_run_4b.ps1
# → 36秒で ComfyUI/output/sdcpp_klein_4b.png に保存
```

## h3-chat.py 統合

- UI: 「キー画像」セクションに `sd.cpp Klein 4B (超爆速・36秒・Q4_0 GGUF)` ラジオ追加
- エンジン: `IMG_ENGINES["sdcpp"]` エントリ追加
- ハンドラ: `_kimg_sdcpp` で ComfyUI を一旦 kill → ps1 実行 → job_meta で進捗管理
- ステータス: `_status_sdcpp` で ComfyUI 非依存の完了検出 (ComfyUI 落ちてても OK)
- 出力: `ComfyUI/output/sdcpp_<timestamp>.png` に rename、既存の `/api/view` で配信

## 自動スタック停止 (autostop)

使い終わったら自動的に ComfyUI + 企画 LLM (llama-server) + h3-chat.py を全部 shutdown する仕組み。

### 有効化

```bash
# 10分 (600秒) idle で自動停止。sd.cpp 画像生成でも発火 (sdcpp も mark_done する)
set LLAMADOCK_H3_AUTOSTOP=600
python tools\h3-chat.py
```

### 仕組み

1. `_status_sdcpp` で sd.cpp 画像生成完了時に `self.server.autostop.mark_done()` 呼び出し
2. `_AutoStop` スレッドが 10秒ごとにチェック、`AUTO_STOP_SECONDS` 経過で `_stop_stack` 実行
3. `_stop_stack` は:
   - ComfyUI の `/free` 叩いてモデル VRAM 解放
   - port 8188 (ComfyUI) kill
   - port `PLAN_PORT` (デフォルト 8190 = llama-server) kill
   - 1.5秒後に `server.shutdown()` で h3-chat.py 自体も終了
4. 動画生成完了 (`has_video=True`) でも同経路で mark_done される

### なぜ opt-in か

連続生成中に kill される事故防止のため **デフォルト 0 = 無効**。
「ブラウザ閉じて放置したら RAM 4GB (llama-server) が居残ってる」状態を防ぐには
`LLAMADOCK_H3_AUTOSTOP=600` 環境変数セットで使う。

### VRAM 解放経路 (autostop と sd.cpp の二重対策)

| 場面 | VRAM 解放の仕組み |
|---|---|
| sd.cpp 画像生成直後 | ps1 ラッパーの `Start-Sleep 1.5s` で Vulkan driver GC 待ち |
| h3-chat.py autostop 発火時 | `_stop_stack` が ComfyUI + llama-server の port kill → 各プロセスが OS に VRAM 返却 |
| 手動 shutdown | `/api/shutdown` エンドポイントが `_stop_stack` 呼び出し |
