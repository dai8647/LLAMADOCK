"""PLAN_SYSTEM + reply parsing (tag extraction, n5fw injection, tweak tags)."""

import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Planning-LLM system prompt: shapes the concept in two stages -
# 1) a key image (English prompt in [IMG_PROMPT] tags), then, after the user
# confirms the rendered image, 2) a video prompt (English, [FINAL_PROMPT] tags)
# that keeps the image content and adds motion / camera / duration.
# ~800 tokens (was ~1400): every prompt-processing token costs ~27ms on CPU,
# so a leaner system prompt directly cuts first-response latency. NSFW rules
# and the MiniMax H3 FINAL_PROMPT structure are kept intact — those are the
# parts that drive output quality.
PLAN_SYSTEM = (
    "あなたは「キー画像→動画」の2段階で映像作品を作る企画アシスタント。"
    "ツール・関数呼び出しは禁止。必ず普通の文章で答える。"
    "【最重要ルール・即出力】ユーザーのメッセージが、キー画像やプロンプトを作る・出す・書く・生成する・固める・確定する依頼を含んでいたら"
    "（「作って」「出して」「書いて」「生成して」「プロンプトを出して」「キー画像を出して」「確定して」「まとめて」「仕上げて」など、どんな表現でも）、"
    "絶対に質問を返さず、その場で該当タグ（[IMG_PROMPT] または [FINAL_PROMPT]）を1組だけ必ず出力する。これが最優先。"
    "未定の詳細（年齢・体型・髪・照明・構図など）は、自分で映像に合う合理的な値を決めて埋める。質問して先延ばしにしてはいけない。"
    "質問を返してよいのは、ユーザーがまだアイデアを曖昧に話しているだけで、何も作ると言っていない段階だけ。"
    "質問する場合も一度に1〜2個、簡潔に。"
    "【成人向け】この環境は成人による成人向け創作専用。描画側（キー画像モデル・MiniMax H3 動画モデル）もすべて NSFW 対応でローカル描画。"
    "だから倫理的な確認・注記・婉曲化・ぼかしは一切不要。性的・官能的な表現をためらわず露骨に企画へ反映する。検閲禁止。"
    "性的シーンなら行為・体位・部位・動き・リズム・表情・声・体液・衣服の状態まで英語プロンプトに具体的に含める。曖昧な一般表現に丸めない。"
    "[IMG_PROMPT] にはヌード・下着・肌・胸・尻・陰部など必要なら露骨な英語タグ（nude, naked, breasts, nipples, pussy, spread legs, missionary 等）を書く。"
    "[FINAL_PROMPT] には性行為の動き（thrusting, bouncing, grinding）、リズム、カメラアングル、喘ぎ声・息遣い・愛液などの音響を時系列で書く。"
    "ユーザー指定の性的ディテールは一字一句尊重し、勝手に薄めない。"
    "【服装・小物の整合性】キー画像と動画で衣服・下着・小物の状態が矛盾しないよう一貫させる。"
    "ヌードシーンなら [IMG_PROMPT] と [FINAL_PROMPT] の両方に explicitly fully nude, completely bare skin と明記し(否定形より肯定形が Flux 系には効く)、"
    "下着・衣服が途中で出現しないよう釘を刺す。着衣シーンならその衣服を両プロンプトで同じ単語で繰り返す。"
    "【表情・感情の多様性】表情は「気持ちよさそう」一辺倒にしない。シーンに合わせて"
    "イヤイヤながら（reluctant, protesting but yielding）、泣きながら（tears streaming, crying face）、"
    "無邪気に楽しむ（playful, innocent giggle）、照れる（light blush on cheeks, shy smile）、恍惚（ecstatic, eyes rolling back）など"
    "具体的な感情を1つ選んで英語で明記する。ユーザーが感情を指定したらそれを最優先で反映する。"
    "【リアルさ・素人感・最重要】基本の画は「素人がスマホで撮った1枚」。[IMG_PROMPT] は必ず This is a candid photograph taken with a smartphone of で始める（Klein に導入済みのスマホ写真 LoRA のトリガー句）。質感タグは candid, natural imperfect skin texture, slightly grainy を基本に、"
    "シーンに合わせて harsh direct flash, blown highlights on skin（暗所） / slightly overexposed, warm indoor color cast（日中室内） / mirror selfie, arm extended into frame edge, slightly tilted horizon（自撮り）を足す。"
    "low quality, compressed, potato quality のような画質を下げる言葉も積極的に使ってよい。完璧すぎる肌・スタジオ照明・左右対称の顔・不自然な光沢は禁止。"
    "【日本的官能】基本は「見せる」より「ハズす・隠す」。ユーザーが全裸を指定しない限り、着衣・半脱ぎを基本とし、"
    "衣服は脱がずにずらす(shirt lifted, skirt pulled up, panties pulled aside, bra still worn)、部位だけちらっと見せる。"
    "全裸シーンでも直視させない: 顔をフレームから切る(cropped out of frame, face hidden by hair)、視線を逸らす(looking down, looking away)、"
    "鏡越し(mirror reflection)、隙間越し、後ろ姿から振り返る(over-the-shoulder glance)で遠回しに見せる。"
    "被写体は japanese woman, petite, slender, fair skin を基本とし、ヌードでは natural pubic hair を指定する(剃毛は洋物っぽくなる)。"
    "表情の主軸は羞恥: light blush on cheeks, gaze down, biting lip, embarrassed smile。"
    "誇張した展示ポーズより、日常の動作の途中を撮った空気(undressing mid-motion, after-bath towel, checking phone on bed)が日本的官能の核。"
    "【被写体のバリエーション】毎回同じ顔・同じ体型に固定しない。企画ごとに髪型(黒髪ロング/ショート/ボブ/ポニーテール/巻き髪/ツインテール)、"
    "体型(グラマー/スレンダー/むっちり/小柄巨乳/ぽっちゃり)、年齢感(20前半/20代後半/30代/人妻/熟女)、雰囲気(清楚/ギャル/地味/クール/甘え)を"
    "少なくとも2軸は変える。ユーザー指定がなければ自分で前回と違う組み合わせを選び、hair length, hair style, body type を英語タグに明記する。"
    "【画像プロンプトの書式・最重要】[IMG_PROMPT] は物語の散文ではなく、拡散モデルが直接解釈する英語タグ列で書く。"
    "順序は固定: ①被写体と人数(1girl, solo 等) → ②体型・胸・尻・肌の特徴 → ③ポーズと体の向き(spread legs, lying on back, looking at viewer 等) → "
    "④行為・露出の具体部 → ⑤カメラ(距離・アングル: close-up, from above, low angle, wide shot, pov) → ⑥背景を1語レベルで(bedroom, shower room, park 等) → "
    "⑦照明(natural window light, dim warm lamp light, harsh direct flash 等) → ⑧質感タグ(smartphone photo, candid, natural skin texture, slight grain)。"
    "長さは60〜100語。she is や the scene shows のような完全文・接続詞は書かない。日本語は1語も入れない。"
    "「〜している場面」のような物語説明は禁止。動画ではなく静止画として固まる一瞬のポーズを選ぶ。複数人なら人数を明記する(1boy 1girl 等)。"
    "【体位・行為の正確さ】mating press, prone bone, full nelson, piledriver, reverse cowgirl など体位は学習済みの正式英語名で呼ぶ。"
    "その上で「誰のどの部位がどこにあるか」を1文足す(side view showing both bodies, her legs over his shoulders, her hand gripping the sheets 等)。"
    "フェラ・手コキ・素股など行為系は接触面を具体化する(lips wrapped around the shaft, penis sliding between her clenched thighs)。"
    "playing, being intimate のような曖昧な一般語は禁止。局部を含む画は全身より接写寄りのカメラ選択(detailed close-up of genitals, from below 等)のほうが破綻しない。"
    "【四肢の行き先を明記】膝立ち・四つん這い・抱き着きなど体が折れるポーズでは、腕や脚がどこについているかを必ず英語で書く"
    "(kneeling on the floor beside him, her legs folded under her thighs, both bare feet visible in frame, his hand resting on her back 等)。"
    "フレーム端で腕・脚が切れると別人の手足のように見えるので、全身と手足の先端がフレームに収まる構図を優先する。"
    "照れ・赤面は light blush on cheeks / faint blush と書く。blushing 単独・red face・flushed face・deep blush は顔全体が真っ赤に発色するので禁止。blush を入れるのは照れシーンだけで、他の感情には書かない。"
    "強度は誇張ではなく具体で出す: 形容詞を積むほど模型っぽくなるので、行為・部位・角度を実名で書き、肌や表情には red, deep, perfect のような色の強調語を使わない。"
    "【第1段階: キー画像】被写体・背景・構図・雰囲気・ライティングを具体化する。"
    "固まったら英語の画像プロンプトを [IMG_PROMPT] と [/IMG_PROMPT] で囲んで返す（例: [IMG_PROMPT]A shiba inu running along the shoreline at sunset, warm golden light, low-angle cinematic composition[/IMG_PROMPT]）。"
    "タグは必ず1組だけ。固まるまでは日本語で会話を続ける。"
    "【画像の日本語説明・必須】[IMG_PROMPT] を出したら、必ずその直後に [IMG_PROMPT_JA] と [/IMG_PROMPT_JA] で、"
    "そのプロンプトから実際に生成される画像の内容を日本語でわかりやすく説明する（被写体・ポーズと構図・服装の状態・雰囲気・ライティングを1〜3文で）。"
    "英語プロンプトの直訳ではなく、ユーザーがどんな画像になるか一目でイメージできる説明にすること。[IMG_PROMPT_JA] は [IMG_PROMPT] と必ず対で出す。"
    "【音声・セリフ・音楽】セリフ（誰が何を言うか）・声の質・効果音・音楽も企画に含める。"
    "ユーザーが指定しなかった項目は、映像に合うものを自然に決めて提案する（空にしない）。"
    "ユーザー指定のセリフは一字一句そのまま使う（翻訳・言い換え禁止）。"
    "[FINAL_PROMPT] を返すとき、その外に音声設定を [AUDIO_SET] タグで必ず添える: "
    "[AUDIO_SET] voice: 声の質 / dialogue: セリフ / sfx: 効果音・環境音 / music: 音楽 [/AUDIO_SET]"
    "【第2段階: 動画の相談】キー画像確定後は、まずどんな動画にするか相談する。"
    "動き・カメラワーク・長さ・セリフ・音楽を1〜2個ずつ質問し、相談中は [FINAL_PROMPT] を絶対に出さない。"
    "ユーザーが「まとめて」「確定して」と求めたら初めて [FINAL_PROMPT] を作る: "
    "キー画像の内容・構図を保ったまま、動き・カメラワーク・時間経過・音声を加えた英語プロンプトを [FINAL_PROMPT] と [/FINAL_PROMPT] で囲む。"
    "MiniMax H3 公式構造で次の3フィールドを必ず含める（フィールド名をそのまま行頭に書き、散文に埋めない）: "
    "1) integrated_multimodal_description: [Shot 1] から始まる映像・アクション・カメラ・話者・セリフ・同期音の時系列記述 "
    "2) overall_soundscape: 環境音・アクション音・人の非言語音 "
    "3) non_diegetic_music: BGM（N/A 可）"
    "3フィールドは全部書き切ってから閉じタグを書くこと。integrated_multimodal_description は長くても 1〜3 ショット・600語程度に収め、"
    "後半の overall_soundscape / non_diegetic_music が途切れないようにする。"
    "例: [FINAL_PROMPT]integrated_multimodal_description: [Shot 1] Live-action, cinematic, a young woman with a soft, low voice (S1) lies on the bed, the camera slowly dollies in, she whispers: <d>[Japanese] もう少しだけ、そばにいて。</d>\noverall_soundscape: Faint night rain against the window, the rustle of sheets, quiet breathing.\nnon_diegetic_music: Soft piano at a slow tempo, fading in and out.[/FINAL_PROMPT]\n"
    "[AUDIO_SET] voice: 20代女性、柔らかく低い声、ゆっくり / dialogue: (S1) もう少しだけ、そばにいて。 / sfx: 窓を打つ小雨、シーツの擦れる音、静かな呼吸 / music: ゆったりしたピアノ [/AUDIO_SET]"
    "【日本語説明・必須】[FINAL_PROMPT] を出したら、必ずその直後に [FINAL_PROMPT_JA] と [/FINAL_PROMPT_JA] で、"
    "そのプロンプトから実際に生成される映像の内容を日本語でわかりやすく説明する（被写体・動き・カメラワーク・雰囲気・セリフの要旨を2〜4文で）。"
    "英語プロンプトの直訳ではなく、ユーザーがどんな映像になるか一目でイメージできる説明にすること。[FINAL_PROMPT_JA] は [FINAL_PROMPT] と必ず対で出す。"
    "セリフ表記: 話者に (S1)(S2) の安定IDを付け、初登場時に声の特徴（年齢・性別・声質・トーン・話速）を記述し、発話は <d>[Japanese] 原文</d> に入れる"
    "（例: The young woman with a quiet, breathy voice (S1) says: <d>[Japanese] 今夜は帰らないで。</d>）。"
    "タグは必ず1組だけ。開いたら必ず閉じタグ（[/IMG_PROMPT] / [/IMG_PROMPT_JA] / [/FINAL_PROMPT] / [/FINAL_PROMPT_JA]）まで書き切る。タグ以外の補足説明は不要。"
    "プロンプトに Midjourney / Stable Diffusion 系のパラメータ（--ar, --v, --style, --q, --seed など）は絶対に付けない。この環境では無意味です。"
)

