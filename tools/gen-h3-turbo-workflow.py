"""Generate the LlamaDock MiniMax-H3 turbo workflow.

Base: ComfyUI-ClipProj/example_workflows/minimax_h3_clipproj.json
Changes:
  - Point model widgets at the files that actually exist on this machine
    (10Eros-Max nvfp4 UNet, heretic 4B encoder, MiniMax-H3 VAEs).
  - Insert LoraLoaderModelOnly (4-step turbo LoRA) between UNETLoader and
    MiniMaxH3SigmaShift; steps 12 -> 4, sampler res_multistep -> euler.
  - Replace the in-ComfyUI ClipProjGenerate planning block with the
    LlamaDock planning nodes (LoadImage -> LlamaDockH3PromptGen) and feed
    the generated prompt into MiniMaxH3ImageToVideo.
  - ClipProjLoader stays: it supplies the projected CLIP that the H3
    conditioning nodes require (that is the VRAM-saving part).
"""
import json, os

BASE = r"C:\Users\dai86\Documents\ComfyUI\custom_nodes\ComfyUI-ClipProj\example_workflows\minimax_h3_clipproj.json"
OUT = r"C:\Users\dai86\Documents\ComfyUI\user\default\workflows\llamadock_h3_turbo.json"

TURBO_LORA = "minimax_h3_turbo_4step_ckpt600_ema_V4.safetensors"
# ComfyUI's folder_paths lists subdirectories with backslash separators on
# Windows; the widget value must match that listing exactly or UNETLoader
# validation rejects it.
UNET_FILE = "10Eros-Max\\10Eros_Max_h3_fl2va_beta2_pruned_nvfp4.safetensors"
ENCODER_FILE = "qwen3vl_4b_heretic_fp8.safetensors"
PROJECTION_FILE = "mmh3-4b-ClipProj-celeb-mlp.safetensors"
VIDEO_VAE = "MiniMax-H3-video_vae_fp16.safetensors"
AUDIO_VAE = "minimax_h3_audio_vae_fp32.safetensors"

with open(BASE, encoding="utf-8") as f:
    wf = json.load(f)

nodes = wf["nodes"]
links = wf["links"]
by_id = {n["id"]: n for n in nodes}

# --- Remove the in-ComfyUI planning block (ClipProjGenerate + PreviewAny) ---
remove_ids = {20, 21}
# also drop the decorative markdown notes to keep the graph focused
remove_ids |= {n["id"] for n in nodes if n.get("type") == "MarkdownNote"}
nodes = [n for n in nodes if n["id"] not in remove_ids]
links = [l for l in links if l[1] not in remove_ids and l[3] not in remove_ids]
by_id = {n["id"]: n for n in nodes}

next_link = max(l[0] for l in links) + 1
next_node = max(n["id"] for n in nodes) + 1

def add_link(src_node, src_slot, dst_node, dst_slot, typ):
    global next_link
    lid = next_link; next_link += 1
    links.append([lid, src_node, src_slot, dst_node, dst_slot, typ])
    src = by_id[src_node]
    outs = src.setdefault("outputs", [])
    while len(outs) <= src_slot:
        outs.append({"name": "", "type": typ, "links": []})
    if outs[src_slot].get("links") is None:
        outs[src_slot]["links"] = []
    outs[src_slot]["links"].append(lid)
    outs[src_slot]["type"] = typ
    dst = by_id[dst_node]
    ins = dst.setdefault("inputs", [])
    while len(ins) <= dst_slot:
        ins.append({"name": "", "type": typ, "link": None})
    ins[dst_slot]["link"] = lid
    ins[dst_slot]["type"] = typ
    return lid

# --- Fix model widgets to files that exist locally ---
# ClipProjLoader(1): the current node has 5 widgets in this order:
#   clip_name, type, projection, device, mode
# The base workflow predates the `type` widget, so rebuild the node's
# widget/input layout to match the current definition and avoid a
# positional restore mismatch.
clipproj = by_id[1]
clipproj["widgets_values"] = [ENCODER_FILE, "auto", PROJECTION_FILE, "cuda:0", "resident"]
clipproj["inputs"] = [
    {"name": "clip_name", "type": "COMBO", "link": None, "widget": {"name": "clip_name"}},
    {"name": "type", "type": "COMBO", "link": None, "widget": {"name": "type"}},
    {"name": "projection", "type": "COMBO", "link": None, "widget": {"name": "projection"}},
    {"name": "device", "type": "COMBO", "link": None, "widget": {"name": "device"}},
    {"name": "mode", "type": "COMBO", "link": None, "widget": {"name": "mode"}},
]
# UNETLoader(2): unet_name, weight_dtype
by_id[2]["widgets_values"] = [UNET_FILE, "default"]
# VAELoader(4) video, VAELoader(5) audio
by_id[4]["widgets_values"] = [VIDEO_VAE]
by_id[5]["widgets_values"] = [AUDIO_VAE]

