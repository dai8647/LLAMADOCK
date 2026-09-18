#!/usr/bin/env python3
"""Inject tokenizer/chat_template KVs from a donor GGUF into MTP draft."""
import struct
import sys
from pathlib import Path


def parse_kv_section(f, n_kv):
    entries = []
    for _ in range(n_kv):
        nlen = struct.unpack("<Q", f.read(8))[0]
        key = f.read(nlen)
        typ = struct.unpack("<I", f.read(4))[0]
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
        entries.append((key, typ, raw))
    return entries


def main(donor_path, mtp_path, out_path):
    donor_keys = (
        b"tokenizer.ggml.model",
        b"tokenizer.ggml.pre",
        b"tokenizer.ggml.tokens",
        b"tokenizer.ggml.token_type",
        b"tokenizer.ggml.merges",
        b"tokenizer.ggml.eos_token_id",
        b"tokenizer.ggml.padding_token_id",
        b"tokenizer.ggml.bos_token_id",
        b"tokenizer.ggml.add_bos_token",
        b"tokenizer.chat_template",
    )
    with open(donor_path, "rb") as f:
        assert f.read(4) == b"GGUF"
        ver, nt, n_kv = struct.unpack("<IQQ", f.read(20))
        donor_entries = parse_kv_section(f, n_kv)
        donor_sel = [e for e in donor_entries if e[0] in donor_keys]
        print(f"donor selected {len(donor_sel)} / {len(donor_entries)} KVs")
        assert len(donor_sel) == len(donor_keys), f"missing some: {[e[0] for e in donor_sel]}"

    with open(mtp_path, "rb") as f:
        magic = f.read(4)
        assert magic == b"GGUF"
        ver2, nt2, n_kv2 = struct.unpack("<IQQ", f.read(20))
        mtp_entries = parse_kv_section(f, n_kv2)
        have = {e[0] for e in mtp_entries}
        add = [e for e in donor_sel if e[0] not in have]
        print(f"mtp kv={n_kv2} adding {len(add)}")
        # tensor infos
        tinfo = bytearray()
        for _ in range(nt2):
            (nlen,) = struct.unpack("<Q", f.read(8))
            tinfo += struct.pack("<Q", nlen)
            tinfo += f.read(nlen)
            (nd,) = struct.unpack("<I", f.read(4))
            tinfo += struct.pack("<I", nd)
            tinfo += f.read(8 * nd)
            tinfo += f.read(4)
            tinfo += f.read(8)
        pos = f.tell()
        pad = (32 - (pos % 32)) % 32
        f.read(pad)
        data = f.read()

    n_kv_new = n_kv2 + len(add)
    with open(out_path, "wb") as out:
        out.write(b"GGUF")
        out.write(struct.pack("<IQQ", ver2, nt2, n_kv_new))
        for key, typ, raw in mtp_entries:
            out.write(struct.pack("<Q", len(key)))
            out.write(key)
            out.write(struct.pack("<I", typ))
            out.write(raw)
        for key, typ, raw in add:
            out.write(struct.pack("<Q", len(key)))
            out.write(key)
            out.write(struct.pack("<I", typ))
            out.write(raw)
            print("  +", key.decode())
        out.write(tinfo)
        pad2 = (32 - (out.tell() % 32)) % 32
        out.write(b"\x00" * pad2)
        out.write(data)
    print(f"wrote {out_path} ({Path(out_path).stat().st_size/1024**3:.2f} GiB) kv={n_kv_new}")


if __name__ == "__main__":
    main(
        sys.argv[1],
        sys.argv[2],
        sys.argv[3],
    )
