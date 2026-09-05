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
proc write_source_data {args} { lappend ::sourcewrites $args }
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

set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PDCD PDC2 PBLD}

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
   [expr {![string match "*DATA>init*" $out] && ![string match "*DATA>targ*" $out]}]
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

# ---- phase-code DIRECTION, the label that was inverted ---------------------
# rtl/scsi.v names phases from the TARGET's side: PHASE_DATA_OUT(2) is the
# target driving data out to the initiator, i.e. a READ, and PHASE_DATA_IN(3)
# is a WRITE. Printing those raw names told a reader the exact opposite of what
# the transfer was doing. Lock the direction so it cannot invert again.
set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PDCD PDC2 PBLD}
set probeval(PDM3) [expr {(0 << 24) | (1 << 20) | (1 << 16) | (2 << 13) | \
                          (1 << 12) | (3 << 9) | (1 << 8) | (0 << 7) | (1 << 6)}]
set out [capture]
ok "reader calls target phase code 2 a READ, not DATA-OUT" \
   [string match "*at the DMA arm: phase=DATA>init(READ)*" $out]
ok "reader calls target phase code 3 a WRITE, not DATA-IN" \
   [string match "*first DACK access after the arm was in phase DATA>targ(WRITE)*" $out]


# ---- a bitstream OLDER than this working tree ------------------------------
# The reader used to return 0 for any probe missing from the running design,
# so a capture from a build predating PDM3 rendered a complete, confident and
# entirely fictional PDM3 block, and PBLD read 00000000 -- indistinguishable
# from a real build whose tag was never stamped. Observed on hardware
# 2026-08-22: the board had only 14 ISSP instances (no PDM3, no PBLD) and the
# capture claimed the driver armed in IDLE and never pumped.
set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PDMA PDM2}
set out [capture]

ok "reader refuses to invent a PDM3 block the bitstream cannot provide" \
   [expr {[string match "*PDM3  ABSENT*" $out] &&
          ![string match "*at the DMA arm: phase=*" $out] &&
          ![string match "*no DACK access at all since the arm*" $out]}]
ok "reader distinguishes an ABSENT tag probe from an unstamped tag" \
   [expr {[string match "*bitstream=UNKNOWN*" $out] &&
          ![string match "*bitstream=00000000*" $out]}]
ok "reader raises an unmissable incomplete-capture banner" \
   [expr {[string match "*INCOMPLETE CAPTURE*" $out] &&
          [string match "*PBLD*" $out] && [string match "*PDM3*" $out]}]
ok "reader still decodes the probes that ARE present" \
   [string match "*DACK reads since the DMA arm:*" $out]

# ...and a complete bitstream must NOT raise the banner.
set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PDCD PDC2 PBLD}
set out [capture]
ok "reader stays quiet when every probe is present" \
   [expr {![string match "*INCOMPLETE CAPTURE*" $out] &&
          ![string match "*PDM3  ABSENT*" $out]}]

# ---- a bitstream predating the write-side probes ---------------------------
# PIO3/PIO4 were added in the same build as the write-path fixes they exist to
# observe, so every capture taken before that build lacks them. The reader must
# say so rather than print "disk write stuck=0 lba=0" -- which reads exactly
# like a healthy write path and would exonerate the very thing under suspicion.
set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PDMA PDM2 PDM3 PBLD}
set out [capture]
ok "reader flags a bitstream with no write-side probes" \
   [expr {[string match "*INCOMPLETE CAPTURE*" $out] &&
          [string match "*PIO3*" $out] && [string match "*PIO4*" $out]}]
ok "reader still decodes the read-side probes that ARE present" \
   [string match "*PIOS  cd fetch stuck=*" $out]

# ...and with them present, the write-side line is real and the banner is quiet.
set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PDCD PDC2 PBLD}
set probeval(PIO3) [expr {(7 << 24) | 4242}]
set probeval(PIO4) [expr {(9 << 24) | (5 << 16) | (2 << 8) | (1 << 2) | (0 << 1) | 0}]
set out [capture]
ok "reader decodes the stalled-flush LBA and stall age" \
   [string match "*PIO3  disk write stuck=7   lba=4242*" $out]
