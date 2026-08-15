`timescale 1ns/1ps
//
// Integration testbench: floppy_loader.v driving the REAL
// addrController_top.v's extra-slot-3 arbitration (not a simplified mock),
// to rule out any timing subtlety in the actual 4-clk_sys-cycle-per-slot
// grant mechanism that the simpler tb_floppy_loader.v mock might have
// papered over. CPU/video ports are tied off quiescent (_cpuAS=1, no CPU
// access ever requested) so extra_slot_count free-runs predictably.
//
module tb_floppy_loader_integrated;

   reg clk = 0;
   always #5 clk = ~clk;

   reg reset = 1;

   // ---- synthetic image: 3 sectors, distinctive per-byte pattern ----
   localparam NSECT = 3;
   localparam IMG_BYTES = NSECT * 512;
   reg [7:0] img [0:IMG_BYTES-1];
   integer i;
   initial for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = (i * 8'd137 + 8'd41) & 8'hFF;

   // ---- addrController_top, CPU/video side quiescent ----
   wire [21:0] memoryAddr;
   wire        dskReadAckInt, dskReadAckExt;
   wire        dskLoadAckInt, dskLoadAckExt, dskLoadWrEn;

   reg  [21:0] ldrA_wr_addr, ldrB_wr_addr; // unused second loader tie-offs
   reg         ldrB_wr_req = 0;

   wire [21:0] ldr_wr_addr;
   wire        ldr_wr_req;

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
      .dskLoadAddrInt(ldr_wr_addr), .dskLoadReqInt(ldr_wr_req), .dskLoadAckInt(dskLoadAckInt),
      .dskLoadAddrExt(22'd0),       .dskLoadReqExt(ldrB_wr_req), .dskLoadAckExt(dskLoadAckExt),
      .dskLoadWrEn(dskLoadWrEn)
   );

   // ---- floppy_loader DUT (the "int" drive) ----
   reg         img_mounted = 0;
   reg  [63:0] img_size    = 0;

   wire [31:0] sd_lba;
   wire        sd_rd;
   reg         sd_ack = 0;

   reg   [7:0] sd_buff_addr = 0;
   reg  [15:0] sd_buff_dout = 0;
   reg         sd_buff_wr = 0;

   wire [15:0] ldr_wr_data;
   wire        done;
   wire [63:0] loaded_size;

   floppy_loader dut (
      .clk_sys(clk),
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
      .wr_addr(ldr_wr_addr),
      .wr_data(ldr_wr_data),
      .wr_req(ldr_wr_req),
      .wr_ack(dskLoadAckInt),
      .done(done),
      .loaded_size(loaded_size),
      .readonly_latched(),
      .busy()
   );

   // ---- SDRAM model with sdram.v's REAL two-phase sampling ----------------
   //
   // The first version of this testbench latched address+data in one shot off
   // dskLoadAckInt. That is not how sdram.v works, and it is why this bench
   // passed against RTL that could not possibly work on hardware: sdram.v
   // issues ACTIVE (row/bank + the oe/we decision) from the signals present
   // during busPhase 0, and WRITE (column address AND write data) from the
   // signals present one clk_sys cycle later, during busPhase 1. Anything
   // that tears its request down in between commits a write to a wrong
   // column with whatever is on the data bus by then.
   //
   // Modelled here at clk_sys resolution (signals are stable within a phase):
   //   posedge with busPhase==0 -> samples the busPhase-0 values (RAS)
   //   posedge with busPhase==1 -> samples the busPhase-1 values (CAS)
   // Chip address mapping, from sdram.v: bank=addr[21:20], row=addr[19:8],
   // column={addr[22], addr[7:0]} - so the column bits come from the CAS
   // sample and everything else from the RAS sample.

   localparam [15:0] BUS_JUNK = 16'hBAD1;   // stands in for memoryDataOut
   localparam [22:0] IMG_BASE = 23'h280000; // word addr of the int floppy image

   // exactly MacPlus.sv's muxes
   wire [24:0] sdram_addr = {3'b000, (dskReadAckInt || dskReadAckExt || dskLoadWrEn), memoryAddr[21:1]};
   wire [15:0] sdram_din  = dskLoadWrEn ? ldr_wr_data : BUS_JUNK;
   wire        sdram_we   = dskLoadWrEn ? 1'b1 : 1'b0;

   reg        we_latch = 0;
   reg [23:0] ras_addr = 0;
   wire [22:0] eff_addr = {sdram_addr[22], ras_addr[21:8], sdram_addr[7:0]};

   reg [15:0] mock_sdram [0:IMG_BYTES/2-1];
   integer stray_writes = 0;

   always @(posedge clk) begin
      if (ac0.busPhase == 2'b00) begin   // RAS: row/bank + we decision
         we_latch <= sdram_we;
         ras_addr <= sdram_addr[23:0];
      end
      if (ac0.busPhase == 2'b01 && we_latch) begin   // CAS: column + data
         if (eff_addr >= IMG_BASE && eff_addr < IMG_BASE + IMG_BYTES/2)
            mock_sdram[eff_addr - IMG_BASE] <= sdram_din;
         else
            stray_writes = stray_writes + 1;
      end
   end

   // ---- mock hps_io: sd_rd -> sd_ack -> 256 x sd_buff_wr -> !sd_ack ----
   reg [8:0] word_i;
   reg [10:0] sect_i;
   reg [3:0] mock_state;
   localparam M_IDLE=0, M_ACKWAIT=1, M_STREAM=2, M_DROP=3;
   always @(posedge clk) begin
      sd_buff_wr <= 0;
      case (mock_state)
      M_IDLE: if (sd_rd) begin
         sect_i <= sd_lba[10:0];
         mock_state <= M_ACKWAIT;
      end
      M_ACKWAIT: begin
         sd_ack <= 1;
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
         sd_ack <= 0;
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

      // addrController_top's busPhase/busCycle/extra_slot_count have no
      // explicit reset - real Cyclone V hardware powers registers up to 0
      // (standard, relied on elsewhere in this design too), but Icarus
      // leaves them X forever without an initial value. Force the real
      // hardware's power-up state so this sim actually exercises the DUT
      // instead of stalling on X.
      force ac0.busPhase = 2'b00;
      force ac0.busCycle = 2'b00;
      force ac0.extra_slot_count = 2'b00;
      @(posedge clk);
      release ac0.busPhase;
      release ac0.busCycle;
      release ac0.extra_slot_count;

      @(posedge clk); @(negedge clk);
      reset = 0;

      img_size = IMG_BYTES;
      @(posedge clk);
      img_mounted = 1;
      @(posedge clk);
      img_mounted = 0;

      wait (done);
      @(posedge clk);

      if (loaded_size !== IMG_BYTES) begin
         $display("FAIL: loaded_size = %0d, expected %0d", loaded_size, IMG_BYTES);
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
         $display("%0d write(s) landed outside the image region", stray_writes);

      if (errors == 0 && stray_writes == 0)
         $display("PASS: all %0d bytes round-tripped correctly through the REAL addrController_top arbiter and sdram.v's two-phase sampling", IMG_BYTES);
      else
         $display("FAIL: %0d/%0d bytes mismatched, %0d stray writes", errors, IMG_BYTES, stray_writes);

      $finish;
   end

   initial begin
      #5000000;
      $display("FAIL: timeout - done never fired");
      $display("  sd_rd=%b sd_ack=%b mock_state=%0d word_i=%0d sect_i=%0d", sd_rd, sd_ack, mock_state, word_i, sect_i);
      $display("  ldr_wr_req=%b dskLoadAckInt=%b dskLoadWrEn=%b dut.state=%0d dut.word_idx=%0d dut.sector=%0d",
                ldr_wr_req, dskLoadAckInt, dskLoadWrEn, dut.state, dut.word_idx, dut.sector);
      $finish;
   end

endmodule
