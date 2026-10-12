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

**Alignment: SETTLED by Phase 0 (2026-10-12).** The TSM snaps every RAM and
ROM bus cycle to a grid, in blanking as well as display. Let phi be the C8M
clock (0-7) within the 1 MHz C1M period at which the bus cycle's S0 falls. The
wait states are then:

| Access | Waits | Effect |
|---|---|---|
| ROM (also IWM and SCSI, which the BMU decodes as /ROM) | (1 - phi) mod 4 | 4-clock grid |
| RAM, blanking | (1 - phi) mod 4 | 4-clock grid |
| RAM, display | (5 - phi) mod 8 | one CPU slot per 8 clocks |
| SCC (/RAM and /ROM both low) | 1 + (4 - phi) mod 8 | C1M sync, at least 1 wait |

These are the wait states between S4 and S5. Back-to-back cycles stay on the
grid at no cost, so the Guide's 2.56 and 3.92 MB/s averages are reproduced.
A cycle that starts 2 clocks off the grid, which happens after any 2-clock
internal operation, pays 2 extra clocks. That applies to ROM and in blanking,
where the core today pays nothing. It is the "unexplained remainder" from
2026-10-11, and it is why Graphics and Math (ROM-heavy) are also ~1.2x fast on
the core.

The result is the same with 0 and 2 half-C16M steps of CPU-to-PAL delay, so it
is a property of the equations, not of the timing assumptions. Free-running
outputs are also consistent: C1M 1 MHz, C2M 2 MHz, one RAS per 4 clocks, and
a video CAS once per C1M during display. Model: `scripts/tsm_pal_model.py`.
It matches Jecel's account (`C:/temp/Mac/PALs/mac512.html`): during display "wait
states were inserted to make memory access take up eight full clocks", and in
retrace the CPU runs at full speed.

**SE: no equations exist** (the BBU is a gate array). Jecel says the SE's memory
timing "was unchanged from the original design" apart from page-mode video
reads. Assumption: the same 4-clock grid, with display RAM losing one 4-clock
slot in four (16-clock period) instead of one in two. The acceptance test is
Speedometer against the real SE's 0.98.

**SE caveats: everything for the SE is assumption, and only the average is
testable.**
1. **The bus grid is assumed.** No BBU logic exists to simulate.
2. **Sound phase 0 is a Plus result.** It came from the Plus LAG PAL, schematic
   and ROM. The SE generates VSYNC and the sound scan inside the BBU, and its
   phase has never been checked.
3. **The interrupt latency is unmeasured.** The SE's VBL handler also services
   ADB, so lat is probably longer.
4. **PoP on the SE is marginal.** Under the assumed timing a display word costs
   37-40 clocks against the Plus's 56. That is clean for lat >= 3 words, or for
   40+ clocks per word, but word 36 is overwritten at 36 clocks with lat 2-2.5.
   The Plus margin is wide; the SE margin is not.
5. **There is no real SE to test on.** The only acceptance check is Speedometer
   CPU against Low End Mac's 0.98 (System 7.5.5, Speedometer 3.06). That tests
   the average slowdown, not the alignment or the sound phase. PoP-on-SE
   results from the core say nothing about a real SE.

