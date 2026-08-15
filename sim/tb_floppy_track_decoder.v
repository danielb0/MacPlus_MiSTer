`timescale 1ns/1ps
//
// Phase 2 -- RTL encoder -> RTL decoder round-trip gate for
// rtl/floppy_track_decoder.v, per FLOPPY_WRITE_PLAN.md Phase 2.
//
// Wires floppy_track_encoder's odata directly into floppy_track_decoder's
// idata (same `ready` pulse train driving both, same convention as
// tb_floppy_track_encoder.v: sparse one-cycle-high ready pulses, not held
// every cycle -- see that file's header for why holding it high is wrong).
//
// Round-trip: for four representative tracks x both sides of the same
// sim/image.hex 800K synthetic image Phase 0 used (0, 16, 40, 79 -- one
// from each spt group), every sector must be recovered byte-exact.
//
// Negative tests (against track 0 side 0, one sector at a time): corrupt
// one byte deep in the payload, corrupt one byte in the trailing checksum,
// and truncate mid-field. All three must reject and must never assert
// sector_valid for that sector -- mirrors sim/test_negative.py's three
// cases for the Phase 0 reference decoder.
//
module tb_floppy_track_decoder;

   localparam READY_GAP     = 8;   // clk cycles between ready pulses (real HW: 128)
   localparam CYCLES_PER_SECTOR = 782; // 781 field bytes + 1 STATE_WAIT cycle

   reg clk = 0;
   always #5 clk = ~clk;

   reg ready = 0;
   reg rst = 1;
   reg side = 0;
   reg sides = 1;
   reg [6:0] track = 0;

   reg [7:0] mem [0:819199];

   // ---- encoder (source of truth) ----
   wire [21:0] enc_addr;
   wire [7:0]  enc_odata;
   wire [7:0]  enc_idata = mem[enc_addr];

   floppy_track_encoder dut_enc (
      .clk(clk), .ready(ready), .rst(rst),
      .side(side), .sides(sides), .track(track),
      .addr(enc_addr), .idata(enc_idata), .odata(enc_odata)
   );

   // ---- corruption injector between encoder and decoder ----
   reg corrupt_this_tick = 0;
   wire [7:0] link_byte = enc_odata ^ (corrupt_this_tick ? 8'hFF : 8'h00);

   // ---- decoder (DUT) ----
   reg [8:0] dec_buf_addr = 0;
   wire [7:0] dec_buf_data;

   floppy_track_decoder dut_dec (
      .clk(clk), .ready(ready), .rst(rst),
      .side(side), .sides(sides), .track(track),
      .idata(link_byte),
      .sector_valid(), .sector(), .addr(),
      .reject(),
      .buf_addr(dec_buf_addr), .buf_data(dec_buf_data)
   );

   // Icarus (this devel build) does not reliably hold a registered pulse
   // output stable if a further blocking assignment to an unrelated signal
   // (here, `ready`) executes in the same simulation timestep before the
   // read - sampling immediately after @(posedge clk), before touching
   // `ready` again, is what's reliable (confirmed against $strobe and a
   // minimal repro during bring-up). So capture the pulse outputs into
   // testbench regs right at the edge, and let callers read those instead
   // of re-reading dut_dec's live signals after tick_normal/tick_corrupt
   // returns.
   reg last_sector_valid, last_reject;
   reg [3:0] last_sector;
   reg [21:0] last_addr;

   task tick_normal;
      begin
         corrupt_this_tick = 1'b0;
         ready = 0;
         repeat (READY_GAP - 1) @(posedge clk);
         ready = 1;
         @(posedge clk);
         last_sector_valid = dut_dec.sector_valid;
         last_reject       = dut_dec.reject;
         last_sector       = dut_dec.sector;
         last_addr         = dut_dec.addr;
         ready = 0;
         #1;
      end
   endtask

   task tick_corrupt;
      begin
         corrupt_this_tick = 1'b1;
         ready = 0;
         repeat (READY_GAP - 1) @(posedge clk);
         ready = 1;
         @(posedge clk);
         last_sector_valid = dut_dec.sector_valid;
         last_reject       = dut_dec.reject;
         last_sector       = dut_dec.sector;
         last_addr         = dut_dec.addr;
         ready = 0;
         #1;
         corrupt_this_tick = 1'b0;
      end
   endtask

   task do_reset;
      begin
         rst = 1;
         @(posedge clk);
         @(negedge clk); // deassert past the DUTs' own reset check, not racing it
         rst = 0;
         #1;
      end
   endtask

   function integer spt_of;
      input [6:0] t;
      begin
         if (t[6:4] == 3'd0)      spt_of = 12;
         else if (t[6:4] == 3'd1) spt_of = 11;
         else if (t[6:4] == 3'd2) spt_of = 10;
         else if (t[6:4] == 3'd3) spt_of = 9;
         else                     spt_of = 8;
      end
   endfunction

   integer all_ok;
   integer cyc, i, base, expected_spt, seen_count, mismatches, total_cycles;
   reg [11:0] seen_mask;

   task run_track_side;
      input [6:0] t;
      input       s;
      begin
         track = t; side = s;
         do_reset;

         expected_spt = spt_of(t);
         total_cycles = expected_spt * CYCLES_PER_SECTOR + 200;
         seen_mask   = 12'd0;
         seen_count  = 0;
         mismatches  = 0;

         for (cyc = 0; cyc < total_cycles; cyc = cyc + 1) begin
            tick_normal;
            if (last_sector_valid) begin
               seen_count = seen_count + 1;
               seen_mask[last_sector] = 1'b1;
               base = last_addr;
               for (i = 0; i < 512; i = i + 1)
                  if (dut_dec.buf_mem[i] !== mem[base + i])
                     mismatches = mismatches + 1;
            end
         end

         if (seen_count == expected_spt && mismatches == 0 && seen_mask == ((12'd1 << expected_spt) - 12'd1)) begin
            $display("PASS: track %0d side %0d - all %0d sectors recovered byte-exact", t, s, expected_spt);
         end else begin
            $display("FAIL: track %0d side %0d - seen %0d/%0d sectors (mask %b), %0d byte mismatches",
                      t, s, seen_count, expected_spt, seen_mask, mismatches);
            all_ok = 0;
         end
      end
   endtask

   // ---- negative tests: run exactly one sector, optionally corrupting
   // one tick, and confirm sector_valid never fires for it ----
   reg got_valid, got_reject;
   integer t2, corrupt_tick, stop_tick;

   task run_one_sector;
      input integer c_tick;   // -1 = no corruption
      input integer s_tick;   // stop feeding after this many ticks (-1 = full sector)
      begin
         track = 7'd0; side = 1'b0;
         do_reset;
         got_valid  = 1'b0;
         got_reject = 1'b0;
         for (t2 = 0; t2 < CYCLES_PER_SECTOR; t2 = t2 + 1) begin
            if (s_tick >= 0 && t2 >= s_tick) begin
               // truncated: stop feeding ready pulses entirely, just let time pass
               #(READY_GAP * 10);
            end else if (t2 == c_tick) begin
               tick_corrupt;
               if (last_sector_valid) got_valid = 1'b1;
               if (last_reject)       got_reject = 1'b1;
            end else begin
               tick_normal;
               if (last_sector_valid) got_valid = 1'b1;
               if (last_reject)       got_reject = 1'b1;
            end
         end
      end
   endtask

   initial begin
      $readmemh("sim/image.hex", mem);
      all_ok = 1;

      // ---- round-trip gate ----
      run_track_side(7'd0,  1'b0);
      run_track_side(7'd0,  1'b1);
      run_track_side(7'd16, 1'b0);
      run_track_side(7'd16, 1'b1);
      run_track_side(7'd40, 1'b0);
      run_track_side(7'd40, 1'b1);
      run_track_side(7'd79, 1'b0);
      run_track_side(7'd79, 1'b1);

      // ---- sanity: a clean single sector must still validate (proves the
      // negative tests below are catching real corruption, not a broken DUT) ----
      run_one_sector(-1, -1);
      if (got_valid && !got_reject) begin
         $display("PASS: clean single sector decodes with no reject");
      end else begin
         $display("FAIL: clean single sector did not decode cleanly (valid=%b reject=%b)", got_valid, got_reject);
         all_ok = 0;
      end

      // ---- corrupt one byte deep in the payload (tick 187: 100 bytes into
      // the DPRE+DATA region, which starts at tick 87) ----
      run_one_sector(187, -1);
      if (!got_valid && got_reject) begin
         $display("PASS: corrupt data byte rejected, never committed");
      end else begin
         $display("FAIL: corrupt data byte - valid=%b reject=%b (expected valid=0 reject=1)", got_valid, got_reject);
         all_ok = 0;
      end

      // ---- corrupt the first checksum byte (tick 774: DZRO(12)+GRP(687)
      // after DHDR ends at tick 75, i.e. 75+687=762... use the field offset
      // derived in the module header: DHDR ends tick 74, DZRO 75-86, GRP
      // 87-773, DSUM starts tick 774 ----
      run_one_sector(774, -1);
      if (!got_valid && got_reject) begin
         $display("PASS: corrupt checksum byte rejected, never committed");
      end else begin
         $display("FAIL: corrupt checksum byte - valid=%b reject=%b (expected valid=0 reject=1)", got_valid, got_reject);
         all_ok = 0;
      end

      // ---- truncate mid-payload (stop feeding bytes partway through GRP) ----
      run_one_sector(-1, 300);
      if (!got_valid) begin
         $display("PASS: truncated field never committed");
      end else begin
         $display("FAIL: truncated field asserted sector_valid");
         all_ok = 0;
      end

      $display("");
      $display("%s", all_ok ? "PHASE 2 GATE: PASS" : "PHASE 2 GATE: FAIL");
      $finish;
   end

endmodule
