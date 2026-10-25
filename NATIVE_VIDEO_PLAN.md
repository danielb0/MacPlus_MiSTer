# Native video: SE/30-style output for the MacPlus core

Status: **planned, not started** (written 2026-10-25). Experimental.

## Goal

Make the MacPlus core's video output the same as the SE/30 core's: the
Mac's own 512x342 raster at about 22 kHz, handed to the MiSTer scaler as is.
On HDMI the SE/30 core looks clearly better; the MacPlus core shows squares
(moire) in the desktop grey.

## Route

1. Build it privately on a dev branch and test on HDMI (Daniel's only display).
2. Post it on the forum as an **experimental** dev build.
3. Forum reaction decides: merge upstream, change it, or keep it private.

Nothing here goes to MiSTer-devel until step 3 says so.

## Why: what is wrong now

- The core outputs a 1024x768-class frame: 672 x 806 clocks at 32.5 MHz,
  48.36 kHz, 60.00 Hz, with every Mac line doubled (342 -> 684).
- The scaler handles the doubled 684-line input badly: fractional scaling of
  the 1-pixel grey checkerboard beats into visible squares. The core's own
  V-Integer option clears them but leaves a small picture (684 lines fit only
  1x on 1080). The SE/30 core has no scaler options and is clean at default
  because it sends 342 lines.
- The display window was also 516 wide, not 512 (4 black pixels on the left).
  Fixed on branch `video-de-512` (`2d81d34`, not compiled); **superseded by
  this plan**, which rewrites the video timer.

### Where the 1024x768 frame came from

The core descends from Plus Too (Big Mess o' Wires) via the MiST. Neither had a
framebuffer scaler, so the core had to emit a mode a VGA monitor accepts; the
Plus's 22 kHz is not one. On MiSTer that constraint is gone. Two workarounds
exist only because of it: the sound scan's Bresenham (370 sound words spread
over 806 lines) and `cpu_wait.v`'s virtual raster rebuilt from sound pulses.

## Reference: the real Plus and the SE/30 core

| | real Plus | SE/30 core | MacPlus now |
|---|---|---|---|
| pixel clock | 15.6672 MHz | C16M (CE on phi1) | 32.5 MHz, 1 px/clk |
| line | 704 px | 704 (H_TOTAL) | 1344-class |
| frame | 370 lines | 370 (V_TOTAL) | 806 |
| visible | 512 x 342 | 512 x 342 | 516 x 684 |
| line rate | 22.2545 kHz | ~22.25 kHz | 48.36 kHz |
| frame rate | 60.147 Hz | ~60.15 Hz | 60.00 Hz |

SE/30 source: `C:/Git/MacSE30_MiSTer/rtl/se30_video.v` (H_TOTAL 704,
H_ACTIVE 512, HSYNC_START 535, 288 px sync wrapping, V_TOTAL 370, VSYNC
343-347), `MacSE30.sv` ~867 (`CLK_VIDEO`, `CE_PIXEL = phi1`,
`VGA_DE = ~(hblank|vblank)`), `VGA_SCALER = 0` at :41. **Phase 0 reads these
in full before anything is designed.**

## Proposed design

**732 x 370 at 16.25 MHz** (clk_sys/2, CE_PIXEL every other clock), 512 x 342
visible.

- Line rate 16.25 MHz / 732 = **22.20 kHz**; frame 16.25 MHz / 270,840 =
  **59.999 Hz**.
- 732 pixels = **366 clk8 per line**, exactly the line `cpu_wait.v` already
  models ("352 CPU clocks ~ 366 clk8"). Frame = 135,420 clk8; the real Plus's
  130,240 CPU clocks per frame need 5,180 skips = **exactly 14 per line**.
- Why not 704 like the SE/30: at 16.25 MHz, 704 x 370 gives 62.4 Hz. 732 keeps
  60 Hz and the CPU calibration. The SE/30 core gets the real 15.6672 MHz from
  its own PLL; this core's CPU clock and every hardware-confirmed timing hang
  off 32.5 MHz, so changing the PLL is out of scope.
- The extra 28 pixels go into horizontal blanking (which porch: Phase 0).

### What changes

1. `rtl/videoTimer.v`: rewritten. 732 x 370 counter, no line doubling, one
   16-pixel word every 8 clk8 (every other video slot, as on the real Plus),
   DE exactly 512 x 342, real-Plus hblank to VIA PB6 and VBL to CA1.
2. `rtl/addrController_top.v`: the sound scan becomes one word per line, as
   on the real machine; the 135,408-clk8 Bresenham goes. `snd_advance` keeps
   its meaning (`cpu_wait` and the sound commit use it).
3. `rtl/cpu_wait.v`: FRAME_CLK8 135,408 -> 135,420, SKIPS 5,168 -> 5,180;
   optionally drive its raster from the real line counter.
4. `MacPlus.sv`: `CE_PIXEL`, `VGA_DE`, sync wiring. `VGA_SCALER` stays 0.
5. `rtl/videoShifter.v`: shift on the pixel CE, not every clock.
6. Benches: new `tb_video_native` (geometry, rates, column-tagged pixel check
   as in `tb_video_de`); `tb_snd_phase` and `tb_cpu_wait` updated.

The coupling search (2026-10-20) found nothing else: `floppy.v:530`'s "every
hsync" comment is stale (it uses `cpu_tick`).

### Decisions already made (Daniel)

- **Match the SE/30 exactly. No VGA option.** The SE/30 manages without one.
  Direct-VGA users set `vga_scaler=1` in `MiSTer.ini` (`[MacPlus]` section);
  add an option later only if forum testers ask.
- **No dual timing** (old 48 kHz and native side by side). It would keep the
  Bresenham, need two sets of `cpu_wait` constants and double every hardware
  check.
- Turbo, 68010/68020 and the other extras stay untouched.

### Rejected alternative

DE on even lines only would present 512 x 342 to the scaler with no timing
change (`ascal.vhd` and `video_freak.sv` count lines by DE falling edges). It
fails direct analog output: `sys_top.v` blanks RGB with the same DE, so every
other line would be black.

## Phases

0. **Read the SE/30 video path** and record its exact sync, porch and DE
   choices; pick the 28-pixel placement.
1. **Failing bench** `tb_video_native` against the current timer.
2. `videoTimer.v` + `videoShifter.v` + `MacPlus.sv`; bench green.
3. Sound scan one word per line; `tb_snd_phase` green.
4. `cpu_wait.v` constants (and raster source); `tb_cpu_wait` green.
5. Bench sweep (ask first), then gated compile.
6. **HDMI hardware test** (Daniel):
   - desktop grey: no squares, at default scaling and V-Integer;
   - Speedometer 6.0.8 Plus and SE: must stay within 1% of today
     (Plus 0.880 / 0.930 / 0.994; SE 1.000 / 0.987 / 0.978);
   - sound: PoP, Lode Runner, Bard's Tale, boot chime;
   - floppy format/write/read, HD20, mouse;
   - the MiSTer info OSD should read 512x342.
7. **Forum experimental build** with the questions below.
8. Decide: merge upstream, change, or keep private.

## Forum: what to ask

Daniel has only HDMI; VGA and CRT results must come from testers. Ask each
tester for:

- display type and **connection**: HDMI, CRT via the scaler, or direct analog
  (VGA port without scaler, or `direct_video`);
- does it sync; how does it look compared with the current build;
- direct-analog testers: also try `vga_scaler=1`.

Expected: HDMI and scaler-fed CRTs fine or better. Direct analog gets raw
22 kHz: most VGA monitors need 31 kHz or more and 15 kHz sets top out near
16 kHz, so only multisync monitors covering 22 kHz will sync; the rest need
`vga_scaler=1`. "Nobody complained about the SE/30 on CRTs" is weak evidence:
it has a small user base.

## Known answers for testers

- **15 kHz monitors:** not natively (no compact Mac ever output 15 kHz), but
  yes through the MiSTer scaler: `vga_scaler=1` and a 15 kHz `video_mode`.
  342 lines onto a ~240-line TV means scaling or interlace, so fine dither and
  small text may suffer; inherent, not a core defect. Same as today: the
  current 48 kHz output is not usable on a 15 kHz set either.
- **VGA monitor shows nothing:** `vga_scaler=1` in `MiSTer.ini`.

## Open questions

- Which porch takes the extra 28 pixels; sync polarity and width vs the SE/30.
- Does `cpu_wait` keep deriving its raster from `snd_advance`, or read the
  video line counter directly (simpler once they are the same line)?
- The sound-phase selector still exists on the dev branch: keep it as an
  instrument here or drop it, as PR #25 did.
- The OSD's slightly wandering kHz reading (48.38 shown vs 48.363 computed) is
  believed to be Main's measurement; recheck on the new build.
