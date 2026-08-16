# LlamaDock サンドボックス・ハンドオフ（2026-08-16・更新版）

この文書は「GitHub 上の最新状態（`HANDOFF.md`）+ この作業サンドボックスで追加した未コミット作業」の
両方を引き継ぐための補足資料です。**Windows 機の動画生成スタック（ComfyUI / MiniMax-H3 / Z-Image / 企画 LLM）は
GitHub ルートの `HANDOFF.md` を参照**してください。ここでは **GitHub にまだ載っていない作業**を扱います。

---

## 1. 現在の状態（2026-08-16・更新）

- **ベース**: `origin/main` = `86c9513`（ユーザーがプッシュした最新。`HANDOFF.md` を含む 21 コミット）に同期済み
- **web-ui 関連の作業一式を origin/main ベースに移植・再適用済み**（下記 §2）。GitHub 側にはまだ無いので、
  **Changes パネルからコミット＆プッシュする**ことでリポジトリに載ります
- `web-ui/`・`tools/mcp-smoke.mjs` は未追跡のまま（コミット対象）

---

## 2. 未コミット作業（GitHub に未反映）— コミット対象一覧

| 対象 | 内容 | 状態 |
|---|---|---|
| `web-ui/`（新規・未追跡） | 依存ゼロの 3 カラム Web GUI（llama-server 起動/停止/計測/クライアント接続） | 動作検証済み・コミット待ち |
| `tools/mcp-smoke.mjs`（新規・未追跡） | MCP サーバーのスモークテスト（起動→initialize→4 ツール→実検索） | 全項目 PASS・コミット待ち |
| `mcp-server.js` | **Serper 検索（`SERPER_API_KEY`）+ 結果キャッシュ**を origin/main 版（`tools/safe-fetch.mjs` 込み）に移植済み | ✅ 安全にコミット可 |
| `package.json` | `start:web` / `start`（`node web-ui/server.js`）を追加 | コミット待ち |
| `.gitignore` | `config/models-config.json` / `config/run-results.json` を追加 | コミット待ち |
| `model-notes.json` | MiniMax H3 エントリ（ComfyUI 専用モデル・警告付き）を追加 | コミット待ち |
| `select-model.ps1` | `LLAMADOCK_COMFYUI_ROOT` / `LLAMADOCK_COMFYUI_PORT` 対応（CLI と Web GUI で起動・監視ポートを共有） | コミット待ち |
| `tools/test.ps1` | web-ui 一式 + `mcp-smoke.mjs` を Node 構文チェックに追加 | コミット待ち |
| `README.md` | 「Web GUI」セクション + ディレクトリ構成更新 | コミット待ち |
| `docs/PARAMETER-CATALOG.md` | §7 実装状況（Phase 1–4・API・残作業）を追記 | コミット待ち |
| `MCP-ENDPOINTS.txt` | Serper / deep_research の環境変数ドキュメントを追記 | コミット待ち |
| `HANDOFF.md` | §7 Web GUI・Serper、§8 次にやること（web-ui コミットを最優先）を追記 | コミット待ち |
| `docs/SANDBOX-HANDOFF.md` | 本ファイル（この引き継ぎ資料） | コミット待ち |

> **前回（旧ベース）の注意は解消済み**: `mcp-server.js` は「古い SSRF ガード入りの旧コードに Serper を足した
> 分岐」でしたが、**origin/main の `tools/safe-fetch.mjs` 版をベースに移植し直した**ため、そのまま push して問題ありません。

---

## 3. web-ui の内容と API

`node web-ui/server.js` で起動（デフォルト **:3000**）。Zero-dependency（Node 標準ライブラリのみ）。

