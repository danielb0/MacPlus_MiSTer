//
// rom_word_addr.v -- the SDRAM word address for one 512KB boot-ROM slot.
//
// MAC128K_PLAN.md Phase 2. MacPlus.sv uses this on two independent paths:
// the download side decides which slot an incoming byte belongs to, and the
// read side decides which slot the running model reads from. Before this
// module existed, those were two separately written concatenations that
// happened to agree on where the slot number sits in the address. This
// module makes that agreement structural -- both sides instantiate the same
// RTL -- rather than something that only holds as long as nobody edits one
// side without the other. That is the same class of risk mac_model.v exists
// to close for `machineType`.
//
// Confirmed against the Main_MiSTer source, not inferred from file sizes:
// the boot-ROM loader sends slot N as `i << 6` in ioctl_index for i = 0..3
// (user_io.cpp:1619, `user_io_file_tx(mainpath, i << 6)`), and
// user_io_file_tx packs that as ioctl_index[7:6] (user_io.cpp:2724). Four
// slots is Main_MiSTer's own ceiling -- its loader loop is `i < 4` -- so a
// fifth boot ROM needs a change there too, not just here.
//
module rom_word_addr
(
	input      [1:0]  slot,        // which bootN.rom: 0, 1, 2 or 3
	input      [17:0] word_offset, // word address within that 512KB image
	output     [20:0] addr         // word address within the reserved ROM region
);

	assign addr = {1'b0, slot, word_offset};

endmodule
