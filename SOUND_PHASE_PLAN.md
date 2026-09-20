# Sound scan phase: where is the reader when the VBL fires?

Branch `sound-phase` off `mac128k`. Opened 2026-09-19.

## The symptom

Prince of Persia's music carries an aggressive buzz on the Plus core, "a 60 Hz
buzz riding on the notes, maybe a bit higher than 60 Hz", not sudden pops. Its
sound effects are clean. Lode Runner, Lemmings and everything else tested is
clean. The same buzz is heard on Mini vMac. The LC core is clean, but the LC has
the Apple Sound Chip and the game ships different assets for it, so that
comparison never localised anything.

A 2 kHz low-pass in the MiSTer audio filter softened it and did not remove it.
A filter cannot: a steady buzz locked to the frame rate is a waveform
discontinuity repeated every frame, and the question is who puts it there.

## What PoP's driver actually does (MDRV decoded 2026-09-19)

PoP's `MDRV` resources (ids 11 and 22) are not standard compressed resources.
CODE 2 protects them itself: a byte cipher over bytes [7:] (`$4532`/`$44fe`,
state seeded `$DCE5`, `out = x ^ (s>>8)`, `s = ((x+s)*$CE6D + $58BF) & $FFFF`)
followed by an LZSS pass (`$4c98`: flag byte LSB-first, 1 = literal, 0 = 2-byte
token, 12-bit offset, length = high nibble + 3, 4 KB window). Bytes [0:4] hold
the unpacked length, and the reimplementation round-trips to exactly that
length for both drivers. Driver globals sit at `a4 = base + $3600`.

The VBL fill routine (MDRV 11 `$28a6`, MDRV 22 `$2800`):

* raises IPL to 1, clears VIA PB7 (sound on),
* copies pre-mixed bytes into the **main** sound buffer (`SoundBase`, $266)
  only. No alternate buffer, no VIA PA3. The core's once-per-frame `snd_alt`
  sampling is therefore irrelevant to this title.
* writes words **S..369 first, then 0..S-1**, with the source pointer running
  continuously across both parts. S = word at `$1508(a4)` (11k) or `$16a8(a4)`
  (22k) = **37 in both**.
* the loop is 30 cycles/word (3.83 us at 7.8336 MHz), so 370 words take
  ~1.42 ms, during which the hardware scan advances ~32 words.

Stream order equals write order, so playback is only continuous if the
reader reads words [V, S-1] **before** the wrap part overwrites them and word S
**after** it is written, where V is the scan word the reader is on when the VBL
interrupt fires and lat is interrupt-to-task latency:

    S - first_part_words  <  V + lat  <  S

