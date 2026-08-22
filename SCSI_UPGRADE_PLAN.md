# Plan: SCSI Subsystem Upgrade for MacPlus_MiSTer

Porting the SCSI work from [MacLC_MiSTer](https://github.com/MiSTer-devel/MacLC_MiSTer)
into the Plus core: SCSI-1 conformance fixes, an AppleCD-compatible CD-ROM target,
and CD audio.

Branch: `scsi-upgrade` (based on `floppy-write`, not `master` — see §6).

Origin: the LC core's author, after the floppy-write forum post, offered the work
directly — *"I've done a fair bit of work on the TG68K cpu, scsi.v and ncr5380 in
the Macintosh LC core... Feel free to grab and update the MacPlus core, I used this
as a reference when creating the LC!"*

---

## 1. Where the core stands today

`rtl/scsi.v` is 448 lines; the LC's is 3,173. Same ancestor module (both descend
from minimigmac by Benjamin Herrenschmidt), heavily diverged.

Our target implements: READ(6/10), WRITE(6/10), INQUIRY, FORMAT, MODE SELECT,
MODE SENSE, TEST UNIT READY, READ CAPACITY, and fake READ/WRITE BUFFER and
VERIFY(6/10). Two targets at SCSI ID 6 and 5, a two-sector double buffer, and
an INQUIRY identity of `SEAGATE ST225N` (a real 1986-era 20MB SCSI drive).

### Two defects that are conformance bugs, not missing features

**REQUEST SENSE (0x03) is entirely absent.** It is *mandatory* in SCSI-1
(ANSI X3.131-1986) for direct-access devices. Today an unsupported opcode returns
CHECK CONDITION with no sense data; the driver's recovery path then issues 0x03,
which is *also* rejected as unsupported — so the condition can never clear. The LC
hit exactly this and documented it in `rtl/scsi.v`: *"on hardware — where a
transient error triggers the recovery path — the Mac could never clear the
condition and wedged."*

**Any 12-byte (group 5) CDB wedges the target permanently.** `rtl/scsi.v:304-306`
only completes group 0 (6-byte) and groups 1/2 (10-byte):

```verilog
wire cmd_cpl   = cmd6_cpl || cmd10_cpl;
wire cmd6_cpl  = (cmd_group == 3'b000) && (cmd_cnt == 6);
wire cmd10_cpl = ((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10);
```

Group 5 is defined in SCSI-1. For any other group, `cmd_cpl` never asserts, `phase`
sticks in `PHASE_CMD_IN`, and BSY is held forever — the bus is dead until reset. No
real drive behaves this way; an unknown opcode gets CHECK CONDITION and the bus is
released. The LC calls this "a latent bus wedge."

Also missing versus a real SCSI-1 direct-access device: REZERO UNIT (0x01),
SEEK(6/10) (0x0B/0x2B), START/STOP UNIT (0x1B), PREVENT/ALLOW (0x1E),
RESERVE/RELEASE (0x16/0x17), REASSIGN BLOCKS (0x07).

---

## 2. Authenticity classification

The user question that shaped this plan: *how much of this is authentic to a Mac
Plus circa 1986?* Three distinct answers, and it maps cleanly onto the phases.

| Tier | Content | Period status |
|---|---|---|
| **1** | REQUEST SENSE, 12-byte CDB non-hang, `bus_busy` arbitration, MODE SENSE pages | **1986.** SCSI-1 mandatory/standard. Our omissions make us *less* accurate than a real ST225N. Porting these is a conformance fix. |
| **2** | CD-ROM target (AppleCD personality, 2048-byte blocks, READ TOC, sub-channel, eject) | **1988.** The AppleCD SC shipped March 1988 and Apple explicitly supported it on the Mac Plus under System 6 with the Apple CD-ROM driver + Foreign File Access. Two years after the machine, but a real Apple-sanctioned Plus configuration. |
| **3** | CD audio (CD-DA playback engine) | **1988**, same configuration. See routing caveat below. |
| **4** | BlueSCSI Toolbox (shared folders, CD changer) | **Modern.** A 2020s vendor command set. **Not in scope** — and inert without a forked Main_MiSTer anyway (§8). |

**Read prefetch ring** sits slightly outside this table. 32 sectors of read-ahead has
no 1986 analogue in *size*, but it restores authentic *behavior*: a real drive
streams continuously off a spinning platter, whereas our block-fetch model stalls at
every 512-byte boundary in a way no real drive ever did.

**CD audio routing is knowingly inauthentic.** On a real AppleCD SC, CD audio came
out of the *drive's own analog jacks* and never touched the Mac's sound hardware.
Digital audio extraction over SCSI did not exist yet — the Apple vendor commands
(0xC2 READ Q SUBCODE, 0xCC AUDIO STATUS, 0xCE AUDIO CONTROL) merely steer the
drive's internal analog playback. Mixing that PCM into the Mac's speaker is the only
workable choice on MiSTer with a single audio output.

**Identity:** we keep `SEAGATE ST225N`. The LC regressed this to `"MiSTer  "`
(`rtl/scsi_vendor.vh`); ours is the more period-correct string and there is no
functional reason to adopt theirs.

---

## 3. Decisions already made

### SCSI IDs: disks stay at 6/5, CD-ROM at 3 — settled from the ROM

The Plus ROM boot scan, disassembled from `releases/boot0.rom` (verified as the
Mac Plus v3 "Loud Harmonicas" 128K ROM, checksum `0x4D1F8172`):

```
407D4E  moveq   #$6, d5        ; start at SCSI ID 6
407D50  btst.l  d5, $b2e.w     ; skip IDs already claimed
407D54  bne.b   $407d58
407D56  bsr.b   $407d62        ; try to boot this ID
407D58  subq.w  #$1, d5        ; ID--
407D5A  bge.b   $407d50        ; loop while d5 >= 0
```

**IDs are scanned 6 → 0, descending.** ($B2E is a bitmap of IDs already claimed;
`$407D62` is the boot-block reader, which builds an `0x08` READ(6) CDB and checks
for the `0x4552` 'ER' boot-block signature.)

Consequences:
- Disks at **6/5** keep boot priority and existing users' setups are unchanged.
- CD at **3** is scanned *after* both disks, so a bootable CD can never preempt a
  bootable hard disk — but *can* still boot when no hard disk is bootable, which is
  the desirable behaviour.
- ID 3 is also the AppleCD SC factory default.
- The LC's layout (disks 0/1, CD 3) would have **inverted** this: the CD would be
  found before the disks. Rejected for the Plus.

### Not porting the LC's pseudo-DMA machinery

The LC `ncr5380.sv` carries `dma_word`, `dma_longword`, `dma_second_word` and 16-bit
`wdata`/`rdata` for the 68020's word/longword pseudo-DMA, plus a large body of
hard-won bug-fix commentary about word-write beat pairing. **None of it applies.**
The Plus is byte-wide — `dataController_top.sv:221-225` reads on UDS, writes on LDS,
8-bit. Dropping this removes the single largest and hairiest chunk of their
`ncr5380.sv`.

Likewise not porting: their JTAG `dbg_*` probe harness (LC-specific SignalTap
plumbing, ~15 ports on `scsi.v` alone), and `o_irq` (routes to the LC's pseudo-VIA
IFR bit 3; the Plus polls SCSI).

---

## 4. Target architecture

```
                        ┌───────────────────────────────┐
  hps_io slot 0 ────────┤ scsi #(.ID(6))                │  disk, unchanged IDs
  hps_io slot 1 ────────┤ scsi #(.ID(5))                │  disk
  hps_io slot 4 ────────┤ scsi #(.ID(3), .CDROM(1))     │  CD-ROM  ── cd_snd_l/r ──┐
                        └───────────────┬───────────────┘                          │
                                        │                                          │
                                   ncr5380 (byte-wide)                              │
                                        │                                          ▼
                              dataController_top ──────────────────────────► audio mixer
```

- `VDNUM` 4 → 5. Slots 0/1 SCSI disks, 2/3 floppies (from `floppy-write`), 4 CD-ROM.
- `sd_buff_addr` widens `[7:0]` → `[12:0]` for CD whole-frame bursts. **`sys/hps_io.sv`
  is byte-identical between the two repos** (`AW = WIDE ? 12 : 13`), so this is a
  local declaration change only — no framework fork.
- CONF_STR gains `SC4,ISOTO*CUEBINCHD,Mount CD-ROM;` and `OI,CD-ROM Drive,Enabled,Disabled;`.
  **Stock MiSTer Main already decodes bin/cue/chd/iso** for this slot — no HPS work.
- `cd_enable=0` makes the CD target never answer selection, so the bus is
  bit-identical to a pre-CD build. This is both the period-purist switch and the
  A/B lever if the new target misbehaves on hardware.

### Fit headroom

We are at **37% ALM (15,427/41,910) and 78/553 M10K**. The LC was fighting at
504/553 and had to cap `RING_LOG` at 5 for that reason. We have ~475 M10K free, so
the ring and CD buffers are not a constraint here. This is the one area where the
Plus core has it easier than the LC.

---

## 5. Phased plan

### Phase 0 — Simulation harness

**iverilog, not verilator.** The LC's bench is `verilator/scsi_bench`, but this
project has no verilator and `sim/` is already iverilog (Icarus 12.0, `tb_*.v`
compiled to `sim/out/*.vvp`). We write the SCSI bench natively in that style rather
than porting theirs — the LC bench is a reference for the initiator command
sequences, not code to lift.

`sim/tb_scsi_target.v`: a SCSI initiator model driving the target's REQ/ACK
handshake through selection → CMD → DATA → STATUS → MSG, plus an hps_io block-device
model serving `io_rd`/`io_wr`/`io_ack`/`sd_buff_*`.

#### STATUS — DONE (2026-08-17). Gate passes: baseline green, both defects reproduced.

