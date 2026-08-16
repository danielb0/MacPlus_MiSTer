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
// This testbench reproduces exactly that access pattern against the real
// `iwm` (and the real `floppy`/`floppy_track_encoder` behind it, so the
// bytes under test are genuine encoder output, not synthetic). It is a
// characterization test, not a pass/fail-on-current-RTL test: it reports
// what each speed does and only FAILS when the pair of results is not the
// intended one. Before the fix the 16 MHz case is expected to fail; after
// the fix both must pass, with 8 MHz behaviour bit-identical.
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
   // it report loudly instead. 400 us is ~25 disk byte times, far beyond
   // anything this test legitimately needs.
   initial begin
      #400_000;
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
   task double_read(input integer cpu_periods, output reg dup);
      integer n;
      reg [7:0] first;
      begin
         // Sync to a freshly latched byte so the ~16 us until the next one
         // cannot interfere with the 1-2 us window under test.
         @(negedge dut.newByteReady);
         @(posedge dut.newByteReady);
         repeat (8) @(posedge clk); #1;

         // read 1: address $1C00 = register 14 (q7L) - the exact address the
         // .Sony poll loop uses, which selects the data register (q7=q6=0).
         cpu_access(4'hE, cpu_periods);
         first = dataOut[7:0];

         // gap: the loop is 16 CPU cycles start-to-start, of which the
         // access itself already consumed 3.
         for (n = 0; n < (16-3)*cpu_periods; n = n + 1) @(posedge clk);
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

   reg dup8, dup16;

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

      // ---------------- 8 MHz (4 clk_sys per CPU clock) ----------------
      turbo = 1'b0;
      double_read(4, dup8);
      if (dup8)
         $display("FAIL: 8 MHz - second read %0.2fus later STILL had bit 7 set (duplicate byte); this speed is known-good on hardware, so something in the test setup is wrong",
                  16*4*CLKSYS_NS/1000.0);
      else
         $display("PASS: 8 MHz - latch self-cleared within the %0.2fus poll gap, second read correctly reported no new byte",
                  16*4*CLKSYS_NS/1000.0);
      if (dup8) errors = errors + 1;

      // ---------------- 16 MHz (2 clk_sys per CPU clock) ---------------
      turbo = 1'b1;
      double_read(2, dup16);
      if (dup16)
         $display("FAIL: 16 MHz - second read only %0.2fus later STILL had bit 7 set: the driver sees a duplicate byte and the disk reads as unreadable. THIS IS THE BUG.",
                  16*2*CLKSYS_NS/1000.0);
      else
         $display("PASS: 16 MHz - latch self-cleared within the %0.2fus poll gap, second read correctly reported no new byte",
                  16*2*CLKSYS_NS/1000.0);
      if (dup16) errors = errors + 1;

      $display("");
      if (errors == 0)
         $display("IWM LATCH GATE: PASS");
      else
         $display("IWM LATCH GATE: FAIL (%0d)", errors);
      $finish;
   end

endmodule
