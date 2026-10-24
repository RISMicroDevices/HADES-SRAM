# =============================================================================
# HADES-SRAM VCU1525 — JTAG-AXI path + ID smoke (pre-check for all A-tests).
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

hw_open
reset_hw_axi [hw_axi]

set id [mrd $::BREG_ID]
check_eq "BOARD_ID" $id 0xB0AD0110

mwr $::BREG_SCRATCH 0xDEADBEEF
check_eq "SCRATCH rw" [mrd $::BREG_SCRATCH] 0xDEADBEEF
mwr $::BREG_SCRATCH 0x12345678
check_eq "SCRATCH rw2" [mrd $::BREG_SCRATCH] 0x12345678

check_eq "HADES ID" [mrd $::REG_ID] 0xADE50110
set params [mrd $::REG_PARAMS]
puts "ok:   PARAMS = [format 0x%08X $params] (bit31 CLK_MODE: [expr {($params >> 31) & 1}], N_MAX=[expr {$params & 0xFF}])"

for {set p 0} {$p < 64} {incr p} {
  mwr $::REG_PORT_SEL $p
  check_eq "PORT_WIDTH port $p" [mrd $::REG_PORT_WIDTH] 32
}

hades_summary "SMOKE"
hw_close
exit [expr {$::g_fail_count != 0}]
