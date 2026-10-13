`timescale 1ns/1ps
//
// CPU_TIMING_PLAN.md, "SE mode: the ADB idle tax".
//
// The real SE transceiver auto-polls the last Talk every 11 ms in state 3 but
// only shifts a byte to the VIA (a shift-register interrupt) when the device
// answered or an SRQ was seen. rtl/adb.sv shifts $FF 11 ms after every Talk,
// and the SE ROM then runs a whole Talk transaction and calls the mouse
// driver. This bench drives the ROM's side of the protocol: a Talk R0 to the
// mouse (address 3), the two response bytes, then state 3.
//
// Rows: idle with no input -> no byte; a mouse report -> one byte; a key while
// the mouse is addressed (SRQ) -> one byte.
//
// Run: iverilog -g2012 -I rtl -o sim/out/tb_adb_idle.vvp sim/tb_adb_idle.v
//        rtl/adb.sv && vvp sim/out/tb_adb_idle.vvp
module tb_adb_idle;

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
   wire        _int, listen, capslock;
   wire [7:0]  dout;
   wire        dout_strobe;

   adb dut(
      .clk(clk), .clk_en(ce), .reset(reset), .st(st), ._int(_int),
      .viaBusy(1'b0), .listen(listen), .adb_din(din),
      .adb_din_strobe(din_strobe), .adb_dout(dout),
      .adb_dout_strobe(dout_strobe), .capslock(capslock),
      .ps2_mouse(ps2_mouse), .ps2_key(ps2_key));

   integer idle_bytes = 0;
   reg     counting = 0;
   always @(posedge clk) if (ce && dout_strobe && counting && st == 2'b11)
      idle_bytes <= idle_bytes + 1;

   reg     capture = 0;
   integer got_n = 0;
   reg [7:0] got [0:3];
   reg     int_end;
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

   // One Talk R0 to the mouse, the way the ROM runs it: state 0 with the
   // command byte, states 1 and 2 for the two data bytes, then idle.
   task talk_mouse;
      begin
         st = 2'b00; ticks(20);
         din = 8'h3C; din_strobe = 1; ticks(1); din_strobe = 0;
         ticks(20);
         st = 2'b01; ticks(40);
         st = 2'b10; ticks(40);
         st = 2'b01; ticks(40);
         st = 2'b11; ticks(20);
      end
   endtask

   task expect_bytes(input integer want, input [8*40-1:0] what);
      begin
         if (idle_bytes == want)
            $display("PASS  %0s: %0d idle byte(s)", what, idle_bytes);
         else begin
            $display("FAIL  %0s: %0d idle byte(s), want %0d", what, idle_bytes, want);
            fails = fails + 1;
         end
      end
   endtask

   // Unread data is re-offered on every 11 ms poll, so a report counts as
   // offered if at least one byte arrived.
   task expect_offered(input [8*40-1:0] what);
      begin
         if (idle_bytes >= 1)
            $display("PASS  %0s: %0d idle byte(s)", what, idle_bytes);
         else begin
            $display("FAIL  %0s: no idle byte", what);
            fails = fails + 1;
         end
      end
   endtask

   initial begin
      ticks(10); reset = 0; ticks(10);

      // Twice, so the second Talk repeats the first (the same-command path).
      talk_mouse;
      talk_mouse;
      idle_bytes = 0; counting = 1;
      ticks(50 * CE_MS);
      expect_bytes(0, "idle, no input, 50 ms");

      // A mouse report: the addressed device has data.
      idle_bytes = 0;
      ps2_mouse = {~ps2_mouse[24], 8'd0, 8'd5, 8'h00};
      ticks(15 * CE_MS);
      expect_offered("mouse report while idle");

      // The ROM reads auto-poll data by going straight from state 3 to 1
      // (SE ROM $403618). The response must start at its first byte:
      // {~button, Y, 1, X} = $80 $85, then a read past the end: INT low
      // and the cleared buffer's $FF, as the firmware's SBASrq0 does.
      counting = 0; got_n = 0; capture = 1;
      st = 2'b01; ticks(40);
      st = 2'b10; ticks(40);
      st = 2'b01; ticks(40);
      int_end = _int;
      st = 2'b11; ticks(20);
      capture = 0;
      if (got_n == 3 && got[0] == 8'h80 && got[1] == 8'h85 && got[2] == 8'hFF
          && int_end == 0)
         $display("PASS  auto-poll read-out: %h %h %h, INT low at end", got[0], got[1], got[2]);
      else begin
         $display("FAIL  auto-poll read-out: %0d byte(s) %h %h %h, INT %b at end",
                  got_n, got[0], got[1], got[2], int_end);
         fails = fails + 1;
      end

      // Read once, the report must not be offered again.
      idle_bytes = 0; counting = 1;
      ticks(30 * CE_MS);
      expect_bytes(0, "same report not re-offered");

      // The transceiver keeps auto-polling in state 3: a second report with
      // no new command in between must still be offered.
      idle_bytes = 0;
      ps2_mouse = {~ps2_mouse[24], 8'd0, 8'd3, 8'h00};
      ticks(15 * CE_MS);
      expect_offered("second report, no new command");

      // Read it out as the ROM would, then a key: the keyboard is not the
      // addressed device, so this is the SRQ case.
      counting = 0;
      talk_mouse;
      ticks(2 * CE_MS);
      idle_bytes = 0; counting = 1;
      ps2_key = {~ps2_key[10], 1'b1, 9'h01C};   // 'a' pressed
      ticks(15 * CE_MS);
      expect_offered("key while mouse addressed (SRQ)");

      if (fails == 0) $display("ALL PASS");
      else            $display("%0d FAIL", fails);
      $finish;
   end
endmodule
