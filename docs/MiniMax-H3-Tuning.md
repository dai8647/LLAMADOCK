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
| **起動時メニュー（対話式）** | `comfyui.bat` / `llamadock.bat` で ComfyUI を起動するとき、フラグ未固定なら毎回表示。**2026-08-17 に 4 項目へ縮小**: `[1] plan`（推奨。ck + 企画モード）/ `[2] ck`（実測 17m19s）/ `[3] default` / `[4] custom`（生フラグ入力）。Enter で **plan**（実測最速の ck + 企画モードがそのまま立ち上がる）。stdin がリダイレクトされている（スクリプト/ベンチ実行）ときは自動スキップ。`super` / `fast` / `triton` / `bench` はメニューから削除したが、`LLAMADOCK_COMFY_PROFILE` で引き続き指定可能（スクリプト実行向け） |
| `LLAMADOCK_COMFY_PROFILE=fast` | 上記 + `--fast fp16_accumulation --force-non-blocking`（AMD でも有効な項目のみ。ComfyUI は「未テスト・品質劣化の可能性」と明記 → **ベンチしてから採用**）。設定すると起動時メニューはスキップ |
| `LLAMADOCK_COMFY_PROFILE=triton` | 上記 + `--enable-triton-backend`。**デフォルト無効**: triton 3.7.x でもこの GPU の H3 INT8 経路はクラッシュするため、`LLAMADOCK_COMFY_TRITON=1` のときだけ付与（詳細は triton 節） |
| `LLAMADOCK_COMFY_PROFILE=super` | 上記 + `--use-ck-attention`。triton は同じく opt-in なので、**この機では ck 相当にフォールバック**（動作中の最速構成）。ワークフローは `h3_workflow_super.json`（Turbo LoRA + ClipProj・8step）と組むと全部載せ |
| `LLAMADOCK_COMFY_PROFILE=ck` | 上記 + `--use-ck-attention`（comfy-kitchen attention。**ComfyUI 0.33.0 以上が必要**。この機で有効化確認済み） |
| `LLAMADOCK_COMFY_PROFILE=bench` | 追加フラグなし（A/B 用） |
| `LLAMADOCK_COMFY_FLAGS="--reserve-vram 0.5 --force-non-blocking"` | **完全上書き**（プロファイル/メニューより優先） |
| `-ComfyUIFlags "..."`（`select-model.ps1` 引数） | **最優先** |

起動時に `ComfyUI flags: ...` と表示されるので、ベンチ結果とフラグを突き合わせられる。

優先順位: `-ComfyUIFlags` > `LLAMADOCK_COMFY_FLAGS` > 起動時メニュー（custom の生フラグ） > プロファイル（`LLAMADOCK_COMFY_PROFILE` > 起動時メニュー > default）。

### triton 導入（2026-08-14 追記: 3.7.1 で復活）→ **2026-08-16 アンインストール**

AMD 公式は **Windows 用 triton wheel を出していない**（`rocm-rel-7.2` は torch/torchvision/torchaudio のみ。triton は Linux のみ）。
Windows で使えるのはフォークの `triton-windows`（woct0rdho、HIP バックエンド対応あり）のみ。

```powershell
uv pip uninstall --python "C:\Users\dai86\Documents\ComfyUI\.venv\Scripts\python.exe" triton-windows   # 2026-08-16 実施
```

- **2026-08-16 削除**: 3.7.1 でも実ワークロード（H3 テキストエンコーダの int8 経路）でクラッシュするため、
  **この機では完全に不要**（HIP バックエンドが int8 を処理）。未使用パッケージの削除で、
  `LLAMADOCK_COMFY_TRITON=1` での誤クラッシュも防止。ランチャーは triton 不在時も「警告＋フラグ省略」で正常動作。
  将来 triton-windows がこの GPU に対応したら再導入可能（`uv pip install ... triton-windows==3.7.1.post27`）。
- **クラッシュの根本原因（判明）**: `comfy/quant_ops.py`（0.33.0）は「triton < 3.7 は ROCm INT8 パスに不適合
  （libdevice.rint 欠落でクラッシュ）」と**既にバージョンガード済み**。ただし
  `if args.enable_triton_backend or triton_version >= (3, 7)` のため、`--enable-triton-backend` を
  **明示指定するとガードが無効化**され、3.5.1 のまま有効化 → クラッシュしていた。
