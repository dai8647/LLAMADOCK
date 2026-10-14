"""Static tests for the key-image img2img (reference) wiring. No GPU, no ComfyUI."""
import importlib.util
import io
import json
import os
import shutil
import sys
from types import SimpleNamespace

REPO = r"C:\Users\dai86\Downloads\llama-tq3"
TMP = r"C:\Users\dai86\AppData\Local\Temp\h3img2img-test"
shutil.rmtree(TMP, ignore_errors=True)
os.makedirs(os.path.join(TMP, "input"), exist_ok=True)
os.environ["LLAMADOCK_COMFY_ROOT"] = TMP
sys.path.insert(0, os.path.join(REPO, "tools"))

spec = importlib.util.spec_from_file_location("h3chat", os.path.join(REPO, "tools", "h3-chat.py"))
h3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h3)

fails = []


def check(label, cond, extra=""):
    if cond:
        print("PASS " + label)
    else:
        print("FAIL " + label + (" :: " + str(extra) if extra else ""))
        fails.append(label)


def png(path, size):
    from PIL import Image
    Image.new("RGB", size, (120, 90, 60)).save(path)
    return path


src_land = png(os.path.join(TMP, "wide.png"), (3000, 2000))
src_port = png(os.path.join(TMP, "tall.png"), (1200, 2400))
src_tiny = png(os.path.join(TMP, "tiny.png"), (64, 48))

print("--- _fit_image_size")
check("landscape fits inside 1024 box", h3._fit_image_size(src_land, 1024, 1024) == (1024, 672),
      h3._fit_image_size(src_land, 1024, 1024))
check("portrait fits inside 1024 box", h3._fit_image_size(src_port, 1024, 1024) == (512, 1024),
      h3._fit_image_size(src_port, 1024, 1024))
check("tiny image is upscaled to the box", h3._fit_image_size(src_tiny, 1024, 1024) == (1024, 768),
      h3._fit_image_size(src_tiny, 1024, 1024))
check("unreadable path falls back to the box", h3._fit_image_size(os.path.join(TMP, "nope.png"), 768, 512) == (768, 512))
check("sides are multiples of 16",
      all(v % 16 == 0 for v in h3._fit_image_size(src_land, 1344, 768)))

print("--- _wire_img2img on the shipped Klein graph")
eng = h3.IMG_ENGINES["kimg"]
wf = json.load(open(eng["workflow"], encoding="utf-8"))["prompt"]
check("shipped graph has no reference nodes", "20" not in wf and "21" not in wf and "22" not in wf)
check("shipped graph is text-to-image",
      wf[eng["seed"]]["inputs"]["latent_image"] == [eng["latent"], 0]
      and wf[eng["seed"]]["inputs"]["denoise"] == 1)
shutil.copy2(src_land, os.path.join(TMP, "input", "staged.png"))
fitted = h3._wire_img2img(wf, eng, "staged.png", 1024, 1024, 0.6)
check("returns the fitted size", fitted == (1024, 672), fitted)
check("LoadImage injected with the staged file", wf["20"]["class_type"] == "LoadImage" and wf["20"]["inputs"]["image"] == "staged.png")
check("ImageScale injected", wf["21"]["class_type"] == "ImageScale" and wf["21"]["inputs"]["width"] == 1024 and wf["21"]["inputs"]["height"] == 672)
check("VAEEncode injected and uses the workflow VAE", wf["22"]["class_type"] == "VAEEncode" and wf["22"]["inputs"]["vae"] == ["3", 0])
check("KSampler latent rewired to VAEEncode", wf["9"]["inputs"]["latent_image"] == ["22", 0])
check("KSampler denoise set", wf["9"]["inputs"]["denoise"] == 0.6)
check("empty latent size follows the reference", wf["7"]["inputs"]["width"] == 1024 and wf["7"]["inputs"]["height"] == 672)
check("ModelSamplingFlux size follows the reference", wf["4"]["inputs"]["width"] == 1024 and wf["4"]["inputs"]["height"] == 672)
check("LoRA chain untouched", wf["9"]["inputs"]["model"] == ["4", 0] and wf["15"]["inputs"]["strength_model"] == 0.0)
check("denoise is clamped", h3._wire_img2img(json.load(open(eng["workflow"], encoding="utf-8"))["prompt"], eng, "staged.png", 1024, 1024, 5)[0] == 1024)
wf_q = json.load(open(h3.IMG_ENGINES["qimg"]["workflow"], encoding="utf-8"))["prompt"]
check("Qwen graph also wireable", h3._wire_img2img(wf_q, h3.IMG_ENGINES["qimg"], "staged.png", 1344, 768, 0.55) == (1152, 768))
check("Qwen KSampler rewired", wf_q["10"]["inputs"]["latent_image"] == ["22", 0] and wf_q["10"]["inputs"]["denoise"] == 0.55)
check("engine without ref nodes returns None", h3._wire_img2img({}, {}, "x.png", 512, 512, 0.5) is None)

