# Plan: add Macintosh 128K / 512K / 512Ke models to the core

Written 2026-09-03. Branch `mac128k`, cut from `scsi-upgrade` at `2d7025f`.

Base is `scsi-upgrade`, not `master`: master carries the upstream squash
(`51cf977`) with `sim/`, `scripts/` and the plan docs stripped, and this work
needs the test benches.

## Scope: settled, and why

This is a **fork-only** feature. We do not have to distribute it, so upstream's
appetite is not a design constraint and no forum sounding is needed first.

An earlier draft of this analysis raised "scope creep for a repo named MacPlus"
as a counterweight. **That objection is withdrawn.** The precedent is the user's
own UK101 core, which carries OSI machines including disk support the UK101
never had. A core name is a lineage marker, not a contract.

Positively: the 128K, 512K and 512Ke are **real machines**. The core already
offers 68010, 68020 and 16 MHz, which are fantasy configurations - no such
Macintosh existed. Adding authentic models sits *better* with the project's
stated scoping principle than what already ships.

## What is already in the core

All of this is inherited from the `plus_too` lineage and is live code, not
commented-out groundwork.

| piece | where | status |
|---|---|---|
| `configRAMSize` = 128K / 512K / 1MB / 4MB | `rtl/addrController_top.v:13` | all four **implemented**, only two reachable |
| RAM address forcing for 128K and 512K | `addrController_top.v:202,206,209` | implemented |
| `configROMSize` = 64K / 128K / 256K / 512K | `addrController_top.v:12` | all four **implemented**, only two reachable |
| ROM address forcing for a 64K image | `addrController_top.v:200,204,207` | implemented, incl. the $20000 placement |
| Model selector + reset-time latching | `MacPlus.sv:89`, `MacPlus.sv:119-137` | exists as a **1-bit** Plus/SE choice |
| 512K ROM-image repeat behaviour | `addrDecoder.v:111-114` | documented in a comment; decode is Plus-shaped |
| 400K single-sided floppy images | `MacPlus.sv:965-1013`, `rtl/floppy.v:56` | working, with a per-mount `DRIVE_REG_SIDES` bit |

Two of these deserve quoting, because they change the size of the job.

**The 64K ROM decode is already written**, including the awkward part -
`addrController_top.v:200-205`:

```verilog
assign macAddr[16] = rom_access && configROMSize == 2'b00 ? 1'b0 :  // force A16 to 0 for 64K ROM access
                     addrMux[16];
assign macAddr[17] = ram_access && configRAMSize == 2'b00 ? 1'b0 :  // force A17 to 0 for 128K RAM access
                     rom_access && configROMSize == 2'b01 ? 1'b0 :  // force A17 to 0 for 128K ROM access
                     rom_access && configROMSize == 2'b00 ? 1'b1 :  // force A17 to 1 for 64K ROM access (64K ROM image is at $20000)
                     addrMux[17];
```

**The RAM sizes are unreachable only because of one line**, `MacPlus.sv:338`:

```verilog
wire [1:0] configRAMSize = status_mem?2'b11:2'b10; // 1MB/4MB
```

## Two corrections to the 2026-08-28 assessment

Recorded because both were stated confidently and both were wrong in ways that
change the plan.

**1. "The 64K ROM is the only substantial new piece."** The ROM *decode* for a
64K image is already implemented, as quoted above. What is missing is ROM
*delivery* - getting a third image into SDRAM and selecting it - which is a
different and smaller problem in the decoder but a real one in the loader (see
"The crux" below).

**2. "Gating SCSI off runs straight into `addrDecoder.v:119`, and that is the
real cost."** It does not. The line is:

```verilog
4'b0100: begin //40 0000 - 4F FFFF
    if(configROMSize[1] || address[17] == 1'b0)   // <- this detects SCSI (on Plus)!!!
        selectROM = !_cpuAS;
```

For a 128K/512K, `configROMSize == 2'b00`, so `configROMSize[1]` is **0** - the
same branch the Plus takes. The new models inherit Plus behaviour here for free.
The line distinguishes the **SE** from everything older; it is not a Plus-vs-128K
seam, and adding these models does not force us to resolve it.

`SCSI_UPGRADE_PLAN.md:3682-3693` records the mechanism as not understood. That
stays open, and this plan does not close it. It is simply not on the path.

## The crux: ROM delivery is single-bit everywhere

This is the one genuinely new piece of design, and it is worth stating precisely
before any code is written.

ROM reads are routed to SDRAM at `MacPlus.sv:1042`:

