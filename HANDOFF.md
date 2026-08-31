# LlamaDock / MiniMax-H3 ハンドオフ（2026-08-19 更新）

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
| **DeepSeek Harness** | 3080 | `npx @deepseek-ai/dsh@latest web` | エージェントハーネス（npx 自動インストール＋自動アップデート） |
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

### 2026-08-20 レビュー修正（全ワークフロー検証済み）
- **`SpectrumApplyMiniMaxH3` カスタムノードを導入**（`xmarre/ComfyUI-Spectrum-MiniMax-H3` を ComfyUI `custom_nodes\` に clone）。fast / r2v_fast 系ワークフローはこのノードが無いと起動できない（依存パッケージなし・venv import 確認済み）。更新時は `git pull --ff-only`
- **r2v 系 5 ファイル**: node 6 `ref_images` が `null` のままだった不具合を修正 → `{"ref_image_0": ["16", 0]}` に接続（以前は参照画像が無視され ImageToVideo 相当になっていた）。LoadImage のプレースホルダ `h3_ref_reference.png` を ComfyUI `input\` に配置済み（実行時は h3-chat が実ファイル名に差し替え）
- **出力プレフィックスを一意化**: `clipproj_short`→`h3_clipproj_short` / `r2v_short`→`h3_r2v_short` / `r2v_short_4b`→`h3_r2v_short_4b` / `turbo_short`→`h3_turbo_short` / `turbo_short_audio`→`h3_turbo_short_audio` / `super_short_audio`→`h3_super_short_audio` / `bench`→`h3_bench` / `bench_short_audio`→`h3_bench_short_audio`。h3-chat は出力ファイルを /history API で取得するため互換性影響なし
- **`shift_audio` を全ワークフローで 6 に統一**（fast / clipproj / bench 系が 3 のままだった。ノードデフォルトは 3、turbo / super / r2v 系の調整値 6 に揃えた。`src.json` も 6.0 に更新）
- **super_audio / super_short_audio**: 未使用の二重 CLIPLoader（node 2）を削除（super / super_short は元々 node 2 なし）

### カスタムノード（ComfyUI `custom_nodes\`）
- `ComfyUI-GGUF`（UnetLoaderGGUF 用）
- `ComfyUI-ClipProj`
- `ComfyUI-Spectrum-MiniMax-H3`（fast / r2v_fast 系の SpectrumApplyMiniMaxH3。2026-08-20 導入）
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
- 最終コミット: `1d886e0`（ZCode auto-configure。その後 ZCode / Odysseus / OpenCode+Harness は削除済み）

---

## 6. 既知の制約・注意

- **コミットポリシー（2026-08-21 変更）**: 変更した作業は**必ず `git commit` + `git push` する**（旧方針の「自動 commit 禁止・ユーザー指示待ち」は廃止）。**git reset は禁止**。代わりに、このリポジトリに着手する AI は最初に直近コミットの内容をレビューしてから作業を引き継ぐこと（手順は `C:\Users\dai86\Downloads\llama-tq3-handoff-2026-08-20.md` §7）
- **ハードコードされた絶対パス**が多い（`C:\Users\dai86\...`）。GitHub クラウド（Codespaces 等）で動かす場合はパス抽象化が必要
- ComfyUI は **0.33 以上必須**（`--use-ck-attention` / comfy-kitchen attention）
- `--enable-triton-backend` は H3 int8 でクラッシュするため **off がデフォルト**（`LLAMADOCK_COMFY_TRITON=1` で強制、super は ck にフォールバック）
- `--fast fp16_accumulation --force-non-blocking`（fast プロファイル）は **未ベンチ**（画質リスク要検証）
- エンコーダが理解できても DiT 自体が描けない内容は出ない（32B でも同様）
- select-model.ps1 は BOM なし UTF-8 なので、**日本語を追加すると PowerShell 5.1 が Shift-JIS 誤読して構文破壊**する → メニュー文言は英語のまま保つ
- **投機的デコード（SpecMode）**: モデル選択後に `[1] Off / [2] MTP/NextN / [3] DSpark / [4] DFlash2` を選択可（Manual モード）。
  - MTP/NextN = built-in `*_MTP.gguf` self-draft (`--spec-type draft-mtp`). No `-md` needed (uses model_tgt directly). **Performance: O(n²) with prompt length** - fast for short prompts (<300 tokens: ~16-29 t/s) but degrades significantly for long prompts (>5K tokens: ~3-6 t/s). This is an inherent limitation of MTP architecture, not a bug. DFlash2 is recommended for long-context use. `--cache-ram 0` recommended to avoid RAM pressure. Draft acceptance improves with context (0.57→0.85) but does not offset compute increase.

  - DSpark = 外部ドラフト（erlidev `Qwen3.8-27B-DSpark-Q8_0.gguf`、`--spec-type draft-dspark`）。**AtomicBot は非対応**（unknown spec type で起動失敗）→ **TurboTan ビルド限定**。select-model.ps1 は DSpark 選択時に TurboTan へ自動切替。ドラフトパスは env `LLAMADOCK_DSPARK_DRAFT` で上書き可
  - DSpark ドラフトは主モデル一覧・planner 候補から除外済み（draft 専用のため主モデルとして起動しない）
  - h3-chat.py の planner 詳細設定に DSpark チェックボックスあり（GPU planner のみ。有効時は TurboTan ビルドに切替）
  - DFlash2（llama.cpp PR #27342）: upstream PR ブランチから ROCm 7.1 HIP (gfx1101) ビルド済み（`C:\Users\dai86\Downloads\llama-dflash2\build-rocm71`）。`--spec-type draft-dflash` + DFlash2 チェックポイントで使用可。ドラフト: incoai/Qwen3.8-27B-DFlash2-GGUF (Q4_K_M)。env `LLAMADOCK_DFLASH2_DRAFT` で上書き可
    - **バグ修正済み（2件）**: (1) `ggml/src/gguf.cpp` — DFlash2 GGUF の `general.tags` が ARRAY of ARRAY（ネスト配列）なのにパーサーが1段しか対応していなかった → ネスト配列をスキップするロジックを追加 (2) `common/speculative.cpp` — ドラフトモデルロード時に `params.model.path`（メインモデル）を参照していたバグを `model_path`（ドラフトモデル）に修正
    - 選択肢: `[4] DFlash2` (SpecMode)。DFlash2 エンジンに自動切替。Draft GGUF が見つからない場合はエラー
    - reasoning effort は自動で `low` に設定（思考量抑制）。`--ChatTemplateKwargs` で上書き可（例: `'{"reasoning_effort":"medium"}'`）
    - ベースモデル `ggml-org/Qwen3.8-27B-GGUF:Q4_K_M` での動作確認済み。heretic-ara でも動作確認済み（アーキテクチャ一致ならOK）
    - **実測（2026-08-21, RX 7800 XT / ctx 4096 / fa on / KV q8_0+q4_0）**: 純正 Qwen3.8-27B 系では acceptance ≈0.74。一方 **heretic-ara.i1-Q4_K_S では acceptance 0.286・生成 8.07 t/s とベースライン 16.02 t/s の半分に悪化**（ドラフトは純正ベース分布で学習されており、abliterated 系改変モデルとは分布ミスマッチ）。**ベースから離れたファインチューンには DFlash2 非推奨**
    - VRAM 目安: 主モデル 14.7GB（Q4_K_S）+ ドラフト 1.09GB（Q4_K_M）で ctx 4096 がギリギリ。ctx 16384 以上は OOM リスク大
- **uncensored MTP モデル追加（2026-08-21 ダウンロード・実測）**: `.lmstudio\models\` に 3 本追加（すべて MTP 内蔵・16GB VRAM 完全搭載・AtomicBot 動作）。bench 条件: ngl99 / fa on / KV q8_0+q4_0
  - **HauhauCS Aggressive IQ3_M**（11.9GiB・3.66bpw）: tg128 18.33、**draft-mtp 実効 25.66 t/s（acceptance 0.673）= 現行最速**。人気 No.1（357K DL）
  - zerodigest YMQ-S（12.53GB・2.5bpw 表記）: tg128 **18.70**（bench トップタイ）
  - hotdogs abliterated mtp-IQ3_M（11.9GiB・3.66bpw）: tg128 18.11
  - 従来の soyaakinohara 3.69bpw-12GB: tg128 18.67 / draft-mtp 22.28 t/s → **HauhauCS が +15% 上回り乗り換え推奨**
  - 教訓: TG は帯域上限で 4 本とも ±3% 差のみ。差が付くのは draft-mtp の acceptance（0.55〜0.67）と品質（bpw・検閲除去手法）
- ✅ **TurboTan b10536 ビルド修復済み（2026-08-21）**: 再ビルド分が GPU で動かない原因は `ggml-hip.dll` が `hipblas.dll` を名前指定インポートするが、ROCm 7.1 同梱は `libhipblas.dll` というファイル名のためロード失敗するだけだった → **b10536 ルートに `libhipblas.dll` を `hipblas.dll` としてコピー**で復旧（backend=ROCm、bench: pp512 223.4 / tg128 20.21 t/s・AtomicBot 比 TG +8%）。**ビルド更新のたびにこのコピーが必要**
  - このビルドは `-ctk/-ctv turbo3/turbo4/tq3_0` を拒否する（select-model.ps1 の KV probe が自動で非表示化済み）
- **--n-cpu-ffn 統合（2026-08-22）**: select-model.ps1 に `-CpuFfnLayers` 追加（""=off 既定 / "all"=--cpu-ffn / 数字=--n-cpu-ffn N）。起動時プローブで PR #26622 非対応ビルドはエラー終了（プローブ自体も ROCm DLL PATH 保護付き）。**通常運用では使わない**こと（実測 TG −65〜91%）→ 詳細は `docs/benchmark-report-20260822-ncpuffn.html`
- **KV キャッシュ戦略の改訂（2026-08-22, 新ビルド bf29aa37c base）**: 新カーネルでは KV 量子化のデクォン overhead が支配的。HauhauCS IQ4_XS 実測: **f16/f16 KV で pp512 558.7 t/s（q8/q4 比 +134%）・tg512 17.1 t/s（+9%）**。ただし f16 KV は VRAM 2倍必要 → **ctx ≤8K なら f16、16K 以上は q8_0+q4_0 が現実解**。旧「KV q8/q4 最適」所見は旧ビルド限定の知見に訂正
- **MTP acceptance は日変動大**: 同一モデル・同一プロンプトでも 0.36〜0.78 の幅を実測 → draft-mtp の効果はレンジで見ること（IQ3_M+MTP 実効 18〜28 t/s）。速度比較には llama-bench（r3 平均・spec 無し）を使い、MTP 込み数値は参考値扱い
- **webgui.bat 追加（2026-08-22）**: フロントドア `[3] Web GUI` または直接 bat で `http://127.0.0.1:3000` を起動。PORT 環境変数は bat 内で 3000 に固定済み
- ⚠️→✅ **CPU フォールバック無音退化問題（2026-08-22 特定・対策済み）**: `-ngl auto` は起動瞬間の空き VRAM で配置を決めるため、直前インスタンスの解放ラグやデスクトップアプリの VRAM 占有があると **GPU ほぼ放置・6コア CPU 推論に黙って退化**する（実害: Cline リクエスト 132 秒、GPU 使用率 0.6%）。VRAM 空き十分なら 32K でもフル GPU（132層/CPU 0）を確認済み。**対策実装**: ①起動前 `Wait-VramRelease` ②ready 後の速度プローブ（<8 t/s で赤字警告）③ `-NglLayers <n>` 強制指定。プローブで「ok」表示を確認してから作業すること
- 🔬 **ROCm fork 遅延の根本原因確定（2026-08-22 / test-backend-ops support 全スキャン）**: AtomicBot HIP バックエンドは **全 22,454 プローブ中 7,831（35%）が NOT SUPPORTED**。致命的欠落: `FLASH_ATTN_EXT` 4,329件（attention 本体！）、`OUT_PROD` 1,216、`MUL_MAT` 型組合せ 446、`SET_ROWS`(TQ系含む)、f16 unary 全滅（SIGMOID/SOFTPLUS/GELU 等）。→ qwen35 ハイブリッドモデルでは attention/gating の一部が**レイヤー毎に CPU フォールバック**し、GPU 放置・CPU 6コア・長ctx PP 逓減（88→22 t/s）が発生する。Vulkan 上流は全 op 実装済みで同一モデルが compute0 を正常使用。**対策**: 通常運用は OfficialVulkan（実装済み）。ROCm fork の恒久対策は HIP カーネルのビルド欠落解消（恐らく hipcc コンパイル失敗が supports_op 縮退に波及）— 要ビルドログ調査
- ✅→✅ **ROCm fork HIP カーネル欠落の恒久修正完了（2026-08-24 / build-rocm71-fa）**: 根本原因は「ビルド壊れ」ではなく**FAカーネルの焼き込み不足**だった。`GGML_HIP_ROCWMMA_FATTN=OFF`（RDNA3用WMMA FA未定義・rocWMMAヘッダも未導入）+ `GGML_CUDA_FA_ALL_QUANTS=OFF`（量子KV FAの一部のみコンパイル）。修正: rocWMMA rocm-7.1.1 を `C:\llama-tq3-deps\rocWMMA` に clone（version header 2.1.0 はスクリプトが自動生成）し、新規ツール **`tools/build-atomicbot-rocm71-fa.ps1`** で両フラグ ON + `-IC:/llama-tq3-deps/rocWMMA/library/include`（HIP/CXX 両方の flags に必要。.cu は LANGUAGE CXX でコンパイルされるため）で再ビルド → `C:\llama-tq3\build-rocm71-fa\bin\`。**結果**: NOT SUPPORTED 7,831→5,234（FLASH_ATTN_EXT 4,329→1,732、残りは上流未対応の iq4_nl KV・特殊ヘッドサイズ>256・TQ系フォーク固有型）。精度テスト 835 OK / 0 FAIL。実測（Qwen3.8-27B IQ4_XS・ngl99・fa1）: 新 pp512 187.8 / tg128 20.63 / pp4096 169.67 vs 旧 190.0 / 20.2 / 182.28 = **同等以上・長ctx逓減なし**。select-model.ps1 は build-rocm71-fa を優先するよう変更済み（env `LLAMA_TQ3_ATOMICBOT_SERVER` で上書き可）。GDN ハイブリッド層は引き続き HIP 未実装のため qwen3.5-GDN モデルは openPangu/Vulkan を使用すること
- ⚙️→✅ **ランチャー既定値の見直し（2026-08-24）**: ① **既定コンテキストを 32K に統一** — 旧ロジックはモデルサイズだけで判定し <12GB モデルで 128K を推奨、16GB VRAM カードでは KV がシステム RAM に溢れて無言で激遅になっていた。コーダーエージェントは自動コンパクションがあるため 32K で十分（DeepSeek のみ従来通り 16K 推奨、RAM セーフティ天井は尊重）。② **supervisor 自動再起動をオプトイン化** — select-model.ps1 は従来無条件に `-AutoRestartServer` を渡しており、タスクマネージャー等で手動 kill した llama-server がバックオフ付きで最大 5 回勝手に復活していた。新スイッチ **`-AutoRestart`** を付けた時のみ引き渡す（デフォルト OFF）。手動 kill 時は supervisor が gateway を道連れにクリーン停止して終了する。即時復活が欲しい特殊ケースのみ `llamadock ... -AutoRestart`
- 🔬→❌ **-ub 拡大は gfx1101 では逆効果（2026-08-24 実測）**: llama-bench A/B（Qwen3.8-27B IQ4_XS・ngl99・fa1・pp4096/tg128）で ub 512/1024/2048 = pp 173.3 / 148.1 / 130.6 t/s。**デフォルト 512 が最速**で、増やすほど ROCm GEMM カーネル効率が落ちる。tg は ub 無影響。→ `-Ubatch` パラメータは追加済みだが通常運用では使わない（将来の大型モデル/カード変更時の保険）。併せて MTP 調査： 手元の HauhauCS 27B MTP-GGUF が現行ベスト。リポジトリ最新版には FastMTP（文書 TG 最大 3.02 倍の報告）と K_P 量子が追加されているため、**ローカルファイルの更新要確認**。多言語 acceptance 低下の報告あり（中国語約 40%）→ 日本語ワークロードでの A/B を推奨
- 📝 **運用メモ（2026-08-24）**: ① **ROCm ドライバーと HIP SDK はペアで更新**すること — HIP ランタイムは `C:\WINDOWS\SYSTEM32\amdhip64_7.dll`（ドライバー側）をロードするため、片方だけ更新するとバージョン不整合で DLL 解決が壊れる。② **`-ModelIndex` は位置依存** — `.lmstudio\models` にモデルを追加/削除すると番号がずれる。スクリプトやショートカットから起動する場合は `-ModelName` 的な安定指定が将来課題（現状はメニュー番号 or 既定）。③ web-ui の launch-manager に CLI 相当のガードを移植済み（ポート解放待ち 20s + ready 後 GPU プローブ <8 t/s 警告、結果は `/api/status` の `gpuProbe` とログに反映）
- ✅ **OfficialVulkan エンジン実用化（2026-08-22）**: 公式 prebuilt b10549 を `C:\llama.cpp-vulkan\` に配置済み（select-model の既定パスと一致するため `EngineMode OfficialVulkan` 選択のみで使用可）。33/33 フル GPU オフロード確認。**選定理由**: AtomicBot/TurboTan fork は hybrid GDN（gated-deltanet）層の HIP カーネルが未実装で CPU フォールバック → compute0 放置・CPU 584%・長プロンプト PP 逓減（88→22 t/s）。Vulkan は GDN も含め GPU 処理され compute0 を正常使用、KV 型に依存しない安定速度（IQ4_XS: q8/q4 = pp419/tg17.42、f16 = ほぼ同一）。draft-mtp / cache-reuse / context-shift は上流機能なので使用可。**turbo KV / --n-cpu-ffn / DFlash2 はフォーク専能のため、これらを使う場合のみ ROCm fork を選択**
- **Vulkan A/B 結果（2026-08-22, 公式 b10549 prebuilt / IQ4_XS）**: pp512 419.4 / tg512 **17.42**（q8/q4 KV）。**f16 KV でもほぼ不変**（422/17.50）= Vulkan は KV 型に左右されない。ROCm 新ビルドは f16 KV 時の pp 559 が最高だが q8/q4 だと pp 239 に落ちるため、**「KV 設定を気にせず安定した速度が欲しいなら Vulkan」が結論**。TG は両バックエンド同等（~17.5）。prebuilt 実績あり → `OfficialVulkan` エンジンの実パス復活候補
- **アージェンティック品質プローブ（IQ4_XS vs IQ3_M）**: 自己検証・タスク分解・長鎖計算・指示階層の4種で両者とも全合格、有意差なし。bpw 差（3.66 vs 4.25）はエージェント能力に影響しない → **Q4_K_P/Q5 への拡張は保留**（IQ4_XS で十分）

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
| `client-manager.js` | Cline/OpenCode/WebUI/LlamaAgent/ComfyUI/DeepSeekHarness の起動契約（ComfyUI は standalone） |
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

**参照モードの生成フロー（2026-08-28 変更）**: 参照モード ON + 画像選択済みで「生成 ▶」を押しても、
いきなり動画生成は始まらない。企画 LLM に参照画像を見せながら「どんな動画にするか」をまず相談し、
`[FINAL_PROMPT]` が確定して「🎬 この企画で生成 ▶」を押してから生成が走る（企画モードと同じ確認フロー）。
🗂 で単独に画像を選んだだけでも内容を相談して決められるようになった。

---


### DeepSeek Harness（エージェントハーネス）
- **URL**: https://deepseek.com/harness/en/
- **起動**: `npx @deepseek-ai/dsh@latest web`（初回は自動インストール、以降は自動アップデート）
- **ポート**: 3080（既定）
- **LLM バックエンド**: ローカル llama.cpp（8090 gateway 経由）。`Open-DeepSeekHarnessClient` が起動時に
  `DEEPSEEK_BASE_URL=http://127.0.0.1:8090/v1` と `DEEPSEEK_API_KEY=not-needed` を環境変数として渡す。
  dsh の `llm-deepseek` アダプタは `baseURL` を `config.baseURL → $DEEPSEEK_BASE_URL → api.deepseek.com`
  の順で解決し、`/chat/completions` を叩く（llama-server の `/v1/chat/completions` と一致）。
  環境変数のキーは credentials-local が `source:env` として `configured:true` を返すため、
  Web UI の「Add an API key」オンボーディング画面もスキップされる。
