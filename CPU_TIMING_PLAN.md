# CPU timing: RAM contention with video

Branch `cpu-timing`, cut from `sound-phase` (`819c321`) because that holds the
newest RTL, and the sound-margin work interacts with CPU speed (see Risks).

## Where the core stands

At 8 MHz the core runs RAM-bound code 30-50% faster than the real machines.
Speedometer 3.2, System 6.0.8, same disk image:

| Machine              | CPU   | Graphics | Math  |
|----------------------|-------|----------|-------|
| Real Plus            | 0.880 | 0.933    | 0.996 |
| Core, Plus mode      | 1.355 | 1.132    | 1.201 |
| Core, SE mode        | 1.30  | 1.08     | 1.05  |
| Real SE (Low End Mac)| 0.98  | 0.98     | 0.99  |
| Classic (baseline)   | 1.00  | 1.00     | 1.00  |

Two causes:

1. **No video contention (the main one).** `MacPlus.sv` `_cpuDTACK` acknowledges
   every RAM and ROM access at once. The SDRAM slot scheme
   (`addrController_top.v`, `busCycle`) gives video and sound their own slots, so
   the CPU never waits. Inherited from upstream (`134c5db`).
2. **The clock is 3.7% fast.** The core's CPU clock is 8.125 MHz (32.5 MHz / 4)
   against 7.8336 MHz, while Speedometer times against the 60 Hz tick.

## What the real machines do (Guide to the Macintosh Family Hardware, 2nd ed., ch. 5)

- **Plus, and the other classic models (128K, 512K):** "one out of every two RAM
  access cycles is devoted to video data during a scan line." The last RAM
  access before a scan line is the sound and disk-speed fetch. Average CPU RAM
  rate is **2.56 MB/s** (Table 5-3).
- **SE:** "one longword video access is made for each four RAM access cycles
  during a scan line", plus the same sound fetch. Average CPU RAM rate is
  **3.22 MB/s**.
- **ROM is never interleaved:** **3.92 MB/s** on both. That is one word per
  4-clock bus cycle, so ROM has no wait states.

Cross-check from first principles (352 CPU clocks per line, 256 active; 370
lines, 342 active; 60.15 Hz; one RAM cycle = 4 clocks):

- **Plus:** 342 x (32 + 23) + 28 x 87 = 21,246 CPU cycles per frame, which is
  **2.556 MB/s**.
- **SE:** 342 x (48 + 23) + 28 x 87 = 26,718, which is **3.21 MB/s**.

Both match the Guide, so the slot model is right at the level of averages.

**Not yet settled: alignment.** Real RAM cycles run on a fixed 4-clock grid set
by the TSM PAL. The 68000 can begin a bus cycle 2 clocks off that grid after an
internal operation. The open question is whether it then waits for the next grid
slot, and whether that applies in blanking and to ROM too. If it does, that is a
cost on top of the bandwidth average and could account for several percent.
This is the open question from the 2026-10-11 analysis; Phase 0 settles it from
the PAL equations.

## Target design

A wait-state generator that holds `_cpuDTACK` on CPU **RAM** accesses at 8 MHz
until the access falls in a CPU-owned slot:

- **Slot grid:** 4 CPU clocks per slot, the core's existing `busCycle` period.
- **Active display:** on the Plus, 128K and 512K (`machineType = 0`) every other
  slot belongs to video. On the SE (`machineType = 1`) one slot in four does.
- **Blanking:** every slot belongs to the CPU, except one sound/disk-speed slot
  per Mac scan line.
- **ROM and I/O:** unchanged, unless Phase 0 shows a grid wait for ROM.
- **Turbo (16 MHz):** unchanged. It is the deliberate non-authentic option.
- **No OSD option.** Authentic timing becomes the 8 MHz behaviour.

**Timing reference: the core's own display, not a virtual Mac raster.** We take
"active" from `videoTimer.v` (`_hblank`, `_vblank`), so the CPU slows down
exactly while the beam the software can see is drawing. The core's raster is
VGA-shaped (168 x 806 at the CPU clock, each Mac line drawn twice). Its CPU
share per frame works out within about 2% of the real machine's:

- **Core:** 684 x (16 + 10) + 122 x 42 - 370 = 22,538 slots in 135,408 clocks,
  which is 0.666.
- **Real Plus:** 21,246 x 4 / 130,240 = 0.652.

