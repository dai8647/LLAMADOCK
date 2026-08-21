# LlamaDock Web GUI ライト統合タスク（別コーダー向け）

リポジトリ: C:\Users\dai86\Downloads\llama-tq3 （main 最新から作業・直コミット可）

## 背景
Web GUI (web-ui/) は機能済み（server.js 構文 OK、engine resolution 実装済み）だが、
ランチャーからの導線が一切ないため `npm start` 手動でしか起動できない。
「試せる状態」にして数日運用 → 継続/削除を判断するためのライト統合。

## 作業内容
1. ルートに webgui.bat を新規作成（UTF-8 / BOM なし / CRLF）:
   - @echo off / chcp 65001 >nul / title LlamaDock Web GUI
   - node "%~dp0web-ui\server.js" を起動
   - 起動後 start http://127.0.0.1:3000 を開く（node 起動成功確認後に開くこと）
   - node 失敗時はエラー表示して pause
2. select-model.ps1 のフロントドアメニュー（"Launch target:" を表示している
   $ClientMode -eq "Prompt" 分岐、約1900行付近）に第3選択肢を追加:
   [3] Web GUI - ブラウザで起動/停止/計測
   選択時は webgui.bat を Start-Process で新コンソール起動し、select-model.ps1 は exit 0。
   ※ 既存の ComfyUI 選択肢([2])と同じ early-exit パターンに倣うこと
3. tools/test.ps1 に最小チェックを追加:
   - webgui.bat が存在し "web-ui\\server.js" を参照すること
   - フロントドアに "Web GUI" 文言があること
   既存の Formatter check 規約（波括弧は行末・catch/finally は改行スタイル）を厳守。
   日本語追記時は BOM なし UTF-8 破壊に注意（既存行の変更は避け、追加行は英語推奨）。

## 検証（必須）
- powershell -NoProfile -ExecutionPolicy Bypass -File tools\test.ps1 が全項目合格
- node --check web-ui/server.js 合格
- webgui.bat 実際に起動して http://127.0.0.1:3000 が応答すること（確認後 Ctrl+C で停止）
- git commit & push（メッセージ例: feat: add webgui.bat entry point and front-door menu item）

## やってはいけない
- web-ui/ 配下の既存ファイルのロジック変更
- params-schema.json / HANDOFF.md への触手（別タスクで管理中）
