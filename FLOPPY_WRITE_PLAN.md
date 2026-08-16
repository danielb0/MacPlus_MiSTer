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

**STATUS: RTL COMPLETE, ELABORATION CLEAN (2026-08-15), hardware gate not yet run.**
New `rtl/floppy_loader.v` (one instance per floppy, `ldr_int`/`ldr_ext` in `MacPlus.sv`): on its slot's `img_mounted` pulse, streams the whole image in via `sd_rd`, sector by sector, staging each 512-byte sector in a small local BRAM (`sd_buff_wr` has no rate limit against on-chip RAM) then draining it out to SDRAM one word at a time through `addrController_top.v`'s previously-unused extra slot 3 (recurs every ~2us — the drain, not the SD transfer, is the slow half of a mount; a 1600-sector 800K image is on the order of a second, correctness-first for Phase 1, not optimized). Drains to the exact same byte offsets (`0x100000`/`0x200000`) the read side already expects, so `floppy.v`/`floppy_track_encoder.v` are untouched.

`insertDisk` (via `dsk_int_ds`/`dsk_int_ss`/etc.) now only goes true on the loader's `done` pulse — i.e. once the whole image is resident — never at the bare mount pulse, so the Mac can never observe a partially-loaded disk; this replaces the old `old_down && ~dio_download` end-of-download latch, with size detection now reading the loader's own latched `img_size` instead of a word-address counter. Also added clear-on-mount (drop `insertDisk` immediately on a fresh mount pulse, before the reload completes), mirroring the SAVE-feature precedent in the UK101 core ([[project-uk101-save-feature]]).

