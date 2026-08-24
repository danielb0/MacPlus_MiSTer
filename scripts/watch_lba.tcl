# watch_lba.tcl -- trace the disk0 LBA probe (PIO3) on a running MacPlus core.
#
#   quartus_stp -t scripts/watch_lba.tcl [seconds]     default 120
#
# Why this exists: PIO3 is a LIVE mirror of scsi_sd_lba[0] (dbg_probes.sv:453),
# not a latched maximum, so the only way to learn which blocks an operation
# touched is to sample fast and record the changes. read_probes.tcl decodes all
# 18 probes per sample, far too slow for that; this reads PIO3 alone, ~2600/s.
#
# It records the TRACE, not just a high-water mark. PIO3 only changes when the
# slot is handed a new LBA, so each CHANGE (with the sample count it was held
# for) reconstructs what was actually addressed. A max alone cannot tell
# "swept the medium" from "touched four blocks, one of them high" -- and that
# distinction is the entire question for the defect B edge test.
#
# NOTE: PIO3 carries lba[23:0] only. Good to 16,777,215 blocks (8 GB); a larger
# volume aliases silently.

set secs 120
if {$argc >= 1} { set secs [lindex $argv 0] }

set hw ""
foreach h [get_hardware_names] {
	if {[string match "*DE-SoC*" $h] || [string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} { puts "ERROR: no JTAG hardware found."; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break }
}
if {$dev eq ""} { puts "ERROR: no Cyclone V FPGA in the chain."; exit 1 }

if {[catch {
	set info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
} err]} { puts "ERROR reading instance info: $err"; exit 1 }

array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
# An absent probe must never be reported as data -- a fictional PIO3 reads
# lba=0, which looks like a healthy idle path and would exonerate the very
# thing under test. Same rule as read_probes.tcl.
foreach need {PIO3 PBLD} {
	if {![info exists idx($need)]} {
		puts "ERROR: $need absent from this bitstream -- wrong build loaded. Not sampling."
		exit 1
	}
}

start_insystem_source_probe -hardware_name $hw -device_name $dev

proc rd {name} {
	global idx
	set bits [read_probe_data -instance_index $idx($name)]
	if {$bits eq ""} { return 0 }
	return [expr 0b$bits]
}

# Line buffering: a run that is killed (or simply long) must still have written
# what it saw. Fully-buffered output lost a whole capture once.
fconfigure stdout -buffering line

puts [format "bitstream=%08X" [rd PBLD]]
puts "tracing PIO3 disk0 LBA for $secs s -- run the operation now"
puts ""

set maxlba  -1
set minlba  -1
set n        0
set stuckmax 0
set last    -1
set reps     0
set nchg     0
set t0 [clock milliseconds]
set tend [expr {$t0 + $secs * 1000}]
set nextreport [expr {$t0 + 15000}]

while {[clock milliseconds] < $tend} {
	set v [rd PIO3]
	set lba   [expr {$v & 0xffffff}]
	set stuck [expr {($v >> 24) & 0xff}]
	incr n
	if {$lba > $maxlba} { set maxlba $lba }
	if {$minlba < 0 || $lba < $minlba} { set minlba $lba }
	if {$stuck > $stuckmax} { set stuckmax $stuck }
	if {$lba != $last} {
		if {$last >= 0} {
			puts [format "  t=%7.3fs  lba=%-9d (held %d samples)" \
				[expr {([clock milliseconds] - $t0) / 1000.0}] $last $reps]
			incr nchg
		}
		set last $lba
		set reps 0
	}
	incr reps
	set now [clock milliseconds]
	if {$now >= $nextreport} {
		puts [format "  -- t=%5.1fs idle, samples=%-8d cur=%-9d max=%d" \
			[expr {($now - $t0) / 1000.0}] $n $lba $maxlba]
		set nextreport [expr {$now + 15000}]
	}
}
if {$last >= 0} {
	puts [format "  t=%7.3fs  lba=%-9d (held %d samples, final)" \
		[expr {([clock milliseconds] - $t0) / 1000.0}] $last $reps]
}

set el [expr {([clock milliseconds] - $t0) / 1000.0}]
puts ""
puts [format "samples: %d in %.1fs (%.0f/s)" $n $el [expr {$n / $el}]]
puts [format "LBA range observed: %d .. %d" $minlba $maxlba]
puts [format "distinct LBA changes: %d" $nchg]
puts [format "max wr_stuck seen:  %d  (nonzero = a flush the HPS never answered)" $stuckmax]
end_insystem_source_probe
