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

   reg  [2:0]  cd_ms_mode   = 3'd0;   // MODE SENSE content bisect

   localparam [2:0] TARGET_ID = 3'd3;   // AppleCD SC factory default

   scsi #(.ID(TARGET_ID), .CDROM(1), .WDOG_LOG(11)) dut   // ~20us watchdog for sim (bench guards are 4000 clks)
   (
      .clk(clk),

      .rst(rst),
      .sys_rst(sys_rst),
      .bus_busy(bus_busy),
      .cd_enable(cd_enable),
      .cd_dbg(3'd0),
      .cd_ms_mode(cd_ms_mode),
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

   // Mount without waiting for the lead-out conversion, so a command can be
   // issued inside the not-ready window on purpose.
   task mount_image_nowait;
      input [31:0] blocks;
      begin
         @(posedge clk); #1;
         img_blocks  = blocks;
         img_mounted = 1'b1;
         @(posedge clk); #1;
         img_mounted = 1'b0;
      end
   endtask

   // Records whether the TOC conversion was actually still running while a
   // command was in flight, so the test asserts on the real condition rather
   // than racing it.
   reg watch_toc    = 1'b0;
   reg saw_toc_busy = 1'b0;
   always @(posedge clk) if (watch_toc && !dut.toc_ready) saw_toc_busy <= 1'b1;

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

   // BLIND transfer, the way the Mac's pseudo-DMA primitive actually works: it
   // arms for the FULL allocation length and pumps for exactly that many bytes.
   // read_data_phase() above is adaptive -- it follows the target's phase -- so
   // it silently tolerates a target that ends the data phase early. Real
   // hardware does not: the host sits armed for bytes that never arrive, takes
   // BERR beats, the SCSI Manager retries, and the machine wedges. That is the
   // 2026-08-20 boot hang (MODE SENSE page 0x0E served 12 bytes for a 28-byte
   // page), and the adaptive model is exactly why the bench missed it.
   integer blind_got;
   reg     blind_short;
   task read_blind;
      input integer want;
      begin : rb
         integer n, guard;
         n = 0; guard = 0;
         while (!timed_out && guard < 2000 &&
                phase_of(msg, cd, io) != P_DATA_OUT &&
                phase_of(msg, cd, io) != P_STATUS) begin
            @(posedge clk); #1; guard = guard + 1;
         end
         while (!timed_out && n < want && phase_of(msg, cd, io) == P_DATA_OUT) begin
            xfer_byte(8'h00);
            if (!timed_out) begin buf_in[n] = sampled; n = n + 1; end
         end
         blind_got   = n;
         blind_short = (n < want);   // target went early -> real Mac deadlocks
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

      // ==================================================================
      // Test 21: a command issued while the lead-out MSF conversion is still
      // running must report NOT READY, not serve the PREVIOUS disc's TOC.
      // Quartus caught this as "toc_ready assigned but never read" -- the
      // readiness flag existed but gated nothing, so a disc swap could hand
      // back the old disc's lead-out for ~150 cycles.
      // ==================================================================
      do_reset;
      mount_image(IMG_BLOCKS);          // settle on a known disc first
      saw_toc_busy = 1'b0;
      watch_toc    = 1'b1;
      mount_image_nowait(IMG_BLOCKS);   // ...then swap without waiting
      select_target;
      send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6);  // TEST UNIT READY
      finish_command;
      watch_toc = 1'b0;
      begin : t21
         reg [7:0] busy_status;
         busy_status = status_byte;
         // and once the conversion finishes, the drive is ready again
         mount_image(IMG_BLOCKS);
         select_target;
         send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6);
         finish_command;
         if (!saw_toc_busy) begin
            $display("       INCONCLUSIVE: never caught the conversion window");
            ok = 0;
         end else begin
            ok = (busy_status == 8'h02) && (!timed_out) && (status_byte == 8'h00);
         end
         if (!ok) $display("       (busy_status=%02x ready_status=%02b saw_busy=%b)",
                           busy_status, status_byte, saw_toc_busy);
      end
      report(ok, "cd21 - commands report NOT READY while the TOC is still converting");

      // ==================================================================
      // Test 22: MODE SENSE page 0x0E (CD Audio Control). The AppleCD driver
      // asks for this page directly at startup. Serving the bare 12-byte
      // header instead of the full 28 is what hung the Mac on hardware.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      select_target;
      send_cdb(8'h1a,8'h00,8'h0e,8'h00,8'd28,8'h00,0,0,0,0,0,0, 6);
      read_blind(28);
      finish_command;
      ok = (!timed_out) && (!blind_short) && (blind_got == 28)
           && (buf_in[0]  === 8'd27)   // mode data length = 28-1
           && (buf_in[12] === 8'h0e)   // page code
           && (buf_in[13] === 8'h0e);  // page length = 14
      report(ok, "cd22 - MODE SENSE page 0E serves all 28 bytes (the boot-hang page)");
      if (!ok) $display("       (got=%0d short=%b b0=%02x b12=%02x b13=%02x)",
                        blind_got, blind_short, buf_in[0], buf_in[12], buf_in[13]);

      // ==================================================================
      // Test 23: MODE SENSE page 0x2A (MM Capabilities), 38 bytes.
      // ==================================================================
      select_target;
      send_cdb(8'h1a,8'h00,8'h2a,8'h00,8'd38,8'h00,0,0,0,0,0,0, 6);
      read_blind(38);
      finish_command;
      ok = (!timed_out) && (!blind_short) && (blind_got == 38)
           && (buf_in[0]  === 8'd37)
           && (buf_in[12] === 8'h2a)
           && (buf_in[13] === 8'h18);
      report(ok, "cd23 - MODE SENSE page 2A serves all 38 bytes");
      if (!ok) $display("       (got=%0d short=%b b0=%02x b12=%02x b13=%02x)",
                        blind_got, blind_short, buf_in[0], buf_in[12], buf_in[13]);

      // ==================================================================
      // Test 24: THE GENERAL GUARD. For every MODE SENSE page the driver may
      // ask for, arm a blind transfer for that page's real size and require
      // the target to deliver all of it. This is the invariant that was
      // missing: an under-served page is invisible to an adaptive initiator
      // and fatal to a real one.
      // ==================================================================
      begin : t24
         integer k, want, bad;
         reg [7:0] pages [0:4];
         integer   lens  [0:4];
         pages[0]=8'h01; lens[0]=12;   // unsupported page -> header only
         pages[1]=8'h0e; lens[1]=28;
         pages[2]=8'h2a; lens[2]=38;
         pages[3]=8'h30; lens[3]=36;
         pages[4]=8'h3f; lens[4]=12;   // "all pages" -> header only
         bad = 0;
         for (k = 0; k < 5; k = k + 1) begin
            want = lens[k];
            select_target;
            send_cdb(8'h1a,8'h00,pages[k],8'h00,want[7:0],8'h00,0,0,0,0,0,0, 6);
            read_blind(want);
            finish_command;
            // byte 0 must also agree with what was actually served
            if (blind_short || (blind_got != want) || (buf_in[0] !== (want-1))) begin
               $display("       page %02x: armed %0d got %0d short=%b b0=%02x",
                        pages[k], want, blind_got, blind_short, buf_in[0]);
               bad = bad + 1;
            end
         end
         ok = (bad == 0);
      end
      report(ok, "cd24 - every MODE SENSE page satisfies a blind transfer of its real size");

      // ==================================================================
      // Test 25: THE FULL BLIND-TRANSFER GUARD. Every CD command that returns
      // data must deliver exactly the number of bytes the initiator armed for.
      // The Mac's pseudo-DMA is blind: it pumps for the full allocation and
      // wedges if the target stops short. MODE SENSE page 0x0E cost a hardware
      // cycle proving that; this sweeps the rest of the command set, including
      // OVER-armed allocations, where a fixed-size response would strand the
      // host the same way.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t25
         integer bad;
         bad = 0;

         // --- 6-byte CDBs: allocation in CDB[4]
         // INQUIRY at the full CD response size, and over-armed
         select_target; send_cdb(8'h12,0,0,0,8'd54,0,0,0,0,0,0,0, 6);
         read_blind(54); finish_command;
         if (blind_short) begin bad=bad+1; $display("       INQUIRY(54): got %0d", blind_got); end

         // REQUEST SENSE
         select_target; send_cdb(8'h03,0,0,0,8'd18,0,0,0,0,0,0,0, 6);
         read_blind(18); finish_command;
         if (blind_short) begin bad=bad+1; $display("       REQUEST SENSE(18): got %0d", blind_got); end

         // --- 10-byte CDBs: allocation in CDB[7:8]
         // READ CAPACITY (fixed 8, no allocation field)
         select_target; send_cdb(8'h25,0,0,0,0,0,0,0,0,0,0,0, 10);
         read_blind(8); finish_command;
         if (blind_short) begin bad=bad+1; $display("       READ CAPACITY(8): got %0d", blind_got); end

         // Apple READ TOC, all three ops, armed EXACTLY
         select_target; send_cdb(8'hc1,0,0,0,0,0,0,8'h00,8'd4,8'h00,0,0, 10);
         read_blind(4); finish_command;
         if (blind_short) begin bad=bad+1; $display("       C1 op00(4): got %0d", blind_got); end
         select_target; send_cdb(8'hc1,0,0,0,0,0,0,8'h00,8'd4,8'h40,0,0, 10);
         read_blind(4); finish_command;
         if (blind_short) begin bad=bad+1; $display("       C1 op01(4): got %0d", blind_got); end
         select_target; send_cdb(8'hc1,0,0,0,0,8'h01,0,8'h00,8'd8,8'h80,0,0, 10);
         read_blind(8); finish_command;
         if (blind_short) begin bad=bad+1; $display("       C1 op10(8): got %0d", blind_got); end

         // Apple READ TOC OVER-ARMED -- the case a fixed 4-byte response strands
         select_target; send_cdb(8'hc1,0,0,0,0,0,0,8'h00,8'd32,8'h00,0,0, 10);
         read_blind(32); finish_command;
         if (blind_short) begin bad=bad+1; $display("       C1 op00 OVER-ARMED(32): got %0d", blind_got); end

         // READ Q SUBCODE, exact and over-armed
         select_target; send_cdb(8'hc2,0,0,0,0,0,0,8'h00,8'd9,8'h00,0,0, 10);
         read_blind(9); finish_command;
         if (blind_short) begin bad=bad+1; $display("       C2(9): got %0d", blind_got); end
         select_target; send_cdb(8'hc2,0,0,0,0,0,0,8'h00,8'd24,8'h00,0,0, 10);
         read_blind(24); finish_command;
         if (blind_short) begin bad=bad+1; $display("       C2 OVER-ARMED(24): got %0d", blind_got); end

         // AUDIO STATUS, exact and over-armed
         select_target; send_cdb(8'hcc,0,0,0,0,0,0,8'h00,8'd6,8'h00,0,0, 10);
         read_blind(6); finish_command;
         if (blind_short) begin bad=bad+1; $display("       CC(6): got %0d", blind_got); end
         select_target; send_cdb(8'hcc,0,0,0,0,0,0,8'h00,8'd16,8'h00,0,0, 10);
         read_blind(16); finish_command;
         if (blind_short) begin bad=bad+1; $display("       CC OVER-ARMED(16): got %0d", blind_got); end

         // standard READ TOC / READ SUB-CHANNEL / READ HEADER
         select_target; send_cdb(8'h43,0,0,0,0,0,0,8'h00,8'd20,8'h00,0,0, 10);
         read_blind(20); finish_command;
         if (blind_short) begin bad=bad+1; $display("       43(20): got %0d", blind_got); end
         select_target; send_cdb(8'h42,8'h02,8'h40,8'h01,0,0,0,8'h00,8'd16,8'h00,0,0, 10);
         read_blind(16); finish_command;
         if (blind_short) begin bad=bad+1; $display("       42(16): got %0d", blind_got); end
         select_target; send_cdb(8'h44,0,0,0,8'h12,8'h34,0,8'h00,8'd8,8'h00,0,0, 10);
         read_blind(8); finish_command;
         if (blind_short) begin bad=bad+1; $display("       44(8): got %0d", blind_got); end

         ok = (bad == 0);
      end
      report(ok, "cd25 - every CD data command satisfies a blind transfer, incl. over-armed");

      // ==================================================================
      // Test 26: NO CDB MAY WEDGE THE BUS. Lengths are defined for groups
      // 0/1/2/5 and 0xC0-0xCF; groups 3, 4, 7 and 0xD0-0xDF are not, so
      // cmd_cpl can never assert for them and the target would sit in COMMAND
      // phase holding BSY forever -- which, because bus_busy gates every other
      // target, freezes the whole machine including the boot disk. That is the
      // 2026-08-20 hang at "Welcome to Macintosh".
      //
      // Also covers the disputed 0xC0 EJECT length: MAME says 10 bytes,
      // BlueSCSI says 6. If the driver sends 6 and we wait for 10, same wedge.
      // The watchdog must turn every one of these into a released bus.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t26
         integer k, bad;
         reg [7:0] ops [0:5];
         integer   lens [0:5];
         ops[0]=8'h60; lens[0]=6;    // group 3, undefined length
         ops[1]=8'h80; lens[1]=6;    // group 4, undefined length
         ops[2]=8'hd0; lens[2]=6;    // group 6 outside the Apple range
         ops[3]=8'he0; lens[3]=6;    // group 7, vendor
         ops[4]=8'hc0; lens[4]=6;    // EJECT sent as 6 bytes, not 10
         ops[5]=8'h28; lens[5]=6;    // a 10-byte opcode truncated to 6
         bad = 0;
         for (k = 0; k < 6; k = k + 1) begin
            select_target;
            send_cdb(ops[k],0,0,0,0,0,0,0,0,0,0,0, lens[k]);
            finish_command;
            if (timed_out || bsy) begin
               $display("       op %02h (%0d-byte CDB): WEDGED (timeout=%b bsy=%b)",
                        ops[k], lens[k], timed_out, bsy);
               bad = bad + 1;
               do_reset; mount_image(IMG_BLOCKS);
            end
         end
         ok = (bad == 0);
      end
      report(ok, "cd26 - no CDB of any group can wedge the bus (watchdog recovers)");

      // ==================================================================
      // Test 27: and the abort is diagnosable -- the sense block reports
      // ABORTED COMMAND with the stalling opcode in the ASC byte, which is
      // the only channel out of the target when this happens on hardware.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      select_target;
      send_cdb(8'he0,0,0,0,0,0,0,0,0,0,0,0, 6);
      finish_command;
      get_sense;
      ok = (!timed_out) && (buf_in[2] === 8'h0b) && (buf_in[12] === 8'he0);
      report(ok, "cd27 - aborted command reports ABORTED COMMAND + the opcode");
      if (!ok) $display("       (key=%02x asc=%02x want 0b/e0)", buf_in[2], buf_in[12]);

      // ==================================================================
      // Test 28: MODE SENSE with an OVER-ARMED allocation. cd24 arms each page
      // at its real size, so alloc == the target's own idea of the length and
      // the clamp in data_len is a no-op -- the bench encoded the same
      // assumption as the RTL. A real driver does not do that: it arms a
      // generous fixed buffer (0xff, 0x40) and/or asks for page 0x3f, then
      // pumps blind for every byte it armed. Serving the page's real size
      // instead of the allocation strands it forever. This is the level-5
      // ("+MODE") hang seen on hardware 2026-08-21.
      //
      // Byte 0 must still report the REAL data length, not the allocation --
      // that is how the host knows where the padding starts.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t28
         integer k, bad;
         reg [7:0] pages [0:4];
         integer   reals [0:4];
         integer   arms  [0:4];
         pages[0]=8'h0e; reals[0]=28; arms[0]=255;  // the page the driver asks for
         pages[1]=8'h2a; reals[1]=38; arms[1]=255;
         pages[2]=8'h30; reals[2]=36; arms[2]=64;
         pages[3]=8'h3f; reals[3]=12; arms[3]=255;  // "all pages"
         pages[4]=8'h01; reals[4]=12; arms[4]=48;   // unsupported page
         bad = 0;
         for (k = 0; k < 5; k = k + 1) begin
            select_target;
            send_cdb(8'h1a,8'h00,pages[k],8'h00,arms[k][7:0],8'h00,0,0,0,0,0,0, 6);
            read_blind(arms[k]);
            finish_command;
            if (blind_short || (blind_got != arms[k]) || (buf_in[0] !== (reals[k]-1))) begin
               $display("       page %02x: armed %0d got %0d short=%b b0=%02x (want b0=%02x)",
                        pages[k], arms[k], blind_got, blind_short, buf_in[0], reals[k]-1);
               bad = bad + 1;
            end
         end
         ok = (bad == 0);
      end
      report(ok, "cd28 - MODE SENSE satisfies an OVER-armed blind transfer");

      // ==================================================================
      // Test 29: the MODE SENSE content bisect itself. An instrument that has
      // never been exercised is not evidence -- the debug ladder shipped with
      // levels 1 and 2 silently gating out REQUEST SENSE, which would have
      // made a hang there unreadable. So prove this one before trusting it.
      //
      // Bare mode must: declare 4 bytes of mode data (byte 0 = 3), declare NO
      // block descriptor (byte 3 = 0), carry no page bytes, and still satisfy
      // the initiator's full armed allocation -- the transfer length must be
      // identical to full mode, so that length is held constant across the
      // bisect and only CONTENT varies.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t29
         integer bad, k;
         bad = 0;
         cd_ms_mode = 3'd1;
         // over-armed, and for a page that has real content in full mode
         select_target;
         send_cdb(8'h1a,8'h00,8'h0e,8'h00,8'd255,8'h00,0,0,0,0,0,0, 6);
         read_blind(255);
         finish_command;
         if (blind_short || (blind_got != 255)) begin
            $display("       bare: armed 255 got %0d short=%b", blind_got, blind_short);
            bad = bad + 1;
         end
         if (buf_in[0] !== 8'd3)    begin $display("       bare: byte0=%02x want 03", buf_in[0]); bad=bad+1; end
         if (buf_in[3] !== 8'd0)    begin $display("       bare: byte3=%02x want 00 (no block desc)", buf_in[3]); bad=bad+1; end
         if (buf_in[2] !== 8'h80)   begin $display("       bare: byte2=%02x want 80 (WP)", buf_in[2]); bad=bad+1; end
         // nothing past the 4-byte header may be non-zero
         for (k = 4; k < 255; k = k + 1)
            if (buf_in[k] !== 8'h00) bad = bad + 1;

         // and the switch must be a true no-op when clear: full mode unchanged
         cd_ms_mode = 3'd0;
         select_target;
         send_cdb(8'h1a,8'h00,8'h0e,8'h00,8'd255,8'h00,0,0,0,0,0,0, 6);
         read_blind(255);
         finish_command;
         if (blind_short || (blind_got != 255) || (buf_in[0] !== 8'd27) ||
             (buf_in[3] !== 8'd8) || (buf_in[12] !== 8'h0e)) begin
            $display("       full: b0=%02x b3=%02x b12=%02x got %0d (want 1b/08/0e/255)",
                     buf_in[0], buf_in[3], buf_in[12], blind_got);
            bad = bad + 1;
         end
         ok = (bad == 0);
      end
      report(ok, "cd29 - MODE SENSE bare-header bisect is correct and reverts cleanly");

      // ==================================================================
      // Test 30: the two middle bisect states. Each must be a response a real
      // drive could legitimately give, and each must differ from its neighbour
      // in exactly ONE component -- otherwise a hardware result cannot be
      // attributed. Transfer length is held constant across all states so that
      // length is never the variable under test.
      //
      //   state 2: header + block descriptor, no pages  (mode data length 11)
      //   state 3: state 2 + page code and declared length, payload zeroed
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t30
         integer bad, k;
         reg [7:0] desc2 [4:11];
         bad = 0;

         // ---- state 2: header + block descriptor, nothing after byte 11
         cd_ms_mode = 3'd2;
         select_target;
         send_cdb(8'h1a,8'h00,8'h0e,8'h00,8'd255,8'h00,0,0,0,0,0,0, 6);
         read_blind(255); finish_command;
         if (blind_short || (blind_got != 255)) begin
            $display("       s2: armed 255 got %0d short=%b", blind_got, blind_short); bad=bad+1; end
         if (buf_in[0] !== 8'd11) begin $display("       s2: byte0=%02x want 0b", buf_in[0]); bad=bad+1; end
         if (buf_in[3] !== 8'd8)  begin $display("       s2: byte3=%02x want 08", buf_in[3]); bad=bad+1; end
         if (buf_in[10] !== 8'h08)begin $display("       s2: byte10=%02x want 08", buf_in[10]); bad=bad+1; end
         for (k = 12; k < 255; k = k + 1)
            if (buf_in[k] !== 8'h00) bad = bad + 1;   // no page may appear
         for (k = 4; k <= 11; k = k + 1) desc2[k] = buf_in[k];

         // ---- state 3: adds ONLY the page shell; payload must stay zero
         cd_ms_mode = 3'd3;
         select_target;
         send_cdb(8'h1a,8'h00,8'h0e,8'h00,8'd255,8'h00,0,0,0,0,0,0, 6);
         read_blind(255); finish_command;
         if (buf_in[0] !== 8'd27) begin $display("       s3: byte0=%02x want 1b", buf_in[0]); bad=bad+1; end
         if (buf_in[3] !== 8'd8)  begin $display("       s3: byte3=%02x want 08", buf_in[3]); bad=bad+1; end
         if (buf_in[12] !== 8'h0e)begin $display("       s3: byte12=%02x want 0e", buf_in[12]); bad=bad+1; end
         if (buf_in[13] !== 8'h0e)begin $display("       s3: byte13=%02x want 0e", buf_in[13]); bad=bad+1; end
         for (k = 14; k < 255; k = k + 1)
            if (buf_in[k] !== 8'h00) bad = bad + 1;   // payload must be zeroed

         // the block descriptor must be IDENTICAL in states 2 and 3, so that a
         // difference between them on hardware is attributable to the page
         // shell alone -- that is the whole point of a one-component step
         for (k = 4; k <= 11; k = k + 1)
            if (buf_in[k] !== desc2[k]) begin
               $display("       s3: descriptor byte %0d = %02x, state 2 had %02x",
                        k, buf_in[k], desc2[k]);
               bad = bad + 1;
            end

         // ---- an unknown page in state 3 must not sprout a page shell
         cd_ms_mode = 3'd3;
         select_target;
         send_cdb(8'h1a,8'h00,8'h01,8'h00,8'd64,8'h00,0,0,0,0,0,0, 6);
         read_blind(64); finish_command;
         if (buf_in[0] !== 8'd11) begin $display("       s3/unknown: byte0=%02x want 0b", buf_in[0]); bad=bad+1; end
         for (k = 12; k < 64; k = k + 1)
            if (buf_in[k] !== 8'h00) bad = bad + 1;

         cd_ms_mode = 3'd0;
         ok = (bad == 0);
      end
      report(ok, "cd30 - bisect states 2 and 3 each add exactly one component");

      // ==================================================================
      // Test 31: the per-page payload states. Hardware exonerated the block
      // descriptor and the page code/length byte (states 1-3 all boot, full
      // hangs), so the fault is in a page BODY. States 4/5/6 suppress exactly
      // one page's body each; the state that boots names the page.
      //
      // The properties that make that inference valid, and so must hold here:
      //  - a state suppresses its OWN page's body and no other page's
      //  - byte 12 and byte 13 still come from the REAL response in all of
      //    them, so the body is the only thing that varies
      //  - a suppressed body is genuinely all zero
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t31
         integer bad, k, s, p;
         reg [7:0] pg  [0:2];
         integer   tot [0:2];
         reg [7:0] b13 [0:2];
         pg[0]=8'h30; tot[0]=36; b13[0]=8'h00;
         pg[1]=8'h0e; tot[1]=28; b13[1]=8'h0e;
         pg[2]=8'h2a; tot[2]=38; b13[2]=8'h18;
         bad = 0;

         for (s = 0; s < 3; s = s + 1) begin
            cd_ms_mode = 3'd4 + s[2:0];
            for (p = 0; p < 3; p = p + 1) begin
               select_target;
               send_cdb(8'h1a,8'h00,pg[p],8'h00,8'd255,8'h00,0,0,0,0,0,0, 6);
               read_blind(255);
               finish_command;
               if (buf_in[0] !== (tot[p]-1)) begin
                  $display("       s%0d/p%02x: byte0=%02x want %02x", 4+s, pg[p], buf_in[0], tot[p]-1);
                  bad = bad + 1; end
               if (buf_in[3] !== 8'd8) begin
                  $display("       s%0d/p%02x: byte3=%02x want 08", 4+s, pg[p], buf_in[3]);
                  bad = bad + 1; end
               if (buf_in[12] !== pg[p]) begin
                  $display("       s%0d/p%02x: byte12=%02x", 4+s, pg[p], buf_in[12]);
                  bad = bad + 1; end
               if (buf_in[13] !== b13[p]) begin
                  $display("       s%0d/p%02x: byte13=%02x want %02x", 4+s, pg[p], buf_in[13], b13[p]);
                  bad = bad + 1; end
               if (s == p)
                  for (k = 14; k < tot[p]; k = k + 1)
                     if (buf_in[k] !== 8'h00) begin
                        $display("       s%0d/p%02x: body byte %0d = %02x, want 00", 4+s, pg[p], k, buf_in[k]);
                        bad = bad + 1; end
            end
         end

         // a NON-targeted page must keep its real body: page 0x30 still says
         // "APPLE" while the 0x0E state is selected
         cd_ms_mode = 3'd5;
         select_target;
         send_cdb(8'h1a,8'h00,8'h30,8'h00,8'd255,8'h00,0,0,0,0,0,0, 6);
         read_blind(255); finish_command;
         if ((buf_in[14] !== "A") || (buf_in[15] !== "P") || (buf_in[18] !== "E")) begin
            $display("       s5/p30: body suppressed but should not be (%02x %02x %02x)",
                     buf_in[14], buf_in[15], buf_in[18]);
            bad = bad + 1;
         end

         cd_ms_mode = 3'd0;
         ok = (bad == 0);
      end
      report(ok, "cd31 - per-page body states suppress one page each, shells intact");

      // ==================================================================
      // Test 32: the Apple vendor commands, armed PAST their internal caps.
      //
      // cd25 claims to sweep over-armed allocations, and it does -- but only
      // past each command's REAL payload, never past the cap in data_len. So
      // min(alloc, cap) was a no-op in every existing test, exactly as
      // min(alloc, cd_ms_len) was for MODE SENSE before cd28. Same blind spot,
      // same class, and this one is now reachable: the magic page on MODE SENSE
      // page 0x30 makes the driver commit to the Apple path, so these commands
      // are the ones a real driver actually issues.
      //
      // Also covers cd_toc_len's ROUND-DOWN: for the 2'b10 form it serves
      // {alloc[31:2], 2'b00}, so any allocation that is not a multiple of 4
      // under-serves by 1..3 bytes -- and 1 byte short deadlocks a blind
      // initiator exactly as 227 bytes short does.
      // ==================================================================
      do_reset; mount_image(IMG_BLOCKS);
      begin : t32
         integer bad;
         bad = 0;

         // --- READ TOC (0xc1), non-MSF form: cap 64
         select_target; send_cdb(8'hc1,0,0,0,0,0,0,8'h00,8'd100,8'h00,0,0, 10);
         read_blind(100); finish_command;
         if (blind_short || (blind_got != 100)) begin
            $display("       c1 op0: armed 100 got %0d short=%b", blind_got, blind_short); bad=bad+1; end

         // --- READ TOC (0xc1), 2'b10 form with a NON-multiple-of-4 allocation
         select_target; send_cdb(8'hc1,0,0,0,0,0,0,8'h00,8'd6,8'h80,0,0, 10);
         read_blind(6); finish_command;
         if (blind_short || (blind_got != 6)) begin
            $display("       c1 op2: armed 6 got %0d short=%b (round-down)", blind_got, blind_short); bad=bad+1; end

         // --- READ Q SUBCODE (0xc2): cap 64
         select_target; send_cdb(8'hc2,0,0,0,0,0,0,8'h00,8'd100,8'h00,0,0, 10);
         read_blind(100); finish_command;
         if (blind_short || (blind_got != 100)) begin
            $display("       c2: armed 100 got %0d short=%b", blind_got, blind_short); bad=bad+1; end

         // --- AUDIO STATUS (0xcc): cap 64
         select_target; send_cdb(8'hcc,0,0,0,0,0,0,8'h00,8'd100,8'h00,0,0, 10);
         read_blind(100); finish_command;
         if (blind_short || (blind_got != 100)) begin
            $display("       cc: armed 100 got %0d short=%b", blind_got, blind_short); bad=bad+1; end

         // --- READ TOC (0x43): cap 512
         select_target; send_cdb(8'h43,0,0,0,0,0,0,8'h02,8'd88,8'h00,0,0, 10);
         read_blind(600); finish_command;
         if (blind_short || (blind_got != 600)) begin
            $display("       43: armed 600 got %0d short=%b", blind_got, blind_short); bad=bad+1; end

         // --- READ SUBCHANNEL (0x42): cap 64
         select_target; send_cdb(8'h42,8'h02,8'h40,8'h01,0,0,0,8'h00,8'd100,8'h00,0,0, 10);
         read_blind(100); finish_command;
         if (blind_short || (blind_got != 100)) begin
            $display("       42: armed 100 got %0d short=%b", blind_got, blind_short); bad=bad+1; end

         // --- READ HEADER (0x44): cap 16
         select_target; send_cdb(8'h44,0,0,0,8'h12,8'h34,0,8'h00,8'd40,8'h00,0,0, 10);
         read_blind(40); finish_command;
         if (blind_short || (blind_got != 40)) begin
            $display("       44: armed 40 got %0d short=%b", blind_got, blind_short); bad=bad+1; end

         ok = (bad == 0);
      end
      report(ok, "cd32 - Apple vendor commands satisfy allocations past their caps");

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
