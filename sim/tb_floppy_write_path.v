`timescale 1ns/1ps
//
// Phase 3 of FLOPPY_WRITE_PLAN.md: exercise floppy.v's new write path -
// the byte-timer/busy/underrun handshake, floppy_track_decoder, and
// floppy_write_committer - end to end, driving floppy.v the same way
// iwm.v does (writeReq + writeData pulses, busy honored between bytes).
//
// Ground truth: `field[]` is loaded directly from
// sim/write_stream_integration.hex (sim/gen_write_stream.py's real,
// non-zero-tag data field for track 0 side 0 sector 0 - side 0 because
// floppy.v's driveSide resets to, and this testbench never changes, 0).
// See that script's header and floppy_track_decoder.v's for why the RTL
// encoder's own output is NOT valid ground truth for THIS test: its
// STATE_DZRO shortcut always emits an all-zero Sony tag (hardcoded), so
// it can never exercise the real-tag case the Phase 3 fix targets - that
// shortcut's byte length matches a real field exactly (it's only zero
// *content*, not a shorter format), the RTL encoder just never produces
// anything else. The decoder scans continuously for D5 AA AD wherever it
// occurs, so no SYN0/ADDR/SYN1/DHDR preamble is needed ahead of the data
// field itself.
//
// A trivial mock acks the shared extra-slot-3 SDRAM write port one cycle
// after each request and records (addr,data) into a byte-addressed model
// array using the established word convention (even source byte -> high
// half, odd -> low half - see floppy_write_committer.v's header).
//
module tb_floppy_write_path;

   reg clk = 0;
   always #5 clk = ~clk;

   reg [7:0] mem [0:819199]; // sim/image.hex ground truth (same as Phase 0/2)
   reg [7:0] sdram_model [0:819199];

   localparam FIELD_BYTES = 709; // D5 AA AD(3) + sector(1) + GRP(699) + DSUM(4) + DTRL(2)
   reg [7:0] field [0:FIELD_BYTES-1];

   // ---- DUT under real write-path timing ----
   reg  _reset = 0;
   reg  cep = 1'b1; // held high: nothing else in this DUT's write path needs
                     // the real 4-phase spacing (see header), and the RTL's
                     // own 128-count timer is exercised in full either way.
   reg  cen = 1'b0;
   reg  _enable = 1'b1;
   reg  writeReq = 1'b0;
   reg  [7:0] writeData = 8'd0;
   reg  writeProtect = 1'b0;
   reg  insertDisk = 1'b1;
   reg  diskSides = 1'b1;
   reg  ca0 = 1'b0, ca1 = 1'b0, ca2 = 1'b0, SEL = 1'b0, lstrb = 1'b1;

   wire [7:0] readData;
   wire writeBusy, writeUnderrun;
   wire [21:0] dskWriteAddr;
   wire [15:0] dskWriteData;
   wire        dskWriteReq;
   reg         dskWriteAck = 1'b0;

   floppy dut (
      .clk(clk), .cep(cep), .cen(cen),
      ._reset(_reset),
      .ca0(ca0), .ca1(ca1), .ca2(ca2), .SEL(SEL), .lstrb(lstrb),
      ._enable(_enable),
      .writeData(writeData),
      .readData(readData),
      .advanceDriveHead(1'b0),
      .newByteReady(),
      .insertDisk(insertDisk),
      .diskSides(diskSides),
      .diskEject(),
      .motor(), .act(),
      .dskReadAddr(), .dskReadAck(1'b0), .dskReadData(8'd0),

      .writeReq(writeReq),
      .writeProtect(writeProtect),
      .writeBusy(writeBusy),
      .writeUnderrun(writeUnderrun),
      .dskWriteAddr(dskWriteAddr),
      .dskWriteData(dskWriteData),
      .dskWriteReq(dskWriteReq),
      .dskWriteAck(dskWriteAck)
   );

   // mock the shared extra-slot-3 SDRAM write port: ack one cycle after
   // each request, record into sdram_model using the established
   // even-byte-high / odd-byte-low word convention.
   always @(posedge clk) begin
      dskWriteAck <= dskWriteReq & ~dskWriteAck;
      if (dskWriteReq && dskWriteAck) begin
         sdram_model[dskWriteAddr]     <= dskWriteData[15:8];
         sdram_model[dskWriteAddr + 1] <= dskWriteData[7:0];
      end
   end

   task do_reset;
      begin
         _reset = 0;
         @(posedge clk);
         @(negedge clk);
         _reset = 1;
         #1;
         // let CSTIN (and anything else level-derived from insertDisk)
         // settle before any test starts driving writes - CSTIN takes
         // exactly one more cep tick to become visible after the tick that
         // clears it (ordinary one-cycle register latency, not a race);
         // without this margin a write attempted on that exact settling
         // edge would see CSTIN's stale pre-clear value and be correctly,
         // but misleadingly, refused by the new gate under test.
         repeat (2) @(posedge clk);
      end
   endtask

   // Drive one drive-register write the way the Mac ROM does: put the
   // register address on {ca1,ca0,SEL} with the data bit on ca2, then strobe
   // lstrb 1->0->1 so floppy.v's `lstrbEdge` (lstrb==0 && lstrbPrev==1) fires
   // on exactly one clk edge.
   //
   // The `#1` after every `@(posedge clk)` is load-bearing, not cosmetic.
   // floppy.v samples lstrb into `lstrbPrev` on posedge clk; driving lstrb at
   // zero delay after that same posedge puts the testbench assignment and the
   // DUT's sampling in the same timestep, and Icarus is free to order them
   // either way. If the DUT reads the new value, lstrbPrev goes straight to 0
   // and the 1->0 edge never exists - the strobe silently does nothing. This
   // is the same race class as the Phase 4 sd_writer testbench bug; unlike a
   // held signal (writeReq, writeData) where a lost race only costs a cycle,
   // losing it on an edge-history register destroys the event outright.
   task strobe_write(input a_ca1, input a_ca0, input a_sel, input a_ca2);
      begin
         ca1 = a_ca1; ca0 = a_ca0; SEL = a_sel; ca2 = a_ca2;
         @(posedge clk); #1;   // lstrbPrev samples lstrb==1 on this edge
         lstrb = 1'b0;
         @(posedge clk); #1;   // this edge: lstrbEdge==1, the write lands
         lstrb = 1'b1;
         @(posedge clk); #1;
      end
   endtask

   // Feed `field[0..FIELD_BYTES-1]` into the DUT's write path, one byte at
   // a time, honoring writeBusy exactly the way iwm.v's writeReqInt/Ext +
   // real Mac ROM software would: pulse writeReq for one clk with the byte
   // on writeData, then wait for writeBusy to clear before the next byte.
   task feed_field;
      integer i;
      begin
         for (i = 0; i < FIELD_BYTES; i = i + 1) begin
            @(posedge clk);
            while (writeBusy) @(posedge clk);
            writeData = field[i];
            writeReq  = 1'b1;
            @(posedge clk);
            writeReq = 1'b0;
         end
         // let the last byte's 128-cycle timer and the committer's SDRAM
         // drain both finish before the caller inspects results.
         repeat (256) @(posedge clk);
         while (dut.wc.busy) @(posedge clk);
      end
   endtask

   integer all_ok, i, mismatches;
   reg [21:0] got_addr;
   reg [3:0]  got_sector;

   initial begin
      $readmemh("sim/image.hex", mem);
      all_ok = 1;

      // ---- ground truth: a real (non-zero-tag) data field for track 0,
      // side 0 (floppy.v's driveSide resets to, and this testbench never
      // changes, 0), sector 0 - see sim/gen_write_stream.py ----
      $readmemh("sim/write_stream_integration.hex", field);

      // =====================================================================
      // Test 1: normal write - full sector round-trips through the real
      // byte-timer/busy handshake, decoder, and committer into (mocked) SDRAM.
      // =====================================================================
      do_reset;
      _enable      = 1'b0; // drive selected+enabled throughout
      writeProtect = 1'b0; // writable
      feed_field;

      got_addr   = dut.secAddr;
      got_sector = dut.secNum;
      mismatches = 0;
      for (i = 0; i < 512; i = i + 1)
         if (sdram_model[got_addr + i] !== mem[got_addr + i])
            mismatches = mismatches + 1;

      if (mismatches == 0) begin
         $display("PASS: normal write - sector %0d at addr %0d committed byte-exact to SDRAM", got_sector, got_addr);
      end else begin
         $display("FAIL: normal write - sector %0d at addr %0d has %0d byte mismatches", got_sector, got_addr, mismatches);
         for (i = 0; i < 16; i = i + 1)
            $display("  [%0d] mem=%h sdram_model=%h", i, mem[got_addr+i], sdram_model[got_addr+i]);
         all_ok = 0;
      end

      // =====================================================================
      // Test 2: write-protected drive must refuse every byte - writeBusy
      // must never assert, so the committer must never run, so SDRAM must
      // stay exactly as test 1 left it (nothing new committed).
      // =====================================================================
      begin : test2
         integer    busy_seen, k;
         do_reset;
         for (i = 0; i < 819200; i = i + 1) sdram_model[i] = 8'hXX; // wipe the model
         _enable      = 1'b0;
         writeProtect = 1'b1; // locked
         busy_seen    = 0;
         for (k = 0; k < FIELD_BYTES; k = k + 1) begin
            @(posedge clk);
            writeData = field[k];
            writeReq  = 1'b1;
            @(posedge clk);
            writeReq = 1'b0;
            if (writeBusy) busy_seen = 1;
         end
         repeat (256) @(posedge clk);
         if (!busy_seen && !dut.wc.busy) begin
            $display("PASS: write-protected drive never accepted a byte (writeBusy never asserted)");
         end else begin
            $display("FAIL: write-protected drive accepted a byte (busy_seen=%b wc.busy=%b)", busy_seen, dut.wc.busy);
            all_ok = 0;
         end
      end

      // =====================================================================
      // Test 3: drive deselected mid-byte must abandon the in-flight byte
      // and latch writeUnderrun, never handing a stale/partial byte to the
      // decoder.
      // =====================================================================
      begin : test3
         do_reset;
         _enable      = 1'b0;
         writeProtect = 1'b0;
         @(posedge clk);
         writeData = field[0];
         writeReq  = 1'b1;
         @(posedge clk);
         writeReq = 1'b0;
         if (!writeBusy) begin
            $display("FAIL: underrun test - byte was not accepted (writeBusy=0 right after writeReq)");
            all_ok = 0;
         end else begin
            repeat (10) @(posedge clk); // well before the 128-cycle byte time completes
            _enable = 1'b1; // deselect mid-byte
            @(posedge clk);
            if (!writeBusy && writeUnderrun) begin
               $display("PASS: mid-byte deselect abandoned the write and asserted writeUnderrun");
            end else begin
               $display("FAIL: mid-byte deselect - writeBusy=%b writeUnderrun=%b (expected 0,1)", writeBusy, writeUnderrun);
               all_ok = 0;
            end
         end
      end

      // =====================================================================
      // Test 4 (Phase 5 item 1): write with no disk in the drive must be
      // refused outright by the new CSTIN gate, same shape as Test 2's
      // write-protect check. insertDisk starts low so driveRegs[CSTIN]
      // stays at its reset value (1 = no disk).
      // =====================================================================
      begin : test4
         integer busy_seen, k;
         insertDisk = 1'b0;
         do_reset;
         for (i = 0; i < 819200; i = i + 1) sdram_model[i] = 8'hXX;
         _enable      = 1'b0;
         writeProtect = 1'b0;
         busy_seen    = 0;
         for (k = 0; k < FIELD_BYTES; k = k + 1) begin
            @(posedge clk);
            writeData = field[k];
            writeReq  = 1'b1;
            @(posedge clk);
            writeReq = 1'b0;
            if (writeBusy) busy_seen = 1;
         end
         repeat (256) @(posedge clk);
         if (!busy_seen && !dut.wc.busy) begin
            $display("PASS: write with no disk inserted was refused outright (writeBusy never asserted)");
         end else begin
            $display("FAIL: write with no disk inserted was accepted (busy_seen=%b wc.busy=%b)", busy_seen, dut.wc.busy);
            all_ok = 0;
         end
      end

      // =====================================================================
      // Test 5 (Phase 5 item 1): an eject immediately followed by a remount
      // mid-field must reset the decoder/committer (writePathReset) so the
      // abandoned half-decoded field can never be completed by whatever
      // comes next. The remount reopens the CSTIN gate right away (unlike
      // Test 4), so this specifically isolates writePathReset's own effect:
      // without it, the decoder would still be sitting mid-field and a
      // subsequent clean field's own D5 AA AD preamble would never be found
      // because state != S_SCAN.
      // =====================================================================
      begin : test5
         integer k;
         do_reset;
         insertDisk   = 1'b1;
         _enable      = 1'b0;
         writeProtect = 1'b0;
         for (i = 0; i < 819200; i = i + 1) sdram_model[i] = 8'hXX;

         // feed a third of a real field, then abandon it mid-flight
         for (k = 0; k < FIELD_BYTES/3; k = k + 1) begin
            @(posedge clk);
            while (writeBusy) @(posedge clk);
            writeData = field[k];
            writeReq  = 1'b1;
            @(posedge clk);
            writeReq = 1'b0;
         end
         while (writeBusy) @(posedge clk);

         // OS eject: DRIVE_REG_EJECT=3'b110 ({ca1,ca0,SEL}), ca2=1.
         // real MacPlus.sv drops dsk_*_ins for as long as diskEject stays
         // asserted (see MacPlus.sv:873-877); mimic that feedback so the
         // CSTIN gate does not get overridden back open by insertDisk's own
         // level on the very next cep cycle, then bring it back for the
         // remount edge below.
         insertDisk = 1'b0;
         strobe_write(1'b1, 1'b1, 1'b0, 1'b1); // eject -> writePathReset
         if (dut.driveRegs[1] !== 1'b1) begin
            $display("FAIL: test5 - the eject strobe never took effect (CSTIN=%b, expected 1)", dut.driveRegs[1]);
            all_ok = 0;
         end
         insertDisk = 1'b1; // remount pulse (edge-detected in floppy.v)
         repeat (2) @(posedge clk); // let CSTIN resettle - see do_reset's comment

         // a complete, fresh field must still decode exactly like Test 1 -
         // proves the abandoned half-field did not leave the decoder stuck.
         feed_field;

         got_addr   = dut.secAddr;
         got_sector = dut.secNum;
         mismatches = 0;
         for (i = 0; i < 512; i = i + 1)
            if (sdram_model[got_addr + i] !== mem[got_addr + i])
               mismatches = mismatches + 1;

         if (mismatches == 0) begin
            $display("PASS: eject/remount mid-field left the decoder clean - the next field still committed byte-exact");
         end else begin
            $display("FAIL: eject/remount mid-field corrupted the decoder - %0d byte mismatches on the next field", mismatches);
            all_ok = 0;
         end
      end

      // =====================================================================
      // Test 6 (Phase 5 item 3): SWITCHED. Read address {ca2,ca1,ca0,SEL} =
      // 0110 (per floppy.v's header table), surfaced as readData[7]. A
      // plain reset with a disk already mounted must NOT set it (same
      // "don't manufacture a spurious edge" seeding writePathReset relies
      // on - see do_reset's comment) - proven implicitly below since it
      // reads 0 right after do_reset. Exercises both triggers: an eject,
      // and a genuine insertDisk edge; cleared only by an explicit write to
      // the reset-disk-switched register (write addr {ca1,ca0,SEL}=001,
      // ca2=1).
      // =====================================================================
      begin : test6
         do_reset;
         insertDisk = 1'b1;
         _enable    = 1'b0;

         ca2 = 1'b0; ca1 = 1'b1; ca0 = 1'b1; SEL = 1'b0; // read SWITCHED
         @(posedge clk); #1;
         if (readData[7] !== 1'b0) begin
            $display("FAIL: test6 - SWITCHED set by a plain reset with a disk already mounted (readData[7]=%b)", readData[7]);
            all_ok = 0;
         end

`ifdef DEBUG_T6
         $monitor("t=%0t ca0=%b ca1=%b ca2=%b SEL=%b lstrb=%b wr=%b lstrbPrev=%b lstrbEdge=%b cstin=%b diskSwitched=%b",
                  $time, ca0, ca1, ca2, SEL, lstrb, dut.driveWriteAddr, dut.lstrbPrev, dut.lstrbEdge, dut.driveRegs[1], dut.diskSwitched);
`endif
         // an eject must set it. As in Test 5, insertDisk has to drop
         // afterward (mirroring MacPlus.sv's real dsk_*_ins feedback) or
         // its still-high level immediately re-mounts on the very next
         // tick and masks the eject.
         insertDisk = 1'b0;
         strobe_write(1'b1, 1'b1, 1'b0, 1'b1); // eject -> diskSwitched set
         if (dut.driveRegs[1] !== 1'b1) begin
            $display("FAIL: test6 - the eject strobe never took effect (CSTIN=%b, expected 1)", dut.driveRegs[1]);
            all_ok = 0;
         end
`ifdef DEBUG_T6
         $display("--- end monitor window ---");
`endif

`ifdef DEBUG_T6
         $display("dbg after eject: cstin=%b diskSwitched=%b", dut.driveRegs[1], dut.diskSwitched);
`endif
         ca2 = 1'b0; ca1 = 1'b1; ca0 = 1'b1; SEL = 1'b0; // read SWITCHED
         @(posedge clk); #1;
         if (readData[7] !== 1'b1) begin
            $display("FAIL: test6 - SWITCHED not set by an eject (readData[7]=%b)", readData[7]);
            all_ok = 0;
         end

         // clear it: write the reset-disk-switched register (addr 1, ca2=1)
         strobe_write(1'b0, 1'b0, 1'b1, 1'b1);

         ca2 = 1'b0; ca1 = 1'b1; ca0 = 1'b1; SEL = 1'b0; // read SWITCHED again
         @(posedge clk); #1;
         if (readData[7] !== 1'b0) begin
            $display("FAIL: test6 - SWITCHED not cleared by the reset-register write (readData[7]=%b)", readData[7]);
            all_ok = 0;
         end

         // a genuine remount (insertDisk edge) must set it again
         insertDisk = 1'b1;
         @(posedge clk); // insertDiskEdge fires -> diskSwitched set
         @(posedge clk);

         ca2 = 1'b0; ca1 = 1'b1; ca0 = 1'b1; SEL = 1'b0; // read SWITCHED again
         @(posedge clk); #1;
         if (readData[7] !== 1'b1) begin
            $display("FAIL: test6 - SWITCHED not set again by a remount (readData[7]=%b)", readData[7]);
            all_ok = 0;
         end else begin
            $display("PASS: test6 - SWITCHED unset across a plain reset, set on eject/remount, cleared only by the reset-register write");
         end
      end

      $display("");
      $display("%s", all_ok ? "PHASE 3 WRITE-PATH GATE: PASS" : "PHASE 3 WRITE-PATH GATE: FAIL");
      $finish;
   end

endmodule