- **対策（最終形）**: 単体カーネルテストは通るが実ワークフローではクラッシュするため、ランチャーは
  **デフォルトで `--enable-triton-backend` を付けない**（HIP バックエンドが正常動作する実用パス）。
  どうしても試す場合は `LLAMADOCK_COMFY_TRITON=1` で opt-in（`triton` / `super` プロファイル両対応）。
- **3.7.1 実機検証の結果（2026-08-15）**: import・単体 HIP カーネルコンパイルは PASS するが、
  `--enable-triton-backend` で H3 テキストエンコーダ（nvfp4_awq）ロード中に
  `error: couldn't allocate input reg for constraint 'r'` で ComfyUI がクラッシュ（以前の 3.5.1 と同じ系統）。
  → **triton フラグはこの機では無効化が正解**。ck + HIP（`super` = ck フォールバック）が動作中の最速構成。
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

## 2026-08-15: 全部載せ（super）＋ 短尺オーディオ全設定スモークテスト

### 全部載せ構成の追加

- **`h3_workflow_super.json`**: Turbo LoRA（strength 1.2）+ ClipProj（4B）を**同時適用**した全部載せ版
  （8step・res_multistep・σ video 12 / audio 6）。`h3_workflow_super_short.json` は 512x320・16f・fps12 の確認用。
- **`super` プロファイル**（`Get-ComfyUILaunchArgs`）: `--use-ck-attention` + `--enable-triton-backend` の同時付与。
  選択メニューを**速い順**に並べ替え: `[1] super / [2] ck / [3] fast / [4] default / [5] bench / [6] custom`（triton 削除に伴い更新）。

### triton 3.7.1 実機検証の結果（→ デフォルト無効化に修正）

- 単体テスト（import + gfx1101 HIP カーネルコンパイル）は PASS するが、`--enable-triton-backend` 付きで
  H3 テキストエンコーダ（nvfp4_awq）ロード中に `error: couldn't allocate input reg for constraint 'r'` で
  ComfyUI がクラッシュ（3.5.1 と同じ系統。`super` プロファイルで再現）。
- **対策**: `Get-TritonBackendFlags` を「デフォルト無効・`LLAMADOCK_COMFY_TRITON=1` で opt-in」に変更。
  この機では `super` は ck 相当にフォールバック（動作中の最速構成）。HIP バックエンド（triton 無し）は正常動作。

### 短尺オーディオ全設定スモークテスト（512x320・16f・fps12・ck プロファイル）

オーディオ VAE + `VAEDecodeAudio` → `CreateVideo(audio=...)` で音声付き出力。
4 設定すべて成功。**ただし後日判明: この時点の音声は AAC トラックは存在するが完全無音だった**
（下記 2026-08-16 の音声 VAE 修正を参照。PyAV で「トラックの存在」だけを見て「音声が出ている」と誤認していた）。

| ワークフロー | 構成 | 所要時間 | 出力 |
| --- | --- | --- | --- |
| `h3_workflow_bench_short_audio.json` | 20step・32B エンコーダ | **244.7s** | h3_bench_audio_00001_.mp4 |
| `h3_workflow_turbo_short_audio.json` | 8step・Turbo LoRA・32B | **48.0s** | h3_turbo_audio_00001_.mp4 |
| `h3_workflow_clipproj_short_audio.json` | 20step・ClipProj 4B | **66.2s** | h3_clipproj_audio_00001_.mp4 |
| `h3_workflow_super_short_audio.json` | 8step・Turbo LoRA + ClipProj 4B | **45.7s** | h3_super_audio_00001_.mp4 |

低解像度・短尺のスモークテスト（モデルロード含む）であり、フル解像度ベンチとは非比較。
ただし相対傾向は明確: **super（8step 全部載せ）が最速**で、20step 構成の約 1/5。
フル解像度（1344x768・48f・音声付き）での本計測は次の一手。

## テキストで動画生成（チャット UI、2026-08-16 追加）