**128K/512K:** BMU0 instead of BMU2, but the same TSM design ("still the same
design", Jecel). They use the Plus rules.

## Target design

A wait-state generator that holds `_cpuDTACK` at 8 MHz until the access falls
on its grid point, per the Phase 0 table:

- **Slot grid:** 4 CPU clocks per slot, the core's existing `busCycle` period,
  plus one bit for the 8-clock C1M period.
- **Active display:** on the Plus, 128K and 512K (`machineType = 0`) every other
  slot belongs to video. On the SE (`machineType = 1`) one slot in four does.
- **Blanking:** every slot belongs to the CPU, except one sound/disk-speed slot
  per Mac scan line.
- **ROM, IWM and SCSI:** the 4-clock grid always. Display never affects them.
- **SCC:** C1M sync, at least one wait.
- **VIA:** unchanged. It is VPA/E-clock synchronised, which fx68k already models.
- **SCSI back-pressure:** `scsi_bus_hold` stays ORed in on top.

Because each rule is "waits = (target - phi) mod G", DTACK reduces to a fixed
phase window: assert it only when the S4 sampling edge falls at the grid point.
That is a gate on a phase counter, not a state machine.
- **Turbo (16 MHz):** unchanged. It is the deliberate non-authentic option.
- **No OSD option.** Authentic timing becomes the 8 MHz behaviour.

**Timing reference: a virtual Mac raster locked to the sound scan, NOT the core's
display.**

- One virtual line = one sound word (the existing `audioAddr` advance, about 366
  clocks on the core).
- Line 0 starts at the VBL, when the scan is at word 0.
- Lines 0-27 are blanking.
- Lines 28-369 are active for the first 256/352 of each line.

On a real Plus the line counter that drives video also drives the sound address
and the VBL. Contention, the sound scan and the VBL are therefore one clock
domain, and the software that is timing-critical is all timed against that
domain: VBL-driven buffer fillers and the mouse-interrupt load against the
sound buffer.

We rejected the core's own display (`videoTimer.v` `_hblank`/`_vblank`) as the
reference. It has about 56 words of blanking after the VBL instead of 28, so a
fill routine that the real machine slows down at line 28 would run uncontended
on the core. The displayed beam position was never authentic on the core, so
we lose nothing visible.

The CPU share per frame with the virtual raster is the real 0.652. The core's
display would have given 0.666.

**Worked prediction: PoP. REVISED 2026-10-12: a real Plus plays it CLEAN at
sound phase 0.**

The fill loop, decoded from MDRV 11 at `$28d2`:

| Instruction | Clocks | Bus cycles |
|---|---|---|
| `move.b (a2)+,(a3)` | 12 | 3 back-to-back |
| `lea 2(a3),a3` | 8 | 2 |
| `dbra d6` | 10 | 2 internal clocks, then 2 |

That is 30 clocks for 7 bus cycles. MDRV 22 starts at the same word, 37.

Timed against the Phase 0 table:
- **Blanking: 32 clocks per word.** The `dbra` internal clocks put the next
  fetch 2 clocks off the grid.
- **Display: 56 clocks per word.** All 7 cycles are RAM, at 8 clocks each.

The fill writes words 37-369, then 0-36. `scripts/pop_fill_race.py` runs it
against the scan, with the VBL at word 0 and display from line 28:

| Timing | Wrap at line | Words overwritten before read |
|---|---|---|
| Core today (30, no contention) | ~31 | 33-36: **buzz** |
| Real Plus (32 / 56) | 34.7-36.9 | **none** for any lat >= 0.4 words (measured lat 2-3) |
| Contention without the grid | | clean for lat >= 2.5 |

**The earlier "still buzzes at 34-36" estimate was WRONG.** It slowed only the
first part. The wrap part (0-36) is ALSO written during display, at 6.3 words
per line against the scan's 1, so it never catches the reader.

**Consequence:** the PoP buzz is the core's missing contention, not Presage's
code. The PAL-based conclusion "a real Plus buzzes" assumed equal CPU speed
on both machines. That assumption is what this plan shows to be false.

**Two tests:**
- The real Plus with expanded RAM at sound phase 0: predicted CLEAN.
- The core with this fix at sound phase 0: predicted CLEAN.

If the real Plus buzzes, the model is wrong somewhere, and PoP becomes the
discriminating test for it.

**Sound tests run at Sound Scan Phase 0 only.** That is the real machine's
setting, settled from the PALs on 2026-09-21: the scan is at word 0 when the VBL
fires. The other phase settings are enhancements, not what a Plus does, so a
result there says nothing about authenticity. ("Sound phase 0" is the OSD
setting; "Phase 0" alone is this plan's first phase.)

**Mechanism.** We hold DTACK and the CPU stays in S4/S5. `dataController_top.sv`
re-latches `cpu_data` on every CPU slot from the held address, so reads stay
correct. Writes repeat harmlessly. Turbo's `turbo_dtack_en` and the SCSI
`scsi_bus_hold` already stretch cycles this way.

## Phases

**Phase 0: settle the real timing from the PALs (no RTL).** DONE 2026-10-12,
see "Alignment" above.
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

**Phase 1: failing bench.** DONE 2026-10-12. `sim/tb_cpu_wait.v` runs the REAL
fx68k against `rtl/cpu_wait.v` (a stub that holds nothing, i.e. today's
behaviour). It checks every bus cycle's waits against the Phase 0 table and
the loop periods against hand timing:

| Loop | Bare | Grid | RAM in display |
|---|---|---|---|
| nop/nop/dbra | 18 | 20 | 32 |
| PoP fill | 30 | 32 | 56 |

It also checks ROM, SCC, IWM, the assumed SE rule and turbo. Against the stub:
**FAIL, 15,238 of 16,632 cycles wrong**, loops at 18/30, turbo ok.

iverilog cannot compile fx68k as written (unpacked structs, piecewise-driven
struct ports, enum ?:), so `sim/fx68k_iverilog.py` writes a sim-only copy to
`sim/out/fx68k_sim.sv`: the structs are packed and the driving module's
members are flattened. `rtl/fx68k` is untouched. Run from `rtl/fx68k`, because
fx68k loads its microcode ROMs from the cwd. About 20 s.

Original Phase 1 text:
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
- Regression set, all sound tests at sound phase 0:
  - chime and boot from floppy, HD20 and SCSI
  - CD audio
  - Lode Runner
  - PoP
  - Lemmings sound margin (see Risks)
  - Bard's Tale
  - Erase Disk

**Phase 5 (optional): the 3.7% clock.**
- Only if Phase 4 lands within the clock error and the user wants the last few
  percent.
- Options: an occasional extra wait state (one in about 27 slots), or a PLL
  change. A PLL change moves video, so prefer the wait state.

## Risks

- **Everything calibrated on the fast core must be re-measured.** Anything
  whose timing is pinned to CPU speed moves. That includes the sound-phase
  results at sound phase 0: interrupt latency lat = 2-3 words, PoP buzzing,
  Lemmings and Bard's Tale clean. It also includes the mouse-fix sound margins. Re-run the `sound-phase` step-4 regression set on
  this branch before either branch goes upstream.

- **Lemmings sound margin.** The mouse-fix measurements (4 words at sound phase 0,
  Very Slow) were taken on the fast core. A slower CPU spends longer in the
  mouse interrupt per frame, so the margin will shrink and may go negative. That
  would be the authentic behaviour, but it must be measured, not assumed.
  Pass/fail is judged at sound phase 0. The phase selector may still be used to
  MEASURE the margin, as before, but not as the configuration under test.
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
