"""
Shared helpers for the Phase 0 floppy GCR simulation: geometry (soff/spt),
and the sony_to_disk_byte forward table extracted mechanically from the
RTL source itself (never hand-transcribed, so a misreading of the table
can't silently diverge from what the core actually does).
"""
import re
import pathlib

RTL_ENCODER = pathlib.Path(__file__).parent.parent / "rtl" / "floppy_track_encoder.v"


def spt_of(track: int) -> int:
    group = min(track // 16, 4)
    return [12, 11, 10, 9, 8][group]


def soff_of(track: int) -> int:
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


def rol1_8(x: int) -> int:
    x &= 0xFF
    return ((x << 1) | (x >> 7)) & 0xFF


def extract_sony_table(path: pathlib.Path = RTL_ENCODER) -> dict:
    """
    Parse the `(si==6'hXX)?8'hYY:` entries out of the sony_to_disk_byte
    table in the RTL source. Returns {si (0-63): disk_byte (0-255)}.
    """
    text = path.read_text()
    m = re.search(r"wire \[7:0\] sony_to_disk_byte =(.*?);", text, re.DOTALL)
    if not m:
        raise RuntimeError(f"could not locate sony_to_disk_byte table in {path}")
    body = m.group(1)
    pairs = re.findall(r"si==6'h([0-9a-fA-F]+)\)\?8'h([0-9a-fA-F]+)", body)
    table = {int(si, 16): int(byte_, 16) for si, byte_ in pairs}
    # the final entry has no `si==` guard (it's the default/else case: si==0x3f)
    default_m = re.search(r":\s*8'h([0-9a-fA-F]+)\s*$", body.strip())
    if default_m:
        table[0x3F] = int(default_m.group(1), 16)
    if len(table) != 64:
        raise RuntimeError(f"expected 64 table entries, got {len(table)}: {sorted(table)}")
    return table


SONY_TABLE = extract_sony_table()
REVERSE_SONY_TABLE = {v: k for k, v in SONY_TABLE.items()}
assert len(REVERSE_SONY_TABLE) == 64, "forward table is not a bijection"


if __name__ == "__main__":
    print(f"{len(SONY_TABLE)} forward table entries extracted from {RTL_ENCODER.name}")
    print("si=0x00 ->", hex(SONY_TABLE[0]))
    print("si=0x3f ->", hex(SONY_TABLE[0x3F]))
    for t in (0, 16, 40, 79):
        print(f"track {t}: spt={spt_of(t)} soff={soff_of(t)}")
