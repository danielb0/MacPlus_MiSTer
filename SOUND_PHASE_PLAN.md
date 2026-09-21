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

## RESULTS: the mouse discriminator, run 2026-09-21

Hardware, build `MacPlus_6aba5a1e_sndphase.rbf`, **phase 0**, System 7.1,
Lemmings in-game with music. `quartus_stp -t scripts/read_probes.tcl`. No
compile: this is the zero-compile test proposed above.

| run | mouse | n | `first_idx` median | fill span median | LATE | splice |
|---|---|---|---|---|---|---|
| A | still | 30 | **2** (max 3) | **32** (also 35, 39) | 0 | 0 |
| B | slow, cursor stops dead | 40 | **19** (max 26) | **32** (max 39) | 0 | 0 |
| C | fast circles, cursor glides on | 45 | **26** (max 31) | **45** (max 56) | 0 | 0 |

`first_word` = **32 on all 135 samples**. The 11k-path decode above is
confirmed on hardware; Lemmings' S is 32 and the 22k path never runs.

**The 17-word cost is a one-off ahead of the filler, not interrupts inside
it.** Run B moved `first_idx` by 17 words but left the fill span at 32,
identical to run A including its outlier values (35, 39, which occur with the
mouse untouched and are therefore not mouse-related). A delay that shifts the
start and leaves the fill length alone is the `jCrsrTask` signature: the ROM
runs it before the VBL queue walk, so it delays the filler and does not
lengthen it. **Cursor redraw = ~17 scan lines = ~0.77 ms.**

**The core's excess interrupts ARE reaching the sound path, and the rate
matches the RTL.** Run C's span grew from 32 to 45 - 13 words landing inside
the fill, which run B did not have. 13 words x 45 us = 585 us inside a 2.0 ms
fill window; at ~73 us per interrupt that is 8 interrupts, i.e. ~3960/s
against the 3968/s predicted from the 12-bit divider in `rtl/ps2_mouse.v`
(1984 per axis, two axes). The 73 us is an estimate from the ROM
disassembly, so that agreement is not fully independent - but the span
growing at all does not depend on it. Spans are bimodal at ~37 and ~45,
consistent with one axis saturated (+5-6) versus both (+13).

**Internal control:** five frames in run C where the hand paused returned to
exactly `first=2, wrap=33-34, span=31-32` - the resting state, to the word.
The shifts are real and entirely mouse-caused.

**Cost split per frame, at phase 0:**

| component | scan lines | authentic? |
|---|---|---|
| interrupt-to-task latency | 2 | yes |
| cursor redraw (`jCrsrTask`) | ~17 | **yes** - same ROM, same code |
| our excess interrupts, before the first write | +7 | **no, ours** |
| our excess interrupts, during the fill | +13 | **no, ours** |

**By ear at phase 0, mouse flicked: no distortion** (Daniel). Predicted: worst
`first_idx` 31 against the cliff at 32, zero LATE frames. The model made a
falsifiable prediction under the worst condition and survived - by one scan
line. "Phase 0 is mouse-immune", claimed above from static analysis, is
WRONG: it is mouse-marginal, and the core's own mouse defect eats 29 of its
30 lines of headroom.

**Also observed (Daniel):** moving the mouse quickly slows the game but not
the music. That is the signature of interrupt-level work crowding out the
foreground: the VBL task always gets its slot, the game loop gets what is
left. It also corroborates the size - VBL-side occupancy is ~71 of 370 lines
plus interrupts across the rest, roughly a third of the machine.

### The System 6.0.4 lower bound does not survive

Run D, same build, Finder under System 7.1, sampled alert sound clicked
repeatedly with the mouse held still, 60 samples:

    S=0  first_idx=2   wrap=2   span=0   (x5)
    S=0  first_idx=93  wrap=93  span=0   (x1)
    54 of 60 frames had no write

7.1's alert-sound path begins its buffer write at **word 0**, ~2 lines after
the VBL interrupt. It looks nothing like the S=90 driver behind the "System
6.0.4 Sound Manager, 23..90" row in the table above - which was Mini vMac's
author's measurement, borrowed, never verified here, and **the only
constraint pushing the phase upward**.

