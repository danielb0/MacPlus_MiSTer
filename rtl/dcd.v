/* dcd.v - DCD (Apple HD20) device: command layer over rtl/dcd_link.v.

   MAC128K_PLAN.md Phase 5. Implements the Status command ($03) and answers
   everything else with a NAK-shaped no-reply. MultiBlock Read ($00), Write
   ($01), Write-Verify ($02) and continued Write ($41) need the HPS sector path
   and are not here yet.

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

	input        present,
	input [23:0] blockCount   // capacity of the mounted image, in 512-byte blocks
);

`include "dcd_icon.vh"

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

	always @(*) begin
		if      (txAddr == 10'd0)  txData = 8'h83;  // opcode $03 with bit 7 set
		else if (txAddr == 10'd1)  txData = 8'h00;  // block count, not relevant here
		else if (txAddr == 10'd2)  txData = 8'h00;  // status, zero means no error
		else if (txAddr <  10'd6)  txData = 8'h00;  // three pads complete the header

		// ---- identity block: header is 6 bytes, so identity k is at 6+k ----
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
	// A command arrives, checksum already verified by the link layer. Only
	// Status is answered so far; a command we do not implement is dropped
	// rather than answered, which the Mac sees as its $11/$13 handshake
	// timeout - the same thing a real drive does when it cannot reply.
	//
	// The reply is exactly as long as the Mac asked for. txLen excludes the
	// checksum, so groups*7-1 puts CHK in the final slot of the final group.
	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			txReq <= 1'b0;
			txLen <= 10'd0;
		end
		else begin
			txReq <= 1'b0;
			if (rxValid && !txBusy && opcode == 8'h03 && rxRspGroups != 7'd0) begin
				txLen <= {rxRspGroups, 3'b000} - {3'b000, rxRspGroups} - 10'd1;
				txReq <= 1'b1;
			end
		end
	end

endmodule