- **ワークスペース**: ワークフロープリセット [7]（モデル選択→llama-server 起動→dsh 起動）またはワークスペースメニュー [7]
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

---

## 9. E2E テスト結果（2026-08-18 実施）

3 パターンの E2E テストを実施し、全パターン成功:

| パターン | 企画LLM | 画像生成 | 企画LLM(動画) | 動画生成 |
|---|---|---|---|---|
| R1_playful_innocent | 74s | 80s | 97s | 903s (~15分) |
| R2_reluctant | 62s | 90s | 108s | 331s (~5.5分) |
| R3_crying | 68s | 40s | 110s | 1163s (~19分) |

品質比較テスト:
- 10Eros NVFP4: 1940s (~32分) — int8 との比較用
- Qwen-Image 2512: 1143s (~19分) — Z-Image との比較用

FPS 24fps 修正済み（映像 5.17s = 音声 5.17s、同期確認済み）。
音声 RMS 分析（tmp-audio-analyze.py）で R2/R3 の喘ぎ声品質を評価済み。

### フレーム品質評価（2026-08-19・数値メトリクス方式）

**重要**: テキスト専用モデル（qwen3.8-max-free 等）のセッションでは PNG フレームを Read で直接開かないこと。画像 part がセッション履歴に入り、以降の全ターンが 400（"must be a text part"）で永続失敗する。視覚評価は PIL の数値メトリクス（ラプラシアン分散＝シャープネス）か、視覚対応モデル/別セッションで行う。

