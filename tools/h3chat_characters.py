"""Character pinning library (config/characters) + workflow appliers."""

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

# ---- キャラ固定ライブラリ（config/characters/） ---------------------------
# 編集は Web GUI (web-ui/server.js の /api/characters)、消費はこのファイル。
# キャッシュを持たずリクエストごとにディレクトリを読むので、GUI での編集が
# h3-chat の再起動なしで次の生成から反映される。システムプロンプト
# (PLAN_SYSTEM) は 1 バイトも変更しない: 認知は「ピン中ターンのユーザー文前置き」
# （char_identity_prefix）、保証は生成時の機械適用（negative 追記 / LoRA 挿入 /
# seed 固定）で行う。ピンなしのリクエストは従来どおり動く。
CHARACTERS_DIR = os.path.join(REPO, "config", "characters")
_CHAR_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


def _char_id_ok(char_id):
    return bool(char_id) and bool(_CHAR_ID_RE.match(char_id))


def _load_characters():
    """キャラカード一覧を読む（毎回ディスク・壊れたファイルはスキップ）。"""
    out = []
    try:
        names = os.listdir(CHARACTERS_DIR)
    except OSError:
        return out
    for fn in sorted(names):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(CHARACTERS_DIR, fn), encoding="utf-8") as f:
                card = json.load(f)
        except Exception as ex:
            print(f"h3-chat: skipping character file {fn}: {ex}")
            continue
        if isinstance(card, dict) and _char_id_ok(card.get("id")) and card.get("summary"):
            out.append(card)
    return out


def get_character(char_id):
    """char_id のカードを返す（無ければ None）。パストラバーサルは ID 正規表現で遮断。"""
    if not _char_id_ok(char_id):
        return None
    for card in _load_characters():
        if card.get("id") == char_id:
            return card
    return None


def char_summary_text(card):
    """カード summary をプロンプト用 1 文に正規化（改行潰し・末尾句点除去）。"""
    s = " ".join(str((card or {}).get("summary") or "").split())
    return s[:-1] if s.endswith(".") else s


def char_negative_text(card):
    return " ".join(str((card or {}).get("negative") or "").split())


def char_identity_prefix(card):
    """認知層: ピン中のターンだけユーザー文の頭に前置きする 1 行。

    PLAN_SYSTEM への追記はしない。前置きは PLAN_HISTORY の 6 ターン窓から
    自然に流れ出るため、ピンを外せばコンテキスト コストはゼロに戻る。
    量は約 60〜80 トークン/ピン中ターン。
    """
    if not card:
        return ""
    name = str(card.get("name") or card.get("id"))
    return (
        "[キャラ固定: " + name + "] "
        "被写体の同一人物性（顔・髪・体型・肌質）は次の英語タグ列で固定する。"
        "[IMG_PROMPT] ではスマホ写真の導入句の直後にこの被写体描写をそのまま置き、"
        "ユーザーの指示と矛盾しない限り髪・体型・顔は変更しない。"
        "人数・ポーズ・行為・服装・構図・照明・質感はシーンに合わせて書いてよい: "
        + char_summary_text(card) + "\n\n"
    )


def _negative_node_id(wf):
    """KSampler の negative 入力リンクを辿って負プロンプト ノード ID を返す。

    ノード ID はワークフローごとに違う（klein=6, qimg=6, 動画系も別）
    のでハードコードせず必ずリンクから特定する。
    """
    for node in wf.values():
        if not isinstance(node, dict):
            continue
        if node.get("class_type") in ("KSampler", "KSamplerAdvanced"):
            neg = (node.get("inputs") or {}).get("negative")
            if isinstance(neg, list) and neg and isinstance(neg[0], str) and neg[0] in wf:
                return neg[0]
    return None


def _append_negative(wf, extra):
    """負プロンプト ノードの text に extra を追記する（重複は無視）。"""
    extra = (extra or "").strip(", ")
    if not extra:
        return False
    nid = _negative_node_id(wf)
    if not nid:
        return False
    inputs = wf[nid].setdefault("inputs", {})
    text = str(inputs.get("text") or "")
    if extra in text:
        return True
    inputs["text"] = (text.rstrip().rstrip(",") + ", " + extra) if text else extra
    return True


def _apply_char_loras(wf, lora_list):
    """カードの LoRA を KSampler の model 入力にチェーン挿入する。

    既存の qimg 多段 LoRA（LoraLoaderModelOnly を model 入力に直列接続）と
    同型の改変。適用できた LoRA 名のリストを返す。
    """
    if not isinstance(lora_list, list) or not lora_list:
        return []
    sampler = next((n for n in wf.values()
                    if isinstance(n, dict) and n.get("class_type") in ("KSampler", "KSamplerAdvanced")), None)
    if not sampler:
        return []
    ins = sampler.get("inputs") or {}
    model_in = ins.get("model")
    if not (isinstance(model_in, list) and len(model_in) == 2
            and isinstance(model_in[0], str) and model_in[0] in wf):
        return []
    cur = model_in[0]
    next_id = max((int(k) for k in wf if k.isdigit()), default=0) + 1
    applied = []
    for entry in lora_list:
        if isinstance(entry, str):
            entry = {"name": entry, "strength": 1.0}
        name = str((entry or {}).get("name") or "").strip()
        if not name or os.sep in name or "/" in name:
            continue
        try:
            strength = float((entry or {}).get("strength", 1.0))
        except (TypeError, ValueError):
            strength = 1.0
        nid = str(next_id)
        next_id += 1
        wf[nid] = {
            "class_type": "LoraLoaderModelOnly",
            "inputs": {"model": [cur, 0], "lora_name": name, "strength_model": strength},
            "_meta": {"title": "Character LoRA: " + name},
        }
        cur = nid
        applied.append(name)
    if applied:
        # Python dict semantics: `ins` IS sampler["inputs"], so this already
        # rewires the sampler in place. Reassign it anyway to make the
        # mutation explicit and survive a future copy-based refactor.
        ins["model"] = [cur, 0]
        sampler["inputs"]["model"] = ins["model"]
    return applied


__all__ = ['HERE', 'REPO', 'CHARACTERS_DIR', '_CHAR_ID_RE', '_char_id_ok', '_load_characters', 'get_character', 'char_summary_text', 'char_negative_text', 'char_identity_prefix', '_negative_node_id', '_append_negative', '_apply_char_loras']
