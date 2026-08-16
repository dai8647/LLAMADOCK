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
}

# Selectable H3 video DiT checkpoints (node "1" = UNETLoader in all video
# workflows). "default" is the int8 pruned PinkCherry; "10eros" is the
# NVFP4 10Eros-Max beta2 (12.5GB, higher quality, 16GB-VRAM friendly).
DITS = {
    "default": "alpha-0.5-testing\\PinkCherry_h3_fl2va_pruned_int8_v0.5-alpha.safetensors",
    "10eros": "10Eros-Max\\10Eros_Max_h3_fl2va_beta2_pruned_nvfp4.safetensors",
}
NODE_UNET = "1"

# Z-Image Turbo (key-image) workflow: 企画 → キー画像 → 確認 → 動画
ZIMG_WORKFLOW = os.path.join(REPO, "h3_workflow_zimage.json")
NODE_ZIMG_PROMPT = "5"   # CLIPTextEncode: image prompt
NODE_ZIMG_LATENT = "7"   # EmptySD3LatentImage: size
NODE_ZIMG_SEED = "8"     # KSampler: seed
NODE_ZIMG_SAVE = "10"    # SaveImage: output filename

# Standard ports (must match tools\h3-chat.ps1 / select-model.ps1)
PLAN_URL_DEFAULT = "http://127.0.0.1:8190"
PLAN_PORT = 8190

# ComfyUI node ids in the super workflows
NODE_PROMPT = "6"     # MiniMaxH3ImageToVideo: user prompt
NODE_SEED = "7"       # KSampler: seed
NODE_SAVE = "10"      # SaveVideo: output filename

# Per-session plan state (single-user local UI): image -> video pipeline.
SESSION = {"image_prompt": None, "video_prompt": None}
SESSION_LOCK = threading.Lock()

