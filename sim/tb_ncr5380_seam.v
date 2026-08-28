// ---------------------------------------------------------------------------
// tb_ncr5380_seam.v -- the ncr5380 <-> scsi.v seam, driven from the HOST side.
//
// Every other bench in this tree drives scsi.v directly on its target-side
// pins. That leaves the 5380 register model -- the thing the Mac's SCSI
// Manager actually talks to -- completely untested, which is where the System 7
// "Welcome to Macintosh" wedge turned out to live.
//
// This bench is an initiator written the way the SCSI Manager behaves: it
// selects a target, hands over a CDB byte by byte, pumps the data phase and
// reads status/message, all through 5380 register reads and writes.
//
// It also proves the three completion behaviours ported from MacLC_MiSTer:
//   * deferred bus-visible REQ  (CSR)
//   * end-of-DMA                (BSR bit 7)
//   * latched completion IRQ    (BSR bit 4)
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

// Register numbers (must match rtl/ncr5380.sv)
`define R_CDR 3'h0
`define R_ICR 3'h1
`define R_MR  3'h2
`define R_TCR 3'h3
`define R_CSR 3'h4
`define R_BSR 3'h5
`define R_IDR 3'h6
`define R_RST 3'h7

`define W_ODR   3'h0
`define W_ICR   3'h1
`define W_MR    3'h2
`define W_TCR   3'h3
`define W_DMAS  3'h5
`define W_IDMAR 3'h7

