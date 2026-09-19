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
