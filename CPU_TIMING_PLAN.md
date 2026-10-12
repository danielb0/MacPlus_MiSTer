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

**Phase 2: implement.** DONE 2026-10-12, NOT YET COMPILED.
- `rtl/cpu_wait.v` turns each rule into a DTACK phase window. fx68k samples
  DTACK on phi2 of S4, which sees phase = phi + 2 + waits, so it releases at
  `target + 2`:
  - grid: phase[1:0] = 3
  - Plus display RAM: phase[2:0] = 7
  - SE display RAM: grid, but not phase 3 of 16
  - SCC: phase[2:0] = 7, and AS low for at least 2 clocks
- It also holds the virtual raster: line 0 at the VBL, one line per
  `snd_advance`, display from line 28 for 266 of ~366 clocks, and the last 8
  clocks of every line for the sound slot.
- `MacPlus.sv` ORs `cpu_wait_hold` into `_cpuDTACK`, with
  authentic = !turbo && 68000. The 68010/68020 options are not authentic
  machines and keep zero waits.
- Registered in `files.qip`.
- Gates passed:
  - `tb_cpu_wait` PASS: 11,973 cycles, all loop periods, turbo and raster.
  - Quartus analysis & elaboration: 0 errors, 83 warnings (the baseline),
    none in `cpu_wait`.
- **Mutation sweep: all 9 caught.** The windows, the SCC first-sample guard,
  the SE video slot, the display gate, the first display line, the sound slot,
  and the IWM and SCSI grid rules.
- The IWM and SCSI rules first SURVIVED their mutations. Their reads were
  absolute and indexed, and "n np nr" puts the read right after a prefetch, so
  it is always on the grid. The bench now reads them with predecrement ("n nr"),
  which puts the read itself off the grid. Lesson: a deterministic loop lands
  each access on ONE phase, so a missing rule can hide on a zero-wait phase.

Original Phase 2 text:
- The wait generator goes in `addrController_top.v`, next to `busCycle`; the
  DTACK term goes in `MacPlus.sv`.
- Model-gated on `machineType`; bypassed under `status_turbo`.
- Gate: Phase 1 passes. The ROM loop and turbo are unchanged.

**Phase 3: regression sims.**
- Re-run the existing benches that drive the CPU or bus timing: floppy, DCD,
  SCSI back-pressure (`seam20`), and the sound-phase probe.
- Mutation check: removing the gate must fail Phase 1.

**Phase 4: hardware (compile is GATED: ask first).** COMPILED 2026-10-12:
`output_files/MacPlus_fa939f22_cputiming.rbf`.
- 0 errors, 120 warnings (the debug-deck count).
- Worst setup slack +0.380 ns, no negative slack.
- 50% ALMs, 135/553 RAM blocks, Fitter peak 9,056 MB.
- **HARDWARE 2026-10-12: ALL TESTS PASS** (Daniel).
- PoP is "much cleaner than it was; hard to say whether it is perfect".
  At higher volume (Daniel, 2026-10-12): **"no buzzing ... a bit of lofi
  sizzle"** in Plus mode, and "perfect" in SE mode. **The buzz prediction holds:
  the splice is gone.** The sizzle is the expected asset ceiling: an 11 kHz
  8-bit wavetable, pitch-shifted by nearest neighbour and mixed in software.
  The SE run may be on the 22 kHz driver (PoP chooses it by System version and
  machine type, and that run was under System 7); not checked. The
  expanded-RAM real Plus is still the independent reference.
- Speedometer 3.2, Plus mode, 8 MHz, against the real Plus 0.880 / 0.933 / 0.996
  (`C:/temp/Mac/Screenshots/20261012_175052-screen.png`):

| Test | Real Plus | Core before | Core now | Now / real | Now / 1.0372 |
|---|---|---|---|---|---|
| CPU | 0.880 | 1.355 (x1.540) | 0.920 | x1.045 | 0.887 |
| Graphics | 0.933 | 1.132 (x1.213) | 0.968 | x1.038 | 0.933 |
| Math | 0.996 | 1.201 (x1.206) | 1.034 | x1.038 | 0.997 |
| Old PR | 0.879 | 1.177 | 0.916 | x1.042 | 0.883 |
| New PR | 0.872 | 1.147 | 0.908 | x1.041 | 0.875 |

  Every test is now 1.038-1.045 of the real Plus. That is the 3.72% clock
  (8.125 / 7.8336 MHz) and nothing else: divided out, Graphics and Math match
  to the third decimal and CPU is within 0.8%. The contention model is complete;
  the remaining error is Phase 5.
