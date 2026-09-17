`timescale 1ns/1ps
//
// Phase 8 of FLOPPY_WRITE_PLAN.md: floppy_sd_writer.v in isolation - the
// sector-number queue, the SDRAM fetch through the extra-slot-3 read
// protocol, the hps_io sd_wr/sd_ack/sd_buff_addr handshake, and every path
// that must REFUSE to write. This is the only module in the floppy write
// chain that can damage the user's file, and every defect class below
// writes a well-formed block at a plausible offset - the kind a "does it
// still boot" check never catches.
//
// The slot-3 model is addrController_top.v's protocol at clk_sys
// resolution: requests sampled at the bus-cycle boundary (every 4th
// clock), one grant per 16 bus cycles (the slot recurs every 16 clk8), the
// word read at the end of the grant's phase 2 (sdram.v's STATE_READ), the
// ack a one-clock pulse in its phase 3. Any fetch address outside the
// image, or not word-aligned, FAILS the run: a wrong-address fetch is this
// design's version of the wrong-LBA bug.
//
// The byte order is the headline check (section 1): SDRAM words are in the
// internal even-byte-high convention and hps_io's wire word is the
// opposite, so the writer's output swap must mirror floppy_loader.v's
// input swap or every byte pair on the card is transposed - an image that
// still mounts and is quietly wrong. Section 8 is the scenario that broke
// the depth-2 writer this module replaced (three commits during one SD
// stall); sections 9 and 10 are the new design's own claims (a sector re-
// committed while queued is written twice with the NEWEST data; a full
// queue refuses and counts, never overwrites). Section 3 is the refuse-
// then-two-more sequence the LC's version got wrong (the plan has it).
//
// ACK_TIMEOUT_BITS is 8 here so the re-presentation is reachable; the
// shipping default (24) is ~0.5 s. QDEPTH_BITS is 3 (8 entries) so the
// full-queue case is reachable; shipping depth is 1024.
//
// Stimulus changes at #1 past the edge throughout (the @(posedge clk); #1;
// idiom - see the plan's Phase 4 notes on the zero-delay race).
module tb_floppy_sd_writer;

   reg clk = 0;
   always #5 clk = ~clk;

   localparam IMG_BLOCKS = 1600;               // an 800K image
   localparam IMG_WORDS  = IMG_BLOCKS * 256;

   reg         reset       = 1'b1;
   reg         img_mounted = 1'b0;
   reg         commit_done = 1'b0;
   reg  [21:0] commit_addr = 22'd0;
   reg         readonly    = 1'b0;
   reg         loader_busy = 1'b0;
   reg  [12:0] size_blocks = IMG_BLOCKS;

   wire [21:0] fetch_addr;
   wire        fetch_req;
   wire        fetch_ack;
   reg  [15:0] fetch_data = 16'd0;

   wire [31:0] sd_lba;
   wire        sd_wr;
   reg         sd_ack = 1'b0;
   reg   [7:0] sd_buff_addr = 8'd0;
   wire [15:0] sd_buff_din;
   wire        busy;
   wire [31:0] dbg;

   floppy_sd_writer #(.ACK_TIMEOUT_BITS(8), .QDEPTH_BITS(3)) dut
   (
      .clk(clk), .reset(reset),
      .img_mounted(img_mounted),
      .commit_done(commit_done), .commit_addr(commit_addr),
      .readonly(readonly), .loader_busy(loader_busy),
      .size_blocks(size_blocks),
      .fetch_addr(fetch_addr), .fetch_req(fetch_req),
      .fetch_ack(fetch_ack), .fetch_data(fetch_data),
      .sd_lba(sd_lba), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_addr(sd_buff_addr), .sd_buff_din(sd_buff_din),
      .busy(busy), .dbg(dbg)
   );

   integer checks = 0;
   integer fails  = 0;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin
            fails = fails + 1;
            $display("  FAIL: %0s", what);
         end
      end
   endtask

   // ---- the extra-slot-3 model (see header) ----------------------------
   reg [15:0] sdram [0:IMG_WORDS-1];
   reg  [5:0] slot = 6'd0;      // [1:0] busPhase, [5:2] which bus cycle of 16
   always @(posedge clk) slot <= slot + 6'd1;
   reg        req_r = 1'b0;     // the request as sampled at the boundary
   always @(posedge clk) if (slot[1:0] == 2'd3) req_r <= fetch_req;
   wire       grant = (slot[5:2] == 4'd15) && req_r;
   integer    bad_addr = 0;
   integer    fetches  = 0;
   always @(posedge clk) if (grant && slot[1:0] == 2'd2) begin
      if (fetch_addr[0] || (fetch_addr[21:1] >= IMG_WORDS)) begin
         bad_addr = bad_addr + 1;
         fetch_data <= 16'hDEAD;
      end else
         fetch_data <= sdram[fetch_addr[21:1]];
      fetches = fetches + 1;
   end
   assign fetch_ack = grant && (slot[1:0] == 2'd3);

   // sector s of the image = words s*256 .. s*256+255, filled from a seed
   task fill_sector(input [12:0] s, input [15:0] seed);
      integer i;
      begin
         for (i = 0; i < 256; i = i + 1) sdram[s*256 + i] = seed + i[15:0];
      end
   endtask

   task pulse_commit(input [12:0] sector);
      begin
         @(posedge clk); #1;
         commit_addr = {sector, 9'd0};
         commit_done = 1'b1;
         @(posedge clk); #1;
         commit_done = 1'b0;
      end
   endtask

   // Answer the presented write the way hps_io does: raise sd_ack, walk
   // sd_buff_addr over the block while it is high, then drop it. Every word
   // is checked against what SDRAM holds NOW, in hps_io's byte order.
   task serve_block(input [12:0] blk);
      integer i;
      reg [15:0] w;
      begin
         @(posedge clk); #1;
         sd_ack = 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            sd_buff_addr = i[7:0];
            @(posedge clk); #1;          // the module's read is registered
            w = sdram[blk*256 + i];
            check(sd_buff_din === {w[7:0], w[15:8]},
                  "block word must be the SDRAM word in hps_io byte order");
         end
         sd_ack = 1'b0;
         // P_WAIT_DONE must SEE the ack fall before it retires the block
         repeat (4) @(posedge clk); #1;
      end
   endtask

   // a loader-style ack on the shared slot after a remount: data flows IN
   // and the writer must ignore it entirely
   task loader_ack;
      integer i;
      begin
         @(posedge clk); #1; sd_ack = 1'b1;
         for (i = 0; i < 256; i = i + 1) begin sd_buff_addr = i[7:0]; @(posedge clk); #1; end
         sd_ack = 1'b0; repeat (4) @(posedge clk); #1;
      end
   endtask

   // hps_io streaming SLOWLY - slower than a whole block fetch - with the
   // ack held high throughout. A writer that retired the block on the ack's
   // RISE rather than its fall would start fetching the next sector into
   // the buffer under the stream; the ordinary serve_block streams too fast
   // to see that. Every word read late must still be this block's, and no
   // sd_wr may rise while the ack is up (wr_rise_in_ack, below).
   task serve_block_slowly(input [12:0] blk);
      integer i;
      reg [15:0] w;
      begin
         @(posedge clk); #1;
         sd_ack = 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            sd_buff_addr = i[7:0];
            repeat (100) @(posedge clk); #1;
            w = sdram[blk*256 + i];
            check(sd_buff_din === {w[7:0], w[15:8]},
                  "a word read late in a slow stream must still be this block's");
         end
         sd_ack = 1'b0;
         repeat (4) @(posedge clk); #1;
      end
   endtask

   // sd_wr rising while sd_ack is high: the handshake broken from our side
   integer wr_rise_in_ack = 0;
   reg     sd_wr_d = 1'b0;
   always @(posedge clk) begin
      sd_wr_d <= sd_wr;
      if (sd_wr && !sd_wr_d && sd_ack) wr_rise_in_ack = wr_rise_in_ack + 1;
   end

   task wait_wr(input integer limit, output ok);
      integer n;
      begin
         n = 0; ok = 0;
         while (n < limit && !ok) begin
            @(posedge clk); #1;
            if (sd_wr) ok = 1;
            n = n + 1;
         end
      end
   endtask

   // a whole block takes 256 grants of 64 clocks
   localparam BLK = 256 * 64 + 400;

   integer i;
   reg     got;
   reg [31:0] lba_first;
   integer f0;

   initial begin
      for (i = 0; i < IMG_WORDS; i = i + 1) sdram[i] = 16'h0000;
      repeat (4) @(posedge clk); #1;
      reset = 1'b0;
      repeat (4) @(posedge clk); #1;

      // ─── 1. the happy path, and the byte order ──────────────────────────
      $display("1. commit -> fetch from SDRAM -> sd_wr at the right LBA, bytes in hps_io order");
      fill_sector(13'd7, 16'h1000);
      f0 = fetches;
      pulse_commit(13'd7);
      wait_wr(BLK, got);
      check(got, "sd_wr must be asserted after a commit");
      check(sd_lba === 32'd7, "sd_lba must be the sector number");
      check(fetches - f0 == 256, "exactly one block's worth of words was fetched");
      serve_block(13'd7);
      check(!busy, "busy must fall once the block has drained");
      check(bad_addr == 0, "every SDRAM address was inside the image and word-aligned");

      // ─── 2. read-only: nothing may reach the card ───────────────────────
      $display("2. a read-only drive refuses the sector outright");
      readonly = 1'b1;
      fill_sector(13'd9, 16'h2000);
      f0 = fetches;
      pulse_commit(13'd9);
      wait_wr(2000, got);
      check(!got, "a commit on a read-only drive must never raise sd_wr");
      check(!busy, "and must not leave the queue busy");
      check(fetches == f0, "and must not fetch anything");
      readonly = 1'b0;

      // ─── 3. past the end of the image: refuse, do not wrap ─────────────
      $display("3. a block at or past size_blocks is retired unwritten, and the ones behind it still land");
      pulse_commit(13'd1600);              // == size_blocks
      wait_wr(2000, got);
      check(!got, "an out-of-range block must not be written");
      check(!busy, "and must be retired rather than left queued");
      check(dbg[23:16] === 8'd1, "the refusal is counted");
      // refuse-then-two-more: the entry behind a refused one must not be
      // judged as the refused one, and the one behind THAT must not vanish
      loader_busy = 1'b1;
      fill_sector(13'd21, 16'h3100);
      fill_sector(13'd22, 16'h3200);
      pulse_commit(13'd1601);
      pulse_commit(13'd21);
      pulse_commit(13'd22);
      loader_busy = 1'b0;
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd21, "the first in-range sector behind the refused one is written");
      serve_block(13'd21);
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd22, "and so is the one behind it");
      serve_block(13'd22);
      check(!busy, "queue empty");
      check(dbg[23:16] === 8'd2, "exactly one more refusal was counted, not two");

      // ─── 4. a remount drops what was queued against the old image ──────
      $display("4. img_mounted drops the queued sector");
      loader_busy = 1'b1;                  // hold it in the queue
      fill_sector(13'd11, 16'h4000);
      pulse_commit(13'd11);
      repeat (4) @(posedge clk); #1;
      check(busy, "the sector is queued while the loader owns the slot");
      img_mounted = 1'b1; @(posedge clk); #1; img_mounted = 1'b0;
      loader_busy = 1'b0;
      wait_wr(2000, got);
      check(!got, "a sector captured before a remount must never be written");
      check(!busy, "and the queue must be empty again");

      // ─── 5. ack timeout re-presents the SAME block ──────────────────────
      $display("5. an ack timeout re-presents the same block, never retires it");
      fill_sector(13'd13, 16'h5000);
      pulse_commit(13'd13);
      wait_wr(BLK, got);
      check(got, "first presentation");
      lba_first = sd_lba;
      @(negedge sd_wr);                    // the timeout drops it...
      wait_wr(10, got);                    // ...and it comes straight back
      check(got, "the request must be presented again after the timeout");
      check(sd_lba === lba_first, "the re-presented LBA must be unchanged");
      check(busy, "busy must stay high while a write is still owed");
      serve_block(13'd13);                 // the same data, from the same buffer
      check(!busy, "and clears once the late ack is finally served");

      // ─── 6. queued sectors drain in commit order ────────────────────────
      $display("6. queued sectors drain in commit order");
      loader_busy = 1'b1;
      fill_sector(13'd31, 16'h6000);
      fill_sector(13'd32, 16'h7000);
      pulse_commit(13'd31);
      pulse_commit(13'd32);
      loader_busy = 1'b0;
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd31, "the first committed sector goes first");
      serve_block(13'd31);
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd32, "then the second");
      serve_block(13'd32);
      check(!busy, "both drained");

      // ─── 7. a remount in the middle of a fetch aborts it ───────────────
      $display("7. img_mounted mid-fetch: idle, request down, the slot's stale grant harmless");
      fill_sector(13'd6, 16'h0D00);
      pulse_commit(13'd6);
      wait (fetch_req);                    // the fetch has started
      wait (req_r);                        // and the slot has SAMPLED it
      @(posedge clk); #1;
      img_mounted = 1'b1; loader_busy = 1'b1;
      @(posedge clk); #1;
      img_mounted = 1'b0;
      @(posedge clk); #1;
      check(!fetch_req && !sd_wr, "both request lines drop at the mount pulse");
      check(!busy, "and the writer is idle, queue dropped");
      repeat (70) @(posedge clk); #1;      // the sampled request is granted anyway...
      check(!busy && !fetch_req && dbg[2:0] === 3'd0, "...and its ack changes nothing");
      loader_ack;                          // the loader's first block on the shared slot
      wait_wr(2000, got);
      check(!got, "no sd_wr may follow the loader's ack");
      loader_busy = 1'b0;
      fill_sector(13'd8, 16'h0E00);        // the next sector is clean
      f0 = fetches;
      pulse_commit(13'd8);
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd8, "the next sector after the abort is written");
      check(fetches - f0 == 256, "from a fetch that started at word 0");
      serve_block(13'd8);
      check(!busy, "done");

      // ─── 8. three commits during one stall: the depth-2 writer's defect ─
      $display("8. three commits during one SD stall all land intact and in order");
      fill_sector(13'd40, 16'h1000);
      fill_sector(13'd41, 16'h2000);
      fill_sector(13'd42, 16'h3000);
      pulse_commit(13'd40);
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd40, "A is presented and left waiting");
      pulse_commit(13'd41);                // B, while A waits
      pulse_commit(13'd42);                // C, while A still waits
      serve_block(13'd40);                 // hps_io wakes up: A must be A
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd41, "then B");
      serve_block(13'd41);
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd42, "then C - nothing torn, nothing lost");
      serve_block(13'd42);
      check(!busy, "queue empty");

      // ─── 9. re-committed while queued: written twice, newest data both times
      $display("9. a sector re-committed while queued is written twice from live SDRAM");
      loader_busy = 1'b1;
      fill_sector(13'd50, 16'h4000);
      pulse_commit(13'd50);
      fill_sector(13'd50, 16'h4100);       // the guest rewrote it before it drained
      pulse_commit(13'd50);
      loader_busy = 1'b0;
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd50, "first write of sector 50");
      serve_block(13'd50);                 // expects the CURRENT contents (seed 4100)
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd50, "second write of sector 50");
      serve_block(13'd50);
      check(!busy, "queue empty");

      // ─── 10. queue full: refuse and raise the witness, never overwrite ──
      $display("10. a full queue refuses the commit and raises the witness");
      loader_busy = 1'b1;
      for (i = 0; i < 9; i = i + 1) begin  // depth is 8 in this bench
         fill_sector(13'd100 + i[12:0], 16'h5000 + i[15:0]);
         pulse_commit(13'd100 + i[12:0]);
      end
      repeat (2) @(posedge clk); #1;
      check(dbg[31:24] === 8'd1, "exactly one commit was refused");
      loader_busy = 1'b0;
      for (i = 0; i < 8; i = i + 1) begin
         wait_wr(BLK, got);
         check(got && sd_lba === 32'd100 + i, "the eight accepted sectors drain in order");
         serve_block(13'd100 + i[12:0]);
      end
      wait_wr(300, got);
      check(!got, "the refused ninth is gone, not smuggled in");
      check(!busy, "queue empty");
      check(dbg[15:8] === 8'd20, "the landed count matches every block served so far");

      // ─── 11. reset after activity ───────────────────────────────────────
      $display("11. a reset mid-fetch returns everything to power-up");
      fill_sector(13'd60, 16'h6000);
      pulse_commit(13'd60);
      wait (fetch_req);
      @(posedge clk); #1;
      reset = 1'b1;
      repeat (2) @(posedge clk); #1;
      reset = 1'b0;
      @(posedge clk); #1;
      check(!busy && !fetch_req && !sd_wr, "idle, both request lines down");
      check(dbg === 32'd0, "every counter and the state are zero");
      fill_sector(13'd61, 16'h6100);
      pulse_commit(13'd61);
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd61, "and the next sector is written normally");
      serve_block(13'd61);
      check(!busy, "done");

      // ─── 12. a slow hps_io stream with the next sector already queued ─
      $display("12. the block stays intact under a slow stream; the next fetch waits for the ack to fall");
      loader_busy = 1'b1;
      fill_sector(13'd70, 16'h7000);
      fill_sector(13'd71, 16'h7100);
      pulse_commit(13'd70);
      pulse_commit(13'd71);
      loader_busy = 1'b0;
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd70, "sector 70 presented");
      serve_block_slowly(13'd70);          // 25,600 cycles under the ack: longer than a fetch
      check(wr_rise_in_ack == 0, "no sd_wr rose while the ack was high");
      wait_wr(BLK, got);
      check(got && sd_lba === 32'd71, "then sector 71");
      serve_block(13'd71);
      check(!busy, "done");
      check(wr_rise_in_ack == 0, "no sd_wr rose while an ack was high anywhere in the run");
      check(bad_addr == 0, "no stray SDRAM address anywhere in the run");

      $display("");
      $display("tb_floppy_sd_writer: %0d checks, %0d failures", checks, fails);
      $display("%s", (fails == 0) ? "PHASE 8 SD-WRITER GATE: PASS" : "PHASE 8 SD-WRITER GATE: FAIL");
      $finish;
   end

   initial begin
      #400_000_000;
      $display("tb_floppy_sd_writer: TIMEOUT (pstate=%0d busy=%b fetch_req=%b sd_wr=%b)", dbg[2:0], busy, fetch_req, sd_wr);
      $display("PHASE 8 SD-WRITER GATE: FAIL");
      $finish;
   end

endmodule