抽出フレーム（tools/tmp-frames/、各動画 f000〜f103 の 6 枚）のシャープネス（ラプラシアン分散、高いほどくっきり）:

| 動画 | fps | 映像/音声 | シャープネス範囲 | 所見 |
|---|---|---|---|---|
| 00012 (R1) | 12fps | 10.33s/5.17s（修正前の旧生成物） | 180〜296 | 中程度・やや暗め(mean~117) |
| 00013 (R2) | 12fps | 10.33s/5.17s（修正前の旧生成物） | 83〜143 | 低め・暗い(mean~93)・後半ぼけ増加 |
| 00014 (R3) | 12fps | 10.33s/5.17s（修正前の旧生成物） | 43〜58 | かなりぼけ・暗い(mean~80) |
| 00015 (10Eros) | 24fps | 5.17s/5.17s ✅同期（修正後） | 470〜648 | 最もシャープ・明るい(mean~114) |

- 00012〜00014 は fps 修正**前**の生成物なので 12fps・2倍速ズレは想定内。00015 が修正後の初生成で同期確認済み
- 10Eros NVFP4（00015）が int8（00012-14）よりシャープネス約 3〜10 倍高い → 画質優位が数値でも確認
- ASR（faster_whisper）: R2「やだ、そんな、見ないで」・R3「いや、でも」は指定セリフと完全一致、R1 も「見たい」検出 → 音声・セリフは合格

### キー画像 zimg vs qimg 比較（2026-08-19・同解像度正規化）

生値のラプラシアン分散は解像度依存（512x320 vs 1344x768）で不公平なため、全画像を 512x320 に LANCZOS リサイズして比較:

| 画像 | 元解像度 | sharpness@512x320 | mean |
|---|---|---|---|
| zimg_00014 | 512x320 | 287.9 | 90.3 |
| qimg_00005 | 1344x768 | **357.8** | 93.5 |
| qimg_00006 | 1344x768 | 275.3 | 89.8 |
| qimg_00007 | 1344x768 | 280.2 | 97.6 |
| qimg_00008 | 1344x768 | 207.1 | 85.6 |

- qimg 平均 280.1 vs zimg 287.9 → **同解像度ではほぼ同等**。qimg の優位は「解像度（1344x768）による細部再現」であり、ピクセル単位のシャープネス自体は zimg も健闘
- 仮説「qimg の方がシャープであるべき」は部分的に確認: 00005 は明確に上、00006-00008 は zimg と同程度
- 結論: prod の qimg 採用は「高解像度で細部（レース・肌質感）が潰れにくい」点が主眼。速度重視の draft は zimg で十分

### キー画像の視覚評価（2026-08-19・Qwen3.5-4B 企画LLM 8190 で実施）

数値メトリクスでは判定できない「レースの細部・肌質感・解剖学的破綻」を、4B 企画 LLM（mmproj 視覚付き・8190）に評価させた。結果は tools/vision-eval-results.json に保存。

| 画像 | レース | 肌質感 | 解剖学 | シャープネス |
|---|---|---|---|---|
| zimg_00014 | 細部あり・実布のクリスプ感に欠ける | 自然・毛穴/欠点あり | 破綻なし | 6/10 |
| qimg_00005 | **ぼやけ・ソフト・細部不足** | **AIプラスチック感・毛穴なし** | 破綻なし | 6/10 |
| qimg_00006 | 細部あり・ややソフトエッジ | 自然・毛穴/欠点あり | 破綻なし | 7/10 |
| qimg_00007 | **細部良好・スカラップ縁/布質感リアル** | **自然・毛穴/頬の赤み/欠点あり** | 破綻なし | 7/10 |
| qimg_00008 | 細部あり・中央カップ部ややソフト | やや滑らか・毛穴は控えめ | 破綻なし | 7/10 |

- **qimg_00007 が最良**（レース・肌・解剖学すべて良好、7/10）
- qimg_00005 は数値シャープネスは高かったが視覚評価では最下位（プラスチック感・レースぼやけ）→ **数値メトリクスと人間の視覚評価は一致しない場合がある**。品質判定は視覚評価を優先すべき
- 全画像で解剖学的破綻なし（手の指・四肢の異常は検出されず）
- 4B 企画 LLM での視覚評価は実用レベル。ただし細部の粗（00005 のプラスチック感）も見抜けるため、品質ゲートとして十分機能する