- **`tools/h3-chat.py`**（+ ランチャー `tools/h3-chat.ps1`）: ノード UI を触らずに
  プロンプトを打つだけで動画を作れるローカルチャットページ（`http://127.0.0.1:8189`）。
  ComfyUI の API をプロキシする小さなサーバーで、ブラウザの CORS 問題を回避。
- **使い方**: ①`comfyui.bat` / `llamadock.bat` で [2] plan（または Enter=ck 起動後に手動）を選んで ComfyUI 起動
  ②`powershell -ExecutionPolicy Bypass -File tools\h3-chat.ps1` ③ブラウザが開くので文章を入力→生成。
- **モード**: クイック（`h3_workflow_super_short_audio.json`・512x320・16f・音声あり・約1分）/
  フル（`h3_workflow_super_audio.json`・1344x768・48f・音声あり・約9分、新規追加）。
  seed は毎回ランダム。完了後はページ内で再生＋保存先パス表示。
- **✎ 企画モード**（2026-08-16 追加・同日 Z-Image 連携化）: チェックを入れると、
  **「キー画像 → 動画」の2段階**で企画できます。
  ① ローカル企画 LLM（llama-server・CPU 推論・VRAM 不使用・`http://127.0.0.1:8190`）と日本語で
     「打ち返しながら」アイデアを固め、`[IMG_PROMPT]` / ツール呼び出しの形で英語の**画像プロンプト**に仕上げる。
  ② **Z-Image Turbo**（`h3_workflow_zimage.json`・`lesliemore/z-image-turbo-nsfw-v2` GGUF Q8_0 7.2GB）
     でキー画像を高速生成（この機で 8step 約15秒）。UnetLoaderGGUF は `ComfyUI-GGUF` カスタムノードが必要。
  ③ 画像を確認 → 必要なら日本語で修正指示（再生成）→ **✅ この画像で確定**。
     確定時に ComfyUI へ `POST /free` を送り Z-Image をアンロード（VRAM 解放 =「Z-Image を落とす」）。
  ④ 確定した画像プロンプトをもとに企画 LLM が `[FINAL_PROMPT]` の英語**動画プロンプト**を作成
     （画像の内容・構図を保ちつつ動き・カメラ・時間経過を追加）→「🎬 この企画で生成 ▶」で生成。
  ⑤ 動画完成後は**自動停止**: ブラウザ側 90 秒カウントダウン（即停止/ComfyUI のみ/キャンセル可）、
     ブラウザが閉じていてもサーバー側が 180 秒後に ComfyUI・企画 LLM を停止し GPU・メモリを解放。
  企画 LLM は `tools/h3-chat.ps1` の `-PlanModel` で選択（**`Qwen3.5`** Qwen3.5-4B Uncensored・NSFW・視覚対応・デフォルト / `Off` 無効）。
  Qwen3.5 は `--mmproj`（視覚エンコーダ 675MB）付きで起動し、**確定したキー画像を base64 で送って
  実際に見た上で**動画プロンプトを作成します（`h3-chat.py` が `data:image/...` 形式で添付）。
  旧 LFM / DirtyMuse は Qwen3.5 に一本化したため削除済み（ツール呼び出し形式のパースは
  他モデル対応として h3-chat.py に残してあります）。モデル導入元:
  `Sinbad-The-Sailor/Qwen3.5-4B-NSFW-ARA-Heretic-Literotica`（えろ文芸特化・Literotica / erotica チューニング）。旧 `HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive` は差し替えで削除済み。
- **視覚入力の検証テスト**（`tools/test-plan-vision.py`）: 合成画像（既知の色・形）を直接見せて
  記述が一致するか（[A]）と、テキストプロンプト無しでキー画像だけを確定パスに通して最終動画
  プロンプトが画像内容を反映するか（[B]）を自動チェックします。企画 LLM + h3-chat 起動中に
  `python tools/test-plan-vision.py` で実行（両方 PASS なら視覚入力が実効している証拠）。

## 2026-08-16: 音声 VAE 修正 + Heretic 4B 導入

### 音声が完全無音/NaN だった根本原因（Reddit / GitHub 調査で特定）

