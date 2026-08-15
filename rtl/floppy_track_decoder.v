/*
 floppy_track_decoder.v

 Phase 2 of FLOPPY_WRITE_PLAN.md: decode a raw GCR data field (the same
 stream floppy_track_encoder.v produces for STATE_DHDR onward) back into
 512 bytes of sector payload, verifying it end to end before it is ever
 handed to a caller.

 Consumes one raw disk byte per `ready` pulse (mirrors floppy_track_encoder.v's
 own pacing convention - see sim/tb_floppy_track_encoder.v's header comment).
 Scans continuously for the D5 AA AD data-field marker (ignoring everything
 else, including the address field's D5 AA 96, whose differing third byte
 never matches), decodes the sector number, verifies the 12-byte DZRO sync
 run, de-nibblizes the 683-byte 6:2 payload back to 512 bytes while running
 the C1/C2/C3 checksum chain in reverse, verifies it against the trailing
 4-byte checksum field, and verifies the DE AA trailer. `sector_valid`
 pulses for exactly one clk if and only if every one of those checks
 passed - never for a partial, corrupt, or truncated field. Any failure
 (bad encoding, bad DZRO run, checksum mismatch, bad trailer) instead
 pulses `reject` and returns to scanning; a field that simply stops
 arriving (truncation) just leaves the decoder waiting, which is the
 correct behaviour - there is no code path that can assert sector_valid
 without having verified the whole field.

 The nibble-recovery arithmetic below is a direct RTL port of the reference
 decoder proved out in Phase 0 (sim/decode_track.py) against this project's
 own RTL encoder dumps: group g's four output bytes recover group (g-1)'s
 three data bytes (a one-group lookback - see decode_track.py's module
 docstring for why), so group 0's bytes are read and discarded, not used.
 The forward/reverse GCR table below was generated mechanically from
 sim/gcr_common.py's REVERSE_SONY_TABLE (itself extracted from
 floppy_track_encoder.v's own table, never hand-transcribed), so it cannot
 silently diverge from what the encoder actually produces.

 The soff/spt geometry math is copied verbatim from floppy_track_encoder.v
 (same track/side/sides inputs) so `addr` lands on exactly the SDRAM byte
 offset the encoder would have read this sector's byte 0 from.
*/

/* verilator lint_off UNUSED */
/* verilator lint_off CASEINCOMPLETE */

