`timescale 1ns/1ps
//
// tb_drive_tach.v - Sad Mac 0F0004: the spindle must answer the Mac.
//
// Compile: iverilog -g2012 -I rtl -y rtl -o out.vvp sim/tb_drive_tach.v
//
// The 64K ROM calibrates floppy speed by measuring the tachometer, CHANGING
// the spindle PWM, and measuring again -- then dividing by the DIFFERENCE
// between the two measurements. A drive that ignores the PWM returns the same
// measurement twice, the divisor is zero, and the ROM takes a divide-by-zero
// exception. That is Sad Mac 0F0004, and it is exactly what this core did:
// the tach period depended only on the track.
//
// So the property under test is not "the period is correct" -- the old code
// passed that and still hung the machine. It is "the ROM's SUBTRACTION IS
// NON-ZERO", which is a statement about two measurements at two different
// PWM values. Every check below is written as a pair for that reason.
//
// This bench measures real toggle periods by counting clocks between TACH
// edges through the drive-register read port, rather than inspecting internal
// signals, so it fails if the PWM is accepted but never reaches the counter.
//
module tb_drive_tach;

	localparam [3:0] REG_TACH = 4'd7; // {ca2,ca1,ca0,SEL} = 0111

	reg clk = 0;
	always #5 clk = ~clk;

	// The drive's counters only leave X through the reset branch, so the
	// bench must actually assert it -- without this the tach never toggles
	// and every measurement below would spin forever rather than fail.
	reg rst_n = 1'b0;

	reg  [7:0] pwm;
	wire [7:0] rd400, rd800;

	floppy dut400 (
		.clk(clk), .cep(1'b1), .cen(1'b1), ._reset(rst_n),
		.ca2(1'b0), .ca1(1'b1), .ca0(1'b1), .SEL(1'b1),
		.lstrb(1'b1), ._enable(1'b0), .writeData(8'h00), .readData(rd400),
		.advanceDriveHead(1'b0), .insertDisk(1'b0), .diskSides(1'b0),
		.drive800k(1'b0), .disk_pwm(pwm),
		.dskReadAck(1'b0), .dskReadData(8'h00),
		.writeReq(1'b0), .writeProtect(1'b0)
	);

	floppy dut800 (
		.clk(clk), .cep(1'b1), .cen(1'b1), ._reset(rst_n),
		.ca2(1'b0), .ca1(1'b1), .ca0(1'b1), .SEL(1'b1),
		.lstrb(1'b1), ._enable(1'b0), .writeData(8'h00), .readData(rd800),
		.advanceDriveHead(1'b0), .insertDisk(1'b0), .diskSides(1'b0),
		.drive800k(1'b1), .disk_pwm(pwm),
		.dskReadAck(1'b0), .dskReadData(8'h00),
		.writeReq(1'b0), .writeProtect(1'b0)
	);

	integer tests = 0, fails = 0;
	task ok;
		input [8*76:1] name;
		input          cond;
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	// Count clocks between two rising edges of a drive's TACH bit, the way
	// the ROM counts them: through the register read port, not by peeking
	// at an internal signal. If the PWM were accepted at the port but
	// never reached the counter, this would still fail.
	task measure400; output integer period;
		integer n; reg prev; reg done;
		begin
			prev = rd400[7]; done = 0;
			while (!done) begin
				@(posedge clk); #1;
				if (rd400[7] === 1'b1 && prev === 1'b0) done = 1;
				prev = rd400[7];
			end
			n = 0; done = 0;
			while (!done) begin
				@(posedge clk); #1; n = n + 1;
				if (rd400[7] === 1'b1 && prev === 1'b0) done = 1;
				prev = rd400[7];
			end
			period = n;
		end
	endtask

	task measure800; output integer period;
		integer n; reg prev; reg done;
		begin
			prev = rd800[7]; done = 0;
			while (!done) begin
				@(posedge clk); #1;
				if (rd800[7] === 1'b1 && prev === 1'b0) done = 1;
				prev = rd800[7];
			end
			n = 0; done = 0;
			while (!done) begin
				@(posedge clk); #1; n = n + 1;
				if (rd800[7] === 1'b1 && prev === 1'b0) done = 1;
				prev = rd800[7];
			end
			period = n;
		end
	endtask

	integer m_lo, m_hi, m8_lo, m8_hi;
	integer m_trk0, m_trk40, m8_trk0, m8_trk40, m_slow, m_fast;

	initial begin
		$display("");
		rst_n = 1'b0; pwm = 8'd128;
		repeat (4) @(posedge clk);
		rst_n = 1'b1;
		@(posedge clk); #1;

		$display("=== spindle PWM: the 400K drive must answer, the 800K must not ===");
		$display("");

		// ---- THE BUG: two PWMs must give two different measurements --------
		pwm = 8'd96;  measure400(m_lo);
		pwm = 8'd160; measure400(m_hi);
		$display("  400K drive: pwm=96 -> %0d clks, pwm=160 -> %0d clks", m_lo, m_hi);
		ok("400K: two PWM values give DIFFERENT tach periods (divisor != 0)",
		   m_lo != m_hi);
		ok("400K: higher PWM spins faster, i.e. shorter period (monotonic)",
		   m_hi < m_lo);

		// ---- the 800K drive must keep ignoring it -------------------------
		// Not symmetry for its own sake: self-regulation is what a real 800K
		// mechanism does, and it is the behaviour already proven on hardware
		// for the Plus and SE. A fix that made them obey the PWM would be a
		// regression dressed up as a feature.
		pwm = 8'd96;  measure800(m8_lo);
		pwm = 8'd160; measure800(m8_hi);
		$display("  800K drive: pwm=96 -> %0d clks, pwm=160 -> %0d clks", m8_lo, m8_hi);
		ok("800K: self-regulating, PWM has NO effect (Plus/SE unregressed)",
		   m8_lo == m8_hi);

		// ---- range: the ROM needs room either side to converge ------------
		ok("400K: adjustment range is meaningful, not a rounding artefact",
		   (m_lo - m_hi) > 100);

		// ---- THE SECOND BUG: speed must NOT depend on the track -----------
		// A real 400K drive has no idea where the head is; the Mac gets each
		// zone's speed by writing a different PWM. Making the period depend on
		// BOTH applied every zone change twice, so the ROM measured a speed
		// its own calibration did not predict. That read fine through zone 0
		// (tracks 0-15: boot blocks, MFS directory, the first of the System
		// file) and failed at the first step into track 16 -- a happy Mac,
		// then the flashing '?'.
		pwm = 8'd128;
		force dut400.driveTrack = 7'd0;  measure400(m_trk0);
		force dut400.driveTrack = 7'd40; measure400(m_trk40);
		release dut400.driveTrack;
		$display("  400K drive: track 0 -> %0d clks, track 40 -> %0d clks", m_trk0, m_trk40);
		ok("400K: period is INDEPENDENT of track (PWM alone owns the speed)",
		   m_trk0 == m_trk40);

		// The 800K drive is the opposite and must stay that way: it regulates
		// itself to the correct CLV zone speed with no help from the Mac.
		force dut800.driveTrack = 7'd0;  measure800(m8_trk0);
		force dut800.driveTrack = 7'd40; measure800(m8_trk40);
		release dut800.driveTrack;
		$display("  800K drive: track 0 -> %0d clks, track 40 -> %0d clks", m8_trk0, m8_trk40);
		ok("800K: still self-regulates PER ZONE (Plus/SE unregressed)",
		   m8_trk0 != m8_trk40);

		// ---- the map must cover every zone the ROM will ask for -----------
		// If a zone's target period were unreachable at any PWM, the ROM's
		// loop could not converge there and the read would fail on exactly
		// those tracks. Half-periods 9996 (500 RPM) and 6634 (750 RPM) are
		// the extremes of floppy.v's own CLV table; measured full periods are
		// twice those.
		// Probe the extremes, not a guessed midpoint: the question is whether
		// the map SPANS the table, and only pwm 0 and 255 answer that.
		pwm = 8'd0;   measure400(m_slow);
		pwm = 8'd255; measure400(m_fast);
		$display("  400K reachable span: %0d .. %0d clks (must span %0d .. %0d)",
		         m_fast, m_slow, 2*6634, 2*9996);
		ok("400K: slowest CLV zone (500 RPM) is reachable", m_slow >= 2*9996);
		ok("400K: fastest CLV zone (750 RPM) is reachable", m_fast <= 2*6634);

		// Headroom, not just coverage: if a zone's target sat hard against a
		// rail the ROM's loop could reach it only by saturating, with nothing
		// left to correct with. Both ends must land inside the PWM range with
		// room to spare.
		ok("400K: slow end has PWM headroom below it",  m_slow  >= 2*9996 + 400);
		ok("400K: fast end has PWM headroom above it",  m_fast  <= 2*6634 - 400);

		$display("");
		$display("DRIVE-TACH: %0d of %0d failing", fails, tests);
		if (fails) $fatal(1, "tb_drive_tach FAILED");
		$display("0F0004 GATE: PASS - the spindle answers the Mac");
		$finish;
	end

endmodule
