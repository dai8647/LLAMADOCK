# LlamaDock

ローカル **GGUF モデル**を用途別ワークスペースに起動する Windows 向けランチャーです。Docker / WSL を使わず、ネイティブの llama.cpp (`llama-server.exe`) を起動し、コーディング・チャット・エージェント・リサーチの各ワークスペースへ接続します。

> **セキュリティ方針**: このリポジトリは API キー・認証情報・トークンを一切含みません。API キーは Windows の環境変数のみで参照します。マシン固有パス（モデル・ComfyUI 等）はスクリプト内にフォールバックとして存在しますが、すべて `LLAMADOCK_*` / `LLAMA_TQ3_*` 環境変数で上書きできます（本リポジトリ自体に個人データは含まれません）。詳しくは下記「セキュリティ」を参照してください。

---

## 主なワークスペース

| ワークスペース | 用途 |
| --- | --- |
| **Cline** | コーディング用エージェント |
| **OpenCode** | ローカル OpenAI 互換 API に接続するターミナル型コーディングエージェント |
| **Open WebUI (Computer)** | 会話・Web 検索・コンパクション対応のブラウザ UI |
| **Llama Agent** | ターミナル型エージェント + 反復 Web 調査ハーネス |
| **ComfyUI** | MiniMax H3 ビデオ / オーディオ生成 |
| **DeepSeek Harness** | エージェントハーネス（npx 自動インストール＋自動アップデート） |

---

## 起動

```powershell
.\llamadock.bat
```

互換用エントリポイントとして `llama-tq3-chat.bat` も残しています（中身は `llamadock.bat` を呼び出します）。

ComfyUIだけを起動する場合は、モデル選択を省略できます。

```powershell
.\comfyui.bat
```

`llamadock.bat` を起動した場合も、最初に LLM workspace と ComfyUI を選択できます。

### MiniMax H3 の高速化

ComfyUI の起動フラグは調査に基づく既定値（`--reserve-vram 1.0`、`--lowvram` なし）が自動適用されます。
起動時に「ComfyUI tuning」メニュー（**推奨順**: `[1] plan`（ck + 企画モード・Enter でも可）/ `[2] ck` / `[3] default` / `[4] custom`。super / fast / triton / bench は `LLAMADOCK_COMFY_PROFILE` で指定可）で対話的に切り替えられます。
`[1] plan` を選ぶと **ck + 企画モード** で起動し、h3-chat（企画 LLM 付き）を自動で開きます。企画 LLM は **Qwen3.5-4B**（CPU・8190・視覚対応・常駐）と **Qwen3.8-27B**（GPU・8191・企画フェーズのみ・高品質）を選択でき、27B は生成直前に h3-chat が自動停止して VRAM を空けます。両方起動済みなら二重起動せずブラウザを開くだけです。
セッションメニューで `[4] Stop server and exit` を選ぶと、**ComfyUI / h3-chat / 企画 LLM も全部停止して GPU・RAM を解放するか**を確認します。
プロファイル／環境変数でも指定できます（`LLAMADOCK_COMFY_PROFILE=super|ck|fast|bench|triton`、
`LLAMADOCK_COMFY_FLAGS`、`-ComfyUIFlags`）。`ck` は `--use-ck-attention`（comfy-kitchen attention、
**ComfyUI 0.33.0 以上**）で、この機（RX 7800 XT）で有効化を確認済み。`super` は ck + triton の
全部載せですが、triton 3.7.x はこの GPU の H3 INT8 経路でクラッシュするためデフォルトで ck 相当に
フォールバックします（`LLAMADOCK_COMFY_TRITON=1` で強制有効化。triton-windows は 2026-08-16 に
アンインストール済みのため、この機では常に ck 相当になります）。

ComfyUI 起動後に **`tools\h3-chat.ps1`** を実行すると、ノード UI を触らずテキストで動画を生成できる
チャットページ（`http://127.0.0.1:8189`）が開きます（クイック約1分 / フル約9分・音声付き）。

