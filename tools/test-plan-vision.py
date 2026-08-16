#!/usr/bin/env python3
"""test-plan-vision.py - verify the planning LLM really uses its vision input.

Checks two things:

  [A] Direct vision probe. A synthetic image with known ground truth
      (blue background, red circle, green square) is sent straight to the
      planning LLM (llama-server with --mmproj). The reply must name the
      actual colors/shapes - a model that guesses from text would fail.

  [B] Pipeline consistency. A synthetic "key image" (orange sky, blue sea,
      white sailboat) is pushed through the real h3-chat confirm path with
      NO text image-prompt (the session is reset first, so the model has
      nothing but the pixels). The resulting [FINAL_PROMPT] video prompt
      must describe the image's content.

Requires:
  - planning LLM on --llm (default http://127.0.0.1:8190), started with the
    mmproj vision encoder (tools\\h3-chat.ps1 does this for Qwen3.5).
  - h3-chat on --chat (default http://127.0.0.1:8189) for check [B].

Usage:
    python tools/test-plan-vision.py [--llm http://127.0.0.1:8190] [--chat http://127.0.0.1:8189] [--skip-pipeline]

Exit codes: 0 all passed, 1 a check failed, 2 environment missing.
"""

import argparse
import base64
import io
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("FAIL: Pillow (PIL) is required: pip install pillow")
    sys.exit(2)

PLAN_LLM = "http://127.0.0.1:8190"
CHAT = "http://127.0.0.1:8189"


def post(url, body, timeout=180):
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get_json(url, timeout=30):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def img_to_b64(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def llm_complete(llm, text, image=None, max_tokens=120):
    """OpenAI-style chat completion; attach a PNG image when given."""
    if image is None:
        content = text
    else:
        content = [
            {"type": "text", "text": text},
            {"type": "image_url",
             "image_url": {"url": "data:image/png;base64," + img_to_b64(image)}},
        ]
    d = post(llm.rstrip("/") + "/v1/chat/completions",
             {"messages": [{"role": "user", "content": content}],
              "max_tokens": max_tokens, "temperature": 0.0})
    return d["choices"][0]["message"].get("content") or ""


def make_probe_image():
    """Blue background, red circle (left), green square (right)."""
    img = Image.new("RGB", (512, 512), (30, 60, 200))
    d = ImageDraw.Draw(img)
    d.ellipse((80, 120, 280, 320), fill=(230, 30, 30))
    d.rectangle((300, 120, 460, 280), fill=(40, 210, 60))
    return img


def make_scene_image():
    """Orange sunset sky, dark blue sea, white sailboat - obvious content."""
    w, h = 640, 360
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    sky_h = int(h * 0.55)
    for y in range(sky_h):
        t = y / sky_h
        d.line([(0, y), (w, y)], fill=(int(255 - 30 * t), int(180 - 70 * t), int(60 + 20 * t)))
    d.rectangle((0, sky_h, w, h), fill=(12, 24, 110))
    d.rectangle((300, 250, 380, 268), fill=(240, 240, 240))          # hull
    d.polygon([(340, 130), (340, 250), (400, 250)], fill=(250, 250, 250))  # sail
    return img


def main():
    ap = argparse.ArgumentParser(description="Verify the planning LLM's vision input")
    ap.add_argument("--llm", default=PLAN_LLM)
    ap.add_argument("--chat", default=CHAT)
    ap.add_argument("--skip-pipeline", action="store_true",
                    help="skip check [B] (needs h3-chat running)")
    args = ap.parse_args()

    results = []

    # environment check (GET /v1/models - POST is not accepted there)
    try:
        get_json(args.llm.rstrip("/") + "/v1/models", timeout=10)
    except Exception:
        print("ENV: planning LLM not reachable at", args.llm)
        print("     Start it with the vision encoder first:")
        print("       powershell -ExecutionPolicy Bypass -File tools\\h3-chat.ps1")
        sys.exit(2)

    # ---- [A] direct vision probe -------------------------------------
    reply = llm_complete(args.llm,
                         "Describe the colors and shapes in this image in one short English sentence.",
                         make_probe_image())
    low = reply.lower()
    ok_a = (all(k in low for k in ("red", "green", "blue"))
            and any(k in low for k in ("circle", "round"))
            and any(k in low for k in ("square", "rectang")))
    print("[A] direct vision probe (blue bg / red circle / green square):",
          "PASS" if ok_a else "FAIL")
    print("    model:", reply.strip()[:220])
    results.append(ok_a)

    # ---- [B] pipeline consistency (key image -> video prompt) ---------
    if args.skip_pipeline:
        print("[B] pipeline consistency: SKIPPED (--skip-pipeline)")
        results.append(True)
    else:
        try:
            post(args.chat.rstrip("/") + "/api/plan",
                 {"text": "__RESET__", "stage": "chat"}, timeout=10)
            scene = make_scene_image()
            tmp = os.path.join(tempfile.gettempdir(), "plan_vision_key.png")
            scene.save(tmp)
            r = post(args.chat.rstrip("/") + "/api/plan",
                     {"text": "__CONFIRM_IMAGE__", "stage": "video", "image": tmp},
                     timeout=240)
            fp = (r.get("final_prompt") or "").strip()
            low = fp.lower()
            keys = ("orange", "sunset", "sea", "ocean", "water", "boat", "sail", "sky")
            hits = [k for k in keys if k in low]
            ok_b = len(hits) >= 2
            print("[B] pipeline consistency (orange sky / blue sea / white sail,"
                  " no text prompt given):", "PASS" if ok_b else "FAIL")
            print("    final_prompt:", fp[:250])
            print("    matched keywords:", hits)
            results.append(ok_b)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")[:200]
            print("[B] pipeline consistency: ERROR HTTP", e.code, body)
            results.append(False)
        except Exception as e:
            print("[B] pipeline consistency: ERROR", repr(e))
            results.append(False)

    ok = all(results)
    print("RESULT:", "ALL PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
