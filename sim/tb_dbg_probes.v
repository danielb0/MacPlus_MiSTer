// ---------------------------------------------------------------------------
// tb_dbg_probes.v -- proves the JTAG probe deck before anyone trusts a capture.
//
// The CD-ROM wedge hunt spent a day on one probe row that turned out to be
// unreadable: a free-running 4-bit DACK-read counter, never cleared, reported
// "no DACK reads" on a machine that had done thousands of them. The reading it
// suggested nearly falsified the correct hypothesis.
//
// So the rule from SCSI_UPGRADE_PLAN.md 5.6 -- instruments are proven before
// they are trusted -- now applies to the instrument itself. This bench drives
// rtl/dbg_probes.sv from a real ncr5380 + scsi target pair, replays the exact
// wedge sequence seam11 characterises, and checks the packed probe words that
// scripts/read_probes.tcl decodes, field by field.
//
// It is a HOST-BUS model as well: every access drives cpuAddr/_cpuAS/_cpuRW the
// way MacPlus.sv does (SCSI at 0x58xxxx, register in A6-A4, DACK on A9), so the
// address decode inside the deck is under test rather than assumed.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`define W_ODR   3'h0
`define W_ICR   3'h1
`define W_MR    3'h2
`define W_TCR   3'h3
`define W_IDMAR 3'h7
`define R_CSR   3'h4
`define R_BSR   3'h5
`define R_CDR   3'h0

// Stub for the Altera primitive: FPGA-only, so the bench supplies its own.
module altsource_probe (input [31:0] probe, output [0:0] source,
                        input source_clk, input source_ena);
	parameter instance_id = "";
	parameter probe_width = 32;
	parameter source_width = 1;
	parameter sld_auto_instance_index = "YES";
	assign source = 1'b0;
endmodule

module tb_dbg_probes;

	localparam DEVS   = 2;
	localparam CD_DEV = 1;

	reg clk = 0;
	reg reset = 1;
	always #15 clk = ~clk;

	// ---- host side of the 5380 -------------------------------------------
	reg        bus_cs = 0;
	reg  [2:0] bus_rs = 0;
	reg        ior = 0, iow = 0, dack = 0;
	reg  [7:0] wdata = 0;
	wire [7:0] rdata;
	wire       dreq;
	wire [11:0] scsi_dbg;

	reg  [DEVS-1:0] img_mounted = 0;
	reg      [31:0] img_size = 0;
	wire     [31:0] io_lba [DEVS];
	wire [DEVS-1:0] io_rd, io_wr;
	reg  [DEVS-1:0] io_ack = 0;
	reg       [7:0] sd_buff_addr = 0;
	reg      [15:0] sd_buff_dout = 0;
	wire     [15:0] sd_buff_din [DEVS];
	reg             sd_buff_wr = 0;

	ncr5380 #(.DEVS(DEVS), .CD_DEV(CD_DEV), .WDOG_LOG(11), .IOWDOG_LOG(14)) dut (
		.clk(clk), .reset(reset),
		.bus_cs(bus_cs), .bus_rs(bus_rs), .ior(ior), .iow(iow),
		.dack(dack), .dreq(dreq), .wdata(wdata), .rdata(rdata),
		.img_mounted(img_mounted), .img_size(img_size),
		.io_lba(io_lba), .io_rd(io_rd), .io_wr(io_wr), .io_ack(io_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.cd_enable(1'b1), .cd_dbg(3'd0), .cd_ms_mode(3'd0),
		.cd_vendor_dbg(4'd0), .cd_sense_mode(2'd0),
		.dbg_bus(scsi_dbg)
	);

	// ---- CPU bus, exactly as MacPlus.sv presents it -----------------------
	reg [23:0] cpuAddr = 24'h000000;
	reg        _cpuAS = 1, _cpuRW = 1;
	reg [15:0] cpuDataOut = 0;
	// addrDecoder.v: 0x58 0000-0x5F FFFF, and only while AS is asserted.
	wire selectSCSI = ~_cpuAS & (cpuAddr[23:20] == 4'h5) & cpuAddr[19];
	// dataController_top.sv puts the SCSI byte on D15-D8.
	wire [15:0] cpuDataIn = selectSCSI ? {rdata, 8'hEF} : 16'hFFFF;

	dbg_probes probes (
		.clk(clk),
		.cpuAddr(cpuAddr), .cpuFC(3'b001), ._cpuAS(_cpuAS), ._cpuRW(_cpuRW),
		.cpuDataOut(cpuDataOut), .cpuDataIn(cpuDataIn),
		.selectSCSI(selectSCSI),
		.cd_io_rd(io_rd[CD_DEV]), .cd_io_wr(io_wr[CD_DEV]),
		.cd_io_ack(io_ack[CD_DEV]), .cd_io_lba(io_lba[CD_DEV]),
		.d0_io_rd(io_rd[0]), .d0_io_ack(io_ack[0]),
		.scsi_dbg(scsi_dbg)
	);

	integer fails = 0, tests = 0;
	task ok(input [800:0] name, input cond);
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	// ---- one CPU bus cycle, driving BOTH the 5380 pins and the bus view ---
	task bus_cycle(input rw, input dk, input [2:0] rs, input [7:0] d,
	               output [7:0] got);
		begin
			@(negedge clk);
			cpuAddr    = {4'h5, 4'h8, 6'd0, dk, 2'b00, rs, 4'h0};  // A9=DACK, A6-A4=reg
			_cpuRW     = rw;
			cpuDataOut = {d, 8'h00};
			bus_rs = rs; dack = dk; wdata = d;
			@(negedge clk);
			_cpuAS = 0; bus_cs = 1; ior = rw; iow = ~rw;
			@(negedge clk);
			@(negedge clk);
			got = rdata;
			@(negedge clk);
			_cpuAS = 1; bus_cs = 0; ior = 0; iow = 0;
			@(negedge clk);
			@(negedge clk);
		end
	endtask

	reg [7:0] rv;
	task reg_wr_(input [2:0] rs, input [7:0] d); begin bus_cycle(1'b0, 1'b0, rs, d, rv); end endtask
	task reg_rd_(input [2:0] rs); begin bus_cycle(1'b1, 1'b0, rs, 8'h00, rv); end endtask
	task dack_rd_(output [7:0] b); begin bus_cycle(1'b1, 1'b1, 3'h0, 8'h00, b); end endtask

	task wait_raw_req;
		integer g;
		begin
			g = 0;
			while (!dut.scsi_req && g < 4000) begin @(posedge clk); g = g + 1; end
		end
	endtask

	task send_cmd_byte(input [7:0] b);
		integer g;
		begin
			wait_raw_req;
			reg_wr_(`W_ODR, b);
			reg_wr_(`W_ICR, 8'h11);               // A_DATA | A_ACK
			g = 0;
			while (dut.scsi_req && g < 2000) begin @(posedge clk); g = g + 1; end
			reg_wr_(`W_ICR, 8'h01);
			while (!dut.scsi_req && g < 6000) begin @(posedge clk); g = g + 1; end
		end
	endtask

	task select_cd;
		integer g;
		begin
			reg_wr_(`W_ODR, 8'h08);               // CD-ROM at ID 3
			reg_wr_(`W_ICR, 8'h05);               // A_DATA | A_SEL
			g = 0;
			while (!dut.scsi_bsy && g < 2000) begin @(posedge clk); g = g + 1; end
			reg_wr_(`W_ICR, 8'h01);
		end
	endtask

	// Field accessors: the SAME slicing scripts/read_probes.tcl performs.
	wire [31:0] pdma = probes.pdma_r;
	wire [31:0] pdm2 = probes.pdm2_r;
	wire  [7:0] f_dack_tot = pdma[31:24];
	wire  [3:0] f_dack_arm = pdma[23:20];
	wire  [3:0] f_arm_cnt  = pdma[19:16];
	wire  [3:0] f_wdog     = pdma[15:12];
	wire  [3:0] f_iowdog   = pdma[11:8];
	wire  [5:0] f_phases   = pdma[7:2];
	wire        f_req_stat = pdma[1];
	wire        f_dack_mis = pdm2[31];
	wire        f_drq_mis  = pdm2[30];
	wire        f_ack_stat = pdm2[29];
	wire        f_irq_seen = pdm2[28];
	wire [23:0] f_ring     = pdm2[23:0];

	reg [7:0] b1, b2;

	initial begin
		repeat (10) @(posedge clk);
		reset = 0;
		repeat (10) @(posedge clk);

		// ---- replay the wedge: a no-media READ, armed for a DATA IN --------
		select_cd;
		send_cmd_byte(8'h08);                     // READ(6) LBA 0, 1 block
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h00);
		send_cmd_byte(8'h01);
		send_cmd_byte(8'h00);
		reg_wr_(`W_ICR, 8'h00);
		reg_wr_(`W_TCR, 8'h01);                   // expect DATA IN
		reg_wr_(`W_MR,  8'h02);                   // MR.DMA_MODE
		reg_wr_(`W_IDMAR, 8'h00);                 // the arm the probes epoch on
		wait_raw_req;

		ok("probe - nothing counted as a DACK read before the arm", f_dack_tot == 0);
		ok("probe - the arm was seen", f_arm_cnt == 1);

		dack_rd_(b1);
		repeat (8) @(posedge clk);
		ok("probe - one DACK read counted since the arm", f_dack_arm == 1);
		dack_rd_(b2);
		repeat (20) @(posedge clk);

		// ---- the discriminating word --------------------------------------
		ok("probe - PDMA reports exactly the 2 DACK reads the mechanism predicts",
		   f_dack_arm == 2 && f_dack_tot == 2);
		ok("probe - PDMA reports no bus-watchdog fire",  f_wdog   == 0);
		ok("probe - PDMA reports no io-stall fire",      f_iowdog == 0);
		ok("probe - PDMA phase mask is CMD+STATUS+MESSAGE+IDLE, no DATA",
		   f_phases == 6'b110011);
		ok("probe - PDMA saw REQ while the target sat in STATUS", f_req_stat);
		ok("probe - PDM2 caught a DACK read during a phase mismatch", f_dack_mis);
		ok("probe - PDM2 caught DRQ asserted during a phase mismatch", f_drq_mis);
		ok("probe - PDM2 caught ACK pulsing in STATUS (the byte moved)", f_ack_stat);
		ok("probe - PDM2 reports the IRQ never latched", !f_irq_seen);
		ok("probe - PDM2 phase ring reads IDLE, MESSAGE, STATUS, CMD (newest first)",
		   f_ring[2:0] == 3'd0 && f_ring[5:3] == 3'd5 &&
		   f_ring[8:6] == 3'd4 && f_ring[11:9] == 3'd1);
		ok("probe - the transaction really did end (bench premise)", !dut.scsi_bsy);
		ok("probe - the two DACK reads returned STATUS then MESSAGE",
		   b1 == 8'h02 && b2 == 8'h00);

		// ---- the epoch behaviour the old counter lacked --------------------
		// A sticky bit that can never be cleared, or a counter that never
		// re-arms, reads the same on every capture and measures nothing.
		// Clear DMA mode first: dma_en survives a transaction, so a fresh
		// selection into COMMAND phase re-asserts the DRQ-during-mismatch bit
		// immediately and legitimately. That is the RTL being honest, not the
		// probe failing to clear -- but it makes for an ambiguous test, so the
		// epoch check starts from a disarmed 5380.
		reg_wr_(`W_MR, 8'h00);
		select_cd;
		repeat (4) @(posedge clk);
		ok("probe - selection clears the per-transaction stickies",
		   !f_dack_mis && !f_drq_mis && !f_ack_stat && f_wdog == 0 &&
		   f_phases == 6'b000010);   // only CMD_IN visited so far
		ok("probe - but the lifetime DACK total survives it", f_dack_tot == 2);

		reg_wr_(`W_MR,  8'h02);
		reg_wr_(`W_IDMAR, 8'h00);
		ok("probe - a fresh arm re-zeroes the per-arm DACK count", f_dack_arm == 0);
		dack_rd_(b1);
		repeat (8) @(posedge clk);
		ok("probe - and counts again from there", f_dack_arm == 1);
		ok("probe - while the lifetime total keeps climbing", f_dack_tot == 3);

		$display("");
		$display("PROBES: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("PROBE DECK GATE: PASS - the instrument measures what it claims");
		else            $display("PROBE DECK GATE: FAIL");
		$finish;
	end

	initial begin
		#20_000_000;
		$display("FAIL: bench timeout");
		$display("PROBE DECK GATE: FAIL");
		$finish;
	end

endmodule
