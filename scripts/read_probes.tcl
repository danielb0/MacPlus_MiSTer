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
set hw ""
foreach h [get_hardware_names] {
	if {[string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} {
	puts "ERROR: no USB-Blaster found. Is the DE10-Nano connected and powered?"
	exit 1
}
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "@1*" $d]} { set dev $d; break }
}
if {$dev eq ""} { set dev [lindex [get_device_names -hardware_name $hw] 0] }
puts "hardware: $hw"
puts "device:   $dev"
puts ""

# ---- map instance ids -----------------------------------------------------
# The ISSP hub enumerates by index, not by name, so build the mapping once.
array set idx {}
start_insystem_source_probe -hardware_name $hw -device_name $dev
foreach inst [get_insystem_source_probe_instance_info \
                 -hardware_name $hw -device_name $dev] {
	# {index source_width probe_width instance_name}
	set idx([lindex $inst 3]) [lindex $inst 0]
}
end_insystem_source_probe

proc rd {name} {
	global idx hw dev
	if {![info exists idx($name)]} { return "" }
	start_insystem_source_probe -hardware_name $hw -device_name $dev
	set v [read_probe_data -instance_index $idx($name)]
	end_insystem_source_probe
	return $v
}

proc b2i {bits} { if {$bits eq ""} { return 0 } ; return [expr 0b$bits] }

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
	set regname {CDR/ODR ICR MR TCR CSR/DMAS BSR IDR RST}
	proc selstr {s} {
		global regname
		set r [expr $s & 0x7]
		set d [expr ($s >> 3) & 1]
		return "[lindex $regname $r][expr {$d ? \" (DACK)\" : \"\"}]"
	}

	puts [format "sample %d" $n]
	puts [format "  PIFA  fetch#%3d  PC=%06X      <- where the CPU is" $if_cnt $if_addr]
	puts [format "  PACT  bus cycles %d" $pact]
	puts [format "  PSCS  last READ  reg=%-12s val=%02X  (reads:%d)" \
	             [selstr $rd_sel] $rd_val $rd_cnt]
	puts [format "  PSCW  last WRITE reg=%-12s val=%02X  (writes:%d)" \
	             [selstr $wr_sel] $wr_val $wr_cnt]
	puts [format "  PODR  last 4 data-reg writes = %02X %02X %02X %02X  <- CDB tail, newest last" \
	             [expr ($podr >> 24) & 0xff] [expr ($podr >> 16) & 0xff] \
	             [expr ($podr >>  8) & 0xff] [expr  $podr        & 0xff]]
	puts ""

	if {$n + 1 < $samples} { after [expr {int($delay * 1000)}] }
}

puts "How to read this:"
puts "  * PIFA fetch# ADVANCING between samples  -> CPU is alive and looping;"
puts "    PC values name the loop. FROZEN -> CPU is stalled on the bus itself."
puts "  * PSCS repeating the same register with an unchanging value is a poll"
puts "    that never satisfies -- that register and value name the wedge."
puts "  * PODR shows the tail of the last CDB the driver handed the target."
