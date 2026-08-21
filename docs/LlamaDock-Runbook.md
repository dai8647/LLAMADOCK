# LlamaDock運用ランブック

## 現在の入口

デスクトップの `LlamaDock.lnk` は `llamadock.bat` から `select-model.ps1` を直接起動する。通常の動線は「モデルを選ぶ → 用途を選ぶ → 起動」の2段階だけ。用途は Chat + Web、Coding、Deep Research、Advanced の4つで、通常3モードは推奨設定を自動適用し、追加質問なしで起動する。細かな設定変更と診断表示は Advanced にまとめる。旧プリセットはコマンドライン互換用に残す。

すべて localhost バインドで、Docker/WSLは既定経路に使わない。ComputerのデータはOneDrive外の `C:\Users\dai86\AppData\Local\LlamaDock\Computer\data` に置く。

LlamaDockから起動した場合、通常のクライアント接続先は `http://127.0.0.1:8090/v1`（回復ゲートウェイ）で、実サーバーは8090から8080へ転送される。クライアント切断時に8080の単一スロットが解放されない場合だけ、監督プロセスがllama-serverを再起動する。8080は診断用とし、通常のCline/OpenCode/Computerは8090を使う。

## 推奨プロファイル

通常3モードの既定値は `select-model.ps1` がモデル形式とサイズに合わせて決める。`config\profiles.json` は方針を確認するためのプロファイル資料として残す。

- `chat-fast`: 16K、K/V q8（TQ3モデルのVはtq3_0）、KV-aware Auto、Computer
- `coding-balanced`: 32K、K/V q8、AutoFit、OpenCode
- `research-standard`: 32K、K/V q8、AutoFit、読み取り中心のMCP
- 20GB以上のモデル: K q8 / V q4、AutoFit。用途に応じてChatは16K、Coding/Researchは32K

## KVキャッシュの扱い

K/Vを量子化する方針は適切。ただしKとVを常に同じ型に固定しない。通常はK q8 + V q8、VRAM不足時はK q8 + V q4系、品質検証時はV f16を比較する。V量子化はFlash Attentionが必須のため、起動時に互換性チェックを行う。

Prompt cacheのRAM上限はランタイムの起動引数に明示する。既定は検出RAMでスケールする（96GB機: 16,384 MiB / 64K以上は8,192 MiB、48GB機: 12,288 MiB / 64K以上は8,192 MiB、32GB級: 従来の 8,192 / 4,096 / 2,048 MiB）。`LLAMADOCK_CACHE_RAM_MIB` か `-CacheRamMiB` でいつでも上書きできる。長文脈でキャッシュを増やすより、まずVRAM、実効コンテキスト、TTFT、生成速度を測る。

## GPUオフロード

`Auto` は固定の99層ではなく、GGUFヘッダー、コンテキスト、K/V型、検出VRAMからランチャーが数値の丸ごと層数を計算する。`All` は比較試験用で、常用既定にしない。

## 回答停止とUTF-8の再発防止

短い日本語回答が空になる主因は、Qwen/TQ3系でthinkingが有効なままになり、短い`max_tokens`を思考出力だけで使い切ることだった。TurboTanは既定で`chat_template_kwargs={"enable_thinking":false}`と`--reasoning off`を両方渡す。Computerのグローバルチャット設定もtemperature 0、max_tokens 512、seed 42、thinking無効にそろえる。GGUFのEOS/chat-template警告は無視せず、短文・停止文字列・SSE終了の実測を合格条件にする。

PowerShell 5.1のJSON POSTは文字列Bodyを使わず、`tools\llamadock-utf8.ps1`でUTF-8バイト列と`application/json; charset=utf-8`を明示する。Cline/OpenCodeは`tools\llamadock-client-shell.ps1`を共通の起動境界にし、コンソール、Python、Clineのデータディレクトリ、MCP設定パスをそろえる。起動中のモデルを検査するときは次を実行する。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test.ps1 -RunUtf8Smoke
```

この検査は日本語、混在CJK、絵文字、JSON、ASCIIを非ストリームとSSEで確認し、Windows PowerShell 5.1の実送信経路も別に確認する。クライアント切断後に再度`/slots`と短文生成が通ることも確認する。

## 変更後の確認

1. `tools\llamadock-doctor.ps1` を実行する。
2. 軽量Gemmaで `/health` と `/v1/models`、短いChat Completionsを確認する。
3. その後に目的モデルを起動し、起動秒数、TTFT、prompt/TG速度、VRAM/RAM、KV型、cache-ramを記録する。
4. `-RunUtf8Smoke`を実行し、非ストリームとSSEの両方で置換文字や欠落がないことを確認する。
5. OOM、ドライバリセット、NaN、VRAM逼迫、品質劣化が出た設定は既定に昇格しない。

## 初回ベンチマーク結果（2026-07-18）

同じ `llamadock-bench.ps1` で、起動後の3回を記録した。値はこのPC固有の目安であり、モデルの品質比較ではない。

- Gemma 12B / Atomic HIP: 32K、K q8 / V turbo3、cache 8192 MiB、起動7.19秒、生成0.110秒（warm平均）、3/3成功
- MidnightCoder 80B / Atomic HIP: 16K、K q8 / V q4、cache 2048 MiB、起動16.31秒、生成0.434秒（warm平均）、3/3成功
- Qwen coder TQ3 / TurboTan HIP: 16K、K q8 / V tq3、cache 2048 MiB、起動13.77秒、生成0.101秒（warm平均）、3/3成功

この結果から、TQ3モデルはTurboTan、一般GGUFはAtomic HIPを初期候補にする。ただし、最終採用は実タスクのTTFT・prompt処理速度・品質・長文脈で再測定する。

## Computer初回セットアップ

`tools\computer-start.ps1` は専用venv `venv-0.9.9` を作成し、Open WebUI Computer 0.9.9をlocalhost:8000で起動する。初回はブラウザでローカル管理者とワークスペースを作成する。LlamaDock経由のLLM接続はComputer側でOpenAI互換、Base URL `http://127.0.0.1:8090/v1`、ダミーAPIキー、Chat Completionsを選ぶ（直接起動の診断時だけ8080）。

既存Open WebUI（port 3000、`mcp-data\open-webui`）はロールバック用に残す。新UIを標準入口にした後も、問題があれば旧 `tools\open-webui-start.ps1` を直接実行できる。

## ClineのMCPと初期プロンプト

Clineのweb検索は、Windowsで`curl`をMCPコマンドとして渡さず、隔離データディレクトリにStreamable HTTP設定を書き込む。既定では初期プロンプトを軽くするため`web_search`だけを登録する。filesystem/memoryも必要な場合は`LLAMADOCK_CLINE_MCP_ALL=1`を設定してからLlamaDockを起動する。検索失敗時はMCPエラーをそのまま表示し、検索できていないのに検索済みと回答しないことを合格条件にする。

Open WebUIの検索スイッチは明示的な検索要求なので、クエリ生成を無効にし、入力文をそのまま検索語としてSerper結果を取得する。モデル設定には`stream: true`を固定保存しない（内部の検索クエリ生成がSSEになり、JSONを期待するOpen WebUI検索処理と衝突するため）。通常チャットのストリーミングはクライアント指定で維持する。

## ロールバック

作業ブランチは `codex/llamadock-computer-20260718`。Phase 0バックアップは `C:\Users\dai86\AppData\Local\LlamaDock\backups\phase0-20260718-061521`。UIだけ戻す場合は `select-model.ps1` のComputer呼出しを旧 `open-webui-start.ps1` に戻し、モデル設定は変更しない。
