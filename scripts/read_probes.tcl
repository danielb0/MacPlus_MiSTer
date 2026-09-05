# Read the MacPlus SCSI JTAG probes over the DE10-Nano's USB-Blaster.
#
#   quartus_stp -t scripts/read_probes.tcl          one sample, decoded
#   quartus_stp -t scripts/read_probes.tcl 20 0.5   20 samples, 0.5 s apart
#   quartus_stp -t scripts/read_probes.tcl 20 0.5 clear
#                                                   zero PDCD's sticky fields
#                                                   first, then sample
#
# `clear` matters for the DCD probe and nothing else. PDCD/PDC2 are sticky by
# design -- the events they record are sub-millisecond and JTAG samples land
# 0.4 s apart -- and sticky state that cannot be zeroed is readable once per
# power cycle. Clear, then provoke the fault from HD Diag, then read.
#
# Sample REPEATEDLY while the Mac is wedged. A single sample says where the CPU
# is; a series says whether it is looping (PIFA fetch count advancing, address
# histogramming over a small range) or truly dead on the bus (count frozen).
#
# Probe deck is defined in rtl/dbg_probes.sv and built only when the
# USE_SCSI_ISSP macro is set in MacPlus.qsf.

array set ipairs {}
array set absent {}
set samples 1
set delay   0.5
set do_clear 0
set posargs {}
foreach a $argv {
	if {[string equal -nocase $a "clear"]} { set do_clear 1 } else { lappend posargs $a }
}
if {[llength $posargs] >= 1} { set samples [lindex $posargs 0] }
if {[llength $posargs] >= 2} { set delay   [lindex $posargs 1] }

# ---- find the board -------------------------------------------------------
# The DE10-Nano's on-board blaster enumerates as "DE-SoC [USB-n]", NOT as
# "USB-Blaster" -- match either.
set hw ""
foreach h [get_hardware_names] {
	if {[string match "*DE-SoC*" $h] || [string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} {
	set all [get_hardware_names]
	if {[llength $all] > 0} { set hw [lindex $all 0] }
}
if {$hw eq ""} {
	puts "ERROR: no JTAG hardware found. Is the DE10-Nano connected and powered?"
	exit 1
}
# The chain is {@1 SOCVHPS, @2 5CSEBA6}: the ARM HPS comes FIRST and carries no
# ISSP hub. Match the FPGA explicitly and never fall back to device 1.
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break }
}
if {$dev eq ""} {
	puts "ERROR: no Cyclone V FPGA in the chain. Devices seen:"
	foreach d [get_device_names -hardware_name $hw] { puts "   $d" }
	exit 1
}
puts "hardware: $hw"
puts "device:   $dev"
puts ""

# ---- map instance ids -----------------------------------------------------
# The ISSP hub enumerates by index, not by name, so build the mapping once.
array set idx {}
# This query must run OUTSIDE a session -- starting one first fails with
# "there is already an active In-System Sources and Probes session".
if {[catch {
	set info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
} err]} { puts "ERROR reading instance info: $err"; exit 1 }
if {[llength $info] == 0} {
	puts "ERROR: no ISSP instances. Is the USE_SCSI_ISSP build actually loaded?"
	exit 1
}
# Start from a clean slate: a stale idx() entry from an earlier run would make
# have{} claim a probe exists that this bitstream does not carry.
array unset idx
array unset absent
array set idx {}
array set absent {}
foreach inst $info {
	# {index source_width probe_width instance_name}
	set idx([lindex $inst 3]) [lindex $inst 0]
	puts [format "  found %-6s index=%s probe_width=%s" [lindex $inst 3] [lindex $inst 0] [lindex $inst 2]]
}
puts ""

# One session for the whole run, rather than one per probe read.
start_insystem_source_probe -hardware_name $hw -device_name $dev

# PDCD's source is the only one connected anywhere in the deck: hold it high to
# zero every sticky field and counter in the DCD block, then drop it to arm.
if {$do_clear} {
	if {[info exists idx(PDCD)]} {
		write_source_data -instance_index $idx(PDCD) -value 1
		after 100
		write_source_data -instance_index $idx(PDCD) -value 0
		puts "PDCD cleared and armed -- provoke the fault NOW, then read."
		puts ""
	} else {
		puts "WARNING: `clear` was asked for, but this bitstream carries no PDCD."
		puts ""
	}
}

