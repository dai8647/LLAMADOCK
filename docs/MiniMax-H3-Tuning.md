# MiniMax H3 高速化チューニング（調査メモ + 実装）

対象: LlamaDock の ComfyUI ワークスペース (`Open-ComfyUIClient`) で MiniMax H3 の動画生成を速くする。
この PC は **AMD RX 7800 XT (gfx1101) / ROCm Windows / torch 2.9.1+rocmsdk20260116 / ComfyUI 0.33.0（2026-08-14 更新）** なので、
コミュニティの定番策（SageAttention 等）の大半は CUDA 前提で**そのままでは使えない**。適用可否を調査して整理した。

---

## 1. 調査ソース（2026-08-14）

| 種別 | ソース | 要点 |
| --- | --- | --- |
| Reddit | [r/StableDiffusion "MiniMax H3 tips and tricks"](https://www.reddit.com/r/StableDiffusion/comments/1vegtac/minimax_h3_tips_and_tricks_and_what_i_experienced/) | SageAttention が速度向上の定番。PyTorch は cu30+ 推奨（NVIDIA 前提） |
| Reddit | [r/comfyui "Lets speed up MiniMax H3"](https://www.reddit.com/r/comfyui/comments/1ve7pj1/lets_speed_up_minimax_h3_we_already_have_a_node/) | 専用加速ノード群が登場 |
| GitHub | [Comfy-Org/MiniMax-H3 discussion #26「Just a quick benchmark」](https://huggingface.co/Comfy-Org/MiniMax-H3/discussions/26) | **KJ の Sage patch は必須**、Sol-Attn は 15–20%、Spectrum は約 15%、EasyCache は 100 フレーム超で約 25%。Spectrum と EasyCache は併用不可 |
| GitHub | [xmarre/ComfyUI-Spectrum-MiniMax-H3](https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3) | **依存ゼロ**の Spectrum 加速（後述）。CK/Comfy-Kitchen と併用可 |
| GitHub | [kijai/ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | "MiniMax H3 Memory Efficient Sage Attention Patch" は**最新 SageAttention 必須 → CUDA 限定** |
| GitHub | [kijai/ComfyUI-SolAttn_triton](https://github.com/kijai/ComfyUI-SolAttn_triton) / [Saganaki22/ComfyUI-sol-attn](https://github.com/Saganaki22/ComfyUI-sol-attn) | Triton カーネル。SM89–SM121（NVIDIA）向け |
| GitHub | [SageAttention #234](https://github.com/thu-ml/SageAttention/issues/234) | SageAttention **v1 は Triton（AMD 可）、v2 は CUDA のみ** |
| 公式 | [ComfyUI MiniMax H3 チュートリアル](https://docs.comfy.org/tutorials/video/minimax/minimax-h3) | Sage Attention で約 2 倍。`--use-sage-attention` フラグ or KJNodes の Patch Sage Attention KJ ノード |
| ComfyUI 本体 | `comfy/cli_args.py`, `comfy/quant_ops.py` (0.31.0) | `--fast` の内容、`--reserve-vram`、comfy-kitchen INT8 Triton バックエンドの条件を確認 |

## 2. この環境（AMD/ROCm）で使えるもの

| 加速手段 | 効果（コミュニティ報告） | AMD/ROCm で使える？ | 品質リスク |
| --- | --- | --- | --- |
| **Turbo LoRA（4–8 step）** | サンプリング約 5 倍（20step→4–8step） | ✅ 純 PyTorch。pruned 対応版（Abiray）は標準 Load LoRA で適用可 | 大きい（4step は軟らかい。6–8step が実用域） |
| **Spectrum Apply MiniMax H3** | 実トランスフォーマー評価を 20step→約 11 回に削減（約 1.4–1.7 倍） | ✅ **依存ゼロの純 PyTorch**。CK と併用可 | あり（動作・音声の同期が変わり得る）。同 seed で A/B 推奨 |
| **起動フラグ調整**（本リポジトリ実装） | ベンチで DiT の VRAM 搭載量 7.8→10.7GB | ✅ | なし（デフォルトは安全側） |
| **comfy-kitchen HIP バックエンド**（triton 不要） | int8/ConvRot の量子化・線形演算をネイティブ化。**デフォルトで既に有効** | ✅ | なし |
| comfy-kitchen INT8 Triton バックエンド | 追加 tl.dot カーネル | ❌ **2026-08-14 実測でクラッシュ**（下記 3 節） | — |
| **`--use-ck-attention`**（comfy-kitchen attention） | SageAttention より高速・高画質と報告（PR #15479、2026-08-11 リリース） | ✅ **ComfyUI 0.33.0 更新で実装。この機で「Using Comfy Kitchen attention」有効化確認済み**（gfx1101 の WMMA で int8 attention 利用可） | 低（要 A/B） |
| ClipProj（テキストエンコーダ差替） | Qwen3-VL-32B（約 15.7GB）→ 4B/8B エンコーダで **VRAM 約 11GB 解放** | ✅ | 条件付けが変わるため要 A/B |
| GGUF 量子化 DiT（ComfyUI-GGUF） | 低 VRAM 化・速読込 | ⚠️ ROCm での動作は要検証 | 量子化による品質低下 |
| SageAttention（`--use-sage-attention` / KJ の sage パッチ） | 約 2 倍（「無料の 2 倍高速化」スレッドの本体も mem-eff sage パッチ） | ❌ v2 は CUDA のみ。v1 は Triton だが H3 用 mem-eff パッチは v2 前提 | 低（dtype フォールバックあり） |
| Sol-Attn（Patch Sol-Attn） | 15–20% | ❌ NVIDIA SM89+ 前提 | 低 |
| EasyCache / LazyCache | 100 フレーム超で約 25% | ⚠️ 汎用だが Spectrum と**排他** | 品質劣化報告あり（"ruins the quality"） |

## 3. ランチャー実装（llamadock 側）

`select-model.ps1` の `Get-ComfyUILaunchArgs` が ComfyUI の起動引数を組み立てる。
既定（`default` プロファイル）:

```
main.py --port 8188 --listen 127.0.0.1 --reserve-vram 1.0
```

- `--reserve-vram 1.0` … OS/デスクトップ用に 1GB 残し、残りは DynamicVRAM に使わせる。
- **`--lowvram` は付けない**。ヘルプ通り「text encoder が CPU に落ちる」うえ、ベンチで DiT の VRAM 搭載量が減った
  （7.8GB vs 10.7GB）。搭載量が増えても step 1 が 119s（従来 44.8s）と遅い結果も出ており、
  ステップ速度は**定常状態で再計測**が必要（下記 5 節）。

### プロファイルと上書き

| 方法 | 内容 |
| --- | --- |
| **起動時メニュー（対話式）** | `comfyui.bat` / `llamadock.bat` で ComfyUI を起動するとき、フラグ未固定なら毎回表示。**速い順**: `[1] ck` / `[2] fast` / `[3] default` / `[4] bench` / `[5] triton` / `[6] custom`（生フラグ入力）。Enter で default。stdin がリダイレクトされている（スクリプト/ベンチ実行）ときは自動スキップ |
| `LLAMADOCK_COMFY_PROFILE=fast` | 上記 + `--fast fp16_accumulation --force-non-blocking`（AMD でも有効な項目のみ。ComfyUI は「未テスト・品質劣化の可能性」と明記 → **ベンチしてから採用**）。設定すると起動時メニューはスキップ |
| `LLAMADOCK_COMFY_PROFILE=triton` | 上記 + `--enable-triton-backend`（comfy-kitchen の INT8 Triton カーネルを有効化。**venv に triton >= 3.7 が前提**。ランチャーがバージョンを確認し、古い・未導入ならフラグを省略して警告のみ） |
| `LLAMADOCK_COMFY_PROFILE=ck` | 上記 + `--use-ck-attention`（comfy-kitchen attention。**ComfyUI 0.33.0 以上が必要**。この機で有効化確認済み） |
| `LLAMADOCK_COMFY_PROFILE=bench` | 追加フラグなし（A/B 用） |
| `LLAMADOCK_COMFY_FLAGS="--reserve-vram 0.5 --force-non-blocking"` | **完全上書き**（プロファイル/メニューより優先） |
| `-ComfyUIFlags "..."`（`select-model.ps1` 引数） | **最優先** |

起動時に `ComfyUI flags: ...` と表示されるので、ベンチ結果とフラグを突き合わせられる。

優先順位: `-ComfyUIFlags` > `LLAMADOCK_COMFY_FLAGS` > 起動時メニュー（custom の生フラグ） > プロファイル（`LLAMADOCK_COMFY_PROFILE` > 起動時メニュー > default）。

### triton 導入（2026-08-14 追記: 3.7.1 で復活）

AMD 公式は **Windows 用 triton wheel を出していない**（`rocm-rel-7.2` は torch/torchvision/torchaudio のみ。triton は Linux のみ）。
Windows で使えるのはフォークの `triton-windows`（woct0rdho、HIP バックエンド対応あり）のみ。

```powershell
uv pip install --python "C:\Users\dai86\Documents\ComfyUI\.venv\Scripts\python.exe" "triton-windows==3.7.1.post27"
```

- **クラッシュの根本原因（判明）**: `comfy/quant_ops.py`（0.33.0）は「triton < 3.7 は ROCm INT8 パスに不適合
  （libdevice.rint 欠落でクラッシュ）」と**既にバージョンガード済み**。ただし
  `if args.enable_triton_backend or triton_version >= (3, 7)` のため、`--enable-triton-backend` を
  **明示指定するとガードが無効化**され、3.5.1 のまま有効化 → クラッシュしていた。
- **対策**: ランチャー（`Get-ComfyUILaunchArgs` の `triton` プロファイル）が venv の triton バージョンを確認し、
  **>= 3.7 のときだけ** `--enable-triton-backend` を付ける。古い・未導入なら警告のみで省略（HIP int8 は triton 無しでも動作）。
- **3.7.1 はこの環境で動作確認済み（2026-08-14）**: `triton-windows==3.7.1.post27` を導入し、
  import + gfx1101 の HIP カーネルコンパイル・実行（PASS）。**torch 2.9.1 のまま使える**
  （旧メモ「3.6 系は torch >= 2.10 が必須」は誤り。wheel は torch 非依存で実測動作）。
- **残タスク**: `--enable-triton-backend` でのフルベンチ（h3_workflow_bench.json）による実機検証は未実施。
  nvfp4 AWQ エンコーダ経路が 3.7.1 で通るかは次回の起動時に確認する。
- フラグを付けなければ triton は import すらされない（`comfy/quant_ops.py` の有効化条件）ので、デフォルト起動には影響しない。
- comfy-kitchen の **HIP バックエンドは triton なしで既に有効**（int8_linear / convrot int8）。
  triton は追加の tl.dot カーネル（nvfp4 逆量子化等）を足す。

## 2026-08-14 実測（この機のデータ）

- **triton クラッシュ（3.5.1）**: 導入時（3.5.1.post24）は `--enable-triton-backend` 起動でベンチジョブ投入時に
  **ComfyUI がクラッシュ**（CLIP/text encoder 処理中、`error: couldn't allocate input reg for constraint 'r'`）。
  原因は「明示フラグが quant_ops.py の < 3.7 ガードを無効化」すること（下記 3 節）。
  **3.7.1.post27 に更新し、HIP カーネルコンパイル・実行を確認済み**（フルベンチ検証は残タスク）。
- **ベースライン（default プロファイル、triton 無効、0.31.0）**: 同一ジョブ（seed 42・20step・1344x768・48f）は
  **18:25:36 → 18:45:02 の 19 分 26 秒で成功**（h3_t2v_00002_.mp4）。起動ログは `Using pytorch attention`
  （デフォルト attention。`--use-ck-attention` で置き換え可能＝ ComfyUI 更新が次の大きな一手）。
- **ck プロファイル（`--use-ck-attention`、0.33.0）**: 同一ジョブ（bench、seed 42・20step・1344x768・48f）は
  **18:59:55 → 19:17:14 の 17 分 19 秒で成功**（h3_t2v_00003_.mp4、`Prompt executed in 00:17:19`）。
  定常ステップ速度は **41.8s/it**（12/20 時点 08:07、11→12 が 42s）。基準 19:26 に対し **約 11% 短縮**。
  ただし ComfyUI 0.31→0.33 の更新も同時に入っているため、ck-attention 単体の効果は
  0.33.0 の `bench` プロファイル（ck なし）との A/B で切り分けが必要（次の一手）。
- **Turbo LoRA / ClipProj（512x320・16f・fps12 の短尺スモークテスト）**: 両方とも成功。
  `h3_workflow_turbo_short.json`（8step・res_multistep・strength 1.2）: **`Prompt executed in 94.94s`**（h3_turbo_00001_.mp4）
  `h3_workflow_clipproj_short.json`（20step・euler）: **`Prompt executed in 81.51s`**（h3_clipproj_00001_.mp4）。
  ClipProj 動作ログ: `mmh3-4b-ClipProj-celeb-mlp.safetensors | tap 24 | 2560 -> 5120 | cos_test 0.7931`。
  低解像度・短尺のスモークテストであり、フル解像度ベンチ（1344x768・48f）とは非比較。
- **Turbo LoRA ファイル修復**: HF `Abiray/MiniMax-H3-Turbo-Lora-Pruned-ComfyUI`（旧名 `MiniMax-H3-Turbo-Lora-ComfyUI`）の
  4 ファイルすべてが safetensors ヘッダ宣言より **64 バイト多い**（`incomplete metadata, file not fully covered`）ため
  ComfyUI が読み込めず error。宣言サイズ（8+ヘッダ+データ末尾）に切り詰めて復旧し、416 テンソル全て正常読み込みを確認。
- **ワークフローバグ修正**: turbo/clipproj ワークフローの負側 CLIPTextEncode（node 5）に `clip` 入力が無く
  バリデーション 400。turbo は `["2", 0]`、clipproj は `["11", 0]`（ClipProjApply 出力）を追加して修正
  （両ワークフローとも未実行だったため未発覚）。
- 旧 src ワークフローの実測は 26 分（h3_t2v_00001_.mp4, 17:15）。

## 2026-08-14 後半: ComfyUI 更新 + Turbo LoRA + ClipProj（3 並行タスク）

### ComfyUI 0.31.0 → 0.33.0（git pull、依存更新済み）

- 41 コミット分を `git pull --ff-only` で更新。`--use-ck-attention` が実装された（`comfy/cli_args.py`）。
- 依存は `uv pip install -r requirements.txt` で更新（comfyui-workflow-templates 等）。
- 起動ログで `Using Comfy Kitchen attention` を確認 → **ck-attention がこの機で有効**。
  comfy-kitchen 0.2.31 の HIP バックエンドが `int8_attention_is_available() = has_wmma()` で
  gfx1101（RDNA3）の WMMA を使う。triton バックエンドは `disabled` のままで安全。

### Turbo LoRA（Abiray pruned）

- `models/loras/minimax_h3_turbo_4step_ckpt600_ema_V4.safetensors`（591MB）を配置。
- 標準 ComfyUI 形式（`diffusion_model.*.lora_A/B` 417 keys）で `LoraLoaderModelOnly` がそのまま読める。
- `h3_workflow_turbo.json`: bench の KSampler を steps 8・res_multistep/simple、σ を video 12 / audio 6 に変更。

### ClipProj（nicolab28/ComfyUI-ClipProj）

- `custom_nodes` に clone。依存なし（torch + ComfyUI 本体のみ）。
- `models/clip_projections/mmh3-4b-ClipProj-celeb-mlp.safetensors` と
  `models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors`（Comfy-Org/Krea-2、4.9GB）を配置。
- `h3_workflow_clipproj.json`: `CLIPLoader (type: krea2) → ClipProjApply` で 32B を置き換え。sampling は bench と同一。

## 4. ワークフロー側のチューニング

| ワークフロー | 変更点 | 用途 |
| --- | --- | --- |
| `h3_workflow_bench.json` | 基準（seed 42・20step・1344x768・48f・euler/simple） | A/B の基準 |
| `h3_workflow_fast.json` | bench + `SpectrumApplyMiniMaxH3`（SigmaShift の後段） | 品質維持のまま ~15% |
| `h3_workflow_turbo.json` | bench + **Turbo LoRA**（`LoraLoaderModelOnly`、strength 1.2）+ **8 step**・res_multistep/simple・σ video 12 / audio 6 | サンプリング 2.5 倍（20step→8step） |
| `h3_workflow_clipproj.json` | bench の CLIP を **Load CLIP (krea2 / qwen3vl_4b_fp8) → ClipProj Apply** に差替（sampling は bench と同一） | エンコーダ VRAM 約 11GB 解放 |

- Spectrum / Turbo LoRA / ClipProj はすべて併用可能（それぞれ別の層を最適化する）。
  組み合わせる場合は 1 つずつ導入して同 seed A/B を取るのが安全。
- **Turbo LoRA の設定**（Abiray pruned 版 README 準拠）: steps 8–12、sampler `res_multistep`、
  Video σ shift **12** / Audio σ shift **6**、strength 0.8–1.8。ファイルは `models/loras/minimax_h3_turbo_4step_ckpt600_ema_V4.safetensors`
  （他に ckpt500_V1 / ckpt600_V4 / ckpt850_V1 もある。`h3_workflow_turbo.json` の `strength_model` をいじって A/B）。
- **ClipProj の注意**（nicolab28 の README より）: 単一 GPU では `ClipProjLoader`（resident モード）を使わず、
  **標準 `Load CLIP`（type: krea2）+ `ClipProj Apply`** を使う。エンコーダは Comfy-Org/Krea-2 の
  `qwen3vl_4b_fp8_scaled.safetensors`（4.9GB）、行列は `mmh3-4b-ClipProj-celeb-mlp.safetensors`（4B 用）。
  4B と 8B の行列は互換性がない（ノードが拒否する）。

## 5. ベンチ手順（前回の続き）

1. `comfyui.bat`（または `llamadock.bat` → ComfyUI）で起動。起動ログの `ComfyUI flags:` を記録。
2. `h3_workflow_bench.json`（ベースライン）と `h3_workflow_fast.json`（Spectrum）を
   `client_id: speed-bench` のまま `/prompt` に POST。seed 42・20step・1344x768・48 フレーム固定。
3. **step 1 は遅い（前回 119s vs 44.8s）**。ロード・デカップリング変換・CLIP が混ざるので、
   1 回目のジョブはウォームアップ扱いにして、**2 回目以降の定常 step 速度**で比較する。
4. `nvidia-smi` は無いので VRAM は `rocm-smi` / ComfyUI の `system_stats`（`devices[].vram_*`）で測る。
5. パラメータ A/B は `LLAMADOCK_COMFY_PROFILE=bench` + `LLAMADOCK_COMFY_FLAGS` で行い、
   フラグ文字列を結果と一緒にメモする。

## 6. 参考: 検出・適用ヘルパー

```powershell
# 現状把握（GPU/venv/カスタムノード/推奨フラグを表示）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\comfyui-tune.ps1

# Spectrum ノードを custom_nodes に導入（AMD で使える加速の第一候補）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\comfyui-tune.ps1 -InstallSpectrum

# KJNodes も導入（sage 系は CUDA 必須なので、主に他のユーティリティノード用）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\comfyui-tune.ps1 -InstallKJNodes
```
