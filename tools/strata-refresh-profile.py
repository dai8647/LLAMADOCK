"""tools/strata-refresh-profile.py - rebuild the Strata expert-traffic profile in one command.

WHY. The serve engine loads its VRAM expert tier by the ranking in --expert-profile. The
GENERIC profile shipped with the pack ranks for someone else's traffic; ours is Japanese
DSH chat. With a profile built from OUR routing the same server runs ~2x faster
(2026-10-08: expert-cache hit 12.4% -> 79%, prose decode 18.6 -> 32.7 tok/s). The ranking
follows traffic, so re-run this after the usage mix shifts (rough rule: monthly, or whenever
answers move to new topics). WHAT IT DOES, in order:

  1. stops whatever holds :8080 (the LlamaDock serve and its strata.exe child)
  2. boots the canonical strata-iq3.json + --dump-routing as a TRACE engine
  3. replays representative Japanese prompts (built-in set + --prompts-file extras)
  4. stops the trace engine, runs tools/make_profile.py --reorder over the trace
  5. repoints strata-iq3.json's --expert-profile at the new dated profile (in place)
  6. restarts the canonical serve via tools/strata-gpu.ps1 restore (truly detached;
     its stdout/stderr -> Strata/probes/serve-gpu.log) and does a final RT check

The gateway on :8090 keeps running the whole time and reconnects by itself.
Non-interactive by design (safe to schedule); add --dry-run to see the plan only.
"""
import argparse
import datetime
import json
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

STRATA = Path(r"C:/Users/dai86/Strata")
MODEL_NAME = "Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS"

# representative traffic: long Japanese prose in the topics DSH actually gets
PROMPTS = [
    ("名古屋の観光名所を10か所、それぞれの特徴を2文ずつで説明して。", 400),
    ("量子コンピュータの現在の課題と、誤り訂正符号がなぜ不可欠なのかを、初学者向けに長めに解説して。", 400),
    ("日本の都市銀行とネット銀行の手数料・金利・利便性を比較するコラムを書いて。具体例を多くして。", 400),
    ("サーバー運用で起きている障害の切り分け手順を、タイムスタンプ整列から再発防止策まで段階的に日本語で説明してください。", 400),
]


def sh(cmd, **kw):
    return subprocess.run(cmd, **kw)


def stop_8080():
    proc = sh(["netstat", "-ano"], capture_output=True)
    out = (proc.stdout or b"").decode("mbcs", "replace")  # JP Windows prints cp932
    pids = set()
    for line in out.splitlines():
        if ":8080" in line and "LISTENING" in line:
            pids.add(line.split()[-1])
    for pid in pids:
        sh(["taskkill", "/PID", pid, "/T", "/F"], capture_output=True)
    sh(["taskkill", "/IM", "strata.exe", "/F"], capture_output=True)
    if pids:
        time.sleep(3)
    return bool(pids)


def port_open(port=8080):
    with socket.socket() as s:
        s.settimeout(0.4)
        return s.connect_ex(("127.0.0.1", port)) == 0


def post(prompt, max_tokens, port=8080, model=None):
    body = json.dumps({"model": model or MODEL_NAME,
                       "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": max_tokens, "temperature": 0}).encode("utf-8")
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r).get("usage", {}).get("completion_tokens", "?")


def serve_env():
    # same PATH/PYTHONPATH as the canonical launcher line
    import os
    env_path = "C:/Users/dai86/rocm-sdk-core/_rocm_sdk_core/bin"
    return {**os.environ, "PATH": env_path + ";" + os.environ.get("PATH", ""), "PYTHONPATH": "tools"}


def wait_loaded(timeout=300, model=None):
    # the honest gate is a tiny completion answering 200
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if post("x", 1, model=model) != "?":
                return True
        except Exception:
            time.sleep(4)
    raise RuntimeError("engine did not answer /v1/chat/completions within timeout")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strata", default=str(STRATA))
    ap.add_argument("--config", default="strata-iq3.json",
                    help="which Strata serve config to refresh (profiles are per-model: "
                         "routing is the model's own, so refresh each pack you serve)")
    ap.add_argument("--prompts-file", help="UTF-8 text file, one prompt per line")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    root = Path(a.strata)
    cfg_path = root / a.config
    stem = a.config[len("strata-"):-len(".json")] if a.config.startswith("strata-") else a.config[:-5]
    model = ""
    cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
    model = cfg.get("model_name", MODEL_NAME)

    stamp = datetime.date.today().strftime("%Y%m%d")
    profile_rel = f"data/expert-profile-{stem}-{stamp}.bin"
    trace = root / "probes" / f"trace-{stem}-{stamp}.bin"
    print(f"[1/6] stopping anything on :8080 ...")
    if a.dry_run:
        print("dry-run: would trace, rebuild", profile_rel, "and restart serve")
        return 0
    stop_8080()

    tcfg = json.loads(json.dumps(cfg))
    tcfg["args"] += ["--dump-routing", str(trace).replace("\\", "/")]
    tcfg["log"] = str(root / f"{stem}-trace-serve.log").replace("\\", "/")
    tname = f"{stem}-trace-serve.json"
    (root / tname).write_text(json.dumps(tcfg, ensure_ascii=False, indent=2), encoding="utf-8")

    print("[2/6] booting the trace engine (this loads the pack, ~1 min) ...")
    serve = subprocess.Popen([str(root / ".venv/Scripts/python.exe"), "serve/server.py",
                              "--engine", "strata", "--config", tname, "--port", "8080"],
                             cwd=str(root), env=serve_env())
    try:
        wait_loaded(model=model)
        prompts = list(PROMPTS)
        if a.prompts_file:
            for line in Path(a.prompts_file).read_text(encoding="utf-8").splitlines():
                if line.strip():
                    prompts.append((line.strip(), 400))
        for i, (p, n) in enumerate(prompts, 1):
            tn = post(p[:4000], n, model=model)
            print(f"[3/6] trace prompt {i}/{len(prompts)} -> {tn} tokens")
    finally:
        sh(["taskkill", "/PID", str(serve.pid), "/T", "/F"], capture_output=True)
        sh(["taskkill", "/IM", "strata.exe", "/F"], capture_output=True)
        time.sleep(3)

    print("[4/6] building the profile ...")
    r = sh([str(root / ".venv/Scripts/python.exe"), "tools/make_profile.py", str(trace),
            "--reorder", "--out", str(root / profile_rel)], cwd=str(root),
           capture_output=True)
    text = (r.stdout or b"") + (r.stderr or b"")
    tail = text.decode("mbcs", "replace").strip().splitlines()
    print("      " + (tail[-1] if tail else f"(exit {r.returncode})"))
    if r.returncode != 0:
        print("make_profile failed - config NOT changed:", text.decode("mbcs", "replace")[-400:])
        return 1

    print("[5/6] repointing", a.config, "at", profile_rel)
    args = cfg["args"]
    args[args.index("--expert-profile") + 1] = profile_rel
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")

    print("[6/6] restarting the serve on", a.config, "...")
    # via strata-gpu.ps1 restore: Start-Process truly detaches. A Popen child — even with
    # DETACHED_PROCESS — dies with the runner's process tree when this script's launcher
    # task ends (observed 2026-10-08: serve vanished minutes after a successful run).
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                    str(Path(__file__).with_name("strata-gpu.ps1")), "restore", "-Config", a.config])
    rt = post("こんにちは。一言だけ挨拶して。", 16, model=model)
    print("done. profile refreshed:", profile_rel, "| RT check:", rt, "tokens | gateway 8090 keeps its connection")
    return 0


if __name__ == "__main__":
    sys.exit(main())
