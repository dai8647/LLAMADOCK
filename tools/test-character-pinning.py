"""Unit tests for h3-chat.py character-pinning helpers (run from repo root).

Covers: char card loading/validation, the cognitive-layer identity prefix,
negative-node discovery + mechanical append, LoRA chain insertion, and the
sdcpp env contract. The planner system prompt must stay byte-identical.
"""
import importlib.util
import json
import os
import shutil
import tempfile

spec = importlib.util.spec_from_file_location("h3chat", "tools/h3-chat.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


# --- loader / id validation -------------------------------------------------
tmp = tempfile.mkdtemp()
old_dir = m.CHARACTERS_DIR
m.CHARACTERS_DIR = tmp

good = {"id": "akari", "name": "あかり", "summary": "japanese woman, mid-20s",
        "negative": "blonde hair", "lora": {"kimg": [{"name": "a.safetensors", "strength": 0.85}]},
        "seed": 42, "refImages": [], "notes": ""}
with open(os.path.join(tmp, "akari.json"), "w", encoding="utf-8") as f:
    json.dump(good, f, ensure_ascii=False)
with open(os.path.join(tmp, "broken.json"), "w", encoding="utf-8") as f:
    f.write("{not json")
with open(os.path.join(tmp, "traversal.json"), "w", encoding="utf-8") as f:
    json.dump({"id": "..\\evil", "name": "x", "summary": "s"}, f)
with open(os.path.join(tmp, "nosummary.json"), "w", encoding="utf-8") as f:
    json.dump({"id": "nope", "name": "x"}, f)

cards = m._load_characters()
check("loader: valid card loaded", any(c["id"] == "akari" for c in cards), repr([c.get("id") for c in cards]))
check("loader: broken json skipped", all(c["id"] != "broken" for c in cards))
check("loader: traversal id rejected", all(c["id"] != "..\\evil" for c in cards))
check("loader: missing summary rejected", all(c["id"] != "nope" for c in cards))
check("get_character: found", m.get_character("akari") is not None)
check("get_character: traversal id returns None", m.get_character("..\\evil") is None)
check("get_character: unknown id returns None", m.get_character("ghost") is None)

# --- cognitive layer: identity prefix ---------------------------------------
card = m.get_character("akari")
prefix = m.char_identity_prefix(card)
check("prefix: contains summary", "japanese woman, mid-20s" in prefix)
check("prefix: contains name", "あかり" in prefix)
check("prefix: single line + blank sep", "\n\n" in prefix and "[キャラ固定: あかり]" in prefix)
check("prefix: no card -> empty", m.char_identity_prefix(None) == "")

# --- guarantee layer: negative node discovery + append -----------------------
def wf_klein_like():
    return {
        "1": {"class_type": "UnetLoaderGGUF", "inputs": {"unet_name": "x.gguf"}},
        "5": {"class_type": "CLIPTextEncode", "inputs": {"text": "positive tags", "clip": ["2", 0]}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": "lowres, blurry", "clip": ["2", 0]}},
        "7": {"class_type": "EmptySD3LatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}},
        "9": {"class_type": "KSampler", "inputs": {
            "model": ["1", 0], "positive": ["5", 0], "negative": ["6", 0], "latent_image": ["7", 0],
            "seed": 42, "steps": 4, "cfg": 1.0}},
    }

wf = wf_klein_like()
check("negative node found by link", m._negative_node_id(wf) == "6")
check("negative append ok", m._append_negative(wf, "blonde hair, tall"))
check("negative append merged", "blonde hair, tall" in wf["6"]["inputs"]["text"] and "lowres" in wf["6"]["inputs"]["text"])
check("negative append idempotent", not m._append_negative(wf, "blonde hair, tall") or "blonde hair, tall, blonde hair" not in wf["6"]["inputs"]["text"])
wf2 = {"1": {"class_type": "KSampler", "inputs": {"negative": ["99", 0]}}}
check("negative append: dangling link -> False", m._append_negative(wf2, "x") is False)
check("negative append: empty extra -> False", m._append_negative(wf_klein_like(), "") is False)

# --- LoRA chain insertion ----------------------------------------------------
# The chain is built last-entry-first: the sampler points at the LAST applied
# LoRA, which chains back through earlier entries and finally into the UNet.
wf = wf_klein_like()
applied = m._apply_char_loras(wf, [{"name": "char_face.safetensors", "strength": 0.9}, "plain.safetensors"])
check("lora: applied 2", len(applied) == 2, repr(applied))
sampler = wf["9"]
cur = sampler["inputs"]["model"]
check("lora: sampler rewired to chain tail", isinstance(cur, list) and cur[0] in wf and wf[cur[0]]["class_type"] == "LoraLoaderModelOnly")
last = wf[cur[0]]["inputs"]
check("lora: string entry defaults strength 1.0", last["lora_name"] == "plain.safetensors" and last["strength_model"] == 1.0, repr(last))
first = wf[last["model"][0]]["inputs"]
check("lora: strength normalized", first["lora_name"] == "char_face.safetensors" and first["strength_model"] == 0.9, repr(first))
check("lora: chain ends at unet", first["model"][0] == "1")
check("lora: traversal name rejected", m._apply_char_loras(wf_klein_like(), [{"name": "..\\evil.safetensors"}]) == [])
check("lora: empty list no-op", m._apply_char_loras(wf_klein_like(), []) == [])

# --- PLAN_SYSTEM byte-identical ----------------------------------------------
check("PLAN_SYSTEM untouched (has smartphone trigger)",
      "This is a candid photograph taken with a smartphone of" in m.PLAN_SYSTEM)
check("PLAN_SYSTEM untouched (no char text leaked)",
      "キャラ固定" not in m.PLAN_SYSTEM)

# --- sdcpp env contract (ps1 reads SDCPP_NEG / SDCPP_SEED) --------------------
ps1_path = os.path.join(os.path.dirname(m.__file__), "sd.cpp", "test_run_4b.ps1")
with open(ps1_path, encoding="utf-8") as f:
    ps1 = f.read()
check("ps1: SDCPP_NEG wired", "SDCPP_NEG" in ps1 and "--negative-prompt" in ps1)
check("ps1: SDCPP_SEED overrides -s 42", "$seedArg = if ($env:SDCPP_SEED)" in ps1)

shutil.rmtree(tmp)
m.CHARACTERS_DIR = old_dir

print(f"\n{passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
