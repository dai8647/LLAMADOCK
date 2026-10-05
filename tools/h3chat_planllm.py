"""Planning-LLM: model discovery, spawn/stop/switch, VRAM guards."""

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


# Planner engine: single engine — Unsloth llama.cpp CUDA build (RTX 3080).
# Previously the HIP/gfx110X build for RX 7800 XT. CUDA runtime DLLs sit next
# to llama-server.exe (Ensure-UnslothCudaRuntime in select-model.ps1). Path may
# churn if Unsloth Desktop updates — _spawn_plan_llm re-resolves when missing.
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
        return "Unsloth (CUDA)"
    return "Unknown"
# ROCm PATH injection is a no-op after the 2026-09-11 CUDA switch (dir gone).
# CUDA DLLs are next to llama-server.exe (cwd in Popen).
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
    "reasoning_effort": "low",     # off, low, medium, xhigh (low = short thinking)
    "reasoning_budget": 768,        # max thinking tokens
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


def _url_alive(base):
    """True when an OpenAI-compatible endpoint answers /v1/models."""
    if not base:
        return False
    try:
        with urllib.request.urlopen(base.rstrip("/") + "/v1/models", timeout=2) as r:
            return r.status == 200
    except Exception:
        return False


def _gpu_used_mib():
    """Dedicated VRAM currently in use, in MiB. 0 when it cannot be measured."""
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "(Get-Counter '\\GPU Process Memory(*)\\Dedicated Usage' -ErrorAction Stop)"
             ".CounterSamples | Where-Object CookedValue -gt 0 | "
             "Measure-Object CookedValue -Sum | Select-Object -ExpandProperty Sum"],
            capture_output=True, text=True, timeout=20)
        used = float(out.stdout.strip())
        return int(used / (1024 * 1024))
    except Exception:
        return 0


def _other_llama_servers():
    """Other running llama-server.exe instances as (pid, port) — they are the
    likely VRAM competitors when the GPU planner fit-offloads to CPU."""
    out = []
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process -Filter \"Name='llama-server.exe'\" | "
             "Select-Object ProcessId, CommandLine | ConvertTo-Json -Compress"],
            capture_output=True, text=True, timeout=20)
        data = json.loads(r.stdout or "[]")
        if isinstance(data, dict):
            data = [data]
        for p in data or []:
            cl = p.get("CommandLine") or ""
            m = re.search(r"--port[= ](\d+)", cl)
            out.append((p.get("ProcessId"), m.group(1) if m else "?"))
    except Exception:
        pass
    return out


def _warn_if_vram_tight():
    """Print a loud warning when something still holds VRAM before a GPU
    planner load — llama.cpp --fit would silently offload layers to CPU
    (12 t/s instead of ~25 t/s measured on the 27B)."""
    try:
        used = _gpu_used_mib()
        model_gb = os.path.getsize(PLAN_MODEL_PATH) / (1024 ** 3) if os.path.isfile(PLAN_MODEL_PATH) else 0
        mm_gb = os.path.getsize(PLAN_MMPROJ_PATH) / (1024 ** 3) if PLAN_MMPROJ_PATH and os.path.isfile(PLAN_MMPROJ_PATH) else 0
        need_gb = model_gb + mm_gb + 1.5   # +KV cache / compute buffers
        total_gb = 16.0
        free_gb = total_gb - used / 1024
        if need_gb > free_gb - 0.5:
            msg = (f"h3-chat: WARNING: VRAM {used} MiB 使用中 / 空き {free_gb:.1f}GB — "
                   f"企画モデル {need_gb:.1f}GB が入り切らず auto-fit で CPU オフロードされます")
            others = _other_llama_servers()
            if others:
                peers = ", ".join(f"pid={pid} port={port}" for pid, port in others)
                msg += f" — 競合相手: 他の llama-server ({peers})。先に終了するか企画側を小さいモデルに"
            else:
                msg += " (ComfyUI のモデル残り・他アプリの VRAM 占有を確認)"
            print(msg)
    except Exception:
        pass


