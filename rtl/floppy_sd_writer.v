// floppy_sd_writer.v
//
// Phase 8 of FLOPPY_WRITE_PLAN.md: persist every sector the guest writes
// out to the mounted .dsk on the SD card, via hps_io's sd_wr/sd_ack/
// sd_buff_addr block-device protocol. This is the only module in the
// floppy write path that touches the user's file.
//
// This module keeps NO copy of the data. floppy_write_committer.v has
// already landed the sector in SDRAM, and SDRAM always holds the newest
// version, so all that is queued here is the sector NUMBER; the block is
// fetched from SDRAM at write time, through addrController_top.v's
// extra-slot-3 read port, into one 256x16 buffer that hps_io then streams
// out. The queue is a FIFO of 2^QDEPTH_BITS sector numbers (1024 = ~13 s
// of backlog at one sector per 12.5 ms). A sector re-committed while still
// queued is queued twice and written twice, with the latest data both
// times - no dedupe, no bitmap, no in-flight tracking. A full queue
// REFUSES the push and counts it in `dbg`; it never overwrites anything.
//
// Why no copy: Main opens a writable image O_RDWR|O_SYNC, so every block
// is a synchronous card write with bursty latency, against a sector every
// 12.5 ms during a track write. The previous design's two shadow buffers
// were overwritten mid-transfer whenever a stall outlasted two sectors -
// a torn sector on the card that the guest's own verify (which reads
// SDRAM) never sees. Any fixed-depth copy of the data has that cliff; a
// queue of numbers does not.
//
// Protocol modelled on scsi.v's io_wr handshake (the only sd_wr producer
// already proven on this core): assert sd_wr with sd_lba valid, drop
// sd_wr as soon as sd_ack rises (hps_io has accepted the request and is
// now stepping sd_buff_addr through the block), then wait for sd_ack to
// fall again before considering the sector durably handed off - mirroring
// floppy_loader.v's own SD_WAIT_ACK/SD_WAIT_DONE split for the read side.
// sd_buff_din for this slot must stay valid, addressed by the HPS-driven
// shared sd_buff_addr bus, for the whole time sd_ack is high.
//
// The extra-slot-3 read port is the write port's protocol run backwards:
// hold fetch_req with fetch_addr stable until the one-clock fetch_ack,
// on which fetch_data is the word at that byte offset of this image (the
// controller captures it at the end of busPhase 2 and acks at the end of
// busPhase 3, see addrController_top.v). Values are frozen while the
// request is up - this core lost two hardware gates to a pulsed handshake
// on that port, and the plan records why.
//
// img_mounted (eject/remount of THIS slot) ABORTS the writer: FSM to
// idle, both request lines low, queue emptied. A sector captured against
// the old image must never land in the one that replaces it, and sd_ack
// is shared per SLOT, so a running FSM would otherwise be walked forward
// by floppy_loader's acks on the new image. Safe because Main is single-
// threaded: a transfer it has captured completes before it can send a
// mount notification, so nothing of ours is mid-transfer at the pulse. A
// fetch withdrawn by the abort costs one read nobody consumes; the ack
// for it is ignored because the request is down.
module floppy_sd_writer #(
	parameter ACK_TIMEOUT_BITS = 24, // ~0.5s at clk_sys (~32MHz); sim overrides this narrower
	parameter QDEPTH_BITS      = 10  // 1024 pending sectors; sim overrides this narrower
) (
	input         clk,
	input         reset,

	input         img_mounted, // this slot's own mount pulse - abort, see header

	// commit tap from floppy_write_committer, via floppy.v/iwm.v/
	// dataController_top.sv's dskCommit* ports
	input             commit_done,
	input      [21:0] commit_addr,  // image byte offset of sector byte 0

	input             readonly,     // this drive's latched img_readonly - refuse persistence outright
	input             loader_busy,  // don't touch the slot or the image while floppy_loader owns them

	// Size of the mounted image in 512-byte blocks (floppy_loader's own
	// loaded_size >> 9, latched at that slot's mount). Any commit landing
	// at or beyond this is dropped rather than written - see P_IDLE.
	input      [12:0] size_blocks,

	// extra-slot-3 read port (addrController_top.v), see header
	output reg [21:0] fetch_addr,   // byte offset within THIS image, word-aligned
	output reg        fetch_req,
	input             fetch_ack,
	input      [15:0] fetch_data,

	output reg [31:0] sd_lba,
	output reg        sd_wr,
	input             sd_ack,

	input      [7:0]  sd_buff_addr, // HPS-driven shared read address
	output     [15:0] sd_buff_din,

	output            busy,

	// Witness word, for the PFSW probe (rtl/dbg_probes.sv):
	//   [31:24] queue refusals (sat) - nonzero means a sector was LOST
	//   [23:16] out-of-range refusals (sat)
	//   [15:8]  blocks landed (wraps)
	//   [2:0]   pstate
	output     [31:0] dbg
);

	// ---- the sector-number queue ------------------------------------
	reg [12:0] q_mem [0:(1<<QDEPTH_BITS)-1];
	reg [QDEPTH_BITS:0] wr_ptr, rd_ptr;
	wire [QDEPTH_BITS:0] count = wr_ptr - rd_ptr;
	wire full  = count[QDEPTH_BITS];
	wire empty = (count == 0);
	reg  [12:0] q_head;    // registered read of q_mem[rd_ptr]
	reg         empty_d;   // q_head lags a push by one cycle; see P_IDLE

	wire push = commit_done && !readonly && !full;

	always @(posedge clk) begin
		if (push) q_mem[wr_ptr[QDEPTH_BITS-1:0]] <= commit_addr[21:9];
		q_head  <= q_mem[rd_ptr[QDEPTH_BITS-1:0]];
		empty_d <= empty;
	end

	// ---- the block buffer: filled from SDRAM, drained by hps_io -------
	reg [15:0] blk [0:255];
	reg        blk_we;
	reg  [7:0] blk_wa;
	reg [15:0] blk_wd;
	always @(posedge clk) if (blk_we) blk[blk_wa] <= blk_wd;

	reg [15:0] blk_do;
	always @(posedge clk) blk_do <= blk[sd_buff_addr];
	// SDRAM words are in the internal convention (even source byte in the
	// high half - see floppy_write_committer.v). hps_io's sd_buff_din/dout
	// wire format is the opposite half-order (see floppy_loader.v's
	// matching swap on the read side), so this swap must mirror that one
	// or every written byte pair comes out transposed in the .dsk on disk.
	assign sd_buff_din = {blk_do[7:0], blk_do[15:8]};

	localparam P_IDLE      = 3'd0,
	           P_SKIP      = 3'd1,  // refused entry: one cycle for q_head to move on
	           P_FILL      = 3'd2,  // fetching the block from SDRAM, word w
	           P_WR        = 3'd3,  // block in the buffer: present sd_wr
	           P_WAIT_ACK  = 3'd4,
	           P_WAIT_DONE = 3'd5;
	reg [2:0] pstate;

	reg [12:0] cur_sec;    // the block being written
	reg  [7:0] w;          // word index within it, during the fetch

	// P_WAIT_ACK has no bound otherwise: if this slot's sd_wr is ever
	// asserted while HPS isn't servicing it (framework quirk, a mount race
	// on the shared slot, etc.) sd_ack never rises and this module would
	// wedge in P_WAIT_ACK forever with busy stuck high (busy feeds
	// LED_USER). ACK_TIMEOUT_BITS defaults to ~0.5s at clk_sys (~32MHz) -
	// far longer than any real sd_ack latency, so it never fires in normal
	// operation. On expiry the request is dropped and re-presented, NOT
	// retired - see P_WAIT_ACK below for why abandoning the queue entry
	// here would be a data-corruption path rather than a recovery.
	reg [ACK_TIMEOUT_BITS-1:0] ackTimer;
	wire ackTimeout = &ackTimer;

	wire lba_in_range = (size_blocks != 13'd0) && (q_head < size_blocks);

	assign busy = (pstate != P_IDLE) || !empty;

	reg [7:0] dbg_refused, dbg_oor, dbg_landed;
	assign dbg = {dbg_refused, dbg_oor, dbg_landed, 5'd0, pstate};

	always @(posedge clk) begin
		blk_we <= 1'b0;
		if (reset) begin
			pstate     <= P_IDLE;
			sd_lba     <= 32'd0;
			sd_wr      <= 1'b0;
			fetch_addr <= 22'd0;
			fetch_req  <= 1'b0;
			wr_ptr     <= 0;
			rd_ptr     <= 0;
			cur_sec    <= 13'd0;
			w          <= 8'd0;
			ackTimer   <= 0;
			dbg_refused <= 8'd0;
			dbg_oor     <= 8'd0;
			dbg_landed  <= 8'd0;
		end else begin
			// capture side: independent of pstate, always ready to accept
			// the next commit. A full queue means the card has stalled
			// for ~13 s; the sector is refused, and the count is the
			// sticky witness that it was.
			if (commit_done && !readonly) begin
				if (full) begin
					if (dbg_refused != 8'hFF) dbg_refused <= dbg_refused + 8'd1;
				end else
					wr_ptr <= wr_ptr + 1'd1;
			end

			case (pstate)
			// q_head is valid once the queue has been non-empty for two
			// cycles (its read lags the push by one), and P_SKIP below is
			// what keeps that true after a pop that stays here.
			P_IDLE: if (!empty && !empty_d && !loader_busy) begin
				rd_ptr <= rd_ptr + 1'd1;
				if (!lba_in_range) begin
					// byte offset -> LBA (512B/sector). The decoder bounds-
					// checks the SECTOR number against this track's spt, but
					// nothing upstream checks the resulting LBA against the
					// mounted image's actual length - `track` is free to
					// reach 0x4F regardless of image size. This is the last
					// place that can refuse, and it is cheap, so refuse here
					// rather than hand hps_io an offset past the end of the
					// file.
					if (dbg_oor != 8'hFF) dbg_oor <= dbg_oor + 8'd1;
					pstate <= P_SKIP;
				end else begin
					cur_sec <= q_head;
					w       <= 8'd0;
					pstate  <= P_FILL;
				end
			end

			// A pop that stays in P_IDLE would pop again next cycle against
			// the head it just retired (q_head has not moved yet): the next
			// entry would be judged as this one and the one after it lost.
			P_SKIP: pstate <= P_IDLE;

			// One word per slot-3 grant. fetch_addr and fetch_req change
			// together and hold until the ack; an ack with the request
			// down (a grant the abort withdrew) is not consulted here.
			P_FILL: if (!fetch_req) begin
				fetch_addr <= {cur_sec, w, 1'b0};
				fetch_req  <= 1'b1;
			end else if (fetch_ack) begin
				blk_we    <= 1'b1;
				blk_wa    <= w;
				blk_wd    <= fetch_data;
				fetch_req <= 1'b0;
				w         <= w + 8'd1;
				if (w == 8'd255) pstate <= P_WR;
			end

			P_WR: begin
				sd_lba <= {19'd0, cur_sec};
				sd_wr  <= 1'b1;
				pstate <= P_WAIT_ACK;
			end

			P_WAIT_ACK: if (sd_ack) begin
				sd_wr  <= 1'b0; // mirrors scsi.v: io_wr drops as soon as io_ack rises
				pstate <= P_WAIT_DONE;
			end else if (ackTimeout) begin
				// Drop the request and RE-PRESENT it - the same block from
				// the same buffer. Retiring the entry here is not safe:
				// hps_io captures sd_lba during its own poll command and
				// raises sd_ack in a LATER, separate command, so there is
				// no bound on the gap between the two. If the entry were
				// retired and the next block fetched, a late sd_ack would
				// stream THAT block out to the LBA the HPS had already
				// captured - a full sector of unrelated data written at a
				// perfectly valid offset in the .dsk. Leaving cur_sec, the
				// buffer and sd_lba alone makes the retry idempotent
				// instead: however late the ack arrives, and whichever
				// attempt it belongs to, it transfers the same block to the
				// same LBA. `busy` stays high while a write is genuinely
				// still owed, which is what the LED should show anyway.
				sd_wr  <= 1'b0;
				pstate <= P_WR;
			end else
				ackTimer <= ackTimer + 1'b1;

			P_WAIT_DONE: if (!sd_ack) begin
				dbg_landed <= dbg_landed + 8'd1;
				pstate     <= P_IDLE;
			end

			default: pstate <= P_IDLE;
			endcase

			if (pstate != P_WAIT_ACK) ackTimer <= 0;

			// Remount ABORT, placed after the case so it wins over anything
			// the state machine decided this cycle - see header.
			if (img_mounted) begin
				wr_ptr    <= 0;
				rd_ptr    <= 0;
				sd_wr     <= 1'b0;
				fetch_req <= 1'b0;
				blk_we    <= 1'b0;
				pstate    <= P_IDLE;
			end
		end
	end

endmodule