# --- Insert LoraLoaderModelOnly between UNETLoader(2) and SigmaShift(3) ---
lora_id = next_node; next_node += 1
lora_node = {
    "id": lora_id,
    "type": "LoraLoaderModelOnly",
    "pos": [40, 350],
    "size": [320, 82],
    "flags": {},
    "order": 2,
    "mode": 0,
    "inputs": [{"name": "model", "type": "MODEL", "link": None}],
    "outputs": [{"name": "MODEL", "type": "MODEL", "links": []}],
    "properties": {"Node name for S&R": "LoraLoaderModelOnly"},
    "widgets_values": [TURBO_LORA, 1.0],
}
nodes.append(lora_node); by_id[lora_id] = lora_node

# Rewire: UNETLoader(2).out0 currently -> SigmaShift(3).in0 (MODEL link).
for l in links:
    if l[1] == 2 and l[3] == 3 and l[5] == "MODEL":
        l[3] = lora_id          # now UNETLoader -> LoraLoader
        lora_node["inputs"][0]["link"] = l[0]
        break
# LoraLoader.out0 -> SigmaShift(3).in0
add_link(lora_id, 0, 3, 0, "MODEL")

# --- Speed: 4 steps, euler sampler ---
by_id[8]["widgets_values"] = ["euler"]                 # KSamplerSelect
by_id[9]["widgets_values"] = ["simple", 4, 1.0]        # BasicScheduler

# --- Planning block: LoadImage -> LlamaDockH3PromptGen -> H3 prompt ---
loadimg_id = next_node; next_node += 1
loadimg = {
    "id": loadimg_id,
    "type": "LoadImage",
    "pos": [440, 500],
    "size": [320, 314],
    "flags": {},
    "order": 0,
    "mode": 0,
    "outputs": [
        {"name": "IMAGE", "type": "IMAGE", "links": []},
        {"name": "MASK", "type": "MASK", "links": []},
    ],
    "properties": {"Node name for S&R": "LoadImage"},
    "widgets_values": ["example.png", "image"],
}
nodes.append(loadimg); by_id[loadimg_id] = loadimg

promptgen_id = next_node; next_node += 1
promptgen = {
    "id": promptgen_id,
    "type": "LlamaDockH3PromptGen",
    "pos": [820, 500],
    "size": [400, 320],
    "flags": {},
    "order": 3,
    "mode": 0,
    "inputs": [
        {"name": "image", "type": "IMAGE", "link": None},
    ],
    "outputs": [{"name": "h3_prompt", "type": "STRING", "links": []}],
    "properties": {"Node name for S&R": "LlamaDockH3PromptGen"},
    "widgets_values": [
        "この画像の被写体と雰囲気を活かした10秒の動画ショットを企画して。",
        "http://127.0.0.1:8090",
        "",  # empty -> node falls back to the built-in H3 system prompt
        0.7,
        1024,
        180,
    ],
}
nodes.append(promptgen); by_id[promptgen_id] = promptgen

# LoadImage.IMAGE -> LlamaDockH3PromptGen.image
add_link(loadimg_id, 0, promptgen_id, 0, "IMAGE")

# Feed generated prompt into MiniMaxH3ImageToVideo(6).prompt (input slot 2).
h3node = by_id[6]
wv = h3node.get("widgets_values", [])
if wv and isinstance(wv[0], str) and len(wv[0]) > 80:
    # keep the array length stable (positional widget restore): placeholder only
    wv[0] = "(prompt is supplied by the LlamaDockH3PromptGen link)"
add_link(promptgen_id, 0, 6, 2, "STRING")

# --- Bookkeeping ---
wf["nodes"] = nodes
wf["links"] = links
wf["last_node_id"] = next_node - 1
wf["last_link_id"] = next_link - 1
wf.setdefault("extra", {})
wf["extra"]["llamadock"] = {
    "turbo_lora": TURBO_LORA,
    "steps": 4,
    "planning_server": "http://127.0.0.1:8090",
    "note": "ClipProjLoader is required: it projects the 4B encoder into the H3 32B space (VRAM saving). Do not remove.",
}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(wf, f, ensure_ascii=False, indent=2)

print("WROTE", OUT)
print("nodes:", len(nodes), "links:", len(links))
print("lora node id:", lora_id, "loadimg:", loadimg_id, "promptgen:", promptgen_id)
