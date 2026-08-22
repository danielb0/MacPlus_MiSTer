/* verilator lint_off UNUSED */

// scsi.v
// implements a target only scsi device
  
module scsi
(
	input      clk,

	// scsi interface
	input 	  rst, // bus reset from initiator (ICR RST)
	input 	  sys_rst, // system/core reset, independent of the bus reset
	input 	  bus_busy, // another target on the bus currently holds BSY
	// CDROM targets only: drive present on the bus. A real AppleCD answers
	// selection with no disc inserted (the driver polls TEST UNIT READY to
	// detect insertion), so the CD target selects on this rather than on
	// `mounted`. Tied low it never answers at all, which makes the bus
	// bit-identical to a pre-CD build -- the period-purist switch and the A/B
	// lever if the new target misbehaves on hardware. Ignored when CDROM == 0.
	input 	  cd_enable,
	// CD-ROM command-set debug ladder (CDROM targets only). 0 = normal. 1..6
	// progressively re-enable commands so the OSD can bisect which one the
	// driver chokes on WITHOUT a rebuild; 7 = everything, same as 0. Every
	// command outside the enabled set answers CHECK CONDITION, which is a
	// legitimate SCSI response, so the bus stays healthy at every level.
	input [2:0] cd_dbg,
	// MODE SENSE content bisect (CDROM targets only). Hardware proved the
	// MECHANISM of answering 0x1a is fine -- state 1 boots with every command
	// enabled -- so the fault is in our response BYTES. These states add one
	// component at a time, all at the SAME transfer length so only content
	// varies, and every one is a response a real drive may legitimately give:
	//   0 full        1 header only    2 +block descriptor  3 +page shell
	//   4 -p30 body   5 -p0E body      6 -p2A body          7 full
	// Hardware walked 1, 2 and 3 green and 0 hangs, so the block descriptor
	// and the page code/length byte are exonerated and the fault is in a page
	// PAYLOAD (bytes 14+). States 4-6 suppress exactly one page's payload, so
	// the state that boots names the page.
	input [2:0] cd_ms_mode,
	input [3:0] cd_vendor_dbg,
	input 	  sel,
	input 	  atn, // initiator requests to send a message
	output 	  bsy, // target holds bus

	output 	  msg,
	output 	  cd,
	output 	  io,

	output 	  req,
	input 	  ack, // initiator acknowledges a request

	input   [7:0] din, // data from initiator to target
	output  [7:0] dout, // data from target to initiator

	// interface to io controller
	input         img_mounted,
	input  [31:0] img_blocks,
	output [31:0] io_lba,
	output reg 	  io_rd,
	output reg 	  io_wr,
	input         io_ack,

	input   [7:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din,
	input         sd_buff_wr
);

// SCSI device id
parameter [2:0] ID = 0;

// CD-ROM personality. 0 = direct-access disk (unchanged in every respect).
// 1 = AppleCD-compatible CD-ROM: SONY CDU-8004 identity, 2048-byte logical
// blocks served as 4 consecutive 512-byte HPS blocks (lba/tlen <<2 at latch
// time, so the whole ring/flush machinery below runs in 512-byte units without
// modification), READ TOC, sub-channel, eject, and no-disc sense.
//
// Every cd_* wire folds to a constant when CDROM == 0, so a disk target
// synthesizes to exactly what it did before this parameter existed.
//
// SCOPE (SCSI_UPGRADE_PLAN.md Phase 2): DATA CDs. The TOC is synthesized as a
// single data track spanning the disc, which is correct for ISO/data images --
// the overwhelming majority of what a Plus would ever mount. Multi-track and
// audio TOCs arrive in Phase 3 with the CD audio engine, which parses the real
// track list; this module's TOC serving is structured so that engine can
// replace the synthesized values without changing the response layout.
parameter CDROM = 0;

// Read-prefetch ring depth (number of 512-byte sectors held for reads). A real
// drive streams continuously off a spinning platter; the original two-sector
// double buffer stalled at every 512-byte boundary while the next block was
// fetched from the HPS. The ring keeps RING_BLOCKS sectors fetched AHEAD of the
// Mac so that latency is hidden. RING_LOG=1 reproduces the old double buffer
// exactly. WRITES are unchanged -- they stay on the two-slot buffer (slots 0/1).
// Ported from MacLC_MiSTer rtl/scsi.v, which uses the same value; we have ~475
// M10K free (§4 of SCSI_UPGRADE_PLAN.md) so the depth is not fit-constrained.
parameter  RING_LOG    = 5;             // log2(sectors); 5 => 32 sectors / 16KB
localparam RING_BLOCKS = 1 << RING_LOG; // sectors buffered for reads
localparam BUF_AW      = 8 + RING_LOG;  // dpram word-address width (256 words/sector)

// A core reset must tear the target down as thoroughly as a bus reset: without
// it a reset landing mid-command leaves this target holding BSY (the phase FSM
// is not otherwise cleared) and the ROM's next boot scan finds a busy bus.
wire any_rst = rst | sys_rst;

localparam PHASE_IDLE        = 3'd0;
localparam PHASE_CMD_IN      = 3'd1;
localparam PHASE_DATA_OUT    = 3'd2;
localparam PHASE_DATA_IN     = 3'd3;
localparam PHASE_STATUS_OUT  = 3'd4;
localparam PHASE_MESSAGE_OUT = 3'd5;
reg [2:0]  phase;

// ------------ sector buffer IO controller read/write -----------------------
// the buffer itself. Holds RING_BLOCKS sectors for reads; writes use slots 0/1.
reg sd_buff_sel;         // WRITE double-buffer half (unchanged path)
reg [22:0] rd_hps_blk;   // READ ring: # of sectors the HPS has delivered this command

// HPS sector-buffer byte order. buffer0 always holds the byte the Mac reads
// FIRST (even byte) and buffer1 the odd byte. The real MiSTer HPS packs WIDE
// words LITTLE-endian (disk byte0 -> sd_buff_dout[7:0]), which is what the lane
// mapping below assumes -- and what sim/tb_scsi_target.v's block-device model
// reproduces. The LC carries a second `ifdef VERILATOR mapping for its own
// bench, which packs big-endian; we have no such bench, so there is nothing to
// switch on and the lanes stay as they always were.

// Buffer addressing. READS span the whole RING_BLOCKS-sector ring; WRITES stay
// on the original two-slot double buffer so the freshly-validated write path is
// byte-for-byte unchanged. A command is either a read or a write, so the two
// schemes never collide on a port. The two-slot addresses are zero-extended to
// BUF_AW by assignment, so RING_LOG=1 still compiles and exactly reproduces the
// original double buffer.
wire [22:0] rd_cur_blk = data_cnt[31:9];                       // sector the Mac is reading
wire [RING_LOG-1:0] rd_hps_slot = rd_hps_blk[RING_LOG-1:0];
wire [BUF_AW-1:0] hps_addr_wr = {sd_buff_sel, sd_buff_addr};   // write flush: slot 0/1
wire [BUF_AW-1:0] mac_addr_wr = data_cnt[9:1];                 // Mac write: slot 0/1
// HPS side (port A): read fills target the ring fetch-slot; write flushes keep
// the original sd_buff_sel half.
wire [BUF_AW-1:0] hps_addr = cmd_write ? hps_addr_wr : {rd_hps_slot, sd_buff_addr};
// Mac side (port B): reads address the full ring; writes the 2-slot half.
wire [BUF_AW-1:0] mac_addr = (phase == PHASE_DATA_IN) ? mac_addr_wr : data_cnt[BUF_AW:1];

wire [7:0] buffer0_dout;
scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer0
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(sd_buff_dout[7:0]),
	.wren_a(sd_buff_wr),
	.q_a(sd_buff_din[7:0]),

	.address_b(mac_addr),
	.data_b(din),
	.wren_b(buffer0_wr),
	.q_b(buffer0_dout)
);

wire [7:0] buffer1_dout;
scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer1
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(sd_buff_dout[15:8]),
	.wren_a(sd_buff_wr),
	.q_a(sd_buff_din[15:8]),

	.address_b(mac_addr),
	.data_b(din),
	.wren_b(buffer1_wr),
	.q_b(buffer1_dout)
);

reg old_io_ack;
always @(posedge clk) begin
	old_io_ack <= io_ack;
	if (phase == PHASE_IDLE)
		sd_buff_sel <= 0;
	else
		if (old_io_ack & ~io_ack) sd_buff_sel <= !sd_buff_sel;

	// READ ring fetch counter: # of sectors the HPS has delivered this command.
	// Reset alongside data_cnt (any non-transfer phase); bump on each io_ack
	// falling edge during a read. Writes never touch it (they use sd_buff_sel).
	if (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN &&
	    phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT)
		rd_hps_blk <= 23'd0;
	else if (old_io_ack & ~io_ack & cmd_read)
		rd_hps_blk <= rd_hps_blk + 23'd1;
end

// -----------------------------------------------------------

// status replies
reg [7:0]  status;
`define STATUS_OK 8'h00
`define STATUS_CHECK_CONDITION 8'h02

