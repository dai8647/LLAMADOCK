#!/usr/bin/env python3
"""Make him0413 MTP shard loadable as a standalone draft (split.no=0, split.count=1)."""
import struct
import sys
from pathlib import Path


def read_str(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n), n


def clone_fix_split(src: Path, dst: Path):
    with src.open("rb") as f:
        magic = f.read(4)
        if magic != b"GGUF":
            raise SystemExit("not GGUF")
        ver, n_tensors, n_kv = struct.unpack("<IQQ", f.read(20))
        print(f"ver={ver} tensors={n_tensors} kv={n_kv}")

        kv_blob = bytearray()
        patched = 0
        for _ in range(n_kv):
            key_raw, key_len = read_str(f)
            key = key_raw.decode("utf-8", "replace")
            (typ,) = struct.unpack("<I", f.read(4))
            # consume value
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
                    f.read(sizes.get(at, 0) * n)
            else:
                raise ValueError(typ)
            end = f.tell()
            f.seek(start)
            raw = f.read(end - start)

            # Patch split metadata
            if key == "split.no" and typ == 2:  # uint16
                raw = struct.pack("<H", 0)
                patched += 1
                print("  patch split.no -> 0")
            elif key == "split.count" and typ == 2:
                raw = struct.pack("<H", 1)
                patched += 1
                print("  patch split.count -> 1")

            kv_blob += struct.pack("<Q", key_len) + key_raw
            kv_blob += struct.pack("<I", typ)
            kv_blob += raw

        # tensor infos (copy as-is)
        tinfo = bytearray()
        for _ in range(n_tensors):
            (nlen,) = struct.unpack("<Q", f.read(8))
            tinfo += struct.pack("<Q", nlen)
            tinfo += f.read(nlen)
            (nd,) = struct.unpack("<I", f.read(4))
            tinfo += struct.pack("<I", nd)
            tinfo += f.read(8 * nd)
            tinfo += f.read(4)
            tinfo += f.read(8)

        align = 32
        pos = f.tell()
        pad = (align - (pos % align)) % align
        f.read(pad)
        data = f.read()

    with dst.open("wb") as out:
        out.write(b"GGUF")
        out.write(struct.pack("<IQQ", ver, n_tensors, n_kv))
        out.write(kv_blob)
        out.write(tinfo)
        pad2 = (align - (out.tell() % align)) % align
        out.write(b"\x00" * pad2)
        out.write(data)
    print(f"wrote {dst} ({dst.stat().st_size/1024**3:.2f} GiB) patched={patched}")


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
        r"D:\llm-work\reuse\him0413-MTP-00004.gguf"
    )
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(
        r"D:\llm-work\reuse\him0413-MTP-standalone.gguf"
    )
    clone_fix_split(src, dst)
