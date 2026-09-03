//
// sdram_map.vh -- the SDRAM region map, in one place.
//
// MAC128K_PLAN.md Phase 3 fix. Every region the core carves out of SDRAM is
// declared here, in WORD units as sdram.v sees them, and consumed by name
// from MacPlus.sv (the sdram_addr mux) and rtl/addrController_top.v (the
// per-image byte offsets). sim/tb_sdram_map.v gates the one property that
// matters and that nothing previously checked: the regions are DISJOINT.
//
// This file exists because they were not. Phase 2 widened boot-ROM delivery
// from two 512KB slots to four without anything recording what sat directly
// above slot 1 -- and what sat there was the internal floppy image. The old
// map was exactly, precisely full:
//
//   words 0x200000-0x27FFFF   ROM slots 0 and 1      (2 x 512KB = 1MB)
//   words 0x280000-...        internal floppy image  (extra region + 1MB)
//
// so slot 2's base (0x200000 + 2<<18 = 0x280000) came out bit-identical to
// the internal floppy image's base. Not a partial overlap -- an exact alias.
// Mounting any internal floppy overwrote boot2.rom, so the 128K and 512K
// fetched their reset SP/PC from the first bytes of the disk image, took a
// double address error and halted the 68000 outright. Which is exactly the
// frozen-PACT/PIFA signature JTAG saw, and exactly why BOTH 64K ROM images
// failed identically: the ROM content was never the variable.
//
// The Plus and SE were unaffected throughout -- slots 0 and 1 still sit
// below the disk area -- which is why the bug read as "the new models are
// broken" rather than "the address map is full".
//
// ROM now has its own region in the upper half of the addressable space
// instead of subletting the first megabyte of the disk region. sdram.v
// decodes addr[22:0] (4 banks x 4096 rows x 512 cols = 8M words = 16MB) and
// everything previously in use had addr[22] = 0, so that whole upper half
// was free. The disk windows keep their existing addresses, so nothing in
// floppy_loader.v, floppy_write_committer.v or the addrController arbiter
// changes.
//
// Two cautions for whoever widens this next:
//
//   - MacPlus.sv drives a 25-bit sdram_addr into sdram.v's 24-bit `addr`
//     port, so bit 24 is silently dropped, and sdram.v ignores bit 23. Only
//     bits [22:0] reach the chip. Keep every base inside SDRAM_USABLE_WORDS.
//   - The bases are added to their payloads rather than concatenated. That
//     is exact only because each base's low bits are zero below the payload
//     width, so no add ever carries; Quartus folds them back to wiring.
//     Check that still holds if you move a base.
//
`ifndef SDRAM_MAP_VH
`define SDRAM_MAP_VH

// Addressable space. sdram.v takes addr[23:0] but decodes only addr[22:0]:
// bank = addr[21:20], row = addr[19:8], column = {addr[22], addr[7:0]}.
// 8M words = 16MB, well inside the 32MB minimum MiSTer SDRAM module.
`define SDRAM_USABLE_WORDS 25'h0800000

// Mac RAM, mapped straight into the 68000's address space. 4MB max.
`define SDRAM_RAM_BASE     25'h0000000
`define SDRAM_RAM_WORDS    25'h0200000

// Floppy image staging, historically "extra rom". addrController_top.v adds
// the per-image byte offsets below to produce a word address in here.
`define SDRAM_DISK_BASE    25'h0200000

// Boot ROMs: four 512KB slots, one per Main_MiSTer boot ROM (boot0..boot3 --
// its loader loop is `i < 4`, so four is its own ceiling). rom_word_addr.v
// places slot N at N << 18 words within this region.
`define SDRAM_ROM_BASE     25'h0400000
`define SDRAM_ROM_SLOTS    4
`define SDRAM_ROM_SLOT_WORDS 25'h0040000

// Byte offsets of each floppy image within the disk region, as used by
// addrController_top.v's memoryAddr mux. A word address is base + off/2.
`define DSK_INT_BYTE_OFF   22'h100000
`define DSK_EXT_BYTE_OFF   22'h200000

// Largest image either drive accepts: 819200 bytes (800K double-sided).
// MacPlus.sv refuses anything that is neither this nor 409600.
`define DSK_IMAGE_MAX_BYTES 25'h00C8000

`endif