```bash
C:/iverilog/bin/iverilog.exe -g2005-sv -o sim/out/tb_scsi_target.vvp sim/tb_scsi_target.v rtl/scsi.v && C:/iverilog/bin/vvp.exe sim/out/tb_scsi_target.vvp
```

Four tests. Two baseline guards that must pass today (INQUIRY returns the SEAGATE
identity; READ(6) returns 512 bytes byte-exact against an LBA-derived pattern — the
regression guard for Phase 1's read-ring rewrite), and the two conformance defects,
which currently fail *by design*:

```
BASELINE (must pass today):        PASS
CONFORMANCE (Phase 1 target):      2 of 2 still failing
PHASE 0 SCSI GATE: PASS - harness good, both defects reproduced
```

The gate reports PASS in exactly two states: baseline-green-with-both-defects (now),
and baseline-green-with-zero-defects (Phase 1 complete). A broken baseline always
reports FAIL, because then the harness is not trustworthy.

#### Two RTL findings from building the harness

**`io_rd`/`io_wr` have no reset.** Together with the internal `rd_pending`/
`wr_pending`, they power up as X and never resolve, which makes `io_busy` — and
therefore `req` — X forever in simulation. `io_ack` is the only thing that clears
them, so the bench has to pulse it during reset to bring the DUT to a defined state.
Harmless on real hardware (the fabric powers up at 0), but it should be a proper
reset. Added to Phase 1.

**`req` asserts ~2 cycles before `io_rd` on entering DATA_OUT.** `req_rd` is
combinational off `phase`, but `io_rd` is registered behind `rd_pending`, so there is
a two-cycle window where `io_busy` is still low and `req` is already high — an
infinitely fast initiator can take a byte before the block fetch has even started.
The bench hits this immediately and reads X. A 68000 pseudo-DMA turnaround is ~500ns
against a 62ns window, so hardware never hits it, but the read-ring rework in Phase 1
touches exactly this logic and should close it rather than inherit it.

Must produce, before any RTL change, a **failing** test for each of the two
conformance bugs in §1 — a REQUEST SENSE after a CHECK CONDITION, and a 12-byte CDB
— so we can prove the fix rather than assume it.

### Phase 1 — SCSI-1 conformance (no CONF_STR change, no new slots)

#### STATUS — RTL COMPLETE, SIM GREEN (2026-08-19). Hardware validation outstanding.

```
BASELINE (must pass today):        PASS
CONFORMANCE (Phase 1 target):      0 of 2 still failing
PHASE 1 BEHAVIOUR:                 0 of 8 failing
PHASE 1 SCSI GATE: PASS - conformance gaps CLOSED, behaviour tests green
```

Port the LC disk-path work into `rtl/scsi.v`:

1. REQUEST SENSE (0x03). ✅ **Decision: real sense keys on the disk path, not the
   LC's static all-zeros block.** The LC gates `cd_sense_key`/`cd_sense_asc` on
   `CDROM != 0`, so its disk path answers "NO SENSE" — *nothing is wrong* — to the
   question "why did you CHECK?", which is self-contradictory and leaves a driver's
   retry logic nothing to act on. Promoting it cost ~12 lines rather than the LC's
   CD state machine, because the disk path has exactly **one** failure mode
   (`!cmd_ok` → ILLEGAL REQUEST / ASC 0x20 invalid operation code). Sequencing it
   before Phase 2 rather than after means the CD target *extends* one sense latch
   instead of un-gating a path written on the assumption that disks have no sense.
   Regression risk was nil: sense is only reachable through 0x03, which did not
   previously exist.
2. Group-5 (12-byte) CDB completion, so an unknown opcode CHECKs and releases the
   bus instead of wedging it. ✅
3. `bus_busy` — don't answer selection while another target holds BSY. ✅
   Wired in `ncr5380.sv` as `|target_bsy`.
4. `sys_rst` separate from bus `rst`. ✅ Wired to ncr5380's `reset`. Both feed
   `any_rst`, which now clears the phase FSM, the IO engine and the sense latch —
   so a core reset landing mid-command can no longer leave a target holding BSY
   with the ROM's next boot scan finding a busy bus.
5. Read prefetch ring (`RING_LOG` = 5, 32 sectors / 16KB), replacing the two-sector
   double buffer. Writes stay on the two-slot buffer. ✅ `RING_LOG=1` is verified
   to still build and pass the whole suite, i.e. it does reproduce the old double
   buffer, so the depth is a one-line rollback if hardware disagrees.
6. HPS byte-lane endianness handling. ✅ **No change needed** — our existing lane
   mapping is already byte-identical to the LC's real-HPS (`else`) branch. Their
   second mapping exists only for their Verilator bench, which packs big-endian;
   we have no such bench, so there is nothing to switch on. Documented in place so
   this is not re-derived later.
7. Reset `io_rd`/`io_wr`/`rd_pending`/`wr_pending` (Phase 0 finding). ✅ The bench's
   reset-time `io_ack` pulse workaround has been removed, so the suite now fails
   outright if this regresses.
8. Close the `req`-before-`io_rd` startup window (Phase 0 finding). ✅ Falls out of
   the ring stall: `rd_cur_blk >= rd_hps_blk` is true at `data_cnt == 0`, so REQ is
   held down until the first sector has actually landed rather than depending on
   `io_rd` having had time to rise. The bench's turnaround delay has been removed
   too — it is now a maximally impatient initiator, which is what would expose the
   race if it came back.

Two items were added beyond the original list, both LC-validated:

9. **Allocation-length clamping.** `tlen6`'s 0 → 256 mapping is the READ/WRITE(6)
   *block-count* convention and does not apply to allocation lengths: for INQUIRY
   an allocation of 0 means "no data", for REQUEST SENSE it means 4 bytes. Without
   this a REQUEST SENSE with allocation 0 would serve 256 bytes into an initiator
   expecting 4 — a wedge on the very recovery path item 1 exists to fix. Responses
   are also capped at their real size (INQUIRY 36, REQUEST SENSE 18).
10. **Zero-length data phases.** A consequence of 9: a phase with `data_len == 0`
    never sees an ACK edge, so `data_complete` never asserts and REQ would be held
    forever. `data_done` treats "no data expected" as complete on entry.

#### Verification

`sim/tb_scsi_target.v` grew from 4 tests to 12: the two Phase 0 baseline guards,
the two Phase 0 conformance defects, and eight new Phase 1 behaviour tests —
multi-sector read with a prefetch-depth watermark assertion, sense contents, sense
lifetime, bus usability after a rejected 12-byte CDB, `bus_busy` arbitration, and
**three write-path regression guards** (single-sector, multi-sector, ring wrap).

The write guards matter disproportionately: Phase 0 had **no SCSI write coverage at
all**, and Phase 1 changed `req_wr`, the flush engine and `io_busy`'s DATA_IN clause.
The bench's HPS model now reads the flushed sector back out of the target's buffer,
so writes are checked to the block device byte-exact, at the right LBA, in the right
byte lanes.

Every fix was mutation-tested — reverted one at a time to confirm the matching test
actually fails. Static NO SENSE → test 6 fails; no `bus_busy` → test 9; an
off-by-one in the ring stall → tests 2/5/8/12 and the baseline; unreset IO engine →
everything wedges on X; `req_wr` tied off or byte lanes swapped → tests 10/11.

**Hardware-validate before starting Phase 2** — this phase touches the path every
existing user depends on, and is the one most likely to regress a working setup.
Two things to watch that simulation cannot answer:

- **M10K usage.** `RING_LOG=5` is ~26 M10K across the two targets by hand estimate
  (8192 × 8 bits × 2 buffers × 2 targets), against ~475 free. Not verified — no
  Quartus compile has been run.
- **REQ during block-boundary fetches.** The LC eventually needed a separate
  bus-visible REQ (`req_bus`) because a driver polling CSR/BSR between pseudo-DMA
  chunks read our dropped REQ as a dead transfer. The Plus polls SCSI and the ring
  makes mid-transfer stalls rarer than before, so this is strictly better than
  today's behaviour — but it is the known failure mode if reads misbehave on real
  hardware.

#### One incidental finding

The `PHASE_STATUS_OUT` clause in `req_wr` is **dead code for block writes**, in both
this core and the LC's. `data_cnt` reaches n×512 while still in `PHASE_DATA_IN`, so
the DATA_IN clause already flushes every sector including the last — verified by
deleting the STATUS_OUT clause and watching all three write tests still pass with
the correct flush count. Left in place: it is a harmless safety net if the
`data_complete`/phase timing ever shifts, and removing it would be an untestable
change to the write path.

#### Follow-up logged during Phase 2

`READ CAPACITY` on the **disk** path still returns `img_blocks`, not
`img_blocks - 1`. The command is defined to return the last LBA, so this is a
pre-existing off-by-one that the LC fixed on its disk path. It was deliberately
left alone: Phase 2 is meant to be purely additive, and changing it alters what
every existing user's driver sees. The CD path uses the correct value. Worth
fixing with Phase 1's hardware validation, not before it.

#### Deliberately *not* done in Phase 1

The other SCSI-1 commands listed in §1 — REZERO UNIT (0x01), SEEK(6/10)
(0x0B/0x2B), START/STOP UNIT (0x1B), PREVENT/ALLOW (0x1E), RESERVE/RELEASE
(0x16/0x17), REASSIGN BLOCKS (0x07). Accepting them is ~6 lines, but it changes
what a driver sees on the path every user depends on (GOOD instead of CHECK), the
LC has not validated them on the disk path, and none is needed by anything we know
issues them. Revisit after Phase 1 hardware validation.

### Phase 2 — CD-ROM target

#### STATUS — RTL COMPLETE, SIM GREEN (2026-08-19). Hardware validation outstanding.

```
PHASE 2 CD-ROM: 0 of 20 failing
PHASE 2 CD GATE: PASS - AppleCD target behaves
```

Third `scsi` instance, `#(.ID(3), .CDROM(1))`. AppleCD personality, 2048-byte
logical blocks served as 4 consecutive 512-byte HPS blocks (lba/tlen <<2), READ TOC
(both standard 0x43 and Apple vendor 0xC1), sub-channel, START/STOP eject,
PREVENT/ALLOW, no-disc sense (`SK_NOT_READY` + vendor ASC 0xB0 — the LC notes 0x3A
makes MacOS "hammer the drive asking the user to format it").

Implemented: SONY CDU-8004 identity (the Apple CD-ROM extension binds only to
drives it recognises, so the identity *is* the compatibility), READ CAPACITY in
2048-byte units, CD MODE SENSE with the page 0x30 Apple magic page and the
write-protect bit, both READ TOC dialects, both READ SUB-CHANNEL dialects, AUDIO
STATUS, READ HEADER, PREVENT/ALLOW, both eject forms, SET CD SPEED, and
accept-noop audio transport. WRITE / FORMAT / VERIFY are deliberately absent from
the CD command set, so they CHECK with ILLEGAL REQUEST as a real AppleCD does.

**`sd_buff_addr` did NOT need widening.** This plan assumed whole-CD-frame bursts
would force `[7:0]` to `[12:0]`. Scaling lba/tlen by 4 at latch time instead means
the CD reuses the existing 512-byte block plumbing unchanged — no `hps_io`
declaration change, no new byte-lane concern, and one less thing that could
regress the disks. The `<<2` line is the single most load-bearing line in the CD
data path and has two dedicated tests.

#### Scope decision: single-track TOC, and therefore ISO only

The LC's TOC comes from `cd_audio.sv`, which parses a real multi-track table.
Phase 2 has no audio engine, so the TOC here is **synthesized as one data track
spanning the disc** — correct for data CDs, which is what Phase 2 is for. The
lead-out address is the only non-constant part; it needs an LBA to MSF conversion,
done by a small iterative subtract at mount time (two passes, ~150 cycles against
a mount event, so no divider).

The two TOC planes disagree on purpose and this is easy to get wrong: the Apple
0xC1 plane is raw LBA-derived MSF in **BCD**, the standard 0x43 plane is MSF **+150**
(the two-second pre-gap) in **binary**. Both are pinned by tests, and the test
image is chosen so minutes, seconds and frames are all non-trivial (40:33:17) —
an evenly-dividing LBA would pass with a broken divider.

Consequence: the CONF_STR slot offers **`ISO` only**, not the `CUEBINCHD` this plan
originally listed. A `.bin` from a CUE/BIN pair is usually 2352-byte raw sectors,
not 2048, and a `.cue` is a text file; serving either as linear 2048-byte logical
blocks would be wrong, not merely incomplete. Those formats arrive in Phase 3
along with the real TOC.

#### Core wiring

- `SCSI_DEVS` 2 to 3, `SCSI_CD_DEV` = 2. One generate loop still builds every
  target; index 2 gets `ID(3)` and `CDROM(1)`. Verified by elaborating the
  hierarchy and reading the parameters back: `ID=6/CDROM=0`, `ID=5/CDROM=0`,
  `ID=3/CDROM=1`.
- `VDNUM` 4 to 5. The CD is hps_io **slot 4**, deliberately not contiguous with the
  disks at slots 0/1 because 2/3 belong to the floppies, so every SCSI vector is
  assembled by hand rather than sliced.
- CONF_STR gains `SC4,ISO,Mount CD-ROM;` and `OI,CD-ROM Drive,Enabled,Disabled;`.
  The mount slot is hidden while the drive is disabled.
- `cd_enable = ~status[18]`, so the drive is **enabled by default** as this plan
  specified. Note this does change the bus for existing users on upgrade: a new
  target answers selection at ID 3. It cannot preempt booting (the ROM scans 6 to 0),
  and flipping the default is a one-character change if hardware testing wants it.

#### Verification

`sim/tb_scsi_cdrom.v`, 20 tests — a separate bench from the disk one so that "the
disk still works" and "the CD works" stay independently meaningful answers. It
covers the no-disc drive-present model, the no-disc sense, `cd_enable` invisibility,
identity, capacity, both READ forms with the <<2 scaling, all three Apple TOC
operations, the standard TOC, allocation-length serving, the Apple magic page,
read-only rejection, the 12-byte SET CD SPEED, PREVENT-blocked eject, the
START/STOP eject form, remount, both sub-channel dialects, and READ HEADER
including the rejected MSF form.

Mutations verified to fail the right tests: removing the `<<2` scaling (cd6, cd7),
dropping the +150 pre-gap (cd11), serving the 0xC1 lead-out in binary instead of
BCD (cd9), using ASC 0x3A instead of 0xB0 for no-disc (cd2), and giving the CD the
disk command set so it accepts WRITE (11 tests).

The disk gate was re-run after every step and stayed green throughout — with all
CD code present, `CDROM == 0` folds it away.

#### One real bug this phase surfaced, worth remembering

Every CD response initially had a **corrupt first byte** — and only the first byte.
The cause is that a continuous assignment calling a function takes its sensitivity
from the call's *arguments*, so a module signal read inside the function body does
not retrigger it; `cmd_dout` was only re-evaluated when `data_cnt` incremented, and
byte 0 therefore carried the previous command's decode. The fix is to pass every
dependency in as a function argument, which is correct by construction. Three
apparently unrelated failures (TOC operation select, TOC BCD, MODE SENSE page
select) were all this one cause.

Note this would likely have *worked* in Quartus and failed only in simulation —
which is precisely why it had to be fixed rather than tolerated: RTL that only
behaves because the synthesizer is smarter than the simulator is untestable.

Guest-side requirement: System 6/7 with the Apple CD-ROM driver + Foreign File
Access. **The LC's own docs warn that CD-image-attached-at-boot causes an
intermittent hang on their core** — gate CD testing with the image *detached* at
boot and mounted from the OSD after the desktop is up, at least until we know
whether the Plus shares that failure mode.

### Phase 3 — CD audio

Port `cd_audio.sv` (1,416 lines) and mix `cd_snd_l/r` into the audio path.

**Blocking investigation before this phase:** our audio output is
`assign AUDIO_L = {audio[10:0], 5'b00000}` with `AUDIO_S = 1` (signed)
(`MacPlus.sv:228-231`). If `audio` is an unsigned 0..2047 value, placing it in a
signed 16-bit field makes everything above 1024 read as *negative*. That is either a
pre-existing bug or `audio` is already centred — determine which before building a
mixer on top of it, because a stereo signed mix will expose the difference loudly.

---

## 5.5 Build results and hardware validation (Phases 1 + 2)

### Synthesis — Quartus 17.0.2, 5CSEBA6U23I7 (commit `0698fd1`)

| | Baseline (pre-upgrade) | Phases 1 + 2 | Delta |
|---|---|---|---|
| Logic (ALMs) | 15,427 (37%) | **16,334 (39%)** | +907 |
| Registers | 17,908 | 18,443 | +535 |
| M10K blocks | 78 (14%) | **122 (22%)** | **+44** |
| Block memory bits | 477,125 | 853,957 | +376,832 |

Compile time ~13 minutes. **Timing passes with no failing paths — TNS 0.000 on
every domain, in both builds compiled so far.**

Per-domain setup slack is worth reading carefully, because it moves between runs
in a way that is easy to misattribute:

| Domain | Baseline | `d93c918` | `0698fd1` |
|---|---|---|---|
| `emu|pll general[1]` — **32.5 MHz, the SCSI domain** (period 30.763 ns) | 4.245 | 4.247 | 4.199 |
| `emu|pll general[0]` — 65 MHz SDRAM, NOT the SCSI domain | 1.468 | 1.172 | 1.670 |
| `pll_hdmi` — HDMI output, unrelated to SCSI | 0.539 | 0.612 | 0.160 |

**Correction:** earlier revisions of this section called `general[0]` "the core
clock where the SCSI logic lives". That is wrong. `dataController_top` — and
therefore ncr5380 and every scsi.v instance — is clocked by `clk_sys`, which is
`outclk_1` = **`general[1]` at 32.5 MHz**. `general[0]` is `clk_mem`, the 65 MHz
SDRAM clock, and its slack movements have nothing to do with this work.

At commit `9377279` (the CD allocation fixes) the SCSI domain sits at **3.530 ns
of 30.763 ns, 11.5% margin** — down from ~4.25, which is real and consistent with
the added MODE SENSE serve logic and the widened data_len mux. Comfortable, but
it is the number Phase 3 should watch, not `general[0]`.

The core clock got *better* in the latest build, not worse, so the read ring's
wider comparator cone and the CD's widened `cmd_dout` mux are not squeezing the
domain they live in. The `pll_hdmi` figure moving 0.612 -> 0.160 has no causal
path to the SCSI work; a CONF_STR string-length change alters the hps_io ROM
contents and perturbs global placement, so unrelated domains drift run to run.

**Still, 0.160 ns is thin.** It is positive and TNS is zero, so this build is
fine, but if a later compile pushes `pll_hdmi` negative, treat it as placement
variance to be re-run and re-measured rather than a SCSI regression — check
whether the core clock moved with it before concluding anything.

**The M10K estimate in §4 was wrong.** It guessed ~26; the real figure is 44. Two
compounding errors: it forgot the CD is a third target instance, and it divided
by 10,240 bits per M10K rather than the 8,192 actually usable in x8 mode. Correct
arithmetic: each ring buffer is 8192 x 8 = 65,536 bits = 8 blocks; 3 targets x 2
buffers = 48, minus the 4 the old 512-deep buffers used = +44. The measured
memory-bit delta matches that exactly (+376,832), so the model is now calibrated.
The conclusion is unchanged — 431 blocks free, nowhere near constrained, and
`RING_LOG=6` would cost another 48 and still fit at 170/553.

### Two defects found only by building and running it

Both are worth recording because neither simulation nor review caught them.

**The "Mount CD-ROM" menu item never appeared.** The CONF_STR entry carried an
`h` conditional-visibility prefix (`"hISC4,ISO,Mount CD-ROM;"`) meant to hide the
slot only while the drive is disabled. That was an unverified assumption about
Main_MiSTer's prefix polarity: with the drive Enabled (status[18] = 0) the item
was hidden outright. Confirmed on hardware, where the unprefixed "CD-ROM Drive:
Enabled" toggle *was* visible while the mount slot was not. MacLC_MiSTer, which
has the same feature, declares its slot plainly with no prefix — matching it is
the fix. The CD target itself was never affected: `cd_enable` was already 1, so
it had been answering selection at ID 3 the whole time; only the UI was missing.

**Quartus caught a readiness flag that gated nothing.** Warning 10036,
"`toc_ready` assigned but never read", was correct: for the ~150 cycles the
lead-out MSF conversion runs after a mount, media commands served the *previous*
disc's TOC — wrong data after a disc swap rather than an error. `!toc_ready` now
folds into `cd_no_media`, so those commands report NOT READY, which is the
correct answer for a drive still spinning up and one the driver's retry path
already handles. The bench had hit this as a mount race and it was "fixed" on the
bench side; that was the wrong call — the bench was reporting a real RTL gap.
`cd21` now covers it, asserting on whether the conversion was genuinely still
running rather than racing it.

---

### Hardware validation checklist

Neither phase has been validated on a DE10 yet. **Back up the test images first**
— Phase 1 changed the write path, and that path had no test coverage at all
before this work. Use a scratch image and keep the previous release `.rbf` to
A/B against.

#### Set up the two bisect levers first

They turn a failure into a diagnosis instead of a mystery. Both are proven in sim.

| Lever | How | Isolates |
|---|---|---|
| CD-ROM Drive -> Disabled | OSD, `status[18]` | Bus becomes bit-identical to a pre-CD build. A *disk* fault that vanishes here is Phase 2's. |
| `RING_LOG` 5 -> 1 | `rtl/scsi.v`, one line + rebuild | Reproduces the old two-sector double buffer exactly. A *read* fault that vanishes here is the ring's. |

#### Tier 1 — the read ring (highest risk; the failure is silent)

The dangerous mode is not a hang, it is a stale ring slot returning
plausible-looking data from earlier in the same transfer. Test **content**, not
completion:

- Place a large file of known checksum on the image from the PC beforehand.
- Boot, copy it around on the Mac, read it back, verify byte-identical.
- Launch several large applications; open a folder full of colour icons. The LC
  found icon rendering and app loading were where ring staleness first showed.
- Pull the image back to the PC and diff it.

**Watch specifically:** the LC needed an extra look-ahead stall (`rd_ahead_blk`)
because their 68020's *longword* pseudo-DMA captures bytes past the current one
and can cross into a not-yet-filled ring block. That was deliberately not ported,
on the grounds that the Plus is byte-wide (`dataController_top.sv:221-225`). If
reads corrupt in a ring-boundary-periodic pattern, that omission is the first
suspect — it is the judgment call in Phase 1 that hardware is best placed to
disprove.

#### Tier 2 — writes

- Copy several MB onto the SCSI disk, reboot, verify every file; then diff the
  image on the PC.
- The LC's signature for the window closed with `wr_pending` was very specific: a
  7.5 MB write perfect *except the first word of one 512-byte block*. A single
  wrong word in an otherwise clean write is meaningful, not noise.

#### Tier 3 — reset and arbitration

- Hit reset repeatedly **during** heavy disk I/O; every reset should re-boot
  cleanly. This exercises `sys_rst`, which now tears down the phase FSM — before,
  a reset mid-command could leave a target holding BSY and the ROM's next boot
  scan would find a busy bus.
- Mount both SCSI disks and drive I/O against both. That is `bus_busy`.

#### Tier 4 — CD-ROM

Per the LC's own warning, **mount the ISO from the OSD after the desktop is up**,
not attached at boot — they see an intermittent hang with a CD attached at boot
and never root-caused it. Only try boot-attached once the rest is known good.

- With no disc, the drive should still be *present* (System 6/7 with the Apple
  CD-ROM driver + Foreign File Access).
- Mount an **ISO** and verify file contents — this exercises the `<<2` scaling.
- Eject from the Finder ("Put Away"), then remount. This tests the `0x1B`
  START/STOP form, which is what the System 7 driver actually uses; if `mounted`
  does not drop, the driver silently remounts the volume ~10 s later.
- **Boot priority:** with a bootable HD at ID 6 and a CD mounted, the HD must
  still win (the ROM scans 6 -> 0).

#### Tier 5 — the error path

REQUEST SENSE only matters when something fails, so provoke it: run SCSI Probe,
Apple HD SC Setup, Lido or SilverLining. These issue opcodes we do not implement,
which is exactly the CHECK CONDITION -> REQUEST SENSE recovery that previously
wedged the bus forever.

- The drive must still identify as **SEAGATE ST225N**. Phase 1 clamps INQUIRY to
  36 bytes; a truncated or garbled identity points at that clamp.
- The utility should complete rather than hang.

#### Where the risk actually sits

Ranked: **the read ring** (biggest change, silent failure, omitted look-ahead
stall), then **REQ behaviour during block fetches** (the LC needed a separate
bus-visible REQ because a driver polling CSR/BSR between pseudo-DMA chunks read
a dropped REQ as a dead transfer and parked forever — the signature is a hang at
a *consistent* point in boot, not a random one), then the **write path**. The CD
is least likely to break anything you care about: it is additive and switchable
off.

---

## 6. Why this branch is based on `floppy-write`

`master` lacks the floppy write feature. Two reasons not to base on it:

- `MacPlus.sv` on `floppy-write` defines the current `VDNUM=4` layout with floppies
  at slots 2/3. Phase 2 adds slot 4. Basing on `master` guarantees a painful
  conflict in exactly the file both projects touch most.
- Any test build from a `master`-based branch would regress floppy writing for the
  people currently testing it.

Merge order: `floppy-write` → `master` first, then rebase this branch.

---

## 7. Risks

| Risk | Severity | Notes |
|---|---|---|
| Phase 1 regresses the existing disk path | **High** | It touches what every current user depends on. Hardware-gate Phase 1 alone before adding CD. The read ring is the largest single behavioural change. |
| CD-ROM unusable on a Plus in practice | Medium | 68000 at 8MHz, 1–4MB RAM, polled SCSI. Historically real, but slow. May be more demo than daily driver. |
| LC's boot-attach CD hang reproduces here | Medium | Documented on their core, cause not established. Test with CD detached at boot. |
| Audio signedness (§Phase 3) | Medium | May surface a pre-existing bug that is currently inaudible. |
| Fit / timing | **Low** | 475 M10K and 63% ALM free. The LC's constraints do not bind us. |

---

## 8. Explicitly not in scope

**BlueSCSI Toolbox** (shared folders + CD changer, LC `TOOLBOX_ENABLE` /
`CDCHANGER_ENABLE`). Two independent reasons:

1. **It cannot work on stock MiSTer.** The LC readme: *"Stock Main has no Toolbox
   handler; the core degrades gracefully without it."* The HPS handler lives on an
   unmerged `add-bluescsi-toolbox-for-MacLC` branch of Main_MiSTer. Porting the RTL
   without also shipping a forked Main yields dead code that returns CHECK.
2. It is wholly anachronistic to the period (§2, tier 4).

Revisit only if the Main-side handler is upstreamed.

Also out of scope: the LC's TG68K CPU work (mentioned in the same forum reply but
orthogonal to SCSI — separate evaluation if wanted), and their JTAG debug harness.

