`timescale 1ns/1ps
//
// tb_dcd_write.v - MAC128K_PLAN.md Phase 5 gate for MultiBlock Write ($01),
// Write-Verify ($02) and the continued forms ($41, $42).
//
// End to end: a Mac model frames a real write command with a whole sector
// riding inside it, a block-device model catches the commit, and the one-group
// reply is decoded the way the Plus ROM decodes it. Both models are written
// from their own sources - $419600-$419E40 for the Mac, hps_io.sv for the
// slot - not from rtl/dcd.v.
//
// FIVE PROPERTIES CARRY THIS TEST, and every one of them is a thing the ROM
// says and nothing else does:
//
//   1. THE FIRST BLOCK RIDES WITH THE COMMAND. $4196D6 adds $14 to the
//      TRANSMIT byte count for opcodes 1 and 2, so the Mac ships 6 header
//      bytes, 20 tags and 512 data bytes in one 77-group frame. rxBuf holds
//      eight of those. If the link layer does not stream the rest into the
//      sector buffer there is no write path at all.
//   2. EACH BLOCK IS ITS OWN COMMAND. $419712 re-transmits per block for a
//      write where a read returns immediately, so the drive answers one group
//      and goes back to idle - it does NOT keep sending like a read.
//   3. THE REPLY OPCODE IS (COMMAND & $3F) | $80. $41975E masks with
//      `andi.b #$3F` before $419776's compare, so $41 -> $81 and $42 -> $82.
//      Answering $C1, or answering a write-verify $81, is error $30.
//   4. A CONTINUED WRITE CARRIES NO USABLE ADDRESS. The reply overwrote the
//      command block at $19C, and $41971C refreshes only the count byte at
//      $19D - so $19E-$1A0 hold the last reply's zero status and padding. The
//      drive has to advance the block number itself, and a drive that trusted
//      the wire would put every block of a multi-block write in block 0. That
//      is a silent, total data-loss bug, so it is asserted directly.
//   5. THE DATA STARTS AT FRAME BYTE 26. Six header bytes and twenty tags come
//      first and must NOT reach the medium. The tags here are a distinctive
//      pattern for exactly that reason.
//
module tb_dcd_write;

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

	dcd dut (
		.clk(clk), .cep(1'b1), .cen(1'b1), .turbo(1'b0),
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

	// A write ships 512 data bytes plus the 20 tag bytes $4196D6 adds to the
	// TRANSMIT count. 77 is never typed here; it falls out of macGroups.
	localparam integer WRITE_LEN = 512 + 20;

	// ------------------------------------------------------------------
	// The block-device model: catches commits, keeps the last few blocks,
	// and can also serve a read back so a round trip is provable.
	// ------------------------------------------------------------------
	localparam integer SLOTS = 8;
	reg  [23:0] slotLba [0:SLOTS-1];
	reg         slotUsed [0:SLOTS-1];
	reg   [7:0] slotData [0:SLOTS*512-1];

	integer commits;
	integer nextSlot;
	reg [23:0] lastCommitLba;
	// How long the host dawdles before acking. The write path must have
	// claimed /HSHK long before this expires, or the Mac's $419820 sense check
	// fails with error $20 - which is the whole reason txArm exists.
	integer serveDelay;

	integer m, slot;

	function integer findSlot;
		input [23:0] lba;
		integer s;
		begin
			findSlot = -1;
			for (s = 0; s < SLOTS; s = s + 1)
				if (slotUsed[s] && slotLba[s] === lba) findSlot = s;
		end
	endfunction

	always @(posedge clk) begin
		if (sd_wr && !sd_ack) begin
			repeat (serveDelay) @(posedge clk);
			sd_ack = 1'b1;
			@(posedge clk);
			slot = nextSlot;
			nextSlot = (nextSlot + 1) % SLOTS;
			slotLba[slot]  = sd_lba[23:0];
			slotUsed[slot] = 1'b1;
			for (m = 0; m < 256; m = m + 1) begin
				@(posedge clk); #1;
				sd_buff_addr = m[7:0];
				// q_a is registered on address_a, so the word is not on the
				// bus until the clock after the address. Sampling it on the
				// same edge reads the previous word and passes every
				// content test by one place - a trap this project has
				// already hit once on the read side.
				@(posedge clk); #1;
				slotData[slot*512 + m*2]     = sd_buff_din[7:0];
				slotData[slot*512 + m*2 + 1] = sd_buff_din[15:8];
			end
			@(posedge clk); #1;
			lastCommitLba = sd_lba[23:0];
			commits = commits + 1;
			sd_ack = 1'b0;
			while (sd_wr) @(posedge clk);
		end
		else if (sd_rd && !sd_ack) begin
			repeat (serveDelay) @(posedge clk);
			sd_ack = 1'b1;
			@(posedge clk);
			slot = findSlot(sd_lba[23:0]);
			for (m = 0; m < 256; m = m + 1) begin
				@(posedge clk); #1;
				sd_buff_addr = m[7:0];
				sd_buff_dout = (slot < 0)
				    ? 16'hDEAD
				    : {slotData[slot*512 + m*2 + 1], slotData[slot*512 + m*2]};
				sd_buff_wr   = 1'b1;
				@(posedge clk); #1;
				sd_buff_wr   = 1'b0;
			end
			@(posedge clk); #1;
			sd_ack = 1'b0;
			while (sd_rd) @(posedge clk);
		end
	end

	// ------------------------------------------------------------------
	// The Mac side
	// ------------------------------------------------------------------
	integer i, g, b;
	reg [7:0] frame [0:559];        // 539 payload bytes for a write frame
	reg [7:0] raw [0:7];
	reg [7:0] rsp [0:15];
	reg [7:0] sum;
	reg [7:0] sync;
	reg       ok;
	integer   hsWait;

	// Distinctive sector contents: differs across the two halves of a host
	// word, across offsets and across seeds, so a transposed byte lane or a
	// stale buffer shows up rather than matching by luck.
	function [7:0] dataByte;
		input integer seed;
		input integer k;
		begin
			dataByte = (k[7:0] + seed[7:0] * 8'h11) ^ (k[8] ? 8'h3C : 8'hC3);
		end
	endfunction

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
		input        ro;
		begin
			@(posedge clk); #1;
			img_size = blocks * 64'd512; img_readonly = ro; img_mounted = 1'b1;
			@(posedge clk); #1;
			img_mounted = 1'b0;
			repeat (2) @(posedge clk);
		end
	endtask

	// Build the 539 payload bytes of a write frame. `corrupt` flips one bit of
	// the checksum so a rejected frame can be tested with everything else the
	// same.
	task buildWrite;
		input  [7:0] op;
		input  [7:0] blocks;
		input [23:0] lba;
		input integer seed;
		input        corrupt;
		begin
			frame[0] = op;
			frame[1] = blocks;
			frame[2] = lba[23:16];
			frame[3] = lba[15:8];
			frame[4] = lba[7:0];
			frame[5] = 8'h00;
			// 20 tag bytes. Nothing may carry these onto the medium.
			for (i = 6; i < 26; i = i + 1) frame[i] = 8'hE0 + i[7:0];
			for (i = 0; i < 512; i = i + 1) frame[26 + i] = dataByte(seed, i);
			sum = 0;
			for (i = 0; i < 538; i = i + 1) sum = sum + frame[i];
			frame[538] = corrupt ? (8'd1 - sum) : -sum;
		end
	endtask

	// The command handshake, then the frame. `hoff` injects the Mac's own
	// hold-off in the middle of group 3: $419B5A drops ca0 after the group's
	// fourth transmitted byte, the Mac sends the rest of the group anyway,
	// adds one filler, releases and resyncs with a bare $AA, and carries on
	// with the NEXT group. Nothing is resent.
	task sendFrame;
		input hoff;
		begin
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
			macByte(8'h80 | macGroups(WRITE_LEN));  // 77 groups from the Mac
			macByte(8'h80 | macGroups(0));          // 1 group back
			for (g = 0; g < 77; g = g + 1) begin
				macByte(8'h80 |
				         frame[g*7+0][0]        | (frame[g*7+1][0] << 1) |
				        (frame[g*7+2][0] << 2)  | (frame[g*7+3][0] << 3) |
				        (frame[g*7+4][0] << 4)  | (frame[g*7+5][0] << 5) |
				        (frame[g*7+6][0] << 6));
				for (i = 0; i < 7; i = i + 1) begin
					if (hoff && g == 3 && i == 3) setState(3'd0);
					macByte(8'h80 | (frame[g*7+i] >> 1));
				end
				if (hoff && g == 3) begin
					macByte(8'h00);         // the filler at $419BBA
					setState(3'd1);         // ca0H at $419BD4
					macByte(8'hAA);         // the resync at $419BE6
				end
			end
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

	// Wait for the drive to ask for the bus, walk 2 -> 3 -> 1 and decode the
	// one reply group. Returns 0 if nothing came within the budget, which is
	// how "an unanswered command" is distinguished from "a bad answer".
	task recvReply;
		output answered;
		integer w;
		begin
			setState(3'd2);
			w = 0;
			while (readData[7] !== 1'b0 && w < 60000) begin
				@(posedge clk); w = w + 1;
			end
			if (readData[7] !== 1'b0) begin
				answered = 1'b0;
			end
			else begin
				setState(3'd3);
				@(posedge clk); #1;
				setState(3'd1);
				w = 0;
				while (!newByteReady && w < 400000) begin
					@(posedge clk); w = w + 1;
				end
				if (!newByteReady) answered = 1'b0;
				else begin
					sync = readData; #1;
					for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
					for (i = 0; i < 7; i = i + 1)
						rsp[i] = {raw[i][6:0], raw[7][i]};
					answered = 1'b1;
					setState(3'd3);
					repeat (4) @(posedge clk);
					setState(3'd2);
				end
			end
		end
	endtask

	reg answered;

	task checkReply;
		input [511:0] tag;
		input  [7:0]  expOp;
		input  [7:0]  expSeq;
		input         expErr;
		begin
			check({tag, " answered at all"}, answered === 1'b1);
			check({tag, " reply is one group behind an $AA sync"}, sync === 8'hAA);
			check({tag, " reply opcode"}, rsp[0] === expOp);
			check({tag, " reply echoes the block count"}, rsp[1] === expSeq);
			check({tag, " status error bit"}, rsp[2][7] === expErr);
			sum = 0;
			for (i = 0; i < 7; i = i + 1) sum = sum + rsp[i];
			check({tag, " reply checksums to zero"}, sum === 8'h00);
		end
	endtask

	task checkSector;
		input [511:0] tag;
		input  [23:0] lba;
		input integer seed;
		integer s;
		begin
			s = findSlot(lba);
			check({tag, " reached the medium at the right block"}, s >= 0);
			ok = 1'b1;
			if (s >= 0)
				for (i = 0; i < 512; i = i + 1)
					if (slotData[s*512 + i] !== dataByte(seed, i)) ok = 1'b0;
			check({tag, " is byte-exact, all 512"}, ok);
		end
	endtask

	initial begin
		_reset = 0; ca0 = 0; ca1 = 1; ca2 = 0;
		lstrb = 0; _enable = 0; writeData = 0; writeReq = 0;
		img_mounted = 0; img_size = 0; img_readonly = 0;
		sd_ack = 0; sd_buff_addr = 0; sd_buff_dout = 0; sd_buff_wr = 0;
		commits = 0; nextSlot = 0; lastCommitLba = 0; serveDelay = 2;
		for (i = 0; i < SLOTS; i = i + 1) slotUsed[i] = 1'b0;

		repeat (4) @(posedge clk); #1; _reset = 1;
		repeat (4) @(posedge clk);
		mount(64'd70000, 1'b0);          // 35 MB, so a 24-bit block number bites

		$display("tb_dcd_write");

		// ---------------------------------------------------------------
		// 1. A single-block MultiBlock Write
		// ---------------------------------------------------------------
		buildWrite(8'h01, 8'd1, 24'd100, 1, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("single write:", 8'h81, 8'd1, 1'b0);
		check("single write: exactly one commit", commits === 1);
		checkSector("single write:", 24'd100, 1);

		// The 20 tag bytes and the six header bytes are NOT disk data. If the
		// offset were wrong by even one byte the sector would still be 512
		// bytes long and would still checksum, so this is checked directly.
		slot = findSlot(24'd100);
		check("single write: the sector does not start with the command block",
		      slotData[slot*512] !== 8'h01);
		check("single write: nor with a tag byte",
		      slotData[slot*512] !== 8'hE6);
		check("single write: byte 0 is frame byte 26",
		      slotData[slot*512] === frame[26]);
		check("single write: byte 511 is frame byte 537",
		      slotData[slot*512 + 511] === frame[537]);

		// ---------------------------------------------------------------
		// 2. Write-Verify is a different opcode and a different reply
		// ---------------------------------------------------------------
		// $419776 subtracts $80 and compares against the opcode it sent,
		// masked to six bits. Answering a $02 with $81 is error $30, and it is
		// exactly the kind of thing an implementation copied from a write-only
		// reference gets wrong.
		buildWrite(8'h02, 8'd1, 24'd101, 2, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("write-verify:", 8'h82, 8'd1, 1'b0);
		checkSector("write-verify:", 24'd101, 2);

		// ---------------------------------------------------------------
		// 3. A TWO-BLOCK WRITE, and the address the second block does not have
		// ---------------------------------------------------------------
		// The Mac sends $01 with a count of 2 and the real address, then $41
		// with a count of 1 and THREE ZERO ADDRESS BYTES, because the first
		// reply overwrote them. The second block must land at lba+1.
		buildWrite(8'h01, 8'd2, 24'd70000 - 24'd10, 3, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("multi block 1:", 8'h81, 8'd2, 1'b0);
		checkSector("multi block 1:", 24'd70000 - 24'd10, 3);

		buildWrite(8'h41, 8'd1, 24'd0, 4, 1'b0);   // address bytes are zeros
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("multi block 2:", 8'h81, 8'd1, 1'b0);
		check("continued write is answered $81, never $C1", rsp[0] !== 8'hC1);
		checkSector("multi block 2:", 24'd70000 - 24'd9, 4);
		check("continued write did NOT go to block 0", findSlot(24'd0) < 0);
		check("24-bit block number survives above 65535",
		      lastCommitLba === 24'd69991);

		// A continued WRITE-VERIFY is $42 and answers $82.
		buildWrite(8'h02, 8'd2, 24'd200, 5, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("verify chain 1:", 8'h82, 8'd2, 1'b0);
		buildWrite(8'h42, 8'd1, 24'd0, 6, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("verify chain 2:", 8'h82, 8'd1, 1'b0);
		checkSector("verify chain 2:", 24'd201, 6);

		// ---------------------------------------------------------------
		// 4. A ROUND TRIP: read back what was written
		// ---------------------------------------------------------------
		// Everything above trusts the block model's view. This closes the loop
		// through the drive's own read path, which is the only check that
		// would survive both halves being wrong in the same direction.
		buildWrite(8'h01, 8'd1, 24'd300, 7, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("round trip write:", 8'h81, 8'd1, 1'b0);

		// A one-block read of block 300, framed the way $419712 does it.
		frame[0] = 8'h00; frame[1] = 8'd1;
		frame[2] = 8'd0;  frame[3] = 8'd1; frame[4] = 8'd44;   // 300
		frame[5] = 8'h00;
		sum = 0;
		for (i = 0; i < 6; i = i + 1) sum = sum + frame[i];
		frame[6] = -sum;
		setState(3'd2);
		@(posedge clk); #1;
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h80 | macGroups(0));
		macByte(8'h80 | macGroups(WRITE_LEN));
		macByte(8'h80 |  frame[0][0]       | (frame[1][0] << 1) |
		                (frame[2][0] << 2) | (frame[3][0] << 3) |
		                (frame[4][0] << 4) | (frame[5][0] << 5) |
		                (frame[6][0] << 6));
		for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (frame[i] >> 1));
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b1 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd2);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 60000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd3);
		@(posedge clk); #1;
		setState(3'd1);
		getByte(sync);
		ok = 1'b1;
		for (g = 0; g < 77; g = g + 1) begin
			for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
			for (i = 0; i < 7; i = i + 1) begin
				b = g*7 + i;
				if (b >= 26 && b < 538)
					if ({raw[i][6:0], raw[7][i]} !== dataByte(7, b - 26)) ok = 1'b0;
			end
		end
		check("round trip: the read gives back exactly what was written", ok);
		setState(3'd3);
		repeat (4) @(posedge clk);
		setState(3'd2);

		// ---------------------------------------------------------------
		// 5. A HOLD-OFF IN THE MIDDLE OF THE WRITE FRAME
		// ---------------------------------------------------------------
		// The Mac drops ca0 mid-group whenever the SCC has an interrupt
		// pending, and on a 77-group write that is the common case on a
		// machine with AppleTalk up. A single lost group is 7 bytes of
		// somebody's file.
		commits = 0;
		buildWrite(8'h01, 8'd1, 24'd400, 8, 1'b0);
		sendFrame(1'b1);
		recvReply(answered);
		checkReply("hold-off write:", 8'h81, 8'd1, 1'b0);
		checkSector("hold-off write:", 24'd400, 8);
		check("hold-off write: still exactly one commit", commits === 1);

		// ---------------------------------------------------------------
		// 6. A SLOW CARD. The Mac's $419820 reads the sense line as the first
		//    instruction of its receive routine, with no retry budget, so the
		//    drive must claim /HSHK on accepting the command rather than when
		//    the commit finishes. A drive that waited would fail every write
		//    on any storage slower than a few microseconds.
		// ---------------------------------------------------------------
		serveDelay = 20000;
		commits = 0;
		buildWrite(8'h01, 8'd1, 24'd500, 9, 1'b0);
		sendFrame(1'b0);
		setState(3'd2);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 200) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		check("slow card: /HSHK is claimed immediately, not after the commit",
		      readData[7] === 1'b0);
		check("  ...and the commit really had not finished", commits === 0);
		setState(3'd3);
		@(posedge clk); #1;
		setState(3'd1);
		getByte(sync);
		for (i = 0; i < 8; i = i + 1) getByte(raw[i]);
		for (i = 0; i < 7; i = i + 1) rsp[i] = {raw[i][6:0], raw[7][i]};
		check("slow card: the reply arrives once the commit lands",
		      (sync === 8'hAA) && (rsp[0] === 8'h81) && (rsp[2][7] === 1'b0));
		check("slow card: and it did commit", commits === 1);
		checkSector("slow card:", 24'd500, 9);
		setState(3'd3);
		repeat (4) @(posedge clk);
		setState(3'd2);
		serveDelay = 2;

		// ---------------------------------------------------------------
		// 7. A BLOCK PAST THE END OF THE IMAGE
		// ---------------------------------------------------------------
		commits = 0;
		buildWrite(8'h01, 8'd1, 24'd70000, 10, 1'b0);   // == capacity
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("out of range:", 8'h81, 8'd1, 1'b1);
		check("out of range: nothing was committed", commits === 0);

		// ---------------------------------------------------------------
		// 8. A LOCKED IMAGE
		// ---------------------------------------------------------------
		// Refusing here rather than discarding is the point: a silently
		// dropped write reports success for data that was never stored.
		mount(64'd70000, 1'b1);
		commits = 0;
		buildWrite(8'h01, 8'd1, 24'd600, 11, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("locked image:", 8'h81, 8'd1, 1'b1);
		check("locked image: nothing was committed", commits === 0);
		mount(64'd70000, 1'b0);

		// ---------------------------------------------------------------
		// 9. A CORRUPTED FRAME IS NOT COMMITTED AND NOT ANSWERED
		// ---------------------------------------------------------------
		// The checksum only arrives at frame byte 538, long after the sector
		// has been streamed into the buffer, so the buffer IS dirty by then.
		// What must not happen is a commit.
		commits = 0;
		buildWrite(8'h01, 8'd1, 24'd700, 12, 1'b1);     // deliberately wrong CHK
		sendFrame(1'b0);
		recvReply(answered);
		check("bad checksum: the command is not answered", answered === 1'b0);
		check("bad checksum: nothing was committed", commits === 0);
		setState(3'd2);
		repeat (8) @(posedge clk);

		// ...and the drive is still usable afterwards.
		commits = 0;
		buildWrite(8'h01, 8'd1, 24'd701, 13, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		checkReply("after a bad frame:", 8'h81, 8'd1, 1'b0);
		checkSector("after a bad frame:", 24'd701, 13);

		// ---------------------------------------------------------------
		// 10. A CONTINUED WRITE WITH NOTHING TO CONTINUE
		// ---------------------------------------------------------------
		// A $41 whose address bytes are zeros and which follows a Status
		// rather than a write has no address at all. Serving it would write
		// block 0 - the boot block - with whatever arrived.
		frame[0] = 8'h03; frame[1] = 8'd1;
		frame[2] = 0; frame[3] = 0; frame[4] = 0; frame[5] = 0;
		sum = 0;
		for (i = 0; i < 6; i = i + 1) sum = sum + frame[i];
		frame[6] = -sum;
		setState(3'd2);
		@(posedge clk); #1;
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h80 | macGroups(0));
		macByte(8'h81);                    // ask for one group back
		macByte(8'h80 |  frame[0][0]       | (frame[1][0] << 1) |
		                (frame[2][0] << 2) | (frame[3][0] << 3) |
		                (frame[4][0] << 4) | (frame[5][0] << 5) |
		                (frame[6][0] << 6));
		for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (frame[i] >> 1));
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b1 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd2);
		recvReply(answered);              // drains the truncated Status reply
		repeat (32) @(posedge clk);
		setState(3'd2);
		repeat (32) @(posedge clk);

		commits = 0;
		buildWrite(8'h41, 8'd1, 24'd0, 14, 1'b0);
		sendFrame(1'b0);
		recvReply(answered);
		check("orphan continued write is not answered", answered === 1'b0);
		check("orphan continued write does not touch block 0", commits === 0);

		// ---------------------------------------------------------------
		// 11. A SHORT WRITE FRAME
		// ---------------------------------------------------------------
		// A write command whose frame stops before the sector is complete
		// leaves the buffer holding a mixture of this command and whatever was
		// there before - which, after the reads above, is a different block of
		// the user's disk. Committing that is silent corruption of data the
		// Mac never sent, so a write is only accepted once frame byte 537 has
		// actually arrived.
		commits = 0;
		frame[0] = 8'h01; frame[1] = 8'd1;
		frame[2] = 0; frame[3] = 8'd3; frame[4] = 8'd32;    // block 800
		frame[5] = 8'h00;
		for (i = 6; i < 69; i = i + 1) frame[i] = 8'h5A;
		sum = 0;
		for (i = 0; i < 69; i = i + 1) sum = sum + frame[i];
		frame[69] = -sum;                                    // 70 bytes = 10 groups
		setState(3'd2);
		@(posedge clk); #1;
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h8A);                    // ten groups, not seventy-seven
		macByte(8'h81);
		for (g = 0; g < 10; g = g + 1) begin
			macByte(8'h80 |
			         frame[g*7+0][0]        | (frame[g*7+1][0] << 1) |
			        (frame[g*7+2][0] << 2)  | (frame[g*7+3][0] << 3) |
			        (frame[g*7+4][0] << 4)  | (frame[g*7+5][0] << 5) |
			        (frame[g*7+6][0] << 6));
			for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (frame[g*7+i] >> 1));
		end
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b1 && hsWait < 8000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		setState(3'd2);
		recvReply(answered);
		check("short write frame is not answered", answered === 1'b0);
		check("short write frame commits nothing", commits === 0);
		check("  ...and does not reach block 800", findSlot(24'd800) < 0);
		setState(3'd2);
		repeat (8) @(posedge clk);

		$display("tb_dcd_write: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("FAILED");
		$finish;
	end

	initial begin
		#600000000;
		$display("tb_dcd_write: TIMEOUT");
		$finish;
	end

endmodule
