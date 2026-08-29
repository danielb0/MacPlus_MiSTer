# Plan: serve 512-byte logical blocks on the CD-ROM target

Written 2026-08-29. Branch `cd-512-blocks`, cut from `scsi-upgrade` at `f254ffd`.

`f254ffd` (a Mac reset empties the CD drive) stays intact on `scsi-upgrade` and
is the fallback. If this branch does not work on hardware, we ship that.

## What we found, and how

The CD-at-boot hang was fixed in `f254ffd` by preventing the ROM from ever
reading the disc. That works, but it treats a symptom. The root cause is now
established from four independent directions, three of them measurements rather
than argument.

| # | finding | how we know |
|---|---|---|
| 1 | The ROM takes its block size **from the disc**, not from the drive: *"using the block size value from the sbBlkSize field of the driver descriptor record, the Start Manager reads each block in the partition map"* | Inside Macintosh: Devices, SCSI Manager chapter (primary source) |
| 2 | Our failing disc declares **512** | measured: `System 7.1 CD-ROM.iso` block 0 has `sbSig='ER'`, `sbBlkSize=512`, `sbBlkCount=731506`, `sbDrvrCount=0` |
| 3 | Its partition map lives at **512-byte blocks 1 and 2** | measured: `'PM'` (0x504D) at byte offsets 512 and 1024, and nowhere else in the first 64 KB |
| 4 | The ROM's pseudo-DMA pump has **no escape** but its byte count | disassembled `releases/boot0.rom` (Plus ROM v3, `4D1F8172`) at `$41740A`: `btst d3,$50(a3)` / `beq` / `move.b (a0),(a2)+` / `subq.l #1,d2` / `bne`. `moveq #6,d3` sets the polled bit to BSR bit 6 (DRQ). No timeout, no error test, no phase test. |

