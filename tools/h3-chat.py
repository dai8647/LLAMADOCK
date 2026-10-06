#!/usr/bin/env python3
"""h3-chat.py - MiniMax H3 text-to-video chat UI.

Runs a tiny local HTTP server (127.0.0.1:8189) that serves a chat-style page.
Type a prompt, pick quick/full, and it submits the matching MiniMax H3
workflow to a running ComfyUI (127.0.0.1:8188), polls until done, and plays
the resulting video inline. Proxies /prompt, /history, /view so the browser
never talks to ComfyUI directly (avoids CORS).

Planning mode: when enabled, messages are bounced off a local planning LLM
(OpenAI-compatible endpoint, e.g. a llama-server on --plan-url) so the user
can shape the video concept conversationally before generating. When the LLM
wraps its final prompt in [FINAL_PROMPT]...[/FINAL_PROMPT], the UI offers a
"generate with this plan" button.

Two planning LLMs are supported:
  - default: Qwen3.5-4B on CPU (-ngl 0, port 8190), resident, vision-capable.
  - LLAMADOCK_PLAN_GPU=1: Qwen3.8-27B-Abliterated on GPU (-ngl all, port
    8191). Started on demand for the planning phase only and killed before
    every ComfyUI generation, so the 14GB planner and the video model never
    fight over VRAM. No vision projector: the confirmed key image is handed
    off as its prompt text.

Reference mode (R2V): when a key image has been confirmed in plan mode,
ticking the reference checkbox generates the video with MiniMaxH3ReferenceToVideo
using the confirmed key image as <Picture 1> (reference LoRA, no ref2va model
needed). The image is copied into ComfyUI input/ so LoadImage can read it.

Usage:
    python tools/h3-chat.py [--port 8189] [--comfy http://127.0.0.1:8188]
                             [--plan-url http://127.0.0.1:8190]
"""

import argparse
import base64
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


# ---- モジュール分割（2026-10-04 リファクタリング）--------------------------
# 純粋なユーティリティ群を tools/h3chat_*.py に分離した。このファイルは
# エントリポイント + HTTPサーバー (ChatHandler) + ワークフロー定数 + 実行状態。
# spec_from_file_location で import される場合に備え、tools/ を sys.path に足す。
sys.path.insert(0, HERE)

from h3chat_kb import *          # noqa: F401,F403
from h3chat_characters import *  # noqa: F401,F403
from h3chat_video import *       # noqa: F401,F403
from h3chat_planllm import *     # noqa: F401,F403
from h3chat_prompting import *   # noqa: F401,F403
from h3chat_sessions import *    # noqa: F401,F403
from h3chat_page import *        # noqa: F401,F403

import h3chat_planllm as planllm  # 実行中に変わる企画LLM状態はモジュール属性経由で読む


WORKFLOWS = {
    # 32B Heretic encoder: best Japanese / detailed-prompt fidelity
    "high": os.path.join(REPO, "h3_workflow_turbo_audio.json"),
    "quick": os.path.join(REPO, "h3_workflow_turbo_short_audio.json"),
    # 4B Heretic encoder: lightest on VRAM
    "lite": os.path.join(REPO, "h3_workflow_super_audio.json"),
    # 4B encoder + short/res (quicklite): fastest option, light on VRAM
    "quicklite": os.path.join(REPO, "h3_workflow_super_short_audio.json"),
    # Spectrum + 20 steps (no turbo LoRA): highest quality, no LoRA artifacts
    "fast": os.path.join(REPO, "h3_workflow_fast_audio.json"),
    "fast_quick": os.path.join(REPO, "h3_workflow_fast_short_audio.json"),
}

# Estimated generation time (seconds) used for the remaining-time display
# before real measurements exist for this session. Updated live from actual
# run times (see _status / job_meta).
ETA_DEFAULTS = {"high": 540, "quick": 240, "lite": 540, "quicklite": 150, "fast": 900, "fast_quick": 360, "kimg": 30, "qimg": 180, "upscale": 180}

# モード ID → UI 表示名（チャット指示による上書きを生成時に表示するのに使う）
MODE_LABELS = {
    "fast": "最高画質 spectrum", "high": "高精度 32B",
    "fast_quick": "高画質 spectrum・短尺", "quick": "クイック 32B",
    "lite": "軽量 4B", "quicklite": "最速 4B",
}

# Selectable H3 video DiT checkpoints (node "1" = UNETLoader in all video
# workflows). "default" is the NVFP4 10Eros-Max beta2 (11.7GB — smaller AND
# higher quality than the old int8 default, so it took over as default).
DITS = {
    # 10Eros-Max beta2 NVFP4 (11.7GB) is both smaller and higher quality than
    # the old int8 default — it is the new "default". The PinkCherry int8
    # stays selectable under the "pinkcherry" key.
    "default": "10Eros-Max\\10Eros_Max_h3_fl2va_beta2_pruned_nvfp4.safetensors",
    "10eros": "10Eros-Max\\10Eros_Max_h3_fl2va_beta2_pruned_nvfp4.safetensors",
    "pinkcherry": "alpha-0.5-testing\\PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors",
}
NODE_UNET = "1"

# FLUX.2 [klein] 9B (key-image, quality-first): pornmasterFlux2Klein_v4TurboBf16
# Q8_0 GGUF + flux_klein_9b_nsfw_v2 LoRA. 4 step / 1秒台想定、9.5GB VRAM。
# Z-Image Turbo (約40秒・品質微妙) は 2026-09-04 に廃止。
KIMG_WORKFLOW = os.path.join(REPO, "h3_workflow_klein.json")
NODE_KIMG_PROMPT = "5"   # CLIPTextEncode: image prompt
NODE_KIMG_LATENT = "7"   # EmptySD3LatentImage: size + batch
NODE_KIMG_SEED = "9"     # KSampler: seed

# Qwen-Image 2.1 Uncensored (key-image, detail/close-up): UC Q4_K_M GGUF +
# Turbo 4step LoRA + GenatomyFixer 0.3. 2026-10-04 再建 — 旧 2512 構成は 9/21 の
# モデル切替がワークフローまで終わっておらず、参照先ファイルが消えて壊れていた。
# TE (qwen3vl_8b int8, 9.35GB) は VRAM を圧迫するので ComfyUI の自動スワップに任せる。
# 公式テンプレ (image_qwen_image_2_1_t2i) にならい ModelSamplingAuraFlow 無し・cfg=1。
QIMG_WORKFLOW = os.path.join(REPO, "h3_workflow_qimage.json")
NODE_QIMG_PROMPT = "5"   # CLIPTextEncode: image prompt
NODE_QIMG_LATENT = "7"   # EmptySD3LatentImage: size + batch
NODE_QIMG_SEED = "10"    # KSampler: seed


# Key-image engines selectable in the UI
IMG_ENGINES = {
    "kimg": {
        "workflow": KIMG_WORKFLOW,
        "prompt": NODE_KIMG_PROMPT, "latent": NODE_KIMG_LATENT, "seed": NODE_KIMG_SEED,
        "default_size": (1024, 1024),
        "label": "Klein 9B（品質主力・スマホ写真＋NSFW LoRA重ね掛け・素人風に強い）",
        "batch_size": 1,
        # 体型バリエーション: bodyweight concept slider (正負両方向のスライダー)。
        # 生成ごとにこの範囲で強度をランダム化して同じ顔・体型のワンパターンを防ぐ。
        # リクエストで bodyweight を明示すれば固定できる。
        "random_lora": {"node": "15", "low": -1.2, "high": 1.2},
    },
    "qimg": {
        "workflow": QIMG_WORKFLOW,
        "prompt": NODE_QIMG_PROMPT, "latent": NODE_QIMG_LATENT, "seed": NODE_QIMG_SEED,
        "default_size": (1344, 768),
        "label": "Qwen-Image 2.1 UC（局所描写・検閲なし・高画質・約3分）",
        "batch_size": 1,
    },
}

# R2V (reference-to-video) workflows: 確定したキー画像を参照画像にして同一キャラを維持する。
# MiniMaxH3ReferenceToVideo ノード + 参照 LoRA（minimax_h3_ref_lora_rank_256_bf16）を
# fl2va モデルに重ねる構成（ref2va モデル不要）。
# quicklite は 4B エンコーダ + ClipProj 射影（mmh3-4b-ClipProj-celeb-mlp）で 32B を代替し、約 1/3 の時間に。
# 4B を生で渡すと次元不一致（30720 vs 5120）で失敗するため ClipProjApply が必須。
# lite も r2v_4b（4B エンコーダ + ClipProj のフル尺版）を使う。以前は high と
# 同一ファイル（32B エンコーダ版）を指していて、「軽量」なのに VRAM も所要時間も
# high と全く同じという偽の選択肢になっていた。
R2V_WORKFLOWS = {
    "high": os.path.join(REPO, "h3_workflow_r2v.json"),
    "quick": os.path.join(REPO, "h3_workflow_r2v_short.json"),
    "lite": os.path.join(REPO, "h3_workflow_r2v_4b.json"),
    "quicklite": os.path.join(REPO, "h3_workflow_r2v_short_4b.json"),
    "fast": os.path.join(REPO, "h3_workflow_r2v_fast.json"),
    "fast_quick": os.path.join(REPO, "h3_workflow_r2v_fast_short.json"),
}
NODE_R2V_IMAGE = "16"    # LoadImage: 参照画像（ComfyUI input/ にコピーしたファイル名を設定）
NODE_R2V_PROMPT = "6"    # MiniMaxH3ReferenceToVideo: user prompt
# I2V（first/last フレーム固定）: 通常ワークフローの MiniMaxH3ImageToVideo
# （ノード "6"）に LoadImage を追加で配線する。ノード ID "20" は全動画
# ワークフローの既存 ID（最大 17）と衝突しない専用 ID。
NODE_I2V_FRAME_IMAGE = "20"
# MiniMaxH3ReferenceToVideo の ref_images は Autogrow 入力で最大 9 枚
# （ref_image_0..8）。プロンプトでは <Picture 1>..<Picture 9> で参照する。
MAX_REF_IMAGES = 9
# R2V はプロンプト内の <Picture N> タグで参照画像を指定する。企画 LLM が
# タグを知らないので、生成時にタグの意味を追記して確実に同一キャラ指定にする。
R2V_TAG_NOTE = (
    "\n\n<Picture 1> is the confirmed key image. "
    "Keep the subject's identity, face, hairstyle, outfit and appearance "
    "consistent with <Picture 1> in every frame of the video."
)


