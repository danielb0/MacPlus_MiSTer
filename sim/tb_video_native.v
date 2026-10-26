// tb_video_native: the Plus's own raster, as NATIVE_VIDEO_PLAN.md specifies it.
//
// videoTimer + videoShifter, clocked the way addrController_top.v clocks them
// (busPhase/busCycle, memoryLatch on phase 3), clk_sys at 31.3344 MHz and one
// pixel every other clock (pix_en = clk16_en_p = CE_PIXEL). Measured in pixel
// clocks, p = 0 at the first DE pixel of a line:
//
//   line      704 px, DE p 0-511, HSYNC* low p 535 for 288 px
//   frame     370 lines; VSYNC* low 4 lines from p 704 of the last DE line;
//             28 blank lines, then 342 DE lines
//   VBL       _vblank falls with VSYNC* (within one clk8) and stays low 28 lines
//   PB6       _hblank high 256 clk8 (512 px) of every line
//   fetch     loads only on busCycle 0, 32 per DE line, none elsewhere
//   pixels    DE line r, pixel k = bit 15 - k%16 of the word at
//             $3FA700 + 64r + 2(k/16); each screen word carries its row and
//             column, so a wrong address, width or offset shows as a mismatch
//
// Rates follow: 1408 clk per line = 22.2545 kHz, 520,960 per frame = 60.147 Hz.
//
// Run: iverilog -g2012 -o sim/out/tb_video_native.vvp sim/tb_video_native.v rtl/videoTimer.v rtl/videoShifter.v
//      vvp sim/out/tb_video_native.vvp
// Against the pre-native modules (no pix_en/de ports): add -DOLD_TIMER.
`timescale 1ns/1ps
module tb_video_native;

	localparam LINE_PX   = 704;
	localparam DE_PX     = 512;
	localparam HS_START  = 535;
	localparam HS_PX     = 288;
	localparam LINES     = 370;
	localparam DE_LINES  = 342;
	localparam BLANK_LNS = 28;
	localparam VS_LINES  = 4;
	localparam HBLANK_HI = 256 * 4;		// clk per line with _hblank high
	localparam LOADS     = 32;
	localparam [21:0] SCREEN = 22'h3FA700;

	reg clk = 0;
	always #15.957 clk = ~clk;	// 31.3344 MHz

	reg [1:0] busPhase = 0;
	reg [1:0] busCycle = 0;
	always @(posedge clk) begin
		busPhase <= busPhase + 1'd1;
		if (busPhase == 2'b11) busCycle <= busCycle + 2'd1;
	end
	wire memoryLatch = busPhase == 2'd3;
	wire clk8_en_p   = busPhase == 2'b11;

	// screen word at an address: {1, column, row, 0}; anything off-screen a marker
	function [15:0] word_at(input [21:0] a);
		reg [21:0] off;
		begin
			off = a - SCREEN;
			if (a >= SCREEN && off < DE_LINES * 64)
				word_at = {1'b1, off[5:1], off[14:6], 1'b0};
			else
				word_at = 16'h5A5A;
		end
	endfunction
	function [15:0] word_rc(input integer r, input integer c);
		word_rc = word_at(SCREEN + r * 64 + c * 2);
	endfunction

	wire [21:0] videoAddr;
	wire hsync, vsync, _hblank, _vblank, loadPixels, de, pixelOut, ce;
`ifdef OLD_TIMER
	assign ce = 1'b1;
	videoTimer vt(
		.clk(clk), .clk_en(clk8_en_p), .busCycle(busCycle), .vid_alt(1'b1),
		.videoAddr(videoAddr), .hsync(hsync), .vsync(vsync),
		._hblank(_hblank), ._vblank(_vblank), .loadPixels(loadPixels));
	assign de = _vblank & _hblank;
	videoShifter vs(
		.clk32(clk), .memoryLatch(memoryLatch), .dataIn(word_at(videoAddr)),
		.loadPixels(loadPixels), .pixelOut(pixelOut));
`else
	assign ce = !busPhase[0];		// clk16_en_p
	videoTimer vt(
		.clk(clk), .clk_en(clk8_en_p), .pix_en(ce), .busCycle(busCycle), .vid_alt(1'b1),
		.videoAddr(videoAddr), .hsync(hsync), .vsync(vsync),
		._hblank(_hblank), ._vblank(_vblank), .de(de), .loadPixels(loadPixels));
	videoShifter vs(
		.clk32(clk), .pix_en(ce), .memoryLatch(memoryLatch), .dataIn(word_at(videoAddr)),
		.loadPixels(loadPixels), .pixelOut(pixelOut));
`endif

	// failure counters, one per check
	integer e_line = 0, e_frame = 0, e_de_w = 0, e_de_pitch = 0, e_de_lines = 0;
	integer e_hs_pos = 0, e_hs_w = 0, e_vs_pos = 0, e_vs_w = 0, e_top = 0;
	integer e_vbl_pos = 0, e_vbl_w = 0, e_hblank = 0;
	integer e_slot = 0, e_loads = 0, e_pix = 0;
	integer first_line = -1, first_de_w = -1, first_hs_pos = -1;

	// state; n counts pixel clocks (ce samples), t counts clk
	integer n = 0, t = 0, frames = 0;
	reg de_q = 0, hs_q = 1, vs_q = 1, vbl_q = 1, hb_q = 0;
	integer de_rise = -1, de_fall = -1, hs_fall = -1, vs_fall = -1, vs_fall_t = -1;
	integer vbl_fall_t = -1, hb_rise_t = -1;
	integer row = 0, de_lines = 0, loads = 0, first_de_after_vs = 0;
	reg checking = 0;			// set at the first VSYNC* fall: frame 1 may be partial
	reg [15:0] w;

	// Sample at negedge: the registered outputs a CE posedge would hand the
	// scaler are already stable, and ce/memoryLatch describe that posedge.
	always @(negedge clk) begin
		t = t + 1;

		// _vblank and _hblank move on clk8, so they are timed in clk
		if (vbl_q && !_vblank) vbl_fall_t = t;
		if (!vbl_q && _vblank && checking && vbl_fall_t >= 0)
			if (t - vbl_fall_t > BLANK_LNS * 1408 + 8 || t - vbl_fall_t < BLANK_LNS * 1408 - 8)
				e_vbl_w = e_vbl_w + 1;
		vbl_q = _vblank;
		if (!hb_q && _hblank) hb_rise_t = t;
		if (hb_q && !_hblank && checking && hb_rise_t >= 0 && t - hb_rise_t != HBLANK_HI)
			e_hblank = e_hblank + 1;
		hb_q = _hblank;

		// fetches: on video slots only, counted per DE line
		if (loadPixels && memoryLatch) begin
			if (busCycle != 2'd0) e_slot = e_slot + 1;
			loads = loads + 1;
		end

		if (ce) begin
			n = n + 1;

			// DE
			if (de && !de_q) begin
				if (checking && de_rise >= 0 && de_lines > 0 && n - de_rise != LINE_PX)
					e_de_pitch = e_de_pitch + 1;
				if (checking && de_lines == 0 && vs_fall >= 0 && n - vs_fall != BLANK_LNS * LINE_PX)
					e_top = e_top + 1;
				de_rise = n;
			end
			if (!de && de_q) begin
				if (checking && n - de_rise != DE_PX) begin
					e_de_w = e_de_w + 1;
					if (first_de_w < 0) first_de_w = n - de_rise;
				end
				de_fall = n;
				de_lines = de_lines + 1;
			end
			if (de) begin
				w = word_rc(de_lines, (n - de_rise) >> 4);
				if (checking && (n - de_rise) < DE_PX && pixelOut !== ~w[15 - ((n - de_rise) & 15)])
					e_pix = e_pix + 1;	// a 1 bit is black
			end
			de_q = de;

			// HSYNC*
			if (hs_q && !hsync) begin
				if (checking && hs_fall >= 0 && n - hs_fall != LINE_PX) begin
					e_line = e_line + 1;
					if (first_line < 0) first_line = n - hs_fall;
				end
				// position, on lines that had DE
				if (checking && de_rise >= 0 && n - de_rise < LINE_PX && n - de_rise != HS_START) begin
					e_hs_pos = e_hs_pos + 1;
					if (first_hs_pos < 0) first_hs_pos = n - de_rise;
				end
				// fetches since the last sync (word 0 is fetched before DE
				// rises): 32 on a line that had DE, none on a blank line
				if (checking && hs_fall >= 0 && loads != (de_fall > hs_fall ? LOADS : 0))
					e_loads = e_loads + 1;
				loads = 0;
				hs_fall = n;
			end
			if (!hs_q && hsync && checking && hs_fall >= 0 && n - hs_fall != HS_PX)
				e_hs_w = e_hs_w + 1;
			hs_q = hsync;

			// VSYNC*
			if (vs_q && !vsync) begin
				if (checking) begin
					frames = frames + 1;
					if (n - vs_fall != LINES * LINE_PX) e_frame = e_frame + 1;
					if (de_lines != DE_LINES) e_de_lines = e_de_lines + 1;
					// the frame just ended: its VBL fell with its VSYNC*, within one clk8
					if (vbl_fall_t - vs_fall_t > 4 || vs_fall_t - vbl_fall_t > 4)
						e_vbl_pos = e_vbl_pos + 1;
				end
				if (de_fall >= 0 && n - de_fall != LINE_PX - DE_PX && checking)
					e_vs_pos = e_vs_pos + 1;
				vs_fall = n;
				vs_fall_t = t;
				de_lines = 0;
				checking = 1;
			end
			if (!vs_q && vsync && checking && n - vs_fall != VS_LINES * LINE_PX)
				e_vs_w = e_vs_w + 1;
			vs_q = vsync;
		end

	end

	integer errs;
	initial begin
		vs.shiftRegister = 16'hFFFF;	// FPGA power-up state
`ifdef OLD_TIMER
		vt.xpos = 0; vt.ypos = 0;	// no initial values in the old timer
`endif
		repeat (4 * 806 * 672) @(posedge clk);	// >= 3 frames of either raster
		errs = e_line + e_frame + e_de_w + e_de_pitch + e_de_lines + e_hs_pos + e_hs_w +
		       e_vs_pos + e_vs_w + e_top + e_vbl_pos + e_vbl_w + e_hblank +
		       e_slot + e_loads + e_pix;
		$display("frames checked %0d", frames);
		$display("line period      %0d bad (first %0d px, want %0d)", e_line, first_line, LINE_PX);
		$display("frame period     %0d bad", e_frame);
		$display("DE width         %0d bad (first %0d px, want %0d)", e_de_w, first_de_w, DE_PX);
		$display("DE pitch         %0d bad", e_de_pitch);
		$display("DE lines/frame   %0d bad", e_de_lines);
		$display("blank lines top  %0d bad", e_top);
		$display("HSYNC position   %0d bad (first p %0d, want %0d)", e_hs_pos, first_hs_pos, HS_START);
		$display("HSYNC width      %0d bad", e_hs_w);
		$display("VSYNC position   %0d bad", e_vs_pos);
		$display("VSYNC width      %0d bad", e_vs_w);
		$display("VBL position     %0d bad", e_vbl_pos);
		$display("VBL width        %0d bad", e_vbl_w);
		$display("PB6 hblank       %0d bad", e_hblank);
		$display("fetch slot       %0d bad", e_slot);
		$display("fetches/line     %0d bad", e_loads);
		$display("pixels           %0d bad", e_pix);
		if (frames >= 3 && errs == 0)
			$display("PASS");
		else
			$display("FAIL");
		$finish;
	end

endmodule