ok "reader decodes the disk write and ack counts" \
   [string match "*PIO4  disk0 wr=9 ack=5*disk1 wr=2*" $out]
ok "reader shows the live write handshake bit" \
   [string match "*d0_wr=1 d0_ack=0 d1_wr=0*" $out]
ok "reader warns that the disk ack count covers both directions" \
   [string match "*ack covers rd+wr*" $out]


# ---- PDCD / PDC2: the DCD (HD20) link -------------------------------------
# The deck's newest probe, and the one with a VERDICT attached, so the decode
# has to be checked case by case: each branch rules out one of the readings the
# instruction-fetch sampler could not separate. A verdict that fires on the
# wrong capture is worse than none, because it reads as an answer.
#
# Field positions match the PDCD/PDC2 packing in rtl/dbg_probes.sv:
#   PDCD [31:24] states seen  [23:16] last opcode  [15:13] rxHs  [12:10] txState
#        [9:7] cmdFSM  [6] /HSHK  [5] present  [4] selected  [3:2] commands
#        [1] bad checksum  [0] reply abandoned in TX_WAIT
#   PDC2 [31:24] bytes out  [23:18] bytes in  [17:15] txState high-water
#        [14:12] rxHs high-water  [11:4] first unanswered opcode
#        [3:2] unanswered count  [1:0] why
proc mkpdcd {seen op rxhs txst cst hshk pres sel cmds bad abort} {
	return [expr {($seen << 24) | ($op << 16) | ($rxhs << 13) | ($txst << 10) | \
	              ($cst << 7) | ($hshk << 6) | ($pres << 5) | ($sel << 4) | \
	              ($cmds << 2) | ($bad << 1) | $abort}]
}
proc mkpdc2 {out in txmax hsmax unop uncnt unwhy} {
	return [expr {($out << 24) | ($in << 18) | ($txmax << 15) | ($hsmax << 12) | \
	              ($unop << 4) | ($uncnt << 2) | $unwhy}]
}

set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PDCD PDC2 PBLD}

# A whole healthy Status exchange: the ID states walked, one command decoded,
# 40 bytes back, /HSHK released, both FSMs home. This is the capture that must
# NOT produce a wedge verdict.
set probeval(PDCD) [mkpdcd 0xEE 0x03 0 0 0 1 1 1 1 0 0]
set probeval(PDC2) [mkpdc2 40 11 5 4 0 0 0]
set out [capture]
ok "reader decodes the PDCD summary line" \
   [string match {*present=1 selected=1 /HSHK=released  commands=1  last op=$03*} $out]
ok "reader lists the phase states the Mac drove, state 5 among them" \
   [string match "*phase states the Mac drove: 1 2 3 5 6 7*" $out]
ok "reader decodes both byte counters, in the right direction" \
   [string match "*bytes: Mac->drive 11   drive->Mac 40*" $out]
ok "reader names the high-water marks of both handshake FSMs" \
   [string match "*furthest reached: txState=TX_END  rxHs=DONE*" $out]
# A healthy capture must say so POSITIVELY. "no unanswered commands" and
# "this bitstream has no such field" are different states, and a reader that
# printed nothing for the healthy case would let a stale deck read as a
# clean bill of health.
ok "reader reports no unanswered commands on a healthy capture" \
   [string match "*unanswered/unimplemented commands: none*" $out]
# The capture this probe was built for: a command decoded, never
# dispatched, and the Mac's driver left to time out. Since b8dedd0 an opcode
# dcd.v does not implement is ACKNOWLEDGED rather than dropped, so it lands
# under reason 3 below; a write whose guard refused it is what still reaches
# reason 1, and naming the wrong one would send the next investigation to the
# wrong branch of the driver.
set probeval(PDC2) [mkpdc2 40 11 5 4 0x01 1 1]
set out [capture]
ok "reader names the opcode of an unanswered command" \
   [string match {*UNANSWERED/UNIMPLEMENTED COMMAND: first opcode $01*} $out]
