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
	reg       [2:0] cd_dbg = 0;      // 0 = all commands enabled
	reg       [2:0] cd_ms_mode = 0;  // 0 = full MODE SENSE response

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
		.cd_enable(cd_enable), .cd_dbg(cd_dbg), .cd_ms_mode(cd_ms_mode), .cd_vendor_dbg(4'd0), .cd_sense_mode(2'd0)
	);

	// ---- minimal HPS sector server ---------------------------------------
	// Answers the CD slot's io_rd with an ack after hps_delay clocks. Setting
	// hps_delay long enough for the target's bus watchdog to fire first is what
	// reproduces a LATE ack -- one that arrives after the target has left the
	// bus and dropped BSY.
	integer hps_delay = 20;
	reg     hps_enable = 1'b1;
	integer hps_acks = 0;
	reg     saw_io_rd = 0;

	// Disk slot 0 gets its own trivial always-ack server: seam12 needs a WRITE
	// target, and the CD is read-only.
	always @(posedge clk) begin : hps_disk
		if (reset) io_ack[0] <= 1'b0;
		else       io_ack[0] <= (io_rd[0] | io_wr[0]) & ~io_ack[0];
	end

	always @(posedge clk) begin : hps
		integer wait_n;
		if (reset) begin
			io_ack[CD_DEV] <= 0;
			wait_n   = 0;
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
	task dma_read_byte(output [7:0] b);
		begin
			@(negedge clk); bus_cs = 1; dack = 1; ior = 1;
			@(negedge clk);
			b = rdata;
			@(negedge clk); ior = 0; dack = 0; bus_cs = 0;
			@(negedge clk);
		end
	endtask

	// Write one byte through the DACK window (the pseudo-DMA send path).
	task dma_write_byte(input [7:0] b);
		begin
			@(negedge clk); bus_cs = 1; dack = 1; wdata = b; iow = 1;
			@(negedge clk);
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
		ok("seam11 - DEFECT: DRQ asserts anyway (a real 5380 inhibits it)",
		   bsr1[`BSR_DRQ] && dreq);
		ok("seam11 - DEFECT: the completion IRQ never latched (mismatch predates the arm)",
		   !bsr1[`BSR_IRQ]);

		// The blind pump loop's first read.
		dma_read_byte(dma_b);
		repeat (8) @(posedge clk);
		s11_phase_after1 = dut.target[CD_DEV].target.phase;
		ok("seam11 - DEFECT: a DACK read returns the STATUS byte as sector data",
		   dma_b == 8'h02);              // CHECK CONDITION
		ok("seam11 - DEFECT: and ACKs it -- the target advances to MESSAGE",
		   s11_phase_after1 == 3'd5);

		// The second read.
		dma_read_byte(dma_b);
		begin : s11_free
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 200) begin @(posedge clk); g = g + 1; end
			s11_free_clks = g;
		end
		ok("seam11 - DEFECT: a second DACK read eats COMMAND COMPLETE",
		   dma_b == 8'h00);
		ok("seam11 - DEFECT: two blind reads end the whole transaction",
		   !dut.scsi_bsy);
		s11_watch = 0;

		ok("seam11 - no DATA phase was ever entered", !s11_data_phase);
		ok("seam11 - ACK was asserted while the target was in STATUS",
		   s11_ack_status);
		ok("seam11 - no watchdog was involved", !s11_abort);
		reg_read(`R_CSR, csr1);
		ok("seam11 - CSR reads back 0x00 on the free bus, as the probes saw",
		   csr1 == 8'h00);

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
		ok("seam9 - the stalled request is cleared, not left asserted",
		   !io_rd[CD_DEV]);

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

		$display("");
		$display("SEAM: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("NCR5380 SEAM GATE: PASS - host-side register path behaves");
		else            $display("NCR5380 SEAM GATE: FAIL");
		$finish;
	end

	initial begin
		#20_000_000;
		$display("FAIL: bench timeout -- initiator stuck (this is the wedge)");
		$display("NCR5380 SEAM GATE: FAIL");
		$finish;
	end

endmodule
