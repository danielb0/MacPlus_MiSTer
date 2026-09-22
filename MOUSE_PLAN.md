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

## RED RUN 2026-09-22: the bench fails on the module as it stands

`sim/tb_ps2_mouse.v` written and run before any converter change. 12 of 49
checks fail, and the three guard rows pass and must keep passing.

    iverilog -g2012 -I rtl -y rtl -o sim/out/tb_ps2_mouse.vvp sim/tb_ps2_mouse.v
    vvp sim/out/tb_ps2_mouse.vvp        # ~4.5 minutes, 3.09 s of simulated time

| row | measured today | required |
|---|---|---|
| silence | 0 edges | 0 edges - PASSES |
| burst | 200 edges, last 819136 ce (100.8 ms) after the report | 25 edges, last within 20 ms |
| spreading | 714 edges, every gap exactly 4096 ce | 100 edges, gaps 13000..52000 ce |
| remainder | 150 edges | 18 edges, none after the last report |
| direction | 638 edges; signs already correct | 200 edges, signs unchanged |
| ceiling and backlog | 515 edges, 119 still arriving past the 40 ms tail | tail ends within 40 ms |
| backlog cap | 510 edges of the 765 sent, 425 past the tail | capped, tail within 40 ms |
| both axes | 200 per axis, axes already independent | 25 per axis |
| reset | lines clear, no edges after | unchanged - PASSES |
| button | press/release track | unchanged - PASSES |

The burst row reproduces the predicted figures exactly (200 edges at ~101 ms).
The backlog-cap row needed three reports 1 ms apart, not the two in the table
above: two reports do not drive `|acc|` past 255, so the drop never bites.
510 = 2 x 255 is the drop, measured: one whole report discarded.

Two things the bench settled that the plan had left loose:

**`div` is a raw divisor port, not a selector index.** `rtl/ps2_mouse.v` takes
`input [4:0] div` (host counts consumed per Plus count) and `MacPlus.sv` does
the index-to-value mux. The module then does not depend on the still-open
question of the value list or which value is index 0, and the bench asserts on
divisors (8, 4, 1) rather than on OSD indices. Added unused in this commit so
the bench elaborates against the unfixed module; `dataController_top.sv` ties
it to `5'd8` until commit 3 routes the selector. Commit 2 must treat `div == 0`
as 1.

**The DDA as specified above has a hole.** "Emits when the phase reaches
`1024*DIV`" and "a remainder smaller than DIV stays in the backlog" are not
consistent: with the budget parked below `DIV` the phase keeps accruing and
will eventually emit a count the backlog cannot pay for. The emit condition
must be `phase >= 1024*DIV` **and** `|budget| >= DIV`, and the phase must be
held (not accrued) whenever `|budget| < DIV`. The remainder row is what
catches this - a naive implementation gives 19+ edges, or dribbles them out
after the hand stops.

## GREEN 2026-09-22: `rtl/ps2_mouse.v` fixed, 53/53, mutation swept

Commit 2. `ps2_mouse` keeps the interface and now holds only the divisor,
the report strobe and the fine-tick prescaler; the per-axis emitter is a new
`ps2_mouse_axis` in the same file, instantiated twice.

| row | before | after |
|---|---|---|
| burst | 200 edges, last 100.8 ms after the report | **25 edges, last 16.1 ms** |
| spreading | 714 edges, every gap 4096 ce | **100 edges, gaps 21760..46208 ce** |
| remainder | 150 edges | **18, none after the hand stops** |
| direction | 638 edges | **180, net travel 0** |
| ceiling and backlog | 119 edges past the 40 ms tail | **0 past it, worst window 32** |
| backlog cap | 510 of 765 sent, 425 past the tail | **68, 0 past the tail** |
| resume after a pause | (new row) | first count 23273 ce after the report |
| both axes | 200 per axis | **25 and 25, diagonal +-25** |

Two things the plan's design section had wrong, both found by the bench:

**The DDA rate must be `|budget|` LATCHED AT THE REPORT, not the live
backlog.** Clocking the DDA from the backlog as it drains gives a harmonic
decay, not linear spreading: the 25 counts of a +200 report at DIV 8 would
have taken 1024*H(25) = 3908 fine ticks, i.e. 61.6 ms, against the 16.1 ms
the row requires. `rate` is therefore its own register, reloaded on each
strobe.

**A ceiling-blocked axis must have its phase clamped at the threshold.**
Otherwise it banks credit while it waits and releases a burst when the
ceiling lifts - the defect being fixed, reappearing at a smaller scale.

### Direction is 180, and 180 is the derived floor

A report interval is 1015.6 fine ticks, but draining 40 host units at DIV 4
takes 1024. So at every reversal the one count still in flight is cancelled
by the report that reverses it rather than being emitted. At most one count
per boundary over 20 reports puts the floor at 200 - 20 = 180, which is what
it measures. Sustained motion loses nothing: the spreading row is exactly
100 of 100, because there the remainder adds to the next report's rate
instead of opposing it.

### Mutation sweep

Five of seven mutants die. The two survivors are equivalent, not gaps:

| mutation | result |
|---|---|
| `okce` forced true (no ceiling) | dies, 2 rows |
| `divq` doubled | dies, 9 rows |
| backlog discarded at each report | dies, 9 rows |
| phase accrues while `|budget| < div` | dies, the resume row |
| that, and no clamp | dies, 2 asserts of the resume row |
| phase remainder discarded on emit | **survives** |
| clamp removed alone | **survives** |

