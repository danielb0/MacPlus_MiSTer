`timescale 1ns/1ps
//
// Phase 3 -- real-write decode gate for rtl/floppy_track_decoder.v.
//
// Unlike tb_floppy_track_decoder.v (which round-trips the RTL *encoder*'s
// output back through the decoder), this feeds the decoder a stream built
// by sim/gen_write_stream.py: a from-scratch encoding of what a real Mac
// write actually puts on the wire -- one continuous checksummed 524-byte
// tag(12)+data(512) payload per sector, not the encoder's all-zero-tag
// literal-sync shortcut. side 0's stream uses an all-zero tag (sanity);
// side 1's uses a real, non-zero, non-trivial tag per sector -- the exact
// case floppy_track_decoder.v rejected before the Phase 3 fix (see its
// header comment and FLOPPY_WRITE_PLAN.md Phase 3).
//
// Both streams must decode to the same 512-byte sector_pattern() payload
// sim/image.hex already carries for track 0 (both sides) -- the tag bytes
// must be recovered-and-discarded, never leak into buf_mem.
//
module tb_floppy_write_stream;

   localparam READY_GAP = 8; // clk cycles between ready pulses

   reg clk = 0;
   always #5 clk = ~clk;

   reg ready = 0;
   reg rst = 1;
   reg side = 0;
   reg sides = 1;
   reg [6:0] track = 0;

   reg [7:0] mem [0:819199];       // expected sector data (sim/image.hex)
   reg [7:0] wmem [0:5999];        // write-stream bytes for the active side

   reg [8:0] dec_buf_addr = 0;
   wire [7:0] dec_buf_data;
   wire sector_valid, reject;
   wire [3:0] sector;
   wire [21:0] addr;

   reg corrupt_this_tick = 0;
   integer byte_idx;
   wire [7:0] feed_byte = wmem[byte_idx] ^ (corrupt_this_tick ? 8'hFF : 8'h00);

   floppy_track_decoder dut_dec (
      .clk(clk), .ready(ready), .rst(rst),
      .side(side), .sides(sides), .track(track),
      .idata(feed_byte),
      .sector_valid(sector_valid), .sector(sector), .addr(addr),
      .reject(reject),
      .buf_addr(dec_buf_addr), .buf_data(dec_buf_data)
   );

   reg last_sector_valid, last_reject;
   reg [3:0] last_sector;
   reg [21:0] last_addr;

   // Every DUT input is driven, and every DUT output sampled, ONE DELTA
   // AFTER the clock edge (#1), never at zero delay on the edge itself.
   // This is the project's standing rule (FLOPPY_WRITE_PLAN.md Phase 0
   // lesson, the Phase 4 sd_writer 50%-dropout bug, the Phase 5 eject
   // strobe race) and it is load-bearing here: `ready = 0` at zero delay
   // straight after @(posedge clk) is in the same timestep as the DUT's own
   // sampling of `ready` at that edge, so which value the DUT sees is
   // decided by Icarus' process ordering, not by the testbench. That
   // ordering happens to depend on the DUT's sensitivity list, so this
   // raced silently for as long as floppy_track_decoder used an async
   // reset and flipped to "every byte dropped" the moment it became
   // synchronous - a pass that was never actually proving anything.
   task tick;
      input do_corrupt;
      begin
         corrupt_this_tick = do_corrupt;
         ready = 0;
         repeat (READY_GAP - 1) begin @(posedge clk); #1; end
         ready = 1;
         @(posedge clk);
         #1; // let this edge's NBAs settle before reading or re-driving
         last_sector_valid = sector_valid;
         last_reject       = reject;
         last_sector       = sector;
         last_addr         = addr;
         ready = 0;
         corrupt_this_tick = 0;
         if (byte_idx < 5999) byte_idx = byte_idx + 1;
      end
   endtask

   task do_reset;
      begin
         rst = 1;
         @(posedge clk);
         @(negedge clk);
         rst = 0;
         #1;
      end
   endtask

   integer all_ok, cyc, i, base, seen_count, mismatches;
   reg [3:0] seen_mask;

   task run_side;
      input s;
      input [8*30-1:0] hexfile;
      begin
         side = s;
         track = 7'd0;
         do_reset;
         byte_idx = 0;
         $readmemh(hexfile, wmem);
         seen_mask = 4'd0;
         seen_count = 0;
         mismatches = 0;

         for (cyc = 0; cyc < 3000; cyc = cyc + 1) begin
            tick(1'b0);
            if (last_sector_valid) begin
               seen_count = seen_count + 1;
               seen_mask[last_sector] = 1'b1;
               base = last_addr;
               for (i = 0; i < 512; i = i + 1)
                  if (dut_dec.buf_mem[i] !== mem[base + i])
                     mismatches = mismatches + 1;
            end
         end

         if (seen_count == 4 && mismatches == 0 && seen_mask == 4'b1111) begin
            $display("PASS: side %0d - all 4 sectors recovered byte-exact (tag discarded correctly)", s);
         end else begin
            $display("FAIL: side %0d - seen %0d/4 sectors (mask %b), %0d byte mismatches",
                      s, seen_count, seen_mask, mismatches);
            all_ok = 0;
         end
      end
   endtask

   // ---- negative tests: run exactly one (real-tag) sector field,
   // optionally corrupting one tick or truncating, and confirm
   // sector_valid never fires for it. Field layout (side 1, sector 0):
   // D5 AA AD(3) + sector(1) + GRP(699) + DSUM(4) + DTRL(2) = 709 bytes.
   integer t2, corrupt_tick, stop_tick;
   reg got_valid, got_reject;

   task run_one_field;
      input integer c_tick; // -1 = no corruption
      input integer s_tick; // stop feeding after this many ticks (-1 = full field)
      begin
         side = 1'b1;
         track = 7'd0;
         do_reset;
         byte_idx = 0;
         $readmemh("sim/write_stream_side1.hex", wmem);
         got_valid  = 1'b0;
         got_reject = 1'b0;
         for (t2 = 0; t2 < 709; t2 = t2 + 1) begin
            if (s_tick >= 0 && t2 >= s_tick) begin
               #(READY_GAP * 10);
            end else begin
               tick(t2 == c_tick);
               if (last_sector_valid) got_valid  = 1'b1;
               if (last_reject)       got_reject = 1'b1;
            end
         end
      end
   endtask

   // ---- negative tests (Phase 5 item 2, holes A/B): a bare D5 AA AD +
   // sector-number byte, no full field behind it - do_reject fires (or
   // doesn't) purely on the S_SECT check, before any GRP bytes are needed,
   // so a handful of ticks is enough. Writes directly into wmem instead of
   // via $readmemh - no fixture file needed for 4 synthetic bytes.
   task run_bad_field;
      input [7:0] sect_byte;
      input       s_side;
      input       s_sides;
      begin
         side  = s_side;
         sides = s_sides;
         track = 7'd0;
         do_reset;
         byte_idx = 0;
         wmem[0] = 8'hD5; wmem[1] = 8'hAA; wmem[2] = 8'hAD; wmem[3] = sect_byte;
         wmem[4] = 8'h00; wmem[5] = 8'h00; wmem[6] = 8'h00; wmem[7] = 8'h00;
         got_valid  = 1'b0;
         got_reject = 1'b0;
         for (t2 = 0; t2 < 8; t2 = t2 + 1) begin
            tick(1'b0);
            if (last_sector_valid) got_valid  = 1'b1;
            if (last_reject)       got_reject = 1'b1;
         end
      end
   endtask

   initial begin
      $readmemh("sim/image.hex", mem);
      all_ok = 1;

      run_side(1'b0, "sim/write_stream_side0.hex");
      run_side(1'b1, "sim/write_stream_side1.hex");

      run_one_field(-1, -1);
      if (got_valid && !got_reject) begin
         $display("PASS: clean real-tag field decodes with no reject");
      end else begin
         $display("FAIL: clean real-tag field did not decode cleanly (valid=%b reject=%b)", got_valid, got_reject);
         all_ok = 0;
      end

      // corrupt one byte deep in the tag+data payload (tick 200, well
      // inside the 699-byte GRP region which starts at tick 4)
      run_one_field(200, -1);
      if (!got_valid && got_reject) begin
         $display("PASS: corrupt payload byte rejected, never committed");
      end else begin
         $display("FAIL: corrupt payload byte - valid=%b reject=%b (expected valid=0 reject=1)", got_valid, got_reject);
         all_ok = 0;
      end

      // corrupt the first checksum byte (GRP ends at tick 702, DSUM starts tick 703)
      run_one_field(703, -1);
      if (!got_valid && got_reject) begin
         $display("PASS: corrupt checksum byte rejected, never committed");
      end else begin
         $display("FAIL: corrupt checksum byte - valid=%b reject=%b (expected valid=0 reject=1)", got_valid, got_reject);
         all_ok = 0;
      end

      // truncate mid-payload (stop feeding bytes partway through GRP)
      run_one_field(-1, 300);
      if (!got_valid) begin
         $display("PASS: truncated field never committed");
      end else begin
         $display("FAIL: truncated field asserted sector_valid");
         all_ok = 0;
      end

      // out-of-range sector number: track 0 has spt=12, raw byte 0xAE
      // decodes to nib_cur=6'h0C=12, i.e. exactly spt - the first invalid
      // value (Phase 5 item 2, hole A).
      run_bad_field(8'hAE, 1'b0, 1'b1);
      if (!got_valid && got_reject) begin
         $display("PASS: out-of-range sector number rejected before the checksum chain even starts");
      end else begin
         $display("FAIL: out-of-range sector number - valid=%b reject=%b (expected valid=0 reject=1)", got_valid, got_reject);
         all_ok = 0;
      end

      // side==1 on a single-sided (sides==0) mount, otherwise-valid sector 0
      // (raw 0x96, nib_cur=0) - Phase 5 item 2, hole B.
      run_bad_field(8'h96, 1'b1, 1'b0);
      if (!got_valid && got_reject) begin
         $display("PASS: side 1 on a single-sided mount rejected");
      end else begin
         $display("FAIL: side 1 on a single-sided mount - valid=%b reject=%b (expected valid=0 reject=1)", got_valid, got_reject);
         all_ok = 0;
      end

      $display("");
      $display("%s", all_ok ? "PHASE 3 WRITE-STREAM GATE: PASS" : "PHASE 3 WRITE-STREAM GATE: FAIL");
      $finish;
   end

endmodule
