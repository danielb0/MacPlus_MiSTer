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

**Item 1 — write refused with no disk, and the write path reset on any disk change** (`rtl/floppy.v`). The write-accept condition gained a ``!driveRegs[`DRIVE_REG_CSTIN]`` (disk-in-place) term, closing a path where a stray post-eject write could reach the real `.dsk` on SD — an OS eject only sets CSTIN and drops `dsk_*_ins`; the S-slot stays mounted and the file stays open, so `floppy_sd_writer`'s `img_mounted` interlock (OSD remount only) does not cover it. A new `writePathReset` (eject pulse, or **either** edge of `insertDisk` — the falling edge was added by the code review below) now resets the decoder and committer and clears the byte-pacer, so a half-decoded field can never be completed by the next disk's bytes and committed as a mixed sector. No new ports.

> `insertDisk` is a **level**, not a pulse — `MacPlus.sv` drives it from `dsk_*_ds || dsk_*_ss`, held high for as long as a disk is mounted. `writePathReset` therefore edge-detects it. Two bugs came out of this during bring-up: using the bare level reset the decoder on every single cycle, and once edge-detected, force-clearing `insertDiskPrev` during reset manufactured a spurious edge that silently swallowed the first write byte of the next field. `insertDiskPrev` is reset to a **constant** `1'b1` for that reason, which produces exactly that "no spurious edge" behaviour without the hazard. It was originally seeded from the live `insertDisk` level instead; that simulates correctly but cannot synthesize, because an asynchronous reset must resolve to a constant — see the code-review section below.

**Item 2 — decoder bounds checks and an SD-writer timeout.** `floppy_track_decoder.v`'s `S_SECT` now rejects a sector number `>= spt`, or a side-1 field on a single-sided mount. Both matter because the decoded sector number sits *outside* the checksum chain — the chain covers the 524-byte payload but not the number that decides where that payload lands, so without a bounds check a mis-synced field could alias to a different *valid* sector and commit a checksum-valid write at the wrong offset. The comparison uses all 6 bits, not the truncated 4, which is what catches the aliases. Separately, `floppy_sd_writer.v`'s `P_WAIT_ACK` had no timeout and would stall forever with `busy` high (wedging `LED_USER`) if `sd_wr` were asserted on a slot the framework was not serving; it now times out. The timeout width is a parameter (`ACK_TIMEOUT_BITS`, default 24 ≈ 0.5 s) purely so a testbench can override it small — the real instantiations in `MacPlus.sv` are unparameterized and keep the 24-bit default. **What the timeout *does* on expiry was corrected by the code review below** — retiring the queue entry there turned out to be a corruption path, so it now re-presents the same request instead.

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
| `tb_floppy_sd_writer` | + 1 new test: `P_WAIT_ACK` times out rather than wedging (test reworked by the code review below, which changed what recovery means) |
| `tb_loader_writer_roundtrip`, `tb_floppy_loader`, `tb_floppy_loader_ext`, `tb_floppy_loader_integrated` | unmodified, no regression |
| `tb_iwm_latch` (**new**) | the 16 MHz root cause: fails at 16 MHz on the pre-fix RTL, passes at both speeds after |

> `tb_iwm_latch.v` is a characterization test built against the *real* `iwm`/`floppy`/`floppy_track_encoder`, so the bytes under test are genuine encoder output rather than synthetic. It guards the pre-fix RTL too, via `-DIWM_HAS_TURBO`, so the before/after comparison runs identical stimulus.

**Testbench lesson worth carrying forward (cost a session):** driving a DUT input at zero delay immediately after `@(posedge clk)` races the DUT's own sampling of that signal in the same timestep, and Icarus may order it either way. On a *held* signal this only costs a cycle; on an **edge-history register** it destroys the event outright. That is what made the `SWITCHED` eject test fail — `lstrbPrev` sampled the new value, so the 1→0 strobe never existed and `lstrbEdge` never fired. It also meant the pre-existing, untouched `CSTIN` eject path silently never fired in that test either, which in turn meant the earlier eject/remount test was passing on its remount edge alone and had never actually exercised eject. `tb_floppy_write_path.v` now routes every drive-register write through one `strobe_write` task with the `#1` discipline baked in, and both eject tests now assert `CSTIN` directly so a dead strobe cannot pass silently again.

**Elaboration:** `quartus_map --analysis_and_elaboration MacPlus` — 0 errors, 20 warnings, the standing baseline.

> Quartus-vs-Icarus gotcha hit during this phase: Quartus needs the literal `if(!_reset) ... else if(cep) ...` two-branch shape to recognize an async-reset register. A single merged condition (`if(!_reset || cep)`) elaborates fine in Icarus but makes Quartus infer a latch and throw Error (10200)/(10240).

---

#### Phase 5 code review (2026-08-16) — six defects found and fixed

A single-pass review of the Phase 5 write path (`floppy.v`, `floppy_track_decoder.v`, `floppy_sd_writer.v`, and the then-uncommitted `iwm.v` change), motivated by the fact that this phase writes to real `.dsk` files on the user's SD card. Ranked by severity; all six are fixed in the tree.

**1. `insertDiskPrev` synthesized to a latch inside a combinational loop** (`floppy.v`). Its asynchronous reset branch assigned the live `insertDisk` signal rather than a constant. Quartus cannot build an async *load*, so it split the register into a flop plus a transparent latch (Warning 13004/13310, both drive instances) and TimeQuest then reported the result as *"2 combinational loops analyzed as latches"* — untimed logic, powering up undefined, feeding `writePathReset`, which at the time was an **asynchronous** reset on the decoder. A glitch of any width there abandons the field in progress, and since the write path signals no error for an abandoned field, the Mac would believe a sector had been written when it never landed. Fixed by resetting to a constant `1'b1`.

> This was the diff's clearest signal and it was sitting in the compile log the whole time: the Phase 5 compile went from the long-standing **57 warnings to 65**, and the delta was never examined. All 8 new warnings were these. **Diff the warning count against the previous phase after every compile.**

**2. The SD-writer ack timeout retired the queue entry** (`floppy_sd_writer.v`). On expiry it cleared `valid[head]` and flipped `head`. But `hps_io` captures `sd_lba` during its own poll command (`'h16`) and raises `sd_ack` in a *later, separate* command (`'h0X18`), so the gap between the two is unbounded from the core's side. A late ack arriving after the timeout would stream the **other** shadow buffer to the LBA the HPS had already captured — a full sector of unrelated data at a valid offset in the `.dsk`. Fixed by re-presenting the request instead: `valid`, `head` and `sd_lba` are left alone, so the retry is idempotent and any ack, however late and whichever attempt it belongs to, transfers the same buffer to the same LBA.

**3. Writes were accepted throughout an image reload** (`floppy.v`). `writePathReset` fired only on the *rising* edge of `insertDisk` (`ldr_*_done`, load complete), but `insertDisk` goes **low** at `img_mounted` (load start). Across that whole window — hundreds of ms for an 800K image — `driveRegs[CSTIN]` still read "disk present", because CSTIN is only ever *set* by an explicit OS eject strobe and is never restored on an OSD remount. So a field completing during or just after a swap would commit the departing disk's sector into the newly mounted image, in SDRAM and then via `floppy_sd_writer` into the new `.dsk`. This is the exact failure class item 1 was written to close, and item 1 did not close it. Fixed with an `insertDisk` term on the write-accept condition and by adding the falling edge to `writePathReset`.

**4. The sector bounds check and the address it protects were evaluated ~11 ms apart** (`floppy_track_decoder.v`). The item-2 check runs in `S_SECT` against live `spt`/`side`/`sides`, but `addr <= addr_base` was sampled at `S_DTRL`, a whole field later, from whatever those inputs were *then*. `driveSide` is driven straight off the CA lines with no read strobe (the module's own comment says *"we don't know if this is a true read"*), so a side flip mid-field could add the `spt*512` term to a field validated as side 0 on a single-sided mount — up to 6144 bytes off, past the end of a 400K image on the outer tracks. Fixed by splitting `addr_base` into `geom_base` and latching the full address in `S_SECT`, at the instant the check passes, making validate-and-commit atomic.

**5. No LBA bounds check against the mounted image** (`floppy_sd_writer.v`). The code claimed the decoder had already range-checked the address; it only checks the *sector* against `spt`, and `driveTrack` is free to reach `0x4F` regardless of image size. New `size_blocks` input (from each loader's own `loaded_size >> 9`); out-of-range commits are retired without ever reaching `hps_io`. This is also the containment for #4.

**6. One wire was an async reset in one module and a sync reset in the next** (`floppy.v`). `!_reset || writePathReset` fed `floppy_track_decoder` asynchronously and `floppy_write_committer` synchronously. `writePathReset` is a derived combinational pulse, not a reset rail, and does not belong on an async reset pin. The decoder is now synchronous, matching the committer (which has consumed the identical wire that way since Phase 3).

**Not a code defect, but the highest untested risk in the phase: `SWITCHED` (item 3).** It went from hardwired `1'b0` — the value every hardware-proven build through Phase 4 ran with — to a live bit set on every `insertDisk` edge and cleared *only* if the ROM actually writes the reset-disk-switched register. Nothing establishes that this ROM ever does; if it does not, the flag latches at 1 on the first mount and every subsequent drive-status poll reports "disk switched", which would affect the **read** path too. Fix 1 made its power-up state deterministic; the rest is a hardware question. Test it early — the revert is one line in `driveRegsAsRead`.

**The sync-reset change (#6) exposed a real testbench defect.** `tb_floppy_track_decoder` and `tb_floppy_write_stream` both drove `ready = 0` at zero delay immediately after `@(posedge clk)` — the same timestep in which the DUT samples `ready` at that edge. Which value the DUT saw was therefore decided by Icarus' process ordering, and that ordering depends on the DUT's sensitivity list: the async reset had been masking the race, and removing it flipped the coin to "every byte dropped", failing 0/12 sectors on every track. Both testbenches now use the project's `#1` discipline throughout and pass on their merits. **Their previous passes were not evidence the decoder was correct** — this is the fourth appearance of this race class in this project (Phase 0 reset, Phase 4 sd-writer 50% dropout, Phase 5 eject strobe), and the first where it was hiding behind an RTL detail rather than in the testbench alone.

**Verification after the fixes:** all 10 testbenches pass (`tb_floppy_sd_writer` gains a reworked timeout test that proves a late ack still lands byte-exact at the original LBA, plus a new out-of-range-LBA test). `quartus_map --analysis_and_elaboration`: 0 errors, 20 warnings, the standing baseline. Full `quartus_map` synthesis: **0 errors, 50 warnings, down from 54** — the four that disappeared are exactly the `insertDiskPrev` latch conversions, with no inferred latches or combinational loops anywhere in the design, and `floppy_track_decoder`'s `buf_mem` still inferring as M10K on both drive instances.

---

**Still open for Phase 5:** full Quartus compile, hardware testing (including a 16 MHz read test, which is the whole point of item 4), and the stress bullet. The stress work should target the three Phase-3/4 structures nothing has exercised yet: the depth-2 commit queue and its documented depth-3 limit (via a large Finder duplicate); shared extra-slot-3 arbitration (write to one drive while mounting the other); and write-then-immediate-OSD-remount (the in-flight-survives / queued-dropped split, sim-proven but never on hardware).

---

### Phase 6 — Formatting (Erase Disk)

**Original assessment (2026-08, superseded):** low-level format requires writing complete tracks *including address fields*, with correct sync gaps and interleave across all 80 tracks; materially harder than sector writes; deferred. If attempted, the commented-out inter-sector gap in `STATE_WAIT` would need to become real.

**What actually happened (2026-09-09).** Erase Disk on an 800K image was tried on hardware (build `375E23A4`) and failed with "Initialization failed" — and left the image unmountable: every data sector of **track 0, both sides, zeroed**, nothing else touched, every write at the correct address, zero step requests. Daniel: *"we can't release the core in this state."* Scope he set: Erase Disk on an already-formatted, correctly-sized image; formatting blank or wrongly-sized images is out of scope.

**The write side was never the problem.** Phases 0–5 already decode whatever data fields arrive, and the ROM's format writes ordinary ones. The failure was on the **read-back**, and the original assessment had the mechanism wrong in every particular: no gaps or interleave need modelling, and address fields need only be *noticed*, not laid out.

#### The ROM's format, decoded (128K ROM `MacPlus v3.ROM`, base `$400000`)

| address | what it does |
|---|---|
| `$419100` | entry: `$32(a1)` ← double-sided flag, `$22(a1)` ← **7** (sync count), copies the 27-byte template at `$4190CA` twelve times |
| `$419136` | the track loop, 0..79; **bails on the first error** |
| `$41917C` | seeks (`$418718` via `$4194B6`), then a spindle-speed check that an 800K drive skips (`tst.b $13(a1,d1.w) / bmi`) — *not* the write, as an earlier reading had it |
| `$4191E6` | per side: `$419362` fills the template's address fields (sector order **0 6 1 7 2 8 3 9 4 10 5 11**, format byte `$22`/`$02`), `$419282` writes, `$418C18` reads back, `$41922C` judges; then side 1 if double-sided |
| `$419282` | **the track write**, one burst: a byte to Q7H, 200 × `FF 3F CF F3 FC FF` (1200 bytes of lead-in), then per sector (sync−1) more sync groups, the 27-byte template (6 sync + `D5 AA 96 t s h f c DE AA FF` + 7 sync + `D5 AA AD s`), **703 × `$96`** (an all-zero data field and its checksum), `DE AA FF FF`. Then `tst.b Q7L`. Checks the handshake's underrun bit (`wrUnderrun`, −74) |
| `$418C18` | the address-field reader: three bytes for a nibble check (`noNybErr`), then hunts `D5 AA 96` with a budget of `$5DC` (400K drive) or `$5BC` (800K) bytes (`noAdrMkErr`, −67), decodes t/s/h/f/checksum (`badCksmErr`), checks `DE AA` (`badBtSlpErr`); returns the sector in `d2` and the unused budget in `d0` |
| `$419214` | **`d2` must be 0, else `$AE` = −82 = `fmt1Err`, "can't find sector 0 after track format"** |
| `$41922C` | `d2 = ($5E0 − d0) / 5 − sync`; if negative: −1 accepts, less rewrites the track with sync−1 (below 4: `fmt2Err`, −83); if ≥ 0: `/spt`, 0 or 1 accepts, more accepts and bumps sync for the next track |

So after the burst the ROM demands that the **first address field to come round is sector 0**, within ~1500 bytes. On real media that is physics: the write went round once, so its start is about to come under the head again. The core's read-side encoder free-runs through its own 12-sector cycle regardless of writes, so the first field after a format was whichever sector it happened to be on — `fmt1Err` eleven times in twelve. (Track 0 side 1 being zeroed as well means side 0 passed by that one-in-twelve luck; on the Plus's 800K budget the gap arithmetic accepts *any* non-negative distance, so sector 0 first is the only hard requirement there.) The 64K ROM's reader is the same shape (`move.w #$5DC` at `$4020DC`); its formatter was not decoded.

#### The fix: a format relay (`rtl/floppy_track_encoder.v`)

The media is treated as a ring of `rev_len` byte cells — spt × 782, the encoder's own cycle (SYN0 56 + ADDR 10 + SYN1 5 + DHDR 4 + DZRO 12 + DPRE 4 + DATA 683 + DSUM 4 + DTRL 3 + WAIT 1). `floppy_track_decoder.v` now reports each address field's sector as it goes by in the write stream (`amark`; a normal sector write never contains one, so this is unambiguous — the same fact the abandoned safety-gate idea rested on). From the first mark of a burst the encoder counts the distance from the head round to that mark per byte written, modulo `rev_len`; when the burst ends it restarts its layout at that sector with exactly that many sync bytes before the address mark (new `STATE_GAP`). The ROM then finds sector 0 where the physics says it is. A burst with no address field never arms the relay.

`floppy.v` bounds the burst with a new `writeMode` input — the IWM's Q7, wired through in `iwm.v` — ANDed with the pacer, and delays the end pulse two clocks so the decoder's verdict on the final byte lands first. Nothing in the read path's timing or layout changed; a plain sector write behaves exactly as before.

Not modelled: a write that runs on more than a revolution past its own first mark has, on real media, overwritten it. Here the count wraps and sector 0 is still presented. The ROM's format never does this (one revolution plus ~1100 bytes of lead-in, tuned toward a ~100-byte gap; with `rev_len` = 9384 the tuning settles at sync 8 by track 1 and stays there), and the consequence would only be accepting a track the ROM would have rewritten.

#### Verification (`sim/tb_floppy_format.v`, iverilog, cep every 4 clocks as on hardware)

1. the layout's period is measured at **9384** bytes and equals `rev_len`;
2. the ROM's exact 10441-byte burst for track 0 side 0: all 12 data fields commit (track zeroed, nothing else written), the first field read back is sector 0 with `t=96 s=96 h=96 f=d9 c=d9`, its `D5` **185** bytes after the write against the ring arithmetic's 186 (the burst's end is a clock-level event inside a 16 µs byte cell; the bench allows a byte either side, the ROM's window is ~1400 wide), and the ROM's `$41922C` arithmetic, reproduced in the bench, accepts it on both budgets (sync bumped to 8 for the next track);
3. an ordinary data-field write commits byte-exact and never arms the relay;
4. a burst ending on the very byte that completes an address field (sector 6) relays to sector 6, 9378 bytes on (predicted 9379);
5. the same burst on side 1 lands on side 1's sectors and reads back as side 1 (`h=d6`).

Mutations: removing the relay fails 2, 4 and 5 (sector 4 comes first, at 499 bytes — the hardware failure, reproduced). Removing the two-clock delay on the burst-end pulse **passes at the hardware cep spacing** — it is load-bearing only when cep is held high every clock, as `tb_floppy_write_path.v` does; kept for that robustness, and the comment says so. All eight pre-existing floppy/IWM benches still pass.

**STATUS: hardware-confirmed 2026-09-09** (`36632fcd`, rbf `MacPlus_36632fcd_format.rbf`; compile 0 errors, 120 warnings - the same count as the daisy build; 20,431/41,910 ALMs, 133/553 M10Ks, all setup slack positive). Five erases, every one verified byte-level offline rather than by the Finder's verdict:

| image | drive | choice | result |
|---|---|---|---|
| 800K | internal | Two-Sided | healthy 800K HFS; all 160 tracks rewritten; the one apparent survivor explained (deterministic empty-extents header) |
| 400K | external | One-Sided | healthy 400K **MFS**; all 80 tracks; 0 survivors |
| 800K x2 | internal | One-Sided | **800K volume over a never-formatted side 1** - see Phase 7 |
| 400K | internal | Two-Sided | healthy 400K MFS; 0 survivors; identical in shape to the One-Sided run |

The relay itself was correct in all five: the tracks the ROM asked for were formatted and read back coherently, across both volume formats, both drives, all five sector-per-track zones, and both dialog choices. The 800K erase also proves the zone arithmetic (`rev_len`) on hardware for every zone - the alternate MDB lands on cylinder 79, the outermost - which `tb_floppy_format.v` never covered, since it only replays track 0.

**Two scope notes in the earlier draft of this phase were wrong and are retracted.** A Two-Sided erase of a 400K image does *not* spoil the image: side 1's data fields are rejected in `S_SECT`, that pass is a silent no-op, and the driver reads back format byte `$02` and builds a normal 400K MFS volume. Tested (`EraseMe400K-2.dsk`): 0 survivors, indistinguishable from the One-Sided run. That claim sat here as a confident prediction for a day and was retired by a one-minute experiment. Prefer the experiment.

### Phase 7 - The medium is a diskette, not a file size (media sidedness)

**The defect, found 2026-09-09 by the Phase 6 hardware testing.** `rtl/floppy_track_encoder.v:123`:

```verilog
wire [5:0] format = { sides, 5'h2 };   // double sided = 22, single sided = 2
```

`sides` is `diskSides`, which comes only from the image file size (`MacPlus.sv:1138`/`1154`, `== 64'd819200`). That byte goes into every synthesised address field (`count == 6`) and into its checksum, and the `.Sony` driver reads it back to decide the disk's geometry. So the core asserts a medium's format from the size of the file holding it.

A One-Sided erase of an 800K image therefore does this: the ROM formats side 0 only (**correctly** - side 0 comes back 99.5% zeroed, side 1 untouched), the driver then reads an address field, our encoder answers `$22` regardless, and the DIP builds an 800K HFS volume spanning a side that was never formatted. The Finder shows a healthy, empty 779K disk of which **308 KB is intact content of the previous volume, sitting in reported-free space** (617 free allocation blocks byte-identical to the source image). Reproducible: two runs, 1596/1600 sectors identical. The earlier tests missed it because the lie happened to be true - in each of them the file size matched the format actually performed.

**Why this is worth fixing rather than documenting (Daniel, 2026-09-09).** Every 3.5" diskette of the era was the same medium. 400K versus 800K was a *formatting choice*, not a property of the disk: SS/DS was a certification label, nothing on the disk encodes it, and the drive cannot tell. So an 819,200-byte image is simply *a diskette*, and the volume on it is whatever was last formatted onto it. Modelling that is the authentic behaviour; deriving it from the file size is the inauthentic shortcut. It also lets one 800K image carry a 400K volume that every model can read.

**409,600-byte images stay fully supported (Daniel, 2026-09-09).** They are the standard 400K format in the emulation world. Today a Two-Sided erase of one still produces a 400K volume, and that behaviour is a requirement of this phase, not an accident to be tidied - see the ceiling rule below.

#### The measurements this design rests on

1. **The format byte is consulted at mount, not only at format.** A real 400K disk put into a Plus's 800K drive reads correctly on a machine that never saw it formatted. The only thing telling it 400K is that byte on the medium.

2. **Proven by observing a write.** `scratchpad/mk400in800.py` built `400Kvol_in_800Kimage.dsk` - a valid 400K MFS volume copied into the *side-0 positions* of an 819,200-byte layout, i.e. what a correct One-Sided format should produce. The Mac said "minor repairs", and the repair wrote exactly three sectors:

   | file sector | physical | volume block | |
   |---|---|---|---|
   | 2 | cyl 0 side 0 sec 2 | MDB | same under both geometries |
   | 4 | cyl 0 side 0 sec 4 | block 4 | same under both geometries |
   | 16 | cyl 0 **side 1** sec 4 | block 16 | **decisive** |

   Block 16 is `drAlBlSt`. Single-sided mapping puts it at file sector 28; double-sided at 16. The Mac wrote 16. Blocks 0-11 agree under both geometries; only block 12 onward discriminates, and the MFS directory (`drDirSt`=4, `drBlLen`=12) runs straight through that boundary.

3. **A free-space figure is not evidence of volume health.** The Mac reported "387K free" while misreading the volume - that figure is `drFreeBks * drAlBlkSiz` straight from the MDB, which sits at file sector 2, identical under both geometries. It nearly bought a wrong conclusion.

4. **A 400K volume can live in an 800K image.** The repaired file is one; it is self-consistent and the Mac reads and writes it happily. The constraint is *consistency of geometry*, not capacity.

#### Design

One signal - call it `media_ds` - replaces `diskSides` at the floppy level and describes **the volume on the medium**, not the file. It feeds *both* consumers:

* `geom_base` and the `S_SECT` bounds check in `floppy_track_decoder.v`
* the `format` byte in `floppy_track_encoder.v`

**The rule, in one line:** `media_ds` is 1 only when the drive is 800K (`drive800k`), the file is 819,200 bytes, *and* the medium says double-sided. Each term is a ceiling the ones after it cannot raise.

1. **The drive.** A 64K-ROM model has a one-headed drive, so `media_ds` is simply 0 there, always. Every image of either size mounts, is addressed linearly, and the ROM judges the contents itself - exactly what a real 400K drive does with any diskette put in it. The sniff and the latch below matter only on the 128K-ROM models, where the drive can do both and the medium has to say which.

2. **The file size.** A 409,600-byte file can never be double-sided, whatever a format burst says. This is what keeps the Two-Sided erase of a 400K image producing a 400K volume: the encoder goes on answering `$02`, side 1's pass goes on being rejected in `S_SECT` (`side && !sides`), and the driver builds MFS 400K as it does today. Without this term the first `$22` field of the burst would flip the geometry, side 1 would be accepted into SDRAM beyond the file's end, and `floppy_sd_writer.v` would drop every one of those blocks at `size_blocks` (`floppy_sd_writer.v:121`) - an 800K volume whose second half vanishes at the next mount. The latch may still *capture* the byte on such a file; it just cannot take effect, so the decoder needs no special case.

3. **The medium**, from two sources:
   * **Mount-time sniff.** Read the MDB and compute `drNmAlBlks * drAlBlkSiz`: about 400K means single-sided, about 800K double-sided. File sector 2 is at byte 1024 under *both* geometries, which is what makes this possible at all, and `drNmAlBlks`/`drAlBlkSiz` sit at MDB offsets 18/20 in **both** MFS and HFS, so only the signature test (`D2D7` MFS, `4244` HFS) differs. **Do it in `floppy_loader.v`, not `floppy.v`:** every sector already streams through the loader's staging BRAM (`floppy_loader.v:114`), word-indexed, so latching words 0, 9, 10 and 11 while `sector == 2` goes by is three compares, needs no mux on the encoder's `addr` (an `output reg` inside the encoder, not a port `floppy.v` owns), and the verdict is valid at the same `done` pulse that gates `insertDisk`. An unrecognised MDB (a zero-filled file, a non-Mac disk) means "medium says nothing" and the rule above falls through to double-sided on an 800K drive - a blank diskette in an 800K drive is formatted however the user chooses.
   * **Latch during a format.** Extend `S_AMRK` from a 2-byte walk to 4 (`t s h f`) and capture **bit 5** of `f` - the low five bits are the interleave code, not part of the sidedness. Check the field's checksum (`t^s^h^f == c`) before latching, so a mis-synced match cannot flip the medium; the walk is reading past `f` anyway. No volume exists yet at format time, so nothing can be sniffed; the latch is what lets the newly written geometry take effect immediately, so the DIP writes its volume with it.

**Consistency is the whole point.** Report `$02` at format and `$22` on the next mount and you manufacture precisely the image that needed repairs. A session-only latch is worse than doing nothing. Within a session the latch overrides the sniff (a format happens after a mount); at the next mount the sniff reads the MDB the DIP wrote, so the two agree by construction.

**Consequence for the 64K-ROM models (Daniel's question, and the reason `media_ds` must drive the addressing too).** A 400K volume stored in *interleaved side-0 slots* is unreadable by a 128K/512K by construction, because those models run `sides=0` and address linearly: track 1 side 0 is file sector 24 on a Plus and file sector 12 on a 512K. With `media_ds` driving `geom_base`, an 800K file carrying a 400K volume is addressed **linearly**, the volume occupies the first 409,600 bytes, both machines read it identically, and the file's first half is byte-for-byte a standard 400K `.dsk` - so it stays portable. And the reverse direction works too: a 512K formats an 819,200 file as 400K, linearly, and a Plus then sniffs it as single-sided and mounts it. A 400K volume in an 800K file can be created on any model.

The mount gate (`MacPlus.sv:1138`/`1154`) loses its `drive800k` term: an 819,200 file mounts on any model. The gate was a leftover of MAC128K_PLAN.md item 8, kept as "refuse what the drive can't read" after the real fix moved to the mechanism register; a real 400K drive does not refuse an 800K disk, it reads side 0 and the 64K ROM says "unreadable, initialise?". Today such a file sets neither `dsk_*_ds` nor `dsk_*_ss`, so `insertDisk` never fires and the Mac sees an empty drive (confirmed on hardware 2026-09-09: "it didn't mount, it's locked out"). The comment above that gate goes with it.

The one place the core still diverges from a real 400K drive: reading an interleaved 800K image, a real drive gets the disk's true side 0 on every cylinder, while linear addressing hands the 512K file sectors 12-23 as cylinder 1 (really cylinder 0 side 1). Both are garbage past sector 11 to a 64K ROM, and sector 2, where the verdict is made, is the same under both layouts, so the outcome is the same. The only image where a real Mac would see something different is an MFS volume formatted on 800K media - rare enough to note and not design for.

#### Corrections folded in after review (2026-09-09)

* **The ceiling, not a fallback.** The first draft ranked the format latch above the file size. That would have turned the Two-Sided erase of a 400K image, benign today and required to stay so, into silent data loss (term 2 above).
* **No refusal on the 64K models, and no "double-sided until formatted".** Both were the core protecting a machine that on real hardware protects itself. A 64K model sees every diskette as single-sided; the drive is the ceiling (term 1). The first draft's fallback would also have stopped a 512K formatting a blank 819,200 file.
* **The sniff does not gate the mount.** With refusal gone, nothing about `insertDisk` depends on the sniff. It still belongs in the loader because it is simpler there, not because the timing needs it.
* **"Blank" images: two things were conflated.** Main cannot *create* an image from the OSD, and a 0-byte S-mount cannot grow (writes are clamped to `size - offset` - verified in Main's source during the UK101 save work). That needs Main. A zero-filled 819,200-byte file made offline (`head -c 819200 /dev/zero > x.dsk`) is an ordinary mountable image; the encoder presents it as a formatted disk of zero sectors, the Mac offers Initialize, and the format runs through the Phase 6 relay. The GCR stream never contains a zero byte (lowest nibble `$96`), so `floppy.v:452`'s zero sentinel is not in play. **Formatting such a file is untested on hardware** - a one-minute experiment on the current rbf, no compile.
* **The scratch artefact from measurement 2 becomes unreadable.** The sniff cannot tell a linear 400K image from the interleaved one `mk400in800.py` built - sectors 0-11 agree under both layouts - and this phase chooses linear. No image any shipped rbf has produced is affected: a One-Sided erase today yields an 800K HFS volume, which sniffs as double-sided.
* **The "cheap partial" (zero side 1 on a One-Sided format) is moot.** With `media_ds` low the volume never addresses the second half of the file, so the stale data is no longer in reported-free space. It stays in the file for anyone inspecting it offline; one sentence in the readme covers that.

#### Verification (benches first, per this project's convention)

1. a failing bench for the defect itself: the format byte reported after a One-Sided format must be `$02`, not `$22`;
2. `S_AMRK` capture: a format burst carrying `$02` sets `media_ds` low, one carrying `$22` sets it high, an ordinary sector write changes neither, and a field with a bad checksum changes neither;
3. the sniff: MFS 391x1024 and a ~400K HFS both yield single-sided; HFS 1594x512 yields double-sided; a zeroed image says nothing (falls through to the drive);
4. addressing: with `media_ds` low on an 819,200 image, track 1 side 0 sector 0 resolves to file sector 12, not 24 - and a side-1 field is rejected;
5. all Phase 6 benches still pass unchanged;
5b. **a disk change clears the format latch** - erase One-Sided, swap the disk, and the new medium's own verdict governs. Added after a mutation sweep found nothing testing it;
6. **the ceiling:** a `$22` format burst on a 409,600 mount leaves `media_ds` low, the first address field read back carries `$02`, and a side-1 field is still rejected - the guard for the 400K-image behaviour Daniel wants kept; the mirror case, the same burst on an 819,200 mount, sets `media_ds` high and reads back `$22`;
7. **the drive:** with `drive800k` low, an 819,200 mount carrying an 800K HFS MDB still has `media_ds` low and addresses linearly.
8. **the sniff on its own (added in review, 2026-09-09):** an 819,200 mount with `mediaSides` low and nothing latched is single-sided - reads back `$02`, addresses track 1 linearly, refuses side 1 - and a Two-Sided burst over it takes. Every single-sided result in 1-7 came from the latch or a ceiling with `mediaSides` held at 1, so the seam between the sniff and the addressing - the path a One-Sided-erased 800K image follows at its next mount - had no check, and a mutant ignoring the sniff (`fmtSeen ? fmtDs : 1'b1`) passed all 30. The commit's "the sniff ignored" mutation had only tried the `1'b0` form, which check 1 catches. Now 35 checks; the `1'b1` mutant fails four.

Mutation sweep as in Phase 6, and note the standing lesson: three of this project's mutation findings have been defects in the *bench*, not the RTL.

#### What was built

Six files, no new modules (nothing to add to `files.qip`).

* **`rtl/floppy_loader.v`** - the mount-time sniff. Sector 2's words 0, 9, 10 and 11 are latched out of the staging BRAM as they stream past (`mdb_wr`), bounds-checked, and `drNmAlBlks * (drAlBlkSiz/512)` compared against 1200 blocks - halfway between a 400K volume's 800 and an 800K volume's 1600. The multiply is a seven-cycle shift-add rather than a 16x7 array or a DSP block; it starts when word 11 lands and finishes hundreds of thousands of cycles before `done`. New output `media_ds`, published at `DONE_PULSE` so it is valid on the same edge as `done`.
* **`rtl/floppy_track_decoder.v`** - `S_AMRK` walks the whole address field (`t s h f c`) instead of stopping after `s`. `amark` still fires on `s`, on the same byte as before, because the encoder's relay measures the head from it. New outputs `fmt_mark`/`fmt_ds`, gated on the field's own checksum.
* **`rtl/floppy.v`** - `diskSides` renamed to `img800k` (it only ever meant "the file is 819,200 bytes"), new input `mediaSides`, and `doubleSidedDisk` becomes `drive800k && img800k && (fmtSeen ? fmtDs : mediaSides)` - the three ceilings, with the format latch cleared by the same `writePathReset` that clears the decoder feeding it.
* **`rtl/iwm.v`, `rtl/dataController_top.sv`** - the rename and the new signal, straight through.
* **`MacPlus.sv`** - the mount gate loses its `drive800k` term; `dsk_*_ds` now means only "819,200-byte file". Each loader's `media_ds` is wired to its drive.

#### Verification

Two new benches, both green, plus the Phase 6 gates unchanged.

* **`sim/tb_floppy_sides.v`** - the floppy-level checks above, driving `img800k`, `drive800k` and `mediaSides` independently so each ceiling is pinned against the others. Check 8 (the sniff alone) was added in review; see item 8 above for the mutant it exists for.
* **`sim/tb_floppy_sniff.v`** - the sniff, on eleven images: MFS 391x1024 and HFS 395x1024 (single-sided), HFS 1594x512 and 797x1024 (double-sided), a zero-filled image, an unrecognised signature, a `drAlBlkSiz` that is not a multiple of 512, one above 64K, one of 32768 (the only value that sets the multiplier's top bit), an image with no sector 2, and a remount.
* **Regression:** `tb_floppy_format` (FORMAT RELAY GATE: PASS), `tb_floppy_write_path` (PHASE 3 WRITE-PATH GATE: PASS), `tb_floppy_track_decoder`, `tb_floppy_track_encoder`, `tb_floppy_loader`, `tb_drive_sides` (ITEM 8 GATE: PASS), `tb_drive_tach`, `tb_iwm_latch`, `tb_iwm_dcd` - all pass, none with an RTL change.
* **Mutation sweep, `floppy.v` and `floppy_track_decoder.v`:** eleven mutations - each ceiling dropped in turn, the latch ignored, the sniff ignored, the latch surviving a disk change, the format byte read from the wrong bit and from the wrong byte, the checksum gate removed, `f` never captured, and the latch disabled outright. One survived: **nothing tested that a disk change clears the latch.** It matters more than most - a latch outliving its medium would address the NEXT disk with the previous one's geometry, the same corruption this phase removes, aimed at a disk that was never touched. Check 4b was added for it and both mutations now die.
* **Mutation sweep, `floppy_loader.v`:** twelve mutations, all caught. Three of them were only caught after the bench was strengthened, and the reason is worth keeping: the multiply's seventh bit, and the `drAlBlkSiz` high-word bound, were **unreachable from any of the original cases** - every real floppy volume uses a 512- or 1024-byte allocation block, so the top of the RTL's own admitted input range had no test. The fix was to add cases at the bounds the RTL admits, not to narrow the RTL. This project's sweeps have now found gaps in the BENCH rather than the RTL well over a dozen times; this phase added three more, plus the two bench defects below.

Two defects were found during verification and both were in the benches, not the RTL:

1. `tb_floppy_sniff.v` bracketed each mount on the `done` pulse. `done` is high during the cycle in which the loader is already back in `IDLE`, so a `wait (done)` posted right after the previous mount returns sees that same pulse and falls straight through - the second mount never ran and the bench read the FIRST image's verdict believing it was the second's. Now bracketed on `busy`.
2. `tb_floppy_sides.v` read the commit counter as soon as `feed_burst` returned, but the write ends slightly before `floppy_write_committer.v` has drained the sector, so the addressing checks were reading the PREVIOUS sector's landing address - in a bench whose entire subject is where a sector lands. One extra cycle was all it needed; it now waits for its own commit, bounded, since a refused field never produces one.

**STATUS: implemented, benched, mutation-swept. NOT compiled, never on hardware.** Phase 6 is unaffected and its gate still passes. The hardware test when this is next built: erase an 800K image One-Sided, confirm the Finder reports a ~400K disk, and check offline that the volume occupies the first 409,600 bytes linearly and that free space contains none of the old contents - the 617 recoverable allocation blocks that started this phase.

---

### Phase 8 - The SD writer keeps no copy of the data (SDRAM-sourced, unbounded backlog)

**The defect, found 2026-09-16 on the MacLC port of this exact module** (danielb0/MacLC_MiSTer, `floppy-write` at `ce07e67`, which carried a witness word the Plus never had). `rtl/floppy_sd_writer.v` holds two 256x16 shadow copies of committed sectors. A commit that arrives while both are still owned - queued, or mid-`sd_wr` - is captured into the buffer of an entry that has not drained yet: the header's own "third commit reuses the still-in-flight buffer" limit. On the LC a 450 KB Finder copy (Speedometer 3.23, ~900 sectors) hit it twice, and the image on the card had **four wrong sectors** in the application's resource fork - one never written, one torn, two carrying mixed data - while `hfs_check` reported the volume consistent, the disk mounted and listed normally, and the guest's own verify passed, because the verify reads SDRAM, which is right. Silent, and exactly the looks-fine-until-a-file-is-lost class.

**Reproduced here first, on the shipped RTL (2026-09-17).** A scratch bench against the current `floppy_sd_writer.v`: commit A, commit B, hold `sd_ack` off, commit C, then serve. The block hps_io streamed for A's LBA was C's data, 256 of 256 words wrong, and C's own LBA was never presented at all - one sector wrong on the card and one lost, from three commits during a single stall. That is the failing test this phase starts from.

**Why a fixed depth cannot be made safe.** Main opens a writable image `O_RDWR|O_SYNC` (`user_io.cpp`, `user_io_file_mount`), so every 512-byte block is a synchronous card write with exFAT bookkeeping behind it, and sync latency is bursty - tens to hundreds of milliseconds. Sectors arrive at the encoder's fixed cadence of 12.5 ms (782 byte cells x 16 us, every zone). Two buffers absorb one hiccup; a longer stall overwrites. Deepening the queue moves the cliff, it does not remove it, and the failure at the cliff is a torn sector, not a refusal.

**Why it has never shown here, and why that proves nothing.** The largest sustained burst this core has run is Erase Disk (Phase 6): 1600 sectors gapless, byte-verified offline with zero survivors. But every format sector carries the same all-zero data field, so a torn write between two of them is byte-identical to a correct one; the erases bound only the 4-deep class (an `addr_q` entry overwritten before it drains, which leaves an old sector standing) at < ~1.25e-3 per sector and say nothing about the 3-deep one. Every other write test copied small files. The Phase 5 "stress the commit-queue depth" bullet was never run. MacPlus is raw-only - one sync write per sector, no read-modify-write - so it has ~4x the LC's slack: rarer, not immune. Its own aggravator is that six slots share one hps_io poll loop (`MacPlus.sv`, the `sd_rd`/`sd_wr` vectors): SCSI, CD and HD20 all contend with the floppy write slots, so the worst realistic case is a file copy onto a floppy while CD audio plays.

**The fix is the LC's, ported, not redesigned** (danielb0/MacLC_MiSTer `floppy-write-sdram-src`, `60d1e95` + `ce07e67`, hardware-gated there 2026-09-16: the same 450 KB copy, zero refusals, both forks byte-identical to the source, on a DC42 and on a raw image). The writer keeps **no copy of the data**:

1. **Queue sector NUMBERS.** On `commit_done && !readonly` push `commit_addr[21:9]` into a FIFO, 1024 x 13 bits (two M10K). `floppy_write_committer.v` has already landed the sector in SDRAM, and SDRAM always holds the newest version, so a sector re-written while still queued is queued twice and written twice with the latest contents - no dedupe, no bitmap, no in-flight tracking. 1024 pending is ~13 s of backlog at one sector per 12.5 ms; if even that fills the push is **refused and counted** (`dbg[31:24]`), never overwritten. That is the one loss path left, and it is loud.

2. **Fetch the block from SDRAM at write time** into ONE 256x16 buffer, then present it to hps_io exactly as the shadow was (same output byte swap: SDRAM words are in the internal even-byte-high convention, the wire is the opposite). The committer's `sd_buf_*` shadow tap, and the `dskCommitBuf*` ports that threaded it through `floppy.v`, `iwm.v` and `dataController_top.sv`, go away.

3. **The SDRAM read path is the part that does not port.** The LC shared its controller's Ethernet-DMA requester; this core's `rtl/sdram.v` is the MiST original and has no such port. What it has is `addrController_top.v`'s extra slot 3, today a write-only port for the loader and the committer. It gains a READ requester pair (`dskFetchAddrInt/Ext`, `dskFetchReqInt/Ext`, `dskFetchAckInt/Ext`, `dskLoadRdEn`) on the same protocol the write side was fixed to in Phase 1: the request is sampled once at the bus-cycle boundary (`busPhase == 3`), the grant and the address selection are held for the whole four-phase cycle, and the ack is a late pulse in `busPhase 3`. `sdram.v` issues ACTIVE from the values present in busPhase 0, the column from busPhase 1, and captures the read word at the end of busPhase 2 (`STATE_READ`), so the word sits in `dout` for the whole of busPhase 3 and the requester captures it on the same edge it sees the ack. `sdram.v` itself is untouched; `MacPlus.sv` adds `dskLoadRdEn` to `sdram_oe` and to the disk-region address select, and hands the writers `sdram_out`. Priority among the four registered requests is loader int, loader ext, fetch int, fetch ext - the fetch is the only client that can afford to wait. Each requester's selection comes from its own registered request, so a committer write and a writer fetch on the same slot interleave word by word without either losing one; the loader/committer data mux in `MacPlus.sv` is not touched.

   Bandwidth: slot 3 recurs every 16 clk8 (~2 us), so a block fetch is ~0.5 ms alone and ~1 ms with the committer draining the next sector on the same slot, against the 12.5 ms sector cadence.

4. **A remount ABORTS the writer** - FSM to idle, both request lines low, FIFO emptied - not just the queue. The inherited "clear the queue but leave `pstate` alone" was safe only while a sector was one hps_io request; the LC found the loader's acks on the shared slot walking a running FSM into an `sd_wr` against the new image. Here a sector is still one request, so it is latent, but the abort costs nothing and the bench pins it. A fetch withdrawn by the abort is harmless: the slot performs one read nobody consumes, and the writer only acts on an ack while its own request is up.

5. **Unchanged:** `readonly` as the gate, `size_blocks` refusal, and the ack-timeout RE-PRESENTATION of the same block (hps_io captures `sd_lba` in one poll and acks in a later one, so a retired entry plus a late ack would stream a different block to a captured LBA).

6. **A witness word** (`dbg`): `{refused[7:0], out_of_range[7:0], landed[7:0], 5'b0, pstate[2:0]}` per writer, the two writers packed into one new `PFSW` probe in `rtl/dbg_probes.sv` (`PRG1`, the older half of the SCSI access ring, is retired to make room: the deck's own header names it the cheapest thing to lose, and the wedge it served is closed). `scripts/read_probes.tcl` decodes it. The gate condition is refusals == 0 after a sustained copy - the instrument that found the defect on the LC, and the only way a clean copy here means anything.

**One defect found in the LC's version while porting (2026-09-17), fixed here and to be reported back.** Its `P_IDLE` pops the queue with `rd_ptr <= rd_ptr + 1` and reads the head through a registered `q_head`, which lags the pointer by one cycle. On the ACCEPT path that is harmless - the FSM leaves `P_IDLE` for hundreds of cycles - but on the REFUSE path (out of range) it stays in `P_IDLE`, and the very next cycle pops again against the stale head: with `[X(out of range), Y, Z]` queued, X is refused twice, Y is written, and Z is never written. Rare (an out-of-range sector needs a malformed image or `track` past the file's end) but it loses a sector. The refuse path here goes through a one-cycle `P_SKIP` state so the head has moved on before the next pop, and the bench queues exactly that sequence.

#### Verification (benches first, per this project's convention)

1. **The failing test: the current writer, three commits during one stall** (above). Scratch-only, against the shipped RTL; the scenario is section 8 of the new bench.
2. **`sim/tb_floppy_sd_writer.v` rewritten** around a slot-3 model (requests sampled at the bus-cycle boundary, one grant per 16 bus cycles, a one-clock ack, the word read out of a modelled SDRAM that FAILS the run on any fetch address outside the image): byte order (the headline check - the swap must mirror `floppy_loader.v`'s); read-only refusal; out-of-range refusal counted, and **refuse-then-two-more** (the LC defect above); remount drops the queue; ack timeout re-presents the same block; commit order; remount mid-fetch aborts (request low, the slot's stale grant harmless, no `sd_wr` on the loader's acks, the next sector clean); **three commits during one stall all land intact and in order**; **a sector re-committed while queued is written twice with the newest data**; **a full queue refuses and raises the witness, never overwrites**; reset after activity.
3. **`sim/tb_slot3_fetch.v`, the seam:** the REAL `addrController_top.v` with the two-phase SDRAM model from `tb_floppy_loader_integrated.v` (RAS from busPhase 0, CAS from busPhase 1, and now the read word at the end of busPhase 2), the REAL `floppy_write_committer.v` and the REAL `floppy_sd_writer.v`, with the committer draining sector N+1 while the writer fetches sector N on the same slot. Every committed word lands, every fetched word is the one SDRAM holds, and the ack and the data agree in phase.
4. **`sim/tb_loader_writer_roundtrip.v`** updated: the writer now fetches from a mock SDRAM holding internal-convention words; the loader must recover them byte-exact from what the writer put on the wire.
5. Every bench that instantiates `addrController_top`, `floppy.v`, `iwm.v` or the committer updated for the port changes; all floppy/IWM regression benches still pass.
6. Mutation sweep on the writer and the arbiter.
7. `quartus_map --analysis_and_elaboration`, then (gated) a compile.
8. **Hardware gate:** a ~450 KB Finder copy onto a floppy image, with CD audio playing (the worst realistic case), `PFSW` refusals == 0, then a byte-for-byte diff of the copied files' forks against the source volume (`scripts/hfs_integrity.py`). Structure checks alone pass on a corrupt copy - they did on the LC.

#### What was built (2026-09-17)

* **`rtl/floppy_sd_writer.v`** - rewritten as above: `q_mem` (1024x13), `blk` (256x16), states `P_IDLE/P_SKIP/P_FILL/P_WR/P_WAIT_ACK/P_WAIT_DONE`, `fetch_addr/req/ack/data` port, `dbg` witness.
* **`rtl/addrController_top.v`** - `dskFetchAddr/Req/AckInt/Ext`, `dskLoadRdEn`; the fetch request registers sit beside the load ones, the grant excludes any load request, the address mux gains one line. The write side is byte-identical.
* **`MacPlus.sv`** - `dskLoadRdEn` into `sdram_oe` and `dsk_cycle`; writers wired to the fetch ports and `sdram_out`; the `wc_*_commit_buf_*` wires gone; `wr_int_dbg`/`wr_ext_dbg` into the probe deck.
* **`rtl/floppy_write_committer.v`, `rtl/floppy.v`, `rtl/iwm.v`, `rtl/dataController_top.sv`** - the shadow tap and its `dskCommitBuf*` ports removed.
* **`rtl/dbg_probes.sv`, `scripts/read_probes.tcl`** - `PFSW` in `PRG1`'s node, decoded per writer.

#### Verification

* `sim/tb_floppy_sd_writer.v`: 11 sections, **5433 checks, 0 failures**. `sim/tb_slot3_fetch.v`: **784 checks, 0 failures** (one bench defect on the way: its stray-read counter also counted the IWM read windows, which read address 0 in that bench - now only a fetch outside the image counts). `sim/tb_loader_writer_roundtrip.v`: PASS.
* Regressions re-run green: `tb_floppy_format`, `tb_floppy_sides`, `tb_floppy_loader_integrated`, `tb_floppy_loader_ext`, `tb_iwm_dcd`, `tb_iwm_latch` (its header's build line predates the DCD work - add `rtl/dcd.v rtl/dcd_link.v rtl/dcd_disk.v rtl/scsi.v`), `tb_floppy_write_path`.
* `quartus_map --analysis_and_elaboration`: **0 errors, 83 warnings - the identical set the untouched branch head produces** (re-measured by stashing the change; the only diff is line-number shifts in `dbg_probes.sv`). The connectivity report has nothing on the new ports.
* **Mutation sweep, 21 mutants over the writer and the arbiter: all killed** - after two survivors of the first pass were dealt with (`c6a0c99`). One was a bench gap of the recurring shape: a writer that retired the block on the ack's RISE rather than its fall only overwrote words the model had already read, because the model streamed a block in ~770 cycles against a ~16,000-cycle fetch. Section 12 now streams slowly (25,600 cycles under the ack) with the next sector queued, and pins that no `sd_wr` rises while the ack is up. The other was an equivalent mutant - the read-only gate was checked twice - now single-sourced as `accept`/`push`. 5950 checks.
* **Cold compile (2026-09-17, tag `c6a0c99f`): 0 errors, timing met** - worst setup slack 0.520 ns (the HDMI PLL domain; 1.415 ns on the core's PLL), hold 0.243 ns; 20,655 / 41,910 ALMs (49%), 135 / 553 RAM blocks; each writer's `q_mem` is two M10K and its `blk` one, as intended. rbf: `output_files/MacPlus_c6a0c99f_sdwriter.rbf`.

**STATUS: implemented, benched, mutation-swept, compiled. NOT yet on hardware.** The hardware gate is item 8 above.

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