### ファイル構成
| ファイル | 役割 |
|---|---|
| `server.js` | HTTP API サーバー（`/api/*`）＋静的ファイル配信 |
| `arg-builder.js` | スキーマ駆動の llama-server 引数生成（解決順: 上書き → モデル別記憶 → `_profiles` → 既定） |
| `launch-manager.js` | 起動/停止/計測の状態機械（spawn・ready 待ち・health ポーリング・ログリング） |
| `results-store.js` | 計測結果を `config/run-results.json` にモデル別・設定指紋別で蓄積、実測成功 minRuns（既定 3）以上で「推奨（実測）」認定 |
| `client-manager.js` | クライアント起動（Cline/OpenCode/OpenClaude/WebUI/DeepResearch/LlamaAgent/ComfyUI）。ComfyUI は standalone（llama-server 不要） |
| `mock-llama-server.mjs` | 非 Windows 用のシミュレーション llama-server（起動→計測→停止ループの検証用） |
| `app.js` / `index.html` / `style.css` | フロントエンド（3 カラム・ダークテーマ・プリセット適用・計測ボタン・クライアント稼働ドット） |

### API 一覧
- `GET /api/bootstrap` — スキーマ（6 グループ・42 パラメータ）/ プリセット（8）/ モデルノートを配信
- `GET/POST /api/params` — モデル別記憶（`config/models-config.json`、`per_model` のみ許可）
- `GET /api/health` / `GET /api/status` — 死活・起動状態（`clients[*].standalone` 含む）
- `POST /api/launch` / `stop` / `benchmark` — 起動 / 停止 / 計測実行
- `GET /api/results` — 計測結果（`config/run-results.json`）
- `POST /api/connect` — クライアント起動（Windows 以外では `simulated: true` で契約を返す）
- `GET /api/clients/health` — WebUI :8000 / DeepResearch :7000 / ComfyUI :8188 をプローブ

### サンドボックスで実測済み（検証済み事項）
- MCP スモーク: 起動 → initialize → 4 ツール（`search_web` / `search_and_fetch` / `fetch_url` / `deep_research`）→ **実検索成功**
- web-ui フルループ: bootstrap → 起動（モック llama-server を実 spawn）→ **3 回計測（実測 22.3 tok/s）** → 結果蓄積 → 停止 → 停止後の接続は `server_not_running` で正しく拒否
- ComfyUI は llama-server 未起動でも standalone 接続可（`:8188`、`LLAMADOCK_COMFYUI_PORT` 反映）

---

## 4. Freebuff（プレビュー / CI）の状態

### プレビュー設定
- install: `npm install`
- preview: `node web-ui/server.js`（ポート **3000**）
- build: `node --check mcp-server.js && node --check web-ui/server.js`

### 「CI (cross): Some jobs were not successful」について
- **GitHub 側に CI は一切ない**（Actions ワークフロー 0 / check-run 0）。表示は Freebuff 側の CI パネルのもの
- 失敗の最有力候補: ① `web-ui/` 未コミット（プレビュー起動が ENOENT）② package.json に `test` スクリプトが無い
- 対策: `web-ui/` 一式のコミット＆プッシュ ＋ 任意で `test` スクリプト追加（例: `node --check mcp-server.js`）

---

## 5. 次にやること（優先度順）

1. **コミット＆プッシュ**（§2 の一覧。web-ui 一式 + 各追記。Freebuff の Changes パネルから）
2. **Windows 実機での web-ui 検証** — `LLAMADOCK_ENGINE_BIN` 配線（Phase 1 コア接続）、GGUF 実パス解決、
   `/api/launch` で実 llama-server 起動、`/api/connect` の Windows 実起動（現状 `simulated`）
3. **Windows 機のスタック検証**（`HANDOFF.md` §8 と共通）— 全体ベンチのやり直し / fast プロファイル検証 / 32B vs 4B 比較
4. **GitHub クラウド移行準備** — 絶対パスの抽象化、Windows 固有コマンドの分離、CI での test.ps1 / test-plan-vision.py 実行

---

## 6. 参考リンク
- `HANDOFF.md`（GitHub ルート）— Windows 機の動画生成スタック全体（モデル・ポート・テスト・注意点・次にやること）
- `docs/PARAMETER-CATALOG.md` — 42 パラメータのスキーマと web-ui 実装状況（§7）
- `docs/LlamaDock-Runbook.md` / `README.md` — 起動手順・セキュリティ方針・Web GUI セクション