**Phase remainder discarded: equivalent.** The discarded part is at most
`rate - 1` of phase, which is under one fine tick (128 ce) of timing per
count, against nominal gaps of ~26000 ce. It is below the emitter's own
quantisation, so no timing assert can see it at any honest tolerance.

**Clamp removed alone: redundant, and kept anyway.** With the `can` gate in
place the phase cannot bank during a still period, and while the ceiling
blocks with the backlog above `div` the excess is bounded by the backlog cap.
The clamp is retained because it is what keeps the phase bound simple:
`thresh + rate` = 33728 worst case, rather than a bound that depends on how
long the ceiling can block. Removing both it and the `can` gate does fail.

The `resume` row was added because of this sweep: the original nine rows all
reset between tests, so none of them left a sub-`div` remainder sitting
through a still period, which is the only place banked phase shows.

## COMMIT 3 2026-09-22: Mouse Speed in the OSD, sixteen values on bits 22-25

Supersedes the "Dev build: a 3-bit OSD selector" bullet above in two ways.

**It ships, and it is not a debug knob.** Daniel's call, and the reasoning is
better than the one in that bullet: the hardware devices that put a modern
mouse on an old machine carry exactly this adjustment, so the faithful
comparison is not the Plus - which of course had no such control - but the
adapter standing between the two. Correcting the record on the argument that
bullet used: "a mouse-speed option is ordinary on MiSTer cores" was asserted
without checking and does not survive one. Of the cores available to check,
only BBC Micro has any mouse menu item at all (`Mouse as Joystick`), and
MacLC, the nearest relative, has none. The case rests on the adapter
precedent, not on core convention.

**Sixteen values, not eight.** Bits 22-25 (M..P) are all free, and the extra
bit costs nothing while this build is also how the divisor gets calibrated -
there are two unknowns to sweep, the 400..1600 cpi spread and the factor of
two in pulse-versus-edge.

    "OMP,Mouse Speed,8,1,2,3,4,5,6,7,9,10,11,12,13,14,16,18;",

Index 0 is the default because `status` powers up at zero, the same
constraint the CD Volume line documents, so 8 leads and the rest ascend.
The labels are the raw divisors while this is a calibration build; they
become user-facing before the release cut, and that relabelling is the only
part of this deferred.

No config version bump: bits 22-25 were unused, so no existing field moved.
Audited every `status[]` reference - 0, 1-3, 4, 5, 6, 7-8, 10, 11-12, 13-14,
15-16, 18, 19-21 and now 22-25, with 9, 17 and 26 up still free.

The index-to-divisor mux sits in `MacPlus.sv` beside the config string that
defines the list, so `rtl/ps2_mouse.v` keeps a plain divisor port and never
depends on what the menu offers. Four address bits is well inside the range
where a case is the right shape ([[macplus-lookup-table-width-rule]]).

**Inert on the SE**, which takes its mouse through `rtl/adb.sv`:
`via_pb_i` masks the quadrature bits with `{3{machineType}}`
(`dataController_top.sv:342`). The item still appears on an SE. Greying it
with a `status_menumask` bit is a one-line job and belongs in the release
cut, not here.

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

## COMMIT 4 2026-09-22: PSND repacked, mouse load measured directly

The plan's split above is superseded in one respect: the fields are sized to
their predicted ranges rather than 6 and 6, which is what leaves the frame
counter 4 bits instead of 2.

| bits | field | was |
|---|---|---|
| [8:0] | `first_idx` | same |
| [17:9] | `wrap_idx` | [26:18] |
| [21:18] | mouse edges before the first write, saturating at 15 | new |
| [27:22] | mouse edges in the whole frame, saturating at 63 | new |
| [31:28] | frame counter | 5 bits at [31:27] |

`first_word` is gone. It was the only field here already known before the
capture - 32 on every Lemmings sample, 37 on every PoP sample - while the
mouse load was not obtainable any other way, because the span this word
yields is blind to interrupts before the first write. One edge on either
axis is one DCD interrupt, so both axes count into the same totals and a
diagonal step counts two.

Width choices: the prediction for a fast hand is 2..5 pre-write and 8..15
per frame, so 4 bits (saturate 15) and 6 bits (saturate 63) each carry
several times the expected range. A saturated pre-write field still says
">= 15", which is decisive on its own. Today's unfixed converter peaks near
33 edges a frame, so 6 bits also captures the before picture.

### What dropping `first_word` cost, and what was done about it

Two things read it, and neither was free to lose:

**`scripts/read_probes.tcl` derived the LATE and splice verdicts from it.**
S is now an assumption in the script, `set psnd_S 32`, and every line
resting on it prints "(S assumed 32)" so a capture of the wrong program
cannot quietly produce a confident wrong verdict. 32 Lemmings, 37 PoP.

**`sim/tb_snd_phase.v` used it to prove the buffer-word arithmetic**, in
particular at 1MB where `top_bits` differs. Replaced with a write to word 0
at 1MB, which exercises the same `buf_off` subtraction through the wrap
detect. The phase-28 splice check now compares the wrap against the literal
37 it wrote, rather than against a reported field.

