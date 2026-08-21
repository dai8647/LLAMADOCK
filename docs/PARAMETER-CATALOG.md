# LlamaDock Parameter Catalogue & Handoff

このドキュメントは、LlamaDock の **Web GUI（3カラム・ダークテーマ）** 企画を実装する次の開発者への引き継ぎ資料です。
既に確定しているのは以下の2点で、このリポジトリ内に保存済みです。

- `config/params-schema.json` … 全パラメータの機械可読カタログ（42項目・6グループ）
- `config/memory-presets.json` … 省メモリ／速度プリセット

## 1. 背景と企画方針

- 目的: `select-model.ps1`（現行CLIウィザード）のロジックを捨てず、**ブラウザのコントロールパネル**から
  「ありとあらゆるパラメータを簡単にいじり、コーダー／ウェブチャット／ComfyUI などへ接続」できるようにする。
- 参考デザイン: `kiwioldman/llama-cpp-launcher` の3カラム（モデル一覧 | パラメータ | 監視）＋ **ダークテーマ**。
- 対象エンジン: `dai8647/llama-cpp-turboquant-experts-laguna`
  （`C:\Users\dai86\llama-cpp-turboquant` にソース、LLaMA・MoE配置・DeepSeek V4・Laguna・MTP/Eagle3 統合fork）。

### 方針（重要）
- **推奨は「断言」ではなく「計測で裏付けられた仮説」**。前回の検討で決定。
  - 「ベスト」表示は、そのモデルで実測成功した設定（`run-results.json`）または検証後のみ。
  - 未知モデルは「強く推奨」せず、安全な控えめプリセットか詳細ウィザードへ誘導する。
- **スキーマ駆動**: パラメータは `params-schema.json` の1行。フロントはスキーマからUIを自動生成し、
  コアは `flags` を llama-server 引数へ変換する。**将来の新フラグ（例 `--spec-type draft-dspark`）は1行追加で対応可能**。

## 2. パラメータカタログ（params-schema.json）

グループ構成と件数:

| グループ | 内容 | 件数 |
|---|---|---|
| `engine` | ランタイムエンジン・ワークフロープリセット・リサーチ深度 | 3 |
| `load` | コンテキスト・プロンプトキャッシュRAM・オフロード・KVキャッシュ種・FlashAttention・スレッド | 9 |
| `moe` | エキスパート配置（all-gpu/frequency/cpu-moe/map）・GPU比率・slot数・CPU MoE・活性expert数 | 7 |
| `spec` | 投機的デコード（--spec-type と draft系フラグ一式） | 13 |
| `inference` | reasoning・override-kv・chat-template-kwargs・tools・MCP・frequency-penalty | 6 |
| `sampling` | temperature・seed・top-p・top-k（サーバー既定値） | 4 |

### 各パラメータの構造
```jsonc
{
  "id": "gpu_layers",              // model-config / preset のoverridesに使うキー
  "label": "GPU layers (-ngl)",
  "type": "int",                    // select | int | num | text | bool
  "allowed": [ ... ],               // type=select のみ
  "allow_custom": true,             // 選択肢以外の数値を許すか
  "default": "auto",
  "flags": ["-ngl", "--gpu-layers", "--n-gpu-layers"],
  "flag_value": null,               // 特殊テンプレ（例 override-kv, env変数）
  "per_model": true,                // モデル別に記憶するか
  "advanced": true,                 // Advanced折り畳みに隠すか
  "help": "説明文（UIに表示）"
}
```

### 注目ポイント（このfork特有）
- **ホットエキスパート = `--moe-expert-placement frequency` と `--moe-gpu-expert-ratio`**。
  頻繁に選ばれるエキスパートをGPUに「ホット」で置き、残りをCPUへ。省メモリに直結。
- **DSpark** = DeepSeek の投機的デコード方式（並列＋逐次ハイブリッド、動的候補長）。
  現forkの `--spec-type` は `{simple, eagle3, mtp}` のみで **DSPARK未実装**。
  スキーマには `draft-dspark` を「future」として既に列挙済み。forkに追加したら `allowed` を更新する。

## 3. 省メモリプリセット（memory-presets.json）