Caveat, honestly: six samples of a half-second sound, and the probe sees the
first write, not the write order. A driver filling from word 0 and a driver
ZEROING the buffer both present as S=0, span=0. This weakens the 23..90 row;
it does not by itself establish 7.1's window.

### Revised band, from measured constraints only

With lat = 2 and redraw = 17, both measured here:

| constraint | source | requires |
|---|---|---|
| PoP lower bound (buzzes at phase 0) | measured here | phase > 7 |
| Lemmings + moving mouse (S = 32) | measured here | phase < 13 |
| ROM free-form driver | third party | -1 .. 50 |
| 7.1 alert sounds | measured here, thin | no upper requirement |
| System 6.0.4 SM | borrowed, **now doubtful** | (> 23) |

Drop the doubtful row and the band is **phase 8 to 12, centre 10**: PoP gets
3 lines of margin at the bottom, Lemmings 3 at the top. The band being narrow
is a point in its favour - two independently written commercial drivers tuned
against the same hardware should bracket the true value tightly.

**This contradicts the release constant of 28 recorded above.** The
"28 = the 28 blanking lines" argument made 28 feel principled rather than
fitted; on this reading it is a coincidence that happens to sit inside PoP's
window, which is why everything keyboard-driven tested clean. Consistency
check supporting the new reading: at phase 28 with a moving mouse PoP itself
is at V+lat 47 against a ceiling of 37, so PoP should crackle too - it is not
reported because it is keyboard-driven and the cursor sits still.

Daniel's framing, which is the right one: a real Plus had ONE value, so the
constraint set must intersect. It does, at 8..12. Neither "the phase was
higher than 0" nor "some programs really did crackle" is forced.

**The slow-mouse objection, and why it does not rescue 28:** the original
mouse was far slower than a modern one, so our interrupt burst is definitely
unfaithful (measured above). But `jCrsrTask` fires once per VBL whenever
`CrsrNew` is set - one pixel of movement costs the same 16x16 erase-and-redraw
as twenty. **It is a per-frame cost, not a per-distance cost.** A slow mouse
pays 17 lines on more frames, not fewer lines per frame. The only relief is
that a genuinely slow mouse may not move the cursor on every frame, which
thins the crackle without removing it.

Supporting the 17 lines being authentic rather than an artefact of our bus
arbitration: phase 20 at 16 MHz is mouse-proof (Daniel, earlier), which only
works if the redraw roughly halved. So it is CPU-bound, and a real Plus at
7.8336 MHz pays about the same.

### Next steps

1. **One compile, then hardware:** extend the selector from `OJK` (bits 19-20,
   4 options) to `OJL` (bits 19-21, 8 options) and ADD 8, 10 and 12 without
   removing 0/20/28/36. Bit 21 is free and nothing uses 21 or above, so the
   field grows upward, no existing bit moves, and `"v,1;"` does not need a
   bump - an old config has bit 21 clear and indices 0-3 keep their meaning.
   Then PoP and Lemmings, mouse still and mouse moving, by ear and on PSND.
   If 10 is clean on all four, the release constant changes from 28 to 10.
2. Sustained-sound measurement of 7.1's Sound Manager, to replace the thin
   six-sample run D and settle whether it fills from 0 or was merely clearing.
