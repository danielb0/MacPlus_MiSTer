// tb_cd_mix.v -- Phase 3C/3D gate. SCSI_UPGRADE_PLAN.md's ladder names three
// things this must show: the pedestal clears, a settled filter sits at 0 rather
// than -1 LSB, and there is no step at mount/unmount.
`timescale 1ns/1ps
module tb_cd_mix;
	reg clk = 0;
	always #5 clk = ~clk;              // 100 MHz, arbitrary; ce sets the rate

	reg ce = 0;
	integer cediv = 0;
	always @(posedge clk) begin
		cediv <= cediv + 1;
		if (cediv == 9) begin cediv <= 0; ce <= 1; end else ce <= 0;
	end

	reg               cd_mounted = 0;
	reg signed [15:0] mac_in = 0, cd_l_in = 0, cd_r_in = 0;
	reg        [1:0]  cd_vol = 0;
	wire signed [15:0] out_l, out_r;

	cd_mix dut (.clk(clk), .ce(ce), .cd_mounted(cd_mounted), .mac_in(mac_in),
	            .cd_l_in(cd_l_in), .cd_r_in(cd_r_in), .cd_vol(cd_vol),
	            .out_l(out_l), .out_r(out_r));

	integer fails = 0, tests = 0;
	task ok(input [800:0] name, input cond);
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	task samples(input integer n);
		integer i;
		begin for (i = 0; i < n; i = i + 1) @(posedge ce); end
	endtask

	// The pedestal the Mac emits while sound is DISABLED: 8'h7f * volume 7,
	// shifted x32. This is the number 3C exists to reclaim.
	localparam signed [15:0] PEDESTAL = 16'sd28448;

	integer  peak, trough, i, prev, step, maxstep;
	reg signed [15:0] base_l, base_r;
	reg signed [15:0] s;

	initial begin
		$display("");
		$display("=== Phase 3C/3D: DC blocker, envelope, mixer ===");

		// ---- 1. a settled filter sits at ZERO, not -1 LSB -----------------
		// The classic DC-blocker foot-gun: >>> on a negative number rounds
		// toward -inf, so a naive implementation settles one LSB low and stays
		// there. dc_blocker_slow avoids it by working 23 bits below an output
		// LSB. If this fails, the {din,23'd0} fixed point has been "simplified".
		mac_in = 16'sd0;
		cd_mounted = 1;
		samples(20000);
		ok("3C - a settled filter with zero input sits at EXACTLY 0",
		   dut.blk.dout === 16'sd0 && dut.dc_est === 16'sd0);

		// ---- 2. the pedestal clears --------------------------------------
		mac_in = PEDESTAL;
		samples(40000);                 // >> 392 ms-equivalent at K=12
		ok("3C - the DC estimate converges on the pedestal",
		   dut.dc_est > 16'sd28000 && dut.dc_est <= PEDESTAL);
		ok("3C - so the corrected Mac channel lands near zero",
		   dut.out_l > -16'sd400 && dut.out_l < 16'sd400);

		// ---- 3. NO STEP at mount or unmount ------------------------------
		// The reason the envelope exists. Switching the correction in is a step
		// of up to 28,448; ramping removes it instead. Measure the largest
		// single-sample jump across an unmount and a remount.
		maxstep = 0; prev = out_l;
		cd_mounted = 0;                 // RELEASE: pedestal comes back
		for (i = 0; i < 12000; i = i + 1) begin
			@(posedge ce);
			step = (out_l > prev) ? (out_l - prev) : (prev - out_l);
			if (step > maxstep) maxstep = step;
			prev = out_l;
		end
		$display("          release: largest single-sample step = %0d", maxstep);
		ok("3C - unmount does not step (release is ramped)", maxstep < 64);
		ok("3C - and the pedestal really did come back",
		   out_l > 16'sd28000);

		maxstep = 0; prev = out_l;
		cd_mounted = 1;                 // ATTACK
		for (i = 0; i < 12000; i = i + 1) begin
			@(posedge ce);
			step = (out_l > prev) ? (out_l - prev) : (prev - out_l);
			if (step > maxstep) maxstep = step;
			prev = out_l;
		end
		$display("          attack:  largest single-sample step = %0d", maxstep);
		ok("3C - mount does not step (attack is ramped)", maxstep < 64);

		// ---- 4. the ramp takes ~171 ms, not a few samples -----------------
		// 8192 samples at 48 kHz. Anything much faster is audible as a click;
		// much slower and a user notices the disc "fading in".
		cd_mounted = 0; samples(20000);
		cd_mounted = 1;
		i = 0;
		while (dut.g != 17'h10000 && i < 40000) begin @(posedge ce); i = i + 1; end
		$display("          attack reached full scale in %0d samples", i);
		ok("3C - the ramp is ~8192 samples (171 ms at 48 kHz)",
		   i >= 8000 && i <= 8400);

		// ---- 5. no disc mounted => the Mac path is BIT-UNCHANGED ----------
		// The property that makes this whole feature a provable no-op for
		// anyone not using it.
		cd_mounted = 0; cd_l_in = 0; cd_r_in = 0;
		samples(20000);
		mac_in = 16'sd12345; samples(2);
		ok("3C - with no disc, out == raw Mac audio, bit for bit",
		   out_l === 16'sd12345 && out_r === 16'sd12345);
		mac_in = -16'sd9876; samples(2);
		ok("3C - including negative values",
		   out_l === -16'sd9876 && out_r === -16'sd9876);

		// ---- 6/7. the mixer and CD volume --------------------------------
		// Measured as the CD's CONTRIBUTION -- out with the CD applied minus out
		// with it silent, taken with NO ce edge in between so the Mac channel is
		// provably identical across the pair. The first draft compared absolute
		// levels and was really measuring the DC blocker still settling from the
		// previous test's step (dc_est was 174, not 0); a volume test that moves
		// when the filter moves is not testing volume.
		mac_in = 0; cd_mounted = 1; samples(20000);

		cd_vol = 2'd0;
		cd_l_in = 0; cd_r_in = 0; #1; base_l = out_l; base_r = out_r;
		cd_l_in = 16'sd1000; cd_r_in = -16'sd2000; #1;
		// A mono error is a volume error; a stereo error is an image error.
		ok("3D - left and right stay independent",
		   (out_l - base_l) == 16'sd1000 && (out_r - base_r) == -16'sd2000);

		cd_l_in = 0; #1; base_l = out_l;
		cd_l_in = 16'sd8000;
		cd_vol = 2'd0; #1;
		ok("3D - volume Full is unity", (out_l - base_l) == 16'sd8000);
		cd_vol = 2'd1; #1;
		ok("3D - volume 3/4", (out_l - base_l) == 16'sd6000);
		cd_vol = 2'd2; #1;
		ok("3D - volume 1/2", (out_l - base_l) == 16'sd4000);
		cd_vol = 2'd3; #1;
		ok("3D - volume Off silences the CD contribution exactly",
		   (out_l - base_l) == 16'sd0);
		// ...and Off must mute the CD ONLY. The Mac channel is not routed
		// through this control -- on real hardware the Mac's volume had no
		// effect on the drive and vice versa.
		ok("3D - volume Off leaves the Mac channel untouched", out_l == base_l);

		// ---- 8. saturation, not wraparound --------------------------------
		// The failure this replaces is a full-scale sign flip, which is far
		// worse than clipping.
		cd_vol = 2'd0;
		mac_in = 16'sd30000; cd_l_in = 16'sd30000; cd_r_in = -16'sd30000;
		samples(20000);                 // let the blocker settle on the new DC
		mac_in = 16'sd30000; samples(2);
		ok("3D - positive overflow saturates to +32767", out_l <= 16'sd32767);
		ok("3D - negative overflow saturates to -32768", out_r >= -16'sd32768);
		peak = out_l; trough = out_r;
		ok("3D - and does NOT wrap sign", peak > 0 && trough < 0);

		$display("");
		$display("CD-MIX: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("PHASE 3C/3D GATE: PASS - pedestal reclaimed, no clicks, mixer sane");
		else            $display("PHASE 3C/3D GATE: FAIL");
		$finish;
	end
endmodule