ok "reader says WHY it went unanswered" \
   [string match "*not dispatched from C_IDLE*" $out]
ok "reader reports how many were unanswered" \
   [string match "*1 seen*" $out]

# Reason 3, and the reader must GRADE it rather than just name it. An Erase
# Disk acks $19 then $1A on every format, so a deck that cried wolf there
# would be ignored by the time it mattered.
set probeval(PDC2) [mkpdc2 40 11 5 4 0x19 1 3]
set out [capture]
ok "reader names an opcode answered by the generic ack" \
   [string match {*UNANSWERED/UNIMPLEMENTED COMMAND: first opcode $19*} $out]
ok "reader explains the generic ack rather than calling it a failure" \
   [string match "*answered by the generic empty-block ack*" $out]
ok "reader says a \$19 ack is ROUTINE, so a reader does not chase it" \
   [string match "*ROUTINE*" $out]

# ...and the one this field exists to catch. $3F is what the Mac sends after
# a hold-off it could not follow; it must not read like a routine format.
set probeval(PDC2) [mkpdc2 40 11 5 4 0x3F 1 3]
set out [capture]
ok "reader names a \$3F ack, the mishandled-hold-off signature" \
   [string match {*UNANSWERED/UNIMPLEMENTED COMMAND: first opcode $3F*} $out]
ok "reader warns that a wrong reply to it draws a NAK" \
   [string match "*7F NAK*" $out]

# The other reason, which is a different bug with the same symptom: the
# command was one we implement, but it landed while the layer was busy.
set probeval(PDC2) [mkpdc2 40 11 5 4 0x03 3 2]
set out [capture]
ok "reader separates 'arrived busy' from 'not implemented'" \
   [string match "*arrived while the command layer was still busy*" $out]
ok "reader marks the unanswered counter as saturated" \
   [string match "*3+ seen*" $out]

# restore the healthy capture for the verdict tests that follow
set probeval(PDC2) [mkpdc2 40 11 5 4 0 0 0]
set out [capture]
ok "a healthy capture produces NO wedge verdict" \
   [expr {[string match "*no wedge visible in this capture*" $out] &&
          ![string match {*THE $28 WEDGE*} $out]}]

# The failure this probe was built for: /HSHK asserted with a reply parked in
# TX_WAIT, which is what HD Diag reports as error $28.
set probeval(PDCD) [mkpdcd 0xEE 0x03 0 1 1 0 1 1 1 0 0]
set probeval(PDC2) [mkpdc2 0 11 1 4 0 0 0]
set out [capture]
ok "reader names the \$28 wedge from the capture alone" \
   [string match {*THE $28 WEDGE: /HSHK is ASSERTED with a reply parked in TX_WAIT*} $out]

# A reply IN PROGRESS also holds /HSHK low, and is perfectly healthy. Without
# this case the verdict could fire on any non-idle txState and every other test
# here would still pass -- which is what a mutation sweep found. Sampling
# mid-reply is not a corner case either: a 392-byte Status frame at 2 us a bit
# is most of a millisecond, and JTAG samples land 0.4 s apart.
set probeval(PDCD) [mkpdcd 0xEE 0x03 0 3 0 0 1 1 1 0 0]
set probeval(PDC2) [mkpdc2 20 11 3 4 0 0 0]
set out [capture]
ok "a reply in flight is NOT reported as the \$28 wedge" \
   [expr {![string match {*THE $28 WEDGE*} $out] &&
          [string match "*no wedge visible in this capture*" $out]}]

# Mounted but not selected -- the resting state of a machine with an HD20
# attached, and the ONLY capture that tells `present` from `selected`. Swap the
# two slices and everything else here still passes.
set probeval(PDCD) [mkpdcd 0x00 0x00 0 0 0 1 1 0 0 0 0]
set probeval(PDC2) [mkpdc2 0 0 0 0 0 0 0]
set out [capture]
ok "reader tells `present` from `selected`" \
   [string match "*present=1 selected=0*" $out]

