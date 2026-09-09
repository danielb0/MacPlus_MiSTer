`timescale 1ns/1ps
//
// tb_floppy_sniff.v - Phase 7 of FLOPPY_WRITE_PLAN.md: the mount-time medium
// sniff in rtl/floppy_loader.v.
//
// Nothing on a 3.5" diskette records whether it is single- or double-sided.
// What can be read off it is how big the volume last formatted onto it is,
// and that is what the .Sony driver's address-field format byte has to agree
// with - so the loader reads the volume's own size out of the Master
// Directory Block as the image streams past, and reports it as media_ds.
//
// Why file sector 2 can be read before the geometry is known: it is image
// byte 1024 under BOTH mappings (block 2 is cylinder 0 side 0 sector 2
// either way). drNmAlBlks and drAlBlkSiz sit at MDB offsets 18 and 20 in MFS
// and HFS alike; only the signature word differs, $D2D7 against $4244.
//
// The cases, and why each one is here:
//
//   1. MFS 391 x 1024 - a real 400K MFS volume, the commonest 400K disk
//      there is. Single-sided.
//   2. HFS 395 x 1024 - a 400K HFS volume. Single-sided, and it proves the
//      signature test is not the thing deciding the answer.
//   3. HFS 1594 x 512 - a real 800K HFS volume. Double-sided, and its
//      allocation-block size differs from every other case here, so the
//      multiply is doing real work rather than the block COUNT alone
//      happening to sort the cases.
//   4. HFS 797 x 1024 - the same 800K volume with the other allocation
//      block size. Double-sided, and it is the pair to case 2 that shows
//      the count alone cannot decide: 797 blocks is double-sided here and
//      395 is single-sided, but 1594 is also double-sided.
//   5. a zero-filled image - a blank diskette. The medium says nothing,
//      which reports double-sided, and floppy.v's ceilings and format latch
//      take it from there.
//   6. a non-Mac image: a plausible MDB body under a signature that is
//      neither MFS nor HFS. Says nothing.
//   7. a valid signature with a nonsense drAlBlkSiz (not a multiple of 512).
//      Says nothing - the bounds on that field are what keep the multiply
//      seven bits wide, so a value outside them cannot be trusted to it.
//      7b and 7c then walk those bounds: 32768 is the largest block size
//      they admit and the only one that sets the multiplier's top bit, and
//      a value just above 64K is refused even though its low word alone
//      would pass. Both exist because a mutation sweep found the RTL's
//      widest input unreachable from the cases above them.
//   8. an image too short to have a sector 2. Says nothing, and does not
//      report whatever the previous mount left behind.
//   9. a remount: case 1 after case 3, to show the verdict is rebuilt per
//      mount rather than latched once.
//
// Run from the repo ROOT:
//   iverilog -g2012 -I rtl -y rtl -o sim/out/tb_floppy_sniff.vvp sim/tb_floppy_sniff.v
//   vvp sim/out/tb_floppy_sniff.vvp
//
module tb_floppy_sniff;

   reg clk_sys = 0;
   always #5 clk_sys = ~clk_sys;

   reg reset = 1;

   // ---- the image the mock SD serves ----
   // Only sector 2 has to be real; the rest is filler. 4 sectors is enough
   // for the loader to stream past the MDB and finish.
   localparam NSECT     = 4;
   localparam IMG_BYTES = NSECT * 512;
   reg [7:0] img [0:IMG_BYTES-1];

   // ---- DUT ----
   reg         img_mounted = 0;
   reg  [63:0] img_size    = 0;

   wire [31:0] sd_lba;
   wire        sd_rd;
   reg         sd_ack = 0;

   reg   [7:0] sd_buff_addr = 0;
   reg  [15:0] sd_buff_dout = 0;
   reg         sd_buff_wr = 0;

   wire [21:0] wr_addr;
   wire [15:0] wr_data;
   wire        wr_req;
   reg         wr_ack = 0;

   wire        done;
   wire [63:0] loaded_size;
   wire        media_ds;
   wire        busy;

   floppy_loader dut (
      .clk_sys(clk_sys),
      .reset(reset),
      .img_mounted(img_mounted),
      .img_size(img_size),
      .img_readonly(1'b0),
      .sd_lba(sd_lba),
      .sd_rd(sd_rd),
      .sd_ack(sd_ack),
      .sd_buff_addr(sd_buff_addr),
      .sd_buff_dout(sd_buff_dout),
      .sd_buff_wr(sd_buff_wr),
      .wr_addr(wr_addr),
      .wr_data(wr_data),
      .wr_req(wr_req),
      .wr_ack(wr_ack),
      .done(done),
      .loaded_size(loaded_size),
      .readonly_latched(),
      .media_ds(media_ds),
      .busy(busy)
   );

   // ---- mocks, lifted from sim/tb_floppy_loader.v ----
   reg [1:0] grant_wait;
   always @(posedge clk_sys) begin
      wr_ack <= 0;
      if (wr_req && !wr_ack) begin
         if (grant_wait != 0) grant_wait <= grant_wait - 1'd1;
         else begin
            wr_ack     <= 1;
            grant_wait <= 2'd2;
         end
      end
      else if (!wr_req) grant_wait <= 2'd2;
   end

   reg  [8:0] word_i;
   reg [10:0] sect_i;
   reg  [3:0] mock_state;
   localparam M_IDLE=0, M_ACKWAIT=1, M_STREAM=2, M_DROP=3;
   always @(posedge clk_sys) begin
      sd_buff_wr <= 0;
      case (mock_state)
      M_IDLE: if (sd_rd) begin
         sect_i     <= sd_lba[10:0];
         mock_state <= M_ACKWAIT;
      end
      M_ACKWAIT: begin
         sd_ack     <= 1;
         word_i     <= 0;
         mock_state <= M_STREAM;
      end
      M_STREAM: begin
         sd_buff_addr <= word_i[7:0];
         // sd_buff_dout[7:0] is the EVEN image byte, [15:8] the ODD one -
         // the convention tb_floppy_loader.v derived from scsi.v's own code
         sd_buff_dout <= { img[sect_i*512 + word_i*2 + 1], img[sect_i*512 + word_i*2] };
         sd_buff_wr   <= 1;
         if (word_i == 9'd255) mock_state <= M_DROP;
         else word_i <= word_i + 9'd1;
      end
      M_DROP: begin
         sd_ack     <= 0;
         mock_state <= M_IDLE;
      end
      endcase
   end

   // ---- building an MDB ----
   integer i;

   task put16(input integer off, input [15:0] v);
      begin img[off] = v[15:8]; img[off+1] = v[7:0]; end
   endtask

   // sig at MDB+0, drNmAlBlks at MDB+18, drAlBlkSiz (32 bits) at MDB+20.
   // The MDB is at image byte 1024 = file sector 2.
   task build_mdb(input [15:0] sig, input [15:0] nalbk, input [31:0] absz);
      begin
         for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h5A; // filler
         put16(1024 +  0, sig);
         put16(1024 + 18, nalbk);
         put16(1024 + 20, absz[31:16]);
         put16(1024 + 22, absz[15:0]);
      end
   endtask

   task blank_image;
      begin for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = 8'h00; end
   endtask

   // Bracket the load on `busy` (state != IDLE), not on the `done` pulse.
   // `done` is high for the cycle in which the loader is already back in
   // IDLE, so a `wait (done)` posted right after the previous mount returns
   // sees that same pulse and falls straight through - the second mount
   // never happens and the bench reads the FIRST image's verdict while
   // believing it read the second's. Sampling at #1 after the edge, as
   // everywhere else in this project's benches, for the same reason.
   task mount(input [63:0] sz);
      begin
         @(posedge clk_sys); #1;
         while (busy || done) begin @(posedge clk_sys); #1; end
         img_size    = sz;
         img_mounted = 1;
         @(posedge clk_sys); #1;
         img_mounted = 0;
         while (!busy) begin @(posedge clk_sys); #1; end  // the load started
         while ( busy) begin @(posedge clk_sys); #1; end  // ... and finished
         @(posedge clk_sys); #1;
      end
   endtask

   integer all_ok = 1;
   task ok(input [8*80:1] name, input cond);
      begin
         if (cond) $display("PASS: %0s", name);
         else begin $display("FAIL: %0s", name); all_ok = 0; end
      end
   endtask

   initial begin
      #4_000_000;
      $display("FAIL: watchdog - a mount never completed (busy=%b)", busy);
      $display("MEDIUM SNIFF GATE: FAIL (watchdog)");
      $finish;
   end

   initial begin
      mock_state = M_IDLE;
      grant_wait = 2'd2;
      blank_image;

      @(posedge clk_sys); @(negedge clk_sys);
      reset = 0;

      $display("");
      $display("=== what the medium says about its own sidedness ===");

      // 1. a real 400K MFS volume
      build_mdb(16'hD2D7, 16'd391, 32'd1024);
      mount(IMG_BYTES);
      ok("MFS 391 x 1024 (400K) reads as single-sided", media_ds === 1'b0);

      // 2. a 400K HFS volume - the signature is not what decides
      build_mdb(16'h4244, 16'd395, 32'd1024);
      mount(IMG_BYTES);
      ok("HFS 395 x 1024 (400K) reads as single-sided", media_ds === 1'b0);

      // 3. a real 800K HFS volume, 512-byte allocation blocks
      build_mdb(16'h4244, 16'd1594, 32'd512);
      mount(IMG_BYTES);
      ok("HFS 1594 x 512 (800K) reads as double-sided", media_ds === 1'b1);

      // 4. the same volume with 1024-byte allocation blocks: 797 blocks is
      //    double-sided where 395 was single-sided, so it is the product
      build_mdb(16'h4244, 16'd797, 32'd1024);
      mount(IMG_BYTES);
      ok("HFS 797 x 1024 (800K) reads as double-sided", media_ds === 1'b1);

      // 5. a blank diskette says nothing
      blank_image;
      mount(IMG_BYTES);
      ok("a zero-filled image says nothing, so it falls through to double-sided",
         media_ds === 1'b1);

      // 6. a non-Mac disk says nothing
      build_mdb(16'h1234, 16'd391, 32'd1024);
      mount(IMG_BYTES);
      ok("an unrecognised signature says nothing, even over a plausible MDB",
         media_ds === 1'b1);

      // 7. a valid signature over a drAlBlkSiz that is not a multiple of 512
      build_mdb(16'h4244, 16'd391, 32'd1000);
      mount(IMG_BYTES);
      ok("a drAlBlkSiz that is not a multiple of 512 is not believed",
         media_ds === 1'b1);

      // 7b. the widest allocation-block size the bounds admit. 32768 is
      //     a multiple of 512 and inside the 16-bit bound, so it reaches
      //     the multiply - and it is the only value that sets the TOP bit
      //     of the seven-bit multiplier, which no ordinary floppy volume
      //     does. Without it a multiply one step short still passes every
      //     other case here.
      build_mdb(16'h4244, 16'd25, 32'd32768);   // 25 x 32768 = 819,200
      mount(IMG_BYTES);
      ok("25 x 32768 (800K) reads as double-sided - the multiplier's top bit",
         media_ds === 1'b1);

      // 7c. a drAlBlkSiz whose HIGH word is set. The low word on its own
      //     looks perfectly reasonable (512), so only the high-word bound
      //     can reject this one.
      build_mdb(16'h4244, 16'd391, 32'h0001_0200); // 66,048
      mount(IMG_BYTES);
      ok("a drAlBlkSiz above 64K is not believed, however sane its low word",
         media_ds === 1'b1);

      // 8. an image with no sector 2 at all. Load a 400K volume first so a
      //    stale verdict would be visible as single-sided.
      build_mdb(16'hD2D7, 16'd391, 32'd1024);
      mount(IMG_BYTES);
      ok("(400K MFS loaded, so the verdict now stands at single-sided)",
         media_ds === 1'b0);
      mount(64'd1024);   // two sectors: sector 2 never streams
      ok("no sector 2 at all: says nothing, and does not keep the last answer",
         media_ds === 1'b1);

      // 9. and the verdict is rebuilt on every mount, not latched once
      build_mdb(16'h4244, 16'd1594, 32'd512);
      mount(IMG_BYTES);
      ok("(800K HFS: double-sided)", media_ds === 1'b1);
      build_mdb(16'hD2D7, 16'd391, 32'd1024);
      mount(IMG_BYTES);
      ok("remounting a 400K volume over an 800K one goes back to single-sided",
         media_ds === 1'b0);

      $display("");
      if (all_ok) $display("MEDIUM SNIFF GATE: PASS");
      else        $display("MEDIUM SNIFF GATE: FAIL");
      $finish;
   end

endmodule
