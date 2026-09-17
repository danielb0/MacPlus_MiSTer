"""Byte-for-byte fork comparison between two HFS volumes.

    python scripts/hfs_fork_diff.py <written.dsk> <source.vhd> [name-substring]

Walks the catalog of the WRITTEN volume (a floppy image the core wrote to),
and for every file on it finds the file of the same name on the SOURCE volume
(the volume the copy came from) and compares the data and resource forks byte
for byte. This is the strong half of the floppy-write gate: hfs_integrity.py's
reconciliation passes on a volume whose sectors carry the wrong CONTENT, as
the LC's corrupt copy showed (FLOPPY_WRITE_PLAN.md Phase 8).

Reuses hfs_integrity.py's Vol (partition map, MDB, 3-extent fork reader).
Files whose forks span more than three extents are reported, not compared.

Resource-fork header bytes $30..$7D are the File Manager's, not the file's:
when a resource fork is created the system writes a "directory copy" of the
file's catalog entry (name, type, creator, from an uncleared buffer) into
that part of the header's reserved area, so a Finder duplicate differs from
its original there by design (Apple Technical Note 74; 68kMLA thread 49937,
2025; found the hard way on 2026-09-17 - one pad byte after the name). Those
bytes are compared separately and reported, never counted as a difference.
"""
import os, struct, sys
sys.path.insert(0, os.path.dirname(__file__))
from hfs_integrity import Vol, be16, be32

def catalog(v):
    """{full path: (dataLen, rsrcLen, dataExt, rsrcExt)} plus dir names."""
    cat = v.fork_bytes(v.ctExt, v.ctSize)
    nodeSize = be16(cat, 14 + 18)
    node = be32(cat, 14 + 10)
    dirs = {1: "", 2: ""}          # parent 1 = root's parent, 2 = root dir
    files = {}
    seen = set()
    while node and node not in seen:
        seen.add(node)
        nd = cat[node * nodeSize:(node + 1) * nodeSize]
        if len(nd) < 14 or struct.unpack_from(">b", nd, 8)[0] != -1:
            break
        for r in range(be16(nd, 10)):
            ro = be16(nd, nodeSize - 2 * (r + 1))
            keyLen = nd[ro]
            parent = be32(nd, ro + 2)
            name = nd[ro + 7:ro + 7 + nd[ro + 6]].decode("mac_roman", "replace")
            do = ro + 1 + keyLen + ((1 + keyLen) & 1)
            t = struct.unpack_from(">b", nd, do)[0]
            if t == 1:
                dirs[be32(nd, do + 6)] = (parent, name)
            elif t == 2:
                files[(parent, name)] = (be32(nd, do + 26), be32(nd, do + 36),
                                         nd[do + 74:do + 86], nd[do + 86:do + 98])
        node = be32(nd, 0)
    def path(parent, name):
        parts = [name]
        while parent not in (1, 2):
            p, n = dirs[parent]
            parts.append(n); parent = p
        return "/".join(reversed(parts))
    return {path(p, n): rec for (p, n), rec in files.items()}

def fork(v, ext, size):
    if size == 0:
        return b""
    try:
        return v.fork_bytes(ext, size)
    except SystemExit:
        return None

def main(written, source, needle=""):
    wv, sv = Vol(written), Vol(source)
    wf, sf = catalog(wv), catalog(sv)
    by_name = {}
    for p, rec in sf.items():
        by_name.setdefault(p.rsplit("/", 1)[-1], []).append((p, rec))
    print("written %r: %d files    source %r: %d files" % (wv.name, len(wf), sv.name, len(sf)))
    ok = bad = skipped = 0
    for p in sorted(wf):
        name = p.rsplit("/", 1)[-1]
        if needle and needle not in p:
            continue
        if name == "Desktop" or name.startswith("Desktop D"):
            continue                                  # the Finder's own, never copied
        cands = by_name.get(name, [])
        if not cands:
            print("  %-40s  no file of that name on the source" % p); skipped += 1; continue
        dl, rl, de, re_ = wf[p]
        wd, wr = fork(wv, de, dl), fork(wv, re_, rl)
        verdicts = []
        for sp, (sdl, srl, sde, sre) in cands:
            sd, sr = fork(sv, sde, sdl), fork(sv, sre, srl)
            if None in (wd, wr, sd, sr):
                verdicts.append("%s: a fork spans >3 extents, not compared" % sp); continue
            same_d = (wd == sd)
            same_r = (wr == sr) or (len(wr) == len(sr) and len(wr) >= 0x7E
                                    and wr[:0x30] == sr[:0x30] and wr[0x7E:] == sr[0x7E:])
            hdr_note = "" if wr == sr else "  [rsrc header $30-$7D differs: the File Manager's directory copy]"
            if same_d and same_r:
                verdicts = [("IDENTICAL to %s  (data %d B, rsrc %d B)%s" % (sp, dl, rl, hdr_note))]; break
            verdicts.append("%s: data %s (%d vs %d B), rsrc %s (%d vs %d B)" % (
                sp, "same" if same_d else "DIFFERS", dl, sdl, "same" if same_r else "DIFFERS", rl, srl))
        v = verdicts[0]
        if v.startswith("IDENTICAL"): ok += 1
        elif "not compared" in v: skipped += 1
        else: bad += 1
        print("  %-40s  %s" % (p, v))
    print()
    print("%d identical, %d differ, %d not compared" % (ok, bad, skipped))
    print("FORK DIFF: %s" % ("PASS" if bad == 0 and ok > 0 else "FAIL"))

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