// message codes
`define MSG_CMD_COMPLETE 8'h00
	
// drive scsi signals according to phase
assign msg = (phase == PHASE_MESSAGE_OUT);
assign cd = (phase == PHASE_CMD_IN) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);
assign io = (phase == PHASE_DATA_OUT) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);

// READ stall: for a block READ, the sector the Mac wants (rd_cur_blk) has not
// been fetched yet -- only sectors [0, rd_hps_blk) are in the ring. Gated on
// cmd_read because INQUIRY / READ CAPACITY / MODE SENSE / REQUEST SENSE also use
// DATA_OUT but serve data combinationally with no HPS fetch (rd_hps_blk stays
// 0), so they must NOT take this stall. Depth-independent; replaces the old
// two-slot "half being filled" test.
//
// This also closes the Phase 0 finding "req asserts ~2 cycles before io_rd on
// entering DATA_OUT": at data_cnt=0 both counters are 0, so rd_cur_blk >=
// rd_hps_blk holds and REQ is suppressed until the first sector has actually
// landed -- rather than depending on io_rd having had time to rise.
//
// `mounted` in the read clause: media loss mid-READ stops the ring refill, and
// holding the CPU on data that will never arrive wedges the guest. With the
// medium gone the read completes with stale bytes and the driver gets its error
// through the normal status path instead (MacLC finding, HW 2026-07-17).
//
// wr_pending is included in the write/non-data clauses: between a block's
// req_wr edge and the flush actually issuing, neither io_wr nor io_ack is high,
// so the old term dropped the busy indication for that window and one extra
// byte could land in the slot the flush had not read yet.
wire   rd_cur_unfilled = (rd_cur_blk >= rd_hps_blk);
wire   io_busy = (phase == PHASE_DATA_OUT && cmd_read && mounted && rd_cur_unfilled) ||
                 (phase == PHASE_DATA_IN  && (io_wr | wr_pending | io_ack) && data_cnt[9] == sd_buff_sel) ||
                 (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN && (io_rd | io_wr | wr_pending | io_ack));

// A zero-length data phase (allocation length 0) never sees an ACK edge, so
// data_complete -- which only sets on one -- would never assert and REQ would be
// held forever. Treat "no data expected" as done on entry.
wire   data_done = data_complete || (data_len == 32'd0);
wire   data_phase_complete = ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN)) && data_done;

assign req = (phase != PHASE_IDLE) && !ack && !io_busy && !data_phase_complete;

assign bsy = (phase != PHASE_IDLE);

assign dout = (phase == PHASE_STATUS_OUT)?status:
	 (phase == PHASE_MESSAGE_OUT)?`MSG_CMD_COMPLETE:
	 (phase == PHASE_DATA_OUT)?cmd_dout:
	 8'h00;

// de-multiplex different data sources
wire [7:0] cmd_dout =
		cmd_read?(data_cnt[0] ? buffer1_dout : buffer0_dout):
		cmd_inquiry?inquiry_dout:
		cmd_read_capacity?read_capacity_dout:
		cmd_mode_sense?mode_sense_dout:
		cmd_request_sense?request_sense_dout:
		cmd_cd_toc?cd_toc_byte(data_cnt, c1_op_r, c1_m, c1_s, c1_f):
		cmd_cd_toc43?cd_toc43_byte(data_cnt, t43_m, t43_s, t43_f):
		cmd_cd_subq?cd_subq_byte(data_cnt):
		cmd_cd_subq43?cd_subq43_byte(data_cnt):
		cmd_cd_astat?cd_astat_byte(data_cnt, cd_astat_vol_r):
		cmd_cd_hdr?cd_hdr_byte(data_cnt, cd_hdr_addr_r):
		8'h00;