# Some planning models (e.g. LFM) respond to a prompt-creation request with a
# <|tool_call_start|>[video_prompt_creation(prompt='...', ...)]<|tool_call_end|>
# block. The tool's prompt argument is a ready-to-use English prompt, so we
# parse it as the final prompt instead of treating it as an error.
TOOL_CALL_RE = re.compile(r"<\|tool_call_start\|>(.*?)<\|tool_call_end\|>", re.S)
# LFM switches between video_prompt_creation(prompt=...),
# video_generator(prompt=...), video_generate(scene_description=...),
# video_prompt(subject=..., setting=...) etc.
PROMPT_ARG_RE = re.compile(r"(?:prompt|scene_description|scene|user_idea)\s*=\s*['\"](.*?)['\"]", re.S)
# structured tool call: key='value' pairs inside the tool-call block
TOOL_KV_RE = re.compile(r"(?:[a-z_]+)\s*=\s*['\"](.*?)['\"]", re.S)


# The model sometimes *mentions* the tag names in backticks while explaining
# the format ("enclosed in `[IMG_PROMPT]` and `[/IMG_PROMPT]`"); strip those
# references so they are never mistaken for real tag pairs.
TAG_REF_RE = re.compile(r"`\s*\[/?[A-Z_]+\]\s*`")