- **SE mode** (`20261012_182026-screen.png`; the menu bar shows System 7, NOT
  6.0.8). Against Low End Mac's real SE 0.98 / 0.98 / 0.99 (Speedometer 3.06,
  System 7.5.5):

| Test | Real SE | Core before | `fa939f22` | x real | After the trim (/1.0372) |
|---|---|---|---|---|---|
| CPU | 0.98 | 1.30 | 0.981 | 1.001 | ~0.946 (x0.965) |
| Graphics | 0.98 | 1.08 | 0.944 | 0.963 | ~0.910 (x0.929) |
| Math | 0.99 | 1.05 | 0.960 | 0.970 | ~0.926 (x0.935) |

  After Phase 5 the SE will be 3.5-7% SLOW, most of it on the ROM-heavy tests.
  One reading is that the BBU does not impose the TSM's 4-clock grid, at least
  not on ROM. But the reference differs from our run in Speedometer version and
  in System, so it is weak. Do NOT change the SE rule on this alone. The
  decisive data point is a real SE on Speedometer 3.2 under the same System.
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

**Phase 5 REGRESSION: floppies would not mount on `0bf0de6d`** (Daniel,
2026-10-12). The IWM's FCLK is the CPU's C8M, so a GCR byte is 128 CPU
clocks on a real Plus. floppy.v counted 128 clk8, which is 123-124 CPU clocks
once trimmed, and the .Sony read loop overran. It fits 128 exactly with the
real wait states (`fa939f22` mounted fine).

**FIX:** a `cpu_tick` input (= !cpu_skip, through dataController and iwm) gates
floppy.v's read byte timer, its fire moment and the write byte timer.
SDRAM acks and everything else stay on every cep.
- `sim/tb_floppy_byte_clock.v`: exactly 128 CPU clocks per byte, read and write,
  trimmed (133-134 clk8) and untrimmed (128 clk8). Without the gates it FAILS
  at 123-124 CPU clocks.
- The seven floppy/IWM benches pass with `cpu_tick` = 1.
- Elaboration 0 errors, 83 warnings.

**COMPILED 2026-10-12: `output_files/MacPlus_aaa8db7d_floppyfix.rbf`.**
- 0 errors, 120 warnings.
- Worst slack +0.191 ns, none negative.
- Fitter peak 9,058 MB.
- **HARDWARE 2026-10-12: still no floppy mount** (Daniel).

**Second half of the regression: the TACH (`bf2c094`).** The byte rate was
only half of it. The ROM times the drive's TACH against its own clock, and
floppy.v's per-track periods (9996 clk8 on track 0) were calibrated on Plus
Too to land the ROM's timing value at $117B inside an acceptance window of
$1135-$11E9, about 2.5% either side. Counted in clk8 with the CPU trimmed,
the half period is 9615 CPU clocks, 3.8% short: the timing value lands
below the window and the drive never passes the speed check. (The ROM holds
no literal copy of those window words; the Plus Too calibration note is the
evidence that it measures in CPU time.) The tach timer now ticks on
`cpu_tick` too, so the ROM sees the hardware-proven 9996 again, trimmed or
not, for the 800K table and the 400K PWM map alike.
- `sim/tb_floppy_byte_clock.v` now measures the tach half period in CPU
  clocks: 9997 both ways with the gate, 9615 trimmed without it.
- `sim/tb_drive_tach.v` 11/11 unchanged.
- Everything else in the floppy/IWM path was checked for the same exposure:
  the IWM read-latch clear (14 cen = 1.75 us against a 2.04 us poll gap, margin
  improves under the trim), step/motor/eject strobes (edge-driven), SDRAM
  acks (real time). The DCD byte budget sits on clk8 and is handshake-driven;
  HD20 goes on the regression list.
- Rule, sharpened: anything the ROM MEASURES in its own clock must count CPU
  clocks, not just things the real machine clocks from C8M.