def _r2v_tag_note(n_pictures):
    """<Picture N> タグの説明をプロンプトに追記する（枚数別）。

    1 枚目は従来どおり「確定したキー画像」として扱い、2 枚目以降は
    追加のアイデンティティ参照として説明する。タグを知らないモデルに
    対して参照画像の役割を確実に伝えるための追記。
    """
    if n_pictures <= 1:
        return R2V_TAG_NOTE
    pics = ", ".join("<Picture %d>" % i for i in range(1, n_pictures + 1))
    return (
        "\n\nReference images provided: " + pics + ". "
        "<Picture 1> is the primary reference (the confirmed key image). "
        "The other pictures are additional identity references. Keep each "
        "appearing subject's face, hairstyle, outfit and appearance "
        "consistent with the corresponding picture in every frame."
    )


# ---- チャットでの画質・長さ調整 --------------------------------------
# キー画像を確定した後、チャットで「もっと高画質で」「長めに」「縦長で」などと
# 指示すると、プロンプトの文言だけでなく生成パラメータ（モード/フレーム数/解像度）
# もここで解釈して反映する。


def _align_h3_frames(n):
    """MiniMax H3 のフレームグリッド (17k+5) にスナップする。"""
    n = max(5, int(n))
    return 5 + 17 * max(0, round((n - 5) / 17))


def _parse_tweak(text):
    """自然言語の画質・長さ・アスペクト指示をパラメータへ変換する。

    Returns None または {'mode'?, 'length_frames'?, 'resolution'?, 'label': 表示用}。
    """
    t = text or ""
    tw = {}
    label = []
    # 画質
    if re.search(r"最高画質|ターボなし|spectrum|20ステップ|20steps", t):
        tw["mode"] = "fast"; label.append("高画質 spectrum")
    elif re.search(r"高画質|高精度|精細|きれい|フル尺|フルで", t):
        tw["mode"] = "high"; label.append("高精度 32B")
    elif re.search(r"省VRAM|軽量|4B", t):
        tw["mode"] = "lite"; label.append("軽量 4B")
    elif re.search(r"最速|チョロッと|さらっと", t):
        tw["mode"] = "quicklite"; label.append("クイック 4B")
    elif re.search(r"クイック|低画質|粗く|速く|サクッと", t):
        tw["mode"] = "quick"; label.append("クイック 32B")
    # 長さ（N秒 / N分 / 長く / 短く）
    m = re.search(r"(\d+)\s*秒", t)
    if m:
        frames = _align_h3_frames(int(m.group(1)) * 24)
        tw["length_frames"] = frames
        label.append(f"長さ 約{int(m.group(1))}秒")
    else:
        m = re.search(r"(\d+)\s*分", t)
        if m:
            frames = _align_h3_frames(int(m.group(1)) * 60 * 24)
            tw["length_frames"] = frames
            label.append(f"長さ 約{int(m.group(1))}分")
        elif re.search(r"(もっと)?長く|延ば|伸ば|長め", t):
            tw["length_frames"] = 100 if re.search(r"もっと|かなり|だいぶ", t) else 48
            label.append(f"長さ 約{round(tw['length_frames'] / 24)}秒")
        elif re.search(r"短く|短め|コンパクトに", t):
            tw["length_frames"] = 16
            label.append("長さ 約0.7秒（短め）")
    # アスペクト
    if re.search(r"縦長|9:16|ポートレート|タテ", t):
        tw["resolution"] = (768, 1344); label.append("縦長 9:16")
    elif re.search(r"正方形|1:1|スクエア", t):
        tw["resolution"] = (768, 768); label.append("正方形 1:1")
    elif re.search(r"横長|16:9|ワイド|ヨコ", t):
        tw["resolution"] = (1344, 768); label.append("横長 16:9")
    # fast + short length → fast_quick (spectrum short variant)
    if tw.get("mode") == "fast" and tw.get("length_frames", 48) <= 20:
        tw["mode"] = "fast_quick"
    if not tw:
        return None
    tw["label"] = "・".join(label)
    return tw


def _audio_block(audio):
    """UI の音声・セリフ設定をプロンプト末尾に追加するブロックを作る。"""
    if not isinstance(audio, dict):
        return ""
    dlg = (audio.get("dialogue") or "").strip()
    voice = (audio.get("voice") or "").strip()
    sfx = (audio.get("sfx") or "").strip()
    music = (audio.get("music") or "").strip()
    if not any([dlg, voice, sfx, music]):
        return ""
    if dlg and "<d>" not in dlg:
        dlg = f"The speaker (S1) says: <d>[Japanese] {dlg}</d>"
    lines = ["", "Audio direction (must be followed):"]
    if voice:
        lines.append("- Voice: " + voice)
    if dlg:
        lines.append("- Dialogue: " + dlg)
    if sfx:
        lines.append("- Soundscape/SFX: " + sfx)
    if music:
        lines.append("- Music: " + music)
    return "\n".join(lines)
SESSION_LOCK = threading.Lock()

# Server-side safety net: when a video finishes and nothing new is started,
# stop ComfyUI + planning LLM (freeing GPU/RAM) even if the browser tab is
# closed. The browser shows a shorter interactive countdown; this is the
# guarantee that "作成終わったらちゃんと落とす".
# Idle auto-stop is now OPT-IN: 0 disables the background watcher entirely so
# users can keep generating (続きの動画 / 別の参照画像) without the stack being
# killed under them. Set LLAMADOCK_H3_AUTOSTOP=180 to restore the old behavior.
AUTO_STOP_SECONDS = int(os.environ.get("LLAMADOCK_H3_AUTOSTOP", "0") or 0)