```verilog
~_romOE ? {4'b0001, 2'b00, status_mod, memoryAddr[18:1]} :
```

and ROM downloads are placed at `MacPlus.sv:1018`:

```verilog
dio_a <= {dio_index[6], dio_addr[17:0]};
```

So the core reserves **two** 512KB ROM slots, selected at download time by
`ioctl_index` bit 6 and at read time by `status_mod` - the single Plus/SE bit.
That matches what ships: `releases/boot0.rom` is 131072 bytes (the Plus 128K
ROM) and `releases/boot1.rom` is 262144 bytes (the SE 256K ROM). A third model
needs a third slot, or a scheme that reuses one.

Two candidate approaches, to be decided in Phase 2 rather than now:

- **Widen the selector.** `status_mod` becomes 2 bits, the read-side window
  index becomes 2 bits, and the download side uses `dio_index[7:6]` instead of
  `dio_index[6]`, giving four slots and a `boot2.rom`. Costs 512KB more
  reserved SDRAM. Cleanest, and symmetrical with both the existing design and
  the framework's `bootN.rom` convention. **Confirm the exact index encoding in
  Main_MiSTer before relying on it** - the index is set HPS-side
  (`sys/hps_io.sv:665` merely latches it), and the two-file/bit-6 evidence is
  consistent with `index = N<<6` but does not prove it.
- **Share the Plus slot.** The 64K image is addressed at $20000 within its
  512KB slot, and the Plus 128K image occupies $00000-$1FFFF - so they do not
  overlap and could share one slot, loaded from one combined file. Costs no
  SDRAM but couples two unrelated images into one download.

Which to choose depends partly on whether the family needs one 64K image or two
(see "The ROM images exist" below). Widening is the safer default: it costs only
reserved SDRAM and does not care about the answer.

Note also that `MacPlus.sv:336` declares `localparam configROMSize = 1'b1;` and
**never references it** - line 620 passes a literal concat instead. Dead code;
delete it while in the area, before it misleads someone.

## The ROM images exist

`C:\temp\Mac\ROMS` (local, not in the repo, not distributed):

| model | file | size |
|---|---|---|
| Macintosh 128K | `64KB ROMs/1984-01 - 28BA61CE - Macintosh 128.ROM` | 65536 |
| Macintosh 512K | `64KB ROMs/1984-10 - 28BA4E50 - Macintosh 512K.ROM` | 65536 |
| Mac Plus v1/v2/v3 | `128KB ROMs/1986-0* - 4D1E*/4D1F8172 - MacPlus v*.ROM` | 131072 |

`4D1F8172` (Plus v3) is the image already in `releases/boot0.rom`, per
`CD_BLOCK_SIZE_PLAN.md`.

**Open, and it sizes the ROM-slot work:** are those two 64K images
machine-specific, or simply successive revisions that both run on both machines?
Their dates (1984-01, 1984-10) match the 128K and 512K launches, and each is
what shipped with its machine -- but the 64K ROM is not RAM-size-dependent, so
either may well run on either. If one image suffices, one extra slot does too.
Confirm before choosing a delivery scheme.

The 512Ke needs no new image: it shipped the **same 128K ROM as the Plus**,
which is consistent with every 128K image in the folder being Plus-labelled.

## Historical accuracy is the point, so: what actually differed

Stated as a requirement, not a nicety. "Functional but inauthentic" is not an
acceptable end state for these models; if a difference is modellable, model it.

**512Ke vs Plus.** The 512Ke is a 512K raised to Plus-era storage, not a Plus cut
down -- the "e" is exactly the 800K drive plus the 128K (HFS) ROM.

| | 512Ke | Plus | modellable? |
|---|---|---|---|
| CPU | 68000 @ 7.8336 MHz | same | n/a |
| ROM | 128K | same 128K | n/a |
| Drive | 800K double-sided | same | n/a |
| RAM | 512K, soldered, not expandable | 1MB SIMMs, to 4MB | **yes** - size only |
| SCSI | **none** | yes | **yes, but see below** |
| Serial | DE-9 | mini-DIN-8 | no - same SCC behind it, connector shape only |
| Keyboard | pre-ADB jack, no keypad | same jack, keypad keyboard | no consequence in RTL |

**128K / 512K vs Plus.** Additionally: the 64K ROM (MFS, no HFS), a physically
single-sided 400K drive, and no SCSI -- but see the next section for why that
last one is free here and not on the 512Ke.

