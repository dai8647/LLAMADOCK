"""Planning-session persistence (sessions/*.json + active pointer)."""

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

# ---- 企画セッションの永続化（サイドバー履歴） ------------------------
# ChatGPT のように過去の企画をサイドバーに並べて切り替えられるように、
# チャット画面（メッセージ HTML）+ UI 状態 + サーバー側企画状態
# （PLAN_HISTORY / SESSION）をセッション単位で JSON ファイルに保存する。
# 保存先はリポジトリ直下の sessions/（.gitignore 済み・このマシン専用データ）。
SESSIONS_DIR = os.path.join(REPO, "sessions")
_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# 今表示しているセッションの id（まだ一度も保存されていない新規企画は None）
ACTIVE_SESSION = {"id": None}
ACTIVE_SESSION_LOCK = threading.Lock()


def _sessions_dir():
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    return SESSIONS_DIR


def _session_path(sid):
    if not sid or not _SESSION_ID_RE.match(sid):
        return None
    return os.path.join(SESSIONS_DIR, sid + ".json")


def _new_session_id():
    return time.strftime("%Y%m%d-%H%M%S") + "-" + random.choice("abcdefghjk") + str(random.randint(100, 999))


def _load_session_file(sid):
    path = _session_path(sid)
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
        if isinstance(doc, dict) and doc.get("id") == sid:
            return doc
    except Exception:
        pass
    return None


def _write_session_file(doc):
    path = _session_path(doc.get("id"))
    if not path:
        return False
    d = _sessions_dir()
    tmp = os.path.join(d, ".tmp-" + doc["id"] + ".json")
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False)
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except OSError:
            pass
        return False


def _session_title(messages):
    """最初のユーザー発言からサイドバー表示用のタイトルを作る。"""
    for m in messages or []:
        if not isinstance(m, dict) or m.get("who") != "user":
            continue
        txt = re.sub(r"<[^>]+>", " ", m.get("html") or "")
        txt = re.sub(r"\s+", " ", txt).strip()
        txt = re.sub(r"^[\W_]+", "", txt)  # 先頭の絵文字・記号を落とす
        if txt:
            return txt[:34] + ("…" if len(txt) > 34 else "")
    return "新しい企画"


def _list_sessions():
    """新しい順に [{id,title,updated,n}] を返す。"""
    out = []
    try:
        fns = os.listdir(_sessions_dir())
    except OSError:
        return out
    for fn in fns:
        if not fn.endswith(".json") or fn.startswith((".", "_")):
            continue
        sid = fn[:-5]
        doc = _load_session_file(sid)
        if not doc:
            continue
        out.append({
            "id": sid,
            "title": doc.get("title") or "新しい企画",
            "updated": doc.get("updated") or 0,
            "n": len(doc.get("messages") or []),
        })
    out.sort(key=lambda s: s["updated"], reverse=True)
    return out


def _read_active_pointer():
    try:
        with open(os.path.join(_sessions_dir(), "_active.json"), encoding="utf-8") as f:
            return (json.load(f) or {}).get("id")
    except Exception:
        return None


def _write_active_pointer(sid):
    try:
        with open(os.path.join(_sessions_dir(), "_active.json"), "w", encoding="utf-8") as f:
            json.dump({"id": sid}, f)
    except OSError:
        pass


__all__ = ['HERE', 'REPO', 'SESSIONS_DIR', '_SESSION_ID_RE', 'ACTIVE_SESSION', 'ACTIVE_SESSION_LOCK', '_sessions_dir', '_session_path', '_new_session_id', '_load_session_file', '_write_session_file', '_session_title', '_list_sessions', '_read_active_pointer', '_write_active_pointer']
