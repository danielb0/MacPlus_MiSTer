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
// Probe deck (5 instances -- deliberately lean; MacLC notes a ~20 hub-node
// ceiling above which the name table reads back corrupted):
//
//   PIFA  instruction-fetch sampler: where is the CPU?
//   PACT  bus-cycle counter: is the CPU alive at all?
//   PSCS  last SCSI register READ  (the poll target + the value it returned)
//   PSCW  last SCSI register WRITE (the register the driver last programmed)
//   PODR  last four bytes written to the data register -- the CDB tail
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

	input  wire        selectSCSI
);

	// ---- bus-cycle edges --------------------------------------------------
	reg as_d;
	always @(posedge clk) as_d <= _cpuAS;
	wire as_fall = as_d & ~_cpuAS;     // address/decode valid
	wire as_rise = ~as_d & _cpuAS;     // data valid, cycle ending

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
				rd_val <= cpuDataIn[15:8];      // SCSI byte rides D15-D8
				rd_sel <= {dack_lat, reg_lat};
			end else begin
				wr_cnt <= wr_cnt + 8'd1;
				wr_val <= cpuDataOut[15:8];
				wr_sel <= {dack_lat, reg_lat};
				// Non-DACK writes to register 0 are the output data register:
				// during COMMAND phase that stream IS the CDB.
				if (!dack_lat && (reg_lat == 3'd0))
					odr_hist <= {odr_hist[23:0], cpuDataOut[15:8]};
			end
		end

	// PSCS: [31:24]=rd_cnt [23:16]=rd_val [15:12]={dack,reg} [7:0]=wr_cnt
	reg [31:0] pscs_r;
	always @(posedge clk) pscs_r <= {rd_cnt, rd_val, rd_sel, 4'd0, wr_cnt};

	// PSCW: [31:24]=wr_cnt [23:16]=wr_val [15:12]={dack,reg} [7:0]=rd_cnt
	reg [31:0] pscw_r;
	always @(posedge clk) pscw_r <= {wr_cnt, wr_val, wr_sel, 4'd0, rd_cnt};

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

endmodule