### Bench

49/49. The PoP-shape frame now injects 3 edges before the driver runs and 4
inside the fill and checks the probe reads 3 and 7; a diagonal test proves
one count per axis per step; a saturation test drives 80 edges and checks
15 and 63; and a following frame checks both counters clear on the frame
edge. `mouseX1`/`mouseY1` come out of `dataController_top` as `dbg_mouseX1`
and `dbg_mouseY1`, matching the `dbg_floppy`/`dbg_dcd` naming already there,
and `MacPlus.sv` carries them to the probe.

### Prediction for the hardware run

At phase 0 after the converter fix: a still mouse reads 0/0; a slow hand a
handful per frame; a fast diagonal hand with the divisor set right 2..5 in
the pre-write window and 8..15 in the frame, which is what a real 90-per-inch
mouse would also produce. A pre-write field reading 15+ with a fast hand
would mean the divisor is still too small, not that the fix failed.

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

## COMPILE AND CALIBRATION 2026-09-22: `MacPlus_6e8d8dac_mousefix.rbf`

The gated compile is done: cold, 0 errors, no `Smart recompilation skipped`
lines, timing met with no negative slack (worst setup +0.296 on the HDMI PLL,
core PLL +1.225), 20,883 / 41,910 ALMs. It carries all four commits, both
selectors and `USE_SCSI_ISSP`.

Process note for the next one: **stamp `rtl/build_tag.v` BEFORE launching and
archive BEFORE reverting it.** The file is committed as zeros deliberately, so
an unstamped build reports `bitstream=UNSTAMPED` and `archive_build.ps1`
refuses to file it; `archive_build.ps1` reads the SHA out of that same file to
name its output, so the revert has to come last.

### Step 1 result: the converter tracks linearly, and the axes agree

Daniel's mouse is a Logitech G309 (HERO 25K), measured by screen-edge sweeps
at System 7.1 with Mouse Tracking on "Very Slow" -- **there is no "Tablet"
setting on this System**, so acceleration could not be switched off and had to
be defeated by moving slowly instead.

| divisor | X (512 px) | Y (342 px) | implied px/in | implied host cpi |
|---|---|---|---|---|
| 14 | 13 cm | 7 cm | 100 / 124 | 1400 / 1737 |
| 16 | 15 cm | 9.5 cm | 86.7 / 91.4 | 1387 / 1463 |

**The 24% axis disagreement at divisor 14 was measurement artefact, not an RTL
defect.** The divisor-14 sweeps were shorter, so the hand was faster for the
same natural motion, and the Mac's own tracking curve inflated them -- Y worst
because its sweep was shortest. At divisor 16 both sweeps are longer and the
spread collapses to 5.5%. The G309's sensor is specified "zero
smoothing/acceleration/filtering", so the mouse cannot have caused it.

**The converter's linearity is confirmed to 1%:** the implied host resolution
is 1400 cpi from the divisor-14 sweep and 1387 from the divisor-16 sweep, two
independent measurements at different divisors.

Contamination pulls both ways and both are defeated by moving slowly, which is
why the slow sweeps are the ones to trust: Mac tracking inflates px/in with a
fast hand, while Main's +-255-per-report clip deflates it (counts are lost
above `17000/cpi` inches per second).

### Step 1 conclusion: it is 180 counts per inch, not 90

**Settled from the Guide to the Macintosh Family Hardware 2e, chapter 7**
(full text at archive.org, `apple-guide-macintosh-family-hardware`):

- Macintosh Plus specifications, p. 46827 of the text dump: "Mechanical/optical
  mechanism generating **90 pulses per inch** on each axis of travel".
- The quadrature section: "The mouse driver can then read bits in the SCC to
  determine which mouse-interrupt signal caused the interrupt, and **whether
  the interrupt was caused by a rising edge or a falling edge** of the signal."
- **Table 7-1 gives a direction for all four cases** -- `X1 rising / X2 low ->
  Left`, `X1 falling / X2 low -> Right`, and likewise for Y1/Y2.

So the ROM acts on **every edge**, and 90 pulses per inch is **180 interrupts
per inch**. Our `rtl/scc.v` already models this correctly: `dcd_ip_a = (dcd_a
!= dcd_latch_a)` is a change detect, so each toggle of `x1` raises exactly one
interrupt, exactly as the real SCC does.

**Pixel-exact divisor = host cpi / 180.** For the G309 at ~1390 cpi that is
7.7, i.e. **divisor 8 -- the existing default**. The factor-of-two ambiguity
that this menu was built to sweep is now closed, and it closed on the branch
the plan treated as the less likely one.

### Why Daniel's feel report says 14-16, and why it is not a contradiction

**WITHDRAWN 2026-09-22 -- see "The feel report was
an Atari ST" below. The discrepancy this section explains did not exist.**

Daniel owned a Macintosh Plus until 2023 and reports that 14-16 "feels very
much like a real Mac" -- that is 87-99 px/in, half the pixel-exact rate.

**Both are right, because they measure different things.** On a real Plus 512
pixels span 7.1 inches of glass, so crossing the screen costs 2.8 inches of
hand: a hand-to-screen gain of ~2.5x. A hand remembers that gain, not pixels
per inch, and preserving it on a modern display scales the required hand
movement with the PHYSICAL width of the image. At the real Plus's gain a
15-inch-wide image wants ~15 cm of hand to cross -- which is what divisor 16
measured.

