# Plan: Diskette Write Support for MacPlus_MiSTer

Target repo: `C:\Git\MiSTer-devel\MacPlus_MiSTer` (fork of MiSTer-devel/MacPlus_MiSTer, remote `danielb0/MacPlus_MiSTer`).

---

## 1. Where the core stands today

Five findings from reading the RTL define the whole shape of this job.

**1.1 — Every floppy currently reports itself as write-protected.**
In [`rtl/floppy.v:113`](rtl/floppy.v) the `WRTPRT` bit of `driveRegsAsRead` is hardwired:

```verilog
1'b0, // WRTPRT = locked
```

Mac OS reads this bit, concludes the disk is locked, and *never attempts a write*. This is the master switch for the entire feature — and, usefully, a ready-made kill switch to hang an OSD "write protect" toggle on.

**1.2 — The write data path is a stub.**
`floppy` declares `input [7:0] writeData` ([`rtl/floppy.v:74`](rtl/floppy.v)) and never references it again. In the IWM, the handshake register is hardwired to "always ready" ([`rtl/iwm.v:73-74`](rtl/iwm.v)):

```verilog
assign _iwmBusy = 1'b1;       // write buffer empty
assign _writeUnderrun = 1'b1;
```

So CPU writes land in `writeData` and evaporate. There is no partially-built write feature to finish — this is greenfield.

**1.3 — Floppies are not block devices; they are ROM-style downloads.**
The SCSI `.vhd` uses the HPS block-device protocol (`sd_rd`/`sd_wr`/`sd_lba`/`sd_buff_*`/`img_mounted`, `VDNUM=2`). Floppies do not. They use `F1`/`F2` CONF_STR rows and are streamed once through `ioctl_download` into SDRAM as a flat blob at byte offsets `0x100000` and `0x200000` ([`MacPlus.sv:640`](MacPlus.sv), [`rtl/addrController_top.v:207-208`](rtl/addrController_top.v)).

**This is the single biggest structural obstacle.** `ioctl_download` is one-way. There is no file handle to write back through, so no amount of GCR decoding alone will persist anything. Floppies must become `S` block-device mounts.

**1.4 — There is a free memory slot, and bandwidth is not a concern.**
`extra_slot_count` is `[1:0]` and only slots 0/1/2 are allocated (internal drive read, external drive read, audio) — **slot 3 is unused** ([`rtl/addrController_top.v:201-204`](rtl/addrController_top.v)). `extraBusControl` occurs every 16 `clk_sys`, and the slot rotates every 64 `clk_sys` ≈ 2 µs at 32 MHz. A disk byte time is 16 µs. That is ~8 free memory accesses per disk byte — ample headroom for a write-back port. (The "every hsync ~21us" comment at [`rtl/floppy.v:183`](rtl/floppy.v) is stale and does not reflect the current slot allocation.)

**1.5 — The written data field identifies its own sector.**
This is the finding that makes the project tractable. Real Apple GCR drives write *only the data field* during a normal sector write; address fields are written only when formatting. So a decoder cannot rely on seeing an address field in the write stream. But it does not need to: the encoder's `STATE_DHDR` emits `D5 AA AD` followed by the 6-bit-encoded sector number ([`rtl/floppy_track_encoder.v:152-156`](rtl/floppy_track_encoder.v)), and the Mac writes the same header. Therefore:

