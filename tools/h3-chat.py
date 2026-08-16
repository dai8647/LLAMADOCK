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
import json
import os
import random
import re
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import argparse
import json
import os
import random
import sys
import threading
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

# ComfyUI node ids in the super workflows
NODE_PROMPT = "6"     # MiniMaxH3ImageToVideo: user prompt
NODE_SEED = "7"       # KSampler: seed
NODE_SAVE = "10"      # SaveVideo: output filename

# Planning-LLM system prompt: shapes the video concept conversationally and,
# when the concept is settled, returns the final prompt in FINAL_PROMPT tags.
PLAN_SYSTEM = (
    "あなたは MiniMax H3 動画生成の企画アシスタントです。"
    "ユーザーのアイデアを聞き出し、映像として具体化していきます。"
    "- 関数呼び出し・ツールは一切使わないでください。必ず普通の文章で答えてください。"
    "- 会話のたびに、映像のポイント（被写体・背景・動き・雰囲気・カメラ）を1つずつ確認・提案する。"
    "- 質問は一度に1〜2個までに絞る。長々と説明せず簡潔に。"
    "- ユーザーが満足したら、最終的な動画生成プロンプトを英語で書き、"
    "  それを [FINAL_PROMPT] と [/FINAL_PROMPT] のタグで囲んで返す。"
    "  （例: [FINAL_PROMPT]A quiet beach at sunset, gentle waves, cinematic shot[/FINAL_PROMPT]）"
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
  .bot .path { color:var(--muted); font-size:11px; margin-top:6px; word-break:break-all; }
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
</style>
</head>
<body>
<header>
  <h1>🎬 MiniMax H3 チャット動画生成</h1>
  <span class="sub">Turbo LoRA 8step・音声付き（32B / 4B エンコーダ切替）</span>
  <span id="status-dot" title="ComfyUI 接続状態"></span>
</header>
<main id="msgs"></main>
<footer>
  <div id="modes">
    <label><input type="radio" name="mode" value="high" checked> 高精度 32B（フル・約9分・日本語に強い）</label>
    <label><input type="radio" name="mode" value="quick"> クイック 32B（短尺・約1分）</label>
    <label><input type="radio" name="mode" value="lite"> 軽量 4B（省VRAM・約9分）</label>
    <label class="plan"><input type="checkbox" id="planmode"> ✎ 企画モード（会話で練ってから生成）</label>
  </div>
  <textarea id="input" placeholder="作りたい動画を言葉で書いてください。例：夕焼けの海岸で波が静かに打ち寄せる映像"></textarea>
  <button id="send" onclick="send()">生成 ▶</button>
</footer>
<script>
const $ = s => document.querySelector(s);
let busy = false;

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
      body: JSON.stringify({mode: mode, text: text})
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
      body: JSON.stringify({text: text})
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || ("HTTP " + r.status));
    let html = '<div class="meta">企画案</div>' + esc(j.reply || "（応答なし）");
    if (j.final_prompt) {
      html += '<button class="genplan" onclick="genPlan(' + JSON.stringify(JSON.stringify(j.final_prompt)) + ')">🎬 この企画で生成 ▶</button>';
    }
    bot.innerHTML = html;
  } catch (e) {
    bot.innerHTML = '<div class="meta">エラー</div><div class="err">' + esc(String(e.message || e)) + "</div>";
  }
  busy = false;
  $("#send").disabled = false;
}

