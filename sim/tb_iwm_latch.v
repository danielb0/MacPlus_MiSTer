`timescale 1ns/1ps
//
// tb_iwm_latch.v - Phase 5 item 4: the 16 MHz "disk unreadable" root cause.
//
// The IWM's read-data latch is cleared by a countdown that ticks on `cen`
// (clk8_en_n, 125 ns) regardless of CPU speed - 13 loaded, cleared when it
// reaches 1, so ~1.5 us after a valid read. The `.Sony` driver detects a new
// disk byte ONLY by polling bit 7, and every GCR disk byte has bit 7 set, so
// a latch that has not yet self-cleared is indistinguishable from a genuine
// fresh byte. The driver's poll loops are unrolled double reads about 16 CPU
// cycles apart (measured from releases/boot1.rom @ 0x03552e):
//
//    8 MHz: 16 cycles = 2.00 us  >  1.5 us -> latch cleared, second read
//                                            correctly reports "no new byte"
//   16 MHz: 16 cycles = 1.00 us  <  1.5 us -> latch STILL SET, second read
//                                            reports a duplicate byte
//
// The first fix scaled the COUNTDOWN onto cen16 so it ticks once per CPU
// cycle at both speeds. That was necessary but not sufficient: the RELOAD
// stayed on `cen`, which is one tick per CPU cycle at 8 MHz but only one per
// TWO at 16 MHz. The hold therefore came out a cycle longer or shorter
// depending on where the access happened to land in busPhase.
//
// That is not benign jitter, because a poll that reads a stale latch RE-ARMS
// the timer. Lose the race once and every subsequent poll is early too - the
// latch is pinned high for as long as polling continues. And cpu_en_p/n come
// off the same busPhase counter, so the alignment never drifts: it is set by
// the wait-stated accesses preceding the poll loop and then stays put. Hence
// the reported hardware behaviour - fails at random between runs, but once it
// is failing it stays failing across restarts.
//
// This testbench drives the real `iwm` (with the real `floppy`/
// `floppy_track_encoder` behind it, so the bytes are genuine encoder output)
// and sweeps poll gap x bus-phase alignment at both speeds, twice over:
//   1. the ROM's unrolled double read, and
//   2. SUSTAINED polling across whole disk-byte times, which is the only way
//      to see the re-arm feedback - a two-read probe cannot show it.
//
// It does NOT gate on "never locks up": a poll gap tighter than the hold
// wedges at both speeds, which is inherent to the hold length, not a defect.
// It gates on the two properties the fix actually claims:
//   * no bus-phase alignment dependence, and
//   * 16 MHz behaving identically to the hardware-proven 8 MHz path at the
//     same gap measured in CPU cycles.
// Both gates FAIL against the pre-fix RTL (16 MHz shows `LL..` at a 14-cycle
// gap - wedged on two alignments, fine on the other two) and PASS after.
//
// Run from the repo ROOT (the sim/*.v files $readmemh relative paths):
//   iverilog -g2012 -o /tmp/t.vvp sim/tb_iwm_latch.v rtl/iwm.v rtl/floppy.v \
//       rtl/floppy_track_encoder.v rtl/floppy_track_decoder.v \
//       rtl/floppy_write_committer.v && vvp /tmp/t.vvp
//
module tb_iwm_latch;

   // clk_sys is 32 MHz on this core (busPhase, a free-running 2-bit counter,
   // divides it: clk8_en_* once per 4 counts, clk16_en_* once per 2).
   localparam CLKSYS_NS = 31.25;

   reg clk = 0;
   always #(CLKSYS_NS/2) clk = ~clk;

   // Reproduce addrController_top.v:153-156's enable generation exactly.
   reg [1:0] busPhase = 2'b00;
   always @(posedge clk) busPhase <= busPhase + 1'b1;
   wire cep      = (busPhase == 2'b11);
   wire cen      = (busPhase == 2'b01);
   wire cen16    = busPhase[0];          // clk16_en_n

   reg        _reset      = 1'b0;
   reg        selectIWM   = 1'b0;
   reg        _cpuRW      = 1'b1;
   reg        _cpuLDS     = 1'b1;
   reg [15:0] dataIn      = 16'h0000;
   reg [3:0]  cpuAddrRegHi = 4'h0;
   reg        SEL         = 1'b0;
   reg        driveSel    = 1'b1;   // select the internal drive

   wire [15:0] dataOut;
   wire [1:0]  diskEject, diskMotor, diskAct;
   wire [21:0] dskReadAddrInt, dskReadAddrExt;

   wire dskReadAckInt;

   // The `turbo` port only exists after the fix; `ifdef` keeps this one
   // testbench usable against both the pre-fix and post-fix RTL so the
   // before/after comparison is genuinely the same stimulus.
   reg turbo = 1'b0;

   iwm dut (
      .clk(clk), .cep(cep), .cen(cen),
`ifdef IWM_HAS_TURBO
      .cen16(cen16), .turbo(turbo),
