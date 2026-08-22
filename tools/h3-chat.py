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
ETA_DEFAULTS = {"high": 540, "quick": 240, "lite": 540, "quicklite": 150, "fast": 900, "fast_quick": 360, "zimg": 40, "qimg": 1250}

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
NODE_ZIMG_SAVE = "10"    # SaveImage: output filename

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
    },
    "qimg": {
        "workflow": QIMG_WORKFLOW,
        "prompt": NODE_QIMG_PROMPT, "latent": NODE_QIMG_LATENT, "seed": NODE_QIMG_SEED,
        "default_size": (1344, 768),
        "label": "Qwen-Image 2512",
    },
}

# R2V (reference-to-video) workflows: 確定したキー画像を参照画像にして同一キャラを維持する。
# MiniMaxH3ReferenceToVideo ノード + 参照 LoRA（minimax_h3_ref_lora_rank_256_bf16）を
# fl2va モデルに重ねる構成（ref2va モデル不要）。lite は 32B エンコーダ版にフォールバック。
# quicklite は 4B エンコーダ + ClipProj 射影（mmh3-4b-ClipProj-celeb-mlp）で 32B を代替し、約 1/3 の時間に。
# 4B を生で渡すと次元不一致（30720 vs 5120）で失敗するため ClipProjApply が必須。
R2V_WORKFLOWS = {
    "high": os.path.join(REPO, "h3_workflow_r2v.json"),
    "quick": os.path.join(REPO, "h3_workflow_r2v_short.json"),
    "lite": os.path.join(REPO, "h3_workflow_r2v.json"),
    "quicklite": os.path.join(REPO, "h3_workflow_r2v_short_4b.json"),
    "fast": os.path.join(REPO, "h3_workflow_r2v_fast.json"),
    "fast_quick": os.path.join(REPO, "h3_workflow_r2v_fast_short.json"),
}
NODE_R2V_IMAGE = "16"    # LoadImage: 参照画像（ComfyUI input/ にコピーしたファイル名を設定）
NODE_R2V_PROMPT = "6"    # MiniMaxH3ReferenceToVideo: user prompt
# R2V はプロンプト内の <Picture N> タグで参照画像を指定する。企画 LLM が
# タグを知らないので、生成時にタグの意味を追記して確実に同一キャラ指定にする。
R2V_TAG_NOTE = (
    "\n\n<Picture 1> is the confirmed key image. "
    "Keep the subject's identity, face, hairstyle, outfit and appearance "
    "consistent with <Picture 1> in every frame of the video."
)

# Standard ports (must match tools\h3-chat.ps1 / select-model.ps1)
#
# The planning LLM runs in one of two modes:
#   cpu4b  (default): Qwen3.5-4B on CPU (-ngl 0), port 8190, pre-started and
#                     always-on; has an mmproj so it can see the confirmed key
#                     image.
#   gpu27b (LLAMADOCK_PLAN_GPU=1): Qwen3.8-27B-Abliterated on GPU (-ngl all),
#                     port 8191. Started on demand for the planning phase only
#                     and killed before every ComfyUI generation, so the 12GB
#                     planner and the video model never fight over VRAM. Ships
#                     its own mmproj, so it can see the confirmed key image.
PLAN_GPU = os.environ.get("LLAMADOCK_PLAN_GPU", "") == "1"
PLAN_PORT = 8191 if PLAN_GPU else 8190
PLAN_URL_DEFAULT = f"http://127.0.0.1:{PLAN_PORT}"

