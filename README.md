# LlamaDock

ローカル **GGUF モデル**を用途別ワークスペースに起動する Windows 向けランチャーです。Docker / WSL を使わず、ネイティブの llama.cpp (`llama-server.exe`) を起動し、コーディング・チャット・エージェント・リサーチの各ワークスペースへ接続します。

> **セキュリティ方針**: このリポジトリは API キー・認証情報・トークンを一切含みません。API キーは Windows の環境変数のみで参照します。マシン固有パス（モデル・ComfyUI 等）はスクリプト内にフォールバックとして存在しますが、すべて `LLAMADOCK_*` / `LLAMA_TQ3_*` 環境変数で上書きできます（本リポジトリ自体に個人データは含まれません）。詳しくは下記「セキュリティ」を参照してください。

---

## 主なワークスペース

| ワークスペース | 用途 |
| --- | --- |
| **Cline** | コーディング用エージェント |
| **OpenCode** | ローカル OpenAI 互換 API に接続するターミナル型コーディングエージェント |
| **OpenClaude** | ローカル OpenAI 互換 API に接続する Claude Code 系ターミナルエージェント |
| **Open WebUI (Computer)** | 会話・Web 検索・コンパクション対応のブラウザ UI |
| **Llama Agent** | ターミナル型エージェント + 反復 Web 調査ハーネス |
| **Deep Research** | Odysseus によるローカル LLM リサーチ UI |
| **ComfyUI** | MiniMax H3 ビデオ / オーディオ生成 |

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
起動時に「ComfyUI tuning」メニュー（**速い順**: super / ck / fast / default / bench / custom / **plan**。triton はアンインストール済みのため削除）で対話的に切り替えられるほか、
`[7] plan` を選ぶと **ck + 企画モード** で起動し、h3-chat（企画 LLM 付き）を自動で開きます（企画 LLM は `LFM` / `DirtyMuse` を選択可）。両方起動済みなら二重起動せずブラウザを開くだけです。
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
企画 LLM は `-PlanModel Qwen3.5`（**Qwen3.5-4B Uncensored・NSFW・視覚対応、デフォルト**）/ `LFM`
（軽量・汎用）/ `DirtyMuse`（エロティカ特化）/ `Off`（無効）で選択します。Qwen3.5 は
mmproj 視覚エンコーダ付きで起動するため、**確定したキー画像を実際に見て**動画プロンプトを作成します。

MiniMax H3 の高速化（Spectrum / **Turbo LoRA** / **ClipProj** の A/B ワークフロー
`h3_workflow_fast.json` / `h3_workflow_turbo.json` / `h3_workflow_clipproj.json` / `h3_workflow_super.json` 含む計 13 個のバリアント
（短尺音声付き `*_short_audio`・スーパー `*_super` 系を含む）の一覧・調査結果・導入方法は **`docs/MiniMax-H3-Tuning.md`** に、現状把握は以下にまとめています。

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
| **Code - OpenClaude** | OpenClaude 向けの安定設定 |
| **Agent Research** | llama-agent + 反復 Web 調査ハーネス |
| **Deep Research Light / Standard / Heavy** | Odysseus 低負荷 / 標準 / 重め |
| **Chat** | Open WebUI（Web 検索・会話コンパクション） |

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

## ディープリサーチ（Llama Agent / Deep Research）

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
└── tools/                     # 調査ハーネス・ランタイムヘルパー・検証スクリプト
```

## パラメータカタログとプリセット

`config/params-schema.json` に、ランタイムエンジン・GPU/CPU配分・KVキャッシュ種・MoEエキスパート配置
（ホットエキスパート＝`--moe-expert-placement frequency`）・投機的デコード（MTP/Eagle3/将来のDSpark）など
**42項目の全パラメータ**を機械可読で定義しています。GUI の設定パネルはこのスキーマから自動生成します。

`config/memory-presets.json` には **省メモリ／速度プリセット**（very-light / light / balanced / full /
moe-cpu-first / spec-mtp / spec-eagle3 / spec-off）を定義しています（現時点ではランチャーが既定値として利用。
GUI 設定パネルからの 1 クリック適用は将来の Web GUI で実装予定）。

次に実装する Web GUI の設計・引き継ぎは **`docs/PARAMETER-CATALOG.md`** を参照してください。


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