Differences that are physical rather than logical -- connector shape, socketed
vs soldered RAM -- have no RTL consequence and are out of scope by nature, not
by choice.

## The core has no bus error, and that is what "no SCSI" needs

Found while checking this plan's assumptions, and it moves item 5 off the
"small" list. `MacPlus.sv:489`:

```verilog
assign _cpuDTACK = ~(!_cpuAS && cpuAddr[23:21] != 3'b111) | (status_turbo & !turbo_dtack_en) | scsi_bus_hold;
```

with `BERRn` tied to `1'b1` (`MacPlus.sv:548`) and `berr` to `1'b0`
(`MacPlus.sv:600`). **The core DTACKs every address below `$E00000`**, mapped or
not, and never asserts a bus error.

On real hardware, "this machine has no SCSI" is discovered *by* the bus error a
probe of the absent chip produces. Deasserting `selectSCSI` does not reproduce
that: the access still completes and returns stale bus data. So gating the
decoder is **not sufficient** to make a machine look SCSI-less, and may hang the
ROM rather than satisfy it. An authentic SCSI-less model needs a synthetic bus
error for the unmapped window.

**Which models this actually blocks:**

- **512Ke -- blocked.** It runs the Plus's 128K ROM, which contains the SCSI
  Manager and does probe. That the very same ROM shipped in both a SCSI and a
  SCSI-less machine is itself good evidence that a bus error is the detection
  mechanism, and that the ROM handles its absence gracefully once it gets one.
- **128K / 512K -- free.** The 64K ROM has no SCSI Manager at all; no Mac had
  SCSI in 1984, so these machines never look. Decoder gating alone is authentic
  for them, and the bus error is wanted only for third-party software that
  probes.

This is also the one place the unexplained `addrDecoder.v:119` comment
(`// <- this detects SCSI (on Plus)!!!`) may finally have to be understood --
not because the new models trip over it, but because it is the only recorded
clue to how detection works.

## What is missing, in full

| # | item | file | size |
|---|---|---|---|
| 1 | ROM delivery for a third (and fourth) image | `MacPlus.sv:1018,1042` | design decision, then small |
| 2 | Model selector 1 bit -> 2 bits, and `configROMSize` driven from it | `MacPlus.sv:89,134,620` | small |
| 3 | `configRAMSize` reachable for 128K/512K | `MacPlus.sv:338` | trivial |
| 4 | Couple RAM options to model (a 128K cannot have 4MB) | `MacPlus.sv:89,338` | small, mostly OSD |
| 5 | Gate SCSI off for non-Plus models | `MacPlus.sv:632,694,1098` | small; accuracy only - the 64K ROM never looks, so it is not needed for booting |
| 6 | Delete the dead `configROMSize` localparam | `MacPlus.sv:336` | trivial |
| 7 | **Synthetic bus error for the unmapped SCSI window** | `MacPlus.sv:489,548,600` | **real work** - blocks an authentic 512Ke |
| 8 | Refuse 800K images in 128K/512K mode | `MacPlus.sv:965-1013` | small - a 400K-only drive cannot take one |

## System 1.x will not boot with a SCSI disk mounted

Observed 2026-09-03 (Daniel): the Plus core boots Finder 1.1g from a 400K disk,
but **not** if a SCSI hard disk is mounted. Recorded here because it changes
item 5's priority, and because it should be confirmed rather than assumed.

**The likely mechanism, and it is authentic.** Finder 1.1g is May 1984. It
predates HFS (September 1985, with the HD20) and SCSI (January 1986) alike, and
is MFS-only. But the Plus's 128K ROM *has* HFS and mounts an HFS volume itself
at boot, before the Finder is involved -- so a 1984 Finder is handed a volume
type it has no concept of. No bug is needed to explain the failure. (A second
candidate: the ROM also loads and installs the driver from the disk's driver
descriptor map, which is 1986+ code. Less likely to be the operative one.)

**What must be ruled out.** "Boots fine without the device, hangs with it" is
exactly the fingerprint of the CD-at-boot wedge, which also looked like period
behaviour and was not -- three theories died before `40f2e1c1`. Discriminate
with the cheap test from `macplus-macpaint-relaunch-system-error`: sample
`PACT` twice. Advancing (millions of cycles) means the CPU is running, so a
software crash or spin -- authentic. Frozen means the CPU is stalled mid-access,
so a bus wedge -- ours. The visible symptom sorts it too: a bomb box or Sad Mac
is software; a silent hang with no disk activity is a wedge.