**COMPILED + HARDWARE 2026-10-12: `output_files/MacPlus_bf2c0945_tachfix.rbf`**
(0 errors, 120 warnings, slack +0.437 ns, Fitter 9,063 MB). **Floppies mount**
(Daniel).

**Speedometer 3.23 on System 6.0.8, Plus mode, bf2c0945 (screenshot
`C:/temp/Mac/Screenshots/20261012_212144-screen.png`):** CPU 0.880 (real Plus
0.880), Graphics 0.929 (0.933), Math 0.994 (0.996), Disk 0.745 (0.740), Old PR
0.879, New PR 0.872. Every test within 0.7% of the real machine; the earlier
Graphics outlier was System 7, not the core. PoP, HD20, System Picker on a copy
and the regression set still to run.

**Also on `0bf0de6d`:** System Picker (Plus mode, System 7) crashed with error 28
when its menu was opened mid-search, and the disk now gives error 39
(probably -39 eofErr). No SCSI mechanism found: ncr5380 is edge-driven off
the CPU strobes on the 32.5 MHz clock, as asynchronous as a real 5380. **Daniel ran the same System Picker search, menu included, on the REAL Plus
from another copy of the image: no crash.** So the crash is core- or
build-specific. The real Plus has 1 MB, and more RAM makes error 28 less
likely, not more. Prime suspect: the broken floppy driver on that build
(a deep retry chain blowing the stack). The damaged image was deleted.
Open:
retest on the floppy-fixed build with a COPY of the image, and bisect on
`fa939f22` if it recurs. `hfs_integrity.py` on the damaged image would tell
crash damage (catalog/Desktop) from transfer damage (scattered bytes).

**Phase 5 (optional): the 3.7% clock.** COMPILED 2026-10-12:
`output_files/MacPlus_0bf0de6d_cputrim.rbf`.
- 0 errors, 120 warnings.
- Worst slack +0.215 ns, none negative.
- Fitter peak 9,074 MB.
- **HARDWARE 2026-10-12, Plus mode** (`20261012_185817-screen.png`). The menu
  bar shows Balloon Help, so this run is on **System 7**. The real Plus and the
  untrimmed run (`175052`, no Help menu) were on **6.0.8**.

| Test | Real Plus | Untrimmed | Trimmed | x real | Predicted |
|---|---|---|---|---|---|
| CPU | 0.880 | 0.920 | 0.878 | 0.998 | 0.887 |
| Graphics | 0.933 | 0.968 | 0.899 | 0.964 | 0.933 |
| Math | 0.996 | 1.034 | 0.997 | 1.001 | 0.997 |
| Disk | 0.740 | 0.770 | 0.737 | 0.996 | 0.742 |
| Old PR | 0.879 | 0.916 | 0.868 | 0.987 | 0.883 |
| New PR | 0.872 | 0.908 | 0.861 | 0.987 | 0.875 |

  CPU and Math are within 0.2% of the real Plus. Graphics is 3.6% low, which
  is the one outlier. The System differs from the reference run, and
  Graphics is where System 7's QuickDraw patches would show. Re-run on 6.0.8
  before reading anything into it. The PR composites are low only through
  Graphics.
- `cpu_wait` drops the CPU's clock (phi2 and phi1 together) for 5,168 of every
  135,408 clk8, using Bresenham, registered on phi1. That gives 130,240 CPU
  clocks per frame, as on a real Plus, so lines are 352 CPU clocks and
  sound samples 352 per word.
- Video, sound, IWM and SCC stay on clk8. The VIA follows E, so it slows too.
  That gives the real 13,024 E ticks per frame and closes the
  "VIA ticks per sound sample 36.6 vs 35.2" deviation.
- Phase, AS age and raster x now count CPU clocks. The raster thresholds are
  the real 256/344.
- Turbo and the 68010/68020 options are untouched.
- Gates passed:
  - bench PASS: 130,240/135,408, skip gaps 26-27, lines 352-353 CPU clocks
  - all wait checks still pass with skipping active
  - 5/5 new mutations caught
  - elaboration 0 errors, 83 warnings
- Prediction: the Plus-mode Speedometer goes from x1.04 to x1.00 of the real
  Plus (CPU ~0.887, Graphics ~0.933, Math ~0.997).

Original Phase 5 text:
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
