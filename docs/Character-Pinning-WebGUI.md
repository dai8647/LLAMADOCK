# キャラ固定機能 設計書 (実装済み) — Web GUI コンフィ側 × h3-chat

2026-09-14 実装完了版。初版 (2026-09-13 調査報告) からの最大の設計変更は
**「PLAN_SYSTEM へのキャラ注記追記を撤回」**したこと。PLAN_SYSTEM は毎ターン全再送
(約 800 トークン) で、追記方式だとピン中の全ターンに +80〜150 トークンが恒久乗る。
本設計では **システムプロンプトは 1 バイトも増やさず**、3 層で同一人物性を担保する。

## 1. アーキテクチャ: 3 層構造

```text
┌─ 認知層 (企画 LLM) ── PLAN_SYSTEM 無変更。ピン中のターンだけ、そのターンの
│    ユーザー文の頭に 1 行前置き (char_identity_prefix / 約 60〜80 トークン)。
│    PLAN_HISTORY の 6 ターン窓から自然に流れ出るので恒久コストはゼロ。
├─ 保証層 (画像生成) ─ h3-chat がワークフロー JSON を機械改変: negative 追記 /
│    LoRA チェーン挿入 / seed 固定。企画 LLM がサボっても描写はモデルに届く。
└─ 動画層 (I2V/R2V) ── 追加実装ゼロ。同一人物性はキー画像から派生するため、
     画像が固定されれば動画は自動的に付いてくる。R2V はカードの refImages を
     既定参照として使い、[FINAL_PROMPT] 側は同じ被写体表現を繰り返すだけ。
```

### 1.1 認知層 (`tools/h3-chat.py` `char_identity_prefix`)

`PLAN_SYSTEM` は触らない。`/api/plan` でピン中 (`char_id` 付き) のときだけ、
ユーザー文の頭に次の 1 行を前置きする:

```text
[キャラ固定: あかり] 被写体の同一人物性（顔・髪・体型・肌質）は次の英語タグ列で固定する。
[IMG_PROMPT] ではスマホ写真の導入句の直後にこの被写体描写をそのまま置き、ユーザーの指示と
矛盾しない限り髪・体型・顔は変更しない。人数・ポーズ・行為・服装・構図・照明・質感は
シーンに合わせて書いてよい: <summary>
```

前置きは履歴窓から流れるため、ピンを外せばコンテキスト コストはゼロに戻る。

### 1.2 保証層 (`_append_negative` / `_apply_char_loras` / seed)

- **negative**: KSampler の `negative` 入力リンクを辿って負プロンプト ノードを特定
  (ノード ID はワークフローごとに違うのでハードコード禁止) し、カードの `negative`
  タグ列を機械追記。kimg / krea2 / qimg 対応。
- **LoRA**: カードの `lora.<engine>` 配列を KSampler の `model` 入力に
  `LoraLoaderModelOnly` チェーンとして挿入 (既存 qimg 多段 LoRA と同型の改変)。
- **seed**: カードの `seed` が整数なら seed ノードに固定値を渡す (構図再現用)。
- **sdcpp**: `tools/sd.cpp/test_run_4b.ps1` に `SDCPP_NEG` (負プロンプト) と
  `SDCPP_SEED` (`-s 42` を上書き) を追加。ハードコード廃止。

### 1.3 動画層 (`/api/generate`)

- カードに `refImages` がある場合、ユーザーが R2V 参照画像を 1 枚も選んでいないとき
  先頭から既定参照として使う (Tier 2 既定参照)。
- T2V 直行 (キー画像なし) のときだけ `char_summary_text(card)` を被写体節に前置。
  I2V/R2V ではキー画像が既に固定済みなのでテキスト側の追記はしない。

## 2. データ & API

### 2.1 ディレクトリ (`config/characters/`)

```text
config/characters/
  index.json              # スキーマ+雛形。コミットされる (h3-chat は読まない)
  <char-id>.json          # 1 キャラ 1 ファイル。ローカル資産 → .gitignore
  ref/<char-id>/*.png     # 基準画像 (Tier 2)。ローカル資産 → .gitignore
```

`.gitignore`: `config/characters/*.json` を除外しつつ `!config/characters/index.json`
だけ追跡。カードと参照画像はローカル運用資産で、リポジトリには入らない。

### 2.2 カードスキーマ (`config/characters/index.json` が正)

| フィールド | 内容 |
|---|---|
| `id` | `^[a-z0-9][a-z0-9_-]{0,63}$`。ファイル名 `<id>.json` と一致させる |
| `name` | 表示名 (チャット UI のセレクタに出る) |
| `summary` | **英語タグ列 1 文**。同一人物性属性 (顔・髪・体型・肌質) だけ。服装・ポーズ・背景はシーン側に任せる |
| `negative` | 英語タグ列。この人物に来てほしくない属性。KSampler negative に機械追記 |
| `lora` | エンジン別: `{ kimg: [{name, strength}], krea2: [...], qimg: [...] }` (sdcpp 未対応) |
| `seed` | 任意・整数 or null。null なら従来どおりランダム |
| `refImages` | 基準画像のフルパス配列 (任意・Tier 2)。R2V 未選択時の既定参照 |
| `notes` | 自由メモ (生成に使われない) |

