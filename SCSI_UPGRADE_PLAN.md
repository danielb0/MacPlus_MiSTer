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
  bootable hard disk. **The scan order is confirmed on hardware (2026-08-23):**
  with ID 6 empty the machine boots from ID 5.
- **CORRECTION (2026-08-23): the CD cannot boot at all.** This bullet used to
  claim a bootable CD "*can* still boot when no hard disk is bootable, which is
  the desirable behaviour". That was inferred from the scan order alone and never
  tested. It is wrong, on two independent counts — see "The CD does not boot"
  below.
- ID 3 is also the AppleCD SC factory default.
- The LC's layout (disks 0/1, CD 3) would have **inverted** this: the CD would be
  found before the disks. Rejected for the Plus.

#### The CD does not boot — tested on hardware, 2026-08-23

Two independent reasons, either one sufficient:

**1. There is normally no disc present when the ROM scans.** MacOS shutdown ejects
mounted volumes, the driver issues EJECT, and `rtl/scsi.v:374` drops `mounted`.
The HPS-side image stays attached while the target reports no-disc until the user
mounts again. So after a normal shutdown ID 3 is empty at the next boot scan.
This is correct and period-accurate — an ejected drive has no disc.

**2. The block size is incompatible with the Plus ROM.** The ROM's boot reader
builds an `0x08` READ(6) CDB and expects a **512-byte** block carrying the `0x4552`
'ER' signature. Our CD target correctly reports **2048-byte** logical blocks
(`capacity` = `img_blocks[31:2] - 1` at `scsi.v:368`; MODE SENSE block length
`0x000800` at `scsi.v:426`; READ(6) LBA/length scaled `<<2`). A one-block READ(6)
therefore delivers 2048 bytes to an initiator expecting 512.

Underneath both: the Plus ROM is from 1986 and Apple's first CD-ROM drive shipped
in 1988. Real Plus hardware could not boot from CD either. By §2's authenticity
rule this is the CORRECT behaviour, not a gap — do not "fix" it.

**Observed, with the CD mounted manually and no bootable hard disk** (probe capture
on `ea4167b2`):

```
PIOS  cd fetch stuck=0   lba=1024            <- CD logical block 256, reads==acks
PDMA  watchdog fires since selection: bus=2  io-stall=0
      phases visited: IDLE CMD DATA>init(READ) STATUS
PDM2  sticky: DACK-in-mismatch=1  REQ+DMA-in-mismatch=1  REQ-in-STATUS=1
PDM3  NOTE: a DACK access landed OUTSIDE a data phase this transaction.
```

The disc WAS read (fetches served, `io-stall=0`). A complete CMD -> DATA-in ->
STATUS transaction ran, then initiator and target diverged on the data phase and
the **bus watchdog fired twice**. That is the shape of an initiator taking 512
bytes from a 2048-byte block — consistent with reason 2, though the capture does
not prove it: `PODR` showed an all-zero CDB tail, so the opcode was not identified.
Pinning it needs a log running across the reset.

