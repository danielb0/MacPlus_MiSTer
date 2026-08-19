`timescale 1ns/1ps
//
// Phase 2 of SCSI_UPGRADE_PLAN.md: the AppleCD-compatible CD-ROM personality of
// rtl/scsi.v, driven by the same style of SCSI initiator model as
// sim/tb_scsi_target.v (which covers the disk personality).
//
// This is a separate bench rather than more cases bolted onto the disk one: the
// two personalities differ in identity, block size, media model and command
// set, and keeping the gates separate means "the disk still works" and "the CD
// works" are independently meaningful answers.
//
// The image used throughout is chosen so the lead-out MSF conversion has
// non-trivial minutes, seconds AND frames -- an LBA that divides evenly would
// pass with a broken divider:
//
//   img_blocks   = 729968  512-byte HPS blocks
//   2048-blocks  = 182492  -> capacity (last LBA) = 182491
//   lead-out LBA = 182492 frames
//     0xC1 plane (raw, BCD):    40:33:17 -> 0x40 0x33 0x17
//     0x43 plane (+150, binary): 182642  -> 40:35:17
//
module tb_scsi_cdrom;

   reg clk = 0;
   always #5 clk = ~clk;

   localparam [31:0] IMG_BLOCKS = 32'd729968;
   localparam [31:0] CD_BLOCKS  = IMG_BLOCKS / 4;        // 182492
   localparam [31:0] CD_CAP     = CD_BLOCKS - 1;         // 182491

   // ---- target bus ------------------------------------------------------
   reg        rst       = 1'b1;
   reg        sys_rst   = 1'b0;
   reg        bus_busy  = 1'b0;
   reg        cd_enable = 1'b1;
   reg        sel  = 1'b0;
   reg        atn  = 1'b0;
   reg        ack  = 1'b0;
   reg  [7:0] din  = 8'h00;

   wire       bsy, msg, cd, io, req;
   wire [7:0] dout;

   // ---- io controller side ----------------------------------------------
   reg         img_mounted = 1'b0;
   reg  [31:0] img_blocks  = 32'd0;

   wire [31:0] io_lba;
   wire        io_rd, io_wr;
   reg         io_ack = 1'b0;

   reg  [7:0]  sd_buff_addr = 8'd0;
   reg  [15:0] sd_buff_dout = 16'd0;
   wire [15:0] sd_buff_din;
   reg         sd_buff_wr   = 1'b0;

   localparam [2:0] TARGET_ID = 3'd3;   // AppleCD SC factory default

   scsi #(.ID(TARGET_ID), .CDROM(1)) dut
   (
      .clk(clk),

      .rst(rst),
      .sys_rst(sys_rst),
      .bus_busy(bus_busy),
      .cd_enable(cd_enable),
      .sel(sel),
      .atn(atn),
      .bsy(bsy),

      .msg(msg),
      .cd(cd),
      .io(io),

      .req(req),
      .ack(ack),

      .din(din),
      .dout(dout),

      .img_mounted(img_mounted),
      .img_blocks(img_blocks),
      .io_lba(io_lba),
      .io_rd(io_rd),
      .io_wr(io_wr),
      .io_ack(io_ack),

      .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout),
      .sd_buff_din(sd_buff_din),
      .sd_buff_wr(sd_buff_wr)
   );

   integer cd_fail  = 0;
   integer cd_total = 0;

   localparam P_DATA_OUT = 3'd2;
   localparam P_DATA_IN  = 3'd3;
   localparam P_STATUS   = 3'd4;
   localparam P_MSG      = 3'd5;
   localparam P_CMD      = 3'd1;
   localparam P_UNKNOWN  = 3'd7;

   function [2:0] phase_of;
      input m, c, i;
      begin
         if      ( m &&  c &&  i) phase_of = P_MSG;
         else if (!m &&  c &&  i) phase_of = P_STATUS;
         else if (!m &&  c && !i) phase_of = P_CMD;
         else if (!m && !c &&  i) phase_of = P_DATA_OUT;
         else if (!m && !c && !i) phase_of = P_DATA_IN;
         else                     phase_of = P_UNKNOWN;
      end
   endfunction

   // ======================================================================
   // hps_io block-device model, identical in behaviour to the disk bench:
   // byte[n] of the sector at lba = lba[7:0] ^ n.
   // ======================================================================
   reg hps_enable = 1'b0;
   integer io_rd_count = 0;
   integer io_wr_count = 0;

   always @(posedge clk) begin : hps_model
      integer w;
      reg [7:0] even_b, odd_b;
      if (hps_enable && (io_rd || io_wr)) begin
         if (io_rd) io_rd_count = io_rd_count + 1;
         if (io_wr) io_wr_count = io_wr_count + 1;
         repeat (8) @(posedge clk);
         if (io_rd) begin
            for (w = 0; w < 256; w = w + 1) begin
               even_b = io_lba[7:0] ^ ((w * 2)     & 8'hff);
               odd_b  = io_lba[7:0] ^ ((w * 2 + 1) & 8'hff);
               sd_buff_addr <= w[7:0];
               sd_buff_dout <= { odd_b, even_b };
               sd_buff_wr   <= 1'b1;
               @(posedge clk);
            end
            sd_buff_wr <= 1'b0;
         end
         @(posedge clk);
         io_ack <= 1'b1;
         repeat (4) @(posedge clk);
         io_ack <= 1'b0;
         @(posedge clk);
      end
   end

   // ======================================================================
   // Initiator model
   // ======================================================================
   task do_reset;
      begin
         rst = 1'b1; sel = 1'b0; ack = 1'b0; din = 8'h00;
         hps_enable = 1'b0;
         repeat (8) @(posedge clk);
         rst = 1'b0;
         repeat (4) @(posedge clk);
         hps_enable = 1'b1;
         @(posedge clk);
      end
   endtask

   task mount_image;
      input [31:0] blocks;
      begin : mi
         integer guard;
         @(posedge clk); #1;
         img_blocks  = blocks;
         img_mounted = 1'b1;
         @(posedge clk); #1;
         img_mounted = 1'b0;
         // Wait for the TOC lead-out conversion to finish (two divide passes).
         // On a REMOUNT toc_ready is still set from the previous disc at this
         // point -- the converter has not seen the mount strobe yet -- so
         // polling it directly returns immediately and the caller then races a
         // conversion that has not started. Wait for the converter to pick the
         // strobe up (toc_ready drops) before waiting for it to finish.
         guard = 0;
         while (dut.toc_ready && guard < 100) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         guard = 0;
         while (!dut.toc_ready && guard < 5000) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         if (!dut.toc_ready) $display("       WARNING: TOC never became ready");
      end
   endtask

   reg       timed_out = 1'b0;
   reg [7:0] sampled   = 8'h00;

   task select_target;
      begin : st
         integer guard;
         timed_out = 1'b0;
         din = (8'd1 << TARGET_ID);
         sel = 1'b1;
         @(posedge clk); #1;
         guard = 0;
         while (!bsy && guard < 2000) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         if (!bsy) begin
            timed_out = 1'b1;
            $display("       select_target: no BSY (mounted=%b cd_en=%b phase=%0d)",
                     dut.mounted, cd_enable, dut.phase);
         end
         sel = 1'b0;
         din = 8'h00;
         @(posedge clk);
      end
   endtask

   task xfer_byte;
      input [7:0] outbyte;
      begin : xb
         integer guard;
         timed_out = 1'b0;
         guard = 0;
         while (!req && guard < 5000) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         if (!req) begin
            timed_out = 1'b1;
         end else begin
            din     = outbyte;
            sampled = dout;
            ack = 1'b1;
            repeat (2) begin @(posedge clk); #1; end
            ack = 1'b0;
            repeat (4) begin @(posedge clk); #1; end
         end
      end
   endtask

   task send_cdb;
      input [7:0] b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11;
      input integer len;
      begin : sc
         reg [7:0] cdb [0:11];
         integer k;
         cdb[0]=b0;  cdb[1]=b1;  cdb[2]=b2;  cdb[3]=b3;
         cdb[4]=b4;  cdb[5]=b5;  cdb[6]=b6;  cdb[7]=b7;
         cdb[8]=b8;  cdb[9]=b9;  cdb[10]=b10; cdb[11]=b11;
         for (k = 0; k < len; k = k + 1)
            if (!timed_out) xfer_byte(cdb[k]);
      end
   endtask

   reg [7:0] buf_in [0:8191];
   integer   buf_len;
   task read_data_phase;
      input integer maxbytes;
      begin : rdp
         integer n, guard;
         n = 0;
         guard = 0;
         while (!timed_out && guard < 2000 &&
                phase_of(msg, cd, io) != P_DATA_OUT &&
                phase_of(msg, cd, io) != P_STATUS) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         while (!timed_out && n < maxbytes &&
                phase_of(msg, cd, io) == P_DATA_OUT) begin
            xfer_byte(8'h00);
            if (!timed_out) begin
               buf_in[n] = sampled;
               n = n + 1;
            end
         end
         buf_len = n;
      end
   endtask

   reg [7:0] status_byte;
   task finish_command;
      begin : fc
         integer guard;
         status_byte = 8'hff;
         guard = 0;
         while (!timed_out && phase_of(msg, cd, io) != P_STATUS && guard < 4000) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         if (phase_of(msg, cd, io) != P_STATUS) begin
            timed_out = 1'b1;
         end else begin
            xfer_byte(8'h00);
            status_byte = sampled;
            guard = 0;
            while (!timed_out && phase_of(msg, cd, io) != P_MSG && guard < 4000) begin
               @(posedge clk); #1;
               guard = guard + 1;
            end
            if (!timed_out && phase_of(msg, cd, io) == P_MSG) xfer_byte(8'h00);
            guard = 0;
            while (bsy && guard < 4000) begin
               @(posedge clk); #1;
               guard = guard + 1;
            end
         end
      end
   endtask

   // Issue a 6-byte command that returns no data, return its status.
   task simple_cmd6;
      input [7:0] b0, b1, b2, b3, b4, b5;
      begin
         select_target;
         send_cdb(b0,b1,b2,b3,b4,b5,0,0,0,0,0,0, 6);
         finish_command;
      end
   endtask

   // Fetch the current sense block into buf_in.
   task get_sense;
      begin
         select_target;
         send_cdb(8'h03,8'h00,8'h00,8'h00,8'h12,8'h00,0,0,0,0,0,0, 6);
         read_data_phase(32);
         finish_command;
      end
   endtask

   task report;
      input ok;
      input [1023:0] name;
      begin
         cd_total = cd_total + 1;
         if (ok) $display("PASS: %0s", name);
         else begin
            $display("FAIL: %0s", name);
            cd_fail = cd_fail + 1;
         end
         // A test that wedged the bus would otherwise take every later test
         // down with it and hide what actually broke. Recover deliberately and
         // say so, rather than reading 14 cascaded failures as 14 problems.
         if (timed_out) begin
            $display("       (bus wedged - resetting and remounting; later results are still independent)");
            do_reset;
            mount_image(IMG_BLOCKS);
         end
      end
   endtask

   // ======================================================================
   // Tests
   // ======================================================================
   integer i;
   reg ok;
   reg [7:0] expect_byte;

   initial begin
      $dumpfile("sim/out/tb_scsi_cdrom.vcd");
      $dumpvars(0, tb_scsi_cdrom);

      $display("-- CD-ROM target, ID %0d --", TARGET_ID);
      do_reset;

      // ==================================================================
      // Test 1: the drive is on the bus with NO disc. A real AppleCD answers
      // selection with an empty tray -- the driver polls TEST UNIT READY to
      // notice an insertion, which it can only do if the target replies.
      // ==================================================================
      select_target;
      send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6); // TEST UNIT READY
      finish_command;
      ok = (!timed_out) && (status_byte == 8'h02);   // CHECK: not ready
      report(ok, "cd1 - drive answers selection with no disc, TUR CHECKs");
      if (!ok) $display("       (timeout=%b status=%02x)", timed_out, status_byte);

      // ==================================================================
      // Test 2: and the sense says NOT READY with the AppleCD vendor "no
      // disc" ASC 0xB0 -- deliberately NOT 0x3A, which makes MacOS hammer
      // the drive asking the user to format it.
      // ==================================================================
      get_sense;
      ok = (!timed_out) && (status_byte == 8'h00) && (buf_len == 18)
           && (buf_in[2] === 8'h02) && (buf_in[12] === 8'hb0);
      report(ok, "cd2 - no-disc sense is NOT READY / ASC B0");
      if (!ok) $display("       (len=%0d key=%02x asc=%02x)", buf_len, buf_in[2], buf_in[12]);

      // ==================================================================
      // Test 3: cd_enable low = the drive is not on the bus at all, so the
      // SCSI bus is bit-identical to a pre-CD build. This is the A/B lever.
      // ==================================================================
      begin : t3
         integer guard;
         cd_enable = 1'b0;
         din = (8'd1 << TARGET_ID);
         sel = 1'b1;
         guard = 0;
         while (!bsy && guard < 200) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         ok = !bsy;
         sel = 1'b0; din = 8'h00;
         cd_enable = 1'b1;
         repeat (4) @(posedge clk);
      end
      report(ok, "cd3 - cd_enable=0 makes the target invisible on the bus");

      // ==================================================================
      // Test 4: identity. Apple's CD-ROM extension binds only to drives it
      // recognises, so the SONY CDU-8004 string IS the compatibility.
      // ==================================================================
      mount_image(IMG_BLOCKS);
      select_target;
      send_cdb(8'h12,8'h00,8'h00,8'h00,8'h36,8'h00,0,0,0,0,0,0, 6); // INQUIRY, alloc 54
      read_data_phase(64);
      finish_command;
      begin : t4
         reg [7:0] want [0:11];
         want[0]="S"; want[1]="O"; want[2]="N"; want[3]="Y";
         want[4]=" "; want[5]=" "; want[6]=" "; want[7]=" ";
         want[8]="C"; want[9]="D"; want[10]="-"; want[11]="R";
         ok = (!timed_out) && (buf_len == 54) && (status_byte == 8'h00)
              && (buf_in[0] === 8'h05)    // CD-ROM device class
              && (buf_in[1] === 8'h80)    // removable
              && (buf_in[4] === 8'h31);   // additional length
         for (i = 0; i < 12; i = i + 1)
            if (buf_in[8+i] !== want[i]) ok = 0;
         // product should read "CD-ROM CDU-8004"
         if (buf_in[23] !== "C" || buf_in[24] !== "D" || buf_in[25] !== "U" ||
             buf_in[27] !== "8" || buf_in[30] !== "4") ok = 0;
      end
      report(ok, "cd4 - INQUIRY is a SONY CDU-8004, 54 bytes, removable CD class");
      if (!ok) $display("       (len=%0d b0=%02x b1=%02x b4=%02x)",
                        buf_len, buf_in[0], buf_in[1], buf_in[4]);

      // ==================================================================
      // Test 5: READ CAPACITY reports 2048-byte logical blocks and the last
      // LBA in those units -- not the 512-byte HPS block count.
      // ==================================================================
      select_target;
      send_cdb(8'h25,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0, 10);
      read_data_phase(16);
      finish_command;
      begin : t5
         reg [31:0] got;
         got = {buf_in[0], buf_in[1], buf_in[2], buf_in[3]};
         ok = (!timed_out) && (buf_len == 8) && (status_byte == 8'h00)
              && (got == CD_CAP) && (buf_in[6] === 8'h08);  // 0x0800 = 2048
         if (!ok) $display("       (len=%0d cap=%0d want=%0d blk_hi=%02x)",
                           buf_len, got, CD_CAP, buf_in[6]);
      end
      report(ok, "cd5 - READ CAPACITY: last LBA in 2048-byte blocks, block len 2048");

      // ==================================================================
      // Test 6: a READ of ONE 2048-byte logical block must pull FOUR
      // consecutive 512-byte HPS sectors and hand back 2048 bytes. This is
      // the lba/tlen <<2 scaling -- the single most load-bearing line in the
      // CD data path.
      // ==================================================================
      io_rd_count = 0;
      select_target;
      // READ(6) logical block 100 -> HPS sectors 400..403
      send_cdb(8'h08,8'h00,8'h00,8'd100,8'h01,8'h00,0,0,0,0,0,0, 6);
      read_data_phase(2048);
      finish_command;
      begin : t6
         integer sec;
         ok = (!timed_out) && (buf_len == 2048) && (status_byte == 8'h00)
              && (io_rd_count == 4);
         if (ok)
            for (i = 0; i < 2048; i = i + 1) begin
               sec = 400 + (i / 512);
               expect_byte = sec[7:0] ^ (i % 512);
               if (buf_in[i] !== expect_byte) begin
                  if (ok) $display("       first mismatch at %0d: got %02x want %02x",
                                   i, buf_in[i], expect_byte);
                  ok = 0;
               end
            end
         if (!ok) $display("       (len=%0d status=%02x fetches=%0d)",
                           buf_len, status_byte, io_rd_count);
      end
      report(ok, "cd6 - READ(6) of one 2048-block = 4 HPS sectors, byte-exact");

      // ==================================================================
      // Test 7: multi-block READ(10), the form a real driver uses.
      // ==================================================================
      io_rd_count = 0;
      select_target;
      // READ(10) logical block 50, length 3 -> HPS sectors 200..211, 6144 bytes
      send_cdb(8'h28,8'h00,8'h00,8'h00,8'h00,8'd50,8'h00,8'h00,8'd3,8'h00,0,0, 10);
      read_data_phase(6144);
      finish_command;
      begin : t7
         integer sec;
         ok = (!timed_out) && (buf_len == 6144) && (status_byte == 8'h00)
              && (io_rd_count == 12);
         if (ok)
            for (i = 0; i < 6144; i = i + 1) begin
               sec = 200 + (i / 512);
               expect_byte = sec[7:0] ^ (i % 512);
               if (buf_in[i] !== expect_byte) begin
                  if (ok) $display("       first mismatch at %0d: got %02x want %02x",
                                   i, buf_in[i], expect_byte);
                  ok = 0;
               end
            end
         if (!ok) $display("       (len=%0d fetches=%0d timeout=%b)",
                           buf_len, io_rd_count, timed_out);
      end
      report(ok, "cd7 - READ(10) multi-block scales lba and length by 4");

      // ==================================================================
      // Test 8: Apple READ TOC (0xC1) operation 00 -> first/last track.
      // The operation lives in the CONTROL byte's top two bits.
      // ==================================================================
      select_target;
      send_cdb(8'hc1,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h04,8'h00,0,0, 10);
      read_data_phase(16);
      finish_command;
      ok = (!timed_out) && (buf_len == 4) && (status_byte == 8'h00)
           && (buf_in[0] === 8'h01) && (buf_in[1] === 8'h01);
      report(ok, "cd8 - Apple READ TOC op 00: one track, first = last = 1");
      if (!ok) $display("       (len=%0d b0=%02x b1=%02x)", buf_len, buf_in[0], buf_in[1]);

      // ==================================================================
      // Test 9: Apple READ TOC operation 01 -> lead-out MSF in BCD. This is
      // the LBA->MSF divider's answer, and the image was picked so all three
      // fields are non-trivial (40:33:17).
      // ==================================================================
      select_target;
      send_cdb(8'hc1,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h04,8'h40,0,0, 10);
      read_data_phase(16);
      finish_command;
      ok = (!timed_out) && (buf_len == 4) && (status_byte == 8'h00)
           && (buf_in[0] === 8'h40) && (buf_in[1] === 8'h33) && (buf_in[2] === 8'h17);
      report(ok, "cd9 - Apple READ TOC op 01: lead-out 40:33:17 BCD");
      if (!ok) $display("       (len=%0d got %02x:%02x:%02x want 40:33:17)",
                        buf_len, buf_in[0], buf_in[1], buf_in[2]);

      // ==================================================================
      // Test 10: Apple READ TOC operation 10 -> track descriptor. Track 1 is
      // a data track (ADR/control 0x14) starting at LBA 0.
      // ==================================================================
      select_target;
      send_cdb(8'hc1,8'h00,8'h00,8'h00,8'h00,8'h01,8'h00,8'h00,8'h04,8'h80,0,0, 10);
      read_data_phase(16);
      finish_command;
      ok = (!timed_out) && (buf_len == 4) && (status_byte == 8'h00)
           && (buf_in[0] === 8'h14) && (buf_in[1] === 8'h00)
           && (buf_in[2] === 8'h00) && (buf_in[3] === 8'h00);
      report(ok, "cd10 - Apple READ TOC op 10: track 1 is data (0x14) at 00:00:00");
      if (!ok) $display("       (len=%0d %02x %02x %02x %02x)",
                        buf_len, buf_in[0], buf_in[1], buf_in[2], buf_in[3]);

      // ==================================================================
      // Test 11: the standard MMC READ TOC (0x43). Different plane, and the
      // difference is easy to get wrong: this one is binary, not BCD, and
      // carries the 150-frame pre-gap, so track 1 sits at 00:02:00 and the
      // lead-out at 40:35:17.
      // ==================================================================
      select_target;
      send_cdb(8'h43,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'd20,8'h00,0,0, 10);
      read_data_phase(64);
      finish_command;
      ok = (!timed_out) && (buf_len == 20) && (status_byte == 8'h00)
           && (buf_in[0] === 8'h00) && (buf_in[1] === 8'd18)  // data length
           && (buf_in[2] === 8'h01) && (buf_in[3] === 8'h01)  // first/last track
           && (buf_in[5] === 8'h14) && (buf_in[6] === 8'h01)  // track 1, data
           && (buf_in[9] === 8'd0) && (buf_in[10] === 8'd2) && (buf_in[11] === 8'd0)
           && (buf_in[13] === 8'h14) && (buf_in[14] === 8'hAA) // lead-out
           && (buf_in[17] === 8'd40) && (buf_in[18] === 8'd35) && (buf_in[19] === 8'd17);
      report(ok, "cd11 - standard READ TOC 0x43: binary MSF, +150 pre-gap");
      if (!ok) begin
         $display("       (len=%0d hdr %02x %02x %02x %02x)",
                  buf_len, buf_in[0], buf_in[1], buf_in[2], buf_in[3]);
         $display("       trk1 %02x %02x @ %0d:%0d:%0d   lo %02x %02x @ %0d:%0d:%0d",
                  buf_in[5], buf_in[6], buf_in[9], buf_in[10], buf_in[11],
                  buf_in[13], buf_in[14], buf_in[17], buf_in[18], buf_in[19]);
      end

      // ==================================================================
      // Test 12: 0x43 must serve EXACTLY the allocation length, zero-filled
      // past the real 20 bytes. Under-serving deadlocks the Mac's blind
      // transfer primitive, which arms the full allocation and pumps for it.
      // ==================================================================
      select_target;
      send_cdb(8'h43,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'd32,8'h00,0,0, 10);
      read_data_phase(64);
      finish_command;
      ok = (!timed_out) && (buf_len == 32) && (status_byte == 8'h00)
           && (buf_in[1] === 8'd18);
      if (ok)
         for (i = 20; i < 32; i = i + 1)
            if (buf_in[i] !== 8'h00) ok = 0;
      report(ok, "cd12 - 0x43 serves the full allocation, zero-filled past 20");
      if (!ok) $display("       (len=%0d want 32)", buf_len);

      // ==================================================================
      // Test 13: MODE SENSE page 0x30, the "magic Apple page" some Apple
      // drivers probe. Also pins the write-protect bit and 2048 block size.
      // ==================================================================
      select_target;
      send_cdb(8'h1a,8'h00,8'h30,8'h00,8'd36,8'h00,0,0,0,0,0,0, 6);
      read_data_phase(64);
      finish_command;
      begin : t13
         reg [7:0] magic [0:12];
         magic[0]="A"; magic[1]="P"; magic[2]="P"; magic[3]="L"; magic[4]="E";
         magic[5]=" "; magic[6]="C"; magic[7]="O"; magic[8]="M"; magic[9]="P";
         magic[10]="U"; magic[11]="T"; magic[12]="E";
         ok = (!timed_out) && (buf_len == 36) && (status_byte == 8'h00)
              && (buf_in[0] === 8'd35)    // mode data length
              && (buf_in[2] === 8'h80)    // write protected
              && (buf_in[3] === 8'd8)     // block descriptor length
              && (buf_in[10] === 8'h08)   // block length 2048
              && (buf_in[12] === 8'h30);  // page code
         for (i = 0; i < 13; i = i + 1)
            if (buf_in[14+i] !== magic[i]) ok = 0;
      end
      report(ok, "cd13 - MODE SENSE page 30: WP, 2048 blocks, Apple magic page");
      if (!ok) $display("       (len=%0d b0=%02x b2=%02x b10=%02x b12=%02x)",
                        buf_len, buf_in[0], buf_in[2], buf_in[10], buf_in[12]);

      // ==================================================================
      // Test 14: the CD is READ-ONLY. WRITE must CHECK with ILLEGAL REQUEST
      // rather than quietly pretending, as a real AppleCD does.
      // ==================================================================
      simple_cmd6(8'h0a,8'h00,8'h00,8'h01,8'h01,8'h00);   // WRITE(6)
      begin : t14
         reg [7:0] wr_status;
         wr_status = status_byte;
         get_sense;
         ok = (!timed_out) && (wr_status == 8'h02)
              && (buf_in[2] === 8'h05) && (buf_in[12] === 8'h20);
         if (!ok) $display("       (wr_status=%02x key=%02x asc=%02x)",
                           wr_status, buf_in[2], buf_in[12]);
      end
      report(ok, "cd14 - WRITE rejected: ILLEGAL REQUEST / invalid opcode");

      // ==================================================================
      // Test 15: SET CD SPEED (0xBB) is a 12-byte CDB. Before Phase 1 it
      // would have wedged the bus outright; now it is an accepted no-op.
      // ==================================================================
      select_target;
      send_cdb(8'hbb,8'h00,8'h01,8'h76,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00, 12);
      finish_command;
      ok = (!timed_out) && (status_byte == 8'h00) && (!bsy);
      report(ok, "cd15 - SET CD SPEED (12-byte CDB) accepted as a no-op");
      if (!ok) $display("       (status=%02x timeout=%b bsy=%b)", status_byte, timed_out, bsy);

      // ==================================================================
      // Test 16: PREVENT MEDIUM REMOVAL locks the door -- an eject while
      // locked must CHECK and the medium must stay put.
      // ==================================================================
      simple_cmd6(8'h1e,8'h00,8'h00,8'h00,8'h01,8'h00);   // PREVENT
      begin : t16
         reg [7:0] prevent_status, eject_status;
         prevent_status = status_byte;
         // START/STOP UNIT with LoEj=1, Start=0 -> eject
         simple_cmd6(8'h1b,8'h00,8'h00,8'h00,8'h02,8'h00);
         eject_status = status_byte;
         get_sense;
         ok = (prevent_status == 8'h00) && (eject_status == 8'h02)
              && (buf_in[2] === 8'h05) && (buf_in[12] === 8'h80)
              && dut.mounted;
         if (!ok) $display("       (prevent=%02x eject=%02x key=%02x asc=%02x mounted=%b)",
                           prevent_status, eject_status, buf_in[2], buf_in[12], dut.mounted);
      end
      report(ok, "cd16 - eject blocked while PREVENT is set, medium stays");

      // ==================================================================
      // Test 17: ALLOW, then eject via the standard START/STOP form -- the
      // one the System 7 AppleCD driver actually uses. Missing this form
      // means `mounted` never drops and the driver silently remounts.
      // ==================================================================
      simple_cmd6(8'h1e,8'h00,8'h00,8'h00,8'h00,8'h00);   // ALLOW
      simple_cmd6(8'h1b,8'h00,8'h00,8'h00,8'h02,8'h00);   // START/STOP, LoEj
      begin : t17
         reg [7:0] eject_status;
         eject_status = status_byte;
         repeat (8) @(posedge clk);
         ok = (eject_status == 8'h00) && (!dut.mounted);
         if (!ok) $display("       (eject=%02x mounted=%b)", eject_status, dut.mounted);
      end
      report(ok, "cd17 - START/STOP LoEj ejects, mounted drops");

      // ==================================================================
      // Test 18: after the eject, the drive is still on the bus but reports
      // no disc -- and a fresh mount is the "disc inserted" edge that brings
      // it back, TOC and all.
      // ==================================================================
      select_target;
      send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6);
      finish_command;
      begin : t18
         reg [7:0] post_eject;
         post_eject = status_byte;
         mount_image(IMG_BLOCKS);
         select_target;
         send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6);
         finish_command;
         ok = (post_eject == 8'h02) && (!timed_out) && (status_byte == 8'h00)
              && dut.mounted && dut.toc_ready;
         if (!ok) $display("       (post_eject=%02x remount=%02x mounted=%b toc=%b)",
                           post_eject, status_byte, dut.mounted, dut.toc_ready);
      end
      report(ok, "cd18 - post-eject reports no disc, remount restores the drive");

      // ==================================================================
      // Test 19: READ SUB-CHANNEL, both dialects. No audio engine yet, so
      // the answer is "stopped at the start of track 1" in both.
      // ==================================================================
      select_target;
      send_cdb(8'hc2,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h09,8'h00,0,0, 10);
      read_data_phase(16);
      finish_command;
      begin : t19
         reg apple_ok;
         apple_ok = (!timed_out) && (buf_len == 9) && (status_byte == 8'h00)
                    && (buf_in[1] === 8'h01) && (buf_in[2] === 8'h01);
         select_target;
         send_cdb(8'h42,8'h02,8'h40,8'h01,8'h00,8'h00,8'h00,8'h00,8'd16,8'h00,0,0, 10);
         read_data_phase(32);
         finish_command;
         ok = apple_ok && (!timed_out) && (buf_len == 16) && (status_byte == 8'h00)
              && (buf_in[1] === 8'h13)   // audio status: stopped
              && (buf_in[3] === 8'd12)   // data length
              && (buf_in[5] === 8'h14) && (buf_in[6] === 8'h01) && (buf_in[7] === 8'h01);
         if (!ok) $display("       (apple_ok=%b len=%0d ast=%02x dlen=%02x)",
                           apple_ok, buf_len, buf_in[1], buf_in[3]);
      end
      report(ok, "cd19 - READ SUB-CHANNEL (0xC2 and 0x42) report track 1, stopped");

      // ==================================================================
      // Test 20: READ HEADER LBA form serves mode 1 + the echoed address;
      // the MSF form is cleanly rejected rather than answered with a wrong
      // address, since this path has no LBA->MSF divide of its own.
      // ==================================================================
      select_target;
      send_cdb(8'h44,8'h00,8'h00,8'h00,8'h12,8'h34,8'h00,8'h00,8'd8,8'h00,0,0, 10);
      read_data_phase(16);
      finish_command;
      begin : t20
         reg lba_ok;
         lba_ok = (!timed_out) && (buf_len == 8) && (status_byte == 8'h00)
                  && (buf_in[0] === 8'h01)                       // mode 1, data
                  && (buf_in[6] === 8'h12) && (buf_in[7] === 8'h34);
         // MSF form: CDB[1] bit 1
         select_target;
         send_cdb(8'h44,8'h02,8'h00,8'h00,8'h12,8'h34,8'h00,8'h00,8'd8,8'h00,0,0, 10);
         finish_command;
         ok = lba_ok && (status_byte == 8'h02);
         if (ok) begin
            get_sense;
            ok = (buf_in[2] === 8'h05) && (buf_in[12] === 8'h24);
         end
         if (!ok) $display("       (lba_ok=%b msf_status=%02x key=%02x asc=%02x)",
                           lba_ok, status_byte, buf_in[2], buf_in[12]);
      end
      report(ok, "cd20 - READ HEADER: LBA form served, MSF form rejected 5/24");

      $display("");
      $display("PHASE 2 CD-ROM: %0d of %0d failing", cd_fail, cd_total);
      $display("");
      if (cd_fail == 0)
         $display("PHASE 2 CD GATE: PASS - AppleCD target behaves");
      else
         $display("PHASE 2 CD GATE: FAIL");
      $finish;
   end

   initial begin
      #20_000_000;
      $display("FAIL: global watchdog expired - simulation hung");
      $display("PHASE 2 CD GATE: FAIL (hung)");
      $finish;
   end

endmodule