| driver | S | first part | required V + lat (words) |
|---|---|---|---|
| PoP MDRV 11 / 22 | 37 | 28 | 9 .. 37 |
| ROM free-form driver (Mini vMac's measurement) | 50 | 51 | -1 .. 50 |
| System 6.0.4 Sound Manager (same source) | 90 | 67 | 23 .. 90 |

All three were tuned on real hardware, so the real machine must satisfy all
three: **V + lat in 23..37 words, 1.0 to 1.7 ms**.

## What the core does

`rtl/addrController_top.v` reset `audioAddr` to word 0 on the falling edge of
`_vblank`, and VIA CA1 is `_vblank` itself (`rtl/dataController_top.sv`, edge
per PCR bit 0 in `rtl/via6522.vhd`). So V = 0. MAME is also V = 0 (sound index
= vpos, vblank lines first). Mini vMac is V = 0 with per-SubTick read-ahead
fudges (offsets 0, 25, 50, 90, ...) that its author added precisely because
Apple's driver otherwise conflicted, so "same on Mini vMac" was never evidence
about this.

With V = 0 and a small latency, PoP's wrap overwrites words ~31..36 before the
reader reaches them: two 370-sample stream jumps per frame, a click train at
60 Hz with a strong 120 Hz component, scaling with sustained tonal content.
That is the observed sound. The ROM driver's window includes 0, which is why
the rest of the library is clean.

Inside Macintosh III only says the VBL interrupt comes "at the beginning of the
vertical blanking interval"; nothing in the documents found gives the sound
scan's word at that instant. Hardware has to be measured.

## The instrument and the experiment (one build, `USE_SCSI_ISSP`)

1. **PSND probe** (`rtl/snd_phase_probe.sv`, wired into `rtl/dbg_probes.sv` in
   PRG0's hub slot, which the closed SCSI wedge no longer needs). Per frame:
   scan word at the first CPU write into the main sound buffer (= V + lat),
   the word that write hit (= S), and the scan word when word 0 was written
   (the wrap). Decoded by `scripts/read_probes.tcl`.
2. **Scan phase select**, OSD `Sound Scan Phase` = status[20:19]: the scan
   starts at word 0 / 20 / 28 / 36 on the vblank edge and wraps 369 -> 0
   mid-frame, so the frame stays exactly 370 words. 0 is the old behaviour.

Predictions, with lat measured by the probe at phase 0:

* phase 0: buzz (the current state).
* phase 20 and 28: clean if 20 + lat and 28 + lat land inside 9..37.
* phase 36: buzz again if 36 + lat > 37. A setting that reintroduces the buzz
  is the falsification half of the test.
* Lode Runner (ROM driver, window -1..50) must stay clean at 0, 20 and 28.

If the buzz follows the prediction, the phase is the cause. The fix is then a
value in the intersection all three drivers were tuned for, and it is a
period-correct change rather than a workaround, because three generations of
Apple's own drivers assume it.

## Verification

* `sim/tb_snd_phase.v` (iverilog): the real `addrController_top.v` scan
  produces exactly 370 advances per frame at every phase, the word sequence is
  `p..369, 0..p-1`, `snd_index` tracks `audioAddr`, and the probe latches the
  three fields from modelled CPU writes and commits them on the frame edge.
* Elaboration + full compile, then hardware: PoP music at each phase, Lode
  Runner as the control, PSND read at each phase.

## Results

Build `6aba5a1e` (`output_files/MacPlus_6aba5a1e_sndphase.rbf`): cold
compile, 0 errors, 120 warnings (probe deck on), setup slack +0.261. Hardware
2026-09-20, PoP music playing, PSND read with `read_probes.tcl 10 0.5`:

| phase | first write hits | scan word then | word 0 written at | reader's verdict | by ear |
|---|---|---|---|---|---|
| 0 | 37 | 2-3 | 30 | WRAP OVERTOOK THE SCAN: words 31..36 | buzz (as before) |
| 20 | 37 | 22-23 | 50 | no splice | clean |
| 28 | 37 | 30-31 | 58 | no splice | **clean** |
| 36 | 37 | 38-39 | 66 | LATE: first part stale | buzz again |

Every sample agreed with its prediction, ten of ten at 0, eight of eight at
28, six of six at 36, three of three at 20 (the other three frames in that
capture had no buffer write: a pause in the music). Interrupt-to-task latency is 2-3 words (~0.1 ms), so
the core's V = 0 put PoP's wrap six words short of the reader on every frame.

Also seen while something other than PoP was making sound: a writer starting
at word 50 with idle frames between, landing at scan word 33 at phase 28 with
no splice. A start word of 50 is the ROM's free-form driver, exactly the
"offsets 50 to 370, then 0 to 50" Mini vMac's author measured.

**Verdict: the scan phase was the cause.** With V + lat = 30-31 words every
driver in the table above is inside its window (PoP 9..37, ROM -1..50, Sound
Manager 6.0.4 23..90). 28 is also the length of vertical blanking in lines,
which is the natural hardware explanation: the scan wraps at one end of
vertical blanking and the VBL interrupt fires at the other.

**Control and side results (Daniel, 2026-09-20):**

* Lode Runner is unaffected by the setting, as predicted for the ROM driver.
  Its 16 MHz corruption is also unchanged, as expected: that is the CPU
  filling at double rate against a fixed-rate drain, a different mechanism.
* Lemmings is clean at 0, 20 and 28 and **distorted at 36**. So Lemmings also
  carries a buffer-filling driver with a start word of about 37 to 39, which
  36 + 2-3 words of latency overtakes. On real hardware it was never in
  danger; a setting of 36 would have broken it.

## Release form

A constant 28, no OSD option, for the upstream re-cut: it is a hardware
constant, 28 is the length of vertical blanking in lines, and every driver
measured or documented sits inside its window there. This branch keeps the
selector for future measurement, but its index 0 is now 28, so a fresh config
gets the fix and only a deliberate change reaches the old behaviour.

## OPEN: the mouse effect on Lemmings (dug 2026-09-20, no build, no hardware)

Daniel: Lemmings is clean at 0, the mouse distorts it at the higher settings,
and at 16 MHz phase 20 is mouse-proof. Suspect was the core's USB-to-quadrature
converter. Everything below was read from code; the one inference is marked.

**Lemmings' driver, decoded.** Its `MDRV` 11 is the same Presage packer as
PoP's and unpacks with `scripts/mdrv_unpack.py` (cipher over bytes [7:], LZSS
input from byte 4). Data area `a4 = driver+$3700`. A VBL task (`_VInstall` at
`$1cbe`, `vblCount = 1`, re-armed each run at `$236c`) runs at IPL 0. Two
paths, chosen by `$76(a4)`:

| path | start word S | first part | wrap part | window for V+lat |
|---|---|---|---|---|
| 11k (`$23cc`) | **32** (`adda.w #$40,a3`) | 32..369, 2 words per sample, ~30 cycles/word = ~28 reader words | 0..31 | **0.7 .. 32** |
| 22k (`$30f2`) | 40 | 66 x 5 words | 8 x 5 words | ~10 .. 40 |

The 22k path would buzz at phase 0 (lower bound) and 0 is clean, so the Plus
runs the 11k path. Lower bounds here include the wrap-part write time (~2.6
words), which the PoP-era formula omitted. Lemmings shows the system cursor
(`SetCursor` x3, no `HideCursor`).

**The margins at each setting (11k path):** phase 0 -> V+lat 2-3: 29 words
above, ~2 below, and a delayed writer only helps the lower bound, so 0 is
mouse-immune. Phase 20 -> 22-23: 9-10 words. **Phase 28 -> 30-31: 1-2 words
(45-90 us).** Phase 36 -> 38-39: late. That reproduces every report, including
16 MHz + 20 (fill and redraw both halve).

**Plus ROM, VBL handler `$1B12` (v3; same offsets v1/v2):** `addq.l #1,Ticks`,
clear VIA IFR, `move #$2000,sr` (IPL to 0), stack check, **`jsr jCrsrTask` at
`$1B46`, THEN the VBL queue walk at `$1BC6`**. A moving mouse therefore costs a
cursor redraw ahead of every VInstall'd filler, with mouse interrupts nesting
inside. Real hardware does exactly this; the redraw's cost was not measured.

**Plus ROM, one mouse interrupt:** level-2 entry `$1A84` -> ext/status
`$1AB6`/`$1AC2` -> `ExtStsDT` ($2BE) -> mouse Y `$1C00` / X `$1BD8` (read VIA B,
eor with the RR0 DCD bit, `addq/subq #1,MTemp`, `move.b CrsrCouple,CrsrNew`,
rts). ~580 cycles with entry/`movem`/`rte` (standard 68000 timings, approximate)
= ~73 us = **~1.6 sound words per interrupt**. One per DCD edge, no IUS reset;
`rtl/scc.v` matches.

**The core's mouse path** (`rtl/ps2_mouse.v`, `ce = clk8_en_p`): one quadrature
edge per 4096 clk8 = 504 us, i.e. a **fixed 1984 edges/s per axis whenever the
accumulator is non-zero**; the accumulator holds ~+-510, so a flick of a modern
mouse drains at max rate for up to ~257 ms after the hand stops (also the
"laggy cursor" complaint). Main sends one report per >= 16 ms, dx/dy clipped
to +-255, unscaled (`input.cpp` mouse_req block, `user_io.cpp:4210`). Both axes
saturated = ~4000 int/s x 73 us = ~29% of the CPU. A real Plus mouse is "90
pulses per inch" (Guide ch.7), ~900/s/axis at a fast 10 in/s, never sustained.

**So the converter IS unlike a real mouse (bursty, ~2x rate, sustained), but
it is not what makes Lemmings fragile: at 28 a single interrupt in the
VBL-to-first-write gap, or the cursor redraw, is enough.**

**Inference, flagged:** if a real Plus had V+lat = 30-31, Lemmings (a
mouse-driven game) would crackle on every mouse move on real hardware. That
argues the true value is a few words lower. The driver windows (PoP 9..37, ROM
-1..50, SM 6.0.4 ~20..90, Lemmings 0.7..32) intersect at about (23, 32); the
centre is V+lat ~27, i.e. **phase ~24-25, which was never on the menu**.

**Next steps, in order:**

1. Zero-compile discriminator on `MacPlus_6aba5a1e_sndphase.rbf`, phase 28,
   Lemmings playing: `quartus_stp -t scripts/read_probes.tcl 30 0.3` with the
   mouse still, moving slowly (<= 1 count per frame: sets `CrsrNew` every frame
   with ~1 interrupt), and flicked. PSND's first-write scan word shift in the
   slow case is the cursor redraw (authentic); the extra shift when flicked is
   the core's burst (ours). PSND is per-frame, not sticky. Also confirm whether
   phase 20 at 8 MHz is mouse-clean (predicted: 9-10 words of margin).
2. If the slow case alone reaches 32: put 24 (or 25) on the selector in place
   of 36 and repeat the four-game set (PoP, Lemmings, Lode Runner, chime) with
   the mouse moving. This is a compile: ask first.
3. Separate, not this branch: a rate-proportional mouse drain (spread each
   report's counts over its 16 ms) would make interrupt density track hand
   speed like a real mouse and remove the cursor lag.