**It fails SAFELY, which is the result that matters.** `PIFA` fetch# advanced
across samples, `PACT` bus cycles climbed, and the CPU sat looping at `PC=0x41740E`
on `67FA` (a tight `BEQ.S` back-branch — the ROM's no-boot poll). The bus watchdog
recovered the bus and the machine fell through to "no bootable device" instead of
wedging. The `iowdog` work doing its job on a path it was not designed for.

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

**The output is genuinely stereo (user, 2026-08-22).** MiSTer's `sys_top` carries
separate 16-bit `AUDIO_L`/`AUDIO_R`, so CD audio does not have to be folded down
— the Mac's own mono output goes to both channels and the CD's two channels can
be mixed in as true stereo. That removes the main reason to compromise on the
mixer design, and it makes the signedness question below MORE important, not
less: a mono error is a volume error, a stereo error is an image error.

#### RESOLVED (2026-08-24): the signedness question was a false alarm

This section used to carry a blocking investigation: whether
`assign AUDIO_L = {audio[10:0], 5'b00000}` with `AUDIO_S = 1` was placing an
unsigned 0..2047 value in a signed field, making everything above 1024 read as
negative. **It is not. `audio` is already signed and centred**, and no fix is
needed.

The proof is `dataController_top.sv:162`:

```
audio_prebuf <= memoryDataIn[15:8] - 8'd128;
```

The Mac's sound buffer holds unsigned 0..255 samples; that subtraction converts
them to two's complement -128..+127. The volume stage
(`dataController_top.sv:136`) is an explicit `$signed` product yielding
-896..+889 in 11 bits. So the concatenation is an 11-bit signed value scaled x32
into 16 bits: **-28,672 .. +28,448**, correctly inside int16. `AUDIO_S = 1` is
right.

#### The REAL blocker: the disabled-state level is SIGNAL, not an offset

`dataController_top.sv:171`:

```
wire [7:0] audio_latch = snd_ena ? 8'h7f : audio_sample;
```

`snd_ena` is the raw /SNDENB pin level, so **1 means sound DISABLED** despite
the name. Disabled emits `8'h7f` = +127 -- near full-scale positive in this
signed domain, not silence. After volume and the x32 shift that is up to
**+28,448**, i.e. 87% of positive full scale.

**Do NOT "fix" this to `8'h00`.** It is deliberate, it is correct, and the
reasoning is invisible in the source. From the PR #12 discussion
(darylrichards, 2024-08-27/28; the change was `8'h00` -> `8'h7f`):

> The original sound hardware was PWM TTL, so the output was only ever zero or
> one. **Many programs ignored the PWM aspect and just drove the enable pin on
> and off to produce sound.** When the original hardware disabled the sound it
> went to a TTL '1'. Driving the analog value high when disabled emulates this
> properly, and produces sound in all the software that doesn't have sound now.

That is bug #7, with forum confirmation. sorgelig raised the obvious modern-
hardware objection -- "driving to 0 while muted is more friendly... setting to 1
may produce pops/clicks" -- and it was answered on authenticity grounds. So for
an entire class of software **the swing between buffer content and +127 IS the
waveform**. Zeroing it re-silences all of them.

Recorded here because the source gives no hint, and this analysis independently
proposed changing it to `8'h00` before the PR history was consulted.

#### Why that blocks the mixer

Two cases that must be told apart:

* Sound disabled **and staying disabled** -- a Mac idling, which is exactly when
  a user plays a CD -- parks the channel at a constant +28,448 at volume 7.
* Software **toggling** enable at audio rates: the same level is signal and must
  pass through untouched.

**A sustained level is inaudible DC; a toggling one is music.** Mixing full-scale
CD audio onto a +28,448 pedestal saturates every positive half-cycle: half-wave
clipping on all CD playback. And it cannot be left to MiSTer's downstream audio
path, because the clipping happens in **our** sum before `sys_top` sees it.

#### Proposed fix: emulate the AC coupling the real hardware has

The Mac's speaker is capacitively coupled. A constant TTL '1' makes no sound on
a real Plus *because the capacitor blocks it*. Our core omits that coupling, so
a DC level that was never audible on real hardware survives into a digital sum
where it costs 87% of the headroom. Restoring it is period-accurate rather than
a workaround, and it separates the two cases above the way the hardware did.

One-pole DC blocker, `y[n] = x[n] - x[n-1] + a*y[n-1]` with `a = 1 - 2^-K`:

```
// Sketch -- NOT yet built or simulated.
// x = the existing {audio[10:0], 5'b00000}, 16-bit signed.
// Internal width 18 bits: the step response can transiently exceed |x|.
reg signed [17:0] dcb_y;
reg signed [15:0] dcb_x1;
always @(posedge clk32) if (aud_ce) begin
    dcb_y  <= $signed({{2{x[15]}}, x}) - $signed({{2{dcb_x1[15]}}, dcb_x1})
              + dcb_y - (dcb_y >>> K);
    dcb_x1 <= x;
end
```

Corner and decay, taking the filter rate as the 48 kHz `sys/audio_out` pickup
(`fc ~= fs / (2*pi*2^K)`, time constant `2^K / fs`):

| K | corner | time constant | droop across a 5 ms half-cycle |
|---|---|---|---|
| 9  | 14.9 Hz | 11 ms | ~37% |
| 10 | 7.5 Hz  | 21 ms | ~21% |
| 11 | 3.7 Hz  | 43 ms | ~11% |

**Start at K=11** and make K a parameter. It kills the pedestal within ~0.2 s
while leaving enable-toggled square waves nearly untilted. Some droop on very
low-frequency toggling is expected and is what real AC coupling does too.

**Three things to get right, none of them obvious:**

1. **`>>>` on a negative number rounds toward -inf**, so the feedback term
   itself injects a small negative DC and the filter settles a little below zero
   rather than exactly at it. Either add a rounding constant or accept ~1 LSB.
   This is the classic DC-blocker foot-gun and it is self-defeating if missed.
2. **Pick the filter's sample rate deliberately.** `snd_ena` is combinational,
   so the toggle path has no inherent rate limit; the existing output is
   whatever `sys_top` samples at 48 kHz. Filtering at the Mac's ~22 kHz
   `snd_advance` tick would undersample the toggle waveform.
3. **Verify against the toggle-based software specifically**, not just the
   startup chime. The chime is buffer audio and already centred, so it exercises
   none of this. The titles named in bug #7 are the regression set.

**Conservative alternative**, if the DC blocker proves too invasive to a working
path: attenuate the Mac channel only while the CD is actually playing. Nothing
changes with no disc -- bit-identical, matching MacLC's exact-zeros property --
at the cost of an audible volume step when playback starts and stops.

#### The mixer itself is a straight port from MacLC

`MacLC.sv:687` sign-extends each source to 18 bits, sums, and saturates:

```
wire signed [17:0] audio_mix_l = {{2{asc_sample_l[15]}}, asc_sample_l}
                               + {{2{cd_snd_l[15]}}, cd_snd_l};
assign AUDIO_L = (audio_mix_l > 18'sd32767) ? 16'sd32767 :
                 (audio_mix_l < -18'sd32768) ? -16'sd32768 : audio_mix_l[15:0];
```

Full gain, saturating. `cd_snd_*` are **exact zeros** when the drive is not
playing, so the mix is bit-identical with no disc -- worth preserving here, since
it makes the whole feature a no-op for period purists. MacLC's own comment
records that they tried half-gain first and it drew a "CD sounds half as loud"
report; the real LC sums drive line-out with the DAC at unity. Inherit that
posture. With the pedestal handled, the only residual saturation is Mac and CD
both near full scale at once, which is rare and is what MacLC accepts.

#### The integration risk is the HPS channel, not the mixer

`cd_audio.sv` carries its own `ca_io_rd` / `ca_io_lba` / `ca_io_active` -- it
fetches audio sectors itself and arbitrates for the channel. **All five hps_io
slots are already spoken for** on this core: 0/1 the SCSI disks, 2/3 the
floppies, 4 the CD (`MacPlus.sv:174-179`). So the audio engine has to share
slot 4 with the SCSI CD target.

A shared request/ack window between two engines on one channel is the same shape
of seam as the 2026-08-22 wedge, which cost days. **It needs a seam test before
it reaches hardware**, not after. That is the real cost of this phase; the mixer
is an afternoon.

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

### Attempt 4 WORKS: booted to the desktop with no disc (2026-08-22, hardware)

**`bitstream=BDE27691`** — the tag did its job on its first outing, and all 16
probes are present. The machine booted through to the Finder with the CD drive
enabled and **no disc mounted**, the case that failed 5 out of 5 before.

```
sample 0   bitstream=BDE27691
  PIFA  PC=402772 -> 03F75C -> 07138A      CPU running normal code, not looping
  PDMA  DACK reads since the DMA arm: 18   arms since selection 1
        watchdog fires since selection: bus=0  io-stall=0
        phases visited: IDLE CMD DATA>init(READ) STATUS MESSAGE
  PDM2  DACK-in-mismatch=0  ACK-in-STATUS=0
  PDM3  at the DMA arm: phase=DATA>init(READ) TCR=1 pmatch=1
        first DACK access after the arm was in phase DATA>init(READ)
```

Every discriminator is on the healthy side: no watchdog fired, the transaction
walked the full `CMD -> DATA -> STATUS -> MESSAGE -> IDLE` sequence, the driver
armed *inside* the data phase with TCR matching, its first DACK landed in that
same phase, and `ACK-in-STATUS=0` — the original defect stays fixed.

**So the conclusion is settled.** The review's diagnosis was right and its
primary remedy — a DACK access must not ACK a byte from a non-data phase — is
the whole fix. Gating `dma_ack` alone delivers it. The second half of the
review's fix shape (inhibit DRQ, level-trigger the completion IRQ) was not just
unnecessary but actively harmful: **suppressing DRQ is what hung attempts 1 and
2**, and the IRQ latch was never implicated at all.

PDM3 also answers, on the healthy path, the question that justified building it:
the driver arms *after* the target is already in its data phase, not before. The
early-pump hypothesis was wrong in sim (`seam13`) and is wrong on hardware.

#### One more instrument trap, found in this capture

`rtl/scsi.v` names phases from the **target's** point of view — `PHASE_DATA_OUT`
is the target driving data *out to the initiator*, i.e. a **READ**, and
`PHASE_DATA_IN` is a **WRITE**. The reader printed those names raw, so every
capture stated the exact opposite of the transfer's direction: attempt 2's
"DATA-IN" was really a write, and this one's "DATA-OUT" is really a read. The
underlying numbers were always self-consistent (attempt 2's frozen accesses were
`wr ODR (DACK)`; this one's are 18 DACK *reads*), so no conclusion was wrong —
but the label was, and it is now `DATA>init(READ)` / `DATA>targ(WRITE)`, with two
tests pinning the direction (reader 18 -> 20).

#### The CD path proved positively, not just by absence of a hang

```
PIO2  cd rd=172 ack=172   disk0 rd=191      PIOS  cd fetch stuck=0
PDMA  watchdog fires: bus=0  io-stall=0
PDM2  DACK-in-mismatch=0  ACK-in-STATUS=0
```

**172 sector fetches asked for and 172 answered.** Every wedged capture in this
investigation read `cd rd=0` — the CD target never once reached the HPS. This is
the counter that separates "working" from "not hanging yet".

Both halves of the original bug report are now clear:

| case | before | after |
|---|---|---|
| no disc, boot | hangs 5/5 | boots consistently |
| disc mounted into a running Mac | intermittent hang | mounts immediately, 172 sectors read |

Note the disc is **ejected on restart**, which is correct: `mounted` has no reset
term and is cleared only by `cd_eject_pulse`, so the Mac's Shutdown Manager
issued a real EJECT — a physical AppleCD SC would spit the caddy out. It does
not come back on a core reset either, because the AppleCD driver mounts on the
insertion *edge* (`scsi.v` ~376) and a reset produces no new `img_mounted`
pulse. Cosmetic, outside the path changed here, and recorded rather than fixed.

#### Still open

* **With a disc mounted** the wedge was intermittent, via the same `cd_no_media`
  path (`!toc_ready` races a READ). Not yet re-tested on attempt 4.
* A real 5380 *does* inhibit DRQ on a phase mismatch. Attempt 4 knowingly does
  not. If that fidelity is ever wanted, it is its own one-variable change — and
  the evidence says it needs a very good reason.
* Debug scaffolding is still in the build (see the removal list below).

### Gates

`disk 12/12, CD 35/35, seam 51/51, probes 31/31, reader 13/13` — run all five,
disk first. The last two cover the instrument, not the core:

```
C:/iverilog/bin/iverilog.exe -g2005-sv -o sim/out/tb_dbg_probes.vvp sim/tb_dbg_probes.v rtl/dbg_probes.sv rtl/ncr5380.sv rtl/scsi.v rtl/build_tag.v && C:/iverilog/bin/vvp.exe sim/out/tb_dbg_probes.vvp
tclsh sim/test_read_probes.tcl
```

### Soak: System 7.1 installed from CD onto a 20 MB disk (2026-08-22)

**It worked, and the Mac BOOTS from the installed volume** — including "Building file: System" — the Installer assembling the
System suitcase resource by resource. That is thousands of small CD reads
interleaved with appends and resource-map rewrites on the disk, i.e. the
catalog/metadata-heavy small-write workload nothing had stressed until now. The
best write-path validation we have, and better than the 32 MB bulk copy.

Booting from it is the end-to-end proof the write path is byte-correct: a System
file boots only if every byte landed, and the boot re-reads the whole thing cold,
past any disk cache. **Phase 1's write path is now hardware-validated**, which no
amount of reading could establish.

Sampled mid-install and the deck read it correctly as healthy: register writes
climbing 33 -> 221 between samples, CDB tails advancing (`20 E3` -> `20 E4` ->
`20 E6`), `cd rd == ack` throughout, no watchdog of either kind, CPU PC scattered
across real code. This is also the first live confirmation of the reworked
verdict logic — it printed "bus ACTIVE" where the old code would have printed
FALSIFIED in capitals at a perfectly healthy machine.

**Open question, not diagnosed:** installing the System 7.1 CD's own CD-ROM
driver set left the CD unmountable; reverting to the previously installed
versions fixed it. The disc is pure HFS (Apple Partition Map, one `Apple_HFS`
partition, no ISO 9660), so the `File Access` extensions are not involved in
mounting it, and our TOC/subchannel coverage is reasonable — `0xC1`/`0x43` READ
TOC, `0xC2`/`0x42` subchannel, `0xCC` audio status, `0xCE` audio control, `0x44`
READ HEADER in LBA form. Missing: actual playback (`0x45`/`0x47`/`0x4B`) and
MSF-form READ HEADER, none of which should block an HFS mount.

A driver **version mismatch** was the first guess and is now unlikely: the user
installed the complete, self-consistent 7.1-era set, not a partial one.

#### KNOWN ISSUE (candidate, unproven): older Apple CD drivers may reject our drive identity

We answer INQUIRY as **`SONY` / `CD-ROM CDU-8004` / rev `1.9a`**
(`cd_inquiry_byte`, [scsi.v:292](rtl/scsi.v:292)).

Apple's CD-ROM driver was **drive-specific**: it checked the INQUIRY vendor and
product strings and refused to bind to a drive it did not recognise. That is why
third-party CD drives on classic Macs needed a patched Apple driver or a
third-party one (FWB CD-ROM Toolkit and similar). It is the most common reason a
Mac sees a CD drive on the bus and still will not mount anything from it.

The AppleCD SC was a rebadged **Sony CDU-8002**; the CDU-8004 is a later unit.
System 7.1 is 1992, so its driver plausibly predates the model string we report
and rejects it, while a later driver knows it and binds. That fits the evidence:
a *complete and consistent* older set failing looks like a whitelist rejection,
whereas a version mismatch would more likely crash or half-work.

**Confidence:** the mechanism (Apple drivers whitelisted drive identities) is
well established. Which exact strings each driver version accepted is NOT known
here. So this is a strong hypothesis, not a finding.

**Two ways to settle it, cheapest first:**

1. Reinstall the failing driver set and capture during a mount attempt. The CDB
   tail plus the sense we return names what it asked and what we said. If the
   driver simply never issues a second command after INQUIRY, that is the
   whitelist, confirmed without touching the RTL.
2. Change the product string to `CDU-8002` and rebuild. If the 7.1 drivers then
   mount, proven.

**Authenticity angle (plan section 2):** a CDU-8004 in a Mac Plus is an
anachronism its own era-appropriate software does not recognise. `CDU-8002` — the
actual AppleCD SC mechanism — is arguably the more correct identity for this
machine regardless of whether it fixes the mount. Worth deciding deliberately
rather than inheriting MacLC's choice, since the LC is a later machine running a
later System.

**Not a bug in the SCSI path.** The core works with the driver versions currently
installed; this only limits which period driver sets can be used.

**Instrumentation gaps this soak exposed** (both worth closing if the deck is
re-enabled for more work):

* **No disk write counter.** `PIO2` carries `d0_rd_cnt` only, so `disk0 rd` sits
  frozen through a heavy write and looks alarming while meaning nothing.
* **No disk LBA.** `PIOS` carries `cd_io_lba` only, which is why the io-stall
  wedge above could not be pinned to an address.

### Soak test found a SECOND wedge, unrelated to the first (2026-08-22)

Copying ~32 MB from CD to a hard disk hung the machine. **Not the bug we fixed** —
`ACK-in-STATUS=0`, `DACK-in-mismatch=0`, bus watchdog `bus=0`. Different signature:

```
PSCW  last WRITE reg=ODR (DACK)  (writes:58 FROZEN across 4 samples)
PIFA  PC looping 00FD1C - 00FD26      PSCS alternating BSR=98 / CSR=00
PDMA  watchdog fires: bus=0  io-stall=1      <-- the IO-STALL timer, not the bus one
      phases visited: IDLE CMD DATA>targ(WRITE) STATUS
PDM3  DACK writes since the arm: >=255       live: BSY=0 REQ=0 DMA_EN=1
```

**An HPS write never completed.** `IOWDOG_LOG=24` aborts an outstanding transfer
after 2^24 clocks at 32.5 MHz (~516 ms). The abort released the bus and left the
driver polling forever — **recovery that does not recover**, which is the real
defect here whatever triggered it.

**Ruled out by measurement, not assumption:**

* *Write past the end of the image.* The volume is 1.3 GB with 222 MB free.
* *LBA truncation.* 32-bit clean end to end: `scsi.v io_lba[31:0]` ->
  `ncr5380 io_lba[31:0]` -> `sd_lba[31:0]`, and `lba10` is a full 32 bits.
* *The 21-bit READ(6)/WRITE(6) ceiling* (2,097,152 blocks = exactly 1 GiB, and
  ~1.08 GB was in use, so this looked extremely promising). Dead: `cmd_read10`
  /`cmd_write10` (0x28/0x2a) are implemented and `lba10` is used for them.
* *The CD path.* `cd rd=96 ack=96`, `cd fetch stuck=0`.

**Leading hypothesis: SD-card write latency exceeded the 516 ms timeout.** Cards
stall for hundreds of ms during internal garbage collection, specifically under
sustained write load — which a 32 MB copy is and which hours of CD reading is not.

**Discriminator, not yet run:** repeat the same copy. Hanging at the same file =
deterministic (address/data dependent) and the probe deck needs the DISK lba added
— `PIOS` carries `cd_io_lba` only, which is why this could not be pinned down live.
Hanging elsewhere, or completing = timing, and the fix is ours.

**Aggravating factor: the volume is absurdly large for the era.** HFS addresses at
most 65,536 allocation blocks, so 1.3 GB means ~20 KB per block and every small
file costs 20 KB — far more block writes than the file count suggests. Legal (under
the 2 GB HFS ceiling) but nothing a Plus ever saw; period drives were 20-80 MB.
Testing continues on smaller images, which **masks this rather than fixing it**.

**Fixes worth making regardless of cause:**

1. An io-stall abort must leave the initiator recoverable, not polling a dead bus.
2. A longer timeout (`IOWDOG_LOG` 24 -> 26 is ~2 s) if SD latency is confirmed.
3. Still outstanding from Phase 1: `capacity <= img_blocks` on the disk path
   ([scsi.v:365](rtl/scsi.v:365)) advertises one block MORE than exists, and there
   is **no LBA bounds check anywhere** — an out-of-range LBA reaches the HPS and
   stalls exactly like this. Not the cause here, but the same crater.

### Debug scaffolding: removed (2026-08-22)

Removed now that the wedge is fixed and the CD path is proved (browsed and
loaded files from a mounted disc, `cd rd=172 ack=172`).

**Gone from the OSD** — four bisect ladders and their `status` bits:
`OJL` CD Debug (21:19), `OMO` CD MODE SENSE (24:22), `OPS` CD Vendor Cmd
(28:25), `OFG` CD NoMedia Sense (16:15). Those bits are now free.

**Gone from the RTL** — `cd_dbg`, `cd_ms_mode`, `cd_vendor_dbg`,
`cd_sense_mode` and everything they gated, collapsed to the level-0 behaviour
that shipped: `cd_ms_bisect_byte`, `cd_ms_kill_body`, `cmd_ok_cd_dbg`,
`cmd_ok_cd_sel`, `cd_vend_all/_supp/_unk_ok`, `cmd_ok_cd_bis`. `cmd_ok` is now
just `(CDROM != 0) ? cmd_ok_cd : cmd_ok_hd`, and the no-media sense is the
constant `02/B0` it always shipped as. ~5 kB out of `scsi.v`, plus the ports
through `ncr5380.sv` and `dataController_top.sv`.

**Kept, deliberately, against the earlier plan:** `rtl/dbg_probes.sv`, its taps
and both its benches. `USE_SCSI_ISSP` is **commented out in `MacPlus.qsf`**
instead of deleted, so the deck and its taps are pruned from a release build and
cost nothing — but re-enabling it is one line rather than a rebuild of the whole
instrument. It found this bug, its benches stay green with the macro off, and
three of the four instrument defects that made this hunt expensive were only
caught because the deck was under test. Delete it later if it ever gets in the
way; do not delete it to tidy up.

**Bench changes.** `cd29`/`cd30`/`cd31` characterised the MODE SENSE bisect and
went with it — the shipping response is covered independently by `cd22`, `cd23`,
`cd24` and `cd28`. `cd33`/`cd34`/`cd35` each had a state-0 leg asserting real
shipping behaviour, so they were rewritten to keep exactly that: vendor opcodes
are served, an unimplemented opcode CHECKs, an empty drive reports `02/B0`.
CD gate is 32 tests, down from 35, with no loss of shipping coverage.

Gates after removal: `disk 12/12, CD 32/32, seam 56/56, probes 31/31,
reader 20/20`. **UNBUILT — needs a compile and a hardware re-test.**


OSD: `status[21:19]` CD Debug ladder, `status[24:22]` MODE SENSE bisect,
`status[28:25]` vendor-command bisect, `status[16:15]` no-media sense bisect.
RTL: `cd_dbg`, `cd_ms_mode`, `cd_vendor_dbg`, `cd_sense_mode`, `USE_SCSI_ISSP`,
`rtl/dbg_probes.sv`, and the debug taps it needs — `dbg_bus` on `ncr5380`,
`dbg_abort` on `scsi.v`, `scsi_dbg` through `dataController_top`. Drop
`sim/tb_dbg_probes.v` and `sim/test_read_probes.tcl` with them. Keep `cd28`/`cd32` (under-serve regression guards),
`seam9`/`seam10`, and the seam bench itself.


## 5.7 The three remaining defects — fix plan (2026-08-23)

Everything above this point is Phase 1/2 history. This section is the plan for
the three defects that are still open, written after the 2026-08-23 review and
soak. Two of them were proven by inspection; the third was only ever *observed*,
and its mechanism is now established deterministically in simulation (below).

Nothing here changes the CD command set or the host-side 5380. All the fixes
live in `rtl/scsi.v`.

A fourth defect (D) turned up while writing the test for B, and is fixed here
too — it is live in the committed code today, on the CD path.

### Why these three are one change, not three

Defects A and B are a matched pair. READ CAPACITY advertises one block more than
the medium has (A), and nothing checks an incoming LBA against the medium at all
(B). Separately each is survivable; together they are a deterministic landmine —
block `img_blocks` is a block the driver is *told* is valid, and which can never
be serviced. Fixing B without A would make the last real block unreachable;
fixing A without B leaves every out-of-range access still hanging for half a
second. They ship together or not at all.

Defect C is the reason either of them presents as a *hang* rather than an error:
the recovery path that is supposed to turn a stalled transfer into a clean SCSI
error does not, on the write path, deliver its status at all.

---

### Defect A — READ CAPACITY returns the block COUNT, not the last LBA

`rtl/scsi.v:365`. SCSI-1 defines READ CAPACITY's returned value as the address of
the **last** logical block. The CD path already subtracts one; the disk path
returns `img_blocks` unmodified, so a 40960-block image is advertised as ending
at block 40960 — one past the end.

This is not a discovery. The code comment admits it: a knowingly deferred Phase 1
follow-up, left alone because "changing it here would alter what every existing
user's driver sees, and Phase 2 is meant to be purely additive."

**That argument does not survive contact with Defect B.** The concern was that an
existing volume might have been formatted against the inflated capacity and would
now find its last block outside the reported medium. But writing to that block has
*never worked* — with no bounds check, a write to `img_blocks` goes to an HPS that
cannot service it, and the command stalls for ~516 ms and then wedges (Defect C).
No existing volume can be relying on data in a block that was never writable. The
compatibility risk the comment defers to is empty.

**Fix.** Report `img_blocks - 1` on the disk path, matching the CD path and the
LC core.

```verilog
capacity <= (CDROM != 0) ? ({2'b00, img_blocks[31:2]} - 1'd1)
                         : (img_blocks - 1'd1);
```

**Test (`tb_scsi_target.v` test13).** Mount 40960 blocks, READ CAPACITY, require
the returned last-LBA to be 40959 and the block length to be 512. Fails today with
`cap=40960`.

---

### Defect B — no LBA bounds check anywhere

Nothing in `rtl/scsi.v` compares an incoming LBA against the mounted image size,
and there is no ILLEGAL REQUEST / ASC 0x21 (LOGICAL BLOCK ADDRESS OUT OF RANGE)
path. An out-of-range LBA is latched and handed straight to the HPS, which cannot
service it; `io_busy` holds, `req` is suppressed, and the target sits on the bus
holding BSY until the io-stall watchdog fires ~516 ms later — at which point
Defect C decides whether the initiator ever learns what happened.

A real drive fails the command immediately. So must this one.

**Fix.** Bound-check the CDB at command completion, before the parameters are
latched, and reject with CHECK CONDITION through the existing rejection path.

The check must run on the *combinational* CDB fields, not on the `lba`/`tlen`
registers: those latch on the same clock edge `cmd_cpl` is evaluated, so at
decision time they still hold the previous command's values.

```verilog
// Bounds check the CDB before it is latched. cmd6/cmd10 fields are raw here --
// on the CD path both `capacity` and the CDB address are in 2048-byte logical
// blocks (the <<2 to HPS sectors happens at latch time), so one comparison is
// correct for both personalities.
wire [31:0] cdb_lba  = cmd6_cpl ? {11'd0, lba6} : lba10;
wire [16:0] cdb_blks = cmd6_cpl ? {8'd0, tlen6} : {1'b0, tlen10};
wire [32:0] cdb_end  = {1'b0, cdb_lba} + {16'd0, cdb_blks};  // one PAST the last
wire lba_out_of_range = (cmd_read || cmd_write) && mounted && (cdb_blks != 0) &&
                        (cdb_end > ({1'b0, capacity} + 33'd1));
```

Three details that are easy to get wrong:

* **Zero-length transfers are legal.** A READ(10) with a transfer length of 0
  moves no data and must not be an error, hence the `cdb_blks != 0` guard.
* **The end, not the start.** A transfer that begins in range and runs off the
  end is equally out of range. Checking only `cdb_lba` would let it through and
  stall on the last sector instead of the first.
* **33-bit arithmetic.** `cdb_lba` is 32 bits and the transfer length can be
  65535, so the sum is widened before comparison; a 32-bit add would wrap and a
  wildly out-of-range LBA would test as valid.

Wire it into the two places a rejection already exists — the CMD_IN gate and the
sense latch:

```verilog
if(cmd_ok && !cd_no_media && !cd_hdr_msf_rej && !lba_out_of_range) begin
```

```verilog
end else if (lba_out_of_range) begin
    sense_key <= 4'h5;  // ILLEGAL REQUEST
    sense_asc <= 8'h21; // LOGICAL BLOCK ADDRESS OUT OF RANGE
```

placed after the `cd_no_media` branch, so an empty CD drive still reports no-disc
rather than a bounds error.

**Tests (`tb_scsi_target.v`).**

| test | what it pins |
|---|---|
| test14 | READ at `img_blocks` → CHECK CONDITION, bus released |
| test15 | the follow-up REQUEST SENSE reports `05/21` |
| test16 | a READ that *starts* in range and runs past the end is also refused |
| test17 | **the guard in the other direction** — the last valid block still reads byte-exact |
| test18 | out-of-range WRITE refused *before any flush is issued* |

test17 is the one that matters most. A bounds check that is itself off by one
would amputate the last sector of every disk on the system — far worse than the
defect it replaces. It passes today (there is no check to be wrong yet) and must
still pass after.

---

### Defect C — the io-stall abort never delivers its status on a write

**Status: mechanism now PROVEN in simulation.** The 2026-08-23 handoff recorded
this as "observed once, mechanism unknown", and warned specifically against
repeating the plan's earlier framing that the abort path simply fails to recover.
That warning was right — the abort path *does* attempt clean recovery, and on the
read path it succeeds. The write path is a different shape.

#### What was already known, and why it was confusing

`scsi.v` sets CHECK CONDITION and moves to `PHASE_STATUS_OUT` on abort, and the
sense latch records key 0xB carrying the stalling opcode. `seam9` proves this
works for a stalled read. Yet the hardware capture from 2026-08-22 showed the
driver polling forever after an io-stall on a **disk write**.

#### The mechanism

A block WRITE's *last* flush is not issued during the data phase. `req_wr` has a
tail clause that fires at `PHASE_STATUS_OUT`, so the final partial sector is
flushed after the data phase has already ended:

```verilog
wire req_wr = ((((phase == PHASE_DATA_IN) && (data_cnt[8:0] == 0) && (data_cnt != 0))
                || (phase == PHASE_STATUS_OUT)) && cmd_write && (data_len != 32'd0));
```

So when the HPS stalls on that flush, the target is stalled **while already in
STATUS_OUT, with its status byte still undelivered**. And the abort branch keys
on the phase:

```verilog
end else if (wdog_abort) begin
    if ((phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT))
        phase <= PHASE_IDLE;                 // "status already sent" -- FALSE HERE
    else begin
        status <= `STATUS_CHECK_CONDITION;
        phase  <= PHASE_STATUS_OUT;
    end
end
```

That first branch exists to stop the abort looping on itself, and it is written on
the assumption that being in STATUS_OUT means the status byte got out. On a
stalled write it has not. The target drops BSY with **no status and no COMMAND
COMPLETE message**, and the initiator waits for a completion that can never
arrive. That is the "polled forever".

Traced in the seam bench, with the disk slot's HPS answering nothing:

```
phase 1 -> 3  (CMD -> DATA_IN)
phase 3 -> 4  (DATA_IN -> STATUS_OUT, data_cnt=512, wr_pending=1)
              io_wr=1, io_busy holds, REQ suppressed
phase 4 -> 0  (STATUS_OUT -> IDLE) -- status byte never sent
```

This also explains why the read path was never affected: a stalled read is stalled
in `PHASE_DATA_OUT`, takes the `else` branch, and does send its CHECK CONDITION.

#### The fix is two parts, and one part alone does not work

**C1 — do not confuse "in STATUS_OUT" with "status delivered".** Track what was
actually sent:

```verilog
reg status_done;   // the status byte for this command has been delivered
always @(posedge clk) begin
    if (phase == PHASE_IDLE) status_done <= 1'b0;
    else if ((phase == PHASE_STATUS_OUT) && stb_adv) status_done <= 1'b1;
end
```

`status_done` is used rather than the existing `status_sent` because
`status_sent` is cleared the moment the phase leaves STATUS_OUT — so in
MESSAGE_OUT it reads 0, and keying the abort on it would send the target *back*
to STATUS_OUT to re-issue a status it had already delivered.

**C2 — an aborted command must not arm a new HPS transaction.** C1 on its own is
not enough, and this is the part that is easy to miss: the abort clears `io_wr`,
but `req_wr`'s tail clause is still true (we are still in STATUS_OUT, still a
write, still non-zero length), so the flush re-arms on the very next cycle,
`io_busy` re-asserts, and REQ is suppressed again — the status still cannot get
out, and 516 ms later the second abort finds `cmd_aborted` set and gives up. The
net effect would be identical to today's bug, just slower.

```verilog
reg cmd_aborted;
always @(posedge clk) begin
    if (any_rst || (phase == PHASE_IDLE)) cmd_aborted <= 1'b0;
    else if (wdog_abort)                  cmd_aborted <= 1'b1;
end
```

gating both request generators:

```verilog
wire req_rd = ... && !cmd_aborted;
wire req_wr = ... && !cmd_aborted;
```

The pending write data is discarded, which is the correct outcome for a command
that is being failed — the driver gets CHECK CONDITION and retries. Discarding a
sector we could not write is not data loss; silently wedging the bus is.

The abort branch then becomes:

```verilog
end else if (wdog_abort) begin
    if (status_done || cmd_aborted) phase <= PHASE_IDLE;
    else begin
        status <= `STATUS_CHECK_CONDITION;
        phase  <= PHASE_STATUS_OUT;
    end
end
```

`cmd_aborted` in that condition is the loop guard: it is registered, so it is
still 0 during the *first* abort (which therefore gets to send its status) and 1
on any subsequent one (which releases the bus). One attempt to report the error,
then let go — a target must never be able to hold BSY indefinitely, which is the
whole reason the watchdogs exist.

**C3 — clear the stalled request on any abort, not just an io-stall.** The
existing clear is keyed on `iostall_abort`; widening it to `wdog_abort` costs
nothing and closes the case where `wr_pending` is set but `io_busy` happens to be
low (`data_cnt[9] != sd_buff_sel`), so the *bus* watchdog fires instead.

**Test (`tb_ncr5380_seam.v` seam14).** A 1-block WRITE to the disk target with
`hps_disk_enable` low, so the tail flush can never complete. Requires: the target
still REQs after the stall aborts, the status byte is CHECK CONDITION, COMMAND
COMPLETE follows, the bus is released, the stalled `io_wr` is cleared, and the
next command still works. Three of those fail today.

The test deliberately goes through the 5380 rather than driving `scsi.v` directly
— what is under test is *what the initiator sees*, which is exactly the seam that
[[test the seams]] says is where a defect like this survives.

`seam14` also has to wait for a free bus before selecting: `seam10` leaves the CD
target mid-CDB holding BSY, and `bus_busy` blocks selection of any other target.

#### What this does NOT fix

The stall itself. Whatever made an HPS write take longer than 516 ms on 2026-08-22
is still unexplained, and the 2026-08-23 soak did not reproduce it (see the soak
notes: a clean run there proves very little, because nothing had been fixed and
the flash restore had reset exactly the SD garbage-collection state the leading
hypothesis names). This fix changes an unrecoverable bus wedge into a failed
command that the driver can retry. That is worth having on its own, and it is not
a diagnosis.

The `IOWDOG_LOG` 24 → 26 (~2 s) change floated in the handoff is **not** included.
It is mitigation for a mechanism we have not identified, it makes the failure
slower rather than rarer, and with C in place a stall now produces a clean error
instead of a hang — which removes most of the reason to want a longer timeout.
Revisit it only if a stall is ever seen to complete between 0.5 s and 2 s.

---

### Defect D — a REJECTED write flushes a stale sector (found by `test18`)

Not on the original list. `test18` was written to check that an out-of-range
WRITE is refused *before any flush is issued*, and it kept failing after the
bounds check was in: the command was correctly refused, and a flush went out
anyway.

`req_wr`'s tail clause fires whenever the target is in `PHASE_STATUS_OUT` with
`cmd_write` and a non-zero `data_len`. A **rejected** write reaches STATUS_OUT
with both still set and no data phase behind them, so the tail flush writes
whatever the sector buffer happens to hold — the previous command's data — to
the LBA it had just declined to write.

The existing `data_len != 0` guard covers only the zero-length case. `data_cnt`
cannot be used as the discriminator either, which is what the first attempt at
this tried: `data_cnt` keeps counting through STATUS_OUT and MESSAGE_OUT, so it
is non-zero again the moment the status byte has gone out — which is precisely
when the stale flush fires. The trace is unambiguous:

```
[t18] io_wr! lba=40960 phase=5 data_cnt=1
```

An explicit latch is needed: did a data-in phase actually happen?

```verilog
reg data_in_seen;
always @(posedge clk) begin
	if((phase == PHASE_IDLE) || (phase == PHASE_CMD_IN)) data_in_seen <= 0;
	else if(phase == PHASE_DATA_IN) data_in_seen <= 1;
end
```

**This is live in the committed code today, on the CD path.** `cmd_ok_cd`
deliberately omits `cmd_write` so the read-only medium rejects writes — and that
rejection is exactly the path that flushes a stale block into the mounted disc
image. It has presumably never been hit because MacOS does not write to a CD
volume, but a WRITE(6) sent to the CD target corrupts the image file. It is only
reachable via the disk path now because the bounds check created the first
rejected-write case there.

Requiring `data_in_seen` on the STATUS_OUT clause covers every rejection path at
once, present and future.

---

### Order of work

1. **DONE** — failing tests first: `test13`–`test18` (disk), `seam14` (seam),
   `cd36`/`cd37` (CD). 5 of 6 disk assertions, 3 of 7 seam assertions and `cd36`
   failed against the pre-fix RTL; `test17` and `cd37` passed both before and
   after, which is what makes them guards rather than decoration. Every
   pre-existing test stayed green throughout.
2. **DONE** — Fix C (`status_done`, `cmd_aborted`, widened abort clear).
   seam 63/63, and `seam9` (the stalled *read*) still green.
3. **DONE** — Fix A (capacity) and Fix B (bounds check + `data_in_seen`).
4. **DONE** — all five gates green: `disk 18/18, CD 34/34, seam 63/63,
   probes 31/31, reader 20/20`.
5. **DONE** — Quartus `--analysis_and_elaboration`: **0 errors, 20 warnings**,
   the standing baseline exactly. No new warnings from `scsi.v`.
6. **NOT DONE — full compile and hardware.** Ask before the compile.

### Gates

Baseline before this work, all green: `disk 12/12, CD 32/32, seam 56/56,
probes 31/31, reader 20/20`. After it: `disk 18/18, CD 34/34, seam 63/63,
probes 37/37, reader 26/26` (the last two grew with the write-side probes below).

**UNBUILT — needs a full compile and a hardware test.** Nothing here is done
until hardware confirms it. The regression to watch for is a previously-working
SCSI disk failing to mount or boot, which would point at Defect A.


### The probe deck grows a write side (PIO3 / PIO4)

Built in the SAME bitstream as the fixes above, deliberately. The 2026-08-23
soak notes listed this as a still-open instrumentation gap "now shown to matter
twice": `PIO2` carried `d0_rd_cnt` only, `PIOS` carried `cd_io_lba` only, so the
deck had **no disk write counter and no disk LBA anywhere**. Defects C and D are
both disk-*write* defects. Shipping the fixes on a deck that cannot observe the
thing they fix would mean a second full compile the first time a wedge recurred.

| probe | packing |
|---|---|
| `PIO3` | `{wr_stuck[7:0], d0_io_lba[23:0]}` — the write-side twin of `PIOS` |
| `PIO4` | `{d0_wr_cnt, d0_ack_cnt, d1_wr_cnt, 5'd0, d0_io_wr, d0_io_ack, d1_io_wr}` |

`d0_ack_cnt` counts `d0_io_ack` edges, which that slot shares between reads and
flushes — so it is the COMBINED ack count and must be compared against
`PIO2 disk0 rd + PIO4 disk0 wr`, not against either alone. `scripts/read_probes.tcl`
prints that caveat inline, because it is exactly the kind of thing that gets
misread at 1 a.m. looking at a dead machine. `d1_wr_cnt` closes the "no disk1
counter at all" half of the same gap.

**A no-reset bug in the existing deck, found by testing the new probes.**
`cd_rd_cnt`, `cd_ack_cnt` and `d0_rd_cnt` only ever increment and had no
power-up value, so in simulation they are **X forever** and every count the deck
reports is X. Nothing caught it because no bench had ever asserted on `PIO2`.
Same shape as the Phase 0 `io_rd`/`io_wr` finding. All six counters are now
initialised to 0, which is what Altera fabric does anyway — so this changes
nothing on hardware and makes the deck's own numbers trustworthy in sim.

**Reader behaviour on an older bitstream.** `read_probes.tcl` marks a missing
probe ABSENT and raises the INCOMPLETE CAPTURE banner, which now covers
`PIO3`/`PIO4` automatically. That matters more than it sounds: a fictional
`PIO3` block would print `disk write stuck=0 lba=0`, which reads exactly like a
*healthy* write path and would exonerate the very thing under suspicion.
`sim/test_read_probes.tcl` pins that.

**Elaboration with the deck on: 0 errors, 23 warnings.** The three above the
release baseline of 20 are the deck's own and were confirmed by diffing the
warning sets with the macro on and off — a pre-existing `dbg_armed` note at
`dbg_probes.sv:78`, `Net is missing source` from the megafunctions' unconnected
`.source()` ports, and the connectivity-warning count rising 17 -> 35 for the
same reason. **None come from the new probes.**

Gates with the deck extended: `disk 18/18, CD 34/34, seam 63/63, probes 37/37,
reader 26/26`.

**This is a DEBUG build**: `USE_SCSI_ISSP=1` is uncommented in `MacPlus.qsf`.
Comment it out again for a release build; the deck and all its taps are then
pruned entirely.

### Risk

* **A changes what every existing driver sees.** Argued above to be safe because
  the extra block was never writable. Still the single most likely thing to
  surface on hardware, and the first thing to suspect if a previously-working
  disk misbehaves after this build. It is a two-character revert.
* **B rejects commands that previously hung.** Any driver that was relying on the
  hang (none plausibly can be) sees a new error path. `test17` guards the real
  risk, which is rejecting one block too many.
* **C discards a pending write sector on abort.** Only on a path that previously
  wedged the machine outright.
* **D changes when a write flush is issued at all.** The new `data_in_seen`
  condition is strictly narrower than what was there, and `test10`/`test11`
  (single- and multi-sector writes, checked byte-exact against the block device)
  are the guard that it did not become too narrow.
* All four are `scsi.v`-local; the CD personality shares the bounds check and
  the abort path, so the CD gate is a real regression check, not a formality --
  `cd36` fails against the pre-fix RTL, which is how we know it is one.

### Defect B CONFIRMED ON HARDWARE — 2026-08-24

The last of the four defects to rest on simulation alone is now closed. Build
`ea4167b2` (read back from `PBLD`, not inferred), blank 20 MiB disk on SCSI ID 6
(`d0`, the only slot with an LBA probe), boot volume on ID 5, initialised with
Apple HD SC Setup 7.3.5. **HD SC Setup's Test Disk was run three times and
passed every time**, with `scripts/watch_lba.tcl` tracing `PIO3` throughout.

20 MiB = 20,971,520 B = **40,960 blocks, last LBA 40,959**. Confirming the
arithmetic at `scsi.v:1076`: a 1-block read at 40,959 gives `cdb_end` = 40,960,
and `40,960 > capacity+1 = 40,960` is false, so it is ALLOWED; at 40,960 the end
is 40,961 and it is REFUSED. The boundary is exactly right.

#### Correction: Test Disk is not a surface scan

The plan called Test Disk "the one ordinary operation that addresses the final
LBA". The conclusion was right; the description was wrong, and the wrong
description nearly caused the result to be discarded. Test Disk completes in
**under a second** on 20 MiB — three orders of magnitude too fast to read the
medium — and that speed was twice read as "it cannot have covered anything".
It does two things, identically on all three runs:

1. **A capacity boundary probe:** `0 -> 768 -> 0 -> 33024 -> 65536 -> 40959 ->
   40960 -> 40959 -> 40960`. It walks out past the end (65,536 on a
   40,960-block device), then alternates the **last valid block against the
   first invalid one**. This is the defect B boundary, hit deliberately by a
   real Apple driver.
2. **A strided spot check:** 80 reads at `0, 512, 1024, … 40448`. It stops at
   40,448 because the next stride would land on 40,960, past the end.

So the medium's end is reached by the capacity probe, not by the scan. **Filling
the volume still does not reach it** — that part of the plan stands, and the
`Apple_Free` tail reasoning behind it is unchanged.

#### What is proven, and what is inferred

**Proven.** The driver requests LBA 40,959 and Test Disk passes. B does not
falsely reject the last good block — the dangerous direction, and the only one
a healthy driver can exercise. The alternating 40,959/40,960 pattern is itself
evidence the two are being told apart: a driver getting the same answer to both
has no reason to repeat the pair.

**Inferred, not proven.** That the out-of-range requests were refused *by the
bounds check*. `PIO3` is `assign io_lba = lba` (`scsi.v:693`) — the latched CDB
address, not a gated request — while the data phase is entered only
`if(cmd_ok && … && !lba_out_of_range)` (`scsi.v:1293`). **The probe therefore
shows what the driver ASKED for, never what was serviced**, and seeing 40,960
is not evidence a transfer happened. The support is indirect: six out-of-range
requests across three runs, no wedge, `wr_stuck` 0 throughout. Per `scsi.v:363`,
before the bounds check such an access "went to an HPS that could not service it
and stalled the bus" — so the prediction is that **this same Test Disk run would
have hung the pre-fix core.** Untested, and it is the cheapest remaining way to
turn this inference into a measurement.

#### New tool: `scripts/watch_lba.tcl`

`read_probes.tcl` decodes all 18 probes per sample and is far too slow to chase
a moving LBA. The new script reads `PIO3` alone at **~2,660 samples/s** and
records every CHANGE with the sample count it was held for. That trace is what
made the two phases legible; a high-water mark alone would have reported
`max=65536` and shown neither the boundary alternation nor the stride.

Two lessons already paid for:
* **Record the trace, not the maximum.** A max cannot distinguish "swept the
  medium" from "touched four blocks, one of them high".
* **Line-buffer any long capture.** The first 10-minute run was killed for a
  faster iteration and lost everything: Tcl had flushed nothing, and both the
  log and the task output were zero bytes.

### The pre-fix A/B: Test Disk FAILS on the old core (2026-08-24)

The experiment logged above as "the cheapest remaining way to turn this
inference into a measurement" was run the same day, and it landed better than
the prediction. The prediction was a HANG. What actually happens is a clean,
reported failure.

| build | Test Disk on the same blank 20 MiB disk |
|---|---|
| `MacPlus_432955e3_clean.rbf` (pre-fix) | **FAILS** -- "Problems writing data to disk" |
| `MacPlus_ea4167b2_scsifix.rbf` (fixed)  | **PASSES**, three runs out of three |

**This is a true single-variable A/B.** Everything that changed between
`432955e` and `7dbc965` (the direct parent of the fix commit) is documentation
and scripts -- `git diff --stat 432955e 7dbc965` touches only
`SCSI_UPGRADE_PLAN.md`, `scripts/archive_build.ps1` and
`scripts/read_probes.tcl`. Zero RTL. So the four fixes are the only difference
in logic between the two bitstreams.

**Why it fails, confirmed in the pre-fix RTL itself.** At `432955e`,
`capacity <= img_blocks` on the disk path -- reporting 40,960 as the LAST LBA of
an image whose blocks are 0..40,959 -- and `lba_out_of_range` does not appear in
that file at all. The driver was told block 40,960 exists, Test Disk wrote to
it, and the write went to a block that is not there.

**This is defect A's consequence observed directly, for the first time.** Until
now A rested on partition-map arithmetic: an inference about what *would* have
gone wrong, reasoned from the on-disk layout of an 80MB init. Now there is the
failure itself, and the fix clearing it.

#### Test Disk WRITES

The error message says so, and it corrects an assumption made twice in this
document -- that Test Disk is a read-only verify. It is not. That upgrades the
three passing post-fix runs: they exercised the **write** path at the boundary,
not merely reads, which gives defects C and D better boundary coverage than
they were credited with.

It also means Test Disk is not safe to run casually on a volume holding data.
Both runs here were on a blank disk, which is the only reason this was free.

#### CORRECTION: the "stalled the bus" mechanism is wrong

`scsi.v` carried, inside the defect A safety argument, the claim that with no
bounds check "an access to it went to an HPS that could not service it and
stalled the bus". That claim is **not what happens**, and it was load-bearing:
it was the stated reason the extra block was never usable, and therefore the
reason it was judged safe to change what every existing driver sees.

Measured: the pre-fix core reports the write error to the driver and **the Mac
carries on working normally**. No stall, no wedge, no reset needed. The
*conclusion* survives untouched -- the block is genuinely not usable, writes to
it fail -- but the mechanism was invented rather than observed. The comment at
`scsi.v:360` has been corrected in place.

**Not overclaimed:** only the WRITE path past the end was characterised here.
Reads past the end were not, and the 2026-08-22 wedge was a different path
entirely (the CD/DMA seam). This says the stall claim is unsupported for this
case, not that no stall can ever occur.

#### What is now measured rather than argued

* **Defect A** -- pre-fix Test Disk fails, post-fix it passes. Direct.
* **Defect B**, accept direction -- LBA 40,959 addressed and not refused, three
  runs. Direct.
* **Defect B**, reject direction -- still inferred. The pre-fix run does not
  isolate it, because pre-fix BOTH A and B are absent: the failure is fully
  explained by A's off-by-one without needing the missing bounds check. The
  probe cannot separate them either, since `PIO3` shows what was asked for and
  not what was serviced.
* **Defect C** -- unchanged, still fixed-by-argument.

### Scope note: everything here was validated in PLUS mode only

Confirmed with the user 2026-08-24. Every hardware result in this document --
the Phase 1/2 bring-up, the CD work, the soaks, and all four defect
confirmations -- was obtained with the OSD `Model` option set to **Plus**
(`status[9]` = 0, the default).

**The core's SCSI path is model-independent**, so this is a gap in coverage, not
a suspicion. Verified: `machineType`/`status_mod` appear **nowhere** in
`scsi.v`, `ncr5380.sv` or `dbg_probes.sv`; `status_mod` is used in only three
places in `MacPlus.sv` (`configROMSize`, `machineType`, the ROM address bit),
none of which touch the SCSI wiring; and `selectSCSI` at `$58 0000` decodes
identically in both models (`addrDecoder.v:123-127`), unlike the IWM and the
`$40 0000` region. The whole simulation ladder is unaffected by definition --
those benches drive the modules directly, with no top level and no ROM.

**What is not covered is the initiator.** The SE runs a different ROM with a
different, later SCSI Manager. Our conformance work has been exercised by the
Plus ROM and the drivers on the test volumes, and by nothing else.

#### Which configurations actually matter (user, 2026-08-24)

**Only two are real machines: Plus / 68000 / 8 MHz, and SE / 68000 / 8 MHz.**
Every other combination -- 68010, 68020, 16 MHz -- is, in the user's words, a
"fantasy computer": no such Macintosh existed. They are explicitly **lower
priority, and a limitation there is acceptable.** This follows the same rule the
rest of this project uses: classify by what real hardware did before scoping
work against it.

That settles the coverage question raised below rather than leaving it open.
`Plus / 68000 / 8 MHz` is the configuration everything so far was validated in;
`SE / 68000 / 8 MHz` is the one remaining configuration that deserves the same
standard. The others do not.

**SE mode boots (user, 2026-08-24).** A smoke observation only -- "it boots, but
that's it" -- NOT a test. It does establish that the SE ROM path, ADB keyboard
and the different overlay/decode arrangement are not obviously broken, which is
more than was known an hour earlier. What it does NOT establish is anything
about the SE's SCSI Manager as an initiator, which is the part worth having.

**One data point on the turbo path:** the floppy write work does function at
16 MHz (user, 2026-08-24). That is not SCSI, and the turbo DTACK special case at
`MacPlus.sv:410-415` is specifically about I/O accesses, so it does not transfer
-- but it does mean 16 MHz is not simply broken.

**Worth doing as an opportunity rather than a chore.** A second independent
initiator is exactly what conformance work wants and we do not otherwise have.
The SE's SCSI Manager may issue commands the Plus ROM never does, prefer 10-byte
CDBs where the Plus uses 6-byte, or request MODE SENSE pages we stub. Any of
those is a real finding for one OSD toggle and a reset. Note `status_mod` is
latched inside the reset counter (`MacPlus.sv:125`), so the switch only takes
effect on a reset, and the SE ROM (`boot1.rom`) must be present.

**One place to look first if SE mode ever misbehaves with the target.**
`addrDecoder.v:119`:

```
if(configROMSize[1] || address[17] == 1'b0)   // <- this detects SCSI (on Plus)!!!
```

In `$40 0000-$4F FFFF` the Plus returns ROM only when A17 is low; the SE returns
ROM across the whole range. The source's own comment ties that to SCSI
detection. **The mechanism it refers to is not understood** -- recorded as an
open question rather than explained, because guessing at it would be worse than
admitting it. It is the only model difference found anywhere near SCSI.

---

## RELEASE BLOCKER: SCSI has no back-pressure to the CPU bus

**Raised and deferred 2026-08-24. This must be resolved BEFORE any release.**
Not before the next hardware test, not before a merge -- before users get it.
"We can't release a core that will corrupt people's disks" (user).

### The mechanism, verified not assumed

`_cpuDTACK` (`MacPlus.sv:415`) is a pure function of `cpuAddr`, `_cpuAS` and
`turbo_dtack_en`. **Nothing from `scsi.v` or `ncr5380.sv` feeds it** -- there is
no `dtack` anywhere in either file. So unlike real hardware, where the SCSI
pseudo-DMA path asserts `/DTACK` only when a byte is actually ready, this core
gives the target **no way to stall the CPU**.

On a DACK read the CPU takes `cur_data` -- whatever the target is currently
offering (`ncr5380.sv:159`) -- and nothing stops it reading again immediately.
All pacing of the pDMA byte stream therefore comes from the driver polling DRQ,
or from timing that happens to work out.

**The failure mode this creates is silent corruption, not a hang.** A wedge is
safe for user data; a dropped or duplicated byte inside a sector write is not.
That is the whole reason this is a blocker rather than a curiosity.

### Why it is not already a demonstrated bug

At 8 MHz / 68000 it is empirically fine, and that is well evidenced: the soaks,
the byte-exact volume integrity checks, `HD20.vhd`'s 8,806 alloc blocks
agreeing exactly with its MDB after heavy writing. So either the driver polls
DRQ per byte and is genuinely self-pacing, or the timing works out. **We do not
know which**, and that is the gap.

At 16 MHz the CPU issues DACK cycles twice as fast into a path with no
interlock. Untested. The 08-22 evidence cuts both ways: the driver waited
forever when `io_busy` held REQ low, which implies real DRQ polling and
therefore speed-independence -- but those same notes record the Plus driver
using tight DACK loops, and a burst inside a sector is exactly where an
interlock would be needed and is absent.

### Three ways to resolve it, in rough order of appeal

1. **Add the missing interlock.** Let the target hold DTACK during a DACK
   access until the byte is genuinely ready. This is what real hardware does,
   so it is period-accurate as well as safe, and it would remove the entire
   class of risk at any clock. It touches the CPU bus path, so it is the most
   invasive and needs the seam bench first.
2. **Validate and document.** Run the bitmap-vs-MDB cross-check after a 16 MHz
   write soak (see the technique and its unmounted-capture precondition
   elsewhere in this document). If it comes back clean over a real payload,
   the risk is bounded empirically -- the same standard 8 MHz is held to.
3. **Refuse the combination.** If it cannot be made safe, block or warn on SCSI
   writes at 16 MHz rather than shipping a selectable option that eats
   volumes. Authenticity already says 16 MHz is a fantasy machine and low
   priority; that argues against spending effort making it *work*, not for
   letting it destroy data quietly.

**Note that 1 and 3 are not in tension with the authenticity scoping.** The
scoping decision is about where to spend effort, not about whether a shipped
option may lose data.

### Testing it is cheap and safe if set up right

Copy the images first -- the .vhd files on the PC may be the only copies, since
the live ones are on the SD card. Then: boot a throwaway image at 16 MHz, write
a real payload, **shut down cleanly** so the MDB and catalog flush, capture, and
cross-check. `drAtrb` bit 8 set confirms the unmount; the bitmap popcount then
either agrees with `drNmAlBlks - drFreeBks` or it does not.

That also probes the 8 MHz question, which is the more valuable half: it tells
us whether the driver is genuinely self-pacing or whether we have been lucky.