# A probe that is NOT in the running bitstream must never be reported as data.
# It used to return 0, and every field derived from it printed as a confident
# number: a capture from a build predating PDM3 rendered a full PDM3 block
# reading "at the DMA arm: phase=IDLE ... no DACK access at all since the arm",
# which is pure fiction, and PBLD read 00000000, which looks like an unstamped
# tag rather than an absent probe. Same failure mode as the 4-bit wrap counter
# that cost this investigation a day. Absent probes are now declared, and the
# blocks that depend on them are suppressed rather than invented.
proc have {name} { global idx; return [info exists idx($name)] }

proc rd {name} {
	global idx absent
	if {![info exists idx($name)]} { set absent($name) 1; return 0 }
	set bits [read_probe_data -instance_index $idx($name)]
	if {$bits eq ""} { return 0 }
	return [expr 0b$bits]
}

proc b2i {v} { return $v }

set prev_wr -1
for {set n 0} {$n < $samples} {incr n} {
	set pifd [b2i [rd PIFD]]
	set pios [b2i [rd PIOS]]
	set pio2 [b2i [rd PIO2]]
	set pio3 [b2i [rd PIO3]]
	set pio4 [b2i [rd PIO4]]
	set phld [b2i [rd PHLD]]
	set pifa [b2i [rd PIFA]]
	set pact [b2i [rd PACT]]
	set pscs [b2i [rd PSCS]]
	set pscw [b2i [rd PSCW]]
	set podr [b2i [rd PODR]]

	set if_cnt  [expr ($pifa >> 24) & 0xff]
	set if_addr [expr  $pifa & 0xffffff]

	set rd_cnt [expr ($pscs >> 24) & 0xff]
	set rd_val [expr ($pscs >> 16) & 0xff]
	set rd_sel [expr ($pscs >> 12) & 0xf]
	set wr_cnt [expr ($pscw >> 24) & 0xff]
	set wr_val [expr ($pscw >> 16) & 0xff]
	set wr_sel [expr ($pscw >> 12) & 0xf]

	# rd_sel/wr_sel = {dack, reg[2:0]}; reg numbers per rtl/ncr5380.sv
	# Read and WRITE register spaces are different chips' worth of meaning at
	# the same addresses -- reg 7 reads as RESET but writes as START DMA
	# INITIATOR RECEIVE. Labelling a write with the read name is how you
	# misread an armed pseudo-DMA as a reset.
	set rdname {CDR ICR MR TCR CSR BSR IDR RST}
	set wrname {ODR ICR MR TCR SER DMAsend DMAtargRcv DMAinitRcv}
	proc selstr {s dir} {
	global rdname wrname
	set r [expr {$s & 0x7}]
	set d [expr {($s >> 3) & 1}]
	if {$dir eq "r"} { set n [lindex $rdname $r] } else { set n [lindex $wrname $r] }
	if {$d} { return "$n (DACK)" }
	return $n
}

	if {[have PBLD]} {
		set pbld [b2i [rd PBLD]]
		if {$pbld == 0} {
			puts [format "sample %d   bitstream=UNSTAMPED (PBLD present, tag reads 0 -- rtl/build_tag.v did not make it into the build)" $n]
		} else {
			puts [format "sample %d   bitstream=%08X" $n $pbld]
		}
	} else {
		set absent(PBLD) 1
		puts [format "sample %d   bitstream=UNKNOWN -- this build has NO PBLD probe, so it predates ac38fc9" $n]
	}
	puts [format "  PIFA  fetch#%3d  PC=%06X      <- where the CPU is" $if_cnt $if_addr]
	# PFLP v2 = {pwmLive[7:0], pwmChanges[7:0], stepWrites[6:0], maxTrack[6:0], motorSeen, motor}
	# Packing mirrors rtl/floppy.v's dbg_floppy assign; keep the two in step.
	#
	# v1's curTrack / pwm-min-max / switched fields all measured nothing (a
	# WORKING Plus read 0..255 and switched=1 too). Only maxTrack earned its
	# bits: Plus 52, both 64K models 0.
	#
	# stepWrites is the fork: the identical RTL steps fine on the Plus, so
	# either the 64K ROM never issues a step, or it issues one we reject.
	# pwmLive across samples says whether disk_pwm is a control signal the Mac
	# is holding steady, or noise we are frequency-modulating the tach with.
	if {[have PFLP]} {
		set pflp [b2i [rd PFLP]]
		set f_pwm   [expr ($pflp >> 24) & 0xFF]
		set f_pchg  [expr ($pflp >> 16) & 0xFF]
		set f_step  [expr ($pflp >>  9) & 0x7F]
		set f_max   [expr ($pflp >>  2) & 0x7F]
		set f_mseen [expr ($pflp >>  1) & 0x1]
		set f_mot   [expr  $pflp        & 0x1]
		set zone    [expr {$f_max / 16}]
		puts [format "  PFLP  maxTrack=%2d (CLV zone %d)  motor=%d (everSpun=%d)" $f_max $zone $f_mot $f_mseen]
		if {$f_step == 0} {
			puts "  PFLP  step requests: NONE -- the ROM never asked to seek, so it gave up BEFORE stepping"
		} elseif {$f_step >= 127} {
			puts "  PFLP  step requests: 127+ (saturated) -- the ROM is seeking; if maxTrack is still 0 we are REJECTING them"
		} else {
			puts [format "  PFLP  step requests: %d   (maxTrack %d -- these should agree unless we reject steps)" $f_step $f_max]
		}
		if {$f_pchg >= 255} {
			puts [format "  PFLP  duty index = %d/199, changes SATURATED -- expected while the ROM hunts; a value that SETTLES mid-range is the pass signal" $f_pwm]
		} else {
			puts [format "  PFLP  duty index = %d/199 (half of the 0..399 index; ~402rpm at 50, ~603rpm at 151), changed %d times" $f_pwm $f_pchg]
		}
	} else {
		set absent(PFLP) 1
		puts "  PFLP  ABSENT from this bitstream -- predates the floppy telemetry probe."
	}
	# PDCD/PDC2: the DCD (Apple HD20) link. Packing mirrors rtl/dbg_probes.sv;
	# keep the two in step. Every field but the four marked "now" is sticky and
	# survives until the next `clear`.
	if {[have PDCD]} {
		set pdcd [b2i [rd PDCD]]
		set pdc2 [b2i [rd PDC2]]
		set d_seen  [expr {($pdcd >> 24) & 0xFF}]
		set d_op    [expr {($pdcd >> 16) & 0xFF}]
		set d_rxhs  [expr {($pdcd >> 13) & 0x7}]
		set d_txst  [expr {($pdcd >> 10) & 0x7}]
		set d_cst   [expr {($pdcd >>  7) & 0x7}]
		set d_hshk  [expr {($pdcd >>  6) & 0x1}]
		set d_pres  [expr {($pdcd >>  5) & 0x1}]
		set d_sel   [expr {($pdcd >>  4) & 0x1}]
		set d_cmds  [expr {($pdcd >>  2) & 0x3}]
		set d_bad   [expr {($pdcd >>  1) & 0x1}]
		set d_abort [expr { $pdcd        & 0x1}]
		set d_txout [expr {($pdc2 >> 24) & 0xFF}]
		set d_rxin  [expr {($pdc2 >> 18) & 0x3F}]
		set d_txmax [expr {($pdc2 >> 15) & 0x7}]
		set d_hsmax [expr {($pdc2 >> 12) & 0x7}]
		set d_unop  [expr {($pdc2 >>  4) & 0xFF}]
		set d_uncnt [expr {($pdc2 >>  2) & 0x3}]
		set d_unwhy [expr { $pdc2        & 0x3}]

		set rxhsname {IDLE ARMED READY DATA DONE ?5 ?6 ?7}
		set txstname {TX_IDLE TX_WAIT TX_SYNC TX_DATA TX_LSB TX_END TX_HOFF ?7}
		set cstname  {C_IDLE C_FETCH C_FETCH_GO C_WAIT C_SEND C_SENDING ?6 ?7}

		set states ""
		for {set b 0} {$b < 8} {incr b} {
			if {($d_seen >> $b) & 1} { append states "$b " }
		}
		if {$states eq ""} { set states "NONE" }

		puts [format "  PDCD  DCD: present=%d selected=%d /HSHK=%s  commands=%s  last op=\$%02X" \
		             $d_pres $d_sel [expr {$d_hshk ? "released" : "ASSERTED"}] \
		             [expr {$d_cmds >= 3 ? "3+" : $d_cmds}] $d_op]
		puts [format "  PDCD  phase states the Mac drove: %s" $states]
		puts [format "  PDCD  now: rxHs=%-6s txState=%-8s cmdFSM=%s" \
		             [lindex $rxhsname $d_rxhs] [lindex $txstname $d_txst] \
		             [lindex $cstname $d_cst]]
		puts [format "  PDCD  sticky: bad-checksum=%d  reply-abandoned-in-TX_WAIT=%d" \
		             $d_bad $d_abort]
		puts [format "  PDC2  bytes: Mac->drive %s   drive->Mac %s" \
		             [expr {$d_rxin  >= 63  ? "63+ (SAT)"  : $d_rxin}] \
		             [expr {$d_txout >= 255 ? "255+ (SAT)" : $d_txout}]]
		puts [format "  PDC2  furthest reached: txState=%s  rxHs=%s" \
		             [lindex $txstname $d_txmax] [lindex $rxhsname $d_hsmax]]
		# A command the drive took in and never replied to. The Mac's driver
		# has no way to distinguish that from a dead drive: it times out and
		# then resets us, which is what sets PDCD's abandoned bit. So this
		# line is upstream of that one -- read it first.
		if {$d_uncnt == 0} {
			puts "  PDC2  unanswered/unimplemented commands: none -- every command decoded was dispatched and implemented"
		} else {
			set why [lindex {"?" "not dispatched from C_IDLE (a guard refused it -- e.g. a write with no sector behind it; an opcode dcd.v does not implement is acknowledged rather than dropped, so it lands under reason 3, not here)" \
			                 "arrived while the command layer was still busy" \
			                 "answered by the generic empty-block ack -- an opcode dcd.v does not implement. \$19/\$1A are Erase Disk and are ROUTINE. Anything else is not: \$3F in particular is what the Mac sends after a hold-off it could not follow, and it expects a real reply -- a wrong one draws a \$7F NAK (TashTwenty's author, 68kMLA). A routine \$19/\$1A here is displaced by any other event, so if this line names \$19 or \$1A that IS the whole story"} $d_unwhy]
			puts [format "  PDC2  UNANSWERED/UNIMPLEMENTED COMMAND: first opcode \$%02X, %s seen, reason: %s" \
			             $d_unop [expr {$d_uncnt >= 3 ? "3+" : $d_uncnt}] $why]
		}

		# The verdict. Each line rules out one of the readings that the
		# instruction-fetch sampler could not separate -- see MAC128K_PLAN.md,
		# "the /HSHK bug", on why a boot capture's silence proved nothing.
		if {!$d_pres} {
			puts "  PDCD  >> no DCD image is MOUNTED. Nothing below this line means anything."
		} elseif {!(($d_seen >> 5) & 1)} {
			puts "  PDCD  >> the Mac NEVER drove state 5, so it has not tried to identify a DCD at all."
		} elseif {$d_cmds == 0 && $d_rxin == 0} {
			puts "  PDCD  >> identification was probed, but NO command ever arrived: the ROM looked and moved on."
		} elseif {$d_cmds == 0 && $d_rxin > 0} {
			puts "  PDCD  >> bytes arrived but no frame ever decoded -- framing or checksum, not identification."
		} elseif {!$d_hshk && $d_txst == 1} {
			puts "  PDCD  >> THE \$28 WEDGE: /HSHK is ASSERTED with a reply parked in TX_WAIT."
			puts "  PDCD     The drive asked for the bus and the Mac never came round to state 1."
		} elseif {!$d_hshk && $d_rxhs == 2} {
			puts "  PDCD  >> /HSHK is ASSERTED waiting to RECEIVE: the Mac reached state 3 and stopped."
		} elseif {$d_abort} {
			puts "  PDCD  >> a reply was abandoned in TX_WAIT. The escape fired, so the drive did NOT wedge --"
			puts "  PDCD     but the Mac walked away mid-exchange and the reason for that is upstream."
		} else {
			puts [format "  PDCD  >> %d command(s) decoded and %s bytes sent back; no wedge visible in this capture." \
			             $d_cmds [expr {$d_txout >= 255 ? "255+" : $d_txout}]]
		}
	} else {
		set absent(PDCD) 1
		puts "  PDCD  ABSENT from this bitstream -- predates the DCD probe."
	}
	puts [format "  PACT  bus cycles %d" $pact]
	puts [format "  PSCS  last READ  reg=%-12s val=%02X  (reads:%d)" \
	             [selstr $rd_sel r] $rd_val $rd_cnt]
	puts [format "  PSCW  last WRITE reg=%-12s val=%02X  (writes:%d)" \
	             [selstr $wr_sel w] $wr_val $wr_cnt]
	puts [format "  PODR  last 4 data-reg writes = %02X %02X %02X %02X  <- CDB tail, newest last" \
	             [expr ($podr >> 24) & 0xff] [expr ($podr >> 16) & 0xff] \
	             [expr ($podr >>  8) & 0xff] [expr  $podr        & 0xff]]
	set fd_a [expr {($pifd >> 16) & 0xffff}]
	set fd_o [expr { $pifd        & 0xffff}]
	set ipairs($fd_a) $fd_o
	puts [format "  PIFD  %04X: %04X                  <- instruction word there" $fd_a $fd_o]
	# PIOS = {rd_stuck[8], window[2], lba[22]} -- but ONLY on a bitstream that
	# sets the PIO2[7] format marker. On an older build those two bits are the
	# top of a 24-bit LBA and decoding them as a window prints a plausible,
	# entirely fictional "win=data". Never print a window we cannot vouch for:
	# report "win=n/a" and the full 24-bit LBA instead, which is what that
	# bitstream actually carries.
	set pios_fmt [expr {($pio2 >> 7) & 1}]
	if {$pios_fmt} {
		set pios_win [lindex {data audio TOC ????} [expr {($pios >> 22) & 0x3}]]
		set pios_lba [expr {$pios & 0x3fffff}]
	} else {
		set pios_win "n/a"
		set pios_lba [expr {$pios & 0xffffff}]
	}
	puts [format "  PIOS  cd fetch stuck=%-3d win=%-5s lba=%d" \
	             [expr {($pios >> 24) & 0xff}] $pios_win $pios_lba]
	puts [format "  PIO2  cd rd=%d ack=%d  disk0 rd=%d   live: cd_rd=%d cd_wr=%d cd_ack=%d d0_rd=%d d0_ack=%d" [expr {($pio2 >> 24) & 0xff}] [expr {($pio2 >> 16) & 0xff}] [expr {($pio2 >> 8) & 0xff}] [expr {($pio2 >> 4) & 1}] [expr {($pio2 >> 3) & 1}] [expr {($pio2 >> 2) & 1}] [expr {($pio2 >> 1) & 1}] [expr {$pio2 & 1}]]
	puts [format "  PIO3  disk write stuck=%-3d lba=%d" [expr {($pio3 >> 24) & 0xff}] [expr {$pio3 & 0xffffff}]]
	puts [format "  PIO4  disk0 wr=%d ack=%d (ack covers rd+wr)  disk1 wr=%d   live: d0_wr=%d d0_ack=%d d1_wr=%d" [expr {($pio4 >> 24) & 0xff}] [expr {($pio4 >> 16) & 0xff}] [expr {($pio4 >> 8) & 0xff}] [expr {($pio4 >> 2) & 1}] [expr {($pio4 >> 1) & 1}] [expr {$pio4 & 1}]]
	# PHLD: the CPU hold-off. holds=0 after a CD read means the interlock was
	# never exercised -- a clean copy then says nothing about whether it works.
	# breaches MUST be 0; any count means a DACK access got past the hold-off
	# and only the CHECK CONDITION backstop stood between it and corruption.
	set phld_holds   [expr {($phld >> 20) & 0xfff}]
	set phld_maxhold [expr {($phld >> 4)  & 0xffff}]
	set phld_breach  [expr {$phld & 0xf}]
	set s_holds $phld_holds
	if {$phld_holds == 4095} { set s_holds "${phld_holds}+ (SAT)" }
	set s_max "${phld_maxhold} clk"
	if {$phld_maxhold == 65535} { set s_max "${phld_maxhold}+ clk (SAT)" }
	set s_breach "0 (good)"
	if {$phld_breach != 0} { set s_breach "$phld_breach <<< FRONTIER BREACHED" }
	puts [format "  PHLD  cpu hold-off: holds=%-12s longest=%-18s breaches=%s" $s_holds $s_max $s_breach]
	# The access ring, newest first. Entry = {rw,dack,reg,3'b0,val}.
	puts [format "  PRG   last 4 non-poll SCSI accesses (newest first); DACK reads so far: %d" [expr {($pscs >> 8) & 0xf}]]
	foreach pr {PRG0 PRG1} {
		set w [b2i [rd $pr]]
		foreach half {0 16} {
			set e [expr {($w >> $half) & 0xffff}]
			if {$e == 0} { continue }
			set erw [expr {($e >> 15) & 1}]
			set edk [expr {($e >> 14) & 1}]
			set erg [expr {($e >> 11) & 7}]
			set ev  [expr { $e & 0xff}]
			if {$erw} {
				set nm [lindex $rdname $erg]
				set dir "rd"
			} else {
				set nm [lindex $wrname $erg]
				set dir "wr"
			}
			if {$edk} { append nm " (DACK)" }
			puts [format "          %s %-13s %02X" $dir $nm $ev]
		}
	}

	# ---- PDMA / PDM2: the discriminating word -----------------------------
	# Added 2026-08-22 to settle the third reading of the wedge (see
	# SCSI_UPGRADE_PLAN.md 5.6). Field layout is defined in rtl/dbg_probes.sv
	# and proven by sim/tb_dbg_probes.v; change all three together.
	set pdma [b2i [rd PDMA]]
	set pdm2 [b2i [rd PDM2]]

	set dack_tot [expr {($pdma >> 24) & 0xff}]
	set dack_arm [expr {($pdma >> 16) & 0xff}]
	set arm_cnt  [expr {($pdma >> 14) & 0x3}]
	set wdog_cnt [expr {($pdma >> 11) & 0x7}]
	set iowd_cnt [expr {($pdma >>  8) & 0x7}]
	set phmask   [expr {($pdma >>  2) & 0x3f}]
	set req_stat [expr {($pdma >>  1) & 1}]
	set req_msg  [expr { $pdma        & 1}]

	set dack_mis [expr {($pdm2 >> 31) & 1}]
	set drq_mis  [expr {($pdm2 >> 30) & 1}]
	set ack_stat [expr {($pdm2 >> 29) & 1}]
	set irq_seen [expr {($pdm2 >> 28) & 1}]
	set lv_bsy   [expr {($pdm2 >> 27) & 1}]
	set lv_req   [expr {($pdm2 >> 26) & 1}]
	set lv_dma   [expr {($pdm2 >> 25) & 1}]
	set lv_pm    [expr {($pdm2 >> 24) & 1}]
	set ring     [expr { $pdm2 & 0xffffff}]

	# PDM3: the arm-to-data-phase window. Layout in rtl/dbg_probes.sv.
	set pdm3 [b2i [rd PDM3]]
	set dack_wr  [expr {($pdm3 >> 24) & 0xff}]
	set tcr_arm  [expr {($pdm3 >> 20) & 0xf}]
	set tcr_now  [expr {($pdm3 >> 16) & 0xf}]
	set ph_arm   [expr {($pdm3 >> 13) & 0x7}]
	set pm_arm   [expr {($pdm3 >> 12) & 1}]
	set ph_1st   [expr {($pdm3 >>  9) & 0x7}]
	set seen_1st [expr {($pdm3 >>  8) & 1}]
	set nondata  [expr {($pdm3 >>  7) & 1}]
	set in_data  [expr {($pdm3 >>  6) & 1}]

	# Codes come from rtl/scsi.v's PHASE_*, which names phases from the TARGET's
	# point of view: PHASE_DATA_OUT(2) is the target driving data OUT to the
	# initiator -- a READ -- and PHASE_DATA_IN(3) is data coming IN to the target
	# -- a WRITE. That is the exact opposite of the initiator-perspective "DATA
	# IN / DATA OUT" every SCSI document uses, so printing the raw names inverts
	# the meaning for anyone reading a capture. Spell out the direction instead.
	set phname {IDLE CMD DATA>init(READ) DATA>targ(WRITE) STATUS MESSAGE ?6 ?7}
	set seen ""
	for {set b 0} {$b < 6} {incr b} {
		if {($phmask >> $b) & 1} { append seen "[lindex $phname $b] " }
	}
	set ringstr ""
	for {set e 0} {$e < 8} {incr e} {
		append ringstr "[lindex $phname [expr {($ring >> ($e * 3)) & 7}]] "
	}

	puts [format "  PDMA  DACK reads since the DMA arm: %s   (lifetime %s, arms since selection %d)" 	             [expr {$dack_arm >= 255 ? ">=255" : $dack_arm}] 	             [expr {$dack_tot >= 255 ? ">=255" : $dack_tot}] $arm_cnt]
	puts [format "        watchdog fires since selection: bus=%d  io-stall=%d" $wdog_cnt $iowd_cnt]
	puts [format "        phases visited since selection: %s" [string trim $seen]]
	puts [format "  PDM2  sticky: DACK-in-mismatch=%d REQ+DMA-in-mismatch=%d ACK-in-STATUS=%d IRQ-latched=%d REQ-in-STATUS=%d REQ-in-MESSAGE=%d" 	             $dack_mis $drq_mis $ack_stat $irq_seen $req_stat $req_msg]
	puts [format "        live: BSY=%d REQ=%d DMA_EN=%d PMATCH=%d" $lv_bsy $lv_req $lv_dma $lv_pm]
	puts [format "        phase ring (newest first): %s" [string trim $ringstr]]
	if {[have PDM3]} {
		puts [format "  PDM3  at the DMA arm: phase=%s TCR=%X pmatch=%d" 	             [lindex $phname $ph_arm] $tcr_arm $pm_arm]
		if {$seen_1st} {
			puts [format "        first DACK access after the arm was in phase %s" 		             [lindex $phname $ph_1st]]
		} else {
			puts "        no DACK access at all since the arm"
		}
		puts [format "        DACK writes since the arm: %s   TCR now=%X   in a data phase now=%d" 	             [expr {$dack_wr >= 255 ? ">=255" : $dack_wr}] $tcr_now $in_data]
		if {$nondata} {
			puts "        NOTE: a DACK access landed OUTSIDE a data phase this transaction."
		}
	} else {
		puts "  PDM3  ABSENT from this bitstream -- this build predates 13cdd79."
		puts "        The arm-to-data-phase window is NOT measured here. Do not"
		puts "        infer anything about where the driver armed or where its"
		puts "        first DACK landed from this capture."
	}

	# The reading this capture supports, stated outright so a capture cannot be
	# quietly re-interpreted after the fact.
	#
	# But these verdicts only MEAN anything on a machine that is actually stuck.
	# "Armed pseudo-DMA and no DACK yet" is the normal window between arming and
	# the first byte, hit constantly during a healthy transfer -- a CD-to-disk
	# copy printed FALSIFIED in capitals on three samples out of five while
	# working perfectly. Confident-but-wrong instrument output is what made this
	# investigation expensive; the verdict now says when it cannot judge.
	#
	# Activity is measured by the WRITE counter alone. Reads are useless for this:
	# the wedged machine polled BSR thousands of times a second, so reads advanced
	# the whole time it was stuck. Writes froze -- that was the airtight signal.
	set data_seen [expr {($phmask >> 2) & 1 || ($phmask >> 3) & 1}]
	set can_judge [expr {$samples > 1 && $n > 0}]
	set active    [expr {$can_judge && ($wr_cnt != $prev_wr)}]
	if {$wdog_cnt > 0 || $iowd_cnt > 0} {
		puts "  ==>   a watchdog FIRED: a target timed out waiting for a handshake"
		puts "        that never came. Always worth explaining, busy or not."
	} elseif {$active} {
		puts "  ==>   bus ACTIVE -- register writes are advancing, so the machine"
		puts "        is NOT wedged. Wedge verdicts suppressed; they apply only"
		puts "        to a stuck machine."
	} elseif {$dack_arm >= 2 && !$data_seen && $dack_mis && $ack_stat} {
		puts "  ==>   CONFIRMED: DACK reads during a phase mismatch consumed the"
		puts "        transaction (ACK pulsed while the target was in STATUS)."
		puts "        No data phase, no watchdog. Fix = gate dma_ack on the bus"
		puts "        data phase (SCSI_UPGRADE_PLAN.md 5.6)."
	} elseif {$arm_cnt > 0 && $dack_arm == 0} {
		puts "  ==>   FALSIFIED: the driver armed pseudo-DMA and then did NO DACK"
		puts "        read at all. The transaction did not complete this way."
		if {!$can_judge} {
			puts "        (single sample: cannot tell a wedge from a healthy machine"
			puts "        caught mid-arm. Take several samples.)"
		}
	} else {
		puts "  ==>   inconclusive so far -- sample again while wedged."
	}
	set prev_wr $wr_cnt
	puts ""

	if {$n + 1 < $samples} { after [expr {int($delay * 1000)}] }
}