# ---- planning LLM auto-start -----------------------------------------
# Mirrors the llama-server launch in tools\h3-chat.ps1 so plan mode works
# even when h3-chat.py is started directly (without h3-chat.ps1 / llamadock).
_DEFAULT_PLAN_MODEL = (
    r"C:\Users\dai86\.lmstudio\models\soyaakinohara\qwen3.8-27b-abliterated-3.69bpw-12GB-MTP.gguf\qwen3.8-27b-abliterated-3.69bpw-12GB-MTP.gguf"
    if PLAN_GPU
    else r"C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica.i1-Q6_K.gguf"
)
PLAN_MODEL_PATH = os.environ.get("LLAMADOCK_PLAN_MODEL", _DEFAULT_PLAN_MODEL)
PLAN_MMPROJ_PATH = os.environ.get(
    "LLAMADOCK_PLAN_MMPROJ",
    r"C:\Users\dai86\.lmstudio\models\soyaakinohara\qwen3.8-27b-abliterated-3.69bpw-12GB-MTP.gguf\mmproj-Q8_0.gguf"
    if PLAN_GPU else
    r"C:\Users\dai86\.lmstudio\models\Sinbad-The-Sailor\Qwen3.5-4B-NSFW-ARA-Heretic-Literotica\mmproj-Qwen3.5-4B-NSFW-Literotica-BF16.gguf",
)
PLAN_SERVER_BIN = os.environ.get(
    "LLAMADOCK_PLAN_BIN",
    r"C:\llama-tq3\build-rocm71\bin\llama-server.exe"
    if PLAN_GPU else
    r"C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe",
)
# 企画 LLM のエンジン名（コーダー側のエンジン表記と揃えた表示用ラベル）。
# DSpark を有効にすると TurboTan ビルドに切り替わるので、その場合のラベルも用意。
PLAN_ENGINE = "AtomicBot (ROCm 7.1 HIP)" if PLAN_GPU else (
    "openPangu (native CPU)" if "llama.cpp-openPangu" in PLAN_SERVER_BIN else
    "AtomicBot (ROCm 7.1 HIP)" if "build-rocm71" in PLAN_SERVER_BIN else "Unknown"
)
PLAN_ENGINE_DSPARK = "TurboTan (draft-dspark)"
PLAN_ENGINE_DFLASH2 = "DFlash2 (ROCm 7.1 HIP, draft-dflash)"
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
    "dspark": False,      # DSpark speculative decoding (experimental)
    "dflash2": False,     # DFlash2 speculative decoding (experimental)
}
# DSpark draft model path (Qwen3.8-27B-DSPark, 1B dflash arch, Q8_0 1.35GB)
DSPARK_GGUF = r"C:\Users\dai86\.lmstudio\models\erlidev\Qwen3.8-27B-DSpark-GGUF\Qwen3.8-27B-DSpark-Q8_0.gguf"
# DSpark requires the TurboTan build (AtomicBot does not support draft-dspark).
TURBOTAN_SERVER_BIN = r"C:\Users\dai86\Downloads\llama-b10536-rocm\llama-server.exe"
# DFlash2 draft model path (Qwen3.8-27B-DFlash2, grouped dynamic convolution, Q4_K_M ~1.14GB)
DFLASH2_GGUF = r"C:\Users\dai86\.lmstudio\models\incoai\Qwen3.8-27B-DFlash2-GGUF\Qwen3.8-27B-DFlash2-Q8_0.gguf"
# DFlash2 requires the DFlash2 fork build (z-lab/llama.cpp-fork dflash2 branch, ROCm 7.1 HIP).
DFLASH2_SERVER_BIN = r"C:\Users\dai86\Downloads\llama-dflash2\build-rocm71\bin\llama-server.exe"
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
    if not os.path.isfile(PLAN_SERVER_BIN) or not os.path.isfile(PLAN_MODEL_PATH):
        return None
    # Speculative decoding requires fork-specific builds: draft-dspark exists
    # only in TurboTan and draft-dflash only in the DFlash2 build; AtomicBot
    # rejects unknown --spec-type values at startup.
    if PLAN_GPU and PLAN_SETTINGS.get("dflash2"):
        if not os.path.isfile(DFLASH2_SERVER_BIN):
            return None
        server_bin = DFLASH2_SERVER_BIN
    elif PLAN_GPU and PLAN_SETTINGS["dspark"]:
        if not os.path.isfile(TURBOTAN_SERVER_BIN):
            return None
        server_bin = TURBOTAN_SERVER_BIN
    else:
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
            # Vision-capable 27B (lemonyins ULTIMATE-UNCENSORED ships its own
            # mmproj). Attach it so the planner can see the confirmed key image.
            args += ["--mmproj", PLAN_MMPROJ_PATH, "--image-min-tokens", "1024"]
        # DSpark speculative decoding: separate 1B dflash draft model predicts
        # up to 7 tokens ahead; main model verifies. Experimental — requires
        # llama.cpp PR #25173+ (spec-type draft-dspark).
        if PLAN_SETTINGS["dspark"] and os.path.isfile(DSPARK_GGUF):
            args += [
                "--spec-type", "draft-dspark",
                "--spec-draft-model", DSPARK_GGUF,
                "--spec-draft-n-max", "7",
                "-ngld", "99",
            ]
        # DFlash2 speculative decoding: grouped dynamic depthwise convolution
        # draft model predicts up to 7 tokens ahead; main model verifies.
        # Requires the DFlash2 fork build (z-lab/llama.cpp-fork dflash2 branch).
        # n_max stays within the checkpoint's trained block size (8) to avoid
        # the "clamping to 7" warning at load time.
        if PLAN_SETTINGS.get("dflash2") and os.path.isfile(DFLASH2_GGUF):
            args += [
                "--spec-type", "draft-dflash",
                "--spec-draft-model", DFLASH2_GGUF,
                "--spec-draft-n-max", "7",
                "-ngld", "99",
            ]
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
    if PLAN_GPU and os.path.isdir(PLAN_ROCM_BIN):
        # The HIP build links amdhip64_7.dll from the ROCm runtime; without it
        # on PATH the server exits with STATUS_DLL_NOT_FOUND.
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
            if PLAN_GPU and PLAN_SETTINGS.get("dflash2"):
                engine_label = PLAN_ENGINE_DFLASH2
            elif PLAN_GPU and PLAN_SETTINGS["dspark"]:
                engine_label = PLAN_ENGINE_DSPARK
            else:
                engine_label = PLAN_ENGINE
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

