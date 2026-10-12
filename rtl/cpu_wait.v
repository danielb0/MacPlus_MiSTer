//
// cpu_wait.v -- the real machines' CPU wait states (CPU_TIMING_PLAN.md).
//
// The Plus TSM PAL snaps every RAM and ROM bus cycle to a 4-clock grid, and
// during display gives RAM to the CPU only one 4-clock slot in two. With phi
// = the C8M clock (0-7) within the 1 MHz C1M period at which S0 falls:
//
//   ROM, IWM, SCSI, RAM in blanking   waits = (1 - phi) mod 4
//   RAM during display                waits = (5 - phi) mod 8
//   SCC                               waits = 1 + (4 - phi) mod 8
//
// (scripts/tsm_pal_model.py). The SE is ASSUMED to keep the grid with one
// display slot in four; no BBU equations exist. The VIA is VPA/E-clock
// timed, which fx68k already models, so it is not held here.
//
// fx68k samples DTACK on phi2 of S4 and leaves S4 on the next phi1. S0 sits
// at phase phi, so the S4 sample with w waits sees phase phi + 2 + w. Every
// rule above is "waits = (target - phi) mod G", so DTACK reduces to a phase
// window: release only when phase = target + 2.
//
// Contention follows a virtual Mac raster locked to the sound scan, not the
// core's VGA-shaped display: line 0 starts at the VBL (the scan is at word 0
// there on a real Plus), one line per sound word, lines 0-27 blank, and the
// first 256/352 of every later line is display. The last slot of every line
// is the sound/disk-speed fetch.
//
// The core's clk8 is 8.125 MHz against 7.8336, so a frame holds 135,408 clk8
// where a Plus has 130,240 CPU clocks. `cpu_skip` drops the CPU's clock for
// 5,168 of every 135,408 clk8, evenly spread, which restores the real CPU
// clocks per frame, per line and per sound sample. Video, sound and the
// IWM/SCC stay on clk8. The VIA runs from the CPU's E clock and so slows too,
// which is right: a real VIA ticks 13,024 times a frame. Phase, AS age and
// the raster's position within a line all count CPU clocks, not clk8.
//
module cpu_wait(
	input        clk,
	input        clk8_en_p,     // CPU phi1, once per 8 MHz clock
	input        authentic,     // 8 MHz authentic timing; 0 under turbo
	input        machineType,   // 0 = Plus/512K/128K, 1 = SE
	input        _vblank,       // falling edge = VBL = line 0
	input        snd_advance,   // one pulse per sound word = per Mac line
	input        _cpuAS,
	input        selectRAM,
	input        selectROM,
	input        selectSCSI,
	input        selectIWM,
	input        selectSCC,
	output [3:0] phase,         // C8M clock within the 16-clock slot frame
	output       display,       // video owns its RAM slots now
	output       hold,          // 1 = withhold DTACK
	output       cpu_skip       // 1 = this clk8 is not a CPU clock
);

	// Bresenham: 130,240 CPU clocks in each 135,408 clk8. Registered on phi1,
	// so the next clock's phi2 AND phi1 are dropped together and fx68k still
	// sees the two phases alternate.
	localparam [17:0] FRAME_CLK8  = 18'd135408;
	localparam [17:0] SKIPS       = 18'd5168;
	reg  [17:0] skip_acc = 18'd0;
	reg         skip = 1'b0;
	wire [17:0] skip_next = skip_acc + SKIPS;
	always @(posedge clk) if (clk8_en_p) begin
		if (!authentic) begin
			skip <= 1'b0;
		end else if (skip_next >= FRAME_CLK8) begin
			skip_acc <= skip_next - FRAME_CLK8;
			skip     <= 1'b1;
		end else begin
			skip_acc <= skip_next;
			skip     <= 1'b0;
		end
	end
	assign cpu_skip = skip;
	wire cpu_clk = clk8_en_p && !skip;

	// 16-clock slot frame: the Plus uses phase[2:0] as C1M, the SE all four
	reg [3:0] ph = 4'd0;
	always @(posedge clk) if (cpu_clk) ph <= ph + 4'd1;
	assign phase = ph;

	// virtual raster, in CPU clocks: a line is 352 (~366 clk8 less its skips),
	// the first 256 are display, and the sound slot is the last 8.
	localparam [8:0] FIRST_DISPLAY_LINE = 9'd28;
	localparam [8:0] DISPLAY_CLOCKS     = 9'd256;
	localparam [8:0] SOUND_SLOT_CLOCK   = 9'd344;

	reg       vblankD = 1'b1, frame_pending = 1'b0;
	reg [8:0] line = 9'd0, xclk = 9'd0;
	always @(posedge clk) if (clk8_en_p) begin
		vblankD <= _vblank;
		if (vblankD && !_vblank) frame_pending <= 1'b1;
		if (snd_advance) begin
			// the scan's first advance follows the VBL edge by one clock
			line          <= frame_pending ? 9'd0 : line + 9'd1;
			frame_pending <= 1'b0;
			xclk          <= 9'd0;
		end else if (!skip && xclk != 9'h1FF)
			xclk <= xclk + 9'd1;
	end
	assign display = (line >= FIRST_DISPLAY_LINE && xclk < DISPLAY_CLOCKS) ||
	                 xclk >= SOUND_SLOT_CLOCK;

	// clocks since AS fell, to keep the SCC from completing on its first sample
	reg [1:0] as_age = 2'd0;
	always @(posedge clk)
		if (_cpuAS) as_age <= 2'd0;
		else if (cpu_clk && as_age != 2'd3) as_age <= as_age + 2'd1;

	// release windows: phase = target + 2
	wire grid_ok    = ph[1:0] == 2'd3;                       // target 1 mod 4
	wire plus_slot  = ph[2:0] == 3'd7;                       // target 5 mod 8
	wire se_slot    = grid_ok && ph != 4'd3;                 // not video's slot
	wire ram_ok     = !display ? grid_ok : machineType ? se_slot : plus_slot;
	wire scc_ok     = plus_slot && as_age >= 2'd2;

	wire release_ok = selectSCC ? scc_ok :
	                  selectRAM ? ram_ok :
	                  (selectROM | selectIWM | selectSCSI) ? grid_ok : 1'b1;

	assign hold = authentic && !_cpuAS && !release_ok;

endmodule
