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

**Physical layer -- the DB-19 lines are REPURPOSED, not shared.** This is the
thing that makes DCD a different engine rather than a floppy variant:

| DB-19 | floppy meaning | DCD meaning | owner |
|---|---|---|---|
| 11 | PH0 | handshake state bit 0 | IWM |
| 12 | PH1 | handshake state bit 1 | IWM |
| 13 | PH2 | handshake state bit 2 (N/C on drive side) | IWM |
| 14 | PH3 | **/Enable** -- selects among daisy-chained DCDs | IWM |
| 15 | /WrReq | **Read Data** (drive -> Mac) | |
| 16 | HDSel | **Write Data** (Mac -> drive) | VIA 6522 |

So the data path is HDSel out and /WrReq in, with PH0-PH2 as a 3-bit state bus
driven by the Mac, which is master throughout. High bit of every byte always 1,
net 428.38 kbps.

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
-- fully supports it, which is a configuration this core could trivially offer
and which real hardware apparently supported too.

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
  software from floppy, if at all. Confirm from the ROM.

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
