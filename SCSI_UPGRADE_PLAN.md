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
