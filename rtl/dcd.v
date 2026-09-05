/* dcd.v - DCD (Apple HD20) device: command layer over rtl/dcd_link.v.

   MAC128K_PLAN.md Phase 5. Implements Status ($03), MultiBlock Read ($00),
   MultiBlock Write ($01/$41) and Write-Verify ($02/$42) over rtl/dcd_disk.v,
   and answers everything else with a NAK-shaped no-reply.

   THE WRITE FRAMING, read out of the ROM's own per-block loop at $419712:

     Write   from Mac:   <$AA> <$CD> <$81>
                         <op> <blks> <adrH> <adrM> <adrL> <pad>
                               <20 tags> <512 data> <CHK>     77 groups
             from drive: <$AA> <$80|op> <blks> <stat> <3 pad> <CHK>
                                                              1 group

   Four things about it are not guessable and all four come from that loop:

   1. EACH BLOCK IS A SEPARATE COMMAND, transmitted and answered in turn.
      $419712's `tst.b d1 / beq $419754` returns immediately for a read; only a
      write re-transmits. So unlike a read, the drive answers one group per
      command rather than sending N frames off one.
   2. SUBSEQUENT BLOCKS CARRY THE OPCODE WITH BIT 6 SET -- $419716's
      `ori.b #$40,$19C(a1)` -- so $01 continues as $41 and $02 as $42.
   3. THE REPLY OPCODE IS THE COMMAND OPCODE MASKED TO 6 BITS, THEN $80.
      $41975E masks the expected opcode with `andi.b #$3F` before $419776's
      `subi.b #$80` compare, so $41 must be answered $81 and NOT $C1 -- and,
      just as firmly, $02 must be answered $82 and not $81. Error $30 either
      way.
   4. THE DRIVE TRACKS THE BLOCK ADDRESS ITSELF ON A CONTINUED WRITE. The
      reply lands on top of the command block at $19C, so by the time $41971C
      rewrites the count byte the three address bytes at $19E-$1A0 hold the
      previous reply's status and padding -- zeros. Only $19D is refreshed.
      A drive that trusted the address would write every block of a multi-block
      write to block 0.

   The count byte at $19D is the number of blocks STILL TO GO, counting down,
   and the reply must echo it: $41978C compares it against the Mac's own d3
   before $4197EE decrements, and a mismatch is error $31. Echoing what we were
   sent is therefore both correct and the only thing we can do.

   WRITE-VERIFY IS SERVED AS A PLAIN WRITE, and that is a recorded deviation. A
   real HD20 wrote the block and read it back off the platter to compare. There
   is no platter here and no failure mode to detect between the sector buffer
   and the HPS that the block layer does not already report, so the read-back
   would compare a buffer against itself. The status byte still reports a
   refused or timed-out write, which is the part the driver acts on.

   MULTIBLOCK READ IS N SEPARATE TRANSMISSIONS, NOT ONE LONG ONE. The Mac sends
   the command once: $419712 returns immediately for opcode 0, and only a write
   re-transmits per block. Then it calls its receive engine N times, each call
   hunting a fresh $AA. So the drive fetches a block, sends a whole 77-group
   frame, fetches the next, sends again. TashTwenty's CmdRea0 loop is the same
   shape.

     Read    from Mac:   <$AA> <$81> <$CD> <$00> <blks> <adrH> <adrM> <adrL>
                                                              1 group
             from drive: N frames of
                         <$AA> <$80> <blks> <stat> <pad> <pad> <pad>
                               <20 tags> <512 data> <CHK>     77 groups each

   `blks` COUNTS DOWN FROM N TO 1 AND THE FIRST FRAME CARRIES N. The ROM's
   compare at $41978C precedes its decrement at $4197EE, and TashTwenty's
   `decfsz TX_BLKS,F` sits after its Transmit; a mismatch is error $31.

   THE 20 TAG BYTES ARE ZEROS, AND THAT IS A KNOWN DEVIATION. They are the
   file-system block tags of the MFS/HFS era, which a real HD20 stores on the
   medium beside each block; a plain disc image has nowhere to keep them.
   TashTwenty does not solve this either - its CmdRead carries a bare
   `;TODO clear 20 tag bytes too?` and ships whatever its buffer held, so zeros
   are strictly better than the only other implementation's behaviour. The Mac
   copies them to $2FC onward but the ROM does not validate them.

   AN ERROR IS ONE GROUP, NOT A SHORT DATA FRAME. TashTwenty answers a failed
   command by "setting the MSB of the status byte and sending only the header
   group", which is the shape this uses: txLen 6, one group.

   THE STATUS BYTE IS $81, NOT $80, AND THE REASON IS BIT 0. This file used to
   send $80 and this header used to say bit 7 "is exactly what the ROM tests at
   $4197DA". It is not. That `btst #24,d0` operates on the LONGWORD at $19E, so
   the bit it names is BIT 0 of the status byte. The drive's own firmware says
   the same (`Op_Failed EQU 001h`, DefsHD20.inc:291). 1.2a's $80 and
   TashTwenty's `bsf TX_STAT,7` are both invisible to this ROM, so with $80 a
   refused write - a read-only mount, an address out of range - was reported to
   the Mac as SUCCESS. $81 carries bit 0 for the ROM and bit 7 for everything
   that follows the document.

   THIS IS THE MAY 1985 REVISION OF THE PROTOCOL, 1.2a, NOT THE MARCH ONE.
   An earlier version of this file was built from
   `Software_Protocol_for_Directly_Connected_Disks_Mar85` (version 1.1) and was
   wrong in every structural dimension: a four-byte reply header, a 36-byte
   identity block lifted from the drive firmware, and a 42-byte reply. The
   shipping Plus ROM implements 1.2a, and asks for 332 identity bytes behind a
   six-byte header. See MAC128K_PLAN.md for the four ROM sites that settle it
   and for the two independent implementations that agree.

   THE FRAMING, all of it read out of ROM 4D1F8172 and cross-checked:

     Status  from Mac:   <$AA> <$81> <$B1> <$03> <5 more> <CHK>   1 group
             from drive: <$AA> <$83> <blks> <stat> <pad> <pad> <pad>
                               <332-byte identity block>
                               <4 pad> <CHK>                     49 groups

   The two count bytes are $80 | groups; $419ADC builds the pair with one
   `addi.l #$810081,d0`, so a Status command is one group out ($81) and 49
   groups back ($B1). 49 is not a constant here - it is whatever the Mac asked
   for, because that is what both real drive implementations do.

   The reply opcode is the command opcode with bit 7 set, which the ROM checks
   explicitly: $419776 does `subi.b #$80,$19C(a1)` and compares against the
   opcode it sent, erroring $30 on a mismatch.

   THE IDENTITY BLOCK, and where each value comes from:

     off  size  field              value
       0     2  Device_Type        0
       2     2  Device_Manuf       1, which 1.2a gives as "Apple = 1"
       4     1  Device_Character   $F6, or $DE on a locked image
       5     3  Num_Blocks         highest block = capacity - 1
       8     2  Num_Spares         0
      10     2  Num_BadBlocks      0
      12    52  Manuf_Reserved     0
      64   256  Icon               rtl/dcd_icon.vh
     320    12  trailer            a Pascal string -- and it is USER-VISIBLE

   Device_Character is $F6 on a writable mount and $DE on a locked one: the
   fixed bits are Mountable + Readable + Ejectable + Icon_Included +
   Disk_In_Place = $D6, and exactly one of Writable ($20) and Write_Protected
   ($08) joins them. It was pinned at $DE while MultiBlock Write was missing,
   because HFS writes the volume's MDB back at mount time to mark it in use
   and an unanswered opcode $01 turns that into a handshake timeout - a
   perfectly good read path presenting as a broken drive. With the write path
   in, the bit follows the image's own read-only flag, which is a state the Mac
   has handled natively since 1984.

   $F6 is Mountable + Readable + Writable + Ejectable + Icon_Included +
   Disk_In_Place, and TashTwenty writes exactly that constant, which is what
   confirms 1.2a's bit values are the shipping ones. A locked image trades $20
   for $08. EJECTABLE IS THE ONE BIT I AM NOT SURE OF - a fixed disk
   arguably should not claim it, and TashTwenty's own comment writes it
   "ejectable (?)". It is kept because $F6 is the value known to mount on real
   hardware; clearing it is the one-bit experiment if the Finder is ever seen
   to behave oddly about unmounting.

   NUM_BLOCKS IS CAPACITY MINUS ONE, and this is the one field held on someone
   else's empirical result rather than on a document. TashTwenty decrements it,
   commenting that "the block size of the drive is actually the maximum block
   on the drive" and flagging its own TODO. The DCD driver in the Plus ROM
   never reads the field - there is no reference to $1A2-$1AB anywhere in
   $419600-$419E40 - so it cannot be settled from the ROM. Minus one is the
   safe direction either way: if the Mac wants a count we lose one block of a
   volume, whereas if it wants a maximum and we send a count it can address one
   block past the end of the image.

   CAPACITY IS THE MOUNTED IMAGE, not the 20 MB a real unit had. Large volumes
   are a convenience, not accuracy - but the protocol was built for them
   (capacity and block number are both 24-bit) and the Floppy Emu serves up to
   2 GB in HD20 mode, so SonyDCD plainly accepts them. The ceiling is HFS, not
   DCD.
*/

