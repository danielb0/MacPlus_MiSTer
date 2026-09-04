// dcd_icon.vh - the 32x32 icon a DCD device publishes in its identity block.
//
// MAC128K_PLAN.md Phase 5. The Status reply carries `Icon` at identity offset
// 64: 128 bytes of image followed by 128 bytes of mask, four bytes per row,
// most significant bit leftmost. The Plus ROM hands the address of that field
// straight to the Finder ($419CC4 `lea $1F0(a1),a2`), and it does so WITHOUT
// testing the Icon_Included bit, so a device that returns zeroes here gets a
// blank icon on the desktop rather than a default one. Something has to be
// drawn.
//
// THIS IS OUR DRAWING, NOT APPLE'S. A real HD20 serves its icon out of the Z8
// controller's internal ROM (341-0339-A), which has never been dumped - the
// 342-0343-B external ROM we do have holds only the ProFile-style
// `DeviceParams` block and no bitmap anywhere in its 8K. So there is no
// authentic bitmap to copy, and copying one of the other emulators' icons
// would be passing off someone else's artwork. This is a plain flat drive box
// with a slot and an activity LED, in the style of the period:
//
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ..############################..
//     ..#..........................#..
//     ..#..........................#..
//     ..############################..
//     ..#..........................#..
//     ..#..........................#..
//     ..#..####################....#..
//     ..#..#..................#.##.#..
//     ..#..#..................#.##.#..
//     ..#..####################....#..
//     ..#..........................#..
//     ..############################..
//     ..############################..
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//     ................................
//
// The mask is the solid silhouette of that box, which is what lets the Finder
// drag and highlight the icon as one shape.
//
// A CASE STATEMENT, AND BY ROW RATHER THAN BY BYTE, for the same reason
// rtl/cd_vol_lut.vh gives: a case guarantees Quartus builds this as logic and
// never as an M10K, and RAM blocks are the scarce resource in this design. By
// row costs 32 entries instead of 256, and only five of the 32 image rows and
// two of the 32 mask rows are distinct, so the minimiser collapses nearly all
// of it.

function [31:0] dcd_icon_row;
	input [4:0] row;
	begin
		case (row)
		5'd8:  dcd_icon_row = 32'h3ffffffc;   // top edge
		5'd9:  dcd_icon_row = 32'h20000004;
		5'd10: dcd_icon_row = 32'h20000004;
		5'd11: dcd_icon_row = 32'h3ffffffc;   // lid seam
		5'd12: dcd_icon_row = 32'h20000004;
		5'd13: dcd_icon_row = 32'h20000004;
		5'd14: dcd_icon_row = 32'h27ffff84;   // slot, top
		5'd15: dcd_icon_row = 32'h240000b4;   // slot sides, and the LED
		5'd16: dcd_icon_row = 32'h240000b4;
		5'd17: dcd_icon_row = 32'h27ffff84;   // slot, bottom
		5'd18: dcd_icon_row = 32'h20000004;
		5'd19: dcd_icon_row = 32'h3ffffffc;   // bottom edge
		5'd20: dcd_icon_row = 32'h3ffffffc;   // and its shadow
		default: dcd_icon_row = 32'h00000000;
		endcase
	end
endfunction

function [31:0] dcd_icon_mask;
	input [4:0] row;
	begin
		case (row)
		5'd8,  5'd9,  5'd10, 5'd11, 5'd12, 5'd13, 5'd14,
		5'd15, 5'd16, 5'd17, 5'd18, 5'd19, 5'd20:
		         dcd_icon_mask = 32'h3ffffffc;
		default: dcd_icon_mask = 32'h00000000;
		endcase
	end
endfunction

// Byte k of the 256-byte Icon field: 0..127 image, 128..255 mask.
function [7:0] dcd_icon_byte;
	input [7:0] k;
	reg [31:0] r;
	begin
		r = k[7] ? dcd_icon_mask(k[6:2]) : dcd_icon_row(k[6:2]);
		case (k[1:0])
		2'd0: dcd_icon_byte = r[31:24];
		2'd1: dcd_icon_byte = r[23:16];
		2'd2: dcd_icon_byte = r[15:8];
		2'd3: dcd_icon_byte = r[7:0];
		endcase
	end
endfunction