---

## 9. Attribution

Not a licensing question — both cores are publicly distributed, cross-porting is
established practice in the MiSTer ecosystem, and the LC author invited this port
directly. Carry their authorship attribution through in the ported file headers as
normal courtesy, and credit the LC core in `readme.md` alongside the existing
Plus Too / minimigmac credits.

---

## 10. Effort

Rough, assuming hardware validation between phases:

| Phase | Scale |
|---|---|
| 0 — sim harness | Small. Mostly porting `verilator/scsi_bench`. |
| 1 — conformance | Medium. ~300–500 lines into `scsi.v`; the read ring is the bulk. |
| 2 — CD-ROM | **Large.** The CD command set is most of the LC's 3,173 lines. |
| 3 — CD audio | Medium-large. `cd_audio.sv` is 1,416 lines but largely self-contained. |

Phases 1 and 2/3 are independently shippable. If CD-ROM proves impractical on a
Plus, Phase 1 still stands on its own as a correctness fix worth having.

---

## 5.6 Hardware bring-up: the CD-ROM boot hang (2026-08-20 → 08-22)

**Status: the CD-ROM feature works** — with a disc mounted the Plus boots System
7.1.2 with the Apple CD extensions and reads the CD directory. Selection,
INQUIRY, MODE SENSE (including the magic page 0x30), the Apple vendor command
path, READ CAPACITY and the 2048-byte READ ring are all validated on real
hardware. **But booting is intermittent, and with no disc mounted it wedges at
"Welcome to Macintosh" every time.** That is the open item.

