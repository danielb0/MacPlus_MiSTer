/* dcd.v - DCD (Apple HD20) device: command layer over rtl/dcd_link.v.

   MAC128K_PLAN.md Phase 5. Implements the Status command ($03) and answers
   everything else with a NAK-shaped no-reply. MultiBlock Read ($00), Write
   ($01) and Write-Verify ($02) need the HPS sector path and are not here yet.

   COMMAND AND REPLY FRAMING, all of it settled in the plan:

     Status  from Mac:   <$AA> <$03> <5 pad> <CHK>            7 bytes, 1 group
             from drive: <$AA> <$83> <pad> <stat>
                               <36-byte Identity Block> <pad> <pad> <CHK>
                                                              42 bytes, 6 groups

   The reply opcode is the command opcode with bit 7 set, which the Plus ROM
   checks explicitly: $419776 does `subi.b #$80,$19C(a1)` and then compares
   against the opcode it sent, erroring $30 on a mismatch.

   The March document draws the Status command with SIX pad bytes, making it 8
   bytes and not a whole group. That is one pad too many: Diagnostic is drawn
   <$04><5-byte pad><CHK> = 7, MultiBlock Read is 7, the ROM's own command
   block at SonyVars+$19C is 6 bytes plus the checksum = 7, and the group count
   the Mac sends for a Status is $81 - one group. Four reasons; the drawing is
   wrong.

   THE IDENTITY BLOCK IS TAKEN FROM A REAL HD20's FIRMWARE, not reconstructed.
   342-0343-B.bin holds it as a template at $00B7, and the first five fields
   decode exactly:

     'Rene-1 RM MH '   13 chars, the device name
     $000210           device type
     $3372             firmware revision - which matches the reassembly's own
                       "Rev. 3372", and is what confirms this IS the ID block
     $009835           capacity, 38965 blocks = 20.0 MB, and one more than
                       DefsHD20.inc's HiMaxLogical/MidMaxLogical/LoMaxLogical
                       = $009834, the highest user block
     532               bytes per block

   From byte 23 on the template decodes to nonsense (36657 cylinders, 16 heads,
   230 sectors). That is not a decode failure, it is the evidence that THE
   STORED TEMPLATE ENDS AFTER Bytes_per_block: the firmware detects Nisha or
   Rodime from the servo response at run time, so it cannot hold fixed
   geometry.

   TWO DELIBERATE CHOICES, both recorded rather than defaulted into:

   1. GEOMETRY IS RODIME RO552 - 305 cylinders, 4 heads, 32 sectors. The
      protocol document's example describes the Nisha mechanism (610/2/32), but
      it is not clear the HD20 ever shipped with one; production units were
      Rodime. Both give 305*4*32 = 610*2*32 = 39040 blocks, which is why the
      capacity works out either way and why the host almost certainly does not
      care. Change the three constants below to 610/2/32 for Nisha.

   2. CAPACITY IS THE MOUNTED IMAGE, not the 20 MB a real unit had. Large
      volumes are a convenience, not accuracy - but the protocol was built for
      them (capacity and block number are both 24-bit) and the Floppy Emu
      serves up to 2 GB in HD20 mode, so SonyDCD plainly accepts them. The
      ceiling is HFS, not DCD.

   Device type is $000210 here because that is what the drive actually sends.
   The March document's comment says $000110. The firmware is the device, so it
   wins - but if a host is ever seen to reject us, this is the first constant
   to try flipping.
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

	// ---- geometry reported in the identity block; see note 1 above ----
	localparam [15:0] CYLINDERS = 16'd305;   // Rodime RO552
	localparam [7:0]  HEADS     = 8'd4;
	localparam [7:0]  SECTORS   = 8'd32;
	localparam [23:0] POSS_SPARES = 24'd76;  // "76 for Rene", per the March document

	wire [63:0] rxBuf;
	wire [3:0]  rxLen;
	wire        rxValid, rxBad;
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
		.txReq(txReq), .txData(txData), .txAddr(txAddr), .txLen(txLen),
		.txBusy(txBusy)
	);

	// ------------------------------------------------------------------
	// Status reply payload, addressed by txAddr. The link layer appends the
	// checksum, so txLen is 41 and the frame on the wire is 42 = 6 groups.
	// ------------------------------------------------------------------
	// The name is 13 characters INCLUDING the trailing space; it is not
	// NUL-terminated and it is not length-prefixed.
	function [7:0] nameChar;
		input [3:0] i;
		begin
			case (i)
			4'd0:  nameChar = "R";
			4'd1:  nameChar = "e";
			4'd2:  nameChar = "n";
			4'd3:  nameChar = "e";
			4'd4:  nameChar = "-";
			4'd5:  nameChar = "1";
			4'd6:  nameChar = " ";
			4'd7:  nameChar = "R";
			4'd8:  nameChar = "M";
			4'd9:  nameChar = " ";
			4'd10: nameChar = "M";
			4'd11: nameChar = "H";
			default: nameChar = " ";
			endcase
		end
	endfunction

	always @(*) begin
		case (txAddr)
		10'd0:  txData = 8'h83;               // reply opcode = $03 | $80
		10'd1:  txData = 8'h00;               // pad
		10'd2:  txData = 8'h00;               // stat

		// ---- identity block, 36 bytes, payload offsets 3..38 ----
		10'd3,  10'd4,  10'd5,  10'd6,  10'd7,  10'd8,  10'd9,
		10'd10, 10'd11, 10'd12, 10'd13, 10'd14, 10'd15:
		        txData = nameChar(txAddr[3:0] - 4'd3);

		10'd16: txData = 8'h00;               // Device_Type $000210
		10'd17: txData = 8'h02;
		10'd18: txData = 8'h10;

		10'd19: txData = 8'h33;               // Firmware_Rev $3372
		10'd20: txData = 8'h72;

		10'd21: txData = blockCount[23:16];   // Capacity, 24-bit, big-endian
		10'd22: txData = blockCount[15:8];
		10'd23: txData = blockCount[7:0];

		10'd24: txData = 8'h02;               // Bytes_per_block = 532
		10'd25: txData = 8'h14;

		10'd26: txData = CYLINDERS[15:8];
		10'd27: txData = CYLINDERS[7:0];
		10'd28: txData = HEADS;
		10'd29: txData = SECTORS;

		10'd30: txData = POSS_SPARES[23:16];
		10'd31: txData = POSS_SPARES[15:8];
		10'd32: txData = POSS_SPARES[7:0];

		10'd33: txData = 8'h00;               // Num_spares = 0
		10'd34: txData = 8'h00;
		10'd35: txData = 8'h00;

		10'd36: txData = 8'h00;               // Num_bad = 0
		10'd37: txData = 8'h00;
		10'd38: txData = 8'h00;

		10'd39: txData = 8'h00;               // pad
		10'd40: txData = 8'h00;               // pad
		default: txData = 8'h00;
		endcase
	end

	// ------------------------------------------------------------------
	// Dispatch
	// ------------------------------------------------------------------
	// A command arrives, checksum already verified by the link layer. Only
	// Status is answered so far; a command we do not implement is dropped
	// rather than answered, which the Mac sees as its $11/$13 handshake
	// timeout - the same thing a real drive does when it cannot reply.
	always @(posedge clk or negedge _reset) begin
		if (!_reset) begin
			txReq <= 1'b0;
			txLen <= 10'd0;
		end
		else begin
			txReq <= 1'b0;
			if (rxValid && !txBusy && opcode == 8'h03) begin
				txLen <= 10'd41;   // 41 payload bytes; the link layer adds CHK
				txReq <= 1'b1;
			end
		end
	end

endmodule