end_insystem_source_probe

if {[array size absent] > 0} {
	puts ""
	puts "############################################################"
	puts "# INCOMPLETE CAPTURE -- probes missing from this bitstream: #"
	puts "#   [lsort [array names absent]]"
	puts "# The running core is OLDER than the probe deck in this"
	puts "# working tree. Every field derived from those probes has"
	puts "# been SUPPRESSED, not printed as zero. Flash the build you"
	puts "# meant to test before drawing any conclusion."
	puts "############################################################"
	puts ""
}
puts "Instruction words collected (feed to a 68000 disassembler):"
foreach a [lsort -integer [array names ipairs]] {
	puts [format "   %04X: %04X" $a $ipairs($a)]
}
puts ""
puts "How to read this:"
puts "  * PIFA fetch# ADVANCING between samples  -> CPU is alive and looping;"
puts "    PC values name the loop. FROZEN -> CPU is stalled on the bus itself."
puts "  * PSCS repeating the same register with an unchanging value is a poll"
puts "    that never satisfies -- that register and value name the wedge."
puts "  * PODR shows the tail of the last CDB the driver handed the target."
puts "  * PIOS stuck>0 with PIO2 cd_rd=1 and rd>ack = a fetch the HPS never"
puts "    answered. That holds io_busy, which holds REQ low AND resets the bus"
puts "    watchdog every cycle -- a hang with no recovery (scsi.v:239, :1195)."
puts "  * PIOS win names WHICH address space the fetch is in: data sectors,"
puts "    the CD-DA window (0x40000000+lba), or the TOC blob (0x7FFF0000)."
puts "    Without it an audio frame for block n is indistinguishable from a"
puts "    data read of block n -- which is the whole Phase 3B question, since"
puts "    cd_audio.sv and the SCSI target share this one channel."
puts "  * PHLD is the one that says whether the CD->disk fix was TESTED, not"
puts "    merely un-contradicted. holds=0 after a CD read means the HPS never"
puts "    lagged and the interlock was never exercised: rerun with a colder"
puts "    cache or a longer seek before believing a clean copy. breaches>0"
puts "    means the hold-off has a hole and the CHECK CONDITION backstop is"
puts "    all that caught it -- expect sense 0xB/0x4b in the driver's log."
puts "    longest= is the worst single CPU stall; ~20k clk is a normal 0.6ms"
puts "    fill lag at 32.5MHz, SATURATED (65535) needs investigating."
puts "  * PIO3/PIO4 are the same test for the WRITE side, which is what the"
puts "    2026-08-22 wedge actually was. PIO3 stuck>0 with PIO4 d0_wr=1 and"
puts "    PIO4 wr+PIO2 rd > PIO4 ack = a FLUSH the HPS never answered, and"
puts "    PIO3 lba names the block it was trying to write."
puts "  * PIO4 disk0 wr climbing between samples is write progress; frozen"
puts "    with d0_wr=1 is a stalled flush. Note PIO4 ack counts BOTH"
puts "    directions on that slot -- compare it against PIO2 disk0 rd + PIO4"
puts "    disk0 wr, not against either one alone."
puts "  * PDMA/PDM2 are the discriminating word. Both readings of the wedge"
puts "    predict the SAME frozen PSCS/PODR capture; they differ only here."
puts "    Predicted by the invisible-completion reading: DACK-since-arm=2,"
puts "    both watchdog counts 0, phases CMD/STATUS/MESSAGE/IDLE with no DATA,"
puts "    DACK-in-mismatch=1 and ACK-in-STATUS=1."
puts "  * With the pmatch gate in place ACK-in-STATUS must read 0: a DACK read"
puts "    during a mismatch no longer consumes the target's status byte."
puts "  * The old DACK row in PRG was a 4-bit WRAPPING counter that was never"
puts "    cleared, so on a machine that booted off a SCSI disk it read as noise"
puts "    mod 16. Trust the PDMA fields, not that row."