### What the wedge actually is (measured, not inferred)

JTAG In-System Probes (`rtl/dbg_probes.sv`, read with
`scripts/read_probes.tcl`) captured the wedged machine directly. `PIFD` recorded
the instruction words, which disassemble to:

```
0128E4:  0710             BTST  D3,(A0)        ; a 5380 register
0128E6:  660E             BNE.S 0128F6         ; bit SET -> exit
0128E8:  082B 0005 0040   BTST  #5,(64,A3)     ; offset 0x40 = CSR, bit 5 = REQ
0128EE:  67F4             BEQ.S 0128E4         ; REQ CLEAR -> loop
```

The driver spins while `BSR[D3]==0 && CSR.REQ==0`. Measured wedged: `BSR=0x90`,
`CSR=0x00`, last register write `DMAinitRcv`, write counter frozen, `PODR` =
`00 00 01 00` (a one-block READ), and no DACK reads at all.

So: **the driver issues a one-block READ to an empty drive, arms pseudo-DMA and
waits for REQ or DRQ, while the bus is completely free** — the target answered
with CHECK CONDITION for no media, correctly, and left. The open question is why
this driver does not handle that CHECK, when a real AppleCD returns the same.

### Two real defects found and fixed en route (neither is the hang)

1. **Unrecoverable IO stall** (`b7e928e`). `io_busy` holds REQ low
   (`scsi.v:239`) *and* sits in the bus watchdog's reset list (`scsi.v:1195`),
   so a sector fetch that never completes wedged the target with its own
   recovery disabled. New `IOWDOG_LOG` (~516 ms) aborts through the same path
   and clears the stale `io_rd`/`io_wr`. Reproduced by `seam9`.
   **Still unvalidated on hardware** — `PIO2` showed `cd rd=0` in every capture,
   so the path was never exercised.