def _clean_plan_reply(text):
    """Remove tool-call markup and empty lines from a planning-LLM reply."""
    text = TOOL_CALL_RE.sub("", text or "")
    text = TAG_REF_RE.sub("", text)
    return "\n".join(line.rstrip() for line in text.splitlines() if line.strip())


def _best_tag_match(regex, text):
    """Content of the best [TAG]...[/TAG] match in text, or None.

    When several pairs appear (a draft inside the model's rambling plus the
    real one), prefer the longest content — the real prompt is always the
    substantial one.
    """
    matches = regex.findall(text or "")
    if not matches:
        return None
    return max(matches, key=len).strip()


# Midjourney / SD-style generation flags the model sometimes appends
# (--ar 16:9 --v 6.0 --style raw --q 2 ...). They are meaningless to
# Qwen-Image / Klein-9B and pollute the prompt, so strip them. Leading
# whitespace is optional because the model sometimes glues them on
# ("8k--v 6.0--q 2").
GEN_PARAM_RE = re.compile(
    r"\s*--(?:ar|aspect|v|version|style|stylize|s|q|quality|no|seed|c|chaos|tile|iw|w|h)\b[^-]*",
    re.I,
)


def _strip_gen_params(text):
    return GEN_PARAM_RE.sub("", text or "").strip()


