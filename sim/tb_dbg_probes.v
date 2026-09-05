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
	wire [15:0] scsi_dbg;

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
		.cd_enable(1'b1),
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
		.d0_io_rd(io_rd[0]), .d0_io_wr(io_wr[0]), .d0_io_ack(io_ack[0]),
		.d0_io_lba(io_lba[0]),
		// DEVS=2 with CD_DEV=1, so there is no second DISK in this bench; the
		// d1 counter uses the same edge-count idiom as d0 immediately above it.
		.d1_io_wr(1'b0),
		.scsi_dbg(scsi_dbg),
		.scsi_hold(dut.bus_hold),
		.scsi_breach(dut.frontier_evt),
		.dbg_dcd(dcd_stim)
	);

	integer fails = 0, tests = 0;
	// ---- DCD stimulus ------------------------------------------------------
	// rtl/dcd.v's telemetry word, driven synthetically. This bench proves the
	// DECK -- that PDCD/PDC2 count, latch and clear what they claim -- exactly
	// as the PHLD leg forces bus_hold rather than staging a late fill. The
	// other half, that rtl/dcd.v packs the word the way the deck unpacks it, is
	// asserted in sim/tb_dcd_status.v against a real exchange.
	reg [31:0] dcd_stim = 0;

	// The persistent fields. Pulses are cleared, so every level change starts
	// from a clean word and a stale pulse cannot leak into the next step.
	task dcd_lvl(input [2:0] st, input sel, input hshkn, input [2:0] rxhs,
	             input [2:0] txst, input [2:0] cst, input pres, input [7:0] op);
		begin
			@(negedge clk);
			dcd_stim         = 32'd0;
			dcd_stim[2:0]    = st;
			dcd_stim[3]      = sel;
			dcd_stim[4]      = hshkn;
			dcd_stim[7:5]    = rxhs;
			dcd_stim[10:8]   = txst;
			dcd_stim[18:16]  = cst;
			dcd_stim[19]     = pres;
			dcd_stim[27:20]  = op;
			@(posedge clk);
		end
	endtask

	// One clock of a pulse bit on top of whatever level is currently set.
	// Driven from negedge to negedge so it spans exactly one posedge -- the
	// same rule the frontier-breach force below follows, and for the same
	// reason.
	task dcd_pulse(input integer b);
		begin
			@(negedge clk); dcd_stim[b] = 1'b1;
			@(negedge clk); dcd_stim[b] = 1'b0;
		end
	endtask

	// The same, held across `n` posedges. rtl/dcd_link.v's newByteReady is
	// held from one cen tick to the next -- four clk -- and a counter that
	// takes it as a level rather than an edge is only caught by a pulse that
	// is actually that wide. A one-clock pulse passes both.
	task dcd_pulse_wide(input integer b, input integer n);
		begin
			@(negedge clk); dcd_stim[b] = 1'b1;
			repeat (n) @(negedge clk);
			dcd_stim[b] = 1'b0;
		end
	endtask

	// The deck registers its stickies on one clock and pdcd_r/pdc2_r on the
	// next, so a capture needs two edges to be true. Three, to be sure.
	task dcd_settle; begin repeat (3) @(posedge clk); end endtask

	// The bench stub ties every ISSP source low, so a clear has to be forced
	// on the net the deck actually reads. Factored out of the inline
	// sequence further down: the unanswered-command tests need a clean slate
	// several times over.
	task dcd_clear;
		begin
			force probes.dcd_clr_src = 1'b1;
			repeat (6) @(posedge clk);
			release probes.dcd_clr_src;
			dcd_settle;
		end
	endtask

	// A whole command arrival, as the deck sees one. rtl/dcd.v dispatches on
	// the SAME edge rxValid is asserted, so what separates an answered
	// command from a dropped one is cstate on the NEXT edge: non-zero means
	// it moved out of C_IDLE and took the command, zero means it did not.
	// cst_after is therefore the whole experiment, and it is driven here
	// rather than derived so the bench can present both outcomes.
	task dcd_cmd(input [7:0] op, input [2:0] cst_after);
		begin
			dcd_lvl(3'd1, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, op);
			@(negedge clk); dcd_stim[14] = 1'b1;   // rxValid, one clock
			@(negedge clk); dcd_stim[14] = 1'b0;
			dcd_stim[18:16] = cst_after;           // cstate as of the next edge
			dcd_settle;
		end
	endtask

	// The other way a command goes unanswered: it lands while the command
	// layer is still busy with the previous one, so C_IDLE never sees it at
	// all. Same silence on the wire, different bug.
	task dcd_cmd_busy(input [7:0] op, input [2:0] cst_now);
		begin
			dcd_lvl(3'd1, 1'b1, 1'b1, 3'd0, 3'd0, cst_now, 1'b1, op);
			@(negedge clk); dcd_stim[14] = 1'b1;
			@(negedge clk); dcd_stim[14] = 1'b0;
			dcd_settle;
		end
	endtask

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

	// Collect one byte through the REGISTER file (not the DACK window) and
	// handshake it. With the pmatch gate in place this is the only way to
	// finish a transaction the target is holding in STATUS/MESSAGE.
	task recv_reg_byte(output [7:0] b);
		integer g;
		begin
			g = 0;
			while (!dut.scsi_req && g < 4000) begin @(posedge clk); g = g + 1; end
			bus_cycle(1'b1, 1'b0, `R_CDR, 8'h00, b);
			reg_wr_(`W_ICR, 8'h10);               // A_ACK
			while (dut.scsi_req && g < 8000) begin @(posedge clk); g = g + 1; end
			reg_wr_(`W_ICR, 8'h00);
			while (!dut.scsi_req && dut.scsi_bsy && g < 12000) begin @(posedge clk); g = g + 1; end
		end
	endtask

	task select_disk;
		integer g;
		begin
			reg_wr_(`W_ODR, 8'h40);               // disk at ID 6
			reg_wr_(`W_ICR, 8'h05);               // A_DATA | A_SEL
			g = 0;
			while (!dut.scsi_bsy && g < 2000) begin @(posedge clk); g = g + 1; end
			reg_wr_(`W_ICR, 8'h01);
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
	wire  [7:0] f_dack_arm = pdma[23:16];
	wire  [1:0] f_arm_cnt  = pdma[15:14];
	wire  [2:0] f_wdog     = pdma[13:11];
	wire  [2:0] f_iowdog   = pdma[10:8];
	wire  [5:0] f_phases   = pdma[7:2];
	wire        f_req_stat = pdma[1];
	wire        f_dack_mis = pdm2[31];
	wire        f_drq_mis  = pdm2[30];
	wire        f_ack_stat = pdm2[29];
	wire        f_irq_seen = pdm2[28];
	wire [23:0] f_ring     = pdm2[23:0];
	wire [31:0] pdm3 = probes.pdm3_r;
	wire  [7:0] g_dack_wr  = pdm3[31:24];
	wire  [3:0] g_tcr_arm  = pdm3[23:20];
	wire  [3:0] g_tcr_now  = pdm3[19:16];
	wire  [2:0] g_ph_arm   = pdm3[15:13];
	wire        g_pm_arm   = pdm3[12];
	wire  [2:0] g_ph_1st   = pdm3[11:9];
	wire        g_seen_1st = pdm3[8];
	wire        g_nondata  = pdm3[7];

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
		// The RTL now gates the DMA handshake on phase match, so this replay
		// measures a target that CHECKed and is still asking. The probe deck
		// has to report exactly that -- these are assertions about the
		// INSTRUMENT, and each one is a field scripts/read_probes.tcl prints.
		ok("probe - PDMA counts both DACK reads even though neither ACKed",
		   f_dack_arm == 2 && f_dack_tot == 2);
		ok("probe - PDMA reports no bus-watchdog fire",  f_wdog   == 0);
		ok("probe - PDMA reports no io-stall fire",      f_iowdog == 0);
		ok("probe - PDMA phase mask is CMD+STATUS, and no DATA phase",
		   f_phases == 6'b010010);
		ok("probe - PDMA saw REQ while the target sat in STATUS", f_req_stat);
		ok("probe - PDM2 flags the DACK read taken during a mismatch", f_dack_mis);
		ok("probe - PDM2 flags REQ+DMA meeting a mismatch", f_drq_mis);
		ok("probe - PDM2 reports NO ACK in STATUS -- the gate is holding",
		   !f_ack_stat);
		ok("probe - PDM2 reports the IRQ never latched (known gap, edge form)",
		   !f_irq_seen);
		ok("probe - PDM2 phase ring reads STATUS, CMD (newest first)",
		   f_ring[2:0] == 3'd4 && f_ring[5:3] == 3'd1);
		ok("probe - the target is still holding the bus, still asking",
		   dut.scsi_bsy && dut.scsi_req);
		ok("probe - both DACK reads returned the STATUS byte, unconsumed",
		   b1 == 8'h02 && b2 == 8'h02);

		// Finish it the way the driver now has to: the register path.
		reg_wr_(`W_MR, 8'h00);
		recv_reg_byte(b1);
		recv_reg_byte(b2);
		begin : rel
			integer g;
			g = 0;
			while (dut.scsi_bsy && g < 4000) begin @(posedge clk); g = g + 1; end
		end
		ok("probe - the register path still completes it (status then message)",
		   !dut.scsi_bsy && b1 == 8'h02 && b2 == 8'h00);

		// ---- PDM3: the arm-to-data-phase window ----------------------------
		// Two attempts at gating the DMA handshake both passed every bench and
		// both hung the machine. What no bench modelled is WHEN the driver
		// starts pumping relative to the target reaching its data phase. These
		// fields are that measurement, and they must be read BEFORE any later
		// arm in this bench overwrites them.
		ok("probe - PDM3 records the phase the driver armed in (STATUS)",
		   g_ph_arm == 3'd4);
		ok("probe - PDM3 records TCR at the arm, and that it did not match",
		   g_tcr_arm == 4'h1 && !g_pm_arm);
		ok("probe - PDM3 records the phase of the FIRST DACK access",
		   g_seen_1st && g_ph_1st == 3'd4);
		ok("probe - PDM3 flags that a DACK landed outside a data phase",
		   g_nondata);
		ok("probe - PDM3 counted no DACK writes on a read transfer",
		   g_dack_wr == 0);
		ok("probe - PDM3 reports TCR live as well", g_tcr_now == 4'h1);

		// ---- the epoch behaviour the old counter lacked --------------------
		// A sticky bit that can never be cleared, or a counter that never
		// re-arms, reads the same on every capture and measures nothing.
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

		// ---- the artifact that misread the 2026-08-22 hardware capture -----
		// dbg_bus bit 0 must be the TARGET's BSY. scsi_bsy also carries the
		// initiator's own BSY (ICR bit 3) and MR_ARB, and during arbitration
		// both are high while NO target drives MSG/CD/IO -- which decodes as
		// phase 3, DATA-IN. On hardware that painted a DATA phase into the
		// mask of a transaction that never had one, and the verdict line went
		// "inconclusive" on a capture that was actually conclusive.
		begin : arb_artifact
			integer g;
			reg [5:0] before_mask;
			// Park the bus idle and start a fresh epoch.
			select_cd;
			reg_wr_(`W_ICR, 8'h00);
			recv_reg_byte(b1);                    // let it CHECK out cleanly
			g = 0;
			while (dut.scsi_bsy && g < 8000) begin
				if (dut.scsi_req) recv_reg_byte(b2);
				@(posedge clk); g = g + 1;
			end
			// Now assert the INITIATOR's BSY and arbitration, with no target.
			reg_wr_(`W_MR,  8'h01);               // MR_ARB
			reg_wr_(`W_ICR, 8'h08);               // ICR_A_BSY
			before_mask = f_phases;
			repeat (40) @(posedge clk);
			ok("probe - initiator BSY/arbitration does not fake a DATA phase",
			   (f_phases[3:2] == 2'b00) && (f_phases == before_mask));
			ok("probe - and the 5380 really is reporting BSY at the time",
			   dut.scsi_bsy);
			reg_wr_(`W_ICR, 8'h00);
			reg_wr_(`W_MR,  8'h00);
		end

		// ---- the instrument that names its own bitstream --------------------
		// PBLD exists because two different RTL fixes once produced byte-for-byte
		// identical hardware captures, and nothing on the board could say whether
		// the second build had actually been loaded. That question is still open,
		// so the probe that answers it is itself under test: rtl/build_tag.v must
		// be in the compile set (this bench will not elaborate without it) and its
		// value must reach the PBLD probe unmodified and non-zero.
		ok("probe - PBLD carries the build tag to the probe unmodified",
		   probes.cp_pbld.probe === probes.build_tag_w);
		ok("probe - and the build tag is stamped, not left at zero",
		   probes.build_tag_w !== 32'h0 && probes.build_tag_w !== 32'hxxxxxxxx);

		// ---- PIO3/PIO4: the write side of the instrument --------------------
		// The 2026-08-22 wedge was an io-stall on a DISK WRITE, and this deck
		// could not see it: no disk write counter and no disk LBA existed
		// anywhere in it. These probes close that, so they are under test
		// before anyone reads a capture from them.
		//
		// Driven by a real stalled flush: io_ack[0] is never asserted in this
		// bench, so the WRITE's tail flush is issued and never answered --
		// exactly the shape the probes exist to name.
		begin : wrprobe
			integer n;
			img_size = 32'd8192;      // LBA 0x001234 must be IN range
			img_mounted[0] = 1'b1;
			@(posedge clk); @(posedge clk);
			img_mounted[0] = 1'b0;
			repeat (50) @(posedge clk);

			// Wait for a free bus: the tests above leave the CD target holding
			// BSY, and bus_busy blocks selection of any other target.
			begin : idle
				integer g;
				g = 0;
				while (dut.scsi_bsy && g < 40000) begin @(posedge clk); g = g + 1; end
			end

			select_disk;
			send_cmd_byte(8'h0A);                 // WRITE(6)
			send_cmd_byte(8'h00);
			send_cmd_byte(8'h12);                 // LBA 0x001234
			send_cmd_byte(8'h34);
			send_cmd_byte(8'h01);                 // 1 block
			send_cmd_byte(8'h00);
			reg_wr_(`W_ICR, 8'h00);

			for (n = 0; n < 512; n = n + 1) send_cmd_byte(8'h5A);
			repeat (40) @(posedge clk);
		end

		ok("probe - PIO4 counted the disk write flush",
		   probes.pio4_r[31:24] == 8'd1);
		ok("probe - PIO4 shows no ack for it, which is the stall",
		   probes.pio4_r[23:16] == 8'd0);
		ok("probe - PIO4 shows the live disk write request asserted",
		   probes.pio4_r[2] === 1'b1 && probes.pio4_r[1] === 1'b0);
		ok("probe - PIO3 names the LBA the stalled flush was writing",
		   probes.pio3_r[23:0] == 24'h001234);
		ok("probe - PIO3 carries the write-stall age in its top byte",
		   probes.pio3_r[31:24] === probes.wr_stuck);

		// ---- PHLD: the deck must be able to say the hold-off ENGAGED --------
		// Without this field a hardware capture cannot tell "the interlock
		// held" from "the HPS never lagged this run", and a clean CD->disk copy
		// proves only the second. Drive bus_hold directly rather than staging a
		// whole late-fill scenario: what is under test here is the DECK's
		// counting, not the RTL's hold-off (seam18/seam19 own that).
		force dut.bus_hold = 1'b1;
		repeat (25) @(posedge clk);
		release dut.bus_hold;
		repeat (4) @(posedge clk);
		force dut.bus_hold = 1'b1;
		repeat (8) @(posedge clk);
		release dut.bus_hold;
		repeat (8) @(posedge clk);
		ok("probe - PHLD counted BOTH hold-off engagements, not cycles",
		   probes.phld_r[31:20] == 12'd2);
		ok("probe - PHLD reports the LONGER of the two stalls",
		   probes.phld_r[19:4] >= 16'd24 && probes.phld_r[19:4] <= 16'd26);
		// Must be zero: nothing in this bench breaches the frontier, and on a
		// healthy build nothing on hardware should either.
		ok("probe - PHLD shows no frontier breach",
		   probes.phld_r[3:0] == 4'd0);
		// And the deck must be able to SEE a breach when there is one, or a
		// permanent zero would be indistinguishable from a dead counter.
		// negedge boundaries so the force spans exactly one posedge: applying it
		// in the same delta as the sampling edge is the race this tree has been
		// bitten by before.
		@(negedge clk); force dut.frontier_evt = 1'b1;
		@(negedge clk); release dut.frontier_evt;
		repeat (4) @(posedge clk);
		ok("probe - PHLD counts a frontier breach when one occurs",
		   probes.phld_r[3:0] == 4'd1);
		// The disk LBA is the field that did not exist at all before; PIOS
		// carries the CD's LBA and would have read 0 here, which is precisely
		// how a stalled disk write used to look identical to no disk IO.
		ok("probe - and that LBA is NOT the CD probe's, which stayed put",
		   probes.pios_r[23:0] != 24'h001234);


		// ---- PDCD / PDC2: the DCD (HD20) link ------------------------------
		// The deck could not see the DCD at all, so the HD20 bring-up had only
		// the instruction-fetch sampler, which reaches code the CPU is ALREADY
		// wedged in and nothing else. What that could never answer is whether
		// identification happens at all: a FAILED identification is
		// microseconds of work and invisible at 2.5 samples/sec.

		// Nothing mounted. Every other field must stay still, or "no DCD" and
		// "a DCD that did nothing" read alike -- the same trap the absent-probe
		// handling in read_probes.tcl exists to close.
		dcd_lvl(3'd2, 1'b0, 1'b1, 3'd0, 3'd0, 3'd0, 1'b0, 8'h00); dcd_settle;
		ok("probe - PDCD reports no DCD present, and records no state for one",
		   probes.pdcd_r[5] == 1'b0 && probes.pdcd_r[31:24] == 8'h00);

		// Mounted but not selected -- the external port is enabled per access,
		// so this is the ordinary resting state of a machine with an HD20
		// attached. It is also the ONLY step that tells `present` and
		// `selected` apart: everywhere else in this leg they move together, so
		// without it the two bits could be swapped and every other assertion
		// would still pass.
		dcd_lvl(3'd2, 1'b0, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		ok("probe - PDCD tells `present` from `selected`",
		   probes.pdcd_r[5] == 1'b1 && probes.pdcd_r[4] == 1'b0);
		ok("probe - and a mounted-but-idle drive still records no phase state",
		   probes.pdcd_r[31:24] == 8'h00);

		// A whole healthy Status exchange, as rtl/dcd.v drives the word.
		// Identification first: the ROM walks the ID states 7, 6, 5.
		dcd_lvl(3'd7, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		dcd_lvl(3'd6, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		dcd_lvl(3'd5, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		// Then the command handshake, 2 -> 3 -> 1, with /HSHK pulled low at 3.
		dcd_lvl(3'd2, 1'b1, 1'b1, 3'd1, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		dcd_lvl(3'd3, 1'b1, 1'b0, 3'd2, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd3, 3'd0, 3'd0, 1'b1, 8'h03); dcd_settle;
		repeat (11) dcd_pulse(12);          // the command frame, 11 bytes
		dcd_pulse(14);                      // rxValid: it checksummed
		dcd_lvl(3'd3, 1'b1, 1'b1, 3'd4, 3'd0, 3'd0, 1'b1, 8'h03); dcd_settle;
		dcd_lvl(3'd2, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h03); dcd_settle;
		// The reply: ask for the bus, sync, data, done.
		dcd_lvl(3'd2, 1'b1, 1'b0, 3'd0, 3'd1, 3'd1, 1'b1, 8'h03); dcd_settle;
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd0, 3'd2, 3'd1, 1'b1, 8'h03); dcd_settle;
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd0, 3'd3, 3'd1, 1'b1, 8'h03); dcd_settle;
		repeat (40) dcd_pulse(13);
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd0, 3'd5, 3'd1, 1'b1, 8'h03); dcd_settle;
		dcd_lvl(3'd2, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h03); dcd_settle;

		// THE question the sampler could not reach. State 5 is the phase-line
		// value a Sony answers 1 to and a DCD answers 0 to, so the Mac driving
		// it is identification happening, stated as one bit.
		ok("probe - PDCD saw the Mac drive state 5, the DCD discriminator",
		   probes.pdcd_r[29] == 1'b1);
		ok("probe - PDCD recorded every phase state the Mac drove, and no other",
		   probes.pdcd_r[31:24] == 8'hEE);
		ok("probe - PDCD names the opcode of the last command decoded",
		   probes.pdcd_r[23:16] == 8'h03);
		ok("probe - PDCD counted exactly one command",
		   probes.pdcd_r[3:2] == 2'd1);
		ok("probe - PDCD shows /HSHK released and both FSMs idle afterwards",
		   probes.pdcd_r[6] == 1'b1 && probes.pdcd_r[15:13] == 3'd0
		   && probes.pdcd_r[12:10] == 3'd0);
		ok("probe - PDCD reports the drive present and selected",
		   probes.pdcd_r[5] == 1'b1 && probes.pdcd_r[4] == 1'b1);
		ok("probe - PDCD flags neither a bad frame nor an abandoned reply",
		   probes.pdcd_r[1:0] == 2'd0);
		ok("probe - PDC2 counted the bytes the drive sent",
		   probes.pdc2_r[31:24] == 8'd40);
		// What the real dcd_link.v drives: newByteReady held for four clk.
		// The deck once counted that as a level and reported four bytes per
		// byte, and the one-clock pulses above could not tell.
		dcd_pulse_wide(13, 4); dcd_settle;
		ok("probe - PDC2 counts a four-clock newByteReady as ONE byte, not four",
		   probes.pdc2_r[31:24] == 8'd41);
		ok("probe - PDC2 counted the bytes the Mac sent",
		   probes.pdc2_r[23:18] == 6'd11);
		ok("probe - PDC2 says the reply ran all the way to TX_END",
		   probes.pdc2_r[17:15] == 3'd5);
		ok("probe - PDC2 says the receive handshake completed",
		   probes.pdc2_r[14:12] == 3'd4);

		// rxBuf fills byte by byte as a frame arrives, so between frames the
		// opcode field carries part of a command that has not been checksummed
		// yet. A deck that latched it continuously would report one of those as
		// "the last command" -- a plausible number that is pure fiction, which
		// is the exact failure this deck exists to avoid. Caught by mutation:
		// every earlier step changed the opcode and pulsed rxValid together.
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd3, 3'd0, 3'd0, 1'b1, 8'hC7); dcd_settle;
		ok("probe - PDCD keeps the last DECODED opcode, not a part-received one",
		   probes.pdcd_r[23:16] == 8'h03);

		// The clear. Sticky state that cannot be zeroed is readable once per
		// power cycle, which is useless for a fault that has to be provoked
		// from HD Diag. The bench stub ties every source low, so force the net
		// the deck reads rather than the stub's output.
		dcd_lvl(3'd2, 1'b0, 1'b1, 3'd0, 3'd0, 3'd0, 1'b0, 8'h00); dcd_settle;
		force probes.dcd_clr_src = 1'b1;
		repeat (6) @(posedge clk);
		release probes.dcd_clr_src;
		dcd_settle;
		ok("probe - PDCD's JTAG clear empties every sticky field",
		   probes.pdcd_r[31:16] == 16'd0 && probes.pdcd_r[3:0] == 4'd0);
		ok("probe - and PDC2 clears with it",
		   probes.pdc2_r == 32'd0);

		// The failure this probe was built for: HD Diag error $28, the drive
		// asserting /HSHK and never releasing it. A reply asks for the bus and
		// the Mac never comes round to state 1.
		dcd_lvl(3'd2, 1'b1, 1'b1, 3'd0, 3'd0, 3'd1, 1'b1, 8'h00); dcd_settle;
		dcd_lvl(3'd2, 1'b1, 1'b0, 3'd0, 3'd1, 3'd1, 1'b1, 8'h00); dcd_settle;
		repeat (20) @(posedge clk);
		ok("probe - PDCD names the $28 wedge: /HSHK low, reply parked in TX_WAIT",
		   probes.pdcd_r[6] == 1'b0 && probes.pdcd_r[12:10] == 3'd1);
		ok("probe - PDC2 says that reply never got past asking for the bus",
		   probes.pdc2_r[17:15] == 3'd1 && probes.pdc2_r[31:24] == 8'd0);

		// abd857c's escape out of TX_WAIT is the one path in the link layer
		// that has never run on hardware, so it gets its own bit rather than
		// being inferred from the high-water mark.
		dcd_lvl(3'd7, 1'b1, 1'b1, 3'd0, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		ok("probe - PDCD flags a reply the drive abandoned in TX_WAIT",
		   probes.pdcd_r[0] == 1'b1);

		// A frame that arrives and fails its checksum is a different fault
		// from a frame that never arrives, and must not be counted as one.
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd3, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		dcd_pulse(15);
		dcd_settle;
		ok("probe - PDCD flags a frame that failed its checksum",
		   probes.pdcd_r[1] == 1'b1);
		ok("probe - and does NOT count that frame as a decoded command",
		   probes.pdcd_r[3:2] == 2'd0);

		// The deck's founding lesson, applied to its newest counter: a wrapping
		// counter that reads 6 is indistinguishable from a real 6.
		force probes.dcd_clr_src = 1'b1;
		repeat (6) @(posedge clk);
		release probes.dcd_clr_src;
		dcd_lvl(3'd1, 1'b1, 1'b0, 3'd3, 3'd0, 3'd0, 1'b1, 8'h00); dcd_settle;
		repeat (70) dcd_pulse(12);
		repeat (300) dcd_pulse(13);
		dcd_settle;
		ok("probe - PDC2's inbound byte counter SATURATES rather than wrapping to 6",
		   probes.pdc2_r[23:18] == 6'd63);
		// The outbound one is eight bits and a Status reply is 392 bytes, so it
		// saturates in ordinary use -- which makes wrapping there MORE likely to
		// mislead than on the inbound side, not less.
		ok("probe - and the outbound one saturates too, rather than wrapping to 44",
		   probes.pdc2_r[31:24] == 8'd255);

		// ---- the unanswered-command field ------------------------------
		// rtl/dcd.v answers $00/$01/$02/$03 (and $41/$42) and DROPS anything
		// else with no reply at all. The Mac cannot tell that from a dead
		// drive: it times out and resets us, which is what sets PDCD's
		// abandoned bit -- so that bit is downstream of this one and reading
		// it first sent one investigation to the wrong layer entirely.
		// dcd_last_op cannot serve here because it keeps the NEWEST opcode
		// and every real capture ends with the $00 of an ordinary read.
		dcd_clear;
		dcd_cmd(8'h03, 3'd4);     // Status, dispatched to C_SEND
		ok("probe - an answered command leaves the unanswered fields clear",
		   probes.pdc2_r[3:2] == 2'd0);

		dcd_cmd(8'h19, 3'd0);     // one the Plus ROM sends and dcd.v drops
		ok("probe - an unanswered command is counted",
		   probes.pdc2_r[3:2] == 2'd1);
		ok("probe - and its OPCODE is recorded, not just the fact of it",
		   probes.pdc2_r[11:4] == 8'h19);
		ok("probe - and the reason is 'not dispatched from C_IDLE'",
		   probes.pdc2_r[1:0] == 2'd1);

		// THE FIRST OPCODE IS KEPT, NOT THE NEWEST. A driver that gives up on
		// a command retries and then resets, so the newest would name the
		// recovery path rather than what started it.
		dcd_cmd(8'h1A, 3'd0);
		ok("probe - a second unanswered command does NOT overwrite the first",
		   probes.pdc2_r[11:4] == 8'h19);
		ok("probe - but it is counted",
		   probes.pdc2_r[3:2] == 2'd2);

		dcd_cmd(8'h1A, 3'd0);
		dcd_cmd(8'h1A, 3'd0);
		ok("probe - the unanswered counter saturates rather than wrapping",
		   probes.pdc2_r[3:2] == 2'd3);

		// The other reason, and it must not be confused with the first: the
		// opcode is one we implement, but it arrived while the layer was busy.
		dcd_clear;
		dcd_cmd_busy(8'h00, 3'd3);
		ok("probe - a command that arrived BUSY is recorded with reason 2",
		   probes.pdc2_r[1:0] == 2'd2 && probes.pdc2_r[11:4] == 8'h00);

		dcd_clear;
		ok("probe - the JTAG clear empties the unanswered fields too",
		   probes.pdc2_r[11:0] == 12'd0);


		$display("");
		$display("PROBES: %0d of %0d failing", fails, tests);
		if (fails == 0) $display("PROBE DECK GATE: PASS - the instrument measures what it claims");
		else            $display("PROBE DECK GATE: FAIL");
		$finish;
	end

	initial begin
		// Raised from 20ms-equivalent when the PIO3/PIO4 legs were added: those
		// pump a full 512-byte block through the register path, which the earlier
		// budget had no room for.
		#60_000_000;
		$display("FAIL: bench timeout");
		$display("PROBE DECK GATE: FAIL");
		$finish;
	end

endmodule
