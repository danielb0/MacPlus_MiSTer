"""
Phase 0 -- reference GCR decoder, the algebraic inverse of encoder_model.py.

Scans a raw byte stream for address fields (D5 AA 96 ...) and data fields
(D5 AA AD ...), decodes them, and verifies every checksum along the way.
Never returns sector data without a valid checksum: this exists to prove
the format is understood well enough for Phase 2's RTL decoder, and a
decoder that fixes up bad data instead of rejecting it would defeat that
purpose.

Key subtlety (see FLOPPY_WRITE_PLAN.md Phase 0 notes): nib_xor_0/1/2 are
registers. Reading them combinationally (to form `si`/odata) always sees
the pre-edge value -- i.e. whatever the *previous* occurrence of that cnt
phase computed -- while the nonblocking update for *this* occurrence only
becomes visible one cnt-cycle later. Net effect: group g's four output
bytes (cnt=0,1,2,3) don't encode group g's own three data bytes at all --
they encode group (g-1)'s three bytes in full (top-bits via cnt=0, low6
via cnt=1/2/3, all from the *same* group g). Decoding therefore needs a
one-group lookback, not a split lookahead within/across a single pair of
groups as an earlier version of this file assumed (caught by round-trip
testing against the corrected RTL dumps, not by inspection).
"""
from gcr_common import spt_of, rol1_8, SONY_TABLE, REVERSE_SONY_TABLE


class DecodeError(Exception):
    pass


def _lookup(byte_val: int) -> int:
    if byte_val not in REVERSE_SONY_TABLE:
        raise DecodeError(f"byte 0x{byte_val:02x} is not a valid encoded nibble")
    return REVERSE_SONY_TABLE[byte_val]


def decode_address_field(stream: bytes, pos: int):
    """
    stream[pos:pos+3] must be D5 AA 96. Returns a dict with track/side/
    sector/sides/checksum_ok, or raises DecodeError.
    """
    if stream[pos:pos + 3] != bytes([0xD5, 0xAA, 0x96]):
        raise DecodeError("bad address prologue")
    vals = [_lookup(b) for b in stream[pos + 3:pos + 8]]
    track_low, sec_in_tr, track_hi, fmt, checksum = vals
    expect_checksum = track_low ^ sec_in_tr ^ track_hi ^ fmt
    if checksum != expect_checksum:
        raise DecodeError(f"address checksum mismatch: got {checksum:#04x} want {expect_checksum:#04x}")
    if stream[pos + 8:pos + 10] != bytes([0xDE, 0xAA]):
        raise DecodeError("bad address trailer")

    track = ((track_hi & 1) << 6) | track_low
    side = (track_hi >> 5) & 1
    sides = (fmt >> 5) & 1
    sector = sec_in_tr & 0x3F
    return dict(track=track, side=side, sector=sector, sides=sides)


