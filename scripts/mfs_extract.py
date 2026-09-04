"""MFS (Macintosh File System) reader: list files, extract forks, list resources.

MFS is the flat pre-HFS filesystem on 400K disks -- the format of the HD20
startup floppy, whose "Hard Disk 20" file carries the DCD driver as a `.Sony`
PTCH resource. Structures per Inside Macintosh II-119.

  python scripts/mfs_extract.py IMAGE
  python scripts/mfs_extract.py IMAGE "Hard Disk 20"           # list resources
  python scripts/mfs_extract.py IMAGE "Hard Disk 20" PTCH 2    # write to stdout

Resource forks only; MFS has no directories, so a name is unique per volume.
"""
import struct, sys


class MFS:
    def __init__(self, data):
        self.d = data
        m = data[1024:1024 + 64]
        (self.sig, self.crDate, self.lsBkUp, self.atrb, self.nmFls,
         self.dirSt, self.dirBlLen, self.nmAlBlks, self.alBlkSiz,
         self.clpSiz, self.alBlSt, self.nxtFNum, self.freeBks) = \
            struct.unpack('>HIIHHHHHIIHIH', m[:36])
        if self.sig != 0xD2D7:
            raise ValueError('not an MFS volume: signature %04X' % self.sig)
        self.name = m[37:37 + m[36]].decode('mac-roman')
        # The volume allocation block map follows the 64-byte MDB in block 2.
        self.mapOff = 1024 + 64

    def alloc_next(self, n):
        """12-bit block-map entry for allocation block n; 1 = last, 0 = free."""
        i = n - 2
        o = self.mapOff + (i * 3) // 2
        if i % 2 == 0:
            return (self.d[o] << 4) | (self.d[o + 1] >> 4)
        return ((self.d[o] & 0x0F) << 8) | self.d[o + 1]

    def ablk_offset(self, n):
        return (self.alBlSt + (n - 2) * (self.alBlkSiz // 512)) * 512

    def read_fork(self, startBlk, length):
        """Walk the allocation chain from startBlk, returning `length` bytes."""
        out, blk, seen = bytearray(), startBlk, set()
        while blk >= 2 and len(out) < length:
            if blk in seen:
                raise ValueError('cycle in allocation chain at block %d' % blk)
            seen.add(blk)
            o = self.ablk_offset(blk)
            out += self.d[o:o + self.alBlkSiz]
            blk = self.alloc_next(blk)
        return bytes(out[:length])

    def files(self):
        base = self.dirSt * 512
        off, end = base, base + self.dirBlLen * 512
        while off < end:
            blkend = (off // 512 + 1) * 512
            while off < blkend - 51:
                if not (self.d[off] & 0x80):
                    break                   # rest of this block is unused
                e = {'type': self.d[off + 2:off + 6].decode('mac-roman', 'replace'),
                     'creator': self.d[off + 6:off + 10].decode('mac-roman', 'replace')}
                (e['fileNum'], e['dStBlk'], e['dLgLen'], e['dPyLen'],
                 e['rStBlk'], e['rLgLen'], e['rPyLen']) = \
                    struct.unpack('>IHIIHII', self.d[off + 18:off + 42])
                nlen = self.d[off + 50]
                e['name'] = self.d[off + 51:off + 51 + nlen].decode('mac-roman', 'replace')
                yield e
                rec = 51 + nlen
                off += rec + (rec & 1)      # directory entries are word-aligned
            off = blkend

    def find(self, name):
        for e in self.files():
            if e['name'] == name:
                return e
        raise KeyError(name)


def parse_rsrc(rf):
    """Parse a resource fork; yield (type, id, name, data)."""
    dataOff, mapOff = struct.unpack('>II', rf[:8])
    typeListOff, nameListOff = struct.unpack('>HH', rf[mapOff + 24:mapOff + 28])
    tl = mapOff + typeListOff
    for i in range(struct.unpack('>H', rf[tl:tl + 2])[0] + 1):
        p = tl + 2 + i * 8
        rtype = rf[p:p + 4].decode('mac-roman', 'replace')
        cnt, refOff = struct.unpack('>HH', rf[p + 4:p + 8])
        for j in range(cnt + 1):
            r = tl + refOff + j * 12
            rid, nameOff = struct.unpack('>hH', rf[r:r + 4])
            dOff = struct.unpack('>I', b'\0' + rf[r + 5:r + 8])[0]
            name = ''
            if nameOff != 0xFFFF:
                np = mapOff + nameListOff + nameOff
                name = rf[np + 1:np + 1 + rf[np]].decode('mac-roman', 'replace')
            dp = dataOff + dOff
            ln = struct.unpack('>I', rf[dp:dp + 4])[0]
            yield rtype, rid, name, rf[dp + 4:dp + 4 + ln]


def main(argv):
    v = MFS(open(argv[1], 'rb').read())
    if len(argv) == 2:
        print('volume %s -- %d files, allocation block %d bytes'
              % (v.name, v.nmFls, v.alBlkSiz))
        for e in v.files():
            print('  %-24s %s/%s  data=%-7d rsrc=%d'
                  % (e['name'], e['type'], e['creator'], e['dLgLen'], e['rLgLen']))
        return 0
    e = v.find(argv[2])
    rf = v.read_fork(e['rStBlk'], e['rLgLen'])
    if len(argv) == 3:
        print('%s -- resource fork %d bytes' % (e['name'], len(rf)))
        for t, i, n, b in parse_rsrc(rf):
            print('  %-4s id=%-6d len=%-7d %s' % (t, i, len(b), n))
        return 0
    want_t, want_id = argv[3], int(argv[4])
    for t, i, n, b in parse_rsrc(rf):
        if t == want_t and i == want_id:
            sys.stdout.buffer.write(b)
            return 0
    sys.stderr.write('no %s id=%d in %s\n' % (want_t, want_id, e['name']))
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