2. **A REQ deferral that could hide REQ forever** (`b0282b6`), introduced by the
   `65910b1` port of MacLC's completion semantics. `req_deferred` cleared only
   on `csr_rd`, which is gated by `ior`, while `rdata` is not — and §3 of this
   document already recorded the reason that matters: *the Plus reads on UDS and
   writes on LDS*. A CSR poll through the other byte lane therefore read the
   right value and never cleared the deferral. Fixed by detecting a read as
   "not a write", plus a 1024-clock age-out. Proven by `seam10`.

### Corrections to §3 "Not porting the LC's pseudo-DMA machinery"

That section still stands on the 16-bit word/longword machinery — the Plus is
byte-wide and none of it applies. Two of its other claims were revised:

* **The JTAG probe harness WAS ported**, in lean form. The objection was to the
  LC's ~15 debug ports threaded through `scsi.v`; the deck actually built takes
  everything from top-level signals in `MacPlus.sv` and adds no ports to
  `scsi.v` at all. It is behind `USE_SCSI_ISSP` and is what finally localised
  the wedge. In-System Sources & Probes works in Quartus 17.0 Lite.
* **`o_irq` is still not routed** — correct, the Plus has no free VIA interrupt
  input and does not route a 5380 IRQ. But `BSR` bit 4 is now a real latched
  completion IRQ that a polled driver can read, which is a different thing from
  an interrupt line and costs nothing.

### The seam finally has a test

`sim/tb_ncr5380_seam.v` is the first bench for the `ncr5380 <-> scsi.v` seam —
the register model the Mac actually talks to, previously untested because every
other bench drives `scsi.v` on its target pins. It covers selection, a full CDB
handover, the pseudo-DMA DACK path, both watchdogs and the REQ deferral.

### Method note

Eight hypothesis-driven fixes found eight real bugs and none of them was the
hang. What actually moved it: a free experiment (mount a disc and compare), and
instruments that were proven before being trusted. Mutation testing caught four
tests that passed for the wrong reason — twice in tests written while explicitly
watching for that failure mode. Also: **any bench test that starts a SCSI
transaction must finish it** (status *and* message); leaving the target holding
BSY makes the next selection fail silently and the following test measure
nothing.

### The third reading: the transaction completed, invisibly (review, 2026-08-22)

An independent review of the wedge evidence against the RTL produced a third
reading, distinct from both "the driver missed REQ" and "selection never
succeeded" — and it explains every probed value with one defect.

First, a deduction that kills the selection theory outright: the CDB tail in
the write ring **proves selection succeeded**. The Plus SCSI Manager sends
command bytes per-byte, polled on REQ; it will not write byte N+1 without
seeing REQ for it. Ten bytes written means a target answered selection and
handshook the whole COMMAND phase.

Second, a deduction that kills the missed-REQ theory: with the target sitting
in STATUS_OUT and `req` un-suppressed, the polling loop *cannot* spin 129 ms.
`bsr_dmarq` is un-deferred, and the CSR REQ deferral is bounded at 1024 clocks
(~31 µs). Either the loop exited, or `req` was suppressed for the entire
window. No suppressor exists on the no-media path (`req_rd` needs DATA_OUT,
`req_wr` needs `cmd_write`, ICR.ACK reads 0), so: the loop exited.

The mechanism. `bsr_dmarq = scsi_req & dma_en` (`ncr5380.sv` ~218) has **no
phase-match term**. A real 5380 inhibits DRQ and halts the DMA handshake when
REQ arrives with MSG/CD/IO not matching the TCR, leaving REQ visible in CSR so
the driver's loop exits through the REQ test and the SCSI Manager handles the
phase change. That inhibition is the entire exit ramp for "target CHECKed
instead of entering a data phase," and our model lacks it. So:

1. No media → READ dispatches to STATUS_OUT with CHECK (correct).
2. Driver arms `DMAinitRcv`; `dma_en=1` meets the status-phase REQ; DRQ rises.
3. The blind loop sees BSR bit 6, does a DACK read; `dma_ack` pulses ACK; the
   target's status byte is consumed *as sector data* and discarded.
4. MESSAGE_OUT asserts REQ; DRQ again; a second DACK read eats COMMAND
   COMPLETE; phase → IDLE. **Bus free, in microseconds, no watchdog involved.**
5. The driver has 2 of ~512 blind-read bytes and polls a free bus forever.

Why the other measurements fit: CSR=0x00 (transaction genuinely ended);
write counter frozen (the pump loop writes nothing until its count is
satisfied); zero CD sector fetches (no data phase ever dispatched); the sense
bisect was a no-op because the driver never reaches REQUEST SENSE — the frozen
write counter is the airtight proof of that, not the bisect. The intermittency
with a disc is the *same* bug: `cd_no_media` includes `!toc_ready`, so a READ
that lands before the TOC build finishes takes the identical CHECK path — one
bug, one race, not two. And BSR bit 4: `irq_latch` is edge-triggered on a
pmatch 1→0 while `dma_armed`; a mismatch that *predates* the arm (as here)
produces no edge — a second divergence from the real chip, which level-checks
phase match when DMA starts. (Open discrepancy: this section earlier recorded
`BSR=0x90` and the review worked from `0x80`. Bit 4 set is still consistent —
`irq_latch` persists from any earlier completed transfer until a reg-7 *read*
clears it — but resolve which was measured; it constrains whether this driver
ever reads reg 7.)

**The one datum in tension, and the measurement that settles it.** The "no
DACK reads" probe row contradicts the mechanism, which predicts **exactly two**
DACK reads within microseconds of the reg-7 write. If a correct counter of
`i_dma_rd` edges truly reads 0 since the arm, the mechanism is falsified.
Check what the instrument counts first: two isolated DACK reads followed by
hours of filtered polling are easy to lose in the access ring, and the ring's
`~dack` decode may not capture the DACK window at all. Sticky probes to add,
cleared on selection / on the reg-7 write:

1. 2-bit DACK-read counter since last `DMAinitRcv` write — predict 2.
2. `wdog_abort` / `iostall_abort` fire counters — predict **0**; the
   missed-REQ reading requires ≥1. This alone separates the theories.
3. Phase-visit bitmask since selection — predict CMD→STATUS→MESSAGE→IDLE,
   no DATA phase.
4. Sticky "`req` high while `phase==STATUS_OUT`" — the fallback theory
   (io_busy suppression, third term of `scsi.v` ~232) has no identified
   setter but can't be excluded post-hoc, because the abort path clears
   `io_rd`/`io_wr`/`wr_pending` and destroys the evidence.

**Fix shape, if confirmed:** gate `bsr_dmarq` and `dma_ack` with `bsr_pmatch`
so a DACK access during a mismatch cannot ACK a status byte, and make the
completion-IRQ latch level-triggered (`dma_en && scsi_req && !bsr_pmatch`) so
a mismatch already present at arm time still latches — which also gives the
SCSI Manager the BSR bit 4 it expects after a short transfer. Per the method
note above: run the discriminating measurement before trusting the fix.

### Acting on the review: the mechanism is now proven in the model (2026-08-22)

Three things came out of the review: audit the instrument, add discriminating
probes, hold the fix until a measurement supports it. All three are done except
the measurement, which needs the board.

**1. The instrument was unreadable, and that is why the datum was "in tension".**
The DACK-read row was a free-running **4-bit wrap counter that was never
cleared**. A machine that boots off a SCSI hard disk performs thousands of DACK
reads before it ever touches the CD, so at the wedge that field held
(lifetime mod 16) — a number with no relationship to the two reads the mechanism
predicts, and one that reads back `0` on roughly one boot in sixteen. "No DACK
reads observed" was never evidence of anything. It is now an 8-bit *saturating*
lifetime total (0 means genuinely none, and it cannot roll back to 0) plus a
small counter re-armed by each DMA start, which is the count the mechanism
actually predicts.

**2. The mechanism reproduces in simulation, exactly as described** — `seam11`
in `sim/tb_ncr5380_seam.v`. Arm pseudo-DMA with `TCR=0x01` (driver expects DATA
IN) while the no-media READ has already CHECKed into STATUS, then do what a
blind pump loop does. Every predicted value landed on the first run:

* BSR reports the mismatch, and **DRQ asserts anyway** — a real 5380 inhibits it.
* The first DACK read returns `0x02` (CHECK CONDITION) *as sector data* and ACKs
  it; the target advances to MESSAGE.
