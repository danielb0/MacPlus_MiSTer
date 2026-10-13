`timescale 1ns/1ps
//
// CPU_TIMING_PLAN.md, "SE mode: the ADB mouse ignores Mouse Speed".
//
// The ADB Apple Standard Mouse counts 100 per inch (handler 1); the Plus
// counts 180. rtl/adb.sv must divide host counts by 9 x div / 5 so the OSD
// Mouse Speed gives the same feel in both models, carry the remainder, and
// add up reports that arrive between two reads.
//
// Run: iverilog -g2012 -I rtl -o sim/out/tb_adb_mouse_div.vvp
//        sim/tb_adb_mouse_div.v rtl/adb.sv && vvp sim/out/tb_adb_mouse_div.vvp
module tb_adb_mouse_div;

   localparam CE_MS = 8125;         // clk8_en_p ticks in one millisecond

   reg clk = 0;
   always #15.385 clk = ~clk;       // 32.5 MHz

   reg [1:0] cediv = 0;
   always @(posedge clk) cediv <= cediv + 1'b1;
   wire ce = (cediv == 2'b11);

   reg         reset = 1;
   reg  [1:0]  st = 2'b11;
   reg  [7:0]  din = 8'hFF;
   reg         din_strobe = 0;
   reg  [24:0] ps2_mouse = 0;
   reg  [10:0] ps2_key = 0;
   reg  [4:0]  div = 5'd8;
   wire        _int, listen, capslock;
   wire [7:0]  dout;
   wire        dout_strobe;

   adb dut(
      .clk(clk), .clk_en(ce), .reset(reset), .st(st), ._int(_int),
      .viaBusy(1'b0), .listen(listen), .adb_din(din),
      .adb_din_strobe(din_strobe), .adb_dout(dout),
      .adb_dout_strobe(dout_strobe), .capslock(capslock),
      .ps2_mouse(ps2_mouse), .ps2_key(ps2_key), .mouseDiv(div));

   integer idle_bytes = 0;
   reg     counting = 0;
   always @(posedge clk) if (ce && dout_strobe && counting && st == 2'b11)
      idle_bytes <= idle_bytes + 1;

   reg     capture = 0;
   integer got_n = 0;
   reg [7:0] got [0:3];
   always @(posedge clk) if (ce && dout_strobe && capture && got_n < 4) begin
      got[got_n] <= dout;
      got_n <= got_n + 1;
   end

   integer fails = 0;

   task ticks(input integer n);
      integer i;
      begin
         for (i = 0; i < n; i = i + 1) begin
            @(posedge clk); while (!ce) @(posedge clk);
         end
         #1;
      end
   endtask

   // An explicit Talk R0 to the mouse, the way the ROM runs it. State 0
   // flushes the previous read; the response bytes are captured.
   task talk_mouse;
      begin
         got_n = 0; capture = 1;
         st = 2'b00; ticks(200);
         din = 8'h3C; din_strobe = 1; ticks(1); din_strobe = 0;
         ticks(200);
         st = 2'b01; ticks(40);
         st = 2'b10; ticks(40);
         st = 2'b01; ticks(40);
         st = 2'b11; ticks(20);
         capture = 0;
      end
   endtask

   // A PS/2 report: dx, dy as 9-bit two's complement, PS/2 Y up positive.
   task report(input integer dx, input integer dy, input btn);
      reg [8:0] x9, y9;
      begin
         x9 = dx; y9 = dy;
         ps2_mouse = {~ps2_mouse[24], y9[7:0], x9[7:0], 2'b00, y9[8], x9[8], 3'b000, btn};
         ticks(400);
      end
   endtask

   // Talk R0 and compare X, Y (signed counts) and the button bit.
   task expect_read(input integer wx, input integer wy, input wbtn,
                    input [8*48-1:0] what);
      reg [6:0] ex, ey;
      reg [7:0] b0, b1;
      begin
         talk_mouse;
         ex = wx; ey = wy;
         b0 = {~wbtn, ey}; b1 = {1'b1, ex};
         if (got_n >= 2 && got[0] == b0 && got[1] == b1)
            $display("PASS  %0s: %h %h", what, got[0], got[1]);
         else begin
            $display("FAIL  %0s: %0d byte(s) %h %h, want %h %h",
                     what, got_n, got[0], got[1], b0, b1);
            fails = fails + 1;
         end
      end
   endtask

   task expect_idle(input integer want, input [8*48-1:0] what);
      begin
         idle_bytes = 0; counting = 1;
         ticks(15 * CE_MS);
         counting = 0;
         if ((want == 0 && idle_bytes == 0) || (want != 0 && idle_bytes >= 1))
            $display("PASS  %0s: %0d idle byte(s)", what, idle_bytes);
         else begin
            $display("FAIL  %0s: %0d idle byte(s), want %0s", what, idle_bytes,
                     want ? ">=1" : "0");
            fails = fails + 1;
         end
      end
   endtask

   initial begin
      ticks(10); reset = 0; ticks(10);
      talk_mouse;                       // address the mouse, enter state 3

      // div 8: one ADB count = 9 x 8 / 5 = 14.4 host counts.
      report(72, 0, 0);
      expect_read(5, 0, 0, "div 8, +72 -> 5");

      // Less than one count waits; the remainder carries into the next.
      report(10, 0, 0);
      expect_idle(0, "div 8, +10 alone not offered");
      report(62, 0, 0);
      expect_idle(1, "div 8, +62 more offered");
      expect_read(5, 0, 0, "div 8, +10 +62 -> 5");

      // ADB Y is down-positive: PS/2 up +144 -> -10.
      report(-72, 144, 0);
      expect_read(-5, -10, 0, "div 8, -72 / +144 -> -5 / -10");

      report(72, 0, 0);
      report(72, 0, 0);
      expect_read(10, 0, 0, "div 8, two reports before a read add up");

      // div 1: one count = 1.8 host counts; +255 = 141.67 -> 63, 63, 15.
      div = 5'd1;
      report(255, 0, 0);
      expect_read(63, 0, 0, "div 1, +255 first read saturates");
      expect_read(63, 0, 0, "div 1, +255 second read carries");
      expect_read(15, 0, 0, "div 1, +255 third read carries");

      report(0, 0, 1);
      expect_idle(1, "button press offered");
      expect_read(0, 0, 1, "button press, zero motion");
      report(0, 0, 0);
      expect_read(0, 0, 0, "button release");

      if (fails == 0) $display("ALL PASS");
      else            $display("%0d FAIL", fails);
      $finish;
   end
endmodule
