#!/usr/bin/env python3
"""
Phase 3 -- synthetic *real Mac write* data-field generator, for testing
rtl/floppy_track_decoder.v's decode of genuine host writes.

This is deliberately NOT built by running rtl/floppy_track_encoder.v: that
RTL only ever emits an all-zero Sony tag, and takes a shortcut to do it
(STATE_DZRO emits 12 literal sync-zero bytes instead of running a real
12-byte tag through the checksum chain like a real Mac write does - see
FLOPPY_WRITE_PLAN.md Phase 3 and floppy_track_decoder.v's header comment).
That shortcut happens to be bit-identical to the real format specifically
*because* the tag is all-zero (encoding 12 real zero bytes the normal way
produces the same literal 0x96 x12 run) - it is not itself a separate
format.

encode_data_field() below is the direct algebraic inverse of
floppy_track_decoder.v's S_GRP (solved from its own equations, then cross-
checked byte-exact against a from-scratch Python port of the RTL's group
loop - see the __main__ self-test): group g directly encodes payload
bytes 3g..3g+2 into 4 raw bytes, no lookback and no discarded group (an
earlier version of this file, and of the RTL, assumed a one-group
lookback with group 0 thrown away - re-derived and confirmed wrong by
decoding the real, unmodified floppy_track_encoder.v's actual 699-byte
DZRO+DPRE+DATA output this way and recovering exactly 12 zero tag bytes +
the real 512-byte sector data, byte-for-byte, using precisely the bytes
the encoder emits).
"""
import pathlib
from gcr_common import rol1_8, SONY_TABLE


def encode_data_field(sector: int, tag: bytes, data: bytes) -> bytes:
    assert len(tag) == 12
    assert len(data) == 512
    src = tag + data  # 524 bytes, one continuous checksummed stream

    out = bytearray()
    out += bytes([0xD5, 0xAA, 0xAD])
    out.append(SONY_TABLE[sector & 0x0F])

    c1 = c2 = c3 = 0
    idx = 0

    # groups 0..173: full (3 source bytes -> 4 raw bytes each)
    for _ in range(174):
        b1, b2, b3 = src[idx], src[idx + 1], src[idx + 2]
        idx += 3

        rol_c1 = rol1_8(c1)
        nib_xor_0 = b1 ^ rol_c1
        top0, s1 = (nib_xor_0 >> 6) & 3, nib_xor_0 & 0x3F
        c3_sum = c3 + b1 + ((c1 >> 7) & 1)
        new_c3x, new_c3 = (c3_sum >> 8) & 1, c3_sum & 0xFF

        nib_xor_1 = b2 ^ new_c3
        top1, s2 = (nib_xor_1 >> 6) & 3, nib_xor_1 & 0x3F
        c2_sum = c2 + b2 + new_c3x
        new_c2x, new_c2 = (c2_sum >> 8) & 1, c2_sum & 0xFF

        nib_xor_2 = b3 ^ new_c2
        top2, s3 = (nib_xor_2 >> 6) & 3, nib_xor_2 & 0x3F
        new_c1 = (rol_c1 + b3 + new_c2x) & 0xFF

        s0 = (top0 << 4) | (top1 << 2) | top2
        out += bytes([SONY_TABLE[s0], SONY_TABLE[s1], SONY_TABLE[s2], SONY_TABLE[s3]])
        c1, c2, c3 = new_c1, new_c2, new_c3

    # group 174: partial (2 source bytes -> 3 raw bytes, no third nibble)
    b1, b2 = src[idx], src[idx + 1]
    idx += 2
    assert idx == len(src)

    rol_c1 = rol1_8(c1)
    nib_xor_0 = b1 ^ rol_c1
    top0, s1 = (nib_xor_0 >> 6) & 3, nib_xor_0 & 0x3F
    c3_sum = c3 + b1 + ((c1 >> 7) & 1)
    new_c3x, new_c3 = (c3_sum >> 8) & 1, c3_sum & 0xFF

    nib_xor_1 = b2 ^ new_c3
    top1, s2 = (nib_xor_1 >> 6) & 3, nib_xor_1 & 0x3F
    c2_sum = c2 + b2 + new_c3x
    new_c2x, new_c2 = (c2_sum >> 8) & 1, c2_sum & 0xFF

    # top2/s3 don't exist for a partial group (has_s3 false - the RTL
    # never computes nib_in_3 for it), so top2 is a don't-care; 0 is fine.
    s0 = (top0 << 4) | (top1 << 2) | 0
    out += bytes([SONY_TABLE[s0], SONY_TABLE[s1], SONY_TABLE[s2]])
    c1, c2, c3 = rol_c1, new_c2, new_c3  # matches RTL: "c1 <= rol_c1" when !has_s3

    want_top = (((c3 >> 6) & 3) << 4) | (((c2 >> 6) & 3) << 2) | ((c1 >> 6) & 3)
    out.append(SONY_TABLE[want_top])
    out.append(SONY_TABLE[c3 & 0x3F])
    out.append(SONY_TABLE[c2 & 0x3F])
    out.append(SONY_TABLE[c1 & 0x3F])
    out += bytes([0xDE, 0xAA])

    assert len(out) == 3 + 1 + 699 + 4 + 2
    return bytes(out)


