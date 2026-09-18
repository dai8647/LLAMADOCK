#!/usr/bin/env python3
import struct
import sys


def read_str(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", errors="replace")


def read_val(f, typ):
    if typ == 4:
        return struct.unpack("<I", f.read(4))[0]
    if typ == 5:
        return struct.unpack("<i", f.read(4))[0]
    if typ == 6:
        return struct.unpack("<f", f.read(4))[0]
    if typ == 10:
        return struct.unpack("<Q", f.read(8))[0]
    if typ == 11:
        return struct.unpack("<q", f.read(8))[0]
    if typ == 8:
        n = struct.unpack("<Q", f.read(8))[0]
        return f.read(n).decode("utf-8", errors="replace")
    if typ == 7:
        return bool(f.read(1)[0])
    if typ == 9:
        at = struct.unpack("<I", f.read(4))[0]
        n = struct.unpack("<Q", f.read(8))[0]
        if at == 4:
            return list(struct.unpack(f"<{n}I", f.read(4 * n)))
        if at == 5:
            return list(struct.unpack(f"<{n}i", f.read(4 * n)))
        if at == 10:
            return list(struct.unpack(f"<{n}Q", f.read(8 * n)))
        if at == 11:
            return list(struct.unpack(f"<{n}q", f.read(8 * n)))
        if at == 8:
            return [f.read(struct.unpack("<Q", f.read(8))[0]).decode() for _ in range(n)]
        return f"?array{at}"
    return f"?type{typ}"


path = sys.argv[1]
with open(path, "rb") as f:
    assert f.read(4) == b"GGUF"
    ver, nt, nkv = struct.unpack("<IQQ", f.read(20))
    print("tensors", nt, "kv", nkv)
    for _ in range(nkv):
        k = read_str(f)
        t = struct.unpack("<I", f.read(4))[0]
        v = read_val(f, t)
        print(f"{k} = {v}")
