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
ETA_DEFAULTS = {"high": 540, "quick": 240, "lite": 540, "quicklite": 150, "fast": 900, "fast_quick": 360, "zimg": 40, "qimg": 1250, "upscale": 180}

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

# Z-Image Turbo (key-image) workflow: 企画 → キー画像 → 確認 → 動画
ZIMG_WORKFLOW = os.path.join(REPO, "h3_workflow_zimage.json")
NODE_ZIMG_PROMPT = "5"   # CLIPTextEncode: image prompt
NODE_ZIMG_LATENT = "7"   # EmptySD3LatentImage: size
NODE_ZIMG_SEED = "8"     # KSampler: seed

# Qwen-Image 2512 (key-image, high quality): GGUF Q4_K_S + Lightning 4step +
# tumblrasia NSFW LoRA. batch_size=4 so the UI can pick the best candidate.
QIMG_WORKFLOW = os.path.join(REPO, "h3_workflow_qimage.json")
NODE_QIMG_PROMPT = "5"   # CLIPTextEncode: image prompt
NODE_QIMG_LATENT = "7"   # EmptySD3LatentImage: size + batch
NODE_QIMG_SEED = "10"    # KSampler: seed

# Key-image engines selectable in the UI
IMG_ENGINES = {
    "zimg": {
        "workflow": ZIMG_WORKFLOW,
        "prompt": NODE_ZIMG_PROMPT, "latent": NODE_ZIMG_LATENT, "seed": NODE_ZIMG_SEED,
        "default_size": (512, 320),
        "label": "Z-Image Turbo",
        "batch_size": 1,
    },
    "qimg": {
        "workflow": QIMG_WORKFLOW,
        "prompt": NODE_QIMG_PROMPT, "latent": NODE_QIMG_LATENT, "seed": NODE_QIMG_SEED,
        "default_size": (1344, 768),
        "label": "Qwen-Image 2512",
        "batch_size": 4,
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

# ---- 動画の続き（延長）/ アップスケール / 結合 -------------------------
# 続きもの: 完成動画の最後の1フレームを PyAV で抜き出し、次の生成の
# first_frame（I2V）にすることで前作から自然に続く動画を作る。
# アップスケール: ComfyUI の LoadVideo→GetVideoComponents→RealESRGAN x4→
# ImageScale（2x/4x 目標サイズ）→CreateVideo（元音声を再mux）→SaveVideo。
# 結合: 複数セグメントを PyAV でデコード→1本の mp4 に再エンコード。
# いずれもシステム ffmpeg 不要（PyAV が FFmpeg ライブラリを内蔵）。
UPSCALE_WORKFLOW = os.path.join(REPO, "h3_workflow_upscale.json")
UPSCALE_MODEL_NAME = "RealESRGAN_x4plus.pth"
NODE_UP_LOADVIDEO = "1"    # LoadVideo: file（ComfyUI input/ 内の動画）
NODE_UP_SCALE = "5"        # ImageScale: 目標サイズ（2x/4x）


def _comfy_root():
    return os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI")


def _extract_last_frame(video_path):
    """動画の最後の1フレームを PNG で ComfyUI input/ に保存し、そのファイル名を返す。"""
    import av
    in_dir = os.path.join(_comfy_root(), "input")
    os.makedirs(in_dir, exist_ok=True)
    container = av.open(video_path)
    try:
        stream = container.streams.video[0]
        last = None
        for frame in container.decode(stream):
            last = frame
        if last is None:
            raise ValueError("動画にフレームがありません")
        img = last.to_image()
        name = "h3_ext_{}.png".format(int(time.time() * 1000) % 10**13)
        img.save(os.path.join(in_dir, name))
        return name
    finally:
        container.close()


def _video_size(video_path):
    """(width, height) of the first video stream."""
    import av
    container = av.open(video_path)
    try:
        s = container.streams.video[0]
        return s.codec_context.width, s.codec_context.height
    finally:
        container.close()


def _concat_videos(paths):
    """動画ファイルを順に結合して ComfyUI output/ に mp4 で保存し、ファイル名を返す。

    全セグメント同一解像度が前提（異なれば ValueError）。映像は 24fps・
    h264 再エンコード、音声は aac でつなぐ（H3 の動画は全て 24fps・音声付き）。
    """
    import av
    from fractions import Fraction
    dims = [_video_size(p) for p in paths]
    if len(set(dims)) > 1:
        raise ValueError("解像度が異なる動画は結合できません（同じモードで生成した動画を結合してください）")
    w, h = dims[0]
    out_dir = os.path.join(_comfy_root(), "output")
    os.makedirs(out_dir, exist_ok=True)
    name = "h3_joined_{}.mp4".format(int(time.time() * 1000) % 10**13)
    out_path = os.path.join(out_dir, name)
    out = av.open(out_path, mode="w")
    try:
        vs = out.add_stream("h264", rate=24)
        vs.width = w
        vs.height = h
        vs.pix_fmt = "yuv420p"
        vs.bit_rate = 8_000_000
        vs.time_base = Fraction(1, 24)
        audio_stream = None
        vi = 0
        ai = 0
        for p in paths:
            c = av.open(p)
            try:
                vstream = c.streams.video[0]
                astream = c.streams.audio[0] if c.streams.audio else None
                if audio_stream is None and astream is not None:
                    audio_stream = out.add_stream("aac", rate=astream.rate or 44100)
                    audio_stream.time_base = Fraction(1, astream.rate or 44100)
                for frame in c.decode(vstream):
                    frame = frame.reformat(format="yuv420p")
                    frame.pts = vi
                    vi += 1
                    for pkt in vs.encode(frame):
                        out.mux(pkt)
                if astream is not None and audio_stream is not None:
                    for frame in c.decode(astream):
                        frame.pts = ai
                        ai += frame.samples
                        for pkt in audio_stream.encode(frame):
                            out.mux(pkt)
            finally:
                c.close()
        for pkt in vs.encode(None):
            out.mux(pkt)
        if audio_stream is not None:
            for pkt in audio_stream.encode(None):
                out.mux(pkt)
    finally:
        out.close()
    return name


# Standard ports (must match tools\h3-chat.ps1 / select-model.ps1)
#
# The planning LLM runs in one of two modes:
#   cpu4b  (default): Qwen3.5-4B on CPU (-ngl 0), port 8190, pre-started and
#                     always-on; has an mmproj so it can see the confirmed key
#                     image.
#   gpu    (LLAMADOCK_PLAN_GPU=1): a large GGUF on GPU (-ngl all), port 8191.
#                     Started on demand for the planning phase only and killed
#                     before every ComfyUI generation, so the planner and the
#                     video model never fight over VRAM.
#
# The GPU planner model is NOT hardcoded: it is auto-selected from the GGUFs
# installed under .lmstudio\models (scan_plan_models) and can be switched at
# runtime from the UI dropdown (GET/POST /api/plan-models). Env vars
# LLAMADOCK_PLAN_MODEL / LLAMADOCK_PLAN_MMPROJ still win when set.
PLAN_GPU = os.environ.get("LLAMADOCK_PLAN_GPU", "") == "1"
PLAN_PORT = 8191 if PLAN_GPU else 8190
PLAN_URL_DEFAULT = f"http://127.0.0.1:{PLAN_PORT}"

# ---- planning LLM model discovery ------------------------------------
# .lmstudio\models をスキャンして企画 LLM 候補を列挙する
# （select-model.ps1 の Get-PlanModelCandidates と同じ規則）。
MODEL_SCAN_ROOT = r"C:\Users\dai86\.lmstudio\models"
# The GPU planner must share the 16GB card with KV cache + mmproj, so the
# auto-pick stays under this size (larger ones remain selectable in the UI).
GPU_AUTO_MAX_GB = 15.5


def _find_mmproj(dirpath):
    """First mmproj*.gguf next to a model file, or None."""
    try:
        for fn in sorted(os.listdir(dirpath)):
            if fn.lower().startswith("mmproj") and fn.lower().endswith(".gguf"):
                return os.path.join(dirpath, fn)
    except OSError:
        pass
    return None


def scan_plan_models():
    """Scan MODEL_SCAN_ROOT for planning-LLM candidates.

    Excludes mmproj projectors, split parts (-of-) and speculative draft
    models (DSpark/DFlash2); pairs each model with an mmproj in the same
    directory. GPU heuristic mirrors select-model.ps1: a parameter count
    >= 13B in the filename, or a file size over 6GB.
    Returns a list of dicts sorted CPU-first, then by size.
    """
    out = []
    if not os.path.isdir(MODEL_SCAN_ROOT):
        return out
    for org in sorted(os.listdir(MODEL_SCAN_ROOT)):
        org_dir = os.path.join(MODEL_SCAN_ROOT, org)
        if not os.path.isdir(org_dir) or org in ("blobs", "manifests"):
            continue
        for root, _dirs, files in os.walk(org_dir):
            for fn in sorted(files):
                low = fn.lower()
                if not low.endswith(".gguf"):
                    continue
                if "mmproj" in low or "-of-" in low or "dspark" in low or "dflash2" in low:
                    continue
                path = os.path.join(root, fn)
                try:
                    size_gb = round(os.path.getsize(path) / (1024 ** 3), 1)
                except OSError:
                    continue
                gpu = size_gb > 6.0
                m = re.search(r"(\d+)\s*b", fn, re.IGNORECASE)
                if m and int(m.group(1)) >= 13:
                    gpu = True
                label = os.path.basename(root)
                parent = os.path.basename(os.path.dirname(root))
                if parent and parent.lower() != "models":
                    label = parent + "/" + label
                if len(label) > 44:
                    label = label[:44] + "…"
                mmproj = _find_mmproj(root)
                out.append({
                    "path": path, "mmproj": mmproj, "gpu": gpu,
                    "size_gb": size_gb, "label": label,
                    "vision": bool(mmproj),
                })
    out.sort(key=lambda m: (m["gpu"], m["size_gb"]))
    return out


def _auto_plan_model(for_gpu):
    """Pick the default planning model from the installed GGUFs.

    GPU: vision-capable models that fit the card first (smallest first, so
    the cold load stays fast and the KV cache keeps headroom). CPU: the
    dedicated Qwen3.5-4B if installed, else the smallest candidate.
    Returns (path, mmproj); both None when nothing usable is installed.
    """
    models = scan_plan_models()
    if for_gpu:
        cands = [m for m in models if m["gpu"] and m["size_gb"] <= GPU_AUTO_MAX_GB]
        cands.sort(key=lambda m: (not m["vision"], m["size_gb"]))
        if not cands:
            cands = [m for m in models if m["gpu"]]
        if cands:
            return cands[0]["path"], cands[0]["mmproj"]
        return None, None
    known_cpu = r"C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica.i1-Q6_K.gguf"
    for m in models:
        if m["path"].lower() == known_cpu.lower():
            return m["path"], m["mmproj"]
    if models:
        return models[0]["path"], models[0]["mmproj"]
    return None, None


def _resolve_plan_model(for_gpu):
    """Resolve the planning model: env vars first, else the auto-pick."""
    env_model = os.environ.get("LLAMADOCK_PLAN_MODEL")
    env_mmproj = os.environ.get("LLAMADOCK_PLAN_MMPROJ")
    if env_model and os.path.isfile(env_model):
        if env_mmproj and os.path.isfile(env_mmproj):
            return env_model, env_mmproj
        return env_model, _find_mmproj(os.path.dirname(env_model))
    return _auto_plan_model(for_gpu)


# Planner engine: single engine since 2026-08-30 — the Unsloth llama.cpp HIP
# build (b10687, gfx110X = RX 7800 XT). It is the fastest measured backend on
# this box (prefill 227-271 t/s vs 49-80 t/s on Vulkan) and replaces the
# retired AtomicBot/TurboTan/DFlash2 chain. Path may churn if Unsloth Desktop
# updates — _spawn_plan_llm re-resolves when the remembered path dies.
_GPU_BIN_CANDIDATES = (
    r"C:\Users\dai86\.unsloth\llama.cpp\build\bin\Release\llama-server.exe",
)
_CPU_BIN_CANDIDATES = _GPU_BIN_CANDIDATES


def _resolve_plan_bin(for_gpu):
    env = os.environ.get("LLAMADOCK_PLAN_BIN")
    if env and os.path.isfile(env):
        return env
    chain = _GPU_BIN_CANDIDATES if for_gpu else _CPU_BIN_CANDIDATES
    for c in chain:
        if os.path.isfile(c):
            return c
    return chain[0]


# ---- planning LLM auto-start -----------------------------------------
# Mirrors the llama-server launch in tools\h3-chat.ps1 so plan mode works
# even when h3-chat.py is started directly (without h3-chat.ps1 / llamadock).
PLAN_MODEL_PATH, PLAN_MMPROJ_PATH = _resolve_plan_model(PLAN_GPU)
PLAN_MODEL_PATH = PLAN_MODEL_PATH or ""
PLAN_MMPROJ_PATH = PLAN_MMPROJ_PATH or ""
PLAN_SERVER_BIN = _resolve_plan_bin(PLAN_GPU)
# 企画 LLM のエンジン名（コーダー側のエンジン表記と揃えた表示用ラベル）。
# モデル切替で GPU/CPU が変わり得るので、起動時のスナップショット
# (PLAN_ENGINE) と現在値 (_plan_engine_label) を分けて持つ。


def _plan_engine_label():
    if ".unsloth" in PLAN_SERVER_BIN:
        return "Unsloth (ROCm 7.1 HIP)"
    return "Unknown"
# The HIP build needs the ROCm runtime (amdhip64_7.dll) on PATH.
PLAN_ROCM_BIN = os.environ.get("LLAMADOCK_ROCM_BIN", r"C:\Program Files\AMD\ROCm\7.1\bin")
# Vision is available whenever an mmproj is configured, regardless of CPU/GPU
# mode. The old rule (vision = not GPU) broke the 27B vision model, which runs
# on GPU but ships its own mmproj.
PLAN_HAS_VISION = bool(PLAN_MMPROJ_PATH)
PLAN_START_LOCK = threading.Lock()
# Runtime-adjustable planner launch parameters (set via /api/plan-settings).
PLAN_SETTINGS = {
    "ctk": "q8_0",       # KV cache key quantization (q8_0, q4_0, f16, none)
    "ctv": "q4_0",       # KV cache value quantization (q8_0, q4_0, f16, none)
    "fa": True,           # Flash Attention
    "reasoning_effort": "medium",  # off, low, medium, xhigh
    "reasoning_budget": 1536,       # max thinking tokens
}
PLAN_ENGINE = _plan_engine_label()
PLAN_PROC = None
PLAN_LAST_TRY = 0.0


def _plan_alive():
    """True when a planning LLM answers on the default port."""
    try:
        with urllib.request.urlopen(PLAN_URL_DEFAULT + "/v1/models", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def _spawn_plan_llm():
    """Launch the planning llama-server detached on PLAN_PORT.

    cpu4b mode: Qwen3.5 + mmproj, CPU-only (-ngl 0), stays resident.
    gpu27b mode: Qwen3.8-27B on GPU (-ngl all), started on demand and killed
    before every ComfyUI generation (see stop_plan_llm).

    Returns the Popen handle, or None when the binary/model is missing or
    the process could not be started.
    """
    global PLAN_SERVER_BIN
    # PLAN_SERVER_BIN is resolved at import time; the build trees churn
    # (the TurboTan prebuilt vanished mid-session on 2026-08-28), so
    # re-resolve when the remembered path no longer exists instead of
    # failing every spawn until h3-chat restarts.
    if not os.path.isfile(PLAN_SERVER_BIN):
        PLAN_SERVER_BIN = _resolve_plan_bin(PLAN_GPU)
    if not os.path.isfile(PLAN_SERVER_BIN):
        print(f"h3-chat: planning LLM binary not found: {PLAN_SERVER_BIN}")
        return None
    if not os.path.isfile(PLAN_MODEL_PATH):
        print(f"h3-chat: planning model not found: {PLAN_MODEL_PATH}")
        return None
    server_bin = PLAN_SERVER_BIN
    args = [
        server_bin, "-m", PLAN_MODEL_PATH,
        "--port", str(PLAN_PORT),
        "-c", "8192", "--no-webui",
        "-np", "1",
        "--temp", "0.8", "--top-p", "0.95", "--min-p", "0.05",
    ]
    if PLAN_GPU:
        # GPU planner: full offload, jinja template, medium reasoning effort.
        # hama-jp's research (github.com/hama-jp/qwen38-reasoning-effort)
        # shows --reasoning off pushes thinking INTO the answer text (3x output
        # tokens, 3x slower). medium effort keeps thinking separate and short
        # (~312 tokens median vs 29k at xhigh default). Budget 1536 tokens as a
        # safety net against runaway thinking (Qwen3.8-27B defaults to xhigh).
        args += [
            "-ngl", "all", "--jinja",
            "--chat-template-kwargs", json.dumps({"reasoning_effort": PLAN_SETTINGS["reasoning_effort"]}),
            "--reasoning-budget", str(PLAN_SETTINGS["reasoning_budget"]),
        ]
        # KV cache compression + Flash Attention (configurable via UI).
        # V quantization requires Flash Attention (see docs/LlamaDock-Runbook.md).
        if PLAN_SETTINGS["fa"]:
            args += ["-fa", "on"]
        if PLAN_SETTINGS["ctk"] and PLAN_SETTINGS["ctk"] != "none":
            args += ["-ctk", PLAN_SETTINGS["ctk"]]
        if PLAN_SETTINGS["ctv"] and PLAN_SETTINGS["ctv"] != "none":
            args += ["-ctv", PLAN_SETTINGS["ctv"]]
        if PLAN_MMPROJ_PATH and os.path.isfile(PLAN_MMPROJ_PATH):
            # Vision-capable planner: attach the mmproj shipped next to the
            # model so the planner can see the confirmed key image.
            args += ["--mmproj", PLAN_MMPROJ_PATH, "--image-min-tokens", "1024"]
    else:
        args += [
            "-ngl", "0", "--mlock",
            # This 4B model is not a reasoning model: when the Qwen3.5 chat
            # template injects a think-block opener it "thinks" by re-reading
            # its own system prompt, burns the whole token budget, then
            # restarts the thinking inside the answer (measured: 200s, no
            # clean output). --reasoning off makes the template emit an empty
            # think block so the model answers directly (this build maps
            # --reasoning off to enable_thinking=false; the older
            # --chat-template-kwargs form is deprecated). Kept fixed on CPU:
            # the UI reasoning controls only apply to the GPU planner.
            "--reasoning", "off",
            "--repeat-penalty", "1.05",
        ]
        # KV cache compression + Flash Attention from the UI (same contract as
        # the GPU branch). V quantization requires Flash Attention.
        if PLAN_SETTINGS["fa"]:
            args += ["-fa", "on"]
        if PLAN_SETTINGS["ctk"] and PLAN_SETTINGS["ctk"] != "none":
            args += ["-ctk", PLAN_SETTINGS["ctk"]]
        if PLAN_SETTINGS["ctv"] and PLAN_SETTINGS["ctv"] != "none":
            args += ["-ctv", PLAN_SETTINGS["ctv"]]
        if os.path.isfile(PLAN_MMPROJ_PATH):
            # Qwen-VL needs >=1024 image tokens to resolve detail (server warns
            # about this at startup); without it the model under-sees the key image.
            args += ["--mmproj", PLAN_MMPROJ_PATH, "--image-min-tokens", "1024"]
    env = dict(os.environ)
    if os.path.isdir(PLAN_ROCM_BIN):
        # The HIP build links amdhip64_7.dll from the ROCm runtime; without it
        # on PATH the server exits with STATUS_DLL_NOT_FOUND. CPU planner too:
        # its binary is the same ROCm build (-ngl 0 does not remove the DLL
        # dependency), and the normal launcher chain (select-model.ps1) is what
        # usually provides the PATH entry — a spawn from a plain shell fails.
        env["PATH"] = PLAN_ROCM_BIN + os.pathsep + env.get("PATH", "")
    log_path = os.path.join(os.environ.get("TEMP", REPO), "h3_plan_llm.log")
    logf = open(log_path, "a", encoding="utf-8", errors="replace")
    try:
        if os.name == "nt":
            return subprocess.Popen(
                args, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL,
                cwd=os.path.dirname(PLAN_SERVER_BIN), env=env,
                creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
            )
        return subprocess.Popen(
            args, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL,
            cwd=os.path.dirname(PLAN_SERVER_BIN), env=env, start_new_session=True,
        )
    except Exception:
        return None


def stop_plan_llm():
    """Stop the planning LLM and free its VRAM (gpu27b mode only).

    Called before every ComfyUI generation: the 14GB GPU planner and the
    video model cannot share the 16GB card. The next plan message restarts
    it (~10s cold load). No-op in cpu4b mode (the CPU planner holds no VRAM).
    """
    global PLAN_PROC, PLAN_LAST_TRY
    if not PLAN_GPU:
        return
    with PLAN_START_LOCK:
        if PLAN_PROC is not None and PLAN_PROC.poll() is None:
            try:
                PLAN_PROC.terminate()
                PLAN_PROC.wait(timeout=10)
            except Exception:
                try:
                    PLAN_PROC.kill()
                except Exception:
                    pass
        PLAN_PROC = None
        # allow an immediate re-spawn on the next plan message
        PLAN_LAST_TRY = 0.0
    # belt and suspenders: also kill whatever answers on the plan port
    ChatHandler._kill_port(PLAN_PORT)


def ensure_plan_llm(wait_seconds=120):
    """Make sure a planning LLM is up on PLAN_PORT, auto-starting it if needed.

    Idempotent: will not spawn while a previously started llama-server is
    still alive, and will not retry a failed spawn more often than every 30s.
    Returns True when the endpoint answers.
    """
    if _plan_alive():
        return True
    global PLAN_PROC, PLAN_LAST_TRY
    with PLAN_START_LOCK:
        dead = PLAN_PROC is None or PLAN_PROC.poll() is not None
        if dead and time.time() - PLAN_LAST_TRY > 30:
            engine_label = _plan_engine_label()
            print(f"h3-chat: auto-starting planning LLM (port {PLAN_PORT}, engine: {engine_label})")
            PLAN_PROC = _spawn_plan_llm()
            PLAN_LAST_TRY = time.time()
            if PLAN_PROC is None:
                return False
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if _plan_alive():
            return True
        time.sleep(2)
    return False


def switch_plan_model(path, mmproj=None, gpu=None):
    """Switch the planning LLM model at runtime (UI dropdown).

    Stops any running planner (the resident CPU 4B or an on-demand GPU
    planner) and re-points the launch config; the next plan message
    auto-starts the new model on the right port. Returns (ok, error).
    """
    global PLAN_MODEL_PATH, PLAN_MMPROJ_PATH, PLAN_GPU, PLAN_PORT
    global PLAN_URL_DEFAULT, PLAN_HAS_VISION, PLAN_PROC, PLAN_LAST_TRY
    global PLAN_SERVER_BIN, PLAN_ENGINE
    if not path or not os.path.isfile(path):
        return False, "モデルファイルが見つかりません"
    if mmproj and not os.path.isfile(mmproj):
        mmproj = None
    if not mmproj:
        mmproj = _find_mmproj(os.path.dirname(path))
    if gpu is None:
        try:
            gpu = os.path.getsize(path) > 6 * 1024 ** 3
        except OSError:
            gpu = False
    with PLAN_START_LOCK:
        if PLAN_PROC is not None and PLAN_PROC.poll() is None:
            try:
                PLAN_PROC.terminate()
                PLAN_PROC.wait(timeout=10)
            except Exception:
                try:
                    PLAN_PROC.kill()
                except Exception:
                    pass
        PLAN_PROC = None
        ChatHandler._kill_port(PLAN_PORT)
        PLAN_MODEL_PATH = path
        PLAN_MMPROJ_PATH = mmproj or ""
        PLAN_GPU = bool(gpu)
        PLAN_PORT = 8191 if PLAN_GPU else 8190
        PLAN_URL_DEFAULT = f"http://127.0.0.1:{PLAN_PORT}"
        ChatHandler._kill_port(PLAN_PORT)   # stale leftover on the new port
        PLAN_HAS_VISION = bool(PLAN_MMPROJ_PATH)
        # CPU<->GPU の切替でも同一エンジン（Unsloth）を使うため再解決のみ
        # （env 指定が優先）。
        if not os.environ.get("LLAMADOCK_PLAN_BIN"):
            PLAN_SERVER_BIN = _resolve_plan_bin(PLAN_GPU)
        PLAN_ENGINE = _plan_engine_label()
        PLAN_LAST_TRY = 0.0
    print(f"h3-chat: planning LLM switched to {os.path.basename(path)} "
          f"({'GPU' if PLAN_GPU else 'CPU'}, port {PLAN_PORT}, bin: {PLAN_SERVER_BIN})")
    return True, None

# ComfyUI node ids in the super workflows
NODE_PROMPT = "6"     # MiniMaxH3ImageToVideo: user prompt
NODE_SEED = "7"       # KSampler: seed

# Per-session plan state (single-user local UI): image -> video pipeline.
SESSION = {
    "image_prompt": None, "video_prompt": None,
    "mode_override": None,     # チャットで「高画質/速く」等と指示したときのモード上書き
    "length_frames": None,     # チャットで「長く/短く/N秒」と指示したときのフレーム数上書き
    "resolution": None,        # (width, height) アスペクト上書き
}

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
    ChatHandler._kill_port(PLAN_PORT)
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
    "ヌードシーンなら [IMG_PROMPT] と [FINAL_PROMPT] の両方に explicitly fully nude, no clothing, no underwear と明記し、"
    "下着・衣服が途中で出現しないよう釘を刺す。着衣シーンならその衣服を両プロンプトで同じ単語で繰り返す。"
    "【表情・感情の多様性】表情は「気持ちよさそう」一辺倒にしない。シーンに合わせて"
    "イヤイヤながら（reluctant, protesting but yielding）、泣きながら（tears streaming, crying face）、"
    "無邪気に楽しむ（playful, innocent giggle）、照れる（blushing, shy smile）、恍惚（ecstatic, eyes rolling back）など"
    "具体的な感情を1つ選んで英語で明記する。ユーザーが感情を指定したらそれを最優先で反映する。"
    "【リアルさ・素人感】AI っぽさを消すため、素人撮影・アマチュア動画風の質感を積極的に取り入れる: "
    "handheld camera with slight shake, amateur home-video look, natural imperfect skin texture, candid unposed feel。"
    "完璧すぎる肌・左右対称すぎる顔・不自然な光沢は避ける。"
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
# Qwen-Image / Z-Image and pollute the prompt, so strip them. Leading
# whitespace is optional because the model sometimes glues them on
# ("8k--v 6.0--q 2").
GEN_PARAM_RE = re.compile(
    r"\s*--(?:ar|aspect|v|version|style|stylize|s|q|quality|no|seed|c|chaos|tile|iw|w|h)\b[^-]*",
    re.I,
)


def _strip_gen_params(text):
    return GEN_PARAM_RE.sub("", text or "").strip()




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

# Per-session conversation history for planning mode (single-user local UI).
PLAN_HISTORY = []
PLAN_LOCK = threading.Lock()

HTML = """<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MiniMax H3 チャット動画生成</title>
<style>
  :root { --bg:#0b0e14; --panel:#12161f; --panel2:#1a2029; --line:#242c3a;
          --text:#e8eaf0; --muted:#8b93a3; --accent:#38bdf8; --accent2:#3b82f6;
          --ok:#34d399; --err:#f87171; --warn:#fbbf24;
          --grad:linear-gradient(135deg,#22d3ee,#3b82f6); }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font-family:"Segoe UI", "Noto Sans JP", sans-serif; height:100vh;
         display:flex; flex-direction:column; }

  /* ---- header ---- */
  header { padding:12px 20px; border-bottom:1px solid var(--line);
           display:flex; align-items:center; gap:14px;
           background:linear-gradient(180deg,rgba(34,211,238,.05),transparent); }
  header h1 { font-size:16px; margin:0; font-weight:700; letter-spacing:.3px; }
  header .sub { color:var(--muted); font-size:12px; }
  #status-dot { width:9px; height:9px; border-radius:50%; background:#555; margin-left:auto;
                box-shadow:0 0 0 3px rgba(255,255,255,.03); }
  #status-dot.ok { background:var(--ok); box-shadow:0 0 8px rgba(52,211,153,.7); }
  #status-dot.down { background:var(--err); box-shadow:0 0 8px rgba(248,113,113,.7); }

  /* ---- sidebar (past sessions, ChatGPT-style) ---- */
  #app { flex:1; display:flex; min-height:0; }
  #sidebar { width:250px; min-width:250px; border-right:1px solid var(--line);
             background:var(--panel); display:flex; flex-direction:column;
             padding:10px; gap:10px; }
  #sidebar.hidden { display:none; }
  #btn-newchat { background:var(--grad); color:#fff; border:none; border-radius:10px;
                 padding:10px 12px; font-size:13px; font-weight:700; cursor:pointer; }
  #sess-list { flex:1; overflow-y:auto; display:flex; flex-direction:column; gap:4px; }
  .sessitem { padding:8px 28px 8px 10px; border-radius:10px; cursor:pointer;
              border:1px solid transparent; position:relative; }
  .sessitem:hover { background:var(--panel2); }
  .sessitem.active { background:var(--panel2); border-color:var(--accent); }
  .sessitem .sesstitle { font-size:12px; line-height:1.4; overflow:hidden;
                         text-overflow:ellipsis; white-space:nowrap; }
  .sessitem .sesstime { font-size:10px; color:var(--muted); margin-top:2px; }
  .sessitem .sessdel { position:absolute; top:6px; right:6px; display:none;
                       background:transparent; border:none; color:var(--muted);
                       padding:2px 5px; font-size:12px; border-radius:6px; cursor:pointer; }
  .sessitem:hover .sessdel { display:block; }
  .sessitem .sessdel:hover { color:var(--err); background:rgba(248,113,113,.12); }
  #sess-empty { color:var(--muted); font-size:11px; padding:6px 4px; }
  #btn-sidebar { background:transparent; border:1px solid var(--line); color:var(--text);
                 border-radius:8px; padding:5px 10px; font-size:14px; cursor:pointer; }
  #btn-sidebar:hover { background:var(--panel2); filter:none; }

  /* ---- chat area ---- */
  main { flex:1; overflow-y:auto; padding:18px 20px; min-width:0; }
  .msg { max-width:80%; padding:11px 15px; border-radius:14px; margin-bottom:12px;
         font-size:14px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }
  .user { background:linear-gradient(135deg,#1e3a5f,#243252); margin-left:auto;
          border:1px solid #2c4a72; border-bottom-right-radius:4px; }
  .bot  { background:var(--panel); border:1px solid var(--line); border-bottom-left-radius:4px; }
  .bot .meta { color:var(--muted); font-size:11px; margin-bottom:6px; }
  .bot .err { color:var(--err); }
  .bot video { width:100%; max-width:520px; border-radius:10px; background:#000; display:block; margin-top:8px; }
  .bot img { width:100%; max-width:520px; border-radius:10px; background:#000; display:block; margin-top:8px; }
  .bot .path { color:var(--muted); font-size:11px; margin-top:6px; word-break:break-all; }
  .row { display:flex; gap:8px; margin-top:10px; flex-wrap:wrap; }
  .row button.ok { background:var(--ok); color:#0b2b1c; }
  .row button.rev { background:var(--warn); color:#3a2400; }
  .row button.small { background:transparent; color:var(--muted); border:1px solid var(--line); }

  /* ---- shutdown banner ---- */
  #shutdown-box { display:none; border-top:2px solid var(--ok); background:#0e241a;
                  padding:10px 20px; font-size:13px; }
  #shutdown-box .meta { color:var(--muted); font-size:11px; margin-bottom:6px; }
  #shutdown-box button { padding:8px 14px; font-size:12px; margin-right:8px; }
  #shutdown-box button.warn { background:var(--err); }

  /* ---- footer: stacked rows, input always full width ---- */
  footer { border-top:1px solid var(--line); padding:12px 16px 14px;
           display:flex; flex-direction:column; gap:10px;
           background:linear-gradient(180deg,transparent,rgba(34,211,238,.04)); }
  .ft-row { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }

  /* segment control (mode pills) */
  .seg { display:flex; gap:3px; background:var(--panel); border:1px solid var(--line);
         border-radius:12px; padding:3px; flex:1; min-width:0; }
  .segbtn { flex:1; min-width:0; }
  .segbtn input { display:none; }
  .segbtn span { display:block; text-align:center; font-size:11px; color:var(--muted);
                 padding:6px 4px; border-radius:9px; cursor:pointer; line-height:1.3;
                 transition:background .15s, color .15s; white-space:nowrap;
                 overflow:hidden; text-overflow:ellipsis; }
  .segbtn span:hover { color:var(--text); background:var(--panel2); }
  .segbtn input:checked + span { background:var(--grad); color:#fff; font-weight:600; }
  .segbtn small { display:block; font-size:9px; opacity:.75; font-weight:400; }

  /* length selector */
  #lenbox { display:flex; align-items:center; gap:6px; font-size:12px; color:var(--muted);
            white-space:nowrap; }
  #lenbox select { background:var(--panel); color:var(--text); border:1px solid var(--line);
                   border-radius:9px; padding:5px 8px; font:inherit; font-size:12px; outline:none; }

  /* toggle / action row */
  .ft-toggles { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
  .plan { font-size:12px; color:var(--muted); display:flex; gap:6px; align-items:center;
          cursor:pointer; white-space:nowrap; }
  .plan input { accent-color:var(--accent); }
  .ft-toggles > button, #refpick button { background:transparent; color:var(--accent);
          border:1px solid var(--accent); border-radius:9px; padding:6px 12px;
          font-size:12px; font-weight:600; cursor:pointer; white-space:nowrap; }
  .ft-toggles > button:hover, #refpick button:hover { background:rgba(56,189,248,.12); }
  #btn-reset { display:none; }
  #refpick { display:flex; align-items:center; gap:8px; }
  #ref-sel { color:var(--muted); font-size:11px; overflow:hidden; text-overflow:ellipsis;
             white-space:nowrap; max-width:280px; }

  /* expandable panels (advanced / audio) side by side */
  .ft-panels { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  @media (max-width:820px) { .ft-panels { grid-template-columns:1fr; } }
  #advset, #audioset { font-size:12px; color:var(--muted); background:var(--panel);
          border:1px solid var(--line); border-radius:12px; padding:8px 12px; }
  #advset summary, #audioset summary { cursor:pointer; font-weight:600; color:var(--text);
          list-style:none; display:flex; align-items:center; gap:6px; }
  #advset summary::-webkit-details-marker, #audioset summary::-webkit-details-marker { display:none; }
  #advset summary::before, #audioset summary::before { content:"▸"; color:var(--accent);
          transition:transform .15s; display:inline-block; }
  #advset[open] summary::before, #audioset[open] summary::before { transform:rotate(90deg); }
  #advset .advgroup { margin-top:8px; }
  #advset label { display:flex; gap:6px; align-items:center; margin-top:4px; cursor:pointer; }
  #planparams select, #planparams input[type=number] { background:var(--panel2); color:var(--text);
          border:1px solid var(--line); border-radius:6px; padding:3px 5px; font-size:11px; }
  #audioset input, #audioset textarea { display:block; width:100%; margin-top:6px;
          background:var(--panel2); color:var(--text); border:1px solid var(--line);
          border-radius:8px; padding:7px 10px; font:inherit; font-size:12px; outline:none; }
  #audioset textarea { height:44px; resize:vertical; }
  #btn-au-auto { padding:8px 14px; font-size:12px; margin-top:8px; background:transparent;
          color:var(--ok); border:1px solid var(--ok); border-radius:8px; cursor:pointer; }
  #au-status { font-size:11px; color:var(--muted); margin-left:8px; }

  /* compose row: textarea + send */
  .ft-compose { display:flex; gap:10px; align-items:flex-end; }
  textarea#input { flex:1; resize:none; height:58px; background:var(--panel); color:var(--text);
          border:1px solid var(--line); border-radius:12px; padding:11px 14px;
          font:inherit; font-size:14px; outline:none; transition:border-color .15s, box-shadow .15s; }
  textarea#input:focus { border-color:var(--accent); box-shadow:0 0 0 3px rgba(56,189,248,.15); }
  .ft-send { display:flex; flex-direction:column; gap:6px; }
  button { background:var(--grad); color:#fff; border:none; border-radius:12px;
           padding:13px 24px; font-size:14px; font-weight:700; cursor:pointer;
           transition:filter .15s, transform .05s; }
  button:hover { filter:brightness(1.12); }
  button:active { transform:translateY(1px); }
  button:disabled { opacity:.45; cursor:default; filter:none; }
  button.warn { background:var(--err); }
  .genplan { display:block; margin-top:10px; background:var(--ok); color:#0b2b1c; }
  .hint { color:var(--muted); font-size:11px; }

  /* 動画プロンプトの日本語説明（何が生成されるか一目でわかるように） */
  .promptja { margin:8px 0; border:1px solid var(--accent); border-radius:8px;
          padding:8px 10px; background:rgba(56,189,248,0.06); }
  .promptja .meta { margin-bottom:4px; }
  .promptja .ja-body { white-space:pre-wrap; word-break:break-word; font-size:13px; line-height:1.6; }

  /* thinking trace */
  details.thinkbox { margin:6px 0; border:1px solid var(--line); border-radius:8px;
          padding:6px 10px; background:rgba(255,255,255,0.02); }
  details.thinkbox summary { cursor:pointer; color:var(--muted); font-size:11px; user-select:none; }
  details.thinkbox pre { white-space:pre-wrap; word-break:break-word; color:var(--muted);
          font-size:11px; margin:6px 0 0; max-height:220px; overflow:auto; }

  /* reference image modal */
  .modal { position:fixed; inset:0; background:rgba(0,0,0,.65); display:none;
           align-items:center; justify-content:center; z-index:50; backdrop-filter:blur(2px); }
  .modal-box { background:var(--panel); border:1px solid var(--line); border-radius:14px;
               padding:16px; width:min(92vw,740px); max-height:82vh; display:flex;
               flex-direction:column; }
  .modal-box .meta { margin-bottom:10px; }
  .modal-box > button { align-self:flex-end; padding:8px 18px; }
  #refgrid { flex:1; overflow-y:auto; display:grid;
             grid-template-columns:repeat(auto-fill,minmax(140px,1fr));
             gap:10px; margin-bottom:12px; }
  .refcard { border:1px solid var(--line); border-radius:10px; overflow:hidden; cursor:pointer;
             background:var(--bg); transition:border-color .15s; position:relative; }
  .refcard:hover { border-color:var(--accent); }
  .refcard.sel { border-color:var(--ok); box-shadow:0 0 0 2px rgba(52,211,153,.35); }
  .refcard img { width:100%; height:90px; object-fit:cover; display:block; background:#000; }
  .refcard .refname { font-size:11px; padding:5px 6px 0; color:var(--text);
                      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .refcard .refdir { font-size:10px; padding:0 6px 6px; color:var(--muted); }
  .refcard .refbadge { position:absolute; top:4px; left:4px; background:var(--ok); color:#04120c;
                       border-radius:10px; font-size:11px; font-weight:700; padding:1px 8px; }
  .reffoot { display:flex; align-items:center; gap:10px; }
  .reffoot > span { flex:1; }

  /* key-image candidate grid */
  .imggrid { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr));
             gap:10px; margin-top:8px; }
  .imgcard { border:2px solid var(--line); border-radius:10px; overflow:hidden; cursor:pointer;
             background:var(--bg); transition:border-color .15s; }
  .imgcard:hover { border-color:var(--accent); }
  .imgcard.sel { border-color:var(--ok); box-shadow:0 0 0 2px rgba(52,211,153,.35); }
  .imgcard img { width:100%; height:110px; object-fit:cover; display:block; background:#000; }
  .imgcard .imgname { font-size:10px; padding:4px 6px; color:var(--muted);
                      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
</style>
</head>
<body>
<header>
  <button id="btn-sidebar" onclick="toggleSidebar()" title="履歴サイドバーを表示/非表示">☰</button>
  <h1>🎬 MiniMax H3 チャット動画生成</h1>
  <span class="sub">企画モード: キー画像（Z-Image Turbo）→ 確認 → 動画（H3・32B/4B）</span>
  <span id="status-dot" title="ComfyUI 接続状態"></span>
</header>
<div id="app">
<aside id="sidebar">
  <button id="btn-newchat" onclick="newChat()">➕ 新しい企画</button>
  <div id="sess-list"></div>
</aside>
<main id="msgs"></main>
</div>
<div id="shutdown-box">
  <div class="meta">生成完了 ✅ 自動停止まで <b id="countdown">90</b> 秒（GPU・メモリを解放します）</div>
  <button class="warn" onclick="stopAll()">🛑 今すぐすべて終了</button>
  <button onclick="stopComfy()">ComfyUI だけ停止</button>
  <button class="small" onclick="cancelStop()">キャンセル</button>
</div>
<div id="refmodal" class="modal">
  <div class="modal-box">
    <div class="meta">参照画像を選択（ComfyUI の output/・input/ にある画像から・クリックで複数選択・最大 9 枚）</div>
    <div id="refgrid"></div>
    <div class="reffoot">
      <span id="refpick-count" class="hint">0 枚選択中</span>
      <button onclick="applyRefPick()">✅ 参照画像として使う</button>
      <button onclick="closeRefModal()">閉じる</button>
    </div>
  </div>
</div>
<footer>
  <div class="ft-row">
    <div class="seg">
      <label class="segbtn"><input type="radio" name="mode" value="fast" checked><span>最高画質<small>spectrum・約15分</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="high"><span>高精度<small>32B・約9分</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="fast_quick"><span>高画質<small>spectrum・短尺</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="quick"><span>クイック<small>32B・2〜4分</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="lite"><span>軽量<small>4B・約9分</small></span></label>
      <label class="segbtn"><input type="radio" name="mode" value="quicklite"><span>最速<small>4B・短尺</small></span></label>
    </div>
    <div id="lenbox">
      <span>長さ:</span>
      <select id="len-sel" onchange="onLenChange()">
        <option value="">モードの既定</option>
        <option value="5">約5秒</option>
        <option value="10">約10秒</option>
        <option value="15">約15秒</option>
      </select>
      <span id="len-note" class="hint"></span>
    </div>
  </div>
  <div class="ft-toggles">
    <label class="plan"><input type="checkbox" id="planmode"> ✎ 企画モード</label>
    <label class="plan" title="ON のとき、確定したキー画像／選んだ参照画像を使って生成します（使い方は右で選択）"><input type="checkbox" id="refmode"> 🖼 画像モード</label>
    <label class="plan" title="📌 先頭フレーム固定 (I2V): 動画がこの画像から始まる／🏁 最終フレーム固定: 動画がこの画像で終わる／🎭 参照 (R2V): フレームは固定せず同一キャラだけ維持"><span class="hint">画像の使い方:</span>
      <select id="imguse">
        <option value="first" selected>📌 先頭フレーム固定（I2V）</option>
        <option value="last">🏁 最終フレーム固定</option>
        <option value="ref">🎭 参照・キャラ維持（R2V）</option>
      </select>
    </label>
    <div id="refpick">
      <button type="button" onclick="pickRefImage()">🗂 参照画像を選ぶ</button>
      <span id="ref-sel" class="hint">未選択（企画モードで確定したキー画像を使用）</span>
      <button type="button" id="ref-clear" onclick="clearRefImage()" style="display:none" title="参照画像の選択を解除する">✕ 解除</button>
    </div>
    <button type="button" id="btn-reset" onclick="resetPlan()">🔄 新しい企画</button>
    <button type="button" id="btn-manual" onclick="showManualPrompt()">✍ 手動プロンプト</button>
  </div>
  <div class="ft-panels">
    <details id="advset">
      <summary>⚙ 詳細設定（動画モデル・キー画像エンジン・企画 LLM）</summary>
      <div class="advgroup">
        <span class="hint">動画モデル:</span>
            <label><input type="radio" name="dit" value="default" checked> 10Eros NVFP4（高画質・11.7GB・既定）</label>
            <label><input type="radio" name="dit" value="pinkcherry"> PinkCherry int8（旧既定・19.5GB）</label>
      </div>
      <div class="advgroup">
        <span class="hint">品質チューニング（任意・空欄 = 既定値）:</span>
        <label title="参照画像を短辺 2048px で使う（MiniMax H3 の ref_image_size=max）。なりきり精度は最高だが、参照トークンが毎ステップに乗るため数倍遅い。R2V（参照）モードのみ効果。"><input type="checkbox" id="refsize-max"> 🔍 参照画像を高解像度で使う（max・低速・R2V のみ）</label>
        <label>EasyCache 閾値:<input type="number" id="tune-easycache" min="0" max="1" step="0.05" placeholder="0.1" style="width:70px"><span class="hint">高い=速い・粗い（spectrum 系モードには無し）</span></label>
        <label>Turbo LoRA 強度:<input type="number" id="tune-lora" min="0" max="2" step="0.1" placeholder="1.2" style="width:70px"><span class="hint">turbo 系モードのみ</span></label>
        <label>保存 crf:<input type="number" id="tune-crf" min="0" max="51" step="1" placeholder="23" style="width:70px"><span class="hint">低い=高画質・大容量（再エンコード）</span></label>
      </div>
      <div class="advgroup">
        <span class="hint">キー画像:</span>
        <label><input type="radio" name="imgengine" value="qimg" checked> Qwen-Image 2512（高画質・4候補）</label>
        <label><input type="radio" name="imgengine" value="zimg"> Z-Image Turbo（最速）</label>
      </div>
      <div class="advgroup" id="planmodelset">
        <span class="hint">企画 LLM モデル（導入済みから選択・GPU 固定ではありません）:</span>
        <label>モデル:<select id="p-model" onchange="selectPlanModel()" style="max-width:420px"></select></label>
        <span id="p-model-status" class="hint"></span>
      </div>
      <div class="advgroup" id="planparams">
        <span class="hint">企画 LLM パラメータ:</span>
        <label>KV キー:<select id="p-ctk" onchange="sendPlanSettings()"><option value="q8_0" selected>q8_0</option><option value="q4_0">q4_0</option><option value="f16">f16</option><option value="none">なし</option></select></label>
        <label>KV 値:<select id="p-ctv" onchange="sendPlanSettings()"><option value="q4_0" selected>q4_0</option><option value="q8_0">q8_0</option><option value="f16">f16</option><option value="none">なし</option></select></label>
        <label><input type="checkbox" id="p-fa" checked onchange="sendPlanSettings()"> フラッシュアテンション</label>
        <label>推論:<select id="p-reasoning" onchange="sendPlanSettings()"><option value="medium" selected>medium</option><option value="low">low</option><option value="off">off</option><option value="xhigh">xhigh</option></select></label>
        <label>予算:<input type="number" id="p-budget" value="1536" min="0" max="32768" step="256" style="width:70px" onchange="sendPlanSettings()"></label>
      </div>
    </details>
    <details id="audioset">
      <summary>🎙 音声・セリフ設定（任意）</summary>
      <input type="text" id="au-voice" placeholder="声: 例：低めの落ち着いた声・息を含むささやき">
      <textarea id="au-dialogue" placeholder="セリフ: 例：今夜は帰らないで"></textarea>
      <input type="text" id="au-sfx" placeholder="効果音・環境音: 例：夜の雨音・布擦れ・遠い車の音">
      <input type="text" id="au-music" placeholder="音楽: 例：ゆっくりしたピアノ">
      <button type="button" id="btn-au-auto" onclick="autoAudio()">🎙 自動で考える（LLM）</button>
      <span id="au-status" class="hint"></span>
    </details>
  </div>
  <div class="ft-compose">
    <textarea id="input" placeholder="作りたい動画を言葉で書いてください。例：夕焼けの海岸で柴犬が波打ち際を走る映像"></textarea>
    <div class="ft-send">
      <button id="send" onclick="send()">生成 ▶</button>
      <button id="cancel" class="warn" style="display:none" onclick="cancelCurrent()">✕ キャンセル</button>
    </div>
  </div>
</footer>
<script>
const $ = s => document.querySelector(s);
let busy = false;
let jobCancelled = false;
let curJobId = null;
let lastImgPrompt = null;
let lastFinalPrompt = null;
// 参照画像リスト（順序付き・[0] が主参照 = <Picture 1>）。企画モードで確定した
// キー画像は 1 要素だけ入る。🗂 ピッカーで複数（最大 9 枚）選べる。
let refImages = [];
// ピッカーが開いている間の一時選択（「適用」で refImages に反映）
let refPickerSelection = [];
let planStage = "chat";   // chat -> image -> video -> done
// 参照モードで「どんな動画にするか」を相談中かどうか。最初の1ターンだけ
// 企画 LLM に"いきなり FINAL_PROMPT を作らず相談して"という指示を付ける。
let refConsultActive = false;
let shutdownTimer = null;
let shutdownLeft = 0;
// セッション履歴（サイドバー）: 今表示中のセッション id
// （null = まだ一度も保存されていない新しい企画）
let activeSessionId = null;
let lastSavedJson = "";   // 自動保存の重複排除（中身 unchanged なら送らない）
let curJobKind = null;    // "video" | "image" | "upscale" — セッション復元時のジョブ再開用
// 動画の続きもの（セグメント連鎖）: extendVideo で始まり、続きセグメントが
// 完成するたびに伸びる。2 本以上で「結合」ボタンが出る。
let segmentChain = [];    // 順序付きファイル名リスト
let extendFrom = null;    // 今生成中の続きセグメントの「元の動画」

function addMsg(kind, html) {
  const el = document.createElement("div");
  el.className = "msg " + kind;
  el.innerHTML = html;
  $("#msgs").appendChild(el);
  $("#msgs").scrollTop = $("#msgs").scrollHeight;
  return el;
}

function esc(s) {
  return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
}

// Collapsible "thinking" trace from the planning LLM (reasoning_content).
function thinkHtml(t) {
  if (!t) return "";
  return '<details class="thinkbox"><summary>💭 企画 LLM の考え中（' + t.length + '字）</summary><pre>' + esc(t) + "</pre></details>";
}

function setBusy(b) {
  busy = b;
  $("#send").disabled = b;
  $("#cancel").style.display = b ? "" : "none";
}

async function checkServer() {
  try {
    const r = await fetch("/api/queue");
    if (r.ok) { $("#status-dot").className = "ok"; return true; }
  } catch (e) {}
  $("#status-dot").className = "down";
  return false;
}
setInterval(checkServer, 5000);
checkServer();
loadPlanModels();

function ditValue() {
  const el = document.querySelector('input[name="dit"]:checked');
  return el ? el.value : "default";
}

function audioSpec() {
  return {
    dialogue: $("#au-dialogue").value.trim(),
    voice: $("#au-voice").value.trim(),
    sfx: $("#au-sfx").value.trim(),
    music: $("#au-music").value.trim()
  };
}

// 「長さ」ドロップダウン: 空ならモードの既定、選べばその秒数（H3 の
// フレームグリッドへはサーバー側でスナップされる）。
function lenValue() {
  const v = $("#len-sel").value;
  return v ? parseInt(v, 10) : null;
}function onLenChange() {
  const v = $("#len-sel").value;
  $("#len-note").textContent = v ? "（約" + v + "秒で生成）" : "";
}

// Send planner KV/FA/reasoning settings to the backend.
function sendPlanSettings() {
  const ctk = $("#p-ctk");
  const ctv = $("#p-ctv");
  const fa = $("#p-fa");
  const re = $("#p-reasoning");
  const rb = $("#p-budget");
  if (!ctk) return;
  fetch("/api/plan-settings", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      ctk: ctk.value, ctv: ctv.value,
      fa: fa.checked, reasoning_effort: re.value,
      reasoning_budget: parseInt(rb.value, 10) || 1536
    })
  }).catch(() => {});
}

// 企画 LLM モデル: 導入済み GGUF をサーバーから取得してドロップダウン表示。
// 選ぶと実行中の企画 LLM が停止し、次のメッセージから新モデルで起動する。
async function loadPlanModels() {
  const sel = $("#p-model");
  if (!sel) return;
  try {
    const r = await fetch("/api/plan-models");
    const j = await r.json();
    if (!r.ok) return;
    sel.innerHTML = "";
    (j.models || []).forEach(m => {
      const o = document.createElement("option");
      o.value = m.path;
      o.dataset.mmproj = m.mmproj || "";
      o.dataset.gpu = m.gpu ? "1" : "0";
      o.textContent = m.label + "（" + m.size_gb + "GB・" + (m.gpu ? "GPU" : "CPU") + (m.vision ? "・視覚" : "") + "）";
      if (j.current && m.path === j.current.path) o.selected = true;
      sel.appendChild(o);
    });
    const st = $("#p-model-status");
    if (st) {
      if (j.external) st.textContent = "外部エンドポイント（--plan-url）が設定されています。";
      else if (!j.current || !j.current.path) st.textContent = "⚠ 企画 LLM のモデルが見つかりません（LM Studio に GGUF を追加してください）";
      else st.textContent = j.running ? "稼働中。切り替えると次回メッセージから反映。" : "停止中。次のメッセージで自動起動。";
    }
  } catch (e) {}
}

async function selectPlanModel() {
  const sel = $("#p-model");
  const o = sel.options[sel.selectedIndex];
  if (!o) return;
  const st = $("#p-model-status");
  if (st) st.textContent = "切り替え中（稼働中の企画 LLM を停止します）…";
  try {
    const r = await fetch("/api/plan-model", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({path: o.value, mmproj: o.dataset.mmproj || null, gpu: o.dataset.gpu === "1"})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    if (st) st.textContent = j.note || "切り替えました。";
  } catch (e) {
    if (st) st.textContent = "切替エラー: " + e.message;
  }
}




async function autoAudio() {
  const btn = $("#btn-au-auto");
  if (btn.disabled) return;
  const concept = lastFinalPrompt || lastImgPrompt || $("#input").value.trim();
  if (!concept) {
    $("#au-status").textContent = "生成したい映像の説明を先に入力してください。";
    return;
  }
  btn.disabled = true;
  $("#au-status").textContent = "企画 LLM が音響を考え中…";
  try {
    const r = await fetch("/api/audio", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: concept})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    const a = j.audio || {};
    let filled = 0;
    if (a.voice) { $("#au-voice").value = a.voice; filled++; }
    if (a.dialogue) { $("#au-dialogue").value = a.dialogue; filled++; }
    if (a.sfx) { $("#au-sfx").value = a.sfx; filled++; }
    if (a.music) { $("#au-music").value = a.music; filled++; }
    $("#au-status").textContent = filled ? ("✅ 自動提案を反映（" + filled + "項目・編集可）") : "提案が取得できませんでした。";
  } catch (e) {
    $("#au-status").textContent = "エラー: " + e.message;
  }
  btn.disabled = false;
}

async function pickRefImage() {
  try {
    const r = await fetch("/api/refimages");
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    const grid = $("#refgrid");
    grid.innerHTML = "";
    // 既存の選択を引き継ぐ（後から追加・削除できるように）
    refPickerSelection = refImages.slice();
    const imgs = j.images || [];
    for (const img of imgs) {
      const c = document.createElement("div");
      c.className = "refcard";
      c.dataset.path = img.path;
      c.innerHTML =
        '<img src="/api/refimg?path=' + encodeURIComponent(img.path) + '" loading="lazy">' +
        '<div class="refname">' + esc(img.name) + '</div>' +
        '<div class="refdir">' + esc(img.dir) + '</div>' +
        '<div class="refbadge" style="display:none"></div>';
      c.onclick = () => toggleRefPick(c, img.path);
      grid.appendChild(c);
    }
    if (!imgs.length) {
      grid.innerHTML = '<div class="hint">参照に使える画像がありません。ComfyUI output/ に生成結果、input/ に手動配置の画像を置いてください。</div>';
    }
    refreshRefGridMarks();
    updateRefPickCount();
    $("#refmodal").style.display = "flex";
  } catch (e) {
    alert("参照画像一覧の取得に失敗: " + e.message);
  }
}
// カードクリックで選択トグル。順序が <Picture N> の番号になる。
function toggleRefPick(card, path) {
  const i = refPickerSelection.indexOf(path);
  if (i >= 0) {
    refPickerSelection.splice(i, 1);
  } else {
    if (refPickerSelection.length >= 9) {
      alert("参照画像は最大 9 枚までです（MiniMax H3 の上限）");
      return;
    }
    refPickerSelection.push(path);
  }
  refreshRefGridMarks();
  updateRefPickCount();
}
function refreshRefGridMarks() {
  const grid = $("#refgrid");
  for (const c of grid.children) {
    if (!c.dataset || !c.dataset.path) continue;
    const idx = refPickerSelection.indexOf(c.dataset.path);
    const badge = c.querySelector ? c.querySelector(".refbadge") : null;
    if (idx >= 0) {
      c.className = "refcard sel";
      if (badge) { badge.style.display = ""; badge.textContent = String(idx + 1); }
    } else {
      c.className = "refcard";
      if (badge) { badge.style.display = "none"; badge.textContent = ""; }
    }
  }
}
function updateRefPickCount() {
  const n = refPickerSelection.length;
  $("#refpick-count").textContent = n ? n + " 枚選択中（番号が <Picture N> の順番）" : "0 枚選択中";
}
// ピッカーの選択を確定する。0 枚で適用 = 選択解除。
function applyRefPick() {
  refImages = refPickerSelection.slice();
  // 新しい参照画像を選んだ＝新しい企画の始まりなので、相談フラグをリセット
  refConsultActive = false;
  if (refImages.length) {
    // 🗂 からの選択は「このキャラを使って動画を作りたい」意味なので、
    // 既定の使い方は参照（R2V）。先頭フレーム固定にしたければ UI で切替可。
    $("#imguse").value = "ref";
    updateRefSel();
    const clr = $("#ref-clear");
    if (clr) clr.style.display = "inline-block";
  } else {
    clearRefImage();
  }
  closeRefModal();
}
function closeRefModal() { $("#refmodal").style.display = "none"; }
// フッターの選択表示を更新する（1 枚目ファイル名 + 枚数）。
function updateRefSel() {
  const sel = $("#ref-sel");
  if (!refImages.length) {
    sel.textContent = "未選択（企画モードで確定したキー画像を使用）";
    return;
  }
  const name = refImages[0].split(/[\\/]/).pop();
  sel.textContent = refImages.length === 1
    ? name
    : name + " ほか計 " + refImages.length + " 枚（<Picture 1.." + refImages.length + ">）";
}

// チャット指示（「高画質で/長めに」等）による設定上書きが効いているとき、
// 生成開始メッセージに追記して「知らない間に別の設定で生成されていた」を防ぐ。
function overrideNote(bot, j) {
  if (!bot || !j || !j.override_label) return;
  const n = document.createElement("div");
  n.className = "hint";
  n.textContent = "⚙ チャット指示を反映中: " + j.override_label + "（UI のモード/長さより優先・解除は 🔄 新しい企画）";
  bot.appendChild(n);
}
// このモードでは効かなかった品質チューニング設定（fast 系の EasyCache 無し等）を
// サーバーから受け取って表示する（サイレントに無視しない）。
function tuneNote(bot, j) {
  if (!bot || !j || !(j.tune_ignored || []).length) return;
  const n = document.createElement("div");
  n.className = "hint";
  n.textContent = "⚙ 反映されなかった設定: " + j.tune_ignored.join("、");
  bot.appendChild(n);
}
// フレーム固定（first/last）に複数画像が選ばれている場合、使われるのは
// 1 枚目だけで残りは無視される。その旨を明示する（黙って裏切らない）。
function refUsageNote(bot) {
  if (!bot) return;
  if (refImages.length > 1 && $("#imguse").value !== "ref") {
    const n = document.createElement("div");
    n.className = "hint";
    n.textContent = "⚠ フレーム固定には 1 枚目の参照画像だけ使われます（残り " + (refImages.length - 1) + " 枚は無視・すべて使うには 🎭 参照を選んでください）";
    bot.appendChild(n);
  }
}
// 詳細設定の品質チューニング（空欄 = ワークフロー既定値を送らない）。
function tuneSpec() {
  const t = {};
  const ec = $("#tune-easycache") ? $("#tune-easycache").value.trim() : "";
  const lo = $("#tune-lora") ? $("#tune-lora").value.trim() : "";
  const crf = $("#tune-crf") ? $("#tune-crf").value.trim() : "";
  if (ec) t.easycache = parseFloat(ec);
  if (lo) t.lora = parseFloat(lo);
  if (crf) t.crf = parseFloat(crf);
  return t;
}

// 参照画像の選択を解除する。一度 🗂 で選ぶと refImages が残り、
// 以降の生成が全て勝手に R2V（参照あり）になってしまうため、明示的に
// 解除できる手段が必要（「画像を参照したくないのに参照される」事故の対策）。
function clearRefImage() {
  refImages = [];
  refPickerSelection = [];
  refConsultActive = false;
  updateRefSel();
  const c = $("#ref-clear");
  if (c) c.style.display = "none";
}

async function send() {
  const text = $("#input").value.trim();
  if (!text || busy) return;
  setBusy(true);
  $("#input").value = "";
  addMsg("user", esc(text));
  if ($("#planmode").checked) { plan(text); return; }
  if ($("#refmode").checked && !refImages.length) {
    addMsg("bot", '<div class="meta">参照画像が未設定です。✎ 企画モードでキー画像を確定するか、下部の「🗂 参照画像を選ぶ」から既存の画像を指定してください。</div>');
    setBusy(false);
    return;
  }
  if ($("#refmode").checked) {
    // 画像モードは「どんな動画にするか」を決めずに長時間の生成を始めない。
    // 企画 LLM に画像を見せながら内容を相談し、[FINAL_PROMPT] を
    // ユーザーが確認してから生成する（企画モードと同じ確認フロー）。
    planStage = "video";
    const first = !refConsultActive;
    refConsultActive = true;
    plan(text, first);
    return;
  }
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  const mode = document.querySelector('input[name="mode"]:checked').value;
  try {
    jobCancelled = false;
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        mode: mode, text: text, dit: ditValue(),
        // 選んだ画像は常に参照される（画像モード checkbox が OFF でも自動有効）。
        // 「画像を入れたのに無視されて無関係な動画ができる」事故の根本対策。
        ref: $("#refmode").checked || refImages.length > 0,
        image: refImages[0] || null, images: refImages,
        image_use: $("#imguse").value,
        ref_size: ($("#refsize-max") && $("#refsize-max").checked) ? "max" : "match",
        tune: tuneSpec(),
        audio: audioSpec(), length: lenValue()
      })
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    overrideNote(bot, j);
    refUsageNote(bot);
    tuneNote(bot, j);
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function plan(text, refStart) {
  const meta = refStart
    ? "企画 LLM が参照画像を見て、動画の内容を相談しています…"
    : "企画 LLM が考え中…";
  const bot = addMsg("bot", '<div class="meta">' + meta + "</div>");
  try {
    const r = await fetch("/api/plan", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: text, stage: planStage, image: refImages[0] || null, images: refImages, ref_start: !!refStart})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    let html = '<div class="meta">企画案</div>' + thinkHtml(j.thinking) + esc(j.reply || "（応答なし）");
    if (j.img_prompt) {
      lastImgPrompt = j.img_prompt;
      const revising = (planStage === "image");
      planStage = "image";
      // どんな画像になるか日本語で必ず示す（英語プロンプトだけだと内容が分からない
      // 問題の対策・動画側の「こんな映像になります」と同じ仕組み）。
      if (j.img_prompt_ja) {
        html += '<div class="promptja"><div class="meta">🖼 こんな画像になります</div><div class="ja-body">' + esc(j.img_prompt_ja) + "</div></div>";
      }
      html += '<details class="thinkbox"><summary>📝 英語プロンプト（原文・クリックで表示）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.img_prompt) + '</pre></details>';
      // 修正時も自動で再生成せず、必ずボタンを出す（ユーザーが確認してから
      // 生成を始める）。自動 genImage は qimg（約20分）を勝手に回して
      // 「再生成します…」のまま固まる原因になっていた。
      html += '<button class="genplan" onclick="genImage()">' +
        (revising ? "🖼 このプロンプトで再生成 ▶" : "🖼 キー画像を生成 ▶") + "</button>";
      html += '<div class="hint">画像を確認して OK なら確定、気に入らなければ「🔁 修正する」で修正できます。</div>';
    } else if (j.final_prompt) {
      // Store the prompt in a module variable instead of inlining it into the
      // onclick attribute: prompts may contain double quotes / HTML special
      // characters that would break the inline-JSON escaping.
      lastFinalPrompt = j.final_prompt;
      planStage = "video";
      // どんな映像になるか日本語で必ず示す（英語プロンプトだけだと内容が分からない
      // 問題の対策）。日本語説明を主表示し、英語原文は折りたたみに格納する。
      if (j.final_prompt_ja) {
        html += '<div class="promptja"><div class="meta">🎬 こんな映像になります</div><div class="ja-body">' + esc(j.final_prompt_ja) + "</div></div>";
      }
      html += '<details class="thinkbox"><summary>📝 英語プロンプト（原文・クリックで表示）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.final_prompt) + '</pre></details>';
      html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
    } else if (planStage === "video") {
      // 動画内容の相談中（参照モード開始直後など）。進め方を案内する。
      html += '<div class="hint">LLM の質問に答えて動画の内容を固めてください。「まとめて」「プロンプト確定」で [FINAL_PROMPT] を作ります。' +
        '画質・長さ・向きもチャットで調整できます（例：「もっと高画質で」「長めに」「縦長で」）。' +
        '自分でプロンプトを書きたい場合は下の「✍ 手動プロンプト」から直接入力できます。</div>';
      html += '<button class="genplan" style="background:transparent;color:var(--accent);border:1px solid var(--accent)" onclick="showManualPrompt()">✍ 手動プロンプトで生成する</button>';
    }
    if (j.audio && (j.audio.voice || j.audio.dialogue || j.audio.sfx || j.audio.music)) {
      if (j.audio.voice) $("#au-voice").value = j.audio.voice;
      if (j.audio.dialogue) $("#au-dialogue").value = j.audio.dialogue;
      if (j.audio.sfx) $("#au-sfx").value = j.audio.sfx;
      if (j.audio.music) $("#au-music").value = j.audio.music;
      html += '<div class="meta">🎙 音声・セリフ設定を自動提案しました（下部の設定欄に反映・編集可）</div>';
    }
    bot.innerHTML = html;
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
  setBusy(false);
}

function imgEngine() {
  const el = document.querySelector('input[name="imgengine"]:checked');
  return el ? el.value : "qimg";
}

async function genImage(prevBot) {
  if (!lastImgPrompt) {
    addMsg("bot", '<div class="meta">⚠ 生成する画像プロンプトがありません。企画 LLM に案を出してもらってください。</div>');
    return;
  }
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了するまでお待ちください。</div>');
    return;
  }
  jobCancelled = false;
  const eng = imgEngine();
  const label = eng === "qimg" ? "Qwen-Image 2512（4候補・約20分）" : "Z-Image Turbo（数秒）";
  const bot = prevBot || addMsg("bot", '<div class="meta">' + label + ' でキー画像を生成中…</div>');
  setBusy(true);
  try {
    const r = await fetch("/api/zimg", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: lastImgPrompt, engine: eng})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    pollImage(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function pollImage(id, bot) {
  if (jobCancelled) return;
  curJobId = id;
  curJobKind = "image";
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const imgs = (j.videos || []).filter(v => v.kind === "image");
      if (!imgs.length) {
        bot.innerHTML = '<div class="meta">エラー</div><div class="err">画像が見つかりませんでした</div>';
        curJobId = null;
        curJobKind = null;
        setBusy(false);
        return;
      }
      // 全候補をギャラリー表示して選べるようにする（最後の1枚だけ問題の修正）
      refImages = [imgs[0].filename];
      updateRefSel();
      let grid = '<div class="imggrid">';
      imgs.forEach((img, i) => {
        grid +=
          '<div class="imgcard' + (i === 0 ? " sel" : "") + '" data-fn="' + esc(img.filename) + '" onclick="pickKeyImage(this)">' +
          '<img src="/api/view?filename=' + encodeURIComponent(img.filename) + '&type=' + encodeURIComponent(img.type || "output") + '">' +
          '<div class="imgname">' + esc(img.filename) + "</div></div>";
      });
      grid += "</div>";
      bot.innerHTML =
        '<div class="meta">キー画像 ✅（' + imgs.length + '枚・クリックで選択）</div>' +
        grid +
        '<div class="row">' +
        '<button class="ok" onclick="confirmImage()">✅ この画像で確定 → 動画を相談</button>' +
        '<button class="rev" onclick="genImage()">🎲 同じプロンプトで引き直す</button>' +
        '<button class="rev" onclick="reviseImage()">🔁 修正する</button>' +
        "</div>";
      planStage = "image";
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "画像生成に失敗しました") + "</div>";
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      return;
    }
    bot.querySelector(".meta").textContent = "キー画像生成中… " + (j.extra || "");
    if (jobCancelled) return;
    setTimeout(() => pollImage(id, bot), 2000);
  } catch (e) {
    if (jobCancelled) return;
    setTimeout(() => pollImage(id, bot), 2000);
  }
}

function pickKeyImage(card) {
  const grid = card.parentElement;
  grid.querySelectorAll(".imgcard").forEach(c => c.classList.remove("sel"));
  card.classList.add("sel");
  refImages = [card.dataset.fn];
  updateRefSel();
}

function reviseImage() {
  planStage = "image";
  $("#input").placeholder = "修正したい点を入力（例：犬を白く、夕焼けをもっと赤く）";
  $("#input").focus();
}

function confirmImage() {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから画像を確定してください。</div>');
    return;
  }
  if (!refImages.length) {
    addMsg("bot", '<div class="meta">⚠ 確定する画像がありません。画像を生成してから選んでください。</div>');
    return;
  }
  // 企画モードで確定したキー画像は「動画の1フレーム目」約束なので、
  // 既定の使い方を先頭フレーム固定 (I2V) にする（参照にしたければ UI で切替可）。
  $("#imguse").value = "first";
  setBusy(true);
  const bot = addMsg("bot", '<div class="meta">企画 LLM と動画の内容を相談中…（Z-Image はアンロード済み）</div>');
  (async () => {
    try {
      const r = await fetch("/api/plan", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({text: "__CONFIRM_IMAGE__", stage: "video", image: refImages[0] || null})
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      let html = '<div class="meta">画像を確定 ✅（ここから動画の内容を相談します）</div>' + thinkHtml(j.thinking) + esc(j.reply || "（応答なし）");
      if (j.final_prompt) {
        lastFinalPrompt = j.final_prompt;
        planStage = "video";
        if (j.final_prompt_ja) {
          html += '<div class="promptja"><div class="meta">🎬 こんな映像になります</div><div class="ja-body">' + esc(j.final_prompt_ja) + "</div></div>";
        }
        html += '<details class="thinkbox"><summary>📝 英語プロンプト（原文・クリックで表示）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.final_prompt) + '</pre></details>';
        html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
      } else {
        planStage = "video";
        html += '<div class="hint">LLM の質問に答えて動画の内容を固めてください。「まとめて」「プロンプト確定」で [FINAL_PROMPT] を作ります。' +
          '画質・長さ・向きもチャットで調整できます（例：「もっと高画質で」「長めに」「縦長で」「30秒で」）。' +
          '自分でプロンプトを書きたい場合は下の「✍ 手動プロンプト」から直接入力できます。</div>';
      }
      html += '<button class="genplan" style="background:transparent;color:var(--accent);border:1px solid var(--accent)" onclick="showManualPrompt()">✍ 手動プロンプトで生成する</button>';
      bot.innerHTML = html;
    } catch (e) {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    }
    setBusy(false);
  })();
}

function showManualPrompt() {
  // 生成中に開けると、🎬 側の busy ガードに当たって「押しても何も起きない」
  // ことになるので、先に開かない。
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから「✍ 手動プロンプト」を開いてください。</div>');
    return;
  }
  const bot = addMsg("bot",
    '<div class="meta">✍ 手動プロンプト</div>' +
    '<textarea id="manual-prompt" style="width:100%;height:110px;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:8px;padding:8px;font:inherit;font-size:13px" placeholder="動画プロンプトを英語で直接入力（例: [Shot 1] The woman turns to the camera and smiles, the camera slowly dollies in...）"></textarea>' +
    '<div class="row"><button class="ok" onclick="useManualPrompt(this)">🎬 このプロンプトで生成 ▶</button></div>');
  bot.querySelector("#manual-prompt").focus();
}

function useManualPrompt(btn) {
  // 手動プロンプト UI は何度でも開けてメッセージが残るため、
  // document.querySelector だと古い（空の）textarea が先にヒットして
  // 無反応になる。必ず自分のメッセージ内の textarea を読む。
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから実行してください。</div>');
    return;
  }
  const msg = btn ? btn.closest(".msg") : null;
  const ta = msg ? msg.querySelector("#manual-prompt") : document.querySelector("#manual-prompt");
  const text = ta ? ta.value.trim() : "";
  if (!text) {
    addMsg("bot", '<div class="meta">⚠ プロンプトが空です。上の入力欄に動画プロンプトを書いてから押してください。</div>');
    return;
  }
  lastFinalPrompt = text;
  planStage = "video";
  addMsg("user", "✍ 手動プロンプトで生成: " + text);
  genPlanLast();
}

function imageUseTag() {
  // 生成開始メッセージに「画像がどう使われるか」を明示する。
  // 「いつの間にか別の使い方で生成されていた」を防ぐための表示。
  const use = $("#imguse").value;
  if (use === "first") return "📌 先頭フレーム固定で生成する: ";
  if (use === "last") return "🏁 最終フレーム固定で生成する: ";
  return "🎭 参照モード（R2V）で生成する: ";
}

function genPlanLast() {
  // 無言で return すると「ボタンが動かない」ように見える。必ず理由を表示する。
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了するまでお待ちください。</div>');
    return;
  }
  if (!lastFinalPrompt) {
    addMsg("bot", '<div class="meta">⚠ 生成するプロンプトがありません。「✍ 手動プロンプト」で入力するか、企画を再相談してください。</div>');
    return;
  }
  const finalPrompt = lastFinalPrompt;
  // lastFinalPrompt は消さない: 生成が失敗・キャンセルされたとき、同じボタンで
  // そのままやり直せる必要がある（以前はここで null にしていて、失敗すると
  // 「プロンプトがありません」になり企画の再相談を強要していた。genImage が
  // lastImgPrompt を保持するのと同じ挙動に揃える）。
  setBusy(true);
  const mode = document.querySelector('input[name="mode"]:checked').value;
  // キー画像（refImages）がある場合は checkbox に関係なく画像モード
  const useRef = $("#refmode").checked || refImages.length > 0;
  const tag = useRef ? imageUseTag() : "✅ この企画で生成する: ";
  addMsg("user", tag + finalPrompt);
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  doGenerate(mode, finalPrompt, bot);
}

async function doGenerate(mode, text, bot) {
  try {
    jobCancelled = false;
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({
        mode: mode, text: text, dit: ditValue(),
        // 選んだ画像は常に参照される（画像モード checkbox が OFF でも自動有効）。
        // 「画像を入れたのに無視されて無関係な動画ができる」事故の根本対策。
        ref: $("#refmode").checked || refImages.length > 0,
        image: refImages[0] || null, images: refImages,
        image_use: $("#imguse").value,
        ref_size: ($("#refsize-max") && $("#refsize-max").checked) ? "max" : "match",
        tune: tuneSpec(),
        audio: audioSpec(), length: lenValue()
      })
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    overrideNote(bot, j);
    refUsageNote(bot);
    tuneNote(bot, j);
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function poll(id, bot, kind) {
  curJobId = id;
  const k = kind || "video";
  curJobKind = k;
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const vids = j.videos || [];
      if (!vids.length) {
        bot.innerHTML = '<div class="meta">エラー</div><div class="err">生成は完了しましたが出力が見つかりませんでした。もう一度お試しください。</div>';
        curJobId = null;
        curJobKind = null;
        setBusy(false);
        return;
      }
      const v = vids[0];
      // 続きセグメントが完成したら連鎖を伸ばす（結合ボタン用）
      if (curJobKind === "video" && extendFrom) {
        segmentChain.push(v.filename);
        extendFrom = null;
      }
      const isUpscale = curJobKind === "upscale";
      bot.innerHTML = '<div class="meta">' + (isUpscale ? "アップスケール完了 ✅" : "完成 ✅") + "</div>" +
        '<video controls autoplay loop muted src="/api/view?filename=' + encodeURIComponent(v.filename) +
        '&type=' + encodeURIComponent(v.type || "output") + '"></video>' +
        '<div class="path">' + esc(v.path) + "</div>" +
        (isUpscale ? "" : videoActionsHtml(v.filename));
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      if (!isUpscale) startShutdown();
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "失敗しました") + "</div>";
      curJobId = null;
      curJobKind = null;
      setBusy(false);
      return;
    }
    // still running: refresh the eta text every poll
    const el = Math.floor((j.elapsed_sec || 0) / 60);
    const es = String((j.elapsed_sec || 0) % 60).padStart(2, "0");
    const eta = j.eta_sec || 0;
    let etaTxt;
    if (eta <= (j.elapsed_sec || 0)) etaTxt = "予定より長引いています…";
    else if (eta >= 60) etaTxt = "残り 約" + Math.round(eta / 60) + "分";
    else etaTxt = "残り 約" + eta + "秒";
    bot.querySelector(".meta").textContent =
      "生成中… " + etaTxt + "（経過 " + el + ":" + es + "・待機中: " + j.pending + " 件）";
    if (jobCancelled) return;   // キャンセル済み: ポーリング停止
    // show a cancel button once so a stuck/stale queue item can be cleared
    if (!bot.querySelector(".cancelbtn")) {
      const b = document.createElement("button");
      b.className = "warn small cancelbtn";
      b.textContent = "✕ キャンセル";
      b.onclick = () => cancelJob(id, bot);
      bot.appendChild(b);
    }
    setTimeout(() => poll(id, bot, k), 3000);
  } catch (e) {
    setTimeout(() => poll(id, bot, k), 3000);
  }
}

async function cancelJob(id, bot) {
  jobCancelled = true;
  setBusy(false);
  try {
    await fetch("/api/cancel", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({prompt_id: id})
    });
  } catch (e) {}
  if (curJobId === id) {
    curJobId = null;
    curJobKind = null;
  }
  if (bot) {
    const meta = bot.querySelector(".meta");
    if (meta) meta.textContent = "キャンセルしました（ComfyUI のジョブを中断・削除）";
    const cb = bot.querySelector(".cancelbtn");
    if (cb) cb.remove();
  }
}

async function cancelCurrent() {
  if (!curJobId) {
    // busy 中でもジョブ ID が無い = 企画 LLM の応答待ち。無言で返すと
    // 「キャンセルが効かない」ように見えるので、理由を表示する。
    addMsg("bot", '<div class="meta">⚠ 実行中のジョブがありません。企画 LLM の応答待ちの場合は、応答後に操作できます。</div>');
    return;
  }
  const id = curJobId;
  await cancelJob(id, null);
  addMsg("bot", '<div class="meta">キャンセルしました。</div>');
}

// ---- 動画の続き / アップスケール / 結合 ---------------------------------

function encArg(s) {
  // onclick 属性内の JS 文字列に安全に埋め込むためのエンコード。
  // encodeURIComponent は ' を残すので %27 に畳む（属性の引用符は &quot;
  // 経由で二重引用符になるが、' も畳んでおく方が安全）。
  return encodeURIComponent(s).replace(/'/g, "%27");
}

function videoActionsHtml(fn) {
  // 動画完成メッセージに出すボタン群。ファイル名はエンコードして inline の
  // onclick に載せる（セッション復元 = innerHTML シリアライズ後も動くように）。
  // 属性内の JS 文字列引用符は &quot;（HTML エンティティ）で渡す — このテン
  // プレートは Python の通常文字列なのでバックスラッシュは使えない。
  let html = '<div class="row">' +
    '<button class="ok" onclick="extendVideo(decodeURIComponent(&quot;' + encArg(fn) + '&quot;))">▶ この動画の続きを作る</button>' +
    '<button class="rev" onclick="upscaleVideo(decodeURIComponent(&quot;' + encArg(fn) + '&quot;))">🔍 アップスケール（2倍）</button>' +
    "</div>";
  if (segmentChain.length >= 2 && segmentChain[segmentChain.length - 1] === fn) {
    html += '<div class="row"><button class="ok" onclick="concatVideos(decodeURIComponent(&quot;' +
      encArg(JSON.stringify(segmentChain)) + '&quot;))">🔗 ' + segmentChain.length + "本の動画を1本に結合</button></div>";
  }
  return html;
}

async function extendVideo(fn) {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから続けてください。</div>');
    return;
  }
  const bot = addMsg("bot", '<div class="meta">動画の続きを準備中…（最後の1コマを抜き出しています）</div>');
  try {
    const r = await fetch("/api/extend", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({filename: fn})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    // 最後の1コマを「次の動画の1フレーム目」(I2V) としてセットし、
    // 続きの内容を企画 LLM と相談する（企画モード ON・画像の使い方=先頭固定）。
    refImages = [j.image];
    updateRefSel();
    $("#imguse").value = "first";
    $("#planmode").checked = true;
    $("#btn-reset").style.display = "inline-block";
    planStage = "video";
    extendFrom = fn;
    if (!segmentChain.length || segmentChain[segmentChain.length - 1] !== fn) segmentChain = [fn];
    bot.innerHTML = '<div class="meta">続きの準備 ✅ 最後の1コマをセットしました</div>' +
      "この動画の最後の1コマが「次の動画の1フレーム目」に固定されます。<br>" +
      "次に何が起きますか？（例：「そのままカメラが引いて、彼女が振り返る」）<br>" +
      "内容を話すと企画 LLM がまとめます。OK なら「まとめて」→ 生成で、前作から自然に続く動画になります。";
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
}

async function upscaleVideo(fn) {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから実行してください。</div>');
    return;
  }
  const bot = addMsg("bot", '<div class="meta">アップスケール中…（解像度2倍・数分かかります）</div>');
  try {
    const r = await fetch("/api/upscale", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({filename: fn, scale: 2})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    jobCancelled = false;
    setBusy(true);
    poll(j.prompt_id, bot, "upscale");
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
}

async function concatVideos(encodedJson) {
  if (busy) {
    addMsg("bot", '<div class="meta">⚠ 生成が進行中です。完了してから実行してください。</div>');
    return;
  }
  let files = [];
  try { files = JSON.parse(encodedJson); } catch (e) {}
  if (!Array.isArray(files) || files.length < 2) {
    addMsg("bot", '<div class="meta">⚠ 結合する動画が不足しています。</div>');
    return;
  }
  const bot = addMsg("bot", '<div class="meta">動画を結合中…（' + files.length + "本 → 1本）</div>");
  try {
    const r = await fetch("/api/concat", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({files: files})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    bot.innerHTML = '<div class="meta">結合完了 ✅（' + files.length + "本 → 1本）</div>" +
      '<video controls autoplay loop muted src="/api/view?filename=' + encodeURIComponent(j.filename) + '&type=output"></video>' +
      '<div class="path">' + esc(j.path) + "</div>";
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
}

function startShutdown() {
  // 生成完了後の停止は「選択式」: 自動カウントダウンで勝手に落とさない。
  // 続きの動画や別の参照画像で連続制作したいケースが多いため、ユーザーが
  // ボタンを選ぶまで ComfyUI / 企画 LLM は生かしたままにする。
  const box = $("#shutdown-box");
  box.style.display = "block";
  box.innerHTML =
    '<div class="meta">生成完了 ✅ このまま続けて生成できます（ComfyUI は起動中）。</div>' +
    '<button onclick="hideShutdown()">▶ 続けて使う</button>' +
    '<button class="warn" onclick="stopAll()">🛑 すべて終了</button>' +
    '<button onclick="stopComfy()">ComfyUI だけ停止</button>';
}

function cancelStop() {
  clearInterval(shutdownTimer);
  shutdownTimer = null;
  $("#shutdown-box").style.display = "none";
  fetch("/api/shutdown", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({scope: "cancel"})
  });
  addMsg("bot", '<div class="meta">停止をキャンセルしました。このまま動画を作り続けられます。</div>');
}

function stopAll() { doShutdown("all"); }
function stopComfy() { doShutdown("comfy"); }

async function doShutdown(scope) {
  clearInterval(shutdownTimer);
  shutdownTimer = null;
  const box = $("#shutdown-box");
  box.innerHTML = '<div class="meta">停止中…（モデルをアンロードして GPU・メモリを解放します）</div>';
  try {
    const r = await fetch("/api/shutdown", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({scope: scope})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    if (scope === "all") {
      box.innerHTML = '<div class="meta">すべて停止しました ✅ GPU・メモリ解放済み。ブラウザは閉じてもらって OK です（動画はファイルとして保存済み）。</div>';
    } else {
      box.innerHTML = '<div class="meta">ComfyUI を停止しました ✅（GPU・VRAM 解放）。動画はこのまま閲覧できます。企画 LLM も止める場合は下のボタンへ。</div>' +
        '<button class="warn" onclick="stopAll()">すべて終了（企画 LLM も停止）</button>' +
        '<button class="small" onclick="hideShutdown()">閉じる</button>';
    }
  } catch (e) {
    box.innerHTML = '<div class="meta">停止エラー: ' + esc(String(e.message || e)) + "</div>";
  }
}

function hideShutdown() { $("#shutdown-box").style.display = "none"; }

// ---- セッション履歴（サイドバー） -------------------------------------
// チャット画面（メッセージ HTML）+ UI 状態をサーバーに JSON 保存し、
// サイドバーに一覧表示して切り替えられる（ChatGPT の履歴と同じ使い勝手）。
// 切り替え時は企画 LLM の会話履歴もサーバー側で一緒に切り替わるので、
// 過去の企画の続きをそのまま相談できる。

function messagesSnapshot() {
  return Array.from($("#msgs").children).map(c => ({
    who: (c.className || "").indexOf("user") >= 0 ? "user" : "bot",
    html: c.innerHTML
  }));
}

function uiSnapshot() {
  return {
    planStage, lastFinalPrompt, lastImgPrompt,
    refImages, refConsultActive,
    imguse: $("#imguse").value,
    curJobId: curJobId, curJobKind: curJobKind,
    segmentChain: segmentChain, extendFrom: extendFrom
  };
}

async function saveSession() {
  const msgs = messagesSnapshot();
  if (!msgs.length && !activeSessionId) return;   // 空の新規チャットは保存しない
  const body = JSON.stringify({id: activeSessionId, messages: msgs, ui: uiSnapshot()});
  if (body === lastSavedJson) return;             // 前回保存から変化なし
  try {
    const r = await fetch("/api/sessions/save", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: body
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    lastSavedJson = body;
    if (j.id) activeSessionId = j.id;
    refreshSidebar();
  } catch (e) {}
}
setInterval(saveSession, 6000);
window.addEventListener("beforeunload", () => {
  // タブを閉じるとき直近の状態を送る（fetch は間に合わないので sendBeacon）
  try {
    const msgs = messagesSnapshot();
    if (!msgs.length && !activeSessionId) return;
    const body = JSON.stringify({id: activeSessionId, messages: msgs, ui: uiSnapshot()});
    if (body !== lastSavedJson && navigator.sendBeacon) {
      navigator.sendBeacon("/api/sessions/save", new Blob([body], {type: "application/json"}));
    }
  } catch (e) {}
});

function relTime(ts) {
  const d = Math.floor(Date.now() / 1000 - (ts || 0));
  if (d < 60) return "たった今";
  if (d < 3600) return Math.floor(d / 60) + " 分前";
  if (d < 86400) return Math.floor(d / 3600) + " 時間前";
  return Math.floor(d / 86400) + " 日前";
}

async function refreshSidebar() {
  try {
    const r = await fetch("/api/sessions");
    const j = await r.json();
    if (!r.ok) return;
    const list = $("#sess-list");
    list.innerHTML = "";
    const sessions = j.sessions || [];
    if (!sessions.length) {
      const d = document.createElement("div");
      d.id = "sess-empty";
      d.textContent = "まだ履歴がありません。始めた企画がここに自動で表示されます。";
      list.appendChild(d);
      return;
    }
    sessions.forEach(s => {
      const d = document.createElement("div");
      d.className = "sessitem" + (s.id === activeSessionId ? " active" : "");
      const t = document.createElement("div");
      t.className = "sesstitle";
      t.textContent = s.title || "新しい企画";
      const tm = document.createElement("div");
      tm.className = "sesstime";
      tm.textContent = relTime(s.updated) + "・" + (s.n || 0) + " メッセージ";
      const del = document.createElement("button");
      del.className = "sessdel";
      del.textContent = "🗑";
      del.title = "この企画を削除";
      del.onclick = (e) => { e.stopPropagation(); deleteSession(s.id); };
      d.appendChild(t);
      d.appendChild(tm);
      d.appendChild(del);
      d.onclick = () => switchSession(s.id);
      list.appendChild(d);
    });
  } catch (e) {}
}

async function switchSession(id) {
  if (busy) {
    alert("生成が進行中です。完了してから切り替えてください（✕ キャンセルで中止できます）。");
    return;
  }
  if (id && id === activeSessionId) return;
  await saveSession();   // 今表示中の画面を先に確定保存する
  try {
    const r = await fetch("/api/sessions/switch", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: id || null})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    renderSession(j.session);
  } catch (e) {
    alert("セッションを切り替えられませんでした: " + (e.message || e));
  }
}

function renderSession(doc) {
  // 切り替え前の画面のポーリングを止める
  jobCancelled = true;
  curJobId = null;
  curJobKind = null;
  // ローカル状態をリセット
  lastImgPrompt = null;
  lastFinalPrompt = null;
  planStage = "chat";
  refConsultActive = false;
  refImages = [];
  refPickerSelection = [];
  segmentChain = [];
  extendFrom = null;
  if (shutdownTimer) { clearInterval(shutdownTimer); shutdownTimer = null; }
  hideShutdown();
  $("#msgs").innerHTML = "";
  lastSavedJson = "";
  if (!doc) {
    activeSessionId = null;
    updateRefSel();
    refreshSidebar();
    return;
  }
  activeSessionId = doc.id;
  const ui = doc.ui || {};
  planStage = ui.planStage || "chat";
  lastFinalPrompt = ui.lastFinalPrompt || null;
  lastImgPrompt = ui.lastImgPrompt || null;
  refImages = Array.isArray(ui.refImages) ? ui.refImages : [];
  refConsultActive = !!ui.refConsultActive;
  segmentChain = Array.isArray(ui.segmentChain) ? ui.segmentChain.filter(x => typeof x === "string") : [];
  extendFrom = typeof ui.extendFrom === "string" ? ui.extendFrom : null;
  if (ui.imguse === "first" || ui.imguse === "last" || ui.imguse === "ref") $("#imguse").value = ui.imguse;
  updateRefSel();
  const clr = $("#ref-clear");
  if (clr) clr.style.display = refImages.length ? "inline-block" : "none";
  (doc.messages || []).forEach(m => addMsg(m.who, m.html));
  $("#msgs").scrollTop = $("#msgs").scrollHeight;
  // 保存時に未完了だった生成ジョブがあればポーリングを再開する
  if (ui.curJobId) {
    const kids = $("#msgs").children;
    let lastBot = null;
    for (let i = kids.length - 1; i >= 0; i--) {
      if ((kids[i].className || "").indexOf("bot") >= 0) { lastBot = kids[i]; break; }
    }
    if (lastBot) {
      curJobId = ui.curJobId;
      curJobKind = (ui.curJobKind === "image" || ui.curJobKind === "upscale") ? ui.curJobKind : "video";
      setBusy(true);
      if (curJobKind === "image") pollImage(ui.curJobId, lastBot);
      else poll(ui.curJobId, lastBot, curJobKind);
    }
  }
  refreshSidebar();
}

async function newChat() {
  if (busy) {
    alert("生成が進行中です。完了してから新しい企画を始めてください（✕ キャンセルで中止できます）。");
    return;
  }
  await saveSession();
  try {
    const r = await fetch("/api/sessions/switch", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: null})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    renderSession(null);
  } catch (e) {
    alert("新しい企画を始められませんでした: " + (e.message || e));
  }
}

async function deleteSession(id) {
  if (id === activeSessionId) {
    alert("今表示中のセッションは削除できません。先に他に切り替えてください。");
    return;
  }
  if (!confirm("この企画を履歴から削除しますか？")) return;
  try {
    const r = await fetch("/api/sessions/delete", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: id})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    refreshSidebar();
  } catch (e) {
    alert("削除できませんでした: " + (e.message || e));
  }
}

function toggleSidebar() {
  $("#sidebar").classList.toggle("hidden");
}

// ページ読み込み時: 最後に表示していたセッションを復元しサイドバーを描画する。
async function initSessions() {
  try {
    const r = await fetch("/api/sessions");
    const j = await r.json();
    if (!r.ok) return;
    if (j.active) renderSession(j.active);
    else refreshSidebar();
  } catch (e) {}
}
initSessions();

async function resetPlan() {
  // 進行中の生成ジョブがあれば先にキャンセルする
  if (curJobId) {
    try {
      await fetch("/api/cancel", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({prompt_id: curJobId})
      });
    } catch (e) {}
  }
  jobCancelled = true;
  curJobId = null;
  curJobKind = null;
  setBusy(false);
  // 自動停止カウントダウンが残っていれば解除する
  if (shutdownTimer) { clearInterval(shutdownTimer); shutdownTimer = null; }
  $("#shutdown-box").style.display = "none";
  // 今の企画を履歴に保存してから、サーバー側で新しいセッション始める。
  // 以前は fire-and-forget の __RESET__ で、失敗しても気づかずサーバーに
  // 古い企画状態が残ったまま次の企画が始まっていた。
  try {
    await saveSession();
    const r = await fetch("/api/sessions/switch", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: null})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
  } catch (e) {
    addMsg("bot", '<div class="meta">⚠ サーバー側のリセットに失敗しました（' + esc(String(e.message || e)) + '）。企画 LLM に古い会話が残っている可能性があります。もう一度「🔄 新しい企画」を押してください。</div>');
    return;
  }
  renderSession(null);
}

$("#planmode").addEventListener("change", e => {
  $("#btn-reset").style.display = e.target.checked ? "inline-block" : "none";
});

$("#input").addEventListener("keydown", e => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
});
</script>
</body>
</html>
"""


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
        elif parsed.path == "/api/sessions":
            self._sessions_list()
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/generate":
            self._generate(parsed)
        elif parsed.path == "/api/zimg":
            self._zimg(parsed)
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
                "path": PLAN_MODEL_PATH, "mmproj": PLAN_MMPROJ_PATH,
                "gpu": PLAN_GPU, "vision": PLAN_HAS_VISION, "port": PLAN_PORT,
                "bin": PLAN_SERVER_BIN,
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
                "path": PLAN_MODEL_PATH, "mmproj": PLAN_MMPROJ_PATH,
                "gpu": PLAN_GPU, "vision": PLAN_HAS_VISION, "port": PLAN_PORT,
                "bin": PLAN_SERVER_BIN,
            },
            "note": "切り替えました。次のメッセージから新しいモデルで起動します。",
        }
        if self.server.plan_url:
            resp["note"] = ("--plan-url の外部エンドポイントが優先されるため、"
                            "この切替は h3-chat が企画 LLM を自前起動するときのみ有効です。")
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
        # Free stale models (e.g. Z-Image Turbo) first so the H3 model has the
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
            self._json(503, {"error": "企画 LLM を起動できませんでした（モデルまたは llama-server が見つかりません）"})
            return
        self.server.autostop.poke()
        image = req.get("image") or None   # 確定したキー画像のファイル名（視覚入力）
        ref_start = bool(req.get("ref_start"))  # 参照モードからの動画相談開始フラグ
        if stage == "video" and text == "__CONFIRM_IMAGE__":
            # キー画像が確定: Z-Image Turbo をアンロードして VRAM を解放してから
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

        Prefers the configured --plan-url; otherwise auto-detects the standard
        llama-server on PLAN_PORT, auto-starting it when missing, so plan mode
        works no matter how h3-chat.py was started. Returns None when no
        planning LLM is reachable.
        """
        if self.server.plan_url:
            return self.server.plan_url
        if probe:
            # The gpu27b planner needs ~14GB: make sure ComfyUI is not holding
            # it before the load starts.
            if PLAN_GPU and not _plan_alive():
                self._free_comfy()
            # Give a first-request spawn a short window to come up. The gpu27b
            # planner cold-loads in ~10s but gets a longer window for safety.
            if ensure_plan_llm(wait_seconds=90 if PLAN_GPU else 30):
                return PLAN_URL_DEFAULT
            return None
        return PLAN_URL_DEFAULT if _plan_alive() else None

    def _attach_plan_image(self, text, image_fn, note=None):
        """Attach image_fn as a base64 image part so a vision-capable planning
        LLM can see it. Returns text unchanged when vision is unavailable or
        the file cannot be read. image_fn may be a bare filename (resolved via
        local_files) or an absolute path (reference-image picker). When `note`
        is given it is prepended to the text part (only if the image actually
        attaches) so the planner knows what the image is for."""
        if not (image_fn and PLAN_HAS_VISION):
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
        # (PLAN_HAS_VISION false) get the prompt text only.
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
            history = [{"role": "system", "content": PLAN_SYSTEM}] + PLAN_HISTORY[-6:]
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

    # ---- Z-Image key image ------------------------------------------

    def _zimg(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        text = (req.get("text") or "").strip()
        if not text:
            self._json(400, {"error": "画像プロンプトが空です"})
            return

        engine = req.get("engine") or "zimg"
        eng = IMG_ENGINES.get(engine)
        if not eng:
            self._json(400, {"error": "unknown image engine: " + engine})
            return
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
        self.server.autostop.poke()
        # gpu27b planner: free its VRAM before the image model loads.
        stop_plan_llm()
        self._free_comfy()
        try:
            _, raw, _ = self._comfy("POST", "/prompt", {"prompt": wf})
            pid = json.loads(raw)["prompt_id"]
            self.server.job_meta[pid] = {"mode": engine, "start": time.time(), "kind": "image"}
            self._json(200, {"prompt_id": pid})
        except Exception as e:
            self._json(502, {"error": self._proxy_error(e)})

    # ---- shutdown / VRAM ---------------------------------------------

    def _free_comfy(self):
        """Unload every model from VRAM (used between Z-Image and H3)."""
        try:
            self._comfy("POST", "/free", {"unload_models": True, "free_memory": True}, timeout=15)
        except Exception:
            pass

    def _shutdown(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            req = {}
        scope = req.get("scope") or "comfy"   # "comfy" | "all" | "cancel"
        if scope == "cancel":
            # browser-side countdown was cancelled: keep the stack alive
            self.server.autostop.poke()
            self._json(200, {"ok": True, "stopped": []})
            return
        self._free_comfy()
        stopped = ["ComfyUI"]
        self._kill_port(self._comfy_port())
        if scope == "all":
            self._kill_port(PLAN_PORT)
            stopped.append("企画 LLM")
            # respond first, then stop the chat server itself
            threading.Timer(1.5, self.server.shutdown).start()
        self.server.autostop.poke()
        self._json(200, {"ok": True, "stopped": stopped})

    def _comfy_port(self):
        return ChatHandler._comfy_port_of(self.server)

    @staticmethod
    def _kill_port(port):
        """Kill the process LISTENING on the given local port."""
        try:
            # netstat on a Japanese Windows emits CP932 bytes; decoding as
            # UTF-8 crashes the reader thread and silently kills the whole
            # cleanup, so read raw bytes and decode with errors="replace"
            # (we only need ASCII tokens: port, LISTENING, PID).
            res = subprocess.run(["netstat", "-ano"], capture_output=True, timeout=15)
            out = (res.stdout or b"").decode("utf-8", errors="replace")
            pids = set()
            for line in out.splitlines():
                if f":{port}" in line and "LISTENING" in line.upper():
                    parts = line.split()
                    if parts and parts[-1].isdigit():
                        pids.add(parts[-1])
            for pid in pids:
                subprocess.run(["taskkill", "/F", "/PID", pid], capture_output=True, timeout=15)
        except Exception:
            pass

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
    print(f"h3-chat: Z-Image = {ZIMG_WORKFLOW}")
    print(f"h3-chat: R2V 参照モード = {R2V_WORKFLOWS['fast']} など（キー画像→参照 LoRA）")
    print(f"h3-chat: plan LLM = {server.plan_url or ('auto (' + str(PLAN_PORT) + ', GPU 27B)' if PLAN_GPU else 'auto (8190, CPU 4B)')} (engine: {PLAN_ENGINE})")
    # Bring up the planning LLM in the background so the first plan-mode
    # message does not have to wait for the model load (~10-60s on CPU).
    # gpu27b mode starts on demand instead: preloading it would hold 14GB of
    # VRAM while ComfyUI may still be generating.
    if not server.plan_url and not PLAN_GPU:
        threading.Thread(target=ensure_plan_llm, kwargs={"wait_seconds": 180}, daemon=True).start()
    print("h3-chat: Ctrl+C で停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