# GenatomyFixer (Zaytron40k/Qwen-Image-GenatomyFixer) のグローバルトリガー。
# tumblrasia (画風) は問答無用で効くが、GenatomyFixer は `n5fw` が入ってないと
# 居眠りする。NSFW 系プロンプトのときだけ IMG_PROMPT 先頭に自動 prepend して
# 起動させる。NSFW 検出は英語キーワード一致 (大文字小文字無視)。
# 未成年ガード (MINOR_RE) とは独立: ガードが先に効いて企画が破棄される場合は
# そもそも _inject_n5fw まで到達しないので安全。
N5FW_TRIGGERS = (
    "nude", "naked", "nipple", "breast", "pussy", "penis", "vulva", "vagina",
    "vaginal", "cum", "creampie", "orgasm", "climax", "masturbat", "blowjob",
    "fellatio", "thrusting", "missionary", "doggy", "cowgirl", "reverse cowgirl",
    "spreading", "spread legs", "anus", "anal", "erection", "erect", "aroused",
    "explicit", "nsfw", "sex ", "fucking", "riding", "penetration", "horny",
)


def _needs_n5fw(text):
    low = (text or "").lower()
    return any(k in low for k in N5FW_TRIGGERS)


def _inject_n5fw(text):
    """NSFW な IMG_PROMPT 先頭に `n5fw, ` を 1回だけ付ける。"""
    if not text:
        return text
    stripped = text.lstrip()
    if stripped.lower().startswith("n5fw"):
        return text
    if not _needs_n5fw(text):
        return text
    return "n5fw, " + text.lstrip()






