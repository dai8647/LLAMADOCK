#!/usr/bin/env python3
"""Build anchored regex tensor-type file so llama-quantize --tensor-type-file matches exactly."""
import re
from pathlib import Path

src = Path(r"D:\llm-work\reuse\ista-daslab\Q2_0.rco-allocation.txt")
dst = Path(r"D:\llm-work\scripts\rco-q2_0-anchored.txt")

lines = []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or ":" not in line:
        continue
    name, typ = line.split(":", 1)
    name = name.strip()
    typ = typ.strip()
    # Escape regex metacharacters and anchor full match
    esc = re.escape(name)
    lines.append(f"^{esc}$={typ}")

# Force PLE after (so it wins if any prefix collision)
esc = re.escape("per_layer_token_embd.weight")
lines.append(f"^{esc}$=IQ4_NL")

dst.write_text("\n".join(lines) + "\n", encoding="ascii")
print(f"wrote {len(lines)} lines -> {dst}")
print("sample:")
for l in lines[:8]:
    print(" ", l)
print(" ...")
for l in lines[-3:]:
    print(" ", l)
