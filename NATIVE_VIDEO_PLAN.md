# Native video: the real Plus raster and clock

Status: **planned, not started.** Written 2026-10-25, rewritten 2026-10-26 for
the PLL change. Experimental dev build.

## Goal

Make the MacPlus core's video output the same as the SE/30 core's: the
Mac's own 512x342 raster at the real 22.25 kHz / 60.15 Hz, handed to the
MiSTer scaler as is. On HDMI the SE/30 core looks clearly better; the MacPlus
core shows squares (moire) in the desktop grey.

Route: the core's main clock moves from 32.5 MHz to **31.3344 MHz, 2 x the
real Plus's 15.6672 MHz dot clock**, as the SE/30 core's does. The video, CPU,
sound and floppy timings then all land on the real values at once.

## Route to release

1. Build it privately on this branch and test on HDMI (Daniel's only display).
2. Post it on the forum as an **experimental** dev build.
3. Forum reaction decides: merge upstream, change it, or keep it private.

Nothing here goes to MiSTer-devel until step 3 says so.

## Why: what is wrong now

- The core outputs a 1024x768-class frame: 672 x 806 clocks at 32.5 MHz,
  48.36 kHz, 60.00 Hz, with every Mac line doubled (342 -> 684).
- The scaler handles the doubled 684-line input badly: fractional scaling of
  the 1-pixel grey checkerboard beats into visible squares. The core's own
  V-Integer option clears them but leaves a small picture (684 lines fit only
  1x on 1080). The SE/30 core has no scaler trouble because it sends 342
  lines.
- The display window is also 516 wide, not 512 (4 black pixels on the left).
  Fixed on branch `video-de-512` (`2d81d34`, not compiled); **superseded by
  this plan**, which rewrites the video timer.

### Where the 1024x768 frame came from

The core descends from Plus Too (Big Mess o' Wires) via the MiST. Neither had a
framebuffer scaler, so the core had to emit a mode a VGA monitor accepts; the
Plus's 22 kHz is not one. On MiSTer that constraint is gone. Three workarounds
exist only because of it: the sound scan's Bresenham (370 sound words spread
over 806 lines), `cpu_wait.v`'s virtual raster rebuilt from sound pulses, and
`cpu_wait.v`'s skipped clocks trimming 8.125 MHz to 7.8336. All three go.

## Reference: the real Plus and the SE/30 core

| | real Plus | SE/30 core | MacPlus now | MacPlus after |
|---|---|---|---|---|
| clk_sys | - | 31.3344 MHz | 32.5 MHz | **31.3344 MHz** |
| pixel clock | 15.6672 MHz | clk_sys/2 | 32.5 MHz | **clk_sys/2** |
| CPU clock | 7.8336 MHz | - | 8.125, 5,168 skips/frame | **7.8336, no skips** |
| line | 704 px | 704 | 1344-class | **704** |
| frame | 370 lines | 370 | 806 | **370** |
| visible | 512 x 342 | 512 x 342 | 516 x 684 | **512 x 342** |
| line rate | 22.2545 kHz | 22.2545 kHz | 48.36 kHz | **22.2545 kHz** |
| frame rate | 60.147 Hz | 60.147 Hz | 60.00 Hz | **60.147 Hz** |
| sound rate | 22,254.5 Hz | - | 22,200 Hz | **22,254.5 Hz** |

## Phase 0 findings (2026-10-26)

**SE/30 geometry** (`C:/Git/MacSE30_MiSTer/rtl/se30_video.v`, from its PALs):
pixel 0-511 active; HSYNC* low for 288 pixels from pixel 535 (front porch
23), wrapping 119 pixels into the next line; line 0 blank, lines 1-342
active, VSYNC* low lines 343-346; `VGA_DE = ~(hblank | vblank)`, registered;
syncs active low. `MacSE30.sv:866-891`: `CLK_VIDEO = clk_sys`,
`CE_PIXEL = phi1` (every other clk_sys); `VGA_SCALER = 0` (`:41`);
`video_freak` with ARX/ARY 256:171 and the four-way Scale item -- **the same
aspect and Scale items this core already has** (`MacPlus.sv:48-59`,
`:114-115`), so no OSD change.

**SE/30 PLL** (`C:/Git/MacSE30_MiSTer/rtl/pll/pll_0002.v`): 50 MHz in,
fractional, VCO 940.032 MHz = 31.3344 x 30. Proof that the DE10-Nano makes
the exact frequency. This core needs 31.3344 (clk_sys) and 62.6688 (clk_mem,
the SDRAM, 2 x clk_sys as now): VCO / 30 and / 15.

**Why not keep 32.5 MHz.** The line must be a multiple of 4 clk8 (video owns
RAM only on `busCycle == 0`; `videoTimer` keeps `xpos` in step with
`busCycle` only because the line divides by 4). At 32.5 MHz the candidates
were 728 px (60.33 Hz, +0.30%) and 736 px (59.67 Hz, -0.79%); the plan's
original 732 (366 clk8) would have missed every other line's video slot.
At 31.3344 MHz the real 704 px = 352 clk8 divides by 4 (and 16).

**Other raster consumers:** VIA CA1 (VBL, `_vblank` falling,
`dataController_top.sv:378`), VIA PB6 (`_hblank`, Plus only, `:349`), the VBL
counter at `dataController_top.sv:306` (replaced in Phase 2 by a clk_sys
second), `snd_phase_probe.sv` (VBL edge),
`cpu_wait.v` (VBL edge + `snd_advance`). All take edges, not counts, so they
follow the new raster. `floppy.v:530`'s "every hsync" comment is stale (it
uses `cpu_tick`).

