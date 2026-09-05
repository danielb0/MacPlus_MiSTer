`timescale 1ns/1ps
//
// tb_dcd_disk.v - MAC128K_PLAN.md Phase 5 gate for rtl/dcd_disk.v.
//
// Drives a model of one hps_io block-device slot against the sector path. The
// model is written from hps_io.sv's behaviour, not from dcd_disk.v's: sd_ack
// is a LEVEL held for the whole transfer, sd_buff_addr is driven by the host
// and not by us, and sd_buff_wr is a shared strobe that fires for whichever
// slot is being serviced - which is why the model can be told to service a
// DIFFERENT slot and the buffer must not move.
//
// THE BYTE LANES ARE THE POINT OF THIS BENCH. The real HPS packs disk byte 0
// into sd_buff_dout[7:0], and rtl/scsi.v is the hardware-proven precedent. So
// the model fills each word as {odd, even} and the test asserts that reading
// byte k back through the byte-addressed port returns disk byte k. Swapping
// the two lanes transposes every pair, which no checksum in the DCD protocol
// would catch and which nothing notices until a filesystem fails to mount.
//
module tb_dcd_disk;

	reg         clk = 0;
	reg         _reset;

	wire [31:0] sd_lba;
	wire        sd_rd, sd_wr;
	reg         sd_ack;
	reg   [7:0] sd_buff_addr;
	reg  [15:0] sd_buff_dout;
	wire [15:0] sd_buff_din;
	reg         sd_buff_wr;

	reg         img_mounted;
	reg  [63:0] img_size;
	reg         img_readonly;

	wire        present;
	wire [23:0] blockCount;
	wire        readonly;

	reg  [23:0] lba;
	reg         rd_req, wr_req;
	wire        busy, err;

	reg   [8:0] buf_addr;
	wire  [7:0] buf_q;
	reg   [7:0] buf_d;
	reg         buf_we;

	integer pass = 0, fail = 0;

	// A short timeout so the timeout test does not take half a second of
	// simulated time; the RTL default is ~0.5 s at clk_sys.
	dcd_disk #(.ACK_TIMEOUT_BITS(8)) dut
	(
		.clk(clk), ._reset(_reset),
		.sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
		.present(present), .blockCount(blockCount), .readonly(readonly),
		.lba(lba), .rd_req(rd_req), .wr_req(wr_req), .busy(busy), .err(err),
		.buf_addr(buf_addr), .buf_q(buf_q), .buf_d(buf_d), .buf_we(buf_we)
	);

	always #10 clk = ~clk;

	task check;
		input [511:0] name;
		input cond;
		begin
			if (cond) begin pass = pass + 1; $display("  PASS  %0s", name); end
			else      begin fail = fail + 1; $display("  FAIL  %0s", name); end
		end
	endtask

	integer i;
	reg  [7:0] got [0:511];      // what the write side handed back to the host
	reg  [7:0] expect_byte;
	reg  [7:0] rdbyte;
	reg        ok;
	integer    served;           // how many sectors the model has served
	reg        mid_rd, mid_busy; // request lines sampled mid-transfer
	reg  [7:0] stream [0:511];
	integer    k;

	// Disk contents: byte k of block b. Deliberately makes the two bytes of a
	// word differ, so a transposed lane pair cannot pass by accident.
	function [7:0] diskByte;
		input [23:0] b;
		input integer k;
		begin
			diskByte = b[7:0] ^ k[7:0] ^ (k[8] ? 8'h5A : 8'hA5);
		end
	endfunction

	// ------------------------------------------------------------------
	// The block-device model
	// ------------------------------------------------------------------
	// forSlot=0 makes it drive sd_buff_wr WITHOUT asserting our sd_ack, which
	// is what the shared strobe looks like when another slot is being serviced.
	task serveRead;
		input [23:0] b;
		input        forSlot;
		begin
			repeat (3) @(posedge clk);
			if (forSlot) sd_ack = 1'b1;
			@(posedge clk);
			for (i = 0; i < 256; i = i + 1) begin
				@(posedge clk); #1;
				sd_buff_addr = i[7:0];
				sd_buff_dout = {diskByte(b, i*2 + 1), diskByte(b, i*2)};
				sd_buff_wr   = 1'b1;
				// Sample the request lines mid-transfer. hps_io holds sd_ack
				// for the whole sector and expects the request to stay
				// asserted until it drops; releasing early also drops busy
				// early, which would let the caller start a second fetch into
				// the sector still being filled.
				if (i == 128) begin mid_rd = sd_rd; mid_busy = busy; end
				@(posedge clk); #1;
				sd_buff_wr   = 1'b0;
			end
			@(posedge clk); #1;
			sd_ack = 1'b0;
			served = served + 1;
		end
	endtask

	task serveWrite;
		begin
			repeat (3) @(posedge clk);
			sd_ack = 1'b1;
			@(posedge clk);
			for (i = 0; i < 256; i = i + 1) begin
				@(posedge clk); #1;
				sd_buff_addr = i[7:0];
				// One clock for the RAM's registered read to follow the address.
				@(posedge clk); @(posedge clk); #1;
				got[i*2]     = sd_buff_din[7:0];
				got[i*2 + 1] = sd_buff_din[15:8];
			end
			@(posedge clk); #1;
			sd_ack = 1'b0;
			served = served + 1;
		end
	endtask

	// Read one byte back out of the sector buffer. buf_q is registered, so the
	// address has to lead the sample by a clock.
	task readByte;
		input  [8:0] a;
		output [7:0] d;
		begin
			@(posedge clk); #1;
			buf_addr = a;
			@(posedge clk);
			@(posedge clk); #1;
			d = buf_q;
		end
	endtask

	task writeByte;
		input [8:0] a;
		input [7:0] d;
		begin
			@(posedge clk); #1;
			buf_addr = a; buf_d = d; buf_we = 1'b1;
			@(posedge clk); #1;
			buf_we = 1'b0;
		end
	endtask

	task pulseRd;
		input [23:0] b;
		begin
			@(posedge clk); #1;
			lba = b; rd_req = 1'b1;
			@(posedge clk); #1;
			rd_req = 1'b0;
		end
	endtask

	task pulseWr;
		input [23:0] b;
		begin
			@(posedge clk); #1;
			lba = b; wr_req = 1'b1;
			@(posedge clk); #1;
			wr_req = 1'b0;
		end
	endtask

	task mount;
		input [63:0] sz;
		input        ro;
		begin
			@(posedge clk); #1;
			img_size = sz; img_readonly = ro; img_mounted = 1'b1;
			@(posedge clk); #1;
			img_mounted = 1'b0;
			@(posedge clk);
		end
	endtask

	initial begin
		_reset = 0;
		sd_ack = 0; sd_buff_addr = 0; sd_buff_dout = 0; sd_buff_wr = 0;
		img_mounted = 0; img_size = 0; img_readonly = 0;
		lba = 0; rd_req = 0; wr_req = 0;
		buf_addr = 0; buf_d = 0; buf_we = 0;
		served = 0;
		repeat (4) @(posedge clk); #1; _reset = 1;
		repeat (4) @(posedge clk);

		$display("tb_dcd_disk");

		// ---------------------------------------------------------------
		// Mount
		// ---------------------------------------------------------------
		check("nothing is present before a mount", present === 1'b0);

		mount(64'd20971520, 1'b0);          // 20 MB, writable
		check("a mount makes the drive present", present === 1'b1);
		check("capacity is the image size in 512-byte blocks",
		      blockCount === 24'd40960);
		check("a writable mount is not read-only", readonly === 1'b0);

		// ---------------------------------------------------------------
		// Read, and the byte lanes
		// ---------------------------------------------------------------
		fork
			pulseRd(24'd1234);
			serveRead(24'd1234, 1'b1);
		join
		// sd_ack falls on a clock edge and the path leaves WAIT_DONE on the
		// next one, so busy is still high the instant the model returns.
		repeat (3) @(posedge clk); #1;
		check("the LBA reached the host unchanged", sd_lba === 32'd1234);
		check("the request is finished", busy === 1'b0);
		check("a good read raises no error", err === 1'b0);
		check("sd_rd stayed asserted for the whole transfer", mid_rd === 1'b1);
		check("  ...and the path stayed busy until the host let go", mid_busy === 1'b1);

		ok = 1'b1;
		for (i = 0; i < 512; i = i + 1) begin
			readByte(i[8:0], rdbyte);
			if (rdbyte !== diskByte(24'd1234, i)) ok = 1'b0;
		end
		check("every one of the 512 bytes reads back in disk order", ok);

		// Called out separately because it is the failure this bench exists
		// for: transposing the lanes still returns all 512 bytes, just pairwise
		// swapped, and every other check above still passes.
		readByte(9'd0, rdbyte);
		check("byte 0 came from the LOW half of the host word",
		      rdbyte === diskByte(24'd1234, 0));
		readByte(9'd1, rdbyte);
		check("byte 1 came from the HIGH half of the host word",
		      rdbyte === diskByte(24'd1234, 1));

		// ---------------------------------------------------------------
		// Streaming read: a new address EVERY clock. readByte() above holds
		// each address for two clocks, which hides whether the byte-lane
		// select is pipelined alongside the registered RAM output - and it
		// did: dropping the delay scored full marks. Walking the address
		// continuously is the only access pattern that tells them apart.
		// ---------------------------------------------------------------
		@(posedge clk); #1; buf_addr = 9'd0;
		for (k = 0; k < 512; k = k + 1) begin
			@(posedge clk); #1;
			buf_addr = (k + 1) % 512;   // address for the NEXT sample
			#2 stream[k] = buf_q;       // this one is byte k
		end
		ok = 1'b1;
		for (k = 0; k < 512; k = k + 1)
			if (stream[k] !== diskByte(24'd1234, k)) ok = 1'b0;
		check("a byte-per-clock walk reads the sector in order", ok);

		// ---------------------------------------------------------------
		// The shared sd_buff_wr strobe must not write our buffer when the
		// host is servicing a different slot.
		// ---------------------------------------------------------------
		served = 0;
		serveRead(24'd99, 1'b0);            // strobes, but never acks us
		check("a transfer for another slot does not ack us", busy === 1'b0);
		ok = 1'b1;
		for (i = 0; i < 16; i = i + 1) begin
			readByte(i[8:0], rdbyte);
			if (rdbyte !== diskByte(24'd1234, i)) ok = 1'b0;
		end
		check("another slot's sd_buff_wr left our sector alone", ok);

		// ---------------------------------------------------------------
		// Out of range
		// ---------------------------------------------------------------
		pulseRd(24'd40960);                 // one past the last block
		repeat (4) @(posedge clk); #1;
		check("a block at the capacity is refused", err === 1'b1);
		check("  ...and no read was issued to the host", sd_rd === 1'b0);
		check("  ...and the path did not go busy", busy === 1'b0);

		pulseRd(24'd40959);                 // the last valid block
		fork serveRead(24'd40959, 1'b1); join
		check("the last block IS in range", err === 1'b0);

		// ---------------------------------------------------------------
		// Write
		// ---------------------------------------------------------------
		for (i = 0; i < 512; i = i + 1) writeByte(i[8:0], diskByte(24'd7, i));
		fork
			pulseWr(24'd7);
			serveWrite;
		join
		check("a write raises no error on a writable mount", err === 1'b0);
		check("the write LBA reached the host", sd_lba === 32'd7);
		ok = 1'b1;
		for (i = 0; i < 512; i = i + 1)
			if (got[i] !== diskByte(24'd7, i)) ok = 1'b0;
		check("the host received all 512 bytes in disk order", ok);
		check("host word 0 low half is disk byte 0",
		      got[0] === diskByte(24'd7, 0) && got[1] === diskByte(24'd7, 1));

		// ---------------------------------------------------------------
		// Read-only
		// ---------------------------------------------------------------
		mount(64'd20971520, 1'b1);
		check("a read-only mount reports itself so", readonly === 1'b1);
		pulseWr(24'd7);
		repeat (4) @(posedge clk); #1;
		check("a write to a read-only mount is refused", err === 1'b1);
		check("  ...and no write was issued to the host", sd_wr === 1'b0);

		pulseRd(24'd7);
		fork serveRead(24'd7, 1'b1); join
		check("but a read-only mount still reads", err === 1'b0);

		// ---------------------------------------------------------------
		// Both requests at once. The command layer never does this, but the
		// tie-break must not be "write": a spurious write destroys data,
		// whereas a spurious read cannot.
		// ---------------------------------------------------------------
		mount(64'd20971520, 1'b0);
		@(posedge clk); #1;
		lba = 24'd20; rd_req = 1'b1; wr_req = 1'b1;
		@(posedge clk); #1;
		rd_req = 1'b0; wr_req = 1'b0;
		@(posedge clk); #1;
		check("a simultaneous read and write is resolved as a READ",
		      (sd_rd === 1'b1) && (sd_wr === 1'b0));
		fork serveRead(24'd20, 1'b1); join
		repeat (3) @(posedge clk);

		// ---------------------------------------------------------------
		// Timeout: an HPS that never acks must not wedge the drive.
		// ---------------------------------------------------------------
		pulseRd(24'd10);
		repeat (4) @(posedge clk); #1;
		check("the request is in flight while waiting for ack", sd_rd === 1'b1);
		repeat (600) @(posedge clk); #1;
		check("an unanswered request times out", err === 1'b1);
		check("  ...and the request line is released", sd_rd === 1'b0);
		check("  ...and the path is idle again", busy === 1'b0);

		// And it must recover: the next request has to work.
		pulseRd(24'd11);
		fork serveRead(24'd11, 1'b1); join
		check("the path recovers after a timeout", err === 1'b0);
		readByte(9'd3, rdbyte);
		check("  ...and serves the new sector", rdbyte === diskByte(24'd11, 3));

		// ---------------------------------------------------------------
		// An empty mount ejects.
		// ---------------------------------------------------------------
		mount(64'd0, 1'b0);
		check("an empty mount ejects the drive", present === 1'b0);
		pulseRd(24'd0);
		repeat (4) @(posedge clk); #1;
		check("a read with nothing mounted is refused", err === 1'b1);
		check("  ...and issues nothing to the host", sd_rd === 1'b0);

		// ---------------------------------------------------------------
		// A MAC RESET MUST NOT EJECT THE MEDIUM.
		//
		// The mount is HOST state: a real HD20 is a separate box with its own
		// power supply, so resetting the Mac neither ejects its disk nor spins
		// it down (scsi.v:389 makes the same argument for the CD). This is not
		// tidiness. The ROM's DCD probe at $418630 runs a few hundred ms into
		// every boot and img_mounted is a one-shot from the HPS that never
		// fires again, so a `present` cleared by _cpuReset can NEVER be 1 at
		// probe time - mount before boot and the reset clears it, mount after
		// boot and the probe has already gone. The drive was unidentifiable on
		// hardware for exactly this reason until 2026-09-05, and every test
		// above passed throughout: the bench reset once at time zero and then
		// never again, so it could not see it.
		// ---------------------------------------------------------------
		mount(64'd1024 * 64'd512, 1'b1);
		check("remounted ahead of the reset test", present === 1'b1);
		_reset = 0;
		repeat (4) @(posedge clk); #1;
		_reset = 1;
		repeat (4) @(posedge clk); #1;
		check("a reset does not eject the medium", present === 1'b1);
		check("  ...and the capacity survives it", blockCount === 24'd1024);
		check("  ...and the read-only flag survives it", readonly === 1'b1);

		$display("tb_dcd_disk: %0d/%0d", pass, pass + fail);
		if (fail != 0) $display("FAILED");
		$finish;
	end

	initial begin
		#50000000;
		$display("tb_dcd_disk: TIMEOUT");
		$finish;
	end

endmodule