### 2.3 API

**web-ui (:3000, コンフィ側・編集者)** — `web-ui/server.js`

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/characters` | カード一覧 (壊れたファイルはスキップ) |
| POST | `/api/characters` | 保存 (upsert)。`normalizeCard` で検証・クランプ |
| DELETE | `/api/characters?id=<id>` | カード削除 |
| POST | `/api/characters/<id>/refimg` | 基準画像アップロード |
| GET | `/api/characters/<id>/refimg` / `.../refimg/<file>` | 一覧 / 配信 |
| DELETE | `/api/characters/<id>/refimg/<file>` | 基準画像削除 |

**h3-chat (:8088, 消費者)** — ディスク直読み (キャッシュなし・毎回再読なので
Web GUI での編集が即反映)。`GET /api/characters` (セレクタ用一覧) と
`GET /api/refimg?path=...` (カードの既定参照を UI に表示) もある。

## 3. UI

- **h3-chat**: 企画モデルセレクタと同じ advgroup 書式で「キャラ固定: なし / …」
  (`#char-pin`)。`pinnedChar` は uiSnapshot に入りセッション復元で戻る。
  ピン中は「この設定でキャラを切りますか?」的な確認は v1 では出さず、
  ユーザーが明示的に別人物を描写したら企画側の判断に任せる (ピンを手で外す)。
- **web-ui**: モデル列と同型の「キャラライブラリ」カード。CRUD フォーム
  (summary は英語タグ列である旨を UI 上で明示) + 基準画像アップロード。

## 4. 競合ルール

- ユーザー指定の属性 (服装・ポーズ・シーン・行為) は常に優先。固定されるのは
  同一人物性の属性 (顔・髪・体型・肌質) だけ。
- ピンは「次のキー画像から」効く。選択はセッション中保持、メッセージ合間に
  切り替え・解除できる。
- v1 スコープは 1 生成につき 1 キャラ (複数キャラ同時ピンは将来課題)。

## 5. ゼロ影響保証

ピンなし (`char_id` なし) のリクエストは従来と完全に同一: 前置きなし・negative
追記なし・LoRA 挿入なし・seed 上書きなし。`tools/test-character-pinning.py` が
**PLAN_SYSTEM が 1 バイトも変更されていないこと** (キャラ語が漏れていないこと含む)、
negative ノード特定 / 追記 / LoRA チェーン / ps1 env 契約をカバー (28 テスト)。
web-ui 側は `web-ui/characters-store.test.mjs` (正規化・atomic 保存・ref パス閉じ込め、
5 テスト)。

## 6. セキュリティ

- `id` は正規表現で遮断 (パストラバーサル不可)。参照画像は
  `config/characters/ref/<id>/` 配下に閉じ込め (正規化後に接頭辞確認)、
  拡張子はホワイトリスト (.png/.jpg/.jpeg/.webp)。
- 書き込みはすべて tmp+rename の atomic write。
- JSON は `json.load` で dict 以外はスキップ。壊れたカードは起動を落とさない。

## 7. 制約と次の一歩 (誠実な評価)

- **静止画の顔同一性は summary + LoRA + seed 頼み。** Klein 9B 静止画には参照条件付けの
  仕組みが現状ない (ComfyUI custom_nodes は GGUF/ClipProj/LlamaDock/Spectrum のみ。
  IPAdapter / PuLID / InstantID 未導入、`photomaker` / `clip_vision` は空)。
  体型・髪・服装・雰囲気の再現は高いが、顔は数枚に 1 枚崩れる。
- **Tier 2 参照画像ピン留めは動画側のみ強く効く** (既存 R2V ref LoRA 経路)。
  静止画には効かない。
- **Tier 3**: PuLID-Flux / IP-Adapter FaceID (Klein 9B への対応可否が未知数、
  1 日スパイクで採否) か、キャラ LoRA 学習 (5〜20 枚、kohya 系。品質最強・
  RTX 3080 で現実的。キャラ追加のたびに学習が必要)。
- 動作確認のすすめ: 同一キャラで 3 シーン生成し一致度を確認してから運用に入る。

## 8. クイックスタート

1. `webgui.bat` → :3000 → キャラライブラリ → 新規カード
   (id=ローマ字, name=表示名, summary=英語タグ列, 必要なら negative / LoRA / seed / 基準画像)。
2. `h3chat.bat` → チャット下部の「キャラ固定」でキャラを選択。
3. 以降のキー画像から固定が効く。解除は「なし」を選ぶだけ
   (セッション復元でも pinnedChar が戻る)。
