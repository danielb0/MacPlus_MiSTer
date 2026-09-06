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
//   2. THE LSB BIT ORDER, AND FIGURE 1 CANNOT TEST IT. The specification
//      works a full group by hand - data $31..$37 encode to
//      $98 $99 $99 $9A $9A $9B $9B behind an LSB byte of $D5 - and this bench
//      used to claim that vector caught a reversed packing. IT DOES NOT.
//      $31..$37 have LSBs 1,0,1,0,1,0,1, which is a PALINDROME: the LSB byte
//      is $D5 under either order. Nor can any loopback catch it, because a
//      reversed packing is self-consistent, and nor can the checksum, because
//      permuting which of seven bytes each +1 lands on leaves their sum alone.
//      The RTL was reversed for a fortnight behind a green bench because of
//      exactly this. The discriminating vector below is the Status command the
//      Plus ROM actually builds, byte for byte off $419D12's `moveq #1,d3`,
//      and it decodes to two different payloads under the two orders.
//
//   3. THE CHECKSUM MUST REJECT. Figure 1's own bytes sum to $72, not zero,
//      so the same vector still proves the checksum actually fires. A checksum
//      that always passes is the classic silent failure, and it would not show
//      up until real data corrupted.
//
//   4. HOLD-OFF IS THE SAME IN BOTH DIRECTIONS: the interrupted group is
//      FINISHED and the NEXT one follows. This header said the opposite until
//      2026-09-05, and so did test 5, and so does the RTL - all three from the
//      same misreading of 1.2a pages 4-5, which is why the bench could not
//      catch it.
//
//      Drive to Mac: $41991C asserts HOFF only after four bytes of the group
//      are already read, $419926-$419964 keep polling for the remaining four,
//      and $41997A's `subq.w #1,d7` is the decrement the skipped `dbne` would
//      have done - so nothing is backed up and $419998 goes on to the NEXT
//      group with the finished one still in the checksum. Mac to drive is the
//      same shape at $419B5A/$419BC8. The earlier reading of $419974 as
//      "backs the group counter up" was wrong in exactly the way the transmit
//      side had already been corrected once.
//
//      Three independent sources agree, and the 1.2a prose is the odd one out:
//      the ROM, the HD20's own firmware (L1f4c-L1fac, which tests P2.7 only
//      after the LSB byte), and TashTwenty's XSuspend ("Resume transmission
//      after interrupted group"). The March-85 timing figure agrees too, in
//      its own words at t3. A transmitter that rewinds, or a receiver that
//      ignored bytes arriving in state 0, loses a group the first time an SCC
//      interrupt lands - and on hardware that is a stall and then a bomb,
//      reproducible on demand by moving the mouse during a transfer.
//
module tb_dcd_link;

	reg         clk = 0;
	reg         _reset;
	reg         ca0, ca1, ca2, lstrb, _enable;
	reg  [7:0]  writeData;
	reg         writeReq;
	reg         present;
	reg         txArm;
	reg         txReq;
	reg  [9:0]  txLen;

	wire [7:0]  readData;
	wire        newByteReady;
	wire [63:0] rxBuf;
	wire [3:0]  rxLen;
	wire        rxValid, rxBad;
	wire [6:0]  rxRspGroups;
	wire        rxStb;
	wire [7:0]  rxStbData;
	wire [9:0]  rxStbAddr;
	wire [9:0]  txAddr;
	wire        txBusy;
	wire        txAbort;

	// txAbort is a ONE-CLOCK pulse, so it has to be latched exactly as rxValid
	// and rxBad are - sampling it with a plain @(posedge clk); #1 reads the
	// clock after the pulse and always sees zero.
	reg         sawAbort;
	always @(posedge clk) if (txAbort) sawAbort <= 1'b1;

	// Everything the payload stream hands up, so a frame longer than rxBuf can
	// be checked end to end. 600 covers a write's 538 payload bytes.
	reg  [7:0] streamed [0:599];
	integer    streamCount = 0;
	always @(posedge clk)
		if (rxStb) begin
			if (rxStbAddr < 600) streamed[rxStbAddr] = rxStbData;
			streamCount = streamCount + 1;
		end

	integer pass = 0;
	integer fail = 0;

	// payload the command layer would supply, addressed by txAddr
	reg [7:0] payload [0:63];
	wire [7:0] txData = payload[txAddr[5:0]];

	dcd_link dut (
		.clk(clk), .cep(1'b1), .cen(1'b1), .turbo(1'b0),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .lstrb(lstrb), ._enable(_enable),
		.writeData(writeData), .writeReq(writeReq),
		.readData(readData), .newByteReady(newByteReady),
		.present(present),
		.rxBuf(rxBuf), .rxLen(rxLen), .rxValid(rxValid), .rxBad(rxBad),
		.rxRspGroups(rxRspGroups),
		.rxStb(rxStb), .rxStbData(rxStbData), .rxStbAddr(rxStbAddr),
		.txArm(txArm),
		.txReq(txReq), .txData(txData), .txAddr(txAddr), .txLen(txLen),
		.txBusy(txBusy), .txAbort(txAbort)
	);

	always #10 clk = ~clk;   // 50 MHz-ish; only the enables matter here

	task check;
		input [1023:0] name;
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

	// THE MAC-INITIATED HANDSHAKE, replayed exactly as $419A98-$419ABC does
	// it. This is the sequence every command rides on, and no bench performed
	// it until 2026-09-04 -- they all jumped straight to state 1 and started
	// sending, which the drive happens to accept. Real hardware does not work
	// that way and answered "Comm error" until this was written.
	//
	//   $419A9E  read sense                 must be 1 at idle, else error $10
	//   $419AA6  tst.b $200(a0)  ca0=1      -> state 3, HOST asserted
	//   $419AB0  spin, timeout -> error $11
	//   $419AB6  read sense
	//   $419ABA  bmi $419AB0                LOOP WHILE SENSE == 1
	//   $419ABC  tst.b $400(a0)  ca1=0      -> state 1, now send
	//
	// TashTwenty's Receive does the mirror image: wait while state 2, require
	// state 3, `bcf PORTC,RC4` to assert /HSHK, wait while state 3, require
	// state 1.
	integer hsWait;
	task macRequestToSend;
		begin
			setState(3'd2);
			@(posedge clk); #1;
			check("idle: /HSHK is de-asserted before a command", readData[7] === 1'b1);
			setState(3'd3);
			hsWait = 0;
			while (readData[7] !== 1'b0 && hsWait < 4000) begin
				@(posedge clk); hsWait = hsWait + 1;
			end
			check("the drive asserts /HSHK when the Mac asserts HOST",
			      readData[7] === 1'b0);
			setState(3'd1);
		end
	endtask

	// $419B... returns to state 3 when the command is fully sent, and IntEn3
	// in TashTwenty says the Mac "is done and is waiting for !HSHK to be
	// deasserted" before it will go idle.
	task macEndOfCommand;
		begin
			setState(3'd3);
			hsWait = 0;
			while (readData[7] !== 1'b1 && hsWait < 4000) begin
				@(posedge clk); hsWait = hsWait + 1;
			end
			check("the drive releases /HSHK once the command is sent",
			      readData[7] === 1'b1);
			setState(3'd2);
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

	// Multi-group frame state, for the hold-off test. A hold-off is only
	// LEGITIMATE on a group that is not the last one - $4198EC's `tst.w d7/beq`
	// feeds the `sne` that drives ph0L, so the Mac never holds off on the final
	// group - and the old single-group test therefore posed a question the real
	// Mac never asks. Four groups gives a middle one and a second-to-last one.
	localparam GROUPS  = 4;
	localparam TXPAY   = 7*GROUPS - 1;      // module appends the checksum byte
	reg [7:0] src  [0:7*GROUPS-1];          // payload ++ checksum, as sent
	reg [7:0] expG [0:8*GROUPS-1];          // expected on the wire, 8 per group
	reg [7:0] strm [0:15];
	reg [7:0] lsbAcc;
	integer   g, gi;
	reg       gotIt;
	reg       gotAll;

	// getByte with a bound. The RTL as built REWINDS on a hold-off and parks in
	// TX_WAIT, emitting nothing until the Mac returns to state 1 - so a plain
	// getByte would block and the whole bench would die on the global timeout
	// with no indication of which assertion failed. Bounded, the miss is
	// reported as a FAIL on the line that cares and the rest of the run
	// continues.
	task getByteTO;
		output [7:0] b;
		output       okd;
		integer      n;
		begin
			n = 0; okd = 1'b0; b = 8'hXX;
			@(posedge clk);
			while (!newByteReady && n < 4000) begin
				@(posedge clk);
				n = n + 1;
			end
			if (newByteReady) begin
				b   = readData;
				okd = 1'b1;
			end
			#1;
		end
	endtask

	initial begin
		_reset = 0; ca0 = 0; ca1 = 1; ca2 = 0;  // state 2, idle
		lstrb = 0; _enable = 0; writeData = 0; writeReq = 0;
		present = 1; txArm = 0; txReq = 0; txLen = 0;
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
		// 1b. THE COMMAND HANDSHAKE. Everything else in this bench assumes
		//     it; nothing tested it, and it was missing from the RTL.
		// ---------------------------------------------------------------
		armRx;
		macRequestToSend;
		macByte(8'hAA);
		macByte(8'h81);
		macByte(8'h81);
		// One whole group is EIGHT bytes: the LSB byte then seven data bytes.
		macByte(8'h80);                                   // LSB byte
		macByte(8'h80); macByte(8'h80); macByte(8'h80);   // 7 data bytes,
		macByte(8'h80); macByte(8'h80); macByte(8'h80);   //  all zero, so the
		macByte(8'h80);                                   //  checksum closes
		macEndOfCommand;

		// The Mac drops /ENBL2 between operations. A handshake abandoned that
		// way must not leave /HSHK stuck low or the state machine mid-sequence,
		// or the NEXT command starts from a lie. Nothing exercised this until a
		// mutant deleting the deselect reset scored full marks.
		setState(3'd2);
		@(posedge clk); #1;
		setState(3'd3);
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 4000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		check("mid-handshake: /HSHK is asserted before the deselect",
		      readData[7] === 1'b0);
		#1; _enable = 1'b1;                 // /ENBL2 released
		repeat (4) @(posedge clk); #1;
		check("a deselected drive reads as absent", readData[7] === 1'b1);
		#1; _enable = 1'b0;                 // selected again
		repeat (4) @(posedge clk); #1;
		check("and it comes back de-asserted, not stuck low",
		      readData[7] === 1'b1);
		// ...and a fresh command still works.
		armRx;
		macRequestToSend;
		macByte(8'hAA);
		macByte(8'h81);
		macByte(8'h81);
		macByte(8'h80);                                   // LSB byte
		macByte(8'h80); macByte(8'h80); macByte(8'h80);   // + seven data bytes
		macByte(8'h80); macByte(8'h80); macByte(8'h80);
		macByte(8'h80);
		macEndOfCommand;

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
		// 2b. THE VECTOR FIGURE 1 CANNOT BE: a real Status command
		// ---------------------------------------------------------------
		// $41967C builds the command block as <op><blks><adrH><adrM><adrL>
		// <pad>, and $419D12's `moveq #$1,d3` puts 1 in the block count for a
		// Status. So the seven payload bytes on the wire are
		//   $03 $01 $00 $00 $00 $00 $FC
		// whose LSBs are 1,1,0,0,0,0,0 -- NOT a palindrome. Data byte n owns
		// bit n, so the LSB byte is $80|$01|$02 = $83, and the group is
		//   $83 $81 $80 $80 $80 $80 $80 $FE
		// Under the reversed packing this same group decodes to
		// $02 $00 $00 $00 $00 $01 $FD -- a valid checksum, an opcode of $02,
		// and no reply. That is precisely what the board reported on
		// 2026-09-05 and was read as "the Mac issued a write-verify".
		armRx;
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h81);
		macByte(8'hB1);
		macByte(8'h83);        // LSB byte: bit 0 = LSB($03), bit 1 = LSB($01)
		macByte(8'h81); macByte(8'h80); macByte(8'h80); macByte(8'h80);
		macByte(8'h80); macByte(8'h80); macByte(8'hFE);
		@(posedge clk); #1;
		check("ROM Status command reports valid", sawValid === 1'b1);
		check("ROM Status command decodes to opcode $03, not $02",
		      rxBuf[7:0] === 8'h03);
		check("ROM Status command block count is 1", rxBuf[15:8] === 8'h01);
		check("ROM Status command address is zero",
		      rxBuf[39:16] === 24'h000000);
		check("ROM Status command asks for 49 groups back", rxRspGroups === 7'd49);

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
		// LSB byte first, and data byte n owns bit n.
		macByte(8'h80 |  payload[0][0]        | (payload[1][0] << 1) |
		                (payload[2][0] << 2)  | (payload[3][0] << 3) |
		                (payload[4][0] << 4)  | (payload[5][0] << 5) |
		                (payload[6][0] << 6));
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
			macByte(8'h80 |  payload[i+0][0]       | (payload[i+1][0] << 1) |
			                (payload[i+2][0] << 2) | (payload[i+3][0] << 3) |
			                (payload[i+4][0] << 4) | (payload[i+5][0] << 5) |
			                (payload[i+6][0] << 6));
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
			// All odd, so the LSB pattern is 1,1,1,1,1,1,0 with the
			// checksum -- deliberately NOT a palindrome, or this test
			// could not tell the two bit orders apart either.
			payload[i] = 8'h41 + 2*i[7:0];
			sum = sum + payload[i];
		end
		chk = -sum;                       // the module must append exactly this

		expTx[7] = 8'h80;
		for (i = 0; i < 6; i = i + 1) begin
			expTx[i] = 8'h80 | (payload[i] >> 1);
			expTx[7] = expTx[7] | (payload[i][0] << i);
		end
		expTx[6] = 8'h80 | (chk >> 1);
		expTx[7] = expTx[7] | (chk[0] << 6);

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
		// 5. HOLD-OFF, DRIVE->MAC: the interrupted group is FINISHED and the
		//    NEXT one follows. Rewritten 2026-09-05 from $4198C4-$419998.
		// ---------------------------------------------------------------
		// This test used to assert the opposite, BY NAME ("the interrupted
		// group RESTARTS, not continues"), because it was written from the
		// same reading of 1.2a pages 4-5 as the RTL. A bench that shares the
		// implementation's misreading cannot disagree with it, which is the
		// third time this project has paid for that and is recorded at the
		// 1.1/1.2a STOP and the LSB STOP.
		//
		// Three independent sources say CONTINUE:
		//   Plus ROM $41991C  asserts HOFF only AFTER reading four bytes of
		//                     the group, then $419926-$419964 keep polling for
		//                     the remaining four; $41997A's `subq.w #1,d7` is
		//                     the decrement the skipped `dbne` would have done,
		//                     so nothing is backed up; $419998 `bra $4198C4`
		//                     decodes the group in hand and reads the NEXT one.
		//                     The finished group stays in the checksum.
		//   HD20 firmware     L1f4c-L1fac tests P2.7 only after the LSB byte.
		//   TashTwenty        XSuspend: "Resume transmission after interrupted
		//                     group".
		// The March-85 timing figure agrees in its own words (t3). The prose in
		// 1.2a is simply wrong, and the ROM outranks the document.
		sum = 0;
		for (i = 0; i < TXPAY; i = i + 1) begin
			// Deliberately NOT a palindrome in the LSBs: a reversed bit order
			// has to be visible here too.
			payload[i] = 8'h41 + 3*i[7:0];
			sum = sum + payload[i];
			src[i] = payload[i];
		end
		chk = -sum;
		src[TXPAY] = chk;

		for (g = 0; g < GROUPS; g = g + 1) begin
			lsbAcc = 8'h80;
			for (gi = 0; gi < 7; gi = gi + 1) begin
				expG[g*8 + gi] = 8'h80 | (src[g*7 + gi] >> 1);
				lsbAcc = lsbAcc | (src[g*7 + gi][0] << gi);
			end
			expG[g*8 + 7] = lsbAcc;
		end

		setState(3'd2);
		@(posedge clk); #1;
		txLen = TXPAY[9:0];
		txReq = 1'b1;
		@(posedge clk); #1;
		txReq = 1'b0;
		setState(3'd1);

		getByteTO(strm[0], gotIt);
		check("HOFF: frame opens with the $AA sync", gotIt && strm[0] === 8'hAA);

		// Group 0 runs clean, so a later failure cannot be blamed on the
		// multi-group frame itself.
		ok = 1;
		for (i = 0; i < 8; i = i + 1) begin
			getByteTO(strm[i], gotIt);
			if (!gotIt || strm[i] !== expG[i]) ok = 0;
		end
		check("HOFF: group 0 arrives intact with no hold-off", ok);

		// ---- group 1, a MIDDLE group: HOFF after four bytes ----
		ok = 1;
		for (i = 0; i < 4; i = i + 1) begin
			getByteTO(strm[i], gotIt);
			if (!gotIt || strm[i] !== expG[8 + i]) ok = 0;
		end
		check("HOFF: four bytes of the middle group arrive before the hold-off", ok);

		setState(3'd0);                   // $41991C asserts HOFF here

		ok = 1;
		gotAll = 1;
		for (i = 4; i < 8; i = i + 1) begin
			getByteTO(strm[i], gotIt);
			if (!gotIt) gotAll = 0;
			if (!gotIt || strm[i] !== expG[8 + i]) ok = 0;
		end
		check("HOFF: the rest of the interrupted group STILL ARRIVES in state 0", ok);
		// readData gates txByte on state 1 only, so a DUT that kept clocking
		// but did not widen that gate would hand the Mac the sense bit ($00)
		// instead of data. That is a DIFFERENT bug from stopping and needs its
		// own name - but the check is only meaningful if the bytes arrived at
		// all. Gated on gotAll, because an X from a timed-out getByteTO is
		// !== 8'h00 and passed this vacuously the first time it ran.
		check("HOFF: those state-0 bytes are DATA, not the sense bit",
		      gotAll && strm[4] !== 8'h00 && strm[5] !== 8'h00 &&
		      strm[6] !== 8'h00 && strm[7] !== 8'h00);

		setState(3'd1);                   // $419986: ph0H 0 -> 1, no state 3

		getByteTO(strm[0], gotIt);
		check("HOFF: a fresh $AA follows the FINISHED group",
		      gotIt && strm[0] === 8'hAA);

		// ---- group 2, the SECOND-TO-LAST: the next group, then HOFF again ----
		ok = 1;
		for (i = 0; i < 4; i = i + 1) begin
			getByteTO(strm[i], gotIt);
			if (!gotIt || strm[i] !== expG[16 + i]) ok = 0;
		end
		check("HOFF: what follows is the NEXT group, not a resend of the interrupted one", ok);

		setState(3'd0);                   // a second hold-off, second-to-last group

		ok = 1;
		for (i = 4; i < 8; i = i + 1) begin
			getByteTO(strm[i], gotIt);
			if (!gotIt || strm[i] !== expG[16 + i]) ok = 0;
		end
		check("HOFF: a second hold-off, on the second-to-last group, also finishes it", ok);

		setState(3'd1);

		getByteTO(strm[0], gotIt);
		check("HOFF: fresh $AA after the second hold-off",
		      gotIt && strm[0] === 8'hAA);

		// ---- group 3, the last: no hold-off is legitimate here ----
		ok = 1;
		for (i = 0; i < 8; i = i + 1) begin
			getByteTO(strm[i], gotIt);
			if (!gotIt || strm[i] !== expG[24 + i]) ok = 0;
		end
		check("HOFF: the final group arrives intact after two hold-offs", ok);
		check("HOFF: the checksum byte survived both hold-offs",
		      strm[6] === expG[30]);

		@(posedge clk);
		while (txBusy) @(posedge clk);
		setState(3'd3);
		@(posedge clk); #1;
		check("HOFF: /HSHK released at end of a held-off frame", readData[7] === 1'b1);
		setState(3'd2);
		@(posedge clk); #1;

		// Restore the single-group expectations that tests 6 and 8 below use.
		sum = 0;
		for (i = 0; i < 6; i = i + 1) begin
			payload[i] = 8'h41 + 2*i[7:0];
			sum = sum + payload[i];
		end
		chk = -sum;
		expTx[7] = 8'h80;
		for (i = 0; i < 6; i = i + 1) begin
			expTx[i] = 8'h80 | (payload[i] >> 1);
			expTx[7] = expTx[7] | (payload[i][0] << i);
		end
		expTx[6] = 8'h80 | (chk >> 1);
		expTx[7] = expTx[7] | (chk[0] << 6);

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
		macByte(8'h80 |  payload[0][0]        | (payload[1][0] << 1) |
		                (payload[2][0] << 2)  | (payload[3][0] << 3) |
		                (payload[4][0] << 4)  | (payload[5][0] << 5) | (chk[0] << 6));
		for (i = 0; i < 6; i = i + 1) macByte(8'h80 | (payload[i] >> 1));
		macByte(8'h80 | (chk >> 1));
		@(posedge clk); #1;
		check("receiver still frames correctly after a RESET", sawValid === 1'b1);

		// ---------------------------------------------------------------
		// THE MAC ABANDONS US MID-REQUEST. The ROM's drive scan walks the
		// chain, so after we have asked for the bus it can perfectly well go
		// off and probe another device instead of coming to state 1. If the
		// transmitter just waits, /HSHK stays low for ever and every later
		// operation sees a drive holding the line. TashTwenty's Transmit calls
		// XAbort on any state it cannot handle, for exactly this reason.
		// ---------------------------------------------------------------
		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd6;
		@(posedge clk); #1; txReq = 1'b1;
		@(posedge clk); #1; txReq = 1'b0;
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 4000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		check("drive asserts /HSHK asking for the bus", readData[7] === 1'b0);
		setState(3'd5);                    // Mac goes off to probe the chain
		repeat (8) @(posedge clk); #1;
		check("an ID state abandons the request rather than holding the bus",
		      txBusy === 1'b0);
		setState(3'd2);
		repeat (8) @(posedge clk); #1;
		check("  ...and /HSHK is released, not stuck low", readData[7] === 1'b1);

		// ---------------------------------------------------------------
		// 7. MAC-TO-DRIVE HOLD-OFF: the rest of the group still arrives
		// ---------------------------------------------------------------
		// $419B5A drops ca0 after the group's fourth transmitted byte and the
		// Mac keeps going: three more data bytes, the LSB byte, one filler
		// $00, then ca0 back up, a fresh $AA, and straight on to the NEXT
		// group. Nothing is resent and the checksum never pauses. A receiver
		// that stops taking bytes in state 0 loses four bytes of the group and
		// then mis-frames everything after it.
		sum = 0;
		for (i = 0; i < 13; i = i + 1) begin
			payload[i] = 8'hA0 + i[7:0];
			sum = sum + payload[i];
		end
		payload[13] = -sum;

		armRx;
		setState(3'd1);
		macByte(8'hAA);
		macByte(8'h82);                  // two groups from the Mac
		macByte(8'h81);
		// group 1, with HOFF asserted part-way through
		macByte(8'h80 |  payload[0][0]       | (payload[1][0] << 1) |
		                (payload[2][0] << 2) | (payload[3][0] << 3) |
		                (payload[4][0] << 4) | (payload[5][0] << 5) |
		                (payload[6][0] << 6));
		macByte(8'h80 | (payload[0] >> 1));
		macByte(8'h80 | (payload[1] >> 1));
		macByte(8'h80 | (payload[2] >> 1));
		setState(3'd0);                  // HOFF, mid-group, exactly as $419B5A
		macByte(8'h80 | (payload[3] >> 1));
		macByte(8'h80 | (payload[4] >> 1));
		macByte(8'h80 | (payload[5] >> 1));
		macByte(8'h80 | (payload[6] >> 1));
		macByte(8'h00);                  // the filler byte at $419BBA
		setState(3'd1);                  // ca0H at $419BD4 releases HOFF
		macByte(8'hAA);                  // the resync at $419BE6
		// group 2 follows immediately; the Mac does NOT resend group 1
		macByte(8'h80 |  payload[7][0]        | (payload[8][0]  << 1) |
		                (payload[9][0]  << 2) | (payload[10][0] << 3) |
		                (payload[11][0] << 4) | (payload[12][0] << 5) |
		                (payload[13][0] << 6));
		for (i = 7; i < 14; i = i + 1) macByte(8'h80 | (payload[i] >> 1));
		@(posedge clk); #1;

		check("hold-off from the Mac: the frame still checksums", sawValid === 1'b1);
		check("hold-off from the Mac: not reported bad", sawBad !== 1'b1);
		ok = 1;
		for (i = 0; i < 8; i = i + 1)
			if (rxBuf[i*8 +: 8] !== payload[i]) ok = 0;
		check("hold-off from the Mac: the interrupted group is kept, not lost", ok);
		ok = 1;
		for (i = 0; i < 14; i = i + 1)
			if (streamed[i] !== payload[i]) ok = 0;
		check("hold-off from the Mac: all 14 payload bytes stream through", ok);

		// ---------------------------------------------------------------
		// 8. THE PAYLOAD STREAM reaches past rxBuf's eight bytes
		// ---------------------------------------------------------------
		// A write's first block rides with the command: 538 payload bytes, of
		// which rxBuf holds eight. Without the stream the sector could not be
		// captured at all. The index must count payload bytes only - not the
		// sync, not the two count bytes, and not the per-group LSB bytes.
		check("payload stream indexes payload bytes only", streamCount >= 14);
		check("payload stream: byte 0 is the first payload byte",
		      streamed[0] === payload[0]);
		check("payload stream: byte 13 is the checksum", streamed[13] === payload[13]);

		// ---------------------------------------------------------------
		// 9. txArm claims the bus before the payload exists
		// ---------------------------------------------------------------
		// $419820 reads the sense line as the FIRST thing the Mac's receive
		// routine does, with no retry budget: /HSHK must already be low. The
		// sync hunt behind it has a budget of $10000. So arming and sending
		// are two separate events, and a drive that waited for its sector
		// before asserting /HSHK would fail every read with error $20 on any
		// storage slower than a few microseconds.
		sum = 0;
		for (i = 0; i < 6; i = i + 1) begin
			payload[i] = 8'h71 + 2*i[7:0];
			sum = sum + payload[i];
		end
		chk = -sum;
		expTx[7] = 8'h80;
		for (i = 0; i < 6; i = i + 1) begin
			expTx[i] = 8'h80 | (payload[i] >> 1);
			expTx[7] = expTx[7] | (payload[i][0] << i);
		end
		expTx[6] = 8'h80 | (chk >> 1);
		expTx[7] = expTx[7] | (chk[0] << 6);

		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd6;
		txArm = 1'b1;                     // "a reply is coming" - no payload yet
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 4000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		check("txArm alone asserts /HSHK", readData[7] === 1'b0);
		setState(3'd3);
		@(posedge clk); #1;
		// State 3 is where the Mac senses, so this is the level that matters.
		check("  ...and still holds it where the Mac reads it, in state 3",
		      readData[7] === 1'b0);
		setState(3'd1);
		// A long wait in state 1 with no payload: the drive must stay silent.
		// (readData carries transmitted bytes in state 1, not the sense line,
		// so newByteReady is the only honest thing to watch here.)
		ok = 1;
		for (i = 0; i < 2000; i = i + 1) begin
			@(posedge clk);
			if (newByteReady) ok = 0;
		end
		check("txArm alone sends nothing while the payload is not ready", ok);

		@(posedge clk); #1; txReq = 1'b1;
		@(posedge clk); #1; txReq = 1'b0;
		getByte(got[0]);
		check("txReq starts the frame that txArm reserved", got[0] === 8'hAA);
		for (i = 0; i < 8; i = i + 1) getByte(got[i]);
		ok = 1;
		for (i = 0; i < 8; i = i + 1)
			if (got[i] !== expTx[i]) ok = 0;
		check("the late frame is encoded exactly as a prompt one", ok);
		@(posedge clk);
		while (txBusy) @(posedge clk);
		#1; txArm = 1'b0;
		setState(3'd3);
		@(posedge clk); #1;
		check("late frame releases /HSHK at the end", readData[7] === 1'b1);
		setState(3'd2);

		// An armed drive whose Mac gives up must let go. Without the escape a
		// fetch the Mac abandoned holds /HSHK low for ever.
		@(posedge clk); #1;
		txArm = 1'b1;
		hsWait = 0;
		while (readData[7] !== 1'b0 && hsWait < 4000) begin
			@(posedge clk); hsWait = hsWait + 1;
		end
		check("armed again for the abandon test", readData[7] === 1'b0);
		setState(3'd3);
		@(posedge clk); #1;
		setState(3'd1);
		repeat (8) @(posedge clk); #1;
		#1; txArm = 1'b0;
		setState(3'd2);                   // the Mac gives up waiting
		repeat (8) @(posedge clk); #1;
		check("an armed frame the Mac abandons releases the bus",
		      readData[7] === 1'b1);
		check("  ...and clears txBusy", txBusy === 1'b0);

		// ---------------------------------------------------------------
		// 9. AN ABANDONED FRAME SAYS SO. txAbort, added 2026-09-05.
		// ---------------------------------------------------------------
		// The command layer cannot tell "finished" from "abandoned" by
		// watching txBusy, because it falls either way. On a multiblock read
		// that difference decides whether the NEXT block is armed into a bus
		// the Mac has already left - an unsolicited frame, which the Mac
		// answers with a reset. The ROM's error exit is 1 -> 3 -> 2, so that
		// is what this drives.
		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd20;                   // 3 groups: long enough to leave mid-frame
		txReq = 1'b1;
		@(posedge clk); #1;
		txReq = 1'b0;
		setState(3'd1);
		getByteTO(strm[0], gotIt);
		check("abort: the frame started", gotIt && strm[0] === 8'hAA);
		for (i = 0; i < 4; i = i + 1) getByteTO(strm[i], gotIt);

		sawAbort = 1'b0;
		@(posedge clk); #1;
		setState(3'd3);                   // the ROM's error exit, first half
		repeat (4) @(posedge clk); #1;
		check("abort: leaving to state 3 mid-group raises txAbort", sawAbort === 1'b1);
		check("abort: ...and clears txBusy", txBusy === 1'b0);
		setState(3'd2);
		@(posedge clk); #1;
		check("abort: ...and releases /HSHK", readData[7] === 1'b1);

		// It must be a PULSE, not a level: a level would re-abort the next
		// frame the instant the command layer armed it.
		sawAbort = 1'b0;
		repeat (8) @(posedge clk); #1;
		check("abort: txAbort is a one-clock pulse, not a level", sawAbort === 1'b0);

		// And a frame that ENDS NORMALLY must never raise it, or the command
		// layer would tear down every good multiblock read after one block.
		sawAbort = 1'b0;
		setState(3'd2);
		@(posedge clk); #1;
		txLen = 10'd6;
		txReq = 1'b1;
		@(posedge clk); #1;
		txReq = 1'b0;
		setState(3'd1);
		for (i = 0; i < 9; i = i + 1) getByteTO(strm[i], gotIt);
		@(posedge clk);
		while (txBusy) @(posedge clk);
		setState(3'd3);
		@(posedge clk); #1;
		check("abort: a frame that COMPLETES does not raise txAbort", sawAbort === 1'b0);
		check("abort: the completed frame still released /HSHK", readData[7] === 1'b1);
		setState(3'd2);
		@(posedge clk); #1;

		// ---------------------------------------------------------------
		// 10. A NEW COMMAND RE-SYNCS THE RECEIVER. Added 2026-09-05.
		// ---------------------------------------------------------------
		// State 3 out of state 2 is ALWAYS the start of a fresh command, so
		// any rxState left over from a frame the Mac abandoned part-way is
		// stale by definition. The handshake FSM used to reset itself on an
		// abandon while the BYTE FSM kept its place, so the next command was
		// decoded as though it were the middle of the last one and never found
		// its sync again. That does not cause the first error - but it turns
		// one error into a reset cycle, which is how a single hold-off became
		// a bomb.
		//
		// Leave the receiver deliberately mid-frame, then send a good command
		// and require it to decode.
		armRx;
		macRequestToSend;
		macByte(8'hAA);                   // sync
		macByte(8'h81);                   // group count
		macByte(8'h81);
		macByte(8'h80);                   // LSB byte, then abandon mid-group
		macByte(8'h80); macByte(8'h80);
		setState(3'd2);                   // the Mac walks away, mid-group
		repeat (8) @(posedge clk); #1;
		check("resync: the abandoned command did not decode", sawValid !== 1'b1);

		armRx;
		macRequestToSend;                 // a FRESH command, properly handshaked
		macByte(8'hAA);
		macByte(8'h81);
		macByte(8'h81);
		macByte(8'h80);
		macByte(8'h80); macByte(8'h80); macByte(8'h80);
		macByte(8'h80); macByte(8'h80); macByte(8'h80);
		macByte(8'h80);
		macEndOfCommand;
		check("resync: the NEXT command decodes after an abandoned one", sawValid === 1'b1);
		check("resync: ...and is not reported bad", sawBad !== 1'b1);

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