**Why it does NOT matter to the 64K models** -- correcting a claim made in this
plan and withdrawn the same day. It was argued that this makes gating SCSI off
**usable** rather than merely accurate, on the grounds that a 128K running
System 1.x would hit it on every boot. That contradicts this plan's own stated
assumption. If the 64K ROM has no SCSI Manager, it never scans the bus, never
loads a driver from the disk's driver descriptor map, and never mounts the
volume -- so the Finder is never handed anything to choke on. The mount is the
ROM's doing, not the System's. A 128K should boot System 1.x cleanly with our
SCSI hardware still present.

Item 5 therefore stands on **accuracy** grounds only, and moves to Phase 4 -- it
is built once, with the mechanism, and then extended to `configROMSize == 2'b00`
as one more term in the condition (Daniel, 2026-09-03).

That is not merely tidier sequencing. **Gating SCSI off in Phase 3 would destroy
the falsification test.** Leaving it enabled on the 64K models is exactly what
proves the no-SCSI-Manager assumption: if a 128K boots System 1.x with an HFS
SCSI disk mounted, the assumption is confirmed by observation. Gate it early and
there is nothing left to observe -- the behaviour would be asserted rather than
tested.

The self-consistency argument survives in a stronger form: a real 128K was safe
from this not merely because it lacked SCSI hardware, but because its ROM would
not have touched a SCSI disk even if one had been attached.

This also gives the Phase 2 falsification test a second job. Booting the 64K ROM
with SCSI still enabled now tests the no-SCSI-Manager assumption *and* predicts
a clean boot with an HFS disk mounted. One test, both confirmations -- and if it
fails, both claims fall together.

## Open questions

These are genuinely open. None is a blocker for Phase 1.

- **Does a 64K ROM boot usefully at all?** It predates HFS, so a 128K is MFS and
  System 1.x/2.x. Expect a curiosity to boot, not a machine to use. Worth
  saying out loud before Phase 3, because it caps the value of Phases 2-4.
- **The single-sided *drive*.** `DRIVE_REG_SIDES` is per-mounted-image, which is
  correct Plus behaviour. A real 128K has a physically single-sided drive that
  reports single-sided even with no disk. Probably harmless; unverified.
- **`selectSEOverlay`** is asserted in the `$40 0000` and `$50 0000` cases
  regardless of model. Not obviously wrong for the new models, not checked.
- **A boot disk.** The rig's images (`macplus-test-rig-images`) are HFS. A 64K
  ROM needs an MFS 400K image; none is on the rig today.

## Phases

Ordered so that the **first complete, authentic machine lands without touching
the one open-ended item**, and each phase is independently testable.

The 128K and 512K go first, and the 512Ke last. That is the opposite of this
plan's first draft, and Daniel's call (2026-09-03). The reasoning: the 512Ke is
the only model that needs the synthetic bus error (item 7), because it is the
only one whose ROM probes for SCSI. Leading with it puts the hardest,
least-understood work on the critical path and delivers nothing authentic until
it is solved. Leading with the 64K models defers item 7 entirely.

| | 128K / 512K | 512Ke |
|---|---|---|
| selector + RAM sizing | yes | yes |
| ROM delivery (item 1) | yes - tractable, sim-verifiable | no |
| decoder SCSI gating (item 5) | yes - small | yes |
| **bus error (item 7)** | **no** | **yes - open-ended** |
| new test asset | MFS 400K image | none, HD20 at s1 boots |

**The cost of this ordering, stated honestly.** The 512Ke would have changed RAM
only and booted a known-good disk, so a failure had one plausible cause. The
128K lands ROM delivery, the 64K decode path, a new RAM size and an untried disk
format at once, so a failure has four. Both mitigations are cheap and are built
into the phases below: prove ROM delivery in simulation before hardware, and
validate both test assets before the FPGA is involved. That separates "is my
test asset good" from "is my RTL right".

An earlier draft proposed Mini vMac for that validation. **Dropped -- neither
half of it needs an emulator.** The ROM images verify against their own stored
checksums (below), and a 400K MFS disk can be booted on the *existing, trusted
Plus core* on the rig, because the Plus ROM reads MFS. Mini vMac would also have
been more friction than implied: it ships no ROM (it wants a supplied
`vMac.ROM`), and its stock build is Mac Plus only -- a 128K or 512K needs a
custom variation build.

**The assumption this ordering rests on.** That the 64K ROM contains no SCSI
Manager -- true as far as we know, since SCSI arrived with the Plus's 128K ROM.
If it is wrong, the 64K models need the bus error too and the reordering buys
nothing. Falsify it cheaply at the end of Phase 2: boot the 64K ROM with SCSI
still enabled and see whether it cares.

