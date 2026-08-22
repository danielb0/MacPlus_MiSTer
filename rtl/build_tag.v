// build_tag.v -- REGENERATED BEFORE EVERY COMPILE, do not hand-edit.
//
// Written by the compile command as:
//   git rev-parse --short=8 HEAD  ->  the constant below
//
// Why this exists: on 2026-08-22 two different RTL fixes produced byte-for-byte
// identical probe captures, and there was no way to tell from the board whether
// the second build had actually been loaded -- the .rbf is loaded from the build
// directory, so which bitstream is running depends on when the core was last
// loaded, not on when it was compiled. A capture must be able to name its own
// bitstream. Read back on the PBLD probe and printed by read_probes.tcl.
module build_tag(output [31:0] tag);
	assign tag = 32'h13cdd790;
endmodule