チャット欄の **✎ 企画モード** にチェックを入れると、**「キー画像 → 動画」の2段階**で企画できます。
① ローカル LLM（CPU 推論・VRAM 不使用）と日本語で「打ち返しながら」アイデアを固め、英語の画像プロンプトを生成
② **Z-Image Turbo**（GGUF Q8・`lesliemore/z-image-turbo-nsfw-v2`）でキー画像を高速生成（約15秒）
③ 画像を確認 → 必要なら日本語で修正指示 → 確定すると Z-Image をアンロード（VRAM 解放）
④ 確定した画像をもとに企画 LLM が英語の動画プロンプト（動き・カメラ・時間経過を追加）を作成 → 生成
動画が完成すると **自動停止のカウントダウン**が始まり、放置すれば ComfyUI・企画 LLM を停止して
GPU・メモリを解放します（ブラウザが閉じていてもサーバー側で 180 秒後に確実に停止）。
企画 LLM は `-PlanModel Qwen3.5`（**Qwen3.5-4B NSFW Literotica・えろ特化・視覚対応、デフォルト）/ `Off`（無効）で
選択します。Qwen3.5 は mmproj 視覚エンコーダ付きで起動するため、**確定したキー画像を実際に見て**
動画プロンプトを作成します。旧 LFM / DirtyMuse / Qwen3.5-4B-Uncensored は一本化・削除済みです。
**h3-chat.py は企画 LLM を自動起動します**（8190 が落ちていても起動時にバックグラウンドで
llama-server を立ち上げ、リクエスト時に再接続も試みる）。「企画 LLM が接続されていません」
エラーは、モデルか llama-server が存在しない場合を除き出なくなります。

**🔗 参照モード（R2V）**: キー画像を確定した状態で参照モードにチェックを入れて生成すると、
確定画像を **参照画像（`<Picture 1>`）** にして同一キャラ維持の動画が作れます。
`MiniMaxH3ReferenceToVideo` + **参照 LoRA**（`minimax_h3_ref_lora_rank_256_bf16`、Kijai 製・
`models\loras\` に配置）を fl2va モデルに重ねる構成で、**ref2va モデルの追加ダウンロードは不要**です。
画像は自動で ComfyUI `input/` にコピーされ、プロンプト末尾にタグの説明が追記されます。
詳細・設定（`ref_image_size` match/max・strength）は `docs/MiniMax-H3-Tuning.md` 参照。

**⚡ ハイスピード / 高精度モード切替**: チャット欄のラジオボタンで品質を選べます。
- **high**（高精度）: turbo LoRA + 8step + 1344×768（約9分）
- **quick**（標準）: turbo LoRA + 8step + 512×320（約4分）
- **lite**（軽量）: turbo LoRA + 8step + 1344×768（super ワークフロー）
- **fast**（最高画質）: **Spectrum + 20step（ターボ LoRA なし）** + 1344×768（アーティファクトなし）
- チャットで「最速」「最高画質」等の自然語言指示でも切替可能（`fast_quick` = fast + 短尺）

MiniMax H3 の高速化（Spectrum / **Turbo LoRA** / **ClipProj** の A/B ワークフロー
`h3_workflow_fast.json` / `h3_workflow_turbo.json` / `h3_workflow_clipproj.json` / `h3_workflow_super.json` 含む計 17 個のバリアント
（短尺音声付き `*_short_audio`・スーパー `*_super` 系・**R2V 参照 `h3_workflow_r2v*.json`** を含む）の一覧・調査結果・導入方法は **`docs/MiniMax-H3-Tuning.md`** に、現状把握は以下にまとめています。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\comfyui-tune.ps1
```

### 基本フロー

1. モデルを選択
2. Workflow preset を選択
3. Workspace を選択
4. コンテキスト / KV cache / GPU offload などを確認
5. LlamaDock が `llama-server` と選択したワークスペースを起動

`select-model.ps1` は引数でモード／値を直接指定することもできます（例: `-PresetMode WebUIChat -ClientMode WebUI`）。スクリプト冒頭の `param()` を参照してください。

---

## Workflow Presets

| Preset | 内容 |
| --- | --- |
| **Manual** | すべて手動選択 |
| **Code - Cline** | Cline 向けの安定設定 |
| **Code - OpenCode** | OpenCode 向けの安定設定 |
| **Agent Research** | llama-agent + 反復 Web 調査ハーネス |
| **Chat** | Open WebUI（Web 検索・会話コンパクション） |
| **DeepSeek Harness** | エージェントハーネス（ローカル llama.cpp 接続・API キー不要、npx 自動インストール＋自動アップデート） |