### h3-chat UI 改善（未コミット → 本コミットで反映）
- セグメントコントロール（動画モード 4 択 → 6 択 pill UI）
- 長さ選択ドロップダウン（5/10/15 秒）
- 詳細設定パネル折り畳み（動画モデル・キー画像エンジン）
- プロンプト強化: 服装整合性・表情多様性・素人感（handheld camera, amateur style）
- 音声解析パーサー修正（multi-line/single-line 両対応）
- 企画 LLM 候補の自動検出（.lmstudio\models スキャン）
- 企画 LLM パラメータ UI 化: KV Key/Value 圧縮、Flash Attention、Reasoning Effort/Budget を詳細設定パネルから変更可能（`/api/plan-settings` エンドポイント経由）

### h3-chat UI 修正 + デザイン刷新（2026-08-21・commit 036e2dd）
ユーザー報告「UI がおかしい」の原因を DOM 実測で特定し修正:
- **CSS コメント破損**: `<style>` 内に Python 風 `# コメント` が混入し、CSS パーサーが後続の `.seg { ... }` ルールごと無効化していた → モード pill が横並びにならず縦積み。`/* */` に修正
- **未定義変数**: `#planparams` の `color:var(--fg)`（未定義）→ `var(--text)` に修正
- **フッター圧縮崩れ（本命）**: フッターが 1 行の flex に 11 要素を詰め込み、メイン入力欄が幅 26px・音声設定が 39px まで潰れていた → 4 段構成に再構築（①モード pill + 長さ ②企画/参照トグル + ボタン群 ③詳細設定・音声パネルを左右 2 列 grid ④全幅入力欄 + 生成ボタン）。入力欄は 1144px に復活
- **btn-reset 表示バグ**: CSS `#btn-reset{display:none}` に対し JS が `style.display=""` で表示しようとして CSS が勝り永遠に出ない → `"inline-block"` に修正
- **デザイン刷新（シネマスタジオ調）**: シアン〜ブルーのグラデーションアクセント、発光ステータスドット、グラデーション生成ボタン、回転マーカー付き折り畳みパネル、ガラス風ヘッダー/フッター
- 検証: HTML タグバランス（Python HTMLParser で BALANCED）・ブラウザ DOM 実測で pill 横並び/パネル開閉/企画モードトグルを確認済み


## Vulkan Engine Support
- OfficialVulkan: C:\llama.cpp-vulkan\llama-server.exe
- GDN layers are GPU-accelerated (unlike AtomicBot/ROCm where they fall back to CPU)
- Recommended for Qwen3.5/3.8 models
- select-model.ps1 now shows engine selection prompt for regular GGUF models
- llamadock.bat accepts -EngineMode parameter (e.g., llamadock.bat -EngineMode OfficialVulkan)

## 静的監査 + モデル更新調査（2026-08-24・GPU稼働中のため動的検証は保留）

### ComfyUI ワークフロー静的監査（完了）
- 全ワークフローの DiT↔CLIP エンコーダ型ペアリング整合確認: **不一致ゼロ**
  （4B=krea2 / 32B NVFP4=minimax、shift_audio=6 統一、参照モデルファイル全て実在）
- テンプレート DiT を旧 `alpha-0.5-testing\PinkCherry int8 v0.5-alpha`(21GB) →
  `10Eros-Max\10Eros_Max_h3_fl2va_beta2_pruned_nvfp4`(11.7GB) に全23ファイル更新。
  h3-chat の DITS 既定と一致。PinkCherry は dit=pinkcherry キーで選択可能のまま
- `h3_workflow_super_audio.json` の shift_audio 6.0(float)→6(int) 表記統一
- H3-Multishot カスタムノードは不要確定: README / model-notes.json / docs/PARAMETER-CATALOG.md の
  記述を「コア同梱 `nodes_minimax_h3.py` で代替」に修正済み（R2V 含め動作確認済み）
- 企画 LLM メニュー実機確認: 既知エントリの削除済みモデル(finex666/lemonyins/mradermacher パス)は
  自動で非表示になり、ディスキャン分(Ornith APEX lite / HauhauCS IQ3_M・IQ4_XS / Qwen3.5-4B /
  Huihui TQ3_4S)が全件表示されることを確認。knownPaths 重複排除も正常。
  注意: Huihui TQ3_4S を企画 LLM に選ぶと AtomicBot では読めない(TQ3 量子化は専用エンジン必要)

### モデル更新調査（HuggingFace、2026-08-24 時点）— 要 GPU 検証
- [要検証] **TenStrip/10Eros-Max 推奨サンプラー設定**: turbo モデルで er_sde/simple 6step +
  カスタムシグマ `[1.00, 0.94, 0.83, 0.72, 0.55, 0.30, 0.10, 0.00]` にするとモーションノイズが
  消えるとのこと。現行 Euler/Beta から GPU 空き後に A/B 比較推奨
