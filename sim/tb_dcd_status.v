`timescale 1ns/1ps
//
// tb_dcd_status.v - MAC128K_PLAN.md Phase 5 gate for rtl/dcd.v.
//
// THIS BENCH IS A REIMPLEMENTATION OF THE MAC'S RECEIVER, NOT A MIRROR OF THE
// TRANSMITTER. The previous version of this file scored 19/19 against an
// implementation built on the WRONG REVISION of the specification, because it
// framed the command and decoded the reply using the same reading as the RTL.
// A bench built from the same reading as the RTL cannot test that reading.
//
// So every structural number below is derived the way $419600-$419E40 of ROM
// 4D1F8172 derives it, and nothing is copied from rtl/dcd.v:
//
//   1. THE GROUP COUNT IS COMPUTED, NOT WRITTEN DOWN. macGroups() is
//      `addq.w #6,dN / divu.w #7,dN` + 1 from $4196FA, and the count byte the
//      Mac puts on the wire is that value or'd with $80 - which is $419ADC
//      `addi.l #$810081,d0` adding $81 to BOTH halves of the pair at once.
//      Feed it the Status length and 49 falls out; nobody types 49.
//
//   2. THE REPLY IS UNPACKED THROUGH THE ROM'S TWO-BUFFER SPLIT. $4198BC
//      presets a group counter to 3 and the `dbra` at $419932 sits after the
//      5th of the group's seven stores, so the receiver switches destination
//      after byte 3*7+5 = 26, UNCONDITIONALLY - there is no opcode test near
//      it. identity() below reassembles the block through that split rather
//      than indexing a flat array, which is what makes the header length
//      testable: a 4-byte header still checksums and still fills whole groups,
//      but it puts every identity field two bytes out.
//
//   3. THE ICON OFFSET IS CHECKED WHERE THE DRIVER PUBLISHES IT. $419CC4 hands
//      the Finder `$1F0(a1)`, and the receive buffer is `$1C4(a1)` from
//      $419D3E, so the icon must be 44 bytes into the second buffer. That is
//      an address the ROM computes for itself, so agreeing with it is evidence
//      and not assertion.
//
// The field VALUES are cross-checked against TashTwenty and BMOW's Floppy Emu,
// both of which mount on real hardware; see MAC128K_PLAN.md.
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

	// ------------------------------------------------------------------
	// The Mac's length arithmetic, $4196FA
	// ------------------------------------------------------------------
	// n is the payload BEYOND the six-byte header, which is why Status - whose
	// command carries no data at all - comes out at one group, and why the
	// reply's 332 comes out at 49 and not 48.
	function integer macGroups;
		input integer n;
		begin
			macGroups = ((n + 6) / 7) + 1;
		end
	endfunction

	localparam integer STATUS_LEN = 332;   // $419D2C move.l #$14C,d7

	// ------------------------------------------------------------------
	// Bus plumbing
	// ------------------------------------------------------------------
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

	integer i, g, nGroups;
	reg [7:0] cmd [0:6];
	reg [7:0] raw [0:7];
	reg [7:0] rsp [0:1023];    // decoded reply payload, nGroups * 7
	reg [7:0] sum;
	reg [7:0] sync;
	reg ok;
	reg [31:0] cap;
	integer nDecoded;
	reg [87:0] trailerStr = "MiSTer HD20";

	// Frame a one-group command the way $419A26-$419AF4 does: the six bytes of
	// the command block at SonyVars+$19C, then the checksum completing the
	// group. rspLen is the DATA length the Mac expects back; the count byte is
	// derived from it, never passed in.
	task sendCommand;
		input [7:0] opcode;
		input integer rspLen;
		begin
			cmd[0] = opcode;
			for (i = 1; i < 6; i = i + 1) cmd[i] = 8'h00;
			sum = 0;
			for (i = 0; i < 6; i = i + 1) sum = sum + cmd[i];
			cmd[6] = -sum;
			setState(3'd1);
			macByte(8'hAA);
			macByte(8'h80 | macGroups(0));         // command groups
			macByte(8'h80 | macGroups(rspLen));    // reply groups
			macByte(8'h80 | (cmd[0][0] << 6) | (cmd[1][0] << 5) | (cmd[2][0] << 4) |
			                (cmd[3][0] << 3) | (cmd[4][0] << 2) | (cmd[5][0] << 1) |
			                 cmd[6][0]);
			for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (cmd[i] >> 1));
		end
	endtask

	// Seven data bytes then the LSB byte LAST on this direction.
	task recvGroups;
		input integer n;
		begin
			for (g = 0; g < n; g = g + 1) begin
				for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
				for (i = 0; i < 7; i = i + 1)
					rsp[g*7 + i] = {raw[i][6:0], raw[7][6-i]};
			end
			nDecoded = n * 7;
		end
	endtask

	// The identity block as the ROM leaves it in memory: reply bytes 0..25 go
	// to the command block at $19C and 26.. to the buffer at $1C4, so identity
	// byte k is at $19C+6+k below 20 and at $1C4+(k-20) at or above it. Written
	// as the two-step lookup the ROM performs, not as rsp[6+k].
	function [7:0] identity;
		input integer k;
		begin
			if (k < 20) identity = rsp[6 + k];              // still in the command block
			else        identity = rsp[26 + (k - 20)];      // switched to $1C4
		end
	endfunction

	// The driver publishes $1F0(a1) as the icon, and the buffer is $1C4(a1).
	function [7:0] iconByte;
		input integer k;
		begin
			iconByte = rsp[26 + (32'h1F0 - 32'h1C4) + k];
		end
	endfunction

	task runStatus;
		begin
			sendCommand(8'h03, STATUS_LEN);
			setState(3'd2);
			repeat (8) @(posedge clk); #1;
			check("drive asserts /HSHK after a Status command", readData[7] === 1'b0);
			setState(3'd3);
			@(posedge clk); #1;
			setState(3'd1);
			getByte(sync);
			check("reply opens with the $AA sync", sync === 8'hAA);
			nGroups = macGroups(STATUS_LEN);
			recvGroups(nGroups);
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

		check("the ROM's own arithmetic makes a Status reply 49 groups",
		      macGroups(STATUS_LEN) === 49);

		runStatus;

		// ---- framing ----
		check("the reply is 49 groups, i.e. 343 payload bytes", nDecoded === 343);

		sum = 0;
		for (i = 0; i < 343; i = i + 1) sum = sum + rsp[i];
		check("the whole reply sums to zero including CHK", sum === 8'h00);

		// Summing to zero does not pin WHERE the checksum sits: a payload one
		// byte short moves CHK forward and leaves a zero pad behind it, and the
		// sum still closes. Both TashTwenty and the HD20's own firmware emit the
		// checksum as the seventh byte of the LAST group, with padding before
		// it, so pin the pads and the final slot separately.
		sum = 0;
		for (i = 0; i < 342; i = i + 1) sum = sum + rsp[i];
		check("the four slots before the checksum are pad",
		      (rsp[338] === 8'h00) && (rsp[339] === 8'h00) &&
		      (rsp[340] === 8'h00) && (rsp[341] === 8'h00));
		check("the checksum is the FINAL slot of the FINAL group", rsp[342] === (-sum));

		// ---- the six-byte header ----
		// $419776 subtracts $80 from the reply opcode and compares it against
		// the opcode it sent, erroring $30 on a mismatch.
		check("reply opcode is $83 (command $03 with bit 7 set)", rsp[0] === 8'h83);
		check("block count and status are zero for a Status reply",
		      (rsp[1] === 8'h00) && (rsp[2] === 8'h00));
		check("the header is six bytes, so three pads follow the status",
		      (rsp[3] === 8'h00) && (rsp[4] === 8'h00) && (rsp[5] === 8'h00));

		// ---- the identity block, read out through the ROM's buffer split ----
		check("Device_Type is a word at identity offset 0",
		      {identity(0), identity(1)} === 16'h0000);
		check("Device_Manuf is 1 (Apple) at identity offset 2",
		      {identity(2), identity(3)} === 16'h0001);
		check("Device_Character is $F6 at identity offset 4",
		      identity(4) === 8'hF6);
		check("  ...which is Mountable, Readable and Writable",
		      (identity(4) & 8'hE0) === 8'hE0);
		check("  ...and declares an icon and a disk in place",
		      (identity(4) & 8'h06) === 8'h06);

		// ---- capacity: 24-bit, and one less than the image ----
		cap = {8'h00, identity(5), identity(6), identity(7)};
		check("Num_Blocks is the highest block, capacity-1, full 24 bits",
		      cap === 32'd3850143);
		check("capacity did not truncate to 16 bits", identity(5) !== 8'h00);

		check("Num_Spares and Num_BadBlocks are zero",
		      ({identity(8),  identity(9)}  === 16'h0000) &&
		      ({identity(10), identity(11)} === 16'h0000));

		// ---- the icon, at the offset the driver publishes ----
		// Checking iconByte(i) against identity(64+i) would prove nothing: both
		// reduce to the same rsp[] subscript, so it holds however the reply is
		// laid out. It did, and a mutation moving the icon two bytes scored full
		// marks against it. What pins the icon is its CONTENT at a known phase,
		// because the drawing is four bytes per row: the top eight rows are
		// margin, row 8 is the drive's top edge, and rows 21 up are margin
		// again. Two bytes out and row 8 lands in the wrong columns.
		//
		// This is also the test that pins the SIX-BYTE HEADER. A four-byte
		// header still checksums, still fills whole groups and still passes
		// every field check above, because the fields either side are zero -
		// but it slides the icon two bytes and this fails.
		ok = 1'b1;
		for (i = 0; i < 32; i = i + 1) if (iconByte(i) !== 8'h00) ok = 1'b0;
		check("the icon's top eight rows are blank margin", ok);

		check("the icon's row 8 is the drive's top edge, on the right phase",
		      (iconByte(32) === 8'h3F) && (iconByte(33) === 8'hFF) &&
		      (iconByte(34) === 8'hFF) && (iconByte(35) === 8'hFC));

		check("row 9 is the box's two side walls",
		      (iconByte(36) === 8'h20) && (iconByte(37) === 8'h00) &&
		      (iconByte(38) === 8'h00) && (iconByte(39) === 8'h04));

		ok = 1'b1;
		for (i = 84; i < 128; i = i + 1) if (iconByte(i) !== 8'h00) ok = 1'b0;
		check("the icon's bottom eleven rows are blank margin", ok);

		// The mask must cover the icon, or the Finder draws a torn shape...
		ok = 1'b1;
		for (i = 0; i < 128; i = i + 1)
			if ((iconByte(i) & ~iconByte(128 + i)) !== 8'h00) ok = 1'b0;
		check("every set icon pixel is inside the mask", ok);

		// ...and it must be a SILHOUETTE, not a second copy of the image. A
		// mask equal to the image passes the covering test above and gives a
		// hollow, unclickable icon on the desktop, so require it to fill the
		// box's interior: row 9 is two side walls in the image and solid in the
		// mask.
		ok = 1'b0;
		for (i = 0; i < 128; i = i + 1)
			if ((iconByte(128 + i) & ~iconByte(i)) !== 8'h00) ok = 1'b1;
		check("the mask is a filled silhouette, not a copy of the image", ok);

		check("the mask's row 9 is solid where the image is hollow",
		      (iconByte(128 + 36) === 8'h3F) && (iconByte(128 + 39) === 8'hFC));

		// ---- the trailer at identity offset 320 ----
		check("the trailer is a Pascal string of 11 characters",
		      identity(320) === 8'd11);
		ok = 1'b1;
		for (i = 0; i < 11; i = i + 1)
			if (identity(321 + i) !== trailerStr[(10-i)*8 +: 8]) ok = 1'b0;
		check("the trailer reads 'MiSTer HD20'", ok);

		// ---- /HSHK release ----
		setState(3'd3);
		repeat (4) @(posedge clk); #1;
		check("/HSHK released after the reply", readData[7] === 1'b1);

		// ---------------------------------------------------------------
		// THE DRIVE IS A SLAVE TO THE MAC'S SECOND COUNT BYTE. TashTwenty
		// sizes its entire reply buffer from `RC_RSPG & $7F` before writing a
		// single field into it, and the HD20's firmware does `ld R2,53h` for
		// the same purpose. Hardcoding 49 works against this ROM and breaks
		// against any driver revision that asks for something else, so ask for
		// a different length and require the drive to honour it.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		sendCommand(8'h03, 32'd130);      // 136 -> 19+1 = 20 groups
		setState(3'd2); repeat (8) @(posedge clk);
		setState(3'd3); @(posedge clk); #1;
		setState(3'd1);
		getByte(sync);
		recvGroups(macGroups(32'd130));
		check("a shorter request is answered with exactly that many groups",
		      nDecoded === 20 * 7);
		sum = 0;
		for (i = 0; i < 140; i = i + 1) sum = sum + rsp[i];
		check("the shortened reply still checksums to zero", sum === 8'h00);
		check("the shortened reply is still a Status reply", rsp[0] === 8'h83);

		// ---------------------------------------------------------------
		// The other side of the 16-bit capacity seam.
		// ---------------------------------------------------------------
		setState(3'd2);
		#1; blockCount = 24'd38965;        // a real HD20, 20 MB
		repeat (4) @(posedge clk);
		runStatus;
		check("a 20 MB capacity reports as 38964, the highest block",
		      {identity(5), identity(6), identity(7)} === 24'd38964);
		sum = 0;
		for (i = 0; i < 343; i = i + 1) sum = sum + rsp[i];
		check("the second reply also checksums to zero", sum === 8'h00);

		setState(3'd3);
		repeat (4) @(posedge clk);

		// ---------------------------------------------------------------
		// An unimplemented opcode must NOT be answered. The Mac sees its own
		// handshake timeout, which is what a real drive does when it cannot
		// reply - answering with a malformed frame would be worse.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		sendCommand(8'h04, 32'd0);         // Diagnostic, not implemented
		setState(3'd2);
		repeat (64) @(posedge clk); #1;
		check("an unimplemented opcode is not answered", readData[7] === 1'b1);

		$display("tb_dcd_status: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("FAILED");
		$finish;
	end

	initial begin
		#200000000;
		$display("tb_dcd_status: TIMEOUT");
		$finish;
	end

endmodule