Chain: the ROM reads block 0 and gets the **right** bytes (our 2048-byte block 0
contains the disc's 512-byte block 0 at its head), so it trusts the disc, learns
`sbBlkSize = 512`, and walks the partition map at blocks 1, 2, ... Our target
maps logical block 1 to byte offset **2048**, which is zero-filled. The `'PM'`
entries at bytes 512/1024 are invisible to a 2048-byte-block reader. The ROM's
subsequent arithmetic is nonsense and its pump spins forever.

Block 0 being the only block that happens to read correctly is exactly why the
ROM gets far enough to trust the disc and then hang.

This also explains every previously observed data point: the trigger is the
presence of `'ER'` (a Saturn CHD without one boots fine); bootability and image
format are irrelevant; and MacLC boots the same disc because it has a real Apple
CD driver that handles 2048-byte blocks natively instead of relying on the ROM's
512-block partition walk.

### A correction to the record

`f254ffd`'s commit message and the RTL comment say the ROM *"tries to LOAD THE
DRIVER"*. That is wrong in its specifics: the ISO has `sbDrvrCount = 0`, so there
is no driver to load. The trigger is the **partition-map walk** that follows a
valid `'ER'`. The fix works either way, because it stops the ROM reading block 0
at all, but the reasoning as recorded is incorrect and is corrected here.

### On authenticity

The earlier framing -- that emptying the drive on reset mirrors a period
mechanism -- does not survive scrutiny and is withdrawn.

A real AppleCD SC (Sony CDU-541, caddy-loading, physical eject button) **kept the
disc across a Mac reset**. A SCSI bus reset produces UNIT ATTENTION, not an
eject; an external drive is not power-cycled by a Mac reset; and a drive that
spat its caddy out on every restart would be notorious. Sharper still: the Plus
ROM has no CD driver, so it had no way to command an eject even in principle.

`f254ffd` therefore does something no period hardware did. It remains a
legitimate workaround -- it stops a real hang and costs the user very little --
but it has no period basis and the docs should not claim one.

Conversely, a real Plus with a Mac CD in the drive booted normally (anything else
would be among the best-documented quirks in Mac history, and it is absent from
the record). Since the disc was present and readable during that boot scan, the
real ROM completed the partition walk successfully. Our target is what differs.

## The change

The CD personality already runs its ring and flush machinery in 512-byte units;
`lba`/`tlen` are shifted `<<2` only at latch time. Serving 512-byte logical
blocks is therefore mostly the **removal** of a conversion, making the CD path
addressing-identical to the disk path.

1. `rtl/scsi.v` latch (~1274): drop the `<<2` on `lba` and `tlen` for CDROM.
2. `capacity` (~455): CDROM becomes `img_blocks - 1`, same as the disk path.
3. `read_capacity_dout` byte 6 (~477): block length 512, not 2048.
4. `cd_mode_sense_byte` byte 10 (~515): block length `0x02`, not `0x08`.
5. Update the `CDROM` parameter documentation (~96).
6. Remove the `sys_rst` eject from `f254ffd` -- **required**, not optional: with
   the drive emptied on reset the hypothesis cannot be tested at all.

### What is NOT affected

`cd_toc_dout` is sourced from `ca_toc_q0`, the **HPS-provided** TOC, and is not
computed from `capacity`. TOC content, MSF conversion and the audio path are all
frame-addressed and untouched by the data block size.

## Risks, stated up front

1. **TOC LBAs and data LBAs diverge.** CD TOC addressing is inherently in
   2352-byte frames. With 512-byte data blocks a track start read from the TOC is
   4x off from the same address used in a READ(10). Harmless for a single-track
   data CD (track 1 starts at LBA 0, and 0 scales to 0) -- which is the Apple
   HFS/ISO case this is meant to fix -- but a **real regression risk for
   mixed-mode or multi-track data discs**. This is the fundamental tension and it
   is why real drives defaulted to 2048 and let drivers cope.
2. **A CD driver that hardcodes 2048 breaks.** ISO 9660's PVD is at *sector 16*
   = byte 32768; a driver honouring READ CAPACITY asks for block 64 and works,
   one assuming 2048 asks for block 16 and reads the wrong place. Whatever
   extension currently reads CDs on the test rig is the thing to watch.
3. **CHD/CUE raw-2352 sources.** The 2048-byte user-data extraction still has to
   happen before any 512-byte slicing. Most likely place for a subtle bug.

## Verification

Sim ladder gates, unchanged: `tb_scsi_cdrom` (+ the new case), `tb_ncr5380_seam`
**84/84**, `tb_scsi_target` **14/14**, `tb_cd_mix` **18/18**. iverilog, not
verilator. Build with `-I rtl` (cd_audio.sv includes `cd_vol_lut.vh`), check the
compile exit status and the absence of a "were missing" warning, and delete the
stale `.vvp` first -- a previous run's binary has passed nonexistent tests before.

**RED test first** (`cd41`): READ(6) at LBA 1, length 1, must return the 512
bytes of HPS sector 1 (`byte[n] = 1 ^ n` in the bench's model). Today it returns
HPS sector 4 and 2048 bytes. That is the ROM's partition-map read, encoded.

Hardware smoke test, in this order:

1. **Boot with the System 7.1 ISO mounted** -- the actual hypothesis. Reaching
   the desktop proves the whole chain end to end.
2. Boot with no CD; mount a CD after reaching the desktop; read it.
3. CD audio still plays; Lode Runner unregressed (the 3C/3D baseline).
4. A CD -> disk copy, byte-exact.
5. Floppy write still works.
6. `PHLD holds/breaches` unchanged.

## Not doing

* **An OSD block-size toggle.** Rejected by the user 2026-08-29: too geeky even
  for MiSTer users. Conform to the documentation instead.
* **Sniffing block 0 for `'ER'`** and switching block size on it. Targeted, but a
  layering violation and unambiguously not authentic.
* **MODE SELECT block-descriptor negotiation.** The principled answer, and real
  SCSI, but we do not know whether Apple's driver actually used it (it may have
  done the 2048->512 mapping in software instead) and it is strictly more work
  for the same default-path behaviour. Revisit if 512 breaks a driver that could
  have asked for 2048.
* **Reverting `f254ffd` on `scsi-upgrade`.** That branch stays as the working
  fallback until this one is proven on hardware.