- [要検証] **drbaph/MiniMax-H3-Turbo-Lora-ComfyUI**（約4日前更新）: lightx2v 公式 Turbo の
  FL2V/**Ref2V** ダイナミックランク LoRA(BF16) を新収録。Ref2V 版は現行
  `turbo_4step_ckpt600_ema_V4 + ref_lora_rank_256_bf16(Kijai)` のスタックを単体置換できる可能性。
  ガイド: 6step=速度品質両立 / 8step=品質(Euler/Beta, video shift 12, audio shift 4-6)、Spectrum 併用可
- [情報] PinkCherry 系最新は **beta-0.6**（int8_convrot、8/12 変更ログ「t2v 修正・fluids 改善」）。
  ローカル v0.5-alpha より新しいが 10Eros beta2 との優劣は未検証（dit=pinkcherry 差し替えで A/B 可）
- [情報] 10Eros 本体(TenStrip) は6日前に更新があるが派生量子化は Beta2 表記のまま
  （Abiray ref2va-Beta2-GGUF は1日前更新）→ **beta2 が現行最新**と判断。追加ダウンロード不要
- [情報] Ornith 公式 GGUF(ornith-ai) が約19時間前にリフレッシュ（Q4_K_M〜Q8_0 標準クォンタのみ、
  MTP/APEX なし）。ローカルの gbuzhf APEX I-Mini-v2D-lite は別系統。代替として
  huihui-ai/Huihui-Ornith-1.5-35B-A3B-abliterated（約5時間前更新）あり
- [見送り] AIconjured Qwen3.8-27B-HauhauCS-Aggressive Q8-NVFP4（約15時間前）— llama.cpp 系は
  NVFP4 非読み込みのため不採用
- [注意] ComfyUI コア 5ab2f7a(8/19) → eb8cad7 更新あり。ComfyUI-GGUF ノードが 2026-01-12 で止まって
  いるため **コア + GGUF ノードをセットで更新**すること（コア単独更新は非整合リスク）

### GPU 空き後の動的検証チェックリスト
1. er_sde + 7step シグマ vs 現行 Euler/Beta の A/B（turbo_short_audio で同一シード比較）
2. lightx2v Ref2V dynamic-rank LoRA 単体 vs V4+Kijai ref スタック比較（r2v_short）
3. ComfyUI コア更新後、主要ワークフローの API プロンプト投入検証

### 2026-08-24 レビュー指摘修正
- repair-hipblas-dll.ps1: ルート刷新 — ExpertsLaguna/TurboQuant HIP ビルド(C:\Users\dai86\llama-cpp-turboquant[-experts-laguna]\build-hip\bin)を追加。実体のない C:\llama-tq3-turbotan と hipblas 不要の C:\llama.cpp-vulkan を削除、C:\llama-tq3\build-rocm71-ffn\bin を追加(vulkan/deprecated は意図的除外をコメント明記)
- launch-manager.js: waitForPortClosed の個別ヘルスプローブタイムアウト 800ms→2500ms。終了処理中で応答が遅い旧インスタンスを「ポート解放済み」と誤判定して新spawnがバインド競合するレースを防止
- web-ui: GPU オフロードプロープ結果をメトリクスチップ m-gpu で常時表示(index.html 4つ目の metric / style.css repeat(4,1fr) / app.js 描画+ツールチップ、ok=false は「失敗」表示)
- select-model.ps1: LLAMADOCK_VISION=on でも mmproj がモデル横に無い場合は Yellow 警告を出して続行(サイレント無効化の解消)/ -Ubatch に 4096 上限クランプ+env 値 Trim(異常値で起動ごと落ちるのを防止)
- tools/build-atomicbot-rocm71-fa.ps1: 冒頭コメントのファイル名を現名称に修正
- 検証: npm test 15/15、node --check (app/launch-manager/server) OK、PS Parser 全ファイル OK

### 2026-08-25 企画 LLM モデル選択式化（GPU 固定パスの解消）
- 症状: 「企画 LLM を起動できませんでした（モデルまたは llama-server が見つかりません）」
- 根因: GPU プランナー既定が実在しないパス（C:\llama-tq3uild-rocm71in\llama-server.exe +
  soyaakinohara 12GB gguf。モデル整理で .lmstudio\models から削除済み、build-rocm71 ツリー自体も
  壊れビルドとして非推奨化済み）。h3-chat.ps1 / select-model.ps1 の known エントリも同様に消滅
- tools/h3-chat.py:
  - scan_plan_models() 追加: .lmstudio\models を走査して企画 LLM 候補を列挙
    （select-model.ps1 の Get-PlanModelCandidates 同等規則: mmproj/-of-/DSpark/DFlash2 除外、
    同ディレクトリ mmproj を自動ペアリング、13B 以上 or 6GB 超を GPU 判定）
  - 既定モデルのハードコード廃止 → スキャンから自動選択（GPU: 視覚あり・15.5GB 以下・小さい順。
    CPU: Qwen3.5-4B を優先、無ければ最小候補）。LLAMADOCK_PLAN_MODEL/MMPROJ env があれば優先
    （mmproj 未指定ならモデル横から自動ペア）
  - llama-server バイナリをフォールバックチェーン化: GPU = TurboTan(b10536) → AtomicBot FA →
    旧 build-rocm71 / CPU = TurboTan → AtomicBot FA。TurboTan 先頭は実測根拠あり
    （AtomicBot FA は 27B MTP モデルで 1.9 t/s しか出ず plan が 300s タイムアウト、
    TurboTan は同一条件で 1m15s 完走 → GPU プランナー用途では FA ビルドを使わないこと）
  - 新 API: GET /api/plan-models（候補一覧+現在选择+稼働状況）、POST /api/plan-model
    （実行中 planner を停止してモデル/GPU・CPU/ポート/バイナリを実行時切替。
    次メッセージから新モデルで自動起動。--plan-url 指定時は外部エンドポイント優先の注意書き付き）
  - UI: 詳細設定パネルに「企画 LLM モデル」ドロップダウン追加（導入済み GGUF 一覧・
    サイズ/GPU・CPU/視覚表示、切替状態表示）
- h3-chat.ps1 / select-model.ps1: 消滅済み GPU エントリ（soyaakinohara/lemonyins/mradermacher/
  finex666）を現行インストールへ更新。キー対応: Qwen3.8-27B-GPU=HauhauCS IQ3_M(11.9GB)、
  Qwen3.8-27B-GPU-Vision=HauhauCS IQ4_XS(14.6GB)、新キー Qwen3.5-A35B-GPU-Vision=
  YTan2000 Huihui-Qwen3.5-A35B TQ3_4S(12.4GB)。GPU 判定は名前列挙から .Gpu フラグ参照へ簡素化
- 検証: py_compile OK / PS Parser OK / GET・POST API 実機テスト OK / GPU planner 実起動確認
  （HauhauCS IQ3_M + TurboTan、port 8191、企画応答 1m15s）/ CPU へ戻す切替も確認済み

## 2026-08-28 Qwen-Image 4候補の明示保証 + UI キャッシュ対策

- 報告: 「Qwen-Image 2512（高画質・4候補）」のラベルがあるのに 4 候補にならない
- 調査結果: 生成・表示のコードは既に 4 候補対応済みだった
  - h3_workflow_qimage.json の EmptySD3LatentImage は batch_size=4
  - ComfyUI 実績: 8/17・8/18 の各実行で 4 枚ずつ保存済み（計 8 ファイル、全て別 md5 = 別内容）
  - /api/status は ComfyUI 履歴の全出力を列挙し、JS ギャラリーも全候補をグリッド表示
- 対処（commit 5ea2ae9）:
  - IMG_ENGINES に batch_size を明示（qimg=4 / zimg=1）。_zimg ハンドラーが latent ノードの
    batch_size を毎回設定するため、ワークフロー JSON が編集されても 4 候補が保証される
  - _html() に Cache-Control: no-store を追加。UI はサーバー内蔵 JS なので、
    ブラウザに古い 1 枚表示版ページがキャッシュされる事故を防止
- 未コミット: tools/h3chat-restart.log.err（再起動ログ、コミット対象外）
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 ボタン無反応のサイレント失敗を全修正（commit 7f29fdd）

- 報告: 「🎬 このプロンプトで生成 ▶」が出たが押しても何も起きない
- 根因: 無言 return のサイレント失敗が 3 種 + 無限リトライ 1 種
  1. showManualPrompt は busy 中でも開けてしまう → 開いた後 🎬 を押しても
     genPlanLast の busy ガードに当たり無反応
  2. useManualPrompt が document.querySelector("#manual-prompt") で読むため、
     手動プロンプト UI を複数回開くと古い（空の）textarea が先にヒットして無反応
  3. 空プロンプト・busy・プロンプト未確定で無言 return
  4. poll(): サーバーが success + videos 空を返すと v.filename が TypeError →
     3 秒ごとの無限リトライで「生成中…」のまま黙り続ける
- 修正内容:
  - useManualPrompt(btn): btn.closest(".msg") 内の textarea を読む（スコープ解決）
  - showManualPrompt / useManualPrompt / genPlanLast / genImage / confirmImage:
    busy・空・未確定の各 return に ⚠ メッセージを表示
  - poll: videos 空なら「出力が見つかりませんでした」エラー表示（無限リトライ廃止）
  - pollImage: jobCancelled を尊重（キャンセル後もポーリングが続く問題を修正）
  - genImage: jobCancelled を false にリセット（video 側と整合）
  - cancelCurrent: ジョブ無し（企画 LLM 応答待ち）でも理由メッセージを表示
- 検証: py_compile / node --check 済み。モックサーバー（port 9190、GPU 不使用）で
  全パス動作確認: 空プロンプト警告 / 複数 textarea スコープ / busy ガード /
  空 videos エラー / 画像生成中キャンセル
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 参照モードで内容未決定のまま生成が直行する問題を修正

- 報告: 「参照モード、画像選択、生成おすとどんなものにするかも決まらずに動画生成始まってしまった」
- 根因: send() で 企画モード OFF + 参照モード ON + 画像選択済み だと、入力テキストが
  そのまま動画プロンプトとして /api/generate に直行していた。本来 参照モードは
  企画モードでキー画像を確定して使う想定だったが、🗂 で単独に画像を選べると
  「内容を相談して決める」ステップが丸ごと抜けていた。
- 修正内容（企画モードと同じ"相談→確認→生成"フローに参照モードを乗せる）:
  - send(): 参照モード ON（画像選択済み）なら /api/generate へ直行せず、
    planStage="video" として企画 LLM 相談（plan()）へルーティング。
  - 最初の1ターンは ref_start=true を付け、サーバー側で「いきなり [FINAL_PROMPT] を
    作らず、参照画像をどんな動画にするか 1〜2 個の質問で相談して」という指示に
    差し替え（__CONFIRM_IMAGE__ と同様）。添付画像は「1フレーム目」ではなく
    「同一キャラを保つ参照画像」として説明する note を付与。
  - 2ターン目以降は ref_start=false（通常の video 段階の対話を継続）。
    相談フラグ refConsultActive は 画像再選択 / 企画リセット で解除。
  - plan(): 動画段階で final_prompt がまだ無い場合、進め方のヒント＋
    「✍ 手動プロンプトで生成する」ボタンを表示（相談中に迷わないように）。
  - LLM が [FINAL_PROMPT] を出したら従来どおり内容を表示し、
    「🎬 この企画で生成 ▶」で初めて生成が走る（genPlanLast が参照画像を自動付与）。
- 検証: py_compile / node --check 済み。DOM+fetch をスタブした Node ハーネスで
  ルーティングを自動検証（9/9 PASS）: 参照モード+画像→/api/plan(ref_start=true)・
  生成未開始 / 2ターン目 ref_start=false / 通常モード→/api/generate 直行（回帰なし）/
  企画モード→ref_start=false / 参照モード+画像未設定→案内のみ。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 ワークフローの同種欠点をまとめて修正（参照画像解除 / 確認ガード / 上書き可視化）

- 方針: 「参照モード直行」事象と同種＝ユーザーの意図がサイレントに裏切られる欠点を
  git 履歴とコード通読から洗い出し、3 件を修正。
- Fix1 参照画像を解除する手段がなかった:
  - 🗂 で参照画像を選ぶと curImageFilename がセットされ、以降 参照モード checkbox が
    OFF でも全生成に自動参照され続けていた（解除手段なし＝意図しないキャラ固定が続く）。
  - #refpick に「✕ 解除」ボタン（#ref-clear）を追加。clearRefImage() で
    curImageFilename / refConsultActive を null 化し、#ref-sel を「未選択」表示に戻す。
    resetPlan()（🔄 新しい企画）からも clearRefImage() を呼んで確実に解除。
- Fix2 キー画像確認(__CONFIRM_IMAGE__)と参照相談(ref_start)のガード順序を強化:
  - _plan_llm で is_confirm を先に確定し、stage=="video" and ref_start の相談ラップが
    確認ターンに被らないよう `and not is_confirm` を明示。ref_note 添付も is_confirm を
    除外。確認と相談のプロンプトが混ざって意図しない指示になるのを防止。
- Fix3 チャット指示の上書きが見えなかった:
  - 「もっと高画質で」「長めに」「縦長で」等のチャット指示は SESSION の
    mode_override / length_frames / resolution に入り、UI のモード/長さ選択を
    サイレレントに上書きしていた（ユーザーは選んだ設定で生成されると思っている）。
  - server: _generate で発動中の override を override_label 文字列にまとめ、
    /api/generate レスポンスに eff_mode と共に返す（MODE_LABELS で人間可読ラベル化）。
  - client: overrideNote() が override_label 非空のとき生成メッセージに
    「⚙ チャット指示を反映中: …（UI のモード/長さより優先・解除は 🔄 新しい企画）」
    の .hint を追記。poll() が .meta を上書きしても消えない別要素として表示。
    send() と doGenerate()（✍ 手動プロンプト / 🎬 この企画で生成）両経路に組み込み。
- 検証: py_compile / node --check 済み。Node ハーネスを拡張し 18/18 PASS
  （既存 9 + 新規 9: override ラベル表示 / 空ラベルでは非表示 / clearRefImage で
    選択・相談フラグ・✕ボタンが全てリセット / 解除後は ref=false・image=null で生成）。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 動画プロンプトの日本語説明表示 + キー画像引き直しボタン

- 報告: 「動画作成はプロンプト作ってくれるのはいいけど、日本語訳もないとどんな動画に
  なるかわからん」「画像生成→気に食わなければもう一度セッション必要」。
- FixA 動画プロンプトの内容が英語だけで分からなかった:
  - PLAN_SYSTEM に [FINAL_PROMPT_JA] タグを追加。[FINAL_PROMPT]（英語・MiniMax H3 用）
    と必ず対で、「実際にどんな映像になるか」の日本語説明（被写体・動き・カメラ・雰囲気・
    セリフ要旨を2〜4文、直訳でなくイメージできる説明）を出力させる。
  - server: FINAL_JA_RE で抽出し、英語 [FINAL_PROMPT] ブロックごと reply から除去
    （チャット泡に生のタグ・英語を残さない）。/api/plan レスポンスに final_prompt_ja を追加。
    _plan の「reply が空ならプロンプトを足す」フォールバックは英語を足さないよう変更
    （日本語説明+折りたたみ英語で表示するため）。
  - client: plan() と confirmImage() の最終プロンプト確定時に
    「🎬 こんな映像になります」ボックス（.promptja、常時表示）+「📝 英語プロンプト
    （原文・クリックで表示）」折りたたみ + 「🎬 この企画で生成 ▶」を表示。
    画像確定→即プロンプト確定の経路（confirmImage）でも内容が見えるようになった。
  - 企画 LLM が [FINAL_PROMPT_JA] を出し損ねた場合は従来どおり英語折りたたみのみ
    （ gracefully degrade、壊れない）。
- FixB キー画像が気に食わないとき LLM セッションなしで引き直せなかった:
  - キー画像ギャラリー（pollImage 成功時）に「🎲 同じプロンプトで引き直す」ボタンを追加。
    lastImgPrompt のまま genImage() を再呼び出しし、新しいシードで別候補を再生成
    （企画 LLM の再相談は不要）。内容を直したい場合は従来どおり「🔁 修正する」。
- 検証: py_compile / node --check 済み。Python 単体テストで [FINAL_PROMPT_JA] 抽出・
  reply からの除去・FINAL_RE との非衝突を確認。Node ハーネスを拡張し 24/24 PASS
  （既存 18 + 新規 6: ギャラリー引き直しボタン表示・同プロンプトで /api/zimg 再送 /
    日本語説明「こんな映像になります」表示・英語原文折りたたみ格納）。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 企画 LLM 起動失敗の緊急復旧 + 再発防止（TurboTan ビルド消失）

- 症状: 「企画 LLM を起動できませんでした（モデルまたは llama-server が見つかりません）」(503)。
- 原因: TurboTan ビルド `C:\Users\dai86\Downloads\llama-b10536-rocm\`（llama-server.exe,
  b10536）がユーザー承認済みのエンジン整理で削除されていた（最後の正常起動は 10:37、
  %TEMP%\h3_plan_llm.log に記録）。ただし稼働中の h3-chat は削除前に起動しており、
  PLAN_SERVER_BIN を起動時に一度だけ解決するため、以降の GPU 企画 LLM
  （port 8191, Qwen3.8-27B）起動が全てサイレントに失敗し続けていた。
  エラーメッセージはどのファイルが無いのかを示していなかった。
- 復旧（再起動不要・ライブ回復）:
  - POST /api/plan-model で CPU プランナー Qwen3.5-4B（port 8190）へ切替。
    switch_plan_model がバイナリを C:\llama-tq3\build-rocm71-fa（実在）へ再解決。
  - /api/audio で end-to-end 検証: コールド起動 24.6 秒 + 正常な [AUDIO_SET] 応答。
    /api/plan-models で running:true を確認（/api/audio は PLAN_HISTORY を汚染しない）。
- 併せて発見・対処: ComfyUI (8188) がハング（LISTEN するが HTTP 無応答）→ のちプロセス
  終了。ck プロファイルで再起動（.venv python main.py --port 8188 --listen 127.0.0.1
  --reserve-vram 1.0 --use-ck-attention、ログ tools/comfyui-restart.log[.err]）。
  全 5 カスタムノード（Spectrum 含む）正常 import、/api/queue でキュー空を確認。
- 再発防止コード（py_compile 済み・反映には h3-chat 再起動が必要）:
  - 生存する TurboTan ビルド `turbo-tan-llama.cpp-tq3-check\build-rocm71\bin`
    （version 10369、--version 動作確認済み）を _GPU/_CPU_BIN_CANDIDATES の先頭に
    追加。TURBOTAN_SERVER_BIN（DSpark 用）も同パスへ更新。
  - _spawn_plan_llm: 記憶している PLAN_SERVER_BIN が消失していたら起動時に再解決
    （self-heal）+ 欠如ファイル（binary/model/DFlash2/DSpark）をサーバーログに
    明示する print を追加。
- 注意: DSpark ドラフト（erlidev）と DFlash2 ビルド + ドラフト（incoai, llama-dflash2）も
  この機械から消失しており、speculative decoding は現在すべて使用不可。
- GPU 27B 企画へ戻す場合: 次回 h3-chat 再起動後に UI のモデルドロップダウンで 27B を
  選び直せばよい（バイナリ候補鎖が TurboTan v10369 を解決する。b10536 より旧版で
  ある点だけ留意）。

## 2026-08-28 画像の使い方を選択可能に（I2V 先頭/最終フレーム固定）+ 監査指摘の欠陥修正

- 背景: 監査で「確認画像は動画の1フレーム目になります」という UI/企画 LLM の約束が
  実際には果たされていなかった（画像は R2V の参照画像としてだけ使われ、フレームは
  固定されない）こと、R2V「軽量 4B」が high と完全同一ファイルだったこと、
  生成失敗時に動画プロンプトが失われて引き直しできないこと等が発覚した。
- FixA 画像の使い方セレクタ（本当の I2V）:
  - フッターに「画像の使い方」を追加: 📌 先頭フレーム固定（I2V）/ 🏁 最終フレーム固定 /
    🎭 参照・キャラ維持（R2V）。「参照モード」checkbox は「画像モード」に改名。
  - server: /api/generate が image_use（first/last/ref、既定 ref=旧挙動）を受け取る。
    first/last は通常ワークフローの MiniMaxH3ImageToVideo（ノード "6"）に LoadImage
    （専用ノード ID "20"、全ワークフローの既存 ID と非衝突）を配線し、
    first_frame / last_frame 入力へ渡す（MiniMax H3 の keyframe conditioning、
    comfy_extras/nodes_minimax_h3.py 組み込み機能）。ref は従来どおり R2V。
  - 企画モードでキー画像を確定（confirmImage）すると既定が「先頭フレーム固定」に、
    🗂 参照画像ピッカーで選ぶと「参照（R2V）」に自動切替。いつでも変更可。
  - 生成開始メッセージに「📌 先頭フレーム固定で生成する: 」等と使い方を明示。
  - 企画 LLM の画像確定メッセージを「1フレーム目として固定されて生成されます」に更新。
- FixB 生成失敗時のプロンプト喪失: genPlanLast が生成前に lastFinalPrompt を
  null にしていたのを廃止。失敗・キャンセル後も同じ「🎬 この企画で生成 ▶」ボタンで
  引き直し可能（genImage が lastImgPrompt を保持する挙動と対称にした）。
- FixC R2V「軽量 4B」の偽選択肢: h3_workflow_r2v_4b.json を新設
  （4B heretic エンコーダ + ClipProj 射影 + 参照 LoRA、フル尺 1344x768x48@24fps、
  r2v_short_4b と同じ構成）。R2V_WORKFLOWS["lite"] がこれを指すように変更。
- 小物修正:
  - resetPlan の __RESET__ が fire-and-forget だった → await して失敗時は
    「サーバー側のリセットに失敗」と警告表示（状態漏洩の可視化）。
  - .gif が /api/status で video 扱いだったのを image に修正（/api/view の
    Content-Type に image/gif も追加）。
  - 死にコード削除: NODE_SAVE / NODE_ZIMG_SAVE 定数（filename_prefix は未使用）、
    startShutdown の未使用引数。
- 検証: py_compile / node --check / ワークフロー構造シミュレーション
  （6 モード × first/last/ref 全組合せ・ノード "20" 非衝突・lite の 4B 化を確認）/
  新規クライアントハーネス tools/h3-chat-client.test.mjs 23/23 PASS
  （ハーネスを初めてリポジトリにコミットし、再検証可能にした）。
- 未実装（監査で指摘の大きい機能・要 GPU 検証のため次回以降）:
  参照画像の複数枚（最大9枚）/ ref_videos / ref_audios、MiniMaxH3AddGuide
  （動画途中アンカー）、ref_image_size "max"、ネガティブプロンプト UI 公開、
  EasyCache/LoRA 強度/crf の公開。h3_workflow_src.json と未使用レガシー
  ワークフロー 12 個の整理は削除判断が必要なため保留。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 キー画像プロンプトにも日本語説明を表示（[IMG_PROMPT_JA]）

- 背景: 動画プロンプトには [FINAL_PROMPT_JA]（3b261db）で日本語説明を付けていたが、
  キー画像段階は英語プロンプトだけしか表示されず、どんな画像が生成されるか
  ユーザーに分からないまま「キー画像を生成」を押す必要があった。
- 仕組み（動画側と完全に対称）:
  - PLAN_SYSTEM: [IMG_PROMPT] を出したら必ず直後に [IMG_PROMPT_JA]…[/IMG_PROMPT_JA] で
    日本語説明（被写体・ポーズと構図・服装の状態・雰囲気・ライティングを1〜3文、
    直訳でなくイメージできる説明）を付けるよう必須化。閉じタグ一覧にも追加。
  - server: IMG_JA_RE を追加し、_plan_llm で日本語説明を抽出 → 英語ブロックごと
    reply から除去。これで画像段階の英語 [IMG_PROMPT] ブロックがチャット泡に
    生で残っていた従来挙動も同時に解消（英語は折りたたみ表示へ）。
    戻り値は 7 要素 (reply, img_prompt, final_prompt, audio, thinking,
    final_prompt_ja, img_prompt_ja) に拡張。
  - /api/plan: img_prompt_ja フィールドを追加。reply が空のときのフォールバック
    文言から英語原文の付与を削除（折りたたみ側に出るため重複だった）。
  - client: plan() の画像段階で「🖼 こんな画像になります」ボックスを日本語説明で
    表示し、英語原文は「📝 英語プロンプト（原文・クリックで表示）」折りたたみに格納。
    JA タグが欠如した場合は従来表示（折りたたみ+ボタン）に縮退。
- 正規表現の非衝突確認済み: IMG_FINAL_RE（`[IMG_PROMPT]`）は `[IMG_PROMPT_JA]` に
  マッチせず、逆も同様（リテラル `]` の位置で区別される）。
- 検証: py_compile / Python 単体 11 項目（抽出・両方向非衝突・unclosed フォールバック・
  動画側リグレッション・PLAN_SYSTEM 文言）全 PASS / クライアントハーネスに [8][9] を
  追加し 30/30 PASS（JA ボックス表示・折りたたみ・lastImgPrompt 保持・縮退）。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず。7f29fdd 以降の
  全変更が次回再起動でまとめて有効になる）

## 2026-08-28 参照画像まわりの機能拡張バッチ（監査残タスク消化）

- 背景: 「comfy を含めて機能をすべて引き出せていない」調査で判明した
  未実装項目のうち、実装可能と判定したものを一括実装。
- 複数参照画像（R2V 最大 9 枚）:
  - MiniMaxH3ReferenceToVideo ノードは ref_image_0..8（Autogrow、最大 9）を
    サポートするが、h3-chat は 1 枚しか渡せていなかった。
  - server: images 配列を受け取り（image は後方互換の 1 枚目）、9 枚超は 400。
    追加画像は LoadImage ノードを動的 ID（既存数値 ID 最大+1）で追加し、
    node 16 配線はフラットキー "ref_images.ref_image_N" とネスト dict
    "ref_images" の両形式を維持（動作確認済みファイル形式のミラー）。
    全 6 R2V ワークフローで構造シミュレーション 25/25 PASS。
  - プロンプトには _r2v_tag_note() で <Picture 1..N> の意味を追記
    （1 枚目は従来どおり R2V_TAG_NOTE）。企画 LLM がタグを知らなくても
    各参照画像と被写体の対応が付く。
  - client: 参照画像ピッカーを単発選択→複数トグル選択+「✅ 参照画像として使う」
    確定方式に変更。クリック順が <Picture N> の番号になり、バッジで表示。
    curImageFilename は廃止し refImages 配列に一本化（全参照箇所更新・残骸ゼロ）。
- ref_image_size "max" トグル: ノードの combo 入力（match 既定 / max = 短辺
  2048px・数倍遅い）を詳細設定に露出。server は値を検証し R2V ノードに設定。
- 品質チューニング露出（EasyCache / LoRA / crf）:
  - EasyCache reuse_threshold（0-1）: ノードを持つワークフロー（turbo/super/
    clipproj/r2v）に適用。持たないモード（fast 系）は tune_ignored で報告。
  - Turbo LoRA strength_model（0-2）: turbo LoRA のみ対象（ref LoRA は対象外）。
    非使用モードは tune_ignored。
  - SaveVideo crf（0-51）: codec を dict 形式 {"codec":"h264","encoding":
    {"encoding":"re-encode","crf":X}} で設定（auto のままでは再エンコード
    されないため）。SaveVideo 無しは tune_ignored。
  - 範囲外・非数値は 400。空欄は送信しない（ワークフロー既定値を維持）。
- 黙って裏切らない仕組み（tune_ignored / refUsageNote）:
  - server → tune_ignored 配列で「このモードでは効かなかった設定」を返し、
    client は生成開始メッセージに「⚙ 反映されなかった設定: …」を表示。
  - フレーム固定（first/last）に複数画像が選ばれている場合「1 枚目だけ使われ
    残り無視」の警告を生成開始メッセージに追記（refUsageNote）。
- 調査のみで実装しなかった項目（判定付き）:
  - ネガティブプロンプト = N/A: 全ワークフローの KSampler が cfg=1 で、
    negative conditioning は数学的に無効（MiniMax H3 は CFG フリー）。
    UI に出すと「効かない設定を効くと見せる」偽の選択肢になるため露出しない。
  - ref_videos / ref_video_audios / ref_audios = 延期: ノードは対応
    （動画最大 3・24fps 2-15s、音声最大 3、動画+サウンドトラックのペアリング）
    するが、動画/音声参照のアップロード経路が h3-chat に無く、UX 設計と
    GPU 検証が必要なため。
  - MiniMaxH3AddGuide = 延期: フレーム指定アンカー（frame_idx + 画像/音声）は
    UX 設計が先。
  - 旧ワークフロー 12 ファイル + h3_workflow_src.json = 削除せず保持を推奨:
    docs/MiniMax-H3-Tuning.md と README がチューニング履歴として参照中。
    削除はユーザーの明示 OK 待ち。
- 検証: py_compile / node --check / クライアントハーネス [10]-[14] 追加で
  47/47 PASS（複数選択トグル+順序+確定 / images[]+ref_size+tune ペイロード /
  フレーム固定+複数画像警告 / 9 枚上限アラート / tune_ignored 表示）。
  ハーネスの innerHTML スタブを実 DOM と同じく「代入で子を消す」挙動に修正
  （refgrid クリアの再現のため）。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）

## 2026-08-28 過去履歴のサイドバー（ChatGPT 風セッション永続化）

- 要望: 「チャットGPTみたいに過去の履歴はサイドバーに」。企画セッションを
  自動保存し、左サイドバーから一覧・切替・復元・削除できるようにした。
- 保存形式: `REPO/sessions/<id>.json` に 1 セッション 1 ファイル（gitignore
  済み）。中身 = {id, title, created, updated, messages:[{who,html}], ui:{…},
  server:{plan_history, session}}。server スナップショット（PLAN_HISTORY と
  SESSION のコピー）は保存時にサーバー側が自分で撮る — クライアントからは
  見えないため。resolution の tuple↔list 変換は保存/復元時に行う。
  - セッション ID は `^[A-Za-z0-9_-]{1,64}$` のみ許可（パス traversal 防止）。
  - 書き込みは tmp + os.replace のアトミック。
  - タイトル = 最初のユーザー発言から HTML タグ・先頭の絵文字/記号を落として
    34 文字 + 「…」。
  - `sessions/_active.json` が「今開いているセッション」のポインタ。
    h3-chat 再起動後の初回アクセスで自動復元される（再起動しても最後の
    セッションに戻れる）。
- API（4 つ）:
  - GET /api/sessions → {active_id, sessions:[{id,title,updated,n}], active}
  - POST /api/sessions/save {id,messages,ui} → {id,title,updated}
    （id=null かつ空メッセージは {id:null} を返して保存しない = 空の新規
    チャットはサイドバーに残さない）
  - POST /api/sessions/switch {id|null} → {session}（null = 新規セッション。
    server 状態は _plan_reset で初期化）
  - POST /api/sessions/delete {id} → {ok, was_active}
- クライアント:
  - 自動保存: 6 秒毎 + beforeunload（sendBeacon）。JSON が前回と同一なら
    送信しない（dedup）。
  - 復元: renderSession(doc) がメッセージ DOM・planStage・lastFinalPrompt・
    lastImgPrompt・参照画像・imguse・モード上書き等を全部復元するため、
    復元後も「確定→動画を相談」「引き直す」等のボタンがそのまま動く。
  - ジョブ再開: 保存中の ui.curJobId/curJobKind があれば、復元時に最後の
    bot メッセージへポーリングを再接続（video→poll / image→pollImage）。
    生成中にページを閉じても、開き直せば進捗表示が復活する。
  - 切替ガード: 生成中（busy）は切替・新規をブロック（アラートで案内、
    ✕ キャンセルで中止可能）。
  - 「🔄 新しい企画」= 現セッションを保存 → 新規セッションへ切替。
    旧セッションはサイドバーの履歴に残る（ChatGPT と同じ挙動）。
    server リセット失敗時は画面を消さず警告だけ出して状態を保持
    （client/server 乖離を防ぐ）。
  - ヘッダーの ☰ ボタンでサイドバー表示/非表示をトグル。
- 検証: py_compile / node --check / クライアントハーネス [15]-[19] 追加 +
  [7] 書き直しで 69/69 PASS（復元・自動保存 dedup・busy ガード・新規チャット・
  ジョブ再開 / リセット失敗時の状態保持）。サーバー側は単体テスト 20/20
  （タイトル抽出・ID 安全性・書込/読込・スナップショット往復・一覧順・
  ポインタ）。
- 反映には h3-chat 再起動が必要（GPU 使用中のため今回は再起動せず）


## 2026-08-28 動画の続きもの・アップスケール・結合（Phase 3）

「一度作った動画の続き」と「アップスケーリング」を実装。システム ffmpeg は
不要（h3-chat の python に入った PyAV 17.0.0 が FFmpeg ライブラリを内蔵）。

- 続きを作る（動画完成メッセージの「▶ この動画の続きを作る」ボタン）:
  - POST /api/extend {filename} → 完成動画の最後の1フレームを PNG で
    ComfyUI input/ に抜き出し（_extract_last_frame / PyAV）、ファイル名を返す。
    抜き出し画像は local_files に登録されるため、後続の /api/plan（企画 LLM の
    視覚入力）と /api/generate（_stage_ref_image）が裸のファイル名で解決できる。
  - クライアントは抜き出し画像を参照画像（先頭フレーム固定 I2V）としてセットし、
    企画モード ON・planStage="video" にして「続きの内容」を企画 LLM と相談 →
    [FINAL_PROMPT] → 生成。前作の最終フレームが新作の1フレーム目になるので
    絵が自然につながる。
  - セグメント連鎖: extendFrom（生成中の続きの元動画）と segmentChain
    （順序付きファイル名リスト）をクライアントが保持。続きセグメントが完成
    するたびに連鎖が伸び、2本以上で「🔗 N本の動画を1本に結合」ボタンが出る。
    連鎖は uiSnapshot/セッション保存に含まれ、復元時も維持される。
- 結合: POST /api/concat {files:[2..20]} → _concat_videos が PyAV でデコード →
  h264 24fps・音声 aac で1本の mp4 に再エンコード（ComfyUI output/ に保存、
  local_files 登録済みなので /api/view で即再生可）。解像度が混在する場合は
  400（「同じモードで生成した動画を結合してください」）。
- アップスケール（「🔍 アップスケール（2倍）」ボタン）:
  - POST /api/upscale {filename, scale:2|4} → 動画を ComfyUI input/ に
    ステージング（LoadVideo は input/ しか読めない）→ h3_workflow_upscale.json
    （LoadVideo→GetVideoComponents→UpscaleModelLoader(RealESRGAN_x4plus)→
    ImageUpscaleWithModel(タイル式で16GB安全)→ImageScale(目標サイズ=元×scale)→
    CreateVideo(元音声を再mux)→SaveVideo(h264 crf18)）を ComfyUI に投入。
    job_meta mode="upscale"（ETA 目安 180 秒）。
  - 完成時は「アップスケール完了 ✅」表示。続き/アップスケールボタンは出さず、
    停止ボックスも出さない（連続作業の邪魔をしない）。
  - モデル: RealESRGAN_x4plus.pth (64MB) を ComfyUI models/upscale_models/ に
    ダウンロード済み（リポジトリ外）。無い場合は 503 で案内。
- セキュリティ: /api/extend・/api/concat・/api/upscale は全て
  _resolve_output_file 経由（ComfyUI output/ 内の実在ファイルだけ許可、
  パス区切り・..・先頭ドット・null バイト・200字超・非文字列を拒否）。
- 検証: py_compile / node --check（Python 文字列パース後の JS を抽出して検査。
  テンプレートは通常文字列なので onclick の引用符は &quot; エンティティ方式）/
  クライアントハーネス [20]-[24] 追加で 97/97 PASS / サーバー単体テスト 18/18
  （最終フレーム抜き出しの色検証・結合のフレーム数合計・解像度混在拒否・
  パストラバーサル防御 8 パターン）。
- 反映には h3-chat 再起動が必要（ユーザーが GPU 使用中のため再起動せず）。

### 同日の緊急対応（再起動が必須な理由）

- 「軽量モード5秒でも1時間以上かかって25%」の診断:
  - 稼働中の h3-chat は古いプロセスで、「軽量R2V = 32B ファイル」だった
    フェイク選択肢バグ（fbc4618 で修正済み・未デプロイ）を抱えていたため、
    実際には最重量設定（32B CLIP + 1344x768 + 124フレーム）で走っていた。
  - 124フレーム（5秒）は48フレーム（2秒）に対して注意機構が超線形に重い。
  - LM Studio が同時刻に GPU を占有しており VRAM/計算の奪い合い。
  - 対策: h3-chat を再起動すれば真の軽量R2V(4B)が効く。長い動画は「2秒
    セグメント + 今回の続きもの機能」で繋ぐ方が速い。LM Studio 稼働中の
    生成は避ける。

## 2026-08-28（夜） 全スタック再起動 + 企画 LLM の DLL サイレント死修正

user がラマドックから接続しても古い h3-chat（11:41 起動・全修正の前のコード）
に繋がり続けていたため、全スタックを新コードで再起動した。

- 古い h3-chat（PID 9724+6476）を停止 → ComfyUI を ck プロファイルで再起動
  （.venv python main.py --port 8188 --listen 127.0.0.1 --reserve-vram 1.0
  --use-ck-attention、ログ tools/comfyui-restart.log[.err]）→ tools/h3-chat.ps1
  で h3-chat + CPU 4B 企画 LLM を起動。
- **発見したバグ（修正済み）**: 企画 LLM（llama-server の ROCm/HIP ビルド）は
  amdhip64_7.dll のため ROCm bin が PATH に必要だが、
  ① h3-chat.py の _spawn_plan_llm は GPU 分岐でしか PATH を補強していなかった
  （CPU 4B planner は select-model.ps1 経由の PATH 継承に依存 → 普通のシェル
  から起動すると STATUS_DLL_NOT_FOUND でサイレント死）、
  ② h3-chat.ps1 単独実行時も同じ問題。
  修正: _spawn_plan_llm は PLAN_GPU に関係なく PLAN_ROCM_BIN を PATH へ
  （LLAMADOCK_ROCM_BIN 環境変数で上書き可）、h3-chat.ps1 も起動前に最新の
  C:\Program Files\AMD\ROCm\*\bin を PATH 補強。
- 再起動で有効になったもの: 画像の使い方セレクタ+真の軽量R2V 4B（fbc4618）/
  キー画像・動画の日本語説明（522cf8a+3b261db）/
  サイドバー（8786376）/ 続きもの・アップスケール・結合（170875e）。
- 検証: 配信 HTML に全マーカー存在（こんな画像になります/こんな映像になります/
  extendVideo/upscaleVideo/segmentChain/sess-list/imguse）、8190 planner 200、
  ComfyUI キュー空。
