# LlamaDock / MiniMax-H3 ハンドオフ（2026-08-16）

この文書は「GitHub クラウド上の AI が現状を読んで作業を引き継げる」ことを目的に書かれている。
コードや設定の変更後は必ずこの文書も更新すること。

---

## 1. このプロジェクトは何か

ローカル（Windows 11・AMD RX 7800 XT 16GB・RAM 96GB）で動く動画生成スタック。

- **ハーネス**: `llama-tq3`（LlamaDock 系 PS1 ランチャー群）
- **動画生成**: ComfyUI 0.33 + MiniMax H3（DiT 動画モデル）
- **キー画像生成**: Z-Image Turbo（NSFW 版 GGUF）
- **企画 LLM**: Qwen3.5-4B Uncensored（NSFW・視覚対応・CPU 推論）
- フロー: ユーザーが日本語でアイデア → 企画 LLM が打ち返しながら企画を固める → キー画像生成 → 企画 LLM が**画像を見て**英語動画プロンプトを作る → 動画生成 → **自動シャットダウン**

---

## 2. ハーネス構成（ポート / プロセス）

| サービス | ポート | 起動元 | 内容 |
|---|---|---|---|
| ComfyUI | 8188 | `select-model.ps1`（ck プロファイル） | 動画・画像生成本体 |
| **DeepSeek Harness** | 5173 | `npx @deepseek-ai/dsh@latest web` | エージェントハーネス（npx 自動インストール＋自動アップデート） |
| h3-chat（Web UI） | 8189 | `tools/h3-chat.ps1` | 企画チャット + 生成ボタン UI |
| 企画 LLM（llama-server） | 8190 | `tools/h3-chat.ps1` | Qwen3.5 企画（CPU・mmproj 視覚付き） |

- **メインメニュー**: `select-model.ps1`（＝ `llamadock`）
  - チューニングメニュー「ComfyUI tuning」（2026-08-17 から 4 項目に縮小）: `[1] plan`（推奨・ck + 企画モード）/ `[2] ck` / `[3] default` / `[4] custom`。Enter で plan。super / fast / triton / bench は `LLAMADOCK_COMFY_PROFILE` でスクリプト指定可
  - `[1] plan` を選ぶと h3-chat（企画 LLM 付き）が起動し、8189 が ready になってからブラウザが自動で開く。企画 LLM は Qwen3.5（CPU・8190・常駐・視覚対応）か Qwen3.8-27B（GPU・8191・企画フェーズのみ起動・高品質・推論 effort=medium・視覚なし）を選択できる
- **h3-chat.ps1**: `-NoBrowser` スイッチ対応 / 8190 が既に動いていれば llama-server を再利用 / 両方起動済みなら即終了（二重起動防止 3 層）
- **自動停止**: 動画完了 → ブラウザに 90 秒カウントダウン（🛑今すぐ終了 / ComfyUI だけ / キャンセル）→ サーバー側安全網として **180 秒後に** `/free`（モデルアンロード → VRAM 解放）→ ComfyUI・企画 LLM・h3-chat を全部 kill。ブラウザを閉じていても発動する
  - 実装: `tools/h3-chat.py` の `_status` 内タイマー + `_shutdown` / `POST /free`
  - 注意: 日本語 Windows の netstat 出力（CP932）を UTF-8 でデコードするとクラッシュするため、`subprocess` は bytes + `errors="replace"` で受けること（既修正済み）

### 起動コマンド（ComfyUI）
```powershell
cd C:\Users\dai86\Documents\ComfyUI
.venv\Scripts\python.exe main.py --port 8188 --listen 127.0.0.1 --reserve-vram 1.0 --use-ck-attention
```

---

## 3. モデル一覧（現時点で実際に使っているもの）