# ComfyUI node ids in the super workflows
NODE_PROMPT = "6"     # MiniMaxH3ImageToVideo: user prompt
NODE_SEED = "7"       # KSampler: seed
NODE_SAVE = "10"      # SaveVideo: output filename

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
    "【成人向け】この環境は成人向け創作専用。性的・官能的な表現をためらわず露骨に企画へ反映する。検閲・婉曲化・ぼかし禁止。"
    "性的シーンなら行為・体位・部位・動き・リズム・表情・声・体液・衣服の状態まで英語プロンプトに具体的に含める。曖昧な一般表現に丸めない。"
    "[IMG_PROMPT] にはヌード・下着・肌・胸・尻・陰部など必要なら露骨な英語タグ（nude, naked, breasts, nipples, pussy, spread legs, missionary 等）を書く。"
    "[FINAL_PROMPT] には性行為の動き（thrusting, bouncing, grinding）、リズム、カメラアングル、喘ぎ声・息遣い・愛液などの音響を時系列で書く。"
    "被写体は全員成人（adult）。未成年を示す表現は絶対に使わない。ユーザー指定の性的ディテールは一字一句尊重し、勝手に薄めない。"
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
    "セリフ表記: 話者に (S1)(S2) の安定IDを付け、初登場時に声の特徴（年齢・性別・声質・トーン・話速）を記述し、発話は <d>[Japanese] 原文</d> に入れる"
    "（例: The young woman with a quiet, breathy voice (S1) says: <d>[Japanese] 今夜は帰らないで。</d>）。"
    "タグは必ず1組だけ。開いたら必ず閉じタグ（[/IMG_PROMPT] / [/FINAL_PROMPT]）まで書き切る。タグ以外の補足説明は不要。"
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

  /* ---- chat area ---- */
  main { flex:1; overflow-y:auto; padding:18px 20px; }
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
             background:var(--bg); transition:border-color .15s; }
  .refcard:hover { border-color:var(--accent); }
  .refcard img { width:100%; height:90px; object-fit:cover; display:block; background:#000; }
  .refcard .refname { font-size:11px; padding:5px 6px 0; color:var(--text);
                      overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .refcard .refdir { font-size:10px; padding:0 6px 6px; color:var(--muted); }

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
  <h1>🎬 MiniMax H3 チャット動画生成</h1>
  <span class="sub">企画モード: キー画像（Z-Image Turbo）→ 確認 → 動画（H3・32B/4B）</span>
  <span id="status-dot" title="ComfyUI 接続状態"></span>
</header>
<main id="msgs"></main>
<div id="shutdown-box">
  <div class="meta">生成完了 ✅ 自動停止まで <b id="countdown">90</b> 秒（GPU・メモリを解放します）</div>
  <button class="warn" onclick="stopAll()">🛑 今すぐすべて終了</button>
  <button onclick="stopComfy()">ComfyUI だけ停止</button>
  <button class="small" onclick="cancelStop()">キャンセル</button>
</div>
<div id="refmodal" class="modal">
  <div class="modal-box">
    <div class="meta">参照画像を選択（ComfyUI の output/・input/ にある画像から）</div>
    <div id="refgrid"></div>
    <button onclick="closeRefModal()">閉じる</button>
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
    <label class="plan"><input type="checkbox" id="refmode"> 🔗 参照モード（R2V）</label>
    <div id="refpick">
      <button type="button" onclick="pickRefImage()">🗂 参照画像を選ぶ</button>
      <span id="ref-sel" class="hint">未選択（企画モードで確定したキー画像を使用）</span>
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
        <span class="hint">キー画像:</span>
        <label><input type="radio" name="imgengine" value="qimg" checked> Qwen-Image 2512（高画質・4候補）</label>
        <label><input type="radio" name="imgengine" value="zimg"> Z-Image Turbo（最速）</label>
      </div>
      <div class="advgroup" id="planparams">
        <span class="hint">企画 LLM パラメータ:</span>
        <label>KV キー:<select id="p-ctk" onchange="sendPlanSettings()"><option value="q8_0" selected>q8_0</option><option value="q4_0">q4_0</option><option value="f16">f16</option><option value="none">なし</option></select></label>
        <label>KV 値:<select id="p-ctv" onchange="sendPlanSettings()"><option value="q4_0" selected>q4_0</option><option value="q8_0">q8_0</option><option value="f16">f16</option><option value="none">なし</option></select></label>
        <label><input type="checkbox" id="p-fa" checked onchange="sendPlanSettings()"> フラッシュアテンション</label>
        <label>推論:<select id="p-reasoning" onchange="sendPlanSettings()"><option value="medium" selected>medium</option><option value="low">low</option><option value="off">off</option><option value="xhigh">xhigh</option></select></label>
        <label>予算:<input type="number" id="p-budget" value="1536" min="0" max="32768" step="256" style="width:70px" onchange="sendPlanSettings()"></label>
        <label><input type="checkbox" id="p-dspark" onchange="if(this.checked){const d=document.getElementById('p-dflash2');if(d)d.checked=false;}sendPlanSettings()"> DSpark（実験・投機的デコード）</label>
        <label><input type="checkbox" id="p-dflash2" onchange="if(this.checked){const d=document.getElementById('p-dspark');if(d)d.checked=false;}sendPlanSettings()"> DFlash2（実験・投機的デコード）</label>
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
let curImageFilename = null;
let planStage = "chat";   // chat -> image -> video -> done
let shutdownTimer = null;
let shutdownLeft = 0;

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
  const dspark = $("#p-dspark");
  const dflash2 = $("#p-dflash2");
  if (!ctk) return;
  fetch("/api/plan-settings", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({
      ctk: ctk.value, ctv: ctv.value,
      fa: fa.checked, reasoning_effort: re.value,
      reasoning_budget: parseInt(rb.value, 10) || 1536,
      dspark: dspark ? dspark.checked : false,
      dflash2: dflash2 ? dflash2.checked : false
    })
  }).catch(() => {});
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
    for (const img of j.images || []) {
      const c = document.createElement("div");
      c.className = "refcard";
      c.innerHTML =
        '<img src="/api/refimg?path=' + encodeURIComponent(img.path) + '" loading="lazy">' +
        '<div class="refname">' + esc(img.name) + '</div>' +
        '<div class="refdir">' + esc(img.dir) + "</div>";
      c.onclick = () => {
        curImageFilename = img.path;
        $("#ref-sel").textContent = img.name + "（" + img.dir + "）";
        closeRefModal();
      };
      grid.appendChild(c);
    }
    if (!(j.images || []).length) {
      grid.innerHTML = '<div class="hint">参照に使える画像がありません。ComfyUI output/ に生成結果、input/ に手動配置の画像を置いてください。</div>';
    }
    $("#refmodal").style.display = "flex";
  } catch (e) {
    alert("参照画像一覧の取得に失敗: " + e.message);
  }
}
function closeRefModal() { $("#refmodal").style.display = "none"; }