`presets[]` の各要素が `overrides`（params-schema の id → 値）を持ち、ベース設定の上に適用されます。

- `very-light` … 非対称KV・frequency 20%・短con他text・キャッシュRAM小
- `light` … 非対称KV・frequency 50%・標準context
- `balanced` … q8_0/q8_0・all-gpu・auto offload（既定）
- `full` … f16 KV・all-gpu・大context
- `moe-cpu-first` … MoE全部CPU＋slot方式（巨大MoE向け）
- `spec-mtp` / `spec-eagle3` / `spec-off` … 投機的デコード切替

GUIは上部バーでプリセットを1クリック適用できるようにする。

## 4. モデル別パラメータ記憶（次の実装で導入）

`config/models-config.json`（新規・ローカル生成物）で、モデルごとの上書きを保存します。`model-notes.json`（パターン→推奨プリセット・警告）をベースに、ファミリー既定＋個別上書き。

```jsonc
{
  "_profiles": [ { "match": ["qwen", "35b"], "gpu_layers": 20, ... } ],  // 家族既定
  "models": {
    "Qwen3.5-9B-Q5_K_M.gguf": { "gpu_layers": 97, "ctx": 16128, "reasoning_mode": "off" }
  }
}
```

`params-schema.json` のうち `per_model: true` の項目だけを `models.<name>` に保存する。
ルール: モデル名の完全一致 → `_profiles` のパターンマッチ → スキーマ既定値 → メモリプリセット、の順で解決。

## 5. 実装引き継ぎ（次の開発者向け手順）

### Phase 1 — コアのリファクタ（最大リスク・優先）
`select-model.ps1`（3291行）から中核ロジックを再利用可能モジュールへ抽出:

- モデル発見 / `Get-HardwareEstimate` / エンジン解決（`Resolve-Engine`）
- **引数生成**: パラメータセット → llama-server 引数配列（`params-schema.json` の `flags` を参照）
- サーバー起動・ready待ち（`Wait-ServerReady`）・停止
- クライアント起動（`Open-WorkspaceClient`: Cline/OpenCode/WebUI/ComfyUI/LlamaAgent）
- `tools/test.ps1`（構文・dry run・秘密スキャン・全プリセット）を常に通すこと。

### Phase 2 — Web API層
既存 Node 資産（`llamadock-proxy.mjs` のHTTP）に REST を相乗り:
- `GET /api/bootstrap`（モデル一覧＋ハードウェア＋サーバー状態）
- `GET /api/params`（スキーマ＋現在値＋モデル別記憶）
- `POST /api/params`（モデル別記憶の保存）
- `POST /api/launch`（設定→コアで引数生成→サーバー起動）
- `GET /api/status`（health・ログ末尾・RAM/VRAM/tok/s）／ `POST /api/stop`
- `POST /api/connect`（クライアント起動）／ `POST /api/preset`

すべて `127.0.0.1` バインド。APIキーは保存しない（既存方針踏襲）。

### Phase 3 — フロント（3カラム・ダーク・ビルド不要）
単一HTML/CSS/JS（依存ゼロ）。`params-schema.json` を読み、グループごとにフォーム自動生成。
- 左: モデル一覧（サイズ・エンジン・「収まるか」信号灯）
- 中央: パラメータパネル（グループ折り畳み、`Auto/手動`、信号灯、プリセット適用）
- 右: ライブ監視（ログ・RAM/VRAM・tok/s）
- 上部バー: 起動/停止・接続先切替（Cline/OpenCode/…/ComfyUI）

### 計測収束（Phase 4）「まだベストを取れてない」問題への回答
`run-results.json` に **tok/s・VRAM実測・成功/失敗** をモデル別に蓄積し、
「実測成功回数がN回以上／最速」の設定だけを初めて「このモデルの推奨（実測）」として信号灯で示す。

## 6. セキュリティ（公開時ルール）

- APIキー・Bearer token・個人トークンをコミットしない（既存方針）。
- `models-config.json`・`run-results.json`・`logs/`・`mcp-data/` は `.gitignore` 対象。
- `params-schema.json`・`memory-presets.json` はキーを含まない（スキーマ/設定のみ）。

