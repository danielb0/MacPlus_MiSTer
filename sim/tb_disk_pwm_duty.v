`timescale 1ns/1ps
//
// tb_disk_pwm_duty.v - the Mac's commanded floppy spindle duty.
//
// Compile: iverilog -g2012 -y rtl -o out.vvp sim/tb_disk_pwm_duty.v
//
// The 400KB drive specification derives the commanded duty from the LOW 6 BITS
// of each sound-buffer word by converting each through a 64-entry TABLE,
// summing 100 of them, and taking index = sum/10 - 11 clamped to 0..399.
//
// The table is a PERMUTATION (0, 1, 59, 2, 60, 40, 54, 3, ...), so summing the
// RAW 6-bit values instead -- which this core did -- produces a number with
// essentially no monotonic relationship to what the Mac commanded. On hardware
// the spindle loop then oscillated rail to rail (a JTAG probe caught 252, 5,
// 118, 5 on successive samples) and the machine booted or failed at random.
//
// So the check that matters is not "does it average" but "does it average the
// TABLE VALUES". Several cases below are chosen specifically so that the raw
// and converted answers differ, and would both look plausible in isolation.
//
module tb_disk_pwm_duty;

	reg        clk = 0;
	always #5 clk = ~clk;

	reg        sample_en = 0;
	reg  [5:0] sample = 0;
	wire [8:0] duty_index;

	disk_pwm_duty dut (.clk(clk), .sample_en(sample_en),
	                   .sample(sample), .duty_index(duty_index));

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

	// Push n samples of a constant value.
	task push; input [5:0] v; input integer n; integer k; begin
		for (k = 0; k < n; k = k + 1) begin
			@(negedge clk); sample = v; sample_en = 1;
			@(negedge clk); sample_en = 0;
		end
	end endtask

	// Push one full 100-sample window alternating between two values.
	task push_dither; input [5:0] a; input [5:0] b; integer k; begin
		for (k = 0; k < 100; k = k + 1) begin
			@(negedge clk); sample = (k[0] ? b : a); sample_en = 1;
			@(negedge clk); sample_en = 0;
		end
	end endtask

	initial begin
		$display("");
		$display("=== spindle duty: the 6-bit field goes through a TABLE ===");
		$display("");

		// ---- constant commands, table value t -> index 10t - 11 ------------
		// table[3]=2 -> 9,  table[7]=3 -> 19,  table[15]=4 -> 29,
		// table[63]=6 -> 49
		push(6'd3, 100);  #1;
		ok("constant sample 3  (table 2)  -> index 9",   duty_index == 9'd9);
		push(6'd7, 100);  #1;
		ok("constant sample 7  (table 3)  -> index 19",  duty_index == 9'd19);
		push(6'd15, 100); #1;
		ok("constant sample 15 (table 4)  -> index 29",  duty_index == 9'd29);
		push(6'd63, 100); #1;
		ok("constant sample 63 (table 6)  -> index 49",  duty_index == 9'd49);

		// ---- THE ONE THAT SEPARATES TABLE FROM RAW -------------------------
		// sample 21 converts to 12, giving index 109. Summing the RAW value 21
		// would give index 199. Both are legal-looking indices in range, so a
		// bench that only checked "is it plausible" would pass either.
		push(6'd21, 100); #1;
		$display("  sample 21: table gives 109, raw would give 199; got %0d", duty_index);
		ok("sample 21 uses the TABLE (109), not the raw value (199)",
		   duty_index == 9'd109);

		// sample 9 converts to 32 -> index 309; raw 9 would give index 79.
		push(6'd9, 100); #1;
		ok("sample 9 uses the TABLE (309), not the raw value (79)",
		   duty_index == 9'd309);

		// ---- clamping ------------------------------------------------------
		// table[32] = 63 -> sum 6300 -> index 619, must clamp to 399.
		push(6'd32, 100); #1;
		ok("high end clamps to 399", duty_index == 9'd399);
		// table[0] = 0 -> index -11, and table[1] = 1 -> index -1: both clamp to 0.
		push(6'd0, 100); #1;
		ok("low end clamps to 0 (table 0 -> index -11)", duty_index == 9'd0);
		push(6'd1, 100); #1;
		ok("low end clamps to 0 (table 1 -> index -1)",  duty_index == 9'd0);

		// ---- dither: the whole point of the 100-sample window ---------------
		// 50 of sample 3 (table 2) + 50 of sample 7 (table 3) = sum 250,
		// index 25 - 11 = 14. A single-sample implementation would report
		// whichever value it happened to catch, i.e. 9 or 19, never 14.
		push_dither(6'd3, 6'd7); #1;
		$display("  dither 3/7: single-sample would give 9 or 19; got %0d", duty_index);
		ok("a dithered command averages to 14, not to either endpoint",
		   duty_index == 9'd14);

		// ---- the window is exactly 100 samples ------------------------------
		// Park at a known index, then push 99 of something different: nothing
		// may change until the 100th completes the window.
		push(6'd7, 100); #1;
		push(6'd3, 99);  #1;
		ok("99 samples do NOT update the index (window is 100)",
		   duty_index == 9'd19);
		push(6'd3, 1);   #1;
		ok("the 100th sample completes the window and updates",
		   duty_index == 9'd9);

		$display("");
		$display("DUTY: %0d of %0d failing", fails, tests);
		if (fails) $fatal(1, "tb_disk_pwm_duty FAILED");
		$display("DUTY GATE: PASS - the conversion table is applied");
		$finish;
	end

endmodule