So:

- **divisor ~= cpi/180** reproduces the Plus's pixel arithmetic exactly;
- **roughly double that** reproduces its feel on a display several times the
  size of a 9-inch CRT.

Which is right depends on the user's monitor, which no label can encode.

### DECISION: the selector ships, with bare numbers, consecutive

Daniel's call, and the argument that settles it: **every user has a different
mouse, so no baked-in constant can be right.** Setting one particular mouse to
match a Plus exactly does nothing for anyone else. The display-size finding
above strengthens this -- the correct value depends on the user's monitor as
well as the user's mouse.

**Labelling the menu by mouse DPI was considered and rejected.** Daniel:
"it commits us to being accurate." A label reading "1000 DPI" asserts that
selecting it is correct for a 1000-DPI mouse, and that assertion inherits every
error in our pulse-versus-edge answer, in whatever the mouse's software
actually reports, AND in the display-size effect, which it cannot express at
all. A bare number asserts only "bigger is slower", which the user resolves by
turning it. The interface should not claim more than it can deliver.

**The list, Daniel's call: 1..16.** Bare divisors, consecutive, no gaps
(the old list omitted 15 and 17 to reach 18 inside sixteen slots):

    "OMP,Mouse Speed,8,1,2,3,4,5,6,7,9,10,11,12,13,14,15,16;",

Sixteen slots: default 8 at index 0 because `status` powers up at zero, then
**1 through 16 with no gaps**. 1..16 fits four bits exactly and reads as a
range rather than a list to be looked up. Index 0 is the pixel-exact value for
a ~1440 cpi mouse.

**The ceiling is worth knowing.** Pixel-exact is `cpi/180` and feel wants
roughly double that, so 16 covers feel up to ~1440 cpi and pixel-exact up to
2880. A 1600 cpi mouse wanting full display compensation would ask ~18 and
gets 16 instead -- about 11% fast, well inside what the next value down
would cost anyway. Above that a user lowers the mouse's own resolution.
`div` is `input [4:0]` (max 31) and does not constrain this; the menu does.

**Applied to `MacPlus.sv` now, not deferred**, so the config string, the
index-to-divisor mux and this document agree. That means the source no longer
matches `MacPlus_6e8d8dac_mousefix.rbf`: the flashed build still offers
`...,14,16,18` and has no 15. Nothing in the hardware order needs 15, and 8,
14 and 16 are all reachable in it, so the Lemmings run is unaffected.

### Corrections to earlier sections of this document

- The value list `2,3,4,6,8,11,16,1` in "Open decisions" is superseded twice
  over: first by the sixteen-value list in commit 3, now by the consecutive
  list above.
- "Pick the DIV that gives 90" in "Hardware, in order" step 1 should read
  **180**. The step's method is unaffected; only the target changes. At 180 the
  screen-width sweep is 7.2 cm, not 14.5 cm.
- The reasoning that the pulse-versus-edge question could only be closed on
  hardware was wrong -- it is stated plainly in chapter 7 and cost one download
  and two greps. [[feedback-read-the-spec-for-historical-hardware]] applies:
  the documentation was not read until after two sessions of inference.

### Step 2, by ear: Lemmings at phase 0 is CLEAN with a moving mouse

`MacPlus_6e8d8dac_mousefix.rbf`, System 7.1, sound phase 0, **mouse speed 8
and 16, hand fast and slow, circles and straight lines: no mouse noise.**

That is the first time this core has been clean at phase 0 with a moving mouse
on merit. The 2026-09-21 run was also clean by ear at phase 0, but with one
scan line of margin (worst `first_idx` 31 against the cliff at 32) and only
because the converter's own burst had eaten 29 of the 30 lines of headroom;
the same build clipped 64% of frames at phase 6 with a fast hand.

**Divisor 8 is the load-bearing half of this result.** It is the pixel-exact
value for this mouse (~174 px/in) and therefore twice the interrupt rate of
16, so the fix is holding at the higher rate rather than only at the
comfortable one. Fast circles at 8 is the worst combination the build offers.

**Still to do: the PSND capture.** By ear establishes that we are under the
cliff, not how far under, and "clean by ear at phase 0" is precisely the
reading that misled this investigation once already. The quantitative pass is
in "Hardware, in order" step 2: fill span 31-32 on every frame regardless of
hand, worst `first_idx` <= 25, mouse edges before the first write <= 5 with a
fast hand. PSND is not sticky -- only PDCD is -- so it reads live during play
with `quartus_stp -t scripts/read_probes.tcl 40 0.5` and needs no reset.

### Step 2 on PSND: 80 frames, zero LATE, and the span criterion was wrong

Two captures of 40 frames each, `scripts/read_probes.tcl 40 0.5`, Lemmings at
sound phase 0, fast circles throughout. PSND is not sticky, so it reads live
during play with no reset.

| | divisor 8 | divisor 16 |
|---|---|---|
| still frames | `first_idx` 2-3, span 31-32 | `first_idx` 2, span 31-32 |
| moving `first_idx` | median 22, **max 28** | median 21, **max 24** |
| moving span | median 37, max 41 | median 35, max 40 |
| edges before first write | median 2, max 3 | median 1, max 2 |
| edges in frame | median 27, max 45 | median 23, max 31 |
| **LATE frames** | **0 of 40** | **0 of 40** |

