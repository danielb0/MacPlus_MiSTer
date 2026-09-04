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
// Model numbering is NOT "however the machines were announced" -- it is
// "however many are exposed in the OSD list right now", because MacPlus.sv's
// CONF_STR lists model names positionally and MiSTer's OSD parser has no
// established way to leave a numbered gap. MODEL_512KE originally sat at
// value 2 (Plus, SE, 512Ke, 512K, 128K), matching a comment written in Phase
// 1 before this was thought through. It moved to 4 in Phase 3 because the
// 512Ke was not exposed then -- it still had SCSI, which is not an authentic
// 512Ke -- and leaving its label out of the OSD string while its numeric value
// sat in the MIDDLE of the exposed range would have meant either a confusing
// blank OSD row (untested; Main_MiSTer's menu parser was not available to
// check) or renumbering 512K/128K later, which would silently change what a
// saved config boots. Moving the unexposed one instead cost nothing.
//
// Phase 4 then gave the 512Ke its missing SCSI absence (`scsiPresent` below)
// and exposed it, so it is now the fifth and last entry in the CONF_STR list
// -- which is why value 4 was the right place to park it. Anything added next
// takes value 5 and appends to the list.
//
module mac_model
(
	// Latched at reset by MacPlus.sv -- changing model mid-run is not a thing.
	input      [2:0] model,
	input            mem_big,       // OSD Memory, Plus/SE only: 0 = 1MB, 1 = 4MB

	output reg [1:0] configROMSize, // 0 = 64K, 1 = 128K, 2 = 256K, 3 = 512K
	output reg [1:0] configRAMSize, // 0 = 128K, 1 = 512K, 2 = 1MB, 3 = 4MB
	output reg       machineType,   // 0 = Plus-like, 1 = SE
	output reg [1:0] romSlot,       // which bootN.rom to read: MacPlus.sv:1050
	output reg       drive800k,     // 1 = drive can use 800K double-sided media
	// 1 = this machine has a SCSI bus. Consumed by rtl/addrDecoder.v, which
	// uses it TWICE, and the first use is the one that matters:
	//
	//   - When clear, the ROM window MIRRORS at A17 = 1. The Plus ROM decides
	//     whether it has SCSI by reading $420000 and $440000 and comparing them
	//     ($4003E4); equal means no SCSI, and it records that in $0B22 bit 7,
	//     which then gates every later SCSI access including the boot search's
	//     drive-queue walk ($407D40). Mirroring is therefore not a side effect
	//     of "no SCSI" -- it IS how a machine says so, and it is the only thing
	//     that distinguishes a 512Ke from a Plus, since they run the same ROM.
	//   - When clear, $58xxxx also stops decoding. Belt and braces: the ROM
	//     will not go there once the flag is clear, but third-party software
	//     that poked the chip directly should find nothing.
	//
	// The SE needs no special case. Its window already decodes in full
	// (configROMSize[1] = 1), but its ROM is 256K, so A17 is a real ROM address
	// bit and the two probes differ in CONTENT rather than in decode.
	output reg       scsiPresent
);

	// Model 0 MUST be the Plus. `status` defaults to zero, and the core's
	// long-standing default is a Plus, so a fresh or reset config must not
	// silently become some other machine. 3, 4 and up are exposed in the OSD
	// string in the order declared here.
	localparam [2:0] MODEL_PLUS  = 3'd0;
	localparam [2:0] MODEL_SE    = 3'd1;
	localparam [2:0] MODEL_512K  = 3'd2;
	localparam [2:0] MODEL_128K  = 3'd3;
	localparam [2:0] MODEL_512KE = 3'd4; // last entry in the OSD list - see above

	// Slot numbers, not one-hot bits: Main_MiSTer's boot-ROM loader packs the
	// slot as a plain binary count in ioctl_index[7:6] (user_io.cpp:1619,
	// `i << 6` for i = 0..3, confirmed against the Main_MiSTer source, not
	// inferred from file sizes). MacPlus.sv:1050 uses these same values to
	// pick the read-side SDRAM window, so a slot number here IS the boot file
	// number: ROM_SLOT_PLUS reads releases/boot0.rom, and so on.
	localparam [1:0] ROM_SLOT_PLUS = 2'd0; // releases/boot0.rom, 128K
	localparam [1:0] ROM_SLOT_SE   = 2'd1; // releases/boot1.rom, 256K
	localparam [1:0] ROM_SLOT_64K  = 2'd2; // releases/boot2.rom, user's choice of 64K image

	always @(*) begin
		case (model)
			MODEL_SE: begin
				configROMSize = 2'b10;                    // 256K, releases/boot1.rom
				configRAMSize = mem_big ? 2'b11 : 2'b10;  // 4MB / 1MB
				machineType   = 1'b1;
				romSlot       = ROM_SLOT_SE;
				drive800k     = 1'b1;
				scsiPresent   = 1'b1;
			end

			// The 512K and 128K run the 64K ROM in slot 2 (boot2.rom, the
			// user's choice per MAC128K_PLAN.md's "The ROM images exist" --
			// diffed 2026-09-03, the two known 64K images differ by 57 of
			// 65536 bytes and neither touches a memory-map constant, so one
			// slot serves both). RAM is soldered and not the same size as
			// each other, which is the one hardware difference between them.
			// scsiPresent = 0 is accuracy, not correctness, for these two:
			// the 64K ROM has no SCSI Manager and never scans the bus, so it
			// would never have noticed either way. No Mac had SCSI in 1984.
			//
			// drive800k = 0: both shipped with a mechanically single-sided
			// drive -- no head for the second side, not merely a format
			// limit -- so an 800K double-sided image cannot be read, only a
			// 400K single-sided one. MacPlus.sv's dsk_int_ds/dsk_ext_ds
			// gating on this is item 8.
			MODEL_512K: begin
				configROMSize = 2'b00;                    // 64K, releases/boot2.rom
				configRAMSize = 2'b01;                    // 512K, soldered
				machineType   = 1'b0;
				romSlot       = ROM_SLOT_64K;
				drive800k     = 1'b0;
				scsiPresent   = 1'b0;
			end

			MODEL_128K: begin
				configROMSize = 2'b00;                    // 64K, releases/boot2.rom
				configRAMSize = 2'b00;                    // 128K, soldered
				machineType   = 1'b0;
				romSlot       = ROM_SLOT_64K;
				drive800k     = 1'b0;
				scsiPresent   = 1'b0;
			end

			// A 512Ke is a Plus with 512K soldered in and no SCSI. It shipped
			// the same 128K ROM and the same 800K double-sided drive as the
			// Plus, so it needs no new image and no drive restriction -- only
			// the RAM strap and scsiPresent. Those two are the entire model,
			// and scsiPresent is the load-bearing one: without it this is
			// indistinguishable from a Plus with less memory, because the ROM
			// is the same ROM. See the port comment above for how the machine
			// tells its own ROM that it has no SCSI.
			MODEL_512KE: begin
				configROMSize = 2'b01;                    // same 128K ROM as the Plus
				configRAMSize = 2'b01;                    // 512K, soldered
				machineType   = 1'b0;
				romSlot       = ROM_SLOT_PLUS;
				drive800k     = 1'b1;
				scsiPresent   = 1'b0;   // the whole point of the model
			end

			// MODEL_PLUS, and every reserved encoding. Falling back to the
			// Plus rather than latching an undefined strap keeps a stale saved
			// config harmless instead of unbootable.
			default: begin
				configROMSize = 2'b01;                    // 128K, releases/boot0.rom
				configRAMSize = mem_big ? 2'b11 : 2'b10;  // 4MB / 1MB
				machineType   = 1'b0;
				romSlot       = ROM_SLOT_PLUS;
				drive800k     = 1'b1;
				scsiPresent   = 1'b1;
			end
		endcase
	end

endmodule