- **症状**: `[aac] Input contains (near) NaN/+-Inf` で SaveVideo が落ちる（`avcodec_send_frame()`）。
  8/15 の「成功」分も実は **std=0 の完全無音トラック**だった（PyAV の統計で確認）。
- **既知問題**: ComfyUI issue #15315（公式 H3 T2V ワークフローで毎回再現、NaN 音声）・
  #15614（H3 音声が常に static/ノイズ）。Reddit でも「ComfyUI 更新で H3 音声が壊れた→修正入り」
  （kemb0 スレ、2026-08-07）。
- **根本原因（ローカルで特定）**: 起動ログの `Missing VAE keys [... decoder.conv_pre.weight ...]` 警告。
  公式 `MiniMax-H3-audio_vae_fp32.safetensors`（MiniMax org）は **weight-norm 形式
  （`weight_g`/`weight_v`、1086 テンソル）の未変換チェックポイント**だが、ComfyUI 0.33 の
  `comfy/ldm/minimax/audio_vae.py` は「weight-norm 畳み込み済みの素の `*.weight`」を strict=True で期待
  → 全キー欠落 → デコーダが空のまま → 無音 or NaN。
- **修正**: **Comfy-Org 公式の変換済み版 `vae/minimax_h3_audio_vae_fp32.safetensors`**
  （917 テンソル・weight_norm ゼロ・素の `decoder.conv_pre.weight`）に差し替え。4 つの音声ワークフロー
  （bench / turbo / clipproj / super の short_audio）の `vae_name` を更新。旧ファイル（605MB）は削除。
- **検証**: 同一シード 42 の super 短尺で再実行 → 音声 std=0.0092 / maxabs=0.047 の**実音声**が出力された
  （旧 VAE は std=0.00000）。`h3_super_audio_00005_.mp4`。

### Heretic 4B（軽量・拒否無し）エンコーダ導入

- **導入**: `DreamFast/Qwen3-VL-4b-Heretic-ComfyUI` の `qwen3-vl-4b-heretic_fp8_e4m3fn.safetensors`
  （4.5GB、fp8）を `qwen3vl_4b_heretic_fp8.safetensors` として配置。
  旧 4B（`qwen3vl_4b_fp8_scaled`、5.2GB）と**同一言語構造（36 層・900 テンソル）のドロップイン**。
  Qwen3-VL-4B-Instruct の Heretic（abliteration）版で、HarmBench ASR 30.8%→100%（拒否 0 相当）・
  KL 0.0283（挙動ほぼ不変）。
- **差替範囲**: 4B を参照する 6 ワークフロー全部（clipproj / clipproj_short / clipproj_short_audio /
  super / super_short / super_short_audio）の `clip_name` を変更。32B 系（bench / turbo / fast）は不変。
- **これで 2 系統とも拒否無し**: 32B（高品質・15.7GB）= Heretic / 4B（軽量・4.5GB・VRAM 約 11GB 節約）= Heretic。
  旧 4B（fp8_scaled）は削除予定（動作確認後に実施）。

### Heretic（uncensored）テキストエンコーダへ差替（2026-08-15）

- **導入**: `sakamakismile/Qwen3-VL-32B-Heretic-MiniMax-H3-NVFP4` の
  `qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors`（15.7GB、NVFP4）を
  `text_encoders/Qwen3-VL-32B-Instruct/` に配置。Comfy-Org の nvfp4_awq と**同サイズのドロップイン置換**
  （`CLIPLoader` type: `minimax` のまま）。拒否の主因は Qwen3-VL-32B エンコーダのアラインメント層で、
  Heretic 系はそれをバイパス（ethanfel の Ultra-Heretic の NVFP4 再量子化）。16GB カードで実測ピーク ~9.9GB。
- **差替範囲**: 32B エンコーダを参照する 7 ワークフロー全部（bench / bench_short_audio / fast / src /
  turbo / turbo_short / turbo_short_audio）の `clip_name` を Heretic に変更。
  4B（ClipProj 系: clipproj / super）は対象外。
- **動作確認（短尺）**: `h3_workflow_turbo_short_audio.json`（Heretic）が成功
  （`Prompt executed in 80.33s`、h3_turbo_audio_00002_.mp4、AAC 音声付き）。
