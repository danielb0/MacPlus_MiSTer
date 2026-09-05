`timescale 1ns/1ps
//
// tb_dcd_read.v - MAC128K_PLAN.md Phase 5 gate for MultiBlock Read ($00).
//
// End to end: a Mac model frames a real Read command, a block-device model
// answers the sector fetches, and the reply frames are decoded the way the
// Plus ROM decodes them. Both models are written from their own sources -
// $419600-$419E40 for the Mac, hps_io.sv for the slot - not from rtl/dcd.v.
//
// THE STRUCTURAL NUMBERS ARE DERIVED, NOT TYPED, for the reason the sibling
// status bench spells out. macGroups() is the ROM's own `addq.w #6 / divu.w
// #7` plus one, and feeding it a read's 532 (512 data + 20 tags, the +$14 at
// $4196D0) produces 77. Nobody writes 77 here.
//
// FOUR PROPERTIES CARRY THIS TEST:
//
//   1. N BLOCKS ARE N SEPARATE FRAMES, each with its own sync and checksum.
//      The Mac sends the command once - $419712 returns immediately for
//      opcode 0 - and then receives N times.
//   2. THE BLOCK BYTE COUNTS DOWN FROM N TO 1. The ROM compares it against its
//      own counter at $41978C before decrementing at $4197EE, so an off-by-one
//      or an ascending count is error $31.
//   3. THE DATA STARTS AT REPLY BYTE 26, after six header bytes and twenty
//      tags. TashTwenty points its read pointer at buffer+26 for the same
//      reason, and the ROM's receiver switches buffers there.
//   4. THE BLOCK NUMBER IS 24 BITS. A read is asked for above 65535 on
//      purpose: a truncated LBA reads the right data for the first 32 MB of
//      any image and silently the wrong data above it, which is the same seam
//      this project has already been caught by twice.
//
module tb_dcd_read;

	reg         clk = 0;
	reg         _reset;
	reg         ca0, ca1, ca2, lstrb, _enable;
	reg   [7:0] writeData;
	reg         writeReq;

	reg         img_mounted;
	reg  [63:0] img_size;
	reg         img_readonly;

	wire [31:0] sd_lba;
	wire        sd_rd, sd_wr;
	reg         sd_ack;
	reg   [7:0] sd_buff_addr;
	reg  [15:0] sd_buff_dout;
	wire [15:0] sd_buff_din;
	reg         sd_buff_wr;

	wire  [7:0] readData;
	wire        newByteReady;

	integer pass = 0, fail = 0;

	wire [31:0] dbg_dcd;
	reg  [2:0]  dbgCstateSeen = 0;
	always @(posedge clk)
		if (dbg_dcd[18:16] > dbgCstateSeen) dbgCstateSeen <= dbg_dcd[18:16];

	dcd dut (
		.clk(clk), .cep(1'b1), .cen(1'b1),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .lstrb(lstrb), ._enable(_enable),
		.writeData(writeData), .writeReq(writeReq),
		.readData(readData), .newByteReady(newByteReady),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.dbg_dcd(dbg_dcd)
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

	function integer macGroups;             // $4196FA
		input integer n;
		begin
			macGroups = ((n + 6) / 7) + 1;
		end
	endfunction

	// A read asks for 512 data bytes plus the 20 tag bytes $4196D0 adds.
	localparam integer READ_LEN = 512 + 20;

	// Disk contents: byte k of block b, made to differ across the two halves
	// of a host word and across blocks.
	function [7:0] diskByte;
		input [23:0] b;
		input integer k;
		begin
			diskByte = b[7:0] ^ b[23:16] ^ k[7:0] ^ (k[8] ? 8'h5A : 8'hA5);
		end
	endfunction

	// ------------------------------------------------------------------
	// The block-device model: services whatever LBA is asked for.
	// ------------------------------------------------------------------
	integer      m;
	integer      fetches;
	reg   [31:0] fetched [0:15];
	// How long the host dawdles before acking. Raised in one test to model an
	// SD card stalling, which is the only thing that separates "wait for the
	// fetch" from "assume the fetch was instant".
	integer      serveDelay;

	always @(posedge clk) begin
		if (sd_rd && !sd_ack) begin
			fetched[fetches[3:0]] = sd_lba;
			fetches = fetches + 1;
			repeat (serveDelay) @(posedge clk);
			sd_ack = 1'b1;
			@(posedge clk);
			for (m = 0; m < 256; m = m + 1) begin
				@(posedge clk); #1;
				sd_buff_addr = m[7:0];
				sd_buff_dout = {diskByte(sd_lba[23:0], m*2 + 1),
				                diskByte(sd_lba[23:0], m*2)};
				sd_buff_wr   = 1'b1;
				@(posedge clk); #1;
				sd_buff_wr   = 1'b0;
			end
			@(posedge clk); #1;
			sd_ack = 1'b0;
			// The request line falls a clock AFTER ack does, so without this
			// the model re-triggers on the tail of the transfer it has just
			// finished and counts one fetch as two.
			while (sd_rd) @(posedge clk);
		end
	end

	// ------------------------------------------------------------------
	// The Mac side
	// ------------------------------------------------------------------
	integer i, g;
	reg [7:0] cmd [0:6];
	reg [7:0] raw [0:7];
	reg [7:0] rsp [0:1023];
	reg [7:0] sum;
	reg [7:0] sync;
	reg       ok, okAll;
	integer   nDecoded;
	integer   hsWait;

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

	task mount;
		input [63:0] blocks;
		begin
			@(posedge clk); #1;
			img_size = blocks * 64'd512; img_readonly = 1'b0; img_mounted = 1'b1;
			@(posedge clk); #1;
			img_mounted = 1'b0;
			repeat (2) @(posedge clk);
		end
	endtask

	// <opcode><blocks><adrH><adrM><adrL><pad> then the checksum, one group.
	task sendRead;
		input  [7:0] blocks;
		input [23:0] lba;
		begin
			cmd[0] = 8'h00;
			cmd[1] = blocks;
			cmd[2] = lba[23:16];
			cmd[3] = lba[15:8];
			cmd[4] = lba[7:0];
			cmd[5] = 8'h00;
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
			macByte(8'h80 | macGroups(0));          // command groups
			macByte(8'h80 | macGroups(READ_LEN));   // reply groups, per block
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

	// Wait for the drive to ask for the bus, then walk 2 -> 3 -> 1 and decode
	// `n` groups. Returns immediately after the last byte of the frame.
	task recvFrame;
		input integer n;
		integer w;
		begin
			setState(3'd2);
			w = 0;
			while (readData[7] !== 1'b0 && w < 200000) begin
				@(posedge clk); w = w + 1;
			end
			setState(3'd3);
			@(posedge clk); #1;
			setState(3'd1);
			getByte(sync);
			for (g = 0; g < n; g = g + 1) begin
				for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
				for (i = 0; i < 7; i = i + 1)
					rsp[g*7 + i] = {raw[i][6:0], raw[7][i]};
			end
			nDecoded = n * 7;
		end
	endtask

	// Whole-frame checks shared by every good data frame.
	task checkDataFrame;
		input [23:0] lba;
		input  [7:0] expBlks;
		input [511:0] label;
		begin
			sum = 0;
			for (i = 0; i < 539; i = i + 1) sum = sum + rsp[i];
			ok = (sum === 8'h00) && (rsp[0] === 8'h80) && (rsp[1] === expBlks) &&
			     (rsp[2] === 8'h00) && (rsp[3] === 8'h00) && (rsp[4] === 8'h00) &&
			     (rsp[5] === 8'h00);
			for (i = 6; i < 26; i = i + 1) if (rsp[i] !== 8'h00) ok = 1'b0;
			for (i = 0; i < 512; i = i + 1)
				if (rsp[26 + i] !== diskByte(lba, i)) ok = 1'b0;
			check(label, ok);
		end
	endtask

	initial begin
		_reset = 0; ca0 = 0; ca1 = 1; ca2 = 0;
		lstrb = 0; _enable = 0; writeData = 0; writeReq = 0;
		img_mounted = 0; img_size = 0; img_readonly = 0;
		sd_ack = 0; sd_buff_addr = 0; sd_buff_dout = 0; sd_buff_wr = 0;
		fetches = 0; serveDelay = 3;
		repeat (4) @(posedge clk); #1; _reset = 1;
		repeat (4) @(posedge clk);

		$display("tb_dcd_read");

		check("the ROM's own arithmetic makes a read frame 77 groups",
		      macGroups(READ_LEN) === 77);

		mount(64'd200000);            // needs 18 bits of block number

		// ---------------------------------------------------------------
		// One block, and the block number crosses the 16-bit seam.
		// ---------------------------------------------------------------
		fetches = 0;
		sendRead(8'd1, 24'd100000);
		recvFrame(77);
		check("a one-block read is 77 groups, 539 payload bytes", nDecoded === 539);
		check("exactly one sector was fetched", fetches === 1);
		check("the fetch used the full 24-bit block number",
		      fetched[0] === 32'd100000);
		checkDataFrame(24'd100000, 8'd1,
		               "the frame decodes: header, zero tags, 512 right bytes");

		// Called out on its own because it is the seam this project has been
		// caught by twice: truncating to 16 bits reads block 34464 instead.
		check("the data is block 100000's, not a truncated block's",
		      rsp[26] === diskByte(24'd100000, 0) &&
		      rsp[26] !== diskByte(24'd34464, 0));
		check("the checksum is the final slot of the final group",
		      nDecoded === 539);

		// ---------------------------------------------------------------
		// Three blocks: three frames, counting down, consecutive LBAs.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		fetches = 0;
		sendRead(8'd3, 24'd70000);

		okAll = 1'b1;
		recvFrame(77);
		checkDataFrame(24'd70000, 8'd3, "block 1 of 3: count reads 3");
		recvFrame(77);
		checkDataFrame(24'd70001, 8'd2, "block 2 of 3: count reads 2");
		recvFrame(77);
		checkDataFrame(24'd70002, 8'd1, "block 3 of 3: count reads 1");

		check("three separate fetches, one per frame", fetches === 3);
		check("the fetches walked consecutive blocks",
		      (fetched[0] === 32'd70000) && (fetched[1] === 32'd70001) &&
		      (fetched[2] === 32'd70002));

		// ---------------------------------------------------------------
		// A block past the end is answered with an error frame, not dropped
		// and not filled with rubbish.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		fetches = 0;
		sendRead(8'd1, 24'd200000);        // one past the last block
		recvFrame(1);
		check("an out-of-range read is answered with ONE group", nDecoded === 7);
		check("  ...carrying the read opcode", rsp[0] === 8'h80);
		check("  ...with bit 7 of the status set", rsp[2][7] === 1'b1);
		sum = 0;
		for (i = 0; i < 7; i = i + 1) sum = sum + rsp[i];
		check("  ...and it still checksums to zero", sum === 8'h00);
		check("  ...and nothing was fetched from the host", fetches === 0);

		// The drive must be usable again straight afterwards.
		setState(3'd2);
		repeat (4) @(posedge clk);
		fetches = 0;
		sendRead(8'd1, 24'd199999);        // the last valid block
		recvFrame(77);
		checkDataFrame(24'd199999, 8'd1, "the last block reads normally");

		// ---------------------------------------------------------------
		// A SLOW HOST MUST NOT PRODUCE A FAST WRONG ANSWER. The frame does not
		// reach its first data byte until 26 byte-times in, which is thousands
		// of clocks, so a drive that starts transmitting without waiting for
		// its fetch still gets the right bytes from any prompt host and only
		// fails when the card stalls. Make it stall: the buffer still holds the
		// PREVIOUS block, so serving late is detectable as serving stale.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		serveDelay = 6000;
		fetches = 0;
		sendRead(8'd1, 24'd123456);
		recvFrame(77);
		serveDelay = 3;
		checkDataFrame(24'd123456, 8'd1,
		               "a stalled host still yields the right sector, not a stale one");
		check("  ...and the stalled fetch did happen", fetches === 1);

		// ---------------------------------------------------------------
		// A zero-block read is not a command. It is dropped, like any opcode
		// we do not implement, rather than answered with an empty frame.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		fetches = 0;
		sendRead(8'd0, 24'd10);
		setState(3'd2);
		// Long enough for a fetch AND the /HSHK request that would follow it -
		// 200 clocks was not, and a mutant accepting a zero-block command
		// scored full marks because the reply had not started yet.
		repeat (20000) @(posedge clk); #1;
		check("a zero-block read is not answered", readData[7] === 1'b1);
		check("  ...and fetched nothing", fetches === 0);

		// ---------------------------------------------------------------
		// A RESET MID-TRANSFER MUST ABANDON THE REST OF THE READ. The Mac can
		// reset a drive it thinks is misbehaving at any point; if the command
		// layer carries on it will ask for the bus again and push a frame the
		// Mac is no longer expecting.
		// ---------------------------------------------------------------
		setState(3'd2);
		repeat (4) @(posedge clk);
		serveDelay = 3;
		fetches = 0;
		sendRead(8'd3, 24'd80000);
		recvFrame(77);
		checkDataFrame(24'd80000, 8'd3, "block 1 of 3 arrives normally");

		// Reset instead of taking block 2.
		setState(3'd4);
		repeat (16) @(posedge clk); #1;
		setState(3'd2);
		repeat (600) @(posedge clk); #1;
		check("a reset abandons the rest of the read",
		      readData[7] === 1'b1);
		check("  ...and no further sector was fetched", fetches === 1);

		// The command FSM only leaves C_IDLE for a READ, so this bench is the
		// only place the cstate field of the telemetry word is ever non-zero --
		// and a field that is only ever zero cannot be told from one that is
		// mis-indexed. C_SENDING is 5, the highest state it reaches.
		check("telemetry: the command FSM field reaches C_SENDING during a read",
		      dbgCstateSeen === 3'd5);

		$display("tb_dcd_read: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("FAILED");
		$finish;
	end

	initial begin
		#500000000;
		$display("tb_dcd_read: TIMEOUT");
		$finish;
	end

endmodule
