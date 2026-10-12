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
// (scripts/tsm_pal_model.py). The SE is assumed to keep the grid with one
// display slot in four. `phase` is the 16-clock slot frame both use.
//
// PHASE 1 STUB: holds nothing, which is the core's behaviour today. The bench
// sim/tb_cpu_wait.v must fail against it.
//
module cpu_wait(
	input        clk,
	input        clk8_en_p,     // CPU phi1, once per 8 MHz clock
	input        authentic,     // 8 MHz authentic timing; 0 under turbo
	input        machineType,   // 0 = Plus/512K/128K, 1 = SE
	input        display,       // video owns its RAM slots now
	input        _cpuAS,
	input        selectRAM,
	input        selectROM,
	input        selectSCSI,
	input        selectIWM,
	input        selectSCC,
	output [3:0] phase,         // C8M clock within the 16-clock slot frame
	output       hold           // 1 = withhold DTACK
);

	reg [3:0] ph = 4'd0;
	always @(posedge clk) if (clk8_en_p) ph <= ph + 4'd1;
	assign phase = ph;

	assign hold = 1'b0;

endmodule
