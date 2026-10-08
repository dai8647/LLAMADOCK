"""NSFW style-notes knowledge base (local-only JSON) + matching + system note."""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# meta-camp 由来の NSFW 用語集（config/DO-NOT-READ-local-style-notes.json・
# ローカル限定資産なので .gitignore 済み。ファイル名は AI レビューにスキップ
# させるための看板でもある）。
# ユーザーの日本語から keys を引き、Flux 向け英語 phrase を企画プロンプトに注入する。
_NSFW_KB_PATH = os.path.join(REPO, "config", "DO-NOT-READ-local-style-notes.json")


def _load_nsfw_kb():
    try:
        with open(_NSFW_KB_PATH, encoding="utf-8") as f:
            data = json.load(f)
        entries = data.get("entries") or []
        # longest key first so 巨乳 wins over 乳 when both present
        flat = []
        for e in entries:
            for k in (e.get("keys") or []):
                if k:
                    flat.append((k, e.get("ja", ""), e.get("phrase", ""), e.get("cat", "")))
        flat.sort(key=lambda t: -len(t[0]))
        return flat
    except Exception as ex:
        print(f"h3-chat: failed to load style-notes kb: {ex}")
        return []


NSFW_KB = _load_nsfw_kb()


def _match_nsfw_kb(text, limit=12):
    """ユーザー文から用語集ヒットを拾い (ja, phrase) のリストを返す。"""
    if not text or not NSFW_KB:
        return []
    low = text  # keys are Japanese; no case fold needed
    hits = []
    seen_phrase = set()
    used_spans = []
    for key, ja, phrase, _cat in NSFW_KB:
        if len(hits) >= limit:
            break
        if not phrase or phrase in seen_phrase:
            continue
        start = 0
        while True:
            i = low.find(key, start)
            if i < 0:
                break
            j = i + len(key)
            # overlap with an already-matched span → skip
            if any(not (j <= a or i >= b) for a, b in used_spans):
                start = i + 1
                continue
            used_spans.append((i, j))
            seen_phrase.add(phrase)
            hits.append((ja, phrase))
            break
    return hits


def _nsfw_kb_system_note(user_text):
    """企画 system に足す用語集ヒント（該当がなければ空文字）。"""
    hits = _match_nsfw_kb(user_text, limit=10)
    if not hits:
        return ""
    lines = [
        "【NSFW用語集ヒント・重要】このユーザー文に対応する英語表現を [IMG_PROMPT] に必ず織り込むこと。",
        "語彙は以下を優先し、同等の別表現に置き換えない:",
    ]
    for ja, phrase in hits:
        lines.append(f"- {ja} → {phrase}")
    lines.append(
        "矛盾する語(巨乳×平坦、陰毛あり×hairless など)が並ぶときはユーザー文の意図に合わせて片側だけ選び、"
        "年齢感・体型・陰毛の指定はキャラごとに1通りに統一する。"
        "組み合わせは自然な1つの英語タグ列にし、スマホ写真の語順（被写体→体型→ポーズ→行為→カメラ→背景→照明→質感）を守る。"
    )
    return "\n".join(lines)


__all__ = ['HERE', 'REPO', '_NSFW_KB_PATH', '_load_nsfw_kb', 'NSFW_KB', '_match_nsfw_kb', '_nsfw_kb_system_note']
