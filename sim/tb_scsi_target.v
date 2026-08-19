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
   reg        rst      = 1'b1;
   reg        sys_rst  = 1'b0;
   reg        bus_busy = 1'b0;
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
      .sys_rst(sys_rst),
      .bus_busy(bus_busy),
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
   integer conform_fail = 0; // the two Phase 0 conformance gaps (tests 3 and 4)
   integer p1_fail = 0;     // Phase 1 behaviour tests (tests 5..9)
   integer p1_total = 0;

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

   // Last sector the target flushed to us, and the LBA it went to. Lets the
   // WRITE tests check that the bytes the initiator sent actually reached the
   // block device, at the right address, in the right byte lanes.
   reg [7:0]  hps_wr_data [0:511];
   reg [31:0] hps_wr_lba = 32'hffffffff;

   // Prefetch-depth watermark: how far the ring ever ran AHEAD of the Mac.
   // A value > 1 proves the read-prefetch ring is actually prefetching rather
   // than having degenerated into the old one-sector-at-a-time fetch.
   integer   ring_depth_max = 0;
   reg       ring_watch = 1'b0;
   always @(posedge clk) begin
      if (ring_watch && (dut.rd_hps_blk > dut.rd_cur_blk))
         if ((dut.rd_hps_blk - dut.rd_cur_blk) > ring_depth_max)
            ring_depth_max = dut.rd_hps_blk - dut.rd_cur_blk;
   end

   always @(posedge clk) begin : hps_model
      integer w;
      reg [7:0] even_b, odd_b;
      if (hps_enable && (io_rd || io_wr)) begin
         if (io_rd) io_rd_count = io_rd_count + 1;
         if (io_wr) io_wr_count = io_wr_count + 1;
         $display("       [hps] serving %s lba=%0d (rd#%0d wr#%0d)",
                  io_rd ? "READ" : "WRITE", io_lba, io_rd_count, io_wr_count);
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
         end else begin
            // WRITE flush: read the sector back out of the target's buffer the
            // way the real HPS does. scsi_dpram's q_a is registered, so the data
            // for an address is valid two edges after presenting it.
            hps_wr_lba = io_lba;
            for (w = 0; w < 256; w = w + 1) begin
               sd_buff_addr <= w[7:0];
               @(posedge clk); #1;
               @(posedge clk); #1;
               hps_wr_data[w*2]     = sd_buff_din[7:0];   // even byte
               hps_wr_data[w*2 + 1] = sd_buff_din[15:8];  // odd byte
            end
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

   // Plain bus reset -- no io_ack pulse. Phase 0 had to pulse io_ack here because
   // io_rd/io_wr (and the internal rd/wr pending latches) had no reset at all and
   // powered up as X, which made io_busy -- and therefore req -- X forever. Phase 1
   // resets them properly, so a bus reset alone must now be enough to bring the
   // DUT to a defined state. If that regresses, every test below wedges.
   task do_reset;
      begin
         rst  = 1'b1; sel = 1'b0; ack = 1'b0; din = 8'h00;
         hps_enable = 1'b0;
         repeat (8) @(posedge clk);
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
   reg [7:0] buf_in [0:4095];
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
         // Phase 0 had to insert a turnaround delay here: on entering DATA_OUT
         // the target asserted req ~2 cycles BEFORE io_rd went high, so a
         // zero-latency initiator could take a byte before the block fetch had
         // even started. Phase 1's ring stall (rd_cur_blk >= rd_hps_blk) holds
         // req down until the sector has actually landed, so the delay is gone
         // and this bench is now a maximally impatient initiator -- which is
         // exactly what would expose the race if it came back.
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

   // Drive the initiator->target data phase. Byte n of sector s is
   // (base + s) ^ n, the same shape the read model uses, so a write followed by
   // an inspection of hps_wr_data checks the whole path end to end.
   task write_data_phase;
      input [7:0] base;
      input integer nbytes;
      begin : wdp
         integer n, guard, sec;
         n = 0;
         guard = 0;
         while (!timed_out && guard < 2000 &&
                phase_of(msg, cd, io) != P_DATA_IN &&
                phase_of(msg, cd, io) != P_STATUS) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         while (!timed_out && n < nbytes &&
                phase_of(msg, cd, io) == P_DATA_IN) begin
            sec = n / 512;
            xfer_byte((base + sec) ^ (n % 512));
            if (!timed_out) n = n + 1;
         end
         buf_len = n;
      end
   endtask

   // Streaming read check: verify the LBA-derived pattern byte by byte without
   // buffering the whole transfer, so a read can be longer than buf_in.
   // Reports the number of bytes taken and the number that did not match.
   integer stream_len, stream_bad;
   reg [31:0] stream_first_bad;
   task read_check_phase;
      input [31:0] start_lba;
      input integer nbytes;
      begin : rcp
         integer n, guard, sec;
         reg [7:0] want;
         n = 0; stream_bad = 0; stream_first_bad = 32'hffffffff;
         guard = 0;
         while (!timed_out && guard < 2000 &&
                phase_of(msg, cd, io) != P_DATA_OUT &&
                phase_of(msg, cd, io) != P_STATUS) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         while (!timed_out && n < nbytes &&
                phase_of(msg, cd, io) == P_DATA_OUT) begin
            xfer_byte(8'h00);
            if (!timed_out) begin
               sec  = n / 512;
               want = (start_lba[7:0] + sec) ^ (n % 512);
               if (sampled !== want) begin
                  if (stream_bad == 0) stream_first_bad = n;
                  stream_bad = stream_bad + 1;
               end
               n = n + 1;
            end
         end
         stream_len = n;
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

      // ==================================================================
      // Test 5 (Phase 1): multi-sector READ(6). The read-prefetch ring
      // replaced the two-sector double buffer, so the case that actually
      // exercises it is a transfer that crosses several 512-byte boundaries
      // -- test 2 only ever reads one sector and never leaves slot 0.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      ring_watch = 1'b1;
      ring_depth_max = 0;
      // READ(6) lba=10 len=4
      send_cdb(8'h08,8'h00,8'h00,8'h0a,8'h04,8'h00,0,0,0,0,0,0, 6);
      read_data_phase(2048);
      finish_command;
      ring_watch = 1'b0;

      begin : test5
         reg ok;
         integer blk;
         p1_total = p1_total + 1;
         ok = (!timed_out) && (buf_len == 2048) && (status_byte == 8'h00);
         if (ok)
            for (i = 0; i < 2048; i = i + 1) begin
               blk = 10 + (i / 512);
               expect_byte = blk[7:0] ^ (i % 512);
               if (buf_in[i] !== expect_byte) begin
                  if (ok) $display("       first mismatch at byte %0d (sector %0d): got %02x want %02x",
                                   i, blk, buf_in[i], expect_byte);
                  ok = 0;
               end
            end
         // The ring is only doing its job if the HPS ran AHEAD of the Mac. A
         // watermark of 1 means it degenerated into the old fetch-per-boundary
         // behaviour and the stall would be back.
         if (ok && (ring_depth_max < 2)) begin
            $display("       ring never ran ahead (watermark=%0d) - prefetch is not working",
                     ring_depth_max);
            ok = 0;
         end
         if (ok) begin
            $display("PASS: test5 - 4-sector READ(6) byte-exact, ring prefetched %0d sectors ahead",
                     ring_depth_max);
         end else begin
            $display("FAIL: test5 - multi-sector READ bad (timeout=%b len=%0d status=%02x depth=%0d)",
                     timed_out, buf_len, status_byte, ring_depth_max);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 6 (Phase 1): the sense block actually says why the command
      // failed. This is decision #1 in SCSI_UPGRADE_PLAN.md -- the LC's
      // disk path returns a static all-zeros NO SENSE, which answers
      // "nothing is wrong" to "why did you CHECK?". We report the real key.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      send_cdb(8'h1d,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6); // SEND DIAGNOSTIC, unsupported
      finish_command;
      select_target;
      send_cdb(8'h03,8'h00,8'h00,8'h00,8'h12,8'h00,0,0,0,0,0,0, 6);
      read_data_phase(32);
      finish_command;

      begin : test6
         reg ok;
         p1_total = p1_total + 1;
         ok = (!timed_out) && (buf_len == 18) && (status_byte == 8'h00)
              && (buf_in[0]  === 8'h70)   // current error, fixed format
              && (buf_in[2]  === 8'h05)   // ILLEGAL REQUEST
              && (buf_in[7]  === 8'h0a)   // additional sense length
              && (buf_in[12] === 8'h20);  // invalid command operation code
         if (ok) begin
            $display("PASS: test6 - sense block reports ILLEGAL REQUEST / ASC 20");
         end else begin
            $display("FAIL: test6 - sense block wrong (len=%0d b0=%02x key=%02x b7=%02x asc=%02x timeout=%b)",
                     buf_len, buf_in[0], buf_in[2], buf_in[7], buf_in[12], timed_out);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 7 (Phase 1): SCSI-1 sense lifetime. A successful command
      // clears the pending sense, so the next REQUEST SENSE reports NO
      // SENSE. Without this the condition would look permanently latched.
      // ==================================================================
      select_target;
      send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6); // TEST UNIT READY, succeeds
      finish_command;

      begin : test7
         reg ok;
         reg [7:0] tur_status;
         p1_total = p1_total + 1;
         tur_status = status_byte;
         select_target;
         send_cdb(8'h03,8'h00,8'h00,8'h00,8'h12,8'h00,0,0,0,0,0,0, 6);
         read_data_phase(32);
         finish_command;
         ok = (!timed_out) && (tur_status == 8'h00) && (status_byte == 8'h00)
              && (buf_in[2] === 8'h00) && (buf_in[12] === 8'h00);
         if (ok) begin
            $display("PASS: test7 - sense cleared by the next successful command");
         end else begin
            $display("FAIL: test7 - sense not cleared (tur=%02x key=%02x asc=%02x timeout=%b)",
                     tur_status, buf_in[2], buf_in[12], timed_out);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 8 (Phase 1): the bus is genuinely usable after a 12-byte CDB.
      // Test 4 only checks that BSY dropped; this proves the target still
      // serves a normal command afterwards rather than being left wedged in
      // some half-state.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      send_cdb(8'ha8,8'h00,8'h00,8'h00,8'h00,8'h01,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00, 12);
      finish_command;

      begin : test8
         reg ok;
         reg [7:0] rej_status;
         p1_total = p1_total + 1;
         rej_status = status_byte;
         select_target;
         send_cdb(8'h08,8'h00,8'h00,8'h07,8'h01,8'h00,0,0,0,0,0,0, 6); // READ(6) lba=7
         read_data_phase(512);
         finish_command;
         ok = (!timed_out) && (rej_status == 8'h02) && (status_byte == 8'h00)
              && (buf_len == 512);
         if (ok)
            for (i = 0; i < 512; i = i + 1)
               if (buf_in[i] !== (8'd7 ^ i[7:0])) ok = 0;
         if (ok) begin
            $display("PASS: test8 - bus fully usable after a rejected 12-byte CDB");
         end else begin
            $display("FAIL: test8 - target not usable after 12-byte CDB (rej=%02x status=%02x len=%0d timeout=%b)",
                     rej_status, status_byte, buf_len, timed_out);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 9 (Phase 1): bus arbitration. While another target holds BSY,
      // this one must not answer selection -- otherwise two targets consume
      // the same ACK stream and corrupt each other's commands.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);

      begin : test9
         reg ok;
         reg selected_while_busy;
         integer guard;
         p1_total = p1_total + 1;

         bus_busy = 1'b1;
         din = (8'd1 << TARGET_ID);
         sel = 1'b1;
         guard = 0;
         while (!bsy && guard < 200) begin
            @(posedge clk); #1;
            guard = guard + 1;
         end
         selected_while_busy = bsy;
         sel = 1'b0; din = 8'h00;
         bus_busy = 1'b0;
         repeat (4) @(posedge clk);

         // and it must still select normally once the bus is free
         select_target;
         send_cdb(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,0,0,0,0,0,0, 6);
         finish_command;

         ok = (!selected_while_busy) && (!timed_out) && (status_byte == 8'h00);
         if (ok) begin
            $display("PASS: test9 - selection refused while the bus is busy, accepted when free");
         end else begin
            $display("FAIL: test9 - bus_busy arbitration wrong (sel_while_busy=%b status=%02x timeout=%b)",
                     selected_while_busy, status_byte, timed_out);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 10 (Phase 1 REGRESSION GUARD): single-sector WRITE(6). The
      // write path was untested by Phase 0, and Phase 1 changed req_wr (the
      // data_len!=0 guard), the flush engine (reset + restructure) and
      // io_busy's DATA_IN clause (wr_pending). Check the bytes the initiator
      // sent actually reach the block device, at the right LBA, in the right
      // byte lanes.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      hps_wr_lba = 32'hffffffff;
      select_target;
      // WRITE(6) lba=17 len=1
      send_cdb(8'h0a,8'h00,8'h00,8'h11,8'h01,8'h00,0,0,0,0,0,0, 6);
      write_data_phase(8'd17, 512);
      finish_command;

      begin : test10
         reg ok;
         p1_total = p1_total + 1;
         ok = (!timed_out) && (buf_len == 512) && (status_byte == 8'h00)
              && (hps_wr_lba == 32'd17);
         if (ok)
            for (i = 0; i < 512; i = i + 1) begin
               expect_byte = 8'd17 ^ i[7:0];
               if (hps_wr_data[i] !== expect_byte) begin
                  if (ok) $display("       first mismatch at byte %0d: flushed %02x want %02x",
                                   i, hps_wr_data[i], expect_byte);
                  ok = 0;
               end
            end
         if (ok) begin
            $display("PASS: test10 - WRITE(6) reaches the block device byte-exact at lba 17");
         end else begin
            $display("FAIL: test10 - WRITE(6) bad (timeout=%b len=%0d status=%02x lba=%0d)",
                     timed_out, buf_len, status_byte, hps_wr_lba);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 11 (Phase 1 REGRESSION GUARD): 3-sector WRITE(6). Exercises the
      // two-slot double-buffer alternation and the mid-transfer flush, which
      // is where the wr_pending window in io_busy matters -- a single-sector
      // write only flushes once, at STATUS.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      hps_wr_lba = 32'hffffffff;
      io_wr_count = 0;
      select_target;
      // WRITE(6) lba=30 len=3
      send_cdb(8'h0a,8'h00,8'h00,8'h1e,8'h03,8'h00,0,0,0,0,0,0, 6);
      write_data_phase(8'd30, 1536);
      finish_command;

      begin : test11
         reg ok;
         p1_total = p1_total + 1;
         // The last flush is the third sector, so hps_wr_data/lba hold sector 2.
         ok = (!timed_out) && (buf_len == 1536) && (status_byte == 8'h00)
              && (io_wr_count == 3) && (hps_wr_lba == 32'd32);
         if (ok)
            for (i = 0; i < 512; i = i + 1) begin
               expect_byte = 8'd32 ^ i[7:0];
               if (hps_wr_data[i] !== expect_byte) begin
                  if (ok) $display("       last-sector mismatch at byte %0d: flushed %02x want %02x",
                                   i, hps_wr_data[i], expect_byte);
                  ok = 0;
               end
            end
         if (ok) begin
            $display("PASS: test11 - 3-sector WRITE(6): 3 flushes, final sector exact at lba 32");
         end else begin
            $display("FAIL: test11 - multi-sector WRITE bad (timeout=%b len=%0d status=%02x flushes=%0d lba=%0d)",
                     timed_out, buf_len, status_byte, io_wr_count, hps_wr_lba);
            p1_fail = p1_fail + 1;
         end
      end

      // ==================================================================
      // Test 12 (Phase 1): a READ longer than the ring, so the ring WRAPS.
      // This is the case a stale-slot bug shows up in -- a slot served at or
      // past the fill frontier returns its previous occupant silently, which
      // is exactly the corruption class the LC chased for weeks. RING_BLOCKS
      // is 32, so 40 sectors wraps by 8.
      // ==================================================================
      do_reset;
      mount_image(32'd40960);
      select_target;
      // READ(6) lba=64 len=40
      send_cdb(8'h08,8'h00,8'h00,8'h40,8'd40,8'h00,0,0,0,0,0,0, 6);
      read_check_phase(32'd64, 40*512);
      finish_command;

      begin : test12
         reg ok;
         p1_total = p1_total + 1;
         ok = (!timed_out) && (stream_len == 40*512) && (status_byte == 8'h00)
              && (stream_bad == 0);
         if (ok) begin
            $display("PASS: test12 - 40-sector READ(6) exact across a ring wrap (%0d bytes)", stream_len);
         end else begin
            $display("FAIL: test12 - ring wrap corrupted the read (timeout=%b len=%0d status=%02x bad=%0d first_bad=%0d)",
                     timed_out, stream_len, status_byte, stream_bad, stream_first_bad);
            p1_fail = p1_fail + 1;
         end
      end

      $display("");
      $display("BASELINE (must pass today):        %s", all_ok ? "PASS" : "FAIL");
      $display("CONFORMANCE (Phase 1 target):      %0d of 2 still failing", conform_fail);
      $display("PHASE 1 BEHAVIOUR:                 %0d of %0d failing", p1_fail, p1_total);
      $display("");
      if (all_ok && conform_fail == 2 && p1_fail == p1_total)
         $display("PHASE 0 SCSI GATE: PASS - harness good, both defects reproduced");
      else if (all_ok && conform_fail == 0 && p1_fail == 0)
         $display("PHASE 1 SCSI GATE: PASS - conformance gaps CLOSED, behaviour tests green");
      else if (!all_ok)
         $display("SCSI GATE: FAIL - baseline broken, harness not trustworthy");
      else
         $display("SCSI GATE: FAIL - conformance %0d/2, behaviour %0d/%0d",
                  conform_fail, p1_fail, p1_total);
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