### 動画（MiniMax H3）— `C:\Users\dai86\.lmstudio\models\MiniMax-H3\`
| 種類 | ファイル | サイズ | 備考 |
|---|---|---|---|
| DiT（標準） | `diffusion_models\alpha-0.5-testing\PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors` | 21GB | int8・pruned・デフォルト |
| DiT（選択可） | `diffusion_models\10Eros-Max\10Eros_Max_h3_fl2va_beta2_pruned_nvfp4.safetensors` | 12.5GB | 10Eros-Max beta2 NVFP4（sakamakismile）・高画質・16GB VRAM 可。h3-chat UI の「動画モデル」で切替 |
| テキストエンコーダ（軽量） | `text_encoders\qwen3vl_4b_heretic_fp8.safetensors` | 4.8GB | CLIPLoader type=`krea2`・super/clipproj 系 WF で使用 |
| テキストエンコーダ（高精度） | `text_encoders\Qwen3-VL-32B-Instruct\qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors` | 15.7GB | type=`minimax`・turbo 系 WF で使用 |
| 動画 VAE | `vae\MiniMax-H3-video_vae_fp16.safetensors` | 5.2GB | |
| 音声 VAE | `vae\minimax_h3_audio_vae_fp32.safetensors` | 605MB | |
| LoRA | （ComfyUI）`models\loras\minimax_h3_turbo_4step_ckpt600_ema_V4.safetensors` | 620MB | Turbo LoRA（8step） |
| **参照 LoRA** | （ComfyUI）`models\loras\minimax_h3_ref_lora_rank_256_bf16.safetensors` | 約 1.9GB | **R2V 用**（Kijai/MiniMax-H3-experimental の loras/）。fl2va モデルに重ねるだけで参照条件付き生成（ref2va モデル不要）。h3-chat の 🔗 参照モードで使用 |
| ClipProj | （ComfyUI）`models\clip_projections\mmh3-4b-ClipProj-celeb-mlp.safetensors` | 304MB | clipproj 系 WF で使用 |

### キー画像（Z-Image Turbo NSFW）— ComfyUI `models\`
| 種類 | ファイル | サイズ | 備考 |
|---|---|---|---|
| DiT（GGUF） | `unet\z_image_nsfw_v2-Q8_0.gguf` | 7.2GB | `ComfyUI-GGUF` の UnetLoaderGGUF でロード |
| テキストエンコーダ | `text_encoders\qwen_3_4b_fp8_mixed.safetensors` | 5.6GB | CLIPLoader type=`lumina2` |
| VAE | `vae\ae.safetensors` | 335MB | |

### 企画 LLM — `C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\`
| ファイル | サイズ | 備考 |
|---|---|---|
| `Qwen3.5-4B-NSFW-ARA-Heretic-Literotica.i1-Q6_K.gguf` | 3.3GB | 唯一の企画 LLM（えろ文芸特化・Literotica / erotica チューニング） |
| `mmproj-Qwen3.5-4B-NSFW-Literotica-BF16.gguf` | 675MB | 視覚エンコーダ（旧 Qwen3.5-4B-Uncensored の mmproj を流用。同アーキテクチャで正常動作） |

旧 `Qwen3.5-4B-Uncensored-HauhauCS-Aggressive`（4.4GB）は NSFW 特化モデルへの差し替えで削除済み。

- 企画 LLM は **CPU 推論**（`-ngl 0`・`--reasoning off`）で VRAM を ComfyUI に全残し
- llama-server は **openPangu フォーク**（Qwen3.5 = Gated DeltaNet 対応が必要、`llama.cpp-openPangu-2.0-*`）。vanilla 版では Qwen3.5 が動かない
- **削除済み**: LFM2.5-2.6B-Heretic / Dirty-Muse-Writer（旧企画 LLM）、Z-Image int8 版、triton バックエンド

---

## 4. ワークフロー JSON（`h3_workflow_*.json`、API 形式）