`define CSR_REQ    5
`define BSR_EODMA  7
`define BSR_DRQ    6
`define BSR_IRQ    4
`define BSR_PMATCH 3

module tb_ncr5380_seam;

	localparam DEVS   = 2;
	localparam CD_DEV = 1;      // target 1 = CD-ROM at SCSI ID 3

	reg clk = 0;
	reg reset = 1;
	always #15 clk = ~clk;      // ~33 MHz

	// host bus
	reg        bus_cs = 0;
	reg  [2:0] bus_rs = 0;
	reg        ior = 0, iow = 0, dack = 0;
	reg  [7:0] wdata = 0;
	wire [7:0] rdata;
	wire       dreq;

	// io controller (unused: INQUIRY needs no media and no HPS fetch)
	reg  [DEVS-1:0] img_mounted = 0;
	reg      [31:0] img_size = 0;
	wire     [31:0] io_lba [DEVS];
	wire [DEVS-1:0] io_rd, io_wr;
	reg  [DEVS-1:0] io_ack = 0;   // driven by the HPS model below
	reg       [7:0] sd_buff_addr = 0;
	reg      [15:0] sd_buff_dout = 0;
	wire     [15:0] sd_buff_din [DEVS];
	reg             sd_buff_wr = 0;

	reg             cd_enable = 1;

	// WDOG_LOG(11) ~= 20us and IOWDOG_LOG(14) ~= 0.5ms, so both timeouts are
	// reachable in simulation. Synthesis keeps the real 129ms / 516ms periods.
	ncr5380 #(.DEVS(DEVS), .CD_DEV(CD_DEV), .WDOG_LOG(11), .IOWDOG_LOG(14)) dut (
		.clk(clk), .reset(reset),
		.bus_cs(bus_cs), .bus_rs(bus_rs), .ior(ior), .iow(iow),
		.dack(dack), .dreq(dreq), .wdata(wdata), .rdata(rdata),
		.img_mounted(img_mounted), .img_size(img_size),
		.io_lba(io_lba), .io_rd(io_rd), .io_wr(io_wr), .io_ack(io_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.cd_enable(cd_enable)
	);

	// ---- minimal HPS sector server ---------------------------------------
	// Answers the CD slot's io_rd with an ack after hps_delay clocks. Setting
	// hps_delay long enough for the target's bus watchdog to fire first is what
	// reproduces a LATE ack -- one that arrives after the target has left the
	// bus and dropped BSY.
	integer hps_delay = 20;
	reg     hps_enable = 1'b1;
	reg     hps_data_mode = 1'b0;      // see the sector server below
	integer hps_seed = 32'h13579BDF;
	integer hps_fills = 0;
	integer hps_acks = 0;
	reg     saw_io_rd = 0;
	// Did the CPU hold-off ever actually engage? Without this, a seam18 that
	// passes proves nothing -- a timing shift that stopped the pump outrunning
	// the fill would look identical to the interlock doing its job.
	reg     saw_bus_hold = 0;
	always @(posedge clk) if (dut.bus_hold) saw_bus_hold <= 1'b1;
	// Direction-split, because "the hold-off engaged" is not specific enough.
	// When seam20 was written, instrumented coverage over the whole bench read
	// 307 read-side engagements and ZERO write-side: the iow half of bus_hold
	// was a CPU-stall condition that had never once executed, in simulation or
	// on hardware. seam20 exists to close exactly that.
	reg     saw_hold_rd = 0, saw_hold_wr = 0, hold_dir_d = 0;
	always @(posedge clk) begin
		hold_dir_d <= dut.bus_hold;
		if (dut.bus_hold && !hold_dir_d) begin
			if (dut.ior) saw_hold_rd <= 1'b1;
			if (dut.iow) saw_hold_wr <= 1'b1;
		end
	end
	// Force the next hps_force_n data-mode fills to take hps_force_delay clocks
	// instead of the randomised 1..400. seam18 uses this to make exactly one
	// fill arrive later than a blind initiator's pump rate -- the condition the
	// randomised sweep cannot hold still.
	integer hps_force_delay = 0;
	integer hps_force_n = 0;

	// Disk slot 0 gets its own trivial always-ack server: seam12 needs a WRITE
	// target, and the CD is read-only.
	// hps_disk_enable low = the disk slot's HPS never answers, which is what
	// seam14 needs to stall a WRITE flush.
	reg     hps_disk_enable = 1'b1;
	// hps_manual hands both slot servers over to the test, so it can emulate
	// hps_io serving a CHOSEN slot -- which is the only way to reproduce one
	// slot's session landing in another target's buffer.
	reg     hps_manual = 1'b0;
	// hps_disk_delay makes a disk fill/flush LAG by that many clocks instead of
	// answering next cycle. hps_disk_enable=0 is the pathological "never
	// answers" case (seam14); this is the far more common one -- an HPS that is
	// merely SLOW -- and it is what seam20 needs, because the write-side
	// hold-off only asserts while a flush is still in flight AND the CPU has
	// come back round to the half being flushed. At delay 0 this is
	// bit-identical to the original always-ack server.
	integer hps_disk_delay = 0;
	integer dsk_cnt = 0;
	always @(posedge clk) begin : hps_disk
		if (reset) begin io_ack[0] <= 1'b0; dsk_cnt <= 0; end
		else if (!hps_manual) begin
			if (io_ack[0]) begin
				io_ack[0] <= 1'b0; dsk_cnt <= 0;
			end else if (hps_disk_enable && (io_rd[0] | io_wr[0])) begin
				if (dsk_cnt >= hps_disk_delay) begin io_ack[0] <= 1'b1; dsk_cnt <= 0; end
				else dsk_cnt <= dsk_cnt + 1;
			end else dsk_cnt <= 0;
		end
	end

	always @(posedge clk) begin : hps
		integer wait_n;
		if (reset) begin
			io_ack[CD_DEV] <= 0;
			wait_n   = 0;
		end else if (hps_manual || hps_data_mode) begin
			wait_n = 0;
		end else begin
			if (io_rd[CD_DEV] | io_wr[CD_DEV]) saw_io_rd <= 1'b1;
			if ((io_rd[CD_DEV] | io_wr[CD_DEV]) && hps_enable && !io_ack[CD_DEV]) begin
				wait_n = wait_n + 1;
				if (wait_n >= hps_delay) begin
					io_ack[CD_DEV] <= 1'b1;
					hps_acks = hps_acks + 1;
					wait_n = 0;
				end
			end else if (io_ack[CD_DEV]) begin
				io_ack[CD_DEV] <= 1'b0;
				wait_n = 0;
			end else begin
				wait_n = 0;
			end
		end
	end

	integer fails = 0;
	integer tests = 0;

	task ok(input [800:0] name, input cond);
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	// ---- host register access -------------------------------------------
	// reg_wr/csr_rd inside the DUT are edge-detected, so every access must
	// assert for a couple of clocks and then fully deassert.
	task reg_write(input [2:0] rs, input [7:0] d);
		begin
			@(negedge clk); bus_cs = 1; dack = 0; bus_rs = rs; wdata = d; iow = 1;
			@(negedge clk);
			@(negedge clk); iow = 0; bus_cs = 0;
			@(negedge clk);
		end
	endtask

	task reg_read(input [2:0] rs, output [7:0] d);
		begin
			@(negedge clk); bus_cs = 1; dack = 0; bus_rs = rs; ior = 1;
			@(negedge clk);
			d = rdata;
			@(negedge clk); ior = 0; bus_cs = 0;
			@(negedge clk);
		end
	endtask

	reg [7:0] rv, csr1, csr2, bsr1, bsr2;

	// Read a register WITHOUT asserting ior, i.e. through the other byte lane.
	// rdata is combinational and not gated by ior, so this returns the correct
	// value -- but csr_rd (which IS gated by ior) never pulses. That asymmetry
	// is the hazard seam10 tests.
	task reg_read_noior(input [2:0] rs, output [7:0] d);
		begin
			@(negedge clk); bus_cs = 1; dack = 0; bus_rs = rs; ior = 0;
			@(negedge clk);
			d = rdata;
			@(negedge clk); bus_cs = 0;
			@(negedge clk);
		end
	endtask

	// Poll CSR until REQ reads back set.
	task wait_req(output integer polls);
		integer guard;
		begin
			polls = 0; guard = 0;
			rv = 0;
			while (!rv[`CSR_REQ] && guard < 2000) begin
				reg_read(`R_CSR, rv);
				polls = polls + 1;
				guard = guard + 1;
			end
		end
	endtask

	// One initiator byte handshake: pulse ACK, wait for the target to drop REQ.
	// Blind byte handshake: assert ACK, wait for the target to drop REQ, drop
	// ACK. Deliberately watches the RAW target REQ instead of polling CSR --
	// a CSR read would consume the deferral window that seam3/seam4 measure,
	// and the Mac's blind pseudo-DMA does not poll CSR between bytes either.
	task ack_pulse(input [7:0] icr_base);
		integer guard;
		begin
			reg_write(`W_ICR, icr_base | 8'h10);   // ICR_A_ACK
			guard = 0;
			while (dut.scsi_req && guard < 2000) begin
				@(posedge clk);
				guard = guard + 1;
			end
			reg_write(`W_ICR, icr_base);           // drop ACK
			// Wait for the target's NEXT REQ before returning, so a caller
			// that inspects the phase sees it settled. Without this the phase
			// is sampled mid-transition and a Data->Status boundary reads as
			// still-in-data, costing one extra byte.
			while (!dut.scsi_req && guard < 6000) begin
				@(posedge clk);
				guard = guard + 1;
			end
			repeat (2) @(posedge clk);
		end
	endtask

	// Wait for the target to assert a fresh REQ on the bus, without reading
	// CSR. Anchors the deferral tests on a REQ that demonstrably exists, so
	// they cannot pass merely because REQ had not risen yet.
	task wait_raw_req;
		integer guard;
		begin
			guard = 0;
			while (!dut.scsi_req && guard < 4000) begin
				@(posedge clk);
				guard = guard + 1;
			end
		end
	endtask

	// Send one command byte (target is in COMMAND phase, receiving)
	task send_cmd_byte(input [7:0] b);
		integer polls;
		begin
			wait_req(polls);
			reg_write(`W_ODR, b);
			ack_pulse(8'h01);                      // keep ICR_A_DATA asserted
		end
	endtask

	// Read one byte from the target (DATA IN / STATUS / MESSAGE)
	task recv_byte(output [7:0] b);
		integer polls;
		begin
			wait_req(polls);
			reg_read(`R_CDR, b);
			ack_pulse(8'h00);                      // release the data bus to read
		end
	endtask

	// ---- pseudo-DMA (DACK) path ------------------------------------------
	// THE PATH THE REAL DRIVER USES, and the one nothing has ever tested. The
	// hardware probes caught the Mac wedged here: last register write was
	// DMAinitRcv, then it polled forever. Everything above this point drives
	// the plain register path instead, which is why that hole survived.
	task pdma_arm;
		begin
			reg_write(`W_MR, 8'h02);      // MR.DMA_MODE
			reg_write(`W_IDMAR, 8'h00);   // Start DMA Initiator Receive
		end
	endtask

	// Read one byte through the DACK window (not the register file).
	//
	// The wait-state loop is the 68000's DTACK behaviour, and it is load-bearing:
	// before rtl's bus_hold existed the SCSI space acknowledged unconditionally,
	// this task always completed in a fixed 4 clocks, and so NO bench in this
	// tree could observe a pacing violation -- which is why cd38, seam17 and a
	// 694-fill sweep were all green against a deterministic hardware failure.
	// Bounded rather than infinite so a stuck hold-off FAILS a test instead of
	// hanging the bench; the bound is well above the target's io-stall watchdog,
	// which is what releases a hold that can never be satisfied.
	task dma_read_byte(output [7:0] b);
		integer w;
		begin
			@(negedge clk); bus_cs = 1; dack = 1; ior = 1;
			@(negedge clk);
			w = 0;
			while (dut.bus_hold && w < 100000) begin @(negedge clk); w = w + 1; end
			b = rdata;
			@(negedge clk); ior = 0; dack = 0; bus_cs = 0;
			@(negedge clk);
		end
	endtask

	// A DACK read that IGNORES bus_hold -- the Plus exactly as it was before the
	// hold-off existed, and the model of any machine whose glue does not wire the
	// target's back-pressure into DTACK. Used by seam19 to defeat fix (a) on
	// purpose, so that fix (c) -- the CHECK CONDITION backstop -- stays testable
	// once (a) has made the breach unreachable through the normal path.
	task dma_read_byte_nowait(output [7:0] b);
		begin
			@(negedge clk); bus_cs = 1; dack = 1; ior = 1;
			@(negedge clk);
			b = rdata;
			@(negedge clk); ior = 0; dack = 0; bus_cs = 0;
			@(negedge clk);
		end
	endtask

	// Write one byte through the DACK window (the pseudo-DMA send path).
	// Same DTACK wait-state model as dma_read_byte -- a blind WRITE pump can
	// overrun a flush that has not been read out of the slot yet, which is the
	// same hazard in the other direction.
	task dma_write_byte(input [7:0] b);
		integer w;
		begin
			@(negedge clk); bus_cs = 1; dack = 1; wdata = b; iow = 1;
			@(negedge clk);
			w = 0;
			while (dut.bus_hold && w < 100000) begin @(negedge clk); w = w + 1; end
			@(negedge clk); iow = 0; dack = 0; bus_cs = 0;
			@(negedge clk);
		end
	endtask

	// Wait for BSR.DRQ, bounded. Returns 1 if it ever asserted.
	task wait_drq(output got);
		integer guard;
		begin
			got = 0; guard = 0;
			while (!got && guard < 3000) begin
				reg_read(`R_BSR, rv);
				if (rv[`BSR_DRQ]) got = 1;
				guard = guard + 1;
			end
		end
	endtask

	// Mount an image on the CD slot (MiSTer convention: img_mounted is a pulse).
	task mount_cd(input [31:0] blocks);
		begin
			img_size = blocks;
			img_mounted[CD_DEV] = 1'b1;
			@(posedge clk); @(posedge clk);
			img_mounted[CD_DEV] = 1'b0;
			repeat (400) @(posedge clk);   // let the lead-out MSF conversion settle
		end
	endtask

	// Select a target by ID bit
	// ---- HPS sector server with VARIABLE latency ------------------------
	// The other model here only ACKS -- it never delivers bytes -- and
	// tb_scsi_cdrom's does deliver but always in a fixed 8 clocks, and talks to
	// scsi.v directly rather than through this file's pseudo-DMA host-face.
	// Neither can produce a JUST-IN-TIME fill, which is the condition MacLC's
	// note names for their equivalent ring-stale bug, and which the hardware
	// failure of 2026-08-26 needs (real HPS latency is wildly variable -- a
	// write flush measured ~28 ms that day).
	//
	// Serves the same pattern as tb_scsi_cdrom: byte n of HPS sector L is
	// L[7:0] ^ n. Ack framing matches hps_io -- sd_ack asserted for the whole
	// session, sd_buff_wr pulsing inside it.
	always @(posedge clk) begin : hps_data
		integer w, dly;
		reg [7:0] eb, ob;
		if (hps_data_mode && io_rd[CD_DEV] && !io_ack[CD_DEV]) begin
			hps_seed = (hps_seed * 32'd1103515) + 32'd12345;
			// 1..400 clocks. The window that corrupts is the one where the
			// fill completes just as the host arrives, so the range has to
			// straddle the host's own byte rate rather than sit under it.
			dly = 1 + ((hps_seed >> 7) % 400);
			if (hps_force_n > 0) begin
				dly = hps_force_delay;
				hps_force_n = hps_force_n - 1;
			end
			repeat (dly) @(posedge clk);
			io_ack[CD_DEV] <= 1'b1;
			@(posedge clk);
			for (w = 0; w < 256; w = w + 1) begin
				eb = io_lba[CD_DEV][7:0] ^ ((w*2)   & 8'hff);
				ob = io_lba[CD_DEV][7:0] ^ ((w*2+1) & 8'hff);
				sd_buff_addr <= w[7:0];
				sd_buff_dout <= {ob, eb};
				sd_buff_wr   <= 1'b1;
				@(posedge clk);
			end
			sd_buff_wr <= 1'b0;
			@(posedge clk);
			io_ack[CD_DEV] <= 1'b0;
			hps_fills = hps_fills + 1;
			@(posedge clk);
		end
	end

	// Emulate one hps_io session for `slot`: sd_ack names the slot, while
	// sd_buff_addr/dout/wr are a SHARED bus every target can see. Writing 8
	// words is plenty -- the defect shows on the first strobe.
	task hps_session(input integer slot, input [15:0] seed);
		integer k;
		begin
			io_ack[slot] = 1'b1;
			@(posedge clk);
			for (k = 0; k < 8; k = k + 1) begin
				sd_buff_addr = k[7:0];
				sd_buff_dout = seed + k[15:0];
				sd_buff_wr   = 1'b1;
				@(posedge clk);
			end
			sd_buff_wr = 1'b0;
			@(posedge clk);
			io_ack[slot] = 1'b0;
			@(posedge clk);
		end
	endtask

	// Read target 0's sector buffer back through its HPS read port.
	task hps_peek(input [7:0] a, output [15:0] d);
		begin
			sd_buff_addr = a;
			@(posedge clk);
			@(posedge clk);
			d = sd_buff_din[0];
		end
	endtask

	task select_target(input [7:0] id_bit);
		integer guard;
		begin
			reg_write(`W_ODR, id_bit);
			reg_write(`W_ICR, 8'h05);              // A_DATA | A_SEL
			guard = 0;
			rv = 0;
			while (!rv[6] && guard < 2000) begin   // CSR bit 6 = BSY
				reg_read(`R_CSR, rv);
				guard = guard + 1;
			end
			reg_write(`W_ICR, 8'h01);              // drop SEL, keep data
		end
	endtask

	integer i;
	integer data_bytes;
	reg [7:0] inq [0:5];
	reg [7:0] stat, msg;
	reg seen_eodma_low;
	integer dma_bytes;
	reg [7:0] dma_b, dma_first;
	reg drq_seen;
	reg saw_data_phase;
	integer settle_iters;

	// ---- seam11 watchers --------------------------------------------------
	// Sticky observers for the un-gated-DACK experiment. These are the sim
	// twins of the sticky JTAG probes in rtl/dbg_probes.sv: same questions
	// (did a watchdog fire? was a DATA phase ever entered? did ACK pulse while
	// the target was in STATUS?), asked of the model first so the hardware
	// instrument is looking for something already known to be measurable.
	reg s11_watch = 0;
	reg s11_abort = 0, s11_ack_status = 0, s11_data_phase = 0;
	reg [2:0] s11_phase_armed, s11_phase_after1;
	integer   s11_free_clks;

	always @(posedge clk) if (s11_watch) begin
		if (dut.target[CD_DEV].target.wdog_abort ||
		    dut.target[0].target.wdog_abort) s11_abort <= 1;
		if (dut.scsi_ack && (dut.target[CD_DEV].target.phase == 3'd4))
			s11_ack_status <= 1;
		if (!dut.scsi_cd && dut.scsi_io && dut.scsi_req) s11_data_phase <= 1;
	end

	initial begin
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		// =============== seam1: selection through the register file ========
		select_target(8'h08);                      // CD-ROM at ID 3
		reg_read(`R_CSR, rv);
		ok("seam1 - target selected via 5380 registers (BSY asserted)", rv[6]);

		// =============== seam2: a whole INQUIRY transaction =================
		// 6-byte CDB: 12 00 00 00 20 00
		send_cmd_byte(8'h12);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h20);
		send_cmd_byte(8'h00);

		// Drop ICR_A_DATA: while we assert the bus, CDR loops back our own
		// output latch and every read returns the last CDB byte.
		reg_write(`W_ICR, 8'h00);

		for (i = 0; i < 6; i = i + 1) recv_byte(inq[i]);
		ok("seam2 - INQUIRY byte0 = peripheral type 05 (CD-ROM)", inq[0] == 8'h05);
		ok("seam2 - INQUIRY byte1 = 0x80 (removable)",            inq[1] == 8'h80);

		// =============== seam3: REQ is deferred by exactly one CSR read =====
		// Drain the rest of the data phase by watching the PHASE, not a byte
		// count -- the count is what the transfer-length bugs got wrong, so the
		// bench must not assume it.
		data_bytes = 6;
		wait_raw_req;
		while (!dut.scsi_cd && dut.scsi_io && data_bytes < 200) begin
			recv_byte(rv);
			data_bytes = data_bytes + 1;
			wait_raw_req;
		end
		ok("seam2 - INQUIRY served exactly the 32-byte allocation",
		   data_bytes == 32);

		// The target has now moved DATA -> STATUS. Wait for the raw REQ so the
		// deferral is measured against a REQ that really is asserted.
		wait_raw_req;
		ok("seam3 - target really has REQ asserted on the bus", dut.scsi_req);

		// This is the SCSI Manager's between-chunk settle loop:
		//     btst #5,CSR / beq exit / btst #3,BSR / bne loop
		// It exits only when a CSR read returns REQ=0.
		settle_iters = 0;
		rv = 8'hff;
		while (rv[`CSR_REQ] && settle_iters < 500) begin
			reg_read(`R_CSR, rv);
			settle_iters = settle_iters + 1;
		end
		ok("seam4 - settle loop exits at the Data->Status transition",
		   settle_iters < 500);
		ok("seam4 - it exits on the FIRST CSR read (the deferral window)",
		   settle_iters == 1);

		reg_read(`R_CSR, csr2);
		ok("seam3 - the next CSR read reveals REQ=1", csr2[`CSR_REQ]);

		// =============== seam5: end-of-DMA polarity =========================
		// Bus is in STATUS phase here, so EODMA must be asserted.
		reg_read(`R_BSR, bsr1);
		ok("seam5 - EODMA asserted outside a data phase", bsr1[`BSR_EODMA]);

		// finish the transaction: status + message
		recv_byte(stat);
		ok("seam5 - status byte = GOOD", stat == 8'h00);
		recv_byte(msg);
		ok("seam5 - message byte = COMMAND COMPLETE", msg == 8'h00);

		reg_read(`R_BSR, bsr1);
		ok("seam5 - EODMA asserted on a free bus", bsr1[`BSR_EODMA]);

		// =============== seam6: latched completion IRQ ======================
		reg_read(`R_RST, rv);                      // clear any stale latch
		reg_read(`R_BSR, bsr1);
		ok("seam6 - IRQ clear after a reg-7 read", !bsr1[`BSR_IRQ]);

		// Arm DMA, run a transaction, clear MR.DMA_MODE mid-flight (what the
		// real driver does), and confirm the latch still fires on DATA->STATUS.
		select_target(8'h08);
		send_cmd_byte(8'h12);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h20);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);                  // release the data bus

		reg_write(`W_MR, 8'h02);                   // MR.DMA_MODE
		reg_write(`W_TCR, 8'h01);                  // expect DATA IN phase
		reg_write(`W_IDMAR, 8'h00);                // arm DMA receive
		reg_write(`W_MR, 8'h00);                   // driver clears DMA mode early

		seen_eodma_low = 0;
		data_bytes = 0;
		wait_raw_req;
		while (!dut.scsi_cd && dut.scsi_io && data_bytes < 200) begin
			reg_read(`R_BSR, bsr2);
			if (!bsr2[`BSR_EODMA]) seen_eodma_low = 1;
			recv_byte(rv);
			data_bytes = data_bytes + 1;
			wait_raw_req;
		end
		ok("seam6 - EODMA deasserted during the data phase", seen_eodma_low);

		reg_read(`R_BSR, bsr2);
		ok("seam6 - IRQ latched on DATA->STATUS despite MR.DMA_MODE cleared",
		   bsr2[`BSR_IRQ]);

		reg_read(`R_RST, rv);
		reg_read(`R_BSR, bsr2);
		ok("seam6 - reg-7 read clears the IRQ latch", !bsr2[`BSR_IRQ]);

		// Consume status + message. Leaving them unread parks the target in
		// STATUS still asserting BSY, and the NEXT select_target then fails
		// silently -- which is exactly how seam7 came to arm pseudo-DMA
		// against a free bus and report a DRQ failure that was not real.
		reg_write(`W_MR, 8'h00);         // leave DMA mode
		recv_byte(rv);
		recv_byte(rv);
		begin : rel
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 2000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam6 - bus released after the transaction", !dut.scsi_bsy);

		// =============== seam7: pseudo-DMA actually delivers ================
		// If the DACK path cannot deliver a normal INQUIRY, that alone explains
		// a driver that arms DMA and polls forever -- so test the GOOD case
		// first, before drawing any conclusion from the failing one.
		select_target(8'h08);
		send_cmd_byte(8'h12);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h20);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		pdma_arm;

		dma_bytes = 0;
		wait_drq(drq_seen);
		ok("seam7 - BSR.DRQ asserts once pseudo-DMA is armed", drq_seen);
		while (drq_seen && !dut.scsi_cd && dut.scsi_io && dma_bytes < 100) begin
			dma_read_byte(dma_b);
			if (dma_bytes == 0) dma_first = dma_b;
			dma_bytes = dma_bytes + 1;
			wait_drq(drq_seen);
		end
		ok("seam7 - pseudo-DMA delivered the full 32-byte INQUIRY",
		   dma_bytes == 32);
		ok("seam7 - first pseudo-DMA byte is the real payload (05)",
		   dma_first == 8'h05);
		recv_byte(rv);   // status
		recv_byte(rv);   // message

		// =============== seam8: a CHECKed command serves no data ============
		// No image is mounted in this bench, so a CD READ CHECKs with the
		// no-media sense and never enters a data phase. An initiator that has
		// already armed pseudo-DMA then polls DRQ forever -- exactly the shape
		// the hardware probes recorded. This documents the mechanism; it does
		// not assert that the target is wrong to CHECK.
		select_target(8'h08);
		send_cmd_byte(8'h08);            // READ(6)
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);            // one block
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		pdma_arm;

		// NOTE: BSR.DRQ is scsi_req & dma_en with no phase qualification, so it
		// also asserts in STATUS. "Did DRQ assert" is therefore the wrong
		// question; "did a DATA phase ever happen" is the right one.
		saw_data_phase = 0;
		for (i = 0; i < 400; i = i + 1) begin
			if (!dut.scsi_cd && dut.scsi_io && dut.scsi_req) saw_data_phase = 1;
			@(posedge clk);
		end
		ok("seam8 - a no-media READ never enters a data phase", !saw_data_phase);
		ok("seam8 - it lands in STATUS instead", dut.scsi_cd && dut.scsi_io);

		// Complete the transaction. Leaving status/message unread parks the
		// target holding BSY and the NEXT selection fails silently -- the same
		// trap that made seam7 measure a free bus. Caught twice now; any test
		// that starts a transaction must finish it.
		reg_write(`W_MR, 8'h00);
		recv_byte(rv);
		recv_byte(rv);
		begin : rel8
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 2000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam8 - bus released after the CHECKed command", !dut.scsi_bsy);

		// =============== seam11: an un-gated DACK eats the STATUS byte ======
		// The 2026-08-22 review's central RTL claim, made falsifiable here.
		//
		// `bsr_dmarq = scsi_req & dma_en` (rtl/ncr5380.sv) carries no phase-match
		// term, and `dma_ack` is not gated by one either. A real 5380 inhibits
		// DRQ and halts the DMA handshake when REQ arrives with MSG/CD/IO not
		// matching TCR, leaving REQ visible in CSR so the driver's poll loop
		// exits and the SCSI Manager handles the phase change. That inhibition
		// is the entire exit ramp for "the target CHECKed instead of entering
		// the data phase" -- the no-media case seam8 just measured.
		//
		// So: arm pseudo-DMA for a DATA IN that never comes (TCR = 0x01), then
		// do what a blind pump loop does -- read the DACK window. If the review
		// is right, those reads ACK the STATUS and MESSAGE bytes as if they were
		// sector data, the transaction completes invisibly in microseconds, and
		// the initiator is left polling a bus that is free.
		//
		// These assertions describe a DEFECT. They invert when the pmatch gate
		// lands; that is the point of writing them down now.
		reg_read(`R_RST, rv);            // clear any IRQ latched by seam5..8
		s11_abort = 0; s11_ack_status = 0; s11_data_phase = 0; s11_watch = 1;

		select_target(8'h08);
		send_cmd_byte(8'h08);            // READ(6), LBA 0, 1 block, no media
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		reg_write(`W_TCR, 8'h01);        // driver expects DATA IN (msg=0,cd=0,io=1)
		pdma_arm;                        // MR.DMA_MODE + DMAinitRcv

		wait_raw_req;
		s11_phase_armed = dut.target[CD_DEV].target.phase;
		bsr1 = 0;
		reg_read(`R_BSR, bsr1);
		reg_read(`R_CSR, csr1);
		ok("seam11 - premise: armed while the target sits in STATUS, not DATA IN",
		   s11_phase_armed == 3'd4);
		ok("seam11 - premise: BSR reports the phase mismatch",
		   !bsr1[`BSR_PMATCH]);
		// DRQ stays VISIBLE, deliberately. A real 5380 does inhibit it here, and
		// two builds that did so both hung the machine; the live capture from the
		// second (2187326, confirmed by md5 and by its 14-instance ISSP set) shows
		// the driver arming pseudo-DMA and then performing ZERO DACK reads while
		// the target sat in a legitimate DATA-IN phase, until the target's bus
		// watchdog fired at 129 ms and left it polling a free bus forever with
		// BSR=0x98 -- DRQ clear. Whatever suppressed DRQ there, hiding it from
		// this driver is what breaks the machine.
		//
		// The confirmed defect is that a DACK access must not ACK a byte from a
		// non-data phase. That is fixed below by gating dma_ack alone. The exit
		// ramp the review actually relies on is REQ staying visible in CSR, which
		// is asserted further down and does not need DRQ suppressed.
		ok("seam11 - DRQ is still offered; only the ACK is withheld",
		   bsr1[`BSR_DRQ] && dreq);
		// The IRQ latch is deliberately NOT touched by this change -- see the
		// note in ncr5380.sv. It stays edge-triggered, so a mismatch that
		// predates the arm still produces no IRQ. That is a known gap, left
		// open on purpose so this experiment changes exactly one thing.
		ok("seam11 - the completion IRQ still does not latch (KNOWN GAP)",
		   !bsr1[`BSR_IRQ]);

		// The blind pump loop's first read.
		dma_read_byte(dma_b);
		repeat (8) @(posedge clk);
		s11_phase_after1 = dut.target[CD_DEV].target.phase;
		ok("seam11 - a DACK read still RETURNS the byte (a real 5380 does too)",
		   dma_b == 8'h02);              // CHECK CONDITION
		ok("seam11 - but does NOT ACK it: the target stays in STATUS",
		   s11_phase_after1 == 3'd4);

		// The second read.
		dma_read_byte(dma_b);
		begin : s11_free
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 200) begin @(posedge clk); g = g + 1; end
			s11_free_clks = g;
		end
		ok("seam11 - a second blind read cannot end the transaction either",
		   dut.scsi_bsy);
		s11_watch = 0;

		ok("seam11 - no DATA phase was ever entered", !s11_data_phase);
		ok("seam11 - ACK was never asserted in STATUS", !s11_ack_status);
		ok("seam11 - no watchdog was involved", !s11_abort);
		// The exit ramp: the poll loop tests CSR bit 5.
		reg_read(`R_CSR, csr1);
		ok("seam11 - CSR shows REQ, so the polling loop can exit",
		   csr1[`CSR_REQ]);

		// Finish the transaction whichever way the DUT behaved. Under today's
		// RTL the two DACK reads already ended it; once the pmatch gate lands
		// they will not ACK at all and status/message are still waiting on the
		// register path. Leaving either case unfinished parks the target
		// holding BSY and the NEXT selection fails silently -- the trap this
		// bench has now been caught by three times.
		reg_write(`W_MR, 8'h00);
		if (dut.scsi_bsy) recv_byte(rv);
		if (dut.scsi_bsy) recv_byte(rv);
		begin : rel11
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 4000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam11 - bus released before the next test", !dut.scsi_bsy);

		// =============== seam12: pseudo-DMA WRITE with a stale TCR ==========
		// The regression that gating the DMA handshake on bsr_pmatch caused on
		// real hardware, and that seam11 could not see because it only covers
		// the READ direction.
		//
		// The Plus driver does NOT reprogram TCR for a write data phase -- the
		// hardware capture showed pmatch reading 0 for the whole transfer. A
		// gate keyed on TCR therefore refuses every ACK, the target waits for a
		// handshake that never comes, and its bus watchdog fires at 129 ms.
		// Measured on the DE10 as: 8 DACK writes, wdog=1, ACK-in-STATUS=0, and
		// the machine hanging BEFORE "Welcome to Macintosh".
		//
		// So this deliberately leaves TCR at 0x01 (data IN) across a data OUT
		// phase and requires the transfer to work anyway.
		img_size = 32'd2048;
		img_mounted[0] = 1'b1;
		@(posedge clk); @(posedge clk);
		img_mounted[0] = 1'b0;
		repeat (50) @(posedge clk);

		s11_abort = 0; s11_watch = 1;
		select_target(8'h40);                 // disk at ID 6
		send_cmd_byte(8'h0A);                 // WRITE(6), LBA 0, 1 block
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		reg_write(`W_TCR, 8'h01);             // STALE: says data IN, this is OUT
		reg_write(`W_MR,  8'h02);
		reg_write(`W_DMAS, 8'h00);            // Start DMA Send
		wait_raw_req;

		ok("seam12 - premise: the target is in a WRITE data phase",
		   dut.target[0].target.phase == 3'd3);
		reg_read(`R_BSR, bsr1);
		ok("seam12 - premise: TCR does NOT match it (this is the hardware case)",
		   !bsr1[`BSR_PMATCH]);
		ok("seam12 - DRQ is still offered, because the BUS is in a data phase",
		   bsr1[`BSR_DRQ]);

		begin : s12
			integer n;
			for (n = 0; n < 8; n = n + 1) begin
				dma_write_byte(8'hA5);
				repeat (4) @(posedge clk);
			end
		end
		ok("seam12 - the DACK writes DO handshake despite the stale TCR",
		   dut.target[0].target.data_cnt >= 8);
		ok("seam12 - and no watchdog fired", !s11_abort);
		s11_watch = 0;

		// Finish it: pump the rest of the block, then take status and message.
		begin : s12done
			integer n, g;
			for (n = 8; n < 512; n = n + 1) begin
				g = 0;
				while (!dut.scsi_req && g < 4000) begin @(posedge clk); g = g + 1; end
				dma_write_byte(8'hA5);
			end
		end
		reg_write(`W_MR, 8'h00);
		if (dut.scsi_bsy) recv_byte(stat);
		if (dut.scsi_bsy) recv_byte(msg);
		begin : rel12
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 8000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam12 - the WRITE completes with GOOD status", stat == 8'h00);
		ok("seam12 - bus released", !dut.scsi_bsy);

		// =============== seam13: the driver pumps BEFORE the data phase =====
		// The window neither seam11 nor seam12 models, and the one the plan named
		// as unmeasured: both of those wait_raw_req first, so they only ever pump
		// once the target is ALREADY offering bytes.
		//
		// It matters because it is the last hypothesis under which the DACK gate
		// itself -- rather than the completion-IRQ latch the two failed attempts
		// also changed -- could be what hung the machine. If a blind pump loop
		// starts while the target is still in COMMAND, or still fetching the
		// sector with REQ held low, then a gate that refuses those accesses drops
		// bytes the un-gated code silently accepted, and the transfer deadlocks.
		// That is the shape of both hardware failures.
		//
		// So: arm pseudo-DMA and start reading IMMEDIATELY after the last CDB
		// byte, with no wait for REQ at all, and require the READ to complete
		// with every byte intact.
		hps_enable = 1'b1;
		img_size = 32'd2048;
		img_mounted[0] = 1'b1;
		@(posedge clk); @(posedge clk);
		img_mounted[0] = 1'b0;
		repeat (50) @(posedge clk);

		s11_abort = 0; s11_watch = 1;
		s11_data_phase = 0;
		select_target(8'h40);                 // disk at ID 6
		send_cmd_byte(8'h08);                 // READ(6), LBA 0, 1 block
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		reg_write(`W_TCR, 8'h01);
		reg_write(`W_MR,  8'h02);
		reg_write(`W_IDMAR, 8'h00);          // arm receive -- and pump at once

		// Blind reads with NO handshake wait, exactly as the wedge loop does.
		// Whatever they return is discarded; the point is that they must not
		// corrupt or stall the transfer that follows.
		begin : s13blind
			integer n;
			reg [7:0] junk;
			for (n = 0; n < 8; n = n + 1) begin
				dma_read_byte(junk);
				repeat (2) @(posedge clk);
			end
		end
		ok("seam13 - premise: pumped before the target offered a byte",
		   dut.target[0].target.data_cnt < 8);
		ok("seam13 - no watchdog fired during the blind pump", !s11_abort);

		// Now let it run properly and require the whole block through.
		begin : s13rest
			integer n, g;
			reg [7:0] junk;
			n = 0;
			while (n < 512 && dut.scsi_bsy) begin
				g = 0;
				while (!dut.scsi_req && dut.scsi_bsy && g < 8000) begin
					@(posedge clk); g = g + 1;
				end
				if (dut.scsi_req && !(dut.scsi_cd || dut.scsi_msg)) begin
					dma_read_byte(junk);
					n = n + 1;
				end else begin
					n = 512;   // target left the data phase; stop pumping
				end
			end
		end
		s11_watch = 0;
		reg_write(`W_MR, 8'h00);
		ok("seam13 - the target still delivered a full 512-byte block",
		   dut.target[0].target.data_cnt >= 512);
		stat = 8'hFF; msg = 8'hFF;
		if (dut.scsi_bsy) recv_byte(stat);
		if (dut.scsi_bsy) recv_byte(msg);
		ok("seam13 - and the READ completed with GOOD status", stat == 8'h00);
		begin : rel13
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 8000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam13 - bus released, no deadlock from the early pump",
		   !dut.scsi_bsy);

		// =============== seam9: a fetch that never completes ================
		// io_busy holds REQ low (scsi.v:239) AND resets the bus watchdog every
		// cycle (scsi.v:1195). So while a sector fetch is outstanding the target
		// cannot time out -- if the HPS never answers, it holds BSY forever with
		// REQ low and no recovery path. That is the shape the hardware probes
		// recorded: initiator polling, no DRQ, activity LED stuck on.
		//
		// A real drive that loses a fetch still releases the bus eventually.
		hps_enable = 1'b0;               // HPS never answers
		saw_io_rd  = 1'b0;
		mount_cd(32'd120000);

		select_target(8'h08);
		send_cmd_byte(8'h08);            // READ(6), LBA 0, 1 block
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		pdma_arm;

		begin : fetchwait
			integer g;
			g = 0;
			while (!saw_io_rd && g < 20000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam9 - target requested a sector fetch", saw_io_rd);

		begin : busfree
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 300000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam9 - target releases the bus when a fetch never completes",
		   !dut.scsi_bsy);

		// The stalled request itself must be cleared. Checked BEFORE the HPS is
		// re-enabled: re-enabling it answers the outstanding fetch and clears
		// io_rd by itself, which masks the difference entirely (the first two
		// versions of this test both passed with the clear removed).
		//
		// io_rd_d, not the module's io_rd output. Since the 3B arbitration fix
		// the output is `io_rd_d | ca_io_rd_w`, and with the HPS switched off the
		// CD-audio engine's own TOC fetch is legitimately still outstanding here
		// -- it is not the SCSI command's request and the watchdog has no
		// business clearing it. The invariant this test exists for is about the
		// DATA-PATH request, and specifically about io_busy, which reads io_rd_d
		// alone; the leg below (the next command still works) checks that end of
		// it behaviourally.
		ok("seam9 - the stalled request is cleared, not left asserted",
		   !dut.target[CD_DEV].target.io_rd_d);

		// Releasing the bus is not enough. A stale io_rd left asserted keeps
		// io_busy high, which suppresses REQ for the NEXT command too -- the
		// failure the any_rst clear already exists to prevent (see scsi.v).
		// Without this leg, dropping the io_rd clear from the fix still passes,
		// because a second stall timeout releases the bus anyway.
		hps_enable = 1'b1;
		select_target(8'h08);
		send_cmd_byte(8'h12);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h20);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		recv_byte(dma_b);
		ok("seam9 - the NEXT command still works after a stalled fetch",
		   dma_b == 8'h05);
		// =============== seam10: the REQ deferral must be self-limiting ======
		// req_deferred hides a newly asserted REQ from CSR until one CSR read
		// COMPLETES, and "completes" is detected via csr_rd, which is gated by
		// ior (= !_cpuUDS). But rdata is NOT gated by ior, so a poll through the
		// other byte lane reads the right value while never clearing the
		// deferral -- REQ stays hidden forever and a driver polling CSR bit 5
		// spins for good. That is the loop disassembled from hardware:
		//     BTST D3,(A0) / BNE exit / BTST #5,(64,A3) / BEQ loop
		// A latch that can hide REQ indefinitely is wrong however it is polled.
		select_target(8'h08);
		// Hand over one CDB byte with the BLIND handshake, which touches no CSR.
		// select_target polls CSR with ior, which would have already cleared the
		// deferral -- the first version of this test passed for exactly that
		// reason. ack_pulse returns with a FRESH REQ asserted and no CSR read
		// since it rose, which is the state the hazard needs.
		reg_write(`W_ODR, 8'h12);
		ack_pulse(8'h01);
		ok("seam10 - target is asserting REQ on the bus", dut.scsi_req);
		ok("seam10 - and that REQ is currently deferred (test premise)",
		   dut.req_deferred);

		begin : deferral
			integer g;
			csr1 = 0;
			g = 0;
			while (!csr1[`CSR_REQ] && g < 40) begin
				reg_read_noior(`R_CSR, csr1);
				g = g + 1;
			end
		end
		ok("seam10 - REQ becomes visible even when polled without ior",
		   csr1[`CSR_REQ]);
		ior = 0;

		// The age-out is a second, independent safety net: the deferral must
		// lapse even with NO CSR access whatsoever. Without this leg the lane
		// fix alone satisfies the test above, and the age-out ships untested --
		// which is the failure mode that made the command ladder unreadable.
		select_target(8'h08);
		reg_write(`W_ODR, 8'h12);
		ack_pulse(8'h01);
		ok("seam10 - premise: a fresh REQ is deferred again", dut.req_deferred);
		repeat (1200) @(posedge clk);
		ok("seam10 - the deferral ages out with no CSR access at all",
		   !dut.req_deferred);

		// =============== seam14: a WRITE flush that never completes =========
		// seam9 covers a stalled READ, and it recovers cleanly: the stall
		// happens in DATA_OUT, so the abort takes the "not in status yet"
		// branch, sends CHECK CONDITION and the initiator sees a failed
		// command. A stalled WRITE is a different shape and has never been
		// tested.
		//
		// A block WRITE's LAST flush is issued at PHASE_STATUS_OUT (scsi.v's
		// req_wr tail clause) -- so if the HPS never answers THAT one, the
		// target is stalled while ALREADY in STATUS_OUT, with its status byte
		// still undelivered. The abort branch keys on the phase, treats
		// "in STATUS_OUT" as "status already sent", and drops straight to
		// IDLE. BSY falls with no status and no COMMAND COMPLETE, and the
		// initiator waits for a completion that can never arrive.
		//
		// That is the 2026-08-22 soak wedge: an io-stall on a disk write.
		// seam10 leaves the CD target mid-CDB holding BSY; a busy bus blocks
		// selection of any other target (scsi.v's bus_busy gate), so wait it out.
		begin : s14idle
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 20000) begin @(posedge clk); g = g + 1; end
		end
		hps_disk_enable = 1'b0;
		img_size = 32'd2048;
		img_mounted[0] = 1'b1;
		@(posedge clk); @(posedge clk);
		img_mounted[0] = 1'b0;
		repeat (50) @(posedge clk);

		select_target(8'h40);                 // disk at ID 6
		send_cmd_byte(8'h0A);                 // WRITE(6), LBA 0, 1 block
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		reg_write(`W_MR,  8'h02);
		reg_write(`W_DMAS, 8'h00);            // Start DMA Send
		wait_raw_req;

		// Pump the whole 512-byte block. No flush can complete, but the data
		// phase itself does not need one.
		begin : s14pump
			integer n, g;
			for (n = 0; n < 512; n = n + 1) begin
				g = 0;
				while (!dut.scsi_req && g < 4000) begin @(posedge clk); g = g + 1; end
				dma_write_byte(8'h5A);
			end
		end
		reg_write(`W_MR, 8'h00);

		repeat (20) @(posedge clk);
		ok("seam14 - premise: the target reached STATUS with a flush pending",
		   dut.target[0].target.phase == 3'd4);

		// The target must still deliver a status byte. Poll for REQ across the
		// io-stall timeout rather than calling recv_byte, which would block.
		begin : s14req
			integer g;
			g = 0;
			while (!dut.scsi_req && dut.scsi_bsy && g < 200000) begin
				@(posedge clk); g = g + 1;
			end
		end
		ok("seam14 - the target still REQs its status after the stall aborts",
		   dut.scsi_req && dut.scsi_bsy);

		stat = 8'hff; msg = 8'hff;
		if (dut.scsi_req && dut.scsi_bsy) recv_byte(stat);
		ok("seam14 - and that status is CHECK CONDITION, not silence",
		   stat == 8'h02);

		begin : s14msg
			integer g;
			g = 0;
			while (!dut.scsi_req && dut.scsi_bsy && g < 200000) begin
				@(posedge clk); g = g + 1;
			end
		end
		if (dut.scsi_req && dut.scsi_bsy) recv_byte(msg);
		ok("seam14 - followed by COMMAND COMPLETE", msg == 8'h00);

		begin : s14rel
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 200000) begin @(posedge clk); g = g + 1; end
		end
		ok("seam14 - bus released", !dut.scsi_bsy);

		// And the stalled flush must not be left asserted to poison the next
		// command -- the same requirement seam9 makes of a stalled read.
		ok("seam14 - the stalled flush is cleared, not left asserted",
		   !io_wr[0]);

		hps_disk_enable = 1'b1;
		select_target(8'h40);
		send_cmd_byte(8'h12);                 // INQUIRY
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h20);
		send_cmd_byte(8'h00);
		reg_write(`W_ICR, 8'h00);
		recv_byte(dma_b);
		ok("seam14 - the NEXT command still works after a stalled flush",
		   dma_b == 8'h00);

		// ==================================================================
		// seam15: a target's sector buffer must capture ONLY its own slot's
		// HPS session.
		//
		// hps_io gives sd_ack per slot but sd_buff_addr/dout/wr are a SHARED
		// bus. ncr5380 qualified the strobe with the target's SCSI BSY instead
		// of its slot ack, which is a proxy that is only correct while every
		// HPS transfer belongs to whichever target happens to own the bus.
		// The CD-audio engine broke that assumption: it fetches while bus-IDLE,
		// so its frames landed in whatever OTHER target was busy at the time.
		//
		// On hardware 2026-08-26 that wrote CD-DA audio into two mounted disk
		// images -- sector-aligned, at legitimate LBAs, destroying both volume
		// headers. Reads are corrupted by the same path.
		// ==================================================================
		begin : seam15
			reg [15:0] own0, own1, after0, after1;
			reg        landed, survived;
			reset = 1'b1; repeat (8) @(posedge clk);
			reset = 1'b0; repeat (8) @(posedge clk);
			hps_disk_enable = 1'b0;
			select_target(8'h40);            // target 0 = SCSI ID 6
			send_cmd_byte(8'h12);            // stay in CMD phase, BSY asserted
			hps_manual = 1'b1;

			hps_session(0, 16'h1100);        // the disk's OWN session: must land
			hps_peek(8'd0, own0);
			hps_peek(8'd3, own1);
			landed = (own0 === 16'h1100) && (own1 === 16'h1103);

			hps_session(CD_DEV, 16'hEE00);   // ANOTHER slot's session: must not
			hps_peek(8'd0, after0);
			hps_peek(8'd3, after1);
			survived = (after0 === own0) && (after1 === own1);

			hps_manual = 1'b0;
			hps_disk_enable = 1'b1;

			ok("seam15 - a target captures its OWN slot's HPS session", landed);
			ok("seam15 - and is NOT written by another slot's session", survived);
			if (!survived)
				$display("          buffer went %04x/%04x -> %04x/%04x: the CD slot's data landed in the DISK's buffer",
				         own0, own1, after0, after1);
		end

		// ==================================================================
		// seam17: a ring-WRAPPING read, then a short one, through the real
		// pseudo-DMA host-face and with VARIABLE HPS latency.
		//
		// Chasing the open defect of 2026-08-26: copying off a CD corrupted
		// about one file in 55, and the wrong bytes were the previous
		// command's data in the same ring slot (its sector 161, slot
		// 161 mod 32 = 1, showing up at the next file's offset 512 = slot 1).
		// Stale head, fresh tail -- the host ran PAST the fetch frontier that
		// rd_cur_unfilled is supposed to hold it behind.
		//
		// cd38 in tb_scsi_cdrom does not reproduce it, and that bench drives
		// scsi.v directly with a fixed-latency HPS. This one goes through
		// ncr5380's DACK path with a randomised fill time, which is the
		// "just-in-time fill" MacLC's note blames.
		// ==================================================================
		begin : seam17
			integer it, i4, bad4, sec4, first4, badtot, firstit;
			integer lba_l, lba_s, nblk_l;
			reg [7:0] got4, want4;
			reg       drq4;
			reg [31:0] hl, hs;
			// seam15 leaves target 0 parked in CMD phase holding BSY, so the
			// CD cannot win selection until the bus is cleared.
			reset = 1'b1; repeat (8) @(posedge clk);
			reset = 1'b0; repeat (16) @(posedge clk);
			hps_data_mode = 1'b1;
			hps_enable    = 1'b1;
			hps_disk_enable = 1'b1;
			mount_cd(32'd400000);
			// the engine's TOC acquisition outlasts mount_cd's fixed wait once
			// latency is randomised; without this the READs are refused with
			// cd_no_media and the test measures nothing.
			begin : tocw
				integer gt;
				gt = 0;
				while (!dut.target[CD_DEV].target.ca_toc_ready && gt < 200000) begin
					@(posedge clk); gt = gt + 1;
				end
			end

			badtot = 0; firstit = -1;
			// SWEEP. The hardware failure was 1 file in 55, so a single pair of
			// reads is unlikely to land in the window. Each iteration moves the
			// LBAs, the long transfer's length (always > 32 sectors so the ring
			// still wraps) and, through the server's PRNG, every fill latency.
			for (it = 0; it < 14 && firstit < 0; it = it + 1) begin
				nblk_l = 9 + (it % 4);                  // 9..12 blocks = 36..48 sectors
				lba_l  = 1000 + it * 131;
				lba_s  = 60000 + it * 97;

				// ---- long READ(10), wraps the ring ----
				select_target(8'h08);
				hl = lba_l;
				send_cmd_byte(8'h28);            send_cmd_byte(8'h00);
				send_cmd_byte(hl[31:24]);        send_cmd_byte(hl[23:16]);
				send_cmd_byte(hl[15:8]);         send_cmd_byte(hl[7:0]);
				send_cmd_byte(8'h00);            send_cmd_byte(8'h00);
				send_cmd_byte(nblk_l[7:0]);      send_cmd_byte(8'h00);
				reg_write(`W_ICR, 8'h00);
				pdma_arm;
				bad4 = 0; first4 = -1;
				for (i4 = 0; i4 < nblk_l * 2048; i4 = i4 + 1) begin
					wait_drq(drq4);
					if (!drq4) i4 = nblk_l * 2048;
					else begin
						dma_read_byte(got4);
						sec4  = (lba_l * 4) + (i4 / 512);
						want4 = sec4[7:0] ^ (i4 % 512);
						if (got4 !== want4) begin
							if (first4 < 0) first4 = i4;
							bad4 = bad4 + 1;
						end
					end
				end
				if (bad4 && firstit < 0) begin
					firstit = it; badtot = bad4;
					$display("          it %0d LONG read: %0d wrong, first at %0d (slot %0d)",
					         it, bad4, first4, (first4/512) % 32);
				end
				begin : fin_l
					integer g4;
					g4 = 0;
					while (dut.scsi_bsy && g4 < 60000) begin @(posedge clk); g4 = g4 + 1; end
				end

				// ---- short READ(6) straight after: the ring still holds the
				//      long transfer's occupants in slots 0..31 ----
				select_target(8'h08);
				hs = lba_s;
				send_cmd_byte(8'h08);
				send_cmd_byte({3'd0, hs[20:16]});
				send_cmd_byte(hs[15:8]);
				send_cmd_byte(hs[7:0]);
				send_cmd_byte(8'h02);
				send_cmd_byte(8'h00);
				reg_write(`W_ICR, 8'h00);
				pdma_arm;
				bad4 = 0; first4 = -1;
				for (i4 = 0; i4 < 4096; i4 = i4 + 1) begin
					wait_drq(drq4);
					if (!drq4) i4 = 4096;
					else begin
						dma_read_byte(got4);
						sec4  = (lba_s * 4) + (i4 / 512);
						want4 = sec4[7:0] ^ (i4 % 512);
						if (got4 !== want4) begin
							if (first4 < 0) first4 = i4;
							bad4 = bad4 + 1;
						end
					end
				end
				if (bad4 && firstit < 0) begin
					firstit = it; badtot = bad4;
					$display("          it %0d SHORT read: %0d wrong, first at %0d (slot %0d) -- STALE RING",
					         it, bad4, first4, (first4/512) % 32);
				end
				begin : fin_s
					integer g5;
					g5 = 0;
					while (dut.scsi_bsy && g5 < 60000) begin @(posedge clk); g5 = g5 + 1; end
				end
			end

			ok("seam17 - READ data survives a ring wrap, swept over LBAs and latencies",
			   firstit < 0);
			$display("          (%0d HPS fills at randomised latency, %0d iterations)",
			         hps_fills, it);
			hps_data_mode = 1'b0;
		end

		// ==================================================================
		// seam18: a BLIND pseudo-DMA pump against one late HPS fill.
		//
		// Every read loop above polls BSR.DRQ before every byte, so the
		// initiator can never pass the fetch frontier -- rd_cur_unfilled drops
		// REQ, DRQ follows, and the polite initiator waits. That is why cd38,
		// seam17 and the 694-fill sweep were all green against a hardware
		// failure that is deterministic.
		//
		// The real Mac Plus is not polite. Its SCSI Manager blind loop reads
		// the DACK window at instruction rate without re-polling, and the Plus
		// has no hardware hold-off (DRQ is not wired to DTACK -- see the
		// release-blocker note in SCSI_UPGRADE_PLAN.md 5.x): once the pump
		// starts, nothing the target does can stop it. On the RTL side the
		// same is true structurally: `rdata = dack ? cur_data` serves a byte
		// regardless of REQ, dma_ack is gated only on dma_en & bus_data_phase,
		// and data_cnt advances on every ACK edge. REQ/DRQ negation is
		// ADVISORY. So one HPS fill arriving later than the pump's per-sector
		// time hands the initiator the ring slot's PREVIOUS occupant until the
		// fill catches up mid-sector: stale head, fresh tail, GOOD status --
		// byte for byte the 2026-08-26 hardware signature (DRA01E01.GRB,
		// slot 1, ~378/~404 stale bytes, both runs).
		//
		// Here: a 40-sector READ seeds the ring, then a 2-block READ is pumped
		// blind after ONE initial DRQ wait (the wait covers slot 0 -- which is
		// exactly why the hardware corruption starts at slot 1, the first slot
		// the initial handshake cannot protect). Fills 0 and 1 are forced to
		// 3000 clocks; the pump crosses into slot 1 at ~2000.
		// ==================================================================
		begin : seam18
			integer i5, bad5, stale5, first5, last5, sec5;
			integer lba_l5, lba_s5, prev_sec5;
			reg [7:0] got5, want5, stale_want5, stat5;
			reg       drq5;
			reg [31:0] hl5, hs5;
			hps_data_mode = 1'b1;
			hps_force_delay = 0; hps_force_n = 0;

			lba_l5 = 2000;    // 10 blocks = 40 sectors: ring slot 1 last holds sector 33
			lba_s5 = 70000;

			// ---- seed the ring: long READ(10), pumped politely ----
			select_target(8'h08);
			hl5 = lba_l5;
			send_cmd_byte(8'h28);            send_cmd_byte(8'h00);
			send_cmd_byte(hl5[31:24]);       send_cmd_byte(hl5[23:16]);
			send_cmd_byte(hl5[15:8]);        send_cmd_byte(hl5[7:0]);
			send_cmd_byte(8'h00);            send_cmd_byte(8'h00);
			send_cmd_byte(8'h0a);            send_cmd_byte(8'h00);
			reg_write(`W_ICR, 8'h00);
			pdma_arm;
			for (i5 = 0; i5 < 10 * 2048; i5 = i5 + 1) begin
				wait_drq(drq5);
				if (!drq5) i5 = 10 * 2048;
				else dma_read_byte(got5);
			end
			begin : fin_l5
				integer g5;
				g5 = 0;
				while (dut.scsi_bsy && g5 < 60000) begin @(posedge clk); g5 = g5 + 1; end
			end

			// ---- short READ(6), pumped BLIND ----
			// Fills 0 and 1 both take 12000 clocks. The single first-DRQ wait
			// absorbs fill 0 (that is the initiator's per-transfer handshake);
			// nothing absorbs fill 1, because a blind pump does not look again.
			//
			// SCALING: on hardware the Plus blind loop moves one byte per
			// ~1.5 us (~50 clocks) and a laggard HPS fill costs ~1 ms
			// (~30k clocks), far under the real 516 ms io-stall watchdog. This
			// bench builds with IOWDOG_LOG=14 (~16k clocks) so a 30k fill would
			// abort with CHECK CONDITION instead of corrupting. Keep the
			// PROPORTIONS (fill ~1.5x the pump's per-sector time, both under
			// the watchdog) by pacing the pump at 16 clocks/byte: a sector
			// takes 8192 clocks and the pump crosses into slot 1 ~4k clocks
			// before its fill lands.
			hps_force_delay = 12000; hps_force_n = 2;
			select_target(8'h08);
			hs5 = lba_s5;
			send_cmd_byte(8'h08);
			send_cmd_byte({3'd0, hs5[20:16]});
			send_cmd_byte(hs5[15:8]);
			send_cmd_byte(hs5[7:0]);
			send_cmd_byte(8'h02);
			send_cmd_byte(8'h00);
			reg_write(`W_ICR, 8'h00);
			pdma_arm;
			// ONE handshake, then blind. Re-invoked only because wait_drq's
			// poll bound is shorter than the forced 30k-clock fill; this is
			// still a single logical "wait for the first DRQ".
			begin : first_drq
				integer tr5;
				drq5 = 0;
				for (tr5 = 0; tr5 < 8 && !drq5; tr5 = tr5 + 1) wait_drq(drq5);
			end
			bad5 = 0; stale5 = 0; first5 = -1; last5 = -1;
			prev_sec5 = (lba_l5 * 4) + 33;   // slot 1's previous occupant
			if (drq5) begin
				for (i5 = 0; i5 < 4096; i5 = i5 + 1) begin
					repeat (12) @(posedge clk);   // + 4 in dma_read_byte = 16 clk/byte (see SCALING)
					dma_read_byte(got5);
					sec5  = (lba_s5 * 4) + (i5 / 512);
					want5 = sec5[7:0] ^ (i5 % 512);
					if (got5 !== want5) begin
						if (first5 < 0) first5 = i5;
						last5 = i5;
						bad5 = bad5 + 1;
						stale_want5 = prev_sec5[7:0] ^ (i5 % 512);
						if (got5 === stale_want5) stale5 = stale5 + 1;
						if (bad5 <= 12)
							$display("            mism i=%0d got=%02x want=%02x (phase=%0d data_cnt=%0d rd_hps_blk=%0d)",
							         i5, got5, want5,
							         dut.target[CD_DEV].target.phase,
							         dut.target[CD_DEV].target.data_cnt,
							         dut.target[CD_DEV].target.rd_hps_blk);
					end
				end
			end
			if (bad5) begin
				$display("          seam18 BLIND pump: %0d wrong bytes, offsets %0d..%0d (slot %0d..%0d)",
				         bad5, first5, last5, (first5/512) % 32, (last5/512) % 32);
				$display("          %0d of %0d wrong bytes are the ring slot's PREVIOUS occupant (stale head, fresh tail)",
				         stale5, bad5);
			end
			// The pinned invariant: a blind initiator must never be served an
			// unfilled sector. RED before the bus hold-off, GREEN after -- this
			// is the reproduction of the 2026-08-26 CD->disk corruption
			// (SCSI_UPGRADE_PLAN.md) and the test that fix (a) closes it.
			ok("seam18 - a blind pseudo-DMA pump cannot outrun the fetch frontier", drq5 && (bad5 == 0));
			// Mechanism check: if corruption happened, it must be the previous
			// occupant of the same ring slot -- the hardware signature. If this
			// one FAILS while seam18 fails, the corruption came from somewhere
			// else and the model is wrong again.
			ok("seam18b - any stale data is the ring slot's previous occupant",
			   (bad5 == 0) || (stale5 == bad5));
			// Anti-vacuity. seam18 passing because the pump happened not to
			// catch up with the fill would look exactly like seam18 passing
			// because the interlock worked. This says the interlock ENGAGED.
			ok("seam18f - premise: the CPU hold-off actually engaged", saw_bus_hold);
			// See seam19's anti-alias guard: without distinguishable payload tags
			// seam18 would pass whether or not the hold-off worked.
			ok("seam18h - premise: stale and fresh payloads are distinguishable",
			   (prev_sec5 % 256) != (((lba_s5 * 4) + 1) % 256));
			// And the transfer that was stalled rather than corrupted must
			// report GOOD -- a hold-off that turned corruption into a spurious
			// error would be no better than the corruption.
			ok("seam18g - a stalled (not corrupted) read still reports GOOD",
			   !dut.target[CD_DEV].target.frontier_violated);
			begin : fin_s5
				integer g6;
				g6 = 0;
				while (dut.scsi_bsy && g6 < 60000) begin @(posedge clk); g6 = g6 + 1; end
			end
			hps_data_mode = 1'b0;
			hps_force_delay = 0; hps_force_n = 0;
		end

		// ==================================================================
		// seam19: fix (a) DEFEATED, to keep fix (c) honest.
		//
		// seam18 above proves the hold-off stops the blind pump. That makes the
		// frontier breach unreachable through the normal path -- and therefore
		// makes (c), the CHECK CONDITION backstop, untestable there. Both were
		// built for a reason: (a) is the interlock, (c) is what happens if the
		// interlock is ever wrong, bypassed, or ported to glue that does not
		// wire DTACK. A backstop nothing exercises is a backstop nobody knows
		// is broken.
		//
		// So this is seam18 byte for byte with ONE difference: the pump uses
		// dma_read_byte_nowait and ignores bus_hold, which is the Plus exactly
		// as it behaved before (a). The corruption MUST come back -- and it
		// must be reported rather than passed off as GOOD.
		// ==================================================================
		begin : seam19
			integer i6, bad6, stale6, sec6;
			integer lba_l6, lba_s6, prev_sec6;
			reg [7:0] got6, want6, stale_want6, stat6;
			reg       drq6;
			reg [31:0] hl6, hs6;
			hps_data_mode = 1'b1;
			hps_force_delay = 0; hps_force_n = 0;

			lba_l6 = 3010;   // see the anti-alias guard below before changing
			lba_s6 = 80000;

			// ---- seed the ring, politely ----
			select_target(8'h08);
			hl6 = lba_l6;
			send_cmd_byte(8'h28);            send_cmd_byte(8'h00);
			send_cmd_byte(hl6[31:24]);       send_cmd_byte(hl6[23:16]);
			send_cmd_byte(hl6[15:8]);        send_cmd_byte(hl6[7:0]);
			send_cmd_byte(8'h00);            send_cmd_byte(8'h00);
			send_cmd_byte(8'h0a);            send_cmd_byte(8'h00);
			reg_write(`W_ICR, 8'h00);
			pdma_arm;
			for (i6 = 0; i6 < 10 * 2048; i6 = i6 + 1) begin
				wait_drq(drq6);
				if (!drq6) i6 = 10 * 2048;
				else dma_read_byte(got6);
			end
			begin : fin_l6
				integer g8;
				g8 = 0;
				while (dut.scsi_bsy && g8 < 60000) begin @(posedge clk); g8 = g8 + 1; end
			end

			// ---- short READ(6), pumped blind AND deaf to the hold-off ----
			hps_force_delay = 12000; hps_force_n = 2;
			select_target(8'h08);
			hs6 = lba_s6;
			send_cmd_byte(8'h08);
			send_cmd_byte({3'd0, hs6[20:16]});
			send_cmd_byte(hs6[15:8]);
			send_cmd_byte(hs6[7:0]);
			send_cmd_byte(8'h02);
			send_cmd_byte(8'h00);
			reg_write(`W_ICR, 8'h00);
			pdma_arm;
			begin : first_drq6
				integer tr6;
				drq6 = 0;
				for (tr6 = 0; tr6 < 8 && !drq6; tr6 = tr6 + 1) wait_drq(drq6);
			end
			bad6 = 0; stale6 = 0;
			prev_sec6 = (lba_l6 * 4) + 33;
			if (drq6) begin
				for (i6 = 0; i6 < 4096; i6 = i6 + 1) begin
					repeat (12) @(posedge clk);
					dma_read_byte_nowait(got6);       // <-- the only difference
					sec6  = (lba_s6 * 4) + (i6 / 512);
					want6 = sec6[7:0] ^ (i6 % 512);
					if (got6 !== want6) begin
						bad6 = bad6 + 1;
						stale_want6 = prev_sec6[7:0] ^ (i6 % 512);
						if (got6 === stale_want6) stale6 = stale6 + 1;
					end
				end
			end
			if (bad6)
				$display("          seam19 hold-off DEFEATED: %0d wrong bytes, %0d of them the slot's previous occupant",
				         bad6, stale6);
			// ANTI-ALIAS GUARD. The payload byte is sec[7:0] ^ (i % 512), so if
			// the ring slot's previous occupant and the sector being read share
			// a low byte, stale data is BYTE-IDENTICAL to correct data and this
			// bench silently proves nothing. That is not hypothetical: the first
			// draft of seam19 picked lba 3000/80000, both tags came out as 0x01,
			// and seam19 reported a clean read of data it had never fetched.
			ok("seam19e - premise: stale and fresh payloads are distinguishable",
			   (prev_sec6 % 256) != (((lba_s6 * 4) + 1) % 256));
			// Premise. If this fails, seam19 proves nothing about (c) -- and it
			// also means seam18's own premise has quietly stopped holding.
			ok("seam19 - premise: ignoring the hold-off DOES corrupt the read",
			   drq6 && (bad6 > 0) && (stale6 == bad6));
			// (c): the breach was caught and the command cannot claim success.
			ok("seam19b - the target latched the frontier violation",
			   dut.target[CD_DEV].target.frontier_violated === 1'b1);
			begin : s19req
				integer g9;
				g9 = 0;
				while (!dut.scsi_req && dut.scsi_bsy && g9 < 200000) begin
					@(posedge clk); g9 = g9 + 1;
				end
			end
			stat6 = 8'hff;
			if (dut.scsi_req && dut.scsi_bsy) recv_byte(stat6);
			ok("seam19c - a read served stale sectors reports CHECK CONDITION",
			   stat6 == 8'h02);
			// The encoding a driver sees from REQUEST SENSE. Key 0xB is shared
			// with the io-stall abort, so the ASC is what tells them apart:
			// 0x4b DATA PHASE ERROR here, the stalled opcode there.
			ok("seam19d - sense is ABORTED COMMAND / DATA PHASE ERROR (B/4b)",
			   (dut.target[CD_DEV].target.sense_key === 4'hb) &&
			   (dut.target[CD_DEV].target.sense_asc === 8'h4b));
			begin : fin_s6
				integer g10;
				g10 = 0;
				while (dut.scsi_bsy && g10 < 60000) begin @(posedge clk); g10 = g10 + 1; end
			end
			hps_data_mode = 1'b0;
			hps_force_delay = 0; hps_force_n = 0;
		end

		// ==================================================================
		// seam20: the WRITE-side hold-off -- the twin of seam18.
		//
		// seam18/seam19 cover reads. The write direction has its own hazard and
		// its own clause in io_busy (scsi.v): a WRITE uses a two-slot double
		// buffer, and while a flush is reading one half out, a blind pump that
		// has come back round to that same half will drop a byte into a slot
		// the HPS has not finished with. Same shape as the read defect --
		// REQ withdrawal is advisory, nothing refuses the ACK -- and the same
		// fix covers it, because bus_hold includes iow.
		//
		// It had NEVER been exercised. Instrumented coverage over the whole
		// bench read 307 read-side hold-offs and 0 write-side, and the 197-file
		// hardware disk->disk copy gave holds=0 too: the .vhd path simply never
		// lags. So this was a CPU-stall condition that had never run anywhere.
		//
		// Arithmetic: a 3-block WRITE, pumped at dma_write_byte's 4 clk/byte, so
		// 512 bytes = ~2048 clk. The flush is forced to 3000 clk. Block 0's
		// flush (slot 0) therefore is still in flight when the pump, having
		// filled slot 1, wraps back to slot 0 at data_cnt=1024 -- which is
		// exactly the io_busy condition data_cnt[9] == sd_buff_sel. 3000 is well
		// under this bench's IOWDOG_LOG(14) ~16k window, so the stall must be
		// RELEASED by the flush completing, not by an abort.
		// ==================================================================
		begin : seam20
			integer i7, g7;
			reg [31:0] dcnt7;
			reg [7:0] stat7, msg7;
			hps_data_mode = 1'b0;

			img_size = 32'd2048;
			img_mounted[0] = 1'b1;
			@(posedge clk); @(posedge clk);
			img_mounted[0] = 1'b0;
			repeat (50) @(posedge clk);

			saw_hold_wr = 1'b0;
			s11_abort = 0; s11_watch = 1;
			hps_disk_delay = 3000;

			select_target(8'h40);                 // disk at ID 6
			send_cmd_byte(8'h0A);                 // WRITE(6)
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h03);                 // 3 blocks = 1536 bytes
			send_cmd_byte(8'h00);
			reg_write(`W_ICR, 8'h00);
			reg_write(`W_TCR, 8'h00);             // data OUT
			reg_write(`W_MR,  8'h02);
			reg_write(`W_DMAS, 8'h00);            // Start DMA Send
			wait_raw_req;

			// BLIND: no re-poll of DRQ between bytes. dma_write_byte models the
			// 68000's DTACK wait states, so if the hold-off works the pump is
			// stalled here rather than overwriting the flushing slot.
			for (i7 = 0; i7 < 1536; i7 = i7 + 1)
				dma_write_byte(((i7 / 512) * 8'h5a) ^ i7[7:0]);

			// THE POINT OF THE TEST: the write-side clause actually fired.
			// Without this, seam20 passing would say nothing at all -- a pump
			// that never caught up with the flush looks identical to one the
			// interlock protected.
			ok("seam20 - premise: the WRITE-side hold-off ENGAGED", saw_hold_wr);

			// Sample data_cnt HERE, not after the handshake: it is cleared the
			// moment the phase leaves DATA/STATUS/MESSAGE (scsi.v), so reading
			// it once the bus is released only ever reports 0.
			// Settle first: the last byte's ACK has to fall and reach stb_adv
			// before data_cnt reflects it. Sampling immediately reads 1535.
			repeat (8) @(posedge clk);
			dcnt7 = dut.target[0].target.data_cnt;

			// And it RELEASED. A hold-off that engages but cannot be satisfied
			// is a hang; the flush completing is what must clear it, not the
			// io-stall watchdog (3000 clk is far under the ~16k window here).
			reg_write(`W_MR, 8'h00);
			g7 = 0;
			while (!dut.scsi_req && dut.scsi_bsy && g7 < 200000) begin
				@(posedge clk); g7 = g7 + 1;
			end
			stat7 = 8'hff; msg7 = 8'hff;
			if (dut.scsi_req && dut.scsi_bsy) recv_byte(stat7);
			g7 = 0;
			while (!dut.scsi_req && dut.scsi_bsy && g7 < 200000) begin
				@(posedge clk); g7 = g7 + 1;
			end
			if (dut.scsi_req && dut.scsi_bsy) recv_byte(msg7);
			s11_watch = 0;

			ok("seam20b - every byte was accepted, none dropped or refused",
			   dcnt7 == 32'd1536);
			ok("seam20c - the stalled WRITE still completes with GOOD status",
			   stat7 == 8'h00);
			ok("seam20d - released by the flush, NOT by a watchdog abort",
			   !s11_abort);
			begin : rel20
				integer g8;
				g8 = 0;
				while (dut.scsi_bsy && g8 < 200000) begin @(posedge clk); g8 = g8 + 1; end
			end
			ok("seam20e - bus released", !dut.scsi_bsy);
			hps_disk_delay = 0;
		end

		// --- seam21: BUSY ERROR must set when the target vanishes mid-DMA ----
		// The 2026-08-28 CD-at-boot hang, brought to the INITIATOR seam.
		//
		// tb_scsi_cdrom cd38 proves the TARGET behaves correctly here: it
		// aborts, releases BSY, and is reusable immediately afterwards. The
		// freeze was on this side. BSR bit 2 (BUSY ERROR) is the 5380's "your
		// target has vanished" exit ramp, and it was hardwired to zero -- so
		// the Plus ROM polled BSR=0x90 forever and the machine sat at a frozen
		// "?" with no volume mounted at all.
		begin : seam21
			reg [7:0] bsr21;
			integer   g21, n21;

			mount_cd(32'd729968);
			select_target(8'h08);            // CD at ID 3
			send_cmd_byte(8'h08);            // READ(6)
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h00);            // length 0 == 256 blocks == 512 KB
			send_cmd_byte(8'h00);
			reg_write(`W_ICR,   8'h00);
			reg_write(`W_TCR,   8'h01);      // data IN
			reg_write(`W_MR,    8'h02);      // DMA mode
			reg_write(`W_IDMAR, 8'h00);      // Start DMA Initiator Receive
			wait_raw_req;

			// Take a slice, then ABANDON -- exactly what the ROM does once it
			// has had the byte count it armed for.
			for (n21 = 0; n21 < 64; n21 = n21 + 1) dma_read_byte(bsr21);

			// Never handshake again. Wait for the target to give up on us.
			g21 = 0;
			while (dut.scsi_bsy && g21 < 400000) begin
				@(posedge clk); g21 = g21 + 1;
			end
			ok("seam21a - premise: the target really did release BSY",
			   !dut.scsi_bsy);

			reg_read(`R_BSR, bsr21);
			$display("       seam21: BSR = %h (berr=%b)", bsr21, bsr21[2]);
			ok("seam21 - BUSY ERROR set when the target vanished mid-DMA",
			   bsr21[2]);

			// And a driver clears it the way a real one does: read reg 7.
			reg_read(`R_RST, bsr21);
			reg_read(`R_BSR, bsr21);
			ok("seam21b - a reg-7 read clears BUSY ERROR", !bsr21[2]);

			reg_write(`W_MR, 8'h00);
		end

		$display("");
		$display("SEAM: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("NCR5380 SEAM GATE: PASS - host-side register path behaves");
		else            $display("NCR5380 SEAM GATE: FAIL");
		$finish;
	end

	// Raised from 20 ms for seam17's sweep: byte-at-a-time pseudo-DMA over
	// ~25 KB per iteration costs roughly 3 ms of sim time, and the sweep needs
	// enough iterations to have a chance at a rare window. Still a real
	// backstop -- a genuine wedge trips it long before this.
	initial begin
		#160_000_000;
		$display("FAIL: bench timeout -- initiator stuck (this is the wedge)");
		$display("NCR5380 SEAM GATE: FAIL");
		$finish;
	end

endmodule
