`timescale 1ns/1ps
//
// MOUSE_PLAN.md: the PS/2 -> quadrature converter's bursts, tail and scale.
//
// The REAL rtl/ps2_mouse.v, clk at 32.5 MHz with ce one cycle in four (as
// clk8_en_p is), fed PS/2 reports on the ps2_mouse[24] toggle and decoded
// the way the ROM does: one count per x1 edge, direction from x2 at that
// edge (x2 != x1 is positive, the sense the module already emits).
//
// Every deadline is counted in ce ticks, not wall time, so the numbers are
// exact whatever the clock period rounds to: 1 ms = 8125 ce, one report
// interval (16 ms) = 130000 ce, the emitter's rate ceiling = 4096 ce and
// the DDA interval (1024 fine ticks of 128 ce) = 131072 ce.
//
// Written before the fix, against the div port added unused in the same
// commit. On rtl/ps2_mouse.v as it stands the burst, spreading, remainder,
// direction, tail, backlog and both-axes rows fail; silence, reset and
// button pass now and must keep passing.
//
// Run: iverilog -g2012 -I rtl -y rtl -o sim/out/tb_ps2_mouse.vvp
//        sim/tb_ps2_mouse.v && vvp sim/out/tb_ps2_mouse.vvp
module tb_ps2_mouse;

   localparam CE_MS    = 8125;      // ce ticks in one millisecond
   localparam CE_RPT   = 130000;    // one 16 ms report interval
   localparam CE_CEIL  = 4096;      // the per-axis rate ceiling
   localparam CE_DDA   = 131072;    // 1024 fine ticks, one planning interval
   localparam BIG      = 1000000000;

   reg clk = 0;
   always #15.385 clk = ~clk;       // 32.5 MHz

   reg [1:0] cediv = 0;
   always @(posedge clk) cediv <= cediv + 1'b1;
   wire ce = (cediv == 2'b11);      // clk8_en_p is one phase in four

   reg         reset = 1;
   reg  [24:0] ps2_mouse = 25'd0;
   reg  [4:0]  div = 5'd8;
   wire        x1, y1, x2, y2, button;

   ps2_mouse dut (
      .clk(clk),
      .ce(ce),
      .reset(reset),
      .ps2_mouse(ps2_mouse),
      .div(div),
      .x1(x1), .y1(y1), .x2(x2), .y2(y2),
      .button(button)
   );

   integer ce_count = 0;
   always @(posedge clk) if (ce) ce_count <= ce_count + 1;

   // ---- the ROM's view: one count per x1 edge, sign from x2 -------------
   // The DUT drives x1 and x2 from the same non-blocking assignment, so the
   // edge is seen one clk late and both lines are already the new values.
   reg     x1d = 0, y1d = 0;
   integer xn = 0, yn = 0;                 // edges since the last clear
   integer xpos = 0, ypos = 0;             // decoded travel, in counts
   integer xlast = 0, ylast = 0;           // ce_count at the last edge
   integer xgap_min = BIG, ygap_min = BIG;
   integer xgap_max = 0, ygap_max = 0;
   integer xt [0:4095];                    // ce_count of each x edge
   integer gap_tmp;

   always @(posedge clk) begin
      x1d <= x1;
      if (x1 !== x1d) begin
         if (xn > 0) begin
            gap_tmp = ce_count - xlast;
            if (gap_tmp < xgap_min) xgap_min = gap_tmp;
            if (gap_tmp > xgap_max) xgap_max = gap_tmp;
         end
         xlast = ce_count;
         if (xn < 4096) xt[xn] = ce_count;
         xn   = xn + 1;
         xpos = xpos + ((x2 !== x1) ? 1 : -1);
      end
   end

   always @(posedge clk) begin
      y1d <= y1;
      if (y1 !== y1d) begin
         if (yn > 0) begin
            gap_tmp = ce_count - ylast;
            if (gap_tmp < ygap_min) ygap_min = gap_tmp;
            if (gap_tmp > ygap_max) ygap_max = gap_tmp;
         end
         ylast = ce_count;
         yn   = yn + 1;
         ypos = ypos + ((y2 !== y1) ? 1 : -1);
      end
   end

   task clear_stats;
      begin
         xn = 0; yn = 0; xpos = 0; ypos = 0;
         xlast = ce_count; ylast = ce_count;
         xgap_min = BIG; ygap_min = BIG;
         xgap_max = 0; ygap_max = 0;
      end
   endtask

   // most edges in any window of `win` ce, over the recorded x edges
   function integer x_max_in_window(input integer win);
      integer i, j, c, best;
      begin
         best = 0;
         i = 0;
         while (i < xn && i < 4096) begin
            c = 0; j = i;
            while (j < xn && j < 4096 && (xt[j] - xt[i]) < win) begin
               c = c + 1; j = j + 1;
            end
            if (c > best) best = c;
            i = i + 1;
         end
         x_max_in_window = best;
      end
   endfunction

   integer fails = 0, tests = 0;
   task check(input cond, input [639:0] what);
      begin
         tests = tests + 1;
         if (!cond) begin fails = fails + 1; $display("  FAIL: %0s", what); end
      end
   endtask

   // One ce is 4 clk, i.e. 123.08 ns. Waiting in time rather than counting
   // edges keeps the run down to minutes; every deadline is still measured
   // in ce_count, so nothing here depends on the delay being exact.
   task wait_ce(input integer n);
      begin
         #(n * 123.08);
         @(posedge clk); #1;      // stimulus settles clear of the DUT's own edge
      end
   endtask

   integer strobe_ce = 0;
   task send_report(input signed [8:0] dx, input signed [8:0] dy);
      begin
         @(posedge clk); #1;
         ps2_mouse[2:0]   = 3'b000;      // no buttons
         ps2_mouse[3]     = 1'b1;        // the PS/2 always-one bit
         ps2_mouse[4]     = dx[8];       // X sign
         ps2_mouse[5]     = dy[8];       // Y sign
         ps2_mouse[7:6]   = 2'b00;       // overflow flags, unused here
         ps2_mouse[15:8]  = dx[7:0];
         ps2_mouse[23:16] = dy[7:0];
         ps2_mouse[24]    = ~ps2_mouse[24];
         strobe_ce        = ce_count;
         @(posedge clk);
      end
   endtask

   task do_reset;
      begin
         reset = 1;
         wait_ce(64);
         reset = 0;
         wait_ce(64);
         clear_stats;
      end
   endtask

   integer i, n_after, n_tail, xpos_prev, xn_prev;

   initial begin
      div = 5'd8;
      wait_ce(16);
      do_reset;

      // ---- silence ------------------------------------------------------
      $display("silence: no reports, then one zero report");
      wait_ce(100 * CE_MS);
      send_report(9'sd0, 9'sd0);
      wait_ce(100 * CE_MS);
      check(xn == 0, "silence: x emitted an edge with no motion");
      check(yn == 0, "silence: y emitted an edge with no motion");

      // ---- burst: the defect --------------------------------------------
      // +200 host units at DIV 8 is 25 counts, and they must all be out
      // within one planning interval. Today the emitter drains at its
      // ceiling: 200 edges, the last ~101 ms after the report.
      $display("burst: one report of +200, DIV 8, then 300 ms of nothing");
      div = 5'd8;
      do_reset;
      send_report(9'sd200, 9'sd0);
      wait_ce(300 * CE_MS);
      $display("  x edges %0d, last edge %0d ce after the report", xn, xlast - strobe_ce);
      check(xn == 25, "burst: 200 host units at DIV 8 is not 25 counts");
      check((xlast - strobe_ce) <= 20 * CE_MS, "burst: the last count is more than 20 ms after the report");
      check(yn == 0, "burst: y moved on an x-only report");

      // ---- spreading -----------------------------------------------------
      // 20 reports of +40 at DIV 8 is 5 counts per interval; they must be
      // spread across it, not fired back to back at the ceiling.
      $display("spreading: 20 reports of +40 at 16 ms, DIV 8");
      div = 5'd8;
      do_reset;
      for (i = 0; i < 20; i = i + 1) begin
         send_report(9'sd40, 9'sd0);
         wait_ce(CE_RPT);
      end
      wait_ce(40 * CE_MS);
      $display("  x edges %0d, gaps %0d..%0d ce (nominal 26214)", xn, xgap_min, xgap_max);
      check(xn == 100, "spreading: 800 host units at DIV 8 is not 100 counts");
      check(xgap_min >= 13000, "spreading: counts came out closer than half the nominal spacing");
      check(xgap_max <= 52000, "spreading: counts came out further apart than twice the nominal spacing");
      check(xgap_min >= CE_CEIL, "spreading: a gap broke the rate ceiling");

      // ---- remainder ------------------------------------------------------
      // 50 reports of +3 is 150 host units: 18 counts at DIV 8, with 6 left
      // in the backlog. Fine motion must accumulate rather than round to
      // zero, and the leftover must NOT dribble out once the hand stops --
      // which is also the row that catches a DDA whose phase keeps running
      // while the budget is below DIV.
      $display("remainder: 50 reports of +3 at 16 ms, DIV 8");
      div = 5'd8;
      do_reset;
      for (i = 0; i < 50; i = i + 1) begin
         send_report(9'sd3, 9'sd0);
         wait_ce(CE_RPT);
      end
      n_after = xn;
      wait_ce(40 * CE_MS);
      $display("  x edges %0d, %0d of them after the last report", xn, xn - n_after);
      check(xn == 18, "remainder: 150 host units at DIV 8 is not 18 counts");
      check(xn == n_after, "remainder: the sub-DIV remainder was flushed after the hand stopped");

      // ---- direction -------------------------------------------------------
      // At DIV 4 a +-40 report is 10 counts, spread over its own interval, so
      // each report's edges are attributable to it.
      // Per interval the decoded travel must equal the edge count with the
      // report's sign: that is "every edge's sign matches the report that
      // produced it", stated without depending on where the interval
      // boundary falls among the edges.
      $display("direction: +40 / -40 alternating, 10 each, DIV 4");
      div = 5'd4;
      do_reset;
      for (i = 0; i < 20; i = i + 1) begin
         xpos_prev = xpos; xn_prev = xn;
         send_report((i % 2 == 0) ? 9'sd40 : -9'sd40, 9'sd0);
         wait_ce(CE_RPT);
         if (i % 2 == 0)
            check((xpos - xpos_prev) ==  (xn - xn_prev), "direction: an edge decoded negative inside a +40 report's interval");
         else
            check((xpos - xpos_prev) == -(xn - xn_prev), "direction: an edge decoded positive inside a -40 report's interval");
      end
      wait_ce(40 * CE_MS);
      // The total is a band, not a number. 800 host units at DIV 4 cannot
      // give more than 200 counts. At the low end, a report interval is
      // 1015.6 fine ticks but draining 40 units at DIV 4 takes 1024, so at
      // every reversal the one count still in flight is cancelled by the
      // report that reverses it instead of being emitted - correct, and at
      // most one count per boundary, so not below 200 - 20. Sustained
      // motion loses nothing: the spreading row above is exactly 100 of
      // 100, because there the remainder adds to the next report's rate.
      // Today's module gives 638.
      $display("  decoded travel %0d counts over %0d edges", xpos, xn);
      check(xpos == 0,  "direction: equal travel each way did not decode to zero");
      check(xn   <= 200, "direction: more counts than the host units divided by DIV");
      check(xn   >= 180, "direction: the reversal cancelled more than a rounding remainder");

      // ---- ceiling and backlog ----------------------------------------------
      // 10 reports of +255 at DIV 4 is ~64 counts per interval, twice what
      // the ceiling passes. The excess must be capped, not queued: the cap
      // is not visible on the pins, but its size is -- 64 counts at the
      // ceiling is a 32 ms tail, so a longer tail means a bigger backlog.
      $display("ceiling and backlog: 10 reports of +255 at 16 ms, DIV 4");
      div = 5'd4;
      do_reset;
      for (i = 0; i < 10; i = i + 1) begin
         send_report(9'sd255, 9'sd0);
         wait_ce(CE_RPT);
      end
      n_after = xn;
      wait_ce(40 * CE_MS);
      n_tail = xn;
      wait_ce(60 * CE_MS);
      $display("  x edges %0d, %0d in the 40 ms tail, %0d after it, worst window %0d",
               xn, n_tail - n_after, xn - n_tail, x_max_in_window(CE_DDA));
      check(xgap_min >= CE_CEIL, "ceiling: a gap broke the rate ceiling");
      check(x_max_in_window(CE_DDA) <= 32, "ceiling: more than 32 counts in one planning interval");
      check(xn == n_tail, "backlog: counts were still coming out 40 ms after the last report");

      // ---- the report today's accumulator drops -------------------------------
      // Three +255 reports 1 ms apart drive |acc| past 255, which is where
      // the current module discards a whole report instead of saturating.
      // After the fix the backlog saturates and the tail is bounded.
      $display("backlog cap: three reports of +255 1 ms apart, DIV 1");
      div = 5'd1;
      do_reset;
      for (i = 0; i < 3; i = i + 1) begin
         send_report(9'sd255, 9'sd0);
         wait_ce(1 * CE_MS);
      end
      wait_ce(40 * CE_MS);
      n_tail = xn;
      wait_ce(260 * CE_MS);
      $display("  x edges %0d, %0d of them after the 40 ms tail", xn, xn - n_tail);
      check(xn == n_tail, "backlog cap: 765 host units were queued, not capped");

      // ---- resume after a pause ----------------------------------------------
      // A gesture that ends on a sub-DIV remainder leaves a rate latched and a
      // phase part of the way to the next count. If the emitter keeps accruing
      // phase through the still period it banks credit, and the next gesture
      // discharges it at the ceiling -- the original defect in a narrow case.
      // The first count of the new gesture must arrive one nominal spacing
      // after the report, not immediately.
      $display("resume: 7 reports of +3, 500 ms still, then +40, DIV 8");
      div = 5'd8;
      do_reset;
      for (i = 0; i < 7; i = i + 1) begin send_report(9'sd3, 9'sd0); wait_ce(CE_RPT); end
      wait_ce(500 * CE_MS);
      clear_stats;
      send_report(9'sd40, 9'sd0);
      wait_ce(40 * CE_MS);
      $display("  first count %0d ce after the report, %0d counts, min gap %0d",
               xt[0] - strobe_ce, xn, xgap_min);
      check(xn == 5, "resume: 45 host units at DIV 8 did not give 5 counts");
      check((xt[0] - strobe_ce) >= 13000, "resume: the first count rode out on banked phase");
      check(xgap_min >= 13000, "resume: the new gesture came out at the ceiling");

      // ---- both axes ---------------------------------------------------------
      $display("both axes: 5 reports each of x only, y only, then both, DIV 8");
      div = 5'd8;
      do_reset;
      for (i = 0; i < 5; i = i + 1) begin send_report(9'sd40, 9'sd0); wait_ce(CE_RPT); end
      wait_ce(40 * CE_MS);
      check(xn == 25, "both axes: x-only reports did not give 25 counts");
      check(yn == 0,  "both axes: y moved on x-only reports");

      clear_stats;
      for (i = 0; i < 5; i = i + 1) begin send_report(9'sd0, 9'sd40); wait_ce(CE_RPT); end
      wait_ce(40 * CE_MS);
      check(yn == 25, "both axes: y-only reports did not give 25 counts");
      check(xn == 0,  "both axes: x moved on y-only reports");

      clear_stats;
      for (i = 0; i < 5; i = i + 1) begin send_report(9'sd40, -9'sd40); wait_ce(CE_RPT); end
      wait_ce(40 * CE_MS);
      $display("  diagonal: x %0d counts, y %0d counts", xpos, ypos);
      check(xpos ==  25, "both axes: the diagonal's x did not decode as +25");
      check(ypos == -25, "both axes: the diagonal's y did not decode as -25");

      // ---- reset ---------------------------------------------------------------
      $display("reset: asserted mid-burst");
      div = 5'd8;
      do_reset;
      send_report(9'sd200, 9'sd0);
      wait_ce(5 * CE_MS);
      reset = 1;
      wait_ce(64);
      check(x1 === 1'b0 && x2 === 1'b0, "reset: the x lines did not clear");
      check(y1 === 1'b0 && y2 === 1'b0, "reset: the y lines did not clear");
      reset = 0;
      wait_ce(64);
      clear_stats;
      wait_ce(100 * CE_MS);
      check(xn == 0, "reset: x kept emitting counts after reset");
      check(yn == 0, "reset: y kept emitting counts after reset");

      // ---- button ---------------------------------------------------------------
      // Not a MOUSE_PLAN row; it guards the one output the fix must not touch.
      $display("button: press and release");
      do_reset;
      @(posedge clk); #1;
      ps2_mouse[2:0] = 3'b001;
      ps2_mouse[24]  = ~ps2_mouse[24];
      wait_ce(16);
      check(button === 1'b0, "button: a press did not pull the line low");
      @(posedge clk); #1;
      ps2_mouse[2:0] = 3'b000;
      ps2_mouse[24]  = ~ps2_mouse[24];
      wait_ce(16);
      check(button === 1'b1, "button: a release did not let the line go high");

      $display("");
      if (fails == 0) $display("PS2-MOUSE: PASS %0d/%0d", tests, tests);
      else            $display("PS2-MOUSE: FAIL %0d of %0d", fails, tests);
      $finish;
   end

endmodule