- `h3_workflow_zimage.json`: キー画像生成（UnetLoaderGGUF + CLIPLoader lumina2 + VAE + ModelSamplingAuraFlow shift=3 + KSampler 8step/cfg1/res_multistep + ConditioningZeroOut）
- 動画ワークフローは全て node `1`=UNETLoader。h3-chat の `/api/generate` が `dit` パラメータ（`default` / `10eros`）で `unet_name` を差し替える（`tools/h3-chat.py` の `DITS` 辞書）
- `super_*`: 4B エンコーダ + ck（+triton）向け / `turbo_*`: 32B エンコーダ + Turbo LoRA / `clipproj_*`: 4B + ClipProj / `fast_*`: **spectrum + 20step（ターボLoRAなし・最高画質）** / `bench` / `src`
- `_short` は短尺、`_audio` は音声付き（音声 VAE 使用）
- **`h3_workflow_fast*.json`**（新規）: SpectrumApplyMiniMaxH3 で VRAM 節約しつつ 20step/euler/simple。Turbo LoRA を使わないためアーティファクトなし。fast=1344×768 48f、fast_short=512×320 16f
- **`h3_workflow_r2v.json` / `h3_workflow_r2v_short.json`**: 参照モード（R2V）。`MiniMaxH3ReferenceToVideo` ノード + **参照 LoRA**（`minimax_h3_ref_lora_rank_256_bf16`）を fl2va モデルに重ねる（ref2va モデル不要）。node 16 = LoadImage（参照画像）、node 6 の `ref_images.ref_image_0` に接続。プロンプトは `<Picture 1>` タグで参照画像を指定（h3-chat が自動追記）
- **`h3_workflow_r2v_fast*.json`**（新規）: 参照モード + spectrum + 20step（ターボなし）。キャラ一貫性と最高画質を両立
- 動画は `ComfyUI\output\` に `h3_turbo_audio_*.mp4` として出力、キー画像は `zimg_*.png`

### カスタムノード（ComfyUI `custom_nodes\`）
- `ComfyUI-GGUF`（UnetLoaderGGUF 用）
- `ComfyUI-ClipProj`
- `websocket_image_save.py`

---

## 5. テスト

```powershell
# 静的スイート（構文・スタイル・menu 回帰）
powershell -File test.ps1 -SkipDryRun

# 企画 LLM の視覚入力を証明する E2E（企画 LLM + h3-chat 起動中に実行）
python tools/test-plan-vision.py