- **旧エンコーダ削除**: `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`（15.6GB）を削除（15.6GB 解放）。
  出所メモは `TEXT_ENCODER_SOURCES.txt` に追記済み。

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
| `h3_workflow_super.json` | **全部載せ**: bench + Turbo LoRA（strength 1.2）+ 8 step・res_multistep・σ video 12 / audio 6 + **ClipProj（4B）** を同時適用 | 最速構成（`super` プロファイルと組む） |

- Spectrum / Turbo LoRA / ClipProj はすべて併用可能（それぞれ別の層を最適化する）。
  `h3_workflow_super.json` が Turbo LoRA + ClipProj の全部載せ版（`h3_workflow_super_short.json` は 512x320・16f・fps12 の動作確認用）。
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

## 7. R2V（参照モード・参照 LoRA）— 2026-08-16 追加

### 概要

**参照画像（キー画像）→ 同一キャラ維持の動画**を生成する R2V モード。
ComfyUI の `MiniMaxH3ReferenceToVideo` ノード（ref2va）を使うが、**専用の ref2va モデルは不要**。
Kijai の **参照 LoRA**（`minimax_h3_ref_lora_rank_256_bf16.safetensors`）を fl2va モデルに
`LoraLoaderModelOnly` で重ねるだけで参照条件付き生成が動く（javawock7618 の
comfy-MiniMax-H3-workflows の Note より確認。`ref2va` モデルは別途あり、そちらは非対応機でも動くが未検証）。

### 導入（Windows 機）

1. 参照 LoRA をダウンロードして配置:
   `https://huggingface.co/Kijai/MiniMax-H3-experimental/tree/main/loras` の
   `minimax_h3_ref_lora_rank_256_bf16.safetensors` → `ComfyUI\models\loras\`
2. ワークフロー（コミット済み）: `h3_workflow_r2v.json`（1344x768・48f・音声付き）/ `h3_workflow_r2v_short.json`（512x320・16f・fps12・音声付き）
   - node 1 = UNETLoader（fl2va int8）→ node 11 = Turbo LoRA（strength 1.2）→ node 12 = **参照 LoRA**（strength 1.0）→ node 4 = SigmaShift（video 12 / audio 6）
   - node 16 = LoadImage（参照画像。h3-chat が ComfyUI `input/` にコピーしたファイル名を設定）
   - node 6 = `MiniMaxH3ReferenceToVideo`（`ref_images.ref_image_0` ← node 16。**API 形式はドット付きキー**。ComfyUI 0.33 の expandable 入力は `ref_images.ref_image_0` のような dotted path で受ける）
   - プロンプトは `<Picture 1>` タグで参照画像を指定（h3-chat が末尾にタグ説明を自動追記）
3. h3-chat で使用: 企画モードでキー画像を確定 → 🔗 参照モードにチェック → 生成
   （`/api/generate` に `ref: true` + `image: <確定画像ファイル名>` を送る。`mode` は high→フル / quick→短尺 に自動で R2V ワークフローへ切替）

### 注意・チューニング

- **Spectrum はオフ推奨**（参照 LoRA 併用時。javawock7618 の Note 準拠。現行 r2v ワークフローは Spectrum 未適用）
- **4–8 step 推奨**（現行は Turbo LoRA 込み 8 step・res_multistep/simple・σ video 12 / audio 6）
- `ref_image_size`: `match` = 生成解像度に合わせ縮小（速い）/ `max` = 2048px 短辺まで保持（同一性↑・遅い）。
  初回は `match` で検証し、顔の同一性が弱ければ `max` を試す
- 参照 LoRA の `strength_model` は 0.8–1.2 の範囲で A/B する（初期値 1.0）
- **LoRA スタック順は問わない**（`LoraLoaderModelOnly` は逐次適用）。Turbo + Ref の両方で問題なし
- Sage-Attention（SolAttn_triton）は **CUDA 専用**のためこの機（RDNA3）では使わない。ck-attention のまま
- 参照画像は `input/` に `h3_ref_<timestamp>_<元ファイル名>` でコピーされる（同名衝突なし・毎回新規）
- 参照できるのは 1 枚（`ref_image_0`）。複数参照（最大 9 枚）や参照動画/音声は今後の拡張候補