## Phase 0b findings: the Plus's own raster (2026-10-26)

Sources in `C:/temp/Mac/PALs/`: Jecel Assumpcao's Unitron notes
(`apple_mac_logic.htm`, the 128K PAL tables), Bomarc M0001A sheet 4
(`MacPlus-M0001A-MB-4-4.png`), Wouter's Plus LAG dump (`pals.txt`), and the
"RESULT 2026-09-21" decode in `SOUND_PHASE_PLAN.md` on `sound-phase`.

**Settled:**

| | value | source |
|---|---|---|
| line | 44 words of 16 px = 704 px | Jecel: "32 ciclos ativas ... 11 ciclos de retraco ... 1 ciclo de som/pwm" |
| active | words 0-31 (px 0-511) | Jecel: VA6..VA1 = 0 to $1F |
| retrace | words 32-42 (11 words) | Jecel: $20 to $2A |
| sound / disk-PWM fetch | **word 43, the last of every line** | Jecel: $2B; Hertzfeld via Wouter: "every 44 microseconds" in the blanking interval |
| horizontal blank | words 32-43, 192 px | the two rows above |
| frame | 370 lines: **28 blank first, then 342 active** | Jecel's line counter: retrace 128-155, active 156-497; checked against $1FFD00 / $1A700 in the sound-phase decode |
| VBL | at the frame reset, the start of the 28 blank lines; the sound scan is at word 0 there | sound-phase decode: VIA CA1 = LAG pin 13 = VSYNC, asserted on the term that resets the line counter; ROM sets CA1 to the falling edge |
| sound word n | fetched at the end of line n | the line counter IS the sound address |

This is exactly the raster `cpu_wait.v` already models (lines 0-27 blank,
display = the first 256 CPU clocks, the sound slot the last 8), so the
contention model needs no new numbers.

**Not settled: HSYNC position and width, VSYNC width.** The LAG's VC0/VC1
inputs (pins 2, 3) do not come from the video counters: on sheet 4 they run
toward BMU2 (E2, 20R4 342-0518), whose equations exist only behind the
pldarchive bot check. A simulation of the LAG's horizontal equations alone
(a throwaway script, not kept) does not close to a 44-word line, so it cannot be
trusted for the sync widths. The sound-phase note's "HSYNC of seven memory
cycles" was a polarity sanity check, not a simulation, and is not adopted.
Only the start of VSYNC is settled (the VBL). Jecel's 128K reconstruction
holds VSYNC through the 28-line window (`/VSYNC := RESLIN + /VSYNC*/L28`),
but that is a reconstruction of the 128K, not a Plus dump.

**Decision for the build:** where the Plus is settled, use the Plus; for the
two open widths use the SE/30's PAL-derived values, which are a real compact
Mac's timing on the same 704 x 370 raster:
- HSYNC* low 288 px from pixel 535 (front porch 23), wrapping to pixel 119
  of the next line;
