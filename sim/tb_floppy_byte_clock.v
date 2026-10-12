`timescale 1ns/1ps
//
// CPU_TIMING_PLAN.md Phase 5: a disk byte is 128 CPU clocks, not 128 clk8.
//
// The IWM's FCLK is the CPU's C8M on a real Plus, so a GCR byte always costs
// the .Sony read loop the same 128 CPU clocks. Once cpu_wait.v trims the CPU
// to 7.8336 MHz by skipping 5,168 of every 135,408 clk8, a byte timer still
// counting clk8 delivers bytes 3.7% early in CPU terms - and the read loop,
// which fits exactly with real wait states, overruns: floppies stop mounting
// (hardware, 0bf0de6d, 2026-10-12). floppy.v's byte timers count cpu_tick.
//
// With the real skip pattern this bench requires every read byte and every
// write byte to take exactly 128 CPU clocks (so more than 128 clk8), and with
// no skipping exactly 128 clk8, i.e. today's behaviour unchanged.
//
// Run: iverilog -g2012 -I rtl -y rtl -o sim/out/tb_floppy_byte_clock.vvp
//        sim/tb_floppy_byte_clock.v && vvp sim/out/tb_floppy_byte_clock.vvp
module tb_floppy_byte_clock;

   reg clk = 0;
   always #5 clk = ~clk;
   reg [1:0] busPhase = 2'b00;
   always @(posedge clk) busPhase <= busPhase + 1'b1;
   wire cep = (busPhase == 2'b11);
   wire cen = (busPhase == 2'b01);

   // cpu_wait.v's skip pattern: registered on cep, valid for the next clk8
   reg        trim = 1;
   reg [17:0] acc = 0;
   reg        skip = 0;
   always @(posedge clk) if (cep) begin
      if (!trim) skip <= 0;
      else if (acc + 18'd5168 >= 18'd135408) begin acc <= acc + 18'd5168 - 18'd135408; skip <= 1; end
      else begin acc <= acc + 18'd5168; skip <= 0; end
   end
   wire cpu_tick = !skip;

   reg [7:0] mem [0:819199];
   integer i;
   initial for (i = 0; i < 819200; i = i + 1) mem[i] = i[7:0] ^ 8'h5A;

   reg        _reset = 0;
   reg  [7:0] writeData = 8'h96;
   reg        writeReq = 0;
   wire       newByteReady, writeBusy;
   wire [21:0] dskReadAddr;

   floppy dut (
      .clk(clk), .cep(cep), .cen(cen), .cpu_tick(cpu_tick),
      ._reset(_reset),
      .ca0(1'b0), .ca1(1'b0), .ca2(1'b1), .SEL(1'b0), .lstrb(1'b0),
      ._enable(1'b0),
      .writeData(writeData),
      .readData(),
      .advanceDriveHead(1'b0),
      .newByteReady(newByteReady),
      .insertDisk(1'b1), .img800k(1'b1), .drive800k(1'b1), .mediaSides(1'b1),
      .disk_pwm(9'd0),
      .diskEject(), .motor(), .act(),
      .dskReadAddr(dskReadAddr),
      .dskReadAck(1'b1),                   // a byte always waiting, as tb_floppy_sides
      .dskReadData(mem[dskReadAddr]),
      .writeReq(writeReq), .writeProtect(1'b0),
      .writeBusy(writeBusy), .writeUnderrun(), .writeMode(1'b0),
      .dskWriteAddr(), .dskWriteData(), .dskWriteReq(), .dskWriteAck(1'b1),
      .dbg_floppy(), .dskCommitDone(), .dskCommitAddr()
   );

   // clk8 and CPU clocks since the last read byte
   integer n_clk8 = 0, n_cpu = 0;
   reg nbrPrev = 0;
   always @(posedge clk) nbrPrev <= newByteReady;
   wire rd_byte = newByteReady && !nbrPrev;

   integer fails = 0;

   // read-byte periods, fire to fire. A byte fires on a cep edge, and rd_byte
   // is high for the ONE clock after it, so counting every cep's tick and
   // closing the period on rd_byte measures (previous fire, this fire].
   integer rc8 = 0, rcc = 0, r_n = 0, r_cmin, r_cmax, r_8min, r_8max;
   reg     r_on = 0, r_armed = 0;
   always @(posedge clk) if (r_on) begin
      if (cep) begin rc8 = rc8 + 1; rcc = rcc + cpu_tick; end
      if (rd_byte) begin
         if (r_armed) begin
            if (rcc < r_cmin) r_cmin = rcc;  if (rcc > r_cmax) r_cmax = rcc;
            if (rc8 < r_8min) r_8min = rc8;  if (rc8 > r_8max) r_8max = rc8;
            r_n = r_n + 1;
         end
         r_armed = 1; rc8 = 0; rcc = 0;
      end
   end

   task measure_reads(input [8*12:1] label, input integer want_cpu, input integer want_clk8_min,
                      input integer want_clk8_max);
      begin
         r_cmin = 1 << 30; r_cmax = 0; r_8min = 1 << 30; r_8max = 0; r_n = 0;
         r_armed = 0; r_on = 1;
         wait (r_n >= 400);
         r_on = 0;
         if (r_cmin != want_cpu || r_cmax != want_cpu || r_8min < want_clk8_min || r_8max > want_clk8_max) begin
            $display("  FAIL %0s read: %0d..%0d CPU clocks, %0d..%0d clk8 per byte (want %0d CPU, %0d..%0d clk8)",
                     label, r_cmin, r_cmax, r_8min, r_8max, want_cpu, want_clk8_min, want_clk8_max);
            fails = fails + 1;
         end else
            $display("  ok   %0s read: %0d CPU clocks, %0d..%0d clk8 per byte", label, r_cmin, r_8min, r_8max);
      end
   endtask

   task measure_writes(input [8*12:1] label, input integer want_cpu);
      integer k, cc, cmin, cmax;
      begin
         cmin = 1 << 30; cmax = 0;
         for (k = 0; k < 50; k = k + 1) begin
            @(posedge clk); while (!cep) @(posedge clk);
            #1 writeReq = 1; @(posedge clk); #1 writeReq = 0;
            cc = 0;
            while (!writeBusy) @(posedge clk);
            while (writeBusy) begin
               @(posedge clk);
               if (cep && cpu_tick) cc = cc + 1;
            end
            if (cc < cmin) cmin = cc; if (cc > cmax) cmax = cc;
         end
         if (cmin < want_cpu - 1 || cmax > want_cpu) begin
            $display("  FAIL %0s write: %0d..%0d CPU clocks per byte (want %0d)", label, cmin, cmax, want_cpu);
            fails = fails + 1;
         end else
            $display("  ok   %0s write: %0d..%0d CPU clocks per byte", label, cmin, cmax);
      end
   endtask

   initial begin
      $display("tb_floppy_byte_clock: disk bytes in CPU clocks");
      repeat (20) @(posedge clk); #1 _reset = 1;
      trim = 0; repeat (2000) @(posedge clk);
      measure_reads ("untrimmed", 128, 128, 128);
      measure_writes("untrimmed", 128);
      trim = 1; repeat (2000) @(posedge clk);
      // 128 CPU clocks with ~1 skip in 26 clk8: 132..134 clk8
      measure_reads ("trimmed", 128, 132, 134);
      measure_writes("trimmed", 128);
      if (fails == 0) $display("PASS: disk bytes are 128 CPU clocks");
      else            $display("FAIL: %0d checks", fails);
      $finish;
   end

endmodule
