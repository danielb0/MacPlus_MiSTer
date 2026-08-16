`timescale 1ns/1ps
//
// Phase 4 regression: prove floppy_sd_writer.v's sd_buff_din byte swap and
// floppy_loader.v's existing sd_buff_dout byte swap are genuine inverses of
// each other, by driving BOTH real RTL modules back-to-back through a
// mocked hps_io rather than trusting the algebra.
//
// floppy_sd_writer commits one sector (internal SDRAM word convention -
// even source byte in the high half, see floppy_write_committer.v) and its
// sd_buff_din stream is captured into `file_mem`, exactly as hps_io would
// write it byte-for-byte to the .dsk. floppy_loader then mounts that same
// sector and its sd_buff_dout is served from `file_mem`, exactly as hps_io
// would read it back - proving the two independently-written swaps
// (`{lo,hi}` on the way out, `{lo,hi}` on the way back in) round-trip the
// original word, not just that each one looks locally plausible.
//
// This is the harness referenced in the Phase 4 code review - previously
// scratchpad-only and not kept; landed here permanently per that review.
module tb_loader_writer_roundtrip;

   reg clk = 0;
   always #5 clk = ~clk;

   reg reset = 1;
   task do_reset;
      begin
         reset = 1'b1;
         @(posedge clk);
         @(negedge clk); // deassert on negedge, not posedge - see FLOPPY_WRITE_PLAN.md Phase 0 lesson 1
         reset = 1'b0;
         #1;
      end
   endtask

   // ---------------------------------------------------------------
   // DUT 1: floppy_sd_writer - commits one sector, we mock hps_io's
   // write side and capture the raw wire bytes into file_mem.
   // ---------------------------------------------------------------
   reg         img_mounted_w = 1'b0;
   reg         commit_done = 1'b0;
   reg  [21:0] commit_addr = 22'd0;
   reg         commit_buf_wr = 1'b0;
   reg  [7:0]  commit_buf_addr = 8'd0;
   reg  [15:0] commit_buf_data = 16'd0;

   wire [31:0] w_sd_lba;
   wire        w_sd_wr;
   reg         w_sd_ack = 1'b0;
   reg  [7:0]  w_sd_buff_addr = 8'd0;
   wire [15:0] w_sd_buff_din;

   floppy_sd_writer wr (
      .clk(clk),
      .reset(reset),

      .img_mounted(img_mounted_w),

      .commit_done(commit_done),
      .commit_addr(commit_addr),
      .commit_buf_wr(commit_buf_wr),
      .commit_buf_addr(commit_buf_addr),
      .commit_buf_data(commit_buf_data),

      .readonly(1'b0),
      .loader_busy(1'b0),
      .size_blocks(13'd1600),

      .sd_lba(w_sd_lba),
      .sd_wr(w_sd_wr),
      .sd_ack(w_sd_ack),

      .sd_buff_addr(w_sd_buff_addr),
      .sd_buff_din(w_sd_buff_din),

      .busy()
   );

   // ---------------------------------------------------------------
   // DUT 2: floppy_loader - mounts the same one-sector image, we mock
   // hps_io's read side serving file_mem back, and mock the shared
   // extra-slot-3 SDRAM write port to capture what it drains out.
   // ---------------------------------------------------------------
   reg         img_mounted_r = 1'b0;
   reg  [63:0] img_size = 64'd512; // exactly one sector -> nsect=1
   reg         img_readonly = 1'b0;

   wire [31:0] r_sd_lba;
   wire        r_sd_rd;
   reg         r_sd_ack = 1'b0;
   reg  [7:0]  r_sd_buff_addr = 8'd0;
   reg  [15:0] r_sd_buff_dout = 16'd0;
   reg         r_sd_buff_wr = 1'b0;

   wire [21:0] r_wr_addr;
   wire [15:0] r_wr_data;
   wire        r_wr_req;
   reg         r_wr_ack = 1'b0;

   wire        ldr_done;

   floppy_loader ldr (
      .clk_sys(clk),
      .reset(reset),

      .img_mounted(img_mounted_r),
      .img_size(img_size),
      .img_readonly(img_readonly),

      .sd_lba(r_sd_lba),
      .sd_rd(r_sd_rd),
      .sd_ack(r_sd_ack),

      .sd_buff_addr(r_sd_buff_addr),
      .sd_buff_dout(r_sd_buff_dout),
      .sd_buff_wr(r_sd_buff_wr),

      .wr_addr(r_wr_addr),
      .wr_data(r_wr_data),
      .wr_req(r_wr_req),
      .wr_ack(r_wr_ack),

      .done(ldr_done),
      .loaded_size(),
      .readonly_latched(),
      .busy()
   );

   // mock SDRAM write port for the loader's drain (extra-slot-3 grant),
   // copied from tb_floppy_loader.v's proven idiom: one-cycle-per-request
   // ack with a couple of idle "arbitration" cycles between grants.
   reg [15:0] recovered_mem [0:255];
   reg [1:0]  grant_wait;
   always @(posedge clk) begin
      r_wr_ack <= 1'b0;
      if (r_wr_req && !r_wr_ack) begin
         if (grant_wait != 0) grant_wait <= grant_wait - 1'd1;
         else begin
            r_wr_ack <= 1'b1;
            recovered_mem[r_wr_addr[8:1]] <= r_wr_data;
            grant_wait <= 2'd2;
         end
      end
      else if (!r_wr_req) grant_wait <= 2'd2;
   end

   reg [15:0] file_mem [0:255];

   // mock hps_io's read-side service of the loader's sd_rd, copied from
   // tb_floppy_loader.v's own proven M_IDLE/M_ACKWAIT/M_STREAM/M_DROP
   // idiom (a clocked FSM, not a blocking-assignment testbench loop) -
   // an earlier draft of this file drove sd_buff_addr/dout with a
   // sequential loop timed off the sd_ack-rising edge, which is actually
   // still SD_WAIT_ACK in the DUT for that whole cycle; SD_WAIT_DONE (the
   // state that samples sd_buff_wr/dout) only becomes active the cycle
   // after, silently dropping the first word. Reusing the FSM form here
   // sidesteps that whole class of off-by-one instead of re-deriving it.
   reg [8:0] read_word_i;
   reg [2:0] read_state = 0; // must init - an uninitialized case selector never matches any branch
   localparam RM_IDLE=0, RM_ACKWAIT=1, RM_STREAM=2, RM_DROP=3;
   always @(posedge clk) begin
      r_sd_buff_wr <= 1'b0;
      case (read_state)
      RM_IDLE: if (r_sd_rd) read_state <= RM_ACKWAIT;
      RM_ACKWAIT: begin
         r_sd_ack    <= 1'b1;
         read_word_i <= 0;
         read_state  <= RM_STREAM;
      end
      RM_STREAM: begin
         r_sd_buff_addr <= read_word_i[7:0];
         r_sd_buff_dout <= file_mem[read_word_i[7:0]];
         r_sd_buff_wr   <= 1'b1;
         if (read_word_i == 9'd255) read_state <= RM_DROP;
         else read_word_i <= read_word_i + 9'd1;
      end
      RM_DROP: begin
         r_sd_ack   <= 1'b0;
         read_state <= RM_IDLE;
      end
      endcase
   end

   integer i, mismatches;
   reg [15:0] expect_word;

   initial begin
      do_reset;

      // ---- feed one sector of distinguishable-nibble-order data into the
      // writer: hi byte counts up, lo byte is its bitwise complement, so a
      // stuck (un-swapped) or double-swapped word can never accidentally
      // match.
      commit_addr = 22'd0; // byte offset 0 -> LBA 0
      for (i = 0; i < 256; i = i + 1) begin
         @(posedge clk); #1;
         commit_buf_addr = i[7:0];
         commit_buf_data = {i[7:0], ~i[7:0]};
         commit_buf_wr   = 1'b1;
      end
      @(posedge clk); #1;
      commit_buf_wr = 1'b0;
      commit_done   = 1'b1;
      @(posedge clk); #1;
      commit_done = 1'b0;

      // ---- mock hps_io's write-side service of the writer's sd_wr.
      wait (w_sd_wr);
      if (w_sd_lba !== 32'd0) begin
         $display("FAIL: writer requested LBA %0d, expected 0", w_sd_lba);
         $finish;
      end
      repeat (3) @(posedge clk); #1;
      w_sd_ack = 1'b1;
      w_sd_buff_addr = 8'd0;
      @(posedge clk); #1; // let mem0_do/mem1_do register address 0's word
      for (i = 0; i < 256; i = i + 1) begin
         file_mem[i] = w_sd_buff_din; // raw wire bytes, as hps_io would store them
         if (i < 255) w_sd_buff_addr = w_sd_buff_addr + 1'b1;
         @(posedge clk); #1;
      end
      w_sd_ack = 1'b0;

      // ---- mount the loader against that same one-sector "file"; the
      // RM_* FSM above handles hps_io's read-side service of its sd_rd.
      img_mounted_r = 1'b1;
      @(posedge clk); #1;
      img_mounted_r = 1'b0;

      wait (r_sd_rd);
      if (r_sd_lba !== 32'd0) begin
         $display("FAIL: loader requested LBA %0d, expected 0", r_sd_lba);
         $finish;
      end

      wait (ldr_done);
      @(posedge clk); #1;

      mismatches = 0;
      for (i = 0; i < 256; i = i + 1) begin
         expect_word = {i[7:0], ~i[7:0]};
         if (recovered_mem[i] !== expect_word) begin
            mismatches = mismatches + 1;
            if (mismatches <= 5)
               $display("  mismatch word %0d: expected %h got %h", i, expect_word, recovered_mem[i]);
         end
      end

      if (mismatches == 0)
         $display("PASS: loader<->writer round trip recovered all 256 words byte-exact");
      else
         $display("FAIL: %0d/256 words did not round-trip", mismatches);

      $display("");
      $display("%s", (mismatches == 0) ? "PHASE 4 ROUND-TRIP GATE: PASS" : "PHASE 4 ROUND-TRIP GATE: FAIL");
      $finish;
   end

endmodule