- VSYNC* low 4 lines from the VBL (the SE/30 also starts VSYNC on the line
  after the last active one, the same place as the Plus's VBL).
The internal CRT never saw these signals leave the case; only direct-analog
users see the widths, and the forum build asks them anyway.

## Design

### Clock

`rtl/pll` regenerated: outclk_0 (clk_mem) 62.6688 MHz, outclk_1 (clk_sys)
31.3344 MHz, fractional mode. clk8 = clk_sys/4 = **7.8336 MHz**, the real
Plus CPU clock.

### Video

- `videoTimer.v` rewritten: xpos 0-351 in clk8 (2 pixels per clk8), ypos
  0-369, no line doubling.
- One 16-pixel word every 8 clk8, on `busCycle == 0` with `xpos[2] == 0`:
  32 words in clk8 0-255, every other video slot, as on the real Plus.
- Horizontal: words 0-31 active, 32-42 retrace, 43 the sound fetch.
  Vertical: lines 0-27 blank (VBL at the start of line 0), 28-369 active.
- Syncs (Phase 0b): HSYNC* low pixels 535 to 118 of the next line; VSYNC*
  low lines 0-3.
- `_hblank` is the real 192-pixel blank (VIA PB6). `_vblank` falls at the
  start of vertical blank (VBL, VIA CA1).
- `VGA_DE` exactly 512 x 342, registered, as the SE/30.
- `videoShifter.v` shifts on the pixel CE (every other clk_sys), not every
  clock.
- `MacPlus.sv`: `CE_PIXEL` = the pixel CE; `VGA_SCALER` stays 0; aspect and
  Scale items unchanged.
- Screen address: base + row x 64 + word x 2, row 0-341 straight from ypos.

### Sound

The sound scan becomes one word per line, at the end of the line (the
real ASG's slot), as on the real machine. The 135,408-clk8 Bresenham goes.
`snd_advance` keeps its meaning: one pulse per word (`cpu_wait` and the
sound commit in `dataController_top.sv:209` use it). `snd_phase` keeps its
meaning (start word at the VBL edge), so the PoP / Lemmings / Bard's Tale
findings carry over in words.

### CPU timing (`cpu_wait.v`)

- The skip Bresenham goes: clk8 is the real CPU clock. `cpu_skip` stays as
  a port tied 0, or is removed with its users (decide in Phase 5).
- The virtual raster is driven by the real video counter (one line = 352
  clk8, display = clk8 0-255 of an active line, sound slot = the last 8)
  instead of being rebuilt from `snd_advance`.
- The wait-state rules (the TSM PAL grid, the display slot) stay as they are.

### Everything else that assumes 32.5 MHz

| Where | What | Change |
|---|---|---|
| `MacPlus.sv:386-387` | 48 kHz audio strobe, divisor 677 | 653 (47,985 Hz, -0.03%) |
| `rtl/cd_audio.sv:29`, `rtl/scsi.v:1686` | `CLK_HZ` 32,500,000, the 44.1 kHz cadence | 31,334,400 |
| `rtl/cd_audio.sv:1277` (+ `:1263` comment) | `frac16` step 89 = 65536 x 44100 / clk | 92 |
| `rtl/scc.v:911` | the one live divisor, 282 (fixed 115,200 baud; the table above it is commented out) | **272, exact** |
| `dataController_top.sv:301` | VIA CA2 one-second tick = 60 VBLs | at 60.147 Hz that gains ~3.6 min/day; count 31,334,400 clk_sys instead (a real Plus RTC has its own crystal) |
| `rtl/rtc.v:67` | the RTC's own seconds: 32,499,999 clk | **31,334,399** (found by the Phase 2 re-search) |
| `rtl/scsi.v:1360-1379` | power-of-two spin-up / watchdog counts | 3.6% longer in time; leave |
| `rtl/adb.sv:23` | TALKINTERVAL 11 ms in clk8 | 3.6% longer; leave |
| `rtl/ps2_mouse.v` | fine tick and rate ceiling in clk8 | gain is the divisor, not time; max rate and drain 3.6% slower; leave |
| `dataController_top.sv:418` | keyboard clock 1300 / 80 clk8 | 3.6% longer; leave |
| `MacPlus.sv:1190` | disk LED hold 500,000 clk | cosmetic; leave |
| `sim/tb_adb_idle.v`, `tb_adb_mouse_div.v`, `tb_ps2_mouse.v` | 32.5 MHz clock, `CE_MS` 8125, 16 ms = 130,000 ce | 31.3344 MHz, 7834, 125,338 |
| `dataController_top.sv:218` | 100 ms reset in clk8 | leave |
| `rtl/sdram.v` | refresh on idle slots, clocked by clk_mem | leave; video now takes half the slots it did, so more idle slots |
| `addrController_top.v:6`, `dataController_top.sv:3`, `cpu_wait.v` header | comments naming 8.125 / 32.5 MHz | update |

Phase 2 repeats the search (`32.5`, `8.125`, `16.25`, `65`, `48000`, `44100`,
baud tables, `_us`/`ms` constants) before calling this list complete.

### Floppy

**Phase 2 finding: the floppy does not move.** `floppy.v` (header at :62-72)
already counts its byte timers and the tach in CPU clocks (`cpu_tick`, clk8
less the skips), because the IWM's FCLK is the CPU's C8M. After the change
every clk8 is a CPU clock, so the tach periods and byte times are the same
number of CPU clocks as today and the ROM reads the same values. The
planned Phase 6 tach check is not needed. `dcd_link.v:260-265`'s 128-clk8
byte becomes the real 2.042 us cell (its comment says why it was 2.000).
The 400K spindle duty table, the DCD poll budget and formatting are still
re-tested on hardware (Daniel: fine), since the SDRAM/HPS side runs 3.6%
slower in wall time.

### Accepted costs (Daniel 2026-10-26)

- Turbo, 68010 and 68020 run 3.6% slower (the 16 MHz setting becomes 15.67).
- The floppy fixes need hardware re-testing.

### Decisions already made (Daniel)

- **Match the SE/30 exactly. No VGA option.** Direct-VGA users set
  `vga_scaler=1` in `MiSTer.ini` (`[MacPlus]` section); add an option later
  only if forum testers ask.
- **No dual timing** (old 48 kHz and native side by side).
- Turbo, 68010/68020 and the other extras keep working, just from the new
  clock.

### Rejected alternatives

- **Keep 32.5 MHz, 728 x 370** (60.33 Hz, 12 skips/line). Workable, but every
  rate stays a little off and the skip Bresenham stays.
- **DE on even lines only** with today's timing (`ascal.vhd` and
  `video_freak.sv` count lines by DE falling edges). Fails direct analog
  output: `sys_top.v` blanks RGB with the same DE, so every other line would
  be black.

## Phases

0. **Done:** SE/30 video path and PLL read; findings above.
   **0b. Done:** the Plus's raster, above; sync widths from the SE/30.
1. **Failing bench** `sim/tb_video_native.v`: 704 x 370 at clk8 = clk_sys/4,
   DE exactly 512 x 342, column-tagged words checked for width and position
   (as `tb_video_de` on `video-de-512`), sync positions, VBL edge, 32 fetches
   per active line on video slots only. Fails against the current timer.
2. **Done:** `rtl/pll` retargeted by hand (the two output frequencies in
   `pll_0002.v`, the wizard metadata in `pll.v`; fractional mode was
   already on, VCO 940.032 MHz as the SE/30's); every row of the constants
   table; the re-search found `rtc.v`. Three clocked benches moved to
   31.3344 MHz and rerun.
3. **Done:** `videoTimer.v` + `videoShifter.v` + `MacPlus.sv`; `tb_video_native`
   green (and green with `-DMISALIGN`, which powers the timer up out of step
   with busCycle); today's timer still fails it. The timer powers up at pixel
   702 of line 369, in step with busCycle from the first clock. Video's RAM
   output enable now follows the fetch (every other video slot), so the idle
   video slots go to SDRAM refresh. Two bench fixes on the way: the VBL check
   compared against the wrong frame's edge, and power-up levels counted as
   edges.
4. **Done:** sound scan one word per line, the Bresenham gone. The scan
   advances where `_hblank` rises (each line start) and restarts on the VBL
   edge (line 0's start, same clk8, VBL wins), so a frame is exactly 370
   commits 352 clk8 apart. The real fetch is word 43, 16 px later; the commit
   point only times the output sample, so that is inaudible, and keeping the
   VBL edge as the restart keeps every sound-phase measurement's meaning.
   `tb_snd_phase` updated (advances detected on the line edge, a new 352-clk8
   spacing check, the old timer's forces removed): 57/57.
5. **Done:** `cpu_wait.v`'s clock trim removed; `cpu_skip` kept as a port
   tied 0 (the CPU enables and the floppy's `cpu_tick` take it, unchanged).
   The raster stays on `snd_advance`: since Phase 4 that pulses at every
   line start, so it IS the video raster and reading the video counter
   instead would change nothing. `tb_cpu_wait` updated (352-clk8 lines, exact
   352; a frame of 130,240 clk8 is 130,240 CPU clocks): all wait-state loop
   periods unchanged, PASS 11,973 bus cycles.
6. ~~Floppy tach check; RTC second from clk_sys.~~ Both settled in Phase 2.
7. Bench sweep (**ask first**), then the gated compile (**ask first**). Check
   the PLL output frequencies and timing in the reports. Mind the SE/30
   session's builds: no Quartus compile near 22:00 without checking.
8. **HDMI hardware test** (Daniel):
   - desktop grey: no squares, at default scaling and V-Integer; the info
     OSD reads 512x342, ~22.25 kHz, ~60.15 Hz;
   - Speedometer 6.0.8, Plus and SE: within 1% of today (Plus 0.880 / 0.930
     / 0.994; SE 1.000 / 0.987 / 0.978); turbo about 3.6% slower;
   - sound: PoP, Lode Runner, Bard's Tale, boot chime; CD audio pitch;
   - floppy: 400K and 800K boot, format/write/read; HD20; mouse;
   - Mac clock against a watch over an hour;
   - serial, if anything to test it with.
9. **Forum experimental build** with the questions below.
10. Decide: merge upstream, change, or keep private.

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
- **Turbo is slightly slower:** the core's clock is now the real Plus's.

## Open questions

- The sound-phase selector still exists on the dev branch: keep it as an
  instrument here or drop it, as PR #25 did.
- `cpu_skip`: tie it off or remove it and its users (Phase 5).
- The OSD's slightly wandering kHz reading seen on today's build is believed
  to be Main's measurement; recheck on the new build.
