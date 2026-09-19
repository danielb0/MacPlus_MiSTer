`timescale 1ns/1ps
//
// SOUND_PHASE_PLAN.md: the sound scan's start word and the PSND probe.
//
// The REAL addrController_top.v, CPU/video side quiescent except for the
// bus cycles this bench drives into the sound buffer. For every phase
// setting it checks that one frame is exactly 370 advances, that the word
// sequence is p..369 then 0..p-1, and that audioAddr follows snd_index. Then
// it proves rtl/snd_phase_probe.sv latches the scan word at the first
// buffer write, the word that write hit, and the scan word at the write to
// word 0, and commits them on the frame edge, at 4MB and at 1MB.
//
// Run: iverilog -g2012 -I rtl -y rtl -o sim/out/tb_snd_phase.vvp
//        sim/tb_snd_phase.v rtl/snd_phase_probe.sv && vvp sim/out/tb_snd_phase.vvp
module tb_snd_phase;

   reg clk = 0;
   always #5 clk = ~clk;

   reg  [1:0]  phase = 2'd0;
   reg  [1:0]  ramsize = 2'b11;
   reg  [23:0] cpuAddr = 24'd0;
   reg         _cpuAS = 1, _cpuRW = 1;
   wire [21:0] memoryAddr;
   wire        clk8_en_p, _vblank, snd_advance;
   wire [8:0]  snd_index;

   addrController_top ac0 (
      .clk(clk),
      .clk8(), .clk8_en_p(clk8_en_p), .clk8_en_n(), .clk16_en_p(), .clk16_en_n(),
      .turbo(1'b0),
      .configROMSize(2'b01),
      .scsiPresent(1'b1),
      .configRAMSize(ramsize),
      .cpuAddr(cpuAddr),
      ._cpuUDS(1'b1), ._cpuLDS(1'b1), ._cpuRW(_cpuRW), ._cpuAS(_cpuAS),
      .memoryAddr(memoryAddr),
      .memoryLatch(), ._memoryUDS(), ._memoryLDS(),
      ._romOE(), ._ramOE(), ._ramWE(),
      .videoBusControl(), .dioBusControl(), .cpuBusControl(),
      .selectSCSI(), .selectSCC(), .selectIWM(), .selectVIA(), .selectRAM(), .selectROM(), .selectSEOverlay(),
      .hsync(), .vsync(), ._hblank(), ._vblank(_vblank), .loadPixels(),
      .vid_alt(1'b0),
      .snd_alt(1'b0), .loadSound(), .snd_advance(snd_advance),
      .snd_phase(phase), .snd_index(snd_index),
      .memoryOverlayOn(1'b0),
      .dskReadAddrInt(22'd0), .dskReadAckInt(),
      .dskReadAddrExt(22'd0), .dskReadAckExt(),
      .dskLoadAddrInt(22'd0), .dskLoadReqInt(1'b0), .dskLoadAckInt(),
      .dskLoadAddrExt(22'd0), .dskLoadReqExt(1'b0), .dskLoadAckExt(),
      .dskLoadWrEn(), .dskLoadSelExt(),
      .dskFetchAddrInt(22'd0), .dskFetchReqInt(1'b0), .dskFetchAckInt(),
      .dskFetchAddrExt(22'd0), .dskFetchReqExt(1'b0), .dskFetchAckExt(),
      .dskLoadRdEn()
   );

   wire [31:0] dbg;
   snd_phase_probe probe (
      .clk(clk), .clk8_en_p(clk8_en_p), ._vblank(_vblank), .snd_index(snd_index),
      .cpuAddr(cpuAddr), ._cpuAS(_cpuAS), ._cpuRW(_cpuRW),
      .configRAMSize(ramsize), .dbg(dbg)
   );

   integer fails = 0, tests = 0;
   task check(input cond, input [639:0] what);
      begin
         tests = tests + 1;
         if (!cond) begin fails = fails + 1; $display("FAIL: %0s", what); end
      end
   endtask

   // the vblank falling edge as the scan sees it (sampled on clk8_en_p)
   reg vblankD = 1;
   always @(posedge clk) if (clk8_en_p) vblankD <= _vblank;
   wire frame_edge = clk8_en_p && vblankD && !_vblank;

   task wait_frame_edge;
      begin @(posedge clk); while (!frame_edge) @(posedge clk); end
   endtask

   // ---- one frame of the scan, checked advance by advance ---------------
   integer n, p, expect_w, bad_seq, bad_addr;
   reg [21:0] base;
   task scan_frame(input [1:0] ph);
      begin
         phase = ph;
         p = (ph == 1) ? 20 : (ph == 2) ? 28 : (ph == 3) ? 36 : 0;
         base = 22'h3FFD00;
         wait_frame_edge;          // the frame that first sees this phase
         wait_frame_edge;          // ... and the next, which starts from it
         // this edge's own advance is the first sample of the frame
         @(negedge clk);
         n = 1; bad_seq = 0; bad_addr = 0;
         if (snd_index !== p) bad_seq = bad_seq + 1;
         if (ac0.audioAddr !== base + {p, 1'b0}) bad_addr = bad_addr + 1;
         expect_w = p;
         forever begin
            @(posedge clk);
            if (frame_edge) begin
               // the frame is over; the reload is this edge's advance
               @(negedge clk);
               check(n == 370, "370 advances per frame");
               check(bad_seq == 0, "word sequence p..369,0..p-1");
               check(bad_addr == 0, "audioAddr == base + 2*snd_index at every advance");
               check(snd_index == p, "next frame restarts at p");
               $display("  phase %0d: start word %0d, %0d advances, seq errors %0d, addr errors %0d",
                        ph, p, n, bad_seq, bad_addr);
               disable scan_frame;
            end
            if (clk8_en_p && ac0.sndAdvance === 1'b0 && ac0.snd_div_next >= ac0.SND_SIZE) begin
               // an advance is being registered on this edge; look at the result
               @(negedge clk);
               n = n + 1;
               expect_w = (expect_w == 369) ? 0 : expect_w + 1;
               if (snd_index !== expect_w) bad_seq = bad_seq + 1;
               if (ac0.audioAddr !== base + {snd_index, 1'b0}) bad_addr = bad_addr + 1;
            end
         end
      end
   endtask

   // ---- a CPU write cycle into the sound buffer ---------------------------
   task cpu_write(input [23:0] a);
      begin
         @(negedge clk); cpuAddr = a; _cpuRW = 0;
         @(negedge clk); _cpuAS = 0;
         repeat (4) @(negedge clk);
         _cpuAS = 1;
         @(negedge clk); _cpuRW = 1; cpuAddr = 24'd0;
      end
   endtask

   task wait_words(input integer k);
      integer c;
      begin
         c = 0;
         while (c < k) begin @(posedge clk); if (clk8_en_p && ac0.sndAdvance) c = c + 1; end
      end
   endtask

   integer idx_first, idx_wrap, frames0;
   reg [23:0] sb;
   initial begin
      $display("tb_snd_phase");
      // power-up state for the arbiter's free-running counters (Icarus
      // leaves them X otherwise) - as tb_slot3_fetch.v does
      force ac0.busPhase = 2'b00;
      force ac0.busCycle = 2'b00;
      force ac0.extra_slot_count = 2'b00;
      // ... and the video timer's, which the scan's vblank edge comes from
      force ac0.vt.xpos = 8'd0;
      force ac0.vt.ypos = 10'd0;
      @(posedge clk);
      release ac0.busPhase;
      release ac0.busCycle;
      release ac0.extra_slot_count;
      release ac0.vt.xpos;
      release ac0.vt.ypos;
      // let a frame pass so the scan is running from a real vblank edge
      repeat (600000) @(posedge clk);

      $display("scan sequence per phase");
      scan_frame(2'd0);
      scan_frame(2'd1);
      scan_frame(2'd2);
      scan_frame(2'd3);

      $display("probe: PoP's shape at 4MB, phase 0");
      phase = 2'd0; ramsize = 2'b11; sb = 24'h3FFD00;
      wait_frame_edge; @(negedge clk);    // after the edge's commit has landed
      frames0 = dbg[31:27];
      wait_words(5);                      // ~the VBL task latency (counts the reload pulse)
      @(negedge clk); idx_first = snd_index;
      cpu_write(sb + 24'd74);             // word 37, the driver's S
      cpu_write(sb + 24'd76);             // word 38: not "first" any more
      wait_words(28);                     // the first part takes ~28 words
      @(negedge clk); idx_wrap = snd_index;
      cpu_write(sb);                      // word 0, the wrap
      cpu_write(sb + 24'd2);
      wait_frame_edge; @(negedge clk);
      check(dbg[17:9]  == 9'd37, "PSND first word hit = 37");
      check(dbg[8:0] == idx_first || dbg[8:0] == idx_first + 1, "PSND scan word at first write");
      check(dbg[26:18] == idx_wrap || dbg[26:18] == idx_wrap + 1, "PSND scan word at the wrap write");
      check(dbg[31:27] == ((frames0 + 1) & 5'h1f), "PSND frame counter advanced by one");
      $display("  first write: word %0d at scan %0d (expected ~%0d); wrap at scan %0d (expected ~%0d); frame %0d",
               dbg[17:9], dbg[8:0], idx_first, dbg[26:18], idx_wrap, dbg[31:27]);

      $display("probe: a frame with no buffer write reads 511s; writes outside the buffer are ignored");
      cpu_write(24'h3FFCFE);              // one word below the buffer
      cpu_write(24'h3FFFE4);              // one word above it
      cpu_write(24'h2FFD00);              // right offset, wrong page
      wait_frame_edge; @(negedge clk);
      check(dbg[8:0] == 9'h1FF && dbg[17:9] == 9'h1FF && dbg[26:18] == 9'h1FF, "PSND idle frame = 511/511/511");

      $display("probe: 1MB decode, reads on the buffer are not writes");
      ramsize = 2'b10; sb = 24'h0FFD00;
      wait_frame_edge;
      wait_words(30);
      @(negedge clk); cpuAddr = sb + 24'd10; _cpuAS = 0; repeat (4) @(negedge clk); _cpuAS = 1; // a READ of word 5
      @(negedge clk); idx_first = snd_index;
      cpu_write(sb + 24'd180);            // word 90
      wait_frame_edge; @(negedge clk);
      check(dbg[17:9] == 9'd90, "PSND 1MB: first write word = 90");
      check(dbg[8:0] == idx_first || dbg[8:0] == idx_first + 1, "PSND 1MB: scan word at first write");
      check(dbg[26:18] == 9'h1FF, "PSND 1MB: no wrap write");
      // at 1MB the 4MB address must NOT decode
      wait_frame_edge;
      cpu_write(24'h3FFD00);
      wait_frame_edge; @(negedge clk);
      check(dbg[8:0] == 9'h1FF, "PSND 1MB: a 4MB-buffer address is ignored");

      $display("phase 28 with a write at word 37 lands behind the scan (the fix's premise)");
      ramsize = 2'b11; sb = 24'h3FFD00; phase = 2'd2;
      wait_frame_edge; wait_frame_edge;
      wait_words(5);
      @(negedge clk); idx_first = snd_index;
      // wait_words counts the reload pulse, so 5 pulses after the edge is word 28+4
      check(idx_first == 32, "at phase 28 the scan is at word 32 when a 4-word-late task runs");
      cpu_write(sb + 24'd74);
      wait_words(28);
      @(negedge clk); idx_wrap = snd_index;
      cpu_write(sb);
      wait_frame_edge; @(negedge clk);
      check(dbg[26:18] + 1 >= dbg[17:9], "phase 28: wrap write lands at or behind the start word (no splice)");
      $display("  scan at first write %0d, at wrap %0d, start word %0d", dbg[8:0], dbg[26:18], dbg[17:9]);

      if (fails == 0) $display("PASS: %0d/%0d", tests, tests);
      else            $display("FAIL: %0d of %0d", fails, tests);
      $finish;
   end
endmodule