def _stop_stack(server):
    """Unload models, kill ComfyUI + planning LLM, then stop the chat server."""
    try:
        # free VRAM first (graceful unload), then kill the processes
        req = urllib.request.Request(
            server.comfy_base + "/free",
            data=json.dumps({"unload_models": True, "free_memory": True}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=15):
            pass
    except Exception:
        pass
    ChatHandler._kill_port(ChatHandler._comfy_port_of(server))
    ChatHandler._kill_port(planllm.PLAN_PORT)
    threading.Timer(1.5, server.shutdown).start()


class _AutoStop(threading.Thread):
    """Background watcher: stop the whole stack after a finished video sits
    idle for AUTO_STOP_SECONDS (no new generation / no plan activity)."""

    def __init__(self, server):
        super().__init__(daemon=True)
        self.server = server
        self._done_at = None
        self._lock = threading.Lock()
        self.start()

    def mark_done(self):
        with self._lock:
            self._done_at = time.time()

    def poke(self):
        with self._lock:
            self._done_at = None

    def run(self):
        if AUTO_STOP_SECONDS <= 0:
            return  # opt-in only: never kill the stack automatically
        while True:
            time.sleep(10)
            with self._lock:
                done_at = self._done_at
            if done_at is not None and time.time() - done_at > AUTO_STOP_SECONDS:
                try:
                    _stop_stack(self.server)
                except Exception:
                    pass
                return


def _server_state_snapshot():
    """企画 LLM の会話履歴と生成パラメータ上書きを JSON 化して保存する。"""
    with PLAN_LOCK:
        history = [dict(h) for h in PLAN_HISTORY]
    with SESSION_LOCK:
        sess = dict(SESSION)
    res = sess.get("resolution")
    if isinstance(res, tuple):
        sess["resolution"] = list(res)
    return {"history": history, "session": sess}


def _restore_server_state(state):
    state = state or {}
    history = state.get("history") or []
    with PLAN_LOCK:
        PLAN_HISTORY.clear()
        for h in history:
            if isinstance(h, dict) and h.get("role") in ("user", "assistant"):
                PLAN_HISTORY.append({"role": h["role"], "content": str(h.get("content") or "")})
    sess = state.get("session") or {}
    with SESSION_LOCK:
        SESSION["image_prompt"] = sess.get("image_prompt")
        SESSION["video_prompt"] = sess.get("video_prompt")
        SESSION["mode_override"] = sess.get("mode_override")
        SESSION["length_frames"] = sess.get("length_frames")
        res = sess.get("resolution")
        SESSION["resolution"] = tuple(res) if isinstance(res, (list, tuple)) and len(res) == 2 else None



# Per-session conversation history for planning mode (single-user local UI).
PLAN_HISTORY = []
PLAN_LOCK = threading.Lock()


class ChatHandler(BaseHTTPRequestHandler):
    server_version = "H3Chat/1.0"

    # ---- helpers -----------------------------------------------------

    def _comfy(self, method, path, body=None, timeout=120):
        url = self.server.comfy_base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), r.headers.get("Content-Type", "")

    def _json(self, code, obj):
        payload = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _html(self, code, text):
        data = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        # UI はサーバー内蔵の生 JS なので、ブラウザに古い版をキャッシュさせない
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _proxy_error(self, e):
        if isinstance(e, urllib.error.HTTPError):
            return f"ComfyUI HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
        return f"ComfyUI に接続できません: {e}"

    # ---- routes ------------------------------------------------------

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/" or parsed.path == "/index.html":
            self._html(200, HTML)
        elif parsed.path == "/api/queue":
            try:
                _, raw, _ = self._comfy("GET", "/queue", timeout=10)
                q = json.loads(raw)
                self._json(200, {
                    "running": len(q.get("queue_running", [])),
                    "pending": len(q.get("queue_pending", [])),
                })
            except Exception as e:
                self._json(503, {"error": self._proxy_error(e)})
        elif parsed.path.startswith("/api/status/"):
            pid = parsed.path.rsplit("/", 1)[-1]
            self._status(pid)
        elif parsed.path == "/api/view":
            self._view(parsed.query)
        elif parsed.path == "/api/refimages":
            self._json(200, {"images": self._ref_images()})
        elif parsed.path == "/api/refimg":
            self._refimg(parsed.query)
        elif parsed.path == "/api/plan-models":
            self._plan_models()
        elif parsed.path == "/api/characters":
            self._json(200, {"characters": _load_characters()})
        elif parsed.path == "/api/sessions":
            self._sessions_list()
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/generate":
            self._generate(parsed)
        elif parsed.path == "/api/kimg":
            self._kimg(parsed)
        elif parsed.path == "/api/plan":
            self._plan(parsed)
        elif parsed.path == "/api/audio":
            self._audio_propose(parsed)
        elif parsed.path == "/api/cancel":
            self._cancel(parsed)
        elif parsed.path == "/api/plan-settings":
            self._plan_settings(parsed)
        elif parsed.path == "/api/plan-model":
            self._plan_model_select(parsed)
        elif parsed.path == "/api/sessions/save":
            self._sessions_save(parsed)
        elif parsed.path == "/api/sessions/switch":
            self._sessions_switch(parsed)
        elif parsed.path == "/api/sessions/delete":
            self._sessions_delete(parsed)
        elif parsed.path == "/api/extend":
            self._extend(parsed)
        elif parsed.path == "/api/concat":
            self._concat(parsed)
        elif parsed.path == "/api/upscale":
            self._upscale(parsed)
        elif parsed.path == "/api/shutdown":
            self._shutdown(parsed)
        else:
            self._json(404, {"error": "not found"})

    def _cancel(self, parsed):
        """Cancel a stuck/running ComfyUI job.

        Sends /interrupt (stops the current executor, which is what frees a
        queue item stuck in "running") and best-effort deletes the pending
        item from the queue by prompt id.
        """
        try:
            req = self._read_json_body()
        except Exception:
            req = {}
        pid = (req or {}).get("prompt_id")
        out = {"ok": True, "interrupted": False, "deleted": False}
        try:
            self._comfy("POST", "/interrupt", {}, timeout=10)
            out["interrupted"] = True
        except Exception:
            pass
        if pid:
            try:
                self._comfy("POST", "/queue", {"delete": [pid]}, timeout=10)
                out["deleted"] = True
            except Exception:
                pass
        self._json(200, out)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 1_000_000:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def _plan_settings(self, parsed):
        """Update planner launch parameters (KV compression, FA, reasoning)."""
        global PLAN_SETTINGS
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        allowed_ctk = {"q8_0", "q4_0", "f16", "none"}
        allowed_reasoning = {"off", "low", "medium", "xhigh"}
        if "ctk" in req and req["ctk"] in allowed_ctk:
            PLAN_SETTINGS["ctk"] = req["ctk"]
        if "ctv" in req and req["ctv"] in allowed_ctk:
            PLAN_SETTINGS["ctv"] = req["ctv"]
        if "fa" in req:
            PLAN_SETTINGS["fa"] = bool(req["fa"])
        if "reasoning_effort" in req and req["reasoning_effort"] in allowed_reasoning:
            PLAN_SETTINGS["reasoning_effort"] = req["reasoning_effort"]
        if "reasoning_budget" in req:
            try:
                PLAN_SETTINGS["reasoning_budget"] = max(0, min(32768, int(req["reasoning_budget"])))
            except (ValueError, TypeError):
                pass
        self._json(200, PLAN_SETTINGS)

    def _plan_models(self):
        """List installed planning-LLM candidates + the current selection."""
        self._json(200, {
            "current": {
                "path": planllm.PLAN_MODEL_PATH, "mmproj": planllm.PLAN_MMPROJ_PATH,
                "gpu": planllm.PLAN_GPU, "vision": planllm.PLAN_HAS_VISION, "port": planllm.PLAN_PORT,
                "bin": planllm.PLAN_SERVER_BIN,
            },
            "running": _plan_alive(),
            "external": bool(self.server.plan_url),
            "models": scan_plan_models(),
        })

    def _plan_model_select(self, parsed):
        """Switch the planning LLM model at runtime (UI dropdown)."""
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        ok, err = switch_plan_model(req.get("path"), req.get("mmproj"), req.get("gpu"))
        if not ok:
            self._json(400, {"error": err})
            return
        resp = {
            "ok": True,
            "current": {
                "path": planllm.PLAN_MODEL_PATH, "mmproj": planllm.PLAN_MMPROJ_PATH,
                "gpu": planllm.PLAN_GPU, "vision": planllm.PLAN_HAS_VISION, "port": planllm.PLAN_PORT,
                "bin": planllm.PLAN_SERVER_BIN,
            },
            "note": "切り替えました。次のメッセージから新しいモデルで起動します。",
        }
        if self.server.plan_url:
            # 選択を優先: 外部エンドポイントを解除して自前起動に切り替える。
            # 外部プランナー（--plan-url が指す llama-server）を停止してから
            # 次メッセージで選択モデルを planllm.PLAN_PORT に起動する。
            try:
                ext_port = int(urllib.parse.urlparse(self.server.plan_url).port or planllm.PLAN_PORT)
            except Exception:
                ext_port = planllm.PLAN_PORT
            self.server.plan_url = None
            ChatHandler._kill_port(ext_port)
            resp["note"] = ("外部エンドポイントを停止し、選択したモデルで自前起動に切り替えました。"
                            "次のメッセージから新しいモデルで起動します。")
        self._json(200, resp)

    def _generate(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        mode = req.get("mode", "quick")
        # チャットで「高画質で/長めに」等と指示していたら、その上書きを優先する
        eff_mode = SESSION.get("mode_override") or mode
        dit = req.get("dit", "default")
        text = (req.get("text") or "").strip()
        ref = req.get("ref") is True
        image_fn = req.get("image") or None
        # 参照画像の複数指定: 新クライアントは images[]（順序付き・1枚目が主参照）
        # を送る。旧クライアントは image だけなので 1 要素リストとして扱う。
        images = req.get("images") or ([image_fn] if image_fn else [])
        if not isinstance(images, list) or not all(isinstance(x, str) and x for x in images):
            self._json(400, {"error": "images はパスのリストで指定してください"})
            return
        if len(images) > MAX_REF_IMAGES:
            self._json(400, {"error": f"参照画像は最大 {MAX_REF_IMAGES} 枚までです（MiniMax H3 の上限）"})
            return
        image_fn = images[0] if images else None
        # 画像の使い方: "first" = 先頭フレーム固定 (I2V)、"last" = 最終フレーム固定、
        # "ref" = 参照画像（R2V・同一キャラ維持）。旧クライアントは送らないので
        # その場合は従来どおり R2V になる。
        image_use = req.get("image_use") or "ref"
        if image_use not in ("first", "last", "ref"):
            self._json(400, {"error": "unknown image_use: " + str(image_use)})
            return
        # 参照画像の解像度: "match"（既定・生成分解能に合わせる）/ "max"
        # （短辺 2048px・なりきり精度最高だが毎ステップの参照トークンが
        # 大きくなり数倍遅い）。R2V 経路のみで意味を持つ。
        ref_size = req.get("ref_size") or "match"
        if ref_size not in ("match", "max"):
            self._json(400, {"error": "unknown ref_size: " + str(ref_size)})
            return
        # キャラ固定: カードは 1 回だけ解決する（ピンなし = None で全経路が
        # 従来どおり動く）。
        card = get_character(req.get("char_id") or None)
        # Tier 2: R2V でユーザーが参照画像を 1 枚も選んでおらず、キャラに
        # 基準画像が登録してあればそれを既定参照に使う。ref_image_N への
        # 挿入や _stage_ref_image は既存経路をそのまま流用する。
        if card and ref and not images:
            char_refs = [p for p in (card.get("refImages") or [])
                         if isinstance(p, str) and p]
            if char_refs:
                images = char_refs[:MAX_REF_IMAGES]
                image_fn = images[0]
        # 画像が選択されているのに参照モード OFF のままでは、その画像は完全に
        # 無視され、テキストだけの無関係な動画が生成されていた（「女の子の
        # 参照画像を入れたのに車の動画になった」の根本原因）。ここで明示的に
        # 弾いて、ユーザーに選択を促す。
        if image_fn and not ref:
            self._json(400, {"error": "画像が選択されていますが「画像モード」が OFF です。選んだ画像を使うには ☑ 画像モード を ON にしてください（OFF のままでは画像は無視されます）。"})
            return
        audio = req.get("audio") or {}
        if mode not in WORKFLOWS or eff_mode not in WORKFLOWS:
            self._json(400, {"error": "unknown mode: " + mode})
            return
        if dit not in DITS:
            self._json(400, {"error": "unknown dit: " + dit})
            return
        if not text:
            self._json(400, {"error": "プロンプトが空です"})
            return

        # UI の音声・セリフ設定をプロンプトにマージ
        text += _audio_block(audio)
        if ref:
            # 画像を使った生成。image_use で 2 系統に分かれる:
            #  - first/last (I2V): 通常ワークフローの MiniMaxH3ImageToVideo に
            #    LoadImage を配線し、画像を動画の先頭/最終フレームとして固定する。
            #    「キー画像が動画の1フレーム目になる」という UI の約束はこちらで
            #    初めて実際に果たされる（R2V は同一キャラ参照だけでフレームは
            #    固定されない）。
            #  - ref (R2V): 確定したキー画像を参照画像（<Picture 1>）として使い、
            #    同一キャラを保つ。構図は自由。
            if not image_fn:
                self._json(400, {"error": "参照画像がありません（先に企画モードでキー画像を確定してください）"})
                return
            if image_use in ("first", "last"):
                try:
                    with open(WORKFLOWS[eff_mode], encoding="utf-8") as f:
                        wf = json.load(f)["prompt"]
                except Exception as e:
                    self._json(500, {"error": f"ワークフロー読み込み失敗: {e}"})
                    return
                try:
                    ref_name = self._stage_ref_image(image_fn)
                except Exception as e:
                    self._json(400, {"error": str(e)})
                    return
                wf[NODE_I2V_FRAME_IMAGE] = {
                    "class_type": "LoadImage",
                    "inputs": {"image": ref_name},
                    "_meta": {"title": "Load Key Frame"},
                }
                wf[NODE_PROMPT]["inputs"]["prompt"] = text
                frame_in = "first_frame" if image_use == "first" else "last_frame"
                wf[NODE_PROMPT]["inputs"][frame_in] = [NODE_I2V_FRAME_IMAGE, 0]
            else:
                try:
                    with open(R2V_WORKFLOWS[eff_mode], encoding="utf-8") as f:
                        wf = json.load(f)["prompt"]
                except Exception as e:
                    self._json(500, {"error": f"R2V ワークフロー読み込み失敗: {e}"})
                    return
                try:
                    ref_names = [self._stage_ref_image(fn) for fn in images]
                except Exception as e:
                    self._json(400, {"error": str(e)})
                    return
                wf[NODE_R2V_IMAGE]["inputs"]["image"] = ref_names[0]
                r2v_in = wf[NODE_R2V_PROMPT]["inputs"]
                # 2 枚目以降の参照画像: LoadImage ノードを追加して ref_image_N に
                # 配線する（Autogrow 入力・最大 9 枚）。プロンプトからは
                # <Picture 1>..<Picture N> で参照される。ワークフロー JSON は
                # フラットキー（ref_images.ref_image_0）とネスト辞書
                # （ref_images.ref_image_0）の両形式を持つため、両方に追記する。
                if len(ref_names) > 1:
                    next_id = max((int(k) for k in wf if k.isdigit()), default=0) + 1
                    for i, name in enumerate(ref_names[1:], start=1):
                        nid = str(next_id)
                        next_id += 1
                        wf[nid] = {
                            "class_type": "LoadImage",
                            "inputs": {"image": name},
                            "_meta": {"title": "Load Ref Image %d" % (i + 1)},
                        }
                        key = "ref_image_%d" % i
                        r2v_in["ref_images." + key] = [nid, 0]
                        r2v_in.setdefault("ref_images", {})[key] = [nid, 0]
                if ref_size == "max":
                    r2v_in["ref_image_size"] = "max"
                r2v_in["prompt"] = text + _r2v_tag_note(len(ref_names))
        else:
            try:
                with open(WORKFLOWS[eff_mode], encoding="utf-8") as f:
                    wf = json.load(f)["prompt"]
            except Exception as e:
                self._json(500, {"error": f"ワークフロー読み込み失敗: {e}"})
                return
            # T2V（参照画像なし直行）は画像から同一人物性を運べないため、
            # キャラ summary をプロンプト頭に機械前置きする。I2V / R2V は
            # 画像が人物を運ぶので触らない（余計なトークンを増やさない）。
            if card:
                text = char_summary_text(card) + ". " + text
            wf[NODE_PROMPT]["inputs"]["prompt"] = text
        # チャットで指示した長さ・解像度の上書きを反映。UI の「長さ」ドロップ
        # ダウン（req["length"]、秒）もここで受け取る。チャット指示がより具体的
        # なので SESSION 側を優先する。
        eff_frames = None
        if req.get("length"):
            try:
                eff_frames = _align_h3_frames(int(req["length"]) * 24)
            except Exception:
                pass
        if SESSION.get("length_frames"):
            eff_frames = SESSION["length_frames"]
        if eff_frames:
            for n in wf.values():
                ct = n.get("class_type")
                if ct in ("MiniMaxH3ImageToVideo", "MiniMaxH3ReferenceToVideo") and "length" in n.get("inputs", {}):
                    n["inputs"]["length"] = eff_frames
                # 音声VAEは「フレーム数/24」秒の音声を出力する（24fps前提の
                # タイムライン）。short系ワークフローは fps=12 で保存するため、
                # そのままだと映像だけが2倍に引き伸ばされて口の動きが半速になり、
                # 音声の途中で映像が余って後半が無音になる。秒数指定は実尺の
                # 指定なので、24fps保存に揃えて 映像の長さ==音声の長さ にする。
                if ct == "CreateVideo":
                    n["inputs"]["fps"] = 24
        if SESSION.get("resolution"):
            w_, h_ = SESSION["resolution"]
            for n in wf.values():
                if n.get("class_type") in ("MiniMaxH3ImageToVideo", "MiniMaxH3ReferenceToVideo"):
                    n["inputs"]["width"] = w_
                    n["inputs"]["height"] = h_
        # 詳細設定の品質チューニング（任意・未指定ならワークフロー既定値のまま）。
        # 実在するノードにだけ適用する: EasyCache / turbo LoRA は Spectrum 系の
        # fast ワークフローには存在せず、ref LoRA（なりきり用・強度調整済み）は
        # 変更しない。効かなかった指定は tune_ignored で返し、UI が「このモード
        # では効かない」を表示する（サイレントな無視をしない）。
        tune = req.get("tune") or {}
        if not isinstance(tune, dict):
            self._json(400, {"error": "tune はオブジェクトで指定してください"})
            return

        def _tune_num(key, lo, hi):
            if key not in tune or tune[key] in (None, ""):
                return None
            try:
                v = float(tune[key])
            except (TypeError, ValueError):
                raise ValueError(key)
            if not (lo <= v <= hi):
                raise ValueError(key)
            return v

        try:
            t_cache = _tune_num("easycache", 0.0, 1.0)
            t_lora = _tune_num("lora", 0.0, 2.0)
            t_crf = _tune_num("crf", 0.0, 51.0)
        except ValueError as bad:
            self._json(400, {"error": f"tune.{bad} の値が範囲外か数値ではありません"})
            return
        # キャラ固定（保証層）: ネガティブ タグを負プロンプト ノードに機械追記。
        # KSampler の negative リンクから汎用に特定するので I2V / R2V / T2V
        # すべてのワークフローでそのまま効く（negative ノードが無いだけの
        # ワークフローでは静かに無視される）。
        if card:
            _append_negative(wf, char_negative_text(card))
        classes = {n.get("class_type") for n in wf.values()}
        tune_ignored = []
        if t_cache is not None:
            if "EasyCache" in classes:
                for n in wf.values():
                    if n.get("class_type") == "EasyCache":
                        n["inputs"]["reuse_threshold"] = t_cache
            else:
                tune_ignored.append("EasyCache 閾値（このモードは EasyCache 非使用）")
        if t_lora is not None:
            applied = False
            for n in wf.values():
                ins = n.get("inputs", {})
                # turbo LoRA だけを対象にする（ref LoRA / 画像系 LoRA は対象外）
                if n.get("class_type") == "LoraLoaderModelOnly" and "turbo" in str(ins.get("lora_name", "")).lower():
                    ins["strength_model"] = t_lora
                    applied = True
            if not applied:
                tune_ignored.append("Turbo LoRA 強度（このモードは turbo LoRA 非使用）")
        if t_crf is not None:
            if "SaveVideo" in classes:
                for n in wf.values():
                    if n.get("class_type") == "SaveVideo":
                        # crf は codec DynamicCombo の re-encode 経路で効く
                        # （auto のままでは互換ストリームが再エンコードされない）。
                        n["inputs"]["codec"] = {
                            "codec": "h264",
                            "encoding": {"encoding": "re-encode", "crf": t_crf},
                        }
            else:
                tune_ignored.append("保存 crf（SaveVideo ノードなし）")
        # チャット指示（「高画質で/長めに/縦長で」）による上書きが有効なとき、
        # UI のモード/長さドロップダウンとは違う設定で生成されることがある。
        # 「知らない間に別の設定で生成されていた」を防ぐため、実際に効いている
        # 上書きを UI 側で表示できるようラベルにして返す。
        override_notes = []
        if SESSION.get("mode_override"):
            override_notes.append("モード→" + MODE_LABELS.get(eff_mode, eff_mode))
        if SESSION.get("length_frames"):
            override_notes.append("長さ 約" + str(max(1, round(SESSION["length_frames"] / 24))) + "秒")
        if SESSION.get("resolution"):
            ow, oh = SESSION["resolution"]
            override_notes.append("向き " + str(ow) + "x" + str(oh))
        override_label = "・".join(override_notes)
        wf[NODE_UNET]["inputs"]["unet_name"] = DITS[dit]
        wf[NODE_SEED]["inputs"]["seed"] = random.randint(0, 2**31 - 1)
        self.server.autostop.poke()
        # gpu27b planner: kill it so its 14GB leaves VRAM before the video
        # model loads (no-op for the CPU 4B planner).
        stop_plan_llm()
        if not self._ensure_comfy():
            self._json(502, {"error": "ComfyUI が起動していません（自動起動も失敗。詳細は %TEMP%\\h3_comfyui.log）"})
            return
        # Free stale models (e.g. Klein 9B) first so the H3 model has the
        # full VRAM - but only when nothing else is running, so we never
        # unload a model mid-generation.
        try:
            _, raw, _ = self._comfy("GET", "/queue", timeout=10)
            q = json.loads(raw)
            if not q.get("queue_running") and not q.get("queue_pending"):
                self._free_comfy()
        except Exception:
            pass
        try:
            _, raw, _ = self._comfy("POST", "/prompt", {"prompt": wf})
            pid = json.loads(raw)["prompt_id"]
            self.server.job_meta[pid] = {
                "mode": eff_mode, "start": time.time(), "kind": "video",
                "image_use": image_use if ref else "",
            }
            self._json(200, {"prompt_id": pid, "eff_mode": eff_mode, "override_label": override_label, "tune_ignored": tune_ignored})
        except Exception as e:
            self._json(502, {"error": self._proxy_error(e)})

    # ---- planning mode ----------------------------------------------

    def _plan(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        text = (req.get("text") or "").strip()
        stage = req.get("stage") or "chat"   # "chat" | "image" | "video"
        if text == "__RESET__":
            self._plan_reset()
            self._json(200, {"reset": True, "reply": "新しい企画を始めましょう。作りたい映像を教えてください。"})
            return
        if not text:
            self._json(400, {"error": "メッセージが空です"})
            return

        endpoint = self._plan_endpoint()
        if not endpoint:
            if planllm.PLAN_GPU and self._comfy_busy():
                self._json(503, {"error": "ComfyUI が生成中のため GPU 企画 LLM を起動できません。生成完了後に再度お送りください。"})
            else:
                self._json(503, {"error": "企画 LLM を起動できませんでした（モデルまたは llama-server が見つかりません）"})
            return
        self.server.autostop.poke()
        image = req.get("image") or None   # 確定したキー画像のファイル名（視覚入力）
        ref_start = bool(req.get("ref_start"))  # 参照モードからの動画相談開始フラグ
        if stage == "video" and text == "__CONFIRM_IMAGE__":
            # キー画像が確定: Klein 9B をアンロードして VRAM を解放してから
            # 企画 LLM に動画プロンプトを作らせる。
            self._free_comfy()
        tweak_note = ""
        if stage == "video" and text != "__CONFIRM_IMAGE__":
            # 画像確定後のチャットで「高画質/長め/縦長」等の指示をパラメータに反映
            tw = _parse_tweak(text)
            if tw:
                with SESSION_LOCK:
                    if tw.get("mode"):
                        SESSION["mode_override"] = tw["mode"]
                    if tw.get("length_frames"):
                        SESSION["length_frames"] = tw["length_frames"]
                    if tw.get("resolution"):
                        SESSION["resolution"] = tw["resolution"]
                tweak_note = "⚙ 設定を更新しました: " + tw["label"] + "（次の生成から反映）\n\n"
        # キャラ固定（認知層）: PLAN_SYSTEM は変更せず、ピン中のターンだけ
        # ユーザー文の頭に同一人物性の固定を 1 行前置きする。__RESET__ /
        # __CONFIRM_IMAGE__ などの内部コマンドには付けない。
        pinned_card = get_character(req.get("char_id") or None)
        if pinned_card and not text.startswith("__"):
            text = char_identity_prefix(pinned_card) + text
        try:
            reply, img_prompt, final_prompt, audio, thinking, final_prompt_ja, img_prompt_ja = self._plan_llm(text, endpoint, stage, image, ref_start=ref_start)
        except Exception as e:
            self._json(502, {"error": f"企画 LLM エラー: {e}"})
            return
        if final_prompt and not reply:
            reply = "動画プロンプトがまとまりました。下のボタンで生成できます。"
        if img_prompt and not reply:
            # 英語原文は足さない（動画側と同じく、日本語説明 + 折りたたみ英語で
            # 表示するため。泡に生の英語プロンプトを残さない）。
            reply = "キー画像のプロンプトがまとまりました。下のボタンで画像を生成できます。"
        self._json(200, {"reply": tweak_note + reply, "img_prompt": img_prompt, "img_prompt_ja": img_prompt_ja, "final_prompt": final_prompt, "final_prompt_ja": final_prompt_ja, "audio": audio, "thinking": thinking})

    def _plan_reset(self):
        global PLAN_HISTORY
        with PLAN_LOCK:
            PLAN_HISTORY.clear()
        with SESSION_LOCK:
            SESSION["image_prompt"] = None
            SESSION["video_prompt"] = None
            SESSION["mode_override"] = None
            SESSION["length_frames"] = None
            SESSION["resolution"] = None

    # ---- session history (sidebar) -----------------------------------

    def _sessions_list(self):
        with ACTIVE_SESSION_LOCK:
            if ACTIVE_SESSION["id"] is None and os.path.isdir(SESSIONS_DIR):
                # サーバー再起動後: 前回表示していたセッションを復元する
                ptr = _read_active_pointer()
                if ptr and _load_session_file(ptr):
                    ACTIVE_SESSION["id"] = ptr
            active = ACTIVE_SESSION["id"]
        doc = _load_session_file(active) if active else None
        self._json(200, {"active_id": active, "sessions": _list_sessions(), "active": doc})

    def _sessions_save(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        sid = req.get("id") or None
        messages = req.get("messages") or []
        ui = req.get("ui") or {}
        if not isinstance(messages, list) or len(messages) > 5000:
            self._json(400, {"error": "messages が不正です"})
            return
        clean = []
        for m in messages:
            if not isinstance(m, dict) or m.get("who") not in ("user", "bot"):
                continue
            html = m.get("html")
            if not isinstance(html, str):
                continue
            clean.append({"who": m["who"], "html": html})
        if sid is not None and not _session_path(sid):
            self._json(400, {"error": "セッション ID が不正です"})
            return
        if sid is None and not clean:
            # 空の新規チャットは保存しない（サイドバーを汚さない）
            self._json(200, {"id": None})
            return
        now = int(time.time())
        old = _load_session_file(sid) if sid else None
        if sid is None:
            sid = _new_session_id()
        doc = {
            "id": sid,
            "title": _session_title(clean),
            "created": (old or {}).get("created") or now,
            "updated": now,
            "messages": clean,
            "ui": ui if isinstance(ui, dict) else {},
            "server": _server_state_snapshot(),
        }
        if not _write_session_file(doc):
            self._json(500, {"error": "セッションの保存に失敗しました"})
            return
        with ACTIVE_SESSION_LOCK:
            ACTIVE_SESSION["id"] = sid
        _write_active_pointer(sid)
        self._json(200, {"id": sid, "title": doc["title"], "updated": now})

    def _sessions_switch(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        target = req.get("id") or None
        if target is not None:
            doc = _load_session_file(target)
            if not doc:
                self._json(404, {"error": "セッションが見つかりません"})
                return
            _restore_server_state(doc.get("server"))
            with ACTIVE_SESSION_LOCK:
                ACTIVE_SESSION["id"] = target
            _write_active_pointer(target)
            self._json(200, {"session": doc})
            return
        # id なし = 新しい企画（旧セッションはクライアントが直前に保存済み）
        self._plan_reset()
        with ACTIVE_SESSION_LOCK:
            ACTIVE_SESSION["id"] = None
        _write_active_pointer(None)
        self._json(200, {"session": None})

    def _sessions_delete(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        sid = req.get("id") or ""
        path = _session_path(sid)
        if not path:
            self._json(400, {"error": "セッション ID が不正です"})
            return
        try:
            if os.path.isfile(path):
                os.remove(path)
        except OSError as e:
            self._json(500, {"error": f"削除に失敗しました: {e}"})
            return
        with ACTIVE_SESSION_LOCK:
            was_active = ACTIVE_SESSION["id"] == sid
            if was_active:
                ACTIVE_SESSION["id"] = None
        if was_active:
            self._plan_reset()
            _write_active_pointer(None)
        self._json(200, {"ok": True, "was_active": was_active})


    def _audio_propose(self, parsed):
        """One-shot '🎙 自動で考える': ask the planning LLM for a voice/dialogue/
        sfx/music proposal for the given concept, without touching plan history."""
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        text = (req.get("text") or "").strip()
        if not text:
            self._json(400, {"error": "プロンプトが空です"})
            return
        endpoint = self._plan_endpoint()
        if not endpoint:
            if planllm.PLAN_GPU and self._comfy_busy():
                self._json(503, {"error": "ComfyUI が生成中のため GPU 企画 LLM を起動できません。生成完了後に再度お送りください。"})
            else:
                self._json(503, {"error": "企画 LLM を起動できませんでした"})
            return
        self.server.autostop.poke()
        body = json.dumps({
            "messages": [
                {"role": "system", "content": AUDIO_SYSTEM},
                {"role": "user", "content": "映像企画: " + text},
            ],
            "max_tokens": 600,
            "temperature": 0.7,
        }).encode("utf-8")
        req_ = urllib.request.Request(
            endpoint.rstrip("/") + "/v1/chat/completions",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req_, timeout=120) as r:
                d = json.load(r)
            content = d["choices"][0]["message"].get("content") or ""
            audio = _parse_audio_set(content)
            self._json(200, {"audio": audio, "reply": content[:500]})
        except Exception as e:
            self._json(502, {"error": f"企画 LLM エラー: {e}"})

    def _plan_endpoint(self, probe=True):
        """Return the planning-LLM base URL to use.

        Prefers the configured --plan-url when it is actually alive; if that
        endpoint is dead, fall through to the auto path (planllm.PLAN_PORT / GPU 8191)
        so a leftover --plan-url 8190 does not pin the UI to a corpse while the
        GPU planner is running on 8191.
        """
        if self.server.plan_url and _url_alive(self.server.plan_url):
            return self.server.plan_url
        if probe:
            # The gpu27b planner needs ~14GB: make sure ComfyUI is not holding
            # it before the load starts. When a generation is in flight we can
            # neither unload its models (it would break the run) nor fit the
            # planner beside them, so refuse until the queue drains.
            if planllm.PLAN_GPU and not _plan_alive():
                if self._comfy_busy():
                    print("h3-chat: ComfyUI 生成中のため GPU 企画 LLM の起動を延期します")
                    return None
                self._free_comfy()
            # Give a first-request spawn a short window to come up. The gpu27b
            # planner cold-loads in ~10s but gets a longer window for safety.
            if ensure_plan_llm(wait_seconds=90 if planllm.PLAN_GPU else 30):
                return planllm.PLAN_URL_DEFAULT
            return None
        return planllm.PLAN_URL_DEFAULT if _plan_alive() else None

    def _attach_plan_image(self, text, image_fn, note=None):
        """Attach image_fn as a base64 image part so a vision-capable planning
        LLM can see it. Returns text unchanged when vision is unavailable or
        the file cannot be read. image_fn may be a bare filename (resolved via
        local_files) or an absolute path (reference-image picker). When `note`
        is given it is prepended to the text part (only if the image actually
        attaches) so the planner knows what the image is for."""
        if not (image_fn and planllm.PLAN_HAS_VISION):
            return text
        abspath = self.server.local_files.get(image_fn) or image_fn
        if not os.path.isfile(abspath):
            return text
        try:
            with open(abspath, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
        except Exception:
            return text
        ext = os.path.splitext(image_fn)[1].lower().lstrip(".")
        if ext == "jpg":
            ext = "jpeg"
        if ext not in ("png", "jpeg", "webp"):
            ext = "png"
        if note:
            text = note + "\n" + text
        return [
            {"type": "text", "text": text},
            {"type": "image_url", "image_url": {"url": f"data:image/{ext};base64,{b64}"}},
        ]

    def _plan_llm(self, user_text, endpoint, stage="chat", image_fn=None, timeout=300, ref_start=False):
        """Send the message (plus history) to the planning LLM.

        Returns (reply_text, img_prompt, final_prompt, audio, thinking,
        final_prompt_ja, img_prompt_ja).
        - stage "chat"/"image": the model settles on the key-image prompt
          ([IMG_PROMPT] tags, or a tool-call prompt argument).
        - stage "video": the model settles on the final video prompt
          ([FINAL_PROMPT] tags, or a tool call whose prompt= is the finished
          prompt). When image_fn is given (the confirmed key image), it is
          attached as a real image so a vision-capable planning LLM can see it.
        """
        global PLAN_HISTORY
        content = user_text
        # 元テキストがキー画像確定(__CONFIRM_IMAGE__)かどうかを、書き替え前に確定しておく
        # （後段の ref_start 分岐が「書き替え済みテキスト」を見て誤発火しないように）。
        is_confirm = (stage == "video" and user_text == "__CONFIRM_IMAGE__")
        if is_confirm:
            with SESSION_LOCK:
                ip = SESSION.get("image_prompt") or ""
            user_text = (
                "キー画像を確定しました。添付した画像（または以下の画像プロンプト）は"
                "動画の1フレーム目として固定されて生成されます（先頭フレーム固定モード）。\n"
                "ここからは【第2段階: 動画の相談】です。いきなり [FINAL_PROMPT] は作らず、"
                "まずこの画像をどんな動画にするか（動き・カメラワーク・長さ・セリフ・音楽など）を"
                "1〜2個の質問でユーザーと相談してください。\n"
                f"画像プロンプト: {ip}"
            )
        if stage == "video" and ref_start and not is_confirm:
            # 参照モードからの動画相談開始。キー画像確定(__CONFIRM_IMAGE__)と
            # 違い、添付画像は「1フレーム目」ではなく「同一キャラを保つ
            # 参照画像」。内容を決めずに生成へ直行しないよう、まず相談させる。
            original = user_text
            user_text = (
                "ユーザーが参照画像を指定して動画を作りたいと言っています。"
                "添付の画像がその参照画像です（見える場合は被写体・外見・服装・"
                "雰囲気を確認してください）。この参照画像の外見を維持した同一キャラで動画を作ります。\n"
                "ここからは【動画の内容の相談】です。いきなり [FINAL_PROMPT] は作らず、"
                f"ユーザーの希望「{original}」を踏まえつつ、"
                "この参照画像をどんな動画にするか（動き・カメラワーク・長さ・セリフ・音楽など）を"
                "1〜2個の質問でユーザーと相談してください。"
            )
        # multimodal: attach the image (base64) on every turn where one is
        # available — the confirmed key image, or the reference image the user
        # picked via 🗂 — so the planner can see it while planning/revising,
        # not only after confirmation. Planners without a vision projector
        # (planllm.PLAN_HAS_VISION false) get the prompt text only.
        ref_note = None
        if image_fn and not is_confirm:
            if stage in ("chat", "image"):
                ref_note = (
                    "【添付画像】ユーザーが指定した参照画像です。この画像の被写体・外見・"
                    "服装・雰囲気を企画のベースにしてください（同一キャラ・同一ルックを維持）。"
                    "ユーザーの指示と矛盾しない限り、参照画像の内容を [IMG_PROMPT] に反映すること。"
                )
            elif stage == "video" and ref_start:
                ref_note = (
                    "【添付画像】ユーザーが指定した参照画像です。この画像の被写体・外見・"
                    "服装・雰囲気を維持した同一キャラで動画を作ります。"
                    "相談や [FINAL_PROMPT] 作成時はこの外見を基準にしてください。"
                )
        content = self._attach_plan_image(user_text, image_fn, note=ref_note)
        with PLAN_LOCK:
            PLAN_HISTORY.append({"role": "user", "content": content})
            # keep the context bounded; system prompt always first. 6 turns is
            # enough for the 2-stage flow and halves prompt-processing time
            # (~36 t/s on CPU: every extra turn costs real seconds of latency).
            kb_note = _nsfw_kb_system_note(user_text)
            system_content = PLAN_SYSTEM if not kb_note else PLAN_SYSTEM + "\n\n" + kb_note
            history = [{"role": "system", "content": system_content}] + PLAN_HISTORY[-6:]
            # An image costs ~1024+ tokens every time it appears. The planner
            # only needs to see it once, so keep the image part in the newest
            # user turn only and downgrade older copies to a text placeholder
            # (otherwise repeated turns with the same reference image bloat
            # the 8192 context and can overflow it).
            last_user_idx = max(
                (i for i, m in enumerate(history) if m["role"] == "user"),
                default=-1,
            )
            for i, m in enumerate(history):
                if i != last_user_idx and isinstance(m.get("content"), list):
                    m = dict(m)
                    m["content"] = [
                        p if p.get("type") == "text"
                        else {"type": "text", "text": "[画像: 直近のターンに添付済み]"}
                        for p in m["content"]
                    ]
                    history[i] = m
            body = json.dumps({
                "messages": history,
                # 3072: with medium reasoning effort, thinking is ~312 tokens
                # (median) with a 1536 safety cap, leaving ~1536 for the answer
                # — plenty for [FINAL_PROMPT] blocks (~500-800 tokens).
                "max_tokens": 3072,
                "temperature": 0.8,
            }).encode("utf-8")
            req = urllib.request.Request(
                endpoint.rstrip("/") + "/v1/chat/completions",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=timeout) as r:
                d = json.load(r)
            msg = d["choices"][0]["message"]
            content = msg.get("content") or ""
            # Medium reasoning: server returns a short thinking block
            # (~312 tokens median); show it in the UI as a collapsible trace.
            thinking = (msg.get("reasoning_content") or "").strip()
            # some reasoning models put the text in reasoning_content
            if not content.strip():
                content = msg.get("reasoning_content") or ""
                thinking = ""
            reply = _clean_plan_reply(content)
            audio = _parse_audio_set(reply)
            if audio:
                # don't show the raw tag block in the chat bubble
                reply = AUDIO_SET_RE.sub("", reply)
                reply = "\n".join(line.rstrip() for line in reply.splitlines() if line.strip())
            img_prompt = None
            final_prompt = None
            final_prompt_ja = None
            img_prompt_ja = None
            if stage == "video":
                final_prompt = _best_tag_match(FINAL_RE, reply)
                if not final_prompt:
                    final_prompt = _unclosed_tag(reply, "FINAL_PROMPT")
                if not final_prompt:
                    final_prompt = _tool_prompt(content)
                # NOTE: 相談中に「プロンプトっぽい英語」が返ってきても、明示的な
                # [FINAL_PROMPT] タグ（またはツール呼び出し）がなければ確定プロンプト
                # にしない。これで「どんな動画にするか決めずにプロンプトが出る」のを防ぐ。
            else:
                img_prompt = _best_tag_match(IMG_FINAL_RE, reply)
                if not img_prompt:
                    img_prompt = _best_tag_match(FINAL_RE, reply)
                if not img_prompt:
                    img_prompt = _unclosed_tag(reply, "IMG_PROMPT")
                if not img_prompt:
                    img_prompt = _tool_prompt(content)
                if not img_prompt and _looks_like_final(reply):
                    img_prompt = reply
            # a real prompt is never a few characters; discard garbage matches
            # (e.g. the model quoting the tag names inside an explanation)
            if img_prompt and len(img_prompt) < 15:
                img_prompt = None
            if final_prompt and len(final_prompt) < 15:
                final_prompt = None
            if img_prompt:
                img_prompt = _strip_gen_params(img_prompt)
                # GenatomyFixer 用に NSFW プロンプトの先頭に n5fw, を自動付与
                img_prompt = _inject_n5fw(img_prompt)
                # スマホ写真トリガー句の保証 + 人数タグ重複の排除 (10パターン実測で
                # opener 欠落 2/10・1girl 重複 1/10 だったので機械保証にする)
                img_prompt = _enforce_opener(img_prompt)
                img_prompt = _dedup_person_tags(img_prompt)
                # 未クローズ抽出の後尾に次タグ名 ([IMG_PROMPT_JA] 等) が
                # くっついてくることがある (V1 実測) ので落とす
                img_prompt = re.sub(r"\s*\[/?[A-Z_]+\]\s*$", "", img_prompt).rstrip()
            if final_prompt:
                final_prompt = _strip_gen_params(final_prompt)
            # 動画プロンプトの日本語説明（[FINAL_PROMPT_JA]、[FINAL_PROMPT] と対）を
            # 取り出し、英語ブロックごと reply から除く（チャット泡に生のタグ・英語を
            # 残さず、UI 側で「こんな映像になります」+ 折りたたみ英語原文として表示）。
            if stage == "video" and final_prompt:
                final_prompt_ja = _best_tag_match(FINAL_JA_RE, reply)
                if final_prompt_ja:
                    reply = FINAL_JA_RE.sub("", reply)
                reply = FINAL_RE.sub("", reply)
                reply = "\n".join(line.rstrip() for line in reply.splitlines() if line.strip())
            if img_prompt:
                # キー画像も同様に: 日本語説明（[IMG_PROMPT_JA]）を取り出し、英語
                # ブロックごと reply から除く（UI は「こんな画像になります」+
                # 折りたたみ英語原文）。タグが閉じずに _unclosed_tag 等の
                # フォールバックで抽出された場合は対が無いため何も除去されない。
                img_prompt_ja = _best_tag_match(IMG_JA_RE, reply)
                if img_prompt_ja:
                    reply = IMG_JA_RE.sub("", reply)
                reply = IMG_FINAL_RE.sub("", reply)
                reply = FINAL_RE.sub("", reply)
                reply = "\n".join(line.rstrip() for line in reply.splitlines() if line.strip())

            if img_prompt:
                with SESSION_LOCK:
                    SESSION["image_prompt"] = img_prompt
            if final_prompt:
                with SESSION_LOCK:
                    SESSION["video_prompt"] = final_prompt
            # keep a non-empty assistant turn in the history so follow-up
            # messages have context (a tool-call reply becomes its prompt text)
            history_reply = reply or final_prompt or img_prompt or "（企画案）"
            PLAN_HISTORY.append({"role": "assistant", "content": history_reply})
            return reply, img_prompt, final_prompt, audio, thinking, final_prompt_ja, img_prompt_ja

    # ---- R2V reference image ----------------------------------------

    def _stage_ref_image(self, image_fn):
        """Copy the confirmed key image (ComfyUI output/) into ComfyUI input/ so
        LoadImage can read it, and return the input-relative filename."""
        comfy_root = os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI")
        src = self.server.local_files.get(image_fn) or image_fn
        if not os.path.isfile(src):
            raise ValueError("参照画像が見つかりません: " + image_fn)
        in_dir = os.path.join(comfy_root, "input")
        os.makedirs(in_dir, exist_ok=True)
        name = "h3_ref_{}_{}".format(int(time.time()), os.path.basename(image_fn))
        shutil.copy2(src, os.path.join(in_dir, name))
        return name

    def _resolve_output_file(self, fn):
        """Resolve a video filename from ComfyUI output/ to an absolute path.

        Returns None for anything that is not a plain filename inside output/
        (path traversal defense) or does not exist.
        """
        if not fn or not isinstance(fn, str) or len(fn) > 200:
            return None
        if os.sep in fn or "/" in fn or fn.startswith(".") or "\x00" in fn:
            return None
        allowed = os.path.realpath(os.path.join(_comfy_root(), "output"))
        cand = self.server.local_files.get(fn) or os.path.join(_comfy_root(), "output", fn)
        real = os.path.realpath(cand)
        if not real.startswith(allowed + os.sep):
            return None
        return real if os.path.isfile(real) else None

    # ---- 動画の続き / 結合 / アップスケール ------------------------------

    def _extend(self, parsed):
        """完成動画の最後の1フレームを抜き出して次の生成の first_frame にする。

        クライアントは返された画像を参照画像（先頭フレーム固定）としてセットし、
        企画 LLM と「続きの内容」を相談してから生成する。
        """
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        src = self._resolve_output_file((req or {}).get("filename"))
        if not src:
            self._json(404, {"error": "動画が見つかりません（すでに削除された可能性があります）"})
            return
        try:
            name = _extract_last_frame(src)
        except Exception as e:
            self._json(500, {"error": f"最後のフレームの抜き出しに失敗しました: {e}"})
            return
        # 抜き出し画像は input/ に置かれる。後続の /api/plan（企画 LLM の視覚
        # 入力）と /api/generate（_stage_ref_image）は裸のファイル名を
        # local_files 経由で解決するため、ここに絶対パスを登録しておく。
        self.server.local_files[name] = os.path.join(_comfy_root(), "input", name)
        self._json(200, {"image": name})

    def _concat(self, parsed):
        """複数セグメントを 1 本の mp4 に結合する（PyAV・24fps・h264 再エンコード）。"""
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        files = (req or {}).get("files")
        if not isinstance(files, list) or not (2 <= len(files) <= 20):
            self._json(400, {"error": "files は 2〜20 本の動画リストで指定してください"})
            return
        paths = []
        for fn in files:
            p = self._resolve_output_file(fn)
            if not p:
                self._json(404, {"error": "動画が見つかりません: " + str(fn)})
                return
            paths.append(p)
        try:
            name = _concat_videos(paths)
        except ValueError as e:
            self._json(400, {"error": str(e)})
            return
        except Exception as e:
            self._json(500, {"error": f"結合に失敗しました: {e}"})
            return
        abspath = os.path.join(_comfy_root(), "output", name)
        self.server.local_files[name] = abspath
        self._json(200, {"filename": name, "path": abspath})

    def _upscale(self, parsed):
        """完成動画を RealESRGAN x4 で高解像度化（2x/4x）して保存する。"""
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        scale = (req or {}).get("scale") or 2
        if scale not in (2, 4):
            self._json(400, {"error": "scale は 2 か 4 で指定してください"})
            return
        src = self._resolve_output_file((req or {}).get("filename"))
        if not src:
            self._json(404, {"error": "動画が見つかりません（すでに削除された可能性があります）"})
            return
        model_path = os.path.join(_comfy_root(), "models", "upscale_models", UPSCALE_MODEL_NAME)
        if not os.path.isfile(model_path):
            self._json(503, {"error": f"アップスケーラーモデルがありません: models/upscale_models/{UPSCALE_MODEL_NAME}"})
            return
        # LoadVideo は input/ からしか読めないのでステージングする
        in_dir = os.path.join(_comfy_root(), "input")
        os.makedirs(in_dir, exist_ok=True)
        staged = "h3_up_{}_{}".format(int(time.time()), os.path.basename(src))
        try:
            shutil.copy2(src, os.path.join(in_dir, staged))
            w, h = _video_size(src)
        except Exception as e:
            self._json(500, {"error": f"動画の読み取りに失敗しました: {e}"})
            return
        try:
            with open(UPSCALE_WORKFLOW, encoding="utf-8") as f:
                wf = json.load(f)["prompt"]
        except Exception as e:
            self._json(500, {"error": f"ワークフロー読み込み失敗: {e}"})
            return
        wf[NODE_UP_LOADVIDEO]["inputs"]["file"] = staged
        wf[NODE_UP_SCALE]["inputs"]["width"] = w * scale
        wf[NODE_UP_SCALE]["inputs"]["height"] = h * scale
        self.server.autostop.poke()
        stop_plan_llm()
        if not self._ensure_comfy():
            self._json(502, {"error": "ComfyUI が起動していません（自動起動も失敗。詳細は %TEMP%\\h3_comfyui.log）"})
            return
        try:
            _, raw, _ = self._comfy("GET", "/queue", timeout=10)
            q = json.loads(raw)
            if not q.get("queue_running") and not q.get("queue_pending"):
                self._free_comfy()
        except Exception:
            pass
        try:
            _, raw, _ = self._comfy("POST", "/prompt", {"prompt": wf})
            pid = json.loads(raw)["prompt_id"]
            self.server.job_meta[pid] = {"mode": "upscale", "start": time.time(), "kind": "upscale"}
            self._json(200, {"prompt_id": pid, "scale": scale})
        except Exception as e:
            self._json(502, {"error": self._proxy_error(e)})

    REF_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".gif")

    def _ref_images(self):
        """List images on disk (ComfyUI output/ and input/) so the UI can pick a
        reference image directly without a fresh plan-mode confirmation."""
        comfy_root = os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI")
        out = []
        for sub, kind in (("output", "output"), ("input", "input")):
            d = os.path.join(comfy_root, sub)
            if not os.path.isdir(d):
                continue
            for root, _, files in os.walk(d):
                rel = os.path.relpath(root, d)
                for fn in sorted(files, key=str.lower):
                    if not fn.lower().endswith(self.REF_IMAGE_EXTS):
                        continue
                    p = os.path.join(root, fn)
                    out.append({
                        "path": p,
                        "name": fn,
                        "dir": kind + (("/" + rel.replace("\\", "/")) if rel != "." else ""),
                    })
        return out

    def _refimg(self, query):
        """Serve a reference image directly from disk by absolute path
        (allowlisted to ComfyUI output/ and input/)."""
        path = urllib.parse.parse_qs(query).get("path", [""])[0]
        if not path:
            self._json(400, {"error": "missing path"})
            return
        comfy_root = os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI")
        allowed = [os.path.realpath(os.path.join(comfy_root, s)) for s in ("output", "input")]
        real = os.path.realpath(path)
        if not any(real == a or real.startswith(a + os.sep) for a in allowed):
            self._json(403, {"error": "path not allowed"})
            return
        if not os.path.isfile(real):
            self._json(404, {"error": "file not found"})
            return
        low = real.lower()
        if low.endswith(".png"):
            ctype = "image/png"
        elif low.endswith(".gif"):
            ctype = "image/gif"
        elif low.endswith(".webp"):
            ctype = "image/webp"
        elif low.endswith((".jpg", ".jpeg")):
            ctype = "image/jpeg"
        else:
            ctype = "application/octet-stream"
        try:
            with open(real, "rb") as f:
                data = f.read()
        except Exception as e:
            self._json(502, {"error": f"read failed: {e}"})
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # ---- Key image (kimg / qimg) -----------------------------------

    def _kimg(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        text = (req.get("text") or "").strip()
        if not text:
            self._json(400, {"error": "画像プロンプトが空です"})
            return

        engine = req.get("engine") or "kimg"
        eng = IMG_ENGINES.get(engine)
        if not eng:
            self._json(400, {"error": "unknown image engine: " + engine})
            return
        card = get_character(req.get("char_id") or None)
        dw, dh = eng["default_size"]
        try:
            width = max(256, min(int(req.get("width") or dw), 1536))
            height = max(256, min(int(req.get("height") or dh), 1536))
        except Exception:
            width, height = dw, dh
        try:
            with open(eng["workflow"], encoding="utf-8") as f:
                wf = json.load(f)["prompt"]
        except Exception as e:
            self._json(500, {"error": f"{eng['label']} ワークフロー読み込み失敗: {e}"})
            return
        wf[eng["prompt"]]["inputs"]["text"] = text
        wf[eng["latent"]]["inputs"]["width"] = width
        wf[eng["latent"]]["inputs"]["height"] = height
        wf[eng["latent"]]["inputs"]["batch_size"] = eng.get("batch_size", 1)
        wf[eng["seed"]]["inputs"]["seed"] = random.randint(0, 2**31 - 1)
        # キャラ固定（保証層）: negative 追記・LoRA 挿入・seed 固定を機械適用。
        # 企画 LLM が summary を書き忘れても、ここで人物の輪郭設定だけは届く。
        char_applied = []
        if card:
            if _append_negative(wf, char_negative_text(card)):
                char_applied.append("negative")
            if _apply_char_loras(wf, (card.get("lora") or {}).get(engine) or []):
                char_applied.append("LoRA")
            char_seed = card.get("seed")
            if isinstance(char_seed, int) and not isinstance(char_seed, bool):
                wf[eng["seed"]]["inputs"]["seed"] = char_seed % (2**31 - 1)
                char_applied.append("seed固定")
        rl = eng.get("random_lora")
        if rl:
            try:
                bw = req.get("bodyweight")
                strength = float(bw) if bw is not None else random.uniform(rl["low"], rl["high"])
                strength = max(-4.0, min(4.0, strength))
                wf[rl["node"]]["inputs"]["strength_model"] = round(strength, 2)
                char_applied.append(f"体型スライダー{strength:+.1f}")
            except Exception:
                pass
        self.server.autostop.poke()
        # gpu27b planner: free its VRAM before the image model loads.
        stop_plan_llm()
        if not self._ensure_comfy():
            self._json(502, {"error": "ComfyUI が起動していません（自動起動も失敗。詳細は %TEMP%\\h3_comfyui.log）"})
            return
        self._free_comfy()
        try:
            _, raw, _ = self._comfy("POST", "/prompt", {"prompt": wf})
            pid = json.loads(raw)["prompt_id"]
            self.server.job_meta[pid] = {"mode": engine, "start": time.time(), "kind": "image"}
            self._json(200, {"prompt_id": pid, "char_applied": char_applied})
        except Exception as e:
            self._json(502, {"error": self._proxy_error(e)})

    # ---- shutdown / VRAM ---------------------------------------------

    def _free_comfy(self):
        """Unload every model from VRAM (used between key-image engine and H3)."""
        try:
            self._comfy("POST", "/free", {"unload_models": True, "free_memory": True}, timeout=15)
        except Exception:
            pass

    def _comfy_busy(self):
        """True when a ComfyUI generation is queued or running."""
        try:
            _, raw, _ = self._comfy("GET", "/queue", timeout=10)
            q = json.loads(raw)
            return bool(q.get("queue_running") or q.get("queue_pending"))
        except Exception:
            return False

    def _ensure_comfy(self, wait_seconds=120):
        r"""ComfyUI が落ちていたら自動起動して応答を待つ（WinError 10061 の根絶）。

        Web GUI (client-manager.js) と同一の起動引数（main.py --port --listen
        127.0.0.1 + LLAMADOCK_COMFY_FLAGS or --reserve-vram 1.0）を使うので、
        どの経路から起動しても同じ設定になる。ログは %TEMP%\h3_comfyui.log。
        Returns True when /system_stats answers.
        """
        try:
            self._comfy("GET", "/system_stats", timeout=2)
            return True
        except Exception:
            pass
        root = _comfy_root()
        py = os.path.join(root, ".venv", "Scripts", "python.exe")
        main_py = os.path.join(root, "main.py")
        if not os.path.isfile(py) or not os.path.isfile(main_py):
            print(f"h3-chat: ComfyUI の自動起動に失敗（{root} に .venv/main.py がありません）")
            return False
        port = ChatHandler._comfy_port_of(self.server)
        args = [py, "main.py", "--port", str(port), "--listen", "127.0.0.1"]
        flags = os.environ.get("LLAMADOCK_COMFY_FLAGS", "").strip()
        args += flags.split() if flags else ["--reserve-vram", "1.0"]
        log_path = os.path.join(os.environ.get("TEMP", REPO), "h3_comfyui.log")
        logf = open(log_path, "a", encoding="utf-8", errors="replace")
        print(f"h3-chat: ComfyUI が停止していたため自動起動します (port {port}, log: {log_path})")
        try:
            if os.name == "nt":
                subprocess.Popen(
                    args, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL,
                    cwd=root,
                    creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
                )
            else:
                subprocess.Popen(args, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, cwd=root, start_new_session=True)
        except Exception as e:
            print(f"h3-chat: ComfyUI の自動起動に失敗: {e}")
            return False
        deadline = time.time() + wait_seconds
        while time.time() < deadline:
            try:
                self._comfy("GET", "/system_stats", timeout=2)
                print("h3-chat: ComfyUI の起動を確認しました")
                return True
            except Exception:
                time.sleep(2)
        print(f"h3-chat: ComfyUI が {wait_seconds} 秒以内に起動しませんでした（ログ: {log_path}）")
        return False

    def _shutdown(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            req = {}
        scope = req.get("scope") or "comfy"   # "comfy" | "all" | "cancel" | "free"
        if scope == "cancel":
            # browser-side countdown was cancelled: keep the stack alive
            self.server.autostop.poke()
            self._json(200, {"ok": True, "stopped": []})
            return
        if scope == "free":
            # モデルのみアンロード（VRAM 解放）。プロセスは止めず連続生成可能。
            self._free_comfy()
            self.server.autostop.poke()
            self._json(200, {"ok": True, "stopped": ["VRAM"]})
            return
        self._free_comfy()
        stopped = ["ComfyUI"]
        self._kill_port(self._comfy_port())
        if scope == "all":
            self._kill_port(planllm.PLAN_PORT)
            stopped.append("企画 LLM")
            # respond first, then stop the chat server itself
            threading.Timer(1.5, self.server.shutdown).start()
        self.server.autostop.poke()
        self._json(200, {"ok": True, "stopped": stopped})

    def _comfy_port(self):
        return ChatHandler._comfy_port_of(self.server)

    @staticmethod
    def _kill_port(port):
        # 2026-10-05 モジュール分割: 実装は h3chat_planllm._kill_port に一本化
        # (switch_plan_model が split 前は同じモジュールだった staticmethod を直接呼ぶため)
        _kill_port(port)

    @staticmethod
    def _comfy_port_of(server):
        try:
            return int(urllib.parse.urlparse(server.comfy_base).port or 8188)
        except Exception:
            return 8188

    # ---- status / view -----------------------------------------------

    def _eta_base(self, mode):
        """Median of past run times for this mode, or a session default."""
        times = self.server.run_times.get(mode) or []
        if times:
            s = sorted(times)
            return s[len(s) // 2]
        return ETA_DEFAULTS.get(mode, 300)

    def _status(self, pid):
        meta = self.server.job_meta.get(pid) or {}
        mode = meta.get("mode") or "video"
        elapsed = int(time.time() - meta["start"]) if meta.get("start") else 0
        eta = self._eta_base(mode)
        try:
            # running or queued?
            _, raw, _ = self._comfy("GET", "/queue", timeout=10)
            q = json.loads(raw)
            running = any(item[1] == pid for item in q.get("queue_running", []))
            pending = any(item[1] == pid for item in q.get("queue_pending", []))
            n_pending = len(q.get("queue_pending", []))
        except Exception:
            running = pending = n_pending = 0
        try:
            _, raw, _ = self._comfy("GET", "/history/" + pid, timeout=10)
            hist = json.loads(raw)
            entry = hist.get(pid)
        except Exception:
            entry = None
        if not entry:
            # 残り時間は「モード別目安 - 経過秒」を毎ポールで再計算して返す
            # （固定値を返すと UI の表示が永遠に「残り 約3分」のままだった）
            self._json(200, {"status": "running", "extra": "", "pending": n_pending, "elapsed_sec": elapsed, "eta_sec": max(0, eta - elapsed)})
            return
        st = entry.get("status", {})
        if st.get("status_str") == "error":
            msg = ""
            for m in st.get("messages", []):
                if m[0] == "execution_error":
                    msg = str(m[1].get("exception_message", ""))[:400]
            self._json(200, {"status": "error", "error": msg or "生成に失敗しました"})
            return
        if not st.get("completed"):
            self._json(200, {"status": "running", "extra": "", "pending": n_pending, "elapsed_sec": elapsed, "eta_sec": max(0, eta - elapsed)})
            return
        videos = []
        comfy_root = os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI")
        for nid, out in entry.get("outputs", {}).items():
            for key, val in out.items():
                if isinstance(val, list):
                    for item in val:
                        if isinstance(item, dict) and "filename" in item:
                            fn = item["filename"]
                            abspath = os.path.join(comfy_root, "output", item.get("subfolder", ""), fn)
                            # remember the on-disk path so /api/view still works
                            # after ComfyUI is stopped (auto-shutdown)
                            self.server.local_files[fn] = abspath
                            videos.append({
                                "filename": fn,
                                "type": item.get("type", "output"),
                                "subfolder": item.get("subfolder", ""),
                                "kind": "image" if fn.lower().endswith((".png", ".jpg", ".jpeg", ".webp", ".gif")) else "video",
                                "path": abspath,
                            })
        # 実測時間を記録して次回の残り時間表示（ETA）に使う
        if elapsed > 10:
            self.server.run_times.setdefault(mode, []).append(elapsed)
            self.server.run_times[mode] = self.server.run_times[mode][-20:]
        self.server.job_meta.pop(pid, None)
        # 動画が完成してキューが空なら、自動停止のタイマーをスタート
        # （画像だけの完了では起動しない: ユーザーが画像を確認中の場合がある）
        has_video = any(v.get("kind") == "video" for v in videos)
        if has_video:
            try:
                _, qraw, _ = self._comfy("GET", "/queue", timeout=10)
                qq = json.loads(qraw)
                queue_empty = not qq.get("queue_running") and not qq.get("queue_pending")
            except Exception:
                queue_empty = False
            if queue_empty:
                try:
                    self.server.autostop.mark_done()
                except Exception:
                    pass
        self._json(200, {"status": "success", "videos": videos})

    def _view(self, query):
        params = urllib.parse.parse_qs(query)
        fn = params.get("filename", [""])[0]
        if not fn:
            self._json(400, {"error": "missing filename"})
            return
        low = fn.lower()
        if low.endswith(".mp4"):
            ctype = "video/mp4"
        elif low.endswith(".png"):
            ctype = "image/png"
        elif low.endswith((".jpg", ".jpeg")):
            ctype = "image/jpeg"
        elif low.endswith(".webp"):
            ctype = "image/webp"
        elif low.endswith(".gif"):
            ctype = "image/gif"
        else:
            ctype = "application/octet-stream"
        url = self.server.comfy_base + "/view?" + urllib.parse.urlencode({
            "filename": fn,
            "subfolder": params.get("subfolder", [""])[0],
            "type": params.get("type", ["output"])[0],
        })
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = r.read()
        except Exception:
            # ComfyUI may be stopped (auto-shutdown); serve the saved file
            # directly from disk so the result stays viewable.
            abspath = self.server.local_files.get(fn)
            if not abspath or not os.path.isfile(abspath):
                self._json(502, {"error": "file not available"})
                return
            try:
                with open(abspath, "rb") as f:
                    data = f.read()
            except Exception as e:
                self._json(502, {"error": f"read failed: {e}"})
                return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("[h3-chat] %s - %s\n" % (self.address_string(), fmt % args))


def main():
    ap = argparse.ArgumentParser(description="MiniMax H3 chat-to-video UI")
    ap.add_argument("--port", type=int, default=8189)
    ap.add_argument("--comfy", default="http://127.0.0.1:8188")
    ap.add_argument("--plan-url", default=None, help="OpenAI-compatible planning LLM endpoint (e.g. http://127.0.0.1:8190)")
    args = ap.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), ChatHandler)
    server.comfy_base = args.comfy.rstrip("/")
    server.plan_url = args.plan_url.rstrip("/") if args.plan_url else None
    server.local_files = {}
    server.job_meta = {}     # prompt_id -> {mode, start, kind} (ETA 用)
    server.run_times = {}    # mode -> [実測秒] (ETA 用・セッション内メモリ)
    server.autostop = _AutoStop(server)
    url = f"http://127.0.0.1:{args.port}"
    print(f"h3-chat: {url}")
    print(f"h3-chat: ComfyUI = {server.comfy_base}  (fast={WORKFLOWS['fast']} high={WORKFLOWS['high']} quick={WORKFLOWS['quick']} lite={WORKFLOWS['lite']})")
    print(f"h3-chat: DITs = default / 10eros ({DITS['10eros']})")
    print(f"h3-chat: Klein 9B = {KIMG_WORKFLOW}")
    print(f"h3-chat: Qwen    = {QIMG_WORKFLOW}")
    print(f"h3-chat: R2V 参照モード = {R2V_WORKFLOWS['fast']} など（キー画像→参照 LoRA）")
    print(f"h3-chat: plan LLM = {server.plan_url or ('auto (' + str(planllm.PLAN_PORT) + ', GPU 27B)' if planllm.PLAN_GPU else 'auto (8190, CPU 4B)')} (engine: {planllm.PLAN_ENGINE})")
    # Bring up the planning LLM in the background so the first plan-mode
    # message does not have to wait for the model load (~10-60s on CPU).
    # gpu27b mode starts on demand instead: preloading it would hold 14GB of
    # VRAM while ComfyUI may still be generating.
    if not server.plan_url and not planllm.PLAN_GPU:
        threading.Thread(target=ensure_plan_llm, kwargs={"wait_seconds": 180}, daemon=True).start()
    print("h3-chat: Ctrl+C で停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        # ── セッション自動クリーンアップ（ログ残さない）──────────
        import shutil
        if os.path.isdir(SESSIONS_DIR):
            shutil.rmtree(SESSIONS_DIR, ignore_errors=True)
            print("h3-chat: sessions cleaned up.")


if __name__ == "__main__":
    main()