A virtual 352 x 370 counter would match the real ratio exactly. But it would
drift against the frame that VBL-synchronised software actually sees.

**Mechanism.** We hold DTACK and the CPU stays in S4/S5. `dataController_top.sv`
re-latches `cpu_data` on every CPU slot from the held address, so reads stay
correct. Writes repeat harmlessly. Turbo's `turbo_dtack_en` and the SCSI
`scsi_bus_hold` already stretch cycles this way.

## Phases

**Phase 0: settle the real timing from the PALs (no RTL).**
- Transcribe the TSM (16R4) JED2EQN equations from `C:/temp/Mac/PALs/pals.txt`
  into a cycle model clocked at C16M. Pin map: i2 C16M, i3 C8M, i4 VID/u*,
  i5 /RAM, i6 /ROM, i7 /AS, i8 /UDS, i9 /LDS; rf14 /RAS, rf15 TC, rf16 C1M,
  rf17 C4M; f12 /CASL, f13 /CASR, f18 C2M, f19 /DTACK.
- Drive it with 68000 bus cycles that start at each phase of the grid, with
  VID/u* held at "video" and at "CPU".
- Tabulate the DTACK latency for each case: RAM vs ROM, on-grid vs off-grid,
  active vs blank.
- Cross-check against the Guide's 2.56 and 3.92 MB/s.
- Gate: the table exists and reproduces both rates. If the JED equations will
  not yield a consistent model, fall back to the Guide's description and record
  that choice.

**Phase 1: failing bench.**
- An iverilog bench of fx68k against the real address/DTACK path, running a
  RAM-bound loop and a ROM-bound loop.
- It measures clocks per iteration and asserts the Phase 0 prediction for
  active-display, blanking and SE cases.
- It must FAIL on the current RTL: RAM runs at ROM speed.

**Phase 2: implement.**
- The wait generator goes in `addrController_top.v`, next to `busCycle`; the
  DTACK term goes in `MacPlus.sv`.
- Model-gated on `machineType`; bypassed under `status_turbo`.
- Gate: Phase 1 passes. The ROM loop and turbo are unchanged.

**Phase 3: regression sims.**
- Re-run the existing benches that drive the CPU or bus timing: floppy, DCD,
  SCSI back-pressure (`seam20`), and the sound-phase probe.
- Mutation check: removing the gate must fail Phase 1.

**Phase 4: hardware (compile is GATED: ask first).**
- Speedometer at 8 MHz, Plus and SE modes.
- Targets: Plus CPU about 0.91 (0.88 x 1.037 for the clock), SE about 1.02.
  Graphics and Math should fall towards 0.93 and 1.00.
- Regression set:
  - chime and boot from floppy, HD20 and SCSI
  - CD audio
  - Lode Runner
  - PoP
  - Lemmings sound margin (see Risks)
  - Bard's Tale at phase 0
  - Erase Disk

**Phase 5 (optional): the 3.7% clock.**
- Only if Phase 4 lands within the clock error and the user wants the last few
  percent.
- Options: an occasional extra wait state (one in about 27 slots), or a PLL
  change. A PLL change moves video, so prefer the wait state.

## Risks

- **Lemmings sound margin.** The mouse-fix measurements (4 words at phase 0,
  Very Slow) were taken on the fast core. A slower CPU spends longer in the
  mouse interrupt per frame, so the margin will shrink and may go negative. That
  would be the authentic behaviour, but it must be measured, not assumed. The
  phase selector is the instrument, as before.
- **Timing-tuned drivers.** DCD, floppy and SCSI pseudo-DMA were all
  hardware-tested on the fast core. A slower CPU moves them TOWARDS what the ROM
  was written for, so failures are unlikely but possible where we tuned a
  constant to the fast core. The `BYTE_TICKS` turbo halving is turbo-only and
  unaffected.
- **Games that ran "fine" because they were fast.** Expected and correct. Note
  them in the game-compat sheet rather than treating them as regressions.
- **Alignment cost (Phase 0) might be large.** If off-grid waits apply
  everywhere, ROM-bound code slows down too, and Graphics and Math on the core
  must fall further. The table decides; the design adapts.

## Out of scope

- The SE/30, LC and other cores.
- The third-party Classic fork. It inherits the fix if it rebases.
- An OSD "fast RAM" option. Turbo already covers "faster than real".
- Video output timing. The raster stays VGA-class (see the video-output note).
