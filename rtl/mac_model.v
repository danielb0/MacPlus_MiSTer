//
// mac_model.v -- map the OSD model selection onto the hardware straps.
//
// MAC128K_PLAN.md Phase 1. One place where "which Macintosh is this" becomes
// the handful of signals the rest of the core actually consumes, so that
// adding a model is a table entry rather than a hunt through MacPlus.sv.
//
// Before this existed the choice was a single bit, `status_mod`, wired
// straight to four unrelated consumers:
//
//   configROMSize   addrController_top -- how much of the ROM window decodes
//   configRAMSize   addrController_top -- how much of the RAM window decodes
//   machineType     dataController_top -- Plus vs SE BEHAVIOUR, see below
//   romSlot         MacPlus.sv         -- which downloaded ROM image to read
//
// `machineType` is the one to be careful with, and the reason this module
// exists rather than a wider `status_mod`. It is NOT a model index: it is a
// Plus-vs-SE boolean, and dataController_top hangs eight behavioural
// differences off it -- the sound buffer (`snd_alt`), drive select, the
// memory-overlay mechanism, VIA port B wiring, and the keyboard, which is a
// wholly different protocol on the SE (ADB) from the Plus. Every pre-Plus
// model therefore wants machineType = 0, not its own model number. A 128K
// handed machineType = 1 would get ADB keyboard timing and never see a
// keypress.
//
// RAM size is DERIVED, not chosen, for the machines that had it soldered
// down. The 128K, 512K and 512Ke were not expandable, so offering them a
// memory option would invent a configuration that never existed. Only the
// Plus and SE, which had SIMM sockets, honour `mem_big`.
//
// The 64K-ROM models (Macintosh 128K and 512K) are deliberately absent here.
// They need the third ROM slot from Phase 2; encoding them now would point
// them at slot 0, which holds the Plus 128K image, and they would run the
// wrong ROM. They arrive with Phase 3.
//
module mac_model
(
	// Latched at reset by MacPlus.sv -- changing model mid-run is not a thing.
	input      [2:0] model,
	input            mem_big,       // OSD Memory, Plus/SE only: 0 = 1MB, 1 = 4MB

	output reg [1:0] configROMSize, // 0 = 64K, 1 = 128K, 2 = 256K, 3 = 512K
	output reg [1:0] configRAMSize, // 0 = 128K, 1 = 512K, 2 = 1MB, 3 = 4MB
	output reg       machineType,   // 0 = Plus-like, 1 = SE
	output reg       romSlot        // which 512KB ROM window to read from
);

	// Model 0 MUST be the Plus. `status` defaults to zero, and the core's
	// long-standing default is a Plus, so a fresh or reset config must not
	// silently become some other machine.
	localparam [2:0] MODEL_PLUS  = 3'd0;
	localparam [2:0] MODEL_SE    = 3'd1;
	localparam [2:0] MODEL_512KE = 3'd2;

	always @(*) begin
		case (model)
			MODEL_SE: begin
				configROMSize = 2'b10;                    // 256K, releases/boot1.rom
				configRAMSize = mem_big ? 2'b11 : 2'b10;  // 4MB / 1MB
				machineType   = 1'b1;
				romSlot       = 1'b1;
			end

			// A 512Ke is a Plus with 512K soldered in and no SCSI. It shipped
			// the same 128K ROM, so it needs no new image -- only the RAM
			// strap. SCSI absence is Phase 4; until then this model is a Plus
			// with less memory, which is why MacPlus.sv does not yet offer it
			// in the OSD.
			MODEL_512KE: begin
				configROMSize = 2'b01;                    // same 128K ROM as the Plus
				configRAMSize = 2'b01;                    // 512K, soldered
				machineType   = 1'b0;
				romSlot       = 1'b0;
			end

			// MODEL_PLUS, and every reserved encoding. Falling back to the
			// Plus rather than latching an undefined strap keeps a stale saved
			// config harmless instead of unbootable.
			default: begin
				configROMSize = 2'b01;                    // 128K, releases/boot0.rom
				configRAMSize = mem_big ? 2'b11 : 2'b10;  // 4MB / 1MB
				machineType   = 1'b0;
				romSlot       = 1'b0;
			end
		endcase
	end

endmodule
