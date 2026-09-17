`timescale 1ns/1ps
//
// tb_floppy_format.v - Erase Disk: the format relay in floppy_track_encoder.v
//
// What the Plus ROM does to format a track, located in the 128K ROM
// (C:/temp/Mac/ROMS/128KB ROMs/1986-03 - 4D1F8172 - MacPlus v3.ROM, base
// $400000) and reproduced here byte for byte:
//
//   $419282  writes the track in one burst: one byte to Q7H to enter write
//            mode, 200 groups of the 6-byte sync pattern FF 3F CF F3 FC FF
//            (1200 bytes of lead-in), then for each of the spt sectors, in
//            the order 0 6 1 7 2 8 3 9 4 10 5 11: (sync-1) more sync groups
//            [sync starts at 7, $41910C], the 27-byte template from $4190CA
//            with the address field and data header filled in by $419362,
//            703 bytes of $96 (an all-zero data field and its checksum),
//            and DE AA FF FF. Then Q7L.
//   $418C18  is then called with the head just past that: it reads three
//            bytes, hunts for D5 AA 96 within a budget of $5DC (400K drive)
//            or $5BC (800K drive) bytes, decodes track/sector/side/format/
//            checksum and checks DE AA. The sector comes back in d2.
//   $419214  requires d2 == 0, else fmt1Err (-82). $41922C then turns the
//            budget left over into a gap measurement and decides whether
//            to accept the track, nudge the sync count for the next one, or
//            rewrite this one with a shorter gap.
//
// So after the burst the FIRST address field the drive presents must be
// sector 0, at a distance the ROM's arithmetic accepts. On real media that
// is physics; on this core it is the relay under test. The checks:
//
//   1. the encoder's revolution really is rev_len bytes (the ring the relay
//      counts in - measured, not trusted)
//   2. the ROM's format burst for track 0 side 0: every data field decodes
//      and commits (the track is zeroed, nothing else is touched), the
//      first field read back is sector 0, at the byte distance the ring
//      arithmetic predicts, and rom_verdict() accepts it on both budgets
//   3. an ordinary sector write - no address field - leaves the layout
//      alone: the relay never arms and the sector commits as before
//   4. a burst that ends on the very byte that completes an address field
//      (its sector byte) still relays, and to that sector: this is the
//      ordering floppy.v's two-clock wrEnd delay exists for
//   5. the same format burst on side 1 lands on side 1's sectors and reads
//      back as side 1
//
// Run from the repo ROOT:
//   iverilog -g2012 -I rtl -y rtl -o sim/out/tb_floppy_format.vvp sim/tb_floppy_format.v
//   vvp sim/out/tb_floppy_format.vvp
//
module tb_floppy_format;

   // clk_sys is 32 MHz on this core; busPhase divides it by 4 for cep/cen
   // exactly as addrController_top.v and sim/tb_iwm_latch.v do.
   localparam CLKSYS_NS = 31.25;
   reg clk = 0;
   always #(CLKSYS_NS/2) clk = ~clk;
   reg [1:0] busPhase = 2'b00;
   always @(posedge clk) busPhase <= busPhase + 1'b1;
   wire cep = (busPhase == 2'b11);
   wire cen = (busPhase == 2'b01);

   reg [7:0] mem [0:819199];         // sim/image.hex: the mounted 800K image
   reg [7:0] sdram_model [0:819199]; // what the write path committed

   // ---- DUT ----
   reg        _reset = 0;
   reg        ca0 = 0, ca1 = 0, ca2 = 1, SEL = 0; // {ca2,ca1,ca0,SEL} = RDDATA0
   reg        lstrb = 0;                          // idle low, as the ROM leaves it
   reg        _enable = 0;
   reg  [7:0] writeData = 0;
   reg        writeReq = 0;
   reg        writeMode = 0;
   reg        writeProtect = 0;
   reg        insertDisk = 1;
   reg        img800k = 1;     // 819,200-byte image ...
   reg        mediaSides = 1;  // ... whose volume sniffed as double-sided

   wire [7:0]  readData;
   wire        newByteReady;
   wire        writeBusy, writeUnderrun;
   wire [21:0] dskReadAddr;
   wire [21:0] dskWriteAddr;
   wire [15:0] dskWriteData;
   wire        dskWriteReq;
   reg         dskWriteAck = 0;

   floppy dut (
      .clk(clk), .cep(cep), .cen(cen),
      ._reset(_reset),
      .ca0(ca0), .ca1(ca1), .ca2(ca2), .SEL(SEL), .lstrb(lstrb),
      ._enable(_enable),
      .writeData(writeData),
      .readData(readData),
      .advanceDriveHead(1'b0),
      .newByteReady(newByteReady),
      .insertDisk(insertDisk),
      .img800k(img800k),
      .drive800k(1'b1),
      .mediaSides(mediaSides),
      .disk_pwm(9'd0),
      .diskEject(),
      .motor(), .act(),
      .dskReadAddr(dskReadAddr),
      // held high: floppy.v samples it under cep, and a byte is then always
      // waiting, which is what the real per-slot SDRAM ack amounts to at
      // this timescale (see sim/tb_iwm_latch.v)
      .dskReadAck(1'b1),
      .dskReadData(mem[dskReadAddr]),
      .writeReq(writeReq),
      .writeProtect(writeProtect),
      .writeBusy(writeBusy),
      .writeUnderrun(writeUnderrun),
      .writeMode(writeMode),
      .dskWriteAddr(dskWriteAddr),
      .dskWriteData(dskWriteData),
      .dskWriteReq(dskWriteReq),
      .dskWriteAck(dskWriteAck),
      .dbg_floppy(),
      .dskCommitDone(), .dskCommitAddr()
   );

   // SDRAM write port mock: ack a cycle after each request, record the word
   // with the image's even-byte-high convention (floppy_write_committer.v).
   always @(posedge clk) begin
      dskWriteAck <= dskWriteReq & ~dskWriteAck;
      if (dskWriteReq && dskWriteAck) begin
         sdram_model[dskWriteAddr]     <= dskWriteData[15:8];
         sdram_model[dskWriteAddr + 1] <= dskWriteData[7:0];
      end
   end

   // ---- the byte stream the Mac would read ----
   // floppy.v raises newByteReady for one cep per disk byte, with the byte
   // on readData (RDDATA0/1 addressed) from the same edge.
   reg  nbrPrev = 0;
   always @(posedge clk) nbrPrev <= newByteReady;
   wire rd_byte = newByteReady && !nbrPrev;
   integer rd_count = 0;
   always @(posedge clk) if (rd_byte) rd_count <= rd_count + 1;

   // anything the encoder does that a test wants to know it did NOT do
   reg relay_seen = 0, gap_seen = 0;
   always @(posedge clk) begin
      if (dut.enc.relay)            relay_seen <= 1'b1;
      if (dut.enc.state == 4'd9)    gap_seen   <= 1'b1; // STATE_GAP
   end

   initial begin
      #3_000_000_000;
      $display("FAIL: watchdog - simulation did not finish");
      $display("FORMAT RELAY GATE: FAIL (watchdog)");
      $finish;
   end

   // ---- GCR, from the ROM's own table at $41908A (= the encoder's) ----
   function [7:0] gcr(input [5:0] n);
      case (n)
      6'h00: gcr = 8'h96; 6'h01: gcr = 8'h97; 6'h02: gcr = 8'h9a; 6'h03: gcr = 8'h9b;
      6'h04: gcr = 8'h9d; 6'h05: gcr = 8'h9e; 6'h06: gcr = 8'h9f; 6'h07: gcr = 8'ha6;
      6'h08: gcr = 8'ha7; 6'h09: gcr = 8'hab; 6'h0a: gcr = 8'hac; 6'h0b: gcr = 8'had;
      6'h0c: gcr = 8'hae; 6'h0d: gcr = 8'haf; 6'h0e: gcr = 8'hb2; 6'h0f: gcr = 8'hb3;
      6'h10: gcr = 8'hb4; 6'h11: gcr = 8'hb5; 6'h12: gcr = 8'hb6; 6'h13: gcr = 8'hb7;
      6'h14: gcr = 8'hb9; 6'h15: gcr = 8'hba; 6'h16: gcr = 8'hbb; 6'h17: gcr = 8'hbc;
      6'h18: gcr = 8'hbd; 6'h19: gcr = 8'hbe; 6'h1a: gcr = 8'hbf; 6'h1b: gcr = 8'hcb;
      6'h1c: gcr = 8'hcd; 6'h1d: gcr = 8'hce; 6'h1e: gcr = 8'hcf; 6'h1f: gcr = 8'hd3;
      6'h20: gcr = 8'hd6; 6'h21: gcr = 8'hd7; 6'h22: gcr = 8'hd9; 6'h23: gcr = 8'hda;
      6'h24: gcr = 8'hdb; 6'h25: gcr = 8'hdc; 6'h26: gcr = 8'hdd; 6'h27: gcr = 8'hde;
      6'h28: gcr = 8'hdf; 6'h29: gcr = 8'he5; 6'h2a: gcr = 8'he6; 6'h2b: gcr = 8'he7;
      6'h2c: gcr = 8'he9; 6'h2d: gcr = 8'hea; 6'h2e: gcr = 8'heb; 6'h2f: gcr = 8'hec;
      6'h30: gcr = 8'hed; 6'h31: gcr = 8'hee; 6'h32: gcr = 8'hef; 6'h33: gcr = 8'hf2;
      6'h34: gcr = 8'hf3; 6'h35: gcr = 8'hf4; 6'h36: gcr = 8'hf5; 6'h37: gcr = 8'hf6;
      6'h38: gcr = 8'hf7; 6'h39: gcr = 8'hf9; 6'h3a: gcr = 8'hfa; 6'h3b: gcr = 8'hfb;
      6'h3c: gcr = 8'hfc; 6'h3d: gcr = 8'hfd; 6'h3e: gcr = 8'hfe; 6'h3f: gcr = 8'hff;
      endcase
   endfunction

   function [6:0] ungcr(input [7:0] b); // {valid, nib}
      integer k;
      begin
         ungcr = 7'd0;
         for (k = 0; k < 64; k = k + 1)
            if (gcr(k[5:0]) == b) ungcr = {1'b1, k[5:0]};
      end
   endfunction

   // ---- the ROM's verdict on a read-back, $418C18 + $419214 + $41922C ----
   // n = bytes the drive delivered from the end of the write up to and
   // including the 96 of the first D5 AA 96. The first three feed the
   // nibble check ($418C22) and are not budgeted; every later byte costs
   // one dbra of the budget ($418C6A). Returns 0 accept, 1 accept and
   // sync++ for the next track, 2 rewrite with sync--, 3 no mark within
   // the budget (noAdrMkErr, -67), 4 the mark was not sector 0 (fmt1Err,
   // -82: the failure on hardware before the relay existed).
   function integer rom_verdict(input integer n, input [7:0] sector_byte,
                                input integer budget, input integer sync,
                                input integer spt);
      integer d0, d2;
      begin
         d0 = budget - (n - 3);
         if (d0 < 0) rom_verdict = 3;
         else if (sector_byte != gcr(6'd0)) rom_verdict = 4;
         else begin
            d2 = (16'h5E0 - d0) / 5;
            d2 = d2 - sync;
            if (d2 < 0) begin
               rom_verdict = (d2 + 1 == 0) ? 0 : 2;
            end else begin
               d2 = d2 / spt;
               if (d2 == 0)          rom_verdict = 0;
               else if (d2 - 1 == 0) rom_verdict = 0;
               else                  rom_verdict = 1;
            end
         end
      end
   endfunction

   // ---- the write burst ----
   reg [7:0] wbuf [0:16383];
   integer   wlen;
   integer   mark_at;    // index in wbuf of the first address field's D5

   task push(input [7:0] b);
      begin wbuf[wlen] = b; wlen = wlen + 1; end
   endtask

   task push_sync; // FF 3F CF F3 FC FF - six 10-bit self-sync bytes
      begin push(8'hFF); push(8'h3F); push(8'hCF); push(8'hF3); push(8'hFC); push(8'hFF); end
   endtask

   // The track-0 burst $419282 emits, sync count `sync`, side `side`.
   task build_rom_format(input side, input integer sync);
      integer i, s;
      reg [5:0] t, h, f;
      begin
         wlen = 0; mark_at = -1;
         t = 6'd0;                 // track 0
         h = side ? 6'h20 : 6'h00; // {side, 0000, track[6]}
         f = 6'h22;                // double-sided
         push(8'hC7);              // the byte that goes to Q7H
         repeat (200) push_sync;
         for (i = 0; i < 12; i = i + 1) begin
            s = (i % 2 == 0) ? i / 2 : i / 2 + 6; // $419362's swap: 0 6 1 7 2 8 ...
            repeat (sync - 1) push_sync;
            push_sync;
            if (mark_at < 0) mark_at = wlen;
            push(8'hD5); push(8'hAA); push(8'h96);
            push(gcr(t)); push(gcr(s[5:0])); push(gcr(h)); push(gcr(f));
            push(gcr(t ^ s[5:0] ^ h ^ f));
            push(8'hDE); push(8'hAA); push(8'hFF);
            push(8'hFF); push(8'h3F); push(8'hCF); push(8'hF3); push(8'hFC); push(8'hFF);
            push(8'hD5); push(8'hAA); push(8'hAD); push(gcr(s[5:0]));
            repeat (703) push(8'h96);
            push(8'hDE); push(8'hAA); push(8'hFF); push(8'hFF);
         end
      end
   endtask

   // Feed wbuf the way iwm.v does: Q7 up, one writeReq per byte once the
   // pacer is free, Q7 down straight after the last byte is handed over
   // (the ROM's tst.b Q7L follows its last data write without waiting for
   // it to finish shifting). Returns once floppy.v has declared the burst
   // over (wrEnd) and the committer has drained; rd_at_end is the disk
   // byte count at wrEnd, where the ROM's own read-back count starts. (The
   // committer can still be draining the last sector then - with cep held
   // high it always is - which is why the hunt counts from here and not
   // from when this task returns.)
   integer rd_at_end;
   task feed_burst;
      integer i;
      begin
         @(posedge clk); #1;
         writeMode = 1'b1;
         for (i = 0; i < wlen; i = i + 1) begin
            while (writeBusy) begin @(posedge clk); #1; end
            writeData = wbuf[i];
            writeReq  = 1'b1;
            @(posedge clk); #1;
            writeReq  = 1'b0;
            @(posedge clk); #1;
         end
         writeMode = 1'b0;
         while (!dut.wrEnd) begin @(posedge clk); #1; end
         rd_at_end = rd_count;
         repeat (4) begin @(posedge clk); #1; end
         while (dut.wc.busy) begin @(posedge clk); #1; end
      end
   endtask

   // Read until the next D5 AA 96 goes by, then the five nibbles behind it.
   // n = bytes delivered from `start` through the 96 - the ROM's own count
   // when start is rd_at_end.
   task hunt_mark(input integer start, output integer n, output [7:0] gt,
                  output [7:0] gs, output [7:0] gh, output [7:0] gf,
                  output [7:0] gc);
      integer k;
      reg [23:0] h;
      begin
         h = 24'd0;
         while (h != 24'hD5AA96) begin
            @(posedge clk); #1;
            if (rd_byte) h = {h[15:0], readData};
         end
         n = rd_count - start;
         for (k = 0; k < 5; k = k + 1) begin
            @(posedge clk); #1;
            while (!rd_byte) begin @(posedge clk); #1; end
            case (k)
            0: gt = readData; 1: gs = readData; 2: gh = readData;
            3: gf = readData; default: gc = readData;
            endcase
         end
      end
   endtask

   task do_reset;
      begin
         _reset = 0;
         @(posedge clk); @(negedge clk);
         _reset = 1;
         #1;
         repeat (8) @(posedge clk);
      end
   endtask

   // a tick of the head to the other side: floppy.v takes driveSide from
   // the RDDATA0/RDDATA1 register address while lstrb is low
   task select_side(input s);
      begin
         @(posedge clk); #1;
         SEL = s;
         repeat (8) @(posedge clk); #1;
      end
   endtask

   integer all_ok = 1;
   integer n, k, rev, m0, m1, expect_ahead, mism, verdict;
   reg [7:0] gt, gs, gh, gf, gc;
   reg [6:0] u;
   reg [7:0] field [0:708];

   task check_field(input [7:0] w_t, input [7:0] w_s, input [7:0] w_h,
                    input [7:0] w_f, input string what);
      begin
         if (gt === w_t && gs === w_s && gh === w_h && gf === w_f &&
             gc === gcr(ungcr(w_t) ^ ungcr(w_s) ^ ungcr(w_h) ^ ungcr(w_f)))
            $display("PASS: %0s address field reads t=%h s=%h h=%h f=%h c=%h", what, gt, gs, gh, gf, gc);
         else begin
            $display("FAIL: %0s address field reads t=%h s=%h h=%h f=%h c=%h, wanted t=%h s=%h h=%h f=%h",
                     what, gt, gs, gh, gf, gc, w_t, w_s, w_h, w_f);
            all_ok = 0;
         end
      end
   endtask

   initial begin
      $readmemh("sim/image.hex", mem);
      $readmemh("sim/write_stream_integration.hex", field);
      for (k = 0; k < 819200; k = k + 1) sdram_model[k] = 8'hXX;

      // the bench's GCR table against the decoder's reverse table, all 256
      for (k = 0; k < 256; k = k + 1) begin
         u = dut.dec.rev_lookup(k[7:0]);
         if (u[6] && gcr(u[5:0]) != k[7:0]) begin
            $display("FAIL: GCR tables disagree at %h", k[7:0]);
            all_ok = 0;
         end
      end

      do_reset;

      // =====================================================================
      // 1. one revolution of the free-running layout, measured
      // =====================================================================
      hunt_mark(0, n, gt, gs, gh, gf, gc);
      while (gs != gcr(6'd0)) hunt_mark(0, n, gt, gs, gh, gf, gc);
      m0 = rd_count;
      $write("      sector order: 0");
      hunt_mark(0, n, gt, gs, gh, gf, gc);
      while (gs != gcr(6'd0)) begin
         u = ungcr(gs); $write(" %0d", u[5:0]);
         hunt_mark(0, n, gt, gs, gh, gf, gc);
      end
      $display("");
      m1  = rd_count;
      rev = m1 - m0;
      if (rev == dut.enc.rev_len)
         $display("PASS: the layout repeats every %0d bytes, and rev_len says %0d", rev, dut.enc.rev_len);
      else begin
         $display("FAIL: the layout repeats every %0d bytes but rev_len says %0d", rev, dut.enc.rev_len);
         all_ok = 0;
      end

      // =====================================================================
      // 2. the ROM's format burst, track 0 side 0
      // =====================================================================
      build_rom_format(1'b0, 7);
      expect_ahead = ((mark_at - wlen) % rev + rev) % rev;
      $display("      burst: %0d bytes, first mark at %0d, so sector 0's D5 is due %0d bytes after the write",
               wlen, mark_at, expect_ahead);
      relay_seen = 0;
      feed_burst;

      // every sector's data field committed - and only those
      mism = 0;
      for (k = 0; k < 819200; k = k + 1)
         if (k < 12*512) begin
            if (sdram_model[k] !== 8'h00) mism = mism + 1;
         end else begin
            if (sdram_model[k] !== 8'hXX) mism = mism + 1;
         end
      if (mism == 0)
         $display("PASS: all 12 data fields committed - track 0 side 0 is zeroed and nothing else was written");
      else begin
         $display("FAIL: %0d bytes wrong after the format burst", mism);
         all_ok = 0;
      end

      if (relay_seen && !dut.enc.relay_armed)
         $display("PASS: the relay fired at the end of the burst and disarmed");
      else begin
         $display("FAIL: relay_seen=%b relay_armed=%b after the burst", relay_seen, dut.enc.relay_armed);
         all_ok = 0;
      end

      // what $418C18 finds
      hunt_mark(rd_at_end, n, gt, gs, gh, gf, gc);
      check_field(gcr(6'd0), gcr(6'd0), gcr(6'h00), gcr(6'h22), "first field after the format:");
      // n - 3 is the D5's distance. The burst's end is a clock-level event
      // inside a 16 us byte cell, so a byte either side of the ring
      // arithmetic is the honest tolerance (it comes out one short at both
      // cep spacings); the ROM's window is ~1400 bytes wide.
      if (n - 3 >= expect_ahead - 1 && n - 3 <= expect_ahead + 1)
         $display("PASS: its D5 came %0d bytes after the write (ring arithmetic said %0d)", n - 3, expect_ahead);
      else begin
         $display("FAIL: its D5 came %0d bytes after the write, ring arithmetic said %0d", n - 3, expect_ahead);
         all_ok = 0;
      end
      verdict = rom_verdict(n, gs, 16'h5BC, 7, 12);
      if (verdict == 0 || verdict == 1)
         $display("PASS: $41922C accepts the track on the 800K budget (verdict %0d: %0s)", verdict,
                  verdict == 0 ? "accept" : "accept, sync+1 next track");
      else begin
         $display("FAIL: $41922C rejects the track on the 800K budget (verdict %0d)", verdict);
         all_ok = 0;
      end
      verdict = rom_verdict(n, gs, 16'h5DC, 7, 12);
      if (verdict == 0 || verdict == 1)
         $display("PASS: ... and on the 400K budget (verdict %0d)", verdict);
      else begin
         $display("FAIL: $41922C rejects the track on the 400K budget (verdict %0d)", verdict);
         all_ok = 0;
      end

      // =====================================================================
      // 3. an ordinary sector write leaves the layout alone
      // =====================================================================
      for (k = 0; k < 819200; k = k + 1) sdram_model[k] = 8'hXX;
      wlen = 0;
      for (k = 0; k < 709; k = k + 1) push(field[k]);
      relay_seen = 0; gap_seen = 0;
      feed_burst;
      mism = 0;
      for (k = 0; k < 512; k = k + 1)
         if (sdram_model[k] !== mem[k]) mism = mism + 1;
      if (mism == 0 && !relay_seen && !gap_seen && !dut.enc.relay_armed)
         $display("PASS: a plain data-field write committed byte-exact and never touched the relay");
      else begin
         $display("FAIL: plain write - %0d mismatches, relay_seen=%b gap_seen=%b armed=%b",
                  mism, relay_seen, gap_seen, dut.enc.relay_armed);
         all_ok = 0;
      end

      // =====================================================================
      // 4. a burst that ends on an address field's sector byte, sector 6
      // =====================================================================
      wlen = 0;
      repeat (20) push(8'hFF);
      mark_at = wlen;
      push(8'hD5); push(8'hAA); push(8'h96); push(gcr(6'd0)); push(gcr(6'd6));
      expect_ahead = ((mark_at - wlen) % rev + rev) % rev; // = rev - 5
      relay_seen = 0;
      feed_burst;
      hunt_mark(rd_at_end, n, gt, gs, gh, gf, gc);
      check_field(gcr(6'd0), gcr(6'd6), gcr(6'h00), gcr(6'h22), "after a burst ending on its sector byte:");
      if (relay_seen && n - 3 >= expect_ahead - 1 && n - 3 <= expect_ahead + 1)
         $display("PASS: relayed to sector 6, D5 %0d bytes on (expected %0d)", n - 3, expect_ahead);
      else begin
         $display("FAIL: relay_seen=%b, D5 %0d bytes on (expected %0d)", relay_seen, n - 3, expect_ahead);
         all_ok = 0;
      end

      // =====================================================================
      // 5. the same format burst on side 1
      // =====================================================================
      for (k = 0; k < 819200; k = k + 1) sdram_model[k] = 8'hXX;
      select_side(1'b1);
      build_rom_format(1'b1, 7);
      expect_ahead = ((mark_at - wlen) % rev + rev) % rev;
      relay_seen = 0;
      feed_burst;
      mism = 0;
      for (k = 0; k < 819200; k = k + 1)
         if (k >= 12*512 && k < 24*512) begin
            if (sdram_model[k] !== 8'h00) mism = mism + 1;
         end else begin
            if (sdram_model[k] !== 8'hXX) mism = mism + 1;
         end
      if (mism == 0)
         $display("PASS: side 1's 12 data fields committed to side 1 and nothing else was written");
      else begin
         $display("FAIL: %0d bytes wrong after the side 1 format burst", mism);
         all_ok = 0;
      end
      hunt_mark(rd_at_end, n, gt, gs, gh, gf, gc);
      check_field(gcr(6'd0), gcr(6'd0), gcr(6'h20), gcr(6'h22), "first field after the side 1 format:");
      if (relay_seen && n - 3 >= expect_ahead - 1 && n - 3 <= expect_ahead + 1)
         $display("PASS: its D5 came %0d bytes after the write (ring arithmetic said %0d)", n - 3, expect_ahead);
      else begin
         $display("FAIL: relay_seen=%b, D5 %0d bytes after the write, ring arithmetic said %0d", relay_seen, n - 3, expect_ahead);
         all_ok = 0;
      end
      select_side(1'b0);

      $display("");
      if (all_ok) $display("FORMAT RELAY GATE: PASS");
      else        $display("FORMAT RELAY GATE: FAIL");
      $finish;
   end

endmodule
