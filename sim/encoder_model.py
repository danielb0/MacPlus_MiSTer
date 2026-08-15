"""
Phase 0 -- cycle-accurate Python port of floppy_track_encoder.v's state
machine (outer FSM + c1/c2/c3 nibbler), used two ways:

1. As a forward encoder, validated byte-for-byte against the real RTL
   dumps produced by tb_floppy_track_encoder.v via Icarus Verilog. This
   is the "ground truth" check: if my reading of the nibbler math is
   wrong, this comparison fails immediately.
2. Once validated, decode_track.py drives the SAME state machine but
   inverts it to recover sector bytes from a stream (Phase 2 will need
   the RTL equivalent of that decoder).

Every register update mirrors the RTL's nonblocking-assignment semantics:
each step() call reads self.* as "current, pre-edge" values, stages new
values from them, then commits all of them at once -- exactly matching
`always @(posedge clk)` semantics with multiple nonblocking assignments.

get_byte(sector, offset) is read using the CURRENT (pre-edge) sector and
src_offset directly, not through a lagged address-register model. That
matches real operation: `ready` (and therefore every step here) only
pulses once per ~128 clk cycles in the real system (rtl/floppy.v's
diskDataByteTimer), so the RTL's own `addr <= ...` register -- which
updates every clk cycle regardless of `ready` -- has settled onto the
current (sector, src_offset) long before the next ready-gated fetch.
An earlier version of this model (and of the testbench that validated
it) drove `ready` every clk cycle, which starves that settle time and
produces a spurious one-cycle address lag: some source bytes get read
twice and others never get read at all. That was caught by cross-
checking the round-trip against a decoder, not by inspection -- see
FLOPPY_WRITE_PLAN.md's Phase 0 notes.
"""
from gcr_common import spt_of, rol1_8, SONY_TABLE


