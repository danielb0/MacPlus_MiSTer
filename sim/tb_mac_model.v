`timescale 1ns/1ps
//
// tb_mac_model.v - MAC128K_PLAN.md Phase 1 gate.
//
// mac_model.v is pure combinational logic, so the interesting failures are not
// timing but wrong table entries -- and a wrong entry here is silent. A model
// strapped to the wrong configRAMSize boots and merely reports the wrong
// memory; one strapped to the wrong machineType boots and merely has a dead
// keyboard. Neither announces itself, so every entry is asserted explicitly
// rather than spot-checked.
//
// Three properties matter more than the individual rows:
//
//   1. Model 0 is the Plus. `status` defaults to zero, so if this ever moves,
//      every existing user's config silently changes machine on next start.
//
//   2. Reserved encodings fall back to the Plus. The model field is 3 bits
//      but only three values are defined, and a config saved by a future
//      build (or a corrupt one) must not latch an undefined strap.
//
//   3. mem_big is honoured ONLY where the real machine had sockets. The
//      512Ke had its 512K soldered down; if mem_big leaked into it, the OSD
//      Memory option would invent a machine that never existed.
//
// The 64K-ROM models are not tested because they are not yet implemented --
// they need Phase 2's third ROM slot. When Phase 3 adds them, the reserved-
// encoding assertions below are what will fail, and that is the intended
// signal to update this bench alongside the table.
//
module tb_mac_model;

	reg  [2:0] model;
	reg        mem_big;

	wire [1:0] configROMSize;
	wire [1:0] configRAMSize;
	wire       machineType;
	wire       romSlot;

	integer tests = 0;
	integer fails = 0;

	task ok;
		input [8*72:1] name;
		input          cond;
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	// Assert a whole row of the table at once, so a wrong entry names itself.
	task expect_straps;
		input [8*72:1] name;
		input [1:0]    rom;
		input [1:0]    ram;
		input          mtype;
		input          slot;
		begin
			tests = tests + 1;
			if (configROMSize === rom && configRAMSize === ram &&
			    machineType   === mtype && romSlot       === slot)
				$display("PASS: %0s", name);
			else begin
				$display("FAIL: %0s", name);
				$display("        got  ROM=%b RAM=%b machineType=%b romSlot=%b",
				         configROMSize, configRAMSize, machineType, romSlot);
				$display("        want ROM=%b RAM=%b machineType=%b romSlot=%b",
				         rom, ram, mtype, slot);
				fails = fails + 1;
			end
		end
	endtask

	mac_model dut
	(
		.model         ( model         ),
		.mem_big       ( mem_big       ),
		.configROMSize ( configROMSize ),
		.configRAMSize ( configRAMSize ),
		.machineType   ( machineType   ),
		.romSlot       ( romSlot       )
	);

	integer m;

	initial begin
		$display("");
		$display("=== mac_model: model -> hardware straps ===");
		$display("");

		// ---- 1. Mac Plus, the default ------------------------------------
		// 128K ROM in slot 0 (releases/boot0.rom), Plus behaviour, and the
		// 1MB/4MB choice honoured because the Plus had SIMM sockets.
		model = 3'd0; mem_big = 1'b0; #1;
		expect_straps("Plus, 1MB", 2'b01, 2'b10, 1'b0, 1'b0);
		mem_big = 1'b1; #1;
		expect_straps("Plus, 4MB", 2'b01, 2'b11, 1'b0, 1'b0);

		// ---- 2. Mac SE ---------------------------------------------------
		// 256K ROM in slot 1 (releases/boot1.rom) and machineType = 1, which
		// is what switches the keyboard to ADB.
		model = 3'd1; mem_big = 1'b0; #1;
		expect_straps("SE, 1MB", 2'b10, 2'b10, 1'b1, 1'b1);
		mem_big = 1'b1; #1;
		expect_straps("SE, 4MB", 2'b10, 2'b11, 1'b1, 1'b1);

		// ---- 3. Mac 512Ke ------------------------------------------------
		// The same 128K ROM as the Plus, so slot 0 and no new image. RAM is
		// 512K and NOT negotiable.
		model = 3'd2; mem_big = 1'b0; #1;
		expect_straps("512Ke", 2'b01, 2'b01, 1'b0, 1'b0);

		// ---- 4. the property that matters most ---------------------------
		// mem_big must not reach a soldered-RAM machine. This is the failure
		// that would quietly invent a 4MB 512Ke.
		mem_big = 1'b1; #1;
		expect_straps("512Ke ignores mem_big - RAM was soldered", 2'b01, 2'b01, 1'b0, 1'b0);

		// ---- 5. every pre-Plus model is Plus-like to dataController ------
		// Not a model index. A 128K given machineType = 1 gets ADB keyboard
		// timing and never sees a keypress.
		model = 3'd2; #1;
		ok("512Ke is machineType 0, not its model number", machineType === 1'b0);

		// ---- 6. reserved encodings fall back to the Plus -----------------
		// A config saved by a later build, or a corrupt one, must not latch an
		// undefined strap. Checked for every undefined value, not just one.
		for (m = 3; m < 8; m = m + 1) begin
			model = m[2:0]; mem_big = 1'b0; #1;
			expect_straps("reserved encoding falls back to Plus", 2'b01, 2'b10, 1'b0, 1'b0);
		end

		// ---- 7. model 0 is the Plus, and must stay so --------------------
		// `status` defaults to zero. If this row ever moves, every existing
		// user's saved config silently changes machine on the next start.
		model = 3'd0; mem_big = 1'b0; #1;
		ok("model 0 straps a 128K ROM (the Plus), not something else",
		   configROMSize === 2'b01 && machineType === 1'b0 && romSlot === 1'b0);

		$display("");
		$display("MAC-MODEL: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("PHASE 1 GATE: PASS - model straps correct, mem_big contained, reserved safe");
		else            $display("PHASE 1 GATE: FAIL");
		$finish;
	end

endmodule
