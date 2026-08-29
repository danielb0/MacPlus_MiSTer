# Plan: bugs to fix before release

Written 2026-08-28. Branch `scsi-upgrade`.

> **STATUS 2026-08-29 -- READ THIS FIRST. The body below is superseded in part.**
>
> * **#1 CD-at-boot hang: root-caused and re-fixed.** `f254ffd` (empty the drive
>   on a Mac reset) stopped the hang and is hardware-confirmed, but it is a
>   **workaround**. The real defect is ours: we served 2048-byte logical blocks
>   while a Mac CD declares `sbBlkSize = 512` and lays its partition map out in
>   512-byte units, which the ROM's Start Manager walks in the units the disc
>   declares. Branch **`cd-512-blocks`** serves 512 and drops the reset-eject.
>   Sim green, **not yet hardware-tested**. See `CD_BLOCK_SIZE_PLAN.md`, which is
>   the live document for this item.
> * **#2 CD boot repulse:** downgraded 2026-08-28 to **not release-blocking**.
>   Never observed firing.
> * **#3 bench gap: CLOSED.** `cd38` covers the short/aborted data phase; `cd41`
>   now covers the partition-map read that actually caused #1.
>
> Two things this document gets wrong and that are corrected in
> `CD_BLOCK_SIZE_PLAN.md`: the ROM does **not** "load the driver" (the failing ISO
> has `sbDrvrCount = 0`; it is the partition-map walk), and the "Not doing" entry
> ruling out *"clearing `mounted` on reset"* is exactly what `f254ffd` went on to
> do. It was the right call at the time and the wrong long-term model.

The rule this exists to serve (user, 2026-08-28): **before release, correct any
bug we identify.** Three items, one of which is in a different repository.

## The release gate

| # | defect | status | repo | blocking? |
|---|---|---|---|---|
| 1 | CD mounted at boot hangs the machine | **CONFIRMED on hardware, twice** | this | **YES** |
| 2 | CD boot repulse arms on MacPlus | suspected, never observed firing | Main_MiSTer | yes, if real |
| 3 | `tb_scsi_cdrom` never tests a short/aborted data phase | certain (read the bench) | this | yes -- it is what let #1 ship |

`bus_hold` / the back-pressure work is **not** implicated and must not be
touched: `PHLD holds=0 breaches=0` with the HPS acking every fetch in both
wedged captures.

---

## 1. CD-at-boot wedge (BLOCKING)

### What is proven

Frozen `?` diskette, no SCSI volume mounts. Probe evidence, reproduced on two
independent boots with three predictions stated in advance and all three held
(`PODR` zero length field, `PIOS lba=1024`, phase list missing MESSAGE):

* ROM scans SCSI 6,5,4,3. ID 6 reads fine and has no bootable System, so it
  moves on. It reaches ID 3 (CD) and the transaction dies mid-DATA-IN.
* Enumeration never completes, so **a boot volume is never selected** -- which
  is why the healthy, bootable `HD20.vhd` at ID 5 never boots.
* `READ(6)` with length 0 = **256 blocks**. Target serves 256 x 2048 = 512 KB
  = 1024 HPS sectors; `cd_io_lba` stops at exactly 1024. Initiator stops
  ACKing partway.
* The bus watchdog fires (`bus=2`) and **releases BSY without terminating the
  transaction**. Wedged phases: `IDLE CMD DATA>init(READ) STATUS`. A healthy
  transaction on the same build reaches `... STATUS MESSAGE` and returns to
  IDLE.
* CPU then spins forever: `740A: BTST D3,$50(A3)` / `740E: BEQ.S -6`, with
  `$50` = the 5380 BSR, reading a constant `0x90`.

### Provenance -- this is OUR bug, not an inherited one