module dcd
(
	input        clk,
	input        cep,
	input        cen,

	input        _reset,

	input        ca0,
	input        ca1,
	input        ca2,
	input        lstrb,
	input        _enable,

	input  [7:0] writeData,
	input        writeReq,
	output [7:0] readData,
	output       newByteReady,

	// ---- one hps_io block-device slot, see rtl/dcd_disk.v ----
	output [31:0] sd_lba,
	output        sd_rd,
	output        sd_wr,
	input         sd_ack,
	input   [7:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din,
	input         sd_buff_wr,

	input         img_mounted,
	input  [63:0] img_size,
	input         img_readonly,

	// A DCD image is mounted. rtl/iwm.v uses this to decide whether the
	// external drive port is a Sony or a DCD; with nothing mounted the port
	// behaves exactly as it always has.
	output        present,

	// ---- JTAG telemetry, decoded by rtl/dbg_probes.sv as PDCD/PDC2 --------
	// rtl/dcd_link.v's own 16 bits sit in the low half; the command layer adds
	// its state above them. Live values only -- see the note on `dbg_link`.
	//
	//   [15:0]  dbg_link, bit assignments in rtl/dcd_link.v
	//   [18:16] cstate                  [19]    present
	//   [27:20] opcode of the frame in rxBuf
	//   [28]    txReq   [29] disk busy   [30] disk err   [31] dcdReset
	output [31:0] dbg_dcd
);

`include "dcd_icon.vh"

	// ---- the sector path and the mount state it publishes ----
	wire        readonly;
	wire [23:0] blockCount;
	wire        diskBusy, diskErr;
	reg  [23:0] diskLba;
	reg         diskRd, diskWr;
	wire  [7:0] bufQ;

	// Byte 26 of a frame is data byte 0 in BOTH directions - six header bytes
	// then the 20 tags - so the same offset serves the read path's txAddr and
	// the write path's receive index. The subtraction is deliberately done on
	// the full 10-bit index and truncated after: 537-26 = 511 wraps correctly
	// either way, but only because the buffer is exactly 512 bytes.
	wire  [9:0] bufWrOff = rxStbAddr - 10'd26;
	wire        bufWe    = rxStb & (rxStbAddr >= 10'd26) & (rxStbAddr < 10'd538);
	wire  [8:0] bufAddr  = bufWe ? bufWrOff[8:0] : (txAddr[8:0] - 9'd26);

	dcd_disk disk
	(
		.clk(clk), ._reset(_reset),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.present(present), .blockCount(blockCount), .readonly(readonly),
		.lba(diskLba), .rd_req(diskRd), .wr_req(diskWr),
		.busy(diskBusy), .err(diskErr),
		.buf_addr(bufAddr), .buf_q(bufQ), .buf_d(rxStbData), .buf_we(bufWe)
	);

	wire        dcdReset;
	wire [63:0] rxBuf;
	wire [3:0]  rxLen;
	wire        rxValid, rxBad;
	wire [6:0]  rxRspGroups;
	wire        rxStb;
	wire [7:0]  rxStbData;
	wire [9:0]  rxStbAddr;
	wire [9:0]  txAddr;
	reg         txReq;
	reg  [9:0]  txLen;
	wire        txBusy;
	wire        txAbort;
	reg  [7:0]  txData;

	// /HSHK has to be claimed the moment a command is accepted, not when the
	// sector is ready: the Mac's receive routine checks the sense line with no
	// retry budget at all. See the txArm note in rtl/dcd_link.v. It stays up
	// for the whole command, which for a multi-block read is N frames. A reg
	// rather than `cstate != C_IDLE` so that it drops on the same edge the
	// last frame is retired, before the link's TX_IDLE can look at it again.
	reg         txArm;

	wire [7:0]  opcode = rxBuf[7:0];
	wire [15:0] dbg_link;

	dcd_link link
	(
		.clk(clk), .cep(cep), .cen(cen),
		._reset(_reset),
		.ca0(ca0), .ca1(ca1), .ca2(ca2), .lstrb(lstrb), ._enable(_enable),
		.writeData(writeData), .writeReq(writeReq),
		.readData(readData), .newByteReady(newByteReady),
		.present(present),
		.rxBuf(rxBuf), .rxLen(rxLen), .rxValid(rxValid), .rxBad(rxBad),
		.rxRspGroups(rxRspGroups),
		.rxStb(rxStb), .rxStbData(rxStbData), .rxStbAddr(rxStbAddr),
		.dcdReset(dcdReset),
		.txArm(txArm),
		.txReq(txReq), .txData(txData), .txAddr(txAddr), .txLen(txLen),
		.txBusy(txBusy), .txAbort(txAbort),
		.dbg_link(dbg_link)
	);

	// ------------------------------------------------------------------
	// Reply payload, addressed by txAddr
	// ------------------------------------------------------------------
	// Offsets past the end of the identity block read as zero, so a request
	// longer than 49 groups pads and a shorter one truncates - which is what a
	// drive that trusts the count byte necessarily does.

	// The 12-byte trailer at identity offset 320. BMOW's Floppy Emu treats
	// these as frame padding and TashTwenty puts its credits there, and this
	// said "nothing in the ROM reads them" -- which was true of the ROM and
	// WRONG about the machine.
	//
	// IT IS THE DRIVE NAME, AND IT IS USER-VISIBLE. Photographed 2026-09-05
	// under System 6: the Finder's Erase Disk alert reads
	//     Completely erase disk named "3.2 32MB (P)" (MiSTer HD20)?
	// -- volume name first, then THIS string as the drive. So it is a product
	// name shown to users, not padding, and changing it changes what they see.
	//
	// It also settles the format, which the next line used to hedge about: a
	// Pascal string was inferred from the shape of 1.2a's neighbouring fields,
	// and the Mac has now rendered it correctly, length byte and all, at this
	// exact offset. That is independent confirmation the identity block is
	// byte-accurate this far in -- from a field nothing was meant to read.
	function [7:0] trailerChar;
		input [3:0] i;
		begin
			case (i)
			4'd0:  trailerChar = 8'd11;   // Pascal length
			4'd1:  trailerChar = "M";
			4'd2:  trailerChar = "i";
			4'd3:  trailerChar = "S";
			4'd4:  trailerChar = "T";
			4'd5:  trailerChar = "e";
			4'd6:  trailerChar = "r";
			4'd7:  trailerChar = " ";
			4'd8:  trailerChar = "H";
			4'd9:  trailerChar = "D";
			4'd10: trailerChar = "2";
			4'd11: trailerChar = "0";
			default: trailerChar = 8'h00;
			endcase
		end
	endfunction

	wire [23:0] maxBlock = (blockCount == 24'd0) ? 24'd0 : (blockCount - 24'd1);

	// Device_Character. Everything but the write pair is fixed: Mountable,
	// Readable, Ejectable, Icon_Included, Disk_In_Place = $D6. Exactly one of
	// Writable ($20) and Write_Protected ($08) joins it.
	//
	// WRITE_IMPLEMENTED went true when MultiBlock Write landed; a read-only
	// mount still reports write-protected, which is a state the Mac has
	// handled natively since 1984.
	localparam WRITE_IMPLEMENTED = 1'b1;
	wire writeProtected = ~WRITE_IMPLEMENTED | readonly;
	wire [7:0] deviceChar = 8'hD6 | (writeProtected ? 8'h08 : 8'h20);

	// The four replies share a six-byte header and differ after it. The kind
	// is latched when the command is decoded rather than derived from the
	// opcode register, because a read answers N times and the opcode is long
	// gone by the last of them.
	localparam K_STATUS = 2'd0, K_READ = 2'd1, K_WRITE = 2'd2, K_ACK = 2'd3;
	reg [1:0] replyKind;
	reg [7:0] replyOp;
	reg [7:0] replyStat;
	reg [7:0] blksLeft;

	always @(*) begin
		// ---- the six-byte header, common to all four ----
		if      (txAddr == 10'd0)  txData = replyOp;
		else if (txAddr == 10'd1)  txData = (replyKind == K_READ ||
		                                     replyKind == K_WRITE) ? blksLeft
		                                                           : 8'h00;
		else if (txAddr == 10'd2)  txData = replyStat;
		else if (txAddr <  10'd6)  txData = 8'h00;  // three pads complete the header

		// ---- MultiBlock Write, and the generic ack: the header IS the reply ----
		else if (replyKind == K_WRITE || replyKind == K_ACK) txData = 8'h00;

		// ---- MultiBlock Read: 20 tag bytes then the sector ----
		else if (replyKind == K_READ)
			txData = (txAddr < 10'd26)  ? 8'h00 :     // tags; see the header
			         (txAddr < 10'd538) ? bufQ  :     // 512 bytes of block
			                              8'h00;

		// ---- Status: identity block, header is 6 bytes, so identity k is 6+k ----
		else if (txAddr <  10'd8)  txData = 8'h00;              // 0  Device_Type
		else if (txAddr == 10'd8)  txData = 8'h00;              // 2  Device_Manuf
		else if (txAddr == 10'd9)  txData = 8'h01;              //    ...= 1, Apple
		else if (txAddr == 10'd10) txData = deviceChar;         // 4  Device_Character
		else if (txAddr == 10'd11) txData = maxBlock[23:16];    // 5  Num_Blocks
		else if (txAddr == 10'd12) txData = maxBlock[15:8];
		else if (txAddr == 10'd13) txData = maxBlock[7:0];
		else if (txAddr <  10'd18) txData = 8'h00;              // 8  Num_Spares
		                                                        // 10 Num_BadBlocks
		else if (txAddr <  10'd70) txData = 8'h00;              // 12 Manuf_Reserved
		else if (txAddr < 10'd326) txData = dcd_icon_byte(txAddr[7:0] - 8'd70);
		else if (txAddr < 10'd338) txData = trailerChar(txAddr[3:0] - 4'd6);

		// ---- pad to the end of the last group; the link layer adds CHK ----
		else                       txData = 8'h00;
	end

	// ------------------------------------------------------------------
	// Dispatch
	// ------------------------------------------------------------------
	// A command arrives with its checksum already verified by the link layer.
	//
	// AN OPCODE WE DO NOT IMPLEMENT IS ANSWERED WITH AN EMPTY BLOCK, not
	// dropped. The Mac states an expected reply length with every command, so
	// a header-only group of that length is a well-formed answer to anything,
	// and it is what TashTwenty does: "respond to commands it doesn't know
	// with an empty block, which seems to frequently get interpreted as 'yup,
	// yeah, did the thing you said, everything's fine'. It certainly works for
	// Erase Disk, anyway." (Tashtari, 68kMLA "Deciphering DCD (Hard Disk 20)",
	// 2022-04-26 -- the author of the second implementation, posting a logic
	// analyser capture off a real HD20.)
	//
	// That capture is exactly this case, and it fixes the reply opcode:
	//
	//     Mac: 19 01 00 00 00 00      Mac: 1A 00 00 00 00 00
	//     DCD: 99 00 00 00 00 00      DCD: 9A 00 00 00 00 8A
	//
	// $19 is format and $1A is verify-format, the two operations behind
	// Initialize / Erase Disk. Neither is in the 1.2a diagnostic list or in
	// the Dec-84 Nisha firmware spec -- they postdate both -- but the Plus ROM
	// specifies the wire format completely at $419D08, whose
	// `andi.b #$3f,$19c(a1)` makes the expected reply opcode (op & $3F) | $80.
	// {2'b10, cmdOp} is that byte, and it agrees with the capture on both
	// commands. Before this, dropping $19 made Erase Disk sit through the
	// Mac's (deliberately long, $419D18) timeout and report "Initialization
	// failed"; the drive was never wedged and the disk was never touched.
	//
	// THE LIE IS BOUNDED ON PURPOSE. Saying "fine" to work we did not do is
	// harmless for $19/$1A specifically -- there are no sector boundaries to
	// lay down on an image file -- and it must not spread to anything that
	// ought to report a genuine failure. So the ack covers ONLY opcodes we do
	// not implement at all. A command we DO implement and then refuse still
	// takes its own path: a write that did not bring a full sector, or a
	// continued write with nothing to continue from, is still not answered
	// here, and the refused-write path still reports $81.
	//
	// A reply is exactly as long as the Mac asked for. txLen excludes the
	// checksum, so groups*7-1 puts CHK in the final slot of the final group.
	localparam C_IDLE  = 3'd0, C_FETCH = 3'd1, C_FETCH_GO = 3'd2,
	           C_WAIT  = 3'd3, C_SEND  = 3'd4, C_SENDING  = 3'd5;
	reg [2:0] cstate;
	reg       sending;

	// The command block is <opcode><blocks><addrH><addrM><addrL><pad>, which
	// is TashTwenty's RC_CMDN/RC_BLKS/RC_ADRH/RC_ADRM/RC_ADRL and the same six
	// bytes the ROM prefetches from $19C in its transmit prologue.
	wire  [7:0] cmdBlocks = rxBuf[15:8];
	wire [23:0] cmdLba    = {rxBuf[23:16], rxBuf[31:24], rxBuf[39:32]};
	wire  [9:0] askedLen  = {rxRspGroups, 3'b000} - {3'b000, rxRspGroups} - 10'd1;

	// Bit 6 is the continued-write marker; bits 5:0 are the opcode proper.
	wire  [5:0] cmdOp     = opcode[5:0];
	wire        cmdCont   = opcode[6];
	wire        cmdIsWr   = (cmdOp == 6'h01) || (cmdOp == 6'h02);

	// Opcodes with a real implementation below: Read, the two Writes, Status.
	// Tested on cmdOp rather than the whole byte so a continued form ($40/$41/
	// $42) counts as known too and cannot fall through to the generic ack.
	wire        cmdKnown  = (cmdOp == 6'h00) || cmdIsWr || (cmdOp == 6'h03);

	// A write command must have brought a whole sector with it. Without this
	// a truncated or malformed frame would commit whatever the buffer happened
	// to hold - which, after a read, is a different block of the user's disk.
	// Cleared by the frame that reports itself, so it is still the previous
	// frame's verdict on the cycle rxValid is read.
	reg lastLba_valid;
	reg [23:0] lastLba;
	reg wrFull;

	always @(posedge clk or negedge _reset) begin
		if (!_reset) wrFull <= 1'b0;
		else if (dcdReset) wrFull <= 1'b0;
		else if (rxStb && rxStbAddr == 10'd537) wrFull <= 1'b1;
		else if (rxValid || rxBad) wrFull <= 1'b0;
	end

	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			txArm     <= 1'b0;
			txReq     <= 1'b0;
			txLen     <= 10'd0;
			diskRd    <= 1'b0;
			diskWr    <= 1'b0;
			diskLba   <= 24'd0;
			lastLba   <= 24'd0;
			lastLba_valid <= 1'b0;
			blksLeft  <= 8'd0;
			replyKind <= K_STATUS;
			replyOp   <= 8'h83;
			replyStat <= 8'h00;
			cstate    <= C_IDLE;
			sending   <= 1'b0;
		end
		// A DCD reset abandons the command in flight. Without this the FSM
		// carries on into its reply after the reset, and the link layer ends up
		// holding /HSHK low in the idle state waiting for a transfer the Mac
		// has long since given up on -- the wedge HD Diag reports as $28.
		else if (dcdReset) begin
			txArm     <= 1'b0;
			txReq     <= 1'b0;
			diskRd    <= 1'b0;
			diskWr    <= 1'b0;
			blksLeft  <= 8'd0;
			lastLba_valid <= 1'b0;
			replyKind <= K_STATUS;
			replyOp   <= 8'h83;
			replyStat <= 8'h00;
			sending   <= 1'b0;
			cstate    <= C_IDLE;
		end
		else begin
			txReq  <= 1'b0;
			diskRd <= 1'b0;
			diskWr <= 1'b0;

			case (cstate)
			C_IDLE:
				if (rxValid && !txBusy && rxRspGroups != 7'd0) begin
					if (opcode == 8'h03) begin
						replyKind <= K_STATUS;
						replyOp   <= 8'h83;
						replyStat <= 8'h00;
						txLen     <= askedLen;
						txArm     <= 1'b1;
						lastLba_valid <= 1'b0;
						cstate    <= C_SEND;
					end
					else if (opcode == 8'h00 && cmdBlocks != 8'd0) begin
						replyKind <= K_READ;
						replyOp   <= 8'h80;
						blksLeft  <= cmdBlocks;
						diskLba   <= cmdLba;
						txLen     <= askedLen;
						txArm     <= 1'b1;
						lastLba_valid <= 1'b0;
						cstate    <= C_FETCH;
					end
					// A continued write with nothing to continue from is not a
					// command: the address would be the zeros the reply left
					// behind at $19E, so serving it would write block 0.
					else if (cmdIsWr && wrFull && (!cmdCont || lastLba_valid))
					begin
						replyKind <= K_WRITE;
						replyOp   <= {2'b10, cmdOp};
						blksLeft  <= cmdBlocks;
						diskLba   <= cmdCont ? (lastLba + 24'd1) : cmdLba;
						lastLba   <= cmdCont ? (lastLba + 24'd1) : cmdLba;
						lastLba_valid <= 1'b1;
						txLen     <= askedLen;
						txArm     <= 1'b1;
						cstate    <= C_FETCH;
					end
					// Anything with no implementation at all: header-only
					// group of the length the Mac asked for, success status,
					// no disk access. See the note above the FSM for why this
					// is bounded to unknown opcodes and cannot swallow a
					// refused write.
					else if (!cmdKnown) begin
						replyKind <= K_ACK;
						replyOp   <= {2'b10, cmdOp};
						replyStat <= 8'h00;
						txLen     <= askedLen;
						txArm     <= 1'b1;
						lastLba_valid <= 1'b0;
						cstate    <= C_SEND;
					end
				end

			// Read fetches, write commits. Same three states either way; the
			// block layer's busy/err handshake is identical.
			C_FETCH: begin
				diskRd <= (replyKind == K_READ);
				diskWr <= (replyKind == K_WRITE);
				cstate <= C_FETCH_GO;
			end

			// One clock for dcd_disk to act on the request: a good one raises
			// busy, a refused one raises err without ever going busy, and
			// C_WAIT below has to be able to tell those apart.
			C_FETCH_GO: cstate <= C_WAIT;

			C_WAIT:
				if (!diskBusy) begin
					// A failed fetch is answered, not dropped. TashTwenty
					// sends "only the header group" with the status MSB set.
					//
					// BUT THE MSB IS NOT WHAT THIS ROM TESTS, and the comment
					// here used to claim it was. `$4197DA btst #24,d0` operates
					// on the LONGWORD at $19E, so bit 24 of that longword is
					// BIT 0 of the status byte, not bit 7 - and the drive's own
					// firmware agrees (`Op_Failed EQU 001h`, DefsHD20.inc:291).
					// 1.2a's $80, TashTwenty's `bsf TX_STAT,7` and the $80 that
					// used to be written here are all invisible to it, so a
					// refused write was being reported to the Mac as SUCCESS.
					//
					// $81 carries both readings: bit 0 for the ROM, bit 7 for
					// the C_SENDING test below and for any host that follows
					// the document.
					// blksLeft is deliberately NOT reset here. The ROM checks
					// the reply's block byte against its own counter first
					// ($41978C, error $31) and only then looks at the status,
					// so zeroing it would report the wrong failure. TashTwenty
					// leaves TX_BLKS alone on its error path for the same
					// reason.
					if (diskErr) begin
						replyStat <= 8'h81;
						// A write reply is one group already, so only the
						// read's 77-group frame needs shortening.
						if (replyKind == K_READ) txLen <= 10'd6;
					end
					else replyStat <= 8'h00;
					cstate <= C_SEND;
				end

			C_SEND: begin
				txReq  <= 1'b1;
				cstate <= C_SENDING;
			end

			C_SENDING:
				// txBusy rises a clock after txReq and falls when the frame is
				// done, so this state has two phases: wait for it up, then
				// wait for it down. `sending` marks the second.
				//
				// AN ABANDONED FRAME IS NOT A FINISHED ONE, and txBusy alone
				// cannot tell them apart - it falls either way. The link now
				// says which, and a multiblock read must NOT arm the next block
				// into a bus the Mac has already left: that armed an
				// unsolicited frame, the Mac saw a drive talking out of turn,
				// and the recovery was a reset. Drop txArm and go back to
				// C_IDLE instead, and let the Mac re-issue.
				//
				// txArm is a LEVEL, so it is cleared HERE, one state before
				// the link's TX_IDLE can look at it again - the phantom-request
				// trap recorded in dcd_link.v's TX_IDLE comment.
				if (txAbort) begin
					sending <= 1'b0;
					txArm   <= 1'b0;
					cstate  <= C_IDLE;
				end
				else if (!sending) begin
					if (txBusy) sending <= 1'b1;
				end
				else if (!txBusy) begin
					sending <= 1'b0;
					// A write is one command per block: the Mac transmits
					// again for the next one. Only a read keeps going off a
					// single command.
					if (replyKind != K_READ || replyStat[7] || blksLeft <= 8'd1)
					begin
						txArm  <= 1'b0;
						cstate <= C_IDLE;
					end
					else begin
						blksLeft <= blksLeft - 8'd1;
						diskLba  <= diskLba + 24'd1;
						cstate   <= C_FETCH;
					end
				end

			default: begin
				txArm  <= 1'b0;
				cstate <= C_IDLE;
			end
			endcase
		end
	end

	// Assembled here rather than beside the link instance because `cstate` is
	// declared below it, and a forward reference from a continuous assignment
	// is not portable between iverilog and Quartus.
	assign dbg_dcd = {dcdReset, diskErr, diskBusy, txReq,
	                  opcode, present, cstate, dbg_link};

endmodule
