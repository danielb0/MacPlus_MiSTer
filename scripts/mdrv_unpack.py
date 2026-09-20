"""Unpack a Presage 'MDRV' sound driver (Prince of Persia, Lemmings) out of an HFS image.

Reimplemented from PoP's CODE 2 (SOUND_PHASE_PLAN.md): a byte cipher over bytes
[7:] (LCG seeded $DCE5), then LZSS from byte 4 (flag byte LSB-first, 1 = literal,
0 = 16-bit token: low 12 bits offset, top nibble + 3 length, 4 KB window).
Bytes [0:4] hold the unpacked length and the output stops exactly there.

    python scripts/mdrv_unpack.py <image.vhd> <app name substring> [MDRV id] [out.bin]

Prints every matching application's MDRV ids; unpacks the requested one (default
11) and scans it for the sound-buffer landmarks used in the plan doc.
"""
import os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hfs_integrity import Vol, be16, be32


def decipher(buf):
    b = bytearray(buf); s = 0xDCE5
    for i in range(7, len(b)):
        x = b[i]; b[i] = (x ^ (s >> 8)) & 0xFF
        s = (((x + s) & 0xFFFF) * 0xCE6D + 0x58BF) & 0xFFFF
    return bytes(b)


def lzss(src, outlen):
    out = bytearray(); i = 0
    while i < len(src) and len(out) < outlen:
        flags = src[i]; i += 1
        for _ in range(8):
            if i >= len(src) or len(out) >= outlen: break
            if flags & 1:
                out.append(src[i]); i += 1
            else:
                tok = (src[i] << 8) | src[i + 1]; i += 2
                off = tok & 0xFFF; ln = (tok >> 12) + 3
                base = len(out) - 0x1000 + off
                for k in range(ln):
                    if len(out) >= outlen: break
                    out.append(out[base + k] if 0 <= base + k < len(out) else 0)
            flags >>= 1
    return bytes(out)


def files(v, pat):
    """(name, rsrcLen, rsrcExtRec) for every file record whose name contains pat."""
    cat = v.fork_bytes(v.ctExt, v.ctSize)
    nodeSize = be16(cat, 14 + 18); node = be32(cat, 14 + 10); seen = set()
    while node and node not in seen:
        seen.add(node)
        nd = cat[node * nodeSize:(node + 1) * nodeSize]
        if struct.unpack_from(">b", nd, 8)[0] != -1: break
        for r in range(be16(nd, 10)):
            ro = be16(nd, nodeSize - 2 * (r + 1))
            name = nd[ro + 7:ro + 7 + nd[ro + 6]].decode("mac_roman", "replace")
            do = ro + 1 + nd[ro]
            if do & 1: do += 1
            if struct.unpack_from(">b", nd, do)[0] == 2 and pat.lower() in name.lower():
                yield name, be32(nd, do + 36), nd[do + 86:do + 98]
        node = be32(nd, 0)


def rsrc_map(rf):
    dataOff, mapOff = be32(rf, 0), be32(rf, 4)
    tl = mapOff + be16(rf, mapOff + 24)
    for t in range(be16(rf, tl) + 1):
        e = tl + 2 + t * 8
        typ = rf[e:e + 4]; n = be16(rf, e + 4) + 1; rl = tl + be16(rf, e + 6)
        for i in range(n):
            re_ = rl + i * 12
            rid = struct.unpack_from(">h", rf, re_)[0]
            d = dataOff + (be32(rf, re_ + 4) & 0xFFFFFF)
            yield typ, rid, rf[d + 4:d + 4 + be32(rf, d)]


LANDMARKS = {
    "_VInstall":        rb"\xA0\x33",
    "SoundBase $266":   rb"\x02\x66",
    "VIA lowmem $1D4":  rb"\x01\xD4",
    "bclr #7,(an)":     rb"\x08[\x90-\x97]\x00\x07",
    "ori #$100,sr":     rb"\x00\x7C\x01\x00",
    "ori #$700,sr":     rb"\x00\x7C\x07\x00",
    "adda.w #imm,a3":   rb"\xD6\xFC\x00[\x00-\xFF]",
}

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    img, pat = sys.argv[1], sys.argv[2]
    want_id = int(sys.argv[3]) if len(sys.argv) > 3 else 11
    outp = sys.argv[4] if len(sys.argv) > 4 else None
    v = Vol(img)
    for name, rlen, rext in files(v, pat):
        if not rlen: continue
        rf = v.fork_bytes(rext, rlen)
        res = {rid: data for typ, rid, data in rsrc_map(rf) if typ == b"MDRV"}
        if not res: continue
        print("%r: MDRV ids %s" % (name, sorted(res)))
        if want_id not in res: continue
        plain = decipher(res[want_id]); outlen = be32(plain, 0)
        drv = lzss(plain[4:], outlen)
        print("  MDRV %d: %d -> %d bytes (header %d)" % (want_id, len(res[want_id]), len(drv), outlen))
        for k, p in LANDMARKS.items():
            hits = [m.start() for m in re.finditer(p, drv)]
            extra = ""
            if k.startswith("adda"):
                extra = "  " + ", ".join("$%04x:+$%x=word %d" % (h, be16(drv, h + 2), be16(drv, h + 2) // 2) for h in hits[:8])
            print("  %-18s x%-3d %s%s" % (k, len(hits), " ".join("$%04x" % h for h in hits[:10]), extra))
        if outp:
            open(outp, "wb").write(drv); print("  saved", outp)
        break
