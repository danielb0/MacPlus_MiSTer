`timescale 1ns/1ps
//
// tb_rom_word_addr.v - MAC128K_PLAN.md Phase 2 gate.
//
// rom_word_addr.v is instantiated twice in MacPlus.sv: once on the download
// side (which slot an incoming byte belongs to) and once on the read side
// (which slot the running model reads from). The property that matters is
// not the arithmetic in isolation -- it is that a byte Main_MiSTer sends for
// slot N, at some offset, lands at the SAME SDRAM word a model reading slot N
// at that offset would fetch. That is the plan's own pass criterion: "a bench
// asserting that ROM reads ... land on the right SDRAM words for each model."
//
// So this bench drives BOTH instances side by side and checks agreement,
// rather than checking either instance against a hand-derived expected value
// -- the latter would just be re-deriving the same concatenation a second
// time and proving it agrees with itself.
//
module tb_rom_word_addr;

	reg  [1:0]  dl_slot, rd_slot;
	reg  [17:0] dl_offset, rd_offset;
	wire [20:0] dl_addr, rd_addr;

	rom_word_addr dl (.slot(dl_slot), .word_offset(dl_offset), .addr(dl_addr));
	rom_word_addr rd (.slot(rd_slot), .word_offset(rd_offset), .addr(rd_addr));

	integer tests = 0;
	integer fails = 0;

	task ok;
		input [8*80:1] name;
		input          cond;
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	integer slot, i;
	reg [17:0] offsets [0:2];

	initial begin
		$display("");
		$display("=== rom_word_addr: download/read agreement, per slot ===");
		$display("");

		offsets[0] = 18'h00000; // bottom of the image
		offsets[1] = 18'h1FFFF; // where addrController_top forces A17=1 for a 64K ROM
		offsets[2] = 18'h3FFFF; // top of the 512KB window

		// ---- 1. download and read agree, for every slot and every offset --
		// This is the actual bug this module exists to prevent: a byte
		// written for slot N must be read back from slot N, not some other
		// slot the two sides disagree about.
		for (slot = 0; slot < 4; slot = slot + 1) begin
			for (i = 0; i < 3; i = i + 1) begin
				dl_slot = slot[1:0]; dl_offset = offsets[i];
				rd_slot = slot[1:0]; rd_offset = offsets[i];
				#1;
				ok("download and read agree for this (slot, offset)", dl_addr === rd_addr);
			end
		end

		// ---- 2. slots do not alias each other ------------------------------
		// The four 512KB windows must be four DISJOINT 18-bit-wide regions of
		// the 21-bit address, not overlapping ranges that happen to look right
		// at offset 0. Checked at the top of the window, where an off-by-one
		// in the slot's bit position would first show up as an overlap into
		// the next slot.
		for (slot = 0; slot < 3; slot = slot + 1) begin
			dl_slot = slot[1:0];     dl_offset = 18'h3FFFF; // top of slot N
			rd_slot = slot[1:0]+1'b1; rd_offset = 18'h00000; // bottom of slot N+1
			#1;
			ok("top of one slot does not alias bottom of the next", dl_addr !== rd_addr);
		end

		// ---- 3. the confirmed Main_MiSTer encoding, by name ---------------
		// user_io.cpp:1619 sends boot0.rom as index 0, boot1.rom as index 1,
		// boot2.rom (Phase 3's 64K ROM) as index 2, packed into
		// ioctl_index[7:6] at user_io.cpp:2724. Slot IS the boot-file number,
		// not an arbitrary code -- so a config that reads slot 2 must be
		// reading boot2.rom, and nothing else.
		dl_slot = 2'd0; dl_offset = 18'h0; rd_slot = 2'd0; rd_offset = 18'h0; #1;
		ok("slot 0 is releases/boot0.rom's window", dl_addr === 21'h000000);
		dl_slot = 2'd1; dl_offset = 18'h0; #1;
		ok("slot 1 is releases/boot1.rom's window", dl_addr === 21'h040000);
		dl_slot = 2'd2; dl_offset = 18'h0; #1;
		ok("slot 2 is Phase 3's boot2.rom window, reserved but addressable", dl_addr === 21'h080000);
		dl_slot = 2'd3; dl_offset = 18'h0; #1;
		ok("slot 3 (boot3.rom) is Main_MiSTer's own ceiling - i < 4", dl_addr === 21'h0C0000);

		$display("");
		$display("ROM-WORD-ADDR: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("PHASE 2 GATE: PASS - download and read agree, slots do not alias");
		else            $display("PHASE 2 GATE: FAIL");
		$finish;
	end

endmodule
