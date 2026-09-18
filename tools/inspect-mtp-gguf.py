#!/usr/bin/env python3
"""List tensor names in an MTP draft GGUF."""
import struct
import sys
from pathlib import Path


def read_string(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", errors="replace")


def skip_kv(f, n_kv):
    for _ in range(n_kv):
        _ = read_string(f)
        (typ,) = struct.unpack("<I", f.read(4))
        skip_value(f, typ)


def skip_value(f, typ):
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
        f.read(n)
    elif typ == 9:
        (at,) = struct.unpack("<I", f.read(4))
        (n,) = struct.unpack("<Q", f.read(8))
        sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8}
        if at == 8:
            for _ in range(n):
                _ = read_string(f)
        else:
            f.read(sizes.get(at, 0) * n)
    else:
        raise ValueError(f"unknown type {typ}")


def main(path):
    p = Path(path)
    print(f"file={p.name} size={p.stat().st_size/1024**3:.2f} GiB")
    with p.open("rb") as f:
        magic = f.read(4)
        print("magic", magic)
        ver, n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))
        print(f"ver={ver} tensors={n_tensors} kv={n_kv}")
        skip_kv(f, n_kv)
        names = []
        for _ in range(n_tensors):
            name = read_string(f)
            (n_dims,) = struct.unpack("<I", f.read(4))
            dims = list(struct.unpack(f"<{n_dims}Q", f.read(8 * n_dims)))
            (dtype,) = struct.unpack("<I", f.read(4))
            f.read(8)  # offset
            names.append((name, dims, dtype))
        print(f"{'tensor':60} dims dtype")
        for n, d, t in names:
            print(f"{n:60} {d} {t}")
        # keywords
        print("--- nextn / mtp ---")
        for n, d, t in names:
            if "nextn" in n or "mtp" in n.lower() or "blk.48" in n or "blk.0" in n:
                print(n, d, t)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\dai86\.lmstudio\models\Qwen3.8-Flash-Next-MTP-Q4_K_M.gguf")