// REQUEST SENSE (0x03) response: fixed-format sense data, 18 bytes.
//   byte 0  = 0x70  current error, no valid information field
//   byte 2  = sense key
//   byte 7  = 0x0a  additional sense length (10 => 18 total)
//   byte 12 = additional sense code (ASC)
// Unlike the LC -- whose disk path serves a static all-zeros NO SENSE block and
// keeps real keys for the CD target only -- this reports the actual reason the
// last command failed. Answering "NO SENSE" to the question "why did you CHECK?"
// is self-contradictory and gives a driver's retry logic nothing to act on. On
// the disk path there is exactly one error class, so the machinery is a register
// pair rather than the LC's CD state machine (see the sense latch below).
wire [7:0] request_sense_dout =
		(data_cnt == 32'd0 )?8'h70:
		(data_cnt == 32'd2 )?{4'd0, sense_key}:
		(data_cnt == 32'd7 )?8'h0a:
		(data_cnt == 32'd12)?sense_asc:
		8'h00;

// CDROM INQUIRY: a SONY CDU-8004, byte-exact from MAME's
// nscsi_cdrom_apple_device (data taken from an AppleCD 150 ROM). This is not a
// cosmetic vendor string -- Apple's CD-ROM extension binds only to drives it
// recognises, so the identity IS the compatibility. 5 + additional-length 0x31
// = 54-byte response.
function [7:0] cd_inquiry_byte;
	input [31:0] cnt;
	begin
		cd_inquiry_byte =
			(cnt == 32'd0 )?8'h05:  // CD-ROM device class
			(cnt == 32'd1 )?8'h80:  // removable
			(cnt == 32'd2 )?8'h02:  // ANSI SCSI-2 (dialect tier)
			(cnt == 32'd3 )?8'h02:
			(cnt == 32'd4 )?8'h31:  // additional length
			(cnt == 32'd8 )?"S":(cnt == 32'd9 )?"O":
			(cnt == 32'd10)?"N":(cnt == 32'd11)?"Y":
			((cnt >= 32'd12) && (cnt <= 32'd15))?" ":
			(cnt == 32'd16)?"C":(cnt == 32'd17)?"D":
			(cnt == 32'd18)?"-":(cnt == 32'd19)?"R":
			(cnt == 32'd20)?"O":(cnt == 32'd21)?"M":
			(cnt == 32'd22)?" ":(cnt == 32'd23)?"C":
			(cnt == 32'd24)?"D":(cnt == 32'd25)?"U":
			(cnt == 32'd26)?"-":(cnt == 32'd27)?"8":
			(cnt == 32'd28)?"0":(cnt == 32'd29)?"0":
			(cnt == 32'd30)?"4":(cnt == 32'd31)?" ":
			(cnt == 32'd32)?"1":(cnt == 32'd33)?".":
			(cnt == 32'd34)?"9":(cnt == 32'd35)?"a":
			(cnt == 32'd39)?8'hd0:(cnt == 32'd40)?8'h90:
			(cnt == 32'd41)?8'h27:(cnt == 32'd42)?8'h3e:
			(cnt == 32'd43)?8'h01:(cnt == 32'd44)?8'h04:
			(cnt == 32'd45)?8'h91:(cnt == 32'd47)?8'h18:
			(cnt == 32'd48)?8'h06:(cnt == 32'd49)?8'hf0:
			(cnt == 32'd50)?8'hfe:
			8'h00;
	end
endfunction

// output of inquiry command, identify as "SEAGATE ST225N" (disk) or the
// SONY CDU-8004 above (CD-ROM).
wire [7:0] inquiry_dout = (CDROM != 0) ? cd_inquiry_byte(data_cnt) : hd_inquiry_dout;
wire [7:0] hd_inquiry_dout =
		(data_cnt == 32'd4 )?8'd32:  // length

		(data_cnt == 32'd8 )?" ":(data_cnt == 32'd9 )?"S":
		(data_cnt == 32'd10)?"E":(data_cnt == 32'd11)?"A":
		(data_cnt == 32'd12)?"G":(data_cnt == 32'd13)?"A":
		(data_cnt == 32'd14)?"T":(data_cnt == 32'd15)?"E":
		(data_cnt == 32'd16)?" ":(data_cnt == 32'd17)?" ":
		(data_cnt == 32'd18)?" ":(data_cnt == 32'd19)?" ":
		(data_cnt == 32'd20)?" ":(data_cnt == 32'd21)?" ":
		(data_cnt == 32'd22)?" ":(data_cnt == 32'd23)?" ":
		(data_cnt == 32'd24)?" ":(data_cnt == 32'd25)?" ":

		(data_cnt == 32'd26)?"S":(data_cnt == 32'd27)?"T":
		(data_cnt == 32'd28)?"2":(data_cnt == 32'd29)?"2":
		(data_cnt == 32'd30)?"5":(data_cnt == 32'd31)?"N" + {5'd0, ID}: // TESTING. ElectronAsh.
		8'h00;

// output of read capacity command
//wire [31:0] capacity = 32'd41056;   // 40960 + 96 blocks = 20MB
//wire [31:0] capacity = 32'd1024096;   // 1024000 + 96 blocks = 500MB
// Initialised: a CDROM target answers MODE SENSE before any image has ever been
// mounted (drive present, no disc), so the capacity bytes must not be X.
reg [31:0] capacity = 32'd0;
reg        mounted = 0;
always @(posedge clk) begin
	if (img_mounted) begin
		if (|img_blocks) begin
			// CDROM: capacity is the LAST LBA in 2048-byte logical blocks, i.e.
			// the mounted 512-block count / 4 - 1.
			//
			// NOTE the disk path deliberately still reports img_blocks, not
			// img_blocks-1. READ CAPACITY is defined to return the last LBA, so
			// that is a pre-existing off-by-one which the LC fixed on its disk
			// path -- but changing it here would alter what every existing
			// user's driver sees, and Phase 2 is meant to be purely additive.
			// Logged in SCSI_UPGRADE_PLAN.md as a Phase 1 follow-up instead.
			capacity <= (CDROM != 0) ? ({2'b00, img_blocks[31:2]} - 1'd1)
			                         : img_blocks;
			if (!mounted) $display("Image mounted on target %d, size: %d", ID, img_blocks);
			mounted <= 1;
		end else
			mounted <= 0;
	end else if ((CDROM != 0) && cd_eject_pulse)
		// EJECT (Apple 0xC0, or standard 0x1B START/STOP with LoEj): drop the
		// medium. The next img_mounted pulse is the "disc inserted" edge the
		// AppleCD driver's insertion poll is waiting for. The HPS-side image
		// stays mounted, which is harmless -- the target simply reports no-disc
		// until the user mounts again.
		mounted <= 0;
end

wire [7:0] read_capacity_dout =
		(data_cnt == 32'd0 )?capacity[31:24]:
		(data_cnt == 32'd1 )?capacity[23:16]:
		(data_cnt == 32'd2 )?capacity[15:8]:
		(data_cnt == 32'd3 )?capacity[7:0]:
		(data_cnt == 32'd6 )?((CDROM != 0)?8'h08:8'd2): // block length 2048 (CD) / 512 (disk)
		8'h00;

// CDROM MODE SENSE(6): header + 8-byte block descriptor (12 bytes), with
// device-specific byte 0x80 (write-protected -- the medium is read-only) and
// block length 0x000800 = 2048. A page 0x30 request additionally appends the
// 24-byte "magic Apple page" (0x30, 0x00, "APPLE COMPUTER, INC   "), byte-exact
// from MAME's apple_magic, which some Apple drivers probe even on CD drives.
// NOTE on the argument lists here and below: every module signal a serving
// function depends on is passed IN, rather than read from the function body.
// A continuous assignment that calls a function gets its sensitivity from the
// call's arguments, so a signal read only inside the body does not retrigger
// it -- the response then carries the PREVIOUS command's decode until some
// other argument changes. That showed up as byte 0 (and only byte 0) of every
// CD response being stale, because data_cnt incrementing is what re-evaluated
// the assignment. Passing them in is correct by construction.
// Page 0x0E (CD Audio Control) and 0x2A (MM Capabilities) are NOT optional:
// the AppleCD driver asks for 0x0E directly during startup. Serving the bare
// 12-byte header for a page the driver armed a longer blind transfer for leaves
// the host waiting for bytes that never come -- BERR beats, SCSI Manager retry,
// boot wedge. That is the hang seen on hardware 2026-08-20 with the drive
// enabled. Lengths and payloads follow MacLC_MiSTer, which is known to work
// with this driver.
function [7:0] cd_mode_sense_byte;
	input [31:0] cnt;
	input [5:0]  page;
	input [31:0] cap;
	begin
		cd_mode_sense_byte =
			// ---- common header + block descriptor (bytes 0..11)
			(cnt == 32'd0 )?((page == 6'h30) ? 8'd35 :   // mode data length = total-1
			                 (page == 6'h0E) ? 8'd27 :
			                 (page == 6'h2A) ? 8'd37 : 8'd11):
			(cnt == 32'd2 )?8'h80:                      // WP (read-only medium)
			(cnt == 32'd3 )?8'd8:                       // block descriptor length
			(cnt == 32'd5 )?cap[23:16]:
			(cnt == 32'd6 )?cap[15:8]:
			(cnt == 32'd7 )?cap[7:0]:
			(cnt == 32'd10)?8'h08:                      // block length 0x000800 = 2048
			// ---- page 0x30: the "magic Apple page" (24 bytes, total 36)
			(page == 6'h30)?(
			   (cnt == 32'd12)?8'h30:
			   (cnt == 32'd14)?"A":(cnt == 32'd15)?"P":
			   (cnt == 32'd16)?"P":(cnt == 32'd17)?"L":
			   (cnt == 32'd18)?"E":(cnt == 32'd19)?" ":
			   (cnt == 32'd20)?"C":(cnt == 32'd21)?"O":
			   (cnt == 32'd22)?"M":(cnt == 32'd23)?"P":
			   (cnt == 32'd24)?"U":(cnt == 32'd25)?"T":
			   (cnt == 32'd26)?"E":(cnt == 32'd27)?"R":
			   (cnt == 32'd28)?",":(cnt == 32'd29)?" ":
			   (cnt == 32'd30)?"I":(cnt == 32'd31)?"N":
			   (cnt == 32'd32)?"C":
			   ((cnt >= 32'd33) && (cnt <= 32'd35))?" ":8'h00):
			// ---- page 0x0E: CD Audio Control (16 bytes, total 28)
			// Port/volume bytes are static here; Phase 3's audio engine makes
			// them the live MODE SELECT-writable state.
			(page == 6'h0E)?(
			   (cnt == 32'd12)?8'h0E:                   // page code
			   (cnt == 32'd13)?8'h0E:                   // page length = 14
			   (cnt == 32'd14)?8'h04:                   // IMMED=1, SOTC=0
			   (cnt == 32'd18)?8'd75:
			   (cnt == 32'd19)?8'd75:
			   (cnt == 32'd20)?8'h01:(cnt == 32'd21)?8'hff:  // port 0 -> ch1, full
			   (cnt == 32'd22)?8'h02:(cnt == 32'd23)?8'hff:  // port 1 -> ch2, full
			   8'h00):
			// ---- page 0x2A: MM Capabilities & Mechanical Status (26 B, total 38)
			(page == 6'h2A)?(
			   (cnt == 32'd12)?8'h2A:                   // page code
			   (cnt == 32'd13)?8'h18:                   // page length = 24
			   (cnt == 32'd16)?8'h71:  // multi-session | Mode 2 F2 | F1 | audio
			   (cnt == 32'd18)?8'h28:  // tray loading | eject
			   (cnt == 32'd19)?8'h03:  // separate channel mute | volume levels
			   (cnt == 32'd22)?8'h01:  // 256 volume levels
			   8'h00):
			8'h00;
	end
endfunction

// The minimum a conforming target may return: a 4-byte header declaring no
// block descriptor and no pages. Every dependency is a function ARGUMENT --
// a continuous assignment calling a function takes its sensitivity from the
// call's arguments, not from signals read inside the body.
function [7:0] cd_ms_bisect_byte;
	input [31:0] cnt;
	input [1:0]  m;
	input [5:0]  page;
	input [31:0] cap;
	reg          known;
	begin
		known = (page == 6'h30) || (page == 6'h0E) || (page == 6'h2A);
		cd_ms_bisect_byte =
			// ---- 4-byte mode parameter header (every state)
			(cnt == 32'd0)?((m == 2'd1) ? 8'd3 :
			                (m == 2'd2) ? 8'd11 :
			                (page == 6'h30) ? 8'd35 :
			                (page == 6'h0E) ? 8'd27 :
			                (page == 6'h2A) ? 8'd37 : 8'd11):
			(cnt == 32'd2)?8'h80:                        // WP
			(cnt == 32'd3)?((m == 2'd1) ? 8'd0 : 8'd8):  // block desc length
			(m == 2'd1)?8'h00:                           // state 1 ends here
			// ---- 8-byte block descriptor (states 2, 3)
			(cnt == 32'd5 )?cap[23:16]:
			(cnt == 32'd6 )?cap[15:8]:
			(cnt == 32'd7 )?cap[7:0]:
			(cnt == 32'd10)?8'h08:                       // block length 2048
			(m == 2'd2)?8'h00:                           // state 2 ends here
			// ---- page SHELL only: code + declared length, payload zeroed
			(cnt == 32'd12)?(known ? {2'd0, page} : 8'h00):
			(cnt == 32'd13)?((page == 6'h0E) ? 8'h0E :
			                 (page == 6'h2A) ? 8'h18 : 8'h00):
			8'h00;
	end
endfunction

// States 3..6 serve the full response with one page's PAYLOAD suppressed --
// byte 12 (page code) and byte 13 (declared length) still come from the real
// response, so the only thing that changes is the body. State 3 suppresses
// every page, 4/5/6 suppress one each.
wire cd_ms_kill_body = (cd_ms_mode == 3'd3) ||
                       ((cd_ms_mode == 3'd4) && (cd_page_r == 6'h30)) ||
                       ((cd_ms_mode == 3'd5) && (cd_page_r == 6'h0E)) ||
                       ((cd_ms_mode == 3'd6) && (cd_page_r == 6'h2A));

wire [7:0] mode_sense_dout =
		(CDROM == 0) ? hd_mode_sense_dout :
		((cd_ms_mode == 3'd1) || (cd_ms_mode == 3'd2))
		    ? cd_ms_bisect_byte(data_cnt, cd_ms_mode[1:0], cd_page_r, capacity) :
		(cd_ms_kill_body && (data_cnt >= 32'd14)) ? 8'h00 :
		cd_mode_sense_byte(data_cnt, cd_page_r, capacity);
wire [7:0] hd_mode_sense_dout =
		(data_cnt == 32'd3 )?8'd8:
		(data_cnt == 32'd5 )?capacity[23:16]:
		(data_cnt == 32'd6 )?capacity[15:8]:
		(data_cnt == 32'd7 )?capacity[7:0]:
		(data_cnt == 32'd10 )?8'd2:
		8'h00;

// =====================================================================
// CD-ROM response synthesis. Every wire here folds to a constant when
// CDROM == 0, so a disk target is unaffected.
// =====================================================================

// Decoded CDB parameters, LATCHED at command completion.
//
// Serving functions must not read the cmd[] array combinationally. This module
// already establishes that pattern for the disk path -- lba6/tlen6 are decoded
// from cmd[] once at cmd_cpl and latched into lba/tlen, and everything
// downstream reads the registers. The CD serve paths follow it for the same two
// reasons: it keeps a wide combinational cone off a memory's outputs, and a
// continuous assignment that reads an array element is not reliably re-evaluated
// when that element changes (Icarus does not retrigger it, which showed up as
// byte 0 of every CD response carrying the PREVIOUS command's decode while
// bytes 1+ were correct -- the data_cnt increment was what retriggered it).
reg [1:0]  c1_op_r        = 2'b00;   // Apple READ TOC operation, CDB[9][7:6]
reg [5:0]  cd_page_r      = 6'd0;    // MODE SENSE page code, CDB[2][5:0]
reg        cd_astat_vol_r = 1'b0;    // AUDIO STATUS asked for volumes, CDB[3]==1
reg [31:0] cd_alloc10_r   = 32'd0;   // raw 10-byte-CDB allocation, CDB[7:8]
reg [31:0] cd_hdr_addr_r  = 32'd0;   // READ HEADER address echo, CDB[2:5]

// A data CD's table of contents is: one track, number 1, type data (ADR/control
// 0x14), starting at LBA 0, plus a lead-out at the end of the disc. Everything
// is a constant except the lead-out address, which needs one LBA -> MSF
// conversion: m = lba/4500, s = (lba%4500)/75, f = lba%75.
//
// The two planes disagree on purpose, and this is easy to get wrong:
//   * the Apple 0xC1 plane reports raw LBA-derived MSF, in BCD
//   * the standard 0x43 plane reports MSF + 150 (the 2-second pre-gap), binary
// Both come from the same iterative subtract, run twice at mount time. That is
// ~150 cycles a pass against a mount event, so a real divider would be fabric
// spent on nothing.
function [7:0] cd_bin2bcd;   // 0..99
	input [7:0] v;
	begin
		cd_bin2bcd = ((v / 8'd10) << 4) | (v % 8'd10);
	end
endfunction

// Lead-out, in CD frames. For a data disc one frame is one 2048-byte logical
// block, so this is the 2048-block count == capacity + 1.
wire [31:0] toc_lo_lba = capacity + 1'd1;

reg [6:0]  toc_m, toc_s;
reg [31:0] toc_v;
reg [7:0]  c1_m  = 8'd0, c1_s  = 8'd0, c1_f  = 8'd0;   // 0xC1 plane, BCD
reg [7:0]  t43_m = 8'd0, t43_s = 8'd2, t43_f = 8'd0;   // 0x43 plane, binary
reg [1:0]  toc_st = 2'd0;
reg        toc_pass = 1'b0;
reg        toc_ready = 1'b0;
reg        cd_mount_d = 1'b0;

always @(posedge clk) begin
	// one cycle behind the mount so `capacity` (and therefore toc_lo_lba) is
	// already the new image's
	cd_mount_d <= img_mounted && (|img_blocks);

	if (any_rst) begin
		toc_st    <= 2'd0;
		toc_ready <= 1'b0;
	end else if (CDROM != 0) begin
		case (toc_st)
		2'd0: if (cd_mount_d) begin
			toc_v <= toc_lo_lba; toc_m <= 7'd0; toc_s <= 7'd0;
			toc_pass <= 1'b0; toc_ready <= 1'b0; toc_st <= 2'd1;
		end
		2'd1: if ((toc_v >= 32'd4500) && (toc_m != 7'd99)) begin
			toc_v <= toc_v - 32'd4500; toc_m <= toc_m + 7'd1;
		end else if (toc_v >= 32'd75) begin
			toc_v <= toc_v - 32'd75; toc_s <= toc_s + 7'd1;
		end else
			toc_st <= 2'd2;
		default: begin
			if (!toc_pass) begin
				c1_m <= cd_bin2bcd({1'b0, toc_m});
				c1_s <= cd_bin2bcd({1'b0, toc_s});
				c1_f <= cd_bin2bcd(toc_v[7:0]);
				// second pass: the same lead-out, +150, for the 0x43 plane
				toc_v <= toc_lo_lba + 32'd150;
				toc_m <= 7'd0; toc_s <= 7'd0;
				toc_pass <= 1'b1; toc_st <= 2'd1;
			end else begin
				t43_m <= {1'b0, toc_m};
				t43_s <= {1'b0, toc_s};
				t43_f <= toc_v[7:0];
				toc_ready <= 1'b1; toc_st <= 2'd0;
			end
		end
		endcase
	end
end

// ---- Apple vendor READ TOC (0xC1) ----------------------------------------
// The operation lives in the CONTROL byte's top two bits (cmd[9][7:6]) -- the
// AppleCD driver's actual dialect. Response planes:
//   00 -> {first track, last track (BCD), 0, 0}
//   01 -> lead-out {M, S, F, 0}, BCD
//   10 -> per-track descriptor {ADR/control, M, S, F}, BCD, indexed by CDB[5]
// With a single track, every descriptor request clamps to track 1 at LBA 0 --
// MAME's "keep returning the last track" behaviour, which is what a request
// running past the real track count is supposed to see.
function [7:0] cd_toc_byte;
	input [31:0] cnt;
	input [1:0]  op;
	input [7:0]  lo_m, lo_s, lo_f;
	begin
		case (op)
		2'b01:   cd_toc_byte = (cnt == 32'd0) ? lo_m :
		                       (cnt == 32'd1) ? lo_s :
		                       (cnt == 32'd2) ? lo_f : 8'h00;
		2'b10:   cd_toc_byte = (cnt[1:0] == 2'd0) ? 8'h14 : 8'h00;
		default: cd_toc_byte = (cnt == 32'd0) ? 8'h01 :   // first track
		                       (cnt == 32'd1) ? 8'h01 :   // last track, BCD
		                       8'h00;
		endcase
	end
endfunction
// Serve EXACTLY the allocation, zero-filled past the real payload (the serve
// functions already return 0 past their payload). A fixed-size response that
// ignores a larger allocation strands a blind host exactly like the page 0x0E
// under-serve did. Op 10 streams whole 4-byte descriptors.

// ---- standard READ TOC (0x43), format 0, MSF form ------------------------
// 20 bytes: 4-byte header, track 1 descriptor, lead-out (0xAA) descriptor.
// Track 1 starts at LBA 0, which in this plane is MSF 00:02:00.
function [7:0] cd_toc43_byte;
	input [31:0] cnt;
	input [7:0]  lo_m, lo_s, lo_f;
	begin
		cd_toc43_byte =
			(cnt == 32'd1 )?8'd18:   // data length = 20 - 2
			(cnt == 32'd2 )?8'h01:   // first track
			(cnt == 32'd3 )?8'h01:   // last track
			// track 1 descriptor [4..11]
			(cnt == 32'd5 )?8'h14:   // ADR 1 / control 4 (data track)
			(cnt == 32'd6 )?8'h01:   // track number
			(cnt == 32'd10)?8'd2:    // 00:02:00
			// lead-out descriptor [12..19]
			(cnt == 32'd13)?8'h14:
			(cnt == 32'd14)?8'hAA:   // lead-out track number
			(cnt == 32'd17)?lo_m:
			(cnt == 32'd18)?lo_s:
			(cnt == 32'd19)?lo_f:
			8'h00;
	end
endfunction

// ---- sub-channel ---------------------------------------------------------
// No audio engine yet (Phase 3), so the position is always "stopped at the
// start of track 1" and the audio status is 0x13 (play completed / stopped).
localparam [7:0] CD_AST_STOPPED = 8'h13;

// Apple READ Q SUBCODE (0xC2), 9 bytes:
// {control, track BCD, index, rel M/S/F, abs M/S/F}
function [7:0] cd_subq_byte;
	input [31:0] cnt;
	begin
		cd_subq_byte = (cnt == 32'd1) ? 8'h01 :   // track 1
		               (cnt == 32'd2) ? 8'h01 :   // index 1
		               8'h00;
	end
endfunction

// standard READ SUB-CHANNEL (0x42), format 1 (current position), 16 bytes
function [7:0] cd_subq43_byte;
	input [31:0] cnt;
	begin
		cd_subq43_byte =
			(cnt == 32'd1 )?CD_AST_STOPPED:
			(cnt == 32'd3 )?8'd12:    // data length
			(cnt == 32'd4 )?8'h01:    // format code: current position
			(cnt == 32'd5 )?8'h14:    // ADR/control
			(cnt == 32'd6 )?8'h01:    // track
			(cnt == 32'd7 )?8'h01:    // index
			(cnt == 32'd10)?8'd2:     // absolute MSF 00:02:00
			8'h00;                    // relative MSF 00:00:00
	end
endfunction

// Apple AUDIO STATUS (0xCC), 6 bytes. CDB[3]==1 asks for the channel volumes
// instead of the position; report both channels at full.
function [7:0] cd_astat_byte;
	input [31:0] cnt;
	input        vol_form;
	begin
		if (vol_form)
			cd_astat_byte = ((cnt == 32'd4) || (cnt == 32'd5)) ? 8'hff : 8'h00;
		else
			cd_astat_byte = (cnt == 32'd0) ? CD_AST_STOPPED :
			                (cnt == 32'd2) ? 8'h14 :
			                (cnt == 32'd4) ? 8'd2 : 8'h00;   // abs MSF 00:02:00
	end
endfunction

// READ HEADER (0x44), 8 bytes: {mode, 0, 0, 0, address}. LBA form only -- the
// MSF form needs an LBA->MSF divide this serve path does not have, and a clean
// rejection beats wrong data.
function [7:0] cd_hdr_byte;
	input [31:0] cnt;
	input [31:0] addr;
	begin
		cd_hdr_byte = (cnt == 32'd0) ? 8'h01 :   // mode 1 (data)
		              (cnt == 32'd4) ? addr[31:24] :
		              (cnt == 32'd5) ? addr[23:16] :
		              (cnt == 32'd6) ? addr[15:8]  :
		              (cnt == 32'd7) ? addr[7:0]   : 8'h00;
	end
endfunction

// buffer to store incoming commands
reg [3:0]  cmd_cnt;
reg [7:0]  cmd [9:0];

/* ----------------------- request data from/to io controller ----------------------- */

assign io_lba = lba;

// READ prefetch (ring): keep issuing sequential sector fetches while sectors
// remain (rd_hps_blk < tlen) and the ring has space (fetched no more than
// RING_BLOCKS ahead of the Mac). This is a LEVEL signal -- the fetch engine
// below pumps one sector per io_ack until the ring is full, hiding per-sector
// HPS latency, versus the old 1-deep "fetch the next one at byte 20" which
// stalled the CPU at every 512-byte boundary. rd_hps_blk >= rd_cur_blk is
// invariant (the Mac stalls via io_busy before it can pass the fetch frontier),
// so the subtraction never underflows.
wire [22:0] rd_blk_total  = {7'd0, tlen};
wire        rd_blk_remain = (rd_hps_blk < rd_blk_total);
wire        rd_ring_space = ((rd_hps_blk - rd_cur_blk) < RING_BLOCKS);
wire req_rd = (phase == PHASE_DATA_OUT) && cmd_read && (data_len != 32'd0) &&
              !data_complete && rd_blk_remain && rd_ring_space;

// generate an io_wr signal whenever a 512 byte block has been received or when the status
// phase of a write command has been reached.
// data_len != 0 guard: a zero-length WRITE reaches STATUS_OUT with no data phase;
// without the guard the STATUS_OUT clause would flush a stale sector-buffer block
// (the previous READ's data) to the command's LBA.
wire req_wr = ((((phase == PHASE_DATA_IN) && (data_cnt[8:0] == 0) && (data_cnt != 0)) || (phase == PHASE_STATUS_OUT)) && cmd_write && (data_len != 32'd0));

// wr_pending lives at module scope because io_busy must include it (see there).
reg wr_pending;

always @(posedge clk) begin
	reg old_wr;
	reg rd_busy;   // a read-prefetch sector fetch is outstanding

	// A reset aborts any in-flight/queued disk IO. Without this, io_rd/io_wr and
	// the pending latches survive it; if the Mac re-selects before a stale io_rd
	// clears via io_ack, the next CMD_IN sees io_busy=1 (phase!=DATA && io_rd),
	// REQ is suppressed, the command never transfers, the Mac times out and
	// resets again -- an intermittent reset/re-scan loop. It is also the Phase 0
	// finding that these registers have no reset at all and power up as X in
	// simulation, which made io_busy (and therefore req) X forever.
	if(any_rst || iostall_abort) begin
		io_rd      <= 1'b0;
		io_wr      <= 1'b0;
		wr_pending <= 1'b0;
		old_wr     <= 1'b0;
		rd_busy    <= 1'b0;
	end else begin
		old_wr <= req_wr;
		if(~old_wr & req_wr) wr_pending <= 1;

		// READ prefetch engine: while req_rd (sectors remain AND ring has space),
		// issue back-to-back sector fetches -- one per io_ack -- to keep the ring
		// filled ahead of the Mac. rd_busy holds across a fetch until rd_hps_blk
		// advances on the io_ack falling edge, so exactly one fetch is issued per
		// sector and the next can start immediately after.
		if(io_ack) io_rd <= 1'b0;
		else if(req_rd && !io_rd && !rd_busy) begin io_rd <= 1'b1; rd_busy <= 1'b1; end
		if(old_io_ack & ~io_ack) rd_busy <= 1'b0;

		// WRITE flush engine -- unchanged two-slot double-buffer behavior.
		if(io_ack) io_wr <= 1'b0;
		else if(wr_pending && !io_wr) begin io_wr <= 1'b1; wr_pending <= 0; end
	end
end

reg  stb_ack;
reg  stb_adv;
always @(posedge clk) begin
	reg old_ack;
	
	old_ack <= ack;
	stb_ack <= (~old_ack & ack); // on rising edge
	stb_adv <= (old_ack & ~ack); // on falling edge
end

reg buffer0_wr, buffer1_wr;

// store data on rising edge of ack, ...
always @(posedge clk) begin
	buffer0_wr <= 0;
	buffer1_wr <= 0;
	if(stb_ack) begin
		if(phase == PHASE_CMD_IN)  cmd[cmd_cnt] <= din;
		if(phase == PHASE_DATA_IN) begin
			buffer0_wr <= ~data_cnt[0];
			buffer1_wr <=  data_cnt[0];
		end
	end
end

// ... advance counter on falling edge
always @(posedge clk) begin
	if(phase == PHASE_IDLE) cmd_cnt <= 4'd0;
	else if(stb_adv && (phase == PHASE_CMD_IN) && (cmd_cnt != 15)) cmd_cnt <= cmd_cnt + 4'd1;
end

// count data bytes. don't increase counter while we are waiting for data from
// the io controller
reg [31:0] data_cnt;
reg        data_complete;

// For block transfers tlen contains the number of 512 bytes blocks to transfer.
// Most other commands have the bytes length stored in the transfer length field.
// And some have a fixed length idependent from any header field.
// The data transfer has finished once the data counter reaches this
// number.
//
// Allocation-length clamping. tlen6's 0 -> 256 mapping is the READ/WRITE(6)
// BLOCK-COUNT convention and does not apply to allocation lengths: for INQUIRY
// an allocation of 0 means "no data", and for REQUEST SENSE it means 4 bytes
// (the pre-SCSI-2 convention). Undo it for those, and never serve more than the
// response actually is -- over-serving leaves the initiator counting bytes that
// carry no meaning, under-serving leaves it armed for a transfer that never
// finishes. (MacLC root-caused a data-corruption class to exactly this.)
wire [31:0] alloc_len = (tlen == 16'd256) ? 32'd0 : {16'd0, tlen};
wire [31:0] sense_len = (tlen == 16'd256) ? 32'd4 : {16'd0, tlen};
// CD INQUIRY is 54 bytes (5 + additional-length 0x31); disk is the standard 36.
localparam [31:0] INQUIRY_LEN = (CDROM != 0) ? 32'd54 : 32'd36;
// The 10-byte CD commands carry their allocation raw in CDB[7:8]. tlen is
// <<2-scaled at latch time for READs only, so these must not use it.
// (latched as cd_alloc10_r at command completion -- see the CD decode block)

wire [31:0] data_len =
		 cmd_read_capacity?32'd8:
		 cmd_read?{ 7'd0, tlen, 9'd0 }:   // read command length is in 512 bytes blocks
		 cmd_write?{ 7'd0, tlen, 9'd0 }:  // write command length is in 512 bytes blocks
		 cmd_inquiry?((alloc_len < INQUIRY_LEN) ? alloc_len : INQUIRY_LEN):
		 cmd_request_sense?((sense_len < 32'd18) ? sense_len : 32'd18):
		 // ---- CD commands. 0x43/0x42 serve EXACTLY the allocation length,
		 // zero-filled past the real payload, with the header length fields
		 // still carrying the true size. Under-serving deadlocks: the Mac's
		 // blind-transfer primitive arms the FULL allocation and pumps for it,
		 // so a target that goes to STATUS early leaves the host armed with
		 // data that never comes (the LC chased this to a boot wedge).
		 // Every one of these serves EXACTLY the allocation, which is what the
		 // comment above has always claimed and what the code did not do. The
		 // caps that used to be here -- min(alloc, 512/64/16), and cd_toc_len's
		 // round-DOWN to a multiple of 4 -- are the same defect class proved on
		 // hardware for MODE SENSE, and cd32 shows all seven under-serving. One
		 // byte short deadlocks a blind initiator exactly as 227 short does.
		 // The byte functions already return 8'h00 past their real payload, so
		 // the extra length is zero fill.
		 cmd_cd_toc?cd_alloc10_r:
		 cmd_cd_toc43?cd_alloc10_r:
		 cmd_cd_subq43?cd_alloc10_r:
		 cmd_cd_subq?cd_alloc10_r:    // READ Q SUBCODE (9 real)
		 cmd_cd_astat?cd_alloc10_r:   // AUDIO STATUS (6 real)
		 cmd_cd_hdr?cd_alloc10_r:
		 cmd_cd_actl?cd_alloc10_r:    // AUDIO CONTROL: DataOut, discarded
		 ((CDROM != 0) && cmd_mode_select)?alloc_len:  // alloc 0 = no data (not 256)
		 // MODE SENSE serves the FULL allocation, padded with zeros past the
		 // real page data. The clamp that used to be here -- min(alloc,
		 // page size) -- was the 2026-08-21 "+MODE" boot hang: a real driver
		 // arms a generous buffer (0xff) or asks for page 0x3f and pumps
		 // blind for every byte, so stopping at the page's real size strands
		 // it forever. Byte 0 still reports the real data length, which is how
		 // the host knows where the padding starts. This matches the disk
		 // path, which has always served the full `tlen`.
		 ((CDROM != 0) && cmd_mode_sense)?alloc_len:
		 { 16'd0, tlen };                 // anything else: length in bytes

always @(posedge clk) begin
	if((phase != PHASE_DATA_OUT) && (phase != PHASE_DATA_IN) && (phase != PHASE_STATUS_OUT) && (phase != PHASE_MESSAGE_OUT)) begin
		data_cnt <= 0;
		data_complete <= 0;
	end else begin	
		if(stb_adv)begin	
			if(!data_complete) data_cnt <= data_cnt + 1'd1;
			data_complete <= (data_len - 1'd1) == data_cnt;
		end
	end
end

// check whether status byte has been sent
reg status_sent;
always @(posedge clk) begin
	if(phase != PHASE_STATUS_OUT) status_sent <= 0;
	else if(stb_adv) status_sent <= 1;
end

// check whether message byte has been sent
reg message_sent;
always @(posedge clk) begin
	if(phase != PHASE_MESSAGE_OUT) message_sent <= 0;
	else if(stb_adv) message_sent <= 1;
end

/* ----------------------- command decoding ------------------------------- */


// parse commands
wire [7:0] op_code = cmd[0];
wire [2:0] cmd_group = op_code[7:5];

// check if a complete command has been received
wire       cmd_cpl = cmd6_cpl || cmd10_cpl || cmd12_cpl;
wire       cmd6_cpl = (cmd_group == 3'b000) && (cmd_cnt == 6);
// Apple CD vendor commands 0xC0-0xCE are ALL 10-byte CDBs (MAME
// nscsi_cdrom_apple_device: command & 0xf0 == 0xc0 -> 10).
wire       cmd_apple_cd_op = (CDROM != 0) && (op_code[7:4] == 4'hc);
wire       cmd10_cpl = (((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10))
                       || (cmd_apple_cd_op && (cmd_cnt == 10));
// Group 5 (0xA0-0xBF) = 12-byte CDBs, defined in SCSI-1. Nothing completed them
// before: the target sat in PHASE_CMD_IN forever, holding BSY, so any 12-byte
// command from any initiator wedged the bus until a reset -- a latent hang, never
// hit in practice only because MacOS sends none. Completing them makes an unknown
// group-5 opcode CHECK with invalid-op and release the bus, which is what a real
// drive does. Only cmd[0..9] are stored (the array is 10 deep and out-of-range
// writes are discarded); bytes 10-11 of a group-5 CDB are reserved + CONTROL.
wire       cmd12_cpl = (cmd_group == 3'b101) && (cmd_cnt == 12);

// https://en.wikipedia.org/wiki/SCSI_command
wire       cmd_read = cmd_read6 || cmd_read10;
wire       cmd_read6 = (op_code == 8'h08);
wire       cmd_read10 = (op_code == 8'h28);
wire       cmd_write = cmd_write6 || cmd_write10;
wire       cmd_write6 = (op_code == 8'h0a);
wire       cmd_write10 = (op_code == 8'h2a);
wire       cmd_inquiry = (op_code == 8'h12);
wire       cmd_format = (op_code == 8'h04);
wire       cmd_mode_select = (op_code == 8'h15);
wire       cmd_mode_sense = (op_code == 8'h1a);
wire       cmd_test_unit_ready = (op_code == 8'h00);
wire       cmd_read_capacity = (op_code == 8'h25);
wire       cmd_read_buffer = (op_code == 8'h3b);  // fake
wire       cmd_write_buffer = (op_code == 8'h3c); // fake
wire       cmd_verify6 = (op_code == 8'h13); // fake
wire       cmd_verify10 = (op_code == 8'h2f); // fake
// REQUEST SENSE (0x03) is MANDATORY in SCSI-1 for direct-access devices: after
// any CHECK CONDITION the initiator issues it to recover the sense data. The
// target previously rejected it (cmd_ok=0 -> CHECK CONDITION), so on hardware --
// where a transient error triggers the recovery path -- the Mac could never
// clear the condition and wedged.
wire       cmd_request_sense = (op_code == 8'h03);

// ----- Apple CD-ROM command set (CDROM targets only; all fold to 0 on disks).
// Oracle: MAME nscsi_cdrom_apple_device.
wire       cmd_cd_eject     = (CDROM != 0) && (op_code == 8'hc0);  // EJECT DISC
wire       cmd_cd_toc       = (CDROM != 0) && (op_code == 8'hc1);  // READ TOC (BCD/MSF)
wire       cmd_cd_subq      = (CDROM != 0) && (op_code == 8'hc2);  // READ Q SUBCODE (9 B)
wire       cmd_cd_astat     = (CDROM != 0) && (op_code == 8'hcc);  // AUDIO STATUS (6 B)
wire       cmd_cd_actl      = (CDROM != 0) && (op_code == 8'hce);  // AUDIO CONTROL (DataOut, discarded)
wire       cmd_cd_toc43     = (CDROM != 0) && (op_code == 8'h43);  // standard READ TOC
wire       cmd_cd_subq43    = (CDROM != 0) && (op_code == 8'h42);  // standard READ SUB-CHANNEL
wire       cmd_cd_hdr       = (CDROM != 0) && (op_code == 8'h44);  // READ HEADER
wire       cmd_cd_prevent   = (CDROM != 0) && (op_code == 8'h1e);  // PREVENT/ALLOW MEDIUM REMOVAL
wire       cmd_cd_startstop = (CDROM != 0) && (op_code == 8'h1b);  // START/STOP UNIT
wire       cmd_cd_setspeed  = (CDROM != 0) && (op_code == 8'hbb);  // SET CD SPEED (12-byte CDB)
// Audio transport. Phase 2 has no PCM path, so these are accepted as no-op
// GOOD rather than rejected: a CD player that gets CHECK on STOP raises an
// error dialog, and on a data disc these are never issued in the first place.
// Phase 3 makes them real. 0x01 REZERO and SEEK(6)/(10) carry Annex-C
// stop-audio semantics and are the AppleCD player's actual STOP button.
wire       cmd_cd_audio_nop = (CDROM != 0) && ((op_code == 8'hc8) || (op_code == 8'hc9) ||
                                               (op_code == 8'hca) || (op_code == 8'hcb) ||
                                               (op_code == 8'hcd) ||
                                               (op_code == 8'h47) || (op_code == 8'h48) ||
                                               (op_code == 8'h4b) || (op_code == 8'h4e) ||
                                               (op_code == 8'h01) ||
                                               (op_code == 8'h0b) || (op_code == 8'h2b) ||
                                               (op_code == 8'h45) || (op_code == 8'ha5));
// BOTH eject forms: the Apple vendor 0xC0 and the standard START/STOP UNIT
// with LoEj=1 / Start=0, which is how the System 7 AppleCD driver actually
// ejects. Missing the 0x1B form means `mounted` never drops, the driver's
// insertion poll sees READY and silently remounts the volume.
wire       cmd_cd_eject_any = cmd_cd_eject ||
                              (cmd_cd_startstop && cmd[4][1] && !cmd[4][0]);

// valid command in buffer? TODO: check for valid command parameters
wire  cmd_ok_hd = cmd_read || cmd_write || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_format || cmd_mode_sense ||
		  cmd_read_buffer || cmd_write_buffer || cmd_verify6 || cmd_verify10 ||
		  cmd_request_sense;

// The CD is READ-ONLY: WRITE / FORMAT / VERIFY / WRITE BUFFER are deliberately
// absent, so they CHECK with ILLEGAL REQUEST exactly as a real AppleCD does.
wire  cmd_ok_cd = cmd_read || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_mode_sense ||
		  cmd_request_sense || cmd_cd_eject || cmd_cd_toc || cmd_cd_subq ||
		  cmd_cd_astat || cmd_cd_actl || cmd_cd_audio_nop ||
		  cmd_cd_toc43 || cmd_cd_subq43 || cmd_cd_hdr ||
		  cmd_cd_prevent || cmd_cd_startstop || cmd_cd_setspeed;

// Debug ladder. Each level adds one command class on top of the previous.
//   1 INQUIRY   2 +TEST UNIT READY   3 +REQUEST SENSE
//   4 +READ CAPACITY   5 +MODE SENSE   6 +READ
wire  cmd_ok_cd_dbg = cmd_inquiry
                   || ((cd_dbg >= 3'd2) && cmd_test_unit_ready)
                   || ((cd_dbg >= 3'd3) && cmd_request_sense)
                   || ((cd_dbg >= 3'd4) && cmd_read_capacity)
                   || ((cd_dbg >= 3'd5) && cmd_mode_sense)
                   || ((cd_dbg >= 3'd6) && cmd_read);

wire  cmd_ok_cd_sel = ((cd_dbg == 3'd0) || (cd_dbg == 3'd7)) ? cmd_ok_cd : cmd_ok_cd_dbg;

// Apple vendor-command bisect (status[28:25]). The MODE SENSE page bisect
// showed the magic page 0x30 body is a GATE: serve it and the driver commits
// to the Apple vendor path, then wedges. Six content/length fixes later the
// wedge is unchanged, so this suppresses ONE vendor command at a time to name
// which one the driver cannot get past.
//   0 off   1 -C1 TOC   2 -C2 subQ   3 -CC astat   4 -CE actl
//   5 -42 subch10   6 -43 TOC10   7 -44 header   8 -all four Apple opcodes
//   9 unknown opcodes complete GOOD instead of CHECK CONDITION
// State 9 is the one a suppression bisect cannot reach: it tests whether the
// driver wedges on an opcode we REJECT rather than one we answer. A suppressed
// command CHECKs, which is an artificial drive state -- read these as boundary
// evidence only, never as mechanism (the ladder lesson).
wire  cd_vend_all  = (cd_vendor_dbg == 4'd8);
wire  cd_vend_supp =
        (((cd_vendor_dbg == 4'd1) || cd_vend_all) && cmd_cd_toc)   ||
        (((cd_vendor_dbg == 4'd2) || cd_vend_all) && cmd_cd_subq)  ||
        (((cd_vendor_dbg == 4'd3) || cd_vend_all) && cmd_cd_astat) ||
        (((cd_vendor_dbg == 4'd4) || cd_vend_all) && cmd_cd_actl)  ||
        ((cd_vendor_dbg == 4'd5) && cmd_cd_subq43) ||
        ((cd_vendor_dbg == 4'd6) && cmd_cd_toc43)  ||
        ((cd_vendor_dbg == 4'd7) && cmd_cd_hdr);
// Unknown-opcode-OK: cmd_ok=1 while no data-phase clause matches, so the
// dispatch falls through to STATUS_OUT -- a complete, zero-length GOOD.
wire  cd_vend_unk_ok = (cd_vendor_dbg == 4'd9);
wire  cmd_ok_cd_bis  = cd_vend_unk_ok ? 1'b1 : (cmd_ok_cd_sel && !cd_vend_supp);
wire  cmd_ok = (CDROM != 0) ? cmd_ok_cd_bis : cmd_ok_hd;

// Media-dependent commands fail with the AppleCD no-disc sense while no image
// is mounted. MAME's return_no_cd uses SK_NOT_READY + the vendor ASC 0xB0 --
// NOT the obvious 0x3A "medium not present", because 0x3A makes MacOS hammer
// the drive asking the user to format it.
wire  cd_needs_media = cmd_test_unit_ready || cmd_read || cmd_read_capacity ||
		  cmd_cd_toc || cmd_cd_subq || cmd_cd_astat || cmd_cd_actl ||
		  cmd_cd_toc43 || cmd_cd_subq43 || cmd_cd_hdr || cmd_cd_audio_nop;
// !toc_ready: the lead-out MSF conversion runs for ~150 cycles after a mount.
// Serving media commands in that window returned the PREVIOUS disc's TOC, which
// is the wrong answer after a disc swap. Report the drive as not-ready-yet
// instead -- the correct SCSI answer for a drive still spinning up, and what the
// driver's retry path already handles. (Quartus caught this: toc_ready was
// assigned but never read, i.e. the readiness flag existed but gated nothing.)
wire  cd_no_media = (CDROM != 0) && (!mounted || !toc_ready) && cd_needs_media;

// READ HEADER in MSF form: rejected (see cd_hdr_byte).
wire  cd_hdr_msf_rej = cmd_cd_hdr && cmd[1][1];

// ----- REQUEST SENSE state -------------------------------------------------
// Key/ASC latched when a command CHECKs, cleared by the next successful
// non-REQUEST-SENSE command (SCSI-1 semantics: sense persists until the next
// command from the same initiator, and REQUEST SENSE itself must not clear it
// before it has been served). The disk path has exactly one failure mode --
// an opcode we do not implement -- so the whole thing is these two registers.
// Phase 2's CD target extends this latch with its media/audio conditions rather
// than adding a parallel CDROM-only path.
reg [3:0] sense_key = 4'd0;
reg [7:0] sense_asc = 8'd0;
reg       cd_prevent = 1'b0;   // PREVENT/ALLOW MEDIUM REMOVAL state

// New-command strobe: one clk on the CDB completing.
reg  cmd_cpl_d = 1'b0;
always @(posedge clk) cmd_cpl_d <= (phase == PHASE_CMD_IN) && cmd_cpl;
wire new_cmd = (phase == PHASE_CMD_IN) && cmd_cpl && !cmd_cpl_d;

// The eject actually happens (drops `mounted`) only if the medium is not locked.
wire cd_eject_pulse = new_cmd && cmd_cd_eject_any && !cd_prevent;

always @(posedge clk) begin
	if (any_rst) begin
		sense_key  <= 4'd0;
		sense_asc  <= 8'd0;
		cd_prevent <= 1'b0;
	end else if (wdog_abort) begin
		// ABORTED COMMAND. The ASC deliberately carries the OPCODE that stalled
		// rather than a standard additional-sense code: if this ever fires we
		// need to know what stranded us, and a REQUEST SENSE is the only channel
		// out of the target. Non-standard, and worth it -- this is an error path
		// that would otherwise have been an unrecoverable hang.
		sense_key <= 4'hB;
		sense_asc <= op_code;
	end else if (new_cmd) begin
		if (!cmd_ok) begin
			sense_key <= 4'h5;  // ILLEGAL REQUEST
			sense_asc <= 8'h20; // invalid command operation code
		end else if (cd_no_media) begin
			sense_key <= 4'h2;  // NOT READY
			sense_asc <= 8'hb0; // AppleCD vendor "no disc" (NOT 0x3A -- see above)
		end else if (cd_hdr_msf_rej) begin
			sense_key <= 4'h5;  // ILLEGAL REQUEST
			sense_asc <= 8'h24; // invalid field in CDB
		end else if (cmd_cd_eject_any) begin
			if (cd_prevent) begin
				sense_key <= 4'h5;  // ILLEGAL REQUEST
				sense_asc <= 8'h80; // "prevent bit is set" (MAME)
			end else begin
				sense_key <= 4'h2;  // NOT READY
				sense_asc <= 8'h3a; // medium not present, post-eject
			end
		end else if (cmd_cd_prevent) begin
			cd_prevent <= cmd[4][0];
			sense_key  <= 4'd0;
			sense_asc  <= 8'd0;
		end else if (!cmd_request_sense) begin
			sense_key <= 4'd0;  // NO SENSE
			sense_asc <= 8'd0;
		end
	end
end

// latch parameters once command is complete
reg [31:0] lba;
reg [15:0] tlen;

always @(posedge clk) begin
	if (old_io_ack & ~io_ack) lba <= lba + 1'd1;
	if(cmd_cpl && (phase == PHASE_CMD_IN)) begin
		// CDROM READs address 2048-byte logical blocks; the HPS block device is
		// 512-byte sectors, so scale lba/tlen by 4 AT LATCH TIME and the whole
		// downstream ring / flush / data_len machinery runs unmodified in
		// 512-byte units. Non-READ commands keep the raw CDB values, because
		// their lengths are byte counts, not block counts.
		if ((CDROM != 0) && cmd_read) begin
			lba  <= (cmd6_cpl?{11'd0, lba6}:lba10) << 2;
			tlen <= (cmd6_cpl?{7'd0, tlen6}:tlen10) << 2;
		end else begin
			lba <= cmd6_cpl?{11'd0, lba6}:lba10;
			tlen <= cmd6_cpl?{7'd0, tlen6}:tlen10;
		end

		// CD serve parameters, decoded here once (see the CD decode block).
		c1_op_r        <= cmd[9][7:6];
		cd_page_r      <= cmd[2][5:0];
		cd_astat_vol_r <= (cmd[3] == 8'h01);
		cd_alloc10_r   <= {16'd0, cmd[7], cmd[8]};
		cd_hdr_addr_r  <= {cmd[2], cmd[3], cmd[4], cmd[5]};
	end
end
   
// logical block address
wire [7:0] cmd1 = cmd[1];
wire [20:0] lba6 = { cmd1[4:0], cmd[2], cmd[3] };
wire [31:0] lba10 = { cmd[2], cmd[3], cmd[4], cmd[5] };

// transfer length
wire [8:0]  tlen6 = (cmd[4] == 0)?9'd256:{1'b0,cmd[4]};
wire [15:0] tlen10 = { cmd[7], cmd[8] };


// ---- bus watchdog --------------------------------------------------------
// A target that stops making progress must never hold BSY indefinitely: because
// bus_busy gates every other target, one stuck target takes the WHOLE bus down
// and the machine freezes -- boot disk included.
//
// We can be driven into that state by any CDB whose length we do not know.
// Lengths are defined for groups 0/1/2/5 and the Apple 0xC0-0xCF range; groups
// 3, 4, 7 and 0xD0-0xDF are not, so cmd_cpl never asserts and the target sits in
// COMMAND phase forever. The sources also disagree about 0xC0 EJECT (MAME: a
// 10-byte CDB; BlueSCSI: 6), so even a "known" opcode can strand us.
//
// A real drive fails a malformed command and releases the bus. So: if no ACK
// edge arrives for ~129 ms while we are not legitimately waiting on the HPS,
// abort with CHECK CONDITION and let go. That is well inside the Mac's own
// ~250 ms SCSI timeout, so the host sees an ordinary failed command rather than
// a dead bus. In normal operation this can never fire -- the initiator answers
// in microseconds -- so it is inert unless something is already broken.
// WDOG_LOG is overridden down to a few thousand cycles by the testbenches so the
// recovery can be exercised in reasonable sim time. The timeout VALUE is not the
// thing under test -- the recovery behaviour is.
parameter WDOG_LOG = 22;               // 2^22 clks @32.5MHz = ~129 ms

// ---- IO-stall watchdog ----------------------------------------------------
// The bus watchdog above is RESET by io_busy, because a legitimate HPS sector
// fetch runs far longer than its period. That leaves exactly one state
// unguarded: a fetch that never completes AT ALL. io_busy then holds REQ low
// (see `req`) and resets the bus watchdog every cycle, so the target keeps BSY
// forever while the initiator polls for data that can never arrive -- a hang
// with no recovery path, by construction. Seen on hardware as the SCSI
// activity LED stuck on with the Mac spinning in its pseudo-DMA poll loop,
// and reproduced by seam9 in sim/tb_ncr5380_seam.v.
//
// A real drive that loses a sector fetch still releases the bus. This is a
// second, much longer timer that runs ONLY while io_busy holds, and aborts
// through the same path as the bus watchdog. Clearing the stale io_rd/io_wr
// is not optional: io_busy suppresses REQ, so without it the abort could not
// even send its own CHECK CONDITION, and the next command would inherit the
// wedge (the same failure the any_rst clear exists to prevent).
parameter IOWDOG_LOG = 24;             // 2^24 clks @32.5MHz = ~516 ms
reg [IOWDOG_LOG-1:0] iowdog = 0;
wire iowdog_expired = &iowdog;
wire iostall_abort  = iowdog_expired;
always @(posedge clk) begin
	if (any_rst || !io_busy || (phase == PHASE_IDLE) || iostall_abort)
		iowdog <= 0;
	else
		iowdog <= iowdog + 1'd1;
end
reg [WDOG_LOG-1:0] wdog = 0;
wire wdog_expired = &wdog;
wire wdog_abort   = (wdog_expired && (phase != PHASE_IDLE)) || iostall_abort;

always @(posedge clk) begin
	if (any_rst || (phase == PHASE_IDLE) || stb_ack || stb_adv || io_busy || wdog_abort)
		wdog <= 0;
	else if (!wdog_expired)
		wdog <= wdog + 1'd1;
end

// the 5380 changes phase in the falling edge, thus we monitor it
// on the rising edge
always @(posedge clk) begin
	if(any_rst) begin
		phase <= PHASE_IDLE;
	end else if (wdog_abort) begin
		// Give up and release the bus rather than wedge it.
		if ((phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT))
			phase <= PHASE_IDLE;
		else begin
			status <= `STATUS_CHECK_CONDITION;
			phase  <= PHASE_STATUS_OUT;
		end
	end else begin
		if(phase == PHASE_IDLE) begin
			// Only answer selection on a FREE bus (SEL asserted, no BSY). While
			// another target holds BSY its dout is wired-ORed onto the data bus,
			// so a stray bit in that byte could otherwise "select" this target
			// mid-dialog and two targets would then consume the shared ACK stream
			// in parallel -- command/LBA corruption, and misdirected writes.
			// A CD-ROM drive is present on the bus even with no disc inserted
			// (the AppleCD driver polls TEST UNIT READY to detect insertion),
			// so the CD target selects on cd_enable rather than on `mounted`.
			if(sel && din[ID] && ((CDROM != 0) ? cd_enable : mounted) && !bus_busy)
				phase <= PHASE_CMD_IN;
		end

		else if(phase == PHASE_CMD_IN) begin
			// check if a full command is in the buffer
			if(cmd_cpl) begin
				$display("New command on target %d: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", ID, cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
				// is this a supported and valid command?
				// (CDROM: media-dependent commands CHECK with the no-disc sense
				// while unmounted, and a prevent-blocked EJECT CHECKs too.)
				if(cmd_ok && !cd_no_media && !cd_hdr_msf_rej) begin
					// yes, continue
					status <= (cmd_cd_eject_any && cd_prevent) ? `STATUS_CHECK_CONDITION : `STATUS_OK;

					// continue according to command

					// these commands return data
					if(cmd_read || cmd_inquiry || cmd_read_capacity || cmd_mode_sense || cmd_read_buffer || cmd_request_sense ||
					   cmd_cd_toc || cmd_cd_toc43 || cmd_cd_subq || cmd_cd_subq43 || cmd_cd_astat || cmd_cd_hdr) phase <= PHASE_DATA_OUT;
					// these commands receive dataa
					else if(cmd_write || cmd_mode_select || cmd_write_buffer || cmd_cd_actl) phase <= PHASE_DATA_IN;
					// and all other valid commands are just "ok"
					else phase <= PHASE_STATUS_OUT;
				end else begin
					// no, report failure
					status <= `STATUS_CHECK_CONDITION;
					phase <= PHASE_STATUS_OUT;
				end
			end
		end

		// data_done, not data_complete: a zero-length data phase never sees an
		// ACK edge, so data_complete would never assert and the phase would hang.
		else if(phase == PHASE_DATA_OUT) begin
			if(data_done) phase <= PHASE_STATUS_OUT;
		end

		else if(phase == PHASE_DATA_IN) begin
			if(data_done) phase <= PHASE_STATUS_OUT;
		end

		else if(phase == PHASE_STATUS_OUT) begin
			if(status_sent) phase <= PHASE_MESSAGE_OUT;
		end

		else if(phase == PHASE_MESSAGE_OUT) begin
			if(message_sent) phase <= PHASE_IDLE;
		end
		
		else
			phase <= PHASE_IDLE;  // should never happen
	end
end
   
   
endmodule

module scsi_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=9)
(
	input	                clock,

	input	[ADDRWIDTH-1:0] address_a,
	input	[DATAWIDTH-1:0] data_a,
	input	                wren_a,
	output reg [DATAWIDTH-1:0] q_a,

	input	[ADDRWIDTH-1:0] address_b,
	input	[DATAWIDTH-1:0] data_b,
	input	                wren_b,
	output reg [DATAWIDTH-1:0] q_b
);

reg [DATAWIDTH-1:0] ram[0:(1<<ADDRWIDTH)-1];

always @(posedge clock) begin
	if(wren_a) begin
		ram[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram[address_a];
	end
end

always @(posedge clock) begin
	if(wren_b) begin
		ram[address_b] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram[address_b];
	end
end

endmodule
