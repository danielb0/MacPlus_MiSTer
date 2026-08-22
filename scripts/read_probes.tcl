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
	puts ""

	if {$n + 1 < $samples} { after [expr {int($delay * 1000)}] }
}

end_insystem_source_probe

puts "How to read this:"
puts "  * PIFA fetch# ADVANCING between samples  -> CPU is alive and looping;"
puts "    PC values name the loop. FROZEN -> CPU is stalled on the bus itself."
puts "  * PSCS repeating the same register with an unchanging value is a poll"
puts "    that never satisfies -- that register and value name the wedge."
puts "  * PODR shows the tail of the last CDB the driver handed the target."