* The second eats COMMAND COMPLETE. The bus is free in under 200 clocks.
* No watchdog fired, no DATA phase was ever entered, ACK pulsed while the target
  sat in STATUS, and CSR reads back `0x00` on the free bus — the wedge capture.
* `irq_latch` never set, because the mismatch predates the arm.

So the RTL half of the reading is no longer a hypothesis. What remains open is
the *driver* half: whether the Mac's pump loop actually issues those two DACK
reads. Only the board can answer that.

These assertions describe a defect and are labelled `DEFECT:` in the bench; they
invert when the fix lands. Mutating the RTL with the proposed gate
(`bsr_dmarq & bsr_pmatch`, `dma_ack & bsr_pmatch`) flips exactly those
assertions and **leaves seam1–seam10 green**, which is the first evidence that
the fix does not break the pseudo-DMA path that already works (`seam7`).

**3. The four discriminating probes are built, and the deck now has a test.**
`PDMA` and `PDM2` in `rtl/dbg_probes.sv`, decoded by `scripts/read_probes.tcl`,
which prints a verdict line rather than leaving the capture open to
re-interpretation:

| field | question | invisible-completion predicts | missed-REQ predicts |
|---|---|---|---|
| `PDMA` DACK-since-arm | did the pump loop run? | **2** | 0 |
| `PDMA` bus / io-stall fires | did anything time out? | **0 / 0** | at least 1 |
| `PDMA` phase mask | where did the target go? | CMD, STATUS, MESSAGE, IDLE — **no DATA** | same, plus an abort |
| `PDM2` DACK-in-mismatch | the smoking gun | **1** | 0 |
| `PDM2` REQ-in-STATUS | separates the `io_busy` fallback | 1 | 0 if `req` was suppressed |
| `PDM2` phase ring | the sequence, not just the set | IDLE, MESSAGE, STATUS, CMD | — |

Everything except the lifetime DACK total is cleared on selection, so a capture
describes the **last transaction** — the wedged one. The `PDM2` bits are cleared
there too, which is itself tested: a sticky bit that can never clear reads the
same on every capture and measures nothing.

`sim/tb_dbg_probes.v` drives the deck from a real `ncr5380` + `scsi` pair over a
modelled **CPU bus** (`cpuAddr`/`_cpuAS`/`_cpuRW`, SCSI at `0x58xxxx`, register
in A6-A4, DACK on A9), replays the wedge and checks every packed field. It found
a bug in itself immediately (a 25-bit address literal), and three mutations of
the deck — a per-arm counter that never re-arms, an inverted DACK decode, a
phase decode that confuses STATUS with DATA-OUT — are each caught by it.
`sim/test_read_probes.tcl` runs the reader script itself against synthetic
captures with the Quartus JTAG commands stubbed, because the reader
re-implements the bit packing by hand in Tcl and a mis-slice there reads back as
a plausible number. That is exactly how the first DACK row misled us.

**Cost of the tap.** This does what §3 said the deck would not: one 12-bit
`dbg_bus` output on `ncr5380` and one 2-bit `dbg_abort` on `scsi.v`. The abort
bit is unavoidable — an abort and an ordinary completion are indistinguishable
from outside the target, and separating them is the measurement that alone
splits the two readings. The other eleven bits are raw state; every counter,
epoch and sticky bit still lives in `dbg_probes.sv`. Both ports prune when the
deck is not instantiated.

**Next, in order:** build with `USE_SCSI_ISSP`, boot with no disc, wedge it, run
`quartus_stp -t scripts/read_probes.tcl`, and read the verdict line. Then apply
the fix — and resolve the `BSR=0x90` vs `0x80` question from that capture, since
`PDM2` now reports whether the IRQ ever latched.

### The hardware capture, and the fix (2026-08-22, commit `ce70a45` + this one)

Captured on the DE10 with the machine wedged at "Welcome to Macintosh", no disc
mounted, booting from a SCSI hard disk. **The reading is confirmed.**

```
PSCS  last READ  reg=BSR  val=80        PSCW  last WRITE reg=DMAinitRcv
PODR  00 00 01 00                       PIO2  cd rd=0   disk0 rd=170
PRG   rd CDR (DACK) 55  x8              <- 0x55 is ncr5380's idle `din`
PDMA  DACK reads since the DMA arm: 15 (saturated)   arms since selection 1
      watchdog fires since selection: bus=0  io-stall=0
PDM2  DACK-in-mismatch=1  ACK-in-STATUS=1  IRQ-latched=1  REQ-in-STATUS=1
      live: BSY=0 REQ=0 DMA_EN=1 PMATCH=0
```

* **`ACK-in-STATUS=1` with `DACK-in-mismatch=1`** — a DACK read pulsed ACK while
  the target sat in STATUS. That is the mechanism, observed directly.
* **Both watchdog counters are 0.** The missed-REQ reading needs at least one.
  Dead.
* **`cd rd=0`** — the CD target never once asked the HPS for a sector, so no
  data phase was ever dispatched, independently of the phase mask.
* **The bus is free** (`BSY=0`) while the driver polls, and the eight newest
  accesses are DACK reads returning `0x55` — `ncr5380`'s idle `din`. The driver
  is blind-reading a bus with nobody on it.

Two things did NOT match the prediction, and both are informative:

1. **15+ DACK reads, not 2.** The prediction assumed the loop stops when DRQ
   drops. It does not — that is what *blind* means. It eats STATUS and MESSAGE,
   then keeps pumping the rest of its count off a dead bus. Not a falsification;
   a correction to the model of the driver. The 4-bit counter saturated at 15
   and hid the real figure, so it is 8 bits now.
2. **A `DATA-IN` bit in the phase mask** — for a transaction that had no data
   phase. This was **my instrument being wrong**: `dbg_bus[0]` was `scsi_bsy`,
   which also carries the *initiator's* own BSY (ICR bit 3) and `MR_ARB`. During
   arbitration both are high while no target drives MSG/CD/IO, and the decoder
   read that as phase 3. Fixed to `|target_bsy`, with a regression in
   `sim/tb_dbg_probes.v` that fails if the tap ever goes back. It also explains
   the `IDLE, DATA-IN, CMD` ordering in the phase ring, which is otherwise
   impossible. Because of the false DATA bit the verdict line printed
   "inconclusive" on a capture that was conclusive.

**`BSR=0x90` vs `0x80` is settled too.** `IRQ-latched=1` (sticky, since
selection) with a live `BSR` of `0x80` means the latch *was* set and a reg-7
read has since cleared it. Both earlier readings were true, at different moments
— and the driver does read reg 7.

**The fix, now applied:**

* `dreq` and `bsr_dmarq` gain the `bsr_pmatch` term: DRQ is inhibited on a phase
  mismatch, as a real 5380 does.
* `dma_ack` gains it too, so a DACK access during a mismatch cannot ACK.
* `irq_latch` becomes **level**-triggered (`dma_armed && scsi_req &&
  !bsr_pmatch`). The edge form only fires when the mismatch appears *after* the
  arm; here it predates it, so no edge and no IRQ. Gated on `dma_armed` rather
  than the review's suggested `dma_en`, because `seam6` documents why gating on
  `dma_en` drops the IRQ when a driver clears MR.DMA_MODE before the phase
  change.

`seam11` now asserts the corrected behaviour: DRQ inhibited, no ACK, target
still in STATUS still asking, REQ visible in CSR so the poll loop can exit, and
the IRQ latched. The register path still completes the transaction.

### The fix was keyed on the wrong signal (2026-08-22, same day)

Gating the DMA handshake on `bsr_pmatch` **broke every pseudo-DMA write**. The
board hung earlier than before, before "Welcome to Macintosh". The capture:

```
PSCW  last WRITE reg=ODR (DACK)         PRG  wr ODR (DACK) 00  x8
PDMA  DACK reads since the DMA arm: 0   watchdog fires: bus=1  io-stall=0
PDM2  ACK-in-STATUS=0  IRQ-latched=1    phase ring: IDLE STATUS DATA-IN CMD ...
```

`dma_ack <= dma_en & bsr_pmatch` with `DMA_EN=1` and eight DACK writes that
produced no ACK leaves only one possibility: **`bsr_pmatch` was 0 for the whole
write data phase**. The Plus driver does not maintain TCR across a write, so a
gate keyed on TCR refuses every handshake, the target waits, and its bus
watchdog fires at 129 ms — `wdog=1` in the capture, which is also the first time
that recovery path has been seen working on hardware.

**Re-keyed onto the bus phase**: `bus_data_phase = scsi_bsy & ~scsi_cd &
~scsi_msg`. What must never happen is a DACK access ACKing a byte from a
NON-data phase; that is the confirmed defect, and it can be said directly
without depending on the driver's TCR discipline. It is the same condition
`bsr_eodma` already reports, so the two cannot disagree. The completion-IRQ
latch was re-keyed the same way — on "the target is asking from STATUS or
MESSAGE" (`cd & io`) rather than `!bsr_pmatch`, which also fired during COMMAND
phase and latched a completion IRQ on a transaction that had not reached its
data phase (visible as `BSR=0x98` mid-write).

**`seam12` is the test that should have existed first.** `seam11` only ever
covered the READ direction, which is why nothing caught this before a 16-minute
build and a hardware round trip. seam12 drives a WRITE(6) data phase with TCR
deliberately left at `0x01`, and requires the transfer to complete anyway.
Mutating the gate back to `bsr_pmatch` fails exactly three of its assertions.

**Open question, not needed for the fix:** whether TCR is stale from the
previous read or never written at all for writes. The probe deck does not tap
TCR; add it if this comes back.

### Reverted: two gate attempts, two hardware hangs (2026-08-22)

