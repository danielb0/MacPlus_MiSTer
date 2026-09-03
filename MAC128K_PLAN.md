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

The second approach has a wrinkle the first does not: the 128K and the 512K
shipped **different** 64K ROMs (see below), so a full family wants two 64K
images, not one. That pushes toward widening.

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

The two 64K images being **distinct** is the point that matters for design: a
128K and a 512K are not the same machine with a different RAM strap. If both are
wanted, that is two ROM slots or a reload between model changes.

## What is missing, in full

| # | item | file | size |
|---|---|---|---|
| 1 | ROM delivery for a third (and fourth) image | `MacPlus.sv:1018,1042` | design decision, then small |
| 2 | Model selector 1 bit -> 2 bits, and `configROMSize` driven from it | `MacPlus.sv:89,134,620` | small |
| 3 | `configRAMSize` reachable for 128K/512K | `MacPlus.sv:338` | trivial |
| 4 | Couple RAM options to model (a 128K cannot have 4MB) | `MacPlus.sv:89,338` | small, mostly OSD |
| 5 | Gate SCSI off for non-Plus models | `MacPlus.sv:632,694,1098` | small |
| 6 | Delete the dead `configROMSize` localparam | `MacPlus.sv:336` | trivial |

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

Ordered so that the cheapest authentic model lands first and each phase is
independently testable.

**Phase 0 - baseline.** Record what Plus and SE do today on the test rig
(s0=mac_80mb, s1=HD20 boots, s4=the ISO) so any regression in later phases is
attributable. No RTL change.

**Phase 1 - Mac 512Ke.** Configuration only: a Plus with 512K of RAM and SCSI
still present. Touches items 2, 3, 4, 6. Needs no new ROM - the 512Ke shipped
the same 128K ROM. This is the phase that proves the model-selector widening
without depending on the unresolved ROM-delivery design.

**Phase 2 - 64K ROM delivery.** Decide and implement the multi-slot scheme
(item 1). Verifiable in simulation before hardware: a bench that asserts ROM
reads at $400000 land on the right SDRAM words for each model.

**Phase 3 - Mac 128K and 512K.** Wire `configROMSize == 2'b00` to the selector
and expose the 128K RAM size. Depends on Phases 1 and 2. Needs an MFS boot
image on the rig.

**Phase 4 - SCSI gating and polish.** Item 5, plus whatever the open questions
above turn into.

## Verification

House ladder applies unchanged: a failing test before the fix, iverilog
simulation (`C:\iverilog` - not verilator; MacLC's benches are unusable here),
then hardware. Watch for the `@(posedge clk); #1;` foot-gun in any new bench.

The standing gate holds: **no merge to master and no full Quartus compile
without asking first.**

Phase 1 has a clear hardware pass criterion - a 512Ke boots System 6 from the
HD20 image at s1 with 512K of RAM reported in "About the Finder", and the Plus
and SE models are unregressed on the same rig.
