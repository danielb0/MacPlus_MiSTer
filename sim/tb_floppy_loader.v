`timescale 1ns/1ps
//
// Standalone testbench for rtl/floppy_loader.v, built to chase down the
// "every mounted disk is unreadable" report after the byte-swap fix didn't
// resolve it (see FLOPPY_WRITE_PLAN.md Phase 1 STATUS). Mocks hps_io's
// sd_rd/sd_ack/sd_buff_* handshake (per sys/hps_io.sv, traced by hand: the
// wr <= 0 reset, the b_wr shift register giving sd_buff_wr a one-cycle
// pulse per word, sd_buff_addr counting 0..255 and resetting to 0 at the
// START of each transfer) and the addrController_top extra-slot-3 write
// grant (a plain one-cycle-per-request ack, confirmed by hand-tracing
// addrController_top.v's dskLoadGrant/dskLoadAckInt - purely combinational
// on the still-asserted req, so it cannot double-fire once the loader drops
// its own req the cycle after being acked).
//
// Then replays the exact byte-selection formula extra_rom_data_demux uses
// in MacPlus.sv to read the mock SDRAM back out, and compares against the
// original synthetic image byte-for-byte. This isolates floppy_loader.v's
// OWN internal addressing/sequencing/byte-swap logic from the one thing a
// testbench cannot independently verify - what byte order the real ARM
// firmware actually sends over sd_buff_dout. The mock drives sd_buff_dout
// per the convention derived from scsi.v's OWN working code (dout <=
// data_cnt[0] ? buffer1_dout : buffer0_dout, buffer0<-sd_buff_dout[7:0]):
// sd_buff_dout[7:0] = image byte at the EVEN position of the word pair,
// sd_buff_dout[15:8] = the ODD position.
//
module tb_floppy_loader;

   reg clk_sys = 0;
   always #5 clk_sys = ~clk_sys;

   reg reset = 1;

   // ---- synthetic image: 3 sectors, distinctive per-byte pattern ----
   localparam NSECT = 3;
   localparam IMG_BYTES = NSECT * 512;
   reg [7:0] img [0:IMG_BYTES-1];
   integer i;
   initial for (i = 0; i < IMG_BYTES; i = i + 1) img[i] = (i * 8'd137 + 8'd41) & 8'hFF;

   // ---- DUT ----
   reg         img_mounted = 0;
   reg  [63:0] img_size    = 0;
   reg         img_readonly = 0;

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
   wire        readonly_latched;
   wire        busy;

   floppy_loader dut (
      .clk_sys(clk_sys),
      .reset(reset),
      .img_mounted(img_mounted),
      .img_size(img_size),
      .img_readonly(img_readonly),
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
      .readonly_latched(readonly_latched),
      .busy(busy)
   );

   // ---- mock SDRAM: word-addressable, byte-addressed on readback below ----
   reg [15:0] mock_sdram [0:IMG_BYTES/2-1];

   // ---- mock addrController_top extra-slot-3 write grant ----
   // One-cycle-per-request ack, a couple of idle cycles of arbitration
   // "latency" to mimic waiting for the slot to come around, matching the
   // real ~2us-per-slot cadence in spirit (scaled down for sim speed).
   reg [1:0] grant_wait;
   always @(posedge clk_sys) begin
      wr_ack <= 0;
      if (wr_req && !wr_ack) begin
         if (grant_wait != 0) grant_wait <= grant_wait - 1'd1;
         else begin
            wr_ack <= 1;
            mock_sdram[wr_addr[21:1]] <= wr_data;
            grant_wait <= 2'd2;
         end
      end
      else if (!wr_req) grant_wait <= 2'd2;
   end

   // ---- mock hps_io: sd_rd -> sd_ack -> 256 x sd_buff_wr -> !sd_ack ----
   reg [8:0] word_i;
   reg [10:0] sect_i;
   reg [3:0] mock_state;
   localparam M_IDLE=0, M_ACKWAIT=1, M_STREAM=2, M_DROP=3;
   always @(posedge clk_sys) begin
      sd_buff_wr <= 0;
      case (mock_state)
      M_IDLE: if (sd_rd) begin
         sect_i <= sd_lba[10:0];
         grant_wait <= grant_wait; // no-op, keep lint quiet
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

   // ---- readback via the exact extra_rom_data_demux formula ----
   function [7:0] readback_byte;
      input integer p; // byte position within the image
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
      grant_wait = 2'd2;

      @(posedge clk_sys); @(negedge clk_sys);
      reset = 0;

      img_size = IMG_BYTES;
      @(posedge clk_sys);
      img_mounted = 1;
      @(posedge clk_sys);
      img_mounted = 0;

      wait (done);
      @(posedge clk_sys);

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

      if (errors == 0) $display("PASS: all %0d bytes round-tripped correctly", IMG_BYTES);
      else $display("FAIL: %0d/%0d bytes mismatched", errors, IMG_BYTES);

      $finish;
   end

   initial begin
      #2000000;
      $display("FAIL: timeout - done never fired (busy=%b state stuck)", busy);
      $finish;
   end

endmodule
