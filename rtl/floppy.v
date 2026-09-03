/* Synchronous 8-bit replica of 3.5 inch floppy disk drive.

	Differences from the true floppy interace at the Mac's DB-19 port:
	True interface has a writeReq control line, only 1-bit readData and writeData, and no clk.
	True interface does not have newByteReady signal. Instead the IWM must watch the data in bit and synchronize with it to
	   determine the timing and framing of bytes.
	
*/

/* Disk register (read):	
	    State-control lines       Register
  CA2    CA1    CA0    SEL    addressed    Information in register

  0      0      0      0      DIRTN        Head step direction (0=toward track 79, 1=toward track 0)
  0      0      0      1      CSTIN        Disk in place (0=disk is inserted)
  0      0      1      0      STEP         Drive head stepping (setting to 0 performs a step, returns to 1 when step is complete)
  0      0      1      1      WRTPRT       Disk locked (0=locked)
  0      1      0      0      MOTORON      Drive motor running (0=on, 1=off)
  0      1      0      1      TKO          Head at track 0 (0=at track 0)
  0		1		 1		  0		SWITCHED   	 Disk switched (1=yes?)
  0      1      1      1      TACH         Tachometer (produces 60 pulses for each rotation of the drive motor)
  1      0      0      0      RDDATA0      Read data, lower head, side 0
  1      0      0      1      RDDATA1      Read data, upper head, side 1 
  1      0      1      0      SUPERDR      Drive is a Superdrive (0=no, 1=yes)
  1      1      0      0      SIDES        Single- or double-sided drive (0=single side, 1=double side)
  1      1      0      1      READY        0 = yes
  1      1      1      0      INSTALLED	 0 = yes
  1      1      1      1      DRVIN        400K/800K: Drive installed (0=drive is present), Superdrive: Inserted disk capacity (0=HD, 1=DD)
	
	Disk registers (write):
    Control lines      Register
  CA1    CA0    SEL    addressed    Register function

  0      0      0      DIRTN        Set stepping direction (0=toward track 79, 1=toward track 0)
  0      0      1      SWITCHED		Reset disk switched flag (writing 1 sets switch flag to 0)
  0      1      0      STEP         Step the drive head one track (setting to 0 performs a step, returns to 1 when step is complete)
  1      0      0      MOTORON      Turn on/off drive motor (0=on, 1=off)
  1      1      0      EJECT        Eject the disk (writing 1 ejects the disk)
	
*/

`define DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
`define DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
	                           /* W: ?? reset disk switch flag ? */