**Phase 0 - baseline and assets.** Record what Plus and SE do today on the test
rig (s0=mac_80mb, s1=HD20 boots, s4=the ISO) so any later regression is
attributable. Then retire the test-asset risk, so none of it can later be
confused with an RTL fault. No RTL change, and no emulator.

- **ROM images: DONE, 2026-09-03.** All five in `C:\temp\Mac\ROMS` verify
  against their own stored checksum -- the first longword equals the sum of the
  remaining big-endian 16-bit words. `28BA61CE` and `28BA4E50` (64K, 65536
  bytes) and `4D1EEEE1`/`4D1EEAE1`/`4D1F8172` (128K, 131072 bytes) all match
  their filenames. That proves they are intact, untruncated and in the right
  byte order, which matters because the download path swaps
  (`MacPlus.sv:1017`). The Mac checks the same sum at power-on, so a bad image
  would give a Sad Mac ROM-checksum code rather than a mystery.
- **MFS 400K boot disk: DONE, already tested.** The Plus core boots System 1
  and System 2 from a 400K disk, hardware-tested (Daniel, 2026-09-03), as a
  real Plus does. So the image is known-good before this project starts, and no
  emulator or new tooling is needed.

  This is worth more than a retired risk: it makes the Phase 3 disk a
  **control**. If the same image that boots on the Plus fails on the 128K, the
  disk is exonerated by construction and the fault is in ROM delivery, RAM
  sizing or the 64K decode. It is also incidental evidence for item 8 -- the
  floppy path already boots a single-sided 400K image, so `DRIVE_REG_SIDES`
  behaves in a boot scenario and not only a data one.

Phase 0 therefore reduces to recording the rig baseline. Both assets are
already validated.

**Phase 1 - model selector and RAM sizing.** Items 2, 3, 4, 6. Needs no new ROM.
Proves the selector widening without depending on the ROM-delivery design.
Delivers no model on its own; verified negatively (Plus and SE unregressed, 512K
correctly reported).

**Phase 2 - 64K ROM delivery.** Item 1. Verifiable in simulation before
hardware: a bench asserting that ROM reads at $400000 land on the right SDRAM
words for each model. Settle the one-image-or-two question first, since it sizes
the scheme. Ends with the SCSI-Manager falsification test above.

**Phase 3 - Mac 512K, then Mac 128K.** The first authentic deliverable. Wire
`configROMSize == 2'b00` to the selector, expose the 128K RAM size, and add item
8. 512K first, because it changes one thing less than the 128K does.

**SCSI stays enabled through this phase, deliberately.** It is not needed for
these models to boot, and leaving it on is what makes the no-SCSI-Manager
assumption observable rather than asserted. Gating it here would also add a
variable to the phase that delivers the first authentic machine.

Hardware pass criterion: boots System 1 or 2 from **the same 400K MFS image the
Plus core already boots**, reports the right RAM, and Plus/SE/512Ke-shaped
models are unregressed. Using that specific image is the point -- it is a
control, so a failure cannot be blamed on the disk.

**Phase 4 - SCSI absence, for every model that needs it.** Items 5 and 7. Build
the gating mechanism and the synthetic bus error once, for the 512Ke -- the only
model whose ROM probes -- then extend the gate to `configROMSize == 2'b00` so
the 64K machines are accurate too. By this point the falsification test has
already been run with SCSI enabled, so nothing is lost by turning it off.

This is where `addrDecoder.v:119` may finally have to be understood. Note that
item 7 is not merely a 512Ke enabler: bus-erroring on unmapped accesses is
authentic 68000 behaviour and a general accuracy win, so it stands on its own as
a capstone.

Hardware pass criteria: a 512Ke boots System 6 from the HD20 image at s1,
reports 512K in "About the Finder", finds no SCSI devices and does not hang
looking; a 128K still boots System 1/2 from the 400K control image with SCSI now
gated; every other model unregressed.

## Verification

House ladder applies unchanged: a failing test before the fix, iverilog
simulation (`C:\iverilog` - not verilator; MacLC's benches are unusable here),
then hardware. Watch for the `@(posedge clk); #1;` foot-gun in any new bench.

The standing gate holds: **no merge to master and no full Quartus compile
without asking first.**

Each phase carries its own pass criterion, stated with the phase above. Phase 1
is the only one verified purely negatively, because it delivers no model.
