/* dcd.v - DCD (Apple HD20) device: command layer over rtl/dcd_link.v.

   MAC128K_PLAN.md Phase 5. Implements Status ($03) and MultiBlock Read ($00)
   over rtl/dcd_disk.v, and answers everything else with a NAK-shaped no-reply.
   Write ($01), Write-Verify ($02) and continued Write ($41) additionally need
   the link layer to stream RECEIVED data into the sector buffer - a write's
   first block rides with the command, far past the eight bytes rxBuf holds -
   and are not here yet.

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
   group", which is what this does: status $80, txLen 6, one group. Bit 7 of
   the status byte is exactly what the ROM tests at $4197DA `btst #$18,d0` on
   the longword at $19E.

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
       4     1  Device_Character   $F6
       5     3  Num_Blocks         highest block = capacity - 1
       8     2  Num_Spares         0
      10     2  Num_BadBlocks      0
      12    52  Manuf_Reserved     0
      64   256  Icon               rtl/dcd_icon.vh
     320    12  trailer            a Pascal string; nothing reads it

   $F6 is Mountable + Readable + Writable + Ejectable + Icon_Included +
   Disk_In_Place. TashTwenty writes exactly this constant, which is what
   confirms 1.2a's bit values are the shipping ones. EJECTABLE IS THE ONE BIT
   I AM NOT SURE OF - a fixed disk arguably should not claim it, and
   TashTwenty's own comment writes it "ejectable (?)". It is set because $F6 is
   the value known to mount on real hardware; $E6 is the one-bit experiment if
   the Finder is ever seen to behave oddly about unmounting.

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
	output        present
);

`include "dcd_icon.vh"

	// ---- the sector path and the mount state it publishes ----
	wire        readonly;
	wire [23:0] blockCount;
	wire        diskBusy, diskErr;
	reg  [23:0] diskLba;
	reg         diskRd;
	wire  [8:0] bufAddr = txAddr[8:0] - 9'd26;   // reply byte 26 is data byte 0
	wire  [7:0] bufQ;

	dcd_disk disk
	(
		.clk(clk), ._reset(_reset),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.present(present), .blockCount(blockCount), .readonly(readonly),
		.lba(diskLba), .rd_req(diskRd), .wr_req(1'b0),
		.busy(diskBusy), .err(diskErr),
		.buf_addr(bufAddr), .buf_q(bufQ), .buf_d(8'd0), .buf_we(1'b0)
	);

	wire [63:0] rxBuf;
	wire [3:0]  rxLen;
	wire        rxValid, rxBad;
	wire [6:0]  rxRspGroups;
	wire [9:0]  txAddr;
	reg         txReq;
	reg  [9:0]  txLen;
	wire        txBusy;
	reg  [7:0]  txData;

	wire [7:0]  opcode = rxBuf[7:0];

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
		.txReq(txReq), .txData(txData), .txAddr(txAddr), .txLen(txLen),
		.txBusy(txBusy)
	);

	// ------------------------------------------------------------------
	// Reply payload, addressed by txAddr
	// ------------------------------------------------------------------
	// Offsets past the end of the identity block read as zero, so a request
	// longer than 49 groups pads and a shorter one truncates - which is what a
	// drive that trusts the count byte necessarily does.

	// The 12-byte trailer at identity offset 320. BMOW's Floppy Emu treats
	// these as frame padding and TashTwenty puts its credits there; nothing in
	// the ROM reads them. A Pascal string is the shape 1.2a's neighbouring
	// fields suggest, so that is what goes in.
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

	// The two replies share a six-byte header and differ after it. replyRead
	// is latched when the command is decoded, not derived from the opcode
	// register, because a read answers N times and the opcode is long gone.
	reg       replyRead;
	reg [7:0] replyStat;
	reg [7:0] blksLeft;

	always @(*) begin
		// ---- the six-byte header, common to both ----
		if      (txAddr == 10'd0)  txData = replyRead ? 8'h80 : 8'h83;
		else if (txAddr == 10'd1)  txData = replyRead ? blksLeft : 8'h00;
		else if (txAddr == 10'd2)  txData = replyStat;
		else if (txAddr <  10'd6)  txData = 8'h00;  // three pads complete the header

		// ---- MultiBlock Read: 20 tag bytes then the sector ----
		else if (replyRead)
			txData = (txAddr < 10'd26)  ? 8'h00 :     // tags; see the header
			         (txAddr < 10'd538) ? bufQ  :     // 512 bytes of block
			                              8'h00;

		// ---- Status: identity block, header is 6 bytes, so identity k is 6+k ----
		else if (txAddr <  10'd8)  txData = 8'h00;              // 0  Device_Type
		else if (txAddr == 10'd8)  txData = 8'h00;              // 2  Device_Manuf
		else if (txAddr == 10'd9)  txData = 8'h01;              //    ...= 1, Apple
		else if (txAddr == 10'd10) txData = 8'hF6;              // 4  Device_Character
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
	// A command we do not implement is dropped rather than answered, which the
	// Mac sees as its $11/$13 handshake timeout - the same thing a real drive
	// does when it cannot reply. Answering with a malformed frame would be
	// worse than not answering.
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

	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			txReq     <= 1'b0;
			txLen     <= 10'd0;
			diskRd    <= 1'b0;
			diskLba   <= 24'd0;
			blksLeft  <= 8'd0;
			replyRead <= 1'b0;
			replyStat <= 8'h00;
			cstate    <= C_IDLE;
			sending   <= 1'b0;
		end
		else begin
			txReq  <= 1'b0;
			diskRd <= 1'b0;

			case (cstate)
			C_IDLE:
				if (rxValid && !txBusy && rxRspGroups != 7'd0) begin
					if (opcode == 8'h03) begin
						replyRead <= 1'b0;
						replyStat <= 8'h00;
						txLen     <= askedLen;
						txReq     <= 1'b1;
					end
					else if (opcode == 8'h00 && cmdBlocks != 8'd0) begin
						replyRead <= 1'b1;
						blksLeft  <= cmdBlocks;
						diskLba   <= cmdLba;
						txLen     <= askedLen;
						cstate    <= C_FETCH;
					end
				end

			C_FETCH: begin
				diskRd <= 1'b1;
				cstate <= C_FETCH_GO;
			end

			// One clock for dcd_disk to act on the request: a good one raises
			// busy, a refused one raises err without ever going busy, and
			// C_WAIT below has to be able to tell those apart.
			C_FETCH_GO: cstate <= C_WAIT;

			C_WAIT:
				if (!diskBusy) begin
					// A failed fetch is answered, not dropped. TashTwenty
					// sends "only the header group" with the status MSB set,
					// which is one group and exactly what the ROM's
					// btst #$18 at $4197DA looks for.
					// blksLeft is deliberately NOT reset here. The ROM checks
					// the reply's block byte against its own counter first
					// ($41978C, error $31) and only then looks at the status,
					// so zeroing it would report the wrong failure. TashTwenty
					// leaves TX_BLKS alone on its error path for the same
					// reason.
					if (diskErr) begin
						replyStat <= 8'h80;
						txLen     <= 10'd6;
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
				if (!sending) begin
					if (txBusy) sending <= 1'b1;
				end
				else if (!txBusy) begin
					sending <= 1'b0;
					if (replyStat[7] || blksLeft <= 8'd1) cstate <= C_IDLE;
					else begin
						blksLeft <= blksLeft - 8'd1;
						diskLba  <= diskLba + 24'd1;
						cstate   <= C_FETCH;
					end
				end

			default: cstate <= C_IDLE;
			endcase
		end
	end

endmodule