3. Separate, not this branch: a rate-proportional mouse drain (spread each
   report's counts over its 16 ms) would make interrupt density track hand
   speed like a real mouse and remove the cursor lag. Confirmed defect
   independent of the phase question - but note it would NOT rescue phase 28,
   because the authentic 17-line redraw blows that margin on its own.

## RESULTS: the 8-value build, and the mouse is the thing setting the ceiling

Hardware 2026-09-21, build `MacPlus_a231e806_sndphase8.rbf` (menu
`0,6,8,10,12,20,28,36`, default 0; cold compile 0 errors, 120 warnings, setup
slack +0.590). System 7.1, Lemmings in-game with music.

### By ear, first (Daniel)

- **PoP is CLEAN at phase 6.** Predicted to BUZZ: 6 puts the reader 8 words in
  and the recorded floor was 9. **The prediction FAILED.** PoP's floor is
  between 2 (buzzes) and 8 (clean), not 9 -- the 28-word estimate for its
  first part is too short, and a longer first part drags the floor down.
- **Lemmings buzzes at 6 with the mouse moving; clean at 0.**

### Run E -- phase 6, slow mouse, 45 samples

The capture caught the setting being changed mid-run, which is a free control:

| samples | `first_idx` | span | regime |
|---|---|---|---|
| 1-8 | 2 | 32 | phase 0, mouse still |
| 9-13 | **8** (one 9) | 31-32 | phase 6, mouse still = 6+2 exactly |
| rest | 16-35, median **25** | mostly 31-32 | phase 6, mouse moving |

Median 25 = 6 + 2 + 17: **the 17-line cursor redraw reconfirmed at a different
phase**, an independent check of the figure measured at phase 0.

Splitting the 31 moving frames by fill span:

| | n | max `first_idx` | LATE |
|---|---|---|---|
| normal span (31-32) | 26 | **30** | **0** |
| elevated span (35-38) | 5 | 35 | 2 |

### Run F -- phase 6, fast mouse, 50 samples

**32 of 50 frames LATE (64%).** Every frame elevated-span (36-54, median 45);
`first_idx` median 33, i.e. the MEDIAN is above the cliff. ~38 glitches a
second, which is what a buzz is.

### The conclusion, on solid numbers

| condition | n | span | max `first_idx` | LATE |
|---|---|---|---|---|
| slow, normal-span frames | 26 | 31-32 | **30** | **0** |
| slow, burst frames | 5 | 35-38 | 35 | 2 |
| fast, all frames | 50 | 36-54 | 37 | **32 (64%)** |

Monotonic. Frames whose fill ran its natural length never clipped; frames with
extra interrupts clipped in proportion. Extra interrupts show up in both
places at once -- they delay the first write AND lengthen the fill -- so high
`first_idx` and high span co-occur, and they do.

**Lemmings buzzing at phase 6 is entirely the core's mouse converter.** The
authentic component never clips there. This upgrades the n=5 hint in run E to
a result.

**Do NOT use "the mouse moved slowly" as a proxy for an authentic interrupt
rate.** "Cursor stops dead" only proves the accumulator is not backing up,
i.e. rate <= 1984/s; a real 90-cpi mouse at the same hand speed is a few
hundred. The only clean separation is the FILL SPAN: a frame at the natural
31-32 had no extra interrupts in it, whatever the mouse was doing.

### Revised band -- and 8, 10 and 12 are all too high

**WITHDRAWN in part by the review below (same day): the span discriminator
cannot see interrupts that land BEFORE the first write, so the worst case of
24 may include our own ticks. 8, 10 and 12 are NOT excluded. Kept as written
for the record.**

Use the authentic WORST case, not the median. `first_idx` 30 at phase 6 on a
normal-span frame means `lat + redraw` reaches **24** (median 19). For
Lemmings never to clip:

    phase + 24 < 32  =>  phase < 8

PoP buzzes at 0 and is clean at 6, so its floor is in 1..6.

**Band = phase 3..7, and 6 is inside it.** Phase 6 is already confirmed clean
for PoP and is predicted clean for Lemmings once the mouse is faithful.

The earlier estimate of 10 used the MEDIAN redraw of 17; the worst case of 24
is the number that matters, because one clipped frame per second is audible.
**The three values added to this build -- 8, 10, 12 -- are all at or above the
ceiling even with a perfect mouse.** The one that mattered was 6.

### Next step: the converter is now the BLOCKING item

The phase cannot be settled while a defect sets its ceiling -- choosing a
value now would mean accommodating a bug we intend to remove.

`rtl/ps2_mouse.v` drains its accumulator at a fixed 1984 edges/s per axis
whenever it is non-zero (12-bit divider on `clk8_en_p` = 8.125 MHz), and the
accumulator holds ~+-510, so a flick sustains max rate for ~257 ms after the
hand stops. Fix: spread each host report's counts across its ~16 ms so
interrupt density tracks hand speed and the tail disappears. Bench, compile,
then re-run PoP and Lemmings across 0/6/8 with the mouse moving.

Prediction to test after the fix: **phase 6 clean in Lemmings with the mouse
moving**, and 8/10/12 still clipping.

**Superseded by the review below: the fix as described here has no scale
factor and would flood the Mac with interrupts, and the prediction needs a
hand speed attached. The plan of record is the next section.**

## REVIEW 2026-09-21: what the phase-6 runs do and do not establish

A read of the three results sections above against `rtl/ps2_mouse.v`,
`rtl/snd_phase_probe.sv`, `scripts/read_probes.tcl` and Main's `input.cpp`.
What survives: the converter is unfaithful in exactly the way described (fixed
drain of one edge per 4096 clk8 per axis, reports dropped while the backlog is
256 or more, a tail of up to ~257 ms); Main sends the raw accumulated delta
every 15 ms or more with `mouse_throttle` defaulting to 1; the measurements
are sound; and the converter must be fixed before a phase is chosen. Three
things do not survive.

### 1. The span discriminator is one-sided

`span = wrap_idx - first_idx` covers the FIRST PART of the fill only. An
interrupt landing inside it lengthens the span, which is what runs E and F
used. An interrupt landing in the PRE-WRITE window (latency + redraw, ~19
words at phase 6) delays the first write and leaves the span untouched, so a
"natural-span" frame can still carry our ticks in front of the fill. That is
not a corner case: a frame whose accumulator ran dry just before the fill
began has its last ticks exactly there.

| quantity | value |
|---|---|
| tick spacing per axis (12-bit divider on clk8) | 504 us = ~11 scan words |
| pre-write window at phase 6 (2 + 17) | ~19 words |
| ticks a natural-span frame can hide there | 1..3 = 2..5 words |
| worst natural-span `first_idx` minus the median (30 - 25) | 5 words |

The excess of the worst case over the median is the size of the
contamination, so the authentic worst `lat + redraw` is somewhere in
**19..24**, and the Lemmings ceiling is somewhere in **phase < 8 .. phase <
13**. The candidates 6, 8, 10 and 12 all remain. Nothing measured so far
separates authentic redraw variance from converter contamination; only a
faithful mouse or a two-sided instrument can.

### 2. The prediction needs a hand speed

A faithful mouse still interrupts. The Plus mouse is 90 pulses per inch per
axis (Guide ch.7). Whether a "pulse" is one quadrature cycle (two X1 edges,
two ROM interrupts) or one edge is not stated, so the count rate carries a
factor-of-two ambiguity that the cursor-travel calibration in section 3
settles. Using the doc's own ~1.6 words per interrupt:

| hand | counts/s per axis (90 or 180 per inch) | interrupts in a 19-word window, two axes | cost |
|---|---|---|---|
| slow, 2 in/s | 180 / 360 | 0.3 / 0.6 | mostly none |
| fast, 10 in/s diagonal | 900 / 1800 | 1.5 / 3 | 2.5 / 5 words |

Against a worst authentic case of 24 that puts a fast hand at 26..29 words at
phase 0, i.e. at or over the cliff at phase 6. So on a real Plus, Lemmings
with a fast mouse may clip occasionally at the true phase; nobody knows, and
the forum question (does a real Plus show the mouse effect?) is the one
calibration point that would settle it.

Predictions after the fix, each with its condition:

- **Slow hand, any phase:** natural-span frames' `first_idx` should tighten.
  If the max drops to about phase + 22, the 30 was contamination and the
  ceiling moves up to phase < 10..11. If it stays at phase + 24, it was
  authentic redraw variance and the ceiling stays at phase < 8.
- **Phase 6, Lemmings, slow hand:** zero LATE frames.
- **Phase 6, Lemmings, fast hand:** a residual LATE rate consistent with 2..5
  words on top of the authentic worst case, not zero. A handful of late
  frames here is Lemmings' own margin, not the fix failing.
- **PoP:** unchanged at every phase (keyboard-driven, cursor still).
- **Cursor:** the lag after a flick is gone, and 512 pixels of travel take
  roughly the hand distance a real Plus mouse needed (5.7 in at 90 per inch,
  2.8 in at 180).

### 3. The fix is three parts, not one

"Spread each report's counts over its 16 ms" has no scale factor. Main
(`input.cpp`, `send_mouse_with_throttle`, `mouse_req` block) delivers the raw
delta, up to +-255 per report, every 15 ms or more, and `mouse_throttle`
defaults to 1. A modern mouse at 1000 counts per inch moving at 10 in/s
delivers ~10,000 counts/s per axis; spread evenly at ~73 us per interrupt
that is ~73% of the CPU on one axis. The current cap of 1984/s is the only
thing keeping the machine alive today. The fix:

1. **A divisor** from the host mouse's resolution to the Plus's 90 per inch.
   Modern mice are 400..1600 per inch, so the divisor is somewhere in 4..18
   and depends on the user's mouse. Recommendation: a fixed default chosen by
   the travel calibration on the bench mouse, applied core-side so it does
   not depend on `MiSTer.ini`. Whether to expose it in the OSD is Daniel's
   call; a 2-bit selector would cost one config field.
2. **A per-axis rate ceiling.** Keep the existing one edge per 4096 clk8
   (1984/s): it is the right order of magnitude for the fastest physical flick
   (20 in/s at 90..180 per inch = 1800..3600/s) and it is what the ROM has
   already been shown to survive.
3. **Even spreading** of the scaled residual across the report interval, so
   interrupt density tracks hand speed. A per-axis DDA on clk8: add the
   scaled count once per report, emit one edge each time the accumulator
   crosses the interval quantum (~16 ms of clk8 per count), never faster than
   the ceiling. Backlog bounded to about two reports' worth so the tail
   cannot exceed ~30 ms, and counts beyond that are dropped, as now. The
   interface (`x1 y1 x2 y2 button`) does not change, so `rtl/scc.v` and the
   VIA port are untouched.

Bench first, `sim/tb_ps2_mouse.v` (iverilog): stationary input emits no
edges; a run of reports emits edges equal to the sum of the scaled deltas,
rounding accounted for; no two edges on one axis closer than 4096 clk8; no
edge later than ~two intervals after the last report; direction on `x2`/`y2`
follows the sign. Then one compile, which is gated: ask first.

### 4. Make the instrument two-sided in the same compile

Count mouse interrupts per frame: `mouseX1`/`mouseY1` edges before the
first write, and in the whole frame. That separates authentic redraw
variance from converter ticks directly instead of inferring it from the span.
The probe deck is at its hub-node ceiling (`rtl/dbg_probes.sv`), so the
field has to come out of an existing word: PSND's 5-bit frame counter and
`first_word` (always 32 for Lemmings, 37 for PoP, both known) are the
candidates. Decide the packing before the compile and add the fields to
`scripts/read_probes.tcl` and `sim/tb_snd_phase.v`.

### 5. Read the hardware, not the drivers

Everything above infers V from driver windows. On a real Plus the sound scan
address and the VBL interrupt both come from the address-generation PALs
(LAG, TSG and friends on the Apple schematic), and equations for the
128K/512K family have, I believe, been reverse-engineered and published;
the Plus reuses the family. If they can be found, they answer the one
question this branch exists to answer directly: on which line the sound
address counter wraps relative to the line on which VIA CA1 is asserted.
Zero compiles. Do the search before the fix compile; 68kMLA needs the in-app
browser (see memory), bitsavers via `bitsavers.trailing-edge.com`. Standing
rule: read the documentation before forming the hypothesis.

### Order of work

1. PAL-equation search (no compile). If it lands, V is known and the rest
   is confirmation.
2. Converter fix in `rtl/ps2_mouse.v` with `sim/tb_ps2_mouse.v` green.
3. Two-sided PSND repacking, bench updated.
4. One compile carrying 2 and 3, selector unchanged (`0,6,8,10,12,20,28,36`).
   Ask first.
5. Hardware: cursor-travel calibration; Lemmings slow and fast at 6/8/10/12
   with the new fields; PoP, Lode Runner and the chime as controls.
6. Only then choose the phase and the release constant. Until then the
   source at HEAD still builds a default of 0 and no value is settled.
