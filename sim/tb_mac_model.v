`timescale 1ns/1ps
//
// tb_mac_model.v - MAC128K_PLAN.md Phase 1/3 gate.
//
// mac_model.v is pure combinational logic, so the interesting failures are not
// timing but wrong table entries -- and a wrong entry here is silent. A model
// strapped to the wrong configRAMSize boots and merely reports the wrong
// memory; one strapped to the wrong machineType boots and merely has a dead
// keyboard. Neither announces itself, so every entry is asserted explicitly
// rather than spot-checked.
//
// Four properties matter more than the individual rows:
//
//   1. Model 0 is the Plus. `status` defaults to zero, so if this ever moves,
//      every existing user's config silently changes machine on next start.
//
//   2. Reserved encodings fall back to the Plus. The model field is 3 bits
//      but only five values are defined, and a config saved by a future
//      build (or a corrupt one) must not latch an undefined strap.
//
//   3. mem_big is honoured ONLY where the real machine had sockets. The
//      128K, 512K and 512Ke had their RAM soldered down; if mem_big leaked
//      into any of them, the OSD Memory option would invent a machine that
//      never existed.
//
//   4. The 512K and 128K both read ROM slot 2 (boot2.rom), and neither is
//      machineType 1. Phase 3 landed the 64K models sharing one ROM slot per
//      MAC128K_PLAN.md's ROM diff (the two known 64K images differ by 57 of
//      65536 bytes, none of it a memory-map constant), so this is the
//      assertion that would catch either model being pointed at the wrong
//      slot or picking up SE behaviour by mistake.
//
module tb_mac_model;

	reg  [2:0] model;
	reg        mem_big;

	wire [1:0] configROMSize;
	wire [1:0] configRAMSize;
	wire       machineType;
	wire [1:0] romSlot;
	wire       drive800k;
	wire       scsiPresent;
	wire       ramSoldered;

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
		input [1:0]    slot;
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
		.romSlot       ( romSlot       ),
		.drive800k     ( drive800k     ),
		.scsiPresent   ( scsiPresent   ),
		.ramSoldered   ( ramSoldered   )
	);

	integer m;
	reg [1:0] ramLo, ramHi;
	reg       soldered;

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

		// ---- 3. Mac 512K and Mac 128K, Phase 3's deliverable --------------
		// Both run the 64K ROM in slot 2 (boot2.rom); RAM is the one thing
		// that tells them apart, and it is soldered, not chosen.
		model = 3'd2; mem_big = 1'b0; #1;
		expect_straps("512K", 2'b00, 2'b01, 1'b0, 2'b10);
		model = 3'd3; mem_big = 1'b0; #1;
		expect_straps("128K", 2'b00, 2'b00, 1'b0, 2'b10);

		// ---- 4. mem_big must not reach either soldered-RAM machine --------
		// This is the failure that would quietly invent a 4MB 128K.
		mem_big = 1'b1; #1;
		expect_straps("128K ignores mem_big - RAM was soldered", 2'b00, 2'b00, 1'b0, 2'b10);
		model = 3'd2; mem_big = 1'b1; #1;
		expect_straps("512K ignores mem_big - RAM was soldered", 2'b00, 2'b01, 1'b0, 2'b10);

		// ---- 5. Mac 512Ke, reachable but not yet exposed in the OSD -------
		// The same 128K ROM as the Plus, so slot 0 and no new image. RAM is
		// 512K and NOT negotiable. Model value 4, not 2: MacPlus.sv's CONF_STR
		// does not list it yet (still has SCSI, so it is not yet an authentic
		// 512Ke), and 2/3 went to the machines that ARE exposed.
		model = 3'd4; mem_big = 1'b0; #1;
		expect_straps("512Ke", 2'b01, 2'b01, 1'b0, 2'b00);
		mem_big = 1'b1; #1;
		expect_straps("512Ke ignores mem_big - RAM was soldered", 2'b01, 2'b01, 1'b0, 2'b00);

		// ---- 6. every pre-Plus model is Plus-like to dataController ------
		// Not a model index. A 128K given machineType = 1 gets ADB keyboard
		// timing and never sees a keypress. Checked for all four, not just
		// the one that prompted this module.
		model = 3'd2; #1; ok("512K is machineType 0, not its model number",   machineType === 1'b0);
		model = 3'd3; #1; ok("128K is machineType 0, not its model number",   machineType === 1'b0);
		model = 3'd4; #1; ok("512Ke is machineType 0, not its model number",  machineType === 1'b0);

		// ---- 7. reserved encodings fall back to the Plus -----------------
		// A config saved by a later build, or a corrupt one, must not latch an
		// undefined strap. Checked for every undefined value, not just one --
		// note this range shrank from Phase 1's 3..7 as real models claimed
		// 2, 3 and 4.
		for (m = 5; m < 8; m = m + 1) begin
			model = m[2:0]; mem_big = 1'b0; #1;
			expect_straps("reserved encoding falls back to Plus", 2'b01, 2'b10, 1'b0, 2'b00);
		end

		// ---- 8. model 0 is the Plus, and must stay so --------------------
		// `status` defaults to zero. If this row ever moves, every existing
		// user's saved config silently changes machine on the next start.
		model = 3'd0; mem_big = 1'b0; #1;
		ok("model 0 straps a 128K ROM (the Plus), not something else",
		   configROMSize === 2'b01 && machineType === 1'b0 && romSlot === 1'b0);

		// ---- 9. drive800k - item 8, MacPlus.sv's 800K-image refusal -------
		// Only the 128K and 512K have a mechanically single-sided drive. If
		// this were wrong for the Plus, SE or 512Ke, a legitimate 800K image
		// would be silently refused on a machine that shipped with a
		// double-sided drive.
		model = 3'd0; #1; ok("Plus drive takes 800K",   drive800k === 1'b1);
		model = 3'd1; #1; ok("SE drive takes 800K",     drive800k === 1'b1);
		model = 3'd2; #1; ok("512K drive is 400K-only", drive800k === 1'b0);
		model = 3'd3; #1; ok("128K drive is 400K-only", drive800k === 1'b0);
		model = 3'd4; #1; ok("512Ke drive takes 800K",  drive800k === 1'b1);

		// ---- 10. scsiPresent - Phase 4 item 9 -----------------------------
		// Only the Plus and SE ever had a SCSI bus. This strap does more than
		// gate the $58xxxx decode: when it is clear, rtl/addrDecoder.v mirrors
		// the ROM window at A17 = 1, which is HOW the Plus ROM is told there is
		// no SCSI ($4003E4 compares $420000 with $440000). A wrong entry here
		// is therefore silent in the worst way -- a 512Ke that still reports a
		// SCSI bus looks like a Plus with less memory, which is exactly the
		// inauthentic machine Phase 4 exists to remove. The end-to-end
		// behaviour is gated by sim/tb_scsi_absence.v; this is the table row.
		model = 3'd0; #1; ok("Plus has SCSI",       scsiPresent === 1'b1);
		model = 3'd1; #1; ok("SE has SCSI",         scsiPresent === 1'b1);
		model = 3'd2; #1; ok("512K has no SCSI",    scsiPresent === 1'b0);
		model = 3'd3; #1; ok("128K has no SCSI",    scsiPresent === 1'b0);
		model = 3'd4; #1; ok("512Ke has no SCSI",   scsiPresent === 1'b0);

		// ---- 11. ramSoldered, and the drift check that gives it its value --
		// This output exists so MacPlus.sv can grey out the Memory item. Its
		// row could be typed wrong in exactly the way a second table in
		// MacPlus.sv could, so it is NOT tested against a list of models --
		// it is tested against the BEHAVIOUR it claims to describe. For every
		// model, ramSoldered must be true if and only if configRAMSize
		// actually ignores mem_big. Sweeping the whole encoding space means a
		// model added later cannot get one of the two right and the other
		// wrong: whichever is edited alone, this fails.
		for (m = 0; m < 8; m = m + 1) begin
			model = m[2:0];
			mem_big = 1'b0; #1; ramLo = configRAMSize; soldered = ramSoldered;
			mem_big = 1'b1; #1; ramHi = configRAMSize;
			ok("ramSoldered iff mem_big changes nothing",
			   soldered === ((ramLo === ramHi) ? 1'b1 : 1'b0));
			ok("  ...and it does not depend on mem_big itself",
			   ramSoldered === soldered);
		end

		// The rows themselves, so a reader can see the intent as well as the
		// invariant. The Plus and SE had SIMM sockets; the other three had
		// their RAM soldered down and were not expandable.
		mem_big = 1'b0;
		model = 3'd0; #1; ok("Plus has sockets",   ramSoldered === 1'b0);
		model = 3'd1; #1; ok("SE has sockets",     ramSoldered === 1'b0);
		model = 3'd2; #1; ok("512K is soldered",   ramSoldered === 1'b1);
		model = 3'd3; #1; ok("128K is soldered",   ramSoldered === 1'b1);
		model = 3'd4; #1; ok("512Ke is soldered",  ramSoldered === 1'b1);

		$display("");
		$display("MAC-MODEL: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("PHASE 1/3 GATE: PASS - model straps correct, mem_big contained, reserved safe");
		else            $display("PHASE 1/3 GATE: FAIL");
		$finish;
	end

endmodule
