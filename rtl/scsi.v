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

// output of inquiry command, identify as "SEAGATE ST225N"
wire [7:0] inquiry_dout =
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
reg [31:0] capacity;
reg        mounted = 0;
always @(posedge clk) begin
	if (img_mounted) begin
		if (|img_blocks) begin
			capacity <= img_blocks;
			$display("Image mounted on target %d, size: %d", ID, img_blocks);
			mounted <= 1;
		end else
			mounted <= 0;
	end
end

wire [7:0] read_capacity_dout =
		(data_cnt == 32'd0 )?capacity[31:24]:
		(data_cnt == 32'd1 )?capacity[23:16]:
		(data_cnt == 32'd2 )?capacity[15:8]:
		(data_cnt == 32'd3 )?capacity[7:0]:
		(data_cnt == 32'd6 )?8'd2:             // 512 bytes per sector
		8'h00;

wire [7:0] mode_sense_dout =
		(data_cnt == 32'd3 )?8'd8:
		(data_cnt == 32'd5 )?capacity[23:16]:
		(data_cnt == 32'd6 )?capacity[15:8]:
		(data_cnt == 32'd7 )?capacity[7:0]:
		(data_cnt == 32'd10 )?8'd2:
		8'h00;

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
	if(any_rst) begin
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
localparam [31:0] INQUIRY_LEN = 32'd36;  // 5 + additional-length(31), the standard size

wire [31:0] data_len =
		 cmd_read_capacity?32'd8:
		 cmd_read?{ 7'd0, tlen, 9'd0 }:   // read command length is in 512 bytes blocks
		 cmd_write?{ 7'd0, tlen, 9'd0 }:  // write command length is in 512 bytes blocks
		 cmd_inquiry?((alloc_len < INQUIRY_LEN) ? alloc_len : INQUIRY_LEN):
		 cmd_request_sense?((sense_len < 32'd18) ? sense_len : 32'd18):
		 { 16'd0, tlen };                 // mode sense etc have length in bytes

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
wire       cmd10_cpl = ((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10);
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

// valid command in buffer? TODO: check for valid command parameters
wire  cmd_ok = cmd_read || cmd_write || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_format || cmd_mode_sense ||
		  cmd_read_buffer || cmd_write_buffer || cmd_verify6 || cmd_verify10 ||
		  cmd_request_sense;

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

// New-command strobe: one clk on the CDB completing.
reg  cmd_cpl_d = 1'b0;
always @(posedge clk) cmd_cpl_d <= (phase == PHASE_CMD_IN) && cmd_cpl;
wire new_cmd = (phase == PHASE_CMD_IN) && cmd_cpl && !cmd_cpl_d;

always @(posedge clk) begin
	if (any_rst) begin
		sense_key <= 4'd0;
		sense_asc <= 8'd0;
	end else if (new_cmd) begin
		if (!cmd_ok) begin
			sense_key <= 4'h5;  // ILLEGAL REQUEST
			sense_asc <= 8'h20; // invalid command operation code
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
		lba <= cmd6_cpl?{11'd0, lba6}:lba10;
		tlen <= cmd6_cpl?{7'd0, tlen6}:tlen10;
	end
end
   
// logical block address
wire [7:0] cmd1 = cmd[1];
wire [20:0] lba6 = { cmd1[4:0], cmd[2], cmd[3] };
wire [31:0] lba10 = { cmd[2], cmd[3], cmd[4], cmd[5] };

// transfer length
wire [8:0]  tlen6 = (cmd[4] == 0)?9'd256:{1'b0,cmd[4]};
wire [15:0] tlen10 = { cmd[7], cmd[8] };


// the 5380 changes phase in the falling edge, thus we monitor it
// on the rising edge
always @(posedge clk) begin
	if(any_rst) begin
		phase <= PHASE_IDLE;
	end else begin
		if(phase == PHASE_IDLE) begin
			// Only answer selection on a FREE bus (SEL asserted, no BSY). While
			// another target holds BSY its dout is wired-ORed onto the data bus,
			// so a stray bit in that byte could otherwise "select" this target
			// mid-dialog and two targets would then consume the shared ACK stream
			// in parallel -- command/LBA corruption, and misdirected writes.
			if(sel && din[ID] && mounted && !bus_busy)  // own id on bus during selection?
				phase <= PHASE_CMD_IN;
		end

		else if(phase == PHASE_CMD_IN) begin
			// check if a full command is in the buffer
			if(cmd_cpl) begin
				$display("New command on target %d: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", ID, cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
				// is this a supported and valid command?
				if(cmd_ok) begin
					// yes, continue
					status <= `STATUS_OK;

					// continue according to command

					// these commands return data
					if(cmd_read || cmd_inquiry || cmd_read_capacity || cmd_mode_sense || cmd_read_buffer || cmd_request_sense) phase <= PHASE_DATA_OUT;
					// these commands receive dataa
					else if(cmd_write || cmd_mode_select || cmd_write_buffer) phase <= PHASE_DATA_IN;
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