---

## ランタイム

モデル名から実行ランタイムを自動選択します。

- `DeepSeek`系: **ExpertsLaguna** runtime
- その他の通常GGUF: **AtomicBot TurboQuant** runtime
- `TQ3` / `TQ3_4S` を含むモデル: **TurboTan** runtime
- `Ternary` / `Bonsai` を含むモデル: **PrismBonsai** runtime（PrismML-Eng/llama.cpp fork）
- 手動指定時のみ: Official llama.cpp **Vulkan / HIP / CPU** runtime

各ランタイムの既定パスと、環境変数による上書き方法（例: `LLAMA_TQ3_TURBOTAN_SERVER`、`LLAMADOCK_OFFICIAL_HIP_SERVER`）は `docs/LlamaDock-Runbook.md` に記載しています。

起動時に RAM・GPU・推定 VRAM・検出済み runtime を表示します。VRAM は `nvidia-smi` がある場合は高信頼、それ以外は `Win32_VideoController` からの推定です。

---

## ディープリサーチ（Llama Agent）

`Llama Agent` で調査テーマを入力すると、`tools/deep-research-harness.mjs` が以下を実行します。

- 調査観点の分解と複数検索クエリ生成
- Serper API 検索（`SERPER_API_KEY` がある場合）
- DuckDuckGo / Bing HTML 検索（フォールバック）
- ページ取得と本文抽出、LLM による証拠抽出
- 未解決ギャップを使った次ラウンド検索、citation URL 付き証拠パック生成

深さは起動時に `1 / 2 / 3` で選択できます（Light / Standard / Heavy）。Serper API キーは **Windows の環境変数のみ**に設定してください。

---

## MCP

`mcp-server.js` と各 `mcp-*.bat` が MCP サーバーを提供します（filesystem / memory / playwright / markitdown / context7 / web search など）。構成の例は `mcp.json` と `MCP-ENDPOINTS.txt` を参照してください。依存関係は `package.json` で管理します。

---

## ディレクトリ構成

```text
.
├── llamadock.bat              # 推奨エントリポイント
├── select-model.ps1           # メインランチャー
├── package.json               # MCP 依存関係
├── mcp-server.js              # MCP サーバー本体
├── mcp-*.bat                  # MCP 起動ヘルパー
├── model-notes.json           # モデル別メモ（推奨プリセット等）
├── config/                    # プロファイル / パラメータスキーマ / プリセット / OpenCode 設定
│   ├── params-schema.json     # 全パラメータの機械可読カタログ（GUI設定パネルの定義）
│   └── memory-presets.json    # 省メモリ／速度プリセット（1クリック適用用）
├── docs/                      # 設計・運用・パラメータカタログ
├── web-ui/                    # Web GUI（3カラム・ダークテーマ・依存ゼロ）
│   ├── server.js              # 静的配信 + REST API（node:http のみ）
│   ├── arg-builder.js         # スキーマ駆動の引数生成（解決順: 上書き→記憶→プロファイル→既定）
│   ├── launch-manager.js      # 起動/停止/計測のランタイム状態機械（ready待ち・healthポーリング）
│   ├── results-store.js       # run-results.json 蓄積 + 実測認定ロジック（Phase 4）
│   ├── client-manager.js      # ワークスペース接続（Cline/OpenCode/…/ComfyUI）の起動契約
│   ├── mock-llama-server.mjs  # 非Windows用のシミュレーション llama-server（計測ループ検証用）
│   ├── index.html             # 3カラムUI（左: モデル / 中央: パラメータ / 右: モニタ）
│   ├── style.css              # テーマ
│   └── app.js                 # スキーマ駆動フォーム生成・引数プレビュー・モデル別記憶・状態ポーリング
└── tools/                     # 調査ハーネス・ランタイムヘルパー・検証スクリプト
```

## Web GUI（パラメータコントロールパネル）

`config/params-schema.json` と `config/memory-presets.json` から設定パネルを自動生成する
ブラウザUIです（設計は `docs/PARAMETER-CATALOG.md`）。依存ゼロ（Node 標準ライブラリのみ）。

