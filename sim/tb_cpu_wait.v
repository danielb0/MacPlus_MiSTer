`timescale 1ns/1ps
//
// CPU_TIMING_PLAN.md Phase 1: the real fx68k against rtl/cpu_wait.v.
//
// Every bus cycle's wait states are checked against the Plus TSM table from
// Phase 0 (scripts/tsm_pal_model.py), with phi = cpu_wait's phase during S0:
//
//   ROM, IWM, SCSI, RAM in blanking   waits = (1 - phi) mod 4
//   RAM during display (Plus)         waits = (5 - phi) mod 8
//   SCC                               waits = 1 + (4 - phi) mod 8
//   RAM during display (SE, assumed)  next grid point (1 mod 4) that is not
//                                     the video slot (1 mod 16)
//
// and loop periods are checked against hand timing of the 68000 code:
//
//   nop/nop/dbra   18 clocks bare; 20 on the grid; 32 from RAM in display
//   PoP fill loop  30 clocks bare; 32 on the grid; 56 from RAM in display
//                  (MDRV 11 $28d2: move.b (a2)+,(a3) / lea 2(a3),a3 / dbra)
//
// Under turbo (authentic = 0) nothing may wait.
//
// Run (fx68k needs an iverilog-compatible copy, and its ROMs from the cwd):
//   python sim/fx68k_iverilog.py
//   iverilog -g2012 -o sim/out/tb_cpu_wait.vvp sim/tb_cpu_wait.v rtl/cpu_wait.v
//     sim/out/fx68k_sim.sv rtl/fx68k/fx68kAlu.sv rtl/fx68k/uaddrPla.sv
//   cd rtl/fx68k && vvp ../../sim/out/tb_cpu_wait.vvp
module tb_cpu_wait;

	reg clk = 0;
	always #5 clk = ~clk;

	// the core's clock enables (addrController_top.v): phi1 at busPhase 3
	reg [1:0] busPhase = 0;
	always @(posedge clk) busPhase <= busPhase + 2'd1;
	wire enPhi1 = busPhase == 2'b11;
	wire enPhi2 = busPhase == 2'b01;

	reg         reset = 1;
	reg         display = 0, machineType = 0, authentic = 1;
	wire        ASn, UDSn, LDSn, RWn, FC0, FC1, FC2;
	wire [23:1] A;
	wire [15:0] dout;
	wire [23:0] addr = {A, 1'b0};

	// memory: RAM $000000 (128 KB, mirrored), ROM $400000 (64 KB)
	reg  [15:0] ram [0:65535];
	reg  [15:0] rom [0:32767];
	wire        isRAM  = addr[23:22] == 2'b00;
	wire        isROM  = addr[23:20] == 4'h4 && addr[19:16] != 4'h8 && !(addr[19] && addr[18:16] == 3'b000);
	wire        isSCSI = addr[23:19] == 5'b0101_1;
	wire        isSCC  = addr[23:22] == 2'b10;
	wire        isIWM  = addr[23:20] == 4'hD;
	wire [15:0] din = isRAM ? ram[addr[16:1]] : isROM ? rom[addr[15:1]] : 16'h0000;

	always @(posedge clk)
		if (!ASn && !RWn && isRAM) begin
			if (!UDSn) ram[addr[16:1]][15:8] <= dout[15:8];
			if (!LDSn) ram[addr[16:1]][7:0]  <= dout[7:0];
		end

	wire [3:0] phase;
	wire       hold;
	cpu_wait dut (
		.clk(clk), .clk8_en_p(enPhi1), .authentic(authentic),
		.machineType(machineType), .display(display), ._cpuAS(ASn),
		.selectRAM(!ASn && isRAM), .selectROM(!ASn && isROM),
		.selectSCSI(!ASn && isSCSI), .selectIWM(!ASn && isIWM),
		.selectSCC(!ASn && isSCC),
		.phase(phase), .hold(hold));

	fx68k cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(enPhi1), .enPhi2(enPhi2),
		.eRWn(RWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(ASn | hold), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1),
		.BGACKn(1'b1), .IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
		.iEdb(din), .oEdb(dout), .eab(A));

	// ---- per-cycle measurement --------------------------------------------
	// phi = cpu_wait's phase during S0. fx68k drops AS on the phi1 edge that
	// leaves S0, the same edge that advances `phase`, so phi = phase - 1 then.
	// Waits = phi1 edges spent in S4 beyond the first.
	integer clk8 = 0;
	always @(posedge clk) if (enPhi1) clk8 <= clk8 + 1;

	reg [3:0]  phi;
	reg [23:0] cyc_addr;
	integer    s4, waits, want_w;
	integer    n_cycles, n_bad, n_bad_total = 0, n_checked_total = 0;
	reg        measuring = 0;
	reg [8*8:1] kind;

	function integer mod(input integer a, input integer m);
		mod = ((a % m) + m) % m;
	endfunction

	function integer expected(input [23:0] a, input [3:0] p);
		integer g;
		begin
			if (!authentic)
				expected = 0;
			else if (a[23:22] == 2'b10)                       // SCC
				expected = 1 + mod(4 - p, 8);
			else if (a[23:22] == 2'b00 && display && !machineType)
				expected = mod(5 - p, 8);
			else if (a[23:22] == 2'b00 && display && machineType) begin
				g = mod(1 - p, 4);                             // next grid point
				if (mod(p + g, 16) == 1) g = g + 4;            // video's slot
				expected = g;
			end
			else
				expected = mod(1 - p, 4);
		end
	endfunction

	always @(negedge ASn) begin
		#1;
		phi      = phase - 4'd1;
		cyc_addr = addr;
		s4       = 0;
	end

	always @(posedge clk)
		if (enPhi1 && !ASn && cpu.busControl.busPhase == cpu.busControl.S4)
			s4 <= s4 + 1;

	// loop-period tracking: instruction fetches of the loop's first opcode
	reg [23:0] loop_pc;
	integer    last_fetch, period, period_min, period_max, n_periods;

	always @(posedge ASn) if (measuring) begin
		waits  = s4 - 1;
		want_w = expected(cyc_addr, phi);
		n_cycles = n_cycles + 1;
		if (waits != want_w) begin
			if (n_bad < 4)
				$display("    MISMATCH addr %06h phi %0d: waits %0d, table says %0d",
				         cyc_addr, phi, waits, want_w);
			n_bad = n_bad + 1;
		end
	end

	always @(negedge ASn) if (measuring) begin
		#2;
		if (addr == loop_pc && {FC2, FC1, FC0} == 3'b110) begin
			if (last_fetch >= 0) begin
				period = clk8 - last_fetch;
				if (n_periods > 2) begin       // skip the loop entry
					if (period < period_min) period_min = period;
					if (period > period_max) period_max = period;
				end
				n_periods = n_periods + 1;
			end
			last_fetch = clk8;
		end
	end

	// ---- scenarios ----------------------------------------------------------
	task load_programs;
		integer i;
		begin
			for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h4E71;
			for (i = 0; i < 32768; i = i + 1) rom[i] = 16'h4E71;
			ram[0] = 16'h0000; ram[1] = 16'h8000;              // SSP
			// $0100 / $400100: nop / nop / dbra
			ram['h80] = 16'h3C3C; ram['h81] = 16'h7FFF; ram['h82] = 16'h4E71;
			ram['h83] = 16'h4E71; ram['h84] = 16'h51CE; ram['h85] = 16'hFFFA;
			for (i = 0; i < 6; i = i + 1) rom['h80 + i] = ram['h80 + i];
			// $0200: the PoP fill loop
			ram['h100] = 16'h247C; ram['h101] = 16'h0000; ram['h102] = 16'h2000;
			ram['h103] = 16'h267C; ram['h104] = 16'h0000; ram['h105] = 16'h3000;
			ram['h106] = 16'h3C3C; ram['h107] = 16'h0FFF; ram['h108] = 16'h169A;
			ram['h109] = 16'h47EB; ram['h10A] = 16'h0002; ram['h10B] = 16'h51CE;
			ram['h10C] = 16'hFFF8; ram['h10D] = 16'h60FE;
			// $0300 / $400300: mixed internal delays, SCC and IWM reads
			ram['h180] = 16'h247C; ram['h181] = 16'h0000; ram['h182] = 16'h2000;
			ram['h183] = 16'h3C3C; ram['h184] = 16'h7FFF; ram['h185] = 16'hE388;
			ram['h186] = 16'h3012; ram['h187] = 16'hE588; ram['h188] = 16'hC141;
			ram['h189] = 16'h1239; ram['h18A] = 16'h009F; ram['h18B] = 16'hFFF8;
			ram['h18C] = 16'hE388; ram['h18D] = 16'h1239; ram['h18E] = 16'h00DF;
			ram['h18F] = 16'hE1FF; ram['h190] = 16'h4E71; ram['h191] = 16'h3012;
			ram['h192] = 16'h51CE; ram['h193] = 16'hFFE4;
			for (i = 0; i < 20; i = i + 1) rom['h180 + i] = ram['h180 + i];
		end
	endtask

	task run(input [8*24:1] name, input [23:0] start, input [23:0] lpc,
	         input d, input mt, input au, input integer want_period);
		begin
			load_programs;
			ram[2] = start[23:16]; ram[3] = start[15:0];
			display = d; machineType = mt; authentic = au;
			reset = 1; repeat (40) @(posedge clk); #1 reset = 0;
			repeat (4000) @(posedge clk);                   // reset, vectors, setup
			loop_pc = lpc; last_fetch = -1; n_periods = 0;
			period_min = 1 << 30; period_max = 0;
			n_cycles = 0; n_bad = 0; measuring = 1;
			repeat (24000) @(posedge clk);
			measuring = 0;
			n_bad_total = n_bad_total + n_bad;
			n_checked_total = n_checked_total + n_cycles;
			if (want_period > 0 && (period_min != want_period || period_max != want_period)) begin
				$display("  FAIL %0s: loop period %0d..%0d clocks, want %0d (%0d cycles, %0d wrong waits)",
				         name, period_min, period_max, want_period, n_cycles, n_bad);
				n_bad_total = n_bad_total + 1;
			end else
				$display("  %0s %0s: loop period %0d clocks, %0d cycles, %0d wrong waits",
				         n_bad ? "FAIL" : "ok  ", name, period_min, n_cycles, n_bad);
		end
	endtask

	initial begin
		$display("tb_cpu_wait: Plus TSM wait states on the real fx68k");
		//    name                       start      loop pc    disp SE auth period
		run("nop loop, RAM, blank",    24'h000100, 24'h000104, 0, 0, 1, 20);
		run("nop loop, RAM, display",  24'h000100, 24'h000104, 1, 0, 1, 32);
		run("nop loop, ROM, blank",    24'h400100, 24'h400104, 0, 0, 1, 20);
		run("nop loop, ROM, display",  24'h400100, 24'h400104, 1, 0, 1, 20);
		run("PoP fill, RAM, blank",    24'h000200, 24'h000210, 0, 0, 1, 32);
		run("PoP fill, RAM, display",  24'h000200, 24'h000210, 1, 0, 1, 56);
		run("mixed, RAM, blank",       24'h000300, 24'h00030A, 0, 0, 1, 0);
		run("mixed, RAM, display",     24'h000300, 24'h00030A, 1, 0, 1, 0);
		run("mixed, ROM, blank",       24'h400300, 24'h40030A, 0, 0, 1, 0);
		run("mixed, ROM, display",     24'h400300, 24'h40030A, 1, 0, 1, 0);
		run("SE: mixed, RAM, display", 24'h000300, 24'h00030A, 1, 1, 1, 0);
		run("SE: PoP fill, display",   24'h000200, 24'h000210, 1, 1, 1, 0);
		run("turbo: PoP fill, display",24'h000200, 24'h000210, 1, 0, 0, 30);
		if (n_bad_total == 0)
			$display("PASS: %0d bus cycles checked", n_checked_total);
		else
			$display("FAIL: %0d failures in %0d bus cycles", n_bad_total, n_checked_total);
		$finish;
	end

endmodule
