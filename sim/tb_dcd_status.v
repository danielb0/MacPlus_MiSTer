`timescale 1ns/1ps
//
// tb_dcd_status.v - MAC128K_PLAN.md Phase 5 gate for rtl/dcd.v.
//
// End-to-end: drive a real Status command onto the wire exactly as the Mac
// would frame it, then decode the reply the same way the Plus ROM's receive
// path does, and check every field of the identity block.
//
// Three properties matter more than the individual fields:
//
//   1. THE REPLY IS SIX GROUPS AND CHECKSUMS TO ZERO. The identity block is 36
//      bytes and the March document says the reply is "a total of 42 bytes, or
//      6 groups". 42 is exactly 6*7, so if the payload length is wrong by even
//      one byte the framing stops being whole groups and the Mac's decoder
//      desynchronises. Summing every decoded byte INCLUDING the checksum to
//      zero is the same test the ROM does at $419A08.
//
//   2. THE REPLY OPCODE IS THE COMMAND OPCODE WITH BIT 7 SET. The ROM checks
//      this explicitly - $419776 subtracts $80 and compares, erroring $30 on a
//      mismatch - so getting it wrong fails at the driver, not at the link.
//
//   3. CAPACITY FOLLOWS THE MOUNTED IMAGE, and it is 24-bit. A capacity
//      truncated to 16 bits reports correctly for anything up to 32 MB and
//      silently wrong above it, which is precisely the seam this plan already
//      warns about for block numbers. So it is checked with a value that needs
//      22 bits, matching the 2 GB test artefact.
//
module tb_dcd_status;

	reg        clk = 0;
	reg        _reset;
	reg        ca0, ca1, ca2, lstrb, _enable;
	reg  [7:0] writeData;
	reg        writeReq;
	reg        present;
	reg [23:0] blockCount;

	wire [7:0] readData;
	wire       newByteReady;

	integer pass = 0;
	integer fail = 0;

	dcd dut (
		.clk(clk), .cep(1'b1), .cen(1'b1),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .lstrb(lstrb), ._enable(_enable),
		.writeData(writeData), .writeReq(writeReq),
		.readData(readData), .newByteReady(newByteReady),
		.present(present), .blockCount(blockCount)
	);

	always #10 clk = ~clk;

	task check;
		input [511:0] name;
		input cond;
		begin
			if (cond) begin pass = pass + 1; $display("  PASS  %0s", name); end
			else      begin fail = fail + 1; $display("  FAIL  %0s", name); end
		end
	endtask

	task setState;
		input [2:0] s;
		begin
			@(posedge clk); #1;
			ca0 = s[0]; ca1 = s[1]; ca2 = s[2];
		end
	endtask

	task macByte;
		input [7:0] b;
		begin
			@(posedge clk); #1;
			writeData = b; writeReq = 1'b1;
			@(posedge clk); #1;
			writeReq = 1'b0;
		end
	endtask

	task getByte;
		output [7:0] b;
		begin
			@(posedge clk);
			while (!newByteReady) @(posedge clk);
			b = readData;
			#1;
		end
	endtask

	integer i, g;
	reg [7:0] cmd [0:6];
	reg [7:0] raw [0:7];
	reg [7:0] rsp [0:47];      // decoded reply payload, 6 groups * 7 bytes
	reg [7:0] sum;
	reg [7:0] sync;
	reg ok;
	reg [31:0] cap;

	// Frame and send a command payload as the Mac would: sync, two count
	// bytes ($80 | total groups), then the group with the LSB byte FIRST.
	task sendCommand;
		begin
			sum = 0;
			for (i = 0; i < 6; i = i + 1) sum = sum + cmd[i];
			cmd[6] = -sum;                      // checksum completes the group
			setState(3'd1);
			macByte(8'hAA);
			macByte(8'h81);                     // one group out
			macByte(8'h81);                     // (the drive decides its own reply length)
			macByte(8'h80 | (cmd[0][0] << 6) | (cmd[1][0] << 5) | (cmd[2][0] << 4) |
			                (cmd[3][0] << 3) | (cmd[4][0] << 2) | (cmd[5][0] << 1) |
			                 cmd[6][0]);
			for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (cmd[i] >> 1));
		end
	endtask

	// Decode `n` groups the way the ROM does: 7 data bytes then the LSB byte
	// LAST on this direction.
	task recvGroups;
		input integer n;
		begin
			for (g = 0; g < n; g = g + 1) begin
				for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
				for (i = 0; i < 7; i = i + 1)
					rsp[g*7 + i] = {raw[i][6:0], raw[7][6-i]};
			end
		end
	endtask

	initial begin
		_reset = 0; ca0 = 0; ca1 = 1; ca2 = 0;
		lstrb = 0; _enable = 0; writeData = 0; writeReq = 0;
		present = 1;
		blockCount = 24'd3850144;     // the 2 GB artefact: needs 22 bits
		repeat (4) @(posedge clk); #1; _reset = 1;
		repeat (4) @(posedge clk);

		$display("tb_dcd_status");

		// ---------------------------------------------------------------
		// Status: <$03> <5 pad> <CHK>, seven bytes, one group
		// ---------------------------------------------------------------
		cmd[0] = 8'h03;
		for (i = 1; i < 6; i = i + 1) cmd[i] = 8'h00;
		sendCommand;

		// The drive should now want the bus.
		setState(3'd2);
		repeat (8) @(posedge clk); #1;
		check("drive asserts /HSHK after a Status command", readData[7] === 1'b0);

		setState(3'd3);
		@(posedge clk); #1;
		setState(3'd1);

		getByte(sync);
		check("reply opens with the $AA sync", sync === 8'hAA);

		recvGroups(6);

		// ---- property 1: whole groups, and the checksum closes ----
		sum = 0;
		for (i = 0; i < 42; i = i + 1) sum = sum + rsp[i];
		check("reply is 6 groups and sums to zero including CHK", sum === 8'h00);

		// ---- property 2: reply opcode ----
		check("reply opcode is $83 (command $03 with bit 7 set)", rsp[0] === 8'h83);

		// Summing to zero does NOT pin where the checksum sits: shortening the
		// payload by one byte moves CHK to offset 40 and leaves a zero pad at
		// 41, and the sum still closes. (It did; a mutation shortening txLen
		// scored full marks until this was added.) The March document is
		// explicit that the reply ends <pad> <pad> <CHK>, so pin all three.
		sum = 0;
		for (i = 0; i < 41; i = i + 1) sum = sum + rsp[i];
		check("the two bytes before the checksum are pads", (rsp[39] === 8'h00) && (rsp[40] === 8'h00));
		check("the checksum is the FINAL byte of the payload", rsp[41] === (-sum));

		// ---- the identity block, offsets 3..38 ----
		ok = (rsp[3]  === "R") && (rsp[4]  === "e") && (rsp[5]  === "n") &&
		     (rsp[6]  === "e") && (rsp[7]  === "-") && (rsp[8]  === "1") &&
		     (rsp[9]  === " ") && (rsp[10] === "R") && (rsp[11] === "M") &&
		     (rsp[12] === " ") && (rsp[13] === "M") && (rsp[14] === "H") &&
		     (rsp[15] === " ");
		check("device name is 'Rene-1 RM MH ', 13 chars from the firmware", ok);

		check("device type is $000210",
		      {rsp[16], rsp[17], rsp[18]} === 24'h000210);
		check("firmware revision is $3372 (matches the reassembly)",
		      {rsp[19], rsp[20]} === 16'h3372);

		// ---- property 3: 24-bit capacity ----
		cap = {8'h00, rsp[21], rsp[22], rsp[23]};
		check("capacity is the mounted image, full 24 bits", cap === 32'd3850144);
		check("capacity did not truncate to 16 bits", rsp[21] !== 8'h00);

		check("bytes per block is 532", {rsp[24], rsp[25]} === 16'd532);
		check("cylinders 305, heads 4, sectors 32 (Rodime RO552)",
		      ({rsp[26], rsp[27]} === 16'd305) && (rsp[28] === 8'd4) && (rsp[29] === 8'd32));
		check("possible spares is 76",
		      {rsp[30], rsp[31], rsp[32]} === 24'd76);
		check("no spared and no bad blocks",
		      ({rsp[33], rsp[34], rsp[35]} === 24'd0) &&
		      ({rsp[36], rsp[37], rsp[38]} === 24'd0));

		// /HSHK must be released so the Mac's end-of-transmission spin ends.
		setState(3'd3);
		repeat (4) @(posedge clk); #1;
		check("/HSHK released after the reply", readData[7] === 1'b1);

		// ---------------------------------------------------------------
		// A capacity that fits in 16 bits must still be reported exactly -
		// the other side of the seam.
		// ---------------------------------------------------------------
		setState(3'd2);
		#1; blockCount = 24'd38965;        // a real HD20, 20 MB
		repeat (4) @(posedge clk);
		cmd[0] = 8'h03;
		for (i = 1; i < 6; i = i + 1) cmd[i] = 8'h00;
		sendCommand;
		setState(3'd2); repeat (8) @(posedge clk);
		setState(3'd3); @(posedge clk); #1;
		setState(3'd1);
		getByte(sync);
		recvGroups(6);
		check("a 20 MB capacity reports as 38965 blocks",
		      {rsp[21], rsp[22], rsp[23]} === 24'd38965);
		sum = 0;
		for (i = 0; i < 42; i = i + 1) sum = sum + rsp[i];
		check("second reply also checksums to zero", sum === 8'h00);

		// ---------------------------------------------------------------
		// An unimplemented opcode must NOT be answered. The Mac sees its own
		// handshake timeout, which is what a real drive does when it cannot
		// reply - answering with a malformed frame would be worse.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		cmd[0] = 8'h00;                    // MultiBlock Read, not implemented
		for (i = 1; i < 6; i = i + 1) cmd[i] = 8'h00;
		sendCommand;
		setState(3'd2);
		repeat (64) @(posedge clk); #1;
		check("an unimplemented opcode is not answered", readData[7] === 1'b1);

		$display("tb_dcd_status: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("FAILED");
		$finish;
	end

	initial begin
		#20000000;
		$display("tb_dcd_status: TIMEOUT");
		$finish;
	end

endmodule