---

## 7. 実装状況（2026-08-16）

- **Phase 2（一部）・Phase 3（UI）を実装**: `web-ui/` に依存ゼロの3カラム・ダークテーマGUIを追加。
  `npm start`（`node web-ui/server.js`）で起動。
- **API（Phase 2）**: `GET /api/bootstrap`・`GET/POST /api/params`（モデル別記憶を
  `config/models-config.json` へ保存、`per_model` のみ許可）・`GET /api/health`・`GET /api/status` を実装。
- **Phase 1/2 コアの Node 実装（全プラットフォームで検証可能）**:
  - `web-ui/arg-builder.js` — スキーマ駆動の引数生成（解決順: 上書き → モデル別記憶 → `_profiles` → 既定）。
    引数プレビュー（UI）と実起動（API）が同じロジックを使う。
  - `web-ui/launch-manager.js` — 起動/停止/計測の状態機械（spawn・ready待ち・healthポーリング・ログリング）。
    Windows では `LLAMADOCK_ENGINE_BIN` のエンジンを実行（Phase 1 コア配線待ち）。
- **Phase 4（計測収束）を実装**:
  - `web-ui/results-store.js` — `config/run-results.json` へモデル別・設定指紋別に実測を蓄積し、
    **実測成功 minRuns（既定3）回以上**の設定だけを「推奨（実測）」に認定。
  - `web-ui/mock-llama-server.mjs` — 非Windows用のシミュレーション llama-server。
    起動 → ready待ち → 3回計測 → 停止のループを実プロセスで検証可能（`simulated: true`）。
  - `POST /api/launch` / `stop` / `benchmark` / `GET /api/results` を実装し、UI の起動/停止ボタンと
    計測実行ボタンを配線。3秒間隔の状態ポーリングで信号灯・メトリクス・ログを更新。
- **`POST /api/connect`（クライアント起動）を実装**: `web-ui/client-manager.js`。
  `select-model.ps1` の `Open-*Client` と同じ起動経路をクライアントID（Cline / OpenCode /
  WebUI / LlamaAgent / ComfyUI）ごとに定義。Windows では detached spawn、それ以外では
  リクエストを検証した上で Windows が実行する正確なコマンドを `simulated: true` で返す（契約を全プラットフォームで検証可能）。
  未起動時は `server_not_running` で拒否。接続状態は `/api/status` の `clients` と UI のチップで確認できる。
- **ComfyUI を standalone 扱いに修正**: llama-server 未起動でも接続可能（`select-model.ps1` の
  「ComfyUI runs its own server on :8188 and does not depend on the llama-server」と同じ契約）。
  `CLIENTS` の `standalone: true` で判定し、`/api/status` の `clients[*].standalone` と UI に反映。
- **MiniMax H3 対応（ComfyUI 専用モデル）**: `model-notes.json` に `MiniMax.?H3|minimax_h3|fl2va|ref2va` の
  エントリを追加（llama-server 非対応・ComfyUI 0.30.0+ / ComfyUI-GGUF / ComfyUI-H3-Multishot v1.5.2+ が前提、
  エンコーダ GGUF + VAE 必須、K 量子化不可）。UI のエンジン推定は `ComfyUI (DiT)` と表示し、
  llama.cpp エンジンへの誤推定を防止。
- **クライアント稼働モニタ（`GET /api/clients/health`）を実装**: 独自 HTTP サーバーを持つクライアント
  （Open WebUI :8000 / ComfyUI :8188）をプローブし、UI に稼働ドット（緑/赤）と
  「開く ↗」を表示。ポートは `LLAMADOCK_<ID>_PORT` で上書き可能で、ComfyUI の起動 `--port` と監視が
  同じ値を使う。CLI クライアントは `no_health_check`。
- **残（Windows 機で実施・検証が必要）**: Phase 1 の `select-model.ps1` モジュール抽出と
  `/api/launch` → コア接続（`LLAMADOCK_ENGINE_BIN` 配線、GGUF 実パス解決）、実モデルでの計測収束、
  `/api/connect` の Windows 実起動（現状は `simulated` のまま）。