# Server-side safety net: when a video finishes and nothing new is started,
# stop ComfyUI + planning LLM (freeing GPU/RAM) even if the browser tab is
# closed. The browser shows a shorter interactive countdown; this is the
# guarantee that "作成終わったらちゃんと落とす".
AUTO_STOP_SECONDS = 180


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
PLAN_SYSTEM = (
    "あなたは「キー画像 → 動画」の2段階で映像作品を作る企画アシスタントです。"
    "- 関数呼び出し・ツールは一切使わないでください。必ず普通の文章で答えてください。"
    "- 会話のたびに、映像のポイント（被写体・背景・構図・雰囲気・ライティング・動き・カメラ）を1つずつ確認・提案する。"
    "- 質問は一度に1〜2個までに絞る。長々と説明せず簡潔に。"
    "【第1段階: キー画像】ユーザーのアイデアを聞き出し、被写体・背景・構図・雰囲気・ライティングを具体化する。"
    "- キー画像の内容が固まったら、英語の画像プロンプトを [IMG_PROMPT] と [/IMG_PROMPT] で囲んで返す。"
    "  （例: [IMG_PROMPT]A shiba inu running along the shoreline at sunset, warm golden light, footprints in wet sand, low-angle cinematic composition[/IMG_PROMPT]）"
    "- タグは必ず1組だけ。タグ以外の補足説明は不要。固まるまでは普通の日本語で会話を続ける。"
    "【第2段階: 動画プロンプト】ユーザーがキー画像を確定したら、その画像の内容・構図を保ったまま、"
    "動き・カメラワーク・時間経過・雰囲気を加えた英語の動画プロンプトを [FINAL_PROMPT] と [/FINAL_PROMPT] で囲んで返す。"
    "  （例: [FINAL_PROMPT]A shiba inu runs along the shoreline at sunset, its paws leaving footprints in the wet sand, the camera slowly dollies in, warm golden light glinting off gentle waves[/FINAL_PROMPT]）"
    "- タグは必ず1組だけ。タグ以外の補足説明は不要。"
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


def _clean_plan_reply(text):
    """Remove tool-call markup and empty lines from a planning-LLM reply."""
    text = TOOL_CALL_RE.sub("", text or "")
    return "\n".join(line.rstrip() for line in text.splitlines() if line.strip())


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

IMG_FINAL_RE = re.compile(r"\[IMG_PROMPT\](.*?)\[/IMG_PROMPT\]", re.S)

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

FINAL_RE = re.compile(r"\[FINAL_PROMPT\](.*?)\[/FINAL_PROMPT\]", re.S)

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
  :root { --bg:#0f1115; --panel:#171a21; --line:#262b36; --text:#e8eaf0;
          --muted:#8b93a3; --accent:#5b8cff; --ok:#3ecf8e; --err:#ff5d5d; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text);
         font-family:"Segoe UI", "Noto Sans JP", sans-serif; height:100vh; display:flex;
         flex-direction:column; }
  header { padding:12px 20px; border-bottom:1px solid var(--line);
           display:flex; align-items:center; gap:14px; }
  header h1 { font-size:16px; margin:0; font-weight:600; }
  header .sub { color:var(--muted); font-size:12px; }
  #status-dot { width:9px; height:9px; border-radius:50%; background:#555; margin-left:auto; }
  #status-dot.ok { background:var(--ok); }
  #status-dot.down { background:var(--err); }
  main { flex:1; overflow-y:auto; padding:18px 20px; }
  .msg { max-width:80%; padding:10px 14px; border-radius:14px; margin-bottom:12px;
         font-size:14px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }
  .user { background:#243252; margin-left:auto; border-bottom-right-radius:4px; }
  .bot  { background:var(--panel); border:1px solid var(--line); border-bottom-left-radius:4px; }
  .bot .meta { color:var(--muted); font-size:11px; margin-bottom:6px; }
  .bot .err { color:var(--err); }
  .bot video { width:100%; max-width:520px; border-radius:8px; background:#000; display:block; margin-top:8px; }
  .bot img { width:100%; max-width:520px; border-radius:8px; background:#000; display:block; margin-top:8px; }
  .bot .path { color:var(--muted); font-size:11px; margin-top:6px; word-break:break-all; }
  .row { display:flex; gap:8px; margin-top:10px; flex-wrap:wrap; }
  .row button.ok { background:var(--ok); color:#0b2b1c; }
  .row button.rev { background:#ffb020; color:#3a2400; }
  .row button.small { background:transparent; color:var(--muted); border:1px solid var(--line); }
  #shutdown-box { display:none; border-top:2px solid var(--ok); background:#0e241a;
                  padding:10px 20px; font-size:13px; }
  #shutdown-box .meta { color:var(--muted); font-size:11px; margin-bottom:6px; }
  #shutdown-box button { padding:8px 14px; font-size:12px; margin-right:8px; }
  #shutdown-box button.warn { background:var(--err); }
  footer { border-top:1px solid var(--line); padding:12px 20px; display:flex; gap:10px;
           align-items:flex-end; }
  #modes { display:flex; flex-direction:column; gap:4px; margin-right:8px; }
  #modes label { font-size:12px; color:var(--muted); display:flex; gap:6px; align-items:center; cursor:pointer; }
  #modes input { accent-color:var(--accent); }
  textarea { flex:1; resize:none; height:56px; background:var(--panel); color:var(--text);
             border:1px solid var(--line); border-radius:10px; padding:10px 12px;
             font:inherit; font-size:14px; outline:none; }
  textarea:focus { border-color:var(--accent); }
  button { background:var(--accent); color:#fff; border:none; border-radius:10px;
           padding:12px 22px; font-size:14px; font-weight:600; cursor:pointer; }
  button:disabled { opacity:.5; cursor:default; }
  .plan { border-top:1px solid var(--line); padding-top:6px; }
  .genplan { display:block; margin-top:10px; background:var(--ok); color:#0b2b1c; }
  .hint { color:var(--muted); font-size:11px; }
  .ditrow { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-top:6px; font-size:12px; }
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
<footer>
  <div id="modes">
    <label><input type="radio" name="mode" value="high" checked> 高精度 32B（フル・約9分・日本語に強い）</label>
    <label><input type="radio" name="mode" value="quick"> クイック 32B（短尺・約1分）</label>
    <label><input type="radio" name="mode" value="lite"> 軽量 4B（省VRAM・約9分）</label>
    <div class="ditrow">
      <span class="hint">動画モデル:</span>
      <label><input type="radio" name="dit" value="default" checked> 標準 int8（PinkCherry）</label>
      <label><input type="radio" name="dit" value="10eros"> 10Eros NVFP4（高画質）</label>
    </div>
    <label class="plan"><input type="checkbox" id="planmode"> ✎ 企画モード（キー画像を作って確認してから動画）</label>
    <button id="btn-reset" onclick="resetPlan()">🔄 新しい企画</button>
  </div>
  <textarea id="input" placeholder="作りたい動画を言葉で書いてください。例：夕焼けの海岸で柴犬が波打ち際を走る映像"></textarea>
  <button id="send" onclick="send()">生成 ▶</button>
</footer>
<script>
const $ = s => document.querySelector(s);
let busy = false;
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

async function send() {
  const text = $("#input").value.trim();
  if (!text || busy) return;
  busy = true;
  $("#send").disabled = true;
  $("#input").value = "";
  addMsg("user", esc(text));
  if ($("#planmode").checked) { plan(text); return; }
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  const mode = document.querySelector('input[name="mode"]:checked').value;
  try {
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({mode: mode, text: text, dit: ditValue()})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    busy = false;
    $("#send").disabled = false;
  }
}

async function plan(text) {
  const bot = addMsg("bot", '<div class="meta">企画 LLM が考え中…</div>');
  try {
    const r = await fetch("/api/plan", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: text, stage: planStage})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    let html = '<div class="meta">企画案</div>' + esc(j.reply || "（応答なし）");
    if (j.img_prompt) {
      lastImgPrompt = j.img_prompt;
      if (planStage === "image") {
        // 修正リクエスト: 新しい画像プロンプトでキー画像を再生成する
        bot.innerHTML = html + '<div class="meta">キー画像を再生成します…</div>';
        genImage(bot);
        return;   // genImage が busy を管理する
      }
      planStage = "image";
      html += '<button class="genplan" onclick="genImage()">🖼 キー画像を生成 ▶</button>';
      html += '<div class="hint">画像を確認して OK なら確定、気に入らなければ「🔁 修正する」で修正できます。</div>';
    } else if (j.final_prompt) {
      // Store the prompt in a module variable instead of inlining it into the
      // onclick attribute: prompts may contain double quotes / HTML special
      // characters that would break the inline-JSON escaping.
      lastFinalPrompt = j.final_prompt;
      planStage = "video";
      html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
    }
    bot.innerHTML = html;
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
  busy = false;
  $("#send").disabled = false;
}

async function genImage(prevBot) {
  if (!lastImgPrompt || busy) return;
  const bot = prevBot || addMsg("bot", '<div class="meta">Z-Image Turbo でキー画像を生成中…（数秒）</div>');
  busy = true;
  $("#send").disabled = true;
  try {
    const r = await fetch("/api/zimg", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: lastImgPrompt})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    pollImage(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    busy = false;
    $("#send").disabled = false;
  }
}

async function pollImage(id, bot) {
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const img = j.videos[0];
      const fn = img.filename;
      curImageFilename = fn;
      bot.innerHTML =
        '<div class="meta">キー画像 ✅（Z-Image Turbo・確認してね）</div>' +
        '<img src="/api/view?filename=' + encodeURIComponent(fn) + '&type=' + encodeURIComponent(img.type || "output") + '">' +
        '<div class="row">' +
        '<button class="ok" onclick="confirmImage()">✅ この画像で確定 → 動画へ</button>' +
        '<button class="rev" onclick="reviseImage()">🔁 修正する</button>' +
        "</div>";
      planStage = "image";
      busy = false;
      $("#send").disabled = false;
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "画像生成に失敗しました") + "</div>";
      busy = false;
      $("#send").disabled = false;
      return;
    }
    bot.querySelector(".meta").textContent = "キー画像生成中… " + (j.extra || "");
    setTimeout(() => pollImage(id, bot), 2000);
  } catch (e) {
    setTimeout(() => pollImage(id, bot), 2000);
  }
}

function reviseImage() {
  planStage = "image";
  $("#input").placeholder = "修正したい点を入力（例：犬を白く、夕焼けをもっと赤く）";
  $("#input").focus();
}

function confirmImage() {
  if (busy) return;
  busy = true;
  $("#send").disabled = true;
  const bot = addMsg("bot", '<div class="meta">企画 LLM が動画プロンプトを作成中…（Z-Image はアンロード済み）</div>');
  (async () => {
    try {
      const r = await fetch("/api/plan", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({text: "__CONFIRM_IMAGE__", stage: "video", image: curImageFilename})
      });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
      let html = '<div class="meta">画像を確定 ✅（企画 LLM が画像を見て動画プロンプト作成）</div>' + esc(j.reply || "（応答なし）");
      if (j.final_prompt) {
        lastFinalPrompt = j.final_prompt;
        planStage = "video";
        html += '<button class="genplan" onclick="genPlanLast()">🎬 この企画で生成 ▶</button>';
        html += '<div class="hint">動画プロンプトを調整したければ、このまま日本語で指示できます（例：カメラはゆっくり寄って）</div>';
      }
      bot.innerHTML = html;
    } catch (e) {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    }
    busy = false;
    $("#send").disabled = false;
  })();
}

function genPlanLast() {
  if (busy) return;
  if (!lastFinalPrompt) return;
  const finalPrompt = lastFinalPrompt;
  lastFinalPrompt = null;
  busy = true;
  $("#send").disabled = true;
  const mode = document.querySelector('input[name="mode"]:checked').value;
  addMsg("user", "✅ この企画で生成する: " + finalPrompt);
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  doGenerate(mode, finalPrompt, bot);
}

async function doGenerate(mode, text, bot) {
  try {
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({mode: mode, text: text, dit: ditValue()})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    poll(j.prompt_id, bot);
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
    busy = false;
    $("#send").disabled = false;
  }
}

async function poll(id, bot) {
  try {
    const r = await fetch("/api/status/" + id);
    const j = await r.json();
    if (j.status === "success") {
      const v = j.videos[0];
      bot.innerHTML = '<div class="meta">完成 ✅</div>' +
        '<video controls autoplay loop muted src="/api/view?filename=' + encodeURIComponent(v.filename) +
        '&type=' + encodeURIComponent(v.type || "output") + '"></video>' +
        '<div class="path">' + esc(v.path) + "</div>";
      busy = false;
      $("#send").disabled = false;
      startShutdown(90);
      return;
    }
    if (j.status === "error") {
      bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(j.error || "失敗しました") + "</div>";
      busy = false;
      $("#send").disabled = false;
      return;
    }
    // still running: refresh the eta text every poll
    bot.querySelector(".meta").textContent = "生成中… " + (j.extra || "") + "（待機中: " + j.pending + " 件）";
    setTimeout(() => poll(id, bot), 3000);
  } catch (e) {
    setTimeout(() => poll(id, bot), 3000);
  }
}

function startShutdown(seconds) {
  shutdownLeft = seconds || 90;
  const box = $("#shutdown-box");
  box.style.display = "block";
  box.innerHTML =
    '<div class="meta">生成完了 ✅ 自動停止まで <b id="countdown">' + shutdownLeft + "</b> 秒（GPU・メモリを解放します）</div>" +
    '<button class="warn" onclick="stopAll()">🛑 今すぐすべて終了</button>' +
    '<button onclick="stopComfy()">ComfyUI だけ停止</button>' +
    '<button class="small" onclick="cancelStop()">キャンセル</button>';
  clearInterval(shutdownTimer);
  shutdownTimer = setInterval(() => {
    shutdownLeft--;
    if (shutdownLeft <= 0) {
      clearInterval(shutdownTimer);
      shutdownTimer = null;
      stopAll();
      return;
    }
    const c = $("#countdown");
    if (c) c.textContent = shutdownLeft;
  }, 1000);
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

function resetPlan() {
  fetch("/api/plan", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({text: "__RESET__"})
  });
  lastImgPrompt = null;
  lastFinalPrompt = null;
  planStage = "chat";
  addMsg("bot", '<div class="meta">新しい企画</div>新しい企画を始めましょう。作りたい映像を教えてください。');
}

$("#planmode").addEventListener("change", e => {
  $("#btn-reset").style.display = e.target.checked ? "" : "none";
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
        elif parsed.path == "/api/shutdown":
            self._shutdown(parsed)
        else:
            self._json(404, {"error": "not found"})

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 1_000_000:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def _generate(self, parsed):
        try:
            req = self._read_json_body()
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        mode = req.get("mode", "quick")
        dit = req.get("dit", "default")
        text = (req.get("text") or "").strip()
        if mode not in WORKFLOWS:
            self._json(400, {"error": "unknown mode: " + mode})
            return
        if dit not in DITS:
            self._json(400, {"error": "unknown dit: " + dit})
            return
        if not text:
            self._json(400, {"error": "プロンプトが空です"})
            return
        try:
            with open(WORKFLOWS[mode], encoding="utf-8") as f:
                wf = json.load(f)["prompt"]
        except Exception as e:
            self._json(500, {"error": f"ワークフロー読み込み失敗: {e}"})
            return
        wf[NODE_UNET]["inputs"]["unet_name"] = DITS[dit]
        wf[NODE_PROMPT]["inputs"]["prompt"] = text
        wf[NODE_SEED]["inputs"]["seed"] = random.randint(0, 2**31 - 1)
        self.server.autostop.poke()
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
            self._json(200, {"prompt_id": json.loads(raw)["prompt_id"]})
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
            self._json(503, {"error": "企画 LLM が接続されていません（h3-chat.ps1 で起動してください）"})
            return
        self.server.autostop.poke()
        image = req.get("image") or None   # 確定したキー画像のファイル名（視覚入力）
        if stage == "video" and text == "__CONFIRM_IMAGE__":
            # キー画像が確定: Z-Image Turbo をアンロードして VRAM を解放してから
            # 企画 LLM に動画プロンプトを作らせる。
            self._free_comfy()
        try:
            reply, img_prompt, final_prompt = self._plan_llm(text, endpoint, stage, image)
        except Exception as e:
            self._json(502, {"error": f"企画 LLM エラー: {e}"})
            return
        if final_prompt and not reply:
            reply = "動画プロンプトがまとまりました。下のボタンで生成できます。\n\n" + final_prompt
        if img_prompt and not reply:
            reply = "キー画像のプロンプトがまとまりました。下のボタンで画像を生成できます。\n\n" + img_prompt
        self._json(200, {"reply": reply, "img_prompt": img_prompt, "final_prompt": final_prompt})

    def _plan_reset(self):
        global PLAN_HISTORY
        with PLAN_LOCK:
            PLAN_HISTORY.clear()
        with SESSION_LOCK:
            SESSION["image_prompt"] = None
            SESSION["video_prompt"] = None

    def _plan_endpoint(self, probe=True):
        """Return the planning-LLM base URL to use.

        Prefers the configured --plan-url; otherwise auto-detects the standard
        llama-server on port 8190 so plan mode works no matter how h3-chat.py
        was started. Returns None when no planning LLM is reachable.
        """
        if self.server.plan_url:
            return self.server.plan_url
        try:
            with urllib.request.urlopen(PLAN_URL_DEFAULT + "/v1/models", timeout=2) as r:
                if r.status == 200:
                    return PLAN_URL_DEFAULT
        except Exception:
            pass
        return None

    def _plan_llm(self, user_text, endpoint, stage="chat", image_fn=None, timeout=300):
        """Send the message (plus history) to the planning LLM.

        Returns (reply_text, img_prompt, final_prompt).
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
                "キー画像を確定しました。添付した画像（または以下の画像プロンプト）をベースに、"
                "動画プロンプトを作成してください。画像の内容・構図を保ちつつ、"
                "動き・カメラワーク・時間経過・雰囲気を加えた英語のプロンプトを "
                "[FINAL_PROMPT] と [/FINAL_PROMPT] のタグで囲んで返してください。\n"
                f"画像プロンプト: {ip}"
            )
            # multimodal: attach the confirmed key image (base64) so the
            # planning LLM can actually see what was rendered
            if image_fn:
                abspath = self.server.local_files.get(image_fn) or image_fn
                if os.path.isfile(abspath):
                    try:
                        with open(abspath, "rb") as f:
                            b64 = base64.b64encode(f.read()).decode("ascii")
                        ext = os.path.splitext(image_fn)[1].lower().lstrip(".")
                        if ext == "jpg":
                            ext = "jpeg"
                        if ext not in ("png", "jpeg", "webp"):
                            ext = "png"
                        content = [
                            {"type": "text", "text": user_text},
                            {"type": "image_url", "image_url": {"url": f"data:image/{ext};base64,{b64}"}},
                        ]
                    except Exception:
                        content = user_text
        with PLAN_LOCK:
            PLAN_HISTORY.append({"role": "user", "content": content})
            # keep the context bounded; system prompt always first
            history = [{"role": "system", "content": PLAN_SYSTEM}] + PLAN_HISTORY[-12:]
            body = json.dumps({
                "messages": history,
                "max_tokens": 512,
                "temperature": 0.7,
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
            # some reasoning models put the text in reasoning_content
            if not content.strip():
                content = msg.get("reasoning_content") or ""
            reply = _clean_plan_reply(content)
            img_prompt = None
            final_prompt = None
            if stage == "video":
                m = FINAL_RE.search(reply)
                final_prompt = m.group(1).strip() if m else None
                if not final_prompt:
                    final_prompt = _tool_prompt(content)
                if not final_prompt and _looks_like_final(reply):
                    final_prompt = reply
            else:
                m = IMG_FINAL_RE.search(reply)
                img_prompt = m.group(1).strip() if m else None
                if not img_prompt:
                    m = FINAL_RE.search(reply)
                    img_prompt = m.group(1).strip() if m else None
                if not img_prompt:
                    img_prompt = _tool_prompt(content)
                if not img_prompt and _looks_like_final(reply):
                    img_prompt = reply
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
            return reply, img_prompt, final_prompt

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
        try:
            width = max(256, min(int(req.get("width") or 512), 1024))
            height = max(256, min(int(req.get("height") or 320), 1024))
        except Exception:
            width, height = 512, 320
        try:
            with open(ZIMG_WORKFLOW, encoding="utf-8") as f:
                wf = json.load(f)["prompt"]
        except Exception as e:
            self._json(500, {"error": f"Z-Image ワークフロー読み込み失敗: {e}"})
            return
        wf[NODE_ZIMG_PROMPT]["inputs"]["text"] = text
        wf[NODE_ZIMG_LATENT]["inputs"]["width"] = width
        wf[NODE_ZIMG_LATENT]["inputs"]["height"] = height
        wf[NODE_ZIMG_SEED]["inputs"]["seed"] = random.randint(0, 2**31 - 1)
        self.server.autostop.poke()
        self._free_comfy()
        try:
            _, raw, _ = self._comfy("POST", "/prompt", {"prompt": wf})
            self._json(200, {"prompt_id": json.loads(raw)["prompt_id"]})
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

    def _status(self, pid):
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
            self._json(200, {"status": "running", "extra": "", "pending": n_pending})
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
            self._json(200, {"status": "running", "extra": "", "pending": n_pending})
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
    server.autostop = _AutoStop(server)
    url = f"http://127.0.0.1:{args.port}"
    print(f"h3-chat: {url}")
    print(f"h3-chat: ComfyUI = {server.comfy_base}  (high={WORKFLOWS['high']} quick={WORKFLOWS['quick']} lite={WORKFLOWS['lite']})")
    print(f"h3-chat: DITs = default / 10eros ({DITS['10eros']})")
    print(f"h3-chat: Z-Image = {ZIMG_WORKFLOW}")
    print(f"h3-chat: plan LLM = {server.plan_url or 'off'}")
    print("h3-chat: Ctrl+C で停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
