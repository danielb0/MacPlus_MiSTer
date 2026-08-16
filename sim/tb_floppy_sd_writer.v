`timescale 1ns/1ps
//
// Phase 4 of FLOPPY_WRITE_PLAN.md: exercise floppy_sd_writer.v's SD
// persistence handshake in isolation, driving its commit_* tap inputs the
// same way floppy_write_committer.v's ASSERT/DONE_PULSE states would
// (see that module's header for the sd_buf_addr/sd_buf_data/sd_buf_wr
// tap this test mimics), and mocking hps_io's sd_wr/sd_ack/sd_buff_addr
// protocol the way scsi.v's own io_wr producer is served on real
// hardware.
//
// Three cases: a normal single commit persists byte-exact at the right
// LBA; two commits landing back-to-back (before the first has even
// started draining) both survive via the depth-2 queue, in order; a
// read-only drive never asserts sd_wr at all.
module tb_floppy_sd_writer;

   reg clk = 0;
   always #5 clk = ~clk;

   reg  reset = 1;
   reg  img_mounted = 1'b0;

   reg         commit_done = 1'b0;
   reg  [21:0] commit_addr = 22'd0;
   reg         commit_buf_wr = 1'b0;
   reg  [7:0]  commit_buf_addr = 8'd0;
   reg  [15:0] commit_buf_data = 16'd0;

   reg         readonly = 1'b0;
   reg         loader_busy = 1'b0;

   wire [31:0] sd_lba;
   wire        sd_wr;
   reg         sd_ack = 1'b0;

   reg  [7:0]  sd_buff_addr = 8'd0;
   wire [15:0] sd_buff_din;

   wire        busy;

   floppy_sd_writer dut (
      .clk(clk),
      .reset(reset),

      .img_mounted(img_mounted),

      .commit_done(commit_done),
      .commit_addr(commit_addr),
      .commit_buf_wr(commit_buf_wr),
      .commit_buf_addr(commit_buf_addr),
      .commit_buf_data(commit_buf_data),

      .readonly(readonly),
      .loader_busy(loader_busy),

      .sd_lba(sd_lba),
      .sd_wr(sd_wr),
      .sd_ack(sd_ack),

      .sd_buff_addr(sd_buff_addr),
      .sd_buff_din(sd_buff_din),

      .busy(busy)
   );

   task do_reset;
      begin
         reset = 1'b1;
         @(posedge clk);
         @(negedge clk);
         reset = 1'b0;
         #1;
      end
   endtask

   // ---- second instance, ACK_TIMEOUT_BITS shrunk to 6 (63 cycles) for
   // Test 5 (P_WAIT_ACK timeout, Phase 5 item 2) - kept entirely separate
   // from `dut` above so its short timeout can never interact with tests
   // 1-4, which deliberately hold sd_wr asserted for long stretches
   // (Test 4 withholds sd_ack for its own reasons) against the real
   // 24-bit/~0.5s default.
   reg  reset_to = 1;
   reg  img_mounted_to = 1'b0;
   reg  commit_done_to = 1'b0;
   reg  [21:0] commit_addr_to = 22'd0;
   reg  commit_buf_wr_to = 1'b0;
   reg  [7:0]  commit_buf_addr_to = 8'd0;
   reg  [15:0] commit_buf_data_to = 16'd0;
   reg  readonly_to = 1'b0;
   reg  loader_busy_to = 1'b0;
   wire [31:0] sd_lba_to;
   wire        sd_wr_to;
   reg         sd_ack_to = 1'b0; // never asserted - this is the point of Test 5
   reg  [7:0]  sd_buff_addr_to = 8'd0;
   wire [15:0] sd_buff_din_to;
   wire        busy_to;

   floppy_sd_writer #( .ACK_TIMEOUT_BITS(6) ) dut_to (
      .clk(clk), .reset(reset_to),
      .img_mounted(img_mounted_to),
      .commit_done(commit_done_to), .commit_addr(commit_addr_to),
      .commit_buf_wr(commit_buf_wr_to), .commit_buf_addr(commit_buf_addr_to),
      .commit_buf_data(commit_buf_data_to),
      .readonly(readonly_to), .loader_busy(loader_busy_to),
      .sd_lba(sd_lba_to), .sd_wr(sd_wr_to), .sd_ack(sd_ack_to),
      .sd_buff_addr(sd_buff_addr_to), .sd_buff_din(sd_buff_din_to),
      .busy(busy_to)
   );

   task do_reset_to;
      begin
         reset_to = 1'b1;
         @(posedge clk);
         @(negedge clk);
         reset_to = 1'b0;
         #1;
      end
   endtask

   // mirrors feed_commit above, against dut_to's inputs.
   task feed_commit_to;
      input [21:0] addr;
      integer i;
      begin
         commit_addr_to = addr;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk); #1;
            commit_buf_addr_to = i[7:0];
            commit_buf_data_to = 16'h6000 + i[15:0];
            commit_buf_wr_to   = 1'b1;
         end
         @(posedge clk); #1;
         commit_buf_wr_to = 1'b0;
         commit_done_to   = 1'b1;
         @(posedge clk); #1;
         commit_done_to = 1'b0;
      end
   endtask

   // mimics floppy_write_committer's ASSERT-state tap: present each of the
   // 256 words for one clk, then pulse commit_done with commit_addr already
   // stable (matches committed_addr being valid continuously, not just at
   // the pulse).
   task feed_commit;
      input [21:0] addr;
      input [15:0] pattern_seed;
      integer i;
      begin
         commit_addr = addr;
         for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk); #1; // #1 avoids racing the DUT's own always @(posedge clk)
                                 // sampling these same signals in the same timestep -
                                 // see FLOPPY_WRITE_PLAN.md Phase 0 lesson #1.
            commit_buf_addr = i[7:0];
            commit_buf_data = pattern_seed + i[15:0];
            commit_buf_wr   = 1'b1;
         end
         @(posedge clk); #1;
         commit_buf_wr = 1'b0;
         commit_done   = 1'b1;
         @(posedge clk); #1;
         commit_done = 1'b0;
      end
   endtask

   // mocks hps_io servicing one sd_wr request: waits for sd_wr, acks after
   // an arbitrary delay, walks sd_buff_addr across the whole 256-word
   // block sampling sd_buff_din (which is a registered, 1-cycle-latency
   // read - address must settle for a full clk before the data is valid,
   // matching mem0_do/mem1_do in the DUT), then drops sd_ack. Results land
   // in the module-scope got_lba/got_data scratch regs below (Icarus'
   // -g2001 mode rejects unpacked-array task ports).
   task drain_block;
      integer i;
      begin
         wait (sd_wr);
         got_lba = sd_lba;
         repeat (3) @(posedge clk); #1; // arbitrary hps_io ack latency
         sd_ack = 1'b1;
         sd_buff_addr = 8'd0;
         // one clk to let mem0_do/mem1_do register address 0's word before
         // the first sample - both are NBA-updated on this same edge, so a
         // #1 after @(posedge clk) is required everywhere below to read the
         // post-NBA value rather than the stale pre-edge one.
         @(posedge clk); #1;
         for (i = 0; i < 256; i = i + 1) begin
            got_data[i] = sd_buff_din;
            if (i < 255) sd_buff_addr = sd_buff_addr + 1'b1;
            @(posedge clk); #1;
         end
         sd_ack = 1'b0;
         sd_buff_addr = 8'd0;
      end
   endtask

   integer all_ok, i;
   reg [31:0] got_lba;
   reg [15:0] got_data [0:255];

   // sd_buff_din is the raw hps_io wire word, byte-swapped from the
   // internal (committed) word convention - see floppy_sd_writer.v's
   // header and tb_loader_writer_roundtrip.v, which proves this swap and
   // floppy_loader.v's inverse one round-trip correctly. Tests here only
   // care that the right bytes reach the wire in the right order, so
   // comparisons below swap the expected pattern to match.
   function [15:0] swap16;
      input [15:0] w;
      swap16 = {w[7:0], w[15:8]};
   endfunction

   initial begin
      all_ok = 1;

      // =====================================================================
      // Test 1: normal commit - one sector, byte-exact at the right LBA.
      // =====================================================================
      do_reset;
      readonly    = 1'b0;
      loader_busy = 1'b0;
      feed_commit(22'd8192, 16'hA000); // byte offset 8192 -> LBA 16

      drain_block;

      begin : test1
         integer mismatches;
         mismatches = 0;
         if (got_lba !== 32'd16) begin
            $display("FAIL: test1 - expected LBA 16, got %0d", got_lba);
            all_ok = 0;
         end
         for (i = 0; i < 256; i = i + 1)
            if (got_data[i] !== swap16(16'hA000 + i[15:0])) mismatches = mismatches + 1;
         if (mismatches == 0 && got_lba === 32'd16) begin
            $display("PASS: test1 - single commit persisted byte-exact at LBA %0d", got_lba);
         end else if (mismatches != 0) begin
            $display("FAIL: test1 - %0d word mismatches", mismatches);
            all_ok = 0;
         end
      end

      // busy must drop once the only queued entry has drained.
      @(posedge clk); #1;
      if (busy) begin
         $display("FAIL: test1 - busy still asserted after the only commit drained");
         all_ok = 0;
      end

      // =====================================================================
      // Test 2: two commits land back-to-back, before the first has even
      // started draining (sd_ack still low) - the depth-2 queue must not
      // drop either one, and they must drain in order.
      // =====================================================================
      do_reset;
      readonly    = 1'b0;
      loader_busy = 1'b0;
      feed_commit(22'd0,     16'h1000); // byte offset 0     -> LBA 0
      feed_commit(22'd20480, 16'h2000); // byte offset 20480 -> LBA 40

      begin : test2
         reg [31:0] lba_a, lba_b;
         reg [15:0] data_a [0:255];
         integer mismatches_a, mismatches_b;

         drain_block;
         lba_a = got_lba;
         for (i = 0; i < 256; i = i + 1) data_a[i] = got_data[i];

         drain_block;
         lba_b = got_lba;

         mismatches_a = 0;
         mismatches_b = 0;
         for (i = 0; i < 256; i = i + 1) begin
            if (data_a[i] !== swap16(16'h1000 + i[15:0])) mismatches_a = mismatches_a + 1;
            if (got_data[i] !== swap16(16'h2000 + i[15:0])) mismatches_b = mismatches_b + 1;
         end

         if (lba_a === 32'd0 && lba_b === 32'd40 && mismatches_a == 0 && mismatches_b == 0) begin
            $display("PASS: test2 - back-to-back commits both persisted in order (LBA %0d then %0d)", lba_a, lba_b);
         end else begin
            $display("FAIL: test2 - lba_a=%0d (want 0, %0d mismatches) lba_b=%0d (want 40, %0d mismatches)",
                      lba_a, mismatches_a, lba_b, mismatches_b);
            all_ok = 0;
         end
      end

      // =====================================================================
      // Test 3: read-only drive must never assert sd_wr for a commit.
      // =====================================================================
      do_reset;
      readonly    = 1'b1;
      loader_busy = 1'b0;
      feed_commit(22'd4096, 16'h3000);
      repeat (300) @(posedge clk); // comfortably longer than a real drain would take
      if (!sd_wr && !busy) begin
         $display("PASS: test3 - read-only drive never asserted sd_wr");
      end else begin
         $display("FAIL: test3 - read-only drive asserted sd_wr=%b busy=%b", sd_wr, busy);
         all_ok = 0;
      end

      // =====================================================================
      // Test 4: eject-race interlock. Two commits land back-to-back so the
      // first (A) is already mid-flight (sd_wr asserted, stuck in
      // P_WAIT_ACK since we withhold sd_ack) when the second (B) becomes
      // queued. An img_mounted pulse must then: let A's already-in-flight
      // transfer complete untouched, but drop B before it ever starts.
      // =====================================================================
      do_reset;
      readonly    = 1'b0;
      loader_busy = 1'b0;
      feed_commit(22'd0,     16'h4000); // A: byte offset 0     -> LBA 0
      feed_commit(22'd20480, 16'h5000); // B: byte offset 20480 -> LBA 40

      begin : test4
         reg saw_second_wr;
         if (!sd_wr) begin
            $display("FAIL: test4 - expected commit A already mid-flight (sd_wr asserted) before img_mounted");
            all_ok = 0;
         end

         @(posedge clk); #1;
         img_mounted = 1'b1;
         @(posedge clk); #1;
         img_mounted = 1'b0;

         // A must still complete normally - the interlock must not have
         // torn down a transfer hps_io may already be servicing.
         drain_block;
         if (got_lba !== 32'd0) begin
            $display("FAIL: test4 - in-flight commit A did not complete at its own LBA (got %0d)", got_lba);
            all_ok = 0;
         end

         // B must never surface as a second sd_wr - it was dropped while
         // still queued, never started.
         saw_second_wr = 1'b0;
         repeat (300) begin
            @(posedge clk);
            if (sd_wr) saw_second_wr = 1'b1;
         end
         if (!saw_second_wr && !busy) begin
            $display("PASS: test4 - in-flight commit survived img_mounted, queued commit was dropped");
         end else begin
            $display("FAIL: test4 - queued commit B was not dropped (saw_second_wr=%b busy=%b)", saw_second_wr, busy);
            all_ok = 0;
         end
      end

      // =====================================================================
      // Test 5 (Phase 5 item 2): P_WAIT_ACK has no bound otherwise - if
      // sd_ack never arrives for this slot's sd_wr (framework quirk, a
      // mount race, etc.) the module must recover on its own instead of
      // wedging forever with busy stuck high. Uses dut_to (ACK_TIMEOUT_BITS
      // = 6, i.e. 63 cycles) so the real 24-bit default doesn't make this
      // test impractically slow.
      // =====================================================================
      do_reset_to;
      readonly_to    = 1'b0;
      loader_busy_to = 1'b0;
      feed_commit_to(22'd0);

      begin : test5
         integer waited;
         waited = 0;
         // capture (commit_done) and the P_IDLE->P_WAIT_ACK transition are
         // one cycle apart (mirrors drain_block's own wait(sd_wr) above) -
         // give it a bounded head start before checking.
         waited = 0;
         while (!sd_wr_to && waited < 10) begin
            @(posedge clk);
            waited = waited + 1;
         end
         if (!sd_wr_to) begin
            $display("FAIL: test5 - expected sd_wr asserted (P_WAIT_ACK) before the timeout");
            all_ok = 0;
         end
         waited = 0;
         while (sd_wr_to && waited < 200) begin
            @(posedge clk);
            waited = waited + 1;
         end
         @(posedge clk); #1;
         if (!sd_wr_to && !busy_to && waited < 200) begin
            $display("PASS: test5 - P_WAIT_ACK with no sd_ack timed out after %0d cycles and recovered (busy=0)", waited);
         end else begin
            $display("FAIL: test5 - never recovered from a withheld sd_ack (sd_wr=%b busy=%b waited=%0d)",
                      sd_wr_to, busy_to, waited);
            all_ok = 0;
         end
      end

      $display("");
      $display("%s", all_ok ? "PHASE 4 SD-WRITER GATE: PASS" : "PHASE 4 SD-WRITER GATE: FAIL");
      $finish;
   end

endmodule