`addrController_top.v` gained a fixed-priority (int-over-ext) arbiter for the shared slot-3 write port (`dskLoadAddrInt/Ext`, `dskLoadReqInt/Ext`, `dskLoadAckInt/Ext`, `dskLoadWrEn`) — address/control only, matching the existing `dskReadAddr*/dskReadAck*` read-side split; `MacPlus.sv` muxes the actual write word using the same ack pulses. `CONF_STR` converted `F1`/`F2` to `S2,DSK,...`/`S3,DSK,...`; `VDNUM` raised 2→4; SCSI (`dataController_top`) still only ever sees a narrowed 2-wide view of the shared arrays (via intermediate `scsi_sd_*` wires — Verilog can't port-slice an unpacked array, so each consumer indexes the shared arrays itself, the same pattern UK101.sv uses per-drive). `img_readonly` is now wired top-to-bottom and latched per-slot (`readonly_latched`) for Phase 3/4 to consume — currently an intentionally-dangling output (confirmed Info-level only in the elaboration connectivity report, not a warning).

Verified via `quartus_map --analysis_and_elaboration`: 0 errors, 20 warnings (all pre-existing/unrelated — `scc.v`/`rxuart.v`/`txuart.v` truncation and unused-signal warnings that predate this change). The only connectivity notes touching new code are Info-level "dangling logic" on `readonly_latched` (expected — unused until Phase 3/4) and a pre-existing `configRAMSize[1]` stuck-at note on `addrController_top` unrelated to this work.

**Full compile completed (2026-08-15, user go-ahead given): 0 errors, 57 warnings, timing met** (setup slack 0.565ns, hold slack 0.246ns). The only warning touching this session's files (`serialCTS` unconnected, `MacPlus.sv:255`) predates this change (commented-out serial port block). `buf_mem` in `floppy_loader.v` correctly inferred as `altsyncram` block RAM (confirmed in the fitter report), not fanned-out logic — the exact trap flagged in the UK101 disk_reader.sv precedent for a two-port BRAM array. Resource usage: 14,884/41,910 ALMs (36%), 452,549/5,662,720 block memory bits (8%) — no blowup. Output: `output_files/MacPlus.rbf`/`.sof`.

**HARDWARE GATE FAILED, then ROOT-CAUSED (2026-08-15).** Every mounted image read as "damaged / not a Macintosh disk", both sizes, both drives, several System versions, while the activity light showed the load running to completion. Not a byte-order problem (the swap in `floppy_loader.v` is correct — it matches what the ROM-download path did, and both derivations of it agree). The bug was in the **slot-3 write handshake vs. `sdram.v`'s two-phase sampling**:

`sdram.v` does not latch a memory cycle in one shot. It issues `ACTIVE` — row, bank, and the `oe`/`we` decision — from the signals present during `busPhase 0`, and `WRITE` — **column address and write data** — from the signals present one `clk_sys` cycle later, during `busPhase 1`. Every memory control signal must therefore hold for the whole four-phase bus cycle. That is exactly why the ROM download path only ever changes `dio_write` while `~dioBusControl`, and why `dskReadAckInt/Ext` are asserted for a whole bus cycle instead of pulsed.

The Phase 1 arbiter instead made `dskLoadGrant` (and hence `dskLoadAckInt/Ext`, `dskLoadWrEn`, and the `memoryAddr` mux) purely combinational on `dskLoadReq*`. The loader sampled its ack at the end of `busPhase 0` and dropped `wr_req` at the start of `busPhase 1` — after RAS had already committed to performing a write, but before CAS sampled the column and the data. So every word was written to the **correct row and bank but the wrong column, with `memoryDataOut` (CPU bus contents) instead of the disk byte**. Confirmed in sim: the whole image region ends up junk-at-column-0 plus never-written words. (The combinational grant also fired a *second* time in `busPhase 3` of the same window, so the loader consumed two words per slot and both were lost.)

Fix (`addrController_top.v`): sample `dskLoadReq*` once at the bus-cycle boundary (`busPhase == 2'b11`), hold the grant for the entire cycle, and make the ack a late pulse in `busPhase 3` so the loader cannot tear its request down before CAS. One word per slot-3 window; ~0.8s for an 800K image.

Why sim missed it: both testbenches modelled SDRAM as a single-cycle latch off `dskLoadAckInt`. `sim/tb_floppy_loader_integrated.v` now replicates `MacPlus.sv`'s `sdram_addr`/`sdram_din`/`sdram_we` muxes and `sdram.v`'s real RAS-at-phase-0 / CAS-at-phase-1 sampling (including the `bank=addr[21:20]`, `row=addr[19:8]`, `col={addr[22],addr[7:0]}` split), and counts stray out-of-region writes. It **fails on the pre-fix arbiter and passes on the fixed one** — the diagnosis is demonstrated, not asserted.

**Re-compiled 2026-08-15 (user gave explicit go-ahead): 0 errors, 57 warnings, timing met** (setup slack 0.386ns, hold slack 0.247ns), 35% ALMs / 8% block memory — no regression from the pre-fix compile.

**Hardware retest: drive 1 (int) works, drive 2 (ext) still fails, 2026-08-15.** SECOND bug, same root cause class, in the code the first fix didn't touch: `MacPlus.sv`'s `loader_wr_data` mux —

```verilog
wire [15:0] loader_wr_data = ldr_ext_wr_ack ? ldr_ext_wr_data : ldr_int_wr_data;
```

— selected which loader's write data reaches SDRAM using `ldr_ext_wr_ack` (`dskLoadAckExt`), which is a late pulse asserted only in busPhase 3. sdram.v's CAS phase (busPhase 1, one phase earlier) is what actually latches `din`. So at the instant that mattered, `ldr_ext_wr_ack` was always 0, and the mux always fell through to `ldr_int_wr_data` — drive 1 "worked" only because it was the ternary's default branch; drive 2 always wrote int's (idle/stale) data instead of its own. The first fix (addrController_top.v's arbiter) got the *address* selection right via an internal `dskLoadSelExt` signal, but never exposed it — so MacPlus.sv's *data* selection was still keyed off the wrong (pulse) signal.

**Fix (2026-08-15):** exposed `dskLoadSelExt` as a new `addrController_top.v` output (held for the whole grant cycle, unlike the ack pulses), wired it into `MacPlus.sv`, and changed the mux to `dskLoadSelExt ? ldr_ext_wr_data : ldr_int_wr_data`. New sim `sim/tb_floppy_loader_ext.v` reproduces MacPlus.sv's dual-loader wiring (both `floppy_loader` instances, real fixed mux formula), mounts only the ext image, and PASSES byte-exact; `tb_floppy_loader_integrated.v` (int path) re-verified still PASSES after the port addition. Neither prior testbench could have caught this — both drove only one loader, so the inter-loader data-selection mux was never exercised in sim.

**Re-compiled 2026-08-15 (user gave explicit go-ahead): 0 errors, 57 warnings, timing met** (setup slack 0.585ns, hold slack 0.245ns), 36% ALMs / 8% block memory — no regression from either fix.

**Not yet done:** re-run the hardware gate on both drives (400K/800K, eject/remount, floppy+SCSI together) — needs the user to flash and test on real MiSTer hardware.

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

**DONE, gate passed (2026-08-15).** `rtl/floppy_track_decoder.v` is a direct RTL port of the Phase 0 reference decoder (`sim/decode_track.py`), including its one-group-lookback subtlety. The reverse GCR table was generated mechanically from `sim/gcr_common.py`'s `REVERSE_SONY_TABLE` (never hand-transcribed). New testbench `sim/tb_floppy_track_decoder.v` wires the RTL encoder directly into the RTL decoder and validates all 8 (track, side) combinations Phase 0 used (0/16/40/79 × both sides) byte-exact, plus the same three negative-test cases as `sim/test_negative.py` (corrupt data byte, corrupt checksum byte, truncated field) — all reject cleanly, never asserting `sector_valid`.

One non-obvious bring-up issue, worth remembering for any future testbench on this core: this Icarus Verilog build does not reliably hold a registered pulse output (`sector_valid`/`reject`) stable if the testbench executes a further blocking assignment to an unrelated signal (here, `ready`) in the same simulation timestep before reading it — confirmed via `$strobe` and a minimal repro. Sampling the pulse immediately after `@(posedge clk)`, before touching anything else, is reliable; a `#1`-delayed read after other statements is not. This wasn't caught by the Phase 0 encoder testbench because it only ever read a combinational output (`odata`), which is immune (recomputing from stable state always gives the same answer regardless of extra delta-cycle re-evaluation). `tb_floppy_track_decoder.v` captures the pulse into a testbench reg at the correct moment instead of re-reading the DUT's live signal later.

---

### Phase 3 — IWM write path, volatile writes only
*The "will the real Mac ROM cooperate" gate. Deliberately cannot touch the user's file.*

- Add `writeReq` / write-strobe / write-byte from `iwm.v` into `floppy.v` (derived from Q7 + drive enable).
- Implement a real `_iwmBusy`: assert busy on CPU write to the data register, clear after one byte time (128 `clk8`), mirroring the existing read-side `diskDataByteTimer`. Implement `_writeUnderrun` honestly.
- Unhardwire `WRTPRT`; drive it from a new OSD write-protect toggle **defaulting to protected**, ANDed with the latched `img_readonly`.
- Commit decoded sectors to the **SDRAM image only**. No `sd_wr` yet.

**Gate (hardware):** with a scratch disk unlocked, save a file from the Finder; confirm it reads back correctly, and that a directory listing survives a floppy eject/reinsert within the session. Reset the core — the change must be *gone*. That confirms writes are working end-to-end while proving no file was touched.

**This is the phase most likely to surprise.** The core models the drive as byte-synchronous (`newByteReady`), whereas real hardware is a self-clocking bit stream that the IWM frames itself. If the Mac ROM's timing-critical write loop does not tolerate the byte-synchronous simplification, the fallback is to model the write path at bit level — a significant escalation. Budget for the possibility; do not assume it.

**STATUS: RTL COMPLETE, SIM GATE PASSED (2026-08-15), hardware gate not yet run.**

New `rtl/floppy_write_committer.v` (twin of `floppy_loader.v`'s drain FSM, run in reverse): drains a checksum-valid sector out of `floppy_track_decoder.v`'s byte-addressed `buf_mem` into SDRAM over the same shared extra-slot-3 port, two address-settle cycles per word (FETCH_LO/FETCH_HI, since the decoder's read port is single-port unlike the loader's pre-staged BRAM) then a WAIT for `wr_ack`. `floppy.v` gained a byte-timer/busy/underrun state machine that paces CPU-supplied bytes at the same 128-clk8 (16us) cadence as the existing read-side `diskDataByteTimer`, then hands each byte to a `floppy_track_decoder` instance (previously sim-only from Phase 2 — this is its first time being wired into synthesizable top-level RTL and registered in `files.qip`) feeding the new committer. `WRTPRT` is unhardwired to `~writeProtect`; `writeProtect` is computed in `MacPlus.sv` as `~status[6] | <drive>_readonly` (OSD bit 6, "Floppy Write", defaults to protected) per drive, so a read-only-mounted image stays locked regardless of the OSD toggle.

`iwm.v` generates `writeReqInt`/`writeReqExt` from the exact same CPU-write condition that used to load its own (now-removed) `writeData` register, gated by `selectExternalDriveNext` to route to the correct drive; `_iwmBusy`/`_writeUnderrun` are now genuinely muxed per selected drive instead of hardwired to 1. `floppy.v`'s `writeData` port is fed `dataInLo` directly rather than through a register — `writeReqInt`/`Ext` and a register load from `dataInLo` would both fire on the same `cen` edge, and since nonblocking assignments only see pre-edge values, reading a registered copy would have been one cycle (one byte) stale; caught in sim before it ever reached hardware.

`MacPlus.sv`'s extra-slot-3 port is now shared three ways per drive: `floppy_loader` (Phase 1, mount-time) and the new per-drive `floppy_write_committer` both present a request to `addrController_top.v`'s existing (hardware-proven, untouched) int/ext arbiter through a per-side combining mux, loader given fixed priority — mount and write-commit contending for the same side is a rare corner case, never a steady-state one, and `addrController_top.v` itself needed no changes.

`writeUnderrun` is a real, driven signal, not another hardwired constant, but honesty has a limit in a byte-synchronous replica: the only condition this model can detect is the drive being deselected/disabled with a byte still in flight (abandoned mid-timer). A true "CPU took too long to supply the next byte" underrun has no independent clock to check against here — the same idealization the read side already accepts via `advanceDriveHead`.

New testbench `sim/tb_floppy_write_path.v` drives `floppy.v` directly the way `iwm.v` would (`writeReq`/`writeData` pulses, `writeBusy` honored between bytes, the real 128-cycle-per-byte timer run in full — not shortened for sim, since it's intrinsic to the RTL under test), replaying one sector's worth of ground-truth GCR bytes extracted from the real RTL encoder. Three cases: a normal write round-trips byte-exact into a mocked SDRAM model; a write-protected drive never asserts `writeBusy` for a single byte; a mid-byte drive-deselect abandons the write and asserts `writeUnderrun`. All three passed after finding and fixing one real bug: the committer's FETCH_LO/FETCH_HI/ASSERT sequence sampled `buf_data` one state too late (capturing the byte that belonged to the state driving `buf_addr` *after* the intended settle cycle, not during it), silently swapping every byte pair in every committed word — caught because the round-trip test compared against the original plaintext image rather than trusting the write path's own output. Fixed by having each FETCH state capture the byte its own cycle's (already-settled) `buf_addr` exposed, which also let the separate ASSERT state be dropped (4 states instead of 5). Elaboration and all prior-phase testbenches (encoder, decoder, both loader variants) re-verified clean after the fix: `quartus_map --analysis_and_elaboration` 0 errors, 20 warnings (same pre-existing baseline as Phase 1) — the only connectivity notes touching new code are Info-level (`wc.busy`/`wc.done` explicitly unconnected, `dec.sector`/`dec.reject` dangling, matching Phase 2's own precedent).

**Full compile completed (2026-08-15, user gave explicit go-ahead): 0 errors, 57 warnings, timing met** (min setup slack 0.471ns, min hold slack 0.246ns) — but Logic utilization came in at **27,802/41,910 ALMs (66%)**, roughly double Phase 1's 36% baseline, with block memory bits unchanged at 8%. Root-caused: `floppy_track_decoder.v`'s `buf_mem` (512x8) never gets inferred as a Cyclone V M10K at all — Quartus builds it out of ~6,470 ALMs *per drive instance* (512 registers + per-byte select muxes) instead. First hypothesis (the read port being combinational/async instead of registered) was real but insufficient — fixed it anyway (now `always @(posedge clk) buf_data <= buf_mem[buf_addr];`, matching `floppy_loader.v`'s `buf_rd` idiom, `floppy_write_committer.v`'s FETCH_LO/FETCH_HI/ASSERT states reverted to account for the 1-cycle read latency this restores) but a recompile showed **no change** (27,845 ALMs, still 66%) — because the actual blocker is upstream: **the decoder writes up to three different `buf_mem` addresses in the same clock edge** (`buf_mem[recovered_count]`, `[+1]`, `[+2]` when a group completes with `has_s3`), and no Cyclone V memory primitive supports three independent write ports in one cycle, so Quartus never attempts RAM inference here at all (no diagnostic - it just silently falls through to registers). A real fix needs the group-completion write spread across at most one `buf_mem` address per cycle (a couple of extra internal cycles per group, harmless against the 128-clk8-per-byte real pacing budget) - but that touches the same checksum-chain-adjacent logic that took real care to get right in Phase 0/2, so it needs its own sim-verify pass before being trusted. **User decision (2026-08-15): defer this optimization, proceed to the hardware gate on the current 66%-ALM build** (still compiles clean with solid timing margin, purely a resource-efficiency issue, not a correctness one). Follow-up work item: restructure `floppy_track_decoder.v`'s `S_GRP` completion to commit one byte per cycle so `buf_mem` maps to a real M10K.

**HARDWARE GATE: PARTIAL (2026-08-15).** Two symptoms from the user's first test, session ended before investigating either:

1. **Directory entry created but no content.** Saving a small MacPaint file from Finder shows up in the disk's directory/catalog (allocated as 4K, matching a real minimum-allocation-block file) but the file's actual data appears empty when read back. Reads as: the directory/catalog write succeeded (or at least the volume structure update did) but the file's own data-fork sector(s) did not actually commit correctly - or `sector_valid`/the committer never fired for those particular sectors while it did for whatever sector(s) the directory update touches. Needs figuring out which specific sector(s) Finder is writing for a save (directory block vs. data block vs. volume bitmap) and checking whether `floppy_track_decoder`'s `sector_valid`/`reject` fired for each.

2. **Does not survive eject/reinsert.** This contradicts the Phase 3 gate's own expectation (SDRAM-resident writes should survive an eject/reinsert within the same session, only a core reset should wipe them - see the gate definition above). Suspect the mount-time `floppy_loader` path: `insertDisk` has a "clear-on-mount" step (drops `insertDisk` immediately on a fresh mount pulse, from Phase 1) and re-streams the WHOLE image back in from the SD card on every mount/remount pulse - if eject+reinsert re-triggers `img_mounted`, the loader would reload the pristine on-disk image from SD, overwriting whatever the write path had committed into SDRAM in the interim. That would exactly explain "doesn't survive dismounting" while being consistent with "resets wipe it" (same mechanism, just triggered by eject/reinsert too, which per Phase 1's design was always going to re-run the loader - the plan's Phase 3 gate wording may have been wrong to expect otherwise, OR eject/reinsert isn't supposed to force a full reload and something in the eject handling is wrong). Needs re-reading `floppy_loader.v`'s `img_mounted`/`mount_pending` logic and `MacPlus.sv`'s `insertDisk`/`diskEject` wiring together before assuming which side is at fault.

Both are open for next session. Start by re-reading this block plus `rtl/floppy_loader.v` and the `insertDisk`/`dsk_int_ds` logic in `MacPlus.sv` (search "clear-on-mount") before making changes.

**ROOT CAUSE FOUND AND FIXED (2026-08-15): both symptoms above were red herrings.** Neither the directory-vs-data-block theory nor the `floppy_loader` reload theory was the bug — no sector write had *ever* committed, for any file, at all, so of course eject/reinsert "loses" nothing (there was nothing in SDRAM to lose) and of course a save shows an allocated-but-empty file (the catalog write and the data write are both real GCR data fields, and both were being rejected identically). `floppy_track_decoder.v`'s `S_DZRO` state treated the data field's 12-byte Sony **tag** — real metadata the Mac's disk driver writes with every sector, part of the same continuous checksummed 6:2 nibble stream as the following 512 data bytes — as if it were a literal 12×`0x96` sync run. That assumption happened to hold for this core's own read-side encoder (`floppy_track_encoder.v`'s `STATE_DZRO`), which fakes an all-zero tag and takes exactly that shortcut, but a real Mac write puts genuine (non-zero) content there, so `S_DZRO` rejected every real write on its first tag byte.

Fix (`rtl/floppy_track_decoder.v`): removed `S_DZRO`; `S_GRP` now decodes one continuous 524-byte tag(12)+data(512) stream directly — group *g* recovers payload bytes `3g..3g+2` with no lookback and no discarded group (175 groups instead of 171, 699 raw bytes instead of 687+12 — exactly what `floppy_track_encoder.v`'s existing `DZRO+DPRE+DATA` region already emits, no format change on the read/encode side needed at all) — discarding the first 12 recovered bytes and committing only the 512 sector-data bytes to `buf_mem`. (A first attempt at this fix wrongly kept the *original* Phase 2 decoder's "one-group lookback, group 0 discarded" mechanism, extended to 176 groups / 703 bytes; that passed its own self-consistency tests but could not decode the real encoder's actual output at all. Re-derived and corrected before landing — see [[project-macplus-floppy-write]] memory for the full story if this ever needs re-deriving again.)

Verified three ways: `sim/gen_write_stream.py` builds real (non-zero-tag) GCR data fields as the direct algebraic inverse of the RTL's own `S_GRP` equations (cross-checked byte-exact by decoding its own output before ever touching Verilog); `sim/tb_floppy_write_stream.v` feeds those straight into `floppy_track_decoder.v` — both an all-zero tag and a real non-trivial tag recover the correct 512 bytes, tag correctly discarded, and the existing corrupt-byte/corrupt-checksum/truncation rejection cases still hold; and — the strongest check — `sim/tb_floppy_track_decoder.v`'s **original, unmodified** Phase 2 round-trip gate (RTL encoder → RTL decoder, all 8 track/side combos + all 3 negative cases) **still passes exactly as it did before this fix**, because the fixed decoder's 699-byte requirement is precisely what the encoder's all-zero-tag shortcut already produces (zero tag content, not a shorter format). `sim/tb_floppy_write_path.v` (full `floppy.v` write-path integration: byte-timer/busy handshake → decoder → committer → mocked SDRAM) re-pointed at a real-tag field from the new generator (the RTL encoder can never produce one — its `STATE_DZRO` is hardcoded to an all-zero tag) and passes end-to-end.

**SIM GATE: PASS (2026-08-15).**

**HARDWARE GATE: PASS (2026-08-15, re-test after the tag-decode fix).** Full compile: 0 errors, 57 warnings, timing met (setup slack 0.617ns, hold slack 0.245ns); 29,189/41,910 ALMs (70%, up from 66% pre-fix — the tag-discard logic added a modest amount, the still-deferred `buf_mem` M10K-inference issue is unchanged). User confirmed: read and write both work on 400K and 800K diskettes, on both drives; compiled and ran a program from UCSD BASIC, i.e. a real write-then-execute round trip, not just a Finder save. **Phase 3 is done.**

### `buf_mem` M10K-inference follow-up — DONE (2026-08-16)

The deferred resource item above is fixed. `floppy_track_decoder.v`'s `S_GRP` group-completion no longer writes up to three `buf_mem` addresses in one clock edge; it latches the (up to 3) pending writes into new `commit_v0/v1/v2`/`commit_a0/a1/a2`/`commit_d0/d1/d2` registers and hands off to a new state, `S_GRPC`, which drains them one write per cycle (3-step `commit_step` counter), then resumes `S_GRP` or `S_DSUM`. `S_GRPC` runs unconditionally every clock (not gated on `ready`), which is safe because `ready` pulses only once per ~128 `clk8` cycles (one incoming disk byte / 16 µs) — comfortably more than the fixed 3-cycle drain.

All four existing testbenches (`tb_floppy_track_decoder.v`, `tb_floppy_write_stream.v`, `tb_floppy_write_path.v`, `tb_floppy_track_encoder.v`) pass **unmodified** — this is a synthesis-timing restructure, not a decode-logic change. `quartus_map --analysis_and_elaboration`: 0 errors, 20 warnings (same baseline).

**Full compile confirms the fix**: 0 errors, 57 warnings (same set), timing met (setup 0.539ns, hold 0.200ns). **ALMs: 15,296/41,910 (36%), down from 29,189/41,910 (70%)** — back to essentially the Phase 1 baseline. `MacPlus.map.rpt` confirms `floppy_track_decoder:dec|altsyncram:buf_mem_rtl_0` is now a real `ALTSYNCRAM` (Simple Dual Port, 512×8) for both `floppyInt` and `floppyExt`.

**HARDWARE RETEST: PASS (2026-08-16).** User confirmed read/write still work as before after reflashing — no regression from the timing restructure. Not yet committed.

---

### Phase 4 — Persistence to SD
- On a checksum-valid sector, raise `sd_wr` on the drive's slot with `LBA = image_byte_offset >> 9` and serve the buffer through `sd_buff_din`.
- Handle back-pressure and the `sd_ack` handshake; never drop a commit because the previous one is in flight.
- Respect `img_readonly` — refuse the `sd_wr` outright, do not merely hide the OSD toggle.

**Gate (hardware + host):** write, eject, remount → change persists. Then verify the `.dsk` on the PC: it opens in a Mac emulator, and a byte-level diff against the pre-write image shows *only* the intended sectors changed. The diff is the important half — it catches a wrong-LBA bug that a "it still boots" test would miss.

**STATUS: RTL COMPLETE, SIM GATE PASSED (2026-08-16), hardware gate not yet run.**

New `rtl/floppy_sd_writer.v` (one instance per drive, `wr_int`/`wr_ext` in `MacPlus.sv`): taps `floppy_write_committer.v`'s existing ASSERT-state word stream (new `committed_addr`/`sd_buf_addr`/`sd_buf_data`/`sd_buf_wr` outputs on that module, threaded through as `dskCommit*` ports on `floppy.v` → `iwm.v` → `dataController_top.sv` → `MacPlus.sv`, mirroring the established `dskWrite*` pass-through pattern) into a local 256×16 shadow sector buffer, byte-for-byte identical to what just landed in SDRAM — no second read of the decoder's single-read-port `buf_mem` is needed. On `commit_done`, asserts `sd_wr` with `sd_lba = committed_addr[21:9]` and serves `sd_buff_din` from the shadow buffer, addressed by the HPS-driven shared `sd_buff_addr` bus. The handshake (drop `sd_wr` as soon as `sd_ack` rises, wait for `sd_ack` to fall before considering the sector durably handed off) is modelled on `scsi.v`'s proven `io_wr`/`io_ack` pattern - the only other `sd_wr` producer already working on this core - rather than invented from the protocol spec.

Back-pressure: a **depth-2 queue** (two independent shadow buffers, ping-ponged by a `tail` pointer on capture and drained in order via a `head` pointer) absorbs a second `commit_done` landing before the first has finished persisting to SD - satisfying "never drop a commit because the previous one is in flight" for the realistic single-overlap case. A third overlapping commit (arriving before either of the previous two has drained) has nowhere new to go and reuses a still-in-flight buffer; this is a documented, not-expected-in-practice limit rather than a silently-corrupting one (see the module's header comment for the timing margin this relies on - the CPU-facing write path can only produce a `commit_done` roughly once per ~10ms+ of 16us-paced IWM bytes, comfortably longer than a real `sd_wr` transfer), the same class of idealization `writeUnderrun` and the committer's own single-sector-in-flight assumption already accept elsewhere in this write path.

`sd_lba[2]`/`[3]` and `sd_wr[2]`/`[3]` are shared per slot between `floppy_loader` (Phase 1, mount-time `sd_rd`) and the new `floppy_sd_writer` (`sd_wr`): the writer's own `P_IDLE` state stalls (without losing the queued entry) while `loader_busy` is asserted, and `sd_lba` is muxed on `ldr_*_busy` - loader wins whenever it's active, mirroring the fixed-priority precedent already used for the shared extra-slot-3 SDRAM port. `sd_buff_din[2]`/`[3]` (hardwired to `16'h0` since Phase 1, "floppy loaders never sd_wr") now come from each writer's shadow buffer.

New testbench `sim/tb_floppy_sd_writer.v` drives `floppy_sd_writer.v` directly with synthetic `commit_*` taps (mimicking `floppy_write_committer`'s own ASSERT-state pattern) and mocks hps_io's `sd_wr`/`sd_ack`/`sd_buff_addr` protocol the way `scsi.v` is actually served on hardware. Three cases: a single commit persists byte-exact at the computed LBA; two commits landing back-to-back (before the first has even started draining) both survive via the depth-2 queue and drain in order; a read-only drive never asserts `sd_wr`. All three passed after finding and fixing one real bug: the first testbench draft updated `commit_buf_addr`/`commit_buf_data`/`sd_buff_addr` with zero delay immediately after `@(posedge clk)`, racing the DUT's own `always @(posedge clk)` blocks sampling those same signals in the same timestep - Icarus resolved the race inconsistently (sometimes stale, sometimes fresh), silently dropping every other word. This is the same class of hazard as the Phase 0 reset-race lesson; fixed by adding `#1` after every `@(posedge clk)` before driving DUT inputs, so testbench updates are unambiguously ordered after that edge's DUT sampling and before the next one. All four prior-phase testbenches (`tb_floppy_write_path.v`, `tb_floppy_track_decoder.v`, `tb_floppy_write_stream.v`, `tb_floppy_track_encoder.v`) re-verified passing unmodified after the `floppy.v`/`iwm.v` port additions - Verilog leaves unconnected optional output ports floating with no error, so the new `dskCommit*` ports required no changes to those testbenches.

`quartus_map --analysis_and_elaboration`: 0 errors, 20 warnings (same pre-existing baseline as every prior phase). The only connectivity notes touching new code are Info-level "explicitly unconnected" on `wr_int`/`wr_ext`'s `busy` output (intentionally dangling, matching the `floppy_write_committer:wc.busy` precedent from Phase 3) - no warnings on any of the new `dskCommit*`/`sd_buf_*` signal chains, confirming they're wired through correctly end to end.

**Not yet done:** full Quartus compile and the hardware+host gate (write, eject, remount, byte-level `.dsk` diff on the PC) - needs the user's go-ahead for a full compile (standing rule) and real hardware to test on.

**Code review findings fixed (2026-08-16), pre-compile.** A review of the Phase 4 diff found one blocker and two follow-ups, all now fixed and sim-verified:

- **Blocker: `sd_buff_din` was missing the byte swap** hps_io's wire format requires (the same swap `floppy_loader.v` already documents and applies on the read side - see that module's `SD_WAIT_DONE` comment). Without it, every written byte pair would land transposed in the `.dsk` on disk. Fixed in `floppy_sd_writer.v` (`sd_buff_din = {mem_do[7:0], mem_do[15:8]}`). Proven with a new permanent testbench, `sim/tb_loader_writer_roundtrip.v`, that drives the real `floppy_sd_writer.v` and `floppy_loader.v` RTL back-to-back through a mocked hps_io and confirms a committed sector survives a full write-then-read-back round trip byte-exact - not just that the two swaps look locally plausible. `sim/tb_floppy_sd_writer.v`'s own data-comparison assertions were updated to expect the (now-correct) swapped wire format.
- **Eject-race interlock:** `floppy_sd_writer.v` gained an `img_mounted` input (wired to `img_mounted[2]`/`[3]` per drive in `MacPlus.sv`) that drops the queue - captured sectors not yet started - on a fresh mount of that slot, so a sector committed against the outgoing image can never land at a stale LBA in whatever gets mounted next. An in-flight `sd_wr` is deliberately left alone (only `valid` is cleared, which just gates entry into a *new* transfer) since tearing down a request hps_io may already be servicing is worse than letting one stale sector finish. New Test 4 in `sim/tb_floppy_sd_writer.v` covers both halves: an in-flight commit survives `img_mounted`, a merely-queued one is dropped.
- **`busy` connected:** `wr_int`/`wr_ext`'s previously-dangling `busy` output now feeds `LED_USER` in `MacPlus.sv` alongside the loader's own busy, so the activity light also covers a pending SD flush after a write.
- **Two minors:** `sd_lba` is now reset to 0 in `floppy_sd_writer.v` (was previously left unreset, unlike every other output in that block); the redundant `MacPlus.qsf` entry for `rtl/floppy_sd_writer.v` was removed (the file is already registered in `files.qip`, which `MacPlus.qsf` sources - the `.qsf`'s own header says new files belong in `files.qip`, not there directly).

All of `sim/tb_loader_writer_roundtrip.v` (new), `sim/tb_floppy_sd_writer.v` (updated, 4/4 including the new eject-race case), and all four prior-phase testbenches re-verified passing.

**Full compile completed (2026-08-16, user gave explicit go-ahead): 0 errors, 57 warnings** (same pre-existing baseline as every prior phase - none of the new/changed code in this review pass introduced a new warning), **timing met** (worst-case setup slack 0.423ns, worst-case hold slack 0.247ns). **15,253/41,910 ALMs (36%), 477,125/5,662,720 block memory bits (8%)** - essentially unchanged from the Phase 3 `buf_mem` M10K-fix baseline (15,296 ALMs, 36%); the review's fixes added negligible logic. Output: `output_files/MacPlus.rbf`/`.sof`.

**HARDWARE + HOST GATE: PASS (2026-08-16).** User tested both drives: a 400K image (`Paint_2.dsk`) in drive 1, an 800K image (`Disk605.dsk`) in drive 2, write/eject/remount, then a byte-level diff of the pre- and post-write `.dsk` files on the PC (512-byte-sector granularity, whole-file comparison).

- `Paint_2.dsk` (400K): 16/800 sectors changed, 3733 bytes total - a handful of small changes in sectors 2-5 and 16 (byte offsets 1024-3071 and 8192-8703, the classic MFS Master Directory Block / volume-metadata region), plus one contiguous 13-sector run (572-584) that is the actual file data write.
- `Disk605.dsk` (800K): 6/1600 sectors changed, 462 bytes total - the same small metadata footprint (sectors 2, 3, 16, 20, 23) plus one data sector (40, 354 bytes changed).

Both files stayed at their exact original size, and in both cases every changed sector clusters into either the volume-metadata region or a single contiguous data run - there is no scattered, unrelated-sector corruption anywhere else in either image, which is exactly the signature a wrong-LBA bug would NOT produce and a correct write-back WOULD. This is the strongest available confirmation (short of opening the images in a Mac emulator, not yet done) that both the LBA arithmetic and this review's `sd_buff_din` byte-swap fix are correct on real hardware, not just in sim.

**Further confirmed the same session:** both images still mount and recall the written files correctly after a full core/system restart (not just an eject/remount within the same session - genuine SD persistence across a power cycle, the actual point of Phase 4), and both were also re-tested in the OPPOSITE drive from their first test (the 400K image that was written in drive 1 now read correctly from drive 2, and vice versa for the 800K image) - confirming the fix is symmetric across `wr_int`/`wr_ext` and not an artifact of one drive's wiring.

**Phase 4 is done.**

---

### Phase 5 — Hardening and parity

Original bullets (written before Phases 1–4 existed, so partly superseded):
- Both drives at full parity (external drive is a second `floppy` instance).
- 400K single-sided write path (different `sides` geometry through `soff`).
- Correct behaviour on eject mid-write, and on write with no disk inserted.
- `SWITCHED` / disk-switched flag, currently hardwired to `1'b0` (`driveRegsAsRead` in [`rtl/floppy.v`](rtl/floppy.v) — the plan originally cited line 114, the correct site is the `SWITCHED` bit of `driveRegsAsRead`).
- Stress: copy a multi-megabyte set of files floppy→floppy and floppy→SCSI; System 6.0.8 installer writing to floppy; Finder duplicate/trash cycles.
- Update `readme.md` (it currently states floppies are not writable) and re-check the 16 MHz caveat, which may interact badly with write timing.

#### STATUS — RTL complete, all sim gates pass, elaboration clean. Not yet compiled or hardware-tested.

**Bullets 1 and 2 were already satisfied by Phase 4's own hardware gate** and are demoted to regression checks, not work: `Paint_2.dsk` (the 400K image tested) exercises the single-sided path, and each image was written in one drive and read back in the other. `floppy_track_decoder.v` copies the encoder's `soff`/`spt` math verbatim, `sides` term included.

**Item 1 — write refused with no disk, and the write path reset on any disk change** (`rtl/floppy.v`). The write-accept condition gained a ``!driveRegs[`DRIVE_REG_CSTIN]`` (disk-in-place) term, closing a path where a stray post-eject write could reach the real `.dsk` on SD — an OS eject only sets CSTIN and drops `dsk_*_ins`; the S-slot stays mounted and the file stays open, so `floppy_sd_writer`'s `img_mounted` interlock (OSD remount only) does not cover it. A new `writePathReset` (eject pulse, or the rising edge of `insertDisk`) now resets the decoder and committer and clears the byte-pacer, so a half-decoded field can never be completed by the next disk's bytes and committed as a mixed sector. No new ports.

> `insertDisk` is a **level**, not a pulse — `MacPlus.sv` drives it from `dsk_*_ds || dsk_*_ss`, held high for as long as a disk is mounted. `writePathReset` therefore edge-detects it. Two bugs came out of this during bring-up: using the bare level reset the decoder on every single cycle, and once edge-detected, force-clearing `insertDiskPrev` during reset manufactured a spurious edge that silently swallowed the first write byte of the next field. `insertDiskPrev` is seeded from the live level while in reset for that reason.

**Item 2 — decoder bounds checks and an SD-writer timeout.** `floppy_track_decoder.v`'s `S_SECT` now rejects a sector number `>= spt`, or a side-1 field on a single-sided mount. Both matter because the decoded sector number sits *outside* the checksum chain — the chain covers the 524-byte payload but not the number that decides where that payload lands, so without a bounds check a mis-synced field could alias to a different *valid* sector and commit a checksum-valid write at the wrong offset. The comparison uses all 6 bits, not the truncated 4, which is what catches the aliases. Separately, `floppy_sd_writer.v`'s `P_WAIT_ACK` had no timeout and would stall forever with `busy` high (wedging `LED_USER`) if `sd_wr` were asserted on a slot the framework was not serving; it now times out. The timeout width is a parameter (`ACK_TIMEOUT_BITS`, default 24 ≈ 0.5 s) purely so a testbench can override it small — the real instantiations in `MacPlus.sv` are unparameterized and keep the 24-bit default.

**Item 3 — `SWITCHED` implemented.** A new `diskSwitched` register feeds `driveRegsAsRead` bit 6 (previously hardwired `1'b0`), set by the same two events `writePathReset` uses (eject, or a genuine `insertDisk` edge) and cleared only when the Mac explicitly writes the reset-disk-switched register. That write decode already existed in the RTL and was consumed by nothing. Note the dependency: single-drive floppy→floppy copying (a stress bullet below) *requires* `SWITCHED` for the disk-swap dance; two-drive copying does not.

**Item 4 — 16 MHz floppy reads fixed** (`rtl/iwm.v`, threaded through `dataController_top.sv` and `MacPlus.sv`). Root cause: the IWM read-data latch clear interval is wall-clock but the driver that depends on it is cycle-counted, and only the CPU speed scales. `readLatchClearTimer` loads 13 and decrements once per `cen` (125 ns) regardless of turbo, clearing the latch a fixed **1.5 µs** after a valid read. The `.Sony` driver detects a new byte *only* by polling bit 7, and **every GCR disk byte has bit 7 set**, so a not-yet-cleared latch is indistinguishable from a fresh byte. Its poll loops are unrolled double reads ~16 CPU cycles apart (measured in `releases/boot1.rom` at `0x03552e`): **2.0 µs at 8 MHz** (clears in time, ~33% margin) but **1.0 µs at 16 MHz** (still latched → duplicate bytes → no checksum ever validates → "disk unreadable").

> Fix: the timer decrements on `clk16_en_n` instead of `cen` when turbo is selected — 12 ticks = 0.75 µs, restoring the same ~33% margin. At 8 MHz the enable reduces to `cen` exactly, so that path is bit-identical to the hardware-proven behaviour. The disk byte rate (16 µs) is a property of the drive and deliberately does **not** scale.
>
> The clear itself had to move onto the same enable as the countdown. `clk16_en_n` is a superset of `clk8_en_n` (`busPhase[0]` vs `busPhase==2'b01`), so a timer ticking at the faster rate reaches its terminal count on a phase-11 tick that `cen` never observes — leaving the clear gated on `cen` would let the terminal count slip past and the latch would never clear at all. The 16 MHz test case exercises exactly that tick, so this is verified, not just reasoned.
>
> Two hypotheses were checked and **ruled out** — do not re-derive them: missed CPU strobes at `cen` (a 68000 holds `_cpuLDS` for 187.5 ns at 16 MHz, longer than `cen`'s 125 ns period, so at least one sample is always guaranteed), and a missed `lstrbEdge` (the ROM's strobe routine holds LSTRB ~1 µs even at 16 MHz = 8 `cep` edges). Overrun is also not involved: `advanceDriveHead` is inert because `floppy.v` hardwires `readyToAdvanceHead` to 1.
>
> Adjacent finding, now documented in a code comment: `iwmMode` is **dead** — written and read back, but no bit of it affects behaviour. Its `L` (latch mode) bit is precisely the real IWM control governing this timing; we always behave as `L=1` regardless of what the driver writes.

**Item 5 — `readme.md` updated**: floppies described as writable and gated by the OSD "Floppy Write" toggle (`status[6]`, defaults Off) which was previously undocumented; the stale "upload takes a few seconds" wording replaced (floppies have been S-mounts since Phase 1, not `ioctl` uploads); eject-before-swap reframed as a data-integrity matter; and the 16 MHz caveat rewritten now that item 4 fixes it.

**Sim gates — 10 testbenches, all passing, run from the repo root:**

| Testbench | Covers |
|---|---|
| `tb_floppy_track_encoder` | Phase 0 ground truth |
| `tb_floppy_track_decoder` | + 2 new negative tests: out-of-range sector, side 1 on a single-sided mount |
| `tb_floppy_write_stream` | real non-zero-tag fields, plus the same two rejects at stream level |
| `tb_floppy_write_path` | + 3 new tests: write refused with no disk; eject/remount mid-field leaves the decoder clean; `SWITCHED` set on eject and on remount, cleared only by the reset-register write |
| `tb_floppy_sd_writer` | + 1 new test: `P_WAIT_ACK` times out and recovers with `busy` low |
| `tb_loader_writer_roundtrip`, `tb_floppy_loader`, `tb_floppy_loader_ext`, `tb_floppy_loader_integrated` | unmodified, no regression |
| `tb_iwm_latch` (**new**) | the 16 MHz root cause: fails at 16 MHz on the pre-fix RTL, passes at both speeds after |

> `tb_iwm_latch.v` is a characterization test built against the *real* `iwm`/`floppy`/`floppy_track_encoder`, so the bytes under test are genuine encoder output rather than synthetic. It guards the pre-fix RTL too, via `-DIWM_HAS_TURBO`, so the before/after comparison runs identical stimulus.

**Testbench lesson worth carrying forward (cost a session):** driving a DUT input at zero delay immediately after `@(posedge clk)` races the DUT's own sampling of that signal in the same timestep, and Icarus may order it either way. On a *held* signal this only costs a cycle; on an **edge-history register** it destroys the event outright. That is what made the `SWITCHED` eject test fail — `lstrbPrev` sampled the new value, so the 1→0 strobe never existed and `lstrbEdge` never fired. It also meant the pre-existing, untouched `CSTIN` eject path silently never fired in that test either, which in turn meant the earlier eject/remount test was passing on its remount edge alone and had never actually exercised eject. `tb_floppy_write_path.v` now routes every drive-register write through one `strobe_write` task with the `#1` discipline baked in, and both eject tests now assert `CSTIN` directly so a dead strobe cannot pass silently again.

**Elaboration:** `quartus_map --analysis_and_elaboration MacPlus` — 0 errors, 20 warnings, the standing baseline.

> Quartus-vs-Icarus gotcha hit during this phase: Quartus needs the literal `if(!_reset) ... else if(cep) ...` two-branch shape to recognize an async-reset register. A single merged condition (`if(!_reset || cep)`) elaborates fine in Icarus but makes Quartus infer a latch and throw Error (10200)/(10240).

**Still open for Phase 5:** full Quartus compile, hardware testing (including a 16 MHz read test, which is the whole point of item 4), and the stress bullet. The stress work should target the three Phase-3/4 structures nothing has exercised yet: the depth-2 commit queue and its documented depth-3 limit (via a large Finder duplicate); shared extra-slot-3 arbitration (write to one drive while mounting the other); and write-then-immediate-OSD-remount (the in-flight-survives / queued-dropped split, sim-proven but never on hardware).

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