```bash
npm start            # http://127.0.0.1:3000
npm run start:web    # 同じ
npm run start:mcp    # MCP ウェブ検索サーバー（http://127.0.0.1:3100/mcp）
```

- 左: モデル一覧（追加・エンジン推定・`model-notes.json` の推奨プリセット / 警告）
- 中央: スキーマ駆動のパラメータパネル（グループ折り畳み・上級設定・メモリプリセット1クリック適用・生成される起動引数プレビュー）
- 右: サーバー状態（信号灯・PID・メトリクス）・起動/停止・**計測実行**・実測結果一覧・ログ・ワークスペース接続

`per_model: true` の項目はモデル別に `config/models-config.json`（gitignore 対象）へ保存され、
起動時の解決順は「個別上書き → `_profiles` パターン → スキーマ既定 → メモリプリセット」です。

### 起動 → 計測 → 実測認定（Phase 4）

`起動` は設定を解決し（`web-ui/arg-builder.js`）起動引数を生成して llama-server を立ち上げます。
`計測実行` は起動中のサーバーに 3 回の Chat Completions を送り、実測 tok/s・VRAM・RAM・成否を
`config/run-results.json`（gitignore 対象）へモデル別・設定別に蓄積します。

- **実測成功 3 回以上**の設定だけをそのモデルの「推奨（実測）」として表示（「推奨は断言ではなく
  実測で裏付けられた仮説」方針）。設定が違えば設定ごとに独立して集計されます。
- プラットフォーム分岐:
  - **Windows**: `LLAMADOCK_ENGINE_BIN` にエンジン実行ファイルを設定すると実際の llama.cpp を起動します
    （Phase 1 コアの配線待ち。未設定時は明確なエラーを返します）。
  - **その他（プレビュー等）**: `web-ui/mock-llama-server.mjs` のシミュレーション llama-server を起動し、
    起動→ready待ち→計測→停止の一連のループを実プロセスで検証できます（`simulated: true` で識別）。

### ワークスペース接続（`POST /api/connect`）

起動中のサーバーに対して Cline / OpenCode / Open WebUI /
Llama Agent / DeepSeek Harness / ComfyUI を接続します（右カラムの「ワークスペース接続」）。

- **Windows**: `web-ui/client-manager.js` が `select-model.ps1` の `Open-*Client` と同じ起動経路を
  （detached で）実行します。Cline / OpenCode は `tools/llamadock-client-shell.ps1`、
  WebUI は `tools/computer-start.ps1`、
  LlamaAgent は `llama-agent.exe`、ComfyUI は `main.py --port 8188`。接続先は回復ゲートウェイ
  `http://127.0.0.1:8090/v1` です。
- **その他（プレビュー等）**: リクエスト全体を検証した上で、Windows が実行する正確なコマンドを
  `simulated: true` で返します（実クライアントは起動しません）。未起動時の接続は `server_not_running` で拒否。
- **ComfyUI は例外（standalone）**: `select-model.ps1` の `Open-ComfyUIClient` と同様、llama-server が
  起動していなくても接続できます（ComfyUI は独自に :8188 で動くため）。モデルを先に起動する必要はありません。
- 各クライアントの接続状態（未接続 / 接続済み / sim / エラー）は `/api/status` の `clients` に載り、
  UI のチップで確認できます。

### クライアント稼働モニタ（`GET /api/clients/health`）

独自の HTTP サーバーを持つワークスペース（Open WebUI :8000 / ComfyUI :8188）は、
接続状態とは別に**実際に稼働しているか**を 10 秒間隔でプローブします。

- プローブ先: WebUI `http://127.0.0.1:8000/`、ComfyUI
  `http://127.0.0.1:8188/system_stats`。ポートは `LLAMADOCK_<ID>_PORT`（例 `LLAMADOCK_COMFYUI_PORT=8190`）で
  変更でき、起動コマンド（ComfyUI の `--port`）と監視が同じ値を使うためずれません。
- UI: 各クライアントの説明の横に稼働ドット（緑 = 応答あり・赤 = 停止/接続拒否）。応答中は「開く ↗」が
  出てブラウザで直接開けます。CLI クライアント（Cline 等）は HTTP サーバーを持たないためドットなし。
- プレビュー環境では何も待ち受けていないため、Web 系は「停止中」と表示されます（真実の状態です）。

