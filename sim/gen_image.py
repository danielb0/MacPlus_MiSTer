#!/usr/bin/env python3
"""
Phase 0 -- synthetic 800K disk image generator for floppy_track_encoder.v
simulation.

Replicates the encoder's own address arithmetic (soff/spt/addr from
rtl/floppy_track_encoder.v) so that the memory image handed to the
testbench is laid out exactly the way the RTL will fetch it: track-major,
side-minor, sides=1 (double-sided), matching an 80-track/2-side/512B-sector
Sony 800K image (1600 sectors, 819200 bytes total).

Each sector's 512 bytes are a deterministic, self-identifying pattern
(track, side, sector baked into the first three bytes, a repeating counter
after that) so a decode failure points straight at which sector and which
byte within it went wrong.
"""
import pathlib

SIDES_PARAM = 1  # matches the encoder's `sides` port for this synthetic disk (double-sided)


def spt(track: int) -> int:
    group = min(track // 16, 4)
    return [12, 11, 10, 9, 8][group]


def soff(track: int) -> int:
    """Cumulative single-side sector count for all tracks before `track`."""
    if track == 0:
        return 0
    tm1 = track - 1
    g2 = min(tm1 // 16, 4)
    if g2 == 0:
        return track * 12
    if g2 == 1:
        return track * 11 + 16
    if g2 == 2:
        return track * 10 + 48
    if g2 == 3:
        return track * 9 + 96
    return track * 8 + 160


def addr(track: int, side: int, sector: int, offset: int) -> int:
    base = soff(track) * 512
    if SIDES_PARAM:
        base += soff(track) * 512
    if side:
        base += spt(track) * 512
    return base + sector * 512 + offset


def sector_pattern(track: int, side: int, sector: int) -> bytes:
    b = bytearray(512)
    b[0] = track & 0xFF
    b[1] = side & 0xFF
    b[2] = sector & 0xFF
    for i in range(3, 512):
        b[i] = (track * 7 + side * 13 + sector * 29 + i) & 0xFF
    return bytes(b)


def build_image() -> bytearray:
    total_size = soff(80) * 1024  # 80 tracks, double-sided -> 819200 bytes
    img = bytearray(b"\xee" * total_size)  # poison byte: anything left this value was never written
    for track in range(80):
        for side in range(2):
            for sector in range(spt(track)):
                a = addr(track, side, sector, 0)
                img[a:a + 512] = sector_pattern(track, side, sector)
    assert 0xEE not in set(img[i] for i in range(0, len(img), 512)), "unwritten sector detected"
    return img


def main():
    out_dir = pathlib.Path(__file__).parent
    img = build_image()

    bin_path = out_dir / "image.bin"
    bin_path.write_bytes(img)

    hex_path = out_dir / "image.hex"
    with hex_path.open("w") as f:
        for b in img:
            f.write(f"{b:02x}\n")

    print(f"image size: {len(img)} bytes ({len(img)/1024:.1f} KB)")
    print(f"soff(80) = {soff(80)} (expect 800 sectors/side)")
    for t in (0, 16, 40, 79):
        print(f"  track {t}: spt={spt(t)} soff={soff(t)}")


if __name__ == "__main__":
    main()
