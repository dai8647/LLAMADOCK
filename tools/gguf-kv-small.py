#!/usr/bin/env python3
"""Print only small/non-huge GGUF KVs."""
import struct
import sys

def read_str(f):
    (n,) = struct.unpack("<Q", f.read(8))
    if n > 10_000_000:
        # skip huge
        f.seek(n, 1)
        return "<huge>"
    return f.read(n).decode("utf-8", "replace")

def skip_typed(f, typ):
    if typ in (0, 1, 7):
        f.read(1)
    elif typ in (2, 3):
        f.read(2)
    elif typ in (4, 5, 6):
        f.read(4)
    elif typ in (10, 11, 12):
        f.read(8)
    elif typ == 8:
        (n,) = struct.unpack("<Q", f.read(8))
        if n > 10_000_000:
            f.seek(n, 1)
            return
        f.read(n)
    elif typ == 9:
        (at,) = struct.unpack("<I", f.read(4))
        (n,) = struct.unpack("<Q", f.read(8))
        if at == 8:
            for _ in range(n):
                (ln,) = struct.unpack("<Q", f.read(8))
                if ln > 10_000_000:
                    f.seek(ln, 1)
                else:
                    f.read(ln)
        else:
            sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8}
            f.read(sizes.get(at, 0) * n)

def read_small_val(f, typ):
    if typ == 4:
        return struct.unpack("<I", f.read(4))[0]
    if typ == 5:
        return struct.unpack("<i", f.read(4))[0]
    if typ == 10:
        return struct.unpack("<Q", f.read(8))[0]
    if typ == 11:
        return struct.unpack("<q", f.read(8))[0]
    if typ == 6:
        return struct.unpack("<f", f.read(4))[0]
    if typ == 7:
        return bool(f.read(1)[0])
    if typ == 8:
        (n,) = struct.unpack("<Q", f.read(8))
        return f.read(n).decode("utf-8", "replace") if n < 200 else f"<str {n}B>"
    if typ == 9:
        (at,) = struct.unpack("<I", f.read(4))
        (n,) = struct.unpack("<Q", f.read(8))
        if at == 4 and n <= 64:
            return list(struct.unpack(f"<{n}I", f.read(4 * n)))
        if at == 5 and n <= 64:
            return list(struct.unpack(f"<{n}i", f.read(4 * n)))
        if at == 10 and n <= 64:
            return list(struct.unpack(f"<{n}Q", f.read(8 * n)))
        if at == 8 and n <= 16:
            return [f.read(struct.unpack("<Q", f.read(8))[0]).decode("utf-8", "replace")[:80] for _ in range(n)]
        skip_typed(f, typ)
        return f"<arr n={n} at={at}>"
    skip_typed(f, typ)
    return f"<type {typ}>"

p = sys.argv[1]
with open(p, "rb") as f:
    magic = f.read(4)
    ver, nt, nkv = struct.unpack("<IQQ", f.read(20))
    print(f"file={p}")
    print(f"ver={ver} tensors={nt} kv={nkv}")
    for _ in range(nkv):
        k = read_str(f)
        if k == "<huge>":
            continue
        (t,) = struct.unpack("<I", f.read(4))
        v = read_small_val(f, t)
        ks = k.lower()
        if any(s in ks for s in ("nextn", "block", "ple", "expert", "arch", "type", "size_label", "name", "layer")):
            print(f"  {k} = {v}")