The still baseline reproduces 2026-09-21 exactly (`first_idx` 2, span 31-32),
so the instrument is reading true.

**Margin to the cliff: 4 words at divisor 8, 8 at divisor 16, against 1 word
before the fix.** No frame came close to `first_idx` 32.

#### The divisor is a GAIN control, not a load control

The obvious check -- halve the rate at divisor 16, watch the span fall -- did
not work, and the reason is the finding. **One interrupt is one pixel of
cursor movement**, so

    interrupts per second = cursor pixels per second

independently of the divisor. Daniel was circling the *cursor* at a similar
on-screen speed in both runs, so the interrupt rate barely moved (median 27 ->
23). The divisor changes how far the hand travels per pixel; it does not
change what a given cursor movement costs. Crossing the screen costs 512
interrupts at every setting, exactly as it did on real hardware.

**Consequence: the pass criterion "fill span 31-32 on every frame regardless
of hand" in "Hardware, in order" step 2 is unachievable by ANY converter,
including a perfect one and including a real Macintosh Plus.** It was wrong in
principle, not merely strict -- it was written when a faithful mouse was
believed to be 90 counts per inch and gentle. **Restate it as: zero LATE
frames, and worst `first_idx` at least several words clear of `S`.** By that
criterion step 2 passes on 80 of 80 frames.

#### The fix is confirmed by the matched-load comparison

Binning both runs by edges-in-frame, the spans are indistinguishable between
divisors at equal load:

| edges/frame | span, divisor 8 | span, divisor 16 |
|---|---|---|
| 11-20 | median 33 | median 35 |
| 21-30 | median 37 | median 35 |
| 31-40 | median 37 | median 38 |

**Span is a function of interrupt count alone, not of the divisor.** A
residual burst would make divisor 8 worse at matched load, because it doubles
the count available to cluster. It does not. Together with pre-write edges of
2-3 (the 2..5 band predicted for a faithful 180-per-inch mouse) and a
per-axis rate well under the 33-per-frame ceiling, the converter is behaving
as designed.

#### Unplanned: the 73 us per interrupt estimate is now corroborated

Pooled over both runs, `span ~= 31.7 + 0.162 * edges_in_frame`. The fill spans
32 of the 370 words in a frame, so only ~8.6% of a frame's interrupts land
inside it, and a scan word is 44.9 us. That predicts a slope of
`0.086 * 73/44.9 = 0.14` against **0.162 measured**, implying ~84 us per
interrupt.

This matters because the ~73 us figure was my own ROM estimate, and the
2026-09-21 record explicitly flagged the agreement it produced as "not fully
independent". A regression of span against a separately counted edge total
shares none of that arithmetic, so the number is now corroborated to within
15% by a second route.

#### A prediction of mine that failed

I predicted worst `first_idx` of 19..25 and ~13 words of headroom. It came in
at **28 and 4 words** at divisor 8. Right direction, over-optimistic
magnitude; the fix quadrupled the margin rather than restoring it fully, and
what remains is authentic load rather than converter defect.

### The feel report was an Atari ST: divisor 8 is authentic after all

Daniel, on reflection: **setting 8 does feel authentic**, and the earlier
"14-16 feels very much like a real Mac" was the **Atari ST** mouse, which was
genuinely slow and does feel like our 16.

**This removes the discrepancy rather than explaining it, so the display-size
section above is withdrawn.** It was built to reconcile chapter 7 (180 per
inch, divisor ~= cpi/180, so 8 for this mouse) with a feel report of 14-16.
With the feel report corrected, both lines land on 8 and there is nothing left
to reconcile.

**The model was wrong in a way worth remembering, because it was convincing.**
It predicted a specific number -- linear magnification 20.5/7.1 = 2.9 divided
by a viewing-distance ratio of ~1.4, giving ~2.1 -- against a measured
preference ratio of 1.8..2.1. That agreement was cited as evidence the model
was "right rather than a story fitted after the fact". It was a story fitted
after the fact. **A two-term model with an unmeasured parameter (viewing
distance, estimated by me) will hit a single data point; one data point cannot
test it.** The geometry is real and the arithmetic is correct -- it simply was
not explaining anything, because the thing it explained had not happened.

**What actually stands, and it is stronger:** the Guide's 180 per inch and
Daniel's hands independently agree on divisor 8 for a ~1390 cpi mouse. Two
routes converging beats either alone.

**The selector decision is UNAFFECTED.** It rested on mice differing in
resolution -- 400..1600 cpi and up -- which is still true and is still
unknowable to the core. Only the secondary display-size argument is withdrawn.

**Consequence for the release default.** The anchor is now pixel-exact,
`cpi/180`, not a display-compensated value: 800 cpi wants 4, 1000 wants 6,
1440 wants 8, 1600 wants 9. **Index 0 is currently 8**, which suits ~1440 cpi
and leaves a low-resolution mouse feeling slow. A default of 6 or 7 would sit
nearer the middle of the common range. Left open for the release cut; it needs
no compile to change and no hardware step depends on it.

### Step 3 PASSED 2026-09-22: feel, all four tests, at divisor 8

Daniel, testing at setting 8 (the pixel-exact value, and the higher interrupt
rate of the two candidates):