# The rival wedge: /HSHK asserted waiting to RECEIVE. Same stuck line, entirely
# different cause, and the two must not print the same verdict.
set probeval(PDCD) [mkpdcd 0x0E 0x00 2 0 0 0 1 1 0 0 0]
set probeval(PDC2) [mkpdc2 0 0 0 2 0 0 0]
set out [capture]
ok "a receive-side stall is NOT reported as the \$28 wedge" \
   [expr {![string match {*THE $28 WEDGE*} $out]}]

# Identification never attempted. This is the question the instruction-fetch
# sampler could not reach at all, and the whole reason PDCD exists.
set probeval(PDCD) [mkpdcd 0x0E 0x00 0 0 0 1 1 1 0 0 0]
set probeval(PDC2) [mkpdc2 0 0 0 0 0 0 0]
set out [capture]
ok "reader says so when the Mac never drove state 5" \
   [string match "*NEVER drove state 5*" $out]

# Probed, but no command followed: the ROM looked and moved on.
set probeval(PDCD) [mkpdcd 0xEE 0x00 0 0 0 1 1 1 0 0 0]
set out [capture]
ok "reader separates 'identified, no command' from 'never identified'" \
   [expr {[string match "*NO command ever arrived*" $out] &&
          ![string match "*NEVER drove state 5*" $out]}]

# Bytes arrived and nothing decoded: framing or checksum, not identification.
set probeval(PDCD) [mkpdcd 0xEE 0x00 0 0 0 1 1 1 0 1 0]
set probeval(PDC2) [mkpdc2 0 11 0 4 0 0 0]
set out [capture]
ok "reader separates a framing failure from a silent bus" \
   [string match "*bytes arrived but no frame ever decoded*" $out]

# Nothing mounted. Every other field is meaningless and the reader must say so
# rather than narrate zeros -- the failure mode the absent-probe handling above
# exists to close, one level in.
set probeval(PDCD) [mkpdcd 0x00 0x00 0 0 0 1 0 0 0 0 0]
set probeval(PDC2) [mkpdc2 0 0 0 0 0 0 0]
set out [capture]
ok "reader refuses to interpret a capture with no DCD mounted" \
   [string match "*no DCD image is MOUNTED*" $out]

# Saturation must read as saturation, not as a number.
set probeval(PDCD) [mkpdcd 0xEE 0x03 0 0 0 1 1 1 3 0 0]
set probeval(PDC2) [mkpdc2 255 63 5 4 0 0 0]
set out [capture]
ok "reader marks both saturated byte counters rather than printing a total" \
   [string match "*Mac->drive 63+ (SAT)   drive->Mac 255+ (SAT)*" $out]

# `clear` must actually write the source, and must say so when it cannot.
set ::sourcewrites {}
set argv {clear}
set out [capture]
set argv {}
ok "`clear` drives PDCD's source high then low" \
   [expr {[llength $::sourcewrites] == 2}]
ok "and says the capture was armed" \
   [string match "*cleared and armed*" $out]

set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PBLD}
set ::sourcewrites {}
set argv {clear}
set out [capture]
set argv {}
ok "a bitstream without PDCD is declared absent, not decoded as zeros" \
   [expr {[string match "*PDCD  ABSENT*" $out] &&
          ![string match "*no DCD image is MOUNTED*" $out]}]
ok "and `clear` on such a bitstream warns instead of writing a source" \
   [expr {[llength $::sourcewrites] == 0 &&
          [string match "*carries no PDCD*" $out]}]

set names {PIFA PACT PSCS PSCW PODR PIFD PRG0 PRG1 PIOS PIO2 PIO3 PIO4 PHLD PDMA PDM2 PDM3 PFLP PDCD PDC2 PBLD}

puts ""
puts "READER: $fails of $tests failing"
if {$fails == 0} {
	puts "PROBE READER GATE: PASS - the decode says what the capture means"
} else {
	puts "PROBE READER GATE: FAIL"
}