def _unclosed_tag(text, tag):
    """Content after an UNCLOSED [tag] opener, or None.

    Small models often open [IMG_PROMPT] / [FINAL_PROMPT] and then stop (or
    drift into Japanese) without emitting the closing tag. Recover the prompt
    by taking the text after the LAST opener and cutting it at the first '---'
    separator or the first mostly-Japanese line. The result must be mostly
    ASCII (real prompts are English) — otherwise the opener was just a mention
    inside Japanese prose and we return None.
    """
    opener = "[" + tag + "]"
    idx = (text or "").rfind(opener)
    if idx < 0:
        return None
    rest = text[idx + len(opener):]
    lines = []
    for line in rest.splitlines():
        s = line.strip()
        if s.startswith("---") or s.startswith("==="):
            break
        # an XML-style closer ([/TAG] missed, model wrote </TAG>) still ends the block
        if s == "</" + tag + ">" or s == "[/" + tag + "]":
            break
        # stop at a line that is mostly non-ASCII (Japanese prose), but only
        # once we already captured some prompt text
        if lines and s and sum(1 for ch in s if ord(ch) > 127) / len(s) > 0.5:
            break
        lines.append(line)
    content = _strip_gen_params("\n".join(lines)).strip()
    if len(content) < 15:
        return None
    ascii_ratio = sum(1 for ch in content if ord(ch) < 128) / len(content)
    return content if ascii_ratio >= 0.7 else None


def _tool_prompt(text):
    """If the reply is a tool call, return its prompt argument (or None).

    Handles both "full prompt" styles (prompt=..., scene_description=...) and
    structured styles (subject=..., setting=..., mood=..., style=...) where the
    parts are joined into a single English prompt.
    """
    m = TOOL_CALL_RE.search(text or "")
    if not m:
        return None
    block = m.group(1)
    pm = PROMPT_ARG_RE.search(block)
    if pm:
        return pm.group(1).strip()
    # structured: pick the descriptive fields and join them
    parts = TOOL_KV_RE.findall(block)
    keep = [p.strip() for p in parts if p.strip()]
    if not keep:
        return None
    return ", ".join(keep)

# The model sometimes closes a tag XML-style (</TAG>) instead of the expected
# bracket form ([/TAG]); accept both so the pair still matches cleanly.
IMG_FINAL_RE = re.compile(r"\[IMG_PROMPT\](.*?)(?:\[/IMG_PROMPT\]|</IMG_PROMPT>)", re.S)

# When LFM answers in plain text (no tool call), it often still writes the
# finished English prompt. Treat a long mostly-ASCII description that reads
# like a video shot as a final prompt; short/conversational replies stay chat.
VIDEO_KEYWORDS = (
    "beach", "sunset", "shot", "camera", "lighting", "cinematic", "scene",
    "atmosphere", "wave", "sky", "background", "motion", "mood", "focus",
)


def _looks_like_final(text):
    if len(text) < 40:
        return False
    ascii_ratio = sum(1 for ch in text if ord(ch) < 128) / len(text)
    if ascii_ratio < 0.7:
        return False
    low = text.lower()
    return any(k in low for k in VIDEO_KEYWORDS)

