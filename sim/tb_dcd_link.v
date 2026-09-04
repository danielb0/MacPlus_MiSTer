`timescale 1ns/1ps
//
// tb_dcd_link.v - MAC128K_PLAN.md Phase 5 gate for rtl/dcd_link.v.
//
// The link layer is the part of DCD that cannot be got right by inspection:
// two directions with DIFFERENT byte orders, a bit-packing nobody would guess,
// a checksum stated in no document, and a hold-off that has to rewind rather
// than continue. Every one of those fails silently - a wrong LSB packing still
// produces plausible bytes, and a checksum that never rejects still passes
// every good-path test.
//
// Four properties matter more than the individual assertions:
//
//   1. THE ID STATES. States 7, 6 and 5 must sense 1, 1, 0. This is the first
//      thing the Mac does and nothing else runs if it is wrong. Three
//      independent sources agree on those levels (the May state table, the
//      IWM_Interface_PAL decode, and the Plus ROM's probe at $418630), so
//      there is no excuse for getting it wrong and no way to notice from a
//      later test - a bad ID just looks like "no hard disk".
//
//   2. THE FIGURE 1 GOLDEN VECTOR. The specification works a full group by
//      hand: data $31..$37 encode to $98 $99 $99 $9A $9A $9B $9B with an LSB
//      byte of $D5, and it gives the Mac-to-DCD order explicitly as
//      "$D5 $98 $99 $99 $9A $9A $9B $9B" - LSB byte FIRST. That is exactly
//      this module's receive direction, so the vector can be asserted
//      verbatim rather than recomputed from my own reading of the prose.
//      A decoder that packs the LSB bits in the wrong order fails here and
//      essentially nowhere else.
//
//   3. THE CHECKSUM MUST REJECT. Figure 1's own bytes sum to $72, not zero,
//      so the same vector that proves the decoder proves the checksum
//      actually fires. A checksum that always passes is the classic silent
//      failure, and it would not show up until real data corrupted.
//
//   4. HOLD-OFF REWINDS, IT DOES NOT CONTINUE. The interrupted group is
//      resent from its start, behind a fresh sync, and is excluded from the
//      checksum. Both the specification and the ROM's resync path are
//      explicit. An implementation that resumes mid-group looks fine until an
//      SCC interrupt lands during a transfer, which on real hardware is
//      often.
//
module tb_dcd_link;

	reg         clk = 0;
	reg         _reset;
	reg         ca0, ca1, ca2, lstrb, _enable;
	reg  [7:0]  writeData;
	reg         writeReq;
	reg         present;
	reg         txReq;
	reg  [9:0]  txLen;

	wire [7:0]  readData;
	wire        newByteReady;
	wire [63:0] rxBuf;
	wire [3:0]  rxLen;
	wire        rxValid, rxBad;
	wire [9:0]  txAddr;
	wire        txBusy;

	integer pass = 0;
	integer fail = 0;

	// payload the command layer would supply, addressed by txAddr
	reg [7:0] payload [0:63];
	wire [7:0] txData = payload[txAddr[5:0]];

	dcd_link dut (
		.clk(clk), .cep(1'b1), .cen(1'b1),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .lstrb(lstrb), ._enable(_enable),
		.writeData(writeData), .writeReq(writeReq),
		.readData(readData), .newByteReady(newByteReady),
		.present(present),
		.rxBuf(rxBuf), .rxLen(rxLen), .rxValid(rxValid), .rxBad(rxBad),
		.txReq(txReq), .txData(txData), .txAddr(txAddr), .txLen(txLen),
		.txBusy(txBusy)
	);

	always #10 clk = ~clk;   // 50 MHz-ish; only the enables matter here

	task check;
		input [511:0] name;
		input cond;
		begin
			if (cond) begin
				pass = pass + 1;
				$display("  PASS  %0s", name);
			end
			else begin
				fail = fail + 1;
				$display("  FAIL  %0s", name);
			end
		end
	endtask

	// The Mac changes ONE phase line at a time, but the settled value is all
	// that means anything, so the bench sets the state directly and lets the
	// DUT see whatever intermediate it likes.
	task setState;
		input [2:0] s;
		begin
			@(posedge clk); #1;
			ca0 = s[0]; ca1 = s[1]; ca2 = s[2];
		end
	endtask

	// One byte from the Mac, as the IWM would hand it over.
	task macByte;
		input [7:0] b;
		begin
			@(posedge clk); #1;
			writeData = b;
			writeReq  = 1'b1;
			@(posedge clk); #1;
			writeReq  = 1'b0;
		end
	endtask

	// Collect the next transmitted byte.
	task getByte;
		output [7:0] b;
		begin
			@(posedge clk);
			while (!newByteReady) @(posedge clk);
			b = readData;
			#1;
		end
	endtask

	// rxValid / rxBad are ONE-CLOCK pulses. Sampling them with a plain
	// @(posedge clk); #1 after the last byte reads the clock AFTER the pulse
	// and always sees zero - the bench's own version of the timing trap this
	// project already records for stimulus. Latch them instead, and clear the
	// latches before each frame.
	reg sawValid, sawBad;
	reg [3:0] capLen;
	always @(posedge clk) begin
		if (rxValid) begin sawValid <= 1'b1; capLen <= rxLen; end
		if (rxBad)   begin sawBad   <= 1'b1; capLen <= rxLen; end
	end
	task armRx;
		begin
			@(posedge clk); #1;
			sawValid = 1'b0; sawBad = 1'b0; capLen = 4'd0;
		end
	endtask

	integer i;
	reg [7:0] got [0:15];
	reg [7:0] sum;
	reg [7:0] chk;
	reg [7:0] expTx [0:7];
	reg ok;

	initial begin
		_reset = 0; ca0 = 0; ca1 = 1; ca2 = 0;  // state 2, idle
		lstrb = 0; _enable = 0; writeData = 0; writeReq = 0;
		present = 1; txReq = 0; txLen = 0;
		repeat (4) @(posedge clk);
		#1; _reset = 1;
		repeat (4) @(posedge clk);

		$display("tb_dcd_link");

		// ---------------------------------------------------------------
		// 1. The identification states
		// ---------------------------------------------------------------
		setState(3'd7); @(posedge clk); #1;
		check("state 7 senses 1 (drive connected)", readData[7] === 1'b1);
		setState(3'd6); @(posedge clk); #1;
		check("state 6 senses 1", readData[7] === 1'b1);
		setState(3'd5); @(posedge clk); #1;
		check("state 5 senses 0 (this is a DCD, not a Sony)", readData[7] === 1'b0);

		// With no image mounted every ID state must read 1 - the phantom
		// states. State 5 is the one that matters: a 0 there would announce a
		// DCD that is not present.
		#1; present = 0;
		setState(3'd7); @(posedge clk); #1;
		check("absent: state 7 senses 1", readData[7] === 1'b1);
		setState(3'd5); @(posedge clk); #1;
		check("absent: state 5 senses 1 (phantom, looks like a Sony)", readData[7] === 1'b1);
		#1; present = 1;

		// /HSHK is idle-HIGH. The ROM errors $10 if it is low at idle, so
		// this is not cosmetic.
		setState(3'd2); @(posedge clk); #1;
		check("idle state 2: /HSHK de-asserted (sense 1)", readData[7] === 1'b1);

		// ---------------------------------------------------------------
		// 2. Figure 1, verbatim - decode direction
		// ---------------------------------------------------------------
		// "$D5 $98 $99 $99 $9A $9A $9B $9B" is the specification's own
		// Mac-to-DCD byte order for data $31..$37.
		armRx;
		setState(3'd1);
		macByte(8'hAA);        // sync
		macByte(8'h81);        // $80 | 1 group total
		macByte(8'h81);        // groups expected back
		macByte(8'hD5);        // LSB byte FIRST on this direction
		macByte(8'h98); macByte(8'h99); macByte(8'h99);
		macByte(8'h9A); macByte(8'h9A); macByte(8'h9B); macByte(8'h9B);
		@(posedge clk); #1;

		ok = 1;
		for (i = 0; i < 7; i = i + 1)
			if (rxBuf[i*8 +: 8] !== (8'h31 + i[7:0])) ok = 0;
		check("Figure 1 decodes to $31..$37", ok);
		check("Figure 1 group yields 7 payload bytes", capLen === 4'd7);

		// Figure 1's bytes sum to $72, so this group MUST be rejected. Same
		// vector, second property: the checksum actually fires.
		check("Figure 1 checksum rejected (sums to $72, not 0)", sawBad === 1'b1);
		check("Figure 1 does not report valid", sawValid !== 1'b1);

		// ---------------------------------------------------------------
		// 3. A well-formed group is accepted
		// ---------------------------------------------------------------
		// Six payload bytes plus a checksum chosen so the whole group sums to
		// zero, encoded here with the documented formula.
		sum = 0;
		for (i = 0; i < 6; i = i + 1) begin
			payload[i] = 8'h10 + i[7:0];
			sum = sum + payload[i];
		end
		payload[6] = -sum;

		armRx;
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h81);
		macByte(8'h81);
		// LSB byte first: bit 6 belongs to payload[0], bit 0 to payload[6].
		macByte(8'h80 | (payload[0][0] << 6) | (payload[1][0] << 5) |
		                (payload[2][0] << 4) | (payload[3][0] << 3) |
		                (payload[4][0] << 2) | (payload[5][0] << 1) |
		                 payload[6][0]);
		for (i = 0; i < 7; i = i + 1)
			macByte(8'h80 | (payload[i] >> 1));
		@(posedge clk); #1;

		check("well-formed group reports valid", sawValid === 1'b1);
		check("well-formed group does not report bad", sawBad !== 1'b1);
		ok = 1;
		for (i = 0; i < 7; i = i + 1)
			if (rxBuf[i*8 +: 8] !== payload[i]) ok = 0;
		check("well-formed group decodes to the payload", ok);

		// A single corrupted byte must be caught.
		armRx;
		setState(3'd1);
		macByte(8'hAA); macByte(8'h81); macByte(8'h81);
		macByte(8'h80);
		for (i = 0; i < 7; i = i + 1)
			macByte((i == 3) ? 8'h80 | ((payload[i] ^ 8'h02) >> 1)
			                 : 8'h80 | (payload[i] >> 1));
		@(posedge clk); #1;
		check("corrupted byte is rejected", sawBad === 1'b1);

		// ---------------------------------------------------------------
		// 3b. A TWO-GROUP frame
		// ---------------------------------------------------------------
		// Every frame above is a single group, and a single group hides an
		// off-by-one in the group counter completely - which is exactly the
		// bug this test was written to catch. The count byte is
		// $80 | TOTAL groups in the transmission (the drive firmware masks it
		// with $7F and uses it directly as a `djnz` loop count), so two
		// groups is $82. On a real command the Mac computes it as
		// dataGroups + $81, the +1 being the group the command itself rides
		// in - which is why a read, carrying no data, sends $81.
		sum = 0;
		for (i = 0; i < 13; i = i + 1) begin
			payload[i] = 8'h60 + i[7:0];
			sum = sum + payload[i];
		end
		payload[13] = -sum;              // 14 bytes = exactly two groups

		armRx;
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h82);                  // $80 | 2 groups
		macByte(8'h82);
		for (i = 0; i < 14; i = i + 7) begin
			macByte(8'h80 | (payload[i+0][0] << 6) | (payload[i+1][0] << 5) |
			                (payload[i+2][0] << 4) | (payload[i+3][0] << 3) |
			                (payload[i+4][0] << 2) | (payload[i+5][0] << 1) |
			                 payload[i+6][0]);
			macByte(8'h80 | (payload[i+0] >> 1)); macByte(8'h80 | (payload[i+1] >> 1));
			macByte(8'h80 | (payload[i+2] >> 1)); macByte(8'h80 | (payload[i+3] >> 1));
			macByte(8'h80 | (payload[i+4] >> 1)); macByte(8'h80 | (payload[i+5] >> 1));
			macByte(8'h80 | (payload[i+6] >> 1));
		end
		@(posedge clk); #1;
		check("two-group frame reports valid", sawValid === 1'b1);
		check("two-group frame does not report bad", sawBad !== 1'b1);
		// rxBuf only holds the first 8 bytes; that is enough to prove the
		// second group was not dropped or the first re-decoded.
		ok = 1;
		for (i = 0; i < 8; i = i + 1)
			if (rxBuf[i*8 +: 8] !== payload[i]) ok = 0;
		check("two-group frame decodes both groups in order", ok);

		// ---------------------------------------------------------------
		// 4. Transmit: sync, then 7 data and the LSB byte LAST
		// ---------------------------------------------------------------
		sum = 0;
		for (i = 0; i < 6; i = i + 1) begin
			payload[i] = 8'h41 + i[7:0];
			sum = sum + payload[i];
		end
		chk = -sum;                       // the module must append exactly this

		expTx[7] = 8'h80;
		for (i = 0; i < 6; i = i + 1) begin
			expTx[i] = 8'h80 | (payload[i] >> 1);
			expTx[7] = expTx[7] | (payload[i][0] << (6 - i));
		end
		expTx[6] = 8'h80 | (chk >> 1);
		expTx[7] = expTx[7] | chk[0];

		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd6;                    // payload only; the module adds CHK
		txReq = 1'b1;
		@(posedge clk); #1;
		txReq = 1'b0;

		// The drive asserts /HSHK; the Mac notices in state 3 and moves to 1.
		repeat (4) @(posedge clk); #1;
		check("drive asserts /HSHK when it wants to transmit", readData[7] === 1'b0);
		setState(3'd3);
		@(posedge clk); #1;
		check("state 3: /HSHK still asserted for the Mac to sense", readData[7] === 1'b0);
		setState(3'd1);

		getByte(got[0]);
		check("first transmitted byte is the $AA sync", got[0] === 8'hAA);
		for (i = 0; i < 8; i = i + 1) getByte(got[i]);

		ok = 1;
		for (i = 0; i < 8; i = i + 1)
			if (got[i] !== expTx[i]) ok = 0;
		check("transmitted group matches the documented encoding", ok);
		check("LSB byte is sent LAST on drive->Mac", got[7] === expTx[7]);
		check("every transmitted byte has its MSB set",
		      got[0][7] & got[1][7] & got[2][7] & got[3][7] &
		      got[4][7] & got[5][7] & got[6][7] & got[7][7]);
		check("checksum byte is -(sum of payload)", got[6] === (8'h80 | (chk >> 1)));

		// /HSHK must go back high so the Mac's end-of-transmission spin ends.
		@(posedge clk);
		while (txBusy) @(posedge clk);
		setState(3'd3);
		@(posedge clk); #1;
		check("/HSHK released at end of transmission", readData[7] === 1'b1);

		// ---------------------------------------------------------------
		// 5. Hold-off rewinds to the start of the group
		// ---------------------------------------------------------------
		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd6;
		txReq = 1'b1;
		@(posedge clk); #1;
		txReq = 1'b0;
		setState(3'd1);
		getByte(got[0]);                  // sync
		getByte(got[1]);                  // first data byte of the group
		check("hold-off test: group started", got[1] === expTx[0]);

		setState(3'd0);                   // HOFF asserted mid-group
		repeat (8) @(posedge clk);
		setState(3'd1);                   // release

		getByte(got[2]);
		check("hold-off: a FRESH sync is sent on resume", got[2] === 8'hAA);
		getByte(got[3]);
		check("hold-off: the interrupted group RESTARTS, not continues",
		      got[3] === expTx[0]);
		for (i = 1; i < 8; i = i + 1) getByte(got[i+3]);
		ok = 1;
		for (i = 1; i < 8; i = i + 1)
			if (got[i+3] !== expTx[i]) ok = 0;
		check("hold-off: the resent group is byte-identical and checksums the same", ok);

		// ---------------------------------------------------------------
		// 6. State 4 is RESET
		// ---------------------------------------------------------------
		// RESET has to be asserted against a transfer that is actually
		// RUNNING. Asserting it from idle asserts nothing - txBusy is already
		// 0 and /HSHK already high - and a mutation removing the state-4 case
		// entirely then still passes. (It did; that is why this is written
		// this way.)
		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd6;
		txReq = 1'b1;
		@(posedge clk); #1;
		txReq = 1'b0;
		setState(3'd1);
		getByte(got[0]);
		getByte(got[1]);
		check("RESET precondition: a transfer is in flight", txBusy === 1'b1);

		setState(3'd4);
		repeat (4) @(posedge clk); #1;
		check("state 4 (RESET) drops the transfer in flight", txBusy === 1'b0);
		setState(3'd2);
		@(posedge clk); #1;
		check("after RESET /HSHK is idle-high again", readData[7] === 1'b1);

		// And a RESET landing mid-frame must not leave the receiver part-way
		// through a group: the next command has to be decoded from scratch.
		armRx;
		setState(3'd1);
		macByte(8'hAA); macByte(8'h81); macByte(8'h81);
		macByte(8'h80 | (payload[0][0] << 6) | (payload[1][0] << 5) |
		                (payload[2][0] << 4) | (payload[3][0] << 3) |
		                (payload[4][0] << 2) | (payload[5][0] << 1) | chk[0]);
		for (i = 0; i < 6; i = i + 1) macByte(8'h80 | (payload[i] >> 1));
		macByte(8'h80 | (chk >> 1));
		@(posedge clk); #1;
		check("receiver still frames correctly after a RESET", sawValid === 1'b1);

		$display("tb_dcd_link: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("FAILED");
		$finish;
	end

	initial begin
		#8000000;
		$display("tb_dcd_link: TIMEOUT");
		$finish;
	end

endmodule
