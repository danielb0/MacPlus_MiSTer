/* dcd_link.v - DCD (Directly Connected Disk / Apple HD20) link layer.

   MAC128K_PLAN.md Phase 5. This is the framing engine only: phase-line state
   decode, the identification states, /HSHK, and 7-for-8 group coding in both
   directions with the checksum. The command layer (Status, MultiBlock Read,
   MultiBlock Write) and the storage back end sit on top of it and are not
   here.

   A DCD device is a PEER OF floppy.v on the interface the IWM already
   provides. That is not a simplification: the corrected DB-19 pinout (read
   from the page image; the OCR of that table had shifted a column) says DCD
   uses the ordinary RD and WR pins, with /ENBL2 as /Enable. Only PH0-PH2 are
   repurposed, from a drive-register address into a 3-bit handshake state bus.
   /WrReq and HDSel are N/C, so SEL is ignored here.

   THE STATE IS {ca2,ca1,ca0} AS PLAIN BINARY, and the Mac changes one line at
   a time, so intermediate states are seen and must not be acted on as
   commands. Only the settled value means anything.

        7  ID: sense 1   "drive connected"
        6  ID: sense 1   (# sides, on a Sony)
        5  ID: sense 0   this is a DCD and not a Sony  <-- the discriminator
        4  RESET asserted
        3  HOST asserted, Mac sensing /HSHK
        2  idle
        1  data mode - readData carries transmitted bytes
        0  HOFF asserted

   /HSHK IS IDLE-HIGH, ASSERTED-LOW. The Plus ROM pins that down three ways:
   the transmit entry ($419A98) errors $10 if sense is 0 at idle, then spins
   `bmi` waiting for it to fall; the end of transmission spins `bpl` waiting
   for it to rise; and the receive entry ($419820) refuses to start unless it
   is already 0.

   AND IT IS DRIVEN FROM BOTH DIRECTIONS, WHICH THIS FILE ORIGINALLY MISSED.
   A drive that only asserts /HSHK when IT wants to talk answers no command at
   all: before sending anything the Mac asserts HOST and SPINS until the drive
   pulls /HSHK low, giving up with error $11. On hardware that presents as a
   diagnostic reporting "Comm error" while the ID probe still succeeds, because
   identification is a static level and needs no handshake.

     $419A9E  read sense                 must be 1 at idle, else error $10
     $419AA6  tst.b $200(a0)  ca0=1      -> state 3, HOST asserted
     $419AB0  subq.l #1,d7 / beq         timeout -> error $11
     $419AB6  read sense
     $419ABA  bmi $419AB0                SPIN WHILE SENSE == 1
     $419ABC  tst.b $400(a0)  ca1=0      -> state 1, and only now send

   TashTwenty's receiver is the mirror image and settles the release too: wait
   while state 2, require state 3, `bcf PORTC,RC4` to assert; then wait while
   state 3, require state 1, receive. When the Mac has sent everything it
   returns to state 3 -- its IntEn3 comment reads "mac is done and is waiting
   for !HSHK to be deasserted" -- and the drive releases before idling.

   EVERY TRANSMITTED BYTE HAS ITS MSB SET, and on this interface that is not a
   quirk - it is the data-ready signal. iwm.v latches readData on newByteReady
   and clears the latch after a read, and the driver polls with `dbmi`,
   looping while the value is non-negative. A byte with the MSB clear would be
   indistinguishable from an empty latch.

   THE FRAMING IS ASYMMETRIC, and both the Plus ROM and the HD20's own Z8
   firmware agree on the asymmetry:

     Mac -> drive:  <$AA> <txGroups+$81> <rxGroups+$81> then groups of 8,
                    LSB BYTE FIRST followed by 7 data bytes
     drive -> Mac:  <$AA> then groups of 8, 7 data bytes followed by the
                    LSB BYTE LAST

   The two count bytes carry the group count in each direction. Only the Mac
   sends them because only the drive needs telling - the Mac computed both
   numbers before the transfer started. They appear in no published document;
   they are read out of the ROM's transmitter and confirmed independently by
   the drive firmware, which masks exactly two bytes with $7F before reaching
   its LSB byte.

   7-for-8 coding, per the specification's own worked example (Figure 1),
   which sim/tb_dcd_link.v asserts verbatim as a golden vector:

     transmitted[i] = $80 | (data[i] >> 1)
     lsbByte        = $80 | (L0<<6 | L1<<5 | ... | L6<<0)   Ln = data[n] & 1

   CHECKSUM: an 8-bit sum of the DECODED data bytes, sent as (-sum) & $FF, so
   a receiver validates by summing everything including the checksum byte to
   zero. Stated in neither specification; read out of both halves of the ROM
   driver independently (`neg.b d5` on transmit, `beq` on the running sum at
   $419A08 on receive).
*/