async function send() {
  const text = $("#input").value.trim();
  if (!text || busy) return;
  setBusy(true);
  $("#input").value = "";
  addMsg("user", esc(text));
  if ($("#planmode").checked) { plan(text); return; }
  if ($("#refmode").checked && !curImageFilename) {
    addMsg("bot", '<div class="meta">参照画像が未設定です。✎ 企画モードでキー画像を確定するか、下部の「🗂 参照画像を選ぶ」から既存の画像を指定してください。</div>');
    setBusy(false);
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
        // 選んだ画像は常に参照される（参照モード checkbox が OFF でも自動有効）。
        // 「画像を入れたのに無視されて無関係な動画ができる」事故の根本対策。
        ref: $("#refmode").checked || !!curImageFilename, image: curImageFilename,
        audio: audioSpec(), length: lenValue()
      })
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function plan(text) {
  const bot = addMsg("bot", '<div class="meta">企画 LLM が考え中…</div>');
  try {
    const r = await fetch("/api/plan", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: text, stage: planStage, image: curImageFilename})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    let html = '<div class="meta">企画案</div>' + thinkHtml(j.thinking) + esc(j.reply || "（応答なし）");
    if (j.img_prompt) {
      lastImgPrompt = j.img_prompt;
      const revising = (planStage === "image");
      planStage = "image";
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
      // 生成される内容をユーザーが事前に確認できるよう、最終プロンプトを
      // 折りたたみで必ず提示する（「LLMが考えるのはいいが何が出るか
      // わからない」問題の対策）。
      html += '<details class="thinkbox"><summary>📝 LLMが考えた動画プロンプト（クリックで確認）</summary><pre style="white-space:pre-wrap;margin:6px 0 0;font-size:12px;">' + esc(j.final_prompt) + '</pre></details>';
      html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
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
  if (!lastImgPrompt || busy) return;
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
  curJobId = id;
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const imgs = (j.videos || []).filter(v => v.kind === "image");
      if (!imgs.length) {
        bot.innerHTML = '<div class="meta">エラー</div><div class="err">画像が見つかりませんでした</div>';
        curJobId = null;
        setBusy(false);
        return;
      }
      // 全候補をギャラリー表示して選べるようにする（最後の1枚だけ問題の修正）
      curImageFilename = imgs[0].filename;
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
        '<button class="rev" onclick="reviseImage()">🔁 修正する</button>' +
        "</div>";
      planStage = "image";
      curJobId = null;
      setBusy(false);
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "画像生成に失敗しました") + "</div>";
      curJobId = null;
      setBusy(false);
      return;
    }
    bot.querySelector(".meta").textContent = "キー画像生成中… " + (j.extra || "");
    setTimeout(() => pollImage(id, bot), 2000);
  } catch (e) {
    setTimeout(() => pollImage(id, bot), 2000);
  }
}

