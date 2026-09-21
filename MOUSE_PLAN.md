# Mouse converter: bursts and a 257 ms tail from a 1984-count-per-second flush

Branch `sound-phase`, alongside `SOUND_PHASE_PLAN.md`. Opened 2026-09-21.

The two pieces of work share this branch on purpose. One dev build has to
carry both the sound-scan selector and this fix, or there is never a
bitstream on which Lemmings and Prince of Persia are both right at once. The
shipping split is a separate decision, taken at the end of this document;
the commits are laid out so that either piece can be cut alone.

## The defect, as measured

`rtl/ps2_mouse.v` turns Main's PS/2 mouse reports into the Plus's quadrature
lines (`x1 y1` into the SCC's DCD inputs, `x2 y2` into VIA port B). Main
sends a report every 15 ms or more, carrying the raw host delta since the
last report clipped to +-255 per axis (`input.cpp`, the `mouse_req` block;
`user_io.cpp` does the clipping). The converter adds each report into a
10-bit accumulator per axis and drains it at a fixed rate: a 12-bit divider
on `clk8_en_p` (8.125 MHz) toggles the axis line once per 4096 clock enables
whenever the accumulator is non-zero.

| what | value |
|---|---|
| drain rate, per axis | one edge per 504 us = 1984 counts/s |
| one edge on the Plus | one SCC DCD interrupt, ~73 us of ROM time, cursor moves one pixel (before System acceleration) |
| accumulator | 10-bit; a report is DROPPED WHOLE when the accumulator's top two bits differ (`|acc| >= 256`), it is not saturated |
| tail after the last report | up to 511 counts x 504 us = 257 ms of edges at the full 1984/s |
| host resolution | 400..1600 counts per inch; the Plus mouse is 90 per inch (Guide ch. 7) |

Three consequences, all seen on the PSND probe (`SOUND_PHASE_PLAN.md`, the
"RESULTS" sections of 2026-09-21):

1. **Bursts.** Any report that carries more than one count is emitted as a
   train at the ceiling rate, however slow the hand was. A hand moving at
   2 in/s with a 1000-cpi mouse puts 30 counts into each report; the Plus
   then sees a 15 ms train of interrupts at 1984/s, i.e. the machine spends
   ~15% of its time in the mouse handler and every one of those interrupts
   lands inside a sound driver's fill. Lemmings' fill span grew from 32 to
   45 words with a fast hand; run F at phase 6 clipped 64% of its frames.
2. **The tail.** After the hand stops the cursor keeps gliding for up to a
   quarter of a second ("cursor glides on" in run C), and the interrupts keep
   coming while it does.
3. **No scale.** The Plus expects ~90 counts per inch; the host gives 4..18
   times that, and today the ceiling is the only thing standing between a
   modern mouse and ~10,000 interrupts per second. That is why the ceiling
   must stay: it is what keeps the machine alive, not the defect.

What a real Plus does instead: the mouse's optical encoders produce edges as
the ball turns, so the interrupt rate follows hand speed, tops out at a few
hundred per second for a fast hand, and stops the instant the hand does.

The SE is not affected and not covered: it takes the mouse through
`rtl/adb.sv`, which has its own conversion (7-bit clamp per report, no
accumulator, no burst) and its own defects if any.

## The fix: three parts

The interface (`x1 y1 x2 y2 button`) does not change, so `rtl/scc.v`, the
VIA port and `rtl/dataController_top.sv`'s instantiation are untouched.

### 1. A divisor from host resolution to 90 per inch

Each axis keeps a signed raw accumulator in host units; one output edge
consumes `DIV` raw units, and the remainder carries forward so slow, fine
motion is never lost to rounding (a 1-count report every 16 ms still moves
the cursor, one edge per `DIV` reports). `DIV` is in 4..18 for real mice
and depends on the user's mouse, so it cannot be a constant chosen at the
desk:

- **Dev build: a 3-bit OSD selector** on free status bits, `"OMO,Mouse
  Speed,...;"` (bits 22-24; the sound selector holds 19-21 and nothing
  uses 22 and up). Values to cover both the resolution range and the
  factor-2 ambiguity in "90 pulses per inch" (one interrupt per pulse or
  per edge): `2,3,4,6,8,11,16,1`, with 8 as index 0 so the default is
  sane for an 800..1000-cpi mouse. Calibration then costs OSD clicks, not
  compiles.
- **Release: Daniel's call.** Either keep the selector under a user-facing
  name (a mouse-speed option is ordinary on MiSTer cores and it is the
  only way a 400-cpi and a 1600-cpi user can both get a real Plus's feel),
  or bake the calibrated value in and drop the field. The selector is
  cheap: three status bits and a 3-bit mux.

`mouse_throttle` in `MiSTer.ini` is not part of the fix: it defaults to 1,
it is global to every core, and it divides before the clip, so it cannot be
relied on to be set.

### 2. The per-axis rate ceiling stays

One edge per 4096 `clk8_en_p` (1984/s) is the right order of magnitude for
the fastest physical flick (20 in/s x 90..180 per inch = 1800..3600/s) and
it is the rate the ROM has already been shown to survive. It is enforced at
the emitter, after the divisor, so it now only bites on genuinely fast
motion instead of on every report.

### 3. Even spreading across the report interval, with a bounded backlog

Instead of draining at the ceiling and stopping, the emitter plans each
report's counts over the following interval:

- On a strobe, `budget <= backlog + delta` (signed, host units), saturated
  at `+-64*DIV` (two intervals' worth at the ceiling; counts beyond that
  are dropped, as now, but by saturation rather than by discarding the
  report).
- A fine tick every 128 `clk8_en_p` (15.75 us; 1024 fine ticks = 16.1 ms,
  one nominal interval). On each fine tick a per-axis DDA adds `|budget|`
  to a phase accumulator; when the phase reaches `1024*DIV` it emits one
  edge, subtracts `1024*DIV` from the phase and `DIV` from `|budget|`.
  Over one interval that emits `budget/DIV` edges, evenly spaced. The rate
  is fixed at the strobe, not recomputed per edge, so the spacing is linear
  and the last count of a report leaves within the interval rather than
  decaying out.
- The ceiling is applied at the emit point: no edge if fewer than 4096
  `clk8_en_p` have passed since the axis's last edge; the phase keeps
  accumulating and the edge goes out at the first allowed tick.
- The direction of each edge is the sign of the remaining budget when it is
  emitted; `x2 <= ~x1 ^ ~sign` as now, so a reversal mid-interval simply
  flips the quadrature sense from that edge on.
- A remainder smaller than `DIV` stays in the backlog until more motion
  arrives; it is not flushed, so a stationary mouse is silent.

Worst-case tail after the last report: one interval (~16 ms) for a normal
report, or the ceiling-limited drain of a saturated backlog (64 counts at
504 us = ~32 ms). Today it is up to 257 ms.

Cost: two signed ~11-bit accumulators, two ~15-bit phase accumulators, a
7-bit fine-tick prescaler and the 12-bit ceiling counter per axis (the
existing one, made per-axis). Tens of LEs; nothing near a hub node.

## Bench first: `sim/tb_ps2_mouse.v`

Written and run BEFORE the RTL changes, so it fails on the module as it is
and passes on the fix. iverilog, per the repository convention:

    Run: iverilog -g2012 -I rtl -y rtl -o sim/out/tb_ps2_mouse.vvp
           sim/tb_ps2_mouse.v && vvp sim/out/tb_ps2_mouse.vvp

The bench drives the real `rtl/ps2_mouse.v` with `clk` at 32.5 MHz and `ce`
one cycle in four (as `clk8_en_p` is), feeds it PS/2 reports on the
`ps2_mouse[24]` toggle every 16 ms, and decodes the quadrature it gets back
the way the ROM does: one count per `x1` edge, direction from `x2` at that
edge. Every check is stated as a number a test can assert:

| test | input | asserts |
|---|---|---|
| silence | no reports for 100 ms; then one zero report | zero edges on both axes |
| burst (the defect) | one report of +200, DIV=8, then nothing for 300 ms | total edges = 25 (200/8); last edge <= 20 ms after the report. Today: 200 edges, last at ~101 ms. **Fails before the fix.** |
| spreading | 20 reports of +40 at 16 ms, DIV=8 | total edges = 100 over 320 ms +- the last interval; every gap between edges on one axis within 0.5x..2x the nominal 3.2 ms; no gap < 4096 ce |
| remainder | 50 reports of +3 at 16 ms, DIV=8 | total edges = 18 (150/8, floor), i.e. fine motion accumulates and is not lost; no edge more than one interval after the last report that completed a count |
| direction | +40 then -40 alternating, 10 reports each way, DIV=4 | decoded sum = 0; every edge's decoded sign matches the sign of the report that produced it |
| ceiling and backlog | 10 reports of +255 at 16 ms, DIV=4 (64 counts per report, twice the ceiling) | never more than 32 edges in any 16.1 ms window; no gap < 4096 ce; outstanding counts never exceed 64; after the last report the tail ends within 40 ms |
| dropped report today | one report of +255 then +255 within 16 ms, DIV=1 | documents the current `acc[8]!=acc[9]` drop; after the fix both are counted up to the backlog cap |
| both axes | x and y reports together, DIV=8 | each axis independent: y silent when only x moves, and vice versa |
| reset | mid-burst `reset` | outputs 0, accumulators 0, no edge for 100 ms |

A mutation pass after green (per `macplus-core-conventions`): drop the
ceiling, drop the remainder carry, double DIV, each must fail at least one
row above.

## The instrument: make PSND two-sided in the same compile

The fill span in PSND sees only interrupts inside the driver's first part;
ticks in the ~19-word pre-write window inflate `first_idx` and leave the
span alone (`SOUND_PHASE_PLAN.md`, review section 1). Counting the mouse
interrupts directly separates authentic cursor-redraw variance from
converter ticks without inference. The probe deck is at its hub-node
ceiling (`rtl/dbg_probes.sv`), so the new fields come out of PSND's own
32 bits by dropping `first_word` (known: 32 for Lemmings, 37 for PoP,
confirmed on every sample) and shrinking the frame counter:

| bits | field | today |
|---|---|---|
| [8:0] | `first_idx`, scan word at the first buffer write | same |
| [17:9] | `wrap_idx`, scan word at the write to word 0 | was [26:18] |
| [23:18] | mouse edges (x1 and y1 together) before the first write, saturating at 63 | new |
| [29:24] | mouse edges in the whole frame, saturating at 63 | new |
| [31:30] | frame counter | was 5 bits at [31:27] |

`mouseX1`/`mouseY1` live inside `rtl/dataController_top.sv`; export them
(two new output ports, like `snd_index` out of `addrController_top`) and
count edges in `rtl/snd_phase_probe.sv`. Update `scripts/read_probes.tcl`'s
PSND decode and `sim/tb_snd_phase.v` (which proves the packing) in the same
commit, and drop the `first_word` printout there.

Prediction to test against, at phase 0 after the fix: a still mouse reads
0/0; a slow hand a handful per frame; a fast diagonal hand with DIV set
right 2..5 edges in the pre-write window and 8..15 in the frame, which is
what a real 90-per-inch mouse would also produce.

## One compile, gated

One Quartus compile carrying: the converter fix, the mouse-speed selector,
the PSND repack, the existing 8-value sound-scan selector unchanged
(`0,6,8,10,12,20,28,36`, default 0), `USE_SCSI_ISSP` on. Ask first, as
always; `git checkout -- MacPlus.qsf` afterwards; `rtl/build_tag.v` stays
zeros in the repository. No hardware step below is possible before it.

## Hardware, in order

1. **Calibration.** Control Panel, Mouse Tracking at its slowest (1:1, no
   System acceleration). Move the mouse a measured 5 in along a ruler and
   read the cursor travel in pixels (a 512-px screen is 7.1 in at 72 dpi).
   A real Plus at 1:1 moves the cursor 90 px per inch if one interrupt is
   one pulse, 180 if one per edge. Pick the DIV that gives 90; if no value
   gets near 90 or 180 the pulse-vs-edge question is answered the other
   way. Record the mouse's rated resolution and the value chosen.
2. **Lemmings at phase 0**, System 7.1, three runs as before (still, slow,
   fast circles), 40+ PSND samples each. Pass: fill span 31-32 on every
   frame regardless of hand, `first_idx` worst case <= 25, mouse edges
   before the first write <= 5 with a fast hand, no LATE frames with a
   slow hand, and by ear no crackle with a moving mouse. A few LATE frames
   with a deliberately fast hand are Lemmings' own margin at phase 0 and
   are recorded, not fixed.
3. **Feel.** Finder drag, MacPaint freehand line, a slow one-pixel nudge;
   the cursor stops when the hand stops; no lost fine motion; System's
   Mouse Tracking settings change the feel the way they do on a real Mac.
4. **Controls.** PoP (still buzzes at 0, clean at 28: the mouse fix must not
   change either), Lode Runner, the boot chime, Bard's Tale from issue #23
   at phase 0 with a moving mouse (it was reported distorting at 20/28/36,
   which is the same mechanism and should now be clean there too).
5. **Regression.** 128K and 512K models with the same converter; 16 MHz
   turbo (`clk8_en_p` is unchanged under turbo, so the rate is the same;
   confirm).

## Shipping

The dev build is both pieces together; that is what the branch is for.
What ships depends on one fact still outstanding: whether a real Macintosh
Plus buzzes playing Prince of Persia. The PAL decode says it must
(`SOUND_PHASE_PLAN.md`, "RESULT 2026-09-21"), but no first-hand report
either way has been found.

| real Plus on PoP | sound-scan selector | mouse fix |
|---|---|---|
| buzzes (predicted) | phase 28 is an enhancement, not a restoration; ship it only as a documented option defaulting to 0, or drop it ([[period-authenticity-matters]]) | ships |
| clean | the model is missing something and the sound-phase work reopens; the selector stays on the dev branch | ships |
| unknown when we want to release | release default 0, selector held back | ships alone |

In every row the mouse fix ships, so the commits are laid out to make the
cut clean:

1. `sim/tb_ps2_mouse.v` (failing) and `MOUSE_PLAN.md`.
2. `rtl/ps2_mouse.v` fix, bench green. Touches no sound-phase file.
3. Mouse-speed selector in `MacPlus.sv` (config string and the three
   status bits into the converter). Separable from 2 if the release bakes
   the value in.
4. PSND repack: `dataController_top.sv` ports, `snd_phase_probe.sv`,
   `read_probes.tcl`, `tb_snd_phase.v`. Dev-only; never part of a release
   cut (the probe deck is stripped anyway, per `UPSTREAM_PR_PLAN.md`).
5. Hardware results into this document.

A mouse-only release is then commits 1-3 cherry-picked onto the release
branch with the sound-scan default at 0 and, if the selector is not
shipping, its config line removed. The 3-way re-cut recipe in
`UPSTREAM_PR_PLAN.md` applies unchanged.

## Open decisions (Daniel's)

- Ship the mouse-speed selector, or bake the calibrated DIV in?
- The `2,3,4,6,8,11,16,1` value list and which value is index 0.
- Whether to ask a real-Plus owner for a PoP listen (the shtunner TikTok
  and the CRT Collective post are the two candidates found; 68kMLA would
  be the place to ask) before the release decision, or release the mouse
  fix alone without waiting.