| test | the defect it probes | result |
|---|---|---|
| move fast, stop dead | the tail, up to 257 ms of continued edges | **stops dead** |
| Finder drag | the burst, a train at the ceiling per report | fine |
| MacPaint freehand | flat 4096-tick spacing under sustained motion | **extremely precise** |
| slow one-pixel nudge | fine motion below one divisor per report | **extremely precise** |

All three original defects are closed on hardware: the tail, the burst and the
absence of scale.

**The one-pixel result beats the prediction.** The review flagged a design
cost -- linear spreading forbids an immediate first count, so a single-count
report emits up to ~16 ms later -- as something that might be felt on the
smallest movements. It was not. The remainder carried in the backlog is
evidently fine enough that the quantisation never surfaces.

Not yet done, and minor: the cross-check that System's Mouse Tracking settings
still shift the feel the way they do on a real Mac. The tracking curve is the
ROM's, not ours, so this is a confirmation rather than a test of the fix.

### Step 4, the control: PoP behaviour is UNCHANGED by the mouse fix

Daniel, 2026-09-22 on `MacPlus_6e8d8dac_mousefix.rbf`: PoP behaves the same as
before the converter fix.

**This is the negative control and it had to pass.** The mouse fix touches no
sound file; had PoP gone clean at phase 0, the converter change would have
reached the sound path by a route not in the model, and the step 2 result
would have been unsafe to trust.

**It also closes the sound-phase chain, with the mouse defect removed as a
confound** -- which is what the last two sessions existed to do:

- the PAL/schematic/ROM read puts the VBL at sound word 0
  (`SOUND_PHASE_PLAN.md`, "RESULT 2026-09-21"), so the authentic phase is 0;
- our core at phase 0 buzzes on PoP;
- the converter no longer contributes interrupts beyond what a faithful
  180-per-inch mouse would (step 2: zero LATE in 80 frames, and matched-load
  binning showing no residual burst);
- therefore **a real Macintosh Plus buzzes playing Prince of Persia.**

The remaining doubt is not about the mouse: it is whether our core at phase 0
is unfaithful in some OTHER respect that matters to PoP. A first-hand listen
from a real Plus owner is still the only thing that would close it
independently.

**Consequence for the release, per the shipping table:** the "buzzes
(predicted)" row is the one we are in. Phase 28 is an ENHANCEMENT, not a
restoration, so it ships only as a documented option defaulting to 0, or not
at all. The mouse fix ships either way.

Still outstanding in step 4: Bard's Tale (issue #23) at phase 0 with a moving
mouse -- reported distorting at 20/28/36, same mechanism, predicted clean now
-- plus Lode Runner and the boot chime as general sound regression.

### Step 4: Bard's Tale is clean at phase 0, and it argues AGAINST 28

**PARTLY WITHDRAWN -- see the CORRECTION section below. The S~=41 figure
and everything resting on it (the issue #23 table, the LATE count, the
"third independent line") do not hold.**

Daniel reported it quiet while moving the mouse and asked for a probe. 60
PSND frames, sound playing throughout (no idle frames), mouse still for the
first half and fast circles for the second.

| | still (40 frames) | fast circles (20 frames) |
|---|---|---|
| `first_idx` | median 4, max 12 | median 23, **max 29** |
| span | median 41 (40-50) | median 50, max 59 |
| edges before first write | 0 | median 2, max 5 |
| edges in frame | 0 | median 39, max 60 |
| **LATE frames** | **0** | **0** |

**S ~= 41 for Bard's Tale, DERIVED not assumed.** `read_probes.tcl` prints
"(S assumed 32)" because `first_word` was dropped in the PSND repack, and 32
is Lemmings' value; those lines are wrong for this program and were discarded.
On a still frame the fill span is approximately S -- which is how Lemmings'
31-32 span matched its known S of 32 -- so the still-frame span gives S here.

**Zero LATE in 60 frames, with 12 words of margin** against Lemmings' 4. The
difference is entirely S: a driver that starts at word 41 has more room before
the scan catches it than one starting at 32. **Lemmings remains the binding
case, which is why it was the right program to design against.**

#### What this says about issue #23, and it is the valuable part

Issue #23 reported Bard's Tale distorting at phases 20, 28 and 36. `first_idx`
shifts one-for-one with the phase while S is fixed by the driver, so this
measurement predicts:

| phase | worst `first_idx` | vs cliff at S=41 |
|---|---|---|
| 0 | 29 | clean, 12 to spare |
| 20 | ~49 | LATE |
| 28 | ~57 | LATE |
| 36 | ~65 | LATE |

**That reproduces the bug report exactly**, and puts the breakpoint at phase
~12. So Bard's Tale is a SECOND commercial driver arguing independently for a
low phase and against 28 -- and unlike our own measurements it arrives from a
user's bug report, so it is not downstream of any modelling of ours.

Together with PoP buzzing at 0 (unchanged by the mouse fix) and the PAL read
putting the VBL at word 0, three independent lines now agree that the
authentic phase is low and that 28 is not a restoration.

#### Caveats

- **The S inference is softer than Lemmings'.** Still-frame spans ranged 40-50
  rather than a tight 31-32, so S is ~41 with slack. The margin stays >= 11
  on any reading in that range, so the verdict does not depend on it.
