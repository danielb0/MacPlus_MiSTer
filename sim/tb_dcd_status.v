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
	// The mount state now comes from rtl/dcd_disk.v rather than being driven
	// directly, so the capacity in the Status reply is the one a real mount
	// would produce. Status touches no sector, so the slot needs no model.
	reg         img_mounted;
	reg  [63:0] img_size;
	reg         img_readonly;
	wire [31:0] sd_lba;
	wire        sd_rd, sd_wr;
	wire [15:0] sd_buff_din;

	wire [7:0] readData;
	wire       newByteReady;

	integer pass = 0;
	integer fail = 0;

	wire [31:0] dbg_dcd;

	dcd dut (
		.clk(clk), .cep(1'b1), .cen(1'b1), .turbo(1'b0),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .lstrb(lstrb), ._enable(_enable),
		.writeData(writeData), .writeReq(writeReq),
		.readData(readData), .newByteReady(newByteReady),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(1'b0),
		.sd_buff_addr(8'd0), .sd_buff_dout(16'd0),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(1'b0),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.dbg_dcd(dbg_dcd)
	);

	task mount;
		input [63:0] blocks;
		begin
			@(posedge clk); #1;
			img_size = blocks * 64'd512; img_readonly = 1'b0; img_mounted = 1'b1;
			@(posedge clk); #1;
			img_mounted = 1'b0;
			@(posedge clk);
		end
	endtask

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
	integer hsWait;
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
			// THE REAL HANDSHAKE, not a jump to state 1. Every bench here
			// used to start sending in state 1, which the drive accepted and
			// real hardware did not: the Mac asserts HOST and spins until the
			// drive pulls /HSHK low ($419AB0, error $11). See tb_dcd_link.v.
			setState(3'd2);
			@(posedge clk); #1;
			setState(3'd3);
			hsWait = 0;
			while (readData[7] !== 1'b0 && hsWait < 8000) begin
				@(posedge clk); hsWait = hsWait + 1;
			end
			check("the drive acknowledged the command with /HSHK",
			      readData[7] === 1'b0);
			setState(3'd1);
			macByte(8'hAA);
			macByte(8'h80 | macGroups(0));         // command groups
			macByte(8'h80 | macGroups(rspLen));    // reply groups
			// Data byte n owns bit n of the LSB byte -- see the four ROM /
			// firmware sites quoted in rtl/dcd_link.v. It was backwards here
			// and in the RTL together, which is why nothing caught it.
			macByte(8'h80 |  cmd[0][0]        | (cmd[1][0] << 1) | (cmd[2][0] << 2) |
			                (cmd[3][0] << 3)  | (cmd[4][0] << 4) | (cmd[5][0] << 5) |
			                (cmd[6][0] << 6));
			for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (cmd[i] >> 1));
			// The Mac returns to state 3 and waits for the release before
			// idling - TashTwenty's IntEn3.
			setState(3'd3);
			hsWait = 0;
			while (readData[7] !== 1'b1 && hsWait < 8000) begin
				@(posedge clk); hsWait = hsWait + 1;
			end
			check("the drive released /HSHK at the end of the command",
			      readData[7] === 1'b1);
			setState(3'd2);
		end
	endtask

	// Seven data bytes then the LSB byte LAST on this direction.
	task recvGroups;
		input integer n;
		begin
			for (g = 0; g < n; g = g + 1) begin
				for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
				for (i = 0; i < 7; i = i + 1)
					rsp[g*7 + i] = {raw[i][6:0], raw[7][i]};
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

	// ------------------------------------------------------------------
	// An opcode with no implementation: the empty-block acknowledgement
	// ------------------------------------------------------------------
	// $419CEC / $419CF0 enter the ordinary sender with d3 = $1A / $19, and the
	// path they share settles the whole shape without any drive-side document:
	//
	//   $419D08  andi.b #$3f,$19c(a1)   the reply opcode is (op & $3F) | $80
	//   $419D0E  suba.l a4,a4           no receive buffer
	//   $419D16  moveq  #$0,d7          no data expected -> macGroups(0) = 1
	//
	// so the reply is ONE group: six header bytes and the checksum. The
	// opcode byte is COMPUTED here from that `andi.b`, never typed as $99, so
	// agreeing with the RTL is evidence rather than a copy. Tashtari's logic
	// analyser capture off a real HD20 (68kMLA, 2022-04-26) shows the same two
	// exchanges, which is the independent confirmation.
	task runAck;
		input [7:0] op;
		begin
			sendCommand(op, 0);
			setState(3'd2);
			repeat (8) @(posedge clk); #1;
			check("an unimplemented opcode is ANSWERED, not dropped",
			      readData[7] === 1'b0);
			// Without this guard a drive that does not answer hangs the bench
			// in getByte instead of reporting, and the run ends in TIMEOUT
			// with no score. Blank the group so the checks below cannot pass
			// on stale bytes from the previous reply.
			//
			// FILLED WITH $01, NOT WITH X. X blanking made the checksum check
			// pass VACUOUSLY -- it compares rsp[6] against the negated sum of
			// the others, and X === X is TRUE, so the one assertion that is
			// self-referential sailed through a drive that had answered
			// nothing at all. $01 fails every check here deterministically:
			// the sum is 7 rather than 0, the opcode is not $99, the block
			// count is not zero and status bit 0 is set.
			if (readData[7] !== 1'b0) begin
				for (i = 0; i < 7; i = i + 1) rsp[i] = 8'h01;
			end
			else begin
				setState(3'd3);
				@(posedge clk); #1;
				setState(3'd1);
				getByte(sync);
				check("the acknowledgement opens with the $AA sync", sync === 8'hAA);
				recvGroups(macGroups(0));
			end
		end
	endtask

	// A command we DO implement and then refuse must keep its own failure
	// path. The generic ack is bounded to opcodes with no implementation at
	// all; if it ever widens to cover a write that arrived without its sector,
	// the Mac would be told a write succeeded that never happened.
	task expectNoReply;
		input [7:0] op;
		begin
			sendCommand(op, 0);
			setState(3'd2);
			ok = 1'b1;
			for (i = 0; i < 2000; i = i + 1) begin
				@(posedge clk); #1;
				if (readData[7] === 1'b0) ok = 1'b0;
			end
			check("a REFUSED command is still not answered", ok);
		end
	endtask

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
		img_mounted = 0; img_size = 0; img_readonly = 0;
		repeat (4) @(posedge clk); #1; _reset = 1;
		repeat (4) @(posedge clk);
		mount(64'd3850144);           // the 2 GB artefact: needs 22 bits

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
		// $F6, the constant TashTwenty writes, now that MultiBlock Write is
		// implemented. It was pinned at $DE while it was not: HFS writes the
		// MDB back at mount time to mark a volume in use, so a drive that
		// claimed to be writable turned a working read path into a handshake
		// timeout at the worst possible moment. The locked case below still
		// has to produce $DE, and from the image's own flag rather than from
		// a compile-time constant.
		check("Device_Character is $F6 at identity offset 4",
		      identity(4) === 8'hF6);
		check("  ...which is Mountable and Readable",
		      (identity(4) & 8'hC0) === 8'hC0);
		check("  ...and declares an icon and a disk in place",
		      (identity(4) & 8'h06) === 8'h06);
		check("  ...and reports WRITABLE, not write-protected",
		      ((identity(4) & 8'h20) === 8'h20) &&
		      ((identity(4) & 8'h08) === 8'h00));

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
		mount(64'd38965);                  // a real HD20, 20 MB
		repeat (4) @(posedge clk);
		runStatus;
		check("a second mount still reports writable",
		      identity(4) === 8'hF6);
		check("a 20 MB capacity reports as 38964, the highest block",
		      {identity(5), identity(6), identity(7)} === 24'd38964);
		sum = 0;
		for (i = 0; i < 343; i = i + 1) sum = sum + rsp[i];
		check("the second reply also checksums to zero", sum === 8'h00);

		// ---------------------------------------------------------------
		// A LOCKED IMAGE. The write path exists now, so write-protection has
		// to come from the mount rather than from a constant - and it must
		// move exactly one bit pair, not disturb Mountable, Readable, the
		// icon flag or Disk_In_Place.
		// ---------------------------------------------------------------
		setState(3'd2);
		@(posedge clk); #1;
		img_size = 64'd38965 * 64'd512; img_readonly = 1'b1; img_mounted = 1'b1;
		@(posedge clk); #1;
		img_mounted = 1'b0;
		repeat (4) @(posedge clk);
		runStatus;
		check("a read-only mount reports $DE, write-protected",
		      identity(4) === 8'hDE);
		check("  ...and nothing else in the byte moved",
		      (identity(4) & 8'hC6) === 8'hC6);
		setState(3'd3);
		repeat (4) @(posedge clk);
		setState(3'd2);
		mount(64'd38965);                  // back to a writable mount
		repeat (4) @(posedge clk);

		setState(3'd3);
		repeat (4) @(posedge clk);

		// ---------------------------------------------------------------
		// THIS TEST ASSERTED THE DEFECT BY NAME and is rewritten. It read:
		//
		//     "An unimplemented opcode must NOT be answered. The Mac sees its
		//      own handshake timeout, which is what a real drive does when it
		//      cannot reply - answering with a malformed frame would be worse."
		//
		// A real drive does no such thing, and the example it used was $04.
		// TashTwenty answers an unknown command with an empty block, and that
		// is what makes Erase Disk work; the false half of the old reasoning
		// is "malformed", because a header-only group of the length the Mac
		// asked for is perfectly well formed. Dropping $19 is what made
		// Initialize fail. The positive property now lives in the
		// "unimplemented opcodes are acknowledged" section at the end.
		//
		// What survives, and is the real property, is the BOUND: a command we
		// DO implement and then refuse must still not be answered, or the Mac
		// would be told a write happened that did not. $01 with no sector
		// behind it is that case.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		expectNoReply(8'h01);              // Write, but no sector arrived

		// ---------------------------------------------------------------
		// THE WEDGE HD DIAG FOUND ON HARDWARE, as error $28.
		// ---------------------------------------------------------------
		// A command is sent, the drive queues its reply and asserts /HSHK to
		// ask for the bus -- and then the Mac RESETS instead of receiving. If
		// the command layer carries on across that reset it re-raises txReq,
		// the link asserts /HSHK in the idle state, and waits for a state 1
		// that is never coming. The line stays low for ever and every later
		// operation fails. HD Diag's reset routine reads that back as
		// "asserted but never released":
		//
		//   00D932  moveq #$24,d0     error if /HSHK never goes LOW
		//   00D942  moveq #$28,d0     error if it never goes HIGH again
		//   00D96A  ror.l #$8,d0      which is why it prints as $28000000
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		sendCommand(8'h03, STATUS_LEN);
		setState(3'd2);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		check("the drive asks for the bus after a command", readData[7] === 1'b0);

		// Now reset instead of receiving, the way HD Diag does.
		setState(3'd4);
		repeat (8) @(posedge clk); #1;
		setState(3'd2);
		repeat (8) @(posedge clk); #1;
		check("a reset releases /HSHK rather than wedging it low",
		      readData[7] === 1'b1);

		// ...and the drive is still usable afterwards.
		sendCommand(8'h03, STATUS_LEN);
		setState(3'd2);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd3); @(posedge clk); #1;
		setState(3'd1);
		getByte(sync);
		recvGroups(49);
		sum = 0;
		for (i = 0; i < 343; i = i + 1) sum = sum + rsp[i];
		check("and a command after the reset still answers correctly",
		      (sum === 8'h00) && (rsp[0] === 8'h83));
		setState(3'd3);
		repeat (4) @(posedge clk);

		// ---- the JTAG telemetry word ---------------------------------------
		// sim/tb_dbg_probes.v proves the probe deck COUNTS correctly. This
		// proves rtl/dcd.v packs the word the way the deck unpacks it, which is
		// a separate claim: the deck reads the fields by hard-coded index and
		// this module writes them as one concatenation, so a slip on either
		// side is invisible to both benches on its own.
		//
		// The indices below are copied from dbg_probes.sv's wire aliases, NOT
		// from the concatenation in rtl/dcd.v. Sampled mid-reply, because at
		// rest every field is zero and any offset passes.
		//
		// TWO sample points, and the second is not redundant. Mid-reply the
		// drive has cleared rxHs to IDLE and pulled /HSHK low, so those two
		// fields read 0 and 0 -- swap them in the packing and every assertion
		// below still passes. A mutation sweep found exactly that. So walk the
		// RECEIVE handshake first, where rxHs is non-zero and /HSHK moves.
		setState(3'd2); repeat (4) @(posedge clk); #1;
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		#1;
		check("telemetry: rxHs reads READY while the drive is ready to receive",
		      dbg_dcd[7:5] === dut.link.rxHs && dbg_dcd[7:5] === 3'd2);
		check("telemetry: /HSHK reads asserted beside a non-zero rxHs",
		      dbg_dcd[4] === 1'b0);
		setState(3'd1); repeat (4) @(posedge clk); #1;
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b1 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		#1;
		check("telemetry: rxHs reads DONE once the Mac has finished sending",
		      dbg_dcd[7:5] === dut.link.rxHs && dbg_dcd[7:5] === 3'd4);
		check("telemetry: /HSHK reads released beside rxHs = DONE",
		      dbg_dcd[4] === 1'b1);
		setState(3'd2); repeat (4) @(posedge clk); #1;

		sendCommand(8'h03, STATUS_LEN);
		setState(3'd2);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd3); @(posedge clk); #1;
		setState(3'd1);
		getByte(sync);
		#1;
		check("telemetry: the phase field is the state the Mac is driving",
		      dbg_dcd[2:0] === {ca2, ca1, ca0});
		check("telemetry: selected",  dbg_dcd[3]  === 1'b1);
		check("telemetry: /HSHK",     dbg_dcd[4]  === dut.link.hshk_n);
		check("telemetry: rxHs",      dbg_dcd[7:5]   === dut.link.rxHs);
		check("telemetry: txState",   dbg_dcd[10:8]  === dut.link.txState);
		check("telemetry: txBusy",    dbg_dcd[11]    === dut.link.txBusy);
		check("telemetry: command FSM state",
		      dbg_dcd[18:16] === dut.cstate);
		check("telemetry: present",   dbg_dcd[19]    === dut.present);
		check("telemetry: the opcode of the frame in rxBuf",
		      dbg_dcd[27:20] === 8'h03);
		// The offset guard. Three fields that happen to hold the same value
		// would let an index slip through every check above.
		check("telemetry: fields differ here, so an index slip cannot pass",
		      (dbg_dcd[10:8] !== dbg_dcd[7:5]) &&
		      (dbg_dcd[18:16] !== dbg_dcd[10:8]) &&
		      (dbg_dcd[2:0] !== dbg_dcd[7:5]));
		recvGroups(49);
		setState(3'd3);
		repeat (4) @(posedge clk);

		// ------------------------------------------------------------------
		// Unimplemented opcodes: $19 format, $1A verify-format, $04 diagnostic
		// ------------------------------------------------------------------
		// Erase Disk / Initialize sends $19 then $1A. Dropping them made the
		// Mac sit through the long timeout $419D18 sets for these commands and
		// report "Initialization failed".
		$display("-- unimplemented opcodes are acknowledged --");

		runAck(8'h19);
		check("reply opcode is the ROM's (op & $3F) | $80, i.e. $99 for $19",
		      rsp[0] === ((8'h19 & 8'h3F) | 8'h80));
		check("the block-count byte is zero -- no blocks were transferred",
		      rsp[1] === 8'h00);
		check("the status byte reports success",   rsp[2] === 8'h00);
		check("  ...and specifically bit 0, which is the ROM's Op_Failed test",
		      rsp[2][0] === 1'b0);
		check("three pads complete the six-byte header",
		      rsp[3] === 8'h00 && rsp[4] === 8'h00 && rsp[5] === 8'h00);
		sum = 0;
		for (i = 0; i < 7; i = i + 1) sum = sum + rsp[i];
		check("the acknowledgement checksums to zero including CHK",
		      sum === 8'h00);
		check("the checksum is the last slot of the one group",
		      rsp[6] === (-(rsp[0] + rsp[1] + rsp[2] + rsp[3] + rsp[4] + rsp[5])));
		setState(3'd3);
		repeat (4) @(posedge clk); #1;
		check("/HSHK released after the acknowledgement", readData[7] === 1'b1);

		runAck(8'h1A);
		check("reply opcode is $9A for $1A, by the same arithmetic",
		      rsp[0] === ((8'h1A & 8'h3F) | 8'h80));
		sum = 0;
		for (i = 0; i < 7; i = i + 1) sum = sum + rsp[i];
		check("the $1A acknowledgement also checksums to zero", sum === 8'h00);
		setState(3'd3);
		repeat (4) @(posedge clk); #1;

		// $04 is Read Device ID on the drive's diagnostic side and is equally
		// unimplemented here. It is tested to prove the answer is GENERIC and
		// not two hand-written special cases for $19 and $1A.
		runAck(8'h04);
		check("the ack is generic: $04 is answered $84 too",
		      rsp[0] === ((8'h04 & 8'h3F) | 8'h80));
		sum = 0;
		for (i = 0; i < 7; i = i + 1) sum = sum + rsp[i];
		check("the $04 acknowledgement also checksums to zero", sum === 8'h00);
		setState(3'd3);
		repeat (4) @(posedge clk); #1;

		// Status still decodes as Status, not as a generic ack: its reply is
		// 49 groups and carries the identity block, which the ack shape cannot
		// produce. Re-checked here because the dispatch order changed.
		runStatus;
		check("Status is still dispatched as Status, not swallowed by the ack",
		      rsp[0] === 8'h83 && nDecoded === 343);
		check("  ...and still carries the identity block",
		      identity(2) === 8'h00 && identity(3) === 8'h01);
		setState(3'd3);
		repeat (4) @(posedge clk); #1;

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