def decode_data_field(stream: bytes, pos: int):
    """
    stream[pos:pos+3] must be D5 AA AD. Returns (sector, data_bytes) where
    data_bytes is exactly 512 bytes, after verifying the data field's own
    checksum chain and trailer. Raises DecodeError on any mismatch.
    """
    if stream[pos:pos + 3] != bytes([0xD5, 0xAA, 0xAD]):
        raise DecodeError("bad data prologue")
    p = pos + 3
    sector = _lookup(stream[p])
    p += 1

    for i in range(12):
        if stream[p + i] != SONY_TABLE[0]:
            raise DecodeError(f"DZRO byte {i} is not the sync-zero byte")
    p += 12

    n = 687  # DPRE(4) + DATA(683), cnt cycles continuously across the boundary
    si_stream = [_lookup(b) for b in stream[p:p + n]]
    p += n

    groups = [si_stream[i:i + 4] for i in range(0, len(si_stream), 4)]

    c1 = c2 = c3 = 0
    recovered = []
    prev = (0, 0, 0)  # (c1, c2, c3) as of just before the group being finalized

    for g in range(1, len(groups)):
        grp = groups[g]
        if len(grp) < 3:
            break
        s0 = grp[0]
        s1 = grp[1]
        s2 = grp[2] if len(grp) > 2 else None
        s3 = grp[3] if len(grp) > 3 else None

        top0 = (s0 >> 4) & 3
        top1 = (s0 >> 2) & 3
        top2_ = s0 & 3
        c1s, c2s, c3s = prev

        nib_xor_0 = (top0 << 6) | s1
        old_c1 = c1s
        nib_in_1 = nib_xor_0 ^ rol1_8(old_c1)
        new_c1 = rol1_8(old_c1)
        s = c3s + nib_in_1 + ((old_c1 >> 7) & 1)
        new_c3x = (s >> 8) & 1
        new_c3 = s & 0xFF
        if len(recovered) < 512:
            recovered.append(nib_in_1)

        if s2 is not None:
            nib_xor_1 = (top1 << 6) | s2
            nib_in_2 = nib_xor_1 ^ new_c3
            s2v = c2s + nib_in_2 + new_c3x
            new_c2x = (s2v >> 8) & 1
            new_c2 = s2v & 0xFF
            if len(recovered) < 512:
                recovered.append(nib_in_2)
        else:
            new_c2, new_c2x = c2s, 0

        if s3 is not None:
            nib_xor_2 = (top2_ << 6) | s3
            nib_in_3 = nib_xor_2 ^ new_c2
            new_c1_final = (new_c1 + nib_in_3 + new_c2x) & 0xFF
            if len(recovered) < 512:
                recovered.append(nib_in_3)
        else:
            new_c1_final = new_c1  # trailing zero-pad byte, not real data

        c1, c2, c3 = new_c1_final, new_c2, new_c3
        prev = (c1, c2, c3)

    if len(recovered) != 512:
        raise DecodeError(f"recovered {len(recovered)} bytes, expected 512")

    dsum_vals = [_lookup(b) for b in stream[p:p + 4]]
    p += 4
    want_top = (((c3 >> 6) & 3) << 4) | (((c2 >> 6) & 3) << 2) | ((c1 >> 6) & 3)
    got_top, got_c3, got_c2, got_c1 = dsum_vals
    if (got_top, got_c3, got_c2, got_c1) != (want_top, c3 & 0x3F, c2 & 0x3F, c1 & 0x3F):
        raise DecodeError(
            f"data checksum mismatch: got ({got_top:#04x},{got_c3:#04x},{got_c2:#04x},{got_c1:#04x}) "
            f"want ({want_top:#04x},{c3 & 0x3F:#04x},{c2 & 0x3F:#04x},{c1 & 0x3F:#04x})"
        )

    if stream[p:p + 2] != bytes([0xDE, 0xAA]):
        raise DecodeError("bad data trailer")

    return sector, bytes(recovered)


def find_sync_marks(stream: bytes, marker: bytes):
    positions = []
    start = 0
    while True:
        idx = stream.find(marker, start)
        if idx == -1:
            break
        positions.append(idx)
        start = idx + 1
    return positions


def decode_track_stream(stream: bytes):
    """
    Scans the whole stream for address+data field pairs. Returns a dict
    {sector_number: 512 bytes} of every sector successfully decoded, plus
    a list of (position, reason) for every rejected field.
    """
    sectors = {}
    errors = []

    for pos in find_sync_marks(stream, bytes([0xD5, 0xAA, 0x96])):
        try:
            addr = decode_address_field(stream, pos)
        except DecodeError:
            continue  # not a real address field (or a corrupted one) -- skip
        # data field follows after 5 sync bytes; search a small window for D5 AA AD
        search_start = pos + 10
        data_pos = None
        for cand in find_sync_marks(stream[search_start:search_start + 20], bytes([0xD5, 0xAA, 0xAD])):
            data_pos = search_start + cand
            break
        if data_pos is None:
            errors.append((pos, "no data field found after address field"))
            continue
        try:
            sector, data = decode_data_field(stream, data_pos)
        except DecodeError as e:
            errors.append((data_pos, str(e)))
            continue
        if sector != addr["sector"]:
            errors.append((data_pos, f"data field sector {sector} != address field sector {addr['sector']}"))
            continue
        sectors[sector] = data

    return sectors, errors


if __name__ == "__main__":
    import pathlib
    from gen_image import sector_pattern

    out_dir = pathlib.Path(__file__).parent / "out"
    all_ok = True

    for track in (0, 16, 40, 79):
        for side in (0, 1):
            stream = (out_dir / f"track{track}_side{side}.bin").read_bytes()
            sectors, errors = decode_track_stream(stream)

            expected_spt = spt_of(track)
            ok = True
            for s in range(expected_spt):
                if s not in sectors:
                    print(f"track {track} side {side}: sector {s} NOT RECOVERED")
                    ok = False
                    continue
                want = sector_pattern(track, side, s)
                if sectors[s] != want:
                    print(f"track {track} side {side}: sector {s} MISMATCH")
                    ok = False

            if len(sectors) != expected_spt:
                print(f"track {track} side {side}: recovered {len(sectors)} sectors, expected {expected_spt}")
                ok = False

            if ok:
                print(f"track {track} side {side}: all {expected_spt} sectors recovered byte-exact")
            else:
                all_ok = False

    print()
    print("PHASE 0 GATE: PASS" if all_ok else "PHASE 0 GATE: FAIL")