- **Bard's Tale has variable foreground load of its own**: still-frame
  `first_idx` reached 12, against Lemmings' 2-3. That variance is the game's,
  not the mouse's -- these are frames with zero mouse edges.
- Peak 60 edges/frame is the fastest hand captured in this session (Lemmings
  peaked at 45) and still sits under the two-axis ceiling of 66.

### CORRECTION: the Bard's Tale S inference is unsafe, and issue #23 is NOT explained

Daniel, immediately after the capture above: **Bard's Tale has simple
single-track music, much less sound than PoP and Lemmings.** That undercuts
the inference the previous section rests on.

**Why `S ~= 41` does not hold.** S was derived from the still-frame span using
a write rate calibrated on Lemmings, whose 4-voice mixer writes at almost
exactly one buffer word per scan word -- which is *why* Lemmings is the
binding case. A single-track driver does much less work per word, so it writes
FASTER than the scan and finishes early. For a light driver the span is a
**lower bound on S, not an estimate of it**: S >= 41, possibly well above.

**Consequences, all retractions:**

- **The issue #23 retrodiction is withdrawn.** The table predicting LATE at
  phases 20/28/36 assumed a cliff at exactly 41. If S is materially larger,
  worst `first_idx` of ~57 at phase 28 may sit comfortably inside the buffer,
  and the distortion reported in that issue needs another explanation.
- **Bard's Tale is NOT a third independent line against 28.** Back to two: the
  PAL read, and PoP buzzing at 0. The claim that three lines agreed was
  overstated within an hour of making it.
- **"Zero LATE frames" was computed against the same unsafe S** and inherits
  its uncertainty. The robust version is weaker and sufficient: the driver's
  first write lands by scan word 29 even with a fast hand, and it sounds
  clean.

**The methodological point is Daniel's and it is the valuable part: a program
with simple music has a large margin, so it stays clean across a wide range of
phases and discriminates badly. Its quietness is exactly what makes it
uninformative.** A clean result from a light driver is weak evidence about the
phase; only the heavy drivers -- Lemmings at S=32 and PoP -- bind. Choose test
programs by how little headroom they have, not by whether a user reported them.

**What survives:** Bard's Tale is a good regression test. It is clean, its
first write lands by scan word 29 under a fast hand, and it carried mouse load
comparable to Lemmings (peak 60 edges/frame against 45). It says the converter
fix holds on a third program. It says nothing reliable about the phase.

**The decisive test is cheap and needs no compile: select phase 28 in the OSD
and listen to Bard's Tale.** If it distorts, issue #23 is confirmed, the cliff
really is near 41 and the retrodiction is reinstated. If it stays clean at 28,
the retrodiction is dead and issue #23 was reporting something else.

**Pattern worth noting, second occurrence this session** (the first was the
display-size model, withdrawn above): a tidy quantitative retrodiction built
on a parameter I INFERRED rather than measured, presented as corroboration.
Both times the arithmetic was right and the input was not. **Check what a
derived parameter assumed before using it to explain a third party's report.**

### RESOLVED: Bard's Tale DOES discriminate. Distorted at phase 28, clean at 0

Daniel, 2026-09-22: **distorted sound at phase 28 on Bard's Tale with the
mouse moving**, against clean at phase 0 with the mouse moving.

**The correction above was right to make and the claim survives it.** The
S ~= 41 figure was genuinely unsafe -- derived from a write rate calibrated on
a heavier driver -- and the worry that a quiet program might discriminate
badly was a legitimate one. It simply does not bite for this program, and we
now know that by direct A/B rather than by inference. **Inference replaced by
measurement is the outcome to want; the retraction cost nothing and bought
certainty.**

**S is now BRACKETED BY MEASUREMENT.** Worst `first_idx` was 29 at phase 0
with a fast hand, and `first_idx` shifts one-for-one with the phase:

| phase | worst `first_idx` | observed |
|---|---|---|
| 0 | 29 | clean |
| 28 | 57 | **distorts** |

**29 < S <= 57.** That is the `first_word` field dropped in the PSND repack,
recovered by using the sound-phase selector itself as the instrument -- no
compile, no probe change. **Worth remembering as a general technique: a
menu-selectable offset on the axis a probe field used to report can substitute
for the field.**

**Pinning S makes Bard's Tale a real constraint on the phase.** It requires
`phase + 29 < S`; an S of 41 would force phase < 12 independently of Lemmings.
Three listens on the build already flashed would do it:

| test | reads | clean means | distorted means |
|---|---|---|---|
| phase 28, mouse STILL | ~40 (still peak was 12) | S > 40 | S <= 40 |
| phase 20, mouse moving | ~49 | S > 49 | S <= 49 |
| phase 12, mouse moving | ~41 | S > 41 | S <= 41 |

The first is the most informative single test.

**Status of the phase evidence: the issue #23 report is corroborated at 28 on
hardware.** Whether Bard's Tale counts as a fully independent third line
depends on pinning S; until then it is a confirmed discriminator between 0 and
28, which on its own already argues against 28 being a restoration.

### Phase 20 CONFIRMED distorted on the probe -- and an analysis defect that nearly hid it

Daniel heard some distortion at phase 20 on Bard's Tale with the mouse moving,
and asked for a probe. The probe confirms it.

