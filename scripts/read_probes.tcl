# Read the MacPlus SCSI JTAG probes over the DE10-Nano's USB-Blaster.
#
#   quartus_stp -t scripts/read_probes.tcl          one sample, decoded
#   quartus_stp -t scripts/read_probes.tcl 20 0.5   20 samples, 0.5 s apart
#
# Sample REPEATEDLY while the Mac is wedged. A single sample says where the CPU
# is; a series says whether it is looping (PIFA fetch count advancing, address
# histogramming over a small range) or truly dead on the bus (count frozen).
#
# Probe deck is defined in rtl/dbg_probes.sv and built only when the
# USE_SCSI_ISSP macro is set in MacPlus.qsf.

array set ipairs {}
set samples 1
set delay   0.5
if {$argc >= 1} { set samples [lindex $argv 0] }
if {$argc >= 2} { set delay   [lindex $argv 1] }

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
foreach inst $info {
	# {index source_width probe_width instance_name}
	set idx([lindex $inst 3]) [lindex $inst 0]
	puts [format "  found %-6s index=%s probe_width=%s" [lindex $inst 3] [lindex $inst 0] [lindex $inst 2]]
}
puts ""

# One session for the whole run, rather than one per probe read.
start_insystem_source_probe -hardware_name $hw -device_name $dev

proc rd {name} {
	global idx
	if {![info exists idx($name)]} { return 0 }
	set bits [read_probe_data -instance_index $idx($name)]
	if {$bits eq ""} { return 0 }
	return [expr 0b$bits]
}

proc b2i {v} { return $v }

for {set n 0} {$n < $samples} {incr n} {
	set pifd [b2i [rd PIFD]]
	set pios [b2i [rd PIOS]]
	set pio2 [b2i [rd PIO2]]
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

	puts [format "sample %d" $n]
	puts [format "  PIFA  fetch#%3d  PC=%06X      <- where the CPU is" $if_cnt $if_addr]
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
	puts [format "  PIOS  cd fetch stuck=%-3d lba=%d" [expr {($pios >> 24) & 0xff}] [expr {$pios & 0xffffff}]]
	puts [format "  PIO2  cd rd=%d ack=%d  disk0 rd=%d   live: cd_rd=%d cd_wr=%d cd_ack=%d d0_rd=%d d0_ack=%d" [expr {($pio2 >> 24) & 0xff}] [expr {($pio2 >> 16) & 0xff}] [expr {($pio2 >> 8) & 0xff}] [expr {($pio2 >> 4) & 1}] [expr {($pio2 >> 3) & 1}] [expr {($pio2 >> 2) & 1}] [expr {($pio2 >> 1) & 1}] [expr {$pio2 & 1}]]
	# The access ring, newest first. Entry = {rw,dack,reg,3'b0,val}.
	puts [format "  PRG   recent non-poll SCSI accesses (newest first); DACK reads so far: %d" [expr {($pscs >> 8) & 0xf}]]
	foreach pr {PRG0 PRG1 PRG2 PRG3} {
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

	set phname {IDLE CMD DATA-OUT DATA-IN STATUS MESSAGE ?6 ?7}
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

	# The reading this capture supports, stated outright so a capture cannot be
	# quietly re-interpreted after the fact.
	set data_seen [expr {($phmask >> 2) & 1 || ($phmask >> 3) & 1}]
	if {$wdog_cnt > 0 || $iowd_cnt > 0} {
		puts "  ==>   a watchdog FIRED: the invisible-completion reading is out."
	} elseif {$dack_arm >= 2 && !$data_seen && $dack_mis && $ack_stat} {
		puts "  ==>   CONFIRMED: DACK reads during a phase mismatch consumed the"
		puts "        transaction (ACK pulsed while the target was in STATUS)."
		puts "        No data phase, no watchdog. Fix = gate bsr_dmarq and"
		puts "        dma_ack with bsr_pmatch (SCSI_UPGRADE_PLAN.md 5.6)."
	} elseif {$arm_cnt > 0 && $dack_arm == 0} {
		puts "  ==>   FALSIFIED: the driver armed pseudo-DMA and then did NO DACK"
		puts "        read at all. The transaction did not complete this way."
	} else {
		puts "  ==>   inconclusive so far -- sample again while wedged."
	}
	puts ""

	if {$n + 1 < $samples} { after [expr {int($delay * 1000)}] }
}

end_insystem_source_probe

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
