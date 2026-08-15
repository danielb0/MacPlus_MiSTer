`timescale 1ns/1ps
//
// Regression test for the SECOND half of the slot-3 write bug: even after
// addrController_top.v's arbiter was fixed (see tb_floppy_loader_integrated.v),
// hardware testing showed drive 1 (int) working but drive 2 (ext) still
// reading as "damaged". Root cause was in MacPlus.sv, not addrController_top.v:
//
//   wire [15:0] loader_wr_data = ldr_ext_wr_ack ? ldr_ext_wr_data : ldr_int_wr_data;
//
// ldr_ext_wr_ack (dskLoadAckExt) is a late pulse in busPhase 3 - one phase
// AFTER sdram.v's CAS phase (busPhase 1) already latched din. So during the
// instant that matters, ldr_ext_wr_ack is always 0, and loader_wr_data always
// fell through to ldr_int_wr_data - int's write data, or its stale/idle
// output when int was never mounted. Drive 1 "worked" only because it was
// the ternary's default branch; drive 2 always got int's data instead of
// its own.
//
// This bench instantiates BOTH floppy_loader drives exactly as MacPlus.sv
// does, mounts ONLY the ext (drive 2) image, and reconstructs loader_wr_data
// using the FIXED formula (dskLoadSelExt-based - held for the whole grant
// cycle, exposed as a new addrController_top.v output). dut_int never mounts,
// so if the mux ever falls back to ldr_int_wr_data during an actual write,
// the readback will not match the ext image and this test fails.
//
module tb_floppy_loader_ext;

   reg clk = 0;
   always #5 clk = ~clk;

   reg reset = 1;

   // ---- synthetic ext image: 3 sectors, distinctive per-byte pattern,
   // deliberately different from the int-side test's pattern so a wrong
   // selection is unambiguous ----
   localparam NSECT = 3;
   localparam IMG_BYTES = NSECT * 512;
   reg [7:0] img [0:IMG_BYTES-1];
   integer i;
   initial for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = (i * 8'd211 + 8'd17) & 8'hFF;

   // ---- addrController_top, CPU/video side quiescent, BOTH loader ports wired
   wire [21:0] memoryAddr;
   wire        dskReadAckInt, dskReadAckExt;
   wire        dskLoadAckInt, dskLoadAckExt, dskLoadWrEn, dskLoadSelExt;

   wire [21:0] ldr_int_wr_addr, ldr_ext_wr_addr;
   wire        ldr_int_wr_req,  ldr_ext_wr_req;
   wire [15:0] ldr_int_wr_data, ldr_ext_wr_data;

   addrController_top ac0 (
      .clk(clk),
      .clk8(), .clk8_en_p(), .clk8_en_n(), .clk16_en_p(), .clk16_en_n(),
      .turbo(1'b0),
      .configROMSize(2'b01),
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
      .dskLoadAddrInt(ldr_int_wr_addr), .dskLoadReqInt(ldr_int_wr_req), .dskLoadAckInt(dskLoadAckInt),
      .dskLoadAddrExt(ldr_ext_wr_addr), .dskLoadReqExt(ldr_ext_wr_req), .dskLoadAckExt(dskLoadAckExt),
      .dskLoadWrEn(dskLoadWrEn),
      .dskLoadSelExt(dskLoadSelExt)
   );

   // ---- dut_int: wired up but NEVER mounted - stand-in for MacPlus.sv's
   // idle int loader. Its wr_data must never end up in SDRAM this test.
   reg img_mounted_int = 0;
   wire [31:0] sd_lba_int;
   wire        sd_rd_int;
   reg         sd_ack_int = 0;
   wire        done_int;

   floppy_loader dut_int (
      .clk_sys(clk), .reset(reset),
      .img_mounted(img_mounted_int), .img_size(64'd0), .img_readonly(1'b0),
      .sd_lba(sd_lba_int), .sd_rd(sd_rd_int), .sd_ack(sd_ack_int),
      .sd_buff_addr(8'd0), .sd_buff_dout(16'd0), .sd_buff_wr(1'b0),
      .wr_addr(ldr_int_wr_addr), .wr_data(ldr_int_wr_data),
      .wr_req(ldr_int_wr_req), .wr_ack(dskLoadAckInt),
      .done(done_int), .loaded_size(), .readonly_latched(), .busy()
   );

   // ---- dut_ext: the drive under test ----
   reg         img_mounted_ext = 0;
   reg  [63:0] img_size_ext    = 0;

   wire [31:0] sd_lba_ext;
   wire        sd_rd_ext;
   reg         sd_ack_ext = 0;

   reg   [7:0] sd_buff_addr = 0;
   reg  [15:0] sd_buff_dout = 0;
   reg         sd_buff_wr = 0;

   wire        done_ext;
   wire [63:0] loaded_size_ext;

   floppy_loader dut_ext (
      .clk_sys(clk), .reset(reset),
      .img_mounted(img_mounted_ext), .img_size(img_size_ext), .img_readonly(1'b0),
      .sd_lba(sd_lba_ext), .sd_rd(sd_rd_ext), .sd_ack(sd_ack_ext),
      .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
      .wr_addr(ldr_ext_wr_addr), .wr_data(ldr_ext_wr_data),
      .wr_req(ldr_ext_wr_req), .wr_ack(dskLoadAckExt),
      .done(done_ext), .loaded_size(loaded_size_ext), .readonly_latched(), .busy()
   );

   // ---- MacPlus.sv's REAL (fixed) data mux ----
   wire [15:0] loader_wr_data = dskLoadSelExt ? ldr_ext_wr_data : ldr_int_wr_data;

   // ---- SDRAM model, same two-phase RAS/CAS sampling as tb_floppy_loader_integrated.v ----
   localparam [15:0] BUS_JUNK = 16'hBAD1;
   localparam [22:0] IMG_BASE = 23'h300000; // word addr of the EXT floppy image (see header derivation)

   wire [24:0] sdram_addr = {3'b000, (dskReadAckInt || dskReadAckExt || dskLoadWrEn), memoryAddr[21:1]};
   wire [15:0] sdram_din  = dskLoadWrEn ? loader_wr_data : BUS_JUNK;
   wire        sdram_we   = dskLoadWrEn ? 1'b1 : 1'b0;

   reg        we_latch = 0;
   reg [23:0] ras_addr = 0;
   wire [22:0] eff_addr = {sdram_addr[22], ras_addr[21:8], sdram_addr[7:0]};

   reg [15:0] mock_sdram [0:IMG_BYTES/2-1];
   integer stray_writes = 0;

   always @(posedge clk) begin
      if (ac0.busPhase == 2'b00) begin
         we_latch <= sdram_we;
         ras_addr <= sdram_addr[23:0];
      end
      if (ac0.busPhase == 2'b01 && we_latch) begin
         if (eff_addr >= IMG_BASE && eff_addr < IMG_BASE + IMG_BYTES/2)
            mock_sdram[eff_addr - IMG_BASE] <= sdram_din;
         else
            stray_writes = stray_writes + 1;
      end
   end

   // ---- mock hps_io serving whichever loader asserts sd_rd (only ext ever will) ----
   reg [8:0] word_i;
   reg [10:0] sect_i;
   reg [3:0] mock_state;
   localparam M_IDLE=0, M_ACKWAIT=1, M_STREAM=2, M_DROP=3;
   wire sd_rd = sd_rd_int || sd_rd_ext;
   always @(posedge clk) begin
      sd_buff_wr <= 0;
      case (mock_state)
      M_IDLE: if (sd_rd) begin
         sect_i <= sd_lba_ext[10:0];
         mock_state <= M_ACKWAIT;
      end
      M_ACKWAIT: begin
         sd_ack_ext <= 1;
         word_i <= 0;
         mock_state <= M_STREAM;
      end
      M_STREAM: begin
         sd_buff_addr <= word_i[7:0];
         sd_buff_dout <= { img[sect_i*512 + word_i*2 + 1], img[sect_i*512 + word_i*2] };
         sd_buff_wr <= 1;
         if (word_i == 9'd255) mock_state <= M_DROP;
         else word_i <= word_i + 9'd1;
      end
      M_DROP: begin
         sd_ack_ext <= 0;
         mock_state <= M_IDLE;
      end
      endcase
   end

   function [7:0] readback_byte;
      input integer p;
      reg [15:0] w;
      begin
         w = mock_sdram[p >> 1];
         readback_byte = p[0] ? w[7:0] : w[15:8];
      end
   endfunction

   integer errors;
   integer p;
   initial begin
      mock_state = M_IDLE;

      force ac0.busPhase = 2'b00;
      force ac0.busCycle = 2'b00;
      force ac0.extra_slot_count = 2'b00;
      @(posedge clk);
      release ac0.busPhase;
      release ac0.busCycle;
      release ac0.extra_slot_count;

      @(posedge clk); @(negedge clk);
      reset = 0;

      img_size_ext = IMG_BYTES;
      @(posedge clk);
      img_mounted_ext = 1;
      @(posedge clk);
      img_mounted_ext = 0;

      wait (done_ext);
      @(posedge clk);

      if (loaded_size_ext !== IMG_BYTES) begin
         $display("FAIL: loaded_size = %0d, expected %0d", loaded_size_ext, IMG_BYTES);
         $finish;
      end

      errors = 0;
      for (p = 0; p < IMG_BYTES; p = p + 1) begin
         if (readback_byte(p) !== img[p]) begin
            if (errors < 16)
               $display("MISMATCH at byte %0d: got %02h, expected %02h", p, readback_byte(p), img[p]);
            errors = errors + 1;
         end
      end

      if (stray_writes != 0)
         $display("%0d write(s) landed outside the ext image region", stray_writes);

      if (errors == 0 && stray_writes == 0)
         $display("PASS: all %0d bytes round-tripped correctly through the EXT (drive 2) path, dut_int never contaminated the data", IMG_BYTES);
      else
         $display("FAIL: %0d/%0d bytes mismatched, %0d stray writes", errors, IMG_BYTES, stray_writes);

      $finish;
   end

   initial begin
      #5000000;
      $display("FAIL: timeout - done_ext never fired");
      $finish;
   end

endmodule
