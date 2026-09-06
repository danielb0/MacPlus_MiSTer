// ---------------------------------------------------------------------------
// dbg_probes.sv -- JTAG In-System Sources & Probes for the MacPlus SCSI hunt.
//
// Ported from MacLC_MiSTer's rtl/dbg_probes.sv (same instance-ID convention,
// so its decode knowledge and reader tooling carry over).
//
// WHY THIS AND NOT SignalTap: the failure under investigation is a FREEZE. A
// trace buffer needs a trigger placed correctly in time; a live probe just
// holds the last latched values, and you read them in Quartus while the Mac
// is still wedged. Nothing has to be predicted in advance.
//
// Read with: Quartus > Tools > In-System Sources and Probes Editor, or
//            quartus_stp -t scripts/read_probes.tcl
//
// FPGA-ONLY: instantiated from MacPlus.sv behind `USE_SCSI_ISSP`, so the
// altsource_probe primitive never reaches a simulator.
//
// Probe deck (12 instances -- MacLC notes a ~20 hub-node ceiling above which
// the name table reads back corrupted, so there is room but not much):
//
//   PIFA  instruction-fetch sampler: WHERE is the CPU?
//   PIFD  {addr16, opcode16} at each fetch: WHAT is it executing there?
//   PACT  bus-cycle counter: is the CPU alive at all?
//   PSCS  last SCSI register READ  (the poll target + the value it returned)
//   PSCW  last SCSI register WRITE (the register the driver last programmed)
//   PODR  last four bytes written to the data register -- the CDB tail
//   PIOS  {rd_stuck, window, cd_io_lba} -- is an HPS fetch stalled, for which
//         LBA, and in which of the three address windows (data / CD-DA / TOC)?
//   PIO2  CD/disk io_rd vs io_ack counts + live handshake bits
//   PIO3  {wr_stuck, d0_io_lba} -- the WRITE-side twin of PIOS
//   PIO4  disk write/ack counts + live write handshake bits
//   PHLD  CPU hold-off engagements + longest stall + frontier breaches
//   PRG0-1  ring of the last 4 SCSI register accesses -- the CONVERSATION,
//           not just its last line
//   PDMA  the discriminating word: DACK reads since the arm, watchdog fire
//         counts, phase-visit mask -- see "the discriminators" below
//   PDM2  sticky evidence bits + a ring of the last 8 target phases
//   PDCD  the DCD (HD20) link: states the Mac drove, /HSHK, both handshake
//         FSMs, the last opcode -- see "the DCD probe" below
//   PDC2  DCD byte counts, how far a reply got, and the opcode of the
//         first command the drive received and never answered
//
// THE DECK IS AT THE ~20 HUB-NODE CEILING MacLC MEASURED, above which the name
// table reads back corrupted. PDCD and PDC2 came in, so PRG2 and PRG3 went
// out: the SCSI access ring is now 4 entries rather than 8. That is the
// cheapest thing here to halve -- the SCSI wedge it was built for is closed
// (see [[macplus-scsi-release-blocker-no-dtack]]), and a 4-entry ring still
// carries a CDB handover. Nothing else in the deck degrades gracefully.
// ---------------------------------------------------------------------------
module dbg_probes (
	input  wire        clk,

	// CPU bus (all available at the MacPlus.sv top level)
	input  wire [23:0] cpuAddr,
	input  wire  [2:0] cpuFC,
	input  wire        _cpuAS,
	input  wire        _cpuRW,
	input  wire [15:0] cpuDataOut,     // CPU -> bus (writes)
	input  wire [15:0] cpuDataIn,      // bus -> CPU (reads; dataControllerDataOut)

	input  wire        selectSCSI,

	// HPS sector-fetch handshake for the CD target (top-level signals, no
	// threading needed). A read that is requested and never acknowledged holds
	// io_busy, which holds REQ low AND continuously resets the bus watchdog --
	// a hang with no recovery by construction (rtl/scsi.v:239 and :1195).
	input  wire        cd_io_rd,
	input  wire        cd_io_wr,
	input  wire        cd_io_ack,
	input  wire [31:0] cd_io_lba,
	input  wire        d0_io_rd,
	input  wire        d0_io_wr,
	input  wire        d0_io_ack,
	input  wire [31:0] d0_io_lba,
	input  wire        d1_io_wr,

	// Raw 5380 state, tapped in rtl/ncr5380.sv. Bit assignments are defined
	// there; all counting, epochs and sticky logic live here.
	input  wire [15:0] scsi_dbg,

	// CPU bus hold-off and frontier-breach pulse (rtl/ncr5380.sv). These are the
	// only way a hardware run can distinguish "the interlock held" from "the HPS
	// happened not to lag this time" -- a clean copy proves the second, not the
	// first, and the two look identical from the guest.
	input  wire        scsi_hold,
	input  wire        scsi_breach,
	// Floppy telemetry from the internal drive (rtl/floppy.v). Added for the
	// 128K's happy-Mac-then-'?' failure, which stopped yielding to inference:
	// maxTrack says whether it dies at the CLV zone boundary (track 16), and
	// the PWM min/max bracket the range the ROM's speed loop actually drove,
	// which is what an invented PWM->period map must be calibrated against.
	input  wire [31:0] dbg_floppy,

	// DCD (Apple HD20) link telemetry from rtl/dcd.v. Raw live state only; all
	// the counting and the sticky bits are below, which is why the clear
	// source can live here and does not have to be threaded back down.
	input  wire [31:0] dbg_dcd
);

	wire dbg_bsy    = scsi_dbg[0];
	wire dbg_msg    = scsi_dbg[1];
	wire dbg_cd     = scsi_dbg[2];
	wire dbg_io     = scsi_dbg[3];
	wire dbg_req    = scsi_dbg[4];
	wire dbg_dma_en = scsi_dbg[5];
	wire dbg_ack    = scsi_dbg[6];
	wire dbg_pmatch = scsi_dbg[7];
	wire dbg_irq    = scsi_dbg[8];
	wire dbg_armed  = scsi_dbg[9];
	wire dbg_wdog   = scsi_dbg[10];
	wire dbg_iowdog = scsi_dbg[11];
	wire [3:0] dbg_tcr = scsi_dbg[15:12];

	// ---- bus-cycle edges --------------------------------------------------
	reg as_d;
	always @(posedge clk) as_d <= _cpuAS;
	wire as_fall = as_d & ~_cpuAS;     // address/decode valid
	wire as_rise = ~as_d & _cpuAS;     // data valid, cycle ending

	// Bus data, delayed one clock. Sampling at AS-rise reads the mux AFTER the
	// cycle may have stopped selecting its source, which is why the first cut
	// of this probe returned impossible BSR values (perr/berr are hardwired 0
	// yet read back set). Use the value from the clock BEFORE the edge, while
	// AS was still asserted.
	reg [15:0] din_d, dout_d;
	always @(posedge clk) begin
		din_d  <= cpuDataIn;
		dout_d <= cpuDataOut;
	end

	// ---- PIFA: instruction-fetch sampler ----------------------------------
	// Captures cpuAddr only on real instruction fetches (AS falling, read,
	// FC = program space). Repeated JTAG samples of a stable wedge loop
	// histogram its PCs -- that is what names the loop the CPU is stuck in.
	// PIFA[31:24] is a wrap-8 fetch count: FROZEN means the CPU is wedged in
	// a state that fetches nothing (bus hang); ADVANCING means it is looping
	// in software, and PIFA[23:0] says where.
	wire if_cycle = as_fall & _cpuRW &
	                ((cpuFC == 3'b010) | (cpuFC == 3'b110));
	reg  [7:0] if_cnt;
	reg [23:0] if_addr;
	always @(posedge clk)
		if (if_cycle) begin
			if_addr <= cpuAddr;
			if_cnt  <= if_cnt + 8'd1;
		end
	reg [31:0] pifa_r;
	always @(posedge clk) pifa_r <= {if_cnt, if_addr};

	// ---- PIFD: the instruction WORD at each fetch --------------------------
	// PIFA says where the CPU is looping; this says what it is executing there.
	// Sampled repeatedly over a stable wedge loop, the {addr, opcode} pairs
	// reconstruct the loop so it can be disassembled instead of guessed at.
	reg        if_pend;
	reg [15:0] if_addr_l;
	always @(posedge clk) begin
		if (if_cycle) begin if_pend <= 1'b1; if_addr_l <= cpuAddr[15:0]; end
		else if (if_pend & as_rise) if_pend <= 1'b0;
	end
	reg [31:0] pifd_r;
	always @(posedge clk)
		if (if_pend & as_rise) pifd_r <= {if_addr_l, din_d};

	// ---- PACT: bus-cycle counter (liveness) -------------------------------
	reg [31:0] as_cycles;
	always @(posedge clk) if (as_fall) as_cycles <= as_cycles + 32'd1;

	// ---- SCSI register traffic --------------------------------------------
	// The decode matches dataController_top: bus_rs = A6-A4, dack = A9.
	// Address and direction are latched when AS falls (decode valid) and the
	// data is taken when AS rises (data valid), so a read captures what the
	// CPU actually got rather than a mid-cycle value.
	reg       sel_lat, rw_lat, dack_lat;
	reg [2:0] reg_lat;
	always @(posedge clk)
		if (as_fall) begin
			sel_lat  <= selectSCSI;
			rw_lat   <= _cpuRW;
			dack_lat <= cpuAddr[9];
			reg_lat  <= cpuAddr[6:4];
		end

	reg  [7:0] rd_cnt, wr_cnt;
	reg  [7:0] rd_val, wr_val;
	reg  [3:0] rd_sel, wr_sel;         // {dack, reg[2:0]}
	reg [31:0] odr_hist;               // last 4 bytes written to reg 0

	always @(posedge clk)
		if (as_rise & sel_lat) begin
			if (rw_lat) begin
				rd_cnt <= rd_cnt + 8'd1;
				rd_val <= din_d[15:8];          // SCSI byte rides D15-D8
				rd_sel <= {dack_lat, reg_lat};
			end else begin
				wr_cnt <= wr_cnt + 8'd1;
				wr_val <= dout_d[15:8];
				wr_sel <= {dack_lat, reg_lat};
				// Non-DACK writes to register 0 are the output data register:
				// during COMMAND phase that stream IS the CDB.
				if (!dack_lat && (reg_lat == 3'd0))
					odr_hist <= {odr_hist[23:0], dout_d[15:8]};
			end
		end

	// PSCS: [31:24]=rd_cnt [23:16]=rd_val [15:12]={dack,reg}
	//       [11:8]=DACK-read count [7:0]=wr_cnt
	reg [31:0] pscs_r;
	always @(posedge clk) pscs_r <= {rd_cnt, rd_val, rd_sel, dack_rd_nib, wr_cnt};

	// PSCW: [31:24]=wr_cnt [23:16]=wr_val [15:12]={dack,reg} [7:0]=rd_cnt
	reg [31:0] pscw_r;
	always @(posedge clk) pscw_r <= {wr_cnt, wr_val, wr_sel, 4'd0, rd_cnt};

	// ---- PRG0..PRG1: a ring of the last 4 SCSI register accesses -----------
	// PSCS/PSCW hold only the LAST access, which shows the poll but not the
	// conversation that led to it. This keeps the last four, newest first, so
	// the CDB handover, the arming writes and any status read can be read back
	// as a sequence. Each entry is {rw, dack, reg[2:0], 3'b0, value[7:0]}.
	// A wedged driver polls CSR/BSR thousands of times a second, so recording
	// every access flooded the ring with identical poll entries and threw away
	// the history that mattered. Filter plain CSR/BSR reads out: what is left
	// is the CDB handover, the arming writes, and any CDR/DACK read -- the
	// events that say how far the transaction actually got.
	//
	// Halved from eight entries to four to make hub-node room for PDCD/PDC2;
	// see the ceiling note in the header.
	wire acc_is_poll = rw_lat & ~dack_lat &
	                   ((reg_lat == 3'd4) | (reg_lat == 3'd5));
	reg [63:0] acc_hist;
	always @(posedge clk)
		if (as_rise & sel_lat & ~acc_is_poll)
			acc_hist <= {acc_hist[47:0],
			             rw_lat, dack_lat, reg_lat, 3'd0,
			             rw_lat ? din_d[15:8] : dout_d[15:8]};

	// ---- the discriminators (PDMA / PDM2) ---------------------------------
	// The 2026-08-22 review left one measurement standing between two readings
	// of the wedge, and the instrument that was supposed to answer it could
	// not:
	//
	//   the OLD counter here was a free-running 4-bit wrap counter, never
	//   cleared. A machine that boots off a SCSI hard disk does thousands of
	//   DACK reads before it ever touches the CD, so at the wedge it holds
	//   (total mod 16) -- a number with no relation to the two reads the
	//   mechanism predicts, and one that reads back 0 once every sixteen
	//   boots. "No DACK reads observed" was never evidence of anything.
	//
	// So: an 8-bit SATURATING lifetime total (0 now means genuinely none, and
	// it cannot roll back to 0), plus a small counter re-armed on each DMA
	// start, which is the count the mechanism actually predicts (2).
	//
	// The rest of this block answers the other three questions the review
	// specified, all sticky and all cleared on selection so what is read back
	// describes the LAST transaction -- the wedged one:
	//   * did either watchdog fire? (predict no: the "missed REQ" reading
	//     needs at least one, the "completed invisibly" reading needs none)
	//   * which phases were visited? (predict CMD -> STATUS -> MESSAGE -> IDLE
	//     and no DATA phase at all)
	//   * was REQ ever high while the target sat in STATUS? (the io_busy
	//     fallback has no identified setter, but its abort path erases
	//     io_rd/io_wr, so it cannot be excluded after the fact any other way)
	wire dack_rd = as_rise & sel_lat &  rw_lat & dack_lat;
	// A write to reg 5 (Start DMA Send) or reg 7 (Start DMA Initiator Receive)
	// is what sets dma_en; the wedge capture recorded reg 7.
	wire dma_arm = as_rise & sel_lat & ~rw_lat & ~dack_lat &
	               ((reg_lat == 3'd5) | (reg_lat == 3'd7));

	// Target phase, decoded from the bus signals the initiator can see. Codes
	// match rtl/scsi.v's PHASE_* so a capture reads against that table.
	wire [2:0] phase_now =
		!dbg_bsy                          ? 3'd0 :   // IDLE
		( dbg_msg &  dbg_cd &  dbg_io)    ? 3'd5 :   // MESSAGE_OUT
		( dbg_msg)                        ? 3'd7 :   // (no such phase)
		( dbg_cd  &  dbg_io)              ? 3'd4 :   // STATUS_OUT
		( dbg_cd)                         ? 3'd1 :   // CMD_IN
		( dbg_io)                         ? 3'd2 :   // DATA_OUT (to initiator)
		                                    3'd3;    // DATA_IN

	reg  dbg_bsy_d = 0, dbg_wdog_d = 0, dbg_iowdog_d = 0;
	reg  [2:0] phase_d = 3'd0;
	wire new_sel = ~dbg_bsy_d & dbg_bsy;             // selection: the epoch mark

	// The 2026-08-22 capture pinned dack_rd_arm at its 4-bit maximum, which
	// answered "more than 2" but hid the real figure -- the driver blind-reads
	// a whole chunk, not two bytes. 8 bits now; the abort and arm counters
	// only ever need to separate zero from non-zero, so they give up the room.
	reg  [7:0] dack_rd_tot = 0;   // lifetime, saturating
	reg  [7:0] dack_rd_arm = 0;   // since the last DMA start, saturating
	reg  [1:0] arm_cnt     = 0;   // DMA starts since selection
	reg  [2:0] wdog_cnt    = 0;   // bus-watchdog aborts since selection
	reg  [2:0] iowdog_cnt  = 0;   // io-stall aborts since selection
	reg  [5:0] phase_seen  = 0;   // bit n = phase code n visited since selection
	reg [23:0] phase_ring  = 0;   // last 8 phases, newest in [2:0]

	reg st_req_status   = 0;      // REQ high while in STATUS
	reg st_req_msgout   = 0;      // REQ high while in MESSAGE
	reg st_dack_mism    = 0;      // a DACK read happened during a phase mismatch
	reg st_drq_mism     = 0;      // DRQ was asserted during a phase mismatch
	reg st_ack_status   = 0;      // ACK pulsed while in STATUS (the byte moved)
	reg st_irq_seen     = 0;      // the completion IRQ latched at some point

	always @(posedge clk) begin
		dbg_bsy_d    <= dbg_bsy;
		dbg_wdog_d   <= dbg_wdog;
		dbg_iowdog_d <= dbg_iowdog;
		phase_d      <= phase_now;

		// Lifetime DACK reads: saturate rather than wrap.
		if (dack_rd && ~&dack_rd_tot) dack_rd_tot <= dack_rd_tot + 8'd1;

		// Per-arm DACK reads. Cleared by the arming write itself, so a capture
		// answers "how many DACK reads since the driver said go", not "ever".
		if (dma_arm)                       dack_rd_arm <= 8'd0;
		else if (dack_rd && ~&dack_rd_arm) dack_rd_arm <= dack_rd_arm + 8'd1;

		// Everything below is per-transaction.
		if (new_sel) begin
			arm_cnt       <= 2'd0;
			wdog_cnt      <= 3'd0;
			iowdog_cnt    <= 3'd0;
			phase_seen    <= 6'd0;
			st_req_status <= 1'b0;
			st_req_msgout <= 1'b0;
			st_dack_mism  <= 1'b0;
			st_drq_mism   <= 1'b0;
			st_ack_status <= 1'b0;
			st_irq_seen   <= 1'b0;
		end else begin
			if (dma_arm                     && ~&arm_cnt)    arm_cnt    <= arm_cnt    + 2'd1;
			if (~dbg_wdog_d   & dbg_wdog    && ~&wdog_cnt)   wdog_cnt   <= wdog_cnt   + 3'd1;
			if (~dbg_iowdog_d & dbg_iowdog  && ~&iowdog_cnt) iowdog_cnt <= iowdog_cnt + 3'd1;
			if (phase_now < 3'd6) phase_seen[phase_now] <= 1'b1;

			if (dbg_req && (phase_now == 3'd4)) st_req_status <= 1'b1;
			if (dbg_req && (phase_now == 3'd5)) st_req_msgout <= 1'b1;
			if (dbg_ack && (phase_now == 3'd4)) st_ack_status <= 1'b1;
			if (dack_rd &&  !dbg_pmatch)                    st_dack_mism <= 1'b1;
			if (dbg_req && dbg_dma_en && !dbg_pmatch)       st_drq_mism  <= 1'b1;
			if (dbg_irq)                                    st_irq_seen  <= 1'b1;
		end

		// Phase ring: one entry per phase CHANGE, so eight entries cover a whole
		// transaction instead of eight clocks of one phase.
		if (phase_now != phase_d) phase_ring <= {phase_ring[20:0], phase_now};
	end

	// ---- PDM3: the arm-to-data-phase window -------------------------------
	// Two attempts at gating the DMA handshake both passed every bench here and
	// both hung the machine on hardware. What no bench models is WHEN the
	// driver starts pumping relative to the target entering its data phase: if
	// it blind-writes while the target is still in COMMAND, a gate that refuses
	// those accesses drops bytes the old ungated code silently accepted, and
	// the transfer deadlocks. That window is what this measures.
	wire dack_wr = as_rise & sel_lat & ~rw_lat & dack_lat;
	wire dack_any = dack_rd | dack_wr;

	reg  [7:0] dack_wr_arm  = 0;   // DACK writes since the arm (reads are in PDMA)
	reg  [2:0] phase_at_arm = 0;   // target phase at the moment DMA was armed
	reg        pmatch_at_arm = 0;
	reg  [2:0] phase_1st_dack = 0; // phase at the FIRST DACK access after the arm
	reg        seen_1st_dack = 0;
	reg        st_dack_nondata = 0; // a DACK access taken outside a data phase
	reg  [3:0] tcr_at_arm = 0;

	// "Data phase" as the bus reports it, the same condition bsr_eodma uses.
	wire in_data_phase = dbg_bsy & ~dbg_cd & ~dbg_msg;

	always @(posedge clk) begin
		if (dma_arm) begin
			dack_wr_arm    <= 8'd0;
			phase_at_arm   <= phase_now;
			pmatch_at_arm  <= dbg_pmatch;
			tcr_at_arm     <= dbg_tcr;
			seen_1st_dack  <= 1'b0;
			phase_1st_dack <= 3'd0;
		end else begin
			if (dack_wr && ~&dack_wr_arm) dack_wr_arm <= dack_wr_arm + 8'd1;
			if (dack_any && !seen_1st_dack) begin
				seen_1st_dack  <= 1'b1;
				phase_1st_dack <= phase_now;
			end
		end
		if (new_sel) st_dack_nondata <= 1'b0;
		else if (dack_any && !in_data_phase) st_dack_nondata <= 1'b1;
	end

	// PDM3 packing, mirrored in scripts/read_probes.tcl and sim/tb_dbg_probes.v:
	//   [31:24] DACK writes since the arm   [23:20] TCR at the arm
	//   [19:16] TCR now                     [15:13] target phase at the arm
	//   [12]    pmatch at the arm           [11:9]  phase at the first DACK
	//   [8]     a DACK happened at all      [7] a DACK landed outside a data phase
	//   [6]     in a data phase now
	reg [31:0] pdm3_r;
	always @(posedge clk)
		pdm3_r <= {dack_wr_arm, tcr_at_arm, dbg_tcr,
		           phase_at_arm, pmatch_at_arm,
		           phase_1st_dack, seen_1st_dack,
		           st_dack_nondata, in_data_phase, 6'd0};

	// PSCS keeps a nibble of the lifetime total for continuity; 15 means ">=15".
	wire [3:0] dack_rd_nib = (dack_rd_tot > 8'd15) ? 4'd15 : dack_rd_tot[3:0];

	// PDMA packing, mirrored in scripts/read_probes.tcl and sim/tb_dbg_probes.v:
	//   [31:24] lifetime DACK reads   [23:16] DACK reads since the DMA arm
	//   [15:14] arms since selection  [13:11] bus-watchdog fires
	//   [10:8]  io-stall fires        [7:2]   phase-visit mask
	//   [1] REQ seen in STATUS        [0] REQ seen in MESSAGE
	reg [31:0] pdma_r, pdm2_r;
	always @(posedge clk) begin
		pdma_r <= {dack_rd_tot, dack_rd_arm, arm_cnt, wdog_cnt, iowdog_cnt,
		           phase_seen, st_req_status, st_req_msgout};
		pdm2_r <= {st_dack_mism, st_drq_mism, st_ack_status, st_irq_seen,
		           dbg_bsy, dbg_req, dbg_dma_en, dbg_pmatch,
		           phase_ring};
	end

	// ---- PIOS / PIO2: is an HPS sector fetch stalled? ----------------------
	// rd_stuck saturates while cd_io_rd stays continuously asserted. A
	// saturated value with rd_cnt > ack_cnt is a fetch the HPS never answered,
	// which is the no-recovery hang described above.
	reg  [7:0] rd_stuck;
	reg        cd_rd_d, cd_ack_d, d0_rd_d;
	reg [15:0] stuck_div;
	always @(posedge clk) begin
		cd_rd_d  <= cd_io_rd;
		cd_ack_d <= cd_io_ack;
		d0_rd_d  <= d0_io_rd;
		if (!cd_io_rd) begin
			rd_stuck  <= 8'd0;
			stuck_div <= 16'd0;
		end else begin
			stuck_div <= stuck_div + 16'd1;
			if (&stuck_div && ~&rd_stuck) rd_stuck <= rd_stuck + 8'd1;
		end
	end

	// ---- PIO3 / PIO4: the WRITE-side twin of the above ---------------------
	// The 2026-08-22 wedge was an io-stall on a DISK WRITE, and this deck could
	// not see it: PIO2 carried d0_rd_cnt only and PIOS carried cd_io_lba only,
	// so there was no disk write counter and no disk LBA anywhere. A capture of
	// that failure could show the machine was wedged but not on which block, in
	// which direction, or how far the write stream had got. Closing that needed
	// a recompile, which is why it is being done in the same build as the fixes
	// for the defects it is meant to observe.
	//
	// wr_stuck mirrors rd_stuck exactly: it saturates while d0_io_wr stays
	// continuously asserted, so a saturated value with wr_cnt > ack_cnt is a
	// flush the HPS never answered.
	reg  [7:0] wr_stuck;
	reg        d0_wr_d, d0_ack_d, d1_wr_d;
	reg [15:0] wstuck_div;
	always @(posedge clk) begin
		d0_wr_d  <= d0_io_wr;
		d0_ack_d <= d0_io_ack;
		d1_wr_d  <= d1_io_wr;
		if (!d0_io_wr) begin
			wr_stuck   <= 8'd0;
			wstuck_div <= 16'd0;
		end else begin
			wstuck_div <= wstuck_div + 16'd1;
			if (&wstuck_div && ~&wr_stuck) wr_stuck <= wr_stuck + 8'd1;
		end
	end

	// Initialised: these only ever increment, so without a power-up value they
	// are X forever in simulation and every count the deck reports is X --
	// the same no-reset shape as the Phase 0 io_rd/io_wr finding. Altera
	// fabric powers up at 0, so this matches the hardware it already had.
	reg [7:0] cd_rd_cnt = 8'd0, cd_ack_cnt = 8'd0, d0_rd_cnt = 8'd0;
	reg [7:0] d0_wr_cnt = 8'd0, d0_ack_cnt = 8'd0, d1_wr_cnt = 8'd0;
	always @(posedge clk) begin
		if (~cd_rd_d  &  cd_io_rd)  cd_rd_cnt  <= cd_rd_cnt  + 8'd1;
		if (~cd_ack_d &  cd_io_ack) cd_ack_cnt <= cd_ack_cnt + 8'd1;
		if (~d0_rd_d  &  d0_io_rd)  d0_rd_cnt  <= d0_rd_cnt  + 8'd1;
		if (~d0_wr_d  &  d0_io_wr)  d0_wr_cnt  <= d0_wr_cnt  + 8'd1;
		// d0_io_ack is shared by reads and flushes on that slot, so this is the
		// COMBINED ack count -- compare it against d0_rd_cnt + d0_wr_cnt.
		if (~d0_ack_d &  d0_io_ack) d0_ack_cnt <= d0_ack_cnt + 8'd1;
		if (~d1_wr_d  &  d1_io_wr)  d1_wr_cnt  <= d1_wr_cnt  + 8'd1;
	end

	// ---- PIOS window tag (added for Phase 3B) ------------------------------
	// cd_io_lba is not a plain block number: the CD target addresses three
	// disjoint spaces on the same channel (SCSI_UPGRADE_PLAN.md Phase 3A).
	//
	//   data      0x00000000 + disc_lba   ordinary sector reads
	//   CD-DA     0x40000000 + disc_lba   raw 2352-byte audio frames
	//   TOC blob  0x7FFF0000..0001        the "MCDA" table
	//
	// PIOS used to carry cd_io_lba[23:0] alone, which DESTROYS that
	// distinction: the audio base is 0x40000000, so bits [31:24] are exactly
	// what separates an audio fetch from a data read, and truncating them makes
	// "audio frame for disc block n" read as "data read of block n". That is
	// the specific ambiguity Phase 3B has to resolve -- cd_audio.sv and the
	// SCSI target share this channel, and telling their fetches apart IS the
	// arbitration test. Same trap as the write side had before PIO3 existed:
	// a probe that cannot see the failure reports a healthy-looking value.
	//
	// So spend 2 bits on a window tag and keep 22 of LBA (4,194,303 blocks --
	// a CD tops out around 360,000, and the audio offset is disc-relative).
	wire [1:0] cd_win = (cd_io_lba[31:16] == 16'h7FFF) ? 2'd2 :   // TOC blob
	                    (cd_io_lba[31:28] == 4'h4)     ? 2'd1 :   // CD-DA
	                    (|cd_io_lba[31:22])            ? 2'd3 :   // unrecognised
	                                                     2'd0;    // data

	// ---- PHLD: did the CPU hold-off actually engage? ----------------------
	// hold_events counts RISING edges (one per stalled access, not per cycle);
	// max_hold is the longest single stall in clk cycles, which is what says
	// whether a stall is a 0.6 ms fill lag or something pathological; breach_cnt
	// must be ZERO -- any count means a DACK access got past the hold-off and
	// only the CHECK CONDITION backstop caught it.
	//
	// All three saturate rather than wrap. A wrapped counter that reads 3 is
	// indistinguishable from a real 3, and this deck exists to be trusted.
	reg [11:0] hold_events = 0;
	reg [15:0] max_hold    = 0;
	reg  [3:0] breach_cnt  = 0;
	reg [15:0] hold_len    = 0;
	reg        hold_d      = 0;
	always @(posedge clk) begin
		hold_d <= scsi_hold;
		if (scsi_hold) begin
			if (!hold_d) begin
				hold_len <= 16'd1;
				if (~&hold_events) hold_events <= hold_events + 1'd1;
			end
			else if (~&hold_len) hold_len <= hold_len + 1'd1;
			if (hold_len > max_hold) max_hold <= hold_len;
		end
		if (scsi_breach && ~&breach_cnt) breach_cnt <= breach_cnt + 1'd1;
	end

	reg [31:0] pios_r, pio2_r, pio3_r, pio4_r, phld_r;
	always @(posedge clk) begin
		pios_r <= {rd_stuck, cd_win, cd_io_lba[21:0]};
		// PIO2[7] is a PROBE-FORMAT MARKER, not a signal. It says "PIOS carries a
		// window tag in [23:22]". Without it read_probes.tcl cannot tell a build
		// that has the tag from one that predates it, and on an older bitstream
		// it decodes the top of the old 24-bit LBA as a window -- printing a
		// perfectly plausible "win=data" that is pure fiction. That happened on
		// 2026-08-25: a comment warning in the script was useless, because the
		// output reads healthy either way. Exactly the failure the window tag
		// was added to fix, reintroduced one level up.
		//
		// It costs one of PIO2's three spare bits and no new hub node, which
		// matters -- the deck is at 18 instances against MacLC's noted ~20
		// ceiling, above which the name table reads back corrupted.
		pio2_r <= {cd_rd_cnt, cd_ack_cnt, d0_rd_cnt,
		           1'b1, 2'd0, cd_io_rd, cd_io_wr, cd_io_ack, d0_io_rd, d0_io_ack};
		pio3_r <= {wr_stuck, d0_io_lba[23:0]};
		pio4_r <= {d0_wr_cnt, d0_ack_cnt, d1_wr_cnt,
		           5'd0, d0_io_wr, d0_io_ack, d1_io_wr};
		phld_r <= {hold_events, max_hold, breach_cnt};
	end

	// ---- the DCD probe (PDCD / PDC2) --------------------------------------
	// MAC128K_PLAN.md Phase 5. HD Diag reports error $28 -- "the drive
	// asserted /HSHK and never released it" -- and nothing in the deck could
	// see the DCD at all, so the only tool left was the instruction-fetch
	// sampler, which can only reach code the CPU is ALREADY wedged in. That
	// missed the whole question of whether identification even happens: a
	// FAILED identification is microseconds of work and is invisible at 2.5
	// samples/sec, so the sampler's silence could never distinguish "the ROM
	// never found us" from "it found us and the command stalled".
	//
	// Everything sticky here, because those events are sub-millisecond and
	// JTAG samples land 0.4 s apart. Sticky state that is never cleared is
	// only readable once, so PDCD's SOURCE bit is the clear: hold it high to
	// zero the block, drop it to arm, then provoke the failure and read.
	wire  [2:0] dcd_state   = dbg_dcd[2:0];
	wire        dcd_sel     = dbg_dcd[3];
	wire        dcd_hshk_n  = dbg_dcd[4];
	wire  [2:0] dcd_rxhs    = dbg_dcd[7:5];
	wire  [2:0] dcd_txstate = dbg_dcd[10:8];
	wire        dcd_rxbyte  = dbg_dcd[12];
	wire        dcd_txbyte  = dbg_dcd[13];
	wire        dcd_rxvalid = dbg_dcd[14];
	wire        dcd_rxbad   = dbg_dcd[15];
	wire  [2:0] dcd_cstate  = dbg_dcd[18:16];
	wire        dcd_present = dbg_dcd[19];
	wire  [7:0] dcd_opcode  = dbg_dcd[27:20];

	// The clear arrives from the JTAG hub, which has no defined phase relation
	// to clk even with source_clk tied to it; two flops before anything fans
	// out from it.
	wire dcd_clr_src;
	reg  dcd_clr_m = 0, dcd_clr = 0;
	always @(posedge clk) begin
		dcd_clr_m <= dcd_clr_src;
		dcd_clr   <= dcd_clr_m;
	end

	reg  [7:0] dcd_states_seen = 0;   // bit n: the Mac drove state n while selected
	reg  [7:0] dcd_last_op     = 0;
	reg  [1:0] dcd_frames_in   = 0;   // rxValid, saturating
	reg        dcd_st_bad      = 0;   // a frame failed its checksum
	reg        dcd_st_abort    = 0;   // TX_WAIT gave up on an abandoned transfer
	reg  [5:0] dcd_bytes_in    = 0;   // saturating
	reg  [7:0] dcd_bytes_out   = 0;   // saturating
	reg  [2:0] dcd_txmax       = 0;   // highest txState reached
	reg  [2:0] dcd_rxhs_max    = 0;   // highest rxHs reached
	reg  [2:0] dcd_rxhs_d      = 0;
	reg  [2:0] dcd_txstate_d   = 0;
	reg        dcd_txbyte_d    = 0;

	// A REPLY ABANDONED MID-FRAME, WHICH dcd_st_abort CANNOT SEE. That bit
	// watches TX_WAIT(1) -> TX_IDLE(0) only, the escape added in abd857c for a
	// transfer the Mac never collected. But dcd_link's TX_DATA(3) and TX_LSB(4)
	// carry their OWN escape -- `!selected || state==2 || state==3 || state>=4`
	// -- and that one fires when the Mac walks away with the frame half sent.
	// On 2026-09-06 a 16 MHz boot showed exactly that: 64 bytes out, txmax
	// stuck at TX_LSB, and every existing flag clean. Record the escape, and
	// the state that caused it, or the deck says "no wedge visible" about a
	// reply that died.
	reg        dcd_ab_send     = 0;   // aborted out of TX_DATA/TX_LSB
	reg  [2:0] dcd_ab_state    = 0;   // the state the Mac drove at that moment
	reg        dcd_ab_sel      = 0;   // selected, at that moment

	// WAS THE DRIVE EVER LATE WITH A BYTE? The poll-budget reading says no --
	// the Mac gives up early, our pacing never slips -- so this is the field
	// that can falsify it. Counted in clk between newByteReady edges while a
	// frame is actually going out; a byte is 512 clk apart at 8 MHz and 256
	// with the turbo fix, so 1024 is late by any reading and nowhere near the
	// Mac's ~90 us (2880 clk) budget.
	reg [11:0] dcd_gap_cnt     = 0;   // clk since the last byte, saturating
	reg  [2:0] dcd_gap_long    = 0;   // gaps over 1024 clk, saturating

	// A COMMAND THE DRIVE RECEIVED AND NEVER ANSWERED. dcd.v dispatches only
	// from C_IDLE and does it on the SAME edge rxValid is asserted, so one
	// clock later an accepted command has moved cstate off C_IDLE and a
	// dropped one has not. That is the whole test, and it deliberately does
	// NOT restate dcd.v's dispatch conditions: a probe that mirrored them
	// would agree with the RTL by construction and measure nothing.
	//
	// The FIRST such opcode is kept, not the newest. A driver that gives up
	// on a command retries and then resets, so the newest would be whatever
	// the recovery path sent last. dcd_last_op is the opposite by design and
	// that is exactly why it could never show this -- every capture so far
	// ends with the $00 of an ordinary read.
	//
	// why: 1 = arrived in C_IDLE and was not dispatched (an opcode dcd.v
	// does not implement, or a guard it failed); 2 = arrived while the
	// command layer was still busy with the previous one.
	reg  [7:0] dcd_unans_op    = 0;
	reg  [1:0] dcd_unans_cnt   = 0;   // saturating
	reg  [1:0] dcd_unans_why   = 0;

	// A COMMAND ANSWERED BY THE GENERIC ACK (reason 3). b8dedd0 made dcd.v
	// answer any opcode it does not implement with an empty block. That is
	// right for $19/$1A, but it SILENCED this probe: an acked command leaves
	// C_IDLE, so neither test below can see it, and dcd_last_op keeps only
	// the newest, which every capture so far ends with as the $00 of an
	// ordinary read. Without this the deck cannot answer "did the Mac send
	// something we do not implement", which is the whole question the field
	// was added for.
	//
	// Told apart WITHOUT restating dcd.v's dispatch conditions: an ack and a
	// Status are the only replies that go straight to C_SEND with no disk
	// fetch (a read or a write goes to C_FETCH first), so C_SEND one clock
	// on, with the opcode not $03, IS the ack. That is the observable path
	// taken, not a copy of the guard that chose it.
	//
	// WHY THIS ONE MAY OVERWRITE, where nothing else does. Erase Disk sends
	// $19 then $1A and both are now acked, so a strict first-wins slot would
	// fill with $19 on the first format and hide everything afterwards. Those
	// two are expected and harmless; any OTHER acked opcode is not -- $3F in
	// particular is what the Mac sends when a hold-off has been mishandled
	// (TashTwenty's author, 68kMLA, 2026). So a stored $19/$1A ack yields to
	// any later event, and every other entry still keeps the first.
	wire       dcd_unans_isack = (dcd_cstate == 3'd4) && (dcd_op_at_rx != 8'h03);
	wire       dcd_unans_newok = dcd_unans_isack &&
	                             ((dcd_op_at_rx == 8'h19) || (dcd_op_at_rx == 8'h1a));
	wire       dcd_unans_oldok = (dcd_unans_why == 2'd3) &&
	                             ((dcd_unans_op == 8'h19) || (dcd_unans_op == 8'h1a));
	wire       dcd_unans_take  = (dcd_unans_cnt == 2'd0) ||
	                             (dcd_unans_oldok && !dcd_unans_newok);
	reg        dcd_rxv_d       = 0;
	reg  [7:0] dcd_op_at_rx    = 0;
	reg  [2:0] dcd_cst_at_rx   = 0;

	always @(posedge clk) begin
		dcd_rxhs_d    <= dcd_rxhs;
		dcd_txstate_d <= dcd_txstate;
		dcd_txbyte_d  <= dcd_txbyte;
		dcd_rxv_d     <= dcd_rxvalid;
		dcd_op_at_rx  <= dcd_opcode;
		dcd_cst_at_rx <= dcd_cstate;

		if (dcd_clr) begin
			dcd_states_seen <= 8'd0;
			dcd_last_op     <= 8'd0;
			dcd_frames_in   <= 2'd0;
			dcd_st_bad      <= 1'b0;
			dcd_st_abort    <= 1'b0;
			dcd_bytes_in    <= 6'd0;
			dcd_bytes_out   <= 8'd0;
			dcd_txmax       <= 3'd0;
			dcd_rxhs_max    <= 3'd0;
			dcd_unans_op    <= 8'd0;
			dcd_unans_cnt   <= 2'd0;
			dcd_unans_why   <= 2'd0;
			dcd_ab_send     <= 1'b0;
			dcd_ab_state    <= 3'd0;
			dcd_ab_sel      <= 1'b0;
			dcd_gap_cnt     <= 12'd0;
			dcd_gap_long    <= 3'd0;
		end
		else begin
			// State 5 is the discriminator that says a DCD and not a Sony
			// answered, so "did the Mac ever drive it" is the identification
			// question stated as one bit. The intermediate values it passes
			// through on the way are recorded too and are not noise -- the Mac
			// changes one phase line at a time, so their presence is what says
			// it was walking the ID states rather than sitting still.
			if (dcd_sel) dcd_states_seen[dcd_state] <= 1'b1;

			if (dcd_rxvalid) begin
				dcd_last_op <= dcd_opcode;
				if (~&dcd_frames_in) dcd_frames_in <= dcd_frames_in + 2'd1;
			end
			if (dcd_rxbad) dcd_st_bad <= 1'b1;

			// TX_WAIT (1) falling back to TX_IDLE (0) is the escape added in
			// abd857c for a transfer the Mac walked away from; it is the one
			// path in the link layer that has never run on hardware, so it
			// gets its own bit rather than being inferred from txmax.
			if (dcd_txstate == 3'd0 && dcd_txstate_d == 3'd1) dcd_st_abort <= 1'b1;

			// The mid-frame escape. dcd_state is sampled a clock after the
			// transition; the phase lines are held far longer than that by
			// the Mac, so it is the state that caused it.
			if (dcd_txstate == 3'd0 &&
			    (dcd_txstate_d == 3'd3 || dcd_txstate_d == 3'd4)) begin
				dcd_ab_send  <= 1'b1;
				dcd_ab_state <= dcd_state;
				dcd_ab_sel   <= dcd_sel;
			end

			// Inter-byte pacing, measured only while a frame is going out so
			// idle time between commands cannot register as a stall.
			if (dcd_txstate == 3'd2 || dcd_txstate == 3'd3 || dcd_txstate == 3'd4) begin
				if (dcd_txbyte && !dcd_txbyte_d) begin
					if (dcd_gap_cnt > 12'd1024 && ~&dcd_gap_long)
						dcd_gap_long <= dcd_gap_long + 3'd1;
					dcd_gap_cnt <= 12'd0;
				end
				else if (~&dcd_gap_cnt) dcd_gap_cnt <= dcd_gap_cnt + 12'd1;
			end
			else dcd_gap_cnt <= 12'd0;

			// The inbound event is the IWM's one-clock writeReq. The outbound
			// one is dcd_link's newByteReady, which is HELD from one cen tick
			// to the next so iwm.v's cen-gated latch can see it -- four clk at
			// 32 MHz -- so it has to be counted on its edge, not its level.
			// Counted as a level it read four bytes per byte.
			if (dcd_rxbyte && ~&dcd_bytes_in)  dcd_bytes_in  <= dcd_bytes_in  + 6'd1;
			if (dcd_txbyte && !dcd_txbyte_d && ~&dcd_bytes_out)
				dcd_bytes_out <= dcd_bytes_out + 8'd1;

			// Both FSMs advance monotonically through one exchange, so the
			// high-water mark says how far it got without needing a ring:
			// txState 1 = asked for the bus and waited, 2 = sent the sync,
			// 3 = sent data, 5 = finished. rxHs 2 = /HSHK asserted for a
			// receive, 3 = the Mac reached data mode, 4 = it took the reply.
			if (dcd_txstate > dcd_txmax)  dcd_txmax    <= dcd_txstate;
			if (dcd_rxhs    > dcd_rxhs_max) dcd_rxhs_max <= dcd_rxhs;

			// rxHs rather than the raw phase lines, because rxHs is already
			// the debounced reading of them: a ring of raw states would fill
			// with the one-line-at-a-time intermediates and show nothing.
			// dcd_cst_at_rx is cstate as it was WHEN the command landed;
			// dcd_cstate here is cstate one clock later, i.e. after the edge
			// that would have dispatched it.
			if (dcd_rxv_d) begin
				if (dcd_cst_at_rx != 3'd0) begin
					if (dcd_unans_take) begin
						dcd_unans_op  <= dcd_op_at_rx;
						dcd_unans_why <= 2'd2;
					end
					if (~&dcd_unans_cnt) dcd_unans_cnt <= dcd_unans_cnt + 2'd1;
				end
				else if (dcd_cstate == 3'd0) begin
					if (dcd_unans_take) begin
						dcd_unans_op  <= dcd_op_at_rx;
						dcd_unans_why <= 2'd1;
					end
					if (~&dcd_unans_cnt) dcd_unans_cnt <= dcd_unans_cnt + 2'd1;
				end
				else if (dcd_unans_isack) begin
					if (dcd_unans_take) begin
						dcd_unans_op  <= dcd_op_at_rx;
						dcd_unans_why <= 2'd3;
					end
					if (~&dcd_unans_cnt) dcd_unans_cnt <= dcd_unans_cnt + 2'd1;
				end
			end
		end
	end

	// PDCD packing, mirrored in scripts/read_probes.tcl and sim/tb_dbg_probes.v:
	//   [31:24] states the Mac drove (bit n = state n)
	//   [23]    a reply was aborted out of TX_DATA/TX_LSB
	//   [22:20] the state the Mac drove at that abort   [19] selected there
	//   [18:16] inter-byte gaps over 1024 clk (saturating)
	//   (this field WAS dcd_last_op, which its own comment records as always
	//    the $00 of an ordinary read -- it carried no signal and the deck is
	//    at the hub-node ceiling, so a new field has to come out of an old one)
	//   [15:13] rxHs now    [12:10] txState now    [9:7] command FSM now
	//   [6]     /HSHK now (1 = de-asserted)
	//   [5]     present     [4]     selected now
	//   [3:2]   commands decoded (saturating at 3)
	//   [1]     a bad checksum was seen   [0] a reply was abandoned in TX_WAIT
	reg [31:0] pdcd_r, pdc2_r;
	always @(posedge clk) begin
		pdcd_r <= {dcd_states_seen,
		           dcd_ab_send, dcd_ab_state, dcd_ab_sel, dcd_gap_long,
		           dcd_rxhs, dcd_txstate, dcd_cstate,
		           dcd_hshk_n, dcd_present, dcd_sel,
		           dcd_frames_in, dcd_st_bad, dcd_st_abort};
		// PDC2:
		//   [31:24] bytes sent to the Mac (sat 255)
		//   [23:18] bytes taken from the Mac (sat 63 -- a command frame is 11)
		//   [17:15] highest txState reached  [14:12] highest rxHs reached
		//   [11:4]  opcode of the FIRST command received and not answered
		//   [3:2]   how many such commands (saturating at 3)
		//   [1:0]   why: 1 = not dispatched from C_IDLE, 2 = arrived busy
		//
		// These twelve bits were the last-4-rxHs ring. It read IDLE ARMED
		// IDLE DONE in every capture taken, healthy and crashed alike, so it
		// was carrying no signal, and the deck is at MacLC's ~20 hub-node
		// ceiling -- a new instance would corrupt the whole name table, so a
		// new field has to come out of an old one.
		pdc2_r <= {dcd_bytes_out, dcd_bytes_in,
		           dcd_txmax, dcd_rxhs_max,
		           dcd_unans_op, dcd_unans_cnt, dcd_unans_why};
	end

	// ---- which bitstream is this? -----------------------------------------
	// rtl/build_tag.v is regenerated from the git SHA before every compile, so
	// a capture names the build it came from. Two RTL fixes once produced
	// identical captures and there was no way to tell whether the second had
	// actually been loaded onto the board.
	wire [31:0] build_tag_w;
	build_tag build_tag_inst(.tag(build_tag_w));

	// ---- probe instances ---------------------------------------------------
	altsource_probe #(
		.instance_id ("PIFA"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pifa (.probe(pifa_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PACT"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pact (.probe(as_cycles), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PSCS"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pscs (.probe(pscs_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PSCW"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pscw (.probe(pscw_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PODR"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_podr (.probe(odr_hist), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIFD"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pifd (.probe(pifd_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PRG0"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_prg0 (.probe(acc_hist[31:0]),   .source(), .source_clk(clk), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PRG1"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_prg1 (.probe(acc_hist[63:32]),  .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIOS"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pios (.probe(pios_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIO2"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pio2 (.probe(pio2_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIO3"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pio3 (.probe(pio3_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIO4"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pio4 (.probe(pio4_r), .source(), .source_clk(clk), .source_ena(1'b1));

	// 19th instance. MacLC notes a ~20 ceiling above which the name table reads
	// back corrupted, so this is close to the last one that can be added
	// without pruning something first.
	altsource_probe #(
		.instance_id ("PHLD"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_phld (.probe(phld_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PDMA"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pdma (.probe(pdma_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PDM2"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pdm2 (.probe(pdm2_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PDM3"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pdm3 (.probe(pdm3_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PFLP"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pflp (.probe(dbg_floppy), .source(), .source_clk(clk), .source_ena(1'b1));

	// The only probe in the deck whose SOURCE is connected: PDCD's clear. Hold
	// it high to zero every sticky bit and counter in the DCD block, drop it to
	// arm, then provoke the failure. Without it the deck is readable once per
	// power cycle, which is no use at all for a fault that has to be triggered
	// deliberately from HD Diag.
	altsource_probe #(
		.instance_id ("PDCD"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pdcd (.probe(pdcd_r), .source(dcd_clr_src), .source_clk(clk), .source_ena(1'b1));

	// 20th instance, which is the ceiling noted at the top -- nothing further
	// can be added without pruning something else first.
	altsource_probe #(
		.instance_id ("PDC2"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pdc2 (.probe(pdc2_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PBLD"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pbld (.probe(build_tag_w), .source(), .source_clk(clk), .source_ena(1'b1));

endmodule