# MCP ウェブ検索サーバーのスモーク（起動→initialize→4 ツール→実検索）
node tools/mcp-smoke.mjs
```
- `test-plan-vision.py`: ①合成画像を直接見せて記述照合 ②テキスト手がかりゼロで確定パスに通し、最終動画プロンプトが画像内容（色・被写体）と一致するか照合
- `tools/mcp-smoke.mjs`: MCP サーバーを実起動して `search_web` / `search_and_fetch` / `fetch_url` / `deep_research` を叩き、全項目 PASS を確認
- 最終コミット: `86c9513`（本 HANDOFF.md を追加したコミット）

---

## 6. 既知の制約・注意

- **ハードコードされた絶対パス**が多い（`C:\Users\dai86\...`）。GitHub クラウド（Codespaces 等）で動かす場合はパス抽象化が必要
- ComfyUI は **0.33 以上必須**（`--use-ck-attention` / comfy-kitchen attention）
- `--enable-triton-backend` は H3 int8 でクラッシュするため **off がデフォルト**（`LLAMADOCK_COMFY_TRITON=1` で強制、super は ck にフォールバック）
- `--fast fp16_accumulation --force-non-blocking`（fast プロファイル）は **未ベンチ**（画質リスク要検証）
- エンコーダが理解できても DiT 自体が描けない内容は出ない（32B でも同様）
- select-model.ps1 は BOM なし UTF-8 なので、**日本語を追加すると PowerShell 5.1 が Shift-JIS 誤読して構文破壊**する → メニュー文言は英語のまま保つ

---

## 7. Web GUI（`web-ui/`・パラメータコントロールパネル）

ComfyUI / h3-chat とは別系統の **依存ゼロ Web GUI**（Node 標準ライブラリのみ）。
`config/params-schema.json`（42 パラメータ）と `config/memory-presets.json`（8 プリセット）から
設定パネルを自動生成し、llama-server の起動/停止/計測/クライアント接続をブラウザから行えます。

```bash
npm start          # http://127.0.0.1:3000（node web-ui/server.js）
```

| ファイル | 役割 |
|---|---|
| `server.js` | 静的配信 + REST API（`/api/bootstrap|params|launch|stop|benchmark|results|connect|status|health|clients/health`） |
| `arg-builder.js` | スキーマ駆動の引数生成（解決順: 上書き → モデル別記憶 → `_profiles` → 既定） |
| `launch-manager.js` | 起動/停止/計測の状態機械（spawn・ready待ち・healthポーリング） |
| `results-store.js` | 実測 tok/s・VRAM を `config/run-results.json`（gitignore）に蓄積、成功 3 回以上で「推奨（実測）」認定 |
| `client-manager.js` | Cline/OpenCode/OpenClaude/WebUI/DeepResearch/LlamaAgent/ComfyUI の起動契約（ComfyUI は standalone） |
| `mock-llama-server.mjs` | 非 Windows 用シミュレーション llama-server（計測ループ検証用） |
| `app.js` / `index.html` / `style.css` | 3カラム・ダークテーマ UI |

- **Windows**: `LLAMADOCK_ENGINE_BIN` にエンジンを設定すると実 llama-server を起動（**Phase 1 配線待ち**）。
  未設定時は明確なエラー、それ以外の OS ではモックで全ループを実証済み（実測 22.3 tok/s を確認）
- **ComfyUI は standalone**: llama-server 未起動でも接続可。`LLAMADOCK_COMFYUI_ROOT` / `LLAMADOCK_COMFYUI_PORT`
  で CLI（`select-model.ps1`）と Web GUI の起動・監視ポートを共有（README「Web GUI」参照）
- 設計・API 詳細・残作業: `docs/PARAMETER-CATALOG.md`（§7 実装状況）

### MCP 検索の Serper 対応

`mcp-server.js` に **Serper API（`SERPER_API_KEY`、環境変数のみ）＋ 結果キャッシュ**
（`MCP_SEARCH_CACHE_TTL_MS`、既定 5 分・最大 200 件）を追加済み。キー設定時は auto で Serper が先頭、
失敗時は DuckDuckGo / Brave / Bing にフォールバック。SSRF ガード（`tools/safe-fetch.mjs`）は維持。

### h3-chat の R2V 参照モード（🔗 参照モード）

企画モードでキー画像を確定すると、`tools/h3-chat.py` の 🔗 参照モードにチェックを入れて生成すると
**確定キー画像を `<Picture 1>` 参照にして同一キャラ維持の動画**（`MiniMaxH3ReferenceToVideo`）が作れます。
確定画像を ComfyUI `input/` にコピーして node 16（LoadImage）へ渡し、プロンプト末尾に
`<Picture 1>` のタグ説明を自動追記。8step・Turbo LoRA + 参照 LoRA（fl2va モデルまま）。
参考: javawock7618/comfy-MiniMax-H3-workflows（R2V 2608.18.1 を解析して移植）。

---


### DeepSeek Harness（エージェントハーネス）
- **URL**: https://deepseek.com/harness/en/
- **起動**: `npx @deepseek-ai/dsh@latest web`（初回は自動インストール、以降は自動アップデート）
- **ポート**: 5173（既定）
- **ワークスペース**: `select-model.ps1` メニュー [8] または web-ui 右カラムから起動可能
- **更新**: `tools/dsh-update.ps1` が起動時にバックグラウンドでバージョンチェック＋更新を実行

## 8. 次にやること（優先度順）

1. **R2V（参照 LoRA）の実機検証** — 参照 LoRA を `models\loras\` に配置 → h3-chat の 🔗 参照モードで
   キー画像 → 同一キャラ動画のスモーク（`h3_workflow_r2v_short.json`）→ フル（`h3_workflow_r2v.json`）。
   品質・`ref_image_size`（match/max）・LoRA strength の A/B を `docs/MiniMax-H3-Tuning.md` に追記
2. **Windows 実機での web-ui 検証** — Phase 1 コア配線（`LLAMADOCK_ENGINE_BIN`・GGUF 実パス解決）、
   `/api/launch` で実 llama-server 起動、`/api/connect` の Windows 実起動（現状 `simulated`）
3. **全体ベンチのやり直し** — Z-Image + Qwen3.5 導入後、super/ck プロファイルの実測（旧実測: ck 17m19s vs default 19m26s）
4. **fast プロファイルの検証** — `--fast fp16_accumulation` の画質劣化リスクを短尺・粗画質で確認（OK なら super より速い可能性）
5. **32B vs 4B エンコーダの画質比較** — turbo（32B・NVFP4）と super（4B・fp8）を同じ複雑な日本語プロンプトで比較、意図反映度を確認
6. **GitHub クラウド移行準備** — 絶対パスの抽象化（環境変数 or 設定ファイル化）、Windows 固有コマンドの分離、CI での test.ps1 / test-plan-vision.py 実行
7. **企画モード UX 改善** — キー画像の複数案生成と比較選択、生成プロンプトのプレビュー編集
8. **新モデル調査** — 「拒否無しでもっと軽い MiniMax」「より軽量な Z-Image / テキストエンコーダ」の Reddit/GitHub 調査（必要時のみ）
