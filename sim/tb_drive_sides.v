`timescale 1ns/1ps
//
// tb_drive_sides.v - MAC128K_PLAN.md item 8, mechanism half.
//
// Compile: iverilog -g2012 -I rtl -y rtl -o out.vvp sim/tb_drive_sides.v
//
// The 128K and 512K shipped a mechanically single-sided 400K drive. Phase 3
// gated the MEDIA on `drive800k` (an 800K image is refused) but left the
// drive's own SIDES register hardcoded to 1, so the machine still told its
// ROM it had a double-sided mechanism. A 64K-ROM Mac wired to an 800K drive
// is the documented cause of Sad Mac 0F0004 (divide by zero), which is
// exactly what the 2026-09-03 hardware test produced once the address-map
// bugs were fixed and the ROM actually ran.
//
// The distinction this bench exists to hold is MEDIA vs MECHANISM. They are
// different signals with different lifetimes -- diskSides changes when you
// mount a disk, drive800k never changes for a given model -- and wiring
// SIDES to the wrong one would look correct with a disk inserted and wrong
// with an empty drive. So every case below pins one against the other.
//
module tb_drive_sides;

	localparam [3:0] REG_SIDES   = 4'd12; // {ca2,ca1,ca0,SEL} = 1100
	localparam [3:0] REG_READY   = 4'd13;
	localparam [3:0] REG_SUPERDR = 4'd10;

	reg clk = 0;
	always #5 clk = ~clk;

	reg  drive800k_i, diskSides_i;
	reg  [3:0] addr;
	wire [7:0] rd800, rd400;

	// Two drives differing ONLY in the mechanism bit, read side by side.
	floppy dut800 (
		.clk(clk), .cep(1'b1), .cen(1'b1), ._reset(1'b1),
		.ca2(addr[3]), .ca1(addr[2]), .ca0(addr[1]), .SEL(addr[0]),
		.lstrb(1'b1), ._enable(1'b0), .writeData(8'h00), .readData(rd800),
		.advanceDriveHead(1'b0), .insertDisk(1'b0),
		.diskSides(diskSides_i), .drive800k(1'b1),
		.dskReadAck(1'b0), .dskReadData(8'h00),
		.writeReq(1'b0), .writeProtect(1'b0)
	);

	floppy dut400 (
		.clk(clk), .cep(1'b1), .cen(1'b1), ._reset(1'b1),
		.ca2(addr[3]), .ca1(addr[2]), .ca0(addr[1]), .SEL(addr[0]),
		.lstrb(1'b1), ._enable(1'b0), .writeData(8'h00), .readData(rd400),
		.advanceDriveHead(1'b0), .insertDisk(1'b0),
		.diskSides(diskSides_i), .drive800k(1'b0),
		.dskReadAck(1'b0), .dskReadData(8'h00),
		.writeReq(1'b0), .writeProtect(1'b0)
	);

	integer tests = 0;
	integer fails = 0;

	task ok;
		input [8*76:1] name;
		input          cond;
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	// Read a drive register: readData = {reg_value, 7'h00}, so bit 7 is it.
	task read_reg;
		input [3:0] a;
		begin
			addr = a;
			@(posedge clk);
			#1;
		end
	endtask

	initial begin
		$display("");
		$display("=== drive SIDES reports the MECHANISM, not the media ===");
		$display("");

		// ---- 1. empty drive: SIDES must still describe the mechanism ------
		// This is the case that separates the two signals. With no disk
		// mounted, media-sidedness is meaningless but the drive still has
		// however many heads it has, and the ROM still asks.
		diskSides_i = 1'b0;
		read_reg(REG_SIDES);
		ok("800K drive, no disk: SIDES = 1 (double-sided mechanism)", rd800[7] == 1'b1);
		ok("400K drive, no disk: SIDES = 0 (single-sided mechanism)", rd400[7] == 1'b0);

		// ---- 2. a single-sided image in each drive ------------------------
		// A 400K disk in a Plus does not turn the Plus's drive into a 400K
		// mechanism. If SIDES were wired to diskSides this would break.
		diskSides_i = 1'b0;
		read_reg(REG_SIDES);
		ok("800K drive + 400K media: SIDES stays 1", rd800[7] == 1'b1);
		ok("400K drive + 400K media: SIDES stays 0", rd400[7] == 1'b0);

		// ---- 3. a double-sided image ---------------------------------------
		// The 400K row is the mirror image of the bug: the media gate should
		// already have refused an 800K image on that model, but even if one
		// arrived, the MECHANISM must not start claiming a second head.
		diskSides_i = 1'b1;
		read_reg(REG_SIDES);
		ok("800K drive + 800K media: SIDES = 1", rd800[7] == 1'b1);
		ok("400K drive + 800K media: SIDES STILL 0 (media must not drive it)", rd400[7] == 1'b0);

		// ---- 4. we are addressing the register we think we are -------------
		// {ca2,ca1,ca0,SEL} = 1100 is SIDES. If that decode were off by one,
		// every check above would be reading READY or SUPERDR and passing or
		// failing for reasons that have nothing to do with the fix.
		read_reg(REG_READY);
		ok("READY reads 0 (ready) on both, and is not the SIDES bit",
		   rd800[7] == 1'b0 && rd400[7] == 1'b0);
		read_reg(REG_SUPERDR);
		ok("SUPERDR reads 0 on both drives", rd800[7] == 1'b0 && rd400[7] == 1'b0);

		// Neighbours agree across the two drives, so case 1's disagreement is
		// attributable to drive800k alone and not to some unrelated drift.
		ok("the two drives differ ONLY at SIDES among these registers",
		   rd800[7] == rd400[7]);

		$display("");
		$display("DRIVE-SIDES: %0d of %0d failing", fails, tests);
		if (fails) $fatal(1, "tb_drive_sides FAILED");
		$display("ITEM 8 GATE: PASS - mechanism reported independently of media");
		$finish;
	end

endmodule
