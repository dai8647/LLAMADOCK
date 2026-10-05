# スタイル・描写精度チューニング 計画書（2026-10-04）

（R18向けローカル創作スタックの画風・解剖学・キャラ多様性の改善計画）

16GB VRAM / GPU は他 AI と共用のため **検証・比較生成は ComfyUI 単独で動く時間帯に** 実施する。
画像エンジンは本日から **2 本**（Klein 9B / Qwen-Image 2.1 UC）。krea2・sd.cpp は廃止済み。

---

## 0. 現在の構成（本日確定分）

| エンジン | モデル | LoRA チェーン | 設定 | 役割 |
|---|---|---|---|---|
| kimg | pornmasterFlux2Klein v4 Turbo Q8 (9.5GB) | flux_klein_9b_nsfw_v2@0.85 → klein_base_snapshot_v13@1.0 | 4step / cfg1 / 1024² | 主力。スマホ写真・素人感・日本人 |
| qimg | qwen-image-2.1-UC-Q4_K_M (4.6GB) | Qwen-Image-2.1-turbo-4step@1.0 → GenatomyFixer@0.3 | 4step / cfg1 / euler-simple / 1344×768 | 局所描写・検閲なし・高画質 |

- qimg は 9/21 に中途半端になっていた切替を再建したもの（旧 2512 構成は参照先が消えて壊れていた）
- ComfyUI 0.34→0.38、ComfyUI-GGUF を leejet fork に載せ替え（2.1 GGUF + sd.cpp 変換互換に必須）
- TE `qwen3vl_8b_int8_convrot` (9.35GB) は VRAM を圧迫 → ComfyUI の自動スワップに任せる（低 VRAM エラーが出たら ComfyUI 起動オプションに `--lowvram` 検討）

## 1. 初回校正（最優先・GPU 必要・所要 ~30分）

同一段階で 1 変数ずつ。**seed=42 固定・同一プロンプト**で比較する。

1. **qimg 実測**: 1 枚生成して所要時間を確認 → `ETA_DEFAULTS` の qimg 180s とラベル「約3分」を校正
2. **Turbo LoRA の効き**: strength 1.0 で描画が糊状・焼け付きなら 0.8 に下げる
3. **GenatomyFixer の 2.1 での効き**: LoRA キーは 2.1 命名（img_mlp/txt_mod 等）で 2.1 と一致を確認済み。
   alpha を 0.2 / 0.3 / 0.4 で 3 枚比較し、解剖学の破綻修正が見えるか確かめる
4. **Klein NSFW LoRA 強度**: 0.85 → 0.9 / 1.0 の比較。露骨さが上がる反面、過-strong だと顔が崩れる

## 2. Klein 強化（1 の次・GPU 必要）

- `klein_base_naturalbeauty_v2.safetensors`（317MB・本日の整理で残置した）を第 3 段に足す実験。
  美肌・色気系。strength 0.4〜0.6 で `h3_workflow_klein.json` のノード 12 の後ろに 1 ノード追加
- steps 4 → 6 / 8 の比較（Turbo 合成モデルなので cfg は 1 のまま。遅くなる分だけ質感が乗るか）

## 3. KB / プロンプト強化（GPU 不要・すぐできる）

- `config/DO-NOT-READ-local-style-notes.json`（旧 nsfw-prompt-kb.json、189 語）は機能テスト済み・正常動作
- **動画向け語彙が無い**のが次の伸びしろ: 現在の KB は `[IMG_PROMPT]`（静止画）前提。
  `cat: "motion"` カテゴリを新設し、`[FINAL_PROMPT]` 用の体の動き・リズム・継続時間の
  英語 phrase（thrusting rhythm, continuous motion, slow grind 等）を 20〜30 語追加する。
  注入先は `_nsfw_kb_system_note` の IMG_PROMPT 用文面と FinalPrompt 用で分岐が必要
- 汎用キー（足・尻・汗 等）の非対象文での誤爆は hint 追加のみで実害小 → 放置でよい

## 4. 動画側（GPU 必要）

- **10Eros Max beta2 (NVFP4・12.5GB)**: UI の「動画モデル」で切替して画質比較。現行 PinkCherry int8 21GB より軽く高画質の評判
- **R2V 複数参照（最大 9 枚）**: 露骨な体勢のシーンでは顔崩れが起きやすいので、
  キー画像 + 顔アップ + 体勢見本の 2〜3 枚を参照に渡すと同一人物性が保てる

