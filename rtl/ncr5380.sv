/* verilator lint_off UNUSED */

/* based on minimigmac by Benjamin Herrenschmidt */

/* Read registers */
`define RREG_CDR        3'h0    /* Current SCSI data */
`define RREG_ICR        3'h1    /* Initiator Command */
`define RREG_MR         3'h2    /* Mode register */
`define RREG_TCR        3'h3    /* Target Command */
`define RREG_CSR        3'h4    /* SCSI bus status */
`define RREG_BSR        3'h5    /* Bus and status */
`define RREG_IDR        3'h6    /* Input data */
`define RREG_RST        3'h7    /* Reset */

/* Write registers */
`define WREG_ODR        3'h0    /* Output data */
`define WREG_ICR        3'h1    /* Initiator Command */
`define WREG_MR         3'h2    /* Mode register */
`define WREG_TCR        3'h3    /* Target Command */
`define WREG_SER        3'h4    /* Select Enable */
`define WREG_DMAS       3'h5    /* Start DMA Send */
`define WREG_DMATR      3'h6    /* Start DMA Target receive */
`define WREG_IDMAR      3'h7    /* Start DMA Initiator receive */

/* MR bit numbers */
`define MR_DMA_MODE     1
`define MR_ARB          0

/* ICR bit numbers */
`define ICR_A_RST       7
`define ICR_TEST_MODE   6
`define ICR_DIFF_ENBL   5
`define ICR_A_ACK       4
`define ICR_A_BSY       3
`define ICR_A_SEL       2
`define ICR_A_ATN       1
`define ICR_A_DATA      0

/* TCR bit numbers */
`define TCR_A_REQ       3
`define TCR_A_MSG       2
`define TCR_A_CD        1
`define TCR_A_IO        0

