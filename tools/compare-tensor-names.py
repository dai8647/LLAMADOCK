#!/usr/bin/env python3
import struct
import sys


def iter_names(path):
    with open(path, "rb") as f:
        assert f.read(4) == b"GGUF"
        ver, nt, nkv = struct.unpack("<IQQ", f.read(20))

        def rs():
            n = struct.unpack("<Q", f.read(8))[0]
            return f.read(n)

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
                n = struct.unpack("<Q", f.read(8))[0]
                f.read(n)
            elif t == 9:
                at = struct.unpack("<I", f.read(4))[0]
                n = struct.unpack("<Q", f.read(8))[0]
                if at == 8:
                    for _ in range(n):
                        ln = struct.unpack("<Q", f.read(8))[0]
                        f.read(ln)
                else:
                    sizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8}
                    f.read(sizes.get(at, 0) * n)

        for _ in range(nkv):
            rs()
            t = struct.unpack("<I", f.read(4))[0]
            skip_val(t)
        names = []
        for _ in range(nt):
            n = struct.unpack("<Q", f.read(8))[0]
            name = f.read(n).decode()
            nd = struct.unpack("<I", f.read(4))[0]
            f.read(8 * nd)
            f.read(4)
            f.read(8)
            names.append(name)
        return names


def main():
    bg = set()
    for shard in [
        r"D:\llm-work\bf16\Qwen3.8-Flash-Next-UNCENSORED-BF16-00001-of-00008.gguf",
        r"D:\llm-work\bf16\Qwen3.8-Flash-Next-UNCENSORED-BF16-00008-of-00008.gguf",
    ]:
        try:
            ns = iter_names(shard)
            print(shard, "tensors", len(ns))
            bg |= set(ns)
        except Exception as e:
            print("err", shard, e)

    alloc = set()
    with open(r"D:\llm-work\reuse\ista-daslab\IQ2_XS.rco-allocation.txt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and ":" in line:
                alloc.add(line.split(":", 1)[0].strip())

    print("BG", len(bg), "alloc", len(alloc), "both", len(bg & alloc))
    print("only BG", len(bg - alloc))
    print("only alloc", len(alloc - bg))
    print("--- BG only ---")
    for n in sorted(bg - alloc)[:40]:
        print(" ", n)
    print("--- alloc only ---")
    for n in sorted(alloc - bg)[:20]:
        print(" ", n)


if __name__ == "__main__":
    main()
