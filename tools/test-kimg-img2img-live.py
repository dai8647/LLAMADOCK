"""Live A/B/C test for the key-image img2img reference path.

Flow: t2i reference portrait -> img2img with a different scene -> compare faces
against t2i controls (no reference) and against an unrelated person.
Usage: python run-img2img-test.py [--quick]
"""
import json
import os
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:8189"
OUT = r"C:\Users\dai86\AppData\Local\Temp\h3img2img-live"
os.makedirs(OUT, exist_ok=True)


def post(path, body):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=120) as r:
        return json.load(r)


def wait_image(pid, timeout=900):
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = get("/api/status/" + pid)
        if st.get("status") == "success":
            imgs = [v for v in (st.get("videos") or []) if v.get("kind") == "image"]
            if imgs:
                return imgs[0]
            raise RuntimeError("success but no image: " + json.dumps(st)[:400])
        if st.get("status") == "error":
            raise RuntimeError("generation error: " + json.dumps(st)[:400])
        time.sleep(4)
    raise TimeoutError("timeout for " + pid)


RESULTS = []


def gen(name, text, **kw):
    t0 = time.time()
    j = post("/api/kimg", dict(text=text, engine="kimg", **kw))
    pid = j.get("prompt_id")
    if not pid:
        raise RuntimeError("no prompt_id: " + json.dumps(j)[:300])
    img = wait_image(pid)
    dt = time.time() - t0
    rec = {"name": name, "sec": round(dt, 1), "filename": img.get("filename"),
           "path": img.get("path"), "ref_used": j.get("ref_used"),
           "ref_denoise": j.get("ref_denoise"), "ref_size": j.get("ref_size"),
           "ref_note": j.get("ref_note"), "char_applied": j.get("char_applied")}
    RESULTS.append(rec)
    print("[%s] %.1fs %s ref_used=%s size=%s %s" % (
        name, dt, rec["filename"], rec["ref_used"], rec["ref_size"],
        (rec["char_applied"] or "")), flush=True)
    # local copy for the metric step (output/ may be pruned later)
    src = rec["path"]
    if src and os.path.isfile(src):
        dst = os.path.join(OUT, name + os.path.splitext(src)[1])
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            fo.write(fi.read())
        rec["local"] = dst
    return rec


REF_PERSON = ("amateur smartphone photo, 38 year old woman, short bright red bob haircut, "
              "heavy freckles across nose and cheeks, hazel eyes, small silver nose ring, "
              "neutral expression, head and shoulders portrait, looking at camera, "
              "plain gray wall background, natural window light, sharp focus")

OTHER_PERSON = ("amateur smartphone photo, 61 year old man, long white beard, deep forehead wrinkles, "
                "bald head, thick grey eyebrows, warm smile, head and shoulders portrait, "
                "looking at camera, plain beige wall background, natural window light, sharp focus")

SCENE = ("amateur smartphone photo, same woman as the reference image, now standing in a bright "
         "kitchen wearing a blue apron over a white shirt, laughing, one hand on a wooden spoon, "
         "waist up, tiled wall background, natural window light, sharp focus")

if __name__ == "__main__":
    quick = "--quick" in sys.argv
    # 1) reference person (t2i)
    ref = gen("ref_person", REF_PERSON)
    # 2) unrelated person (baseline "different")
    other = gen("other_person", OTHER_PERSON)
    # 3) img2img from the reference at two strengths
    b06 = gen("img2img_d060", SCENE, image=ref["path"], denoise=0.6)
    if not quick:
        b035 = gen("img2img_d035", SCENE, image=ref["path"], denoise=0.35)
        b100 = gen("img2img_d100", SCENE, image=ref["path"], denoise=1.0)
    # 4) control: identical prompt, no reference
    ctl = gen("t2i_control", SCENE)
    json.dump(RESULTS, open(os.path.join(OUT, "results.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\nresults ->", os.path.join(OUT, "results.json"))