async function genPlan(finalJson) {
  if (busy) return;
  const finalPrompt = JSON.parse(finalJson);
  busy = true;
  $("#send").disabled = true;
  const mode = document.querySelector('input[name="mode"]:checked').value;
  addMsg("user", "✅ この企画で生成する: " + finalPrompt);
  const bot = addMsg("bot", '<div class="meta">生成中…（モデルロード込みで数分）</div>');
  try {
    const r = await fetch("/api/generate", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({mode: mode, text: finalPrompt})
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
        elif parsed.path == "/api/plan":
            self._plan(parsed)
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
        text = (req.get("text") or "").strip()
        if mode not in WORKFLOWS:
            self._json(400, {"error": "unknown mode: " + mode})
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
        wf[NODE_PROMPT]["inputs"]["prompt"] = text
        wf[NODE_SEED]["inputs"]["seed"] = random.randint(0, 2**31 - 1)
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
        if not text:
            self._json(400, {"error": "メッセージが空です"})
            return
        if not self.server.plan_url:
            self._json(503, {"error": "企画 LLM が接続されていません（h3-chat.ps1 で起動してください）"})
            return
        try:
            reply, final_prompt = self._plan_llm(text)
        except Exception as e:
            self._json(502, {"error": f"企画 LLM エラー: {e}"})
            return
        if final_prompt and not reply:
            reply = "企画案がまとまりました。下のボタンで生成できます。\n\n" + final_prompt
        self._json(200, {"reply": reply, "final_prompt": final_prompt})

    def _plan_llm(self, user_text, timeout=300):
        """Send the message (plus history) to the planning LLM.

        Returns (reply_text, final_prompt) where final_prompt is set when the
        model settled on a final video prompt (either [FINAL_PROMPT] tags or a
        tool call whose prompt= argument is the finished prompt).
        """
        global PLAN_HISTORY
        with PLAN_LOCK:
            PLAN_HISTORY.append({"role": "user", "content": user_text})
            # keep the context bounded; system prompt always first
            history = [{"role": "system", "content": PLAN_SYSTEM}] + PLAN_HISTORY[-12:]
            body = json.dumps({
                "messages": history,
                "max_tokens": 512,
                "temperature": 0.7,
            }).encode("utf-8")
            req = urllib.request.Request(
                self.server.plan_url.rstrip("/") + "/v1/chat/completions",
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
            m = FINAL_RE.search(reply)
            final_prompt = m.group(1).strip() if m else None
            if not final_prompt:
                final_prompt = _tool_prompt(content)
            if not final_prompt and _looks_like_final(reply):
                final_prompt = reply
            # keep a non-empty assistant turn in the history so follow-up
            # messages have context (a tool-call reply becomes its prompt text)
            history_reply = reply or final_prompt or "（企画案）"
            PLAN_HISTORY.append({"role": "assistant", "content": history_reply})
            return reply, final_prompt

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
        for nid, out in entry.get("outputs", {}).items():
            for key, val in out.items():
                if isinstance(val, list):
                    for item in val:
                        if isinstance(item, dict) and "filename" in item:
                            fn = item["filename"]
                            videos.append({
                                "filename": fn,
                                "type": item.get("type", "output"),
                                "subfolder": item.get("subfolder", ""),
                                "path": os.path.join(
                                    os.path.join(os.environ.get("LLAMADOCK_COMFY_ROOT", r"C:\Users\dai86\Documents\ComfyUI"), "output"),
                                    item.get("subfolder", ""), fn),
                            })
        self._json(200, {"status": "success", "videos": videos})

    def _view(self, query):
        params = urllib.parse.parse_qs(query)
        fn = params.get("filename", [""])[0]
        if not fn:
            self._json(400, {"error": "missing filename"})
            return
        url = self.server.comfy_base + "/view?" + urllib.parse.urlencode({
            "filename": fn,
            "subfolder": params.get("subfolder", [""])[0],
            "type": params.get("type", ["output"])[0],
        })
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = r.read()
            self.send_response(200)
            ctype = "video/mp4" if fn.lower().endswith(".mp4") else "application/octet-stream"
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self._json(502, {"error": self._proxy_error(e)})

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
    url = f"http://127.0.0.1:{args.port}"
    print(f"h3-chat: {url}")
    print(f"h3-chat: ComfyUI = {server.comfy_base}  (high={WORKFLOWS['high']} quick={WORKFLOWS['quick']} lite={WORKFLOWS['lite']})")
    print(f"h3-chat: plan LLM = {server.plan_url or 'off'}")
    print("h3-chat: Ctrl+C で停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
