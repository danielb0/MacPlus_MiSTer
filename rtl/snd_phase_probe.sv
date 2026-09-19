// ---------------------------------------------------------------------------
// snd_phase_probe.sv -- where is the sound scan when software fills the buffer?
//
// SOUND_PHASE_PLAN.md. A buffer-filling driver (PoP's MDRV, the ROM's
// free-form driver, the Sound Manager) runs from the VBL interrupt and writes
// the 370-word main sound buffer from a start word S to 369, then 0 to S-1,
// racing the hardware scan. Whether the wrap part overtakes the scan depends
// on ONE number the core has never measured: the scan word the reader is on
// when the driver's first write lands. This block latches, once per frame:
//
//   [8:0]   snd_index at the FIRST CPU write into the main sound buffer
//           (= V + latency in words; 511 if the frame had no write)
//   [17:9]  the buffer WORD that first write hit (= the driver's S)
//   [26:18] snd_index when word 0 was written (the wrap; 511 if never)
//   [31:27] frame counter, so a reader can see the word is live
//
// The word is committed on the vblank edge that ends the frame, so a JTAG
// sample always reads a complete frame. Sound-buffer decode: the main buffer
// is the top of RAM minus $300, so the address is $xxxD00-$xxxFE3 with the
// bits above [11:0] all set within the model's RAM size (configRAMSize:
// 00=128K 01=512K 10=1MB 11=4MB, the encoding rtl/addrController_top.v
// forces its address bits from). The alternate buffer is not watched: PoP
// does not use it, and the point is the main-buffer race.
//
// No Altera primitive here, so benches can elaborate it; MacPlus.sv wires the
// word into rtl/dbg_probes.sv's PSND instance.
// ---------------------------------------------------------------------------
module snd_phase_probe (
	input  wire        clk,
	input  wire        clk8_en_p,
	input  wire        _vblank,
	input  wire  [8:0] snd_index,
	input  wire [23:0] cpuAddr,
	input  wire        _cpuAS,
	input  wire        _cpuRW,
	input  wire  [1:0] configRAMSize,
	output reg  [31:0] dbg = 32'd0
);

	wire [9:0] top_bits = (configRAMSize == 2'b00) ? 10'h01F :
	                      (configRAMSize == 2'b01) ? 10'h07F :
	                      (configRAMSize == 2'b10) ? 10'h0FF : 10'h3FF;
	wire in_buf = (cpuAddr[23:22] == 2'b00) && (cpuAddr[21:12] == top_bits) &&
	              (cpuAddr[11:0] >= 12'hD00) && (cpuAddr[11:0] < 12'hFE4);
	wire [10:0] buf_off  = cpuAddr[11:1] - 11'h680;  // ($D00 >> 1); 0..369 inside the buffer
	wire  [8:0] buf_word = buf_off[8:0];

	// one event per bus cycle: AS falling with RW low
	reg asD = 1'b1;
	wire wr_evt = asD && !_cpuAS && !_cpuRW && in_buf;

	reg vblankD = 1'b1;
	reg       seen_first = 1'b0, seen_wrap = 1'b0;
	reg [8:0] first_idx = 9'h1FF, first_word = 9'h1FF, wrap_idx = 9'h1FF;
	reg [4:0] frames = 5'd0;

	always @(posedge clk) begin
		asD <= _cpuAS;
		if (wr_evt) begin
			if (!seen_first) begin
				seen_first <= 1'b1;
				first_idx  <= snd_index;
				first_word <= buf_word;
			end
			if (!seen_wrap && buf_word == 9'd0) begin
				seen_wrap <= 1'b1;
				wrap_idx  <= snd_index;
			end
		end
		if (clk8_en_p) begin
			vblankD <= _vblank;
			if (vblankD && !_vblank) begin
				dbg        <= {frames, wrap_idx, first_word, first_idx};
				frames     <= frames + 5'd1;
				seen_first <= 1'b0;
				seen_wrap  <= 1'b0;
				first_idx  <= 9'h1FF;
				first_word <= 9'h1FF;
				wrap_idx   <= 9'h1FF;
			end
		end
	end

endmodule