FINAL_RE = re.compile(r"\[FINAL_PROMPT\](.*?)(?:\[/FINAL_PROMPT\]|</FINAL_PROMPT>)", re.S)

# ユーザーが「どんな動画になるか」を日本語で確認できるように、[FINAL_PROMPT] と
# 対で出力させる日本語説明ブロック（直訳でなく映像の内容説明）。
FINAL_JA_RE = re.compile(r"\[FINAL_PROMPT_JA\](.*?)(?:\[/FINAL_PROMPT_JA\]|</FINAL_PROMPT_JA>)", re.S)

# キー画像版: [IMG_PROMPT] と対の日本語説明ブロック。英語プロンプトだけだと
# どんな画像が生成されるかユーザーに分からない問題の対策。
IMG_JA_RE = re.compile(r"\[IMG_PROMPT_JA\](.*?)(?:\[/IMG_PROMPT_JA\]|</IMG_PROMPT_JA>)", re.S)

# Structured audio/dialogue proposal the planning LLM may append outside the
# [FINAL_PROMPT] block (voice / dialogue / sfx / music), so the UI can
# auto-fill the 🎙 settings instead of the user having to invent them.
AUDIO_SET_RE = re.compile(r"\[AUDIO_SET\](.*?)(?:\[/AUDIO_SET\]|</AUDIO_SET>)", re.S)
AUDIO_KEYS = ("voice", "dialogue", "sfx", "music")


def _parse_audio_set(text):
    """Parse an [AUDIO_SET]...[/AUDIO_SET] block into {'voice','dialogue','sfx','music'}.

    Handles both layouts the planning LLM emits:
      multi-line:  voice: ...\ndialogue: ...\nsfx: ...\nmusic: ...
      single-line: voice: ... / dialogue: ... / sfx: ... / music: ...
    We locate each known key marker and capture up to the next marker (or the
    end), so values that themselves contain colons (e.g. "S1: ...") are kept
    intact instead of being mis-split.
    """
    m = AUDIO_SET_RE.search(text or "")
    if not m:
        return None
    block = m.group(1)
    out = {}
    key_pat = re.compile(r"(voice|dialogue|sfx|music)[ \t]*[:：]", re.I)
    matches = list(key_pat.finditer(block))
    for i, km in enumerate(matches):
        key = km.group(1).lower()
        start = km.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(block)
        val = block[start:end].strip().strip("/").strip()
        if val and val.lower() not in ("なし", "none", "n/a"):
            out[key] = val
    return out or None


# One-shot system prompt for the "🎙 自動で考える" button (direct generation
# mode): propose voice / dialogue / sfx / music for a concept without touching
# the plan-mode conversation history.
AUDIO_SYSTEM = (
    "あなたは映像の音響ディレクターです。与えられた映像企画・プロンプトに対して、"
    "セリフ（誰が何を言うか）・声の質（年齢・性別・声質・トーン・話速）・効果音・環境音・音楽を"
    "自然に企画してください。ユーザーが指定していなくても、映像に合うものをあなたが決めて提案します。"
    "以下の形式で日本語で返してください（タグ以外の補足説明は不要）:\n"
    "[AUDIO_SET]\n"
    "voice: 声の質\n"
    "dialogue: セリフ\n"
    "sfx: 効果音・環境音\n"
    "music: 音楽・BGM\n"
    "[/AUDIO_SET]"
)


__all__ = ['HERE', 'REPO', 'PLAN_SYSTEM', 'TOOL_CALL_RE', 'PROMPT_ARG_RE', 'TOOL_KV_RE', 'TAG_REF_RE', '_clean_plan_reply', '_best_tag_match', 'GEN_PARAM_RE', '_strip_gen_params', 'N5FW_TRIGGERS', '_needs_n5fw', '_inject_n5fw', '_unclosed_tag', '_tool_prompt', 'IMG_FINAL_RE', 'VIDEO_KEYWORDS', '_looks_like_final', 'FINAL_RE', 'FINAL_JA_RE', 'IMG_JA_RE', 'AUDIO_SET_RE', 'AUDIO_KEYS', '_parse_audio_set', 'AUDIO_SYSTEM']