function pickKeyImage(card) {
  const grid = card.parentElement;
  grid.querySelectorAll(".imgcard").forEach(c => c.classList.remove("sel"));
  card.classList.add("sel");
  curImageFilename = card.dataset.fn;
}

function reviseImage() {
  planStage = "image";
  $("#input").placeholder = "修正したい点を入力（例：犬を白く、夕焼けをもっと赤く）";
  $("#input").focus();
}

function confirmImage() {
  if (busy) return;
  setBusy(true);
  const bot = addMsg("bot", '<div class="meta">企画 LLM と動画の内容を相談中…（Z-Image はアンロード済み）</div>');
  (async () => {
    try {
      const r = await fetch("/api/plan", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({text: "__CONFIRM_IMAGE__", stage: "video", image: curImageFilename})
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      let html = '<div class="meta">画像を確定 ✅（ここから動画の内容を相談します）</div>' + thinkHtml(j.thinking) + esc(j.reply || "（応答なし）");
      if (j.final_prompt) {
        lastFinalPrompt = j.final_prompt;
        planStage = "video";
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
  const bot = addMsg("bot",
    '<div class="meta">✍ 手動プロンプト</div>' +
    '<textarea id="manual-prompt" style="width:100%;height:110px;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:8px;padding:8px;font:inherit;font-size:13px" placeholder="動画プロンプトを英語で直接入力（例: [Shot 1] The woman turns to the camera and smiles, the camera slowly dollies in...）"></textarea>' +
    '<div class="row"><button class="ok" onclick="useManualPrompt()">🎬 このプロンプトで生成 ▶</button></div>');
  bot.querySelector("#manual-prompt").focus();
}

function useManualPrompt() {
  const ta = document.querySelector("#manual-prompt");
  const text = ta ? ta.value.trim() : "";
  if (!text) return;
  lastFinalPrompt = text;
  planStage = "video";
  addMsg("user", "✍ 手動プロンプトで生成: " + text);
  genPlanLast();
}

function genPlanLast() {
  if (busy) return;
  if (!lastFinalPrompt) return;
  const finalPrompt = lastFinalPrompt;
  lastFinalPrompt = null;
  setBusy(true);
  const mode = document.querySelector('input[name="mode"]:checked').value;
  // キー画像（curImageFilename）がある場合は checkbox に関係なく参照モード
  const useRef = $("#refmode").checked || !!curImageFilename;
  const tag = useRef ? "🔗 参照モードで生成する: " : "✅ この企画で生成する: ";
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
        // 選んだ画像は常に参照される（参照モード checkbox が OFF でも自動有効）。
        // 「画像を入れたのに無視されて無関係な動画ができる」事故の根本対策。
        ref: $("#refmode").checked || !!curImageFilename, image: curImageFilename,
        audio: audioSpec(), length: lenValue()
      })
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    setBusy(false);
  }
}

async function poll(id, bot) {
  curJobId = id;
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const v = j.videos[0];
      bot.innerHTML = '<div class="meta">完成 ✅</div>' +
        '<video controls autoplay loop muted src="/api/view?filename=' + encodeURIComponent(v.filename) +
        '&type=' + encodeURIComponent(v.type || "output") + '"></video>' +
        '<div class="path">' + esc(v.path) + "</div>";
      curJobId = null;
      setBusy(false);
      startShutdown(90);
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "失敗しました") + "</div>";
      curJobId = null;
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
    setTimeout(() => poll(id, bot), 3000);
  } catch (e) {
    setTimeout(() => poll(id, bot), 3000);
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
  if (curJobId === id) curJobId = null;
  if (bot) {
    const meta = bot.querySelector(".meta");
    if (meta) meta.textContent = "キャンセルしました（ComfyUI のジョブを中断・削除）";
    const cb = bot.querySelector(".cancelbtn");
    if (cb) cb.remove();
  }
}

async function cancelCurrent() {
  if (!curJobId) return;
  const id = curJobId;
  await cancelJob(id, null);
  addMsg("bot", '<div class="meta">キャンセルしました。</div>');
}

function startShutdown(seconds) {
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

async function resetPlan() {
  // 進行中の生成ジョブがあれば先にキャンセルする
  const hadJob = !!curJobId;
  if (curJobId) {
    try {
      await fetch("/api/cancel", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({prompt_id: curJobId})
      });
    } catch (e) {}
    curJobId = null;
  }
  jobCancelled = true;
  setBusy(false);
  // 自動停止カウントダウンが残っていれば解除する
  if (shutdownTimer) { clearInterval(shutdownTimer); shutdownTimer = null; }
  $("#shutdown-box").style.display = "none";
  fetch("/api/plan", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({text: "__RESET__"})
  });
  lastImgPrompt = null;
  lastFinalPrompt = null;
  planStage = "chat";
  if (hadJob) {
    addMsg("bot", '<div class="meta">新しい企画</div>進行中の生成をキャンセルし、新しい企画を始めます。作りたい映像を教えてください。');
  } else {
    addMsg("bot", '<div class="meta">新しい企画</div>新しい企画を始めましょう。作りたい映像を教えてください。');
  }
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
        if "dspark" in req:
            PLAN_SETTINGS["dspark"] = bool(req["dspark"])
            # DSpark (draft-dspark, TurboTan build) and DFlash2 (draft-dflash,
            # DFlash2 build) need different llama-server binaries — keep the
            # two modes mutually exclusive so _spawn_plan_llm picks one bin.
            if PLAN_SETTINGS["dspark"]:
                PLAN_SETTINGS["dflash2"] = False
        if "dflash2" in req:
            PLAN_SETTINGS["dflash2"] = bool(req["dflash2"])
            if PLAN_SETTINGS["dflash2"]:
                PLAN_SETTINGS["dspark"] = False
        self._json(200, PLAN_SETTINGS)

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
        # 画像が選択されているのに参照モード OFF のままでは、その画像は完全に
        # 無視され、テキストだけの無関係な動画が生成されていた（「女の子の
        # 参照画像を入れたのに車の動画になった」の根本原因）。ここで明示的に
        # 弾いて、ユーザーに選択を促す。
        if image_fn and not ref:
            self._json(400, {"error": "画像が選択されていますが「参照モード」が OFF です。選んだ画像を使うには ☑ 参照モード を ON にしてください（OFF のままでは画像は無視されます）。"})
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
            # 参照モード: 確定したキー画像を参照画像（<Picture 1>）として使う R2V 生成
            if not image_fn:
                self._json(400, {"error": "参照画像がありません（先に企画モードでキー画像を確定してください）"})
                return
            try:
                with open(R2V_WORKFLOWS[eff_mode], encoding="utf-8") as f:
                    wf = json.load(f)["prompt"]
            except Exception as e:
                self._json(500, {"error": f"R2V ワークフロー読み込み失敗: {e}"})
                return
            try:
                ref_name = self._stage_ref_image(image_fn)
            except Exception as e:
                self._json(400, {"error": str(e)})
                return
            wf[NODE_R2V_IMAGE]["inputs"]["image"] = ref_name
            wf[NODE_R2V_PROMPT]["inputs"]["prompt"] = text + R2V_TAG_NOTE
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
            self.server.job_meta[pid] = {"mode": eff_mode, "start": time.time(), "kind": "video"}
            self._json(200, {"prompt_id": pid})
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
            reply, img_prompt, final_prompt, audio, thinking = self._plan_llm(text, endpoint, stage, image)
        except Exception as e:
            self._json(502, {"error": f"企画 LLM エラー: {e}"})
            return
        if final_prompt and not reply:
            reply = "動画プロンプトがまとまりました。下のボタンで生成できます。\n\n" + final_prompt
        if img_prompt and not reply:
            reply = "キー画像のプロンプトがまとまりました。下のボタンで画像を生成できます。\n\n" + img_prompt
        self._json(200, {"reply": tweak_note + reply, "img_prompt": img_prompt, "final_prompt": final_prompt, "audio": audio, "thinking": thinking})

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

    def _plan_llm(self, user_text, endpoint, stage="chat", image_fn=None, timeout=300):
        """Send the message (plus history) to the planning LLM.

        Returns (reply_text, img_prompt, final_prompt, audio, thinking).
        - stage "chat"/"image": the model settles on the key-image prompt
          ([IMG_PROMPT] tags, or a tool-call prompt argument).
        - stage "video": the model settles on the final video prompt
          ([FINAL_PROMPT] tags, or a tool call whose prompt= is the finished
          prompt). When image_fn is given (the confirmed key image), it is
          attached as a real image so a vision-capable planning LLM can see it.
        """
        global PLAN_HISTORY
        content = user_text
        if stage == "video" and user_text == "__CONFIRM_IMAGE__":
            with SESSION_LOCK:
                ip = SESSION.get("image_prompt") or ""
            user_text = (
                "キー画像を確定しました。添付した画像（または以下の画像プロンプト）が動画の1フレーム目になります。\n"
                "ここからは【第2段階: 動画の相談】です。いきなり [FINAL_PROMPT] は作らず、"
                "まずこの画像をどんな動画にするか（動き・カメラワーク・長さ・セリフ・音楽など）を"
                "1〜2個の質問でユーザーと相談してください。\n"
                f"画像プロンプト: {ip}"
            )
        # multimodal: attach the image (base64) on every turn where one is
        # available — the confirmed key image, or the reference image the user
        # picked via 🗂 — so the planner can see it while planning/revising,
        # not only after confirmation. Planners without a vision projector
        # (PLAN_HAS_VISION false) get the prompt text only.
        ref_note = None
        if image_fn and stage in ("chat", "image") and user_text != "__CONFIRM_IMAGE__":
            ref_note = (
                "【添付画像】ユーザーが指定した参照画像です。この画像の被写体・外見・"
                "服装・雰囲気を企画のベースにしてください（同一キャラ・同一ルックを維持）。"
                "ユーザーの指示と矛盾しない限り、参照画像の内容を [IMG_PROMPT] に反映すること。"
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
            return reply, img_prompt, final_prompt, audio, thinking

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
                                "kind": "image" if fn.lower().endswith((".png", ".jpg", ".jpeg", ".webp")) else "video",
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
