`timescale 1ns/1ps
//
// Phase 0 of SCSI_UPGRADE_PLAN.md: a SCSI initiator model driving rtl/scsi.v's
// target directly, plus an hps_io block-device model, so the Phase 1
// conformance work can be proven rather than assumed.
//
// The initiator drives the REQ/ACK handshake the ncr5380 would: assert sel with
// the target's ID bit on din, then for every byte wait for req, present/sample
// data, pulse ack, wait for req to drop. The target latches on ack's rising edge
// (stb_ack) and advances its counters on the falling edge (stb_adv), so a single
// task serves both transfer directions.
//
// The hps_io model answers io_rd by streaming 256 words into the sector buffer
// through sd_buff_addr/sd_buff_dout/sd_buff_wr and then pulsing io_ack, mirroring
// how the real controller serves a block. Data is LBA-derived so a read can be
// checked byte-exact.
//
// Tests 1 and 2 are baseline guards that must pass today. Tests 3 and 4 are the
// two conformance defects from SCSI_UPGRADE_PLAN.md section 1 and are EXPECTED TO
// FAIL until Phase 1 lands -- that is the point of writing them first.
//
module tb_scsi_target;

   reg clk = 0;
   always #5 clk = ~clk;

   // ---- target bus ------------------------------------------------------
   reg        rst  = 1'b1;
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

   localparam [2:0] TARGET_ID = 3'd6;

   scsi #(.ID(TARGET_ID)) dut
   (
      .clk(clk),

      .rst(rst),
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

   integer all_ok = 1;      // baseline regression guards (must pass today)
   integer conform_fail = 0; // known conformance gaps (expected to fail until Phase 1)

   // Phase decode from the target's msg/cd/io lines, so tests can assert on
   // where the target actually is rather than peeking inside it.
   localparam P_DATA_OUT = 3'd2;  // target -> initiator
   localparam P_DATA_IN  = 3'd3;  // initiator -> target
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
   // hps_io block-device model. On io_rd, stream a sector into the buffer
   // then pulse io_ack. Content is a function of the LBA so reads are
   // checkable byte-exact: byte[n] = lba[7:0] ^ n.
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
         $display("       [hps] serving %s lba=%0d (rd#%0d)",
                  io_rd ? "READ" : "WRITE", io_lba, io_rd_count);
         // a little latency before the block starts moving
         repeat (8) @(posedge clk);
         if (io_rd) begin
            for (w = 0; w < 256; w = w + 1) begin
               even_b = io_lba[7:0] ^ ((w * 2)     & 8'hff);
               odd_b  = io_lba[7:0] ^ ((w * 2 + 1) & 8'hff);
               sd_buff_addr <= w[7:0];
               // low byte = even disk byte, high byte = odd (real-HPS packing)
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

   // NOTE: scsi.v's io_rd/io_wr (and its internal rd_pending/wr_pending) have no
   // reset, so they power up as X in simulation and never resolve -- which makes
   // io_busy, and therefore req, X forever. io_ack is the only thing that clears
   // io_rd/io_wr, so pulse it during reset to bring the DUT to a defined state.
   // Phase 1 should give those registers a proper reset; see SCSI_UPGRADE_PLAN.md.
   task do_reset;
      begin
         rst  = 1'b1; sel = 1'b0; ack = 1'b0; din = 8'h00;
         hps_enable = 1'b0;
         repeat (4) @(posedge clk);
         io_ack = 1'b1;
         repeat (4) @(posedge clk);
         io_ack = 1'b0;
         rst  = 1'b0;
         repeat (4) @(posedge clk);
         hps_enable = 1'b1;
         @(posedge clk);
      end
   endtask

   // Drive img_mounted off the #1-after-posedge phase so it is unambiguously
   // high at the NEXT posedge; setting and clearing it inside one time step
   // races the DUT's sampling and the mount silently does not take.
   task mount_image;
      input [31:0] blocks;
      begin
         @(posedge clk); #1;
         img_blocks  = blocks;
         img_mounted = 1'b1;
         @(posedge clk); #1;
         img_mounted = 1'b0;
         repeat (2) @(posedge clk);
      end
   endtask

   // Select the target by putting its ID bit on the data bus.
   task select_target;
      begin : st
         integer guard;
         timed_out = 1'b0;   // each selection starts a fresh command
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
            $display("       select_target: no BSY (mounted=%b phase=%0d req=%b io_rd=%b io_wr=%b)",
                     dut.mounted, dut.phase, req, io_rd, io_wr);
         end
         sel = 1'b0;
         din = 8'h00;
         @(posedge clk);
      end
   endtask

   // One REQ/ACK beat. `outbyte` is presented on din for initiator->target
   // phases; `sampled` returns dout for target->initiator phases. Sets
   // `timed_out` rather than hanging, so a wedged target is a FAIL not a hang.
   reg       timed_out = 1'b0;
   reg [7:0] sampled   = 8'h00;
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
            // Sample while req is still asserted -- dout is only valid then.
            din     = outbyte;
            sampled = dout;
            // req is combinational on ack, so it drops the instant ack rises.
            // Waiting on req falling would exit in zero time and the ack pulse
            // would never cross a clock edge; hold it across real edges instead
            // so the target sees stb_ack (rise) then stb_adv (fall).
            ack = 1'b1;
            repeat (2) begin @(posedge clk); #1; end
            ack = 1'b0;
            // Settle before the next beat samples dout. The chain after ack
            // falls is: stb_adv registers (+1), data_cnt increments (+1), the
            // dpram's registered q_b follows the new address_b (+1). Sampling
            // sooner returns the PREVIOUS byte. A real initiator is a full
            // 68000 bus cycle behind, so this is bench pacing, not a DUT issue.
            repeat (4) begin @(posedge clk); #1; end
         end
      end
   endtask

   // Send a CDB, one byte per beat, while the target is in COMMAND phase.
   task send_cdb;
      input [7:0] b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11;
      input integer len;
      begin : sc
         reg [7:0] cdb [0:11];
         integer k;
         cdb[0]=b0;  cdb[1]=b1;  cdb[2]=b2;  cdb[3]=b3;
         cdb[4]=b4;  cdb[5]=b5;  cdb[6]=b6;  cdb[7]=b7;
         cdb[8]=b8;  cdb[9]=b9;  cdb[10]=b10; cdb[11]=b11;
         for (k = 0; k < len; k = k + 1) begin
            if (!timed_out) xfer_byte(cdb[k]);
         end
      end
   endtask

   // Drain the target->initiator data phase into `buf_in`.
   reg [7:0] buf_in [0:1023];
   integer   buf_len;
   task read_data_phase;
      input integer maxbytes;
      begin : rdp
         integer n, guard;
         n = 0;
         // The target is still in COMMAND for a cycle or two after the last CDB
         // byte. Wait for it to land in DATA_OUT before sampling, or bail out if
         // it goes straight to STATUS (a rejected or no-data command).
         guard = 0;
         while (!timed_out && guard < 2000 &&
                phase_of(msg, cd, io) != P_DATA_OUT &&
                phase_of(msg, cd, io) != P_STATUS) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         // Real-initiator turnaround. On entering DATA_OUT the target asserts
         // req ~2 cycles BEFORE io_rd goes high, so a zero-latency initiator can
         // take a byte before the block fetch has even started (see
         // SCSI_UPGRADE_PLAN.md "req/io_rd startup race"). A 68000 pseudo-DMA
         // read cannot turn around in 62ns, so model that minimum latency here.
         repeat (8) begin @(posedge clk); #1; end
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

   // Consume STATUS + MESSAGE, leaving the bus idle. Returns the status byte.
   reg [7:0] status_byte;
   task finish_command;
      begin : fc
         integer guard;
         status_byte = 8'hff;
         guard = 0;
         while (!timed_out && phase_of(msg, cd, io) != P_STATUS &&
                guard < 4000) begin
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

   // ======================================================================
   // Tests
   // ======================================================================
   integer i;
   reg [7:0] expect_byte;

   initial begin
      $dumpfile("sim/out/tb_scsi_target.vcd");
      $dumpvars(0, tb_scsi_target);

      $display("-- harness: reset + mount");
      do_reset;
      mount_image(32'd40960);

      // ==================================================================
      // Test 1 (baseline, must pass today): INQUIRY returns the SEAGATE
      // ST225N identity. Proves selection, CDB transfer, data-in and the
      // status/message tail all work, so later failures are real.
      // ==================================================================
      select_target;
      send_cdb(8'h12,8'h00,8'h00,8'h00,8'h20,8'h00,0,0,0,0,0,0, 6);
      read_data_phase(32);   // exactly the allocation length, as a real initiator counts
      finish_command;

      begin : test1
         reg ok;
         reg [7:0] vendor [0:6];
         ok = (!timed_out) && (buf_len == 32) && (status_byte == 8'h00);
         // bytes 9..15 spell SEAGATE (byte 8 is a leading space)
         vendor[0]="S"; vendor[1]="E"; vendor[2]="A"; vendor[3]="G";
         vendor[4]="A"; vendor[5]="T"; vendor[6]="E";
         for (i = 0; i < 7; i = i + 1)
            if (buf_in[9+i] !== vendor[i]) ok = 0;
         if (ok) begin
            $display("PASS: test1 - INQUIRY returns SEAGATE identity, status 00");
         end else begin
            $display("FAIL: test1 - INQUIRY bad (timeout=%b len=%0d status=%02x)",
                     timed_out, buf_len, status_byte);
            all_ok = 0;
         end
      end

      // ==================================================================
      // Test 2 (baseline, must pass today): READ(6) of one block returns the
      // hps model's LBA-derived pattern byte-exact. This is the regression
      // guard for Phase 1's read-prefetch-ring change, which rewrites the
      // buffer addressing this test pins down.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      // READ(6) lba=3 len=1
      send_cdb(8'h08,8'h00,8'h00,8'h03,8'h01,8'h00,0,0,0,0,0,0, 6);
      read_data_phase(512);
      finish_command;

      begin : test2
         reg ok;
         ok = (!timed_out) && (buf_len == 512) && (status_byte == 8'h00);
         if (ok)
            for (i = 0; i < 512; i = i + 1) begin
               expect_byte = 8'd3 ^ i[7:0];
               if (buf_in[i] !== expect_byte) begin
                  if (ok) $display("       first mismatch at byte %0d: got %02x want %02x",
                                   i, buf_in[i], expect_byte);
                  ok = 0;
               end
            end
         if (ok) begin
            $display("PASS: test2 - READ(6) returns 512 bytes byte-exact, status 00");
         end else begin
            $display("FAIL: test2 - READ(6) bad (timeout=%b len=%0d status=%02x io_rd_count=%0d ram0=%02x ram1=%02x)",
                     timed_out, buf_len, status_byte, io_rd_count,
                     dut.buffer0.ram[0], dut.buffer1.ram[0]);
            all_ok = 0;
         end
      end

      // ==================================================================
      // Test 3 (EXPECTED FAIL until Phase 1): REQUEST SENSE after a CHECK
      // CONDITION. SCSI-1 makes 0x03 mandatory; the target does not
      // implement it, so the recovery path can never clear the condition.
      // An unsupported opcode should CHECK (02), and the following REQUEST
      // SENSE should then succeed (00) with a sense block.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      send_cdb(8'h1d,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6); // SEND DIAGNOSTIC, unsupported
      finish_command;

      begin : test3
         reg [7:0] first_status;
         reg ok;
         first_status = status_byte;
         // now the recovery command the driver would issue
         select_target;
         send_cdb(8'h03,8'h00,8'h00,8'h00,8'h12,8'h00,0,0,0,0,0,0, 6);
         read_data_phase(64);
         finish_command;

         ok = (first_status == 8'h02) && (!timed_out) && (status_byte == 8'h00)
              && (buf_len > 0);
         if (ok) begin
            $display("PASS: test3 - REQUEST SENSE accepted after CHECK CONDITION");
         end else begin
            $display("FAIL: test3 - REQUEST SENSE not supported (first_status=%02x sense_status=%02x len=%0d timeout=%b)",
                     first_status, status_byte, buf_len, timed_out);
            $display("       EXPECTED until Phase 1 lands - this is the conformance gap.");
            conform_fail = conform_fail + 1;
         end
      end

      // ==================================================================
      // Test 4 (EXPECTED FAIL until Phase 1): a 12-byte (group 5) CDB must
      // not wedge the bus. cmd_cpl only completes groups 0/1/2, so for a
      // group-5 opcode the target sticks in COMMAND phase and holds BSY
      // forever. A real drive CHECKs and releases the bus.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      send_cdb(8'ha8,8'h00,8'h00,8'h00,8'h00,8'h01,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00, 12); // READ(12)
      finish_command;

      begin : test4
         reg ok;
         ok = (!timed_out) && (status_byte == 8'h02) && (!bsy);
         if (ok) begin
            $display("PASS: test4 - 12-byte CDB rejected with CHECK, bus released");
         end else begin
            $display("FAIL: test4 - 12-byte CDB wedged the target (timeout=%b status=%02x bsy=%b)",
                     timed_out, status_byte, bsy);
            $display("       EXPECTED until Phase 1 lands - this is the latent bus wedge.");
            conform_fail = conform_fail + 1;
         end
      end

      $display("");
      $display("BASELINE (must pass today):        %s", all_ok ? "PASS" : "FAIL");
      $display("CONFORMANCE (Phase 1 target):      %0d of 2 still failing", conform_fail);
      $display("");
      if (all_ok && conform_fail == 2)
         $display("PHASE 0 SCSI GATE: PASS - harness good, both defects reproduced");
      else if (all_ok && conform_fail == 0)
         $display("PHASE 0 SCSI GATE: PASS - conformance gaps CLOSED (Phase 1 done)");
      else
         $display("PHASE 0 SCSI GATE: FAIL - baseline broken, harness not trustworthy");
      $finish;
   end

   // global watchdog so a wedged target can never hang the run
   initial begin
      #4_000_000;
      $display("FAIL: global watchdog expired - simulation hung");
      $display("PHASE 0 SCSI GATE: FAIL (hung)");
      $finish;
   end

endmodule
