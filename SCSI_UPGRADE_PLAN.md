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

The LC has `verilator/scsi_bench`. Port or re-create it against our `sim/` layout
(which is iverilog-based from the floppy work). Gate: a scripted initiator that can
drive selection → CMD → DATA → STATUS → MSG against the target and diff byte
streams.

Must produce, before any RTL change, a **failing** test for each of the two
conformance bugs in §1 — a REQUEST SENSE after a CHECK CONDITION, and a 12-byte CDB
— so we can prove the fix rather than assume it.

### Phase 1 — SCSI-1 conformance (no CONF_STR change, no new slots)

Port the LC disk-path work into `rtl/scsi.v`:

1. REQUEST SENSE (0x03). **Note:** the LC's disk path returns a *static all-zeros
   "NO SENSE" block* — the real per-error sense keys (`cd_sense_key`/`cd_sense_asc`,
   ILLEGAL REQUEST / NOT READY / ASC codes) are gated on `CDROM != 0`, CD target
   only. So the LC gets "the recovery handshake completes", not "the drive reports
   why it failed." **Decide during this phase** whether to port their static block
   or promote the CD sense machinery to the disk path too. The latter is more
   correct and probably cheap once the CD code is in tree; it may be better
   sequenced *after* Phase 2.
2. Group-5 (12-byte) CDB completion, so an unknown opcode CHECKs and releases the
   bus instead of wedging it.
3. `bus_busy` — don't answer selection while another target holds BSY.
4. `sys_rst` separate from bus `rst`.
5. Read prefetch ring (`RING_LOG`), replacing the two-sector double buffer. Keep
   writes on the existing two-slot buffer, as the LC does — our write path is
   freshly validated and should not be disturbed.
6. HPS byte-lane endianness handling (their `VERILATOR` vs real-HPS packing split).

Testable against existing HD images with no user-visible change. **Hardware-validate
before starting Phase 2** — this phase touches the path every existing user depends
on, and is the one most likely to regress a working setup.

### Phase 2 — CD-ROM target

Third `scsi` instance, `#(.ID(3), .CDROM(1))`. AppleCD personality, 2048-byte
logical blocks served as 4 consecutive 512-byte HPS blocks (lba/tlen <<2), READ TOC
(both standard 0x43 and Apple vendor 0xC1), sub-channel, START/STOP eject,
PREVENT/ALLOW, no-disc sense (`SK_NOT_READY` + vendor ASC 0xB0 — the LC notes 0x3A
makes MacOS "hammer the drive asking the user to format it").

New hps_io slot, `sd_buff_addr` widening, CONF_STR entries, `cd_enable` toggle.

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