module dcd_link
(
	input         clk,
	input         cep,
	input         cen,

	input         _reset,

	// phase lines from the IWM. lstrb is PH3 (daisy-chain select); with a
	// single device it only has to not break the ID probe.
	input         ca0,
	input         ca1,
	input         ca2,
	input         lstrb,
	input         _enable,      // /ENBL2

	// byte interface, the same shape floppy.v presents to iwm.v
	input   [7:0] writeData,
	input         writeReq,
	output  [7:0] readData,
	output reg    newByteReady,

	input         present,      // a DCD image is mounted

	// ---- command layer above ----
	// A fully received payload is presented for one clock with rxValid (good
	// checksum) or rxBad. Flattened rather than an array port so this stays
	// plain Verilog-2001 for Quartus as well as iverilog; byte 0 is in the
	// low bits, which is receive order.
	output reg [63:0] rxBuf,
	output reg  [3:0] rxLen,
	output reg        rxValid,
	output reg        rxBad,

	// How many groups the Mac has asked to receive back, from the second count
	// byte. Valid alongside rxValid. A DCD drive does not decide its own reply
	// length: both real implementations size the reply from this byte and
	// nothing else - TashTwenty zeroes exactly `RC_RSPG & $7F` groups of buffer
	// before it writes a single field into them, and the HD20's own firmware
	// does `ld R2,53h` immediately before sending the $AA and then ends its
	// transmit loop on `dec R2 / jr NZ`. Honouring it is also what keeps us
	// correct against a driver revision that asks for a length we did not
	// anticipate.
	output reg  [6:0] rxRspGroups,

	// The command layer raises txReq with a payload; the link layer adds the
	// sync, the group coding and the checksum. txBusy falls when it is done.
	// txLen is the payload length EXCLUDING the checksum, and txLen+1 must be
	// a multiple of 7 so the payload fills whole groups.
	//
	// THE CHECKSUM MUST LAND IN THE LAST SLOT OF THE LAST GROUP, not merely
	// after the data. Where a reply is shorter than the groups requested, the
	// padding goes BEFORE the checksum: the HD20 firmware emits `com R4 / inc
	// R4` as the seventh byte of the group in which its counter reaches zero,
	// and TashTwenty sums one byte less than the block "so we can write the
	// checksum to the very last byte position". Choosing txLen so that txLen+1
	// fills whole groups is what puts it there, so that requirement above is
	// not a convenience - it is the wire format.
	input             txReq,
	input       [7:0] txData,    // payload byte selected by txAddr
	output reg  [9:0] txAddr,
	input       [9:0] txLen,
	output reg        txBusy
);

	// The DCD sync byte. $AA in BOTH directions: the specification says writes
	// use $96, but no $96 exists anywhere in the DCD engine of any Plus ROM
	// revision, nor in the .Sony PTCH, and the May document's own handshake
	// section says the sync "is always $AA". Accepting $AA costs nothing;
	// requiring $96 would deadlock against Apple's own driver.
	localparam [7:0] SYNC = 8'hAA;

	// 128 clk8 per byte - 2 us per bit, 8 bits - which is the rate floppy.v
	// already uses. The DCD cell is 2.042 us rather than 2.000 because a real
	// Mac clocks at 7.8333 MHz, but this core's IWM models that same clock as
	// its nominal 8 MHz enable, so matching floppy.v keeps DCD at the correct
	// rate RELATIVE to everything else the IWM does.
	localparam [7:0] BYTE_TICKS = 8'd128;

	wire [2:0] state    = {ca2, ca1, ca0};
	wire       selected = present & ~_enable;

	// Mac-initiated command handshake. Separate from the transmit FSM because
	// the two are different conversations that happen to share one wire: here
	// the Mac asks and we answer, there we ask and the Mac answers.
	//
	// ARMING REQUIRES PASSING THROUGH IDLE FIRST, and that is not tidiness.
	// State 3 occurs at BOTH ends of every exchange - the Mac raises HOST to
	// begin, and returns to it to wait for the release - so a drive that armed
	// on state 3 alone would re-assert /HSHK the instant it finished a reply
	// and deadlock against the Mac's own end-of-transmission spin.
	localparam RXH_IDLE  = 3'd0, RXH_ARMED = 3'd1, RXH_READY = 3'd2,
	           RXH_DATA  = 3'd3, RXH_DONE  = 3'd4;
	reg [2:0] rxHs;

	// A reply request has to be REMEMBERED rather than acted on immediately.
	// The command layer raises txReq the moment a command decodes, which is
	// while the Mac is still in state 1 finishing the send - and a drive that
	// grabbed /HSHK there would never release it for the end-of-command
	// acknowledgement, hanging the Mac at the far end of the very exchange it
	// had just got right. TashTwenty's Transmit refuses to start unless the
	// state is 2 and aborts otherwise; this is that rule, with a latch so the
	// one-clock request survives the wait for idle.
	reg txPend;

	// ------------------------------------------------------------------
	// Sense
	// ------------------------------------------------------------------
	// With nothing mounted every ID state reads 1 - the "phantom states" a
	// non-chaining DCD returns once the next device has been selected, which
	// is how the Mac learns it has reached the end of the chain. A real Sony
	// also answers 1 in state 5, so an absent DCD is indistinguishable from
	// an ordinary drive, which is what we want.
	reg hshk_n;   // 1 = de-asserted (idle), 0 = asserted
	reg senseBit;

	always @(*) begin
		if (!selected)
			senseBit = 1'b1;
		else case (state)
			3'd7:    senseBit = 1'b1;
			3'd6:    senseBit = 1'b1;
			3'd5:    senseBit = 1'b0;
			default: senseBit = hshk_n;
		endcase
	end

	// In data mode the byte is on the bus; everywhere else bit 7 is the sense
	// line, mirroring floppy.v's dual use of readData.
	reg [7:0] txByte;
	assign readData = (state == 3'd1 && txBusy) ? txByte : {senseBit, 7'b0000000};

	// ------------------------------------------------------------------
	// Receive: Mac -> drive
	// ------------------------------------------------------------------
	localparam RX_SYNC = 2'd0, RX_CNT1 = 2'd1, RX_CNT2 = 2'd2, RX_GROUP = 2'd3;

	reg  [1:0] rxState;
	reg  [2:0] rxIdx;      // position within the group, 0..7
	reg  [7:0] rxLsb;
	reg  [7:0] rxSum;
	reg  [6:0] rxGroups;   // groups still to come, including the current one
	reg  [3:0] rxCount;

	// LSB byte first on this direction, so index 0 is the LSB byte and
	// indices 1..7 are data bytes 0..6. Bit 6 of the LSB byte belongs to the
	// first data byte and bit 0 to the seventh - the packing Figure 1 fixes.
	wire [2:0] rxDataIdx = rxIdx - 3'd1;
	wire       rxLsbBit  = rxLsb[3'd6 - rxDataIdx];
	wire [7:0] rxDecoded = {writeData[6:0], rxLsbBit};
	wire [7:0] rxSumNext = rxSum + rxDecoded;

	// ------------------------------------------------------------------
	// Transmit: drive -> Mac
	// ------------------------------------------------------------------
	localparam TX_IDLE = 3'd0, TX_WAIT = 3'd1, TX_SYNC = 3'd2,
	           TX_DATA = 3'd3, TX_LSB  = 3'd4, TX_END  = 3'd5;

	reg  [2:0] txState;
	reg  [7:0] txTick;
	reg  [2:0] txIdx;        // data byte within the group, 0..6
	reg  [7:0] txLsbAcc;
	reg  [7:0] txSum;
	reg  [9:0] txSent;       // payload bytes emitted, including the checksum

	// Saved at each group boundary so a hold-off can rewind exactly. The
	// interrupted group is RESENT, and the specification is explicit that it
	// "will not be included in the checksum" - so the running sum has to go
	// back too, not just the address.
	reg  [9:0] txAddrGrp;
	reg  [9:0] txSentGrp;
	reg  [7:0] txSumGrp;

	wire [9:0] txTotal  = txLen + 10'd1;              // payload + CHK
	wire       txIsChk  = (txSent == txLen);
	wire [7:0] txSource = txIsChk ? (~txSum + 8'd1) : txData;
	wire [7:0] txLsbSet = txLsbAcc | (8'd1 << (3'd6 - txIdx));

	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			rxState      <= RX_SYNC;
			rxIdx        <= 0;
			rxLsb        <= 0;
			rxSum        <= 0;
			rxGroups     <= 0;
			rxCount      <= 0;
			rxRspGroups  <= 0;
			rxBuf        <= 0;
			rxLen        <= 0;
			rxValid      <= 0;
			rxBad        <= 0;
			txState      <= TX_IDLE;
			txTick       <= 0;
			txIdx        <= 0;
			txLsbAcc     <= 8'h80;
			txSum        <= 0;
			txSent       <= 0;
			txAddr       <= 0;
			txAddrGrp    <= 0;
			txSentGrp    <= 0;
			txSumGrp     <= 0;
			txByte       <= 0;
			txBusy       <= 0;
			newByteReady <= 0;
			hshk_n       <= 1'b1;
			rxHs         <= RXH_IDLE;
			txPend       <= 1'b0;
		end
		else begin
			rxValid      <= 0;
			rxBad        <= 0;
			newByteReady <= 0;

			// State 4 is RESET: the device performs the equivalent of a
			// power-up reset. Handled here rather than folded into _reset so
			// a mounted image is not disturbed.
			if (selected && state == 3'd4) begin
				rxState <= RX_SYNC;
				rxIdx   <= 0;
				rxCount <= 0;
				txState <= TX_IDLE;
				txBusy  <= 1'b0;
				hshk_n  <= 1'b1;
				rxHs    <= RXH_IDLE;
				txPend  <= 1'b0;
			end
			else begin

				// ---------------- command handshake ----------------
				// Runs only while we are not the initiator; a reply drives
				// /HSHK from the transmit FSM below, whose assignments come
				// later in this block and therefore win on the cycle txReq
				// arrives.
				if (txState == TX_IDLE && !txBusy) begin
					if (!selected) begin
						hshk_n <= 1'b1;
						rxHs   <= RXH_IDLE;
					end
					else case (rxHs)
					RXH_IDLE:
						if (state == 3'd2) rxHs <= RXH_ARMED;

					RXH_ARMED:
						if (state == 3'd3) begin
							hshk_n <= 1'b0;      // "ready to receive"
							rxHs   <= RXH_READY;
						end

					RXH_READY:
						if (state == 3'd1) rxHs <= RXH_DATA;
						else if (state == 3'd2) begin
							hshk_n <= 1'b1;      // Mac changed its mind
							rxHs   <= RXH_IDLE;
						end

					RXH_DATA:
						// Back to 3 means the Mac has sent everything and is
						// waiting for the release; 2 means it abandoned the
						// transfer, which TashTwenty's IntEn2 treats as an
						// abort for the same reason.
						if (state == 3'd3) begin
							hshk_n <= 1'b1;
							rxHs   <= RXH_DONE;
						end
						else if (state == 3'd2) begin
							hshk_n <= 1'b1;
							rxHs   <= RXH_IDLE;
						end

					RXH_DONE:
						if (state == 3'd2) rxHs <= RXH_IDLE;

					default: rxHs <= RXH_IDLE;
					endcase
				end

				// ---------------- receive ----------------
				// The Mac only transmits in state 1. writeReq is the IWM
				// handing over a byte it has finished shifting out.
				if (writeReq && selected && state == 3'd1) begin
					case (rxState)
					RX_SYNC:
						// Hunt for the sync. Anything else is noise from a
						// transfer we were not party to.
						if (writeData == SYNC) rxState <= RX_CNT1;

					RX_CNT1: begin
						// The count byte is $80 | TOTAL groups, where the
						// total INCLUDES the command's own group - so a
						// command with no data rides in one group and sends
						// $81. That is settled from the drive firmware, which
						// masks this byte with $7F, loads it into R10 and
						// uses `djnz R10` directly as its group loop: the
						// masked value IS the number of groups it receives.
						//
						// It was `- 7'd1` here, which is right for a
						// single-group command and one group short for every
						// other - invisible until the bench grew a two-group
						// frame.
						rxGroups <= writeData[6:0];
						rxState  <= RX_CNT2;
					end

					RX_CNT2: begin
						// The second count is how many groups the Mac expects
						// back, in the same $80|n form. $419ADC builds the
						// pair with a single `addi.l #$810081,d0` - $81 added
						// to both halves at once - so the two bytes are the
						// same encoding and the low half, sent first, is the
						// command's.
						rxRspGroups <= writeData[6:0];
						rxState <= RX_GROUP;
						rxIdx   <= 0;
						rxSum   <= 0;
						rxCount <= 0;
					end

					RX_GROUP:
						if (rxIdx == 3'd0) begin
							rxLsb <= writeData;
							rxIdx <= 3'd1;
						end
						else begin
							rxSum <= rxSumNext;
							if (rxCount < 4'd8) begin
								rxBuf[{rxCount, 3'b000} +: 8] <= rxDecoded;
								rxCount <= rxCount + 4'd1;
							end
							if (rxIdx == 3'd7) begin
								rxIdx <= 3'd0;
								if (rxGroups <= 7'd1) begin
									// Last group. The running sum INCLUDING
									// the checksum byte must be zero.
									rxState <= RX_SYNC;
									// rxCount has not yet taken the byte
									// being stored this cycle.
									rxLen   <= rxCount + 4'd1;
									if (rxSumNext == 8'd0) rxValid <= 1'b1;
									else                   rxBad   <= 1'b1;
								end
								else
									rxGroups <= rxGroups - 7'd1;
							end
							else
								rxIdx <= rxIdx + 3'd1;
						end
					endcase
				end

				// ---------------- transmit ----------------
				case (txState)
				TX_IDLE: begin
					if (txReq && selected) txPend <= 1'b1;
					// Only out of IDLE, and only with the bus idle: see txPend
					// above. Assert /HSHK to ask for the bus, then wait for the
					// Mac to come round to state 1. It goes 2 -> 3 -> 1.
					if ((txReq || txPend) && selected && state == 3'd2) begin
						txPend    <= 1'b0;
							// Assert /HSHK and wait for the Mac to come round to
							// state 1. It goes 2 -> 3 -> 1, sensing us in 3.
							hshk_n    <= 1'b0;
							txBusy    <= 1'b1;
							txState   <= TX_WAIT;
							rxHs      <= RXH_IDLE;
							txSent    <= 0;
							txAddr    <= 0;
							txIdx     <= 0;
							txSum     <= 0;
							txTick    <= 0;
							txLsbAcc  <= 8'h80;
							txAddrGrp <= 0;
							txSentGrp <= 0;
							txSumGrp  <= 0;
					end
				end

				TX_WAIT:
					if (state == 3'd1) begin
						txState <= TX_SYNC;
						txTick  <= BYTE_TICKS;
					end

				TX_SYNC:
					if (cen) begin
						if (txTick != 0) txTick <= txTick - 8'd1;
						else begin
							txByte       <= SYNC;
							newByteReady <= 1'b1;
							txState      <= TX_DATA;
							txTick       <= BYTE_TICKS;
							txLsbAcc     <= 8'h80;
							txIdx        <= 0;
						end
					end

				// Seven data bytes, then the LSB byte, on this direction.
				TX_DATA:
					// A hold-off can arrive anywhere in a group. That group is
					// abandoned, excluded from the checksum, and RESENT from
					// its start once HOFF releases - preceded by a fresh sync,
					// because the Mac hunts for one before re-decoding. Not
					// "continued": the specification and the ROM's resync path
					// are both explicit.
					if (state == 3'd0) begin
						txState  <= TX_WAIT;
						txAddr   <= txAddrGrp;
						txSent   <= txSentGrp;
						txSum    <= txSumGrp;
						txIdx    <= 0;
						txLsbAcc <= 8'h80;
					end
					else if (cen) begin
						if (txTick != 0) txTick <= txTick - 8'd1;
						else begin
							txByte       <= {1'b1, txSource[7:1]};
							txLsbAcc     <= txSource[0] ? txLsbSet : txLsbAcc;
							txSum        <= txSum + txSource;
							newByteReady <= 1'b1;
							txTick       <= BYTE_TICKS;
							txSent       <= txSent + 10'd1;
							if (!txIsChk) txAddr <= txAddr + 10'd1;
							if (txIdx == 3'd6) txState <= TX_LSB;
							else               txIdx   <= txIdx + 3'd1;
						end
					end

				TX_LSB:
					if (state == 3'd0) begin
						txState  <= TX_WAIT;
						txAddr   <= txAddrGrp;
						txSent   <= txSentGrp;
						txSum    <= txSumGrp;
						txIdx    <= 0;
						txLsbAcc <= 8'h80;
					end
					else if (cen) begin
						if (txTick != 0) txTick <= txTick - 8'd1;
						else begin
							txByte       <= txLsbAcc;
							newByteReady <= 1'b1;
							txTick       <= BYTE_TICKS;
							txIdx        <= 0;
							txLsbAcc     <= 8'h80;
							// Group boundary: this is the point a hold-off
							// rewinds to.
							txAddrGrp    <= txAddr;
							txSentGrp    <= txSent;
							txSumGrp     <= txSum;
							if (txSent >= txTotal) txState <= TX_END;
							else                   txState <= TX_DATA;
						end
					end

				TX_END: begin
					// De-assert /HSHK. The Mac is spinning in state 3 waiting
					// for exactly this, then drops to idle state 2.
					hshk_n  <= 1'b1;
					txBusy  <= 1'b0;
					txState <= TX_IDLE;
				end

				default: txState <= TX_IDLE;
				endcase
			end
		end
	end

endmodule
