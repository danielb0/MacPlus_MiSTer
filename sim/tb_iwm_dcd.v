`timescale 1ns/1ps
//
// tb_iwm_dcd.v - MAC128K_PLAN.md Phase 5, "Review 2026-09-05" item 5.
//
// THE SEAM BETWEEN rtl/iwm.v AND THE DCD, WHICH NO OTHER BENCH LOOKS AT.
//
// sim/tb_dcd_link.v, tb_dcd_status.v and tb_dcd_read.v all instantiate
// `dcd_link`/`dcd` DIRECTLY, with cep = cen = 1 and hand-made single-clock
// `writeReq` pulses. Every one of them passes against RTL that cannot work on
// hardware, because the three things that were actually broken live entirely
// on the wires BETWEEN the IWM and the DCD:
//
//   BUG 1  The IWM status register took its sense bit from the external
//          FLOPPY unconditionally, so the ROM's ID probe and HD Diag both
//          talked to floppyExt and never saw the DCD at all. Every hardware
//          symptom so far - "init driver failed", the $28 - was the floppy's
//          drive registers answering in the drive's place.
//   BUG 2  dcd_link cleared `newByteReady` on every clk and set it only under
//          `cen`, so the pulse was high for exactly the one clk when `cen` is
//          necessarily low - and iwm.v latches on `cen && newByteReady`. Not
//          one reply byte could ever reach the data latch.
//   BUG 3  `writeReqExt` is built from `dataRegWrite`, a LEVEL on _cpuLDS
//          which fx68k holds for three CPU clock periods, so every byte the
//          Mac sent arrived at the drive THREE TIMES. floppy.v never noticed
//          because it refuses a writeReq while its 16 us write-busy is set.
//
// So this bench drives the REAL `iwm` - both floppies and the DCD inside it -
// through its CPU port only, with busPhase-derived cep/cen and _cpuLDS held
// for three CPU periods the way sim/tb_iwm_latch.v established. Nothing here
// reaches into the DCD's byte interface; the Mac model touches the sixteen
// IWM registers and nothing else, which is all a 68000 can do.
//
// Three checks name the three bugs directly, so a regression says which one
// came back rather than just "no reply":
//   * the ID probe through the STATUS register            -> bug 1
//   * writeReq pulses counted per CPU data-register write -> bug 3
//   * newByteReady pulses vs. pulses the cen-gated latch  -> bug 2
// and the end-to-end Status and MultiBlock Read exchanges prove the seam
// carries a whole conversation, not just a signal edge.
//
// THE REGRESSION THAT MATTERS is the first block: with NO DCD image mounted
// the external port must still be bit-identical to the floppy it has always
// been, sense line included. That is the property the whole design rests on.
//
// Run from the repo ROOT:
//   iverilog -g2012 -I rtl -o /tmp/t.vvp sim/tb_iwm_dcd.v rtl/iwm.v rtl/floppy.v \
//       rtl/floppy_track_encoder.v rtl/floppy_track_decoder.v \
//       rtl/floppy_write_committer.v rtl/dcd.v rtl/dcd_link.v rtl/dcd_disk.v \
//   && vvp /tmp/t.vvp
//
module tb_iwm_dcd;

	// clk_sys is 32 MHz; busPhase divides it exactly as addrController_top.v
	// does, so cep/cen are the real 8 MHz enables and not a convenience.
	localparam CLKSYS_NS = 31.25;
	reg clk = 0;
	always #(CLKSYS_NS/2) clk = ~clk;

	reg [1:0] busPhase = 2'b00;
	always @(posedge clk) busPhase <= busPhase + 1'b1;
	wire cep   = (busPhase == 2'b11);
	wire cen   = (busPhase == 2'b01);
	wire cen16 = busPhase[0];

	// clk_sys cycles per CPU clock. 4 = 8 MHz, the speed a 512Ke runs at and
	// the only speed an HD20 was ever attached to.
	localparam integer CPUP = 4;

	// Poll spacing for the data-latch read loop, in CPU cycles of IDLE - the
	// access itself is 3 more, so start to start is POLL_GAP + 3.
	//
	// THIS HAS TO CLEAR THE LATCH HOLD WITH REAL MARGIN. The IWM's clear
	// countdown is 12 cen ticks = 1.5 us from the END of a valid read, and
	// every poll that finds bit 7 still set RE-ARMS it - so one poll landing
	// early pins the latch high for as long as polling continues, and the next
	// byte read is a duplicate of the last. At 18 cycles start to start the
	// margin is about 3 clk_sys, which one bus-phase alignment eats: the
	// Status frame decoded cleanly and the read frame came back with its sync
	// byte twice ($54 in the first decoded slot, which is {$AA[6:0],x}).
	// That is sim/tb_iwm_latch.v's subject - the shared latch, nothing
	// DCD-specific - so sit well inside its passing region instead of on the
	// boundary. 24 cycles start to start is 3.0 us against a 1.5 us hold, and
	// still gives ~5 polls per 16 us drive byte.
	localparam integer POLL_GAP = 21;

	reg         _reset       = 1'b0;
	reg         selectIWM    = 1'b0;
	reg         _cpuRW       = 1'b1;
	reg         _cpuLDS      = 1'b1;
	reg  [15:0] dataIn       = 16'h0000;
	reg  [3:0]  cpuAddrRegHi = 4'h0;
	reg         SEL          = 1'b0;   // the ROM probes the chain with SEL low
	reg         driveSel     = 1'b1;

	wire [15:0] dataOut;
	wire [1:0]  diskEject, diskMotor, diskAct;
	wire [21:0] dskReadAddrInt, dskReadAddrExt;
	wire [31:0] dbg_floppy, dbg_dcd;

	// ---- the DCD's hps_io block-device slot ----
	wire [31:0] dcd_sd_lba;
	wire        dcd_sd_rd, dcd_sd_wr;
	reg         dcd_sd_ack       = 1'b0;
	reg   [7:0] dcd_sd_buff_addr = 8'd0;
	reg  [15:0] dcd_sd_buff_dout = 16'd0;
	wire [15:0] dcd_sd_buff_din;
	reg         dcd_sd_buff_wr   = 1'b0;
	reg         dcd_img_mounted  = 1'b0;
	reg  [63:0] dcd_img_size     = 64'd0;
	reg         dcd_img_readonly = 1'b0;

	iwm dut (
		.clk(clk), .cep(cep), .cen(cen), .cen16(cen16), .turbo(1'b0),
		._reset(_reset),
		.selectIWM(selectIWM),
		._cpuRW(_cpuRW),
		._cpuLDS(_cpuLDS),
		.dataIn(dataIn),
		.cpuAddrRegHi(cpuAddrRegHi),
		.SEL(SEL),
		.driveSel(driveSel),
		.dataOut(dataOut),
		.insertDisk(2'b00),
		.diskEject(diskEject),
		.diskSides(2'b00),
		.drive800k(1'b0),
		.disk_pwm(9'd0),
		.dbg_floppy(dbg_floppy),
		.diskMotor(diskMotor),
		.diskAct(diskAct),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(1'b0),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(1'b0),
		.dskReadData(8'h00),
		.writeProtect(2'b11),
		.dskWriteAddrInt(), .dskWriteDataInt(), .dskWriteReqInt(), .dskWriteAckInt(1'b0),
		.dskWriteAddrExt(), .dskWriteDataExt(), .dskWriteReqExt(), .dskWriteAckExt(1'b0),
		.dcd_sd_lba(dcd_sd_lba),
		.dcd_sd_rd(dcd_sd_rd),
		.dcd_sd_wr(dcd_sd_wr),
		.dcd_sd_ack(dcd_sd_ack),
		.dcd_sd_buff_addr(dcd_sd_buff_addr),
		.dcd_sd_buff_dout(dcd_sd_buff_dout),
		.dcd_sd_buff_din(dcd_sd_buff_din),
		.dcd_sd_buff_wr(dcd_sd_buff_wr),
		.dcd_img_mounted(dcd_img_mounted),
		.dcd_img_size(dcd_img_size),
		.dcd_img_readonly(dcd_img_readonly),
		.dbg_dcd(dbg_dcd),
		.dskCommitDoneInt(), .dskCommitAddrInt(), .dskCommitBufWrInt(),
		.dskCommitBufAddrInt(), .dskCommitBufDataInt(),
		.dskCommitDoneExt(), .dskCommitAddrExt(), .dskCommitBufWrExt(),
		.dskCommitBufAddrExt(), .dskCommitBufDataExt()
	);

	integer pass = 0, fail = 0;

	task check;
		input [1023:0] name;
		input cond;
		begin
			if (cond) begin pass = pass + 1; $display("  PASS  %0s", name); end
			else      begin fail = fail + 1; $display("  FAIL  %0s", name); end
		end
	endtask

	// ------------------------------------------------------------------
	// Seam monitors - the three bugs, watched directly
	// ------------------------------------------------------------------
	// writeReq is counted at the DCD's PORT, not at whatever wire inside
	// iwm.v happens to feed it, so the same bench measures the pre-fix and
	// post-fix RTL without an edit.
	integer wrPulses = 0;
	reg     wrPrev   = 1'b0;
	always @(posedge clk) begin
		if (dut.dcd0.writeReq && !wrPrev) wrPulses = wrPulses + 1;
		wrPrev <= dut.dcd0.writeReq;
	end

	// nbrEdges   - bytes the drive OFFERED to the IWM
	// nbrLatched - of those, how many the IWM's `cen && newByteReady` latch
	//              could actually see. Bug 2 is exactly nbrEdges > 0 with
	//              nbrLatched == 0, and keeping the two counters apart is what
	//              separates "the drive never replied" from "the drive
	//              replied and nothing arrived".
	integer nbrEdges   = 0;
	integer nbrLatched = 0;
	reg     nbrPrev    = 1'b0;
	always @(posedge clk) begin
		if (dut.newByteReadyDcd && !nbrPrev) nbrEdges   = nbrEdges + 1;
		if (cen && dut.newByteReadyDcd)      nbrLatched = nbrLatched + 1;
		nbrPrev <= dut.newByteReadyDcd;
	end

	// ------------------------------------------------------------------
	// The CPU bus. One access = _cpuLDS low for three CPU clock periods,
	// which is what fx68k does (rLDS asserted at the S2 enPhi1 edge, released
	// at S7 enPhi2) and is the whole of bug 3.
	// ------------------------------------------------------------------
	task cpu_gap;
		input integer cycles;
		integer n;
		begin
			for (n = 0; n < cycles*CPUP; n = n + 1) @(posedge clk);
			#1;
		end
	endtask

	task cpu_read;
		input  [3:0] addr;
		output [7:0] d;
		integer n;
		begin
			cpuAddrRegHi = addr;
			_cpuRW       = 1'b1;
			selectIWM    = 1'b1;
			_cpuLDS      = 1'b0;
			for (n = 0; n < 3*CPUP; n = n + 1) @(posedge clk);
			#1;
			d         = dataOut[7:0];   // sampled while the access is still up
			_cpuLDS   = 1'b1;
			selectIWM = 1'b0;
		end
	endtask

	task cpu_write;
		input [3:0] addr;
		input [7:0] d;
		integer n;
		begin
			cpuAddrRegHi = addr;
			dataIn       = {8'h00, d};
			_cpuRW       = 1'b0;
			selectIWM    = 1'b1;
			_cpuLDS      = 1'b0;
			for (n = 0; n < 3*CPUP; n = n + 1) @(posedge clk);
			#1;
			_cpuLDS   = 1'b1;
			selectIWM = 1'b0;
			_cpuRW    = 1'b1;
		end
	endtask

	reg [7:0] scratch;

	// Setting one of the sixteen one-bit registers is a bare access.
	task iwm_set;
		input [3:0] addr;
		begin
			cpu_read(addr, scratch);
			cpu_gap(2);
		end
	endtask

	// Drive the phase lines to a state, one register at a time, the way a
	// 68000 must. THE ORDER IS NOT ARBITRARY: state 4 is the DCD's RESET, so
	// coming down out of the 4-7 group drops ca2 FIRST and going up into it
	// raises ca2 LAST. Walking the bits in a fixed order instead resets the
	// drive in the middle of, say, 5 -> 2.
	task setState;
		input [2:0] s;
		begin
			if (s[2] == 1'b0) begin
				iwm_set({3'h2, s[2]});   // ca2
				iwm_set({3'h1, s[1]});   // ca1
				iwm_set({3'h0, s[0]});   // ca0
			end
			else begin
				iwm_set({3'h0, s[0]});
				iwm_set({3'h1, s[1]});
				iwm_set({3'h2, s[2]});
			end
		end
	endtask

	// The IWM status register: Q7 low, Q6 high. $1A00 (q6H) then read $1C00
	// (q7L), which is `tst.b $1a00(a2) / tst.b $1c00(a2)` at HD Diag $D926 and
	// the ROM's $418600. Bit 7 is the sense line.
	task readStatus;
		output [7:0] d;
		begin
			iwm_set(4'hD);          // q6H
			cpu_read(4'hE, d);      // q7L -> {q7,q6} = 01 = status
			cpu_gap(2);
		end
	endtask

	// The data-in register: Q7 low, Q6 low.
	task setDataMode;
		begin
			iwm_set(4'hC);          // q6L
			iwm_set(4'hE);          // q7L
		end
	endtask

	// Poll the data latch for a byte, the ROM's `move.b (a3),d0 / dbmi` loop.
	// The latch clears itself after a valid read, so bit 7 IS the ready flag.
	// A DUPLICATE IS INVISIBLE IN THE DECODED FRAME - the checksum just fails
	// and everything after it is shifted - so detect it where it happens: a
	// byte is genuine only if the latch took a new one from the drive since
	// the last successful read. nbrLatched is that count.
	//
	// THIS FOUND A FOURTH DEFECT, AND IT IS NOT ONE OF THE THREE SEAM BUGS
	// AND NOT DCD-SPECIFIC. iwm.v arms its latch-clear countdown with
	//     if (iwmRead && readDataLatch[7]) readLatchClearTimer <= 4'hD;
	// which reads readDataLatch BEFORE the edge. When a drive byte is latched
	// on the LAST cen tick of a CPU read access, that pre-edge value is still
	// zero, so the countdown is never armed at all - readLatchClearTimer stays
	// 0, the latch never self-clears, and the next poll returns the same byte
	// a second time. Observed directly: every good byte leaves timer = 13, the
	// byte before a duplicate leaves timer = 0.
	//
	// It applies to floppy reads identically, and it is alignment-dependent in
	// exactly the way sim/tb_iwm_latch.v documents - the 393-byte Status frame
	// below lands on a safe phase and decodes perfectly, the 617-byte read
	// frame does not. The IWM specification quoted at the top of rtl/iwm.v
	// calls a valid read "/DEV low and D7 outputting a one for at least one
	// fclk period", which that final cen tick satisfies, so the hardware would
	// have armed it. Fixing it means touching the shared, hardware-proven
	// floppy latch path, which is outside the three-bug fix plan - so it is
	// gated here by name and left for a decision.
	integer rxTimeouts = 0;
	integer dupBytes   = 0;
	integer firstDupAt = -1;
	integer bytesRead  = 0;
	integer lastLatch  = 0;
	task iwmGetByte;
		output [7:0] b;
		integer w;
		reg [7:0] d;
		reg       got;
		begin
			got = 1'b0; w = 0; b = 8'h00;
			// A byte arrives every 128 cen = 16 us, which is ~9 polls. 400 is
			// half a millisecond: generous against the drive's sector fetch,
			// and short enough that a dead seam reports rather than hangs.
			while (!got && w < 400) begin
				cpu_read(4'hE, d);
				if (d[7]) begin
					b   = d;
					got = 1'b1;
					if (nbrLatched <= lastLatch) begin
						dupBytes = dupBytes + 1;
						if (firstDupAt < 0) firstDupAt = bytesRead;
					end
					lastLatch = nbrLatched;
					bytesRead = bytesRead + 1;
				end
				cpu_gap(POLL_GAP);
				w = w + 1;
			end
			if (!got) rxTimeouts = rxTimeouts + 1;
		end
	endtask

	// Wait for the sense line to reach `want`, polling the status register.
	task waitSense;
		input        want;
		output       okv;
		integer      w;
		reg    [7:0] d;
		begin
			okv = 1'b0; w = 0;
			while (!okv && w < 1000) begin
				readStatus(d);
				if (d[7] === want) okv = 1'b1;
				w = w + 1;
			end
		end
	endtask

	// Hand a byte to the drive through the IWM's write-data register. The
	// handshake poll at $1800 is the ROM's `tst.b (a3) / bpl` at $419AE8 and
	// is ALSO what returns Q6 to 0, so the write to $1A00 below sets it again
	// and lands on {q7,q6} = 11. Both halves are load-bearing.
	task macByte;
		input [7:0] b;
		integer     w;
		reg   [7:0] d;
		begin
			w = 0; d = 8'h00;
			while (!d[7] && w < 200) begin
				cpu_read(4'hC, d);      // $1800, q6L -> {q7,q6} = 10 = handshake
				cpu_gap(1);
				w = w + 1;
			end
			cpu_write(4'hD, b);         // $1A00, q6H with Q7 already high
			cpu_gap(2);
		end
	endtask

	// The sync goes to $1E00 (q7H), which is how the ROM raises Q7 and writes
	// the first byte in one access. Q6 must already be high for it.
	task macSync;
		input [7:0] b;
		begin
			iwm_set(4'hD);              // q6H
			cpu_write(4'hF, b);         // $1E00, q7H -> {q7,q6} = 11
			cpu_gap(2);
		end
	endtask

	// ------------------------------------------------------------------
	// The block-device model, written from hps_io.sv (see sim/tb_dcd_read.v)
	// ------------------------------------------------------------------
	function [7:0] diskByte;
		input [23:0] b;
		input integer k;
		begin
			diskByte = b[7:0] ^ b[23:16] ^ k[7:0] ^ (k[8] ? 8'h5A : 8'hA5);
		end
	endfunction

	integer m, fetches = 0;
	reg [31:0] lastLba = 32'hFFFFFFFF;

	always @(posedge clk) begin
		if (dcd_sd_rd && !dcd_sd_ack) begin
			lastLba = dcd_sd_lba;
			fetches = fetches + 1;
			repeat (3) @(posedge clk);
			dcd_sd_ack = 1'b1;
			@(posedge clk);
			for (m = 0; m < 256; m = m + 1) begin
				@(posedge clk); #1;
				dcd_sd_buff_addr = m[7:0];
				dcd_sd_buff_dout = {diskByte(dcd_sd_lba[23:0], m*2 + 1),
				                    diskByte(dcd_sd_lba[23:0], m*2)};
				dcd_sd_buff_wr   = 1'b1;
				@(posedge clk); #1;
				dcd_sd_buff_wr   = 1'b0;
			end
			@(posedge clk); #1;
			dcd_sd_ack = 1'b0;
			// sd_rd falls a clock after ack, so without this the model
			// retriggers on the tail of the transfer it just finished.
			while (dcd_sd_rd) @(posedge clk);
		end
	end

	task mountDcd;
		input [63:0] blocks;
		begin
			@(posedge clk); #1;
			dcd_img_size     = blocks * 64'd512;
			dcd_img_readonly = 1'b0;
			dcd_img_mounted  = 1'b1;
			@(posedge clk); #1;
			dcd_img_mounted  = 1'b0;
			repeat (8) @(posedge clk); #1;
		end
	endtask

	// ------------------------------------------------------------------
	// The Mac's own arithmetic, $4196FA. Nothing here is a typed constant.
	// ------------------------------------------------------------------
	function integer macGroups;
		input integer n;
		begin
			macGroups = ((n + 6) / 7) + 1;
		end
	endfunction

	localparam integer STATUS_LEN = 332;        // $419D2C move.l #$14C,d7
	localparam integer READ_LEN   = 512 + 20;   // 512 data + the tags at $4196D0

	integer   i, g, nDecoded;
	reg [7:0] cmd [0:6];
	reg [7:0] raw [0:7];
	reg [7:0] rsp [0:1023];
	reg [7:0] sum, sync;
	reg       ok, okv;
	reg [7:0] st7, st6, st5, dtmp;
	// The two candidate sources, sampled AT the probe. Reading either of them
	// after the fact reads whatever the phase lines have since moved on to,
	// which is a different register entirely.
	reg       fx7, fx6, fx5;    // what floppyExt was offering
	reg       dc7, dc6, dc5;    // what the DCD was offering
	integer   wrMark, wrPerByte;
	integer   nbrMark;

	task idProbe;
		begin
			setState(3'd7); readStatus(st7);
			fx7 = dut.readDataExt[7]; dc7 = dut.readDataDcd[7];
			setState(3'd6); readStatus(st6);
			fx6 = dut.readDataExt[7]; dc6 = dut.readDataDcd[7];
			setState(3'd5); readStatus(st5);
			fx5 = dut.readDataExt[7]; dc5 = dut.readDataDcd[7];
		end
	endtask

	// Frame one command group the way $419A26-$419AF4 does, entirely through
	// the IWM. wrPerByte is captured around the sync so bug 3 is measured on a
	// single, named write rather than inferred from a broken frame.
	task sendCommand;
		input [7:0] c0, c1, c2, c3, c4, c5;
		input integer rspLen;
		begin
			cmd[0] = c0; cmd[1] = c1; cmd[2] = c2;
			cmd[3] = c3; cmd[4] = c4; cmd[5] = c5;
			sum = 0;
			for (i = 0; i < 6; i = i + 1) sum = sum + cmd[i];
			cmd[6] = -sum;

			setState(3'd2);
			setState(3'd3);
			waitSense(1'b0, okv);
			check("the drive answers the command request with /HSHK", okv);

			setState(3'd1);
			wrMark = wrPulses;
			macSync(8'hAA);
			wrPerByte = wrPulses - wrMark;
			macByte(8'h80 | macGroups(0));
			macByte(8'h80 | macGroups(rspLen));
			macByte(8'h80 | (cmd[0][0] << 6) | (cmd[1][0] << 5) | (cmd[2][0] << 4) |
			                (cmd[3][0] << 3) | (cmd[4][0] << 2) | (cmd[5][0] << 1) |
			                 cmd[6][0]);
			for (i = 0; i < 7; i = i + 1) macByte(8'h80 | (cmd[i] >> 1));

			setState(3'd3);
			waitSense(1'b1, okv);
			check("the drive releases /HSHK at the end of the command", okv);
			setState(3'd2);
		end
	endtask

	// Wait for the drive to ask for the bus, walk 2 -> 3 -> 1, and pull one
	// frame out through the data latch.
	task recvFrame;
		input integer n;
		begin
			setState(3'd2);
			waitSense(1'b0, okv);
			check("the drive asks for the bus with /HSHK before its reply", okv);
			if (!okv) rxTimeouts = rxTimeouts + 1;
			setState(3'd3);
			setState(3'd1);
			setDataMode();
			iwmGetByte(sync);
			for (g = 0; g < n && rxTimeouts == 0; g = g + 1) begin
				for (i = 0; i < 8 && rxTimeouts == 0; i = i + 1)
					iwmGetByte(raw[i]);
				for (i = 0; i < 7; i = i + 1)
					rsp[g*7 + i] = {raw[i][6:0], raw[7][6-i]};
			end
			nDecoded = (rxTimeouts == 0) ? n * 7 : 0;
		end
	endtask

	initial begin
		repeat (8) @(posedge clk);
		@(negedge clk);
		_reset = 1'b1;
		repeat (8) @(posedge clk); #1;

		$display("tb_iwm_dcd");
		$display("");
		$display("-- the external port with NO DCD mounted (the regression) --");

		// Select the external port and assert /ENBL2, as $4185AC does. The
		// enable register follows the CURRENT selectExternalDrive, so the
		// order matters.
		iwm_set(4'hB);   // extDrive
		iwm_set(4'h9);   // mtrOn

		idProbe;
		check("no DCD: the status sense is still the external floppy's, exactly",
		      (st7[7] === fx7) && (st6[7] === fx6) && (st5[7] === fx5));
		check("no DCD: state 7 reads INSTALLED = 0, so the ROM's ID probe fails here",
		      st7[7] === 1'b0);

		// ------------------------------------------------------------------
		$display("");
		$display("-- BUG 1: the ID probe, with a DCD mounted --");
		// ------------------------------------------------------------------
		// $418600 reads the status register in states 7, 6 and 5 and requires
		// 1, 1, 0. HD Diag's $D9BC does the same and prints "init driver
		// failed" otherwise. Both were reading floppyExt.
		mountDcd(64'd38965);            // a real HD20, 20 MB
		idProbe;
		check("BUG 1: state 7 sense is 1 (the drive is there)",       st7[7] === 1'b1);
		check("BUG 1: state 6 sense is 1",                            st6[7] === 1'b1);
		check("BUG 1: state 5 sense is 0 (not a Superdrive)",         st5[7] === 1'b0);
		// Not a restatement of the three above: it pins WHERE the bit came
		// from. State 7 is the one where the two sources disagree, so a mux
		// left on the floppy cannot pass it by luck.
		check("BUG 1: and that is the DCD's line, not the floppy's",
		      (st7[7] === dc7) && (st7[7] !== fx7));

		// ------------------------------------------------------------------
		$display("");
		$display("-- HD Diag's hard reset, $D8FC --");
		// ------------------------------------------------------------------
		// mtrOff, ca2/ca1/ca0 -> state 4 (RESET), select external, mtrOn,
		// wait, 6, then 2, then poll the status register. HD Diag wants the
		// sense LOW first and then HIGH; we only ever give it HIGH, so it
		// reports $24 rather than success. That is the known deviation - a
		// real drive holds /HSHK low for its self-test - and it is NOT what
		// the Plus ROM needs ($419C6C waits for HIGH only), so the gate here
		// is the ROM's requirement.
		iwm_set(4'h8);   // mtrOff
		iwm_set(4'h5);   // ca2H
		iwm_set(4'h2);   // ca1L
		iwm_set(4'h0);   // ca0L   -> state 4, RESET
		iwm_set(4'hB);   // extDrive
		iwm_set(4'h9);   // mtrOn  -> /ENBL2
		cpu_gap(400);
		iwm_set(4'h3);   // ca1H   -> state 6
		iwm_set(4'h4);   // ca2L   -> state 2
		readStatus(dtmp);
		check("after a RESET the drive's sense is released, which is what the ROM waits for",
		      dtmp[7] === 1'b1);

		// ------------------------------------------------------------------
		$display("");
		$display("-- BUGS 3 and 2: a Status command and its reply, end to end --");
		// ------------------------------------------------------------------
		nbrMark = nbrEdges;
		sendCommand(8'h03, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, STATUS_LEN);
		check("BUG 3: one CPU write to the data register is ONE byte to the drive",
		      wrPerByte === 1);

		recvFrame(macGroups(STATUS_LEN));
		check("BUG 2: the drive offered reply bytes at all (the command framed correctly)",
		      nbrEdges > nbrMark);
		check("BUG 2: every byte the drive offered was seen by the IWM's cen-gated latch",
		      (nbrLatched > 0) && (nbrLatched === nbrEdges));
		check("no byte timed out on the way through the data latch", rxTimeouts === 0);
		// SEPARATE FROM THE THREE SEAM BUGS, and pre-existing: see the note on
		// dupBytes at its declaration. The Status frame happens to land on a
		// safe phase; the longer read frame below does not.
		check("no byte was read twice from the data latch (Status frame)",
		      dupBytes === 0);

		check("the reply opened with the $AA sync", sync === 8'hAA);
		check("the reply is 49 groups, i.e. 343 payload bytes", nDecoded === 343);
		sum = 0;
		for (i = 0; i < 343; i = i + 1) sum = sum + rsp[i];
		check("the whole reply checksums to zero through the IWM", sum === 8'h00);
		check("the reply opcode is $83", rsp[0] === 8'h83);
		// Reply byte 6 begins the identity block; capacity is at offset 5..7
		// of it, so bytes 11..13, and 38965 blocks reports 38964.
		check("the capacity survived the trip: 38964, the highest block",
		      {rsp[11], rsp[12], rsp[13]} === 24'd38964);

		// ------------------------------------------------------------------
		$display("");
		$display("-- MultiBlock Read of one block, through the same seam --");
		// ------------------------------------------------------------------
		// A block above 65535 on purpose: a truncated LBA reads the right data
		// for the first 32 MB of any image and silently the wrong data above.
		// THAT NEEDS AN IMAGE THAT REACHES THAT FAR, so remount at 64 MB
		// first - the 20 MB HD20 above stops at block 38964, and asking past
		// the end gets the protocol's one-group error frame, which is the
		// right answer to the wrong question. Remounting also walks the mount
		// path a second time through the seam.
		setState(3'd2);
		mountDcd(64'd131072);
		nbrMark = nbrEdges;
		sendCommand(8'h00, 8'h01, 8'd1, 8'h00, 8'h00, 8'h00, READ_LEN);
		recvFrame(macGroups(READ_LEN));
		check("the read reply is 77 groups", nDecoded === 77*7);
		sum = 0;
		for (i = 0; i < 539; i = i + 1) sum = sum + rsp[i];
		check("the read reply checksums to zero", sum === 8'h00);
		check("the read reply header is opcode $80 with one block to come",
		      (rsp[0] === 8'h80) && (rsp[1] === 8'h01));
		check("the drive fetched the 24-bit block that was asked for",
		      lastLba === 32'h00010000);
		ok = 1'b1;
		for (i = 0; i < 512; i = i + 1)
			if (rsp[26 + i] !== diskByte(24'h010000, i)) ok = 1'b0;
		check("all 512 data bytes arrived intact at the CPU's data latch", ok);
		check("no byte was read twice from the data latch (read frame)",
		      dupBytes === 0);
		if (dupBytes != 0)
			$display("        (%0d duplicate reads, first at frame byte %0d - see the dupBytes note)",
			         dupBytes, firstDupAt);

		$display("");
		$display("tb_iwm_dcd: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("IWM/DCD SEAM GATE: FAIL (%0d)", fail);
		else           $display("IWM/DCD SEAM GATE: PASS");
		$finish;
	end

	// A seam that does not work stalls rather than failing, so make the stall
	// report itself. 80 ms covers both frames at the drive's 16 us byte rate
	// with room to spare.
	initial begin
		#80_000_000;
		$display("");
		$display("tb_iwm_dcd: TIMEOUT after %0d/%0d checks", pass, pass + fail);
		$display("IWM/DCD SEAM GATE: FAIL (watchdog)");
		$finish;
	end

endmodule
