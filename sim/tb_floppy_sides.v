`timescale 1ns/1ps
//
// tb_floppy_sides.v - Phase 7 of FLOPPY_WRITE_PLAN.md: the medium is a
// diskette, not a file size.
//
// The defect this bench was written for: floppy_track_encoder.v derived the
// address field's FORMAT byte from the image FILE SIZE, so a One-Sided Erase
// Disk on an 819,200-byte image formatted side 0 (correctly), was then asked
// what geometry the disk had, answered "double-sided" anyway, and let the
// driver build an 800K volume across a side that had never been formatted.
// 308 KB of the previous volume stayed live in reported-free space. Two
// hardware runs, 1596 of 1600 sectors byte-identical to the old disk.
//
// What replaces it is floppy.v's doubleSidedDisk: three terms, each a
// CEILING on the ones after it - the drive's mechanism, the file's size, and
// then the medium itself. The medium speaks twice: through the volume it
// already carries (mediaSides, sniffed at mount by floppy_loader.v and
// covered by sim/tb_floppy_sniff.v) and, from the moment a format overwrites
// that volume, through the format byte of the track being laid down, which
// is what floppy_track_decoder.v's S_AMRK walk now reads out.
//
// The checks:
//
//   1. the defect itself: a One-Sided format burst on an 800K image must
//      read back $02, and must leave the geometry single-sided
//   2. a Two-Sided burst reads back $22 and puts it back
//   3. an ordinary sector write - no address field at all - changes neither
//   4. an address field whose checksum does not add up changes neither: a
//      mis-synced match must not be able to reformat the whole disk
//   4b. a disk change clears the latch, so it cannot describe the medium
//      that replaced it.
//   5. addressing follows the same signal as the format byte. With the
//      medium single-sided, track 1 side 0 sector 0 commits to file sector
//      12 (byte 6144), not 24 (byte 12288), so the volume is stored
//      LINEARLY and its first 409,600 bytes are an ordinary 400K .dsk that
//      a 128K/512K reads identically. A side-1 field is refused.
//   6. the FILE ceiling: a Two-Sided burst on a 409,600 image leaves the
//      geometry single-sided and still reads back $02 - this is what keeps
//      a Two-Sided erase of a 400K image producing a 400K volume, which is
//      required behaviour, not an accident. The mirror case on an 819,200
//      image does take, so the ceiling is what is doing the work.
//   7. the DRIVE ceiling: on a single-headed 400K mechanism the geometry is
//      single-sided whatever the file and whatever the medium say.
//
// Run from the repo ROOT:
//   iverilog -g2012 -I rtl -y rtl -o sim/out/tb_floppy_sides.vvp sim/tb_floppy_sides.v
//   vvp sim/out/tb_floppy_sides.vvp
//
module tb_floppy_sides;

   localparam CLKSYS_NS = 31.25;
   reg clk = 0;
   always #(CLKSYS_NS/2) clk = ~clk;
   reg [1:0] busPhase = 2'b00;
   always @(posedge clk) busPhase <= busPhase + 1'b1;
   wire cep = (busPhase == 2'b11);
   wire cen = (busPhase == 2'b01);

   reg [7:0] mem [0:819199];         // sim/image.hex: the mounted image

   // ---- DUT ----
   reg        _reset = 0;
   reg        ca0 = 0, ca1 = 0, ca2 = 1, SEL = 0; // {ca2,ca1,ca0,SEL} = RDDATA0
   reg        lstrb = 0;
   reg        _enable = 0;
   reg  [7:0] writeData = 0;
   reg        writeReq = 0;
   reg        writeMode = 0;
   reg        writeProtect = 0;
   reg        insertDisk = 1;

   // the three terms of doubleSidedDisk, driven independently so each can be
   // pinned against the others
   reg        img800k    = 1;  // the FILE is 819,200 bytes
   reg        drive800k  = 1;  // the DRIVE has two heads
   reg        mediaSides = 1;  // the MEDIUM's volume sniffed double-sided

   wire [7:0]  readData;
   wire        newByteReady;
   wire        writeBusy, writeUnderrun;
   wire [21:0] dskReadAddr;
   wire [21:0] dskWriteAddr;
   wire [15:0] dskWriteData;
   wire        dskWriteReq;
   reg         dskWriteAck = 0;
   wire        commitDone;
   wire [21:0] commitAddr;

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
      .drive800k(drive800k),
      .mediaSides(mediaSides),
      .disk_pwm(9'd0),
      .diskEject(),
      .motor(), .act(),
      .dskReadAddr(dskReadAddr),
      // held high: floppy.v samples it under cep, so a byte is always
      // waiting - what the real per-slot SDRAM ack amounts to at this
      // timescale (see sim/tb_iwm_latch.v)
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
      .dskCommitDone(commitDone), .dskCommitAddr(commitAddr),
      .dskCommitBufWr(), .dskCommitBufAddr(), .dskCommitBufData()
   );

   // SDRAM write port mock: ack a cycle after each request. Where the bytes
   // land is what this bench is about, so only the addresses are kept.
   always @(posedge clk) dskWriteAck <= dskWriteReq & ~dskWriteAck;

   // where the last completed sector landed, and how many landed at all
   reg [21:0] last_commit_addr;
   integer    commits = 0;
   always @(posedge clk) if (commitDone) begin
      last_commit_addr = commitAddr;
      commits = commits + 1;
   end

   // ---- the byte stream the Mac would read ----
   reg  nbrPrev = 0;
   always @(posedge clk) nbrPrev <= newByteReady;
   wire rd_byte = newByteReady && !nbrPrev;
   integer rd_count = 0;
   always @(posedge clk) if (rd_byte) rd_count <= rd_count + 1;

   initial begin
      #6_000_000_000;
      $display("FAIL: watchdog - simulation did not finish");
      $display("MEDIA SIDEDNESS GATE: FAIL (watchdog)");
      $finish;
   end

   // ---- GCR, the encoder's own table ----
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
      6'h3c: gcr = 8'hfc; 6'h3d: gcr = 8'hfd; 6'h3e: gcr = 8'hfe; default: gcr = 8'hff;
      endcase
   endfunction

   // ---- the write burst ----
   reg [7:0] wbuf [0:16383];
   integer   wlen;

   task push(input [7:0] b);
      begin wbuf[wlen] = b; wlen = wlen + 1; end
   endtask

   task push_sync; // FF 3F CF F3 FC FF - six 10-bit self-sync bytes
      begin push(8'hFF); push(8'h3F); push(8'hCF); push(8'hF3); push(8'hFC); push(8'hFF); end
   endtask

   // The track-0 burst $419282 emits (sim/tb_floppy_format.v's header decodes
   // it), with the format byte the Erase Disk dialog's One-Sided / Two-Sided
   // choice puts there. `spoil_sum` writes a checksum byte that does not add
   // up, which is what a mis-synced match looks like from here.
   task build_rom_format(input side, input [5:0] fmt, input spoil_sum);
      integer i, s;
      reg [5:0] t, h, c;
      begin
         wlen = 0;
         t = 6'd0;                 // track 0
         h = side ? 6'h20 : 6'h00; // {side, 0000, track[6]}
         push(8'hC7);              // the byte that goes to Q7H
         repeat (200) push_sync;
         for (i = 0; i < 12; i = i + 1) begin
            s = (i % 2 == 0) ? i / 2 : i / 2 + 6; // $419362's swap: 0 6 1 7 ...
            repeat (7) push_sync;
            push(8'hD5); push(8'hAA); push(8'h96);
            push(gcr(t)); push(gcr(s[5:0])); push(gcr(h)); push(gcr(fmt));
            c = t ^ s[5:0] ^ h ^ fmt;
            push(gcr(spoil_sum ? c ^ 6'h01 : c));
            push(8'hDE); push(8'hAA); push(8'hFF);
            push(8'hFF); push(8'h3F); push(8'hCF); push(8'hF3); push(8'hFC); push(8'hFF);
            push(8'hD5); push(8'hAA); push(8'hAD); push(gcr(s[5:0]));
            repeat (703) push(8'h96);
            push(8'hDE); push(8'hAA); push(8'hFF); push(8'hFF);
         end
      end
   endtask

   // Feed wbuf the way iwm.v does, and return once floppy.v has declared the
   // burst over and the committer has drained (see tb_floppy_format.v).
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
         repeat (4) begin @(posedge clk); #1; end
         while (dut.wc.busy) begin @(posedge clk); #1; end
      end
   endtask

   // Read until the next D5 AA 96 goes by, then the five nibbles behind it.
   task hunt_mark(output [7:0] gt, output [7:0] gs, output [7:0] gh,
                  output [7:0] gf, output [7:0] gc);
      integer k;
      reg [23:0] h;
      begin
         h = 24'd0;
         while (h != 24'hD5AA96) begin
            @(posedge clk); #1;
            if (rd_byte) h = {h[15:0], readData};
         end
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

   // Eject and re-insert, without a reset. floppy.v samples insertDisk under
   // cep, and BOTH its edges raise writePathReset, which is what clears the
   // format latch - so this is the path a real disk change takes, and the
   // only one that proves the latch cannot outlive the medium it describes.
   task change_disk;
      begin
         @(posedge clk); #1;
         insertDisk = 1'b0;
         repeat (32) begin @(posedge clk); #1; end
         insertDisk = 1'b1;
         repeat (32) begin @(posedge clk); #1; end
      end
   endtask

   // NOTE: this also returns the head to track 0 (floppy.v's driveTrack is
   // reset), so anything testing track 1 has to step again afterwards.
   task do_reset;
      begin
         _reset = 0;
         @(posedge clk); @(negedge clk);
         _reset = 1;
         #1;
         repeat (8) @(posedge clk);
      end
   endtask

   // floppy.v takes driveSide from the RDDATA0/RDDATA1 register address
   task select_side(input s);
      begin
         @(posedge clk); #1;
         ca2 = 1; ca1 = 0; ca0 = 0; SEL = s;
         repeat (8) @(posedge clk); #1;
      end
   endtask

   // One track outward. DIRTN (write register 0, data on ca2) then STEP
   // (write register 2, data 0), each on a falling edge of lstrb with
   // _enable low - floppy.v's driveWriteAddr is {ca1,ca0,SEL}.
   task step_out;
      begin
         @(posedge clk); #1;
         lstrb = 1; ca2 = 0; ca1 = 0; ca0 = 0; SEL = 0;  // DIRTN = 0, toward 79
         repeat (8) @(posedge clk); #1;
         lstrb = 0;
         repeat (8) @(posedge clk); #1;
         lstrb = 1; ca2 = 0; ca1 = 0; ca0 = 1; SEL = 0;  // STEP
         repeat (8) @(posedge clk); #1;
         lstrb = 0;
         repeat (8) @(posedge clk); #1;
         ca2 = 1; ca1 = 0; ca0 = 0; SEL = 0;             // back to RDDATA0
         repeat (8) @(posedge clk); #1;
      end
   endtask

   integer all_ok = 1;
   integer k;
   reg [7:0] gt, gs, gh, gf, gc;
   reg [7:0] field [0:708];

   task ok(input [8*80:1] name, input cond);
      begin
         if (cond) $display("PASS: %0s", name);
         else begin $display("FAIL: %0s", name); all_ok = 0; end
      end
   endtask

   // Read back the first address field the encoder now presents - the format
   // byte in it is what the .Sony driver reads the geometry out of.
   task read_format(output [7:0] f);
      begin
         hunt_mark(gt, gs, gh, gf, gc);
         f = gf;
      end
   endtask

   // Commit one ordinary sector-0 data field wherever the head is, and
   // report where it landed and whether it landed at all.
   // feed_burst returns when the WRITE is over, which is a little before
   // floppy_write_committer.v has drained the sector into SDRAM - its
   // `busy` has not necessarily risen yet when feed_burst last looks at it.
   // Reading the commit counter straight afterwards therefore reports the
   // PREVIOUS sector's landing address, which is exactly wrong for a bench
   // whose whole subject is where a sector lands. So wait for this write's
   // own commit, bounded, since a refused field never produces one.
   task write_one_sector(output [21:0] where, output [31:0] landed);
      integer commits_before; // NB: `before` is a SystemVerilog keyword
      integer waited;
      begin
         commits_before = commits;
         wlen = 0;
         for (k = 0; k < 709; k = k + 1) push(field[k]);
         feed_burst;
         waited = 0;
         while (commits == commits_before && waited < 20000) begin
            @(posedge clk); #1;
            waited = waited + 1;
         end
         landed = commits - commits_before;
         where  = last_commit_addr;
      end
   endtask

   integer n_landed;
   reg [21:0] where;

   initial begin
      $readmemh("sim/image.hex", mem);
      $readmemh("sim/write_stream_integration.hex", field);

      $display("");
      $display("=== the medium is a diskette, not a file size ===");

      // ==================================================================
      // 1. the defect: a One-Sided Erase Disk on an 800K image
      // ==================================================================
      img800k = 1; drive800k = 1; mediaSides = 1;
      do_reset;
      ok("before any format, an 800K image on an 800K drive is double-sided",
         dut.doubleSidedDisk === 1'b1);

      build_rom_format(1'b0, 6'h02, 1'b0);
      feed_burst;
      read_format(gf);
      ok("a One-Sided format burst reads back f=$02, not $22", gf === gcr(6'h02));
      ok("... and the geometry follows it: the disk is now single-sided",
         dut.doubleSidedDisk === 1'b0);

      // ==================================================================
      // 2. and back again
      // ==================================================================
      build_rom_format(1'b0, 6'h22, 1'b0);
      feed_burst;
      read_format(gf);
      ok("a Two-Sided format burst reads back f=$22", gf === gcr(6'h22));
      ok("... and puts the geometry back to double-sided",
         dut.doubleSidedDisk === 1'b1);

      // ==================================================================
      // 3. an ordinary sector write says nothing about the medium
      // ==================================================================
      do_reset;
      build_rom_format(1'b0, 6'h02, 1'b0);
      feed_burst;
      ok("(single-sided, set up by a One-Sided burst)", dut.doubleSidedDisk === 1'b0);
      write_one_sector(where, n_landed);
      ok("a plain data-field write committed", n_landed == 1);
      ok("... and left the geometry alone - it carries no address field",
         dut.doubleSidedDisk === 1'b0 && dut.fmtSeen === 1'b1);

      // ==================================================================
      // 4. a field whose checksum does not add up says nothing either
      // ==================================================================
      do_reset;
      ok("(double-sided again after reset)", dut.doubleSidedDisk === 1'b1);
      build_rom_format(1'b0, 6'h02, 1'b1);   // One-Sided, checksum spoiled
      feed_burst;
      ok("a One-Sided burst with a bad checksum does not touch the geometry",
         dut.doubleSidedDisk === 1'b1 && dut.fmtSeen === 1'b0);
      read_format(gf);
      ok("... and the encoder goes on reporting $22", gf === gcr(6'h22));

      // ==================================================================
      // 4b. the latch does not outlive the medium it describes
      //
      // Erase a disk One-Sided, then swap in another one. If the latch
      // survived the change, the NEW disk - whatever its own volume says -
      // would be addressed with the old disk's geometry, which is the same
      // class of corruption this whole phase exists to remove, only aimed
      // at a disk that was never touched.
      // ==================================================================
      do_reset;
      build_rom_format(1'b0, 6'h02, 1'b0);
      feed_burst;
      ok("(One-Sided erase done: single-sided, and the latch is set)",
         dut.doubleSidedDisk === 1'b0 && dut.fmtSeen === 1'b1);
      change_disk;
      ok("a disk change clears the format latch",
         dut.fmtSeen === 1'b0);
      ok("... so the new disk is addressed by its OWN medium, not the old one's",
         dut.doubleSidedDisk === 1'b1);
      read_format(gf);
      ok("... and reads back $22 again", gf === gcr(6'h22));

      // ==================================================================
      // 5. addressing follows the same signal, and side 1 is refused
      // ==================================================================
      do_reset;
      build_rom_format(1'b0, 6'h02, 1'b0);
      feed_burst;
      step_out;                       // track 1
      ok("(head stepped to track 1, single-sided)",
         dut.driveTrack === 7'd1 && dut.doubleSidedDisk === 1'b0);
      write_one_sector(where, n_landed);
      ok("single-sided: track 1 side 0 sector 0 commits to byte 6144 (file sector 12)",
         n_landed == 1 && where === 22'd6144);

      select_side(1'b1);
      write_one_sector(where, n_landed);
      ok("single-sided: a side-1 field is refused outright", n_landed == 0);
      select_side(1'b0);

      // the same head position, double-sided: the interleaved slot instead
      do_reset;                       // clears the latch AND the head position
      step_out;
      ok("(double-sided again, back on track 1)",
         dut.doubleSidedDisk === 1'b1 && dut.driveTrack === 7'd1);
      write_one_sector(where, n_landed);
      ok("double-sided: the same sector commits to byte 12288 (file sector 24)",
         n_landed == 1 && where === 22'd12288);

      // ==================================================================
      // 6. the FILE ceiling
      // ==================================================================
      img800k = 0; drive800k = 1; mediaSides = 1;   // a 409,600-byte image
      do_reset;
      ok("a 400K image is single-sided before anything happens",
         dut.doubleSidedDisk === 1'b0);
      build_rom_format(1'b0, 6'h22, 1'b0);          // Two-Sided erase of a 400K image
      feed_burst;
      ok("a Two-Sided burst on a 400K image cannot make it double-sided",
         dut.doubleSidedDisk === 1'b0);
      read_format(gf);
      ok("... and it still reads back $02, so the driver builds a 400K volume",
         gf === gcr(6'h02));
      step_out;
      write_one_sector(where, n_landed);
      ok("... with track 1 addressed linearly, inside the file",
         n_landed == 1 && where === 22'd6144);
      select_side(1'b1);
      write_one_sector(where, n_landed);
      ok("... and side 1 refused, so nothing lands past the end of the file",
         n_landed == 0);
      select_side(1'b0);

      // the mirror: the identical burst on an 819,200 image DOES take
      img800k = 1;
      do_reset;
      build_rom_format(1'b0, 6'h22, 1'b0);
      feed_burst;
      read_format(gf);
      ok("the same burst on an 800K image reads back $22 - the file was the ceiling",
         gf === gcr(6'h22) && dut.doubleSidedDisk === 1'b1);

      // ==================================================================
      // 7. the DRIVE ceiling
      // ==================================================================
      img800k = 1; drive800k = 0; mediaSides = 1;
      do_reset;
      ok("a one-headed drive sees an 800K image as single-sided",
         dut.doubleSidedDisk === 1'b0);
      build_rom_format(1'b0, 6'h22, 1'b0);
      feed_burst;
      ok("... and a Two-Sided format burst cannot change that",
         dut.doubleSidedDisk === 1'b0);
      read_format(gf);
      ok("... the address field still says $02", gf === gcr(6'h02));
      step_out;
      write_one_sector(where, n_landed);
      ok("... and track 1 is addressed linearly", n_landed == 1 && where === 22'd6144);

      $display("");
      if (all_ok) $display("MEDIA SIDEDNESS GATE: PASS");
      else        $display("MEDIA SIDEDNESS GATE: FAIL");
      $finish;
   end

endmodule
