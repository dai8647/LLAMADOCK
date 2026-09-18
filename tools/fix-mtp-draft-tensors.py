#!/usr/bin/env python3
"""Rewrite MTP draft GGUF: map output_hc_* -> blk.48.nextn.hc_head_* for Unsloth qwen4exp."""
import struct
import sys
from pathlib import Path

RENAME = {
    "output_hc_norm.weight": "blk.48.nextn.hc_head_norm.weight",
    "output_hc_down.weight": "blk.48.nextn.hc_head_down.weight",
    "output_hc_up.weight": "blk.48.nextn.hc_head_up.weight",
}


def read_len_str(f) -> bytes:
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n)


def write_len_str(buf: bytearray, s: bytes) -> None:
    buf += struct.pack("<Q", len(s))
    buf += s


def consume_typed(f, typ: int) -> bytes:
    start = f.tell()
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
        if at == 8:
            for _ in range(n):
                (ln,) = struct.unpack("<Q", f.read(8))
                f.read(ln)
        else:
            sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8}
            f.read(sizes[at] * n)
    else:
        raise ValueError(f"unsupported KV type {typ}")
    end = f.tell()
    f.seek(start)
    raw = f.read(end - start)
    return raw


def clone_with_renames(src: Path, dst: Path) -> None:
    with src.open("rb") as f:
        magic = f.read(4)
        if magic != b"GGUF":
            raise SystemExit("not GGUF")
        ver, n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))
        print(f"src ver={ver} tensors={n_tensors} kv={n_kv}")

        kv_blob = bytearray()
        align = 32
        for _ in range(n_kv):
            key = read_len_str(f)
            write_len_str(kv_blob, key)
            (typ,) = struct.unpack("<I", f.read(4))
            kv_blob += struct.pack("<I", typ)
            raw = consume_typed(f, typ)
            kv_blob += raw
            if key == b"general.alignment" and typ == 4:
                align = struct.unpack("<I", raw[:4])[0]

        tinfos = []
        for _ in range(n_tensors):
            name = read_len_str(f)
            (n_dims,) = struct.unpack("<I", f.read(4))
            dims = struct.unpack(f"<{n_dims}Q", f.read(8 * n_dims))
            (dtype,) = struct.unpack("<I", f.read(4))
            (off,) = struct.unpack("<Q", f.read(8))
            tinfos.append((name, n_dims, dims, dtype, off))

        pos = f.tell()
        pad = (align - (pos % align)) % align
        f.read(pad)
        data = f.read()
        print(f"align={align} tinfo_end={pos} pad={pad} data={len(data)}")

    tinfo_blob = bytearray()
    for name, n_dims, dims, dtype, off in tinfos:
        key = name.decode("utf-8")
        new = RENAME.get(key)
        nb = name if new is None else new.encode("utf-8")
        if new:
            print(f"  rename {key} -> {new}")
        write_len_str(tinfo_blob, nb)
        tinfo_blob += struct.pack("<I", n_dims)
        tinfo_blob += struct.pack(f"<{n_dims}Q", *dims)
        tinfo_blob += struct.pack("<I", dtype)
        tinfo_blob += struct.pack("<Q", off)

    with dst.open("wb") as out:
        out.write(b"GGUF")
        out.write(struct.pack("<IQQ", ver, n_tensors, n_kv))
        out.write(kv_blob)
        out.write(tinfo_blob)
        pad2 = (align - (out.tell() % align)) % align
        out.write(b"\x00" * pad2)
        out.write(data)
    print(f"wrote {dst} ({dst.stat().st_size / 1024**3:.2f} GiB)")


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        r"C:\Users\dai86\.lmstudio\models\Qwen3.8-Flash-Next-MTP-Q4_K_M.gguf"
    )
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_name(
        src.stem + "-unsloth-mtp.gguf"
    )
    clone_with_renames(src, dst)