def _ensure_plan_cuda_runtime(server_bin):
    """Copy CUDA 13 DLLs next to llama-server when ggml-cuda.dll is present.

    ggml-cuda.dll imports cublas64_13 / nvcudart_hybrid64. Unsloth's Release
    folder does not ship them; without them llama-server silently falls back
    to CPU even with -ngl all (high CPU, no VRAM). Mirrors
    select-model.ps1 Ensure-UnslothCudaRuntime so plan mode / UI model
    switch works without a prior coder launch.
    """
    if not server_bin or not os.path.isfile(server_bin):
        return
    rel = os.path.dirname(server_bin)
    if not os.path.isfile(os.path.join(rel, "ggml-cuda.dll")):
        return
    if os.path.isfile(os.path.join(rel, "cublas64_13.dll")):
        return
    candidates = (
        r"C:\Users\dai86\.unsloth\studio\unsloth_studio\Lib\site-packages\torch\lib",
        r"C:\Users\dai86\Documents\ComfyUI\.venv\Lib\site-packages\torch\lib",
    )
    torch_lib = next((p for p in candidates if os.path.isdir(p)), None)
    if not torch_lib:
        return
    copies = (
        ("cublas64_13.dll", "cublas64_13.dll"),
        ("cublasLt64_13.dll", "cublasLt64_13.dll"),
        ("cudart64_13.dll", "cudart64_13.dll"),
        ("cudart64_13.dll", "nvcudart_hybrid64.dll"),
        ("nvrtc64_130_0.dll", "nvrtc64_130_0.dll"),
        ("nvrtc-builtins64_130.dll", "nvrtc-builtins64_130.dll"),
    )
    for src_name, dst_name in copies:
        src = os.path.join(torch_lib, src_name)
        dst = os.path.join(rel, dst_name)
        if os.path.isfile(src) and not os.path.isfile(dst):
            try:
                shutil.copy2(src, dst)
                print(f"h3-chat: installed CUDA runtime DLL for planner: {dst_name}")
            except OSError as e:
                print(f"h3-chat: failed to copy {dst_name}: {e}")


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
    _ensure_plan_cuda_runtime(PLAN_SERVER_BIN)
    server_bin = PLAN_SERVER_BIN
    args = [
        server_bin, "-m", PLAN_MODEL_PATH,
        "--port", str(PLAN_PORT),
        "-c", "8192", "--no-webui",
        "-np", "1",
        "--temp", "0.8", "--top-p", "0.95", "--min-p", "0.05",
        # 毎メッセージで巨大な PLAN_SYSTEM + 履歴を再送するため、prefix の
        # KV キャッシュ再利用で 2 ターン目以降の prefill を大幅短縮する。
        # コーディング起動と同じ組（b10715 で動作確認済み）。
        "--cache-reuse", "512",
        "--prio", "2",
    ]
    if PLAN_GPU:
        # GPU planner: full offload, jinja template, short reasoning.
        # hama-jp's research (github.com/hama-jp/qwen38-reasoning-effort):
        # --reasoning off pushes thinking INTO the answer text (3x tokens).
        # low effort keeps thinking separate and brief; budget 768 is a
        # safety net against runaway thinking (Qwen3.8-27B defaults xhigh).
        args += [
            "-ngl", "all", "--jinja",
            "-ub", "1024",
            "--chat-template-kwargs", json.dumps({"reasoning_effort": PLAN_SETTINGS["reasoning_effort"]}),
            "--reasoning-budget", str(PLAN_SETTINGS["reasoning_budget"]),
        ]
        # MTP self-draft (built into *_MTP.gguf). Unsloth CUDA build supports
        # --spec-type draft-mtp. Without it the 27B runs ~11-13 t/s; with it
        # ~18-26 t/s (HANDOFF / HauhauCS bench). Mirrors select-model.ps1.
        # Do NOT pass -md (draft context is derived from model_tgt).
        if re.search(r"(?i)mtp", os.path.basename(PLAN_MODEL_PATH or "")):
            args += [
                "--spec-type", "draft-mtp",
                "--spec-draft-n-max", "2",
                "--spec-draft-n-min", "1",
            ]
            if PLAN_SETTINGS["ctk"] and PLAN_SETTINGS["ctk"] != "none":
                args += ["-ctkd", PLAN_SETTINGS["ctk"]]
            if PLAN_SETTINGS["ctv"] and PLAN_SETTINGS["ctv"] != "none":
                args += ["-ctvd", PLAN_SETTINGS["ctv"]]
        # KV cache compression + Flash Attention (configurable via UI).
        # V quantization requires Flash Attention (see docs/LlamaDock-Runbook.md).
        if PLAN_SETTINGS["fa"]:
            args += ["-fa", "on"]
        if PLAN_SETTINGS["ctk"] and PLAN_SETTINGS["ctk"] != "none":
            args += ["-ctk", PLAN_SETTINGS["ctk"]]
        if PLAN_SETTINGS["ctv"] and PLAN_SETTINGS["ctv"] != "none":
            args += ["-ctv", PLAN_SETTINGS["ctv"]]
        # llama.cpp の --fit (デフォルト on) は入り切らない分を黙って CPU に落とす
        # (2026-09-05 実測: 27B Q3_K_XL が 12 t/s まで低下)。headroom を env で調整
        # できるようにしておく (MiB 単位。デフォルト 1024 — 狭めたい時は 256 等)。
        fit_target = os.environ.get("LLAMADOCK_PLAN_FIT_TARGET", "").strip()
        if fit_target:
            args += ["--fit-target", fit_target]
        _warn_if_vram_tight()
        if PLAN_MMPROJ_PATH and os.path.isfile(PLAN_MMPROJ_PATH):
            # Vision-capable planner: attach the mmproj shipped next to the
            # model so the planner can see the confirmed key image.
            args += ["--mmproj", PLAN_MMPROJ_PATH, "--image-min-tokens", "1024"]
    else:
        # --mlock は Unsloth CUDA ビルド (b11160) で "invalid argument" になり
        # プランナー spawn が即死する (2026-10-05 実測) ので外した。
        args += [
            "-ngl", "0",
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
            # CPU prefill: 大きめのバッチ + 分割処理でトークン生成と prefill を
            # 両立させる（4B Q4_K_M で実用域）。
            "-b", "2048", "-ub", "512",
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
    _kill_port(PLAN_PORT)


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
        _kill_port(PLAN_PORT)
        PLAN_MODEL_PATH = path
        PLAN_MMPROJ_PATH = mmproj or ""
        PLAN_GPU = bool(gpu)
        PLAN_PORT = 8191 if PLAN_GPU else 8190
        PLAN_URL_DEFAULT = f"http://127.0.0.1:{PLAN_PORT}"
        _kill_port(PLAN_PORT)   # stale leftover on the new port
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


def _kill_port(port):
    """Kill the process LISTENING on the given local port.

    netstat on a Japanese Windows emits CP932 bytes; decode with
    errors="replace" (we only need ASCII tokens: port, LISTENING, PID).
    """
    try:
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


__all__ = ['HERE', 'REPO', 'PLAN_GPU', 'PLAN_PORT', 'PLAN_URL_DEFAULT', 'MODEL_SCAN_ROOT', 'GPU_AUTO_MAX_GB', '_find_mmproj', 'scan_plan_models', '_auto_plan_model', '_resolve_plan_model', '_GPU_BIN_CANDIDATES', '_CPU_BIN_CANDIDATES', '_resolve_plan_bin', 'PLAN_MODEL_PATH', 'PLAN_MMPROJ_PATH', 'PLAN_SERVER_BIN', '_plan_engine_label', 'PLAN_ROCM_BIN', 'PLAN_HAS_VISION', 'PLAN_START_LOCK', 'PLAN_SETTINGS', 'PLAN_ENGINE', 'PLAN_PROC', 'PLAN_LAST_TRY', '_plan_alive', '_url_alive', '_gpu_used_mib', '_other_llama_servers', '_warn_if_vram_tight', '_ensure_plan_cuda_runtime', '_spawn_plan_llm', 'stop_plan_llm', 'ensure_plan_llm', 'switch_plan_model', 'NODE_PROMPT', 'NODE_SEED', 'SESSION', '_kill_port']