## 5. 2.1 用 NSFW LoRA 追加候補（画風目的・UC の次段）

2.1 UC 自体が検閲なしなので、追加は「画風」の味付け。turbo の後段に 0.5〜0.8 で重ねる。

| 候補 | DL 数 | 備考 |
|---|---|---|
| f23gg/NSFW-LORA-Qwen-Image-2.1 | 4.3k | 本命。まずこれ |
| prithivMLmods/Qwen-Image-2.1-Natural-Exposure-LoRA | 5.6k | 露出・自然系 |
| chfm/NSFW-LORA-Qwen-Image-2.1 | 1.3k | 予備 |

## 6. 検証のルール

- 比較は必ず **seed 固定 + プロンプト固定 + 1 変数**。複数同時に変えない
- 実測値（所要秒）は ETA_DEFAULTS に反映してコミットまでやる
- h3-chat.py / ワークフロー JSON 変更後は h3-chat 再起動が必要（GPU 空き時に）

---

## 7. 追補（同日・第2回）: AI顔対策とバリエーション機構

方向性の結論: **LoRA を増やすのではなく「レバーを増やしてランダムに回す」**。チェーンは 3〜4 本が限界、それ以上は画風が溶ける。

### 導入済み（本日）

| LoRA | サイズ | 組み込み先 | 役割 |
|---|---|---|---|
| klein_slider_anatomy (Civitai v1.5 相当) | 19MB | kimg チェーン3段目 @0.8 | 解剖学・品質の修正（チンコの形崩れ対策の Klein 側） |
| klein_slider_bodyweight | 19MB | kimg チェーン4段目 **生成ごとに ±1.2 でランダム** | 体型バリエーションの機械的レバー。`bodyweight` をリクエストで明示すれば固定可 |
| klein_slider_detail | 19MB | 未接続（予備） | ディテール増強。I2I 向き |
| qwen-image-2.1-fix-1.0-comfy | 106MB | qfix エンジン @1.0 | 2.1 の生成問題全体の修正。20step/cfg3/sgm_uniform・cfg>1 なのでネガティブ有効 |

kimg の生成ラベルに「体型スライダー±x.x」が出る（char_applied 経由）。

### 未導入の候補（Civitai・実測してから採用）

- **Klein Bust Slider** (160👍) / **Klein Crowd Slider** — 同じスライダー方式
- **[KLEIN 9b] Mystic 2 Realism** (165👍) — "switch to realistic style" で現実寄り。**fixed 版**を使うこと（初版は ComfyUI で shape error の報告あり）
- **Klein-9b-Turn2Real** (342👍) — I2I で "reskin this into a real photo"（既存画のリスキン用・T2I ではない）
- **Qwen Image 2.1 Fix v2.0** (108👍) — v1 より強いが専用サンプラー `ComfyUI-DPMpp-2M-Sharp` (envy-ai) の導入が前提
- **PornMaster Qwen 2.1 Age Slider** (141👍・3MB) — 年齢感のスライダー。Qwen Research License（非商用注意）

### 色んなパターンを作る仕組み（LoRA以外の2層）

1. **プロンプト層（導入済み）**: PLAN_SYSTEM に①体位は正式英語名+部位の位置関係を1文（mating press 等）、②企画ごとに髪型・体型・年齢感・雰囲気の2軸を変える指示を追加。KB は 189→**485語**（romptn mania 5218 のカタログから厳選。素股=thighjob、イラマチオ、フルネルソン、まんぐり返しなど正規体位名と構図説明つき）。※KB はローカルファイルなのでこの変更は git に載らない
2. **顔バンク層（運用）**: 良い顔が出たらキャラカード `config/characters/<id>.json` の refImages に登録 → R2V でその顔を系列として固定。Web GUI で CRUD 可。見本カードは user 判断で作らず、実運用で育てる

### 校正タスク（GPU 空き時・§1 に追加）

- kimg: anatomy 0.6 / 0.8 / 1.0 比較、bodyweight -1.2 / 0 / +1.2 の体型変化を目視確認
- qimg (turbo 4step) vs qfix (20step cfg3) の局部描画比較 — 破綻率で使い分けを決める
- Qwen Fix v2.0 + DPMpp-2M-Sharp を入れるかは qfix の実測後
