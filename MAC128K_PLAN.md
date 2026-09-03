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

## What is missing, in full

| # | item | file | size |
|---|---|---|---|
| 1 | ROM delivery for a third (and fourth) image | `MacPlus.sv:1018,1042` | design decision, then small |
| 2 | Model selector 1 bit -> **3** bits (and moved to bits 1-3), straps derived from it | `MacPlus.sv:89,136,641,698,1066` + `rtl/mac_model.v` | **DONE** `21c0460` |
| 3 | `configRAMSize` reachable for 128K/512K | `MacPlus.sv:338` | **DONE** `21c0460` |
| 4 | RAM size derived from model, not chosen, for the soldered-RAM machines | `rtl/mac_model.v` | **DONE** `21c0460` |
| 5 | Gate SCSI off for non-Plus models | `MacPlus.sv:632,694,1098` | small; accuracy only - the 64K ROM never looks, so it is not needed for booting |
| 6 | Delete the dead `configROMSize` localparam | `MacPlus.sv:336` | **DONE** `21c0460` |
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

**Phase 3 - Mac 512K, then Mac 128K. RTL/sim DONE, `83cd840`; hardware test
2026-09-03 HUNG, and the two causes are fixed in RTL/sim -- see "Phase 3's boot
hang" below. Hardware RE-TEST still outstanding.** The first authentic
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