- **sector** ← decoded from the incoming data-field header
- **track** ← `driveTrack` (the drive's own head position, authoritative)
- **side** ← `driveSide`

No rotational position, no index pulse, and no encoder-state snooping are required. Note the contrast with the UK101 rotational-timing work: there the fix *was* true rotational position; here, header-driven identification sidesteps the need for it entirely. The commented-out inter-sector gap in `STATE_WAIT` ([`rtl/floppy_track_encoder.v:349`](rtl/floppy_track_encoder.v)) is consequently harmless for writes, since framing is driven by `D5 AA AD` detection rather than by position.

**1.6 — No simulation infrastructure exists.** No testbenches, no Makefile, no Verilator setup. The floppy subsystem (`floppy.v`, `iwm.v`, `floppy_track_encoder.v`) is plain Verilog-2001, so Icarus Verilog or Verilator will handle it without the rest of the core.

---

## 2. Target architecture

```
Mac CPU ──write──► IWM writeData reg  ──► floppy.v write strobe (1 byte / 16 µs)
                        │                          │
              real _iwmBusy handshake              ▼
                                        floppy_track_decoder.v   (NEW)
                                        strip sync, find D5 AA AD,
                                        de-nibblize 6:2, verify checksum
                                                   │
                                                   ▼
                                        512-byte BRAM sector buffer
                                                   │
                              ┌────────────────────┴────────────────────┐
                              ▼                                          ▼
                  SDRAM image write-back                      HPS sd_wr → .dsk on SD
                  (free extra slot 3, 256 words)              (LBA = offset >> 9)
                  keeps read path coherent                    persistence
```

Two deliberate choices:

- **Buffer a whole sector in BRAM before committing.** Writing individual bytes into SDRAM would require byte-granular `sdram_ds` control during the extra slot, which the current mux does not provide (`_memoryUDS`/`_memoryLDS` are forced low outside `cpuBusControl`). Committing 256 full words instead sidesteps byte enables completely, gives a natural place to enforce "only commit on valid checksum", and produces exactly the 512-byte buffer the HPS `sd_buff` interface wants. 256 word-writes at one slot per 2 µs ≈ 512 µs — trivially within a sector time.
- **Write to both SDRAM and SD.** SDRAM keeps the in-memory image coherent so the Mac's read-after-write verify passes; the `sd_wr` makes it durable.

---

## 3. Phased plan

Each phase ends at a gate that can be evaluated on its own. Phases 1 and 3 are the two that can genuinely fail; they are deliberately separated so a failure in one does not confound the other.

### Phase 0 — Simulation harness and format ground truth
*No core changes.*

- Icarus/Verilator testbench driving `floppy_track_encoder.v` standalone, backed by a synthetic image.
- Dump the encoder's byte stream for representative tracks (0, 16, 40, 79; both sides).
- Write a reference decoder in Python/C and confirm it recovers the original 512-byte sectors and checksums.

**Gate:** reference decoder round-trips every sector of a synthetic 800K image byte-exactly. The GCR format is now pinned down by executable ground truth rather than by reading tables.

**Why first:** cheapest possible place to discover a misunderstanding of the 6:2 nibble scheme or the checksum chain.

**STATUS: GATE PASSED (2026-08-15).** Icarus Verilog testbench (`sim/tb_floppy_track_encoder.v`) drives the real `rtl/floppy_track_encoder.v` for tracks 0/16/40/79 × both sides on a synthetic 800K image (`sim/gen_image.py`, geometry formulas cross-checked against the RTL's own `soff`/`spt`). A cycle-accurate Python port (`sim/encoder_model.py`) matches the RTL byte-for-byte across all 8 combos, and a reference decoder (`sim/decode_track.py`), the algebraic inverse of that model, recovers all 84 sectors byte-exact and correctly rejects three corruption cases (`sim/test_negative.py`).

Two real bugs surfaced and got fixed along the way, both worth remembering for Phase 2:
1. **Testbench reset race:** deasserting `rst` on the same clock edge as the DUT's own `if(rst)` check races the DUT — Icarus resolved it in the "wrong" order, corrupting the very first cycle. Fix: deassert `rst` on a `negedge`, clear of any `posedge`.
2. **`ready` must be sparse, not continuous.** The encoder's `addr` register updates every `clk` cycle regardless of `ready`, and in real operation (`rtl/floppy.v`) `ready` only pulses once per ~128 clocks (`diskDataByteTimer`), giving `addr` ample idle time to settle before each fetch. An early testbench version held `ready` high every cycle, starving that settle time — the resulting artifact wasn't a crash, it silently produced a self-consistent but wrong byte stream (some source bytes read twice, others never read), which only surfaced as a checksum failure in the *decoder*, not in the encoder validation. Any Phase 2/3 testbench must pulse `ready` sparsely for the same reason.

A third, purely algorithmic bug (not a timing issue) was in the decoder itself: nib_xor_0/1/2 are registers, so a group's four output bytes (cnt=0,1,2,3) encode the *previous* group's three bytes in full — not a lookahead split across two groups, as first assumed. Fixed by decoding with a one-group lookback instead.

---

### Phase 1 — Convert floppies to block devices (still read-only)
*The riskiest plumbing change, isolated from any write behaviour.*

- CONF_STR: `F1`/`F2` → `S2,DSK,Mount Pri Floppy;` / `S3,DSK,Mount Sec Floppy;` (append as slots 2/3 so existing SCSI slots 0/1 and users' saved mounts are undisturbed).
- `VDNUM`: 2 → 4. Widen `sd_lba`/`sd_rd`/`sd_wr`/`sd_ack`/`sd_buff_din`/`img_mounted` and keep the SCSI wiring on indices 0/1.
- New mount-time loader FSM: on `img_mounted[2]`/`[3]`, stream the image via `sd_rd` into SDRAM at the existing `0x100000`/`0x200000` offsets (1600 × 512-byte blocks for an 800K image).
- Replace the download-end size latch ([`MacPlus.sv:604-628`](MacPlus.sv)) with `img_size`-derived single/double-sided detection, latched per slot at that slot's own mount pulse.
- Latch `img_readonly` per slot at its own mount pulse.
- Remove the now-dead floppy branches from the `dio_a` index mux; verify ROM download (index 0 and the bit-6 alt ROM) still works.

The per-slot latch-at-own-mount-pulse pattern is proven in the UK101 core (`VDNUM=5`, four drives) and should be copied rather than reinvented.

**Gate (hardware):** core boots from floppy exactly as before — both drives, 400K and 800K images, eject and remount, floppy + SCSI together. No write behaviour introduced. If this phase regresses anything, it is provably the plumbing and not the GCR work.

---

### Phase 2 — GCR decoder RTL
*New module, validated purely in simulation.*

`rtl/floppy_track_decoder.v`:
- skip self-sync `FF` bytes; detect `D5 AA AD`; decode the 6-bit sector number
- de-nibblize the 683-byte 6:2 data field back to 512 bytes
- run the C1/C2/C3 rotate-and-carry checksum chain in reverse and verify against the trailing 4-byte checksum
- reject on bad checksum, bad trailer (`DE AA`), or truncated field — never commit a partial sector
- reuse the existing `soff`/`spt` geometry math from the encoder for the byte offset

**Gate (sim):** RTL encoder → RTL decoder round-trip recovers every sector of a synthetic 800K image byte-exactly. Plus negative tests: corrupt one data byte, one checksum byte, and truncate a field — the decoder must reject all three and commit nothing.

RTL-to-RTL round-trip is worth insisting on over comparing against the Phase 0 model, because it proves consistency with the exact stream this core actually produces.

---

### Phase 3 — IWM write path, volatile writes only
*The "will the real Mac ROM cooperate" gate. Deliberately cannot touch the user's file.*

- Add `writeReq` / write-strobe / write-byte from `iwm.v` into `floppy.v` (derived from Q7 + drive enable).
- Implement a real `_iwmBusy`: assert busy on CPU write to the data register, clear after one byte time (128 `clk8`), mirroring the existing read-side `diskDataByteTimer`. Implement `_writeUnderrun` honestly.
- Unhardwire `WRTPRT`; drive it from a new OSD write-protect toggle **defaulting to protected**, ANDed with the latched `img_readonly`.
- Commit decoded sectors to the **SDRAM image only**. No `sd_wr` yet.

**Gate (hardware):** with a scratch disk unlocked, save a file from the Finder; confirm it reads back correctly, and that a directory listing survives a floppy eject/reinsert within the session. Reset the core — the change must be *gone*. That confirms writes are working end-to-end while proving no file was touched.

**This is the phase most likely to surprise.** The core models the drive as byte-synchronous (`newByteReady`), whereas real hardware is a self-clocking bit stream that the IWM frames itself. If the Mac ROM's timing-critical write loop does not tolerate the byte-synchronous simplification, the fallback is to model the write path at bit level — a significant escalation. Budget for the possibility; do not assume it.

---

### Phase 4 — Persistence to SD
- On a checksum-valid sector, raise `sd_wr` on the drive's slot with `LBA = image_byte_offset >> 9` and serve the buffer through `sd_buff_din`.
- Handle back-pressure and the `sd_ack` handshake; never drop a commit because the previous one is in flight.
- Respect `img_readonly` — refuse the `sd_wr` outright, do not merely hide the OSD toggle.

**Gate (hardware + host):** write, eject, remount → change persists. Then verify the `.dsk` on the PC: it opens in a Mac emulator, and a byte-level diff against the pre-write image shows *only* the intended sectors changed. The diff is the important half — it catches a wrong-LBA bug that a "it still boots" test would miss.

---

### Phase 5 — Hardening and parity
- Both drives at full parity (external drive is a second `floppy` instance).
- 400K single-sided write path (different `sides` geometry through `soff`).
- Correct behaviour on eject mid-write, and on write with no disk inserted.
- `SWITCHED` / disk-switched flag, currently hardwired to `1'b0` ([`rtl/floppy.v:114`](rtl/floppy.v)).
- Stress: copy a multi-megabyte set of files floppy→floppy and floppy→SCSI; System 6.0.8 installer writing to floppy; Finder duplicate/trash cycles.
- Update `readme.md` (it currently states floppies are not writable) and re-check the 16 MHz caveat, which may interact badly with write timing.

---

### Phase 6 — Formatting (explicitly deferred)
Low-level format / "Erase Disk" requires writing complete tracks *including address fields*, with correct sync gaps and interleave across all 80 tracks. It is a materially harder problem than sector writes and is not needed to edit files on an already-formatted disk. Recommend shipping Phases 1–5 first and treating format as a separate project. If attempted, the currently commented-out inter-sector gap in `STATE_WAIT` will need to become real.

---

## 4. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Byte-synchronous drive model can't satisfy the ROM's write loop timing | **Medium** (was High) — see §7; a proven bit-level reference now exists | Phase 3 gate exposes it before any file is at risk; fall back to porting `iwm_flux.v`'s handshake |
| Wrong LBA / geometry math corrupts a `.dsk` | High | Byte-level host diff in Phase 4; write-protect defaults on |
| Block-device conversion regresses booting | Medium | Phase 1 is standalone and read-only; UK101 precedent to copy |
| `sd_wr` back-pressure drops a sector commit | Medium | Explicit handshake FSM; stress test in Phase 5 |
| Mac writes multiple sectors back-to-back faster than write-back drains | Medium | 512 µs commit vs ~16 ms sector spacing gives large margin; verify in sim |
| `SC0`/`S` CONF_STR flag semantics differ from assumption | Low | Verify against Main_MiSTer framework source before Phase 1 |

**Safety posture:** write-protect defaults to ON at every stage; Phase 3 is structurally incapable of writing to the SD card; Phase 4 is not attempted until Phase 3 has been demonstrated on hardware. Test only against copies of disk images throughout.

---

## 5. Effort

| Phase | Estimate |
|---|---|
| 0 — Sim harness | 2–3 days |
| 1 — Block-device conversion | 3–5 days |
| 2 — GCR decoder + round-trip sim | 4–6 days |
| 3 — IWM write path, volatile | 3–5 days *(contingency largely removed — see §7)* |
| 4 — SD persistence | 2–3 days |
| 5 — Hardening | 4–6 days |
| **Total (Phases 0–5)** | **≈ 3–4 weeks** |
| 6 — Formatting (deferred) | +1–2 weeks |

Estimates assume the existing working rhythm of simulate-then-flash, and include Quartus compile turnaround but not extended forum-based field testing. Revised down from 4–5 weeks after surveying the Apple IIgs core (§7); the *worst case* shrinks considerably more than the expected case, because the main tail risk now has a working reference implementation.

---

## 7. Reusable prior art: Apple-IIgs_MiSTer

`github.com/MiSTer-devel/Apple-IIgs_MiSTer` has full floppy read/write with SD write-back, on the same IWM and the same Sony 800K GCR format. Surveyed at commit tip; local clone in scratchpad. It helps, but not in the way one would first assume.

### It has two floppy paths, and neither does what we need

| Path | Image format | How writes work | GCR decode needed? |
|---|---|---|---|
| Flux (`iwm_flux.v`, `flux_drive.v`, `woz_floppy_controller.sv`) | `.woz` | Bit-level read-modify-write into a per-track BRAM buffer; dirty tracks flushed back to the file | **No** — the file format *is* the bitstream |
| SmartPort (`smartport_dev.v`, instantiated inside `iwm_woz.v`) | `.po`, `.2mg` | Emulates the Apple 3.5″ drive's internal microcontroller and serves 512-byte blocks over the IWM bus | **No** — bypasses GCR entirely |

**Neither path ever decodes a GCR data field back into 512-byte sectors.** That is precisely the combination MacPlus requires: GCR-*encoded* reads from a sector image plus decode-on-write back to that same sector image. The IIgs escapes it twice over — once by storing bitstreams, once by having a smart drive with a block protocol. The Mac's `.Sony` driver talks to a *dumb* drive at GCR level and has no block-level escape hatch (on a Mac Plus that hatch is SCSI, already implemented).

**So Phase 2 survives essentially intact.** The data-field de-nibblization and reverse checksum chain remain ours to write.

### What is directly reusable (all GPLv3 — see below)

1. **`iwm_flux.v` write handshake** — a real `m_whd` handshake register (MAME-derived, init `0xBF`), an underrun counter, and an explicit `SW_UNDERRUN` state, including the subtlety of holding the handshake not-ready until the backend has actually taken the byte. This is a working answer to the exact question Phase 3 asks, and it is why that risk drops from High to Medium.
2. **`flux_drive.v` write logic** — bit-level RMW into a track buffer, with source comments documenting latching bugs (`bit_shift` and BRAM address must be latched at read time) that they already paid for. Worth reading before writing our own.
3. **`woz_floppy_controller.sv` flush architecture** — per-side dirty flags, flush on track seek / motor-off / ~500 ms idle timer, and a careful `sd_rd`/`sd_wr` handshake (`transfer_active` / `request_issued`). **This is a better design than the per-sector commit in §2** and should replace it: commit whole dirty tracks on seek rather than sectors on checksum.
4. **The reverse GCR table** — `gcr_6_2_decode` at [`rtl/iwm_flux.v:2188`](rtl/iwm_flux.v) is the exact inverse of our `sony_to_disk_byte` table (`96`→`00`, `97`→`01`, `9A`→`02`, …). Directly liftable; a transcription typo here would otherwise cost real debugging time.
5. **Their Verilator harness (`vsim/`)** — screenshots at chosen frames, scripted key injection, bounded VCD capture. MacPlus has no simulation at all. As a template for Phase 0 this may be worth more than any of the RTL.

### Strategic options this opens

- **A — Keep the current plan, borrow components.** Lift the reverse table, model the IWM handshake on `iwm_flux.v`, adopt track-level dirty/flush instead of per-sector commit. Lowest risk; saves ~1 week and most of the Phase 3 tail.
- **B — Adopt the flux/track-buffer architecture wholesale.** On mount, GCR-encode the whole `.dsk` into per-track bitstreams (we already own the encoder — it just runs on the fly today instead of into a buffer); serve reads from the buffer; writes do bit-level RMW; decode dirty tracks back to sectors on seek. More work up front, materially more accurate, and the only route that later enables copy-protected Mac disks. **Still needs the decoder.**
- **C — Support `.woz` for Mac disks.** WOZ 2.x covers 3.5″ (`disk_type 2`) and Applesauce images Mac 400K/800K. A bitstream image needs **no decoder at all**, genuinely eliminating Phase 2 — but it changes what users must supply, and Mac `.woz` images are rare against the enormous `.dsk` library. Sensible as an *additional* format later, not as the v1 answer.

Recommendation: **A now, with B's flush architecture folded in**, leaving C as a follow-on.

### Licensing — resolve before copying any code

Apple-IIgs_MiSTer is **GPLv3** (`LICENSE` at repo root). **MacPlus_MiSTer has no LICENSE file at all** — it descends from Plus Too via the MiST `plus_too` port, with licensing stated only informally. Copying GPLv3 RTL in makes the combined work GPLv3 and requires attribution plus a license file.

This needs sorting out *before* code is lifted, not after, particularly given the intent to publish upstream to MiSTer-devel. Reimplementing from the *documented format* (rather than from their source) is the alternative if the licensing can't be settled — the reverse GCR table in particular is a published Apple format, not their invention, so it can be regenerated from the encoder table we already have.

---

## 6. Build notes

New RTL modules must be registered in `files.qip`:

```
set_global_assignment -name VERILOG_FILE rtl/floppy_track_decoder.v
```

Per standing rule: no merge to `master` and no full Quartus compile without asking first.
