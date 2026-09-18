#!/usr/bin/env python3
"""Sample weight statistics from GGUF tensors to detect garbage source."""
import struct
import math
import sys


def read_tensor_stats(path, want_names, max_rows=64):
    with open(path, "rb") as f:
        assert f.read(4) == b"GGUF"
        ver, nt, n_kv = struct.unpack("<IQQ", f.read(20))

        def skip_val(t):
            if t in (0, 1, 7):
                f.read(1)
            elif t in (2, 3):
                f.read(2)
            elif t in (4, 5, 6):
                f.read(4)
            elif t in (10, 11, 12):
                f.read(8)
            elif t == 8:
                (n,) = struct.unpack("<Q", f.read(8))
                f.read(n)
            elif t == 9:
                at = struct.unpack("<I", f.read(4))[0]
                n = struct.unpack("<Q", f.read(8))[0]
                if at == 8:
                    for _ in range(n):
                        ln = struct.unpack("<Q", f.read(8))
                        f.read(ln[0])
                else:
                    sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8}
                    f.read(sizes.get(at, 0) * n)

        for _ in range(n_kv):
            n = struct.unpack("<Q", f.read(8))[0]
            f.read(n)
            t = struct.unpack("<I", f.read(4))[0]
            skip_val(t)

        tensors = []
        data_start = None
        infos = []
        for _ in range(nt):
            nlen = struct.unpack("<Q", f.read(8))[0]
            name = f.read(nlen).decode()
            nd = struct.unpack("<I", f.read(4))[0]
            dims = list(struct.unpack(f"<{nd}Q", f.read(8 * nd)))
            dtype = struct.unpack("<I", f.read(4))[0]
            off = struct.unpack("<Q", f.read(8))[0]
            infos.append((name, dims, dtype, off))

        pos = f.tell()
        pad = (32 - (pos % 32)) % 32
        f.read(pad)
        data_start = f.tell()

        for name, dims, dtype, off in infos:
            if name not in want_names:
                continue
            f.seek(data_start + off)
            # dtype 1 = F16, 0 = F32, 32 = BF16?
            # GGML: 0 F32, 1 F16, 32 BF16 (need check). Read first N floats.
            n_el = 1
            for d in dims:
                n_el *= d
            take = min(n_el, max_rows * dims[0] if dims else max_rows)
            if dtype == 0:  # F32
                raw = f.read(4 * take)
                vals = list(struct.unpack(f"<{take}f", raw))
            elif dtype == 1:  # F16
                raw = f.read(2 * take)
                # decode f16
                vals = []
                for i in range(take):
                    h = struct.unpack_from("<H", raw, i * 2)[0]
                    # simple f16 to f32
                    sign = (h >> 15) & 1
                    exp = (h >> 10) & 0x1F
                    mant = h & 0x3FF
                    if exp == 0:
                        v = (mant / 1024.0) * (2 ** -14)
                    elif exp == 31:
                        v = float("nan")
                    else:
                        v = (1 + mant / 1024.0) * (2 ** (exp - 15))
                    vals.append(-v if sign else v)
            elif dtype == 32:  # BF16
                raw = f.read(2 * take)
                vals = []
                for i in range(take):
                    h = struct.unpack_from("<H", raw, i * 2)[0]
                    # bf16 -> f32: shift left 16
                    bits = h << 16
                    v = struct.unpack("<f", struct.pack("<I", bits))[0]
                    vals.append(v)
            else:
                print(f"  {name}: dtype={dtype} dims={dims} (skip sample)")
                continue
            finite = [v for v in vals if math.isfinite(v)]
            if not finite:
                print(f"  {name}: dims={dims} dtype={dtype} ALL non-finite")
                continue
            mean = sum(finite) / len(finite)
            var = sum((x - mean) ** 2 for x in finite) / len(finite)
            nz = sum(1 for x in finite if abs(x) > 1e-8)
            print(
                f"  {name}: dims={dims} dtype={dtype} n={len(finite)} "
                f"mean={mean:.4g} std={math.sqrt(var):.4g} "
                f"min={min(finite):.4g} max={max(finite):.4g} "
                f"nonzero={nz}/{len(finite)}"
            )


if __name__ == "__main__":
    want = {
        "token_embd.weight",
        "blk.0.attn_qkv.weight",
        "blk.0.ffn_gate_exps.weight",
        "blk.0.hc_attn_norm.weight",
        "per_layer_token_embd.weight",
        "output.weight",
    }
    for p in sys.argv[1:]:
        print("====", p)
        try:
            read_tensor_stats(p, want)
        except Exception as e:
            print("ERR", e)
