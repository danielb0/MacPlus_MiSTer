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

   7-for-8 coding:

     transmitted[i] = $80 | (data[i] >> 1)
     lsbByte        = $80 | (L0<<0 | L1<<1 | ... | L6<<6)   Ln = data[n] & 1

   THE LSB BIT ORDER IS data[n] -> BIT n, AND IT WAS BACKWARDS HERE UNTIL
   2026-09-05. The specification's Figure 1 cannot settle it: its worked example
   is $31..$37, whose LSBs are 1,0,1,0,1,0,1 and whose LSB-byte is $D5 -- a
   PALINDROME, identical under either order. So the "golden vector" this file
   used to cite proved nothing, and neither could any bench, because a reversed
   packing is self-consistent in a loopback and INVISIBLE TO THE CHECKSUM: it
   only permutes which of the seven bytes each +1 lands on, and the sum of seven
   bytes does not change. Four independent sources settle it instead, two on
   each side of the wire:

     Plus ROM, transmit  $419A4C..$419B06  six `roxr.b #1,d4` then `roxr.b #2,d4`
                         leaves [1, L6, L5, L4, L3, L2, L1, L0]
     Plus ROM, receive   $4198C4  `lsr.b #1,d4 / addx.b d1,d1` -- the FIRST data
                         byte takes bit 0, the second bit 1, and so on
     HD20 firmware, rx   L1dfc  `rrc R8 / rlc R9` per byte, R8 the LSB byte, so
                         again byte n takes bit n
     HD20 firmware, tx   L1edc  `scf / rrc Rn / rrc R15` seven times plus one
                         more shift and `or R15,#$80` -- Ln accumulates at bit n

   The symptom of the reversed order was that a Status reply's first byte, $83,
   reached the Mac as $82 and failed the `$419776 subi.b #$80` opcode compare
   with error $30, while the checksum passed and the link looked healthy from
   every probe we had.

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

	// Payload bytes as they are decoded, for a caller that needs more than the
	// eight rxBuf holds. rxStb is one clock; rxStbData is the decoded byte and
	// rxStbAddr its index within this frame's payload, counting from 0 at the
	// first byte after the two count bytes and including the checksum byte at
	// the end. A MultiBlock Write's first block rides WITH the command -- 538
	// payload bytes - so the sector cannot come out of rxBuf and has to be
	// streamed into the command layer's buffer as it arrives.
	output reg        rxStb,
	output reg  [7:0] rxStbData,
	output reg  [9:0] rxStbAddr,

	// High while the Mac holds the RESET state. The command layer above must
	// abandon whatever it was doing: a reply still queued across a reset
	// re-raises txReq afterwards, and the link then asserts /HSHK in the idle
	// state and waits forever for a state 1 that is never coming. HD Diag
	// reports exactly that as error $28 -- "asserted but never released".
	output            dcdReset,

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
	// ARMING AND STARTING ARE TWO DIFFERENT THINGS, and the ROM is why.
	// $419820 is the first instruction of the Mac's receive routine and it
	// reads the sense line with NO retry budget at all: /HSHK must already be
	// asserted, error $20 otherwise. The Mac gets there within a few
	// microseconds of leaving state 2 at the end of its own transmission, long
	// before an SD card can answer a sector request. The sync byte, by
	// contrast, has a budget of $10000 spins ($419846) -- over a hundred
	// milliseconds. So the drive must claim the bus IMMEDIATELY on accepting a
	// command and send when the data is ready, which is what a real drive with
	// a spinning platter necessarily does too.
	//
	//   txArm  level: a reply is coming. Asserts /HSHK and waits for state 1.
	//   txReq  pulse: the payload behind txData/txLen is ready; send it.
	//
	// Raising both together is the immediate-reply case and behaves exactly as
	// txReq alone used to.
	input             txArm,
	input             txReq,
	input       [7:0] txData,    // payload byte selected by txAddr
	output reg  [9:0] txAddr,
	input       [9:0] txLen,
	output reg        txBusy,

	// ONE-CLOCK PULSE: a frame was ABANDONED in flight, as opposed to
	// finishing. The command layer cannot tell the two apart from txBusy alone
	// - it falls either way - so without this an abandoned read frame looks
	// like a completed one and the next block of a multiblock read is armed
	// into a bus the Mac has already walked away from. See dcd.v's C_SENDING.
	output reg        txAbort,

	// ---- JTAG telemetry, decoded by rtl/dbg_probes.sv as PDCD/PDC2 --------
	// LIVE RAW STATE ONLY. Every counter, sticky bit and epoch lives in the
	// probe deck, which is the same division `scsi_dbg` already uses: a module
	// under observation must not grow logic that only an instrument reads,
	// because that logic then has to be maintained and proven twice.
	//
	//   [2:0]  {ca2,ca1,ca0} exactly as the Mac is driving it -- INCLUDING the
	//          intermediate values, since it changes one line at a time
	//   [3]    selected                [4]    /HSHK  (1 = de-asserted, idle)
	//   [7:5]  rxHs                    [10:8] txState
	//   [11]   txBusy
	//   [12]   a byte taken from the Mac in data mode        (pulse)
	//   [13]   newByteReady -- a byte handed to the IWM       (pulse)
	//   [14]   rxValid                 [15]   rxBad           (pulses)
	output     [15:0] dbg_link
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

	assign dcdReset = selected & (state == 3'd4);

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
	// STATE 0 PRESENTS DATA TOO, not just state 1. The Mac asserts the hold-off
	// (state 0) and then goes on reading the rest of the group - $419926-$419964
	// poll for four more bytes and raise error $22 if they do not come. Gating
	// on state 1 alone handed those reads {senseBit, 7'b0} = $00 instead, so
	// even a transmitter that kept clocking would have fed the Mac zeros.
	assign readData = ((state == 3'd1 || state == 3'd0) && txBusy)
	                  ? txByte : {senseBit, 7'b0000000};

	// ------------------------------------------------------------------
	// Receive: Mac -> drive
	// ------------------------------------------------------------------
	// HOLD-OFF ON THIS DIRECTION IS NOT A RETRANSMISSION, and it is the one
	// place the two directions genuinely differ. When the Mac is transmitting
	// and finds an SCC interrupt pending it drops ca0 mid-group ($419B5A,
	// after the group's fourth byte), FINISHES the group anyway, sends one
	// filler $00, services the interrupt, releases HOFF, sends a fresh $AA and
	// carries on with the NEXT group. $419BC8's `subq.w #1,d6` replaces the
	// `dbra` it skipped, so the group counter and the source pointer both move
	// on: nothing is resent and the checksum keeps running. The HD20's own
	// firmware receives it exactly that way -- L1e53 tests the phase line at
	// the group boundary, discards bytes until $AA and jumps back into the
	// group loop with the interrupted group's data intact.
	//
	// Two consequences here. Bytes that arrive while HOFF is asserted are real
	// payload and must be taken, so the accept condition covers state 0 once a
	// frame is under way. And the $AA that follows is a bare resync, NOT the
	// start of a frame - the two count bytes do not come again - so it needs
	// its own state rather than a trip through RX_SYNC.
	//
	// None of this can fire on a Status or a Read: $419B40 clears the hold-off
	// flag when the group counter says this is the last group, and those
	// commands are one group long. Only a write's 77 groups can see it.
	localparam RX_SYNC = 3'd0, RX_CNT1 = 3'd1, RX_CNT2 = 3'd2,
	           RX_GROUP = 3'd3, RX_RESYNC = 3'd4;

	reg  [2:0] rxState;
	reg  [2:0] rxIdx;      // position within the group, 0..7
	reg  [7:0] rxLsb;
	reg  [7:0] rxSum;
	reg  [6:0] rxGroups;   // groups still to come, including the current one
	reg  [3:0] rxCount;
	reg  [9:0] rxPos;      // payload bytes taken so far in this frame
	reg        rxHoff;     // HOFF seen during the current group

	// LSB byte first on this direction, so index 0 is the LSB byte and
	// indices 1..7 are data bytes 0..6. Data byte n takes bit n; see the
	// header for the four sources that settle the order.
	wire [2:0] rxDataIdx = rxIdx - 3'd1;
	wire       rxLsbBit  = rxLsb[rxDataIdx];
	wire [7:0] rxDecoded = {writeData[6:0], rxLsbBit};
	wire [7:0] rxSumNext = rxSum + rxDecoded;

	// A frame is under way from the sync byte until the last group lands.
	wire       rxInFrame = (rxState != RX_SYNC);
	wire       rxTake    = writeReq & selected &
	                       ((state == 3'd1) | (rxInFrame & (state == 3'd0)));

	// ------------------------------------------------------------------
	// Transmit: drive -> Mac
	// ------------------------------------------------------------------
	localparam TX_IDLE = 3'd0, TX_WAIT = 3'd1, TX_SYNC = 3'd2,
	           TX_DATA = 3'd3, TX_LSB  = 3'd4, TX_END  = 3'd5,
	           TX_HOFF = 3'd6;

	reg  [2:0] txState;
	reg  [7:0] txTick;
	reg  [2:0] txIdx;        // data byte within the group, 0..6
	reg  [7:0] txLsbAcc;
	reg  [7:0] txSum;
	reg  [9:0] txSent;       // payload bytes emitted, including the checksum

	// A hold-off seen mid-group. The group is FINISHED anyway, and the flag is
	// acted on at the group BOUNDARY - the only place the Plus ROM, the HD20's
	// own firmware and TashTwenty all agree it may be acted on. There are
	// deliberately no saved-at-the-boundary copies of txAddr/txSent/txSum here
	// any more: nothing rewinds, so there is nothing to restore.
	reg        txHoff;

	reg        txGo;         // the payload is ready; see txArm/txReq above

	wire [9:0] txTotal  = txLen + 10'd1;              // payload + CHK
	wire       txIsChk  = (txSent == txLen);
	wire [7:0] txSource = txIsChk ? (~txSum + 8'd1) : txData;
	wire [7:0] txLsbSet = txLsbAcc | (8'd1 << txIdx);

	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			rxState      <= RX_SYNC;
			rxIdx        <= 0;
			rxLsb        <= 0;
			rxSum        <= 0;
			rxGroups     <= 0;
			rxCount      <= 0;
			rxPos        <= 0;
			rxHoff       <= 0;
			rxRspGroups  <= 0;
			rxBuf        <= 0;
			rxLen        <= 0;
			rxValid      <= 0;
			rxBad        <= 0;
			rxStb        <= 0;
			rxStbData    <= 0;
			rxStbAddr    <= 0;
			txGo         <= 0;
			txState      <= TX_IDLE;
			txTick       <= 0;
			txIdx        <= 0;
			txLsbAcc     <= 8'h80;
			txSum        <= 0;
			txSent       <= 0;
			txAddr       <= 0;
			txHoff       <= 0;
			txByte       <= 0;
			txBusy       <= 0;
			txAbort      <= 0;
			newByteReady <= 0;
			hshk_n       <= 1'b1;
			rxHs         <= RXH_IDLE;
			txPend       <= 1'b0;
		end
		else begin
			rxValid      <= 0;
			rxBad        <= 0;
			rxStb        <= 0;
			txAbort      <= 0;

			// NEWBYTEREADY MUST BE HELD UNTIL THE NEXT cen, NOT CLEARED ON
			// EVERY CLOCK. It is set below inside `if (cen)`, so an
			// unconditional clear here made it high for exactly the one clk
			// AFTER a cen tick - the clock on which cen is necessarily low.
			// iwm.v latches with `if (cen && newByteReady)`, so the two could
			// never coincide and not one reply byte could reach the data
			// latch. floppy.v sets and clears its own inside `if (cep)` for
			// this reason, which is why the floppy path never showed it.
			//
			// Clearing under cen instead spans the pulse from one cen tick to
			// the next: the IWM samples it high on the following tick, latches
			// the byte, and this clear drops it on that same tick. Exactly one
			// latch per byte. The clear comes BEFORE the transmit FSM below,
			// so a byte presented on a cen tick still overrides it.
			if (cen) newByteReady <= 0;

			// State 4 is RESET: the device performs the equivalent of a
			// power-up reset. Handled here rather than folded into _reset so
			// a mounted image is not disturbed.
			if (selected && state == 3'd4) begin
				rxState <= RX_SYNC;
				rxIdx   <= 0;
				rxCount <= 0;
				rxPos   <= 0;
				rxHoff  <= 1'b0;
				txState <= TX_IDLE;
				txBusy  <= 1'b0;
				txGo    <= 1'b0;
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
							// RE-SYNC THE BYTE FSM HERE. State 3 out of state 2
							// is always the start of a FRESH command, so any
							// rxState left over from a frame the Mac abandoned
							// mid-way is stale by definition. Without this the
							// receiver carries that state into the new frame and
							// never finds its sync again - which does not cause
							// the first error, but turns one into a reset cycle.
							rxState <= RX_SYNC;
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
				// The Mac transmits in state 1, and keeps transmitting the
				// rest of a group after it drops to state 0 for a hold-off.
				// writeReq is the IWM handing over a byte it has finished
				// shifting out. Note the hold-off latch below is set BEFORE
				// the case, so the group-boundary arm clears it cleanly.
				if (selected && rxState == RX_GROUP && state == 3'd0)
					rxHoff <= 1'b1;

				if (rxTake) begin
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
						rxPos   <= 0;
						rxHoff  <= 1'b0;
					end

					// A bare $AA after a hold-off, with no count bytes behind
					// it. Anything else -- the Mac's filler $00, or a byte
					// still in flight -- is skipped.
					RX_RESYNC:
						if (writeData == SYNC) begin
							rxState <= RX_GROUP;
							rxIdx   <= 3'd0;
						end

					RX_GROUP:
						if (rxIdx == 3'd0) begin
							rxLsb <= writeData;
							rxIdx <= 3'd1;
						end
						else begin
							rxSum <= rxSumNext;
							rxStb     <= 1'b1;
							rxStbData <= rxDecoded;
							rxStbAddr <= rxPos;
							rxPos     <= rxPos + 10'd1;
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
									// being stored this cycle. It SATURATES
									// at 8 above, because rxBuf holds eight,
									// so the clamp is not decoration: without
									// it a write's 77-group frame reports 9,
									// a length rxBuf cannot have.
									rxLen   <= (rxCount < 4'd8) ? (rxCount + 4'd1)
									                           : 4'd8;
									if (rxSumNext == 8'd0) rxValid <= 1'b1;
									else                   rxBad   <= 1'b1;
								end
								else begin
									rxGroups <= rxGroups - 7'd1;
									// The group is complete and counted; the
									// hold-off only costs us the byte framing,
									// so hunt the resync $AA and carry on.
									if (rxHoff) begin
										rxState <= RX_RESYNC;
										rxHoff  <= 1'b0;
									end
								end
							end
							else
								rxIdx <= rxIdx + 3'd1;
						end
					endcase
				end

				// ---------------- transmit ----------------
				// txReq can land in any state on the way in, so latch it here
				// rather than only where the frame starts.
				if (txReq) txGo <= 1'b1;

				case (txState)
				TX_IDLE: begin
					// Remember a one-clock txReq until the bus comes round to
					// state 2. DO NOT latch it from txArm as well, tempting as
					// that looks: txArm is a LEVEL and it is necessarily still
					// high for one clock after the frame it armed has finished,
					// because the command layer cannot know the frame is over
					// until it has seen txBusy fall. Latching that tail leaves
					// a phantom request behind, which then grabs the bus at the
					// start of the NEXT command - and the command layer reads
					// the resulting txBusy as "still sending" and drops the
					// command entirely. That cost an afternoon; the symptom was
					// a second Status going unanswered while the first was
					// perfect.
					if (txReq && selected) txPend <= 1'b1;
					else if (!txArm && !txGo) txPend <= 1'b0;

					// Only out of IDLE, and only with the bus idle: see txPend
					// above. Assert /HSHK to ask for the bus, then wait for the
					// Mac to come round to state 1. It goes 2 -> 3 -> 1.
					if ((txReq || txArm || txPend) && selected && state == 3'd2) begin
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
							txHoff    <= 1'b0;
					end
				end

				// Wait for the Mac to come round to state 1 -- but ONLY while
				// it is plausibly on its way. TashTwenty's Transmit spins on
				// states 2 and 3 and calls XAbort on anything else; without
				// that escape a drive that has asserted /HSHK holds it low for
				// ever if the Mac goes somewhere unexpected, which is a wedge
				// with no recovery and the second half of error $28.
				TX_WAIT:
					if (state == 3'd1) begin
						txState <= TX_SYNC;
						txTick  <= BYTE_TICKS;
					end
					// States 0-3 are all legitimate here: 2 and 3 are the Mac
					// on its way in, and 0 is a HOLD-OFF, which TX_DATA and
					// TX_LSB rewind to this state to wait out. Only 4-7 mean
					// the Mac has abandoned us - a reset, or the ID states as
					// it moves on to probe another device in the chain.
					else if (!selected || state >= 3'd4) begin
						hshk_n  <= 1'b1;
						txBusy  <= 1'b0;
						txGo    <= 1'b0;
						txAbort <= 1'b1;
						txState <= TX_IDLE;
					end

				// Armed, on the bus, and waiting for the payload. The Mac is
				// spinning on its $10000-try sync hunt, which is where a real
				// drive's seek time goes; state 0 here is a hold-off before we
				// have sent anything and is simply waited out. State 2 means
				// the Mac gave up, and without that escape a slow fetch that
				// the Mac abandoned would hold /HSHK low for ever.
				TX_SYNC:
					if (!selected || state == 3'd2 || state >= 3'd4) begin
						hshk_n  <= 1'b1;
						txBusy  <= 1'b0;
						txGo    <= 1'b0;
						txAbort <= 1'b1;
						txState <= TX_IDLE;
					end
					else if (cen && txGo) begin
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
				// A HOLD-OFF ARRIVING MID-GROUP DOES NOT ABANDON THE GROUP.
				// This rewound until 2026-09-05, on the strength of 1.2a pages
				// 4-5 ("that group will be ignored and will not be included in
				// the checksum ... restarts reading data with the group that
				// was interrupted"). Nothing real behaves that way, and the
				// prose is simply wrong:
				//
				//   Plus ROM  $41991C asserts HOFF only AFTER four bytes of the
				//             next group are already read; $419926-$419964 go on
				//             polling for the remaining four under an ~265 us
				//             budget and raise error $22 if they stop arriving.
				//             $41997A's `subq.w #1,d7` is the decrement the
				//             skipped `dbne` would have done, so nothing is
				//             backed up, and $419998 decodes the group in hand
				//             and reads the NEXT one - checksum included.
				//   firmware  L1f4c-L1fac tests the hold-off line only after
				//             the LSB byte of the group.
				//   TashTwenty XSuspend: "Resume transmission after interrupted
				//             group."
				//
				// The March-85 timing figure agrees in its own words at t3. So
				// remember the hold-off and keep sending; it is acted on at the
				// group boundary in TX_LSB.
				//
				// On hardware the rewind cost a stall and then a System Error,
				// reproducible on demand by moving the mouse during a transfer:
				// the mouse quadrature is on the SCC's DCD inputs, and the
				// driver asserts HOFF from SCC RR3 at byte 1 of every group.
				TX_DATA: begin
					if (state == 3'd0) txHoff <= 1'b1;
					// THE MAC'S ERROR EXIT LEAVES 3, THEN 2. Neither is
					// legitimate mid-group: the Mac reads in state 1 and only
					// goes to 3 once it has taken the whole frame, by which
					// time TX_END owns the release. Seeing either here means it
					// has walked away, and without this the transmitter went on
					// clocking bytes into a bus nobody was reading.
					if (!selected || state == 3'd2 || state == 3'd3 || state >= 3'd4) begin
						hshk_n  <= 1'b1;
						txBusy  <= 1'b0;
						txGo    <= 1'b0;
						txHoff  <= 1'b0;
						txAbort <= 1'b1;
						txState <= TX_IDLE;
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
				end

				TX_LSB: begin
					if (state == 3'd0) txHoff <= 1'b1;
					if (!selected || state == 3'd2 || state == 3'd3 || state >= 3'd4) begin
						hshk_n  <= 1'b1;
						txBusy  <= 1'b0;
						txGo    <= 1'b0;
						txHoff  <= 1'b0;
						txAbort <= 1'b1;
						txState <= TX_IDLE;
					end
					else if (cen) begin
						if (txTick != 0) txTick <= txTick - 8'd1;
						else begin
							txByte       <= txLsbAcc;
							newByteReady <= 1'b1;
							txTick       <= BYTE_TICKS;
							txIdx        <= 0;
							txLsbAcc     <= 8'h80;
							// THE GROUP BOUNDARY, and the only place a hold-off
							// is acted on. txAddr, txSent and txSum are left
							// exactly where they are: the group that just
							// finished counts, and it stays in the checksum.
							//
							// The last group is never held off - $4198EC's
							// `tst.w d7 / beq` feeds the `sne` that drives ph0L
							// - so TX_END wins the race if both are true.
							if (txSent >= txTotal)                txState <= TX_END;
							else if (txHoff || state == 3'd0)     txState <= TX_HOFF;
							else                                  txState <= TX_DATA;
						end
					end
				end

				// ACKNOWLEDGE THE HOLD-OFF, then resume with the NEXT group.
				// The March-85 timing figure puts the acknowledgement here and
				// nowhere else ("Rene will acknowledge the holdoff immediately
				// after the last byte of the group is sent"), and the firmware
				// does the same: release /HSHK, wait for the Mac to drop the
				// hold-off, re-assert, send a fresh $AA. The Mac hunts for that
				// sync at $419992 and then carries straight on, which is why
				// TX_SYNC is the right place to come back to - it emits the
				// sync and clears txIdx/txLsbAcc for the new group.
				//
				// The escapes matter as much as the resume. The ROM's error
				// exit leaves state 2 or 3 behind, and without these the
				// transmitter would hold /HSHK low there for ever - one half of
				// the $28 wedge, and what put `reply-abandoned-in-TX_WAIT` in
				// every crashed capture.
				TX_HOFF:
					if (!selected || state >= 3'd4 || state == 3'd2 || state == 3'd3) begin
						hshk_n  <= 1'b1;
						txBusy  <= 1'b0;
						txGo    <= 1'b0;
						txHoff  <= 1'b0;
						txAbort <= 1'b1;
						txState <= TX_IDLE;
					end
					else if (state == 3'd1) begin
						hshk_n  <= 1'b0;
						txHoff  <= 1'b0;
						txState <= TX_SYNC;
						txTick  <= BYTE_TICKS;
					end
					else hshk_n <= 1'b1;

				// THE `cen` HERE IS WHAT SAVES THE LAST BYTE OF EVERY FRAME.
				// readData only presents txByte while txBusy is set, and the
				// IWM latches a byte on the cen tick AFTER the one that
				// offered it. Tearing down on the very next clk instead
				// dropped txBusy inside that gap, so the CPU latched
				// {senseBit, 7'b0} = $80 in place of the final group's LSB
				// byte - which silently cleared bit 0 of all seven bytes of
				// the last group. Waiting for the next cen means txBusy is
				// still set at the instant the IWM samples (nonblocking, so
				// this clear lands after that edge), and the byte survives.
				//
				// It cost one cen tick, 125 ns, before /HSHK is released; the
				// Mac is spinning in state 3 waiting for exactly that release
				// and does not care.
				TX_END:
					if (cen) begin
						hshk_n  <= 1'b1;
						txBusy  <= 1'b0;
						txGo    <= 1'b0;
						txState <= TX_IDLE;
					end

				default: txState <= TX_IDLE;
				endcase
			end
		end
	end

	// The one derived value the deck cannot reconstruct from the outside: a
	// byte is only a RECEIVED byte if it arrives while we are selected and the
	// Mac is transmitting to us. writeReq alone also fires for the internal
	// drive, and a hold-off puts part of a group in state 0.
	wire rxByteEvt = rxTake;

	assign dbg_link = {rxBad, rxValid, newByteReady, rxByteEvt,
	                   txBusy, txState, rxHs, hshk_n, selected, state};

endmodule
