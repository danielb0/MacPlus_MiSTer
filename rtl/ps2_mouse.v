`timescale 1ns / 100ps

/*
 * PS2 mouse protocol
 * Bit       7    6    5    4    3    2    1    0
 * Byte 0: YOVR XOVR YSGN XSGN   1   MBUT RBUT LBUT
 * Byte 1:                 XMOVE
 * Byte 2:                 YMOVE
 */

/*
 * PS2 Mouse to Mac interface module
 *
 * Main sends a report every 15ms or more carrying the raw host delta, which
 * is 400..1600 counts per inch; the Plus mouse is 90. Dividing is therefore
 * not optional, and neither is the rate ceiling that keeps a fast hand from
 * burying the ROM in SCC interrupts. See MOUSE_PLAN.md and
 * sim/tb_ps2_mouse.v.
 */
module ps2_mouse
(
	input	clk,
	input	ce,

	input	reset,

	input [24:0] ps2_mouse,

	/* MOUSE_PLAN.md: host counts consumed per Plus count. */
	input  [4:0] div,

	output x1,
	output y1,
	output x2,
	output y2,
	output reg button
);

/* A divisor of zero would never let a count through. */
wire [4:0] divq = (div == 0) ? 5'd1 : div;

/* One count costs 1024 fine ticks at a rate of one host unit per tick. */
wire [16:0] thresh = { 2'd0, divq, 10'd0 };

/* Backlog cap, in host units: two intervals' worth at the ceiling. */
wire signed [13:0] poslim = $signed({ 3'd0, divq, 6'd0 });

wire strobe = (old_stb != ps2_mouse[24]);
reg  old_stb = 0;
always @(posedge clk) old_stb <= ps2_mouse[24];

/* Capture button state */
always@(posedge clk or posedge reset)
	if (reset) button <= 1;
	else if (strobe) button <= ~(|ps2_mouse[2:0]);

/* Fine tick: one per 128 ce (15.75us), so 1024 to a nominal report */
reg [6:0] finediv;
always@(posedge clk or posedge reset)
	if (reset) finediv <= 0;
	else if (ce) finediv <= finediv + 1'b1;

wire fine = ce && (finediv == 0);

ps2_mouse_axis xaxis
(
	.clk(clk), .ce(ce), .reset(reset), .fine(fine), .strobe(strobe),
	.delta({ ps2_mouse[4], ps2_mouse[4], ps2_mouse[15:8] }),
	.divq(divq), .thresh(thresh), .poslim(poslim),
	.q1(x1), .q2(x2)
);

ps2_mouse_axis yaxis
(
	.clk(clk), .ce(ce), .reset(reset), .fine(fine), .strobe(strobe),
	.delta({ ps2_mouse[5], ps2_mouse[5], ps2_mouse[23:16] }),
	.divq(divq), .thresh(thresh), .poslim(poslim),
	.q1(y1), .q2(y2)
);

endmodule

/*
 * One axis: host units in, quadrature out.
 *
 * budget is the signed backlog in host units, saturated so a flick cannot
 * queue more than the ceiling can drain in two intervals. rate is |budget|
 * latched at the report: holding it fixed is what makes the spacing linear,
 * because a DDA clocked by the live backlog would slow down as it drained
 * and stretch one report's counts over several intervals.
 *
 * phase advances by rate on each fine tick and one count leaves every
 * 1024*div of it. The count is only emitted if the backlog still holds div
 * units, so a remainder smaller than div waits for more motion rather than
 * dribbling out after the hand stops - and because phase is held, not
 * accrued, while the backlog is short, it cannot bank credit for a count
 * nothing paid for.
 *
 * The 4096-ce ceiling gates the emit. phase is clamped at the threshold
 * while it waits, so a blocked axis releases one count per slot instead of
 * a burst.
 */
module ps2_mouse_axis
(
	input                clk,
	input                ce,
	input                reset,
	input                fine,
	input                strobe,
	input  signed  [9:0] delta,
	input          [4:0] divq,
	input         [16:0] thresh,
	input  signed [13:0] poslim,
	output reg           q1,
	output reg           q2
);

reg  signed [12:0] budget;
reg         [11:0] rate;
reg         [16:0] phase;
reg         [12:0] gap;

wire [12:0] mag  = budget[12] ? -budget : budget;
wire        can  = (mag >= { 8'd0, divq });	// the backlog can pay for a count
wire [16:0] sum  = phase + { 5'd0, rate };
wire        due  = (sum >= thresh);
wire        okce = (gap >= 13'd4096);
wire        emit = fine && can && due && okce;

/* One emit walks the backlog one div toward zero; a report adds to it. */
wire signed [13:0] step = emit ? (budget[12] ?  $signed({ 9'd0, divq })
                                             : -$signed({ 9'd0, divq })) : 14'sd0;
wire signed [13:0] add  = strobe ? {{4{delta[9]}}, delta} : 14'sd0;
wire signed [13:0] next = { budget[12], budget } + step + add;
wire signed [13:0] sat  = (next >  poslim) ?  poslim :
                          (next < -poslim) ? -poslim : next;
wire signed [13:0] satmag = sat[13] ? -sat : sat;

always@(posedge clk or posedge reset)
	if (reset) budget <= 0;
	else if (strobe || emit) budget <= sat[12:0];

always@(posedge clk or posedge reset)
	if (reset) rate <= 0;
	else if (strobe) rate <= satmag[11:0];

always@(posedge clk or posedge reset)
	if (reset) phase <= 0;
	else if (fine && can) begin
		if (emit)     phase <= sum - thresh;	// keep the remainder, spacing stays true
		else if (due) phase <= thresh;		// a count is due, the ceiling is holding it
		else          phase <= sum;
	end

always@(posedge clk or posedge reset)
	if (reset) gap <= 13'd4096;			// first count of a gesture is not delayed
	else if (emit) gap <= 0;
	else if (ce && !okce) gap <= gap + 1'b1;

/* Quadrature, in the sense the SCC and VIA already expect */
always@(posedge clk or posedge reset)
	if (reset) begin
		q1 <= 0;
		q2 <= 0;
	end else if (emit) begin
		q1 <= ~q1;
		q2 <= ~q1 ^ ~budget[12];
	end

endmodule