Both attempts at inhibiting the DMA handshake outside the armed phase passed
every bench in this tree and both hung the machine **earlier** than the bug they
were fixing. The RTL is now back to its `ce70a45` behaviour — the CD-ROM
no-media wedge is present again, deliberately, because a machine that reaches
"Welcome to Macintosh" is a better base than one that does not boot at all.

| attempt | gate | bench result | hardware |
|---|---|---|---|
| 1 | `bsr_pmatch` | all green | hangs early; no ACK all through a write data phase, bus watchdog fires |
| 2 | `scsi_bsy & ~scsi_cd & ~scsi_msg` | all green, incl. the new seam12 | hangs early, **same counters, same PC** |

Attempt 2 is the important one: `seam12` models a write data phase with a stale
TCR and passes, yet hardware fails identically to attempt 1 — `writes:34`,
`disk0 rd=113`, `PC=417454`, same phase ring. Either the failure is perfectly
deterministic, or the board was not running the bitstream we think it was. That
has to be ruled out before anything else is concluded.

**What both attempts had in common, and why guessing a third time was refused:**
no bench models *when the driver starts pumping relative to the target entering
its data phase*. If the blind loop writes while the target is still in COMMAND,
a gate that refuses those accesses drops bytes the ungated code silently
accepted, and the transfer deadlocks — which is exactly the shape of both
failures. Nothing in the probe deck could see that window.

**So the deck now measures it.** New `PDM3`:

| field | question |
|---|---|
| phase at the DMA arm | did the driver arm before the data phase existed? |
| TCR at the arm, and pmatch at the arm | what phase did it *think* it armed for? |
| phase of the **first** DACK access after the arm | where does the pump loop actually start? |
| DACK **writes** since the arm | PDMA only counted reads, and read 0 on every write transfer |
| a DACK landed outside a data phase | the sticky that any future gate must be keyed on |
| TCR live | settles whether TCR is stale or never written |

`seam11` is back to characterising the defect, `seam12` stays (it passes on the
ungated RTL too, and is the regression guard for attempt 1). Gates are
`disk 12/12, CD 35/35, seam 51/51, probes 29/29, reader 13/13`.

**Next capture answers, in one shot:** where the driver arms, where it starts
pumping, what TCR holds, and whether any DACK access ever lands outside a data
phase. A gate can then be written against measurements instead of a model.

### SESSION END STATE — 2026-08-22 evening (read this first next session)

**The wedge mechanism is confirmed on hardware. The fix is not done.** Three
attempts; all three passed every bench; two were built and both broke the
machine *worse* than the bug. The third is committed but **never built**.

#### What is proven

