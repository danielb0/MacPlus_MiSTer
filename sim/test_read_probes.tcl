# ---------------------------------------------------------------------------
# test_read_probes.tcl -- run scripts/read_probes.tcl against a synthetic
# capture, with the Quartus JTAG commands stubbed out.
#
#   tclsh sim/test_read_probes.tcl
#
# The reader re-implements the probe deck's bit packing in Tcl by hand. A
# mis-sliced field there reads back as a plausible number, which is exactly how
# the first DACK-count row sent this investigation down a dead end. So the
# packing is checked from both ends: sim/tb_dbg_probes.v proves the RTL side
# produces these words, and this proves the script turns them back into the
# right story.
# ---------------------------------------------------------------------------

set fails 0
set tests 0
proc ok {name cond} {
	global fails tests
	incr tests
	if {$cond} { puts "PASS: $name" } else { puts "FAIL: $name"; incr fails }
}

proc tobin {v} {
	set s ""
	for {set b 31} {$b >= 0} {incr b -1} { append s [expr {($v >> $b) & 1}] }
	return $s
}

# ---- Quartus stubs --------------------------------------------------------
proc get_hardware_names {} { return {DE-SoC [USB-1]} }
proc get_device_names {args} { return {@1: SOCVHPS @2: 5CSEBA6(.|ES)/5CSEMA6/..} }
proc start_insystem_source_probe {args} {}
proc end_insystem_source_probe {args} {}

proc get_insystem_source_probe_instance_info {args} {
	global names
	set out {}
	set i 0
	foreach n $names { lappend out [list $i 1 32 $n]; incr i }
	return $out
}

proc read_probe_data {args} {
	global names probeval
	set i [lindex $args 1]
	set n [lindex $names $i]
	if {[info exists probeval($n)]} { return [tobin $probeval($n)] }
	return [tobin 0]
}

set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PRG2 PRG3 PIOS PIO2 PDMA PDM2 PDM3 PBLD}

# ---- the capture the invisible-completion reading predicts -----------------
# Field positions match the PDMA packing in rtl/dbg_probes.sv:
#   [31:24] lifetime  [23:16] since-arm  [15:14] arms  [13:11] bus wdog
#   [10:8] io wdog    [7:2] phase mask   [1] REQ-in-STATUS [0] REQ-in-MESSAGE
# DACK reads since the arm = 2, lifetime 2, one arm, no watchdog fire,
# phases IDLE+CMD+STATUS+MESSAGE (mask 0b110011), REQ seen in STATUS and
# MESSAGE; sticky DACK-in-mismatch, DRQ-in-mismatch and ACK-in-STATUS set,
# IRQ never latched; ring newest-first IDLE, MESSAGE, STATUS, CMD.
array set probeval {}
set probeval(PDMA) [expr {(2 << 24) | (2 << 16) | (1 << 14) | (0 << 11) | \
                          (0 << 8) | (0b110011 << 2) | (1 << 1) | 1}]
set probeval(PDM2) [expr {(1 << 31) | (1 << 30) | (1 << 29) | (0 << 28) | \
                          (0 << 27) | (0 << 26) | (1 << 25) | (0 << 24) | \
                          ((1 << 9) | (4 << 6) | (5 << 3) | 0)}]

set argv {}
set argc 0

proc capture {} {
	rename puts _real_puts
	set ::out ""
	proc puts {args} { append ::out "[lindex $args end]\n" }
	uplevel #0 {source scripts/read_probes.tcl}
	rename puts {}
	rename _real_puts puts
	return $::out
}

# PDM3: armed in STATUS (phase 4) with TCR=1, first DACK also in STATUS,
# one DACK landed outside a data phase, no DACK writes.
set probeval(PDM3) [expr {(0 << 24) | (1 << 20) | (1 << 16) | (4 << 13) |                           (0 << 12) | (4 << 9) | (1 << 8) | (1 << 7) | (0 << 6)}]

set probeval(PBLD) 0x13cdd790

set out [capture]

ok "reader names the bitstream the capture came from"    [string match "*bitstream=13CDD790*" $out]
ok "reader names the phase the driver armed in"    [string match "*at the DMA arm: phase=STATUS TCR=1 pmatch=0*" $out]
ok "reader names the phase of the first DACK after the arm"    [string match "*first DACK access after the arm was in phase STATUS*" $out]
ok "reader flags the DACK that landed outside a data phase"    [string match "*landed OUTSIDE a data phase*" $out]

ok "reader prints the per-arm DACK count, not a wrapped lifetime total" \
   [string match "*DACK reads since the DMA arm: 2*" $out]
ok "reader prints both watchdog counts as zero" \
   [string match "*bus=0  io-stall=0*" $out]
ok "reader names the phases visited" \
   [string match "*IDLE CMD STATUS MESSAGE*" $out]
ok "reader reports no DATA phase in the mask" \
   [expr {![string match "*DATA-IN*" $out] && ![string match "*DATA-OUT*" $out]}]
ok "reader decodes the sticky evidence bits" \
   [string match "*DACK-in-mismatch=1 REQ+DMA-in-mismatch=1 ACK-in-STATUS=1 IRQ-latched=0*" $out]
ok "reader decodes the phase ring newest-first" \
   [string match "*phase ring (newest first): IDLE MESSAGE STATUS CMD*" $out]
ok "reader reaches the CONFIRMED verdict on this capture" \
   [string match "*CONFIRMED*" $out]

# ---- the rival reading: a watchdog fired ----------------------------------
set probeval(PDMA) [expr {(2 << 24) | (2 << 16) | (1 << 14) | (1 << 11) | \
                          (0 << 8) | (0b110011 << 2) | (1 << 1) | 1}]
set out [capture]
ok "a bus-watchdog fire flips the verdict away from CONFIRMED" \
   [expr {[string match "*watchdog FIRED*" $out] && ![string match "*CONFIRMED*" $out]}]

# ---- the falsifying capture: armed, but no DACK read at all ---------------
set probeval(PDMA) [expr {(0 << 24) | (0 << 16) | (1 << 14) | (0 << 11) | \
                          (0 << 8) | (0b110011 << 2) | (1 << 1) | 1}]
set probeval(PDM2) [expr {(0 << 31) | (1 << 30) | (0 << 29) | (0 << 28) | \
                          ((1 << 9) | (4 << 6) | (5 << 3) | 0)}]
set out [capture]
ok "armed with zero DACK reads reads back as FALSIFIED" \
   [string match "*FALSIFIED*" $out]

puts ""
puts "READER: $fails of $tests failing"
if {$fails == 0} {
	puts "PROBE READER GATE: PASS - the decode says what the capture means"
} else {
	puts "PROBE READER GATE: FAIL"
}
