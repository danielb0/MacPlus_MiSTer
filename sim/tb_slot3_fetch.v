`timescale 1ns/1ps
//
// Phase 8 of FLOPPY_WRITE_PLAN.md, the seam: the REAL addrController_top.v
// with its extra-slot-3 write AND read requesters, the REAL
// floppy_write_committer.v landing one sector while the REAL
// floppy_sd_writer.v fetches the previous one back out through the same
// slot, against an SDRAM model with sdram.v's two-phase sampling - RAS
// from the values in busPhase 0, CAS from busPhase 1, and (new here) the
// read word captured at the end of busPhase 2, which is where sdram.v's
// STATE_READ puts it in dout.
//
// What this proves that tb_floppy_sd_writer.v cannot: that the fetch
// requester's ack and its data agree in PHASE against the real arbiter
// and the real controller timing, that the two requesters share the slot
// without either losing a word (the committer has priority; the fetch
// waits), and that the address the arbiter presents for a fetch is the
// image's byte offset plus the int image's base - i.e. the word the
// committer wrote comes back, not a neighbour.
//
// CPU/video ports are tied off quiescent as in tb_floppy_loader_integrated.v.
module tb_slot3_fetch;

   reg clk = 0;
   always #5 clk = ~clk;

   reg reset = 1;

   localparam NSECT = 8;                   // a tiny image: 8 sectors
   localparam IMG_WORDS = NSECT * 256;
   localparam [22:0] IMG_BASE = 23'h280000; // word address of the int floppy image

   // ---- addrController_top, CPU/video side quiescent ----
   wire [21:0] memoryAddr;
   wire        dskReadAckInt, dskReadAckExt;
   wire        dskLoadAckInt, dskLoadAckExt, dskLoadWrEn, dskLoadSelExt;
   wire        dskFetchAckInt, dskFetchAckExt, dskLoadRdEn;

   wire [21:0] wc_wr_addr;
   wire [15:0] wc_wr_data;
   wire        wc_wr_req;
   wire [21:0] fetch_addr;
   wire        fetch_req;

   addrController_top ac0 (
      .clk(clk),
      .clk8(), .clk8_en_p(), .clk8_en_n(), .clk16_en_p(), .clk16_en_n(),
      .turbo(1'b0),
      .configROMSize(2'b01),
      .scsiPresent(1'b1),
      .configRAMSize(2'b10),
      .cpuAddr(24'd0),
      ._cpuUDS(1'b1), ._cpuLDS(1'b1), ._cpuRW(1'b1), ._cpuAS(1'b1),
      .memoryAddr(memoryAddr),
      .memoryLatch(), ._memoryUDS(), ._memoryLDS(),
      ._romOE(), ._ramOE(), ._ramWE(),
      .videoBusControl(), .dioBusControl(), .cpuBusControl(),
      .selectSCSI(), .selectSCC(), .selectIWM(), .selectVIA(), .selectRAM(), .selectROM(), .selectSEOverlay(),
      .hsync(), .vsync(), ._hblank(), ._vblank(), .loadPixels(),
      .vid_alt(1'b0),
      .snd_alt(1'b0), .loadSound(), .snd_advance(),
      .memoryOverlayOn(1'b0),
      .dskReadAddrInt(22'd0), .dskReadAckInt(dskReadAckInt),
      .dskReadAddrExt(22'd0), .dskReadAckExt(dskReadAckExt),
      // the committer alone on the int write request (no loader in this bench)
      .dskLoadAddrInt(wc_wr_addr), .dskLoadReqInt(wc_wr_req), .dskLoadAckInt(dskLoadAckInt),
      .dskLoadAddrExt(22'd0),      .dskLoadReqExt(1'b0),      .dskLoadAckExt(dskLoadAckExt),
      .dskLoadWrEn(dskLoadWrEn),
      .dskLoadSelExt(dskLoadSelExt),
      .dskFetchAddrInt(fetch_addr), .dskFetchReqInt(fetch_req), .dskFetchAckInt(dskFetchAckInt),
      .dskFetchAddrExt(22'd0),      .dskFetchReqExt(1'b0),      .dskFetchAckExt(dskFetchAckExt),
      .dskLoadRdEn(dskLoadRdEn)
   );

   // ---- SDRAM model: sdram.v's two-phase sampling, plus the read -------
   // exactly MacPlus.sv's muxes
   wire        dsk_cycle  = dskReadAckInt || dskReadAckExt || dskLoadWrEn || dskLoadRdEn;
   wire [24:0] sdram_addr = {3'b000, dsk_cycle, memoryAddr[21:1]};
   wire [15:0] sdram_din  = dskLoadWrEn ? wc_wr_data : 16'hBAD1;
   wire        sdram_we   = dskLoadWrEn;
   wire        sdram_oe   = dskReadAckInt || dskReadAckExt || dskLoadRdEn;

   reg         we_latch = 0, oe_latch = 0, fetch_latch = 0;
   reg  [23:0] ras_addr = 0;
   reg  [22:0] rd_addr  = 0;
   reg  [15:0] sdram_out = 0;
   wire [22:0] eff_addr = {sdram_addr[22], ras_addr[21:8], sdram_addr[7:0]};

   reg [15:0] mock_sdram [0:IMG_WORDS-1];
   integer stray_writes = 0, stray_reads = 0;
   integer both = 0;

   always @(posedge clk) begin
      if (ac0.busPhase == 2'b00) begin      // RAS: row/bank + the oe/we decision
         we_latch <= sdram_we;
         oe_latch <= sdram_oe;
         fetch_latch <= dskLoadRdEn;        // a fetch, as opposed to an IWM read window
         ras_addr <= sdram_addr[23:0];
      end
      if (ac0.busPhase == 2'b01) begin      // CAS: column (+ data for a write)
         if (we_latch) begin
            if (eff_addr >= IMG_BASE && eff_addr < IMG_BASE + IMG_WORDS)
               mock_sdram[eff_addr - IMG_BASE] <= sdram_din;
            else
               stray_writes = stray_writes + 1;
         end
         rd_addr <= eff_addr;
      end
      if (ac0.busPhase == 2'b10 && oe_latch) begin   // STATE_READ: dout lands
         if (rd_addr >= IMG_BASE && rd_addr < IMG_BASE + IMG_WORDS)
            sdram_out <= mock_sdram[rd_addr - IMG_BASE];
         else begin
            // the IWM read windows (extra slots 0/1) read address 0 in
            // this bench; only a FETCH outside the image is a defect
            if (fetch_latch) stray_reads = stray_reads + 1;
            sdram_out <= 16'hDEAD;
         end
      end
      if (dskLoadWrEn && dskLoadRdEn) both = both + 1;
   end

   // ---- the committer, fed by a mock decoder buffer (registered read) ----
   reg         sector_valid = 0;
   reg  [21:0] sector_addr  = 0;
   wire  [8:0] buf_addr;
   reg   [7:0] buf_data;
   reg   [7:0] dec_mem [0:511];
   always @(posedge clk) buf_data <= dec_mem[buf_addr];

   wire        wc_busy, wc_done;
   wire [21:0] wc_committed_addr;

   floppy_write_committer wc (
      .clk(clk), .rst(reset),
      .sector_valid(sector_valid), .sector_addr(sector_addr),
      .buf_addr(buf_addr), .buf_data(buf_data),
      .wr_addr(wc_wr_addr), .wr_data(wc_wr_data), .wr_req(wc_wr_req), .wr_ack(dskLoadAckInt),
      .busy(wc_busy), .done(wc_done), .committed_addr(wc_committed_addr)
   );

   // ---- the writer, fetching through the same slot ------------------------
   wire [31:0] sd_lba;
   wire        sd_wr;
   reg         sd_ack = 0;
   reg   [7:0] sd_buff_addr = 0;
   wire [15:0] sd_buff_din;
   wire        busy;
   wire [31:0] dbg;

   floppy_sd_writer wr (
      .clk(clk), .reset(reset),
      .img_mounted(1'b0),
      .commit_done(wc_done), .commit_addr(wc_committed_addr),
      .readonly(1'b0), .loader_busy(1'b0),
      .size_blocks(NSECT[12:0]),
      .fetch_addr(fetch_addr), .fetch_req(fetch_req),
      .fetch_ack(dskFetchAckInt), .fetch_data(sdram_out),
      .sd_lba(sd_lba), .sd_wr(sd_wr), .sd_ack(sd_ack),
      .sd_buff_addr(sd_buff_addr), .sd_buff_din(sd_buff_din),
      .busy(busy), .dbg(dbg)
   );

   integer wc_acks = 0, fetch_acks = 0;
   always @(posedge clk) begin
      if (dskLoadAckInt)  wc_acks    = wc_acks + 1;
      if (dskFetchAckInt) fetch_acks = fetch_acks + 1;
   end

   integer checks = 0, fails = 0;
   task check(input cond, input [639:0] what);
      begin
         checks = checks + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

   // sector s byte b, as the decoder would have recovered it
   function [7:0] pat(input integer s, input integer b);
      pat = (b * 8'd137 + s * 8'd29 + 8'd41) & 8'hFF;
   endfunction

   task commit_sector(input integer s);
      integer b;
      begin
         for (b = 0; b < 512; b = b + 1) dec_mem[b] = pat(s, b);
         @(posedge clk); #1;
         sector_addr  = s * 512;
         sector_valid = 1'b1;
         @(posedge clk); #1;
         sector_valid = 1'b0;
      end
   endtask

   // serve the presented block and check every word against the pattern:
   // the committer packs {even, odd}; the wire carries {odd, even}
   task serve_block(input integer s);
      integer i;
      begin
         @(posedge clk); #1;
         sd_ack = 1'b1;
         for (i = 0; i < 256; i = i + 1) begin
            sd_buff_addr = i[7:0];
            @(posedge clk); #1;
            check(sd_buff_din === {pat(s, 2*i+1), pat(s, 2*i)},
                  "the block hps_io receives is the sector the committer landed, in wire order");
         end
         sd_ack = 1'b0;
         repeat (4) @(posedge clk); #1;
      end
   endtask

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

   integer i, s, wrong;
   reg got;

   initial begin
      for (i = 0; i < IMG_WORDS; i = i + 1) mock_sdram[i] = 16'h0000;

      // power-up state for the arbiter's free-running counters (Icarus
      // leaves them X otherwise) - as tb_floppy_loader_integrated.v does
      force ac0.busPhase = 2'b00;
      force ac0.busCycle = 2'b00;
      force ac0.extra_slot_count = 2'b00;
      @(posedge clk);
      release ac0.busPhase;
      release ac0.busCycle;
      release ac0.extra_slot_count;
      @(posedge clk); @(negedge clk);
      reset = 0;
      #1;

      // ─── 1. one sector: commit lands it, the writer fetches it back ───
      $display("1. sector 5 committed through the real arbiter, fetched back through it");
      commit_sector(5);
      wait (wc_done);                      // the writer queues it here
      wait_wr(200000, got);
      check(got && sd_lba === 32'd5, "the writer presents sector 5");
      check(fetch_acks == 256, "256 fetch acks for one block");
      check(wc_acks == 256,    "256 committer acks for one sector");
      serve_block(5);
      check(!busy, "drained");
      check(both == 0, "the arbiter never granted a read and a write in the same cycle");

      // ─── 2. the overlap: the writer fetches 6 while the committer lands 7
      $display("2. commit 6, then commit 7 while 6 is being fetched: both requesters on the slot");
      commit_sector(6);
      wait (wc_done);
      wait (fetch_req);                    // the fetch of 6 has begun
      commit_sector(7);                    // the committer now contends for the slot
      wait_wr(400000, got);
      check(got && sd_lba === 32'd6, "sector 6 is presented");
      serve_block(6);                      // every word must be 6's, not 7's
      wait (!wc_busy);
      wait_wr(400000, got);
      check(got && sd_lba === 32'd7, "then sector 7");
      serve_block(7);
      check(!busy, "drained");
      check(fetch_acks == 3 * 256, "every fetch got exactly its 256 words");
      check(wc_acks == 3 * 256,    "every commit got exactly its 256 words - none stolen by the fetch");
      check(both == 0, "still never both grants in one cycle");

      // ─── 3. SDRAM itself holds every committed sector, byte-exact ─────
      $display("3. the image in SDRAM");
      wrong = 0;
      for (s = 5; s <= 7; s = s + 1)
         for (i = 0; i < 256; i = i + 1)
            if (mock_sdram[s*256 + i] !== {pat(s, 2*i), pat(s, 2*i+1)}) wrong = wrong + 1;
      check(wrong == 0, "sectors 5..7 are in SDRAM exactly as committed");
      check(stray_writes == 0, "no write landed outside the image");
      check(stray_reads == 0,  "no fetch read outside the image");
      check(dbg[31:16] === 16'd0, "no refusal of any kind");
      check(dbg[15:8] === 8'd3, "three blocks landed");

      $display("");
      $display("tb_slot3_fetch: %0d checks, %0d failures", checks, fails);
      $display("%s", (fails == 0) ? "PHASE 8 SLOT-3 SEAM GATE: PASS" : "PHASE 8 SLOT-3 SEAM GATE: FAIL");
      $finish;
   end

   initial begin
      #200_000_000;
      $display("tb_slot3_fetch: TIMEOUT (wc.state=%0d wr.pstate=%0d fetch_req=%b wc_req=%b acks wc=%0d fetch=%0d)",
               wc.state, dbg[2:0], fetch_req, wc_wr_req, wc_acks, fetch_acks);
      $display("PHASE 8 SLOT-3 SEAM GATE: FAIL");
      $finish;
   end

endmodule
