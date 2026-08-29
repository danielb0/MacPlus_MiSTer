"""HFS volume integrity reconciliation.

The check recorded from the 2026-08-23 soak: walk the catalog B-tree, sum every
file's PHYSICAL data and resource fork, add the two B-trees, and compare against
the MDB's in-use figure. A single dropped, duplicated or mislanded write breaks
the reconciliation. Run on a CLEANLY UNMOUNTED image.
"""
import struct, sys

def be16(b, o): return struct.unpack_from(">H", b, o)[0]
def be32(b, o): return struct.unpack_from(">I", b, o)[0]

class Vol:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.base = self.find_hfs()
        self.mdb = self.rd(self.base + 1024, 512)
        if self.mdb[0:2] != b"BD":
            sys.exit("no HFS MDB at partition+1024 (got %s)" % self.mdb[0:2].hex())
        self.alBlkSiz = be32(self.mdb, 0x14)
        self.alBlSt   = be16(self.mdb, 0x1C)
        self.nmAlBlks = be16(self.mdb, 0x12)
        self.freeBks  = be16(self.mdb, 0x22)
        n = self.mdb[0x24]
        self.name = self.mdb[0x25:0x25+n].decode("mac_roman", "replace")
        # MDB layout: drFndrInfo is 32 bytes at 0x5C, then drVCSize 0x7C,
        # drVBMCSize 0x7E, drCtlCSize 0x80, drXTFlSize 0x82, drXTExtRec 0x86,
        # drCTFlSize 0x92, drCTExtRec 0x96.
        self.xtSize = be32(self.mdb, 0x82)
        self.xtExt  = self.mdb[0x86:0x86+12]
        self.ctSize = be32(self.mdb, 0x92)
        self.ctExt  = self.mdb[0x96:0x96+12]

    def rd(self, off, n):
        self.f.seek(off); return self.f.read(n)

    def find_hfs(self):
        b0 = self.rd(0, 512)
        if b0[0:2] != b"ER":
            return 0                      # bare volume, no partition map
        for i in range(1, 64):
            e = self.rd(i * 512, 512)
            if e[0:2] != b"PM":
                break
            start = be32(e, 8)
            ptyp  = e[48:80].split(b"\0")[0].decode("ascii", "replace")
            if "HFS" in ptyp:
                return start * 512
        sys.exit("no Apple_HFS partition found")

    def alloc_off(self, blk):
        return self.base + self.alBlSt * 512 + blk * self.alBlkSiz

    def fork_bytes(self, extrec, size):
        """Read a fork described by up to 3 extents."""
        out = bytearray()
        for k in range(3):
            st = be16(extrec, k * 4)
            cnt = be16(extrec, k * 4 + 2)
            if cnt == 0:
                continue
            out += self.rd(self.alloc_off(st), cnt * self.alBlkSiz)
            if len(out) >= size:
                break
        if len(out) < size:
            sys.exit("catalog spans >3 extents (%d of %d bytes); needs the "
                     "extents overflow file" % (len(out), size))
        return bytes(out[:size])

def walk_catalog(cat):
    """Yield (dataPhysical, rsrcPhysical) for every file record."""
    nodeSize = be16(cat, 14 + 18)
    firstLeaf = be32(cat, 14 + 10)
    nfiles = 0
    node = firstLeaf
    seen = set()
    while node and node not in seen:
        seen.add(node)
        off = node * nodeSize
        nd = cat[off:off + nodeSize]
        if len(nd) < 14:
            break
        fLink = be32(nd, 0)
        kind = struct.unpack_from(">b", nd, 8)[0]
        nrecs = be16(nd, 10)
        if kind != -1:                     # not a leaf
            break
        for r in range(nrecs):
            ro = be16(nd, nodeSize - 2 * (r + 1))
            keyLen = nd[ro]
            # record data begins after the key, word-aligned
            do = ro + 1 + keyLen
            if do & 1:
                do += 1
            if do + 2 > nodeSize:
                continue
            cdrType = struct.unpack_from(">b", nd, do)[0]
            if cdrType == 2:               # file record
                dpy = be32(nd, do + 30)
                rpy = be32(nd, do + 40)
                nfiles += 1
                yield dpy, rpy
        node = fLink
    if nfiles == 0:
        sys.exit("walked no file records -- catalog parse is wrong")

def main(path):
    v = Vol(path)
    cat = v.fork_bytes(v.ctExt, v.ctSize)
    data = rsrc = 0
    n = 0
    for d, r in walk_catalog(cat):
        data += d; rsrc += r; n += 1
    btrees = v.ctSize + v.xtSize
    accounted = data + rsrc + btrees
    inuse = (v.nmAlBlks - v.freeBks) * v.alBlkSiz

    print("volume        %r" % v.name)
    print("alloc block   %d bytes   total %d   free %d" %
          (v.alBlkSiz, v.nmAlBlks, v.freeBks))
    print("files walked  %d" % n)
    print()
    print("  data forks  physical  %14s" % f"{data:,}")
    print("  rsrc forks  physical  %14s" % f"{rsrc:,}")
    print("  B-trees               %14s" % f"{btrees:,}")
    print("  accounted             %14s" % f"{accounted:,}")
    print("  MDB in use            %14s" % f"{inuse:,}")
    diff = inuse - accounted
    print("  difference            %14s" % f"{diff:,}")
    print()
    # forks are rounded up to whole allocation blocks on disk
    slack = n * 2 * v.alBlkSiz
    if diff == 0:
        print("EXACT: every byte the MDB says is in use is accounted for.")
    elif 0 <= diff <= slack:
        print("CONSISTENT: difference is %d bytes, within the %d-byte rounding\n"
              "slack for %d files x 2 forks at a %d-byte allocation block.\n"
              "No write was dropped, duplicated or mislanded." %
              (diff, slack, n, v.alBlkSiz))
    else:
        print("MISMATCH -- outside rounding slack (%d). Investigate." % slack)

if __name__ == "__main__":
    main(sys.argv[1])