class EncoderModel:
    def __init__(self, track: int, side: int, sides: int, get_byte):
        """
        get_byte(sector, offset) -> int (0-255): the synthetic sector data
        source, called exactly the way the RTL's memory read would be:
        by (sector number in interleave order, byte offset 0-511).
        """
        self.track = track
        self.side = side
        self.sides = sides
        self.get_byte = get_byte
        self.spt = spt_of(track)

        self.state = "SYN0"
        self.count = 0
        self.sector = 0
        self.src_offset = 0

        self.c1 = self.c2 = self.c3 = 0
        self.c2x = self.c3x = 0
        self.cnt = 0
        self.nib_xor_0 = self.nib_xor_1 = self.nib_xor_2 = 0
        self.data_latch = 0

    def _combinational(self):
        track_low = self.track & 0x3F
        sec_in_tr = self.sector & 0x3F
        track_hi = ((self.side & 1) << 5) | ((self.track >> 6) & 1)
        fmt = ((self.sides & 1) << 5) | 0x02
        checksum = track_low ^ sec_in_tr ^ track_hi ^ fmt

        if self.count == 3:
            sony_addr_in = track_low
        elif self.count == 4:
            sony_addr_in = sec_in_tr
        elif self.count == 5:
            sony_addr_in = track_hi
        elif self.count == 6:
            sony_addr_in = fmt
        else:
            sony_addr_in = checksum

        sony_dhdr_in = sec_in_tr

        if self.count == 0:
            sony_dsum_in = (((self.c3 >> 6) & 3) << 4) | (((self.c2 >> 6) & 3) << 2) | ((self.c1 >> 6) & 3)
        elif self.count == 1:
            sony_dsum_in = self.c3 & 0x3F
        elif self.count == 2:
            sony_dsum_in = self.c2 & 0x3F
        else:
            sony_dsum_in = self.c1 & 0x3F

        if self.cnt == 1:
            nib_out = self.nib_xor_0 & 0x3F
        elif self.cnt == 2:
            nib_out = self.nib_xor_1 & 0x3F
        elif self.cnt == 3:
            nib_out = self.nib_xor_2 & 0x3F
        else:
            nib_out = (((self.nib_xor_0 >> 6) & 3) << 4) | (((self.nib_xor_1 >> 6) & 3) << 2) | ((self.nib_xor_2 >> 6) & 3)

        if self.state == "ADDR":
            si = sony_addr_in
        elif self.state == "DHDR":
            si = sony_dhdr_in
        elif self.state in ("DZRO", "DPRE", "DATA"):
            si = nib_out
        elif self.state == "DSUM":
            si = sony_dsum_in
        else:
            si = 0x3F

        sony_byte = SONY_TABLE[si]

        if self.state == "ADDR":
            if self.count == 0:
                odata = 0xD5
            elif self.count == 1:
                odata = 0xAA
            elif self.count == 2:
                odata = 0x96
            elif self.count == 8:
                odata = 0xDE
            elif self.count == 9:
                odata = 0xAA
            else:
                odata = sony_byte
        elif self.state == "DHDR":
            if self.count == 0:
                odata = 0xD5
            elif self.count == 1:
                odata = 0xAA
            elif self.count == 2:
                odata = 0xAD
            else:
                odata = sony_byte
        elif self.state in ("DZRO", "DPRE", "DATA", "DSUM"):
            odata = sony_byte
        elif self.state == "DTRL":
            if self.count == 0:
                odata = 0xDE
            elif self.count == 1:
                odata = 0xAA
            else:
                odata = 0xFF
        else:
            odata = 0xFF

        nib_in = 0 if self.state == "DZRO" else self.data_latch
        strobe = ((self.state == "DPRE") or (self.state == "DATA" and self.count < 683 - 4 - 1)) and (self.cnt != 3)

        return odata, nib_in, strobe

    def step(self) -> int:
        odata, nib_in, strobe = self._combinational()

        new_data_latch = self.data_latch
        if strobe:
            new_data_latch = self.get_byte(self.sector, self.src_offset)

        if self.state == "DHDR":
            new_c1 = new_c2 = new_c3 = 0
            new_c2x = new_c3x = 0
            new_cnt = 0
            new_x0 = new_x1 = new_x2 = 0
        else:
            new_c1, new_c2, new_c3 = self.c1, self.c2, self.c3
            new_c2x, new_c3x = self.c2x, self.c3x
            new_x0, new_x1, new_x2 = self.nib_xor_0, self.nib_xor_1, self.nib_xor_2
            new_cnt = self.cnt
            if self.state in ("DPRE", "DATA"):
                new_cnt = (self.cnt + 1) & 3
                if self.count < 683 - 4:
                    if self.cnt == 1:
                        old_c1 = self.c1
                        new_c1 = rol1_8(old_c1)
                        s = self.c3 + nib_in + ((old_c1 >> 7) & 1)
                        new_c3x = (s >> 8) & 1
                        new_c3 = s & 0xFF
                        new_x0 = nib_in ^ rol1_8(old_c1)
                    elif self.cnt == 2:
                        s = self.c2 + nib_in + self.c3x
                        new_c2x = (s >> 8) & 1
                        new_c2 = s & 0xFF
                        new_c3x = 0
                        new_x1 = nib_in ^ self.c3
                    elif self.cnt == 3:
                        new_c1 = (self.c1 + nib_in + self.c2x) & 0xFF
                        new_c2x = 0
                        new_x2 = nib_in ^ self.c2
                else:
                    if self.cnt == 3:
                        new_x2 = 0

        new_state, new_count = self.state, self.count + 1
        new_sector, new_src_offset = self.sector, self.src_offset
        if strobe:
            new_src_offset = self.src_offset + 1

        if self.state == "SYN0":
            if self.count == 55:
                new_state, new_count = "ADDR", 0
        elif self.state == "ADDR":
            if self.count == 9:
                new_state, new_count = "SYN1", 0
        elif self.state == "SYN1":
            if self.count == 4:
                new_state, new_count = "DHDR", 0
        elif self.state == "DHDR":
            if self.count == 3:
                new_state, new_count = "DZRO", 0
        elif self.state == "DZRO":
            if self.count == 11:
                new_state, new_count = "DPRE", 0
        elif self.state == "DPRE":
            if self.count == 3:
                new_state, new_count = "DATA", 0
        elif self.state == "DATA":
            if self.count == 682:
                new_state, new_count = "DSUM", 0
        elif self.state == "DSUM":
            if self.count == 3:
                new_state, new_count = "DTRL", 0
        elif self.state == "DTRL":
            if self.count == 2:
                new_state, new_count = "WAIT", 0
        elif self.state == "WAIT":
            new_state, new_count, new_src_offset = "SYN0", 0, 0
            if self.sector == self.spt - 2 or self.sector == self.spt - 1:
                new_sector = 1 - (self.sector & 1)
            else:
                new_sector = self.sector + 2

        self.data_latch = new_data_latch
        self.c1, self.c2, self.c3 = new_c1, new_c2, new_c3
        self.c2x, self.c3x = new_c2x, new_c3x
        self.nib_xor_0, self.nib_xor_1, self.nib_xor_2 = new_x0, new_x1, new_x2
        self.cnt = new_cnt
        self.state, self.count, self.sector, self.src_offset = new_state, new_count, new_sector, new_src_offset

        return odata

    def run(self, n_cycles: int) -> bytes:
        return bytes(self.step() for _ in range(n_cycles))


if __name__ == "__main__":
    import pathlib
    from gen_image import sector_pattern

    out_dir = pathlib.Path(__file__).parent / "out"
    CYCLES = 20000
    mismatches = 0

    for track in (0, 16, 40, 79):
        for side in (0, 1):
            sectors = {s: sector_pattern(track, side, s) for s in range(spt_of(track))}
            model = EncoderModel(track, side, sides=1, get_byte=lambda sec, off, sectors=sectors: sectors[sec][off])
            got = model.run(CYCLES)

            dump_path = out_dir / f"track{track}_side{side}.bin"
            want = dump_path.read_bytes()

            if got == want:
                print(f"track {track} side {side}: MATCH ({len(got)} bytes)")
            else:
                mismatches += 1
                first_diff = next(i for i in range(len(got)) if got[i] != want[i])
                print(f"track {track} side {side}: MISMATCH at byte {first_diff}: "
                      f"model=0x{got[first_diff]:02x} rtl=0x{want[first_diff]:02x}")
                lo, hi = max(0, first_diff - 4), first_diff + 12
                print(f"  model: {got[lo:hi].hex()}")
                print(f"  rtl:   {want[lo:hi].hex()}")

    if mismatches:
        print(f"\n{mismatches} track/side combo(s) MISMATCHED")
    else:
        print("\nall track/side combos match byte-for-byte")