module ncr5380
(
	input    		clk,
	input 	     	reset,

	/* Bus interface. 3-bit address, to be wired
	 * appropriately upstream (to A4..A6) plus one
	 * more bit (A9) wired as dack.
	 */
	input         bus_cs,
	input   [2:0] bus_rs,
	input         ior,
	input         iow,
	input         dack,
	output        dreq,
	input   [7:0] wdata,
	output  [7:0] rdata,

	// connections to io controller
	input  [DEVS-1:0] img_mounted,
	input      [31:0] img_size,
	
	output reg [31:0] io_lba[DEVS],
	output [DEVS-1:0] io_rd,
	output [DEVS-1:0] io_wr,
	input  [DEVS-1:0] io_ack,

	input        [7:0] sd_buff_addr,
	input       [15:0] sd_buff_dout,
	output      [15:0] sd_buff_din[DEVS],
	input              sd_buff_wr,

	// CD-ROM drive present on the bus (see scsi.v's cd_enable). Only meaningful
	// when CD_DEV is in range; low makes the bus identical to a disks-only build.
	input              cd_enable,
	input        [2:0] cd_dbg,
	input        [2:0] cd_ms_mode,
	input        [3:0] cd_vendor_dbg
	,input       [1:0] cd_sense_mode

	// Debug tap for the JTAG probe deck (rtl/dbg_probes.sv). Raw state only --
	// every counter, sticky bit and epoch lives in the probe deck, so this bus
	// stays one flat vector of things that already exist and the debug logic
	// stays in one file. Pruned entirely when the deck is not instantiated.
	,output     [11:0] dbg_bus
);
	parameter DEVS = 2;
	// Index of the CD-ROM target within the DEVS arrays, or DEVS for "none".
	// The disks keep indices 0..n at IDs 6,5,... exactly as before; the CD takes
	// the last index at ID 3.
	parameter CD_DEV = DEVS;
	// Target bus-watchdog period, forwarded to scsi.v. Benches shorten it so a
	// timeout is reachable in simulation; synthesis keeps the ~129 ms default.
	parameter WDOG_LOG = 22;
	// Stall timeout for an HPS fetch that never completes; see scsi.v.
	parameter IOWDOG_LOG = 24;

	// DRQ is inhibited outside a data phase. See bsr_dmarq for why this is
	// keyed on the BUS phase rather than on TCR.
	assign dreq = scsi_req & dma_en & bus_data_phase;

	reg  [7:0] mr;        /* Mode Register */
	reg  [7:0] icr;       /* Initiator Command Register */
	reg  [3:0] tcr;       /* Target Command Register */
	wire [7:0] csr;       /* SCSI bus status register */

	/* Data in and out latches and associated
	* control logic for DMA
	*/
	reg  [7:0] din;
	reg  [7:0] dout;
	reg        dma_en;

	/* --- Main host-side interface --- */

	/* Register & DMA accesses decodes */
	reg dma_wr;
	reg reg_wr;
	reg dma_ack;

	wire i_dma_rd = bus_cs &  dack & ior;
	wire i_dma_wr = bus_cs &  dack & iow;
	wire i_reg_wr = bus_cs & ~dack & iow;

	always @(posedge clk) begin
		reg old_dma_rd, old_dma_wr, old_reg_wr;

		old_dma_rd <= i_dma_rd;
		old_dma_wr <= i_dma_wr;
		old_reg_wr <= i_reg_wr;

		dma_wr <= 0;
		dma_ack <= 0;
		reg_wr <= 0;

		if(~old_dma_wr & i_dma_wr) dma_wr <= 1;
		if(~old_reg_wr & i_reg_wr) reg_wr <= 1;
		// A DACK access only ACKs when the bus phase matches TCR. Without this
		// term a blind pump loop reading the DACK window during a mismatch ACKs
		// whatever the target is offering -- after a CHECK CONDITION that is the
		// STATUS byte, then COMMAND COMPLETE, and the transaction ends while the
		// driver thinks it is collecting sector data (seam11, and confirmed on
		// hardware 2026-08-22: ACK-in-STATUS with no watchdog fire).
		if((old_dma_wr & ~i_dma_wr) | (old_dma_rd & ~i_dma_rd)) dma_ack <= dma_en & bus_data_phase;
	end

	/* System bus reads */
	assign rdata = dack                ? cur_data         :
	               bus_rs == `RREG_CDR ? cur_data         :
	               bus_rs == `RREG_ICR ? icr_read         :
	               bus_rs == `RREG_MR  ? mr               :
	               bus_rs == `RREG_TCR ? { 4'h0, tcr }    :
	               bus_rs == `RREG_CSR ? csr              :
	               bus_rs == `RREG_BSR ? bsr              :
	               bus_rs == `RREG_IDR ? cur_data         :
	               bus_rs == `RREG_RST ? 8'hff            :
	               8'hff;

	/* Data out latch (in DMA mode, this is one cycle after we've
	* asserted ACK)
	*/
	always@(posedge clk) if((reg_wr && bus_rs == `WREG_ODR) || dma_wr) dout <= wdata;

	/* Current data register. Simplified logic: We loop back the
	* output data if we are asserting the bus, else we get the
	* input latch
    */
	wire [7:0] cur_data = out_en ? dout : din;

	/* Logic for "asserting the bus" simplified */
	wire       out_en = icr[`ICR_A_DATA] | mr[`MR_ARB];

	/* ICR read wires */
	wire [7:0] icr_read = { icr[`ICR_A_RST],
	                        icr_aip,
	                        icr_la,
	                        icr[`ICR_A_ACK],
	                        icr[`ICR_A_BSY],
	                        icr[`ICR_A_SEL],
	                        icr[`ICR_A_ATN],
	                        icr[`ICR_A_DATA] };

	/* ICR write */
	always@(posedge clk or posedge reset) begin
		if (reset) begin
			icr <= 0;
		end else if (reg_wr && (bus_rs == `WREG_ICR)) begin
			icr <= wdata;
		end
	end
   
	/* MR write */
	always@(posedge clk or posedge reset) begin
		if (reset) mr <= 8'b0;
		else if (reg_wr && (bus_rs == `WREG_MR)) mr <= wdata;
	end
   
	/* TCR write */
	always@(posedge clk or posedge reset) begin
		if (reset) tcr <= 4'b0;
		else if (reg_wr && (bus_rs == `WREG_TCR)) tcr <= wdata[3:0];
	end
   
	/* DMA start send & receive registers. We currently ignore
	* the direction.
	*/
	always@(posedge clk or posedge reset) begin
		if (reset) begin
			dma_en <= 0;
		end else begin
			if (!mr[`MR_DMA_MODE]) begin
				dma_en <= 0;
			end else if (reg_wr && (bus_rs == `WREG_DMAS)) begin
				dma_en <= 1;
			end else if (reg_wr && (bus_rs == `WREG_IDMAR)) begin
				dma_en <= 1;
			end
		end
	end

	/* CSR (read only). We don't do parity */
	assign csr = { scsi_rst, scsi_bsy, scsi_req & ~req_deferred, scsi_msg,
	               scsi_cd, scsi_io, scsi_sel, 1'b0 };	

	/* Bus and Status register */
	/* BSR (read only). We don't do a few things... */
	wire bsr_eodma = ~(scsi_bsy & ~scsi_cd & ~scsi_msg);	/* asserted whenever NOT in a data phase */
	/* A real 5380 inhibits DRQ when REQ arrives with MSG/CD/IO not matching TCR,
	 * and halts the DMA handshake with it. That inhibition is the exit ramp for
	 * "the target CHECKed instead of entering the data phase": REQ stays visible
	 * in CSR, the driver's poll loop exits, and the SCSI Manager handles the
	 * phase change. Without it the blind pump loop ACKs the STATUS byte as if it
	 * were sector data and the transaction ends invisibly (seam11; confirmed on
	 * hardware 2026-08-22 as ACK-in-STATUS with no watchdog fire).
	 *
	 * But it is keyed on the BUS PHASE, not on bsr_pmatch. Gating on TCR was
	 * tried and broke every pseudo-DMA WRITE on hardware: the Plus driver does
	 * not maintain TCR across a write data phase, so bsr_pmatch reads 0 all the
	 * way through, no DACK write ever ACKs, and the target's bus watchdog fires
	 * at 129 ms (measured: 8 DACK writes, wdog=1, ACK-in-STATUS=0, the machine
	 * hanging before "Welcome to Macintosh"). The behaviour that actually has to
	 * be prevented is a DACK access consuming a byte from a NON-DATA phase, and
	 * that is exactly what this says. It is also the same condition bsr_eodma
	 * reports, so the two cannot disagree.
	 */
	wire bus_data_phase = scsi_bsy & ~scsi_cd & ~scsi_msg;
	wire bsr_dmarq = scsi_req & dma_en & bus_data_phase;
	wire bsr_perr = 1'b0;	/* We don't do parity */
	wire bsr_irq = irq_latch;	/* latched completion IRQ, cleared by a reg-7 read */
	wire bsr_pmatch = 
	         tcr[`TCR_A_MSG] == scsi_msg &&
	         tcr[`TCR_A_CD ] == scsi_cd  &&
	         tcr[`TCR_A_IO ] == scsi_io;

	wire bsr_berr = 1'b0;	/* XXX ? Does MacOS use this ? */
	wire [7:0] bsr = { bsr_eodma, bsr_dmarq, bsr_perr, bsr_irq,
	                   bsr_pmatch, bsr_berr, scsi_atn, scsi_ack };

   /* --- Simulated SCSI Signals --- */

   /* BSY logic (simplified arbitration, see notes) */
	wire scsi_bsy = 
	    icr[`ICR_A_BSY] |
	    |target_bsy |
	    //scsi2_bsy |
	    //scsi6_bsy |
	    mr[`MR_ARB];

	/* Remains of simplified arbitration logic */
	wire icr_aip = mr[`MR_ARB];
	wire icr_la = 0;

	/* Other ORed SCSI signals */
	wire scsi_sel = icr[`ICR_A_SEL];
	wire scsi_rst = icr[`ICR_A_RST];
	wire scsi_ack = icr[`ICR_A_ACK] | dma_ack;
	wire scsi_atn = icr[`ICR_A_ATN];

	/* Mux target signals */
	reg scsi_cd, scsi_io, scsi_msg, scsi_req;

	always @* begin
		integer i;
		scsi_cd = 0;
		scsi_io = 0;
		scsi_msg = 0;
		scsi_req = 0;
		din = 8'h55;

		for (i = 0; i < DEVS; i = i + 1) begin
			if (target_bsy[i]) begin
				scsi_cd = target_cd[i];
				scsi_io = target_io[i];
				scsi_msg = target_msg[i];
				scsi_req = target_req[i];
				din = target_dout[i];
			end
		end
	end

	/* ---- 5380 completion semantics (ported from MacLC_MiSTer) -------------
	 * Three status behaviours the SCSI Manager and Apple's CD driver depend
	 * on, all previously stubbed out here. MacLC's ncr5380.sv documents each
	 * as a fix for a System 7 "Welcome to Macintosh" wedge.
	 */

	/* Register-space read strobes (never the DACK/pseudo-DMA window) */
	wire csr_rd = bus_cs & ~dack & ~iow & (bus_rs == `RREG_CSR);
	wire rst_rd = bus_cs & ~dack & ~iow & (bus_rs == `RREG_RST);

	/* Deferred bus-visible REQ (Snow controller.rs `set_req` semantics).
	 * The SCSI Manager's between-chunk settle loop
	 *     btst #5,CSR / beq exit / btst #3,BSR / bne loop
	 * exits only when a CSR read returns REQ=0. A real 5380 driving a real
	 * drive gives it that window through the per-byte handshake; a target
	 * that asserts REQ immediately on the Data -> Status transition never
	 * does, and the loop spins forever -- the initiator hangs while the
	 * target is behaving perfectly, which is why a bus watchdog cannot see
	 * it. Hide each newly-asserted REQ from CSR until one full CSR read has
	 * completed (that read returns 0 and disarms; the next shows 1).
	 * BSR.DRQ and dreq are deliberately NOT deferred, so DRQ-polled transfer
	 * loops and DACK pacing are unaffected.
	 */
	reg req_deferred;
	reg [9:0] defer_age;   // bounds how long a REQ can stay hidden
	reg old_req_bus_d;
	reg old_csr_rd_d;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			req_deferred  <= 1'b0;
			old_req_bus_d <= 1'b0;
			old_csr_rd_d  <= 1'b0;
		end else begin
			old_req_bus_d <= scsi_req;
			old_csr_rd_d  <= csr_rd;
			if (~old_req_bus_d & scsi_req)
				req_deferred <= 1'b1;       // new REQ: hidden until a CSR read
			else if (req_deferred & old_csr_rd_d & ~csr_rd)
				req_deferred <= 1'b0;       // CSR read completed: reveal REQ
			// Self-limiting: csr_rd depends on the host asserting a particular
			// byte lane, but rdata does not, so a poll through the other lane
			// reads the right value while never clearing the deferral -- REQ
			// would stay hidden for good and a CSR-polling driver would spin
			// forever (seam10). Age it out so that cannot happen.
			if (!req_deferred) defer_age <= 10'd0;
			else if (~&defer_age) defer_age <= defer_age + 10'd1;
			if (&defer_age) req_deferred <= 1'b0;
			if (!scsi_req)
				req_deferred <= 1'b0;
		end
	end

	/* Completion-IRQ latch. `dma_armed` deliberately survives a DMA-mode
	 * clear: the driver often clears MR.DMA_MODE just before the phase
	 * change, so gating the latch on MR.DMA_MODE drops the IRQ and an async
	 * driver sleeps on a completion that never arrives. Latched on the
	 * target's DATA -> STATUS phase mismatch, cleared by a reg-7 read or a
	 * bus reset. Polled through BSR bit 4 -- the Plus routes no 5380 IRQ to
	 * the VIA, so no interrupt line is synthesised here.
	 */
	reg irq_latch;
	reg dma_armed;
	reg pmatch_d;
	reg old_rst_rd;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			irq_latch  <= 1'b0;
			dma_armed  <= 1'b0;
			pmatch_d   <= 1'b1;
			old_rst_rd <= 1'b0;
		end else begin
			old_rst_rd <= rst_rd;
			pmatch_d   <= bsr_pmatch;
			if (reg_wr && (bus_rs == `WREG_DMAS || bus_rs == `WREG_IDMAR))
				dma_armed <= 1'b1;
			if (~old_rst_rd & rst_rd)
				irq_latch <= 1'b0;
			// LEVEL, not edge. The edge form (pmatch_d && !bsr_pmatch) only
			// fires when the mismatch APPEARS after the arm. A driver that
			// arms pseudo-DMA when the target is ALREADY in STATUS -- the
			// no-media CHECK case -- produces no edge and no IRQ, so a driver
			// waiting on BSR bit 4 waits forever. A real 5380 level-checks
			// when DMA starts.
			// The condition is "the target is asking from STATUS or MESSAGE"
			// (cd & io), not "!bsr_pmatch": the latter also fires during
			// COMMAND phase, latching a completion IRQ on a transaction that
			// has not even reached its data phase yet (seen on hardware as
			// BSR=0x98 during a healthy disk write).
			// Gated on dma_armed rather than dma_en deliberately: the driver
			// often clears MR.DMA_MODE just before the phase change, and
			// gating on dma_en drops the IRQ (see dma_armed above, seam6).
			if (dma_armed && scsi_req && scsi_cd && scsi_io) begin
				irq_latch <= 1'b1;
				dma_armed <= 1'b0;
			end
			if (scsi_rst) begin
				irq_latch <= 1'b0;
				dma_armed <= 1'b0;
			end
		end
	end


	/* ---- debug tap -------------------------------------------------------
	 * Bit assignments are mirrored in rtl/dbg_probes.sv and decoded by
	 * scripts/read_probes.tcl; change all three together.
	 *   [4:0]   scsi_bsy, scsi_msg, scsi_cd, scsi_io, scsi_req  (raw, un-deferred)
	 *   [9:5]   dma_en, dma_ack, bsr_pmatch, irq_latch, dma_armed
	 *   [11:10] any target's bus-watchdog / io-stall abort
	 * The five bus signals decode the target's phase exactly (see the phase
	 * table in scsi.v), which is why no phase port is needed here.
	 */
	// bit 0 is |target_bsy, NOT scsi_bsy: scsi_bsy also carries the INITIATOR's
	// own BSY (ICR bit 3) and MR_ARB, so during arbitration/selection it reads
	// high while no target drives MSG/CD/IO -- which the probe deck's phase
	// decode then reports as a spurious DATA phase. Cost us a misread on the
	// 2026-08-22 hardware capture.
	assign dbg_bus = { |target_iostall, |target_wdog,
	                   dma_armed, irq_latch, bsr_pmatch, dma_ack, dma_en,
	                   scsi_req, scsi_io, scsi_cd, scsi_msg, |target_bsy };

	wire [DEVS-1:0] target_wdog, target_iostall;

	// input signals from targets
	wire [DEVS-1:0] target_bsy;
	wire [DEVS-1:0] target_msg;
	wire [DEVS-1:0] target_io;
	wire [DEVS-1:0] target_cd;
	wire [DEVS-1:0] target_req;
	wire      [7:0] target_dout[DEVS];

	generate
		genvar i;
		for (i = 0; i < DEVS; i = i + 1) begin : target
			// connect a target
			// SCSI IDs: disks descend from 6 (6, 5, ...); the CD sits at 3.
			// The Plus ROM scans IDs 6 -> 0, so a bootable hard disk is always
			// found before the CD, while a bootable CD still works when no disk
			// is bootable. ID 3 is also the AppleCD SC factory default.
			scsi #(.ID((i == CD_DEV) ? 3'd3 : (3'd6 - i[2:0])),
			       .CDROM((i == CD_DEV) ? 1 : 0), .WDOG_LOG(WDOG_LOG), .IOWDOG_LOG(IOWDOG_LOG)) target
			(
				.clk    ( clk ),
				.rst    ( scsi_rst ),
				.sys_rst( reset ),
				// SCSI arbitration: a target must not answer selection while
				// another one holds the bus. Own BSY is included and is
				// harmless -- this target is in IDLE (bsy=0) whenever the test
				// is evaluated.
				.bus_busy( |target_bsy ),
				.cd_enable( (i == CD_DEV) ? cd_enable : 1'b0 ),
				.cd_dbg   ( cd_dbg ),
				.cd_ms_mode( cd_ms_mode ),
				.cd_vendor_dbg( cd_vendor_dbg ),
				.cd_sense_mode( cd_sense_mode ),
				.sel    ( scsi_sel ),
				.atn    ( scsi_atn ),

				.ack    ( scsi_ack ),

				.bsy    ( target_bsy[i]  ),
				.msg    ( target_msg[i]  ),
				.cd     ( target_cd[i]   ),
				.io     ( target_io[i]   ),
				.req    ( target_req[i]  ),
				.dout   ( target_dout[i] ),

				.din    ( dout ),

				// connection to io controller to read and write sectors
				// to sd card
				.img_mounted(img_mounted[i]),
				.img_blocks(img_size),
				.io_lba ( io_lba[i] ),
				.io_rd  ( io_rd[i] ),
				.io_wr  ( io_wr[i] ),
				.io_ack ( io_ack[i] & target_bsy[i] ),

				.sd_buff_addr( sd_buff_addr ),
				.sd_buff_dout( sd_buff_dout ),
				.sd_buff_din( sd_buff_din[i] ),
				.sd_buff_wr( sd_buff_wr & target_bsy[i] ),

				.dbg_abort( { target_iostall[i], target_wdog[i] } )
			);
		end
	endgenerate

endmodule
