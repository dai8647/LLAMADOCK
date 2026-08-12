# LlamaDock 外部エージェント・ハーネス v1

## 目的

OpenCode 本体を fork せず、LlamaDock の外側からローカル LLM の切断・停止・再試行ループを監視し、60 分以上のコーディング作業を安全に再開できるようにする。

## 境界

- OpenCode / Cline / OpenClaude 本体は変更しない。
- 初版の実行対象は OpenCode。既存の通常起動は残す。
- 副作用のある tool call を自動再実行しない。
- モデル能力、壊れた GGUF、誤った tokenizer は検出・停止・モデル切替の対象であり、自動修復はしない。
- dry-run / mock / 静的試験で機構を検証済み。v1 では 30B 級モデルや 60 分超の実モデル実行は未実施。

## 構成

### 1. OpenCode ランナー

`tools/llamadock-opencode-harness.ps1` を追加する。

- 必須引数: Workspace、ModelName。実運用では Prompt も必須（client-shell が省略時は対話的に入力させる）。
- 既定値: MaxMinutes=90、MaxResumes=3、StallSeconds=300。
- 初回は `opencode run --format json`、再開は取得した session ID を使う。
- JSON イベントから session ID、最終出力時刻、終了状態を記録する。
- transport/backend 障害だけを再開対象とする。正常終了、権限待ち、明確なモデル出力エラーは自動再開しない。
- 再開前に 8090 と 8080 の準備完了を確認し、git 状態を記録する。自動 commit/reset はしない。
- 同じ出力または同じ tool call 指紋が 3 回続いたら loop として停止する。
- 状態は `mcp-data/agent-harness/<run-id>.json`、イベントは同名 `.jsonl` に UTF-8 で保存する。prompt、API key、tool 結果本文は保存しない。
- `-DryRun` と `-SelfTest` を持たせ、OpenCode やモデルを起動せず検証できるようにする。
- 起動例: LlamaDockのプリセットで「Code - OpenCode + Harness」を選ぶ。手動起動する場合は `tools/llamadock-client-shell.ps1 -Client OpenCode -Harness -ConfigPath mcp-data/opencode-local.json -ModelName qwen3_coder_japanese_heretic_TQ3_4S -Workspace (Get-Location).Path`。

### 2. Gateway の観測

既存 `tools/llamadock-proxy.mjs` を最小限拡張する。

- 既存 API と streaming を変えない。
- GET `/llamadock/status` を追加し、gateway 起動時刻、active request 数、直近の成功・失敗、restart request 状態、upstream health を返す。
- request body の生内容は保存せず、既存メタデータと SHA-256 指紋だけを記録する。
- 同一指紋が短時間に 3 回続いた場合は `possible_retry_loop` を記録するが、要求は遮断しない。

### 3. Supervisor の回復制御

既存 `tools/llamadock-server-supervisor.ps1` を拡張する。

- coding クライアント用に自動再起動を選べる既存仕様を維持する。
- 120 秒内に 5 回を超える再起動を circuit breaker で停止する。
- 再起動待ちは 2、4、8、16、30 秒上限の backoff とする。
- requested restart と unexpected exit を別イベントとして記録する。
- PID、restart count、breaker 状態を `mcp-data/server-supervisor/status.json` に UTF-8 で原子的に保存する。

### 4. 起動導線

通常の LlamaDock OpenCode 起動（既定）は変更しない。選択画面に「Code - OpenCode + Harness」を追加し、その選択時だけ `tools/llamadock-client-shell.ps1` へ `-Harness` を渡す。`-Harness` 未指定時は従来どおり通常 TUI で起動する。手動起動も引き続き可能。

## 受入条件

1. `tools/test.ps1` が成功する。
2. Node の構文確認と PowerShell の parse 確認が成功する。
3. `llamadock-opencode-harness.ps1 -SelfTest` がモデルなしで成功する。
4. gateway status と loop fingerprint を mock upstream で検証できる。
5. 既存の Cline / OpenClaude / 通常 OpenCode 起動に互換性がある。
6. 秘密情報・prompt 本文・tool 出力本文を新規ログへ保存しない。
7. 実装は上記範囲に限定し、クライアント本体やグローバル設定を変更しない。