module floppy_track_decoder (
   input             clk,
   input             ready,   // one incoming raw disk byte per pulse
   input             rst,

   input             side,
   input             sides,
   input      [6:0]  track,

   input      [7:0]  idata,   // raw byte from the write stream

   // pulses for exactly one clk when a full sector has been decoded and
   // verified - the only time sector/addr/buf_* are meaningful.
   output reg        sector_valid,
   output reg [3:0]  sector,     // decoded sector number, valid with sector_valid
   output reg [21:0] addr,       // SDRAM byte offset of this sector's byte 0

   // pulses for exactly one clk whenever a field is abandoned
   output reg        reject,

   // recovered 512-byte payload from the most recently completed sector,
   // synchronous-address / combinational-read port
   input      [8:0]  buf_addr,
   output     [7:0]  buf_data
);

   // ------------------------------------------------------------------
   // geometry: soff/spt, copied verbatim from floppy_track_encoder.v
   // ------------------------------------------------------------------
   wire [3:0] spt =
      (track[6:4] == 3'd0)?4'd12:
      (track[6:4] == 3'd1)?4'd11:
      (track[6:4] == 3'd2)?4'd10:
      (track[6:4] == 3'd3)?4'd9:
      4'd8;

   wire [9:0] track_times_12 = { track, 3'b000 } + { 1'b0, track, 2'b00 };
   wire [9:0] track_times_11 = { track, 3'b000 } + { 2'b00, track, 1'b0 } + { 3'b000, track };
   wire [9:0] track_times_10 = { track, 3'b000 } + { 2'b00, track, 1'b0 };
   wire [9:0] track_times_9  = { track, 3'b000 } + { 3'b000, track };
   wire [9:0] track_times_8  = { track, 3'b000 };

   wire [6:0] trackm1 = track - 7'd1;
   wire [9:0] soff =
      (track == 0)?10'd0:
      (trackm1[6:4] == 3'd0)?track_times_12:
      (trackm1[6:4] == 3'd1)?(track_times_11 + 10'd16):
      (trackm1[6:4] == 3'd2)?(track_times_10 + 10'd32 + 10'd16):
      (trackm1[6:4] == 3'd3)?(track_times_9 + 10'd48 + 10'd32 + 10'd16):
      (track_times_8 + 10'd64 + 10'd48 + 10'd32 + 10'd16);

   wire [21:0] addr_base =
      { 3'b00, soff, 9'd0 } +
      (sides ? { 3'b00, soff, 9'd0 } : 22'd0) +
      (side  ? { 9'd0, spt, 9'd0 }   : 22'd0) +
      { 9'd0, sector_reg, 9'd0 };

   // ------------------------------------------------------------------
   // reverse GCR table: disk byte -> 6-bit nibble, or invalid.
   // Generated from sim/gcr_common.py's REVERSE_SONY_TABLE - do not
   // hand-edit; regenerate from that script if the encoder's table ever
   // changes.
   // ------------------------------------------------------------------
   function [6:0] rev_lookup; // {valid, nib[5:0]}
      input [7:0] b;
      reg [5:0] nib;
      reg       valid;
      begin
         valid = 1'b1;
         case (b)
         8'h96: nib = 6'h00; 8'h97: nib = 6'h01; 8'h9a: nib = 6'h02; 8'h9b: nib = 6'h03;
         8'h9d: nib = 6'h04; 8'h9e: nib = 6'h05; 8'h9f: nib = 6'h06; 8'ha6: nib = 6'h07;
         8'ha7: nib = 6'h08; 8'hab: nib = 6'h09; 8'hac: nib = 6'h0a; 8'had: nib = 6'h0b;
         8'hae: nib = 6'h0c; 8'haf: nib = 6'h0d; 8'hb2: nib = 6'h0e; 8'hb3: nib = 6'h0f;
         8'hb4: nib = 6'h10; 8'hb5: nib = 6'h11; 8'hb6: nib = 6'h12; 8'hb7: nib = 6'h13;
         8'hb9: nib = 6'h14; 8'hba: nib = 6'h15; 8'hbb: nib = 6'h16; 8'hbc: nib = 6'h17;
         8'hbd: nib = 6'h18; 8'hbe: nib = 6'h19; 8'hbf: nib = 6'h1a; 8'hcb: nib = 6'h1b;
         8'hcd: nib = 6'h1c; 8'hce: nib = 6'h1d; 8'hcf: nib = 6'h1e; 8'hd3: nib = 6'h1f;
         8'hd6: nib = 6'h20; 8'hd7: nib = 6'h21; 8'hd9: nib = 6'h22; 8'hda: nib = 6'h23;
         8'hdb: nib = 6'h24; 8'hdc: nib = 6'h25; 8'hdd: nib = 6'h26; 8'hde: nib = 6'h27;
         8'hdf: nib = 6'h28; 8'he5: nib = 6'h29; 8'he6: nib = 6'h2a; 8'he7: nib = 6'h2b;
         8'he9: nib = 6'h2c; 8'hea: nib = 6'h2d; 8'heb: nib = 6'h2e; 8'hec: nib = 6'h2f;
         8'hed: nib = 6'h30; 8'hee: nib = 6'h31; 8'hef: nib = 6'h32; 8'hf2: nib = 6'h33;
         8'hf3: nib = 6'h34; 8'hf4: nib = 6'h35; 8'hf5: nib = 6'h36; 8'hf6: nib = 6'h37;
         8'hf7: nib = 6'h38; 8'hf9: nib = 6'h39; 8'hfa: nib = 6'h3a; 8'hfb: nib = 6'h3b;
         8'hfc: nib = 6'h3c; 8'hfd: nib = 6'h3d; 8'hfe: nib = 6'h3e; 8'hff: nib = 6'h3f;
         default: begin nib = 6'h00; valid = 1'b0; end
         endcase
         rev_lookup = {valid, nib};
      end
   endfunction

   wire [6:0] rl = rev_lookup(idata);
   wire       nib_valid = rl[6];
   wire [5:0] nib_cur    = rl[5:0];

   // ------------------------------------------------------------------
   // state machine
   // ------------------------------------------------------------------
   localparam S_SCAN = 3'd0;  // hunting for D5 AA AD
   localparam S_SECT = 3'd1;  // 1 byte: sector number
   localparam S_DZRO = 3'd2;  // 12 bytes: must all be the sync-zero byte
   localparam S_GRP  = 3'd3;  // 687 bytes across 172 groups (last partial)
   localparam S_DSUM = 3'd4;  // 4 bytes: checksum
   localparam S_DTRL = 3'd5;  // 2 bytes: DE AA trailer

   reg [2:0]  state;
   reg [23:0] hist;

   reg [3:0]  sector_reg;

   reg [3:0]  dzro_cnt;

   reg [7:0]  group_index;   // 0..171
   reg [1:0]  byte_in_group; // 0..3
   reg [5:0]  grp_byte0, grp_byte1, grp_byte2;

   reg [7:0]  c1, c2, c3;
   reg [9:0]  recovered_count;

   reg [1:0]  dsum_idx;
   reg [5:0]  dsum0, dsum1, dsum2;

   reg        dtrl_idx;

   reg [7:0]  buf_mem [0:511];
   assign buf_data = buf_mem[buf_addr];

   // group-completion combinational helpers (S_GRP only)
   wire has_s3    = (byte_in_group == 2'd3);
   wire grp_done  = has_s3 || (group_index == 8'd171 && byte_in_group == 2'd2);
   wire [5:0] gs2 = has_s3 ? grp_byte2 : nib_cur; // s2: stored, or live on the partial group's completing byte

   wire [1:0] top0 = grp_byte0[5:4];
   wire [1:0] top1 = grp_byte0[3:2];
   wire [1:0] top2_= grp_byte0[1:0];

   wire [7:0] nib_xor_0 = {top0, grp_byte1};
   wire [7:0] rol_c1    = {c1[6:0], c1[7]};
   wire [7:0] nib_in_1  = nib_xor_0 ^ rol_c1;
   wire [8:0] c3_sum    = {1'b0, c3} + {1'b0, nib_in_1} + {8'd0, c1[7]};
   wire       new_c3x   = c3_sum[8];
   wire [7:0] new_c3    = c3_sum[7:0];

   wire [7:0] nib_xor_1 = {top1, gs2};
   wire [7:0] nib_in_2  = nib_xor_1 ^ new_c3;
   wire [8:0] c2_sum    = {1'b0, c2} + {1'b0, nib_in_2} + {8'd0, new_c3x};
   wire       new_c2x   = c2_sum[8];
   wire [7:0] new_c2    = c2_sum[7:0];

   wire [7:0] nib_xor_2 = {top2_, nib_cur}; // only meaningful when has_s3
   wire [7:0] nib_in_3  = nib_xor_2 ^ new_c2;
   wire [7:0] new_c1_full = rol_c1 + nib_in_3 + {7'd0, new_c2x};

   wire [5:0] want_dsum_top = {c3[7:6], c2[7:6], c1[7:6]};

   task do_reject;
      begin
         reject <= 1'b1;
         state  <= S_SCAN;
         hist   <= 24'd0;
      end
   endtask

   always @(posedge clk or posedge rst) begin
      if (rst) begin
         state        <= S_SCAN;
         hist         <= 24'd0;
         sector_valid <= 1'b0;
         reject       <= 1'b0;
         sector       <= 4'd0;
         addr         <= 22'd0;
      end else begin
         sector_valid <= 1'b0;
         reject       <= 1'b0;

         if (ready) begin
            case (state)

            S_SCAN: begin
               hist <= {hist[15:0], idata};
               if ({hist[15:0], idata} == 24'hD5AAAD)
                  state <= S_SECT;
            end

            S_SECT: begin
               if (!nib_valid) do_reject;
               else begin
                  sector_reg <= nib_cur[3:0];
                  state      <= S_DZRO;
                  dzro_cnt   <= 4'd0;
               end
            end

            S_DZRO: begin
               if (idata != 8'h96) do_reject;
               else if (dzro_cnt == 4'd11) begin
                  state           <= S_GRP;
                  group_index     <= 8'd0;
                  byte_in_group   <= 2'd0;
                  c1 <= 8'd0; c2 <= 8'd0; c3 <= 8'd0;
                  recovered_count <= 10'd0;
               end else
                  dzro_cnt <= dzro_cnt + 4'd1;
            end

            S_GRP: begin
               if (!nib_valid) do_reject;
               else begin
                  if (byte_in_group < 2'd3) begin
                     case (byte_in_group)
                     2'd0: grp_byte0 <= nib_cur;
                     2'd1: grp_byte1 <= nib_cur;
                     2'd2: grp_byte2 <= nib_cur;
                     endcase
                  end

                  if (grp_done) begin
                     if (group_index != 8'd0) begin
                        // group 0 is read-and-discarded (see header comment) -
                        // only groups 1..171 actually recover/commit bytes.
                        buf_mem[recovered_count[8:0]]     <= nib_in_1;
                        buf_mem[recovered_count[8:0] + 1] <= nib_in_2;
                        if (has_s3) begin
                           buf_mem[recovered_count[8:0] + 2] <= nib_in_3;
                           recovered_count <= recovered_count + 10'd3;
                           c1 <= new_c1_full;
                        end else begin
                           recovered_count <= recovered_count + 10'd2;
                           c1 <= rol_c1; // last (partial) group: no third byte to add
                        end
                        c2 <= new_c2;
                        c3 <= new_c3;
                     end

                     byte_in_group <= 2'd0;
                     if (group_index == 8'd171) begin
                        state    <= S_DSUM;
                        dsum_idx <= 2'd0;
                     end else
                        group_index <= group_index + 8'd1;
                  end else
                     byte_in_group <= byte_in_group + 2'd1;
               end
            end

            S_DSUM: begin
               if (!nib_valid) do_reject;
               else if (dsum_idx == 2'd3) begin
                  if (dsum0 == want_dsum_top && dsum1 == c3[5:0] &&
                      dsum2 == c2[5:0] && nib_cur == c1[5:0]) begin
                     state    <= S_DTRL;
                     dtrl_idx <= 1'b0;
                  end else
                     do_reject;
               end else begin
                  case (dsum_idx)
                  2'd0: dsum0 <= nib_cur;
                  2'd1: dsum1 <= nib_cur;
                  2'd2: dsum2 <= nib_cur;
                  endcase
                  dsum_idx <= dsum_idx + 2'd1;
               end
            end

            S_DTRL: begin
               if (dtrl_idx == 1'b0) begin
                  if (idata != 8'hDE) do_reject;
                  else dtrl_idx <= 1'b1;
               end else begin
                  if (idata != 8'hAA) do_reject;
                  else begin
                     sector       <= sector_reg;
                     addr         <= addr_base;
                     sector_valid <= 1'b1;
                     state        <= S_SCAN;
                     hist         <= 24'd0;
                  end
               end
            end

            endcase
         end
      end
   end

endmodule
