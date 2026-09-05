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

**DONE, `c2c06c1`. Widening was confirmed correct, not merely chosen.** The plan
flagged the index encoding as consistent with the two-file/bit-6 evidence but
unproven, and to confirm it in Main_MiSTer before relying on it. Read the actual
source: `user_io.cpp:1619` sends `boot0.rom`..`boot3.rom` as `i << 6` in
`ioctl_index` for `i = 0..3`, and `user_io_file_tx` (`user_io.cpp:2724`) packs
that as `ioctl_index[7:6]`. So `dio_index[7:6]` was exactly right -- and it
comes with a hard ceiling worth having on record: the loader loop is `i < 4`, so
Main_MiSTer supports at most four boot ROMs. A fifth slot needs a change there
too, not just here. Moot for this project, since one extra slot is all Phase
2/3 need, but not moot in general.

Implemented as a shared module, `rtl/rom_word_addr.v`, instantiated once per
side (download, read) rather than as two independently widened concatenations.
Before this, the two sides agreeing on where the slot number sits in the
address was coincidental; now it is structural, for the same reason
`rtl/mac_model.v` centralizes `machineType` rather than trusting two call sites
to stay in sync. Gate: `sim/tb_rom_word_addr.v`, 19/19, mutation-tested (a
misplaced slot field and a wrong shift amount each fail 3 of 19 -- the four
named boot-file-window checks, which is exactly what should catch this class of
bug, since the agreement checks alone would not: a fault inside one shared
module affects both instantiations identically).

Note also that `MacPlus.sv:336` declared `localparam configROMSize = 1'b1;` and
**never referenced it** - line 620 passed a literal concat instead. Dead code;
removed in Phase 1 (`21c0460`).

## The ROM images exist

`C:\temp\Mac\ROMS` (local, not in the repo, not distributed):

| model | file | size |
|---|---|---|
| Macintosh 128K | `64KB ROMs/1984-01 - 28BA61CE - Macintosh 128.ROM` | 65536 |
| Macintosh 512K | `64KB ROMs/1984-10 - 28BA4E50 - Macintosh 512K.ROM` | 65536 |
| Mac Plus v1/v2/v3 | `128KB ROMs/1986-0* - 4D1E*/4D1F8172 - MacPlus v*.ROM` | 131072 |

`4D1F8172` (Plus v3) is the image already in `releases/boot0.rom`, per
`CD_BLOCK_SIZE_PLAN.md`.

**Are the two 64K images machine-specific? Almost certainly not -- diffed
2026-09-03.** They differ by **57 bytes of 65536 (0.087%)** in five clusters:

| offset | change | reading |
|---|---|---|
| 0x00002 | `61CE` -> `4E50` | the stored ROM checksum, expected |
| 0x01CA6 | `66 4E` -> `60 36` | `BNE.S +$4E` -> `BRA.S +$36`, a conditional test removed |
| 0x01D8B | `72 1F` -> `72 3F` | `MOVEQ #$1F,D1` -> `MOVEQ #$3F,D1` |
| 0x01D9D-0x01DD5 | 2-byte insertion + shift | `MOVEQ #$1F,D1` inserted, a `MOVE.W` retargeted D1->D2, `#$52`->`#$50`, and `MOVEQ #0,D0 / BRA.S` replaced by `NOP`. Every downstream displacement moves by exactly 2, consistent with the insertion |
| 0x05040 | `ORI #$0100,SR` -> `ORI #$0300,SR` | immediately after `MOVEA.L #$00EFE1FE,A1` (the VIA): raising the interrupt mask from level 1 to 3, so the SCC (level 2) can no longer interrupt a VIA access |

The main cluster is inside the **`.Sony` floppy driver** -- the `.Sony` name
string is at 0x016A3 and the IWM base constant `$00DFE1FF` at 0x01F2C, so
0x01CA6-0x01DD5 lies between them.

**The decisive part is what is absent.** Those 57 bytes are the *entire*
difference, so this is a definitive claim and not a sample: **no memory-map
constant differs anywhere in the ROM.** No changed screen base, no changed RAM
top, no changed sizing table. A ROM hardcoding 512K rather than 128K would have
to show one. So these are a floppy-driver revision plus an interrupt-masking
race fix -- neither machine-specific -- and either image very likely runs on
either machine.

Unexplained: `#$1F` -> `#$3F`. That is the shape a size mask could take, but it
is a doubling where 128K->512K is a factor of four, and it sits inside the
floppy driver. Both argue against a memory reading. Inference from the diff, not
a boot test; confirm in Phase 2.

**Consequence for the design: one extra 64K slot is sufficient**, with the user
choosing which image goes in it rather than the core hardcoding a model->ROM
pairing. The pairing is not clean-cut anyway -- a 128K sold in late 1984 may
well have shipped with the October ROM.

**Decided 2026-09-03 (Daniel): one slot, user's choice.** Concretely, drop the
wanted 64K image into `boot2.rom` on the SD card -- the same mechanism as
`boot0.rom`/`boot1.rom` today, so no new RTL beyond the extra index and no OSD
entry.

The consequence, stated so it is not a surprise later: the model selector then
sets **RAM size only, not the ROM**. Switching between Macintosh 128K and
Macintosh 512K in the OSD will not switch ROM revisions -- both run whatever is
in `boot2.rom`. Per the diff, that costs a floppy-driver revision and an
interrupt-mask fix, not machine identity. If it ever chafes, a second slot is
one more index value.

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

**CORRECTED 2026-09-04: detection is NOT a bus error, and item 7 does not block
the 512Ke.** The Plus ROM was disassembled rather than reasoned about, and it
settles both questions at once. At `$4003E0`:

```
$4003E0  clr.w   $0B22.w
$4003E4  move.l  $420000.l, d0
$4003EA  cmp.l   $440000.l, d0
$4003F0  beq     $4003F8          ; SAME -> no SCSI, flag stays 0
$4003F2  move.b  #$C0, $0B22.w    ; DIFFERENT -> SCSI present
```

Two plain reads in the ROM window, compared. `$420000` has A17 = 1 and
`$440000` has A17 = 0 -- exactly the discriminator at `addrDecoder.v:119`.
Nothing faults, and no bus-error handler is installed first (`$1D4`/`$1E0` are
not written until `$4003FC`), so a bus error cannot be the mechanism: both reads
must return data, on both machines.

`$0B22` bit 7 is then the single gate on everything SCSI. `$407D40` -- the
drive-queue advance inside the boot search -- opens with `tst.b $0B22.w / bpl`
and returns immediately when the flag is clear, so a machine that fails the test
never probes an ID, never looks for the `'ER'` (`$4552`) Driver Descriptor Map,
and never enqueues a SCSI volume.

**So an authentic 512Ke needs exactly one thing: the ROM must MIRROR at
A17 = 1.** Then `$420000` and `$440000` read the same word and the flag stays
clear. `addrController_top.v:225` already forces A17 to 0 for a 128K-ROM access,
so a mirrored read lands on ROM offset 0 either way -- only the decode condition
has to change.

And the file said so all along. `addrDecoder.v`'s own header comment reads **"If
ROM is mirrored when A17 is 1, then SCSI is assumed to be unavailable"**. The
`!!!` at line 119 was the headline; the mechanism was already written out four
lines up, in the memory map. Same lesson as Phase 3's conversion table
([[feedback-read-the-spec-for-historical-hardware]]): read the whole mechanism,
not the marker somebody left on it.

**Why the SE is unaffected.** With `configROMSize[1] = 1` the whole `$4xxxxx`
window already decodes ROM -- but the SE's ROM is 256K, so A17 is a real ROM
address bit and `$420000` genuinely differs from `$440000` in CONTENT. The SE
passes the test on data, not on decode. Nothing to change there.

**What the bus error is still for.** Item 7 keeps its accuracy argument -- a
68000 with nothing at an address should fault -- but it is now a nice-to-have,
not a 512Ke enabler, and it carries a hazard worth recording before anyone
builds it: bus-erroring *every* unmapped access would fault the Plus at
`$4003E4`, during its own SCSI probe, with no handler installed, and kill the
machine at startup. Any synthetic bus error must be scoped to the SCSI window
and must NOT cover the `$4xxxxx` ROM window.

## What is missing, in full

| # | item | file | size |
|---|---|---|---|
| 1 | ROM delivery for a third (and fourth) image | `MacPlus.sv:1018,1042` | design decision, then small |
| 2 | Model selector 1 bit -> **3** bits (and moved to bits 1-3), straps derived from it | `MacPlus.sv:89,136,641,698,1066` + `rtl/mac_model.v` | **DONE** `21c0460` |
| 3 | `configRAMSize` reachable for 128K/512K | `MacPlus.sv:338` | **DONE** `21c0460` |
| 4 | RAM size derived from model, not chosen, for the soldered-RAM machines | `rtl/mac_model.v` | **DONE** `21c0460` |
| 5 | Gate SCSI off for non-Plus models | `rtl/addrDecoder.v:139` | **DONE** `dcfbe62` |
| 6 | Delete the dead `configROMSize` localparam | `MacPlus.sv:336` | **DONE** `21c0460` |
| 7 | Synthetic bus error for the unmapped SCSI window | `MacPlus.sv:523,579,614` | optional accuracy - does **NOT** block the 512Ke (corrected 2026-09-04); must not cover the `$4xxxxx` ROM window |
| 8 | Refuse 800K images in 128K/512K mode | `MacPlus.sv:965-1013` | small - a 400K-only drive cannot take one |
| 9 | **Mirror the ROM at A17 = 1 for SCSI-less models** | `rtl/addrDecoder.v:134` + `rtl/mac_model.v` | **DONE** `dcfbe62` |

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

This also gives the falsification test a second job (it runs in Phase 3, not
Phase 2 -- see that phase below, corrected after the plan first misplaced it).
Booting the 64K ROM with SCSI still enabled tests the no-SCSI-Manager assumption
*and* predicts a clean boot with an HFS disk mounted. One test, both
confirmations -- and if it fails, both claims fall together.

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

**Phase 1 - model selector and RAM sizing. DONE, `21c0460`.** Items 2, 3, 4, 6.
No new model offered; `rtl/mac_model.v` maps model -> straps in one table, with
`sim/tb_mac_model.v` (13/13, mutation-tested) as the gate. No Quartus compile
run -- there is nothing observable to see yet, so hardware verification is
bundled with Phase 3.

**Two errors in this plan surfaced while wiring it, both now corrected above.**

*Item 2 said "1 bit -> 2 bits". It is 3 bits, and the field had to move.* Five
models are wanted, so 2 bits is not enough; and bit 10, next to the old bit 9,
is the serial input (`MacPlus.sv:349` -- live in code even though its OSD entry
is commented out), so there was no contiguous room. Model now sits at bits 1-3.
That is an incompatible CONF_STR layout change, so the config version went
`v,0` -> `v,1` and **every saved setting resets once** on first start.

*The plan listed three consumers of `status_mod`. There are four.*
`dataController_top` takes it as `machineType` and hangs **eight** behavioural
differences off it -- sound buffer, drive select, the memory-overlay mechanism,
VIA port B wiring, and the keyboard, which is a wholly different protocol on the
SE (ADB) from the Plus. It is a Plus-vs-SE **boolean, not a model index**: a
128K handed its own model number would get ADB keyboard timing and never see a
keypress. This is the single most dangerous thing in the whole project, because
it fails silently, and it is why the mapping is a module with a bench rather
than a wider `status_mod`.

Item 4 also came out better than specified. Rather than guarding "a 128K cannot
have 4MB", RAM size is **derived** for the soldered-RAM machines -- the 128K,
512K and 512Ke were not expandable, so only the Plus and SE honour the OSD
Memory option and no invented configuration exists to guard against.

**Phase 2 - 64K ROM delivery. DONE, `c2c06c1`.** Item 1. Verified in simulation,
not yet hardware: `sim/tb_rom_word_addr.v` asserts that a byte written for slot
N reads back from slot N, for all four slots. No model points at the new slot
yet -- `rtl/mac_model.v` leaves it reserved -- so there is nothing to boot and
nothing to see on hardware from this phase alone. **The SCSI-Manager
falsification test cannot run here after all**, on reflection while writing
this up: it needs a booting 64K model, which does not exist until Phase 3. Moved
below, where it belongs.

**Phase 3 - Mac 512K, then Mac 128K. DONE AND HARDWARE-CONFIRMED 2026-09-03,
build `46aec82a`: the Mac 128K BOOTS TO THE FINDER DESKTOP.** The first
authentic pre-Plus machine in this core. Six bugs, every one reachable only by
a 64K model, are written up in the sections below -- keep them for the lessons,
not as open work. Known-good probe baseline at the desktop: `maxTrack=52`
(matching a working Plus), duty index settled at 52/199, which is the
documented ~402 rpm operating point for tracks 0-15.

The first authentic
deliverable. Wired
`configROMSize == 2'b00` to the selector, exposed the 128K/512K RAM sizes, and
added item 8. `sim/tb_mac_model.v` extended to 22/22, mutation-tested.

Renumbered `MODEL_512KE` from 2 to 4 while doing this -- see `rtl/mac_model.v`'s
own comment for why (the Phase 1 comment's assumed ordering did not survive
contact with "512Ke isn't exposed in the OSD yet" and MiSTer's OSD parser
having no established way to leave a numbered gap).

Still needed before the pass criteria below can be checked: place the chosen
64K ROM image as `releases/boot2.rom`, and a Quartus compile -- **not run without
asking first**, per standing rule.

**SCSI stays enabled through this phase, deliberately.** It is not needed for
these models to boot, and leaving it on is what makes the no-SCSI-Manager
assumption observable rather than asserted. Gating it here would also add a
variable to the phase that delivers the first authentic machine.

Hardware pass criteria: boots System 1 or 2 from **the same 400K MFS image the
Plus core already boots**, reports the right RAM, and Plus/SE/512Ke-shaped
models are unregressed. Using that specific image is the point -- it is a
control, so a failure cannot be blamed on the disk.

This is also where the **SCSI-Manager falsification test** runs (moved here
from Phase 2, where it could not yet run): with a SCSI hard disk still mounted,
confirm the 64K ROM boots this HFS-formatted machine cleanly with no complaint.
That both confirms the no-SCSI-Manager assumption this plan's phase order rests
on, and predicts the outcome of Daniel's Finder-1.1g observation for these
models: since the 64K ROM never scans the bus, the System-1.x-vs-SCSI failure
seen on the Plus should not reproduce here. If it does reproduce, both claims
fall together and Phase 4's scope grows to cover the 64K models sooner.

### Phase 3's boot hang: two bugs, both 64K-only, both fixed

**Hardware test 2026-09-03: the 128K and 512K compiled clean and hung.** Plus
and SE unregressed. JTAG (`scripts/read_probes.tcl`) showed `PACT` and `PIFA`
bit-for-bit identical across three samples 1.5s apart -- a genuine 68000 HALT,
not a software loop, which on this CPU means a double fault from a garbage
reset SP/PC. Both known 64K ROM images failed identically, so ROM *content* was
never the variable.

**Diagnosed and fixed 2026-09-03. There were two independent causes, either one
sufficient on its own, and both reachable only by a 64K model** -- which is
exactly why Plus and SE kept working and why the fault looked like "the new
models are broken" rather than "the address map is full".

**Bug 1: ROM slot 2 and the internal floppy image were the same SDRAM words.**
The old map packed the two ROM slots into the first megabyte of the disk region
(words `0x200000`-`0x27FFFF`) and started the internal floppy image at exactly
one megabyte into it (`0x280000`). Two 512KB slots is exactly one megabyte, so
the map was **precisely full**. Phase 2 widened ROM to four slots without
anything recording what sat above slot 1, and slot 2's base came out
bit-identical to the floppy image's base -- an exact alias, not a partial
overlap. Mounting any internal floppy overwrote `boot2.rom`, so the 68000 read
its reset vector out of the first bytes of a disk image.

Fixed by giving ROM its own region at word `0x400000`. `sdram.v` decodes
`addr[22:0]` (4 banks x 4096 rows x 512 columns = 8M words = 16MB) and
everything previously in use had `addr[22] = 0`, so that entire upper half was
free. The disk windows keep their addresses, so `floppy_loader.v`, the write
committer and the arbiter are untouched.

**Bug 2: the 64K ROM was read from the wrong offset inside its slot.**
`addrController_top.v` forced A17 to **1** for `configROMSize == 2'b00`,
commented "64K ROM image is at $20000" -- true of plus_too's single-blob ROM
region, where a 64K image would have sat above the Plus's 128K ROM. Phase 2
gives every image its slot's offset 0, so `boot2.rom` was written at slot 2 +
`$00000` and read back from slot 2 + `$20000`: SDRAM nobody ever wrote. Fixed
by forcing A17 to 0, which is where every other ROM size already reads from.

**Both lines were older than this project and neither had ever executed.**
`configROMSize` came from `{status_mod, ~status_mod}` and `configRAMSize` from
`status_mem ? 2'b11 : 2'b10`, so `2'b00` was **unreachable on both** until
Phase 3 exposed these models. The A17 line dates to `c996f47`. Treat every
`configROMSize == 2'b00` / `configRAMSize == 2'b00` branch as untested legacy
by default -- the RAM sizing was audited at the same time and is correct (128K
forces A17-A21, 512K forces A19-A21), but that was luck, not coverage.

**The `"O13"` OSD suspect was wrong, and is now settled from source.**
`Main_MiSTer/user_io.cpp:506` (`user_io_status_bits`) parses `"O13"` as
`start = '1'-'0' = 1`, `end = '3'-'0' = 3`, `size = 1 + end - start = 3`. It is
a genuine inclusive span, so `status[3:1]` was right all along and
non-adjacent hex digits are fine. Do not re-open this.

**Gate: `sim/tb_sdram_map.v`, 27/27.** The whole SDRAM region map now lives in
`rtl/sdram_map.vh`, named, and is consumed from both `MacPlus.sv` (the
`sdram_addr` mux) and `addrController_top.v` (the per-image byte offsets), so
the bench checks the *real* constants rather than re-deriving them. It asserts
every pair of windows is disjoint and that each fits `addr[22:0]`. It carries
its own mutation checks: run against the historical ROM base it must still
report that slot 2 aliased the internal floppy and that slots 0/1 did not. It
FAILS 2/27 against the pre-fix map -- slots 2 and 3 versus the internal floppy,
with 0 and 1 clear, reproducing the hardware symptom exactly.

**Why the existing gates could not have caught this.** `sim/tb_mac_model.v`
(22/22) proved the straps and `sim/tb_rom_word_addr.v` (19/19) proved that a
byte written for slot N reads back from slot N. Both were green throughout.
Neither knows where its region *sits* in SDRAM, because until now the region
map existed nowhere but inside one concatenation in `MacPlus.sv`. Textbook
seam: every module correct, the joins between them unowned and untested.

**Still needed: a Quartus compile and a hardware re-test** -- not run without
asking, per standing rule. Re-run `scripts/read_probes.tcl` afterwards; `PACT`
and `PIFA` advancing between two samples is the pass signal, a boot to the
Finder is the real one.

**One prediction worth testing on the OLD archived rbf, no compile needed:**
selecting 128K with **no floppy mounted at all** should not halt, because
nothing then overwrites slot 2. Bug 2 alone still breaks it, so this is a check
on the diagnosis rather than a workaround -- but note it discriminates: if the
128K halts identically with no disk mounted, bug 2 is doing the work; if it
gets further, bug 1 was contributing too.

### Phase 3, second hardware round: Sad Mac 0F0004

**Hardware 2026-09-03, after `1345aa9`: the machine BOOTS.** The 64K ROM runs,
passes its ROM and RAM self-tests, initialises video and draws -- both
address-map bugs above are genuinely closed. It then fails to load the System
with **Sad Mac `0F0004`**.

Class `0F` is the exception class and subclass `0004` is **divide by zero**, so
this is the ROM catching a 68000 exception, not failing a memory test. The
documented cause is specific and matches this configuration exactly: a 64K-ROM
Mac talking to an **800K drive mechanism**, where the ROM does not get RPM/tach
readings it considers valid and divides by zero.

**Item 8 was only half done.** Phase 3 gated the **media** on `drive800k` (an
800K image is refused) and left the drive's own `SIDES` register hardcoded to
`1'b1` in `rtl/floppy.v` -- so a 128K still told its ROM it had a double-sided
mechanism. The media is what the user mounts; the **mechanism is what the ROM
interrogates**, and only the second one is on this path.

Fixed by plumbing `drive800k` from `rtl/mac_model.v` down the existing chain
(`MacPlus.sv` -> `dataController_top.sv` -> `iwm.v` -> both `floppy.v`
instances) and reporting it as `SIDES`. Plus/SE/512Ke keep `1'b1` and are
bit-identical to before.

**This did NOT fix it, and the reasoning that dismissed the tachometer was
wrong.** The claim made here was "the tachometer needs no change: it is already
a track-indexed CLV table (500/550/600/675/750 RPM), correct for the 400K and
800K drives alike." The RPM *values* are indeed right for both. That was never
the question. See the next section.

**Gate: `sim/tb_drive_sides.v`, 9/9, mutation-tested** (3/9 fail against the
hardcoded value, and only the 400K rows). The property it holds is **media vs
mechanism**: they are different signals with different lifetimes -- `diskSides`
changes when you mount a disk, `drive800k` never changes for a given model --
so wiring `SIDES` to the wrong one looks right with a disk inserted and wrong
with an empty drive. Every case pins one against the other, and two neighbour
registers confirm the `{ca2,ca1,ca0,SEL} = 1100` decode is really `SIDES`.

**Consequence for testing, and it is not optional: these models can only take a
400K image.** The media gate refuses 819200 bytes outright, so an 800K image on
a 128K/512K produces no inserted disk at all -- a blinking "?" disk, a
different failure from this one. Use the 400K MFS control image.

### 0F0004, actually understood: the spindle has to answer the Mac

**`SIDES` was not it. Hardware still gave 0F0004.** The reason is worth stating
plainly, because it invalidates the reasoning above and not just its
conclusion: **the ROM never asks the drive what it is. It discovers the drive
type by whether the speed responds.**

The documented mechanism:

- On a **400K** mechanism the Mac controls spindle speed **in software**. It
  writes a PWM byte into the **low byte of every 16-bit word of the sound
  buffer** and closes the loop by reading `TACH` back.
- An **800K** mechanism self-regulates and ignores the PWM entirely.
- The 64K ROM calibrates by measuring the tach, **changing the PWM**, and
  measuring again -- then **dividing by the difference**. Against a drive that
  ignores the PWM, both measurements are identical, the divisor is zero, and it
  takes a divide-by-zero exception. Class `0F`, subclass `0004`.

**This core WAS such a drive.** `floppy.v`'s tach period depended only on the
track, so no PWM write could ever move it -- functionally identical to a
self-regulating 800K mechanism. And `dataController_top.sv` was *discarding*
the PWM: `audio_prebuf <= memoryDataIn[15:8]` takes the audio byte and the low
byte, which is the spindle PWM, went nowhere. The signal the ROM needed was
already in the design and being thrown away.

Confirmed independently from the ROM itself rather than from the error code
alone. Disassembling the 64K image (capstone, `CS_ARCH_M68K`) gives the Sad Mac
routine at `$4000F4` and the generic exception handler at `$4009D0`:

```
$4009D0  move.w  d0, d1      ; subclass <- d0
$4009D2  movea.w #$f, a4     ; class = $0F
$4009D8  bra.w   $4000f4     ; -> Sad Mac
```

and the display routine takes the low byte of `a4` then the word of `d1`, which
is where the six digits come from. So `0F0004` is structurally `a4 = $0F`,
`d1 = 4` -- an exception, not a memory-test failure. Useful technique to keep:
**the ROM can be disassembled locally to settle what a code means**, instead of
trusting a forum table.

**Fix: the PWM now trims the per-track period, for 400K mechanisms only.**
`dataController_top.sv` captures `memoryDataIn[7:0]` alongside the audio byte
and passes it down the same chain as `drive800k`. Trimming rather than
replacing the table keeps the known-good per-track speed as the natural
operating point, so the ROM's loop converges on the speed this core already
reads disks at, rather than on some point of a curve nobody has measured. All
the loop needs is a monotonic response with room either side of the target;
8 counts per PWM step gives about +/-10%, well outside the acceptance windows
in `floppy.v`'s own table and inside 14 bits at both extremes (5618..11020).
Plus/SE/512Ke keep the fixed table -- authentic for an 800K drive, and already
proven on hardware.

