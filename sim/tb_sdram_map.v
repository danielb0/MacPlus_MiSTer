`timescale 1ns/1ps
`include "sdram_map.vh"   // compile with: iverilog -I rtl (see header)
//
// tb_sdram_map.v - MAC128K_PLAN.md Phase 3 gate for rtl/sdram_map.vh.
//
// The Phase 3 boot hang was not a logic bug in any module. Every module
// involved was individually correct and individually gated: sim/tb_mac_model.v
// (22/22) proved the straps, sim/tb_rom_word_addr.v (19/19) proved that a byte
// written for slot N reads back from slot N. Both passed. Neither could have
// caught this, because neither knows where its region SITS in SDRAM -- the
// region map lived nowhere but inside one concatenation in MacPlus.sv.
//
// That is the seam, and this bench tests it: not "is each window computed
// correctly" but "do any two windows land on the same words".
//
// Mutation-tested in place, which is the point of the SLOT2_ALIASED check
// below: the same arithmetic run against the historical ROM base must still
// report the collision it had. A disjointness check that cannot detect the
// bug it was written for is decoration.
//
module tb_sdram_map;

	// Historical ROM base: ROM used to sublet the first megabyte of the disk
	// region. Kept here as the mutation, not as live configuration.
	localparam [24:0] ROM_BASE_PRE_FIX = 25'h0200000;

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

	// True when [a_lo, a_lo+a_len) and [b_lo, b_lo+b_len) share no word.
	function disjoint;
		input integer a_lo, a_len, b_lo, b_len;
		begin
			disjoint = (a_lo + a_len <= b_lo) || (b_lo + b_len <= a_lo);
		end
	endfunction

	// The two floppy windows, in words. addrController_top.v adds the byte
	// offset to a byte address and MacPlus.sv shifts down by one to index
	// SDRAM, so the word address is base + off/2.
	localparam integer DISK_WORDS   = `DSK_IMAGE_MAX_BYTES / 2;
	localparam integer DISK_INT_LO  = `SDRAM_DISK_BASE + (`DSK_INT_BYTE_OFF / 2);
	localparam integer DISK_EXT_LO  = `SDRAM_DISK_BASE + (`DSK_EXT_BYTE_OFF / 2);

	localparam integer SLOT_WORDS   = `SDRAM_ROM_SLOT_WORDS;

	integer i, j, lo_i, lo_j;

	initial begin
		$display("=== tb_sdram_map ===");
		$display("RAM      %0h + %0h words", `SDRAM_RAM_BASE, `SDRAM_RAM_WORDS);
		$display("ROM      %0h, %0d slots of %0h words", `SDRAM_ROM_BASE, `SDRAM_ROM_SLOTS, SLOT_WORDS);
		$display("disk int %0h + %0h words", DISK_INT_LO, DISK_WORDS);
		$display("disk ext %0h + %0h words", DISK_EXT_LO, DISK_WORDS);

		// --- the bug: every ROM slot must clear both floppy windows -------
		// Slot 2 is the one the 128K and 512K read (rtl/mac_model.v
		// ROM_SLOT_64K). Slot 3 is unused by any model today but is
		// reachable from Main_MiSTer, so it is checked too.
		for (i = 0; i < `SDRAM_ROM_SLOTS; i = i + 1) begin
			lo_i = `SDRAM_ROM_BASE + (i * SLOT_WORDS);
			ok({"ROM slot vs internal floppy, slot ", 8'h30 + i[7:0]},
			   disjoint(lo_i, SLOT_WORDS, DISK_INT_LO, DISK_WORDS));
			ok({"ROM slot vs external floppy, slot ", 8'h30 + i[7:0]},
			   disjoint(lo_i, SLOT_WORDS, DISK_EXT_LO, DISK_WORDS));
			ok({"ROM slot vs Mac RAM, slot ", 8'h30 + i[7:0]},
			   disjoint(lo_i, SLOT_WORDS, `SDRAM_RAM_BASE, `SDRAM_RAM_WORDS));
		end

		// --- ROM slots must not alias each other -------------------------
		for (i = 0; i < `SDRAM_ROM_SLOTS; i = i + 1)
			for (j = i + 1; j < `SDRAM_ROM_SLOTS; j = j + 1) begin
				lo_i = `SDRAM_ROM_BASE + (i * SLOT_WORDS);
				lo_j = `SDRAM_ROM_BASE + (j * SLOT_WORDS);
				ok({"ROM slots distinct, ", 8'h30 + i[7:0], "/", 8'h30 + j[7:0]},
				   disjoint(lo_i, SLOT_WORDS, lo_j, SLOT_WORDS));
			end

		// --- the rest of the map -----------------------------------------
		ok("floppy windows distinct",
		   disjoint(DISK_INT_LO, DISK_WORDS, DISK_EXT_LO, DISK_WORDS));
		ok("internal floppy vs Mac RAM",
		   disjoint(DISK_INT_LO, DISK_WORDS, `SDRAM_RAM_BASE, `SDRAM_RAM_WORDS));
		ok("external floppy vs Mac RAM",
		   disjoint(DISK_EXT_LO, DISK_WORDS, `SDRAM_RAM_BASE, `SDRAM_RAM_WORDS));

		// --- capacity: only addr[22:0] reaches the chip ------------------
		// Bit 24 is dropped connecting MacPlus.sv's 25-bit sdram_addr to
		// sdram.v's 24-bit port, and sdram.v ignores bit 23. A base past
		// this wraps onto another region instead of erroring.
		ok("ROM region fits addressable space",
		   (`SDRAM_ROM_BASE + (`SDRAM_ROM_SLOTS * SLOT_WORDS)) <= `SDRAM_USABLE_WORDS);
		ok("disk region fits addressable space",
		   (DISK_EXT_LO + DISK_WORDS) <= `SDRAM_USABLE_WORDS);
		ok("RAM region fits addressable space",
		   (`SDRAM_RAM_BASE + `SDRAM_RAM_WORDS) <= `SDRAM_USABLE_WORDS);

		// --- mutation: the check must still catch the original bug -------
		// Slot 2 at the historical base is 0x200000 + 2<<18 = 0x280000,
		// which is the internal floppy image's base exactly. If this ever
		// reports disjoint, the arithmetic above has stopped meaning
		// anything and the other results are worthless.
		ok("MUTATION: pre-fix slot 2 aliased the internal floppy",
		   !disjoint(ROM_BASE_PRE_FIX + (2 * SLOT_WORDS), SLOT_WORDS,
		             DISK_INT_LO, DISK_WORDS));
		ok("MUTATION: pre-fix slot 2 base == internal floppy base",
		   (ROM_BASE_PRE_FIX + (2 * SLOT_WORDS)) == DISK_INT_LO);
		ok("MUTATION: pre-fix slots 0 and 1 were clear (Plus/SE still booted)",
		   disjoint(ROM_BASE_PRE_FIX, 2 * SLOT_WORDS, DISK_INT_LO, DISK_WORDS));

		$display("=== %0d tests, %0d failures ===", tests, fails);
		if (fails) $fatal(1, "tb_sdram_map FAILED");
		$finish;
	end

endmodule