print("--- /api/kimg request path")


class FakeAutostop:
    def poke(self):
        pass


def call_kimg(body):
    handler = object.__new__(h3.ChatHandler)
    raw = json.dumps(body).encode("utf-8")
    handler.headers = {"Content-Length": str(len(raw))}
    handler.rfile = io.BytesIO(raw)
    out = []
    handler._json = lambda code, obj: out.append((code, obj))
    handler.server = SimpleNamespace(local_files={}, job_meta={}, autostop=FakeAutostop())
    posted = {}

    def fake_comfy(method, path, payload=None, timeout=None):
        posted["payload"] = payload
        return None, json.dumps({"prompt_id": "p1"}), None

    handler._comfy = fake_comfy
    handler._ensure_comfy = lambda: True
    handler._free_comfy = lambda: None
    handler._kimg.__func__(handler, None)
    return out, posted


out, posted = call_kimg({"text": "1girl, nude", "engine": "kimg", "image": src_land})
code, resp = out[0]
check("reference request returns 200", code == 200, out)
check("ref_used reported", resp.get("ref_used") is True and resp.get("ref_size") == "1024x672", resp)
check("img2img reached ComfyUI", posted["payload"]["prompt"]["9"]["inputs"]["latent_image"] == ["22", 0])
check("denoise applied from the engine default", posted["payload"]["prompt"]["9"]["inputs"]["denoise"] == 0.6)
check("bodyweight randomization disabled for references",
      posted["payload"]["prompt"]["15"]["inputs"]["strength_model"] == 0.0)
check("applied list mentions img2img", any("img2img" in c for c in resp["char_applied"]), resp["char_applied"])

out, posted = call_kimg({"text": "1girl, nude", "engine": "kimg", "image": src_land, "denoise": 0.35, "bodyweight": 0.8})
check("explicit denoise wins", posted["payload"]["prompt"]["9"]["inputs"]["denoise"] == 0.35)
check("explicit bodyweight still honored", posted["payload"]["prompt"]["15"]["inputs"]["strength_model"] == 0.8)

out, posted = call_kimg({"text": "1girl, nude", "engine": "kimg"})
code, resp = out[0]
check("no reference stays text-to-image", posted["payload"]["prompt"]["9"]["inputs"]["latent_image"] == ["7", 0])
check("no reference keeps denoise 1", posted["payload"]["prompt"]["9"]["inputs"]["denoise"] == 1)
check("no reference randomizes bodyweight",
      -1.2 <= posted["payload"]["prompt"]["15"]["inputs"]["strength_model"] <= 1.2
      and posted["payload"]["prompt"]["15"]["inputs"]["strength_model"] != 0.0)
check("no reference: ref_used false", resp.get("ref_used") is False and resp.get("ref_note") == "")

out, posted = call_kimg({"text": "1girl", "engine": "qfix"})
check("legacy qfix alias does not 400", out[0][0] == 200 and posted["payload"]["prompt"]["10"]["class_type"] == "KSampler", out)

out, posted = call_kimg({"text": "1girl", "engine": "kimg", "image": os.path.join(TMP, "missing.png")})
check("missing reference falls back to t2i with a note",
      out[0][0] == 200 and posted["payload"]["prompt"]["9"]["inputs"]["latent_image"] == ["7", 0]
      and "参照画像" in out[0][1]["ref_note"], out[0][1])

out, posted = call_kimg({"text": "1girl", "engine": "kimg", "images": [src_port, src_land]})
check("images[] takes the first entry", out[0][1]["ref_size"] == "512x1024", out[0][1])

check("IMG_ENGINES has no qfix key", "qfix" not in h3.IMG_ENGINES)
check("both engines advertise img2img", all(h3.IMG_ENGINES[k].get("ref_encode") for k in ("kimg", "qimg")))

print("\n%d failed" % len(fails))
sys.exit(1 if fails else 0)