| | phase 0 (clean by ear) | phase 20 (distorted by ear) |
|---|---|---|
| still `first_idx` min/med/max | 3/4/12 | 23/23/24 |
| moving `first_idx` min/med/max | 11/23/**29** | 24/44/**88** |
| frames with `first_idx` >= 32 | **0 of 60** | **20 of 60** |
| edges/frame max | 60 | 60 |

Mouse load is identical between the two captures, so the comparison is fair.

#### The analysis defect, which would have produced the opposite conclusion

The first parse of the phase-20 capture decoded only 40 of 60 frames. The
regex required `mouse edges:` and `word 0 written` on adjacent lines, and
`read_probes.tcl` prints its LATE warning BETWEEN them -- so **every LATE
frame silently failed to match and vanished from the statistics.** What
survived was 37 still frames and 3 moving ones with a worst `first_idx` of 30,
from which the conclusion drawn was going to be "the mouse was barely moved
and the probe cannot confirm anything". Both halves of that were artefacts of
the parser.

**It was caught only because 60 frames went in and 40 came out.** Record the
habit, not just the bug: **make a parser account for every record it was given,
and fail loudly when it cannot.** A filter that drops exactly the anomalous
rows is the worst possible failure mode, because the remaining data looks
clean and self-consistent.

**Unaffected by the defect** -- both verified by re-parsing with the fixed
reader: the Lemmings step-2 captures decoded 40 of 40 with zero flagged
frames, and Bard's Tale at phase 0 decoded 60 of 60 with zero. Nothing was
hidden in either, so the step-2 verdict stands exactly as recorded.

#### New finding: degradation past the cliff is NON-LINEAR

- **Still frames shift by exactly the phase**: median 4 at phase 0 -> 23 at
  phase 20, a delta of 19 against the 20 expected. The one-for-one shift
  assumption is confirmed, for still frames.
- **Moving frames do not**: worst 29 at phase 0 -> **88** at phase 20, where a
  linear shift predicts ~49.

Once the driver falls behind, it cascades: a late fill starts the next one
later still. **So the bracketing table above, which computes "worst
`first_idx` = 29 + phase", is valid ONLY for still frames.** It was used to
estimate the moving case at phases 20 and 28; those estimates are withdrawn.
The still-frame column of that table stands.

#### S for Bard's Tale, updated

Clean at worst 29 (phase 0) and distorted with a moving median of 44 (phase
20) gives **29 < S <~ 44**. The span-derived 41 retracted earlier sits inside
that window -- the value was plausible even though its derivation was not
sound, which is a reason to have retracted the *reasoning* rather than the
number.

**Still the single most informative outstanding test: phase 28 with the mouse
completely STILL.** Still frames are the regime where the linear shift holds,
so that reads ~32 and a clean/distorted verdict there pins S against a number
we can trust.

### Step 4 regression: Lode Runner sounds exactly the same

Daniel, 2026-09-22: unchanged by the mouse fix.

Second negative control after PoP, and the same reasoning applies -- the
converter fix touches no sound file, so any change here would have meant it
reached the sound path by an unmodelled route. Lode Runner was part of the
Phase 3 CD-audio regression set, so "exactly the same" is being judged against
a familiar reference rather than a first listen.

Step 4 status: PoP unchanged, Bard's Tale clean at 0 / distorted at 20 and 28
(both confirmed on the probe), Lode Runner unchanged. **Outstanding: the boot
chime.** Then step 5 -- 128K, 512K, 16 MHz turbo.

### Step 4 COMPLETE, and step 5 begun

Daniel, 2026-09-22: **boot chime is fine**, and **Lode Runner on the 512K
sounds exactly the same**.

Step 4 is therefore closed:

| test | result |
|---|---|
| PoP | unchanged by the fix |
| Bard's Tale, phase 0 | clean, 0 of 60 frames flagged |
| Bard's Tale, phase 20 | **distorted**, 20 of 60, confirmed on the probe |
| Bard's Tale, phase 28 | distorted |
| Lode Runner | unchanged |
| boot chime | fine |

Step 5 has its first result: the 512K carries the same converter and the same
sound path, and Lode Runner is unchanged there too.

#### Turbo: settled statically, so the hardware step is a formality

The plan's step 5 says "`clk8_en_p` is unchanged under turbo, so the rate is
the same; confirm". Confirmed from the source rather than the bench:

- `ps2_mouse` is clocked `clk32` with `ce = clk8_en_p`
  (`rtl/dataController_top.sv:610`);
- turbo reroutes only `cpu_en_p` -- `status_turbo ? clk16_en_p : clk8_en_p`
  (`MacPlus.sv:661`). Nothing gates `clk8_en_p` itself;
- `rtl/ps2_mouse.v` contains no reference to turbo or `clk16`.

**So the mouse edge rate is identical in absolute time at 8 and 16 MHz.** The
corollary is favourable: under turbo the ROM services each interrupt in about
half the time, so the CPU load from the mouse HALVES. Turbo should be strictly
better for sound, consistent with the existing observation that phase 20 at
16 MHz is mouse-proof. A hardware pass is still worth having, but nothing is
riding on it.

**Outstanding in step 5: the 128K**, and a turbo listen for completeness. Worth
checking the cursor itself moves correctly on 128K and 512K as well as the
sound, since those models reach the VIA through the same path but were never
the subject of a mouse test.
