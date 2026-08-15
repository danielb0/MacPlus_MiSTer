`timescale 1ns/1ps
//
// Phase 0 -- standalone testbench for rtl/floppy_track_encoder.v
//
// Drives the encoder for a handful of representative tracks/sides on a
// synthetic 800K (double-sided) image and dumps the raw byte stream it
// produces to sim/out/track<T>_side<S>.bin. No core changes; this only
// exercises the encoder module in isolation.
//
// `ready` is a sparse one-cycle-high pulse (READY_GAP clk cycles between
// pulses), not asserted every cycle. This matters: in the real system
// (rtl/floppy.v) `ready` is `~old_newByteReady & newByteReady`, pulsed
// once per ~128 clk cycles by diskDataByteTimer -- one pulse per disk
// byte time. The `addr` register updates every clk cycle regardless of
// `ready`, so in real operation it has ~128 idle cycles to settle onto
// the current (sector, src_offset) before each ready-gated fetch. Holding
// `ready` high every cycle (as an earlier version of this testbench did)
// starves that settle time and produces an address-pipeline artifact
// (some source bytes read twice, others never read) that cannot occur in
// real operation -- caught by cross-checking against a decoder built from
// the resulting dumps, which is exactly what Phase 0 is for.
//
// Byte count per track is generous (multiple full revolutions) so the
// Python-side decoder can hunt for sync marks the way a real decoder
// would, rather than relying on a hand-derived cycle count.
//
module tb_floppy_track_encoder;

   localparam READY_GAP = 8; // clk cycles between ready pulses (real HW: 128)

   reg clk = 0;
   reg ready = 0;
   reg rst = 1;
   reg side = 0;
   reg sides = 1;
   reg [6:0] track = 0;

   wire [21:0] addr;
   wire [7:0] odata;

   reg [7:0] mem [0:819199];
   wire [7:0] idata = mem[addr];

   floppy_track_encoder dut (
      .clk(clk),
      .ready(ready),
      .rst(rst),
      .side(side),
      .sides(sides),
      .track(track),
      .addr(addr),
      .idata(idata),
      .odata(odata)
   );

   always #5 clk = ~clk;

   integer CYCLES;
   integer i;
   integer fd;
   reg [8*64-1:0] fname;

   // advances the encoder by exactly one ready-gated step: idle for
   // READY_GAP-1 clk cycles (mirroring diskDataByteTimer counting up
   // between bytes), then one clk cycle with ready=1.
   task tick;
      begin
         ready = 0;
         repeat (READY_GAP - 1) @(posedge clk);
         ready = 1;
         @(posedge clk);
         ready = 0;
         #1; // let combinational odata settle before the next sample
      end
   endtask

   task run_track;
      input [6:0] t;
      input s;
      begin
         track = t;
         side  = s;
         rst   = 1;
         @(posedge clk);
         @(negedge clk); // deassert clear of the posedge to avoid racing the DUT's own reset check
         rst = 0;
         #1; // let combinational odata settle post-reset before first sample

         $sformat(fname, "sim/out/track%0d_side%0d.bin", t, s);
         fd = $fopen(fname, "wb");
         if (fd == 0) begin
            $display("ERROR: could not open %s for writing", fname);
            $finish;
         end

         for (i = 0; i < CYCLES; i = i + 1) begin
            $fwrite(fd, "%c", odata);
            tick;
         end

         $fclose(fd);
         $display("wrote %0d bytes to %s (track=%0d side=%0d spt-relevant)", CYCLES, fname, t, s);
      end
   endtask

   initial begin
      $readmemh("sim/image.hex", mem);

      // 20000 bytes covers >2 full revolutions even at the densest track
      // (track 0, spt=12, ~778 bytes/sector -> ~9336 bytes/rev) and >3
      // revolutions at the sparsest (track 64-79, spt=8, ~6224 bytes/rev).
      CYCLES = 20000;

      run_track(7'd0, 1'b0);
      run_track(7'd0, 1'b1);
      run_track(7'd16, 1'b0);
      run_track(7'd16, 1'b1);
      run_track(7'd40, 1'b0);
      run_track(7'd40, 1'b1);
      run_track(7'd79, 1'b0);
      run_track(7'd79, 1'b1);

      $display("done");
      $finish;
   end

endmodule