`define DRIVE_REG_STEP		2  /* R: drive head is stepping (1 = complete) */
	                           /* W: 0 = step drive head */
`define DRIVE_REG_WRTPRT	3  /* R: 0 = disk is write-protected */
`define DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
`define DRIVE_REG_TK0		5  /* R: 0 = head at track 0 */
`define DRIVE_REG_EJECT		6  /* R: disk switched (1=yes?)*/
	                           /* W: 1 = eject the disk */
`define DRIVE_REG_TACH		7  /* R: tach-o-meter */
`define DRIVE_REG_RDDATA0	8  /* R: activate lower head: side 0 */
`define DRIVE_REG_RDDATA1	9  /* R: activate upper head: side 1 */
`define DRIVE_REG_SUPERDR	10 /* R: drive is a superdrive (0=no, 1=yes) */
`define DRIVE_REG_SIDES		12 /* R: number of sides (0=single, 1=dbl) */
`define DRIVE_REG_READY		13 /* R: drive ready (head loaded) (0=ready) */
`define DRIVE_REG_INSTALLED	14 /* R: drive present (0 = yes ??) */
`define DRIVE_REG_DRVIN		15 /* R: 400K/800k: drive present (0=yes, 1=no), Superdrive: disk capacity (0=HD, 1=DD) */

module floppy
(
	input clk,
	input cep,
	input cen,

	input _reset,
	input ca0,				// PH0
	input ca1,				// PH1
	input ca2,				// PH2
	input SEL, 				// HDSEL from VIA
	input lstrb,			// aka PH3
	input _enable,
	input [7:0] writeData,
	output [7:0] readData,

	input advanceDriveHead,  // prevents overrun when debugging, does not exist on a real Mac!
	output reg newByteReady,
	input insertDisk,
	input diskSides,
	// The DRIVE's capability, not the media's: 1 = 800K double-sided
	// mechanism, 0 = 400K single-sided. Constant per model (rtl/mac_model.v),
	// unlike diskSides above, which describes whichever image is mounted.
	input drive800k,
	// Spindle duty INDEX, 0..399, computed by dataController_top.sv exactly as
	// the hardware does: low 6 bits -> 64-entry table -> sum of 100 -> /10 - 11.
	// duty%% = index/4.19. Only a 400K mechanism obeys it; see the tachometer.
	input [8:0] disk_pwm,
	output diskEject,

	output motor,
	output act,

	output [21:0] dskReadAddr,
	input dskReadAck,
	input [7:0] dskReadData,

	// write path (Phase 3 of FLOPPY_WRITE_PLAN.md)
	input writeReq,        // pulse: CPU registered a new byte in the IWM write-data register
	input writeProtect,    // 1 = writes refused for this drive (OSD toggle ANDed with img_readonly)
	output writeBusy,      // 1 = write buffer full, mac must wait (iwm.v inverts for _iwmBusy)
	output writeUnderrun,  // 1 = an in-flight write byte was abandoned (iwm.v inverts for _writeUnderrun)

	output [21:0] dskWriteAddr,
	output [15:0] dskWriteData,
	output        dskWriteReq,
	input         dskWriteAck,

	// SD persistence tap (Phase 4 of FLOPPY_WRITE_PLAN.md): mirrors the
	// SDRAM commit above so a floppy_sd_writer instance outside this
	// module can build a byte-exact shadow of the committed sector.
	// Debug bundle for the JTAG deck (rtl/dbg_probes.sv). Costs a handful of
	// LEs and is optimised away when nothing reads it. Exists because the
	// 128K's floppy failure could not be narrowed further by inference: it
	// reports HOW FAR the head got and WHAT PWM RANGE the Mac actually used,
	// which together say whether the trouble is the CLV zone boundary or the
	// absolute calibration of the PWM->speed map.
	output [31:0] dbg_floppy,
	output        dskCommitDone,   // one clk pulse: sector fully committed to SDRAM
	output [21:0] dskCommitAddr,   // image byte offset of sector byte 0, valid at dskCommitDone
	output        dskCommitBufWr,
	output [7:0]  dskCommitBufAddr,
	output [15:0] dskCommitBufData
);

	assign motor = ~driveRegs[`DRIVE_REG_MOTORON];
	assign act = lstrbEdge;

	reg [15:0] driveRegs;
	reg [6:0] driveTrack;
	reg driveSide;
	reg [7:0] diskDataIn; // incoming byte from the floppy disk
	
	// read drive registers
	wire [15:0] driveRegsAsRead = {
		1'b0, // DRVIN = yes
		1'b0, // INSTALLED = yes
		1'b0, // READY = yes
		// SIDES: the 128K and 512K shipped a mechanically single-sided 400K
		// drive, and their 64K ROM behaves badly when it finds a
		// double-sided mechanism -- that is Sad Mac 0F0004, divide by zero,
		// the documented failure for a 64K-ROM Mac wired to an 800K drive.
		// Reporting the real mechanism is also simply accurate; it was
		// hardcoded because until MAC128K_PLAN.md Phase 3 every model the
		// core exposed genuinely had an 800K drive. MAC128K_PLAN.md item 8
		// gated the MEDIA on this same signal; this gates the MECHANISM,
		// which is the half that the ROM interrogates.
		drive800k, // SIDES: 1 = double-sided drive, 0 = single-sided
		1'b0, // UNUSED
		1'b0, // SUPERDR
		1'b0, // RDDATA1
		1'b0, // RDDATA0
		driveRegs[`DRIVE_REG_TACH], // TACH: 60 pules for each rotation of the drive motor
		diskSwitched, // disk switched?
		~(driveTrack == 7'h00), // TK0: track 0 indicator
		driveRegs[`DRIVE_REG_MOTORON], // motor on
		~writeProtect, // WRTPRT: 0 = locked, 1 = write enabled
		1'b1, // STEP = complete
		driveRegs[`DRIVE_REG_CSTIN], // disk in drive
		driveRegs[`DRIVE_REG_DIRTN] // step direction
	};

	reg dskReadAckD;
	always @(posedge clk) if(cen) dskReadAckD <= dskReadAck;

	// latch incoming data
	reg [7:0] dskReadDataLatch;
	always @(posedge clk) if(cep && dskReadAckD) dskReadDataLatch <= dskReadData;
		
	wire [7:0] dskReadDataEnc;
	
	reg old_newByteReady;
	always @(posedge clk) old_newByteReady <= newByteReady;
	
	// include track encoder
	floppy_track_encoder enc
	(

		.clk		( clk ),
		.ready	( ~old_newByteReady & newByteReady ),

		.rst     ( !_reset ),
		
		.side    ( driveSide ),
		.sides   ( doubleSidedDisk ),
		.track   ( driveTrack ),

		.addr    ( dskReadAddr ),
		.idata   ( dskReadDataLatch ),
		.odata   ( dskReadDataEnc )
	);

	// TODO: auto-detect doubleSidedDisk from image file size
	wire doubleSidedDisk = diskSides;

	// ---------------------------------------------------------------------
	// Write path (Phase 3 of FLOPPY_WRITE_PLAN.md).
	//
	// CPU-supplied bytes are paced at the same 128-clk8 (16us) byte time as
	// the read side's diskDataByteTimer below, then handed to
	// floppy_track_decoder. A completed, checksum-valid sector is drained
	// to SDRAM by floppy_write_committer over the same shared extra-slot-3
	// port floppy_loader.v uses for mounting - loader and committer never
	// contend in practice (loader only runs at mount, committer only after
	// a write completes), and MacPlus.sv gives the loader fixed priority
	// on the rare chance they do overlap.
	//
	// writeUnderrun is a real signal, not a hardwired constant, but this
	// synchronous byte-at-a-time replica has only one path that can
	// meaningfully raise it: the drive being deselected/disabled with a
	// byte still in flight (abandoned before its 16us window completed).
	// A true "CPU too slow to supply the next byte" underrun has no
	// independent clock to detect against in this model, the same
	// idealization already accepted on the read side (see
	// advanceDriveHead's comment above).
	reg        writeBusyReg;
	reg [6:0]  writeByteTimer;
	reg [7:0]  pendingWriteByte;
	reg        writeUnderrunReg;
	reg        decReady;

	assign writeBusy     = writeBusyReg;
	assign writeUnderrun = writeUnderrunReg;

	// Any disk change - an OS-driven eject or a fresh HPS/OSD mount - must
	// not let a field the decoder/committer had half-decoded for the
	// departing image be completed by bytes belonging to the next one
	// (which would commit a mixed sector). ejectPulse mirrors the exact
	// eject-detect condition the CSTIN write-register block below uses.
	// insertDisk itself is a LEVEL held high for as long as a disk stays
	// mounted (see MacPlus.sv: dsk_int_ins/dsk_ext_ins are registers set on
	// ldr_*_done and cleared only on eject/remount), not a one-shot mount
	// pulse, so the actual "a new image just landed" event is its rising
	// edge - same idiom as lstrbEdge just below.
	// Reset to a CONSTANT 1, which happens to be exactly the "suppress the
	// spurious edge" behaviour wanted here: a plain reset with a disk
	// already mounted - the common case, e.g. a Mac "Reset & Apply" - must
	// not manufacture an edge the instant reset lifts, which would
	// otherwise land on (and swallow) the very first legitimate write byte
	// via the branch below. With prev=1 and insertDisk=1 there is no edge;
	// with no disk mounted insertDisk is 0 so there is no edge either, and
	// prev tracks down to 0 on the first cep so a LATER real mount still
	// produces a proper one.
	//
	// An earlier version seeded this from the live insertDisk level inside
	// the reset branch. Verilog accepts that and Icarus simulates it, but
	// an asynchronous reset must resolve to a constant: Quartus cannot
	// build an async LOAD, so it split the register into a flop plus a
	// transparent latch (Warning 13004/13310, both drive instances) and
	// TimeQuest then reported the result as a combinational loop it was
	// "analyzing as a latch" - i.e. untimed logic, powering up undefined,
	// feeding writePathReset below. Do not reintroduce a non-constant here.
	reg insertDiskPrev;
	always @(posedge clk or negedge _reset)
		if (!_reset)   insertDiskPrev <= 1'b1;
		else if (cep)  insertDiskPrev <= insertDisk;
	wire insertDiskEdge = insertDisk && !insertDiskPrev;
	wire insertDiskFall = !insertDisk && insertDiskPrev;

	wire ejectPulse = cep && _enable == 1'b0 && lstrbEdge == 1'b1 &&
	                   driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1;

	// Both EDGES of insertDisk matter, not just the rising one. insertDisk
	// drops at img_mounted (the loader starting to stream a new image into
	// SDRAM) and only rises again at ldr_*_done. Resetting on the rising
	// edge alone left the whole load window - hundreds of ms for an 800K
	// image - with the departing disk's half-decoded field still sitting in
	// dec, and a byte already in the 16us pacer could be the very DE/AA
	// that completes it, committing the old disk's sector into the newly
	// mounted image. The falling edge discards that field (and the in-
	// flight byte) the moment the image starts changing underneath it.
	wire writePathReset = ejectPulse || (cep && (insertDiskEdge || insertDiskFall));

	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			writeBusyReg     <= 1'b0;
			writeByteTimer   <= 7'd0;
			pendingWriteByte <= 8'd0;
			writeUnderrunReg <= 1'b0;
			decReady         <= 1'b0;
		end else if (writePathReset) begin
			// abandon any in-flight write byte, same as the deselect path
			// below, but triggered by the disk itself changing underneath it
			writeBusyReg     <= 1'b0;
			writeByteTimer   <= 7'd0;
			decReady         <= 1'b0;
		end else begin
			decReady <= 1'b0; // default; pulsed for exactly one cep below

			// byte pacing runs on the same clk8 cadence as diskDataByteTimer
			if (cep && writeBusyReg) begin
				if (_enable == 1'b1) begin
					// drive deselected mid-byte: it never reached the media
					writeBusyReg     <= 1'b0;
					writeUnderrunReg <= 1'b1;
				end else if (writeByteTimer == 7'd127) begin
					writeBusyReg <= 1'b0;
					decReady     <= 1'b1; // hand this byte to the decoder now
				end else begin
					writeByteTimer <= writeByteTimer + 1'b1;
				end
			end

			// Byte acceptance happens whenever the IWM registers a new
			// write-data byte for this drive (iwm.v's writeReq pulses on
			// `cen`, not `cep` - this is a plain register capture, not an
			// SDRAM access, so it carries none of addrController_top.v's
			// 4-phase RAS/CAS discipline). cen and cep never coincide, so
			// this cannot race the block above.
			//
			// insertDisk is checked as well as CSTIN, and they are not
			// redundant: CSTIN is only ever SET by an explicit OS eject
			// strobe (see its own block below) and is never restored to
			// "no disk" on an OSD remount, so through an entire image
			// reload it still reads "disk present" while insertDisk is
			// correctly low. Without this term the Mac could keep feeding
			// write bytes all the way through a swap, and a field
			// completing then would commit the departing disk's sector
			// into the newly mounted image - in SDRAM and, via
			// floppy_sd_writer, into the new .dsk on the SD card.
			if (writeReq && _enable == 1'b0 && !writeProtect && !writeBusyReg &&
			    !driveRegs[`DRIVE_REG_CSTIN] && insertDisk) begin
				pendingWriteByte <= writeData;
				writeBusyReg     <= 1'b1;
				writeByteTimer   <= 7'd0;
				writeUnderrunReg <= 1'b0;
			end
		end
	end

	wire        secValid, secReject;
	wire [3:0]  secNum;
	wire [21:0] secAddr;
	wire [8:0]  wcBufAddr;
	wire [7:0]  wcBufData;

	floppy_track_decoder dec
	(
		.clk          ( clk ),
		.ready        ( decReady ),
		.rst          ( !_reset || writePathReset ),

		.side         ( driveSide ),
		.sides        ( doubleSidedDisk ),
		.track        ( driveTrack ),

		.idata        ( pendingWriteByte ),

		.sector_valid ( secValid ),
		.sector       ( secNum ),
		.addr         ( secAddr ),
		.reject       ( secReject ),

		.buf_addr     ( wcBufAddr ),
		.buf_data     ( wcBufData )
	);

	floppy_write_committer wc
	(
		.clk          ( clk ),
		.rst          ( !_reset || writePathReset ),

		.sector_valid ( secValid ),
		.sector_addr  ( secAddr ),
		.buf_addr     ( wcBufAddr ),
		.buf_data     ( wcBufData ),

		.wr_addr      ( dskWriteAddr ),
		.wr_data      ( dskWriteData ),
		.wr_req       ( dskWriteReq ),
		.wr_ack       ( dskWriteAck ),

		.busy         (  ),
		.done         ( dskCommitDone ),
		.committed_addr ( dskCommitAddr ),

		.sd_buf_addr  ( dskCommitBufAddr ),
		.sd_buf_data  ( dskCommitBufData ),
		.sd_buf_wr    ( dskCommitBufWr )
	);
	
	wire [3:0] driveReadAddr = {ca2,ca1,ca0,SEL};
	
	// a byte is read or written every 128 clocks (2 us per bit * 8 bits = 16 us, @ 8 MHz = 128 clocks)
	// The CPU must poll for data at least this often, or else an overrun will occur.
	reg [6:0] diskDataByteTimer; 
	reg [7:0] diskImageData;	
	reg readyToAdvanceHead;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 0) begin		
			driveSide <= 0;
			diskImageData <= 8'h00;
			diskDataIn <= 8'hFF;
			diskDataByteTimer <= 0;
			readyToAdvanceHead <= 1;
			newByteReady <= 1'b0;
		end 
		else begin			
			if(cep) begin
			// at time 0, latch a new byte and advance the drive head
			if (diskDataByteTimer == 0 && readyToAdvanceHead && diskImageData != 0) begin
				diskDataIn <= diskImageData;
				newByteReady <= 1;
				diskDataByteTimer <= 1;  // make timer run again

				// clear diskImageData after it's used, so we can tell when we get a new one from the disk	
				diskImageData <= 0;

				// for debugging, don't advance the head until the IWM says it's ready
				readyToAdvanceHead <= 1'b1; // TEMP: treat IWM as always ready
			end

			// extraRomReadAck comes every hsync which is every 21us. The iwm data rates
			// is 8MHZ/128 = 16us
			else begin
				// a timer governs when the next disk byte will become available
				diskDataByteTimer <= diskDataByteTimer + 1'b1;

				newByteReady <= 1'b0;

				if (dskReadAck) begin
					// whenever ACK is received, store the data from the current diskImageAddr 
					diskImageData <= dskReadDataEnc;  // xyz
 				end

				if (advanceDriveHead) begin
					readyToAdvanceHead <= 1'b1;
				end
			end

			// switch drive sides if DRIVE_REG_RDDATA0 or DRIVE_REG_RDDATA1 are read
			// TODO: we don't know if this is a true read, since we don't know if IWM is selected or 
			// could be bad if we use this test to flush a cache of encoded disk data
			if (driveReadAddr == `DRIVE_REG_RDDATA0 && lstrb == 1'b0)
				driveSide <= 0;
			if (driveReadAddr == `DRIVE_REG_RDDATA1 && lstrb == 1'b0)
				driveSide <= 1;	
		end
	end
	end

	// create a signal on the falling edge of lstrb
	reg lstrbPrev;
	always @(posedge clk) if(cep) lstrbPrev <= lstrb;

	wire lstrbEdge = lstrb == 1'b0 && lstrbPrev == 1'b1;

	assign readData = _enable ? 8'hFF :
	                  (driveReadAddr == `DRIVE_REG_RDDATA0 || driveReadAddr == `DRIVE_REG_RDDATA1) ? diskDataIn :
							{ driveRegsAsRead[driveReadAddr], 7'h00 };
		
	// write drive registers
	wire [2:0] driveWriteAddr = {ca1,ca0,SEL};
	
	// DRIVE_REG_DIRTN		0  /* R/W: step direction (0=toward track 79, 1=toward track 0) */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_DIRTN] <= 1'b0;
		end 
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_DIRTN) begin
			driveRegs[`DRIVE_REG_DIRTN] <= ca2;
		end
	end


	// DRIVE_REG_CSTIN		1  /* R: disk in place (1 = no disk) */
										/* W: ?? reset disk switch flag ? */
	// disk in drive indicators
	reg [23:0] ejectIndicatorTimer;
	assign diskEject = (ejectIndicatorTimer != 0);
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
			ejectIndicatorTimer <= 24'd0;
		end 
		else if(cep) begin
			if (_enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_EJECT && ca2 == 1'b1) begin
				// eject the disk
				driveRegs[`DRIVE_REG_CSTIN] <= 1'b1;
				ejectIndicatorTimer <= 24'hFFFFFF;
			end
			else if (insertDisk) begin
				// insert a disk
				driveRegs[`DRIVE_REG_CSTIN] <= 1'b0;
			end
			else begin
				if (ejectIndicatorTimer != 0)
					ejectIndicatorTimer <= ejectIndicatorTimer - 1'b1;
			end
		end
	end

	// SWITCHED (Phase 5 item 3): set on the same two disk-change events
	// writePathReset above already reacts to (an OS eject, or a fresh
	// mount's insertDisk edge), cleared only when the Mac explicitly writes
	// the reset-disk-switched register (driveWriteAddr==`DRIVE_REG_CSTIN`,
	// its write-side function per the header table: "writing 1 sets switch
	// flag to 0"). Previously hardwired to 0 in driveRegsAsRead, and this
	// write decode existed but was consumed by nothing.
	reg diskSwitched;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			diskSwitched <= 1'b0;
		end
		else if (ejectPulse || (cep && insertDiskEdge)) begin
			diskSwitched <= 1'b1;
		end
		else if (cep && _enable == 1'b0 && lstrbEdge == 1'b1 &&
		         driveWriteAddr == `DRIVE_REG_CSTIN && ca2 == 1'b1) begin
			diskSwitched <= 1'b0;
		end
	end

	// ---- debug telemetry v2 (see the dbg_floppy port comment) -----------
	// v1 wasted three of its four fields. curTrack read 0 always, the PWM
	// min/max saturated to 0..255 on a WORKING Plus as well as on the
	// failing 128K (so it measured nothing), and `switched` was a sticky
	// seen-latch that is set by any mount and would read 1 on a healthy
	// machine too. Only maxTrack earned its bits: Plus 52, 64K models 0.
	//
	// v2 answers the two questions that actually fork the diagnosis:
	//
	//   stepWrites  Does the ROM ever ASK to step? The identical RTL steps
	//               fine on the Plus, so either the 64K ROM never issues a
	//               step (it gave up earlier) or it issues one we reject.
	//               No amount of code reading separates those two.
	//   pwmLive +   Is disk_pwm a control signal or noise? The Mac writes a
	//   pwmChanges  CONSTANT PWM into every word of the sound buffer, so a
	//               real one is stable between samples and changes only when
	//               the ROM decides to. A change count that pins means we
	//               are frequency-modulating the tachometer with whatever
	//               happens to be in that buffer -- which would explain the
	//               inconsistent symptoms, and nothing else so far does.
	reg [6:0] dbgMaxTrack;
	reg [7:0] dbgPwmChanges;
	reg [6:0] dbgStepWrites;
	reg [7:0] dbgPwmPrev;   // top 8 of the averaged duty
	reg       dbgMotorSeen;
	wire dbgStepStrobe = cep && _enable == 1'b0 && lstrbEdge == 1'b1 &&
	                     driveWriteAddr == `DRIVE_REG_STEP && ca2 == 1'b0;
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin
			dbgMaxTrack    <= 7'd0;
			dbgPwmChanges  <= 8'd0;
			dbgStepWrites  <= 7'd0;
			dbgPwmPrev     <= 8'd0;
			dbgMotorSeen   <= 1'b0;
		end else begin
			dbgPwmPrev <= disk_pwm[12:5];
			if (disk_pwm[12:5] != dbgPwmPrev && ~&dbgPwmChanges)
				dbgPwmChanges <= dbgPwmChanges + 1'd1;
			if (dbgStepStrobe && ~&dbgStepWrites)
				dbgStepWrites <= dbgStepWrites + 1'd1;
			if (cep) begin
				if (driveTrack > dbgMaxTrack) dbgMaxTrack <= driveTrack;
				if (motor)                    dbgMotorSeen <= 1'b1;
			end
		end
	end
	// disk_pwm is 13 bits now (a 128-sample sum); the top 8 keep the field at
	// 8 bits so the bundle still packs to exactly 32. Reported value is
	// therefore duty/32, i.e. 0..252 for a full-scale 0..8064.
	assign dbg_floppy = {disk_pwm[12:5], dbgPwmChanges, dbgStepWrites,
	                     dbgMaxTrack, dbgMotorSeen, motor};

	//`define DRIVE_REG_STEP		2  /* R: drive head stepping (1 = complete) */
												/* W: 0 = step drive head */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin	
			driveTrack <= 0; 
		end 
		else if(cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_STEP && ca2 == 1'b0) begin
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b0 && driveTrack != 7'h4F) begin
				driveTrack <= driveTrack + 1'b1;
			end
			if (driveRegs[`DRIVE_REG_DIRTN] == 1'b1 && driveTrack != 0) begin
				driveTrack <= driveTrack - 1'b1;
			end
		end
	end
	
	// DRIVE_REG_MOTORON	4  /* R/W: 0 = motor on */
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_MOTORON] <= 1'b1;
		end 
		else if (cep && _enable == 1'b0 && lstrbEdge == 1'b1 && driveWriteAddr == `DRIVE_REG_MOTORON) begin
			driveRegs[`DRIVE_REG_MOTORON] <= ca2;
		end
	end

	// DRIVE_REG_TACH  7  Tachometer (produces 60 pulses for each rotation of the drive motor)
	/* Data from MESS, sonydriv.c:
	   Tracks	RPM   Timing Value
	   00-15:   500   timing value $117B (acceptable range {1135-11E9})
	   16-31:   550   timing value $???? (acceptable range {12C6-138A})
	   32-47:   600   timing value $???? (acceptable range {14A7-157F})
	   48-63:   675   timing value $???? (acceptable range {16F2-17E2})
	   64-79:   750   timing value $???? (acceptable range {19D0-1ADE})

	   CAUTION: those RPM labels are WRONG and cost time. The real CLV speeds
	   (Guide to the Macintosh Family Hardware) are 402/438/482/536/603 rpm.
	   The PERIODS below are right -- RPM = clk8 / (2*period), since TACH is
	   60 pulses (120 edges) per revolution: 9996 -> 406 rpm, 9122 -> 445,
	   8292 -> 490, 7463 -> 544, 6634 -> 612, all within ~1.5%% of the real
	   table. Only the labels in this comment were wrong.
		
		Experimentally determined toggle rates for Plus Too with 8.125 MHz CPU clock:
		TACH Half Period Clocks		Resulting Timing Value
					9996					$117B (4475)
					9122  				$1328 (4904)
					8292  				$1513 (5395)
					7463  				$176A (5994)
					6634					$1A56 (6742)
	*/
	
	reg [13:0] driveTachTimer; 
	reg [13:0] driveTachBase;
	
	always @(*) begin
		case (driveTrack[6:4])
			0: // tracks 0-15
				driveTachBase <= 9996;
			1: // tracks 16-31
				driveTachBase <= 9122;
			2: // tracks 32-47
				driveTachBase <= 8292;
			3: // tracks 48-63
				driveTachBase <= 7463;
			default: // tracks 64-79
				driveTachBase <= 6634;	
		endcase
	end

	// ---- spindle speed: who controls it, the Mac or the drive? ---------
	//
	// This is the whole of Sad Mac 0F0004, and the table above is only half
	// the story. On a 400K mechanism the Mac controls motor speed IN
	// SOFTWARE: it writes a PWM byte into the low byte of every word of the
	// sound buffer (captured in dataController_top.sv and passed in here as
	// disk_pwm) and closes the loop by reading TACH back. An 800K mechanism
	// self-regulates and ignores the PWM entirely.
	//
	// The 64K ROM calibrates by measuring the tach, CHANGING the PWM, and
	// measuring again -- then dividing by the difference between the two
	// measurements. Against a drive that ignores the PWM both measurements
	// come out identical, the divisor is zero, and the ROM takes a divide-
	// by-zero exception: class 0F, subclass 0004. That is the documented
	// reason a 64K-ROM Mac cannot boot from an 800K drive, and until now
	// this core WAS such a drive -- the period depended only on the track,
	// so no PWM write could ever move it.
	//
	// Reporting SIDES=0 did not help precisely because the ROM never asks:
	// it discovers the drive type by whether the speed responds.
	//
	// The PWM TRIMS the per-track period rather than setting it outright.
	// That keeps the known-good table as the natural operating point, so the
	// ROM's loop converges on the speed this core already reads disks at,
	// instead of settling somewhere derived from a curve nobody has
	// measured. All the ROM needs is a response that is monotonic and has
	// room either side of the target; +/-8 counts per PWM step gives about
	// +/-10%, comfortably outside the acceptance windows in the table above
	// and well inside 14 bits at both extremes (5618 .. 11020).
	//
	// Plus/SE/512Ke keep the old fixed behaviour, which is both authentic
	// for their 800K drive and already proven on hardware.
	// A real 400K drive HAS NO IDEA WHICH TRACK THE HEAD IS ON. Its speed is
	// a function of the commanded duty alone, and the Mac gets the different
	// speed for each CLV zone by COMMANDING A DIFFERENT DUTY. So the period
	// below must not consult driveTachBase at all.
	//
	// disk_pwm is the SUM OF THE LOW 6 BITS OF 128 CONSECUTIVE sound-buffer
	// words, not one sampled byte -- see dataController_top.sv for why that
	// distinction is the whole bug. Range 0..8064.
	//
	// The map only has to be monotonic and to cover the CLV range the ROM
	// asks for (periods 9996..6634, i.e. 500..750 RPM in the table above),
	// because the actual byte rate this core delivers is fixed and does not
	// depend on the modelled speed -- exactly as a real drive's constant
	// data rate does not. The real duty->speed curve goes through a lookup
	// table nobody here has, but the ROM closes its own loop by measuring,
	// so a monotonic line with headroom at both rails converges just as
	// well: 11000 - (duty*81 >> 7) spans 11000..5897 across the full range.
	//
	// Plus/SE/512Ke keep the track-indexed table: an 800K mechanism
	// self-regulates, which is both authentic and already proven on
	// hardware.
	// The duty index sets the speed outright, as it does on real hardware.
	//
	// Earlier attempts here trimmed the per-track table instead, because the
	// duty->speed calibration was unknown. It is not unknown any more: the
	// documented curve is 9.4%% duty -> ~305-380 rpm and 91%% -> ~625-780 rpm,
	// i.e. HIGHER DUTY IS FASTER, monotonic, and the drive has no idea which
	// track the head is on. With the conversion table finally applied in
	// dataController_top.sv, disk_pwm is a real duty index and this can be a
	// straight map again.
	//
	// Fitted to the two documented operating points rather than guessed:
	// index 101 is ~402 rpm (period 9996, tracks 0-15) and index 302 is
	// ~603 rpm (period 6634, tracks 64-79), giving period = 11686 - 17*index
	// over 0..399 = 11686..4903. That brackets the whole CLV table with the
	// ROM's own operating range sitting comfortably mid-scale, which is what
	// a converging loop needs -- the previous maps put it near a rail.
	//
	// Exact absolute accuracy is not required: the ROM CALIBRATES against
	// whatever curve the drive presents, measuring at two duties before
	// choosing one. Monotonic, correctly signed, and covering the range is
	// what matters -- and all three failed before only because the table was
	// missing upstream.
	//
	// Plus/SE/512Ke keep the track-indexed table: an 800K mechanism
	// self-regulates, which is authentic and hardware-proven.
	wire [13:0] pwm_span   = {disk_pwm, 4'b0} + {5'b0, disk_pwm}; // index*17
	wire [13:0] pwm_period = 14'd11686 - pwm_span;                // 11686..4903
	wire [13:0] driveTachPeriod = drive800k ? driveTachBase : pwm_period;
	
	always @(posedge clk or negedge _reset) begin
		if (_reset == 1'b0) begin		
			driveRegs[`DRIVE_REG_TACH] <= 1'b0;
			driveTachTimer <= 0;
		end 
		else if(cep) begin
			if (driveTachTimer == driveTachPeriod) begin
				driveTachTimer <= 0;
				driveRegs[`DRIVE_REG_TACH] <= ~driveRegs[`DRIVE_REG_TACH];
			end
			else begin
				driveTachTimer <= driveTachTimer + 1'b1;
			end
		end
	end	
endmodule
