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
//   PIOS  {rd_stuck, cd_io_lba} -- is an HPS fetch stalled, and for which LBA?
//   PIO2  CD/disk io_rd vs io_ack counts + live handshake bits
//   PRG0-3  ring of the last 8 SCSI register accesses -- the CONVERSATION,
//           not just its last line
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
	input  wire        d0_io_ack
);

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
	always @(posedge clk) pscs_r <= {rd_cnt, rd_val, rd_sel, dack_rd_cnt, wr_cnt};

	// PSCW: [31:24]=wr_cnt [23:16]=wr_val [15:12]={dack,reg} [7:0]=rd_cnt
	reg [31:0] pscw_r;
	always @(posedge clk) pscw_r <= {wr_cnt, wr_val, wr_sel, 4'd0, rd_cnt};

	// ---- PRG0..PRG3: a ring of the last 8 SCSI register accesses -----------
	// PSCS/PSCW hold only the LAST access, which shows the poll but not the
	// conversation that led to it. This keeps the last eight, newest first, so
	// the CDB handover, the arming writes and any status read can be read back
	// as a sequence. Each entry is {rw, dack, reg[2:0], 3'b0, value[7:0]}.
	// A wedged driver polls CSR/BSR thousands of times a second, so recording
	// every access flooded the ring with eight identical poll entries and threw
	// away the history that mattered. Filter plain CSR/BSR reads out: what is
	// left is the CDB handover, the arming writes, and any CDR/DACK read -- the
	// events that say how far the transaction actually got.
	wire acc_is_poll = rw_lat & ~dack_lat &
	                   ((reg_lat == 3'd4) | (reg_lat == 3'd5));
	reg [127:0] acc_hist;
	always @(posedge clk)
		if (as_rise & sel_lat & ~acc_is_poll)
			acc_hist <= {acc_hist[111:0],
			             rw_lat, dack_lat, reg_lat, 3'd0,
			             rw_lat ? din_d[15:8] : dout_d[15:8]};

	// Count DACK reads separately: a pseudo-DMA read consumes a byte with no
	// register write at all, so it is invisible in PSCW. If the driver ever
	// collected a status byte that way, this is the only thing that shows it.
	reg [3:0] dack_rd_cnt;
	always @(posedge clk)
		if (as_rise & sel_lat & rw_lat & dack_lat) dack_rd_cnt <= dack_rd_cnt + 4'd1;

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

	reg [7:0] cd_rd_cnt, cd_ack_cnt, d0_rd_cnt;
	always @(posedge clk) begin
		if (~cd_rd_d  &  cd_io_rd)  cd_rd_cnt  <= cd_rd_cnt  + 8'd1;
		if (~cd_ack_d &  cd_io_ack) cd_ack_cnt <= cd_ack_cnt + 8'd1;
		if (~d0_rd_d  &  d0_io_rd)  d0_rd_cnt  <= d0_rd_cnt  + 8'd1;
	end

	reg [31:0] pios_r, pio2_r;
	always @(posedge clk) begin
		pios_r <= {rd_stuck, cd_io_lba[23:0]};
		pio2_r <= {cd_rd_cnt, cd_ack_cnt, d0_rd_cnt,
		           3'd0, cd_io_rd, cd_io_wr, cd_io_ack, d0_io_rd, d0_io_ack};
	end

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
		.instance_id ("PRG2"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_prg2 (.probe(acc_hist[95:64]),  .source(), .source_clk(clk), .source_ena(1'b1));
	altsource_probe #(
		.instance_id ("PRG3"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_prg3 (.probe(acc_hist[127:96]), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIOS"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pios (.probe(pios_r), .source(), .source_clk(clk), .source_ena(1'b1));

	altsource_probe #(
		.instance_id ("PIO2"), .probe_width (32), .source_width (1),
		.sld_auto_instance_index ("YES")
	) cp_pio2 (.probe(pio2_r), .source(), .source_clk(clk), .source_ena(1'b1));

endmodule