### ComfyUI / MiniMax H3

**ComfyUI は llama-server を必要としない「単独起動」ワークスペース**です。起動コマンドは
`select-model.ps1` と同一で、ComfyUI の `.venv` の Python で `main.py --port 8188 --listen 127.0.0.1` を
実行します（ルートは `LLAMADOCK_COMFYUI_ROOT` で変更可、既定 `C:\Users\dai86\Documents\ComfyUI`）。
既に :8188 で起動中なら再利用します。

**MiniMax H3（`minimax_h3`）は llama-server 用のテキストモデルではありません**。
33B の動画・音声生成 DiT（拡散モデル）で、ComfyUI 内で GGUF として読み込みます（`model-notes.json` に警告あり）。

- GGUF: `joeygambino/MiniMax-H3-GGUF`（fl2va / ref2va、Q8_0・Q5_1・Q5_0・Q4_0 のみ。K 量子化は hidden width 2688 のため不可）
- 前提: **ComfyUI 0.30.0+** + **ComfyUI-GGUF** + **ComfyUI-H3-Multishot v1.5.2+**（GGUF 版）
  （ネイティブ版は `MiniMaxAI/MiniMax-H3` のノード。`Open-ComfyUIClient` は起動時に
  `MiniMaxH3ImageToVideo` / `MiniMaxH3SigmaShift` などのネイティブノードを検出し、無ければ警告します）
- 必須の付属ファイル: テキストエンコーダ GGUF（`joeygambino/MiniMax-H3-encoder-GGUF` = Qwen3-VL-32B + mmproj）と VAE（`Comfy-Org/MiniMax-H3`）。エンコーダなしでは生成できません。
- 配置例: ComfyUI の `extra_model_paths.yaml` で `.lmstudio\models\MiniMax-H3` を参照し、DiT・エンコーダ・mmproj・VAE を置きます。
- VRAM 目安: Q5_1 ≈ 25.9 GB（24–32 GB カード）、Q4_0 ≈ 19.9 GB（16 GB カードはストリーミング）。

MiniMax H3 を Web GUI に登録すると、エンジンは「ComfyUI (DiT)」と表示され、起動フロー（llama-server）には
回りません。

> プレビュー環境では `127.0.0.1:8080` が使用中の場合、`LLAMADOCK_UPSTREAM_PORT` で
> llama-server のポートを変更できます。

## パラメータカタログとプリセット

`config/params-schema.json` に、ランタイムエンジン・GPU/CPU配分・KVキャッシュ種・MoEエキスパート配置
（ホットエキスパート＝`--moe-expert-placement frequency`）・投機的デコード（MTP/Eagle3/将来のDSpark）など
**42項目の全パラメータ**を機械可読で定義しています。GUI の設定パネルはこのスキーマから自動生成します。

`config/memory-presets.json` には **省メモリ／速度プリセット**（very-light / light / balanced / full /
moe-cpu-first / spec-mtp / spec-eagle3 / spec-off）を定義しています。Web GUI の上部バーから
1 クリックで適用できます。

Web GUI（3カラム・ダークテーマ）の設計・引き継ぎ資料は **`docs/PARAMETER-CATALOG.md`**、
実装済みのコントロールパネルは **`web-ui/`** を参照してください（上記「Web GUI」セクション）。


## 検証

編集後は以下を実行してください。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test.ps1
```

- PowerShell 構文チェック / フォーマット確認
- `model-notes.json` 検証 / Node.js ツール構文チェック
- 秘密情報スキャン
- 全プリセットの dry run

---

## セキュリティ / 公開時の注意

このリポジトリを公開する際は、以下を守ってください。

- `.env`、ログ、DB、`node_modules`、`mcp-data/` などを含めない（`.gitignore` で除外済み）
- API キー、Bearer token、個人アクセストークンをコミットしない
- API キーは Windows 環境変数のみで参照する（スクリプトや README に書かない）
- **Llama Agent は `--yolo`（全ツール自動承認・シェル権限あり）で起動します**。ローカルの llama-server にのみ接続する設計ですが、ターミナルに全権を与えるツールである点に留意してください

---

## ライセンス

本リポジトリ内のソースコードは特に明記のない限り自由にご利用ください（必要に応じて LICENSE を追加してください）。
