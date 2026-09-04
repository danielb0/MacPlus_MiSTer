`timescale 1ns/1ps
//
// tb_scsi_absence.v - MAC128K_PLAN.md Phase 4 gate (items 9 and 5).
//
// Compile: iverilog -g2012 -I rtl -y rtl -o sim/out/SCSI_ABSENCE.vvp sim/tb_scsi_absence.v
//
// What this tests, and why it is written this way.
//
// The Plus ROM does not discover SCSI with a bus error. It reads $420000 and
// $440000 and compares them (ROM $4003E4), and stores the answer in $0B22 bit
// 7, which then gates every later SCSI access including the boot search's
// drive-queue walk at $407D40:
//
//     move.l  $420000.l, d0
//     cmp.l   $440000.l, d0
//     beq     ...              ; SAME  -> no SCSI
//     move.b  #$C0, $0B22.w    ; DIFFER -> SCSI present
//
// So "does this model have SCSI" is decided by whether those two addresses
// return the same WORD, and that is the property asserted here -- not the
// decoder condition that happens to implement it. A future rewrite of
// addrDecoder.v is free to reach the same answer differently; this bench only
// cares that the machine gives the ROM the answer its real counterpart gave.
//
// That is also why the whole addrController_top is instantiated rather than
// addrDecoder alone. selectROM is only half the mechanism: macAddr[17] is
// forced to 0 for a 128K-ROM access (addrController_top.v:225), so the two
// probes land on the same ROM word only if BOTH the decode and the masking
// agree. Testing the decoder by itself would pass while the CPU still read two
// different words -- the seam, exactly as sim/tb_sdram_map.v found for the
// region map.
//
// The four models are asserted against what the real machines did:
//
//   Plus  - has SCSI. ROM does not decode at A17=1, so $420000 is open bus.
//   SE    - has SCSI. Whole window decodes, but its ROM is 256K, so A17 is a
//           real ROM address bit and the two probes differ in CONTENT.
//   512Ke - NO SCSI, and it runs the same 128K ROM as the Plus, so the mirror
//           is the only thing that can tell them apart. This is the row the
//           phase exists for.
//   512K  - NO SCSI (1984 machine; no Mac had SCSI).
//   128K  - NO SCSI.
//
module tb_scsi_absence;

	localparam [2:0] MODEL_PLUS  = 3'd0;
	localparam [2:0] MODEL_SE    = 3'd1;
	localparam [2:0] MODEL_512K  = 3'd2;
	localparam [2:0] MODEL_128K  = 3'd3;
	localparam [2:0] MODEL_512KE = 3'd4;

	// The two addresses the Plus ROM actually compares.
	localparam [23:0] PROBE_A17_1 = 24'h420000;
	localparam [23:0] PROBE_A17_0 = 24'h440000;
	localparam [23:0] SCSI_BASE   = 24'h580000;

	integer tests = 0;
	integer fails = 0;

	task ok;
		input [8*64:1] name;
		input          cond;
		begin
			tests = tests + 1;
			if (cond) $display("PASS: %0s", name);
			else begin $display("FAIL: %0s", name); fails = fails + 1; end
		end
	endtask

	reg clk = 0;
	always #5 clk = ~clk;

	// addrController_top has no reset port -- on hardware Quartus powers its
	// bus-phase counters up at 0, but in simulation they stay X forever
	// (busPhase <= busPhase + 1 from X is X), which makes cpuBusControl X and
	// addrMux X. Seed them here. Anything that leaves this out reads memoryAddr
	// as xxxxxx and every address comparison below silently succeeds against
	// another X, which is worse than failing.
	// Seeded from the stimulus block below rather than from an initial block of
	// its own: two initial blocks both starting at t=0 race, and the loser
	// leaves the first probe sampling an X bus cycle.
	task seed_bus_counters;
		begin
			ac.busPhase           = 2'd0;
			ac.busCycle           = 2'd0;
			ac.extra_slot_count   = 2'd0;
			ac.audioAddr          = 22'd0;
			ac.snd_div            = 18'd0;
			// These three feed the extra-slot arbiter, and an X here reaches
			// memoryAddr through the dskReadAck/dskLoadGrant mux rather than
			// through macAddr -- which is why it first showed up as a lone X
			// in bits 21:20, the only bits where those two branches differ.
			ac.extra_slot_advance = 1'b0;
			ac.dskLoadReqIntR     = 1'b0;
			ac.dskLoadReqExtR     = 1'b0;
		end
	endtask

	// ---- device under test -------------------------------------------------

	reg  [2:0] model   = MODEL_PLUS;
	reg        mem_big = 1'b0;

	wire [1:0] configROMSize, configRAMSize, romSlot;
	wire       machineType, drive800k, scsiPresent;

	mac_model mm
	(
		.model         ( model         ),
		.mem_big       ( mem_big       ),
		.configROMSize ( configROMSize ),
		.configRAMSize ( configRAMSize ),
		.machineType   ( machineType   ),
		.romSlot       ( romSlot       ),
		.drive800k     ( drive800k     ),
		.scsiPresent   ( scsiPresent   )
	);

	reg  [23:0] cpuAddr = 24'h400000;
	wire [21:0] memoryAddr;
	wire        cpuBusControl;
	wire        selectROM, selectSCSI, selectSCC, selectIWM, selectVIA;
	wire        selectRAM, selectSEOverlay;

	addrController_top ac
	(
		.clk             ( clk           ),
		.clk8            (), .clk8_en_p (), .clk8_en_n (),
		.clk16_en_p      (), .clk16_en_n (),

		.turbo           ( 1'b0          ),
		.configROMSize   ( configROMSize ),
		.configRAMSize   ( configRAMSize ),
		.scsiPresent     ( scsiPresent   ),

		.cpuAddr         ( cpuAddr       ),
		._cpuUDS         ( 1'b0          ),
		._cpuLDS         ( 1'b0          ),
		._cpuRW          ( 1'b1          ),
		._cpuAS          ( 1'b0          ),

		.memoryAddr      ( memoryAddr    ),
		._memoryUDS      (), ._memoryLDS (),
		._romOE          (), ._ramOE     (), ._ramWE (),
		.videoBusControl (),
		.dioBusControl   (),
		.cpuBusControl   ( cpuBusControl ),
		.memoryLatch     (),

		.selectSCSI      ( selectSCSI      ),
		.selectSCC       ( selectSCC       ),
		.selectIWM       ( selectIWM       ),
		.selectVIA       ( selectVIA       ),
		.selectRAM       ( selectRAM       ),
		.selectROM       ( selectROM       ),
		.selectSEOverlay ( selectSEOverlay ),

		.hsync           (), .vsync (), ._hblank (), ._vblank (),
		.loadPixels      (),
		.vid_alt         ( 1'b0 ),
		.snd_alt         ( 1'b0 ),
		.loadSound       (),
		.snd_advance     (),

		.memoryOverlayOn ( 1'b0 ),

		.dskReadAddrInt  ( 22'd0 ), .dskReadAckInt (),
		.dskReadAddrExt  ( 22'd0 ), .dskReadAckExt (),

		.dskLoadAddrInt  ( 22'd0 ), .dskLoadReqInt ( 1'b0 ), .dskLoadAckInt (),
		.dskLoadAddrExt  ( 22'd0 ), .dskLoadReqExt ( 1'b0 ), .dskLoadAckExt (),
		.dskLoadWrEn     (), .dskLoadSelExt ()
	);

	// ---- probing -----------------------------------------------------------
	//
	// macAddr's A17 forcing is qualified by rom_access = cpuBusControl &&
	// selectROM, so a sample taken outside the CPU's bus slot would read the
	// UNFORCED address and the two probes would spuriously differ.
	//
	// The settle (#1) must come BEFORE the test, not after it. cpuBusControl
	// is combinational from busCycle, which is updated by a nonblocking
	// assignment, so reading it at `@(posedge clk)` returns the PREVIOUS bus
	// cycle. Testing there and settling afterwards exits the loop on a stale
	// true and then samples one cycle later -- often the video slot, where
	// addrMux takes videoAddr and videoTimer's unreset registers put X into
	// memoryAddr. That is the house `@(posedge clk); #1;` foot-gun, and it
	// cost a debugging round here before the X was traced.
	reg        p_rom;
	reg [21:0] p_addr;

	task probe;
		input [23:0] a;
		begin
			cpuAddr = a;
			@(posedge clk); #1;
			while (!cpuBusControl) begin
				@(posedge clk); #1;
			end
			p_rom  = selectROM;
			p_addr = memoryAddr;
		end
	endtask

	// Result of the ROM's own test for the currently selected model.
	reg        rom1, rom0;
	reg [21:0] addr1, addr0;
	reg        scsi_sel;

	task run_model;
		input [2:0] m;
		begin
			// mac_model.v is `always @(*)`, which iverilog evaluates only on an
			// EVENT -- not once at time 0. Assigning `model` a value it already
			// holds therefore leaves every strap at X, and an X configROMSize
			// silently poisons macAddr[18] through `configROMSize != 2'b11`
			// (Verilog != returns x whenever either operand has an x, even when
			// another bit already differs). The reads then compare X against X
			// and the bench reports nonsense. Force a transition every time.
			model = 3'd7;   // reserved encoding; straps fall back to Plus
			#1;
			model = m;
			#1;
			probe(PROBE_A17_1); rom1 = p_rom; addr1 = p_addr;
			probe(PROBE_A17_0); rom0 = p_rom; addr0 = p_addr;
			probe(SCSI_BASE);   scsi_sel = selectSCSI;
			$display("  [model %0d] $420000: rom=%b addr=%06x | $440000: rom=%b addr=%06x | selectSCSI=%b",
			         m, rom1, addr1, rom0, addr0, scsi_sel);
		end
	endtask

	// The ROM concludes "no SCSI" exactly when both probes return the same
	// word. Both must decode to ROM, and both must resolve to the same ROM
	// address; anything else and the compare at $4003EA sees a difference.
	function reads_identical;
		input        r1, r0;
		input [21:0] a1, a0;
		begin
			reads_identical = r1 && r0 && (a1 == a0);
		end
	endfunction

	initial begin
		seed_bus_counters();
		$display("== tb_scsi_absence: does each model give the Plus ROM the right answer? ==");

		// The seeding initial block above races this one at t=0. Let the bus
		// counters run a full four-phase cycle before the first probe, or that
		// probe alone reads X in macAddr[21:20].
		repeat (8) @(posedge clk);

		// ---- Plus: has SCSI -------------------------------------------------
		run_model(MODEL_PLUS);
		ok("Plus: the two ROM probes do NOT read alike (SCSI detected)",
		   !reads_identical(rom1, rom0, addr1, addr0));
		ok("Plus: $420000 (A17=1) is not ROM",  !rom1);
		ok("Plus: $440000 (A17=0) is ROM",       rom0);
		ok("Plus: $440000 masks to ROM offset 0", addr0 == 22'h000000);
		ok("Plus: SCSI window decodes",           scsi_sel);

		// ---- SE: has SCSI, by content not by decode -------------------------
		run_model(MODEL_SE);
		ok("SE: the two ROM probes do NOT read alike (SCSI detected)",
		   !reads_identical(rom1, rom0, addr1, addr0));
		ok("SE: both probes decode as ROM",       rom1 && rom0);
		ok("SE: 256K ROM makes A17 a real address bit", addr1 != addr0);
		ok("SE: SCSI window decodes",             scsi_sel);

		// ---- 512Ke: NO SCSI, same ROM as the Plus ---------------------------
		run_model(MODEL_512KE);
		ok("512Ke: the two ROM probes read ALIKE (no SCSI)",
		   reads_identical(rom1, rom0, addr1, addr0));
		ok("512Ke: $420000 mirrors to ROM offset 0", rom1 && (addr1 == 22'h000000));
		ok("512Ke: SCSI window does NOT decode",   !scsi_sel);

		// ---- 512K and 128K: NO SCSI ----------------------------------------
		run_model(MODEL_512K);
		ok("512K: the two ROM probes read ALIKE (no SCSI)",
		   reads_identical(rom1, rom0, addr1, addr0));
		ok("512K: SCSI window does NOT decode",    !scsi_sel);

		run_model(MODEL_128K);
		ok("128K: the two ROM probes read ALIKE (no SCSI)",
		   reads_identical(rom1, rom0, addr1, addr0));
		ok("128K: SCSI window does NOT decode",    !scsi_sel);

		// ---- neighbours must not move --------------------------------------
		//
		// The change is one term in one decode branch, but that branch shares
		// a casez with every other peripheral. These are cheap and would catch
		// a mis-edited case item.
		run_model(MODEL_512KE);
		probe(24'h900000); ok("512Ke: SCC still decodes at $900000", selectSCC);
		probe(24'hD00000); ok("512Ke: IWM still decodes at $D00000", selectIWM);
		probe(24'hE80000); ok("512Ke: VIA still decodes at $E80000", selectVIA);
		probe(24'h000000); ok("512Ke: RAM still decodes at $000000", selectRAM);

		run_model(MODEL_PLUS);
		probe(24'h900000); ok("Plus: SCC still decodes at $900000",  selectSCC);
		probe(24'hD00000); ok("Plus: IWM still decodes at $D00000",  selectIWM);
		probe(24'hE80000); ok("Plus: VIA still decodes at $E80000",  selectVIA);
		probe(24'h000000); ok("Plus: RAM still decodes at $000000",  selectRAM);

		$display("== %0d tests, %0d failures ==", tests, fails);
		if (fails != 0) $display("RESULT: FAIL");
		else            $display("RESULT: PASS");
		$finish;
	end

endmodule