* The mechanism (review reading #3) is real, in sim and on hardware:
  `ACK-in-STATUS=1`, `DACK-in-mismatch=1`, both watchdog counters 0, `cd rd=0`,
  bus free while the driver polls, DACK reads returning `0x55` (ncr5380's idle
  `din`). A DACK read ACKs the CHECK CONDITION status byte as if it were sector
  data.
* The driver's blind loop does **15+** DACK reads, not 2 — it does not stop when
  DRQ drops. That is what *blind* means.
* `BSR=0x90` vs `0x80` is settled: the IRQ latch was set and a reg-7 read
  cleared it. This driver **does** read reg 7.
* The bus-watchdog recovery from `b7e928e` works on hardware (first sighting).

#### The three attempts

| # | change | bench | hardware |
|---|---|---|---|
| 1 `bcb8a68` | gate on `bsr_pmatch` + level IRQ latch | green | hangs early, no ACK through a write data phase, wdog fires |
| 2 `2187326` | gate on bus phase + level IRQ latch | green (incl. seam12) | hangs early, **byte-identical counters to #1** |
| 3 *(working tree)* | gate on bus phase, **IRQ latch untouched** | green | **NEVER BUILT** |

Attempt 2 was re-flashed over JTAG with the bitstream identity confirmed by
md5 against its archive, and it failed again — so it is genuinely broken, not a
stale-core artefact.

#### The live hypothesis, and why attempt 3 exists

Attempts 1 and 2 each changed **two** things: the DACK gate *and* the
completion-IRQ latch (made level-triggered). Both captures show `BSR=0x98`
mid-write — bit 4, IRQ, **set during a healthy write**, because the level form
fires in COMMAND phase, long before any data phase. A driver that reads bit 4 as
"transfer complete / error" would stop pumping right there, which is exactly
what both captures show: ~8 bytes written, then polling forever while the target
waits for an ACK that never comes.

**So the gate may never have been the problem.** Attempt 3 is the isolating
experiment: the gate alone, IRQ latch left edge-triggered. One variable.

#### Exact state of the tree

* HEAD `ac38fc9`. Uncommitted: `rtl/ncr5380.sv` (attempt 3) and
  `rtl/build_tag.v` (stamped `ac38fc96`, regenerated per build — expected dirty).
* Behavioural delta vs `ce70a45` is exactly three lines: `dreq`, `dma_ack` and
  `bsr_dmarq` gained `& bus_data_phase`, where
  `bus_data_phase = scsi_bsy & ~scsi_cd & ~scsi_msg`. `irq_latch` is untouched
  (edge form). Verified with `git diff ce70a45 -- rtl/ncr5380.sv`.
* Gates all green: `disk 12/12, CD 35/35, seam 51/51, probes 29/29, reader 13/13`.

#### Hazards left behind

* **A compile was killed mid Analysis & Synthesis** (18:24) after RTL was edited
  underneath it — my error, and exactly the hazard already recorded in the JTAG
  notes. `db/` and `incremental_db/` may be inconsistent. **Delete both before
  the next compile.**
* `output_files/MacPlus.rbf` and `.sof` are still **attempt 2** (17:39), and the
  board is running attempt 2. Anything loaded from that path right now is the
  broken build.
* `sim/tb_dbg_probes.v` asserts RTL *behaviour*, so it has to be flipped every
  time the gate is switched on or off. That is a design flaw in that bench — it
  should assert instrument properties only. Worth fixing.

#### New instrumentation, built but never exercised on hardware

* `PDM3` — phase at the DMA arm, TCR and pmatch at the arm, **the phase of the
  first DACK access after the arm**, DACK writes per arm, a sticky for any DACK
  landing outside a data phase, TCR live. This is the window neither attempt
  could see and the reason a third guess was refused.
* `PBLD` — `rtl/build_tag.v` carries the git SHA, printed on every sample line
  as `bitstream=xxxxxxxx`. Regenerate it from `git rev-parse --short=8 HEAD`
  before every compile.

#### Next session, in order

1. `rm -rf db incremental_db` (the killed compile), then compile attempt 3.
2. Flash it, boot with **no disc**, same config (SCSI HD boot).
3. If it reaches "Welcome to Macintosh" and boots through — the gate was always
   fine and the level IRQ latch was the regression. Then decide separately
   whether the IRQ latch gap is worth closing.
4. If it still hangs early — the gate itself is implicated after all, and PDM3
   now says where the driver arms and where its first DACK lands. Read that
   before touching anything.
5. Standing fallback if this keeps costing build cycles: the CD-ROM target sits
   behind `cd_enable` and the core is fully working with it off. Shipping
   Phase 1 without Phase 2 remains a legitimate outcome.

### Audit before the third build: one link in the argument does not hold (2026-08-22, later)

Re-read the two failed attempts against the commits rather than the prose, because
attempt 3 was about to be built on the strength of a hypothesis nobody had checked.

**The stated reason for expecting attempt 3 to work is not supported by the evidence.**
The session-end summary says "attempts 1 and 2 each changed two things ... both
captures show `BSR=0x98` mid-write, because the level form fires in COMMAND phase".
That is true of attempt 1 and **false of attempt 2**:

| attempt | gate | IRQ latch condition | fires in COMMAND (CD=1, IO=0)? |
|---|---|---|---|
| 1 `bcb8a68` | `bsr_pmatch` | `dma_armed && scsi_req && !bsr_pmatch` | **yes** |
| 2 `2187326` | `bus_data_phase` | `dma_armed && scsi_req && scsi_cd && scsi_io` | **no** — `io` is 0 |
| 3 `3426398` | `bus_data_phase` | `dma_armed && pmatch_d && !bsr_pmatch` (edge, untouched) | n/a |

Attempt 2's latch cannot fire in COMMAND phase, so the `BSR=0x98` explanation
belongs to attempt 1's capture only and was generalised to both when the summary
was written. Tracing it back: it appears at its origin (the attempt-2 write-up,
where it is correctly attributed to attempt 1 and given as the *reason* for
re-keying) and then again in the summary as though it were an attempt-2
observation. No attempt-2 capture showing `0x98` is recorded anywhere.

**So the important fact is the one that is still unexplained.** Attempts 1 and 2
differ in *both* changed terms, and produced byte-identical hardware state
(`writes:34`, `disk0 rd=113`, `PC=417454`, same phase ring). Two materially
different RTL variants failing byte-identically has two readings, and the plan
only records one:

* **H-A (recorded):** both level latches set BSR bit 4 too early — via different
  phases — and the driver's response to "transfer complete" arriving early is the
  same either way, so the downstream counters match. Survives the correction, but
  now rests on a mechanism nobody has demonstrated for attempt 2.
* **H-B (not recorded):** the board ran the *same* bitstream both times, so
  attempt 2 was never actually exercised. The md5 check that was done proves
  which **file** was programmed; it does not prove the FPGA was still running it
  at capture time, because the core reloads `output_files/MacPlus.rbf` from SD
  whenever it is re-selected.

H-B has never been testable before. It is now: `PBLD` stamps the git SHA into
every capture line. **`bitstream=` is the first field to read in the next capture,
before any conclusion is drawn from any other field.** If it does not match the
build that was just flashed, nothing else in that capture means anything — and
the same is retroactively true of the attempt-2 capture.

Both hypotheses take the same next step, so this does not change the plan; it
changes what the next capture has to be checked for first.

**Fixed while here, all five gates green (`disk 12/12, CD 35/35, seam 51/51,
probes 31/31, reader 13/13`):**

* `bus_data_phase` was declared at column 0, *after* its first use in `dreq`.
  Hoisted above the first use; `bsr_eodma` now derives from it (`~bus_data_phase`)
  instead of repeating the expression, so the comment's claim that "the two
  cannot disagree" is structurally true rather than a promise.
* **`PBLD` was not covered by any bench, and `rtl/build_tag.v` was not in the
  probes gate's compile line** — the instrument meant to settle H-B was itself
  unproven, against the standing rule that instruments are proven before they are
  trusted. Two tests added (`probes` is now 31); without `rtl/build_tag.v` the
  bench no longer elaborates at all, so the file cannot silently drop out again.
* **The tag was stamped `ac38fc96` while HEAD was `3426398e`** — it was hand-
  edited and then committed, so it named the *previous* commit. A capture that
  misnames its own build is worse than no tag. `scripts/stamp_build_tag.ps1` now
  generates it from `git rev-parse --short=8 HEAD`, warns if design files are
  dirty, and is to be run immediately before each compile, leaving `build_tag.v`
  dirty in the tree by design.

**And the stamping script bit immediately, which is the point of writing it.**
Windows PowerShell 5.1's `Set-Content -Encoding utf8` writes a **BOM**, and
iverilog will not parse a file that starts with one: it reported `build_tag`
as a missing module and produced no executable. That was nearly missed,
because a stale `.vvp` from the previous run was still on disk and `vvp` ran
it happily -- the new PBLD tests "passed" against a binary built before they
existed. The script now writes UTF-8 without a BOM, and the gate runs check
the compile's exit status and the absence of a "were missing" warning before
trusting any PASS line. Piping iverilog into `tail` hides its exit status;
don't.

**H-B, answered by the user: the JTAG flash was discarded before the capture.**
Confirmed directly — the core *was* re-selected/power-cycled after programming
the `.sof`. On MiSTer that makes the HPS reload the `.rbf` from disk, which
overwrites the JTAG-programmed bitstream. **So the md5 check proved nothing
about what ran**: it verified the `.sof` file, and the `.sof` was thrown away
seconds later. Whatever executed came from the `.rbf` path.

Whether that `.rbf` was attempt 2 now turns entirely on how the file reaches
the board, and **nothing on this machine can answer that**: there is no
archived `.rbf` for attempt 1 or attempt 2. `output_files/MacPlus.rbf` is one
file every build overwrites, and the per-SHA archives that do exist
(`MacPlus.rbf.010dff8` and friends) are from an older session and predate both
attempts. The sole evidence of what ran is a file timestamp.

Two consequences, both procedural:

1. **Stop JTAG-flashing `.sof` for these tests.** It is discarded by the very
   action needed to boot the machine. Put the build on the path the core
   actually loads, then load it. One artefact, one route.
2. **Archive the `.rbf` under its SHA at every build**, the way `PBLD` stamps
   the bitstream — so "which build was that?" stays answerable afterwards and
   not only live over JTAG.

Attempt 2 is therefore **not a trustworthy data point**. It may have run; it
cannot be shown to have run. Its byte-identical counters should not be treated
as evidence about the gate, and the argument for attempt 3 does not need them:
attempt 3 is the one-variable experiment regardless.

**Compile hazard confirmed, not yet cleared:** `compile_log.txt` ends mid-word
(`Warni`), so the 18:24 Analysis & Synthesis really was killed. `db/` (700 files)
and `incremental_db/` must be deleted before the next compile.

### The board answered: the gate works, and it is also what breaks the machine (2026-08-22, live)

**Retraction first.** The section above concluded attempt 2 "cannot be shown to
have run" and that no per-SHA `.rbf` archives existed for the two attempts. Both
claims are wrong. The archives use `MacPlus_<sha>_<tag>.rbf`, which my glob
missed: `MacPlus_bcb8a68_pmatchgate.rbf` and `MacPlus_2187326_dataphasegate.rbf`
are both on disk. `output_files/MacPlus.rbf` is md5-identical to the latter, and
the running bitstream carries exactly 14 ISSP instances — PDMA and PDM2 but no
PDM3 and no PBLD — which is precisely attempt 2's probe set, since PDM3 arrived
in `13cdd79` and PBLD in `ac38fc9`. **H-B is dead. Attempt 2 genuinely ran.**

**And the reader was lying.** Against that 14-instance bitstream,
`read_probes.tcl` printed a full, confident PDM3 block — *"at the DMA arm:
phase=IDLE ... no DACK access at all since the arm"* — entirely fabricated,
because `rd()` returned 0 for any absent instance and every derived field
formatted that zero as data. `bitstream=00000000` likewise read as an unstamped
tag rather than a missing probe. Fixed, with five tests (reader 13 -> 18).

#### What attempt 2 actually does on hardware

Four samples, machine wedged, CPU alive and looping over `0x417450-0x417454`:

```
PSCS  last READ  reg=BSR  val=98  (reads:42 -> 143 -> 56 -> 159, wrapping)
PSCW  last WRITE reg=ODR (DACK)   val=00  (writes:34, FROZEN)
PDMA  DACK reads since the DMA arm: 0    arms since selection 1
      watchdog fires since selection: bus=1  io-stall=0
      phases visited since selection: IDLE CMD DATA-IN STATUS
PDM2  DACK-in-mismatch=0  ACK-in-STATUS=0  IRQ-latched=1  REQ-in-STATUS=1
      live: BSY=0 REQ=0 DMA_EN=1 PMATCH=1
```

* **The gate works.** `ACK-in-STATUS=0` and `DACK-in-mismatch=0`: no DACK access
  ever consumed a byte from a non-data phase. The confirmed defect is fixed.
* **But a new failure replaced it.** The transaction reached a *legitimate*
  `DATA-IN` phase, the driver armed pseudo-DMA — and then did **zero** DACK
  reads. The target's bus watchdog fired at 129 ms, the bus went free, and the
  driver has been polling `BSR=0x98` ever since. `0x98` is eodma + IRQ + pmatch:
  **DRQ (bit 6) is clear.** The driver is waiting for a DRQ that the gate can
  suppress and that never comes.
* This **exonerates the completion-IRQ latch** the plan blamed. `IRQ-latched=1`
  and BSR bit 4 is set, yet the loop does not exit on it — the loop's `BTST`
  tests a different bit, and the failure is "never pumped at all", which a latch
  that only sets bit 4 cannot cause.

#### Attempt 4: gate the ACK, leave DRQ visible

So the gate on `dreq`/`bsr_dmarq` is implicated and the gate on `dma_ack` is not.
Attempt 4 keeps only the latter:

| | dreq | bsr_dmarq | dma_ack | IRQ latch |
|---|---|---|---|---|
| attempts 1-3 | gated | gated | gated | 1,2 level / 3 edge |
| **attempt 4** | **un-gated** | **un-gated** | **gated** | edge (untouched) |

This is the minimal change that fixes the confirmed defect, and it cannot cause
a DRQ-visibility regression because it does not touch DRQ. The review's actual
exit ramp is preserved: `seam11` still passes *"CSR shows REQ, so the polling
loop can exit"*, and still passes *"does NOT ACK it: the target stays in
STATUS"* and *"ACK was never asserted in STATUS"*.

A real 5380 does inhibit DRQ on a phase mismatch, so this is knowingly less
faithful than the review asked for. That fidelity is what two builds died on. If
PDM3 later shows the inhibition is needed, it can be added back as its own
one-variable change — with the instrument to see it, which attempt 2 lacked.

`seam11`'s DRQ assertion was flipped to match, and that is the third time this
bench has had to be edited to track an RTL decision. **The benches that assert
RTL *policy* rather than instrument properties remain a real design flaw** — see
the note in the session-end state.

Two hypotheses were also closed out in sim, both negative results worth keeping:

* **seam13** (new): the driver pumping *before* the target reaches its data
  phase — the window the plan named as unmeasured, which neither seam11 nor
  seam12 covers because both `wait_raw_req` first. It **passes** on the gated
  RTL, so early pumping does not explain the regressions.
* **seam12** already covered the stale-TCR write, which killed attempt 1.

Gates: `disk 12/12, CD 35/35, seam 56/56, probes 31/31, reader 18/18`.
**Attempt 4 is UNBUILT.**

### Gates

`disk 12/12, CD 35/35, seam 51/51, probes 31/31, reader 13/13` — run all five,
disk first. The last two cover the instrument, not the core:

```
C:/iverilog/bin/iverilog.exe -g2005-sv -o sim/out/tb_dbg_probes.vvp sim/tb_dbg_probes.v rtl/dbg_probes.sv rtl/ncr5380.sv rtl/scsi.v rtl/build_tag.v && C:/iverilog/bin/vvp.exe sim/out/tb_dbg_probes.vvp
tclsh sim/test_read_probes.tcl
```

### Debug scaffolding to remove when this closes

OSD: `status[21:19]` CD Debug ladder, `status[24:22]` MODE SENSE bisect,
`status[28:25]` vendor-command bisect, `status[16:15]` no-media sense bisect.
RTL: `cd_dbg`, `cd_ms_mode`, `cd_vendor_dbg`, `cd_sense_mode`, `USE_SCSI_ISSP`,
`rtl/dbg_probes.sv`, and the debug taps it needs — `dbg_bus` on `ncr5380`,
`dbg_abort` on `scsi.v`, `scsi_dbg` through `dataController_top`. Drop
`sim/tb_dbg_probes.v` and `sim/test_read_probes.tcl` with them. Keep `cd28`/`cd32` (under-serve regression guards),
`seam9`/`seam10`, and the seam bench itself.
