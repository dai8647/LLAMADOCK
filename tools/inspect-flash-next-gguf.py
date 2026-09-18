#!/usr/bin/env python3
"""Inspect Qwen3.8-Flash-Next GGUF shards: arch, PLE table size, tensor counts."""
import struct
import sys
from pathlib import Path


def read_string(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", errors="replace")


def parse_kv(f, n_kv):
    kvs = {}
    for _ in range(n_kv):
        key = read_string(f)
        (typ,) = struct.unpack("<I", f.read(4))
        # 0=uint8 1=int8 2=uint16 3=int16 4=uint32 5=int32 6=float32 7=bool
        # 8=string 9=array 10=uint64 11=int64 12=float64
        if typ == 4:
            (v,) = struct.unpack("<I", f.read(4))
        elif typ == 5:
            (v,) = struct.unpack("<i", f.read(4))
        elif typ == 6:
            (v,) = struct.unpack("<f", f.read(4))
        elif typ == 10:
            (v,) = struct.unpack("<Q", f.read(8))
        elif typ == 11:
            (v,) = struct.unpack("<q", f.read(8))
        elif typ == 8:
            v = read_string(f)
        elif typ == 7:
            v = bool(f.read(1)[0])
        elif typ == 9:
            (at,) = struct.unpack("<I", f.read(4))
            (n,) = struct.unpack("<Q", f.read(8))
            if at == 4:
                v = list(struct.unpack(f"<{n}I", f.read(4 * n)))
            elif at == 5:
                v = list(struct.unpack(f"<{n}i", f.read(4 * n)))
            elif at == 10:
                v = list(struct.unpack(f"<{n}Q", f.read(8 * n)))
            elif at == 11:
                v = list(struct.unpack(f"<{n}q", f.read(8 * n)))
            elif at == 8:
                v = [read_string(f) for _ in range(n)]
            else:
                v = f"[array type={at} n={n}]"
                break
        else:
            v = f"[unknown type={typ}]"
        kvs[key] = v
    return kvs


def inspect(path: Path):
    print(f"=== {path.name} ({path.stat().st_size / 1024**3:.2f} GiB) ===")
    with path.open("rb") as f:
        magic = f.read(4)
        if magic != b"GGUF":
            print("not GGUF")
            return
        ver, n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))
        print(f"version={ver} tensors={n_tensors} kv={n_kv}")
        kvs = parse_kv(f, n_kv)
        arch = kvs.get("general.architecture", "?")
        print(f"arch={arch}")
        for k in sorted(kvs):
            if k.startswith(arch) and any(
                s in k
                for s in (
                    "ple",
                    "expert",
                    "context",
                    "block",
                    "embedding",
                    "nextn",
                    "layer",
                )
            ):
                print(f"  {k} = {kvs[k]}")
        # tensor infos: name, n_dims, dims[], dtype, offset
        ple_bytes = 0
        total_bytes = 0
        ple_names = []
        for _ in range(n_tensors):
            name = read_string(f)
            (n_dims,) = struct.unpack("<I", f.read(4))
            dims = list(struct.unpack(f"<{n_dims}Q", f.read(8 * n_dims)))
            (dtype,) = struct.unpack("<I", f.read(4))
            (off,) = struct.unpack("<Q", f.read(8))
            # rough size: product of dims * element size by dtype id
            # 0=f32 1=f16 2=q4_0 ... 8=q8_0 ... IQ types higher
            el = {
                0: 4,
                1: 2,
                2: 18 / 32,
                3: 20 / 32,
                7: 34 / 32,
                8: 18 / 32,
                9: 20 / 32,
                10: 22 / 32,
                12: 17 / 32,
                13: 18 / 32,
                14: 19 / 32,
                15: 20 / 32,
                16: 21 / 32,
                29: 20 / 32,  # iq2_xxs rough
                30: 21 / 32,
            }.get(dtype, 2)
            ne = 1
            for d in dims:
                ne *= d
            nbytes = int(ne * el)
            total_bytes += nbytes
            if "ple" in name.lower() or "per_layer" in name.lower() or "ngram" in name.lower():
                ple_bytes += nbytes
                if len(ple_names) < 8:
                    ple_names.append((name, dims, dtype, nbytes))
        print(f"PLE/ngram tensor bytes (approx): {ple_bytes / 1024**3:.2f} GiB")
        print(f"all tensor bytes (approx): {total_bytes / 1024**3:.2f} GiB")
        for n, d, t, b in ple_names:
            print(f"  {n} dims={d} dtype={t} ~{b/1024**3:.2f} GiB")


if __name__ == "__main__":
    paths = sys.argv[1:]
    if not paths:
        base = Path(r"C:\Users\dai86\.lmstudio\models")
        paths = [
            str(base / "Qwen3.8-Flash-Next-Uncensored-IQ2_XXS-00001-of-00002.gguf"),
            str(base / "Qwen3.8-Flash-Next-Uncensored-IQ2_XXS-00002-of-00002.gguf"),
        ]
    for p in paths:
        inspect(Path(p))