**Gate: `sim/tb_drive_tach.v`, 5/5, mutation-tested** (3/5 fail when the PWM is
ignored again -- including, by name, "two PWM values give DIFFERENT tach
periods (divisor != 0)", which IS the divide-by-zero condition). The bench
measures real toggle periods by counting clocks between `TACH` edges **through
the drive-register read port**, not by inspecting internals, so a PWM that is
accepted at the port but never reaches the counter still fails. It also asserts
the 800K drive does **not** respond, because self-regulation there is the
hardware-proven behaviour and making Plus/SE obey the PWM would be a regression
dressed as a feature.

**Lesson, and it is the same one twice now.** `SIDES` was a plausible,
authentic, well-motivated change that fixed nothing, because it was chosen from
a symptom's *usual* cause rather than from the mechanism. The search result
that named it said "does not get valid RPM readings" in the same sentence, and
that clause was the actual answer. Read the mechanism, not the headline.

### Happy Mac, then the flashing "?": the trim was still wrong

**0F0004 is GONE** -- the spindle loop converges, so the PWM work was right in
substance. The 128K/512K now read the boot blocks, accept the disk and show a
happy Mac, then revert to the flashing "?" after a while.

**The disk exonerates itself and dates the failure precisely.** Parsing
`System Disk 1.0.img` (the same image that boots on the Plus): MFS, boot block
`$4C4B` valid, `bbVersion $0011`, System with a 137,728-byte resource fork.
Layout:

| what the ROM reads | logical blocks | track | zone |
|---|---|---|---|
| boot blocks | 0-1 | 0 | 0 |
| MFS directory | 4-15 | 0-1 | 0 |
| System file | 16 onward | 1 .. most of the disk | 0, then **1, 2, 3** |

Everything read before the happy Mac lives in **tracks 0-15, which is CLV zone
0**. The failure is the first step into track 16.

**The cause was the shape of the fix, not the idea.** A real 400K drive has no
idea which track the head is on: its speed is a function of the PWM ALONE, and
the Mac obtains each zone's speed by WRITING A DIFFERENT PWM. Trimming the
per-track table made the period depend on BOTH, so every zone change was
applied twice -- once because the head moved, again when the Mac wrote the PWM
for the new zone -- and the ROM measured a speed its own calibration did not
predict. Zone 0 never exercises that, which is exactly why it got as far as it
did.

Fixed by making the 400K period a function of `disk_pwm` only:
`11000 - 20*pwm`, spanning half-periods 11000..5900 against a table needing
9996..6634, i.e. reachable at pwm 50..219 with headroom at both rails. The
modelled speed is free to be "cosmetic" here because **this core's byte rate is
fixed and does not depend on it** -- which is itself faithful, since a real
drive's data rate is constant across zones and that is the whole point of CLV.
Plus/SE/512Ke keep the track-indexed table.

**Gate: `sim/tb_drive_tach.v` now 10/10, mutation-tested against the trim
design, which fails 5/10** -- track-independence AND, tellingly, all four CLV
range checks: the trim could not reach the extreme zones from any single PWM
value at all. Added checks: the period is independent of the track for a 400K
drive and still zone-dependent for an 800K one, the map spans the full CLV
table, and both ends keep PWM headroom rather than sitting on a rail.

**Method note worth keeping: the disk image is evidence.** Parsing the boot
block and MFS directory locally turned "it fails somewhere after the happy Mac"
into "it fails at the first track-16 read", which named the bug. `sim/`-side
Python can read these images directly; MFS signature is `$D2D7` at offset 1024,
boot block `$4C4B` at 0.

### Instrumenting it: the PFLP probe (`dbg_floppy`)

**The PWM-absolute map did not fix it either, and a 400K GAME disk fails the
same way** -- so the fault is in the floppy read path, not the System disk, and
not RAM capacity. Model under test is the **128K**.

Between the working Plus and the failing 128K the floppy path now differs in
exactly two things: `SIDES`, and the tach map. The tach must respond to the PWM
or 0F0004 returns, and the fact that 0F0004 STAYED away proves the PWM byte is
genuinely arriving. That leaves the map's **absolute calibration** as the live
suspect -- ours needs pwm 50..219 to cover the CLV table, and if the ROM's real
operating range is elsewhere it converges somewhere it will not accept.

That is a number, not a theory, so stop guessing and measure it. Added a 20th
probe, `PFLP`, carrying `rtl/floppy.v`'s new `dbg_floppy` bundle up through
`iwm.v` and `dataController_top.sv`:

```
{maxTrack[6:0], curTrack[6:0], pwmMin[7:0], pwmMax[7:0], switched, motor}
```

- **maxTrack** is a HIGH-WATER mark, not the live head position -- by the time
  a probe is read the ROM has recalibrated back to track 0. Track 15/16 is the
  CLV zone-0/zone-1 boundary, so this single number confirms or kills the zone
  theory outright.
- **pwmMin/pwmMax** bracket the range the Mac's loop actually drove, which is
  exactly what an invented PWM->period map has to be calibrated against. If
  they read `NEVER WRITTEN`, the sound-buffer low byte is not reaching us at
  all and everything above is moot.

Decoded by `scripts/read_probes.tcl`, which degrades gracefully on older
bitstreams (verified against the live board on `01A1AF72`: prints `PFLP ABSENT`
and reads every other probe normally).

**19 -> 20 instances, which is the documented ceiling.** Anything further needs
a SCSI probe pruned first; `PDM3`/`PIO4`/`PIO3` are the least load-bearing.

**Free finding from that live read.** `PIFA` had the CPU at `$400530` with
`PACT` advancing, and disassembly shows exactly where that is:

```
$4004CE  movea.l #$10000, a1     ; boot blocks are read to $10000
$4004D8  move.l  #$400, $24(a0)  ; 1024 bytes = logical blocks 0-1
$400530  subq.l  #$1, d0         ; <- CPU here: 262144-iteration delay
$400532  bne.b   $400530         ;    the "?" blink timer
$400546  cmpi.w  #$4c4b, (a1)+   ; boot-block 'LK' signature
$40054A  bne.b   $400500         ; not bootable -> animate and retry
```

So the machine is in the ROM's "read boot blocks, no 'LK', blink, retry" loop --
alive and looping, not wedged, which matches the flashing icon and rules out a
bus hang. Worth keeping: **the probe deck plus a local disassembly turns a PC
into a named routine**, which is far stronger evidence than a symptom.

### What PFLP measured, and what the documentation then explained

**Probe results, `398b34c4`:**

| model | maxTrack | outcome |
|---|---|---|
| Plus | **52** | boots to the desktop |
| 512K | **0** | fails |
| 128K | **0** | fails |

**Neither 64K model ever steps the head -- not once, across minutes of retrying.**
That killed the CLV-zone theory outright (track 16 was never reached, so the two
preceding fixes were repairing something off the failure path), and 512K failing
identically exonerated RAM size. Daniel also reported the symptom is
**inconsistent** -- flashing "?", flashing X, happy Mac, varying run to run and
changing without input. **A deterministic logic error does not do that. Unstable
data does.**

**Two of the four probe fields were badly chosen and measured nothing**, which is
worth recording so the mistake is not repeated: `curTrack` read 0 always,
`switched` was a sticky seen-latch that any mount sets (a healthy Plus reads 1
too), and the PWM **min/max** saturated to 0..255 on the working Plus as well as
on the failures. Only `maxTrack` earned its bits. Min/max over a whole session
was always going to saturate; the useful measurement is the LIVE value sampled
repeatedly.

**The documentation then named the bug** (Guide to the Macintosh Family
Hardware, via the drive-emulation writeups):

> To calculate the PWM duty cycle from the data in the sound buffer, convert the
> **lower 6 bits** of each value using a table, **sum these over a period of
> ~100 values**, then calculate the index.

The Mac does **not** write one constant PWM byte into every word. It writes a
**dithered sequence**, and the duty is the **average of the low 6 bits over
~100 words**. This core sampled a **single word** and used **all 8 bits** -- an
arbitrary point on a dither pattern, i.e. noise. The tachometer was therefore
frequency-modulated at random, the ROM's speed measurement returned a different
answer every attempt, no speed was ever accepted, and the head never seeked.
It also explains why 0F0004 stopped: the tach did start varying, so the divisor
was no longer zero -- it was just varying randomly instead of under the Mac's
control.

**Fix:** `dataController_top.sv` now accumulates the **low 6 bits** of 128
consecutive sound-buffer words and hands `floppy.v` the sum (0..8064, 13 bits).
128 rather than 100 because a power of two makes the boxcar a shift, and the ROM
closes its own loop by measurement so the window length is not critical -- the
noise rejection is. The tach map rescales to `11000 - (duty*81 >> 7)`, spanning
11000..5897 against a CLV table needing 9996..6634.

**Gate: `sim/tb_drive_tach.v` 12/12**, with two new checks aimed exactly at what
failed on hardware: the same duty must measure the same period twice (no
jitter), and one dither tick must move the period far less than a CLV zone
rather than making the loop chase quantisation noise. Measured: 2 clocks.

**Method lesson, twice over now.** Both times this stalled, the answer was in
documentation rather than in more inference -- first the PWM speed-control
mechanism behind 0F0004, now the dithered 6-bit encoding behind the unstable
tach. Both times the earlier search result had already contained the answer in a
subordinate clause. **When a 40-year-old hardware behaviour is in question, read
the spec before theorising.**

### The averaging worked, and it exposed inverted polarity

**PFLP on `c975617a`:**

```
maxTrack= 0   motor=0 (everSpun=1)
step requests: NONE -- the ROM never asked to seek
spindle duty = 238/252, STABLE across samples (238, 239, 238)
```

**Two results, both useful.**

**1. The averaging fixed the noise.** The duty now holds steady between samples
instead of swinging 0..255. It is a control value at last, which is what the
low-6-bits-averaged-over-128-words change was for.

**2. `step requests: NONE` settles the fork inference could not.** We are NOT
rejecting steps -- the ROM never issues one. So everything downstream of the
step decode is exonerated, and the failure is upstream: the ROM will not seek
because it never accepts a speed.

**3. The duty is RAILED at 238/252 (~94%), and that is the diagnosis.** The head
is on track 0, where the ROM wants the SLOWEST CLV zone (500 RPM, period 9996).
The map made a higher duty mean a FASTER spindle, so the loop was asking for
slow while pushing toward fast -- **positive feedback, which diverges to a rail
instead of settling.** Negative feedback settles mid-range; positive feedback
rails. The measurement distinguishes them, and it railed.

**Fix: invert the polarity.** `period = 5900 + (duty*81 >> 7)`, spanning
5900..11003 against a CLV table needing 6634..9996. A higher commanded duty now
means a longer period, i.e. a slower spindle.

This is also more defensible than the original direction rather than less: the
documented low-6-bit field goes through a **conversion table** this core does
not have, so the raw field was never a linear duty to begin with. An inverted
monotonic line is simply a better model of it, and the ROM calibrates out the
remainder by measuring.

**Gate: `tb_drive_tach` 12/12**, with the direction now asserted explicitly
("higher duty commands a SLOWER spindle"). One bench bug fixed while doing it:
the adjustment-range check computed `m_lo - m_hi`, which silently encoded a
direction and failed for the wrong reason once the map inverted. It now takes
an absolute difference, so **direction is asserted in exactly one place**.

### The documentation had the whole algorithm, including a conversion TABLE

Daniel's steer, for the third time and decisively. The 400KB drive
specification gives the complete method, and this core was implementing a
guess at it:

```
index = sum/(count/10) - 11,  clamped 0..399,  duty% = index/4.19
```
where each of the 100 summed values is the low 6 bits of a sound-buffer word
**converted through a fixed 64-entry table**:
```
 0,  1, 59,  2, 60, 40, 54,  3,   61, 32, 49, 41, 55, 19, 35,  4,
62, 52, 30, 33, 50, 12, 14, 42,   56, 16, 27, 20, 36, 23, 44,  5,
63, 58, 39, 53, 31, 48, 18, 34,   51, 29, 11, 13, 15, 26, 22, 43,
57, 38, 47, 17, 28, 10, 25, 21,   37, 46,  9, 24, 45,  8,  7,  6
```

**That table is a PERMUTATION, and missing it is why nothing converged.**
Summing raw 6-bit values gives a number with essentially no monotonic
relationship to the commanded duty, so the ROM's loop had nothing coherent to
close on: PFLP caught it oscillating 252, 5, 118, 5 on successive samples,
reaching dsFinderErr on one attempt and failing at once on the next.

**It also explains why inverting the polarity "helped".** It did not -- the
input was scrambled, so neither direction was right, and the apparent
improvement was chance. The documented curve is 9.4% duty -> 305-380 rpm and
91% -> 625-780 rpm: **higher duty is FASTER**, the original direction. Two
builds were spent on that.

**And a comment in `floppy.v` was actively misleading.** Its CLV table is
labelled 500/550/600/675/750 rpm; the real speeds are **402/438/482/536/603**.
The PERIODS are correct -- `RPM = clk8/(2*period)` since TACH is 60 pulses (120
edges) per revolution, giving 406/445/490/544/612, all within ~1.5% -- only the
labels were wrong. Corrected in place, because that error cost real time when
fitting the duty map.

**Implementation.** `rtl/disk_pwm_duty.v` does the documented computation and
is a **separate module on purpose**: `dataController_top.sv` instantiates VHDL
and cannot be elaborated by iverilog, so anything buried in it is untestable --
and every bug in this project has been in exactly that kind of unowned seam.
`floppy.v` maps the index straight to a period, fitted to the two documented
operating points (index 101 ~ 402 rpm ~ period 9996; index 302 ~ 603 rpm ~
period 6634), giving `period = 11686 - 17*index` over 0..399. Absolute accuracy
is not required -- the ROM calibrates against whatever curve the drive presents
-- but the operating range now sits mid-scale instead of against a rail, which
is what a converging loop needs.

**Gates: `sim/tb_disk_pwm_duty.v` 12/12 and `sim/tb_drive_tach.v` 11/11.** The
duty bench is written around the distinction that actually broke: several cases
are chosen so the raw and table answers are BOTH plausible in-range indices
(sample 21 -> 109 via the table, 199 raw; sample 9 -> 309 vs 79), so a bench
that only checked plausibility would have passed the broken code. It also pins
the dither average (3/7 alternating -> 14, which no single-sample implementation
can produce) and that the window is exactly 100 samples.

**Also confirmed correct against the spec, so stop re-checking them:** `SIDES`
0 = single-sided 400K drive; and the whole drive-command decode --
TRACKUP/TRACKDN via CA2, TRACKSTEP, MOTORON/MOTOROFF, TACH at
{CA2,CA1,CA0,HEADSEL} = 0111, SIDES at 1100 -- all match.

### SOLVED: the 128K boots (`46aec82a`, 2026-09-03)

Applying the documented conversion table closed it. Probe at the desktop:

```
maxTrack = 52 (CLV zone 3)   step requests: 127+ (saturated)
duty index = 52/199          <- settled, not railed
```

`maxTrack 52` is exactly what a working Plus reports. The duty settling near
**50** is the confirmation that matters: the documented operating point for
tracks 0-15 (~402 rpm) is index ~101 of 399, i.e. ~50 on the probe's halved
scale. **The ROM's calibration loop converged where the specification says it
should**, which is a much stronger result than "it happens to boot".

**Scorecard for the whole hunt.** Six bugs, every one reachable only by a 64K
model, because `configROMSize == 2'b00` and `configRAMSize == 2'b00/01` were
unreachable dead code before this phase:

| # | bug | found by |
|---|---|---|
| 1 | ROM slot 2 exactly aliased the internal floppy image | reading the SDRAM map |
| 2 | 64K ROM read from `$20000` inside its slot | reading the RTL |
| 3 | `SIDES` reported a double-sided mechanism | documentation (correct, but not a cause) |
| 4 | spindle ignored the PWM -> divide by zero | documentation |
| 5 | duty sampled not averaged, 8 bits not 6 | documentation |
| 6 | **6-bit field used raw instead of through the conversion TABLE** | documentation |

Plus a timing failure (setup slack -3.945 ns) I introduced and caught before it
shipped, and which would have produced exactly the intermittent behaviour being
hunted.

**Remaining Phase 3 items to confirm at leisure:** that the reported RAM matches
the model, that Plus/SE are unregressed (the ROM region moved under them and
`SIDES` became a signal), and the SCSI-Manager falsification test -- SCSI was
deliberately left enabled throughout, so a clean boot with a SCSI disk mounted
confirms the assumption this plan's phase order rests on.

### Phase 3 pass criteria: all met, 2026-09-03

| criterion | result |
|---|---|
| boots System 1/2/3 from a 400K MFS image | **YES** -- Finder desktop on the 128K |
| reports the right RAM | **YES, BOTH MODELS** -- System 3 reports 128K on the 128K and 512K on the 512K. Earlier Systems report no RAM figure at all, which is period-correct: the "About the Finder" memory display came later |
| floppy WRITE works | **YES** -- a file created in MacWrite under System 3 survived a reboot |
| **SCSI-Manager falsification test** | **PASSED** -- the 64K models ignore mounted SCSI disks entirely |
| Plus unregressed | **YES** -- boots from the SCSI hard disk and mounts both 400K and 800K diskettes on `46aec82a` |
| SE unregressed | not separately tested; low risk (see below) |

**The floppy write result is stronger than it looks.** Surviving a reboot means
the commit reached the SD card, not merely the SDRAM copy -- the whole chain
(IWM write path -> `floppy_write_committer` -> SDRAM -> `floppy_sd_writer` ->
card -> remount -> read back) round-trips on a 64K model. The write path
carries no model-specific logic and paces on the same `clk8` cadence as reads,
which is why it worked first time; it was still worth testing rather than
assuming, since "shares no code with the broken thing" was true of several
things that broke during this phase.

**The SCSI result closes the assumption this plan's phase order rests on.**
Phase 3 deliberately left SCSI ENABLED so the no-SCSI-Manager claim would be
observable rather than asserted -- gating it here would have destroyed the
test. The 64K ROM never scans the bus, never loads a driver, and never mounts
the volume, so a mounted SCSI disk is simply invisible. Two consequences:

- Phase 4 keeps its planned shape: build the gate for the 512Ke, then extend it
  to `configROMSize == 2'b00`. For the 64K models it is **accuracy only, not
  correctness** -- they already behave correctly with SCSI present.
- It confirms the earlier reasoning that the System-1.x-vs-SCSI failure seen on
  the Plus would NOT reproduce here, because the HFS mount is the ROM's doing
  and not the System's.

**PHASE 3 IS COMPLETE.** The Plus check is the one that mattered, because
this phase moved the ROM region underneath every model and turned `SIDES`
and the tachometer from constants into signals. It boots from the SCSI hard
disk and mounts **both 400K and 800K** diskettes, which covers all three:
the relocated ROM region (slot 0 reads correctly), the media gate still
admitting 819200 bytes when `drive800k = 1`, and the 800K drive path
(`SIDES` = 1, track-indexed tach, PWM ignored) behaving exactly as before.

The SE was not booted separately. Risk is low rather than zero: it takes
`drive800k = 1`, so its `SIDES` and tachometer behaviour is bit-identical to
the Plus's, and the ROM-region move is proven by the Plus reading slot 0 --
the SE's slot 1 is the same mechanism one slot along. Worth a boot when
convenient, but nothing in this phase treats the SE differently from the
Plus except `machineType`, which was not touched.

### Which 64K ROM is in `boot2.rom`, and the free slot 3

Both 64K models read **the same** `boot2.rom` -- the deliberate "one slot,
user's choice" decision, made because the two images differ by 57 of 65536
bytes and **none of them is a memory-map constant**. Confirmed in service: the
128K reports 128K and the 512K reports 512K from one shared ROM.

**Identifying the installed image takes two seconds** -- each ROM stores its own
checksum as its first longword, so `xxd -l 4 -p boot2.rom` gives `28ba61ce`
(Macintosh 128) or `28ba4e50` (Macintosh 512K).

**Slot 3 is free** if per-model ROMs are ever wanted: `rom_word_addr.v` handles
four slots and Main_MiSTer sends `boot0`..`boot3`, while only 0/1/2 are used. It
would be **accuracy only** -- the diff carries no memory-map difference -- so it
is a nicety, not a fix.

**INSTALLED IMAGE IDENTIFIED 2026-09-03: it is `28BA4E50`, the Macintosh 512K
ROM.** Verified byte-identical to the reference, with its own stored checksum
recomputing correctly (so intact, untruncated, right byte order through the
download path), and differing from the Mac 128 ROM by exactly the 57 bytes the
earlier diff found.

**That matters because one of those 57 bytes is not cosmetic.** The 512K ROM
changes `ORI #$0100,SR` to `ORI #$0300,SR` after loading the VIA address,
raising the interrupt mask so the SCC cannot interrupt a VIA access -- an Apple
bug fix aimed squarely at floppy I/O reliability, and writes are more
timing-sensitive than reads. It plausibly explains why floppy writes worked
first time.

**So the obvious fallback is already spent: do NOT "try the 512K ROM" if writes
ever misbehave -- it is already in use.**

**And the accuracy/reliability trade-off I recorded here does NOT exist.**
Checked 2026-09-03 rather than assumed: **Macintosh 128Ks were sold with the
`28BA4E50` ROM.** Apple moved to a **dual-use logic board** -- same part
numbers `630-0101` / `820-0086-C`, built with either 128K or 512K of RAM --
around the time the 512K entered production, and the 64K ROM went from revision
A (`342-0220-A`/`342-0221-A`, = `28BA61CE`) to revision B
(`342-0220-B`/`342-0221-B`, = `28BA4E50`) with it. Documented evidence includes
a 128K board carrying rev B ROMs beside a CPU date-coded **8504** (early 1985).

So `28BA4E50` is not "the 512K's ROM" -- it is **the second revision of the
shared 64K ROM**, and a 128K built from roughly late 1984 onward had it from
the factory. **Running it on our 128K is period-authentic, not a compromise**,
and there is nothing to revisit. Slot 3 plus `28BA61CE` would merely model an
*early-1984* 128K instead of a 1985 one; both are real machines.

Two things NOT established, so do not assert them: the exact rev A -> B
changeover date (one source says ~August 1984, another says the timeframe is
unclear), and whether Apple ever offered existing 128K owners a ROM-only
upgrade.

**Phase 4 - SCSI absence, for every model that needs it.** Items 9 and 5.
**Re-scoped 2026-09-04, after the Plus ROM was disassembled** -- see "CORRECTED
2026-09-04" above. `addrDecoder.v:119` HAS now been understood, and it turns the
phase from "build a bus error" into a strap:

- **Item 9, and it is the whole phase.** One new `mac_model.v` output says
  whether this machine has SCSI. `addrDecoder.v` consumes it twice: mirror the
  ROM at A17 = 1 when it is clear, and refuse to decode `$58xxxx` when it is
  clear. The mirror is what the Plus ROM actually tests, so it is what makes the
  512Ke authentic; the decode gate is belt-and-braces for third-party software
  that pokes the chip directly without asking `$0B22` first.
- **Item 7 drops out of the phase.** Not needed, and hazardous if built
  carelessly -- see the correction above.

Values: SCSI present on the Plus and SE, absent on the 512Ke, 512K and 128K.
The SE needs no special case (its 256K ROM fails the equality test on content).
The 64K machines never run the test at all, so for them item 9 is pure accuracy
-- their ROM window simply starts mirroring where it previously returned open
bus, which is what the real machines did.

**The 512Ke also gets exposed in the OSD as part of this phase.** `mac_model.v`
deliberately parked it at model 4, outside the listed range, because "it still
has SCSI, which is not an authentic 512Ke". That is the condition this phase
removes, so the model becomes real here and the CONF_STR list grows by one.

By this point the falsification test has already been run with SCSI enabled, so
nothing is lost by turning it off.

**CORRECTED 2026-09-03 (Daniel spotted it).** This phase previously said "a
512Ke boots System 6 from the HD20 image at s1", which contradicts the phase's
own goal: **a 512Ke has no SCSI**, so once the gate exists it cannot see s1 at
all. The criterion was also wrong on the image -- `s1` is `HD20.vhd`, a SCSI
disk at ID 5 holding **System 7.1**, which 512K of RAM could not run anyway.

How the error happened is worth recording, because the trap is reusable: the
file is *named* HD20, and the real **Apple HD20 was a 20 MB drive for exactly
these machines -- connected to the external FLOPPY port**, precisely because the
512K/512Ke had no SCSI. The name is period-correct; the inference from it was
not. This core does not emulate the floppy-port HD20, so:

**A 512Ke in this core is a FLOPPY-ONLY machine, and that is authentic** for a
512Ke without its optional external hard disk. Worth stating plainly because it
changes what "useful" means for the model -- Phase 4 removes the only mass
storage it currently has.

**System version support, corrected 2026-09-04:** the **512Ke runs System 6.0.x
up to 6.0.8**, which is its ceiling -- memory is tight but it boots. The
**512K** cannot run System 6 at all, because HFS lives in the 128K ROM it does
not have. Earlier text in this plan implying System 6 needs 1 MB and is out of
reach for a 512Ke was wrong.

**A cheap second witness for the 512Ke (Daniel, 2026-09-04).** In "About the
Finder", a 512K and a 512Ke are distinguished by a **trailing period**: `512K`
is a 512K, `512K.` is a 512Ke. That is worth having because it is independent of
the SCSI test -- it asks whether SOFTWARE believes it is running on a 512Ke,
where everything else in Phase 4 only establishes that the SCSI bus is absent.

**CONFIRMED ON OUR BUILD, 2026-09-04 (Daniel), under System 3: the 512Ke shows
the period and the 512K does not.** Our two models are correctly distinguishable
to software.

**It is SYSTEM-VERSION DEPENDENT: the distinction does not work under System
6.0.5.** Harmless here, since System 6 wants 1 MB and will not run on a 512K
anyway, but record it so that nobody re-running this test on a newer System sees
no period and concludes something has regressed. Use System 3.

**What it actually witnesses, stated precisely, because I over-claimed it when I
first wrote this down.** I called it "independent of the SCSI test -- it asks
whether SOFTWARE believes it is running on a 512Ke". That is too strong. The
512K runs the 64K ROM and the 512Ke runs the 128K ROM, so what the Finder is
almost certainly keying on is **ROM VERSION** (inference -- the About box is the
Finder's, and nobody has disassembled it to check). That makes it an excellent
discriminator for these two machines, because ROM version is precisely what
separates a real 512K from a real 512Ke -- but it is NOT independent evidence
about SCSI absence. What it confirms is that the model straps deliver the right
ROM to the right machine.

Same lesson as the yellow LED, applied rather than repeated: an indicator
witnesses what it witnesses, not what you hoped to test with it.

Hardware pass criteria: **a 512Ke boots from an 800K floppy** (System 3.x/4.x,
which is what the machine shipped with and has the RAM for -- System 6 wants
1 MB and is marginal at best on 512K), reports **512K** in "About the Finder",
and **finds no SCSI devices without hanging while it looks**. That last one is
the real test, since this is the only model whose ROM probes -- but note what
"looks" now means after the 2026-09-04 correction: with the mirror in place the
ROM decides at `$4003E4`, before it ever touches `$58xxxx`, so the expected
behaviour is that it never looks at all. A 128K still boots System 1/2/3 from
the 400K control image; Plus/SE unregressed, which after this phase means
checking they still see their SCSI disks, because the changed decode branch is
shared by every model even though only three of them alter behaviour.

**Phase 4 status: the 512Ke is HARDWARE-CONFIRMED, 2026-09-04, build
`d7df117e` (`output_files/MacPlus_d7df117e_phase4-512ke.rbf`).** Daniel:
boots from both 400K and 800K disks, reports 512K, and **totally ignores a
mounted SCSI disk**. Timing closed with room (worst setup +0.741 ns, worst
hold +0.201 ns, no negative slack), 19,872/41,910 ALMs.

**RETRACTED, same day: the yellow disk LED is NOT a SCSI indicator, and I
read it wrongly.** The 512Ke showed no LED flash on a CD mount attempt and
that was recorded here as "no sector request, exactly as predicted". Then a
128K DID flash a couple of times on the same action, which looked like an
inconsistency and is not one: `rtl/cd_audio.sv:36` documents `img_mounted`
as "mount pulse: (re)acquire the TOC", so every mount makes the CD audio
engine fetch the TOC over the HPS sector path (`ca_io_rd` -> `io_rd` ->
`sd_rd[4]`) with the 68000 not involved at all. That is SD activity, hence
yellow, on ANY model with SCSI fully gated -- `scsiPresent` is 0 for the
512K, 128K and 512Ke alike.

So the LED conflates Mac-driven SCSI with an autonomous TOC fetch and cannot
answer this question either way. Worse, the expected result on a SUCCESSFUL
mount is a couple of flashes, so the 512Ke's silence more likely means the
mount did not take (or the disc was already mounted, so no fresh pulse) than
that anything was demonstrated. **The CD half of the 512Ke result is
withdrawn; the SCSI-disk half stands, because that was observed as a volume
not appearing, not as an LED.**

Lesson worth keeping: an LED that several subsystems can light is not an
instrument. This is the second time this LED has misled --
[[mister-yellow-disk-led-monostable]] was the first.

**What the remaining result does NOT isolate:** gating `selectSCSI` alone
would produce the same observation, because an undecoded controller has
nothing to answer a probe with either way. The
hardware shows the MACHINE is authentic; the bench is what shows the MIRROR
specifically works, by asserting both probes resolve to the same ROM word.
Distinguishing the two halves on hardware would need `$0B22` read back over
JTAG, and it is not worth a probe deck change: the outcome is what the model
is for, and the Plus keeping its SCSI proves the strap is not simply stuck.

**PLUS REGRESSION PASSED 2026-09-04: the Plus still recognises its SCSI
disks.** And the retraction above is confirmed by the same session --
unmounting and REMOUNTING the CD in 512Ke mode does flash the yellow LED, so
the fresh mount pulse produces the TOC fetch on the 512Ke exactly as on the
128K. No model difference, which is what the RTL says.

**The Plus/SE check was over-billed as a risk, and the algebra says why.**
For any model with `scsiPresent = 1` the two changed conditions reduce to
their originals: `configROMSize[1] || address[17]==0 || !scsiPresent` becomes
`configROMSize[1] || address[17]==0`, and `address[19] && scsiPresent` becomes
`address[19]`. The Plus and SE decode paths are BIT-IDENTICAL to before the
change, so this test could not have failed on decode. It was still worth
running -- it confirms the STRAP is really 1 for the Plus, i.e. that
`mac_model` and the wiring are right -- but the phrase used at the time ("the
one that could actually invalidate the change") was wrong. Read the changed
expression before assigning risk to a regression test.

Not separately run, and low value for the same reason: the SE (identical
algebra to the Plus) and a fresh 128K boot of the 400K control image (the
128K was demonstrably running during the CD tests).

**Simulation status, `dcfbe62`.**
Items 9 and 5 landed together as one strap. `sim/tb_scsi_absence.v` gates it
end-to-end (24/24, written red first: 7 failures, exactly the three SCSI-less
models, with Plus and SE passing throughout), and `sim/tb_mac_model.v` grew the
five table rows (27/27). `sim/tb_rom_word_addr.v` (19/19) and
`sim/tb_sdram_map.v` (27/27) are unregressed.

What that does NOT yet prove is the thing only hardware can: that the Plus ROM,
running for real, reads the mirrored `$420000` and actually leaves `$0B22` clear.
The bench asserts the two probes resolve to the same ROM word, which is the
input to the ROM's compare -- not the ROM's conclusion. Until a 512Ke boots on
the DE10 and finds no SCSI, treat this as argued-and-simulated, the same
standing as defect C in [[macplus-scsi-pending-fixes]].

Three simulation traps were found writing that bench and are recorded in its
comments, because each one silently produces a PASSING bench rather than a
failing one: `addrController_top` has no reset so its bus counters stay X;
`@(posedge clk)` then testing `cpuBusControl` reads the pre-nonblocking value,
exits on a stale true and samples the video slot instead; and `mac_model` is
`always @(*)`, which iverilog evaluates only on an event, so setting `model` to
a value it already holds leaves every strap X -- and an X `configROMSize` then
poisons `macAddr[18]`, because Verilog `!=` returns x whenever either operand
has an x, even when another bit already differs.

## Phase 5 - HD20 / DCD, and it gates the release

**Daniel's decision, 2026-09-03: "there is no point releasing a core that
doesn't support it."** So floppy-port hard disk support is a **prerequisite for
releasing this branch**, not an optional extra, and Phase 4's floppy-only 512Ke
is an intermediate state rather than a shippable one.

The reasoning is sound: Phase 4 gates SCSI off to make the 512Ke authentic, and
in doing so removes the only mass storage that model has in this core. A 512Ke
that can only use floppies is accurate to the bare machine but not to how
anybody actually used one -- the HD20 was its hard disk.

**What it is.** The Apple HD20 (Sept 1985, 20 MB) connects to the external
floppy port using **DCD - Directly Connected Disk**, an Apple protocol that
shares the DB-19 connector with the floppy drive but nothing else. It was the
only drive ever to use it; SCSI arrived in 1986 and ended it.

**~~The risk profile is the opposite of Phase 3's.~~ WRONG, corrected
2026-09-04: APPLE'S OWN DCD SPECIFICATION IS PUBLIC.** This section used to say
DCD was never publicly documented, that there was no specification to read, and
that [[feedback-read-the-spec-for-historical-hardware]] "does not protect us
here". All three are false. Two internal Apple documents surfaced and sit on
Bitsavers at `bitsavers.org/pdf/apple/disk/hd20/`:

| file | size |
|---|---|
| `Directly_Connected_Disks_Specification_1.2a_May85.pdf` | 556K |
| `Software_Protocol_for_Directly_Connected_Disks_Mar85.pdf` | 234K |
| `IWM_Interface_PAL.pdf` | 275K |
| `HD-20_Tests_2.0.dc42` | 409K |
| `RO552_Patent.pdf` | 1.4M |

plus `firmware/` and `diag/` directories. The protocol is described as a
state-based command-and-response system with data carried in groups of 7
logical bytes encoded into 8 physical bytes -- which is a framing detail nobody
would have guessed from behaviour, and exactly the class of thing the standing
rule exists to stop us inferring.

**So the standing rule held after all, and the mistake was mine: I asserted the
absence of documentation without looking for it.** "Never publicly documented"
was true for decades and is no longer true; the docs surfaced and BMOW's HD20
work drew on them. Note the connection -- this core descends from Plus Too,
which is BMOW, so our own upstream ancestor is the leading DCD implementer.

**But the specs are NOT sufficient on their own, and that is the second
correction in one day -- do not over-correct twice.** BMOW, who used these very
documents to build the Floppy Emu's HD20 mode, reports that they conflicted with
each other in many details, were silent on critical points, and conflicted with
tests performed on a real Macintosh -- which forced Mac ROM disassembly to
resolve. So the first correction above ("the ROM is now the CORROBORATING
source, not the primary one") is itself wrong.

**The actual source hierarchy for this phase, in order of authority:**

1. **Real hardware behaviour** -- what the Mac and a real drive actually do.
2. **The 128K ROM** (`boot0.rom`, `4D1F8172`), which contains Apple's own DCD
   driver: the Mac's half of the protocol, first-hand, and the half we must
   satisfy. It arbitrates wherever the two documents disagree, because it is
   what actually shipped. The disassembly workflow is proven -- Sad Mac decoder
   and exception-vector map in Phase 3, boot search above.
3. **The two 1985 specifications**, which give structure, vocabulary and the
   framing nobody would infer -- but which contradict each other.

Read the specs FIRST anyway, because they make the ROM disassembly legible:
knowing to look for a 7-into-8 byte encoding and a state-based command/response
machine turns an unreadable driver into a recognisable one. Just never treat a
spec statement as settled when the ROM says otherwise.

**Second independent implementation to compare against: TashTwenty**, a
single-chip DCD (Hard Disk 20) interface, separate from the Floppy Emu and
discussed on 68kMLA. Two independent implementations plus Apple's own driver is
a far better position than the plan originally assumed.

### What the two 1985 specifications actually say

Downloaded 2026-09-04 to `C:\temp\Mac\HD20\` (from the `bitsavers.trailing-edge.com`
mirror -- bitsavers.org itself 403s a non-browser agent on file downloads, and
spoofing a User-Agent to get round that is not something to do). Both scans carry
an OCR text layer, extracted alongside as `.txt`, so they are greppable. OCR noise
is mild but real: `fmished`, `defmed`, `flISt`, and some table cells transposed --
check anything surprising against the page image before trusting it.

`Software_Protocol_for_Directly_Connected_Disks_Mar85.pdf` is by **Karl B. Young
and Michael Hanlon, version 1.1, 28 March 1985**, and is subtitled "7-for-8
version". "Rene" throughout is the drive's internal codename.

**Physical layer -- and the table below is CORRECTED FROM THE PAGE IMAGE,
2026-09-04, because the OCR shifted a whole column.** Read `may_p1.png`
(rendered with PyMuPDF -- see the rendering note further down), not the `.txt`.

| DB-19 | Macintosh name | DCD usage | Mac connection |
|---|---|---|---|
| 11 | PH0 | Phase0 -- handshake state bit 0 | IWM |
| 12 | PH1 | Phase1 -- handshake state bit 1 | IWM |
| 13 | PH2 | Phase2 -- handshake state bit 2 | IWM |
| 14 | PH3 | Phase3 -- "used to allow multiple DCD's" | IWM |
| 15 | /WrReq | **N/C** | |
| 16 | HDSel | **N/C** | VIA/6522 |
| 17 | /ENBL2 | **/Enable** | IWM |
| 18 | RD | **ReadData** -- "also connected to Sense on IWM" | IWM |
| 19 | WR | **WriteData** | IWM |

**~~The data path is HDSel out and /WrReq in.~~ WRONG, and it was my error, not
the document's.** The OCR ran the "DCD usage" column two rows out of step with
the pin numbers, so ReadData and WriteData landed on pins 15/16 instead of
18/19, and `/Enable` landed on PH3 instead of `/ENBL2`. Four rows of that table
were wrong. What the page actually says:

- **DCD uses the ORDINARY IWM data lines** -- RD (18) in, WR (19) out -- exactly
  the pins a floppy uses. It is not a repurposing of the data path at all.
- **`/WrReq` and `HDSel` are N/C.** So **SEL is unused by DCD**, and an earlier
  note here saying "SEL/HDSel is a VIA port A bit 5 line, not an IWM line, so
  our RTL must take it from the VIA" is **withdrawn**: the ROM's phase primitive
  does drive VIA PA5 as bit 1 of its nibble, but that is the *generic Sony*
  primitive, and every DCD call passes a nibble with that bit clear
  (`moveq #$D,d0` = `%1101`). The DCD engine should ignore SEL entirely.
- **`/Enable` is pin 17 (`/ENBL2`), the ordinary external-drive enable.** PH3 is
  a separate line used for daisy-chaining.

**What IS repurposed is only PH0-PH2**, from a drive-register address into a
3-bit handshake state bus, plus ReadData becoming bi-modal: serial data in
state 1, a constant sense level in every other state. The Mac is master
throughout. High bit of every byte always 1, net 428.38 kbps.

**This is good news for the RTL, and it is why the ROM writes bytes to the IWM
data register rather than bit-banging a VIA pin.** A DCD device is a peer of
`floppy.v` on the same byte-level interface the IWM already provides -- `ca0`,
`ca1`, `ca2`, `lstrb`, `_enable`, `writeData[7:0]`, `readData[7:0]` with bit 7
doubling as sense. No new physical modelling is needed.

**Correction, 2026-09-04: the clock is 7.8333 MHz, NOT 8.0, and the spec says so
explicitly.** "WriteData ... provides serial data transmission at 489.58K bps
(2.042 microsecond data cell). This is because the Macintosh clock is 7.8333
instead of a full 8.0 MHz." So the raw cell rate is 489.58 kbps and 428.38 kbps
is what survives 7-for-8. The distinction matters because the RTL must clock the
link off the same 7.8333 MHz the core already derives, not off a round 8 MHz.

**The state machine (PH0-PH2), states 0-7:**

- **6, 7, 5 -- the ID states.** After startup the Mac transitions through 6, 7
  and 5 to decide whether a drive is there and what type it is. A DCD that does
  not support further chaining must return 1 for states 5, 6 and 7 once the
  "next" DCD has been selected -- so-called **phantom states** -- which is how
  the Mac learns it has reached the end of the chain.
- **0-3 -- data transmission.** State 3 = Mac asserts it wants to transmit and
  senses the drive's /HSHK; state 1 = Mac sends a sync byte; state 2 = idle;
  **state 0 = HOFF (hold-off) asserted**.
- **~~Transitions are not necessarily adjacent -- the spec warns the Mac can go
  straight from state 0 to state 3.~~ EXACTLY BACKWARDS, corrected 2026-09-04.**
  The spec says the opposite: "Note that the phase lines can only change one at
  a time--one can't go instantly from state 0 to 3, for example." The Mac ROM
  confirms it -- every transition in the driver is a single `phNL`/`phNH` touch,
  and multi-step moves are spelled out one line at a time. So the DCD engine
  WILL see intermediate states and must not act on them as commands; only the
  settled value means anything.
- **Abort** = hold-off first (state 0), then de-assert HOST and HOFF together by
  going straight to state 2.

**7-for-8 framing.** Seven bytes of data for every eight transmitted. Sync bytes
are NOT encoded into any group, so a sync byte always has the high bit set.

**Sync and acknowledgement:**

- `$AA` -- sync for read/status/diagnostic commands
- `$96` -- sync for write and write-verify commands
- **Fast-NAK is always `$D5`**
- **Fast-ACK is the same value as the sync byte of the group just sent** (so an
  ACK to an `$AA` command is `$AA`). ACK and NAK are themselves sync bytes.

**Commands.** Reply opcodes are the command opcode with bit 7 set.

| op | command | from Mac | from drive |
|---|---|---|---|
| `$00` | MultiBlock Read | `<$AA><$00><count><block# 3B><pad><CHK>` | fast-ACK `<$AA>`, then count x `<$AA><$80><seq><stat><532 data><pad><CHK>`, seq from 0 |
| `$01` | MultiBlock Write | `<$96><$01><count><block# 3B><532 data><pad><CHK>` | fast-ACK `<$96>`, then count-1 x `<$96><$01><seq><3B pad><532 data><pad><CHK>`, seq from 1 |
| `$02` | Write-verify | as `$01` | as `$01` |
| `$03` | Status | `<$AA><$03><6 pad><CHK>` | `<$AA><$83><pad><stat><36-byte ID block><pad><pad><CHK>` = 42 bytes = 6 groups |
| `$04` | Diagnostic | `<$AA><$04><5 pad><CHK>` | fast-ACK `<$AA>`; subsequent commands follow a special diagnostic protocol |

Two deliberate design details the spec explains, both of which the RTL must
honour rather than tidy away: the **first write block ships with the command**
(to optimise one-block writes, "of which there seem to be a lot in the
Macintosh"), and there are **three pad bytes between the sequence number and the
data** on subsequent write blocks purely so the data lines up identically in
every write transmission.

**BLOCK SIZE IS 532 BYTES ON THE WIRE, NOT 512.** Stated in the command formats
and again in the identity block.

**But that does NOT mean images need 532-byte sectors -- I over-read this, and
the correction matters because it makes the storage side easy.** The 532 bytes
are 512 of data plus **20 tag bytes**: 12 of them the same tags floppies carry,
plus two further longwords specific to the HD20. **The Mac discards the tags**
and treats only the 512 as disk data, so an emulator need only fill 512 bytes
per block from the image and can prepend 20 zero bytes for the tags. That is not
theory -- it is what BMOW's Floppy Emu does, and it works: HD20 mode there takes
a plain raw `.DSK`.

So the earlier claim that "existing `.vhd` images are not reusable, the sector
size alone settles it" is **withdrawn**. Ordinary 512-byte-per-sector raw images
are fine, the existing HPS sector path can serve them unchanged, and the open
question shrinks back to what it always was: the LAYOUT (bare HFS volume versus
partitioned), not the sector size.

Treat "the Mac ignores the tags" as strongly evidenced by a working
implementation rather than as documented -- the ROM could still read them for
something, and that is cheap to check once the driver is located.

**Identity block, 36 bytes**, returned by Status. Fields (OCR transposed the
name/type column, so the pairing is reconstructed and should be checked against
the page image before it is coded): 13-character device name; **device code
`$000110`**; firmware revision; capacity in blocks; bytes per block = **532**;
cylinders = **610**; heads = **2**; sectors per track = **32**; possible spares;
number of spares; number of bad blocks.

**Hold-off, which is the flow control and matters for us.** The Mac may assert
HOFF anywhere within a group; that group is discarded and **excluded from the
checksum**; the drive acknowledges the hold-off immediately after the last byte
of the group; the drive then waits forever for HOFF to release, and resumes with
**the group that was interrupted**. The point of doing it per group is that an
SCC interrupt can be serviced at a group boundary without finishing the group.

**Timings worth designing to:**

- drive normally answers the Mac in ~14 us, **but may take up to 2 SECONDS while
  self-testing** -- the same class of trap as the CD spin-up window in
  [[macplus-cd-boot-scan-wedge]], and a reason not to treat a slow first
  response as a fault
- responds to HOFF release within 14-18 us; resumes transmission within 34 us
- signals end of transmission within 3 us of the last byte
- sends ACK/NAK 35-40 us after the handshake
- the drive waits forever for the Mac at several points -- deliberate, not a bug

**Two companion documents are referenced and are NOT in the bitsavers folder:**
"DB19/IWM to Rigid Disk Interface Specification" (dated 2/13) and "Notes on IWM
Rigid Disk Interface Meeting" (2/27). The March document says all three should be
combined "as soon as possible", which never happened. `IWM_Interface_PAL.pdf`
may cover some of the same ground -- not yet read.

### The PAL document: the drive's side of the phase lines

`IWM_Interface_PAL.pdf` is the HD20's own interface logic, not the Mac's -- a
**PAL 16R6 clocked at 7.5 MHz**, dated 12/13/84. Two facts about the real drive
fall out of it that the protocol document never states:

- The PAL sits between the host IWM and the drive side, watching the write-data
  lines of both. The document names the drive side "Nisha", and I first read
  that as the HD20 having its own IWM. **That reading is wrong: "Nisha" is a
  DRIVE MECHANISM, not an IWM** -- see the reassembly notes below. What the
  drive-side interface actually is remains unsettled between the two sources,
  and it is not on our critical path either way.
- **The controller is a Zilog Z8**; the PAL presents it with three decoded
  signals (Reset, HoldOff, Host) rather than raw phase lines.

Neither matters for emulation directly -- we implement the drive behaviourally,
not its silicon -- but they explain why the protocol is shaped the way it is,
and the phase decode below is authoritative for the state machine.

**Phase Line Control for "Renee"** (read from the page image; the OCR of this
table is unusable):

| Ph3 | Ph2 | Ph1 | Ph0 | Reset | HoldOff | Host | Data to Host |
|---|---|---|---|---|---|---|---|
| 1 | 0 | 0 | 0 | 0 | 0 | 0 | |
| 1 | 0 | 0 | 1 | 0 | 0 | 1 | |
| 1 | 0 | 1 | 0 | 0 | 1 | 0 | |
| 1 | 0 | 1 | 1 | 0 | 1 | 1 | |
| 1 | 1 | 0 | 0 | **1** | 0 | 0 | |
| 0 | 1 | 0 | 1 | | | | **0** |
| 0 | 1 | 1 | 0 | | | | **1** |
| 0 | 1 | 1 | 1 | | | | **1** |

The prose notes on page 2-3 agree with the table, which is worth saying out loud
given BMOW's warning that these documents contradict each other: `/RESET` when
the phase lines are `1100`, `/CMD` when `10X1`, `/HOLDOFF` when `101X`, read data
enabled when `10XX` -- all gated by `/ENABLE` low. So `/CMD` IS the "Host"
column, and data only flows in the `Ph3=1, Ph2=0` group, never in the ID states.

**The identification is a static level, not a transaction.** In states 5, 6 and 7
the drive holds Data-to-Host at **0, 1, 1** respectively. The "phantom states" of
a non-chaining drive -- all ones -- are therefore literally distinguishable from
a real drive's 0,1,1, which is exactly how the Mac finds the end of the chain.
This is the single most implementable thing in either document: it is the first
thing a DCD engine has to get right, and it needs no protocol at all.

Read-data pulses are a high-going pulse of **two clock periods** (at 7.5 MHz)
generated on each transition of either write-data line.

### Hunting the DCD driver in the ROM: inconclusive, and one trap

**The trap, recorded because it is a good one.** The DCD sync bytes are `$AA`,
`$96` and the fast-NAK `$D5`. Searching the ROM for places where all three
cluster looks like a perfect way to find the driver. It is not: **`$D5 $AA $96`
is the Apple GCR sector address prologue**, which this core's own
`floppy_track_encoder.v` emits. Five clusters were found and they are almost
certainly all floppy GCR tables. The protocol reuses the familiar constants, so
they cannot discriminate. Do not repeat this search.

**What was actually established, all of it negative:**

- **No dedicated driver name.** The Plus ROM's only disk driver string is
  `.Sony` (alongside `.Sound`, `.Print`, `.MPP`, `.ATP`, `.AIn`/`.AOut`,
  `.BIn`/`.BOut`). There is no `.HD20`-style name. If the ROM does speak DCD, it
  does so from inside `.Sony` -- which is plausible, since it is the same
  physical port, and it would mean an HD20's `DrvQEl` carries `ioRefNum = -5`
  like a floppy and needs nothing new from the boot search.
- **No 532 or 524 literal**, in either ROM, as an immediate operand.
- **No `HD20`, `Hard Disk`, `Rene`, `Nisha` or `Widget` text** in either ROM.

**This is suggestive, NOT conclusive, and must not be written up as a finding
yet.** A block size of 532 need never appear as a literal -- it can be built as
`512 + 20`, or fall out of a loop count, or live in a table. Negative searches
over hand-written 68000 code are weak evidence.

**The next step is therefore NOT more constant-hunting.** Three things to settle
first, cheapest first:

1. **Is HD20 boot support actually in the Plus ROM at all?** This has been
   assumed throughout the plan and never checked. If the DCD driver in fact
   shipped as the **HD20 INIT / system software on floppy**, then the Mac side is
   Apple's own loadable code and our job reduces to emulating the DEVICE
   faithfully -- which would be good news, but it changes "which models can boot
   it" completely, because a machine cannot boot from a disk whose driver only
   loads after boot.
2. **Follow `.Sony` instead of hunting constants.** The driver dispatches on the
   drive number / queue element; find where it decides a unit is not a floppy.
   That is a structural search rather than a needle hunt, and it is the same
   technique that found the boot search this morning.
3. **Check a later ROM.** If the SE or II ROM contains obvious DCD code and the
   Plus ROM does not, that dates the feature and settles item 1 immediately.

**ITEM 1 ANSWERED 2026-09-04 (Daniel, from 68kMLA): serial HD-20 support IS
built into ROM**, on the Macintosh **512Ke, Plus, SE, Classic, IIci and
Portable**. Forum-sourced, so not the standing of the Apple documents, but it
agrees with what this plan assumed and it is decisive in one respect: **the
driver is in the Plus ROM, so the negative searches above were simply too
weak** -- which is exactly why they were recorded as inconclusive rather than
written up as a finding. Drop the constant-hunting; use the structural `.Sony`
approach.

The list matters for scope too. The 512Ke and Plus both have it, so both of this
project's Plus-ROM machines can boot an HD20. The 128K and 512K are absent,
which fits: they would need the HD20 system software from floppy, and software
that loads after boot cannot boot you.

### FOUND: the DCD driver in the Plus ROM, disassembled (2026-09-04)

**The structural `.Sony` approach worked, first try.** No constant-hunting: the
name string is a driver header's Pascal name field, so finding the string finds
the header, and the header gives the entry points.

**Locating it.** `.Sony` occurs three times in every 128K ROM and once in each
64K ROM. The occurrence that is a driver name -- preceded by a `$05` length byte
and a full 18-byte `DCE` header -- is:

| ROM | driver base | Open | Prime | Ctl | Status | Close |
|---|---|---|---|---|---|---|
| Plus `4D1F8172` | `$417D30` | `$6E` | `$33A` | `$1E2` | `$2EC` | `$18` |
| 64K `28BA4E50` | `$401690` | `$50` | `$18C` | `$DA` | `$144` | `$B4` |

The other two Plus hits are name tables: `$40086F` next to `.Sound`, and
`$417829` in the `.MPP`/`.ATP`/`.Sony`/`.Sound`/`.Print`/`Chicago` list.

The Plus driver runs from `$417D30` to about `$419C60` -- **roughly 7.8 KB,
which matches the 6.6-7.4 KB `.Sony` `PTCH` on the HD20 startup floppy.** Two
independent artefacts agreeing on the size is good evidence that the ROM driver
and the floppy patch are the same body of code.

**The phase-line primitive, and it is SHARED with the 64K ROM.** `$4185C4` on
the Plus, `$401B5C` on the 64K, same semantics: one nibble in `d0` drives all
four lines.

| `d0` bit | line | how |
|---|---|---|
| 0 | PH2 | IWM `ca2H`/`ca2L` (`$A00`/`$800`) |
| 1 | **SEL** | **VIA port A bit 5** -- `bset`/`bclr #5, $1E00(a2)`, `a2` = VIABase (`$1D4`) |
| 2 | PH0 | IWM `ca0H`/`ca0L` (`$200`/`$000`) |
| 3 | PH1 | IWM `ca1H`/`ca1L` (`$600`/`$400`) |

`a0` = IWMBase, read from low memory `$01E0`. This confirms from the Mac side
what the pinout table says: **SEL/HDSel is a VIA line, not an IWM line**, and
the driver treats it as a fourth phase bit. Our RTL must take it from the VIA,
not the IWM.

The sense read is `$418600`: touch `q6H` (`$1A00`), read `q7L` (`$1C00`) into
`d0`, touch `q6L` (`$1800`), all inside `ori.w #$300,sr` so it cannot be
interrupted. **Bit 7 of that byte is the ReadData line.**

**THE ID PROBE, `$418630` -- and it matches both specifications exactly.**

```
418630  moveq  #$0D,d0        ; %1101 -> Ph2=1 Ph1=1 Ph0=1, SEL=0  = STATE 7
418632  bsr    $4185FE        ; set phases, read sense
418634  bpl    fail           ;   require bit7 = 1
418636  tst.b  (a0)           ; ca0L -> Ph0=0                      = STATE 6
418638  bsr    $418600        ; read sense
41863A  bpl    fail           ;   require bit7 = 1
41863C  tst.b  $200(a0)       ; ca0H -> Ph0=1
418640  tst.b  $400(a0)       ; ca1L -> Ph1=0                      = STATE 5
418644  bsr    $418600        ; read sense -> returned to the caller
418648  fail:  moveq #$FF,d0
```

and the caller in Open (`$417E42`) takes the DCD path only when that final
state-5 sense is **0**.

So the required levels are **state 7 -> 1, state 6 -> 1, state 5 -> 0**. That is
the third independent source to say so: the May protocol document's state table,
the `IWM_Interface_PAL` phase-decode table, and now Apple's own driver. **This is
the first thing the RTL has to get right and it is now beyond doubt.** The
polarity is straight, not inverted -- worth stating, because the adjacent floppy
probe at `$417E54` uses the opposite sense, since on a real Sony that address
selects a different status line entirely.

**State encoding settled: `state = {Ph2,Ph1,Ph0}` as a plain 3-bit binary
number.** Every transition in the driver is consistent with it -- see the reset
and end-of-transmission sequences below. This also means the plan's reading of
the hand-drawn PAL table (HOFF at `101X`, HOST at `10X1`, with Ph3 leading) does
not line up, and **the ROM wins**: it is the half we have to satisfy. The PAL
table is the drive's decode of the same lines and can be revisited if a
device-side question ever turns on it.

**DCD units are drive 3 and up.** Open probes drives in a loop on `d2`, and
`cmpi.w #$3,d2` splits it. Drives 1-2 get only a single state-7 "drive
connected" check -- the floppies -- and **`$418630` is called only for
`d2 >= 3`.** So an HD20 occupies drive-queue slots after the two floppies, which
is a concrete constraint on how the core presents it.

**THE 7-FOR-8 TRANSMIT ENGINE, `$419AC0`-`$419C3C`.** Unrolled across `d1`-`d4`
with `swap` for the second half. The per-byte motif is four instructions:

```
419AFC  move.b (a1)+,d4      ; next data byte
419AFE  add.b  d4,d5         ; running checksum
419B00  roxr.b #1,d4         ; shift right; the LSB falls into X
419B02  or.b   d0,d4         ; d0 = $80 -> set the MSB the IWM requires
419B04  swap   d4
419B06  roxr.b #2,d4         ; rotate that X into the LSB-accumulator byte
        tst.b (a3) / bpl .-2 ; a3 = q6L: wait for the IWM to want a byte
        move.b d4,(a0)       ; a0 = q6H/q7H: the IWM data register
```

**The checksum is a plain 8-bit sum of the DATA bytes, transmitted negated.**
`d5` accumulates `add.b` per byte, and the group closes at `$419BF0` with
`neg.b d5` before the same `roxr`/`or #$80` encoding. So `CHK = (-sum) & $FF`.
Neither specification states this in the text we have; the ROM does.

**Hold-off, and it is exactly what the spec describes.** `a5` is polled each
group (`tst.b (a5)`); a pending interrupt sets bit 31 of `d6`, and `$419B5A`
then does `tst.b -$1A00(a0)` = `ca0L`, i.e. **state 1 -> state 0, HOFF
asserted**. Resumption at `$419BC8` is `subq.w #1,d6` -- **back up one group** --
then `q7L`, `q6L`, `q6H`, `ca0H` (state 0 -> 1) and a fresh `$AA` sync. That is
"resume with the group that was interrupted", implemented.

**End of transmission, `$419C3E`:** `ca1H` takes state 1 -> 3, then it spins on
the `q7L` sense up to `$FF` times waiting for `/HSHK` high (error `$13` on
timeout), then `ca0L` takes state 3 -> 2, idle. That matches the spec sentence
for sentence.

**The reset sequence, `$419C6C`, and the long wait is real:**

```
ca2H, ca1L, ca0L      -> %100 = STATE 4 = RESET asserted
delay($3E8 = 1000)
ca1H                  -> %110 = state 6
ca2L                  -> %010 = state 2, idle
delay($4E20 = 20000)
then poll up to $640 = 1600 times, with delay($64 = 100) between each
```

A second site (`$419D18`) uses an `$4650` = 18000 iteration budget. **So the ROM
genuinely expects a drive that may take a very long time to answer after a
reset** -- the 2-second worst case in the protocol document and the ~15-second
power-on self-test in the Mac GUI article are both accommodated. This is the
same shape as the CD spin-up window in [[macplus-cd-boot-scan-wedge]], and the
lesson from there applies in reverse as well: a device that answers *too
eagerly* is as unlike the real thing as one that never answers. Do not tune this
by guesswork -- the budgets above are the numbers to design against.

**532 = 512 + 20 CONFIRMED FIRST-HAND.** At `$4196D0`/`$4196D6` the byte count
gets `addi.w #$14` -- **exactly 20 -- added**, and `$4196FA` then computes the
group count as `addq.w #6; divu.w #7`, i.e. `ceil(n/7)`. So the driver counts 20
tag bytes onto every 512-byte block and frames the result into 7-byte groups.
That upgrades the "512 data + 20 tags" split from inference-plus-secondary-
source to a fact read out of Apple's own driver, and it supports the 512-byte
image recommendation: the tags are added by the link layer, not stored.

**AND THE 64K ROMs HAVE NO DCD LINK LAYER -- the open question is closed, from
the ROM instead of from a forum.** The `roxr.b #1` / `or.b d0` encoder motif
occurs:

| ROM | occurrences |
|---|---|
| Plus `4D1F8172` | **8** |
| `28BA4E50` (512K) | **0** |
| `28BA61CE` (128K) | **0** |

Eight is the unrolled group. Zero is zero. The 64K ROMs do carry the *shared*
phase primitive and sense read -- those are the Sony driver's own -- but nothing
that frames a DCD group. **So HD20 boot support is 128K-ROM-only: the Plus and
the 512Ke, not the 128K or 512K**, which is what the forum report said and what
this plan assumed. It is now first-hand.

That also means the negative constant searches recorded above were not merely
"too weak" -- they were looking in the right ROM for the wrong kind of evidence.
The lesson stands as written: on hand-written 68000, search for STRUCTURE (a
driver header, an addressing idiom, an unrolled motif), never for constants.

**What this does NOT yet settle**, so the next disassembly pass has targets:

- the **receive** (8-to-7 decode) path -- in the same region, not yet read line
  by line
- how the driver builds and dispatches the command blocks (`$00` read, `$01`
  write, `$03` status), and where the identity block lands
- what the driver does with the 20 tag bytes on the read path: it clearly
  *counts* them, and "the Mac discards them" is still Floppy-Emu evidence rather
  than something read here
- the `$19C(a1)` / `$1C0(a1)` / `$1C2(a1)` state block in SonyVars (`$134`),
  which is where the per-unit DCD state lives

**Reproducing this.** capstone `CS_ARCH_M68K`, `CS_MODE_BIG_ENDIAN`, linear
sweep with `skipdata`, ROM base `$400000` -- the same technique as the Sad Mac
decoder in Phase 3 and the boot search below. Note one foot-gun: do not name the
driver script `dis.py`, because it shadows Python's own `dis` module and
capstone fails to import with a circular-import error that says nothing about
the real cause.

### The receive path, the command block, and one conflict with the spec (2026-09-04)

Second disassembly pass, picking up the four targets left open above. Three of
them are closed; the fourth turned into something more interesting than expected.

**The 8-to-7 decoder, `$4198C4`-`$41996E`, is the exact mirror of the encoder:**

```
4198C4  lsr.b  #1,d4       ; d4 = the LSB byte; its next LSB falls into X
4198C6  addx.b d1,d1       ; d1 = d1+d1+X = (received << 1) | that LSB
4198C8  add.b  d1,d5       ; running checksum on the DECODED byte
4198CA  move.b d1,(a1)+    ; store
4198CC  move.b (a3),d1     ; read the next byte from the IWM
4198CE  dbmi   d6,.-4      ; poll for it, d6 = $50 = 80 tries
4198D2  bpl    error $22   ; exhausted -> error $22
```

Transmit peels the LSB out with `roxr.b #1` and sets the MSB with `or #$80`;
receive shifts it back in with `addx.b dN,dN`. The group is **prefetched whole**
(`$419886`-`$4198AC` fills `d1`-`d4` with eight bytes) before decoding starts,
which is how the driver can consume the LSB byte first even though the drive
sends it last -- so the spec's awkward "LSB-byte first from the Mac, last from
the drive" asymmetry costs the receiver nothing. Our engine has to honour it.

**THE CHECKSUM IS NOW CONFIRMED FROM BOTH ENDS OF THE DRIVER.** The transmit
side sends `neg.b d5`; the receive side, at `$419A08`, simply does
`move.b d5,d0 / beq ok` -- **the sum of every decoded byte INCLUDING the received
checksum byte must be zero.** That is what `-sum` is for, and the two halves were
read independently, so this is no longer a single-site reading.

**The trailing partial group is decoded in full but stored in part.**
`$4199A0`-`$4199F6` unrolls all seven positions with `subq.w #1,d7 / bmi` guarding
only the `move.b dN,(a1)+`. So a short final group still contributes all seven
positions to the checksum. An implementer would very plausibly get this wrong.

**Error codes, recovered from the branch targets:**

| code | raised when |
|---|---|
| `$10` | sense low before a transmission even starts -- nothing there |
| `$11` | timeout waiting for `/HSHK` after asserting HOST (budget `$140000`) |
| `$13` | timeout waiting for `/HSHK` high at end of transmission (budget `$FF`) |
| `$22` | per-byte receive timeout (budget `$50`) |
| `$24` | resync failed -- 65536 tries hunting the `$AA` after a hold-off |
| `$25` | sense low at the end of a received group |
| `$26` | **checksum mismatch** |

**Hold-off on the receive side, `$419974`-`$41999E`, and it shows WHY hold-off
exists:**

```
419976  andi.w #$F8FF,sr   ; DROP the interrupt mask -- let the SCC be serviced
41997A  subq.w #1,d7       ; back up one group
419982  ori.w  #$700,sr    ; mask again
419986  tst.b  $200(a0)    ; ca0H: state 0 -> 1, release HOFF
419992  cmpi.b #$AA,(a3)   ; hunt for a fresh sync byte
419998  bra    $4198C4     ; re-decode the group from the top
```

**So the drive must retransmit the interrupted group from its start, preceded by
a fresh `$AA`.** That is the spec sentence "resume with the group that was
interrupted", made concrete -- and the RTL must implement retransmission, not
continuation.

**`a5` and `a6` are the SCC, which settles what hold-off is for.** `$419A2A`
does `movem.l $1D8.w,a5-a6`, so **`a5` = SCCRd (`$01D8`) and `a6` = SCCWr
(`$01DC`)**. Every `tst.b (a5)` scattered through both loops is a poll for a
pending serial character, and that is what triggers HOFF. The protocol document
says hold-off exists so "an SCC interrupt can be detected at the beginning of a
group and serviced"; the driver polls the SCC literally, in both directions.
Nothing about this is guesswork any more.

**THE COMMAND BLOCK, and it is exactly the spec's layout.** `$19C(a1)` onward in
SonyVars (`$134`), assembled at `$41967C`-`$419688`:

| offset | field | built by |
|---|---|---|
| `$19C` | **opcode** | `0` read, `1` write, `2` write-verify, `3` status, `4` diagnostic |
| `$19D` | block count, one byte | `move.b d3,$19D(a1)` |
| `$19E`-`$1A0` | **24-bit block number** | `move.l d5,d0 / lsl.l #8,d0 / move.l d0,$19E(a1)` |
| `$1A1` | pad | the zero left by that shift |

Six bytes, plus the sync and the checksum, is the eight-byte command the
protocol document specifies -- and it matches `HostCmndBuf`, which the firmware
reassembly independently reports as **8 bytes**. Three sources, one layout.

The `lsl.l #8` is worth noticing on its own: the block number is left-justified
in a longword so that the three bytes land in wire order. **It is a genuine
24-bit path with no truncation anywhere** -- which is the thing the >32 MB test
requirement above exists to catch, and it is reassuring that the Mac side was
built for it.

**Opcode numbering confirmed, and the tag bytes go on the DATA direction only.**
`$4196C2` reads `$19C(a1)` and splits on it:

```
cmpi.b #3,d1 ; bge  -> no adjustment      (Status and Diagnostic carry no data)
tst.b  d1    ; beq  -> addi.w #$14,d7     (READ:  +20 on the RECEIVE count)
             ; bne  -> addi.w #$14,d6     (WRITE: +20 on the TRANSMIT count)
then both:     addq.w #6 ; divu.w #7      (groups = ceil(n/7))
```

`d6` and `d7` are the transmit and receive byte counts, seeded at `$419694` with
`#$200` = 512 in one and zero in the other, swapped by direction with `exg.l`.
So **532 on the wire in whichever direction carries data, 512 in the image, and
Status/Diagnostic get no tag bytes at all.** The read-path tag question from the
previous pass is answered as far as counting goes: the driver reserves 20 bytes
and receives them; what it does with them afterwards is in the buffer handling,
not here.

**Transmit handshake, `$419A98`-`$419ABC`, matches the spec sentence for
sentence:** sense first (`$10` if dead), `ca0H` takes state 2 -> 3 asserting
HOST, spin until `/HSHK` goes low (`$11` on timeout), `ca1L` takes state 3 -> 1,
then the sync byte. The `$11` budget is `$140000` iterations of a four-cycle
loop -- **over a second at 7.8333 MHz**, which is the protocol document's
"up to 2 SECONDS while self-testing" showing up as a real number in real code.

**I WALKED INTO THE GCR TRAP THIS PLAN ALREADY WARNED ABOUT, and the warning
paid for itself.** Searching the driver for `#$96` -- the DCD write sync -- hits
`$419324`. It is **floppy GCR code, not DCD**: the same routine touches
`$DFFDFF` directly, indexes a 64-entry six-bit table at `$25A`, and runs a
`$2BE` = 702 byte count. Exactly the "`$D5 $AA $96` is the Apple GCR sector
prologue" collision recorded above. **The warning was right and it should stay
right at the top of anyone's Phase 5 reading.**

**AND THAT LEAVES A REAL CONFLICT WITH THE SPECIFICATION, which is recorded as
an observation and NOT yet as a conclusion.** In the whole DCD engine
(`$419700`-`$419E00`) there is **no `$96` anywhere**, and the only sync ever
transmitted is `$AA`, hardcoded at two sites -- the initial one at `$419AE2` and
the post-hold-off resync at `$419BE6`. Checked across all three Plus ROM
revisions:

| ROM | `$96` in the DCD engine | `$AA` written to the IWM data register |
|---|---|---|
| `4D1EEEE1` | 0 | 2 |
| `4D1EEAE1` | 0 | 2 |
| `4D1F8172` | 0 | 2 |

So it is not a revision quirk. The protocol document is explicit that write and
write-verify use a `$96` sync and that the fast-ACK echoes whichever sync was
sent -- yet this driver builds write commands (it adds the 20 tag bytes to the
transmit count for opcodes 1 and 2, so the write path is plainly reachable) and
still sends `$AA`. The receive side agrees with itself: both sync hunts compare
against `$AA` and nothing else.

**Two readings, and I have not yet distinguished them:**

1. The ROM driver is effectively read-only in practice, and write support is
   what the `.Sony` `PTCH` on the HD20 startup floppy adds. The command-block
   construction would then be shared code that the ROM never drives with
   opcode 1.
2. This implementation simply does not use `$96`, and the spec statement did not
   survive contact with the shipping driver -- which is precisely the class of
   thing BMOW warned about when they said the documents conflicted with tests on
   a real Macintosh.

**Either way there is an RTL consequence, and it is the safe one in both cases:
our DCD engine must accept `$AA` as the sync on a write and must not require
`$96`.** Accepting both costs nothing; requiring `$96` would deadlock against
Apple's own driver.

**How to settle it**, and it is the natural next artefact anyway: pull the three
`PTCH` resources out of the "Hard Disk 20" file on `HD_20_Startup.img` and
disassemble the `.Sony` one. It is a self-contained DCD driver with no floppy
code around it -- a better read than the ROM in several ways -- and it is the
half that a 512K uses, so it has to contain whatever the ROM lacks. That needs
an MFS reader plus resource-fork parsing, which is new tooling but small.

**Still open after this pass:** what the driver does with the 20 tag bytes once
received (it counts and stores them; whether anything reads them is a buffer
question, not a link-layer one), the identity block's landing site, and the two
bytes the transmitter sends between the sync and the first group -- they are
built as `(groupcount_tx | groupcount_rx << 16) + $810081`, i.e. each count plus
one with bit 7 set, which is not in the text the OCR gave us and wants checking
against the page images before anything is built on it.

### The `.Sony` PTCH, and the `$96` question is answered (2026-09-04)

**New tooling: `scripts/mfs_extract.py`** -- an MFS reader (list files, walk the
12-bit allocation chain, extract forks) plus a resource-fork parser. MFS is the
flat pre-HFS format of every 400K disk, so this is reusable well beyond Phase 5.
Don't re-derive it.

```
python scripts/mfs_extract.py HD_20_Startup.img
python scripts/mfs_extract.py HD_20_Startup.img "Hard Disk 20"
python scripts/mfs_extract.py HD_20_Startup.img "Hard Disk 20" PTCH 2 > sony.bin
```

**The three `PTCH` resources are exactly what the Mac GUI article said**, which
is a nice independent check on that secondary source:

| id | name | size |
|---|---|---|
| 0 | TFS | 24,758 |
| 1 | Dispatch Kernel | 290 |
| 2 | **`.Sony`** | **6,606** |

**THE `$96` HITS IN THE PTCH ARE BOTH FALSE, and one of them is the GCR trap for
the second time.** A raw byte scan finds `00 96` at `$E02` and `$106A`.
Disassembled:

- `$E00` is `move.b #$96,(a3)` inside a block that also touches `$DFFDFF`
  directly, indexes the 64-entry six-bit table at `$25A`, and counts `$2BE` =
  702 -- **the floppy GCR writer**, byte-for-byte the same code as the ROM's
  `$419324`. The PTCH is a whole `.Sony` replacement, so of course it carries
  the floppy driver too.
- `$106A` is not an instruction at all: it is the displacement of
  `bsr.w $1100` (`61000096`).

So the patch has **no DCD `$96` either**. The only sync it ever transmits is
`$AA`, at two sites (`$157A`, `$167E`) -- the same count and the same roles,
initial and post-hold-off, as the ROM.

**AND THE PATCH IS THE SAME CODE AS THE ROM, WHICH KILLS ONE OF THE TWO
READINGS.** Byte comparison against the Plus ROM:

| ROM region | bytes | found in the PTCH |
|---|---|---|
| transmit prologue `$419A40` | 48 | yes, at `$14D8` |
| ID probe `$418630` | 26 | yes, at `$54A` |

Sweeping the whole driver in 32-byte windows, 25% match verbatim, in two long
contiguous runs: `$4192D0`-`$4193D0` (the floppy GCR writer) and
**`$419AB0`-`$419C30` (384 bytes -- the DCD transmit engine, containing BOTH
sync sites)**. The remaining 75% is the same logic with different displacements,
which is what two builds of one source look like after relocation; the parts
that match exactly are precisely the tight register-only inner loops that carry
no addresses.

**Therefore reading 1 above is dead.** The ROM driver is not a read-only subset
that the patch completes -- the patch *is* the driver, it is what a 512K uses
for full HD20 support including writing, and its transmit engine is byte-
identical to the ROM's. There is one transmit engine and it sends `$AA`.

**Reading 2 stands: Apple's shipping DCD implementation does not use the `$96`
sync.** The protocol document says write and write-verify use it; the code that
actually shipped, in both builds, does not. This is exactly the category BMOW
warned about when they said the documents conflicted with tests on a real
Macintosh, and it is why the source hierarchy in this plan puts the ROM above
the specifications.

**State this honestly, because it cuts the other way too: this is now ONE
implementation seen in TWO BUILDS, not two independent witnesses.** I went into
this pass expecting the patch to be an independent implementation and it is not,
so it does not corroborate the spec being wrong -- it only shows that the one
implementation we must satisfy never sends `$96`. That is enough for the RTL
requirement and not enough for a claim about the protocol in general.

**RTL REQUIREMENT, now firm:** the DCD engine **must accept `$AA` as the sync on
write and write-verify commands, and must never require `$96`.** Accepting both
is free; requiring `$96` deadlocks against Apple's own driver. Whether a real
HD20 would also have accepted `$AA` is a question about the drive, not about us,
and the firmware reassembly could answer it if it ever matters -- a bounded
question of exactly the kind that file is worth opening for.

**The genuinely independent check, if one is ever wanted**, is the other
direction entirely: BMOW's Floppy Emu and TashTwenty are DRIVE-side
implementations written by other people, and what they accept as a write sync
would corroborate or contradict this. Not needed before the RTL, because the
requirement above is safe under either answer.

**Unchanged and still open:** the two bytes the transmitter sends between the
sync and the first group, built as `(tx_groups | rx_groups << 16) + $810081`.
They are in the byte-identical run, so both builds agree, but nothing in the OCR
text explains them. Check the page images before building anything on them.

### The two bytes after the sync: ANSWERED, and by two independent sides (2026-09-04)

Checked before building, on Daniel's instruction. The answer needed all three
sources and none of them alone would have given it.

**Rendering the page images needs no new software.** PyMuPDF (`fitz`) is already
installed and is what produced `pal_p5.png`; poppler/`pdftoppm` is not present
and is not needed. The scans are **JBIG2**, so `pypdf` cannot extract them and
PIL is not installed -- go straight to `fitz`:

```python
import fitz
d = fitz.open(pdf)
d[i].get_pixmap(matrix=fitz.Matrix(2.2, 2.2)).save('p%d.png' % (i+1))
```

**A titling bug in the March document, worth knowing before anyone reads it.**
Pages 3 and 4 are **both titled "Data Transmission From Mac to Drive"**. Page 4
is the real one -- it ends with an `ack` on the Data line, and its notes say
"René will send ACK/NAK 35-40us after handshake" and "last byte received".
**Page 3 is Drive-to-Mac**: its notes say "René will send sync within 33us" and
"last byte of the group is sent". Saved as
`C:/temp/Mac/HD20/mar85_p3_drive_to_mac.png` and `mar85_p4_mac_to_drive.png`.
A concrete instance of the unreliability BMOW warned about, in the title of a
figure rather than anywhere subtle.

**The timing figures this plan recorded all check out against the images**, and
now each is attached to the right direction:

| | Mac -> Drive (p4) | Drive -> Mac (p3) |
|---|---|---|
| first response | 14 us, **up to 2 s during self test** | -- |
| sync | drive waits forever for a valid sync | drive sends sync within 33 us |
| holdoff acknowledged | after last byte **received** | after last byte **sent** |
| holdoff release | responds within **14 us** | within **18 us** |
| resume | starts with the interrupted group | ...within **34 us** |
| end of transmission | drive acks within 3 us of last byte | drive signals within 3 us |
| ACK/NAK | **35-40 us after handshake** | -- |

Both pages also state the rule this plan already had: a held-off group **"will be
ignored and will not be included in the checksum"**, and transmission resumes
**with** the interrupted group. Plus one detail not recorded before: the Mac
receives the end-of-transmission signal **one byte time later** than the drive
raises it.

**THE DIAGRAMS DO NOT SHOW THE TWO BYTES.** Both Data waveforms are
`sync` -> `data`, with nothing between. So the protocol document does not
describe them anywhere -- not in the text, and not in the figures the OCR lost.

**But they are real, and the ROM uses them in BOTH directions.** The receive
prologue at `$419852` hunts the `$AA` (timeout `$10000`, error `$21`), then
reads **two bytes before any group data**:

```
41984C  cmpi.b #$AA,(a3)     ; hunt for sync
419856  move.b (a3),d1       ; FIRST byte after the sync
41985E  cmpi.b #$BF,d1       ; special case -> d7.high = 6
41986A  move.b (a3),d1       ; SECOND byte after the sync
419874  move.b (a3),d2       ; ...then the group
```

symmetric with the transmitter's `$AA`, then `d6 + $810081` low byte, then its
high-word byte.

**THE DRIVE FIRMWARE SETTLES IT, and this is the first genuinely INDEPENDENT
corroboration in the whole phase.** `342-0343-B.asm` at `L1da2` (line 2941) is
the Z8's host-receive routine:

```
L1da2   ld  R9, #0AAh        ; the expected sync byte
        ld  >52h, #07Fh      ; two working bytes, pre-set to $7F
        ld  >53h, #07Fh
L1dc1   lde R8, @RR0
        cp  R8, R9           ; hunt for $AA
        jr  Z, L1dce
L1dce   lde R8, @RR0         ; wait for a byte with the MSB set
        or  R8, R8
        jr  PL, L1dce
        and >52h, R8         ; FIRST byte  -> mask off the MSB, keep 7 bits
L1dd7   lde R8, @RR0
        or  R8, R8
        jr  PL, L1dd7
        and >53h, R8         ; SECOND byte -> same
```

**So the two bytes after the sync are the GROUP COUNTS, one per direction, each
sent as `$80 | (count + 1)` and recovered by masking with `$7F`.** The Mac side
builds them with `+$810081` on a longword holding both counts; the drive side
ANDs each into a byte pre-loaded with `$7F`. Two different CPUs, two different
teams' code, same framing -- and unlike the ROM-versus-PTCH comparison, these
really are independent implementations.

The reassembly's author did not know what they were either: `DefsHD20.inc`
line 192 is literally `; ??? EQU 053h`. So this is a small genuine addition to
what is publicly understood about DCD, not something recovered from a label.

**What the RTL must do:** after the `$AA` sync, emit or consume **two count
bytes** before the first group -- transmit count first, then receive count, each
`$80 | (groups + 1)`. Do not build a framer that goes straight from sync to
data; both real implementations would reject it.

**Two things still not explained, and neither blocks the RTL:**

- **`cmpi.b #$BF,d1`** on the Mac's receive path, which sets `d7.high = 6` when
  the drive's first count byte is `$BF`. `$BF` masks to `$3F` = 63, so it would
  mean 62 groups. Whether that is a real count or a sentinel is not yet clear;
  it is one branch and it can be traced when the read path is implemented.
- **`BlockLength EQU 524+2+6`** in `DefsHD20.inc` -- the drive's own block is
  524 data + 2 CRC + 6 ECC = 532. That is the same 532 as the wire, but split
  differently: 524 = 512 + the 12 standard Sony tags, with CRC and ECC making up
  the rest, whereas the wire's 532 is described everywhere else as 512 + 20 tag
  bytes. **Flag, do not build on it.** It does not disturb the 512-byte image
  recommendation, because the Mac only ever sees the 512 either way -- but the
  two decompositions should be reconciled before anyone writes tag handling.

### CORRECTION: the count bytes are Mac-to-drive ONLY (2026-09-04)

**I got the receive side wrong in the section above and it is corrected here
before any RTL was built on it.** The claim was that the ROM "reads two bytes
after the sync on the receive side too, symmetric with the transmitter". It does
not. Counting the byte reads between the sync hunt at `$419852` and the decode
loop at `$4198C4` gives **eight**, into `d1,d1,d2,d2,d3,d3,d4,d4` -- and the
decode then opens with `lsr.b #1,d4`, consuming the **eighth** byte as the LSB
byte. That is a whole-group prefetch, and it confirms the specification's
"when sending data from the DCD to the Macintosh, the LSB-byte is sent last".

So the framing is **asymmetric, and both sides' code agrees on the asymmetry**:

| direction | after the sync |
|---|---|
| **Mac -> drive** | **two count bytes**, then groups of 8 -- **LSB byte first**, then 7 data |
| **drive -> Mac** | groups of 8 straight away -- 7 data, then the **LSB byte last** |

**And that asymmetry makes sense of what the count bytes are for.** They carry
the group count in *each* direction: the Mac tells the drive how many groups it
is about to send and how many it expects back. The drive has no need to tell the
Mac anything, because the Mac already knows both numbers -- it computed them at
`$4196FA`/`$419704` before the transfer started. So one direction carries them
and the other does not, which is not an inconsistency but the obvious design.

The evidence for the count bytes themselves is unaffected and still comes from
two genuinely independent sides: the Mac transmitter builds them with
`+$810081`, and the drive firmware's host-receive routine (`L1da2`) masks
exactly two bytes with `$7F` before reaching its LSB byte. Only the claim of
symmetry was wrong.

**`cmpi.b #$BF,d1` is therefore not a check on a count byte.** It tests the
FIRST TRANSMITTED BYTE OF THE FIRST GROUP from the drive, and sets `d7.high = 6`
when it matches. Still unexplained, still one branch, and still cheap to trace
when the read path is implemented -- but it is a different question from the one
recorded above.

**How the error happened, since it is worth not repeating.** I found two reads,
stopped counting, and matched them against a pattern I had just established on
the transmit side. The prefetch is unrolled with `swap` between each pair, so
the first two reads look like a preamble and the rest look like the loop body.
**Count the whole unrolled sequence before naming it** -- the same discipline the
transmit engine needed, where six `roxr` steps and two register halves are one
group and not two.

### The link layer, as it will be built

Everything above, reduced to what `rtl/dcd.v` has to do. Nothing here is new;
this is the specification the bench is written against.

**Phase decode.** `state = {ca2,ca1,ca0}`, plain binary, one line changing at a
time. `lstrb` is PH3 (daisy-chain select) and **SEL is ignored** -- see the
corrected pinout.

**Sense, driven onto `readData[7]` whenever the device is not sending data:**

| state | sense | meaning |
|---|---|---|
| 7 | **1** | drive connected |
| 6 | **1** | (# sides on a Sony) |
| 5 | **0** | this is a DCD, not a Sony |
| 4 | -- | RESET asserted; device performs a power-up reset |
| 3 | /HSHK | HOST asserted, Mac sensing |
| 2 | /HSHK | idle |
| 1 | -- | data mode; `readData` carries transmitted bytes |
| 0 | /HSHK | HOFF asserted |

**/HSHK is idle-HIGH, asserted-LOW**, which the ROM pins down three ways: the
transmit entry errors `$10` if sense is 0 at idle, then spins `bmi` waiting for
it to fall; the end-of-transmission spins `bpl` waiting for it to rise; and the
receive entry refuses to start unless it is already 0.

**Every transmitted byte has its MSB set, and that is what makes the IWM work
for us.** `iwm.v` latches `readData` on `newByteReady` and clears the latch
after a read; the driver polls with `dbmi`, looping while the value is
non-negative. A byte with the MSB clear would be indistinguishable from an empty
latch. So the MSB rule is not a quirk of the IWM's write side -- it is the
data-ready signal on the read side, and the framing depends on it.

**Checksum:** an 8-bit sum of the *decoded* data bytes, sent as `(-sum) & $FF`.
The receiver validates by summing everything including the checksum byte to zero.

**A DCD device is a peer of `floppy.v`**, on the interface the IWM already has:
`ca0`, `ca1`, `ca2`, `lstrb`, `_enable`, `writeData[7:0]` + `writeReq`,
`readData[7:0]` + `newByteReady`. No new physical modelling, because DCD uses
the ordinary RD and WR lines.

### RTL stage 1: `rtl/dcd_link.v`, 30/30 and mutation-tested (2026-09-04)

The link layer only -- phase decode, the ID states, /HSHK, 7-for-8 coding both
ways, the checksum, and hold-off. The command layer (Status, MultiBlock Read,
MultiBlock Write) and the storage back end sit on top and are next. The module
header carries the reasoning; this is the record of what was gated and how.

**Not yet instantiated anywhere, and deliberately so.** `MacPlus.sv`, `iwm.v`,
`files.qip` and the `.qsf` are untouched, so nothing in the built core changes
and no Quartus compile is implied. Integration is its own step, and adding the
file to the build before it is instantiated would only synthesise dead logic.
Remember when that step comes that this project's `.qsf` and `files.qip`
disagree about which files exist -- see [[macplus-qsf-quartus-gui-pollution]].

**`sim/tb_dcd_link.v`: 30/30 under iverilog.** The vector that matters most is
free: the May specification works a full group by hand in Figure 1, giving
data `$31..$37` -> `$98 $99 $99 $9A $9A $9B $9B` with an LSB byte of `$D5`, and
it states the Mac-to-DCD order explicitly as `$D5 $98 $99 $99 $9A $9A $9B $9B`
-- LSB byte first, which is exactly this module's receive direction. **So the
decoder is asserted against Apple's own worked example rather than against my
reading of the prose.** The same vector does double duty: its bytes sum to `$72`
rather than zero, so it must be REJECTED, which proves the checksum actually
fires. A checksum that never rejects is the classic silent pass.

**Twelve mutants, all caught** (baseline 30/30):

| mutation | score |
|---|---|
| RESET state ignored | 28 |
| ID state 5 senses 1 | 29 |
| ID state 6 senses 0 | 29 |
| LSB bit order reversed | 29 |
| checksum not negated | 27 |
| checksum never rejects | 27 |
| TX shift direction wrong | 25 |
| sync byte `$96` not `$AA` | 21 |
| absent device reports DCD | 28 |
| hold-off does not rewind | 28 |
| `rxLen` off by one | 29 |
| group count off by one | 23 |

**Two bugs the bench caught that inspection had not**, both worth recording
because both are the kind that survive a good-path test:

- `rxLen` was set from `rxCount` before the last byte had been counted, so
  every command came out one byte short.
- The group count is `$80 | (groups + 1)`, and I had treated the recovered
  value as "groups remaining AFTER this one", so a single-group command sat
  waiting for a second group that never came. Every decode was correct and
  nothing ever completed -- which looks like a link fault, not an arithmetic
  one.

**And one gap the mutation sweep caught in the BENCH itself.** The first
version of the RESET test asserted `txBusy == 0` and `/HSHK` high after
entering state 4 -- from idle, where both were already true. Removing the
state-4 case from the module entirely still scored 30/30. The test now starts a
transfer, gets two bytes out of it, and only then asserts RESET, plus a second
assertion that the receiver still frames a fresh command afterwards. **A test
whose precondition is already satisfied is not a test**, and only the mutation
sweep says so.

**One mutant fails by TIMEOUT rather than by assertion** -- removing the
hold-off check in `TX_DATA` entirely, which hangs the bench waiting for a sync
that never comes. That is a detection, but a poor one; if that path is ever
reworked, give it a bounded assertion instead.

**Deferred to the command layer**, with what is known already recorded above:
the identity block is now fully pinned down from the page image -- 13 + 3 + 2 +
3 + 2 + 2 + 1 + 1 + 3 + 3 + 3 = **exactly 36 bytes**, and the field widths are
in the March document's `ID_Block` record on pages 1-2. Two document errors to
carry forward: the Status command is drawn with SIX pad bytes, which makes it 8
bytes and not a whole group, where MultiBlock Read and Diagnostic are both 7
and the ROM's own command block is 6 + checksum = 7; and the read response is
drawn as 537 bytes, which is not a whole number of groups either, while the ROM
computes exactly 76 groups = 532. **The ROM arbitrates, per this plan's source
hierarchy** -- but neither has been resolved yet, and the read path should not
be built until they are.

### Both length questions settled -- and the count byte finally has semantics (2026-09-04)

**The answer came from the DRIVE FIRMWARE, not the ROM**, and it is exact.
`342-0343-B.asm` masks the first count byte with `$7F` into `$52`, then:

```
ld   R10, >52h        ; the masked count byte
...
djnz R10, L1e53       ; ... used DIRECTLY as the group loop counter
```

**So the count byte is `$80 | the TOTAL number of groups in the transmission`,
and the receiver simply loops that many times.** The Mac builds it as
`dataGroups + $81`, where the `+1` is the group the command itself rides in.
Checks out both ways: a MultiBlock Read carries no outbound data, so the Mac's
`d6` is 0 and the byte is `$81` = one group = the command; a MultiBlock Write
has `d6` = 532 -> 76 data groups and the byte is `$CD`, masked `$4D` = 77 = the
command group plus 76 of data.

This is the third time the firmware has answered something the Mac side could
only hint at. It keeps earning its place as an arbiter for bounded questions.

**QUESTION 1 -- the Status command is 7 BYTES, ONE GROUP.** For a Status the
outbound data count is zero, so the count byte is `$81` and exactly one group
goes out. The March document draws Status with **six** pad bytes, which makes 8
and is not a whole group; Diagnostic is drawn `<$04><5-byte pad><CHK>` = 7 and
MultiBlock Read `<$00><count><block# 3B><pad><CHK>` = 7, and the ROM's own
command block at SonyVars+`$19C` is 6 bytes plus the checksum = 7. **Four
converging reasons: the Status drawing has one pad too many.** Build it as
`<$03><5 pad><CHK>`.

**QUESTION 2 -- there is NO CONTRADICTION, and the error was mine.** I had set
"the spec draws 537" against "the ROM computes 532" as if they were the same
quantity. They are not. The ROM's 76 is the number of groups needed for the
**532 data bytes**; the count byte then adds one for the group carrying the
response header, giving **77 groups = 539 byte-slots**, into which the
specification's 537-byte response (`<$80><seq><stat><532 data><pad><CHK>`) fits
with two slots of padding. Both sources agree and neither needs correcting.

That leaves the framing for the read path fully determined: **the drive replies
with a sync and 77 groups.**

**What did NOT settle, and it is flagged rather than guessed.** At `$419D2C`
the Status path loads `move.l #$14C,d7` -- 332 -- which reconciles with a
42-byte response under no reading I tried. Two reasons not to force it: `$19C`
also takes the values `$19` and `$1A`, which are not DCD opcodes at all, so
that byte is not purely an opcode; and the routine dispatches through
`$4196AC`, which is `move.l $b44.w,-(a7); rts`.

**Which is the real ceiling here: the driver dispatches through vectors
installed in low memory at runtime** -- `$B44`, `$B48`, and `$198(a1)` -- so
static disassembly cannot follow the command layer's control flow the way it
followed the link layer's. The link layer was tractable because it is a
straight-line unrolled loop; the command layer is not. **Further command-layer
questions should be answered by simulating against the real ROM, or from the
firmware, not by more static reading.** Note this before spending another
session on the disassembly.

### The bug this immediately found in `rtl/dcd_link.v`

`rxGroups <= writeData[6:0] - 7'd1` was **one group short on every multi-group
frame**. It is exactly right for a single-group command, which is why 30/30
passed: every frame in the bench was one group. A write, or any read response,
would have lost its last group and failed the checksum.

Fixed to `rxGroups <= writeData[6:0]`, and the bench grew a **two-group frame**
that catches it (the old code now scores 30/33). **33/33, ten mutants all
caught**, including the original bug and both directions of the adjacent
off-by-one:

| mutation | score |
|---|---|
| the original bug (`count - 1`) | 30 |
| `count + 1` | 23 |
| end-of-frame test off by one | 23 |
| ID state 5 senses 1 | 32 |
| LSB bit order reversed | 31 |
| checksum never rejects | 30 |
| checksum not negated | 30 |
| TX shift direction wrong | 28 |
| RESET state ignored | 31 |
| hold-off does not rewind | 31 |

**The lesson is the one this project keeps relearning, in a new costume.** A
seam that only breaks past a boundary, with nothing in the test set crossing
it -- the same shape as the SDRAM region alias, the A17 forcing that had never
executed, and the 16-bit block-number ceiling this plan already warns about
above. **Every frame being one group was the same blindness as every volume
being under 32 MB.** Cross the boundary deliberately, in the bench, before the
hardware does it for you.

### RTL stage 2: `rtl/dcd.v`, the Status command, 19/19 (2026-09-04)

The command layer over the link layer. Status (`$03`) is implemented; MultiBlock
Read, Write and Write-Verify need the HPS sector path and are next. Still not
instantiated anywhere -- `MacPlus.sv`, `iwm.v`, `files.qip` and the `.qsf` are
untouched, so no compile is implied.

**THE IDENTITY BLOCK IS TAKEN FROM A REAL HD20's FIRMWARE, not reconstructed
from the prose.** `342-0343-B.bin` holds it as a template at `$00B7`, and the
first five fields decode exactly:

| offset | field | value |
|---|---|---|
| 0..12 | NameString | **`'Rene-1 RM MH '`** -- 13 chars, no terminator, trailing space included |
| 13..15 | Device_Type | **`$000210`** |
| 16..17 | Firmware_Rev | **`$3372`** |
| 18..20 | Capacity | `$009835` = 38,965 blocks = 20.0 MB |
| 21..22 | Bytes_per_block | **532** |

**`$3372` is what proves this is the ID block**, because the reassembly's own
header calls itself "Rev. 3372" -- an independent label on the same number. And
`$009835` is exactly one more than `DefsHD20.inc`'s
`HiMaxLogical/MidMaxLogical/LoMaxLogical` = `$009834`, "highest user block", so
capacity is a count and the block numbering is zero-based.

**From byte 23 the template decodes to nonsense -- 36,657 cylinders, 16 heads,
230 sectors -- and that is the finding, not a decode failure.** The stored
template ENDS after `Bytes_per_block`. It has to: the firmware detects Nisha or
Rodime from the servo response at run time, so it cannot hold fixed geometry.
Everything from `Num_cylinders` on is filled in live.

**One discrepancy, recorded not resolved:** the March document's comment says
`{ Device code = $000110 }`; the drive sends **`$000210`**. The firmware is the
device, so it wins here, but if a host is ever seen to reject us this is the
first constant to try flipping.

**Two deliberate choices, both stated in the module rather than defaulted into:**

1. **Geometry is Rodime RO552 -- 305 cylinders, 4 heads, 32 sectors.** The
   protocol document's example describes Nisha (610/2/32), but it is not clear
   the HD20 ever shipped with one and production units were Rodime. Both work
   out to 305*4*32 = 610*2*32 = **39,040** blocks, which is why the capacity
   reconciles either way and why the host almost certainly does not care.
   `DefsHD20.inc` carries both mechanisms' constants, which is what let this be
   a choice rather than a guess.
2. **Capacity is the mounted image, not the 20 MB a real unit had.** Large
   volumes are convenience rather than accuracy, but the protocol was built for
   them -- capacity and block number are both 24-bit -- and the ceiling is HFS,
   not DCD.

**`sim/tb_dcd_status.v`: 19/19, twelve mutants all caught.** It drives a real
Status command onto the wire, frames it exactly as the Mac does (sync, two
count bytes, one group with the LSB byte first), then decodes the six-group
reply the way the ROM's receive path does and checks every field.

**And the mutation sweep caught another bench gap, of exactly the kind that
keeps recurring here.** Shortening the payload by one byte -- `txLen` 41 to 40 --
scored a clean 19/19 at first. The reason is worth keeping: **summing to zero
does not pin where the checksum SITS.** With the payload one short, the
checksum lands at offset 40 and a zero pad at 41, the frame is still six whole
groups, and the sum still closes, so every existing assertion held. The bench
now pins all three trailing bytes -- `<pad> <pad> <CHK>` -- and the mutant
scores 18/19.

That is the third bench gap this phase found by mutation rather than by
inspection, and all three have the same shape: **an assertion that is true for
the right reason and also true for the wrong one.**

**One mutant fails by TIMEOUT rather than assertion** -- lengthening the payload
by a byte, which makes the reply seven groups while the bench reads six and
then waits. Detection, but poor; the same note applies as in the link bench.

**Not answered, and not answerable from this test:** whether the Mac accepts
this identity block. Everything above is what a real drive sends, so there is
good reason to expect it, but the only real gate is the ROM itself -- and per
the note above, the command layer's control flow goes through runtime-installed
dispatch vectors, so that gate is simulation against the real ROM or hardware,
not more static reading.

### STOP: we built Phase 5 on the WRONG SPEC REVISION (2026-09-04)

**Found while starting MultiBlock Read, by reading the sources before designing
the framing -- [[feedback-read-the-spec-for-historical-hardware]] paying for
itself again. `C:\temp\Mac\HD20\` holds TWO specifications, and everything above
was built on the earlier one.**

- `Software_Protocol_for_Directly_Connected_Disks_Mar85.pdf` -- Young & Hanlon,
  **version 1.1, 28 March 1985**. What this plan has been quoting throughout.
- `Directly_Connected_Disks_Specification_1.2a_May85.pdf` -- **version 1.2a,
  May 1985** (KBY, dated 4/11 in the page footers). Read here only for the
  handshake/sync question; **its command formats were never read, and they
  differ substantially.**

**THE SHIPPING PLUS ROM IMPLEMENTS 1.2a.** Four independent confirmations, all
from disassembling `$419600`-`$419E40` of `4D1F8172` with capstone:

| # | site | what it shows | 1.1 | 1.2a |
|---|---|---|---|---|
| 1 | `$419716 ori.b #$40,$19C(a1)` | subsequent write blocks carry opcode **`$41`** | `$01` | **`$41`** |
| 2 | `$4197EE subq.b #1,d3`, checked at `$41978C cmp.b $19D(a1),d3` | reply seq **counts DOWN** from #blks to 1 | up from 0 | **down** |
| 3 | the byte accounting below | reply header is **6 bytes** | 4 bytes | **6** |
| 4 | `$419D2C move.l #$14C,d7` | Status identity block is **332 bytes** | 36 | **332** |

**THE BYTE ACCOUNTING, and it closes exactly.** `$4196FA`/`$419704` do
`addq.w #6,dN / divu.w #7,dN / andi.w #$7F,dN`. `divu` leaves the quotient in the
low word and the REMAINDER in the high word, and the receiver uses both:
`d7.low` is the whole-group loop (`dbne d7,$4198C4`) and `d7.high` is the number
of bytes to store from the trailing partial group (`$4199A0` onward). So for a
data byte count `n` the Mac reads `q+1` groups and **stores exactly `n+6`
bytes** -- the `+6` is the reply header. Checks out on both directions:

- **read**, `n` = 512+20 = 532: `q`=76, `r`=6, so 77 groups on the wire = 539
  slots, and the payload is `<$80><seq><stat><pad><pad><pad>` + 532 + `<CHK>` =
  **539 exactly, no padding**. 1.1's 4-byte header needs two slots of pad; 1.2a
  fits perfectly.
- **status**, `n` = 332: `q`=48, `r`=2, so **49 groups** = 343 slots, storing
  338 = 6 + 332.

**AND THE BUFFER-SWITCH COUNTERS INDEPENDENTLY CONFIRM THE 6, AND SETTLE THE TAG
ORDER.** Both directions switch from the command block to the caller's data
buffer at **byte 26 = 6 header + 20 tags**:

- receive: `$4198BC moveq #3,d6 / swap d6`, then the `dbra d6` at `$419932` sits
  after the 5th store of the group -> switches at 3*7+5 = **26**.
- transmit: 6 bytes are prefetched in the prologue (`$419A42`-`$419A94`), then
  the `dbra d7` at `$419B88` with `d7`=2 (`$419AC8`) sits after the 6th fetch of
  the group -> 6 + 2*7 + 6 = **26**.

**So the 532 is `<20 tag bytes><512 data>`, tags FIRST.** That was an open
question and it is now answered from the driver's own pointer arithmetic.

**`move.l #$14C,d7` FINALLY HAS A MEANING.** This plan recorded it as
"reconciles with a 42-byte response under no reading I tried". It does not
reconcile because **the Status reply is not 42 bytes**: `$14C` = 332 is the
identity block length, and the reply is 49 groups. Corroboration from the same
routine: `$419CC4` installs a pointer to `$1F0(a1)`, which is `$1F0-$1C4` = 44
bytes into the Status buffer at `a4` = `$1C4(a1)`, i.e. identity offset
20+44 = **64** -- exactly where 1.2a's `ID_Block` puts `Icon`, and exactly what
the Mac GUI article meant by "the HD20's icon lives in the controller's
firmware".

**1.2a's `ID_Block`** (the OCR transposes the columns; order reconstructed, and
the sizes sum to 512 which is what the document's own "Filler bytes to make it
512 bytes" requires):

| offset | field | size |
|---|---|---|
| 0 | Device_Type | word |
| 2 | Device_Manuf | word (Apple = 1) |
| 4 | Device_Character | byte |
| 5 | Num_Blocks | 3 bytes |
| 8 | Num_Spares | word |
| 10 | Num_BadBlocks | word |
| 12 | Manuf_Reserved | 52 |
| **64** | **Icon** | 256 |
| 320 | Filler | 192 |

Device characteristics bits: `Mountable $80`, `Readable $40`, `Writable $20`,
`Ejectable $10`, `Write-protected $08`, `Icon Included $04`, `Disk In Place $02`.

**1.2a also replaces the bare `$D5` fast-NAK with a NAK FRAME**,
`<$AA><$7F><5 pad><CHK>` -- one group -- and has the drive answer each write
block with `<$AA><$81><seq><stat><3 pad><CHK>`, also one group, rather than with
a bare fast-ACK.

**TWO MORE RTL CONSEQUENCES, both from the drive firmware and both cheap to get
wrong:**

- **The drive sizes its reply from the Mac's SECOND count byte.**
  `342-0343-B.asm` `L1ead` does `ld R2, 53h` -- the second post-sync byte,
  masked to 7 bits -- immediately before sending the `$AA`, and the transmit
  loop ends `dec R2 / jr NZ`. So the drive sends exactly the number of groups
  the Mac asked for. **`rtl/dcd_link.v` currently CONSUMES AND DISCARDS that
  byte** ("the command layer decides that from the opcode"); it must expose it,
  and the command layer should honour it rather than hardcoding lengths. That is
  also what makes us robust across driver revisions.
- **The checksum is always the LAST SLOT of the LAST group.** In the same loop,
  when `R2` hits zero the drive emits `com R4 / inc R4` -- the negated running
  sum -- as the **7th** data byte of that group, and then the LSB byte. So
  padding goes BEFORE the checksum, not after. Our link layer places `CHK` at
  `txLen` and zero-pads after it: numerically equivalent, since the pads are
  zero and the Mac sums all seven positions of the trailing group, but it does
  not match the drive. Fix by setting `txLen` to fill whole groups so `CHK`
  lands last.

**WHAT THIS INVALIDATES.** `rtl/dcd.v`'s Status command is built to 1.1: 41
payload bytes, 42 on the wire, 6 groups, and the 36-byte `'Rene-1 RM MH '` block
lifted from the firmware template at `$00B7`. The 128K ROM asks for **49 groups
and a 332-byte 1.2a-layout block**. The firmware template is genuine but
**March-era**, and reading it was not the mistake -- building the reply from it
was.

**And note what the 19/19 gate was worth here: nothing.** `sim/tb_dcd_status.v`
frames the command and decodes the reply using our own understanding of the
protocol, so it asserts our framing against itself. Twelve mutants caught, and
not one of them could have caught "the whole revision is wrong". **A bench built
from the same reading as the RTL cannot test that reading.** The only gate that
would have caught it is the ROM, which is why the next one has to be simulation
against the real ROM, or hardware.

`rtl/dcd_link.v` is believed unaffected -- sync, count bytes, 7-for-8, the
checksum and hold-off are the same in both revisions -- but the count-byte
plumbing above is a change to it.

**NEXT, in order:**

1. **Settle the 332-byte block from a drive-side implementation before coding
   it.** 1.2a leaves `Device_Type`, `Device_Manuf`, the 52 reserved bytes and
   the icon content undetermined, and 332-64 = 268 against a 256-byte `Icon`
   field leaves 12 bytes unaccounted (a `where` Pascal string is the obvious
   guess, and it is a guess). **TashTwenty and BMOW's Floppy Emu are drive-side
   implementations by other people** -- this plan already named them as the
   independent cross-check -- and either would settle all of it at once.
2. Rewrite `rtl/dcd.v` Status to 1.2a; plumb the second count byte through
   `rtl/dcd_link.v`; make `CHK` land in the last slot. Re-gate and re-mutate.
3. Then MultiBlock Read, whose framing is now **fully determined**:
   `<$AA>` then 77 groups of `<$80><seq><stat><pad><pad><pad><20 tags><512
   data><CHK>`, with `seq` counting DOWN from the block count to 1.

**Reading order from here on: 1.2a is the specification, 1.1 is history.** Where
the two conflict, the ROM has agreed with 1.2a every time it has been asked.


### Step 1 settled: the identity block, from three independent implementations

**Done 2026-09-04. Every open question in the STOP note above is now closed, and
the answer is not a reconstruction: three implementations that have no author in
common all frame the Status reply identically.**

**First, I re-derived the ROM evidence rather than trusting the note.** The four
disassembly sites hold up, and two of them are worth restating because they are
what makes the rest safe:

- `$419D2C move.l #$14C,d7` sits inside `cmpi.b #$3,$19C(a1) / bne`, so 332 is
  specifically the Status data length, and `$419D3E lea $1C4(a1),a4` is the
  buffer it lands in.
- `$4196C2`-`$4196FA` is the length arithmetic in full, and it explains the
  `+20` this plan spent so long on. `d1` is the opcode; **`addi.w #$14,d7` is
  reached only when `d1 == 0`** (Read, tags added to the RECEIVE count) and
  `addi.w #$14,d6` only when `d1` is 1 or 2 (Write, tags added to the TRANSMIT
  count). Status takes `bge` at `cmpi.b #$3,d1` and **gets no tags at all** --
  which is why its 332 is a bare identity block where a read's 532 is
  `<20 tags><512 data>`.

**The 26-byte buffer switch is now read off the instructions, not inferred.**
`$4198BC moveq #3,d6 / swap d6` presets the group counter to 3, and the seven
`move.b dN,(a1)+` stores of a group sit at `$4198CA`, `$4198E0`, `$4198FA`,
`$41990C`, `$419924`, then `$419930 swap d6 / dbra d6,$419938 / movea.l a4,a1`,
then `$419940` and `$419954`. The switch is therefore after the **5th** store of
the **4th** group -- 3*7+5 = **26** -- and it is **unconditional**, with no
opcode test anywhere near it. That single fact carries the whole layout:

> For Status there are no tags, so reply byte 26 is identity byte **20**, and
> the icon the driver publishes from `$419CC4 lea $1F0(a1),a2` is at
> `$1F0-$1C4 = 44` into the buffer, i.e. identity offset **20+44 = 64**.

**Then the cross-check the STOP note asked for, and it is unanimous.**

| | header | identity | tail | frame |
|---|---|---|---|---|
| Plus ROM `4D1F8172` | 6 | 332 read | -- | 49 groups |
| **TashTwenty** (Tashtari, PIC16F1704) | 6 | 332 written | 4 pad + CHK | 49 groups |
| **Floppy Emu** (BMOW, 2014) | 6 | 336 struct | CHK | 49 groups |

BMOW and TashTwenty differ only in where they draw the line between "identity
block" and "frame padding" -- BMOW's `padding[16]` at 320 is TashTwenty's
12-byte trailer plus the 4 pad bytes. **The bytes on the wire are the same 343.**
Both are known to mount on real hardware, which is the gate our own bench cannot
be.

**`Directly_Connected_Disks_Specification_1.2a_May85` is WRONG about the length,
and this is worth keeping.** Its Status page says in as many words that the ID
block "need be only 288 bytes long, but a total of 532 bytes are still sent".
The shipping ROM asks for 332, and the drive obeys the count byte rather than
the document. So even the correct revision of the specification does not
describe the shipping behaviour -- **the ROM outranks both documents**, and the
only reason we can say that with confidence is that two other people's working
implementations agree with the ROM and not with the paper.

**The settled layout.** 6-byte header, then:

| offset | field | size | what we send |
|---|---|---|---|
| 0 | `Device_Type` | word | 0 |
| 2 | `Device_Manuf` | word | 1 (Apple) |
| 4 | `Device_Character` | byte | `$F6` |
| 5 | `Num_Blocks` | 3 | highest block = capacity-1 |
| 8 | `Num_Spares` | word | 0 |
| 10 | `Num_BadBlocks` | word | 0 |
| 12 | `Manuf_Reserved` | 52 | 0 |
| 64 | `Icon` | 256 | 128 icon + 128 mask |
| 320 | trailer | 12 | `\pMiSTer HD20` -- the DRIVE NAME the Finder shows; see below |

= 332. Header `<$83><blks><stat><pad><pad><pad>`, then 4 pad, then `CHK` in the
**final slot of the final group**: 6+332+4+1 = 343 = 49*7.

**`Device_Character = $F6`** is Mountable+Readable+Writable+Ejectable+
Icon_Included+Disk_In_Place. The 1.2a bit values are confirmed by TashTwenty
using exactly this constant. **Ejectable is the one bit I am not sure of** -- a
fixed disk arguably should not set it, and TashTwenty's own comment writes it
`ejectable (?)`. It is set here because $F6 is the value known to mount; `$E6`
is the one-bit experiment if the Finder ever behaves oddly about unmounting.

**`Num_Blocks` is capacity MINUS ONE, and this is the one field held on
someone else's empirical result rather than on a document.** TashTwenty
decrements it with the comment "it appears that the block size of the drive is
actually the maximum block on the drive / TODO look into this further". The DCD
driver in the Plus ROM never reads the field -- I checked every reference to
`$1A2`-`$1AB` across `$419600`-`$419E40` and there is none -- so it is consumed
further out and I cannot settle it from the ROM. **Minus one is the safe
direction whichever reading is right**: if the Mac wants a count we lose one
block of a volume, whereas if it wants a maximum and we send a count it can
address one block past the end.

**Step 2 done: `sim/tb_dcd_status.v` 36/36, and this time the bench is a
reimplementation of the Mac's receiver rather than a mirror of our transmitter.**
Three things in it are derived rather than typed, which is the whole point:

- `macGroups()` is `addq.w #6 / divu.w #7` + 1 from `$4196FA`, and the count
  byte is that or'd with `$80` because `$419ADC` adds `$81` to both halves of
  the pair at once. **Feed it 332 and 49 falls out; the number 49 is nowhere in
  the bench.**
- The reply is unpacked through the ROM's own two-buffer split at byte 26, so
  identity offsets are reached the way the driver reaches them.
- The icon is read at `$1F0`, an address the ROM computes for itself.

**MUTATION SWEEP: 25 mutants, 22 killed, 3 provably equivalent.** The three
survivors are all no-ops rather than gaps -- moving the icon FIELD boundary by
two bytes changes nothing because the icon's first two bytes are blank top
margin, and the two header-boundary mutants only reshuffle which `else if`
returns the same zero. The faithful four-byte-header mutant, which shifts every
offset together, **is** killed.

**The sweep found four real holes, all in the BENCH, none in the RTL** -- the
third time this project has had that result, and worth the same note as before:

- **The icon test was tautological.** `iconByte(i) === identity(64+i)` reduces to
  the same `rsp[]` subscript on both sides, so it held however the reply was laid
  out; a mutant moving the icon two bytes scored full marks. It is now pinned by
  CONTENT at a known phase -- eight blank rows, then row 8's `3F FF FF FC` -- and
  that is also what kills the four-byte header.
- Nothing checked the trailer at all.
- "Every icon pixel is inside the mask" passes trivially when the mask is a copy
  of the image, which would give a hollow, unclickable desktop icon. The mask now
  has to be strictly larger somewhere.
- Blanking part of the icon went unnoticed.

**What this gate still cannot do is what the last one could not: prove the
revision is right.** It is a stronger bench, not a different kind of evidence.
The evidence that 1.2a is correct is the ROM plus TashTwenty plus Floppy Emu;
the bench only proves we implement what we read. **Simulation against the real
ROM, or hardware, remains the next real gate.**

**Three things that are settled but belong to later steps:**

- **NAK is a frame, not a byte.** TashTwenty answers a bad checksum with
  "a blank one-group command buffer with a command number of `$7F`", which is
  1.2a's `<$AA><$7F><5 pad><CHK>` exactly.
- **The continued-write opcode is `$41`**, dispatched as such by TashTwenty and
  produced by the ROM's `ori.b #$40,$19C(a1)`.
- **The reply's second byte is the block count, not a bare sequence number.**
  TashTwenty copies the command's block count straight into it for a read; the
  ROM compares it against a counter that walks DOWN to 1. For Status both ends
  make it zero, so it is untested until MultiBlock Read.

**And the group count really is the Mac's to choose.** TashTwenty sizes its
whole reply buffer from `RC_RSPG & $7F` -- the second count byte -- before it
writes a single field into it, and the HD20's own firmware does `ld R2, 53h` for
the same purpose. So the drive is a slave to the count in both real
implementations, and `rtl/dcd.v` should be too rather than hardcoding 49.


### Step 3 framing: MultiBlock Read, settled from both ends before coding

**Read the protocol out of the ROM's receive loop and TashTwenty's read loop
before writing any of it, per [[feedback-read-the-spec-for-historical-hardware]].
Both agree, and three details are not what the STOP note assumed.**

**ONE COMMAND, N SEPARATE FRAMES.** `$419712` is the per-block loop, and its
first instruction is `tst.b d1 / beq $419754` -- **for a read (opcode 0) it
returns immediately without transmitting anything**. Only a write re-transmits
per block. So the Mac sends the Read command once and then calls the receive
engine `$41980E` N times, each call hunting a fresh `$AA`. TashTwenty's
`CmdRea0` loop matches exactly: read a block, `movlw 77 / movwf GROUPS`,
checksum, `Transmit`, `decfsz TX_BLKS,F`, loop.

**Each frame is 77 groups**: `<$AA>` then
`<$80><blks><stat><pad><pad><pad>` + `<20 tags>` + `<512 data>` + `<CHK>`
= 6+20+512+1 = 539 = 77*7, no padding. TashTwenty hardcodes the 77 rather than
taking it from the count byte -- only its Status path uses `RC_RSPG` -- but the
Mac asks for 77 anyway (`d7` = 512+20 = 532, `(532+6)/7+1` = 77), so sizing from
the count byte as `rtl/dcd.v` now does gives the same answer.

**THE TAGS ARE FIRST AND THEY ARE NOT IN THE CALLER'S BUFFER.** Confirmed three
ways now, and from the receive side this time: `$4197AA` copies 12 bytes from
`$1A2` to the caller's tag pointer and `$4197B8` copies 20 bytes from `$1A2` out
to `$2FC/$300/$304/$38A/$38E`, so the tags land in the command-block scratch --
which is reply bytes 6..25, exactly the region before the 26-byte buffer switch.
TashTwenty points its data pointer at `0x2062` = buffer + 26 with the comment
"past the six header bytes and the 20 'tag' bytes". And `$1B6`, the amount
`$4197E8` advances the caller's data pointer by after each block, is set at
`$4196BA` **before** the `+$14` is added, so it is 512 and not 532.

**THREE THINGS THAT ARE EASY TO GET WRONG:**

1. **The reply opcode does not echo the continued-write bit.** `$41975E` masks
   the expected opcode with `andi.b #$3F` before comparing, so a command of
   `$41` must be answered `$81` and **not** `$C1`. TashTwenty answers every
   write with `0x81` whether the command was `$01` or `$41`. Answering `$C1`
   fails the `$419776` comparison and errors $30.
2. **`blks` counts DOWN from N to 1, and the first frame carries N.**
   `$41978C cmp.b $19D(a1),d3` happens **before** `$4197EE subq.b #1,d3`, and
   TashTwenty's `decfsz TX_BLKS,F` sits **after** its `Transmit`. A mismatch is
   error $31.
3. **Status bit 7 is the error flag, and $0A is a second one.** `$4197DA
   btst #$18,d0` on the longword at `$19E` tests bit 7 of the status byte, and
   `$4197E0` separately rejects a status of exactly `$0A`. TashTwenty's failure
   path is `bsf TX_STAT,7` plus a one-group reply, which is the same convention.

**THE ONE THING NEITHER SOURCE SETTLES: what goes IN the 20 tag bytes.** They
are the file-system block tags of the MFS/HFS era, which a real HD20 stores on
the medium alongside each block. A plain disc image has nowhere to keep them,
and **TashTwenty does not solve this either** -- its `CmdRead` carries a bare
`;TODO clear 20 tag bytes too?` and ships whatever the buffer held. Sending
zeros is the honest choice and is strictly better than TashTwenty's stale
buffer; the Mac copies them to `$2FC` onward but the ROM does not validate them.
**Recorded as a known deviation, not an oversight.**

**STILL OPEN, and it is the real work rather than the protocol: the HPS sector
path.** Everything above is framing; none of it moves a byte off the SD card.
That needs a mount slot, `hps_io` wiring and a sector buffer, and it is the
first part of Phase 5 that touches files outside `rtl/dcd*.v`.


### Step 3 built: the sector path, MultiBlock Read, and the first integration

**Done 2026-09-04, `1db34fa` + `d9a43bd` + `cd2a6f3`. This is the first part of
Phase 5 that touches anything outside `rtl/dcd*.v`.**

**`rtl/dcd_disk.v` -- one sector buffer and one hps_io slot.** Byte addressed on
the command side, so the command layer never has to think about lanes. Three
things in it are not decoration:

- **The byte lanes are not a free choice.** The HPS packs disk byte 0 into
  `sd_buff_dout[7:0]`, so even bytes go to `buffer0`. `rtl/scsi.v` is the
  hardware-proven precedent and is the reference for byte order anywhere on
  this core. Getting it backwards transposes every pair, which no checksum in
  DCD would catch and nothing notices until a filesystem fails to mount.
- **`sd_buff_wr` is shared across every slot** and is qualified with our own
  `sd_ack`, or another slot's transfer lands in our sector.
  `rtl/floppy_loader.v` guards it for the same reason.
- **An unanswered request times out.** Without that, a stalled HPS leaves the
  drive holding /HSHK forever, which the Mac sees as a hung bus rather than as
  a failed command.

The buffer is `scsi_dpram`'s shape **copied rather than instantiated**: a DCD
device has to work on a **512Ke**, a machine defined by having no SCSI at all,
and depending on `rtl/scsi.v` for a RAM primitive would tie the two together
for nothing and drag 1700 lines into the bench.

**MultiBlock Read works exactly as the framing section above says**, and the
bench proves each frame end to end against a block-device model. Two details
that only showed up in the building:

- **A failed fetch is ANSWERED, not dropped** -- one group, status bit 7, which
  is TashTwenty's error path verbatim and exactly what `$4197DA btst #$18,d0`
  looks for. `blksLeft` is deliberately NOT reset on that path, because the ROM
  checks the block byte against its own counter FIRST (`$41978C`, error $31)
  and only then reads the status, so zeroing it reports the wrong failure.
- **A zero-block read is not a command** and is dropped like any unimplemented
  opcode.

**THE INTEGRATION DECISION, and it is a real deviation.** `rtl/iwm.v`
instantiates the DCD as a peer of `floppy.v` on the same byte interface, with
`_enable` = `~diskEnableExt`, and **it REPLACES the external floppy while a DCD
image is mounted**. A real HD20 daisy-chains a floppy behind itself -- PH3
selects down the chain, which is why `rtl/dcd_link.v` takes `lstrb` at all --
and we do not. That is this plan's stated shape ("occupies the external drive
slot"), and the deviation is recorded here rather than buried.

**What makes it safe is the other half:** the mux is on `dcdPresent`, so with no
DCD image mounted the external port is bit-identical to what it has always
been. `sim/tb_iwm_latch.v` passes unchanged with the DCD instantiated, which is
the regression that matters.

**GATES.** `tb_dcd_link` 33/33, `tb_dcd_disk` 37/37, `tb_dcd_status` 36/36 (its
capacity now comes from a real mount rather than a bench-driven port),
`tb_dcd_read` 22/22. Mutation: 15/16 and 16/17 killed, both survivors
demonstrably equivalent.

**AND THE SWEEPS FOUND FIVE MORE HOLES, ALL IN THE BENCHES, NONE IN THE RTL.**
That is now the rule and not the exception on this project. The two worth
keeping:

- **Holding a buffer address for two clocks hid whether the byte-lane select is
  pipelined alongside the registered RAM output.** Only a byte-per-clock walk
  tells them apart, and the real consumer will eventually do exactly that.
- **Nothing made the host stall, and that hid a genuine race.** A frame does not
  reach its first data byte until 26 byte-times in -- thousands of clocks -- so
  a drive that starts transmitting *without waiting for its fetch* is correct
  against any prompt host and only fails when the SD card is slow. The bench
  now stalls the host deliberately, with the previous block still in the buffer
  so serving late is detectable as serving stale.

**FIRST COMPILE OF THE PHASE.** Quartus analysis and elaboration clean, 0
errors, and the hierarchy really is there
(`emu|dataController_top:dc0|iwm:i|dcd:dcd0`). Its only connectivity notes are
the write path that does not exist yet -- `wr_req`, `buf_d`, `buf_we` stuck at
GND and `readonly` dangling -- plus the parts of `rxBuf` a one-group command
never reaches.

**WHAT IS LEFT, and it is now a short list:**

1. **MultiBlock Write.** The blocker is not the command layer, it is the LINK
   layer: a write's first block rides WITH the command, so `rxBuf`'s eight
   bytes are nowhere near enough and `rtl/dcd_link.v` has to stream received
   data into the sector buffer instead. Opcodes `$01`, `$02` and the continued
   `$41`, answered `$81` and never `$C1`.
2. **Hardware bring-up**, with `HD Diag` (ReneDiag) first -- it exercises the
   link without needing the file system, the driver patch or a bootable volume.
3. The OSD greying already deferred, which can ride this phase's build.


### Hardware bring-up: the artefacts, and the order to use them

**Assembled 2026-09-04, before the first board test. Everything named here is on
disk and verified; nothing below is a plan to go and find something.**

**THE DIAGNOSTIC FLOPPIES ARE IN HAND.** `C:\temp\Mac\HD20\diag\`, fetched from
bitsavers (**via `bitsavers.trailing-edge.com` -- `bitsavers.org` itself answers
403 to a plain fetch**), each a 400K DiskCopy 4.2 image whose **data and tag
checksums both verify**, all four distinct, each converted to a raw `.img`
beside its `.dc42`:

| image | volume | boots | carries |
|---|---|---|---|
| **`HD20_SEP_85.img`** | HD 20 STARTUP | yes | **`HD Diag`**, `HD 20 Test`, `Hard Disk 20` |
| `HD_20_Test.img` | HD 20 test | yes | `HD Diag`, `HD 20 Test`, `DiskTimerII` |
| `HD-20_Tests_2.0.img` | HD-20 Tests | yes | **`RenéDiag`** (creator `RODG`), `MacFormat`, `MacFinal`, `Manual Sparer`, `dcATP` |
| `NISHA_HD_DIAG.img` | blank | **no** | `HD Diag` only -- a data disk, boot block is zeros |

`RenéDiag`'s creator code `RODG` is Rodger Mohme, which is the corroboration
that this plan had the right tool named: `HD 20 Test` is his too, and `HD Diag`
is the same `HDTS` signature.

**Start with `HD20_SEP_85.img`.** It is the genuine startup disk, it boots, and
it carries `HD Diag` -- so one 400K floppy covers the whole first test without
needing a mountable volume, a driver patch or a bootable HD20. Go to
`HD-20_Tests_2.0.img` and RenéDiag second, once HD Diag has said something.

**THE HD20 VOLUMES, both verified as HFS with `LK` boot blocks:**

| image | volume name | blocks | why |
|---|---|---|---|
| `320_32MB_volume.dsk` | `3.2 32MB (P)` | 65535 | sits exactly ON the 16-bit boundary |
| `608_2GB_volume.dsk` | `6.0.8 2GB (P)` | 3850144 | needs 22 bits -- the seam test |

**Copy them to `.img` before use:** the mount slot declares `IMGVHD`, matching
the SCSI slots, so a `.dsk` will not appear in the browser. That is deliberate
-- adding `DSK` there would clutter the floppy browser with hard disk images.

**PROCEDURE, and the model matters:**

1. **Plus or 512Ke only.** The DCD engine is 128K-ROM-only. The menu item shows
   on a 128K/512K too, but nothing there will ever talk to it -- **those need
   `Hard Disk 20` from a startup floppy**, which is the later second test and a
   genuinely independent one, since the `.Sony` `PTCH` reaches the same drive
   through RAM rather than ROM.
2. **Boot from Pri Floppy, never Sec.** With a DCD image mounted the DCD owns
   the external drive port and the secondary floppy is gone.
3. **Detection is the milestone.** If the Mac reacts to the drive at all -- an
   icon, or a dialog naming it -- then framing, the 332-byte identity block, the
   icon and the capacity are all right at once. That is the whole of Status
   proven in one observation.
4. Then reads; then booting from the volume.

**WRITE IS REPORTED AS PROTECTED, DELIBERATELY, and know this before reading a
result.** `Device_Character` is `$DE`, not TashTwenty's `$F6`. HFS writes the
MDB back at mount time to mark a volume in use, and with opcode `$01` unanswered
that write is a handshake timeout -- so an honest "writable" would make a
working read path present as a broken drive at exactly the wrong moment. **A
mount failure with `$DE` set therefore means a real bug, not the known gap.**

**THERE ARE NO DCD PROBES IN THE DECK.** If it fails silently there is nothing
on JTAG to separate "never selected" from "selected but Status rejected". Adding
last-opcode / frame-count / last-error probes is the first move if the board
says nothing, not more simulation.


### The /HSHK bug, found on hardware by disassembling HD Diag's spin loop

**2026-09-04. First hardware test of the phase, and it failed: HD Diag reported
"init driver failed", then "Comm error" on a hard reset. The bug is real, it is
now fixed (`7e76cae`), and the way it was CONFIRMED is worth more than the bug.**

**THE BUG.** `rtl/dcd_link.v` only ever asserted /HSHK when the DRIVE wanted to
talk. But before sending any command the Mac asserts HOST (state 3) and **spins
until the drive pulls /HSHK low**, giving up with error `$11`:

```
419AB0  subq.l #$1, d7        ; $140000 iterations, about 3.3 s at 8 MHz
419AB2  beq.w  $419c56        ;   -> error $11
419AB6  tst.b  $1c00(a0)      ; read sense
419ABA  bmi.b  $419ab0        ; LOOP WHILE SENSE == 1
419ABC  tst.b  $400(a0)       ; ca1=0, and only NOW send
```

TashTwenty's receiver is the mirror image and settles the release as well: wait
while state 2, require state 3, `bcf PORTC,RC4` to assert, wait while state 3,
require state 1. When the Mac has sent everything it returns to state 3 -- its
`IntEn3` comment is "mac is done and is waiting for !HSHK to be deasserted".

**HOW IT WAS CONFIRMED, and this is the reusable part.** The instruction-fetch
sampler (`PIFA`/`PIFD`) was pointed at the machine while Daniel triggered a hard
reset in HD Diag. 55 of 150 samples landed in a 40-byte range in RAM, and
`PIFD` supplies the WORD fetched at each address, so the loop reassembles
directly:

```
00D938  subq.l #$1, d1        ; HD Diag's own timeout counter
00D93A  beq.b  $d96a          ;   -> timed out, reported as "Comm error"
00D93C  tst.b  $1c00(a2)      ; the SAME IWM sense register
00D940  bmi.b  $d938          ; LOOP WHILE SENSE == 1
00D942  moveq  #$28, d0
```

**Same register, same structure, same exit condition as the ROM** -- from a
completely independent implementation, since HD Diag carries its own driver in
RAM (which is why it runs on a 128K whose ROM has no DCD engine at all). The
drive was never pulling /HSHK low, on real silicon.

**THE TECHNIQUE GENERALISES: probe the DEVICE, not the CPU, unless the CPU is
stuck -- and when it is stuck, PIFA+PIFD is a disassembler.**
[[mister-jtag-issp-debugging]] already recorded this shape; this is the second
time it has ended a stall, and the first where the wedged code was in RAM and
therefore unreadable any other way.

**A FALSE STEP WORTH KEEPING.** A first capture across a BOOT showed zero
samples anywhere in `$419600`-`$419E40`, and that was read as "the handshake is
not what is blocking us". **That reading was wrong and the error is instructive:
only a SUCCESSFUL identification followed by a command produces the 3.3 s spin
that sampling can catch. A FAILED identification is microseconds of work and is
invisible at 2.5 samples/sec.** So the boot capture could never distinguish
"identification failed" from "identification succeeded, command deferred", and
concluding anything from its silence was over-reading a negative result. HD Diag
reaches the wait because it drives the lines directly without needing the ROM's
identification to pass first.

**STILL OPEN: whether boot-time identification works.** The handshake fix is
confirmed NECESSARY; whether it is SUFFICIENT for the ROM to find and mount an
HD20 at boot is not yet known. The next escalation, if a fixed build still will
not mount, is a `PDCD` probe rather than more sampling: `present`, `selected`, a
STICKY states-seen bitmap (did the Mac ever drive state 5? state 3?), `rxHs`,
sync and command counts, and the last opcode -- all sticky, with the source side
of `altsource_probe` wired as an arm/clear so a sub-millisecond event can be
caught between JTAG samples 0.4 s apart. Every probe in the deck already
declares `source_width(1)` with `.source()` unconnected, so the wiring exists.
**Mind the ~20 hub-node ceiling: the deck is AT 20, so one goes out for each one
that comes in.**

**And the bench gap, for the third time in one phase.** All three benches jumped
straight to state 1 and started sending, which the drive accepted, so nothing
could have caught this. They now perform the real handshake at both ends of
every command: link 42/42, status 46/46, read 34/34, and the handshake mutation
sweep kills 8 of 8.


### The `PDCD` probe, built and gated (2026-09-04)

**The escalation above is now in the tree. Nothing is compiled: the RTL,
the reader and all six benches are green under iverilog and tclsh, and the
Quartus compile is the next step and has not been taken.**

**WHY A PROBE AND NOT MORE SAMPLING.** The instruction-fetch sampler can only
reach code the CPU is already wedged in, so it can say "HD Diag is spinning on
the IWM sense register" and nothing whatever about whether the ROM ever
identified a DCD in the first place. That question -- did the Mac drive state
5, and did a command follow -- is microseconds of work at boot and invisible at
2.5 samples/sec. **Probe the device, not the CPU.**

**THE SHAPE.** `rtl/dcd_link.v` and `rtl/dcd.v` export one 32-bit word of
LIVE RAW STATE, `dbg_dcd`, threaded up through `iwm.v` ->
`dataController_top.sv` -> `MacPlus.sv` to the deck. Every counter, sticky bit
and epoch lives in `rtl/dbg_probes.sv`. That is the same division `scsi_dbg`
already uses and it is not decoration: a module under observation that grows
logic only an instrument reads has to be maintained and proven twice, and the
clear can then stay in the deck instead of being threaded back down.

```
  dbg_link (rtl/dcd_link.v)          dbg_dcd (rtl/dcd.v)
  [2:0]  {ca2,ca1,ca0}, raw          [15:0]  dbg_link
  [3]    selected                    [18:16] cstate
  [4]    /HSHK  1 = de-asserted      [19]    present
  [7:5]  rxHs                        [27:20] opcode of the frame in rxBuf
  [10:8] txState                     [28]    txReq
  [11]   txBusy                      [29]    disk busy
  [12]   byte taken from the Mac     [30]    disk err
  [13]   newByteReady                [31]    dcdReset
  [14]   rxValid   [15] rxBad
```

```
  PDCD                                PDC2
  [31:24] phase states seen (sticky)  [31:24] bytes out, saturating
  [23:16] last DECODED opcode         [23:18] bytes in, saturating
  [15:13] rxHs now                    [17:15] txState high-water
  [12:10] txState now                 [14:12] rxHs high-water
  [9:7]   command FSM now             [11:0]  last 4 rxHs, newest in [2:0]
  [6]     /HSHK now
  [5]     present    [4] selected
  [3:2]   commands decoded, sat 3
  [1]     bad checksum (sticky)
  [0]     reply abandoned in TX_WAIT
```

**THE CLEAR, and why it is not optional.** Every interesting field is sticky,
because the events are sub-millisecond and JTAG samples land 0.4 s apart. Sticky
state that cannot be zeroed is readable ONCE PER POWER CYCLE, which is useless
for a fault you have to provoke deliberately from HD Diag. So `PDCD`'s SOURCE is
wired -- the only connected source anywhere in the deck -- and
`scripts/read_probes.tcl` takes a `clear` argument:

```
quartus_stp -t scripts/read_probes.tcl 20 0.5 clear
```

Hold high to zero the block, drop to arm, provoke the fault, read.

**THE VERDICT LINES, which are the point.** Each rules out one reading that the
sampler could not separate, in order: no image mounted / the Mac never drove
state 5 / identified but no command arrived / bytes arrived but nothing decoded
/ **the $28 wedge: /HSHK asserted with a reply parked in TX_WAIT** / /HSHK
asserted waiting to receive / a reply abandoned by `abd857c`'s escape / no wedge
visible. A verdict that fires on the wrong capture is worse than no verdict at
all, because it reads as an answer -- so each branch has its own test.

**THE PRUNE.** The deck was AT the ~20 hub-node ceiling MacLC measured, above
which the name table reads back corrupted. Two came in, so `PRG2` and `PRG3`
went out and the SCSI access ring is 4 entries rather than 8. That is the only
thing here that degrades gracefully, and the SCSI wedge it was built for is
closed. `read_probes.tcl` and the reader tests follow.

**GATES.** `tb_dcd_link` 45/45, `tb_dcd_status` 69/69, `tb_dcd_read` 40/40,
`tb_dcd_disk` 37/37, `tb_dbg_probes` 66/66, `test_read_probes` 45/45. Three
mutation sweeps, 26 mutants, all caught:

| sweep | what it mutates | mutants |
|---|---|---|
| deck logic | the counting, stickies and clear in `dbg_probes.sv` | 12 |
| packing | the concatenations in `dcd.v` / `dcd_link.v` | 6 |
| reader | the field slices and verdict branches in the Tcl | 8 |

**AND THE BENCH GAP, FOR THE FOURTH, FIFTH AND SIXTH TIME IN THIS PHASE.** All
three sweeps found holes that inspection had not, and every one is the same
shape -- **a test whose distinguishing values happen to be equal**:

- Mid-reply the drive clears `rxHs` to IDLE and pulls `/HSHK` low, so both read
  0. **Swap them in the packing and every assertion still passed.** Fixed by
  sampling the RECEIVE handshake as well, where `rxHs` is 2 or 4 and `/HSHK`
  moves.
- `present` and `selected` moved together everywhere, in BOTH the RTL bench and
  the reader test. A mounted-but-idle drive is the resting state of a real
  machine and neither bench had one.
- The opcode never changed without an accompanying `rxValid`, so latching it
  continuously passed. It must not: `rxBuf` fills byte by byte, so between
  frames that field is part of a command that has not been checksummed, and a
  capture would report it as "the last command" -- a plausible number that is
  pure fiction, which is the exact failure this deck exists to prevent.
- The `$28` verdict fired on any non-idle `txState` and nothing caught it: a
  reply IN FLIGHT also holds `/HSHK` low and is perfectly healthy, and no
  capture in the test had one. A 392-byte Status frame is most of a millisecond
  and samples land 0.4 s apart, so that is not a corner case.
- Neither byte counter was ever pushed past its width, so wrapping passed. The
  outbound one is 8 bits against a 392-byte reply, so it saturates in ORDINARY
  use -- which makes a wrap there more misleading than on the inbound side, not
  less.

**ONE PRE-EXISTING BREAK FOUND AND FIXED.** `sim/test_read_probes.tcl` was
already failing 1 of 26 before any of this work: `PFLP` and `PHLD` had been
added to the deck without being added to the test's "complete bitstream" list,
so the no-banner assertion failed against a correct reader. **A broken gate
reads exactly like a broken script**, and this one had been red long enough to
stop being noticed.

**NEXT: the compile, then hardware.** The order is unchanged -- `clear`, boot
with the HD20 mounted, read; then `clear`, run HD Diag, read. The first capture
answers whether boot-time identification happens at all, which is the question
that has been open since the handshake fix.


### Review 2026-09-05: the HD20 was never wired to the IWM -- three seam bugs, and the `$28` was not ours

**Code review against the specifications, the Plus ROM, HD Diag's own code and
`fx68k`, with no compile and no RTL change. The result is that nothing on the
board has yet observed the DCD at all.** Every hardware symptom so far --
"init driver failed", "Comm error", `$28000000` -- is produced by the EXTERNAL
FLOPPY model answering in the DCD's place, and the three bugs that cause it
all sit on the seam between `rtl/iwm.v` and the DCD modules, which is the one
place the benches never look: all three DCD benches instantiate `dcd_link` or
`dcd` directly with `cep = cen = 1` and hand-made single-clock `writeReq`
pulses. [[macplus-core-conventions]]'s "test the seams" lesson, for the fourth
time.

**BUG 1 -- THE SENSE LINE NEVER REACHES THE CPU.** `rtl/iwm.v:136` defines
`senseExt = readDataExt[7]`, and `readDataExt` is `floppyExt`'s output. The
DCD's `readData` is only muxed into `readDataExtSel`, which feeds the DATA
LATCH. The IWM status register -- Q7=0, Q6=1, which is what `$418600` (`q6H`,
read `q7L`, `q6L`) and HD Diag's `tst.b $1c00(a2)` read -- takes its bit 7
from `senseExt` (`rtl/iwm.v:405`), i.e. from the floppy, always. So:

- **The ID probe cannot pass.** With `_enable` low, `floppy.v:449` returns
  `driveRegsAsRead[{ca2,ca1,ca0,SEL}]`. State 7 with SEL=0 is register `1110`
  = INSTALLED = 0. Both the ROM (`$418634 bpl fail`) and HD Diag (`$D9BC bpl`)
  require 1 there. State 5 = `1010` SUPERDR = 0 happens to be what a DCD
  answers, which is a coincidence that helps nobody. HD Diag's "init driver
  failed" is this, and the ROM's Open takes the "not a DCD" branch at
  `$417E46` on every boot.
- **The `$28` is the floppy's MOTORON or TK0 register.** HD Diag's hard reset
  (`$D8EC`, disassembled below) drives state 4 with /ENBL2, drops to state 2
  and then reads the status register: it wants sense LOW first (`$24` if it
  never happens) and then HIGH (`$28` if that never happens). In state 2 the
  floppy answers register `0100` = MOTORON with SEL=0 (0 = motor on) or
  `0101` = TK0 with SEL=1 (0 = head at track 0, where an unused drive sits).
  Either reads 0 -> "asserted" at once -> never "released" -> `$28`. A `$24`
  would only have meant the motor register was off. **So the inference in
  `abd857c` -- "the handshake fix works; the drive now takes the line and does
  not let go", and "`$28` proves the image is mounted and the device is
  selected" -- is void.** The fix in `7e76cae` is still correct on the ROM
  disassembly and TashTwenty, but it has not been observed on hardware, and
  neither has the mount. `PDCD` bit 5 (`present`) is the first thing that will
  say whether the image was ever mounted.

```
00D8FC  movea.l $1e0.w,a2      ; IWMBase
00D900  tst.b $1000(a2)        ; mtrOff
00D904  tst.b $a00(a2)         ; ca2=1
00D908  tst.b $400(a2)         ; ca1=0
00D90C  tst.b (a2)             ; ca0=0      -> state 4, RESET
00D90E  tst.b $1600(a2)        ; select external
00D912  tst.b $1200(a2)        ; mtrOn      -> /ENBL2 asserted
00D916  move.w #$e5b0,d1 / dbra ; ~74 ms
00D91E  tst.b $600(a2)         ; ca1=1      -> state 6
00D922  tst.b $800(a2)         ; ca2=0      -> state 2, idle
00D926  tst.b $1a00(a2)        ; q6H: status register from here on
00D92A  ...delay $A0000...
00D932  moveq #$24,d0
00D938  subq.l #1,d1 / beq $d96a / tst.b $1c00(a2) / bmi $d938   ; wait LOW
00D942  moveq #$28,d0
00D944  subq.l #1,d1 / beq $d96a / tst.b $1c00(a2) / bpl $d944   ; wait HIGH
00D94E  moveq #1,d0            ; success
```

**BUG 2 -- THE DRIVE'S BYTES NEVER REACH THE DATA LATCH.** `rtl/dcd_link.v`
clears `newByteReady` unconditionally every clock and sets it only inside
`if (cen)`, so it is high for exactly ONE `clk` -- the cycle after the `cen`
tick, when `cen` (`busPhase == 01`) is necessarily low. `rtl/iwm.v:494`
latches with `if (cen && newByteReady)`. The two never coincide. `floppy.v`
sets and clears its `newByteReady` inside `if (cep)`, so its pulse spans a
whole 8 MHz period and the `cen` in the middle catches it. With bug 1 fixed
alone, the Mac would time out hunting the `$AA` (error `$21`) on every reply.

**BUG 3 -- EVERY BYTE THE MAC SENDS ARRIVES THREE TIMES.** `rtl/iwm.v:141`
builds `writeReqExt = cen && dataRegWrite && selectExternalDriveNext`, and
`dataRegWrite` is a LEVEL on `_cpuLDS`. `fx68k.sv:2408-2424` asserts `rLDS`
for a write at the S2 `enPhi1` edge and releases it at the S7 `enPhi2` edge,
so `_cpuLDS` is low across three `cen` samples (`sim/tb_iwm_latch.v:148` says
the same for a read: "holds `_cpuLDS` for 3 CPU clock periods"). `floppy.v`
never noticed because `floppy.v:122` refuses a `writeReq` while
`writeBusyReg` is set, and busy lasts 16 us. `dcd_link.v` takes every pulse
as a new byte: `$AA $AA $AA $81 $81 $81 ...` -- the second `$AA` becomes the
count byte, the framing is gone, no command ever checksums, no reply is ever
requested. Invisible with bug 1 in place; the first thing that would break
after it.

**Lesser, recorded so they are not rediscovered:**

- **`_iwmBusy` is the floppy's** (`rtl/iwm.v:129`), and `floppyExt` never
  goes busy without a disk, so the Mac's `tst.b (a3) / bpl` at `$419AE8`
  never waits and it sends at full CPU speed rather than one byte per 16 us.
  The receive side is byte-driven and does not care. A deviation, not a fault.
- **`floppyExt` stays enabled while the DCD is present.** It only loses the
  `readData`/`newByteReady` mux. PH3 strobes still write its registers: the
  ROM's chain walk at `$4189A4` pulses PH3 in state 7 with SEL=0, which is
  `{ca1,ca0,SEL} = 110` = EJECT with `ca2 = 1`, so `diskEject[1]` fires at
  the HPS. Harmless with no external floppy mounted; untidy.
- **PH3 is decoded, and ignoring it costs nothing with one drive.** The ROM's
  Open (`$417E0C`) first probes drive INDEX 7: `$41892A` -> `$4189BE` enables
  the port and walks `index - 3 = 4` PH3 pulses while the state-7 sense reads
  1, then runs the ID probe. A DCD still answering after four advances sets
  `$fc(a1)` = `$FF`, which makes `$417E32` SKIP indices 4-6 and `$418972`
  enable the port directly for index 3. So a drive that ignores PH3 is seen
  once, as drive 3, which is exactly what we want. The authentic behaviour --
  phantom states after a PH3 pulse until /ENBL2 is raised (the flip-flop in
  the flow-through circuit, spec 1.2a Figure 2) -- is optional accuracy.
- **HD Diag's reset wants /HSHK LOW then HIGH; the ROM wants only HIGH.**
  `$419C6C` resets, idles, then polls `$418600` up to 1600 x 100 waiting for
  sense = 1 and never requires a low. Our link deasserts on RESET, so after
  bug 1 the ROM path passes and HD Diag's hard reset reports `$24` -- as it
  would against TashTwenty ([[macplus-hd20-diag-oracle]]). A real drive holds
  /HSHK low for its self-test after a reset (the "up to 2 seconds" in the
  spec, the 1600-poll budget in the ROM). A short assertion after state 4 is
  the authentic answer and would turn HD Diag's hard reset into a passing
  oracle. Inferred from two programs, not read from a document -- say so in
  the comment.

**Everything else on the ROM's path checks out against the RTL** and is
recorded so it need not be re-read: `$4185AC`/`$41892A` select the external
port, drive state 7, clear SEL and enable for index 3; the transmit prologue
writes the sync to `$1E00` and data to `$1A00` with Q7 high (both are
`dataRegWrite`), polling `a3 = $1800` (q6L, the handshake register, not the
status register -- so the drive holding /HSHK low during a receive does not
stall it); the receive end at `$4199F8` goes 1 -> 3 and reads the sense ONCE,
erroring `$25` unless it is already high, which `TX_END`'s immediate release
satisfies; and the receive entry `$419820` requires sense low before it
starts, so the caller polls, which `TX_IDLE`'s wait for state 2 satisfies.

**THE FIX, in the order that keeps the floppy port bit-identical:**

1. `rtl/iwm.v`: `senseExt` from the DCD when it is present --
   `dcdPresent ? readDataDcd[7] : readDataExt[7]` -- so with nothing mounted
   the wire reduces to what it is today. The status-register mux at `:405` is
   otherwise untouched.
2. `rtl/dcd_link.v`: hold `newByteReady` until the NEXT `cen` -- set it on the
   tick that presents the byte, clear it on the following tick, both under
   `cen` -- mirroring `floppy.v`. Check `dbg_link[13]` still reads as a pulse
   in the deck's counter.
3. `rtl/iwm.v`: a one-shot data-register strobe for the DCD only:
   `writeReqDcd = cen && dataRegWrite && !dataRegWriteSeen &&
   selectExternalDriveNext`, with `dataRegWriteSeen` tracking `dataRegWrite`
   on `cen`. The floppy's `writeReqExt` stays as it is. Consecutive writes are
   always separated by the `tst.b (a3)` read, so an edge is safe.
4. Same build, optional: force `floppyExt`'s `_enable` high while
   `dcdPresent`, and take `_iwmBusy` from a constant "ready" on that branch,
   which is what it already evaluates to. Also optional: the post-RESET /HSHK
   window, and phantom states after a PH3 pulse.
5. **The seam bench, which is the actual deliverable:** `sim/tb_iwm_dcd.v`,
   instantiating the REAL `iwm` (both floppies and the DCD inside it) with
   `busPhase`-derived `cep`/`cen` and `tb_iwm_latch.v`'s `cpu_access` task
   holding `_cpuLDS` for 3 CPU periods. Mount an image with `img_mounted`,
   then drive exactly what the ROM drives, through the IWM's CPU port:
   - the ID probe through the STATUS register: 1, 1, 0 for states 7, 6, 5,
     and the floppy's own values with nothing mounted (that is the regression
     that matters);
   - HD Diag's reset sequence, then sense high;
   - a Status command as `$419A98`-`$419AEC` sends it: state 3, poll sense
     low, state 1, `$AA $81 $B1` and the group through the data register,
     state 3, poll high, state 2;
   - poll sense low, state 3 -> 1, read all 344 bytes through the data latch
     with the ROM's `dbmi` idiom and the real latch clear, decode 7-for-8 and
     check the checksum and the identity fields;
   - then MultiBlock Read of block 0 the same way, against the mounted image.
   Run it against the CURRENT RTL first: it must fail at the ID probe; with
   fix 1 only, at the reply; with fixes 1 and 2, at the command. Each bug
   caught by name, or the bench is not testing the seam.
6. Then the compile that was already queued, with the `PDCD` probe still in
   it, and the hardware order unchanged: `clear`, boot, read -- `present` and
   states-seen 7/6/5 -- then HD Diag, which should now get past "init driver
   failed". Its hard reset will say `$24` until item 4's window exists.

**What changes in the record.** "Hardware-confirmed" on `7e76cae` is
withdrawn; "the image IS mounted" is withdrawn; the `$28` needs no theory
about our drive. What stands: the /HSHK design in `dcd_link.v` matches the
ROM and TashTwenty, and the command layer is unchanged by any of this.

### Fixes applied 2026-09-05: all three, plus two the bench found that the review did not

**Items 1-3 and 5 of the fix above are DONE. The seam bench is
`sim/tb_iwm_dcd.v` and it passes 29/29. Nothing has been compiled: the build
gate came back the same day (see the memory note), so HEAD is ready for Quartus
and has not been through it.**

The bench was written FIRST and run against the unfixed RTL, which is the only
way to know it tests anything. Its baseline and the ladder down:

| RTL | tb_iwm_dcd | first failure |
| --- | --- | --- |
| before any fix | 6/27 | the ID probe -- bug 1 |
| fix 1 only | 11/27 | the command frame -- bug 3 |
| fixes 1+2+3 | 22/27 | the MultiBlock Read reply |
| + TX_END (below) | 25/29 | duplicate bytes -- the arming defect |
| + the arming fix | **29/29** | -- |

It drives the REAL `iwm` -- both floppies and the DCD inside it -- through its
CPU port and nothing else: `busPhase`-derived `cep`/`cen`, `_cpuLDS` held for
three CPU periods, the sixteen one-bit registers, and the status/handshake/data
registers selected by Q6 and Q7 exactly as `$418600`, `$419A98` and HD Diag's
`$D8FC` select them. The three bugs are checked BY NAME -- the ID probe through
the status register, `writeReq` pulses counted per CPU write at the DCD's own
port, and `newByteReady` edges against the ones the `cen`-gated latch could see
-- so a regression says which one came back rather than just "no reply". The
first block is the regression that matters: with NO image mounted the sense line
must still be `floppyExt`'s, bit for bit, and that is asserted against
`readDataExt[7]` directly rather than against a written-down expectation.

**The three fixes went in as planned.** `senseExt` now comes off
`readDataExtSel[7]`, the same mux the data takes, so it reduces to
`readDataExt[7]` with nothing mounted. `dcd_link` clears `newByteReady` under
`cen` instead of unconditionally. `writeReqDcd` is a one-shot built from
`dataRegWriteSeen`, and `writeReqExt` is untouched so the floppy path is
bit-identical. Item 4's optional accuracy -- the post-RESET /HSHK window and the
phantom states after a PH3 pulse -- is still NOT done, so HD Diag's hard reset
will still report `$24`.

**FOURTH: TX_END dropped the last byte of every frame.** `dcd_link`'s
`readData` only presents `txByte` while `txBusy` is set, and with fix 2 the IWM
latches a byte on the cen tick AFTER the one that offered it. `TX_END` ran on
the very next clk, so `txBusy` fell inside that gap and the CPU latched
`{senseBit, 7'b0}` = `$80` in place of the final group's LSB byte -- which
silently cleared bit 0 of all seven bytes of the last group. Three data bytes
wrong out of 512, at 506, 508 and 510, and a checksum that would not close.
`TX_END` now waits for `cen`; nonblocking assignment means `txBusy` is still set
at the instant the IWM samples. Cost: 125 ns before /HSHK is released, which the
Mac spends spinning in state 3 anyway. **The Status reply passed this by luck**
-- its last group is four pads and the checksum, whose bit 0 happened to be
zero. A bench that only ran Status would have shipped it.

**FIFTH -- WITHDRAWN the same day; see "The fifth fix was the bench's, not
the IWM's" below. Kept as written so the reasoning that went wrong can be
read.** As claimed at the time: NOT DCD-specific: the IWM never armed its
latch-clear when the byte arrived during the read. `rtl/iwm.v` had

```
if (iwmRead && readDataLatch[7]) readLatchClearTimer <= 4'hD;
```

which reads the latch PRE-EDGE. A drive byte landing on the last `cen` tick of a
CPU read access finds that value still zero, so the countdown is never armed at
all -- `readLatchClearTimer` stays 0, the latch never self-clears, and the next
poll returns the same byte a second time. Measured directly rather than
inferred: every good byte leaves the timer at 13, and the byte before a
duplicate leaves it at 0. Over a 617-byte MultiBlock Read frame that was **68
duplicate reads** and a frame that could not decode.

The condition now also accepts `cen && newByteReady && readData[7]`. That is
what the IWM manual quoted at the top of `iwm.v` already says -- a valid read is
/DEV low with D7 outputting a one "for at least one fclk period", and that final
tick is exactly one fclk period with /DEV still low, so the hardware arms it.

**Why it survived this long, and why it is worth watching.** It is
alignment-dependent in exactly the way `sim/tb_iwm_latch.v` documents: the
393-byte Status frame lands on a safe phase and decodes perfectly while the
617-byte read frame does not. `tb_iwm_latch` passes IDENTICALLY with and without
the fix, so the bench that owns this latch could not see it -- it sweeps poll
gap against bus phase, and this race is about where the byte lands inside the
access, which is a different axis. Only two benches instantiate `iwm` at all, so
simulation coverage of the change is complete, but the floppy read path is
hardware-proven and simulation is not hardware: **if anything regresses in
floppy reads after this build, this one-line change is the first suspect.**

**Still open, unchanged by any of this:** the compile with the `PDCD` probe in
it, and then the hardware order from item 6 -- `clear`, boot, read `present` and
states-seen 7/6/5, then HD Diag. Everything above is simulation. Nothing here
has been observed on the board.

### Review of the fixes, 2026-09-05: the fifth fix was the bench's, not the IWM's

**`072b90f` is reverted. The three seam fixes and the `TX_END` fix stand. The
"68 duplicate reads" were an artefact of the seam bench's CPU model, and the
RTL change made to satisfy it would have LOST bytes on hardware, floppy reads
included.** Nothing is compiled; this section brings the tree to the point
where the compile is the next step.

**THE ONE EDGE.** `fx68k.sv` captures the data bus with `dbin <= iEdb` on
`enPhi2 & bcComplete` ("on PHI2, starting the external S7 phase") and releases
`rLDS` on that IDENTICAL edge (`enPhi2 & bcComplete` in `busControl`).
`enPhi2` is `clk8_en_n`, which is the IWM's `cen`, and the path from
`readDataLatch` to `iEdb` is combinational. Both assignments are nonblocking:
the CPU sees the pre-edge bus at the third `cen` of the access, and the IWM
sees the pre-edge `_cpuLDS`, still low, on the same edge. **A drive byte the
IWM latches on that edge is not what that access returned.** The old arming
condition, reading `readDataLatch[7]` pre-edge, does not arm the clear for it;
the next poll is that byte's FIRST read and arms the clear then. One read per
byte, which is right. The IWM manual quoted at the top of `iwm.v` says the
same thing the RTL does: a valid read needs D7 high "for at least one fclk
period" with /DEV low, and a byte landing on the release edge has zero such
periods.

`sim/tb_iwm_dcd.v`'s `cpu_read` held `_cpuLDS` across that edge and sampled
`dataOut` AFTER it. That sees a byte fx68k cannot. So a byte landing on the
last `cen` was counted as read, its clear was (correctly) not armed, and the
next poll returned it -- reported as a duplicate. `072b90f` then armed the
clear on that edge: the latch empties 12 ticks (1.5 us) after an edge the CPU
never sampled, and the next poll at 16-18 cycles finds nothing.

**Measured, with the bench's CPU model corrected to sample pre-edge on the
third `cen` and a counter of bytes landing on an access's last `cen`:**

| poll period (cen) | last-cen landings | `072b90f` iwm.v | `c7e1bce` iwm.v |
| --- | --- | --- | --- |
| 24 (`POLL_GAP` 21, as committed) | 0 | 29/29 | 29/29 |
| 23 (`POLL_GAP` 20) | 17 / 44 | **22/29 -- a byte lost, both frames fail** | 29/29, 0 duplicates |

The committed bench never exercised the race at all: a byte lands every 128
`cen`, and 128 mod 24 = 8 visits three phases out of twenty-four, none of them
the last tick. That is why the bench passed either way at the alignment it
had, and why the 68 duplicates appeared only once the read frame drifted onto
the other model's blind spot. **A bench that cannot reach the race passes
whichever way the RTL is wrong.** This is the same bench-gap shape recorded
three times already in this phase, now on the CPU side of the seam.

**What changed:**

- `rtl/iwm.v`: the arming condition is back to `iwmRead && readDataLatch[7]`,
  byte-identical to `c7e1bce`.
- `sim/tb_iwm_dcd.v`: `cpu_read` samples pre-edge on the third `cen` and
  releases on it, mirroring fx68k; `POLL_GAP` is 20 so the 23-tick period is
  coprime with 128 and every phase is visited within 23 bytes; `lastCenHits`
  counts bytes landing on an access's last tick and the gate asserts it is
  non-zero, so the bench is known to reach the race it covers. 30/30.
- `sim/tb_iwm_latch.v` shares the older access structure. Its gates -- no
  bus-phase dependence, 16 MHz matching 8 MHz -- do not turn on the sample
  edge, so it is unchanged, but it is not evidence for either model and should
  not be cited as such.

**The record.** "Every good byte leaves the timer at 13, the byte before a
duplicate leaves it at 0" was a true observation of a bench reading an edge
the CPU does not. The lesson is [[feedback-read-the-spec-for-historical-hardware]]'s
again, one layer down: the CPU model in a bench is a historical-hardware claim
too, and fx68k was there to be read. `rtl/build_tag.v` in the working tree
was stamped `072b90fe`; it is restored to the committed unstamped value, and
must be re-stamped from HEAD before the compile.

### Two more from the same review, both in this build

**`PDC2`'s outbound byte count was four per byte.** Fix 2 above holds
`newByteReady` from one `cen` to the next, which is four `clk` at 32 MHz, and
`rtl/dbg_probes.sv` counted it as a level. The plan item said to check exactly
this and it was not done. `sim/tb_dbg_probes.v` drove the bit as a one-clock
pulse, so it could not see it -- the bench-gap shape once more. The deck now
counts the rising edge, and the bench drives one four-clock pulse and asserts
it counts once (67/67). The inbound event (`writeReq`), `rxValid` and `rxBad`
are still single-clock and are unchanged. The bench's documented file list in
`SCSI_UPGRADE_PLAN.md` needs `rtl/cd_audio.sv` added now that `scsi.v`
instantiates it.

**`floppyExt` is now held disabled while a DCD image is mounted** (item 4 of
the fix plan, previously optional). `writeReqExt` still reached it, and
`floppy.v` accepts a write whenever it has an inserted, unprotected disk -- so
an external floppy image inserted after boot with the OSD write toggle on
would have had the DCD's command bytes written onto its track 0. With the
enable forced off, `floppy.v` refuses the write, clears its own busy, does not
fire the PH3 eject the ROM's chain walk would otherwise trigger, and `_iwmBusy`
on that branch reads ready as before. With no DCD mounted the expression
reduces to `~diskEnableExt` exactly, so the external port stays bit-identical.
`tb_iwm_dcd` asserts the enable both ways and that a PH3 pulse in state 7 with
the DCD mounted ejects nothing. One existing check moved with it: a disabled
floppy reads `$FF` in every state, so state 7 no longer separates the two
sense sources and the "DCD's line, not the floppy's" check now uses state 5,
which is the ROM's own discriminator. 33/33.

The post-RESET /HSHK window and the phantom states after PH3 remain optional
and undone; HD Diag's hard reset will still report `$24`.

**Gates at this point:** `tb_iwm_dcd` 33/33, `tb_dbg_probes` 67/67,
`tb_iwm_latch` PASS, `quartus_map --analyze_file` clean on `iwm.v` and
`dbg_probes.sv`. The other DCD benches do not instantiate `iwm` and none of
this touches what they cover. **Next step is the Quartus compile, gated, with
`build_tag.v` stamped from HEAD first.**

### STOP: the 7-for-8 LSB BIT ORDER WAS REVERSED, and it is what the board was actually reporting (2026-09-05)

**Found while starting MultiBlock Write, by reading the ROM's own write loop
before designing anything -- [[feedback-read-the-spec-for-historical-hardware]]
paying for itself for the third time in this phase. It is not the write path
that was blocking the boot.**

`rtl/dcd_link.v` packed data byte *n*'s LSB into **bit 6-n** of the group's LSB
byte, in both directions. It is **bit n**. Four independent sites, two on each
side of the wire, and they agree with each other and not with us:

| source | site | what it does |
|---|---|---|
| Plus ROM, transmit | `$419A4C`..`$419B06` | six `roxr.b #1,d4` in the prologue then `roxr.b #2,d4`, leaving `[1, L6, L5, L4, L3, L2, L1, L0]` |
| Plus ROM, receive | `$4198C4` | `lsr.b #1,d4 / addx.b d1,d1` -- the FIRST data byte takes bit 0, the second bit 1 |
| HD20 firmware, receive | `L1dfc` | `rrc R8 / rlc R9` per byte, R8 being the LSB byte: byte n takes bit n |
| HD20 firmware, transmit | `L1edc` | `scf / rrc Rn / rrc R15` seven times, one more shift, `or R15,#$80` -- Ln accumulates at bit n |

**WHY NOTHING CAUGHT IT, and all three reasons are worth keeping.**

1. **Figure 1 is a palindrome.** The specification's worked example is data
   `$31..$37`, whose LSBs are `1,0,1,0,1,0,1`. Reversed, that is `1,0,1,0,1,0,1`.
   The LSB byte is `$D5` under either order. `sim/tb_dcd_link.v` asserted this
   vector "verbatim" and its own comment claimed a wrong packing "fails here and
   essentially nowhere else". It fails there never.
2. **A reversed packing is self-consistent**, so every loopback bench -- ours
   encode, ours decode -- agrees with itself perfectly.
3. **The checksum cannot see it.** It sums the seven decoded bytes; a permutation
   of which byte each `+1` lands on leaves the sum alone. So `bad-checksum=0` on
   hardware proved nothing about it, and neither could any amount of soak.

**AND IT RE-READS THE 2026-09-05 HARDWARE RESULT, which was over-interpreted.**
The board reported `commands=3+`, `last op=$02`, 255+ bytes out and zero
checksum errors, and that was written up as "Status and MultiBlock Read both
work; the Mac then issued a write-verify". Work through the arithmetic instead:

- **A Status REPLY could never be accepted.** Its first group is
  `$83 $00 $00 $00 $00 $00 $00`, LSBs `1,0,0,0,0,0,0`. Reversed, the Mac decodes
  byte 0 as **`$82`**, and `$419776`'s `subi.b #$80` / compare then errors
  **`$30`** every single time. Every Status the drive answered was thrown away.
- **`last op=$02` IS A MISDECODED STATUS COMMAND.** `$419D12` sets `d3` to 1, so
  the Status command block on the wire is `$03 $01 $00 $00 $00 $00 $FC` -- LSBs
  `1,1,0,0,0,0,0`, which is *not* a palindrome. Reversed it decodes to
  `$02 $00 $00 $00 $00 $01 $FD`: a **valid checksum**, an **opcode of `$02`**,
  and a block count of 0. `rtl/dcd.v` matched neither `$03` nor `$00`, dropped
  it, and the Mac spun. That is the whole hang, exactly as observed, and the
  write path was never reached at all.
- The 255+ bytes out are one Status reply (49 groups = 392 bytes) saturating an
  8-bit counter -- consistent with a command that happened to decode as `$03`
  because a different address made its checksum parity land the other way.

**So "identification, Status and MultiBlock Read all work on the board" is
withdrawn.** What was proven on hardware is identification (static sense levels,
untouched by any of this), that frames move in both directions, and that the
Mac really does send `$AA` on a write. Nothing above the link layer was
confirmed. `sim/tb_dcd_link.v` now carries the ROM's real Status command as a
discriminating vector, and the header comment records why the Figure 1 one is
not one.

**The lesson is not "read the spec" -- we did.** It is that a worked example can
be degenerate, and that a bench built from the same reading as the RTL cannot
test that reading. This plan already wrote that sentence once, at the 1.1/1.2a
STOP note. It was right then and it was still not enough.

### MultiBlock Write and Write-Verify, built (2026-09-05)

**The plan's own item 1, and the framing came out of `$419712` rather than out
of either specification.** The per-block loop settles four things that are not
guessable, and three of them are silent-corruption bugs if guessed wrong:

1. **Each block is a separate command.** `$419712`'s `tst.b d1 / beq $419754`
   returns immediately for a read; only a write re-transmits. So the drive
   answers **one group** and goes back to idle, where a read sends N frames off
   one command.
2. **Continuations set bit 6, not a fixed `$41`.** `$419716` is
   `ori.b #$40,$19C(a1)`, so `$01` continues as `$41` **and `$02` continues as
   `$42`**.
3. **The reply opcode is `(command & $3F) | $80`.** `$41975E` masks with
   `andi.b #$3F` before `$419776`'s compare, so `$41` is answered `$81` -- and,
   just as firmly, **`$02` must be answered `$82`**. An implementation copied
   from a write-only reference answers `$81` and earns error `$30`.
4. **A continued write carries no usable address.** The reply lands on top of
   the command block at `$19C`, and `$41971C` refreshes **only** the count byte
   at `$19D` -- so `$19E`-`$1A0` hold the previous reply's zero status and
   padding. **The drive must advance the block number itself.** A drive that
   trusted the wire would write every block after the first to block 0.

The count byte at `$19D` counts **down** and the reply must echo it
(`$41978C` compares before `$4197EE` decrements; a mismatch is error `$31`).

**`rtl/dcd_link.v` now streams the payload.** A write's first block rides with
the command -- 6 header + 20 tags + 512 data = 538 payload bytes -- so `rxBuf`'s
eight are nowhere near enough. The link exposes `rxStb` / `rxStbData` /
`rxStbAddr` (the byte's index within the frame's payload) and `rtl/dcd.v` routes
indices 26..537 into the sector buffer. **Byte 26 is data byte 0 in both
directions**, so the same `-26` offset serves the read path's `txAddr` and the
write path's receive index.

**A write is refused unless frame byte 537 actually arrived** (`wrFull`). The
checksum is not known until byte 538, long after the sector has been streamed
into the buffer, so a truncated frame leaves the buffer holding a mixture of
this command and whatever was there before -- which, after a read, is a
different block of the user's disk. Committing that is silent corruption of data
the Mac never sent.

**Write-verify is served as a plain write, and that is a recorded deviation.** A
real HD20 wrote the block and read it back off the platter. There is no platter
here, and the read-back would compare the sector buffer against itself; the
block layer already reports a refused or timed-out commit through the status
byte, which is the part the driver acts on.

**`WRITE_IMPLEMENTED` is now true**, so `Device_Character` is `$F6` on a
writable mount and `$DE` on a locked one -- and it comes from the image's own
read-only flag rather than from a compile-time constant.

### /HSHK has to be claimed on ACCEPTING a command, not on having the data

**A second thing the write path forced out of the ROM, and it was wrong for
MultiBlock Read too.** `$419820` is the **first** instruction of the Mac's
receive routine and it reads the sense line with **no retry budget at all** --
error `$20` otherwise. The Mac gets there within a few microseconds of leaving
state 2 at the end of its own transmission, long before an SD card can answer.
The sync byte behind it, by contrast, has a budget of `$10000` spins
(`$419846`) -- over a hundred milliseconds, which is where a real drive's seek
time goes.

So arming and sending are two different events, and `rtl/dcd_link.v` now takes
two signals: `txArm` (level, "a reply is coming" -- assert /HSHK and wait for
state 1) and `txReq` (pulse, "the payload is ready"). `rtl/dcd.v` raises `txArm`
the moment a command is accepted and holds it for the whole command, which for a
multi-block read is all N frames.

**One trap in that, and it cost an afternoon.** `txPend` used to latch from
`(txReq || txArm)`. `txArm` is a level and is necessarily still high for one
clock after the frame it armed has finished -- the command layer cannot know the
frame is over until it has *seen* `txBusy` fall. Latching that tail left a
phantom request that grabbed the bus at the start of the **next** command, and
the command layer then read the resulting `txBusy` as "still sending" and
dropped the command entirely. The symptom was a second Status going unanswered
while the first was perfect. `txPend` now latches from `txReq` only and clears
when neither `txArm` nor `txGo` is asserted.

### Hold-off is NOT the same in the two directions

**Drive to Mac** the interrupted group is **resent** from its start behind a
fresh sync and excluded from the checksum -- `$419974` backs the group counter
up and re-decodes. That is what the specification describes and what
`rtl/dcd_link.v` already did.

**Mac to drive it is not.** `$419B5A` drops `ca0` after the group's **fourth**
transmitted byte when the SCC has an interrupt pending, and the Mac then:

- sends the **rest of the group anyway**, in state 0;
- sends one filler `$00` (`$419BBA`);
- drops the interrupt mask so the SCC ISR runs;
- `subq.w #1,d6` -- which **replaces** the `dbra` it skipped, so the group
  counter and the source pointer both move on and **nothing is resent**;
- `ca0H` releases HOFF, then a bare `$AA` (`$419BE6`), then the **next** group.

The HD20's own firmware receives it exactly that way at `L1e53`: it tests the
phase line at the group boundary, discards bytes until `$AA`, and jumps back
into the group loop with the interrupted group's data intact.

Two consequences, both now in the RTL. Bytes arriving while HOFF is asserted are
**real payload and must be taken**, so the accept condition covers state 0 once
a frame is under way. And the `$AA` that follows is a **bare resync**, not the
start of a frame -- the two count bytes do not come again -- so it needs its own
state (`RX_RESYNC`) rather than a trip through `RX_SYNC`.

**None of this can fire on a Status or a Read.** `$419B40` clears the hold-off
flag when the group counter says this is the last group, and those commands are
one group long. Only a write's 77 groups can see it -- which is why it has never
mattered until now, and why it will matter the first time somebody writes to an
HD20 with AppleTalk up.

### Gates, 2026-09-05

| bench | result |
|---|---|
| `tb_dcd_link` | **66/66** (was 45; the ROM Status vector, the Mac-to-drive hold-off, the payload stream and the arm/go split are new) |
| `tb_dcd_write` | **133/133**, new file |
| `tb_dcd_status` | **75/75** (was 69; a read-only mount now has to produce `$DE` from the mount rather than from a constant) |
| `tb_dcd_read` | **40/40** unchanged |
| `tb_iwm_dcd` | **33/33** unchanged |

**Mutation: 9 built and 9 killed**, chosen to attack the new claims rather than
the easy ones -- both LSB orders restored, the reply opcode pinned to `$81`, the
continued write trusting the wire address, the sector offset moved to 25, the
receiver ignoring state-0 bytes, the resync removed, `txArm` dropped from the
bus claim, and the short-frame guard removed. Two die by timeout, which is the
honest failure mode for a drive that never answers.

**`sim/tb_dcd_write.v` is deliberately not built from `rtl/dcd.v`.** Its Mac
model frames the command out of `$419600`-`$419E40` and its block-device model
out of `hps_io.sv`, and the round-trip test writes a block through the write
path and reads it back through the read path -- the only check that survives
both halves being wrong in the same direction.

**NEXT STEP IS THE QUARTUS COMPILE, gated, with `build_tag.v` stamped from HEAD
first.** Nothing here has been near the board. The hardware question this build
answers is a real one: with the LSB order corrected, does the Plus ROM accept a
Status reply at all? Everything above the link layer is still unconfirmed on
hardware.

**Still open and untouched:** the post-RESET /HSHK window and the phantom
states after PH3; and the OSD greying.

**`iwm.v:319`'s `lstrb` IS the right signal. The port is dead, which is a
different and smaller problem.** Two claims, and this document had the first
one backwards. The specification settles it on page 1: the connector pin
table gives pin 14 as `PH3` / `/Enable`, "Used to allow multiple DCD's",
sourced from the **IWM** -- and the same table sources pin 16 `HDSel` from
the **VIA/6522**, so it is drawing exactly the distinction the open item got
wrong. PH3 is an IWM phase line, NOT VIA PA5/`SEL`, and feeding `dcd0` the
IWM's `lstrb` is correct. `rtl/dcd_link.v:120`'s comment calling lstrb "PH3
(daisy-chain select)" is right, and now has a citation behind it.

What is true is that nothing reads it: `dcd_link` declares `lstrb` at `:125`
and never uses it, taking every phase decision from `state = {ca2, ca1, ca0}`
at `:242`. That is a real gap rather than a cosmetic one, because the spec
makes the behaviour behind PH3 mandatory. Raising /ENBL clears the
flow-through flip-flop and every one down the chain; the Mac "may toggle
Phase3 to enable the next device in the chain (and disable the current
DCD)"; and a drive that does not support chaining "must support 'phantom'
states (i.e., returning a 1 for all states 5, 6, and 7) after the 'next' DCD
has been selected", so that the Mac does not assume an infinite chain.

**That is the same phantom-states item already listed above: they are one
item, not two, and PH3 is its trigger.** Harmless with a single drive, which
is all we mount, and harmless for this build. Recorded rather than fixed.

**The lesson is [[feedback-read-the-spec-for-historical-hardware]] again, and
it was earned twice in one session.** The open item inferred "PH3 is VIA
PA5/`SEL`" without opening the spec. The correction to it then called the
code's own comment "an unverified hardware claim" -- also without opening the
spec, which had the answer in a pin table on its first page, in a file
already sitting on this machine and already inventoried in this document.
Both times the wrong answer was plausible and internally consistent.

### Review 2026-09-05 (evening): the drive-to-Mac HOLD-OFF is built from the spec's prose, and the ROM, the firmware and TashTwenty all contradict it

**Read-only review against the 1.2a specification, the Plus ROM (`4D1F8172`,
capstone linear disassembly of `$417D30`-`$41A800`), the HD20 Z8 firmware
reassembly (`342-0343-B.asm`) and TashTwenty. No RTL changed, nothing compiled.
This supersedes the `$19`/`$1A` unimplemented-opcode hypothesis as the leading
explanation of the intermittent System Error.**

**THE FINDING.** `rtl/dcd_link.v` `TX_DATA`/`TX_LSB` treat state 0 as "abandon
this group, rewind to `txAddrGrp`, wait in `TX_WAIT` for state 1, resend behind
a fresh `$AA`". That is what 1.2a pages 4-5 say ("that group will be ignored and
will not be included in the checksum ... restarts reading data with the group
that was interrupted"). It is not what anything real does:

| source | on HOFF mid-group |
|---|---|
| Plus ROM `$4198EC`..`$419998` | writes 3 to the SCC (`$4198D6`) and reads RR3 at byte 1 of every group; `$41991C tst.b (a0)` asserts HOFF after it has ALREADY read four bytes of the next group; `$419926`..`$419964` keep polling for the remaining four under the shared 80-poll `dbmi d6` budget (~265 us), error `$22` if they stop; `$41996E dbne` falls through and `$41997A subq.w #1,d7` performs the SAME decrement, so nothing is backed up; `$419986` ph0H takes 0 -> 1 directly, no state 3 and no /HSHK check; `$419992` hunts `$AA` 65535 tries; `$419998 bra $4198C4` decodes the group already in `d1`-`d4` and reads the NEXT group. The finished group stays in the checksum. `tst.w d7 / beq` feeds the `sne`, so there is never a hold-off on the last group. |
| HD20 firmware `L1f4c`..`L1fac` | tests P2.7 only after the LSB byte; `or P2,#8` releases /HSHK; sends a `$00` filler; waits for release; `and P2,#0F7h` re-asserts; sends `$AA`; `jp L1edc` with R8-R14 already holding the next group |
| TashTwenty `XSuspend` | "We finished a group, so decrement group count ... Resume transmission after interrupted group" |

The plan's earlier reading of `$419974` as "backs up one group" was wrong in
exactly the way the transmit side had already been corrected: the `subq` stands
in for the `dbra`/`dbne` it skipped. Both directions CONTINUE. The March-85
timing figure agrees in its own words -- t3 "Rene will acknowledge the holdoff
immediately after the last byte of the group is sent" -- and the prose in 1.2a
is simply wrong. The ROM outranks the document; third time in this phase.

**WHAT THE MAC SEES FROM THE RTL AS BUILT, deterministically per hold-off:**

1. The remaining bytes of the group never arrive (and could not be seen anyway:
   `dcd_link.v:295` only presents `txByte` in state 1). Error `$22` ~265 us
   after HOFF; the error exit `$419A0E` lands in state 2.
2. We hold /HSHK low in `TX_WAIT`, where state 2 is "legitimate". The retry's
   transmit entry `$419A9E` finds sense low at idle and returns `$10`.
3. Prime's retry logic (`$4195DC`: `$1BE`=2 hard, bit 6 of `$1BA` clear, `$1BF`
   clear) resets the drive via `$419C66` -> `$B48`. **That reset is what sets
   `reply-abandoned-in-TX_WAIT`. It is the signature of this bug, not a
   downstream symptom, and it was in every crashed capture.**
4. `$2D(a1)` allows three attempts per request. Three hold-offs inside one
   request return readErr -19 (`$41960A`) to the File Manager. A code segment
   or resource load failing that way bombs as ID 02 / ID 10. Steps 1-3 are read
   out of the ROM; step 4's last sentence is inference.

**WHY IT IS INTERMITTENT: the trigger is SCC RR3, and the mouse is on the SCC.**
Quadrature goes to the DCD inputs; `rtl/scc.v:725` raises `dcd_ip` on every
transition, so a moving mouse produces a hold-off at the next group boundary of
whatever frame is in flight. AppleTalk or serial traffic does the same with the
mouse still. Keyboard and mouse button are VIA (level 1, masked) and cannot.

**SMALLER DISCREPANCIES FROM THE SAME READ:**

- **The error flag is BIT 0, not `$80`.** `$4197DA btst #24,d0` on the longword
  at `$19E` tests bit 0 of the status byte (plus `cmpi.b #$A`). The firmware's
  own defs say `Op_Failed EQU 001h` (`DefsHD20.inc:291`, marked `???` by the
  reassembler, but the ROM agrees). Softerr `$40` IS honoured -- `btst #$1e,
  $1ba` selects retry-without-reset. 1.2a's `$80`, TashTwenty's `bsf TX_STAT,7`
  and `rtl/dcd.v`'s `replyStat <= 8'h80` are all invisible to this ROM: a
  refused write (read-only mount, out of range) is currently reported as
  SUCCESS; a failed read only changes which error fires (`$22` on length).
- **Abandoned frames are not abandoned.** On the Mac's error exit (1 -> 3 -> 2,
  or 0 -> 2) the transmitter keeps clocking bytes out and `TX_WAIT` holds
  /HSHK low in state 2 for ever; the receiver keeps a stale `rxState` across an
  abort and never re-syncs at the next state-3 handshake. Neither causes the
  first error; each turns one into a reset cycle.
- **No NAK.** `$41985E cmpi.b #$BF` is the ROM checking for the `$7F` NAK frame
  the spec draws. We answer a bad checksum with silence, so the Mac waits out
  `$419658`'s budget. `bad-checksum=0` on hardware, so low priority.
- **The ROM DOES read the identity block**, at `$41951C`-`$41953E`, outside the
  `$419600`-`$419E40` window the earlier search covered: Num_Blocks into the
  drive table (`$12(a1,d1)`, swapped, with `$14` cleared), Device_Character bit
  3 into the write-protect flag `$2(a1,d1)`, and bit 4 (Ejectable) selects
  drive-queue flag byte 2 instead of 8. Inside Macintosh: 8 = "nonejectable
  disk in drive". So `$F6` presents the HD20 to the Finder as EJECTABLE. Not the
  bomb, but it is the documented consumer of the bit this plan called uncertain,
  and the "ROM never reads `$1A2`-`$1AB`" claim above is withdrawn.
- **`$19`/`$1A` have no caller.** Nothing in `$417D30`-`$41A800` branches to
  `$419CEC` or `$419CF0`; the diagnostic csCode table at `$419E6E` (csCodes 249
  to 256, offsets relative to `$419DA0`) targets `$419EEE`-`$41A38C`. The PDC2
  unanswered-opcode probe is built and green and can stay in the next build,
  but expect it to print "none".

**RETRY ANATOMY, for reading captures.** `$1BE` = 1 soft / 2 hard; `$1BA` =
error code or the reply status longword; `$2D(a1)` = attempts left (3);
`$1BF` = "already reset once". Between frames of a multi-block read the Mac
requires sense HIGH in state 3 (`$419A02`, error `$25`, no retry), then in
state 2 waits for it to go LOW again (`$419658`, generous budget, soft `$40`),
then `$419820` requires LOW with no retry. `txArm` satisfies all three; the
TX_END release timing and the state-2 re-arm are what make it work.

**FIX SHAPE -- APPLIED 2026-09-05, benches green, NOT YET COMPILED:**

1. `TX_DATA`/`TX_LSB`: on state 0 set a `txHoff` flag and KEEP SENDING to the
   end of the group. `readData` must present `txByte` in state 0 as well as 1.
2. At the group boundary with `txHoff`: release /HSHK; wait in a `TX_HOFF`
   state; on state 1 re-assert, send `$AA`, continue with the NEXT group --
   `txAddr`/`txSent`/`txSum` untouched, no rewind. States 2, 3 and >= 4 there,
   and 2/3 anywhere mid-frame, abort: release, `TX_IDLE`.
3. A `txAbort` pulse to `rtl/dcd.v` so `C_SENDING` drops `txArm` and returns to
   `C_IDLE` instead of arming an unsolicited next frame -- sequenced so the
   `TX_IDLE` re-arm cannot fire on the tail of `txArm` (the phantom-request trap
   already recorded above).
4. Receiver: return `rxState` to `RX_SYNC` when the handshake enters
   `RXH_READY` (state 3 from 2 is always a fresh command).
5. `replyStat` on failure carries bit 0 (`$01`, or `$81` to satisfy both
   readings).
6. Optional: the `$7F` NAK on `rxBad`.

**THE TEST METHOD, and what it was missing.** Byte-exact copies and
`hfs_integrity.py` prove data integrity, which is why they kept passing; nothing
in the method controlled for the one intermittent input to the protocol.

- **Zero-compile discriminator, on the CURRENT bitstream:** the same read-heavy
  action (launch an application, open a large document, duplicate a large file)
  ten times with the mouse untouched and ten times moving it continuously.
  Prediction: untouched clean, moving stalls (each hold-off costs a reset cycle)
  and bombs. Then copy a large file TO the HD20 while moving the mouse and
  byte-compare it -- the Mac-to-drive `RX_RESYNC` path has only ever run in
  simulation. Check the Chooser: AppleTalk active is an SCC source without the
  mouse; off for the control.
- **Probe:** before the compile, spend two of PDC2's twelve bits on sticky
  "HOFF seen while transmitting" / "HOFF seen while receiving"; fold into the
  same build as the opcode probe per the standing one-compile instruction. Read
  `reply-abandoned-in-TX_WAIT` as the primary signal.
- **Benches:** `sim/tb_dcd_link.v` test 5 asserts the wrong behaviour BY NAME
  ("the interrupted group RESTARTS, not continues"); `tb_dcd_read` (77 groups)
  and `tb_dcd_status` (49 groups) contain no hold-off at all. Same reading as
  the RTL, so they could not disagree with it -- the lesson already written at
  the 1.1/1.2a STOP and the LSB STOP. Rewrite the Mac model from
  `$4198C4`-`$419998`: assert state 0 after four bytes of a group, keep polling
  for the other four within 80 polls (fail if any is missing), 0 -> 1, hunt
  `$AA`, expect the NEXT group, sum everything including the finished group;
  put the hold-off on a middle group of a multi-group frame and once on the
  second-to-last. Mutants that must die: the rewind; stopping at HOFF; presenting
  sense instead of data in state 0. Add a ROM-faithful status check (bit 0).

**Reproducing the disassembly:** capstone `CS_ARCH_M68K | CS_MODE_M68K_000 |
CS_MODE_BIG_ENDIAN`, base `$400000`, linear, emitting `dc.w` and advancing two
bytes on any undecodable word (capstone stops dead otherwise). The regions read
here were `$419600`-`$419E40` (engines), `$417D30`-`$419600` (Prime, at
`$4194D6`-`$419648`), `$419E40`-`$41A800` (the csCode table and its targets).

### The mouse experiment: PROTOCOL, pre-registered. NOT YET RUN

The first recommendation of the review above, written out so it can be executed
without re-deriving it, and with its predictions committed BEFORE any data
exists. Zero compiles: it runs on the bitstream already on the board.

**PRECONDITIONS, both verified 2026-09-05 by reading the tree, not assumed:**

- **The board is running HEAD.** `rtl/build_tag.v` is stamped `6cc44fdc` and
  `git rev-parse HEAD` is `6cc44fdc`. The fix shape above is NOT applied, which
  is the whole point -- this experiment measures the bug, it does not test a fix.
- **Moving the mouse really does reach the SCC in this core.**
  `rtl/dataController_top.sv:596` wires `.dcd_a(mouseX1)` and `:597`
  `.dcd_b(mouseY1)` -- raw quadrature into the SCC's two DCD inputs -- and
  `rtl/scc.v:725` raises `dcd_ip_a` on `(dcd_a != dcd_latch_a) & wr15_a[3]`.
  So a mouse in motion sets an RR3 IP per quadrature transition, and a mouse
  held still sets none. Without this the experiment would have been void, and
  it is exactly the sort of thing this plan has assumed wrongly before.

**READ THE PROBES WITH THE PINNED SCRIPT, NOT THE WORKING TREE.** The working
tree's `scripts/read_probes.tcl` has been re-cut for the unanswered-opcode
probe, which is NOT in the flashed bitstream: against `6cc44fdc` its
`UNANSWERED COMMAND` line decodes the old rxHs ring and is pure fiction.
`PDCD`'s packing is untouched by that diff, so the primary signal would in fact
survive -- but running the matching script costs nothing and removes the
question. The HEAD copy is pinned at

```
C:/Users/User/AppData/Local/Temp/claude/C--Git-MiSTer-devel-MacPlus-MiSTer/5f70b546-25ae-445f-b37d-e71b90e2ecc8/scratchpad/read_probes_6cc44fdc.tcl
```

**THE THREE ARMS.** The review's still-vs-moving pair cannot separate "an SCC
interrupt causes a hold-off" from "mouse tracking costs CPU time and something
downstream is timing-sensitive": moving the mouse does both at once. A third
arm at a different movement RATE separates them, because only the first
mechanism is proportional to the transition count.

| arm | mouse | prediction |
|---|---|---|
| **A (control)** | untouched for the whole trial | clean; `reply-abandoned-in-TX_WAIT=0` |
| **B (low dose)** | slow, small movements, kept up throughout | occasional abandon, occasional stall |
| **C (high dose)** | continuous fast sweeps corner to corner | abandon on most trials, visible stalls, bombs |

Ten trials each. **AppleTalk OFF in the Chooser for all three** -- it is an SCC
interrupt source that does not need the mouse, so leaving it on contaminates
arm A. Confirm it is off before starting and record that you did.

**Arm A must be driven from the KEYBOARD, or it is not a control.** Double-
clicking an icon means moving the mouse, which is the treatment. Select the
target with the mouse, let go, wait two seconds, clear the probe, then open it
with **Cmd-O** and do not touch the mouse until the read has finished.

**PER-TRIAL PROCEDURE.** Same read-heavy action every trial -- launch an
application, or open a large document, off the HD20.

Wrapped as `arm.cmd` / `take.cmd` in the scratchpad beside the pinned reader,
because the rig is driven from PowerShell and thirty trials of a bare
`quartus_stp` command line is how transcription errors get into a data set.
Both were smoke-tested against the live board before the run began.

1. `arm.cmd` -- clears PDCD's sticky fields and reports `ARMED`.
2. Perform the action, with the arm's mouse regime running throughout.
3. `take.cmd <label>` -- reads once, prints a one-line summary, appends it to
   `mouse_experiment_log.txt`, and keeps the full capture as `raw_<label>.txt`.
4. Note by hand what the probe cannot see: whether the Mac **stalled** (a pause
   of a second or more that the control never shows) and whether it **bombed**
   (with the ID).

**A TRIAL THAT SHOWS `commands=0` IS VOID, NOT CLEAN**, and `take.cmd` says so
in those words. Measured 2026-09-05: an idle Finder generates NO DCD traffic
whatsoever -- `commands=0`, `Mac->drive 0`, `drive->Mac 0` over six samples --
which is the good news, because it means every counter in a trial comes from
the action alone and nothing background pollutes it. The cost is that an action
served out of the disk cache is indistinguishable from a clean run on the
`abandoned` bit alone. Quit the application fully between trials and rotate
between two or three large ones.

**INTERLEAVE THE ARMS -- A1, B1, C1, A2, B2, C2 ...** rather than ten of each in
a block. Thirty blocked trials drift on cache state, uptime and heat, and that
drift would land entirely on whichever arm ran last.

**THEN THE WRITE SIDE.** Copy a large file TO the HD20 while sweeping the mouse,
and reconcile it with `scripts/hfs_integrity.py`. The Mac-to-drive `RX_RESYNC`
path has only ever run in simulation; every hardware write so far was done with
a mouse that was, by necessity, mostly still.

**PRE-REGISTERED READINGS.** Committed now so that whatever comes back cannot be
narrated into agreement afterwards:

- **A clean, C failing, B in between** -- the hold-off finding is confirmed on
  hardware and the fix shape above is the right work. This is the prediction.
- **A clean, but B and C failing at the SAME rate** -- something about mouse
  movement matters and it is NOT the transition count. Suspect the VBL tracking
  task's CPU cost, not the link layer, and do not start cutting `dcd_link.v`.
- **A fails too** -- the trigger is not the mouse. Either another SCC source is
  live (re-check the Chooser and the serial ports) or the System Error has a
  second cause, and the hold-off work becomes a correctness fix on the spec
  rather than the explanation of the bomb.
- **Nothing fails anywhere, over thirty trials** -- the action is not read-heavy
  enough to span a multi-group frame with a hold-off in it. Escalate to a
  bigger read (a large file duplicate) before concluding anything; a null from a
  test that could not have failed is not evidence. See
  [[feedback-read-the-spec-for-historical-hardware]] on hollow empirical claims.

**RESULTS. FIRST DATA 2026-09-05, and it went the way the prediction said.**
One trial per condition so far -- this is a signal, not yet a result.

| arm | trials | abandoned | bad-cksum | stalls | bombs | notes |
|---|---|---|---|---|---|---|
| A control (still, Cmd-O) | 1 | 0/1 | 0 | 0 | 0 | MacWrite launched from the keyboard |
| B low dose (slow movement) | 1 | **1/1** | 0 | **1** | **1** | slow movement fails too -- see the note on why this arm could not discriminate |
| C high dose (fast sweeps) | 1 | **1/1** | 0 | **1** | **1** | MacWrite, mouse moved a lot: noticeable pause, then a System Error |
| **D mouse-launch, then still** | 1 | 0/1 | 0 | 0 | 0 | **the de-confounding trial: clean** |
| write + sweep, `hfs_integrity.py` | 0 | - | - | - | - | not run |

**BOTH TRIALS ARE VALID, which is the first thing to check and the easiest to
skip.** Each shows `commands=3+` and `drive->Mac=255+ (SAT)`, so each really did
drive the HD20 -- neither is the cached read that would have made a clean
`abandoned=0` meaningless.

**THE CRASH CAPTURE PUTS THE CPU IN THE BOMB BOX.** `PIFA PC=4013F6`, inside
`$4013F2`'s `btst.b #$3, $EFE1FE.l` / `bne` click loop -- the System Error
alert polling the mouse button ([[macplus-rom-pc-landmarks]]). `PACT` and the
fetch counter advance, so the CPU is healthy and the machine is sitting in an
alert, not wedged on the bus. `PDCD` reads `rxHs=IDLE txState=TX_IDLE
cmdFSM=C_IDLE` with `/HSHK` released and `reply-abandoned-in-TX_WAIT=1`: the
escape fired and the drive recovered, and what is left on screen is the Mac's
own reaction. That is step 4 of the review's chain observed rather than
inferred.

**WHAT THIS DOES NOT YET ESTABLISH, and the trial that would.** The two
conditions run differ in TWO ways, not one: the control was launched from the
keyboard AND held still, the treatment was launched by mouse AND moved. Launch
method was therefore confounded with movement, and a single trial each could
not separate them.

**D SETTLED IT, AND IT CAME BACK CLEAN.** Double-click to launch, then hands off
the mouse: `abandoned=0`, no stall, no bomb, and `commands=3+` /
`drive->Mac=255+` so the trial was valid. D differs from the failing condition
by MOVEMENT ALONE and from the passing control by LAUNCH METHOD alone. Launch
method is excluded. **What breaks the link is the mouse being in motion during
the transfer, nothing else about how the read was started.**

**ARM B FAILED TOO, AND THE ARM WAS BADLY DESIGNED -- it could not have
discriminated whatever the answer was.** It was set up to separate "an SCC
interrupt causes the hold-off" from "mouse tracking costs CPU time", on the
prediction that slow movement would fail far less often than fast sweeps. That
prediction rested on an unexamined assumption: that "slow" would push the
expected number of hold-offs per transfer below about one. It does not. Even
slow movement yields tens to hundreds of quadrature transitions per second, and
a MacWrite launch spans many frames over hundreds of milliseconds, so BOTH arms
saturate at one-or-more hold-offs per transfer under either hypothesis. B and C
were always going to look alike. **B's failure is therefore consistent with both
readings and evidence for neither** -- it is a null result from a test that
could not have come out any other way, which is precisely the trap this plan
pre-registered a warning about, walked into anyway, one arm later.

**MECHANISM SETTLES IT WHERE THE DOSE-RESPONSE COULD NOT, and it was already on
the table.** The Mac drives state 0 mid-frame from exactly one place:
`$41991C tst.b (a0)` reads SCC RR3 at byte 1 of every group and asserts HOFF
from it. There is no path by which cursor-redraw CPU cost causes the driver to
assert a hold-off -- CPU load can make the machine slow, it cannot make the
polling loop drive a phase line. And `reply-abandoned-in-TX_WAIT` is not a
generic distress flag: `TX_WAIT` is where the rewind parks the reply, so the bit
firing IS the hold-off path being taken. The CPU-load alternative fails on
mechanism rather than on data.

**A ZERO-COMPILE CONFIRMATION, if one is wanted: AppleTalk ON in the Chooser,
mouse held still.** That is an SCC interrupt source with no mouse and no
tracking cost. A FAILURE there would be decisive -- SCC interrupts alone
suffice. A clean result would be weak, because it would not distinguish "SCC is
not the trigger" from "this core's AppleTalk never generates SCC traffic in the
first place". Worth two minutes; not worth blocking the fix on. **NOT AVAILABLE: there is no
AppleTalk on the boot disk (checked 2026-09-05), so this confirmation cannot be
run on the current rig. Do not propose it again without putting AppleTalk on the
volume first.** The mechanism argument above is what carries the point.

**THE EXPERIMENT HAS DELIVERED WHAT IT WAS FOR: A RELIABLE REPRODUCER.** Any
mouse movement during an HD20 transfer stalls it and then bombs, on demand.
A bug that was intermittent for days is now switchable, which is what makes a
before/after test of the fix meaningful. Further trials of A/B/C/D would refine
a rate nobody needs. Go and fix it.

### Phase 5: the hold-off fix. HARDWARE-CONFIRMED 2026-09-05, `f157fcc8`

Items 1-5 of the fix shape above, written against the reproducer the mouse
experiment produced. Item 6 (the `$7F` NAK) is deliberately left out: it is the
one the review itself called low priority, `bad-checksum=0` in every capture,
and it would be untestable against hardware that never provokes it.

**`rtl/dcd_link.v` -- the transmit side no longer rewinds.**

- `TX_DATA`/`TX_LSB` on state 0 set a `txHoff` flag and KEEP SENDING. The group
  is finished; `txAddr`, `txSent` and `txSum` are untouched, so the finished
  group stays in the checksum. The three `*Grp` shadow registers existed only to
  rewind to and are DELETED rather than left dangling -- this project has been
  bitten by a dead port that read as live wiring once already this phase.
- A new `TX_HOFF` state acts on the flag AT THE GROUP BOUNDARY, which is the
  only place the ROM, the firmware and the March-85 timing figure all permit:
  release /HSHK to acknowledge, wait for state 1, re-assert, and re-enter
  `TX_SYNC` so a fresh `$AA` precedes the NEXT group. No filler byte -- the Mac
  hunts for the sync at `$419992` and would skip one anyway.
- `readData` now presents `txByte` in STATE 0 as well as state 1. Without this
  a transmitter that kept clocking would still have handed the Mac
  `{senseBit, 7'b0}` = `$00` for the four bytes it reads after asserting HOFF.
  Two separate bugs behind one symptom; the bench names them separately.
- `TX_DATA`/`TX_LSB` now ABORT on states 2, 3 and >= 4. That is the ROM's error
  exit (1 -> 3 -> 2), and without it the transmitter clocked bytes into a bus
  nobody was reading and `TX_WAIT` held /HSHK low in state 2 for ever.
- The receiver returns `rxState` to `RX_SYNC` when the handshake enters
  `RXH_READY`. State 3 out of state 2 is always a fresh command, so anything
  left over is stale by definition.

**`rtl/dcd.v` -- an abandoned frame is now distinguishable from a finished one.**

- New `txAbort`, a one-clock pulse from the link at all five abandon points.
  `txBusy` falls either way, so the command layer could not tell them apart and
  armed the next block of a multiblock read into a bus the Mac had already left.
  `C_SENDING` now drops `txArm` and returns to `C_IDLE`, cleared one state ahead
  of the link's `TX_IDLE` re-arm so the phantom-request trap cannot fire.
- **`replyStat` on failure is `$81`, not `$80`.** `$4197DA btst #24,d0` is on the
  LONGWORD at `$19E`, so it names BIT 0 of the status byte; the firmware agrees
  (`Op_Failed EQU 001h`). With `$80` a refused write was reported to the Mac as
  SUCCESS. `$81` satisfies the ROM and the document both. The wrong claim was
  also in `dcd.v`'s file header and in a comment beside the assignment, and both
  are corrected -- a comment asserting a hardware fact is exactly what this plan
  has learned to distrust.

**`sim/tb_dcd_link.v` -- the bench that could not have caught this.** Test 5
asserted the bug BY NAME ("the interrupted group RESTARTS, not continues") and
the file header taught it as a property. Both rewritten from
`$4198C4`-`$419998`. The new test 5 runs a FOUR-GROUP frame -- the old one had a
single group, and the Mac never holds off on the last group, so it posed a
question real hardware does not ask -- and holds off on a middle group and again
on the second-to-last, checking that the rest of the interrupted group still
arrives IN STATE 0 and is data rather than the sense bit, that a fresh `$AA`
follows, and that what comes next is the NEXT group. Tests 9 and 10 cover
`txAbort` and the receiver re-sync.

**MUTATION SWEEP, four mutants, all killed:** the rewind restored (6 fails), the
`TX_DATA` abort removed (3), `txAbort` left as a level (2), the `rxState`
re-sync removed (2). Two of the new assertions were themselves wrong first time
and were caught the same way: `check`'s name field truncated at 64 characters,
and "those bytes are DATA" PASSED VACUOUSLY because a timed-out `getByteTO`
leaves `X`, and `X !== 8'h00`. Both fixed before the RTL was touched.

**Benches: `tb_dcd_link` 89/89, `tb_dcd_read` 40/40, `tb_dcd_status` 75/75,
`tb_dcd_write` 133/133, `tb_dcd_disk` 41/41.** `scripts/read_probes.tcl` learns
`TX_HOFF` so it does not decode as `?6`.

**FIXED, CONFIRMED ON HARDWARE 2026-09-05 on `f157fcc8`, BOTH DIRECTIONS.** The
reproducer that failed on demand -- launch an application by mouse and keep
sweeping -- no longer does. The intermittent System Error that had been open
since the HD20 first booted is closed, and it was one defect: the transmit side
rewinding a held-off group that the ROM, the drive firmware and TashTwenty all
finish and continue past.

**The WRITE side was tested too (Daniel, same day), which matters more than it
sounds.** Every hardware write before this build happened with a mouse that was
necessarily mostly still, and the Mac-to-drive `RX_RESYNC` path had only ever
run in simulation -- so it was the one route in this change that hardware had
never exercised. It is now exercised and clean.

**MORE SOAK TESTING IS PLANNED BEFORE RELEASE (Daniel).** So read Phase 5 as
"confirmed, not yet soaked": a single clean pass in each direction is what is
recorded here, and the volume-integrity method to reuse is
`scripts/hfs_integrity.py` -- do not re-derive it. Note what the soak must now
control for that earlier ones did not: byte-exact copies kept passing all week
while this defect was live, because nothing in the method moved the mouse.
Any future HD20 soak should keep the mouse in motion throughout, or it is
testing the easy path again.

**COMPILED 2026-09-05: `f157fcc8`, archived as
`output_files/MacPlus_f157fcc8_hd20-holdoff.rbf`.** 0 errors, 119 warnings,
18m59s. Timing closes with margin in every corner -- setup +0.491, hold +0.191,
recovery +4.588, removal +0.807, minimum pulse width +1.098. The one Critical
Warning is the pre-existing RTC `.mif` depth mismatch (32 vs 20) and is
unrelated. NOT FLASHED.

**One new warning that IS ours, and it is cosmetic:**
`dbg_probes.sv(602): object "dcd_rxhs_d" assigned a value but never read`. The
rxHs ring that read it was replaced by the unanswered-opcode fields, so the
register is now dead. Harmless, synthesised away; clean it up on the next change
to that file rather than spending a compile on it. Recorded here because a dead
signal left unrecorded is how `iwm.v:319`'s dead `lstrb` port came to read as
live wiring earlier in this phase.

**THE HARDWARE TEST, which needs no design work: repeat condition C -- launch
MacWrite by mouse and keep sweeping.** That fails on demand on `6cc44fdc`, so
for the first time in this phase a fix has a before/after test that can actually
fail. Two things to watch beyond pass/fail:

- `reply-abandoned-in-TX_WAIT` should stay **0** through sustained movement.
  Read it with the WORKING-TREE `scripts/read_probes.tcl` now, not the pinned
  `6cc44fdc` copy -- the new script matches this bitstream and the pinned one no
  longer does. `TX_HOFF` decodes by name rather than as `?6`.
- `PDC2`'s unanswered-command line should print "none". The review found no
  caller for `$19`/`$1A` anywhere in `$417D30`-`$41A800`, so anything else there
  is a genuine surprise and worth stopping for.
- **The WRITE side is the untested half.** Every hardware write so far happened
  with a mouse that was necessarily mostly still, and the Mac-to-drive
  `RX_RESYNC` path has only ever run in simulation. Copy a large file TO the
  HD20 while sweeping, then reconcile with `scripts/hfs_integrity.py`.

### The 512K route: the HD20 startup diskette. PROCEDURE, being tested 2026-09-05

The artefact table above has always listed `HD_20_Startup.img` as "the 512K
route -- driver arrives as a `.Sony` patch from floppy", and no procedure or
result was ever recorded against it. Written down here so the result has
somewhere to land.

**WHY THE 512K IS DIFFERENT.** HD20 support in ROM arrived with the 128K ROM
(512Ke, Plus, SE, Classic, IIci, Portable). The plain 512K has the 64K ROM and
no DCD driver at all, so it comes from floppy: the file **`Hard Disk 20`** on
the startup disk, type/creator `ZSYS/MACS`, and a **`PTCH` carrier rather than
an INIT** -- it patches `.Sony` at boot. So **a 512K cannot boot FROM the
HD20**: code that loads after boot cannot boot you. The floppy boots, the patch
installs, the HD20 mounts, and the Mac continues from it.

**Procedure.** Model = Macintosh 512K (NOT 512Ke -- that boots an HD20 from ROM
and would not test this path). HD20 image on slot 5, `HD_20_Startup.img`
(`C:/temp/Mac/HD20/`, 409,600 bytes, raw 400K MFS, mounts as-is) as the floppy,
left WRITABLE because the MFS volume wants its DeskTop file. Mount first, then
reset.

**Expected, from the period documentation:** "Hard Disk 20 Startup." beneath
"Welcome to Macintosh."; after about 14 seconds the Mac EJECTS THE FLOPPY BY
ITSELF and carries on from the hard disk. Holding the mouse button at the
Welcome screen keeps it on the floppy. (System 3.0 showed "Using External
Drive." instead.)

**WHY THIS IS THE MOST INFORMATIVE UNTESTED THING LEFT.** Every byte of Phase
5's hardware validation so far was against the PLUS ROM's driver. The floppy
patch is a different implementation of the Mac side of the same protocol, and it
may use opcodes, timings or hold-off patterns the ROM driver never touches --
including the two the review found unreachable from the ROM (`$19`/`$1A`, whose
probe is now in the build and expected to print "none"). If it prints an opcode
here, that is the probe earning its place.

Two specifics with no prior coverage:

- **The auto-eject at ~14 s** is the Mac ejecting a floppy on its own
  initiative. Nothing tested so far has exercised that; the eject paths this
  project has touched were OSD-driven or the DCD-medium case from `2e5171e`.
- **Our DCD is ready immediately** -- there is no spin-up delay in `dcd.v`,
  where a real HD20 self-tests for ~15 s. That is more forgiving than real
  hardware rather than less, so it should not bite; but "too fast" is a
  direction with no coverage either. Unrelated to the ~4.1 s NOT READY window,
  which is the CD.

**Not model-gated:** the DCD lives in `iwm.v` on the external floppy port for
every model, keyed only off a mounted image, so a 512K gets the same device a
Plus does. Nothing in the RTL needs to change for this test.

| model | HD20 | status |
|---|---|---|
| 128K | no -- the `Hard Disk 20` patch will not load (source says so; it does not say why); `HD Diag` still exercises the link | not applicable |
| **512K** | **via the startup diskette** | **CONFIRMED 2026-09-05, `f157fcc8`** |
| 512Ke / Plus | from ROM | confirmed, `f157fcc8` |

**RESULT: IT WORKED, first attempt, exactly as the period documentation
describes it** (Daniel, 2026-09-05). The startup floppy boots, the `Hard Disk
20` patch installs, the Mac ejects the floppy by itself and carries on from the
hard disk.

**What that closes, and it is more than one thing:**

- **The DCD device is right against a SECOND, INDEPENDENT Mac-side driver.**
  Everything before this was the Plus ROM's `SonyDCD`. The floppy `PTCH` is
  Apple's other implementation of the same protocol, written for a machine with
  no DCD ROM at all, and our drive satisfied it with no RTL change. That is much
  stronger evidence that the device model is correct than any amount of further
  soak testing against the one driver would have been.
- **The Mac's own auto-eject works** -- a floppy ejected on the machine's
  initiative rather than from the OSD, which nothing had exercised.
- **A drive that is ready immediately is acceptable.** A real HD20 self-tests
  for ~15 s; `dcd.v` has no spin-up delay, and the patch did not mind.
- **The 512K gains a hard disk**, which makes it a materially more useful
  machine in this core than the bare floppy-only model Phase 3 delivered.

**Not captured:** the probe deck was not read during this run, so `PDC2`'s
unanswered-command line is unrecorded for the floppy driver. Worth one `arm` /
`take` next time a 512K is booted this way -- if that driver calls an opcode the
Plus ROM never does, this is the only configuration that would show it.

### MacWrite's free-space figure and its crash: a 1984 application, not a core defect

**Observed 2026-09-05 on `f157fcc8`.** On the ~32 MB HD20 volume, MacWrite
reports **16377K remaining** where the Finder reports **31540K available**.
Pointed at a large SCSI disk instead, **MacWrite itself crashes** -- the
application, not the system, and the Mac carries on.

**Daniel's reading, and it is the right one: an early application not coping
with later system and hardware.** MacWrite 1.x/2.x predate HFS entirely -- MFS
only, 400K floppies -- and are being asked about volumes eighty times larger
than anything that existed when they were written.

**Three independent supports, so this is not merely the comfortable answer:**

1. **Only MacWrite is affected.** The Finder reads the SAME volume through the
   SAME File Manager and gets it right. Nothing in the storage stack can give
   one application a wrong answer and another a correct one: by the time either
   asks, both are reading the same MDB fields.
2. **It is monotonic in volume size.** ~32 MB gives a wrong number but works;
   ~80 MB crashes. That is arithmetic degrading with magnitude. A device or
   driver fault would be size-independent, or would fail at a BLOCK ADDRESS
   rather than at a CAPACITY.
3. **The two symptoms unify.** The 16 MB figure and the crash are plausibly one
   overflow at two severities. One fault explaining both beats positing two.

**The number itself kills the first hypothesis considered.** 16377K is 16.0 MB
(16384K less 7K), not 20 MB (20480K). So it is not the HD20's size hard-coded
into MacWrite, and therefore not anything the drive reported. Our capacity
reporting is correct independently: `dcd_disk.v:116` gives
`blockCount = img_size >> 9` and `dcd.v:317` `Num_Blocks = blockCount - 1`.

**NO PRECISE ARITHMETIC IS OFFERED HERE ON PURPOSE.** Several plausible
mechanisms land near 16377K -- allocation-block-size assumptions, signed versus
unsigned free-block counts -- and none reproduces BOTH observed numbers exactly.
Any one of them written up here would be a plausible-sounding story rather than
an explanation, which is the habit this project has paid for repeatedly. If it
ever matters, disassemble MacWrite; until then the class of fault is enough.

**RULED OUT, and it was the one mechanism that could have linked the crash to
Phase 5: shared HPS sector-buffer corruption.** Every consumer of the shared
`sd_buff_wr` is gated on its own slot -- `dcd_disk.v:127`
`hps_we = sd_buff_wr & sd_ack`, `ncr5380.sv:603` `sd_buff_wr & io_ack[i]`,
`floppy_loader.v:114` `sd_buff_wr && sd_ack`. `ncr5380.sv:578` documents that
exact corruption being fixed on 2026-08-26 after it destroyed two mounted
volumes; the guard is hard-won and intact.

**Also confirmed incidentally: the HD20 and SCSI disks mount SIMULTANEOUSLY on
the Plus**, and MacWrite runs from the HD20. That co-existence had never been
stated as tested.

**Open, and cheap:** (a) which MacWrite version -- 1.x/2.x makes the story
airtight, 4.5/5.x is HFS-aware and a crash there would be more surprising;
(b) reproduce the SCSI crash with the HD20 UNMOUNTED, which exonerates the DCD
outright. Worth having in hand because a forum tester will ask.

**Not release-blocking, and nothing to fix.**

### The identity trailer is the DRIVE NAME, and it is user-visible

**Photographed 2026-09-05, System 6 booted from floppy, Erase Disk on the
mounted HD20:**

```
Completely erase disk named "3.2 32MB (P)" (MiSTer HD20)?
```

Volume name first, then the **12-byte trailer at identity offset 320** as the
drive. That string is ours: `rtl/dcd.v`'s `trailerChar`, a Pascal string --
length byte 11, then `MiSTer HD20`.

**This falsifies two comments we wrote.** `dcd.v:122` called the field "a Pascal
string; nothing reads it", and the function's own comment said "nothing in the
ROM reads them". The second was true OF THE ROM and wrong about the machine: the
system software reads it and shows it to the user. Both are corrected in place.
The assumption came from the other implementations -- BMOW's Floppy Emu treats
those bytes as frame padding and TashTwenty puts its credits there -- which is
reasonable evidence that nothing *needs* them, and no evidence at all that
nothing *displays* them. [[feedback-read-the-spec-for-historical-hardware]],
pointed at our own prose again: the two are not the same claim.

**IT ALSO CONFIRMS A GUESS, which is the better half of the finding.** The
format was inferred, and the comment said so honestly: "A Pascal string is the
shape 1.2a's neighbouring fields suggest, so that is what goes in." The Mac has
now rendered it correctly -- right length byte, right offset, no leading garbage
and no truncation. That is independent confirmation that the identity block is
byte-accurate all the way out to offset 320, obtained from a field nobody
expected to be read. A wrong length byte or a C string would have shown up as
mangled text in that dialog.

**CONSEQUENCE: it is a product name, not padding.** Whatever goes in those 12
bytes is what users see in Erase Disk, and presumably anywhere else the system
names the drive. `MiSTer HD20` is a good choice -- honest about what the device
is, and it will not be mistaken for Apple's own -- but it is now a
user-facing string and should be changed only deliberately. 11 characters is the
maximum the length byte and the field allow.

**Open, and cheap to answer next time a Get Info is to hand:** where else does
it surface? Get Info's `Where:` field is the obvious candidate, since that is
where a SCSI disk shows its driver identity
([[macplus-test-disk-driver-incompat]] uses exactly that field as its `RM 1.0`
fingerprint). If it appears there too, it is worth a line in the readme so users
know what they are looking at.

### Opcode $19: format is unsupported, and it fails GRACEFULLY. Found 2026-09-05

**The probe earned its place on its first real outing.** Erase Disk on the
mounted HD20, System 6 booted from floppy, build `f157fcc8`:

```
PDC2  UNANSWERED COMMAND: first opcode $19, 2 seen,
      reason: not dispatched from C_IDLE (opcode not implemented, or a guard failed)
PIFA  fetch# 68  PC=402422
PDCD  present=1 selected=1 /HSHK=released  commands=3+  last op=$19
PDCD  now: rxHs=ARMED  txState=TX_IDLE  cmdFSM=C_IDLE
PDCD  sticky: bad-checksum=0  reply-abandoned-in-TX_WAIT=0
```

`PC=402422` is the decoded landmark `$402420`-`$402426`: **a driver call
spinning on `ioResult`** ([[macplus-rom-pc-landmarks]]). The link is healthy in
every respect -- checksum clean, nothing abandoned, /HSHK released, command FSM
idle. `dcd.v` simply drops `$19`, so the reply never comes.

**IT IS NOT A HANG, and this document said it was for about ten minutes.** The
Mac's own timeout expires and it reports **"Initialization failed"** cleanly.
The drive is never wedged and the disk is not touched -- it booted again
afterwards. So the accurate statement is: **formatting an HD20 is unsupported
and fails gracefully after a long pause.** NOT release-blocking. One line in the
readme ("HD20 images must be pre-formatted") is a complete answer if we choose
not to implement it.

**THIS OVERTURNS THE DEMOTION OF [[macplus-dcd-unimplemented-opcodes]].** That
note was demoted the previous evening because no caller of `$419CEC`/`$419CF0`
exists anywhere in `$417D30`-`$41A800`. Hardware says a caller exists. The
resolution is almost certainly that **the Disk Initialization Package is
`PACK 2`, a resource loaded from the System file, not ROM code** -- so the
caller is in RAM and no ROM disassembly could ever have found it. The plan had
already written the lesson at its own line 1630: *"Negative searches over
hand-written 68000 code are weak evidence."* We made the mistake anyway.

To be fair to that review, it was right about what it was arguing: the hold-off
WAS the System Error, and fixing it fixed that. `$19` is a SECOND, SEPARATE bug
the same negative search wrongly buried. Two faults, not one.

**WHAT $19 IS, from the drive's own firmware.** `342-0343-B.asm:122`'s command
vector table indexes in HEX, and `$19`/`$1A` are its last two entries -- real
commands, which the reassembler never named:

```
DW D_RdTrack   ; 17 Read Track
DW D_WrTrack   ; 18 Write Track
DW L17e4       ; 19
DW L17ee       ; 1A
```

Both `Bank_Call` into a banked routine and then `jp Rd_Leave`, the READ exit
path that assembles a status word. The bodies are in a bank the reassembly does
not cover, so it cannot give the semantics -- the documented limit of that
source. It does correct one thing: `Read Device ID` and `Controller Status` are
`$04` and `$05`, NOT `$19`/`$1A` as an earlier note guessed.

**NEITHER SPECIFICATION DOCUMENTS IT, and that is now checked rather than
assumed.** Both 1.2a and the Mar85 protocol document scope themselves in their
own words to "the formats for Status, MultiBlock Read, and MultiBlock Write".
Searching both for initialize/format/verify/erase finds nothing Mac-facing.

**BUT THE ROM SPECIFIES THE WIRE FORMAT COMPLETELY**, which is all we need:

```
419CE8  moveq  #$3,  d3        ; three adjacent entry points into one sender
419CEC  moveq  #$1a, d3
419CF0  moveq  #$19, d3
419D08  andi.b #$3f, $19c(a1)  ; reply opcode must be ($19 & $3F) | $80 = $99
419D0E  suba.l a4, a4          ; NO receive buffer
419D16  moveq  #$0, d7         ; NO data expected
419D18  move.w #$64,   $1c0(a1); timeouts 100 / 18000 -- MUCH longer than
419D1E  move.w #$4650, $1c2(a1); Status's 10 / 10000
419D24  cmpi.b #$3, $19c(a1)   ; only Status is special-cased (a4=buffer, d7=332)
419D42  bsr.w  $4196ac         ; then the ordinary send / wait / validate path
```

So `$19` wants a **one-group, header-only reply with opcode `$99`** -- exactly
the shape of our MultiBlock Write reply, with a different opcode. `$1A` is
presumably the sibling at `$9A`. The long timeout corroborates a command that
does physical work.

**Three adjacent entry points is suggestive** -- the Disk Initialization Package
has exactly three operations, DIFormat / DIVerify / DIZero -- but that is a
guess and nothing should be built on it.

**FIX SHAPE (not applied):** answer `$19`/`$1A` from `C_IDLE` with a header-only
group, `replyOp = opcode | $80`, status byte, pads. A handful of lines in
`dcd.v`'s dispatch, reusing `K_WRITE`'s reply shape.

**WHAT THE ROM CANNOT TELL US, and how to settle it:** whether acknowledging
`$19` with success -- doing nothing physical -- lets Initialize proceed to a
valid HFS volume. An HFS initialise is mostly boot blocks, MDB, bitmap and
catalog written through ORDINARY block writes, and the low-level `Format Track`
is `$13`, a different command, so a bare acknowledgement may well be enough.
That is behavioural, not documentary. **Answer it and try it: the reproducer
takes seconds, the failure path has been watched to completion twice, and the
test disk is a disposable backup (Daniel).** If it fails, THEN fetch TashTwenty
and the Floppy Emu sources -- both authors solved this exact problem and a
second implementation is the right arbiter.

### Do we need the firmware?

**No, not to build it.** `firmware/` holds the drive's Z8 code -- four 8K `.bin`
dumps (`RENE_2.8E`, `RENE_2.8I`, `HD20_3371`, `342-0343-B`). Using those would
mean writing a Z8 CPU core to run them: a great deal of work to arrive at
behaviour the specifications already describe. We implement the drive
behaviourally, exactly as the SCSI targets were done.

**Two files in there are worth having anyway, as arbiters of last resort:**

- **`hd20.lst` (208K) -- a disassembly of that firmware. DOWNLOADED 2026-09-04,
  and it is much weaker than its name suggests.** It is a raw IDA auto-analysis
  dump of `342-0343-B`: 8,207 lines in which every symbol is `sub_XXXX` or
  `loc_XXXX`, and the only human annotation in the entire file is on the six
  interrupt vectors (`DAV1, IRQ1`; `IRQ3, Serial in`; `T0, Serial out`). It adds
  almost nothing over the raw `.bin`. Calling it "the definitive statement of
  what the drive did" was fair about the FIRMWARE and wrong about the LISTING --
  consulting it means doing the reverse engineering from scratch, in Z8
  assembly, an architecture nobody on this project knows.

  So treat it as a genuine last resort: worth opening only for a bounded,
  specific question that nothing else can answer (for example "what does the
  drive do with opcode `$04`?", which reduces to finding one dispatch table),
  never as general reading. Saved at `C:/temp/Mac/HD20/hd20.lst`.

- **`firmware/reassembly/FW3372_PS2013-10-02.zip` (1.0M) -- DOWNLOADED
  2026-09-04, and it is the real thing. Use this, not `hd20.lst`.** Extracted to
  `C:/temp/Mac/HD20/reassembly/`: `342-0343-B.asm` (the source), `.lst`, a PDF
  listing, `DefsHD20.inc`, and the original `.bin` -- whose MD5 matches the IDA
  dump byte for byte, so it is provably the same firmware. By Patrick (RWTH
  Aachen `asl` assembler), reassembling to Rev. 3372.

  **Quality: 6,608 lines, about half carrying comments, with real symbol names**
  (`HostCmndBuf`, `Get_HostParms`, `Cmnd_Ptr`, `Cur_Cyl`, `DiskStat`,
  `BadBlock`) and prose descriptions of each procedure. It is annotated
  reverse-engineering work, not a dump.

**Three things the reassembly settles, and one limit that matters:**

- **The HD20 firmware is DERIVED FROM WIDGET** -- the Lisa 2 / Mac XL internal
  drive controller -- which is why the author could reuse Widget's comments.
  That is a useful lineage: Widget is far better documented than the HD20, so a
  question the HD20 sources cannot answer may be answerable from Widget.
- **A controller supports TWO mechanisms**, distinguished at runtime from the
  servo response: **Nisha**, 5.25", 610 tracks, 2 heads -- which is exactly the
  geometry in the protocol document's identity block -- and **Rodime RO552**,
  3.5", 305 tracks, 4 heads. So "Nisha" is a mechanism, not an IWM, and the
  identity block we saw describes the Nisha-equipped variant.
- **The host byte stream is handled by the Z8's on-chip UART**, not by bit-
  banging: `DefsHD20.inc` configures Port 3 bit 0 as SIO in and bit 7 as SIO
  out, and the interrupt vectors are `IRQ3 = Serial in`, `IRQ4 = T0, Serial
  out`, so timer T0 paces transmission. `HostCmndBuf` is **8 bytes**, matching
  the command layout in the protocol document.
- **LIMIT: the source is incomplete, and the gap could matter.** The Z8's
  INTERNAL ROM (`341-0339-A`, the low `0x0000-0x07FF`) has never been dumped --
  the author does not own an HD20 -- and many calls go into that region with
  their meaning only guessed. So if a link-layer detail (7-for-8 packing,
  checksum, hold-off resumption) turns out to live in the internal ROM, this
  source cannot answer it and we are back to the specifications plus the Mac
  ROM. Establish early whether the answers we need are above `0x0800`.
- **`342-0414-A.jed` (51K) -- the PAL fuse map**, the exact equations. It
  supersedes a reading of the hand-drawn table if the phase decode is ever in
  doubt.

### Mac GUI / Mac 512K Blog, "Macintosh Hard Disk 20" (Dog Cow, 24 Oct 2017)

Found by Daniel: `applefool.com/se30/sites/Mac GUI HD20.html`. Note the host
serves it under `mcdermond.net`'s certificate, so an https fetch fails on a name
mismatch -- open it in a browser. Secondary source, but a careful one working
from the same Apple documents plus real hardware, and it settles several things.
("Rene" below is spelled with an acute accent in the sources.)

**THE ROM DRIVER IS CALLED `SonyDCD`.** The 128K ROM carries it, which is what
lets a Plus and a 512Ke boot an HD20 directly rather than loading a driver from
floppy, and it was kept in ROM for years afterwards. That is a name to search
for, and it confirms the structural guess: DCD lives with `.Sony`, not in a
driver of its own.

**Better still, the pre-128K-ROM driver is literally a `.Sony` PATCH.** The
"Hard Disk 20" file on the startup floppy is not an INIT -- it is type
`ZSYS/MACS` containing three `PTCH` resources: **TFS** (RAM-based HFS, ~24 KB),
a **Dispatch Kernel** (290 bytes), and **`.Sony`** (6.6-7.4 KB depending on
version). So on a 512K, DCD support arrives as a patch to the floppy driver --
strong corroboration that in ROM it sits inside `.Sony` too.

**CONFIRMS the 512 + 20 split, which this plan recorded as inference.** Each
sector is 532 bytes: 512 of data plus 20 tag bytes holding file number,
modification timestamp and type/creator code. Crucially the tags were meant for
disk-recovery software and **Apple later deprecated them** -- which is why the
Floppy Emu can synthesise zeroes and nothing notices. That makes the 512-byte
image recommendation above safe rather than merely convenient.

**CONFIRMS what the About-the-Finder period means**, also recorded here as
inference: the dot after the RAM size indicates the machine has the **128K
ROM**. Not "is a 512Ke". The reading was right and so was the narrowing.

**Corrects the geometry.** Nisha (610 cylinders, 2 surfaces) is the
Apple-designed mechanism the specifications describe -- but it is not clear the
HD20 ever SHIPPED with one. Production units used a **Rodime RO552: 305
cylinders, 4 surfaces**, same 20 MB, same 32 sectors per track, same 532-byte
sectors, and the firmware detects which is fitted from the servo response. So
the identity block extracted above describes the Nisha variant, and we must
choose which geometry to report. Since capacity, sector size and sectors/track
agree, it probably does not matter to the host -- but it is a deliberate choice,
not an oversight.

**Names, finally straight:** *Nisha* = the drive assembly. *Rene* = the
interface between the Mac and Nisha, i.e. the controller board carrying the Z8
(the author notes even he cannot tell whether Rene means the board or the HDA).
Both appear in our documents; neither is an IWM.

**Behaviour to design to:**

- The drive self-tests for about **15 seconds** after power-on, green light
  blinking. Independent of, and far longer than, the 2-second worst case the
  protocol document gives for answering a command during self-test.
- Boot flow on a 512K: insert the HD20 startup floppy; the screen shows "Hard
  Disk 20 Startup." beneath "Welcome to Macintosh."; after ~14 s the Mac
  **ejects the floppy** and continues from the hard disk. Holding the mouse
  button at the Welcome screen keeps it on the floppy. (System 3.0 showed "Using
  External Drive." instead.)
- **Daisy chain:** at most two hard disks followed by a floppy, and a second
  unit is not recognised unless the first is powered on at startup.
- **The HD20's icon lives in the controller's firmware**, so the driver fetches
  it from the device rather than supplying it.

**The best bring-up tool is named here: `HD Diag` (ReneDiag)** -- low-level block
access over the Rene interface -- and the author reports **it works even on a
128K**, where the ROM patch will not load. That is exactly what we want first: a
tool that exercises the DCD link without needing the file system, the driver
patch, or a bootable volume. `HD 20 Test` (by Rodger Mohme, ancestor of HD SC
Setup) is the other. Both correspond to the `diag/` floppies on bitsavers.

**Machines the author tested with a real HD20:** 512Ke, Plus, Classic and
Classic II worked; an SE/30 did not. A 128K with a Plus ROM fitted -- a "128Ke"
-- fully supports it.

**DECIDED 2026-09-05: we are NOT offering a "128Ke". Do not re-propose it.**
This paragraph used to call it "a configuration this core could trivially offer",
which is true and beside the point. It was never a shipped model -- it is a
128K board with the Plus ROM swapped in, a user upgrade -- and the model selector
exists to offer machines people actually had. A 128K that behaves like a Plus is
a Plus with less RAM. [[period-authenticity-matters]].

It stays in the record for one reason only, and it is an ANALYTICAL one: it is
the data point that falsifies "128K of RAM is too small for an HD20". Same
128 KB, and it works -- so the barrier for the plain 128K is not RAM as such but
the RAM-RESIDENT PATCH, whose bulk (the ~24 KB TFS resource) is HFS in RAM,
needed only because the 64K ROM has none.

### Borrowing from the Lisa core (Daniel's suggestion, 2026-09-04)

`MiSTer-devel/Apple-Lisa_MiSTer` (default branch `main`, a port of
alexthecat123's LisaFPGA) contains **`rtl/profile.sv`**, ~900 lines emulating a
ProFile hard disk. That is the same Apple family as the HD20 -- ProFile, Widget
and the HD20 share lineage, which is precisely why the HD20 firmware could reuse
Widget's comments -- and it shows.

**What transfers, and it is the part we would otherwise build from scratch:**

- **The 532-to-512 translation.** ProFile images there are raw 532-byte blocks,
  so a block spans up to THREE 512-byte SD sectors. `profile.sv` computes the
  byte offset as `(n<<9) + (n<<4) + (n<<2)` (i.e. `n * 532` by shift-and-add) and
  runs a **three-sector cache**, with read-modify-write on the write path. If we
  ever store true 532-byte blocks, that is the design, already working.
- **The HPS plumbing is signal-for-signal what we use**: `sd_lba`, `sd_rd`,
  `sd_wr`, `sd_ack`, `sd_buff_addr`, `sd_buff_dout`, `sd_buff_din`,
  `sd_buff_wr`, `img_mounted`, `img_size`. The integration pattern carries over
  directly.
- **Command-set shape as a semantic reference**: `$00` read block, `$01`-`$03`
  write variants, a spare/diagnostic table at block `$FF`, status bytes ahead of
  data. DCD's read / write / write-verify / status is the same family, so this
  is a useful cross-check on what the responses are FOR.

**What does NOT transfer -- and it is the bulk of Phase 5.** ProFile's host link
is a **parallel handshake**: `_CMD`, `_PSTRB`, `_BSY`, `R_W`, an 8-bit
bidirectional `PD` bus and a parity line. DCD is serial over the floppy port: a
phase-line state machine, 7-for-8 group encoding, sync bytes, fast ACK/NAK, and
per-group hold-off with the held-off group excluded from the checksum. There is
essentially no overlap. **Borrow the storage layer; write the link layer.**

**This reopens the image-format decision, which is now a genuine choice rather
than a constraint.** Earlier this section withdrew the "532-byte images" claim on
the strength of the Floppy Emu using plain 512-byte images with synthesized zero
tags. Both approaches are real and now both have working precedent:

| | 512-byte image (Floppy Emu) | 532-byte image (`profile.sv`) |
|---|---|---|
| image | reuses existing artefacts, incl. our blank `mac_20mb.vhd` | bespoke, must be created |
| HPS mapping | 1 block = 1 sector, trivial | block spans 3 sectors, needs the cache |
| tags | synthesized as zero; a tag written is not read back | full fidelity, tags round-trip |

**Recommendation: start with 512-byte images.** It reuses the artefacts we
already have and the sector path already in this core, and the Mac discards the
tags. Keep `profile.sv` as the proven blueprint for the 532 path if tags ever
turn out to matter -- the cost of that option just dropped a lot, because
somebody has already solved its hard part on the same platform.

### Test artefacts, and they are mountable TODAY

`diag/` holds three **400K floppy images** in Disk Copy 4.2 format --
`HD20_SEP_85.dc42`, `HD_20_Test.dc42`, `NISHA_HD_DIAG.dc42` -- plus
`HD-20_Tests_2.0.dc42` in the parent directory. These are not HD20 disk images;
they are Apple's HD20 diagnostic SOFTWARE, which makes them the natural bring-up
harness: programs whose whole purpose is to talk to a DCD device, running on a
machine whose ROM speaks the protocol. They mount in the existing floppy slots
once converted from DC42 to raw (`dc2dsk`, `releases/bin2dsk.sh`, already
documented in the README).

**A candidate hard-disk image already exists locally.** `C:/temp/Mac/mac_20mb.vhd`
is exactly 20,971,520 bytes -- 20 MB, HD20-sized -- and blocks 0 and 2 are both
zero, so it is blank rather than formatted. That is the right starting artefact:
mount it empty and let the Mac's own HD20 formatter write the volume, which is
how BMOW brought Floppy Emu HD20 mode up. By contrast `20MB.vhd` carries `'ER'`
at block 0 and `'PM'` at block 2 -- a Driver Descriptor Map and partition map,
the SCSI-era layout that postdates the HD20 -- so it is the wrong shape to start
from even though it is the right size.

**`IWM_Interface_PAL.pdf` may matter as much as the protocol docs.** We
implement the IWM and the external drive port, so the hardware side of how a DCD
device hangs off that connector is directly ours, not the drive vendor's.

**`HD-20_Tests_2.0.dc42` is Apple's own HD20 test disk** -- a ready-made
hardware acceptance artefact for this phase. It is Disk Copy 4.2 format, which
this core does not read directly, but the README already documents the
conversion (`dc2dsk`, `releases/bin2dsk.sh`).

**Open questions to settle from the ROM before any design:**
- Does an HD20 present a **bare HFS volume from block 0**, or a partitioned
  device? Our SCSI images carry a Driver Descriptor Map (`'ER'`) plus an Apple
  Partition Map, but both postdate the HD20 by a year, and HFS actually DEBUTED
  on the HD20. Believed bare, **not confirmed**. **PARTLY ANSWERED 2026-09-04:
  the conclusion holds for a better reason than the one guessed.** The blocks
  are **532 bytes**, so existing `.vhd` images are not reusable regardless of
  what the partition structure turns out to be -- the sector size alone settles
  it. Still open: the layout inside those blocks, and whether the extra 20 bytes
  are Apple tag bytes.

  **ANSWERED IN FULL 2026-09-04 -- and it is BARE HFS, as believed.** Daniel
  produced `C:/temp/Mac/HD20/320_32MB_volume.dsk`, and parsing it settles the
  layout from an artefact instead of an argument:

  - **33,553,920 bytes = exactly 65,535 x 512.** A whole number of 512-byte
    blocks and NOT of 532-byte ones (63,071.28), so the image is stored in
    512-byte sectors -- confirming the recommendation above.
  - **Block 0 is `'LK'`** -- HFS boot blocks, so the volume is bootable.
  - **Block 2 (offset 1024) is `'BD'`** -- the HFS Master Directory Block, right
    where a bare volume puts it.
  - **No `'ER'` Driver Descriptor Map and no partition map.** Bare HFS from block
    0, exactly as this plan guessed and unlike every SCSI image we ship.
  - Volume `3.2 32MB (P)`, 65,514 allocation blocks of 512 bytes, 3 files in the
    root, 30.9 MB free, attributes `$0100` (cleanly unmounted).

  **The size caveat is CLOSED (Daniel, 2026-09-04): the Floppy Emu serves up to
  2 GB in HD20 mode**, so `SonyDCD` plainly accepts capacities far beyond the
  20 MB a real unit had, and a 32 MB volume is unremarkable.

  **And the ceiling is the FILE SYSTEM, not the interface.** The DCD read and
  write commands carry a **3-byte block number**, so the protocol addresses
  16,777,216 blocks -- 8 GB at 512 bytes each. The 2 GB figure is the HFS limit:
  65,535 allocation blocks (a 16-bit count) times a 32 KB maximum allocation
  block. Worth knowing because it means capacity questions in this phase are
  HFS questions, and the identity block can honestly report whatever is mounted.

  That also explains the artefact's size rather than leaving it odd: 65,514
  allocation blocks of 512 bytes is just under the same 65,535 limit, so
  `320_32MB_volume.dsk` is "as large as HFS goes with 512-byte allocation
  blocks", not an arbitrary 32 MB.

  Separately, `count` in the read/write command is a SINGLE byte, so at most 255
  blocks move per command. That is a transfer-size limit, not a capacity one,
  but the engine has to honour it.

  **TEST REQUIREMENT: get one image LARGER than 32 MB, and use it.** A 32 MB
  volume is 65,535 blocks -- exactly 16 bits -- so every block number in the
  engine fits in a word and **a 16-bit truncation anywhere in the addressing
  path would pass every test built on the artefacts we have.** The block number
  on the wire is 3 bytes for exactly this reason, and only a larger image
  exercises bits 16-23. Daniel reports bigger images are available from the same
  source as `320_32MB_volume.dsk`.

  This is the same shape as two bugs this project has already been bitten by --
  the SDRAM region alias in `rtl/sdram_map.vh`, and the A17 forcing in
  `addrController_top.v` that had never once executed. A seam that only breaks
  past a power of two, with nothing crossing it. Cross it deliberately.

  **SUPPLIED, 2026-09-04: `C:/temp/Mac/HD20/608_2GB_volume.dsk`.**
  1,971,273,728 bytes = **3,850,144 blocks of 512, which needs 22 bits** -- so it
  exercises block-number bits 16 through 21 properly rather than sitting just
  over the line. Bare HFS again (`'LK'` at block 0, `'BD'` at block 2, no
  Driver Descriptor Map), volume `6.0.8 2GB (P)`, 65,254 allocation blocks of
  30,208 bytes.

  **Two things it independently confirms.** Bare-HFS-from-block-0 is now seen on
  two unrelated artefacts, so it is the HD20 convention rather than a quirk of
  one file. And the allocation block size of 30,208 bytes -- an odd number,
  chosen to keep the count under 65,535 -- is HFS visibly scaling to stay inside
  its 16-bit allocation-block count, which is the ceiling analysis above
  demonstrated rather than argued.

  **It also shows the protocol was designed for this.** The identity block's
  Capacity field is 24 bits (`0..$FFFFFF`, per the March document), so it can
  express 3,850,144 blocks with room to spare -- capacity, block number and
  addressing are consistently 24-bit across the design. Nothing here is being
  stretched beyond what Apple specified.

  **A caveat I wrote here was WRONG and is withdrawn (Daniel, 2026-09-04).** It
  claimed System 6.0.8 needs 1 MB and would not run on a 512Ke, making this a
  boot test only on a Plus or SE. Not so: **6.0.8 is the MAXIMUM system for the
  512Ke and it runs there.** The limit is practical -- with 512K there is very
  little left for applications -- not a floor that stops it booting. So this
  volume is a boot test on a 512Ke as well.

  Two lessons, since this is the same mistake in two forms. Daniel had already
  reported running 6.0.5 on the Ke earlier the same day, so the contradiction
  was in the conversation before I wrote the claim. And the underlying error was
  conflating the **512K** (64K ROM, cannot run System 6 at all, since HFS needs
  the 128K ROM) with the **512Ke** (128K ROM, runs it fine but tightly). Those
  two models differ by exactly the thing this whole project is about; do not let
  the shared "512" in the names blur them.

  **Authenticity note, so the two do not get confused:** a real HD20 is ~20 MB,
  so large volumes are a CONVENIENCE feature, not accuracy -- the Floppy Emu
  offers them and nobody minds. Whether this core exposes them is a separate
  decision from whether the engine handles them correctly. It must handle them
  correctly either way, because the identity block reports whatever is mounted.

  **THE STARTUP DISK IS HERE TOO**, `C:/temp/Mac/HD20/HD_20_Startup.img`
  (Daniel, 2026-09-04) -- and it needs no conversion: **409,600 bytes, raw 400K,
  `'LK'` boot blocks, MFS volume (`$D2D7`) named `HD 20 Startup`**, 10 files, 69
  KB free. It mounts in this core's existing floppy slots as-is. Contents:

  | type/creator | file |
  |---|---|
  | `ZSYS/MACS` | System |
  | `FNDR/MACS` | Finder |
  | `ZSYS/MACS` | **Hard Disk 20** -- the driver, and note the type codes match the Mac GUI article exactly: not an INIT, a `PTCH` carrier |
  | `APPL/HDTS` | **HD 20 Test** -- Rodger Mohme's utility, ancestor of HD SC Setup |
  | `APPL/DMOV` | Font/DA Mover |
  | `PRES/IWRT` | ImageWriter |
  | | DeskTop, Note Pad File, Scrapbook File, Clipboard File |

  So the diagnostic tooling is already on the startup disk; the bitsavers
  `diag/` floppies are a bonus rather than a prerequisite.

  **THE ARTEFACT SET FOR PHASE 5 IS NOW COMPLETE**, and it covers every path:

  | artefact | what it tests |
  |---|---|
  | `HD_20_Startup.img` (400K MFS) | the 512K route -- driver arrives as a `.Sony` patch from floppy |
  | `320_32MB_volume.dsk` | READ path and booting, on a 512Ke/Plus via ROM `SonyDCD` |
  | `mac_20mb.vhd` (blank 20 MB) | FORMAT and the WRITE path, by letting the Mac initialise it |
  | `HD 20 Test` (on the startup disk) | low-level exercise without needing a bootable volume |

  Nothing further needs to be found or built before implementation starts.
- Which models can boot it. HD20 boot support is believed to live in the 128K
  ROM, i.e. Plus and 512Ke; the 64K-ROM machines would need the HD20 system
  software from floppy, if at all. Confirm from the ROM. **ANSWERED: 512Ke and
  Plus from ROM, 512K from the startup diskette, all three confirmed on hardware
  2026-09-05; 128K not applicable.**

**Shape.** A new protocol engine on the external floppy port -- different
framing and command set, sharing only the physical lines -- plus a storage
backend and hardware bring-up. Comparable in size to the SCSI work, and it
occupies the external drive slot alongside the internal floppy.

## The ROM's startup disk search, disassembled (2026-09-04)

**Why this exists.** Daniel mounted two bootable floppies on a 128K and it
booted from the SECOND one, and asked whether that is how the machine is
supposed to behave. Rather than reason from the symptom, the ROM was
disassembled -- [[feedback-read-the-spec-for-historical-hardware]], and here the
ROM *is* the specification, since Apple never published the boot search. The
answer turned out to be "not a bug", but the disassembly is worth keeping: it
is the exact code path an HD20 has to appear in, so it is Phase 5's starting
point rather than a one-off.

**Method.** capstone `CS_ARCH_M68K` over the images in `C:\temp\Mac\ROMS`, the
same technique that produced the Sad Mac decoder in Phase 3. Both families were
read: `28BA4E50` (the 64K image actually installed as `boot2.rom`) and
`4D1F8172` (the Plus image, `boot0.rom`). The entry points were found by
searching for the boot-block signature `'LK'` = `$4C4B`, which occurs exactly
ONCE in each image.

### 64K ROM (128K / 512K / 512Ke): alternate between two drives, forever

Boot loop at `$4004A0`, in flow order -- so the addresses are not monotonic:

```
$4004A0  lea      $4008C8(pc),a0   ; "insert disk" icon
$4004A6  moveq    #1,d6            ; d6 = drive 1 = INTERNAL
$4004A8  btst     #4,$020B.w       ; boot-drive override flag
$4004AE  beq      $4004B2
$4004B0  addq.w   #1,d6            ;   if set: start at drive 2 = EXTERNAL
$4004B2  moveq    #3,d3            ; toggle mask
$4004B6  tst.b    $0172.w          ; MBState
$4004BA  bpl      $400500          ;   mouse button DOWN -> eject, do not boot
$4004BC  move.w   #$FFFB,$18(a0)   ; ioRefNum = -5, the .Sony driver
         move.w   #1,$2C(a0)       ; ioPosMode = fsFromStart
         clr.l    $2E(a0)          ; ioPosOffset = 0
         move.l   #$10000,$20(a0)  ; ioBuffer
         move.l   #$400,$24(a0)    ; ioReqCount = 1024 = blocks 0 and 1
         move.w   d6,$16(a0)       ; ioDrvNum  <- the drive being tried
         move.w   d6,$0210.w       ; BootDrive
$4004E8  _Read
$4004EA  beq      $400546
$4004EE  cmpi.w   #$FFBF,d0        ; -65 offLinErr (no disk) -> just retry
$4004F2  beq      $40051C
$4004F4  cmpi.w   #$FFC0,d0        ; -64 noDriveErr (no drive)
$4004F8  bne      $400500
$4004FA  eor.w    d3,d6            ;   toggle once...
$4004FC  moveq    #0,d3            ;   ...then STOP toggling: stick to the
$4004FE  bra      $40051C          ;   drive that actually exists
$400546  cmpi.w   #$4C4B,(a1)+     ; 'LK' boot-block signature -> boot
$40054A  bne      $400500          ;   readable but not bootable -> eject
$400500  move.w   #7,$1A(a0)       ; csCode 7 = EJECT
         _Control
         lea      $4008E6(pc),a0   ; switch to the "bad disk" X icon
$400540  eor.w    d3,d6            ; alternate 1 <-> 2 and go round again
$400542  bra      $4004BC
```

What this establishes:

- **Drive 1 (internal) is tried first**, drive 2 (external) second.
- **The search never gives up.** `eor.w d3,d6` with `d3 = 3` flips 1 <-> 2 on
  every pass, with the flashing-disk icon and a delay between passes. A machine
  sitting at the "insert disk" screen is polling BOTH drives continuously, so
  **whichever disk arrives first wins, regardless of which drive it is in.**
- **A readable but non-bootable disk is EJECTED** and the search moves on.
- **`noDriveErr` (-64) is how the ROM prunes a drive that is not there**: it
  toggles once and zeroes the toggle mask, sticking to the surviving drive.
- **Mouse button held at startup ejects instead of booting** (`MBState`,
  `$0172`). That is documented 1984 behaviour, and it is what confirms the
  low-memory decoding above is right -- including `BootDrive` at `$0210`.

### Plus 128K ROM: walk the drive queue

Boot loop at `$4006E4`. Structurally different, same outcome:

```
$4006E4  move.l   $030A.w,d6       ; DrvQHdr.qHead -- the drive queue
$4006EA  btst     #4,$020B.w
$4006F0  bne      $40077C          ;   if set: skip this element
$400712  movea.l  d6,a1
$400714  move.w   $8(a1),d3        ; dQRefNum  -> ioRefNum
$400720  move.w   $6(a1),d3        ; dQDrive   -> ioDrvNum
$400728  move.w   d3,$0210.w       ; BootDrive
$40072E  tst.b    $0172.w          ; MBState, same eject-on-mouse-down
$400734  _Read
$400738  cmpi.w   #$4C4B,(a6)      ; same 'LK' check
$40077C  jsr      $407D40(pc)      ; next queue element
```

So the Plus boots **in drive-queue order** -- installation order, i.e. internal
floppy, external floppy, then whatever the SCSI driver enqueued.

**This is the Phase 5 hook.** An HD20 is bootable on a Plus/512Ke exactly if
its driver puts a `DrvQEl` in that queue with a working `dQRefNum`; the boot
code itself needs no HD20 knowledge at all. That is a much smaller target than
"teach the ROM about DCD", and it is the first thing to confirm once the DCD
disassembly starts.

### `$020B` bit 4: a real override, provenance unknown

Both ROM families consult `btst #4,$020B` before the search: the 64K ROM starts
at drive 2 instead of drive 1, the Plus ROM skips the first queue element.
**Neither ROM ever writes it.** A sweep of every absolute-addressed operand in
`$0200`-`$020F` across both images found reads only, and no low-memory clear
loop covers the address, so its value at boot is whatever the memory test left
in DRAM.

Two things NOT established, so do not assert them: what the byte is called (it
could not be matched to a documented low-memory global), and that nothing sets
it -- the sweep would not catch a write through a walking pointer. Treat
"nothing initialises `$020B`" as "no absolute writer found", which is weaker.

### The two-floppy observation: mount order, not a defect

The most likely explanation, and Daniel's own: the disks were mounted one at a
time while the machine was already looping at the flashing-disk screen, and the
loop takes whichever disk appears first. **A real 128K does exactly the same**,
so there is nothing to fix.

Two conditions have to hold before an observation like this tests drive
PREFERENCE at all, and both are easy to miss:

- **Both images mounted BEFORE the boot search starts** -- mount both, then
  Reset & Apply. Only then must drive 1 win.
- **The mounts allowed to settle.** `insertDisk` is held LOW for the whole time
  `floppy_loader` is staging an image into SDRAM -- hundreds of ms for an 800K
  image -- so a reset issued straight after a mount hands the ROM an internal
  drive that honestly reports "empty", and it steps to drive 2.

If a deliberate both-mounted-then-reset trial ever DOES boot drive 2, `$020B`
bit 4 is the first suspect, and the value is readable through the probe deck.
Testing this on the early Systems is awkward for an unrelated reason: System
1/2/3 have no Shut Down command, so the procedure is eject, wait for the disk
LED to settle (so `floppy_sd_writer` has flushed its shadow to SD), then
Reset & Apply.

### One genuine deviation found on the way

`rtl/floppy.v:134` reports `DRVIN`, `INSTALLED` and `READY` as "present" for
**both** drives unconditionally, whether or not an image is mounted. On real
hardware an absent external drive answers `noDriveErr` (-64) -- which is
precisely the case the 64K loop above uses to stop alternating and settle on
the drive that exists. The core never gives the ROM that signal, so it will
alternate between a real drive and a phantom one forever.

Not release-blocking, and not the cause of the two-floppy observation. But it
is the same class of problem as Phase 4 -- reporting a device that is not there
-- so it should be fixed alongside the SCSI gate rather than separately.

## Code quality for upstream: the lookup-table defect, and an audit for its siblings

**Daniel's instruction, 2026-09-05, and it REVERSES the earlier call.** After
PR #21 merged, Sorgelig wrote: *"it would be good to reduce AI slop in the code.
cd_vol_lut.vh is very ugly. Not how HDL should be written. It must be a
BRAM/MLAB driven look up with proper clocked pipeline. It's very hard for fitter
to fit this monster lookup table!"* The decision then (2026-08-30) was **leave
it, do not bother him** -- he had merged it as-is, so it was a quality bar being
set rather than a change request. That decision is now withdrawn: fix it, and
audit the rest of our code for the same class of problem.

This is a good time to do it. The file is being reopened anyway for the `mac128k`
release, so the reason the earlier decision gave for leaving it ("fix it only if
the file is reopened for another reason") is now satisfied on its own terms.

### 1. The named defect: `cd_vol_lut.vh`

**The `case` statement is NOT the problem. The missing output register is.**
Measured 2026-08-30, standalone `quartus_map` + `quartus_fit`, same device and
version, two harnesses around the IDENTICAL table differing only in whether the
lookup output is registered:

| form | ALMs | RAM blocks | mem bits |
|---|---|---|---|
| combinational (what ships) | **109** | 0 | 0 |
| registered (same table) | **5** | 2 | 8,192 |

Given a registered output, Quartus 17.0 infers the ROM by itself
(`altsyncram:Ram0_rtl_0`/`Ram1_rtl_0`). `cd_audio.sv:1336` reads it into a
`wire`, and a combinational output cannot be a memory read, so the mux tree is
forced into logic -- twice, once per channel.

The fix is about six lines and does not touch the table data, so the measured
fifth-power volume law survives bit for bit:

```verilog
reg [15:0] ap_gain_l, ap_gain_r;
always @(posedge clk) begin
    ap_gain_l <= cd_vol_gain(ap_vol0);
    ap_gain_r <= cd_vol_gain(ap_vol1);
end
```

The added cycle is free: `ap_vol0/1` only move on a MODE SELECT of page 0x0E.

**Two things NOT to do.** Do not argue the severity -- 109 ALMs is 0.55% of
19,799 and the table uses zero memory bits, so it cannot have driven M10K
placement pressure, but the defect is real, his prescribed fix is the right one,
and winning that argument costs goodwill and buys nothing. And do not reply
"that came from MacLC": true, but it is deflection, it drags a third party into
criticism aimed at us, and we submitted it regardless.

**PROVENANCE, which matters for where the fix belongs.** `cd_vol_lut.vh` is
`MiSTer-devel/MacLC_MiSTer` commit `0089c82` (Dani Sarfati, 2026-07-30), still
live at MacLC HEAD in the same combinational form at the same line numbers. Our
copy differs by two lines, both from the PR's encoding audit. Fixing it here is
right because we shipped it; whether it is also fixed in MacLC is Dani
Sarfati's call, not ours to make on their behalf.

### 2. The audit: what else looks like this

Surveyed 2026-09-05 across every file `mac128k` adds or changes under `rtl/`
and `MacPlus.sv`. The pattern to look for is NOT "a big case statement" -- it is
**a wide lookup read combinationally into a `wire`**, which is what forces the
mux tree into logic.

**ONE genuine sibling, and it is ours:**

- **`rtl/floppy_track_decoder.v:179`, `wire [6:0] rl = rev_lookup(idata);`** --
  a 256-entry reverse GCR table, 8 bits in and 7 out, read straight into a wire.
  Structurally identical to `cd_vol_lut` at about a quarter the width
  (256x7 = 1,792 bits against 8,192). By the measured ratio that is tens of
  ALMs, not hundreds. **MEASURE IT BEFORE CHANGING IT** -- the whole point of
  the `cd_vol_lut` measurement was that the obvious culprit (the case) was not
  the cause, and a second guess deserves the same treatment. Registering it
  means finding a cycle in the decoder's timing, which is real work rather than
  six lines, so the measurement decides whether it is worth it.

**CHECKED AND FINE -- recorded so the audit is not repeated:**

- **`rtl/disk_pwm_duty.v:39` `pwm_convert`** -- 64 entries, 6 bits in and 6 out
  (384 bits), and it already feeds a REGISTER through a deliberate three-stage
  pipeline that exists because the combinational form missed setup by 3.945 ns.
  Right as built.
- **`rtl/dcd_icon.vh`** -- 32 entries by ROW rather than 256 by byte, and only
  13 rows are non-zero with the mask collapsing to two distinct values. The
  minimiser eats nearly all of it.
- **`rtl/cd_audio.sv:1410`'s forced `(* ramstyle = "M10K,no_rw_check" *)`** --
  the stated motivation is stale (below) but forcing these arrays into M10K is
  still the right call in a design sitting at 24% M10K. Leave it.
- **`scsi.v`'s `cd_*_byte` response functions** -- tens of entries each,
  ordinary response muxes, not tables.

### 3. THE FALSE JUSTIFICATION, WHICH SPREAD INTO OUR OWN FILES

This is the finding worth more than the ALMs. **"RAM blocks are the scarce
resource in this design" is not true of this design, and it appears in four
places:**

| file | claim |
|---|---|
| `rtl/cd_vol_lut.vh:14` | "never an M10K -- RAM blocks are the scarce resource" |
| `rtl/cd_audio.sv:1419` | "the device is at 513/553 M10K blocks (93%)" |
| `rtl/dcd_icon.vh:57` | the same words, **and it cites `cd_vol_lut.vh` as its authority** |
| `rtl/disk_pwm_duty.v:37` | "synthesises to logic, never an M10K -- RAM blocks are the scarce resource" |

**513/553 (93%) is MacLC's figure. This core fits at 131/553 (24%).** The claim
was rational where it was written and became false the moment it crossed repos
-- and then we repeated it, from memory, in two files we wrote ourselves this
year, one of which explicitly cites the criticised file as its reason.

That is the actual slop: not the case statement, but a measurement that expired
and kept being quoted. **Correct all four comments, and where a justification
rests on a number, cite the number and where it was measured.**
[[feedback-read-the-spec-for-historical-hardware]] is the same lesson pointed at
our own prose: distrust a comment asserting a fact, including one we wrote.

### 4. `mac128k` IS BEHIND MASTER ON EXACTLY THE CLEANUPS THIS IS ABOUT

`master` has one commit `mac128k` does not: `51cf977`, the squashed PR #21. The
functional content is already in `mac128k` unsquashed -- but the PR-preparation
cleanups are NOT. Demonstrated: `master:rtl/cd_vol_lut.vh` is pure ASCII, while
`mac128k`'s still carries **two raw `0x97` cp1252 em-dashes, which make the file
INVALID UTF-8**. `master` fixed them during the strip; the fix never came back.

So the next PR off `mac128k` would re-introduce encoding defects that were
already fixed once. **Before any upstream submission, diff `mac128k` against
`master` on the shared files and re-apply what the strip cleaned.** Not a
rebase -- the two histories are deliberately different shapes -- a file-by-file
reconciliation of the cleanups.

Non-ASCII more broadly: `addrController_top.v`, `scsi.v`, `cd_audio.sv` and
`dataController_top.sv` contain non-ASCII too, but all of it is VALID UTF-8
(em-dashes, plus-minus, section signs, micro, approximately-equal). Only
`cd_vol_lut.vh` is actually malformed. Whether to flatten the rest to ASCII is a
house-style question, not a defect -- decide it once rather than per file.

### 5. What was NOT said, and must not be invented

Sorgelig wrote "slop" generally and gave exactly ONE example. A hypothesis was
recorded on 2026-08-30 that he might also mean comment density (`cd_mix.v` 51%,
`scsi.v` 42%, `floppy_write_committer.v` 38%, `ncr5380.sv` 37%, much of it dated
lab-notebook narrative). **That remains a hypothesis and he has never said it.**
Do not restructure the comments across the core on the strength of it. If it
matters it can be asked -- but the earlier judgement that unsolicited follow-up
reads as fussing applies to questions as well as to patches.

### Order of work

1. `cd_vol_lut` output register -- six lines, measured, known win.
2. The four false justifications -- comments only, no RTL.
3. `cd_vol_lut.vh` encoding, taken from `master`'s copy.
4. MEASURE `rev_lookup`; fix only if the number justifies the timing work.
5. The `mac128k`-versus-`master` cleanup reconciliation, before any PR.

Items 1 to 3 are one compile between them, and 1 is the only one that changes
anything at all about behaviour. **The gate is unchanged: benches, then ask
before compiling.**

## Deferred: grey out the menu items a model cannot use

**Daniel's idea, 2026-09-04, and DEFERRED ON HIS INSTRUCTION: do not spend a
compile on this alone -- fold it into the next stage's build.** Recorded in full
here so the OSD research is not repeated.

A 128K offers Mount CD-ROM, two SCSI slots, CD Volume and a Memory option, and
every one of them is inert on that machine. They should be greyed out.

**The mechanism, confirmed from Main_MiSTer rather than inferred**
(`menu.cpp:1958-1968`):

```c
int flg = (hdmask & (1 << user_io_hd_mask(p + 1))) ? 1 : 0;
if (p[0] == 'H') h |= flg;         // hide when the mask bit is 1
if (p[0] == 'h') h |= (flg ^ 1);   // hide when the mask bit is 0
if (p[0] == 'D') d |= flg;         // GREY when the mask bit is 1
if (p[0] == 'd') d |= (flg ^ 1);   // grey when the mask bit is 0
```

Prefixes chain (`p += 2` in a loop), the bit index is spelled like a status bit
(`user_io_hd_mask` calls `user_io_status_bits`), and the mask arrives from the
core on `status_menumask`, a 16-bit input on `sys/hps_io.sv:122`.

**This also explains a landmine already recorded in our own CONF_STR.** The
comment on the CD-ROM slot says an `h` prefix "hid the item outright". It would:
lowercase `h` hides when the mask bit is ZERO, and `MacPlus.sv` does not drive
`status_menumask` at all, so every bit is zero. The convention was never wrong;
the mask was simply unconnected. Delete that comment when this lands.

**Design:**

| mask bit | meaning | greys |
|---|---|---|
| 0 | `~scsiPresent` | `SC0`, `SC1`, `SC4`, `OI` CD-ROM Drive, `OFG` CD Volume |
| 1 | `ramSoldered` | `O4,Memory,1MB,4MB` |

Uppercase `D0`/`D1`, so a set bit reads as "unavailable".

Three decisions already taken:

- **Derive the mask from `mac_model`, never from a second table in MacPlus.sv.**
  Bit 0 is `scsiPresent` inverted; bit 1 wants one new output (`ramSoldered` --
  the SIMM-socket fact that currently exists only as prose in that file). Two
  independently written encodings of one fact drift apart silently, which is the
  whole reason `rtl/rom_word_addr.v` exists.
- **Feed it from the LIVE `status[3:1]`, not the latched `status_model`.**
  Greying is a menu affordance, not a hardware strap, so it should follow what
  the user just picked rather than waiting for Reset & Apply. That means a
  second `mac_model` instance for the mask -- a five-entry combinational case,
  a handful of LEs, and it reuses the table instead of copying it.
- **No `v` bump.** `D` prefixes move no status bit and change no saved config.

**Limit worth stating:** greying is cosmetic. It prevents a new mistake; it does
not unmount an image a saved config already carries. The core ignores it either
way, which is what the hardware tests showed.

## Verification

House ladder applies unchanged: a failing test before the fix, iverilog
simulation (`C:\iverilog` - not verilator; MacLC's benches are unusable here),
then hardware. Watch for the `@(posedge clk); #1;` foot-gun in any new bench.

The standing gate holds: **no merge to master and no full Quartus compile
without asking first.**

Each phase carries its own pass criterion, stated with the phase above. Phase 1
is the only one verified purely negatively, because it delivers no model.