`endif
      ._reset(_reset),
      .selectIWM(selectIWM),
      ._cpuRW(_cpuRW),
      ._cpuLDS(_cpuLDS),
      .dataIn(dataIn),
      .cpuAddrRegHi(cpuAddrRegHi),
      .SEL(SEL),
      .driveSel(driveSel),
      .dataOut(dataOut),
      .insertDisk(2'b01),
      .diskEject(diskEject),
      .diskSides(2'b01),
      .diskMotor(diskMotor),
      .diskAct(diskAct),
      .dskReadAddrInt(dskReadAddrInt),
      .dskReadAckInt(dskReadAckInt),
      .dskReadAddrExt(dskReadAddrExt),
      .dskReadAckExt(1'b0),
      .dskReadData(8'h00),
      .writeProtect(2'b11),
      .dskWriteAddrInt(), .dskWriteDataInt(), .dskWriteReqInt(), .dskWriteAckInt(1'b0),
      .dskWriteAddrExt(), .dskWriteDataExt(), .dskWriteReqExt(), .dskWriteAckExt(1'b0),
      .dskCommitDoneInt(), .dskCommitAddrInt(), .dskCommitBufWrInt(),
      .dskCommitBufAddrInt(), .dskCommitBufDataInt(),
      .dskCommitDoneExt(), .dskCommitAddrExt(), .dskCommitBufWrExt(),
      .dskCommitBufAddrExt(), .dskCommitBufDataExt()
   );

   // floppy.v refills `diskImageData` from the encoder on every dskReadAck.
   // NOTE the ack is consumed inside floppy.v's `if(cep)` branch, so a mock
   // that pulses it on any other phase is never seen at all - hold it high
   // and let cep do the sampling. Acking continuously keeps a byte always
   // available, which is what the real per-hsync SDRAM ack effectively does
   // at this timescale (~21 us vs the 16 us byte rate).
   assign dskReadAckInt = 1'b1;

   integer errors = 0;

   // Watchdog. The measurement below waits on `newByteReady`, which never
   // pulses at all if the disk byte pipeline fails to spin up - and Verilog
   // has no built-in timeout, so that is an infinite simulation rather than
   // a failure. A hanging test in a regression suite reports nothing; make
   // it report loudly instead. 4 ms comfortably covers the full sweep below
   // (2 speeds x 5 gaps x 4 alignments, each resynced to a fresh 16 us byte).
   initial begin
      #12_000_000;
      $display("FAIL: watchdog - simulation did not finish; the disk byte pipeline almost certainly never produced a newByteReady pulse (check the dskReadAck mock: floppy.v only samples it inside its `if(cep)` branch)");
      $display("");
      $display("IWM LATCH GATE: FAIL (watchdog)");
      $finish;
   end

   // One CPU bus access to an IWM register. `cpu_periods` is how many
   // clk_sys cycles one CPU clock lasts (4 at 8 MHz, 2 at 16 MHz); a 68000
   // holds _cpuLDS for 3 CPU clock periods on a byte read.
   task cpu_access(input [3:0] addr, input integer cpu_periods);
      integer n;
      begin
         cpuAddrRegHi = addr;
         selectIWM    = 1'b1;
         _cpuRW       = 1'b1;
         _cpuLDS      = 1'b0;
         for (n = 0; n < 3*cpu_periods; n = n + 1) @(posedge clk);
         #1;
         _cpuLDS   = 1'b1;
         selectIWM = 1'b0;
      end
   endtask

   // Set one of the IWM's 16 one-bit registers (a bare access does it).
   task iwm_set(input [3:0] addr);
      begin
         cpu_access(addr, 4);
         repeat (4) @(posedge clk); #1;
      end
   endtask

   // The measurement. Runs the ROM's unrolled double-read at the given CPU
   // speed and reports whether the SECOND read still shows bit 7 (i.e. the
   // driver would see a duplicate byte).
   //
   // `align` shifts the whole access sequence by 0-3 clk_sys cycles, which
   // sweeps its phase relative to busPhase (period 4). This matters because
   // cpu_en_p/n are derived from that SAME counter, so on hardware the
   // alignment does not drift - it is fixed by the history of wait-stated
   // memory accesses before the driver enters its poll loop, and then stays
   // put. A latch whose behaviour depends on alignment therefore fails
   // "randomly" between runs but consistently within one, which is exactly
   // the reported hardware symptom. Probing a single alignment (as this
   // testbench originally did) cannot see it.
   //
   // `gap_cycles` sweeps the poll spacing, so the report shows WHERE the
   // margin boundary is rather than just pass/fail at one assumed spacing.
   task double_read(input integer cpu_periods, input integer align,
                    input integer gap_cycles, output reg dup);
      integer n;
      reg [7:0] first;
      begin
         // Sync to a freshly latched byte so the ~16 us until the next one
         // cannot interfere with the 1-2 us window under test.
         @(negedge dut.newByteReady);
         @(posedge dut.newByteReady);
         repeat (8) @(posedge clk);
         for (n = 0; n < align; n = n + 1) @(posedge clk);
         #1;

         // read 1: address $1C00 = register 14 (q7L) - the exact address the
         // .Sony poll loop uses, which selects the data register (q7=q6=0).
         cpu_access(4'hE, cpu_periods);
         first = dataOut[7:0];

         // gap is start-to-start, of which the access already consumed 3.
         for (n = 0; n < (gap_cycles-3)*cpu_periods; n = n + 1) @(posedge clk);
         #1;

         // read 2
         cpu_access(4'hE, cpu_periods);
         dup = dataOut[7];

         if (!first[7]) begin
            $display("FAIL: setup - the FIRST read did not return a valid byte (bit 7 clear, dataOut=%02h)", first);
            errors = errors + 1;
         end
      end
   endtask

   // Sustained polling - the case that actually matters, and the one a
   // two-read probe cannot see. The driver polls continuously for the whole
   // ~16 us between disk bytes, and EVERY poll that finds bit 7 set re-arms
   // readLatchClearTimer. So a single poll that lands before the latch has
   // cleared does not cost one duplicate byte - it restarts the hold, making
   // the next poll early too, and the next. The latch stays pinned high for
   // as long as polling continues. Counts how many polls report a valid byte
   // across `bytes` disk-byte times; correct behaviour is exactly one each.
   task sustained_poll(input integer cpu_periods, input integer align,
                       input integer gap_cycles, input integer bytes,
                       output integer seen);
      integer n, polls, maxpolls;
      begin
         @(negedge dut.newByteReady);
         @(posedge dut.newByteReady);
         repeat (8) @(posedge clk);
         for (n = 0; n < align; n = n + 1) @(posedge clk);
         #1;
         seen     = 0;
         polls    = 0;
         // one disk byte = 128 clk8 = 512 clk_sys
         maxpolls = (bytes * 512) / (gap_cycles * cpu_periods);
         while (polls < maxpolls) begin
            cpu_access(4'hE, cpu_periods);
            if (dataOut[7]) seen = seen + 1;
            for (n = 0; n < (gap_cycles-3)*cpu_periods; n = n + 1) @(posedge clk);
            #1;
            polls = polls + 1;
         end
      end
   endtask

   localparam GAP_LO = 13;
   localparam GAP_HI = 18;
   localparam POLL_BYTES = 2;
   localparam SP_LO = 14;   // sustained-poll sweep range
   localparam SP_HI = 16;

   reg       dup_r;
   reg [3:0] res [0:1][GAP_LO:GAP_HI];   // [speed][gap] -> one bit per alignment
   reg [3:0] lockres [0:1][SP_LO:SP_HI];  // [speed][gap] -> one bit per alignment
   integer   sp, gp, al, cp, jitter, mismatch, seen, locked;

   initial begin
      _reset = 1'b0;
      repeat (8) @(posedge clk);
      @(negedge clk);
      _reset = 1'b1;
      #1;
      repeat (8) @(posedge clk); #1;

      // Bring the drive up the way the ROM does: select the internal drive
      // (index 10 = intDrive), ca2 on (index 5) so driveReadAddr
      // {ca2,ca1,ca0,SEL} == 8 == DRIVE_REG_RDDATA0 (the read-data head),
      // then enable the drive (index 9 = mtrOn).
      iwm_set(4'hA); // intDrive  -> selectExternalDrive = 0
      iwm_set(4'h5); // ca2H
      iwm_set(4'h9); // mtrOn     -> diskEnableInt = 1

      // let the byte pipeline spin up and produce real encoder bytes
      repeat (4000) @(posedge clk);

      if (!dut.readDataLatch[7]) begin
         $display("FAIL: setup - no valid disk byte ever reached the IWM read latch");
         errors = errors + 1;
      end

      // Sweep both speeds over poll gap x busPhase alignment.
      for (sp = 0; sp < 2; sp = sp + 1) begin
         turbo = (sp == 1);
         cp    = (sp == 1) ? 2 : 4;      // clk_sys cycles per CPU clock
         for (gp = GAP_LO; gp <= GAP_HI; gp = gp + 1)
            for (al = 0; al < 4; al = al + 1) begin
               double_read(cp, al, gp, dup_r);
               res[sp][gp][al] = dup_r;
            end
      end

      $display("");
      $display("  Latch-hold sweep. '.' = latch cleared in time (correct);");
      $display("  'D' = second read still had bit 7 set, i.e. the driver sees a DUPLICATE byte.");
      $display("  The four characters are busPhase alignments 0..3 of the CPU access.");
      $display("");
      $display("   poll gap |   8 MHz  |  16 MHz");
      $display("  ----------+----------+---------");
      for (gp = GAP_LO; gp <= GAP_HI; gp = gp + 1) begin
         $write("   %0d cyc   |   ", gp);
         for (al = 0; al < 4; al = al + 1) $write("%s", res[0][gp][al] ? "D" : ".");
         $write("   |   ");
         for (al = 0; al < 4; al = al + 1) $write("%s", res[1][gp][al] ? "D" : ".");
         $write("\n");
      end
      $display("");

      // Gate 1: behaviour must not depend on bus-phase alignment. A row that
      // is neither all-'.' nor all-'D' means the same driver code succeeds or
      // fails purely on where its access landed in busPhase - random between
      // runs, sticky within one.
      jitter = 0;
      for (sp = 0; sp < 2; sp = sp + 1)
         for (gp = GAP_LO; gp <= GAP_HI; gp = gp + 1)
            if (res[sp][gp] !== 4'b0000 && res[sp][gp] !== 4'b1111) begin
               jitter = jitter + 1;
               $display("FAIL: %s, %0d-cycle gap - result depends on bus-phase alignment (%b)",
                        (sp == 1) ? "16 MHz" : " 8 MHz", gp, res[sp][gp]);
            end

      // Gate 2: 16 MHz must be cycle-equivalent to the hardware-proven 8 MHz
      // behaviour - the same poll gap, measured in CPU cycles, must give the
      // same answer at both speeds. This is the actual property the fix claims.
      mismatch = 0;
      for (gp = GAP_LO; gp <= GAP_HI; gp = gp + 1)
         if (res[0][gp] !== res[1][gp]) begin
            mismatch = mismatch + 1;
            $display("FAIL: %0d-cycle gap - 8 MHz gives %b but 16 MHz gives %b; not cycle-equivalent",
                     gp, res[0][gp], res[1][gp]);
         end

      // Gate 3: sustained polling must report exactly one valid byte per disk
      // byte at every speed and alignment. More than that means the re-arm
      // feedback has pinned the latch high - the "stuck until reflash" mode.
      // Note a poll gap too tight for a 13-cycle hold locks up at BOTH speeds -
      // that is inherent to the hold length, not a defect. What must not happen
      // is the two speeds DISAGREEING, or one speed disagreeing with itself
      // across bus-phase alignments.
      locked = 0;
      $display("  Sustained poll: 'L' = latch pinned high (>%0d valid-byte reports",
               POLL_BYTES + 1);
      $display("  across %0d disk bytes), '.' = exactly one report per byte.", POLL_BYTES);
      $display("");
      $display("   poll gap |   8 MHz  |  16 MHz");
      $display("  ----------+----------+---------");
      for (sp = 0; sp < 2; sp = sp + 1) begin
         turbo = (sp == 1);
         cp    = (sp == 1) ? 2 : 4;
         for (gp = SP_LO; gp <= SP_HI; gp = gp + 1)
            for (al = 0; al < 4; al = al + 1) begin
               sustained_poll(cp, al, gp, POLL_BYTES, seen);
               lockres[sp][gp][al] = (seen > POLL_BYTES + 1);
            end
      end
      for (gp = SP_LO; gp <= SP_HI; gp = gp + 1) begin
         $write("   %0d cyc   |   ", gp);
         for (al = 0; al < 4; al = al + 1) $write("%s", lockres[0][gp][al] ? "L" : ".");
         $write("   |   ");
         for (al = 0; al < 4; al = al + 1) $write("%s", lockres[1][gp][al] ? "L" : ".");
         $write("\n");
      end
      $display("");
      for (gp = SP_LO; gp <= SP_HI; gp = gp + 1) begin
         if (lockres[1][gp] !== 4'b0000 && lockres[1][gp] !== 4'b1111) begin
            locked = locked + 1;
            $display("FAIL: 16 MHz, %0d-cycle gap - lock-up depends on bus-phase alignment (%b): the same driver loop works or wedges purely on where its access landed",
                     gp, lockres[1][gp]);
         end
         if (lockres[0][gp] !== lockres[1][gp]) begin
            locked = locked + 1;
            $display("FAIL: %0d-cycle gap - 8 MHz locks %b but 16 MHz locks %b; not cycle-equivalent",
                     gp, lockres[0][gp], lockres[1][gp]);
         end
      end

      errors = errors + jitter + mismatch + locked;

      $display("");
      if (errors == 0)
         $display("IWM LATCH GATE: PASS (no alignment dependence, 16 MHz cycle-equivalent to 8 MHz)");
      else
         $display("IWM LATCH GATE: FAIL (%0d)", errors);
      $finish;
   end

endmodule