`git show master:rtl/scsi.v` has **zero** matches for both `wdog|watchdog` and
`CDROM`. Upstream has neither a watchdog nor a CD target. The watchdog arrived
on this branch at `cfb2c8d` ("no CDB can hold BSY forever and freeze the
machine"). It fixed a real hang and introduced a second one: it traded
"BSY held forever" for "BSY released, initiator polls forever".

### The intended fix

On watchdog fire, **terminate the transaction properly** instead of silently
releasing BSY: drive STATUS = `CHECK CONDITION`, then MESSAGE IN = COMMAND
COMPLETE, then bus-free. Sense `SK=0xB` (ABORTED COMMAND) / `ASC=0x4B` (DATA
PHASE ERROR), which is what actually happened. The ROM then gets an error,
moves to the next SCSI ID, completes enumeration, and boots from `HD20.vhd`.

Preferred over clearing `mounted` on reset, which does not help the real case
(on a COLD boot with a disc in the drive the disc IS legitimately mounted) and
leaves a target that can still strand an initiator.

### THE RISK, stated up front

**The fix may not be sufficient, and we must not assume it is.** The watchdog
exists precisely because the initiator has stopped handshaking. STATUS and
MESSAGE are themselves REQ/ACK phases -- if the ROM is not servicing
handshakes, driving them may simply stall in the same way.

What we know: the ROM loops on `BTST D3,$50(A3)` with `BSR=0x90` (End-of-DMA
and IRQ already SET; DRQ and Phase Match CLEAR). It is waiting on a bit that is
currently 0. We do **not** know which bit. If it is Phase Match, note the ROM's
`TCR=1` (DATA IN) while STATUS is `TCR=3` -- a phase change alone would leave
PMATCH still 0 and would NOT release it.

**Therefore step 1 is a diagnostic as much as a test.** The bench must tell us
what actually releases a stranded initiator before we commit to the RTL change.
If proper termination does not release it, fall back to:

* (b) keep BSY asserted and hold the target in STATUS rather than going
  bus-free, so the initiator sees a live target rather than an empty bus; or
* (c) prevent the strand at the source -- refuse or bound a CDB whose transfer
  size cannot be reconciled, returning CHECK CONDITION *before* entering DATA.

(c) is the most robust and the least period-accurate; prefer (a), then (b).

---

## FINDING 2026-08-28: fix (a) is DEAD. The target is not at fault.

`cd38` (added to `sim/tb_scsi_cdrom.v`) reproduces the hardware signature
exactly -- same two watchdog fires, STATUS reached, MESSAGE never:

```
cd38: took 1024 bytes, then stopped ACKing
cd38: saw_status=1 saw_msg=0 bsy_dropped=1 wdog_fires=2
cd38: reusable afterwards=1 (status 00)
```

**But the target RECOVERS.** It aborts, tries STATUS, gives up, releases BSY,
and the very next command succeeds with GOOD status. So:

* **Fix (a) is dead.** The target ALREADY reaches STATUS. It cannot deliver
  STATUS or MESSAGE to an initiator that has stopped ACKing -- those are
  handshake phases. "Terminate the transaction properly" was the wrong model.
* **Fix (b) is dead** for the same reason.
* The wedge is entirely on the **INITIATOR** side -- and the initiator's 5380
  is also our RTL (`rtl/ncr5380.sv`).

### The real root cause: BUSY ERROR is hardwired to zero

`rtl/ncr5380.sv:315`:

```verilog
wire bsr_berr = 1'b0;	/* XXX ? Does MacOS use this ? */
```

BSR bit 2 is **BUSY ERROR**. On a real NCR 5380 it latches when BSY is lost
unexpectedly while DMA mode is armed -- it is precisely the driver's "your
target vanished, stop waiting" exit. Ours can never set it.

That closes the loop on the observed `BSR = 0x90`
(`eodma=1 drq=0 perr=0 irq=1 pmatch=0 **berr=0** atn=0 ack=0`): the target
correctly drops BSY, and the ROM is left polling a register in which **no bit
can ever change**. The freeze is not the target giving up; it is the initiator
having no way to learn that it did.

### Revised fix

Latch `bsr_berr` when BSY is lost with DMA mode armed, cleared the same way the
other latched BSR state is.

**Do it ALONE.** `ncr5380.sv:296-305` records that two earlier attempts each
changed this gate AND the completion-IRQ latch together, and **both hung the
machine earlier than the bug**. The file's own conclusion is "gate alone, latch
untouched, one variable". Honour that: change `bsr_berr` and nothing else.

### Residual uncertainty, to settle on hardware

We do NOT know which bit the ROM's `BTST D3,$50(A3)` tests -- D3 is a register
and the probe deck does not expose it. Of the bits reading 0, the candidates
are DRQ (6), PMATCH (3) and BERR (2). If it is BERR this fix ends the hang
outright. If it is DRQ or PMATCH it may not, and the fallback becomes (c):
refuse a CDB whose transfer size cannot be reconciled BEFORE entering DATA.
Implementing BERR is correct regardless -- a 5380 that cannot report a lost
target is wrong on its own terms -- so it is worth doing first either way.

### Where the initiator-side test goes

`tb_scsi_cdrom.v` drives the target directly and has no 5380 in it, so it
cannot test this. **`sim/tb_ncr5380_seam.v` has both** and is where the BERR
test belongs.

---

## 2. CD boot repulse arms on MacPlus (Main_MiSTer)

`mac_cdrom_poll()` re-inserts the disc ~60 s after attach unless the guest read
it more than 8 times. Its stated premise -- "the Apple CD driver misses the
single early attach pulse" -- is **false on a Plus**, which has neither the
Apple CD driver nor CD boot. A silent remount under a running guest is a
plausible way to strand a transaction.

* **Scope, verified by reading the code:** arms only for `MAC_CDROM_HANDLED`
  (CUE / CHD / raw-2352). A flat `.iso` is `MAC_CDROM_PASSTHRU`, leaves
  `cd.active=0`, and never arms. So it is **not** the cause of #1, which was
  observed with an ISO.
* **Why it can hide:** the skip test is `rp_data_reads > 8`. Heavy CD work
  (the 08-27 copy and audio tests) blows past 8 and skips the repulse. A disc
  mounted but barely read leaves it armed and it FIRES.
* **UNVERIFIED** -- never observed firing. It prints
  `"Mac CD: boot repulse - re-inserting %s"`, so one run with Main's stdout
  captured settles it.

**Fix:** do not arm the repulse for cores that cannot boot from CD. This is in
**merged** code (PR #1295, `9b193ea`), so it needs a **follow-up PR**, not an
edit to #1295.

**Do this one second**, and only after confirming it fires. Fixing an
unconfirmed defect in someone else's merged code is worse than leaving it.

---

## 3. Bench gap that let #1 ship

`sim/tb_scsi_cdrom.v` exercises only a well-behaved initiator that knows blocks
are 2048 bytes and always drains the full data phase (`read_data_phase(2048)`):
cd5 READ CAPACITY, cd6 READ(6) = 4 HPS sectors byte-exact, cd7 READ(10).
**Nothing tests an initiator that stops ACKing early.**

---

## Order of work

1. **RED test** in `sim/tb_scsi_cdrom.v`: `READ(6)` length 0, consume only what
   a 512-byte-block initiator would, then stop ACKing. Assert the target does
   not strand the bus. **Expected to FAIL, reproducing the hardware wedge in
   sim.** Also instrument it to answer the risk above: what, if anything,
   releases a stranded initiator.
2. **Fix** `rtl/scsi.v` per (a), falling back to (b)/(c) on what step 1 shows.
3. **Green** the new test; re-run the full ladder.
4. **Ask before compiling** (standing rule), then hardware smoke test.
5. Only then: confirm #2 fires, and if so raise the Main follow-up PR.

## Verification

Sim ladder gates, unchanged: `tb_ncr5380_seam` **81/81**, `tb_scsi_target`,
`tb_scsi_cdrom` (+ the new case), `tb_cd_mix` **18/18**. Simulator is
**iverilog**, not verilator.

Hardware smoke test, in this order:

1. **Boot with a CD mounted** -- the actual regression. Must reach the desktop.
2. Boot with no CD; mount a CD after reaching the desktop; read it.
3. CD audio still plays; Lode Runner unregressed (the 3C/3D baseline).
4. A CD -> disk copy, byte-exact.
5. Floppy write still works.
6. Re-probe: `PHLD holds/breaches` unchanged, and a completed transaction must
   show `... STATUS MESSAGE` in the phase list.

## Outstanding, not a bug

Before the forum post goes up: confirm **mount-after-boot** works on this
build. Strongly implied by the 08-27 tests and by the healthy capture
(`cd rd=82 ack=82`, transactions completing), but not specifically exercised.
The post's workaround depends on it.

## Not doing

* Clearing `mounted` on reset -- see above.
* Touching `bus_hold` or anything in the back-pressure path -- exonerated.
* Shipping the fix without a hardware boot-with-CD test. That is the whole bug.