def _self_test():
    """Ports floppy_track_decoder.v's S_GRP verbatim and confirms it
    recovers exactly tag+data from encode_data_field()'s own output -
    this is what actually proves encode/decode agree, not the byte count."""
    from gcr_common import REVERSE_SONY_TABLE

    tag = bytes((i * 53 + 7) & 0xFF for i in range(12))
    data = bytes((i * 197 + 11) & 0xFF for i in range(512))
    field = encode_data_field(5, tag, data)
    grp_raw = field[4:4 + 699]

    c1 = c2 = c3 = 0
    grp_byte0 = grp_byte1 = grp_byte2 = 0
    group_index = 0
    byte_in_group = 0
    recovered = []
    pos = 0
    while True:
        nib_cur = REVERSE_SONY_TABLE[grp_raw[pos]]
        pos += 1
        has_s3 = byte_in_group == 3
        grp_done = has_s3 or (group_index == 174 and byte_in_group == 2)
        gs2 = grp_byte2 if has_s3 else nib_cur

        if byte_in_group < 3:
            if byte_in_group == 0:
                grp_byte0 = nib_cur
            elif byte_in_group == 1:
                grp_byte1 = nib_cur
            else:
                grp_byte2 = nib_cur

        top0, top1, top2_ = (grp_byte0 >> 4) & 3, (grp_byte0 >> 2) & 3, grp_byte0 & 3
        rol_c1 = rol1_8(c1)
        nib_in_1 = ((top0 << 6) | grp_byte1) ^ rol_c1
        c3_sum = c3 + nib_in_1 + ((c1 >> 7) & 1)
        new_c3x, new_c3 = (c3_sum >> 8) & 1, c3_sum & 0xFF
        nib_in_2 = ((top1 << 6) | gs2) ^ new_c3
        c2_sum = c2 + nib_in_2 + new_c3x
        new_c2x, new_c2 = (c2_sum >> 8) & 1, c2_sum & 0xFF
        nib_in_3 = ((top2_ << 6) | nib_cur) ^ new_c2
        new_c1_full = (rol_c1 + nib_in_3 + new_c2x) & 0xFF

        if grp_done:
            recovered.append(nib_in_1)
            recovered.append(nib_in_2)
            if has_s3:
                recovered.append(nib_in_3)
                c1 = new_c1_full
            else:
                c1 = rol_c1
            c2, c3 = new_c2, new_c3
            byte_in_group = 0
            if group_index == 174:
                break
            group_index += 1
        else:
            byte_in_group += 1

    assert bytes(recovered) == tag + data, "self-test: decode(encode(x)) != x"
    print("self-test PASS: decode(encode(tag+data)) == tag+data (524 bytes)")


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).parent))
    from gen_image import sector_pattern

    _self_test()

    out_dir = pathlib.Path(__file__).parent

    # side 0: all-zero tag (sanity - the case the old DZRO shortcut also
    # happened to get right). side 1: real, non-zero, non-trivial tag
    # per sector (the bug scenario - a real Mac write's actual tag data).
    groups = {
        0: [(0, 0, sector, bytes(12)) for sector in range(4)],
        1: [(0, 1, sector, bytes((sector * 41 + i * 17 + 3) & 0xFF for i in range(12)))
            for sector in range(4)],
    }

    for side, cases in groups.items():
        stream = bytearray()
        manifest = []
        for track, s, sector, tag in cases:
            data = sector_pattern(track, s, sector)
            field = encode_data_field(sector, tag, data)
            manifest.append((track, s, sector, len(stream), len(field), tag.hex()))
            stream += field
            stream += bytes([0xFF] * 8)  # inter-field gap, like real media

        hex_path = out_dir / f"write_stream_side{side}.hex"
        with hex_path.open("w") as f:
            for b in stream:
                f.write(f"{b:02x}\n")

        print(f"wrote {hex_path} ({len(stream)} bytes, {len(cases)} fields)")
        for t, s, sec, off, flen, tag_hex in manifest:
            print(f"  track={t} side={s} sector={sec} offset={off} len={flen} tag={tag_hex}")

    # single-field, real (non-zero) tag, track 0 / side 0 / sector 0 - for
    # tb_floppy_write_path.v, whose DUT (floppy.v) has driveSide fixed at
    # its reset value (0) throughout, unlike the side-1 fields above.
    tag = bytes((i * 61 + 19) & 0xFF for i in range(12))
    field = encode_data_field(0, tag, sector_pattern(0, 0, 0))
    hex_path = out_dir / "write_stream_integration.hex"
    with hex_path.open("w") as f:
        for b in field:
            f.write(f"{b:02x}\n")
    print(f"wrote {hex_path} ({len(field)} bytes, track=0 side=0 sector=0, tag={tag.hex()})")
