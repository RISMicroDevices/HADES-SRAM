# =============================================================================
# HADES-SRAM VCU1525 — A2: power-up init (spec 6.2)
#   CALIB_DONE=1, READY=1 after ENABLE; measured port_clk period matches the
#   programmed gear +-0.1%.  -tclargs <div_src_cycles> (default 600 = 500 KHz
#   SYNC gear; ASYNC MMCM build: 200)
# =============================================================================
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

set div [lindex $argv 0]
if {$div eq ""} { set div 600 }

hw_open
reset_hw_axi [hw_axi]

check_eq "BOARD_ID" [mrd $::BREG_ID] 0xB0AD0100
check_eq "HADES ID" [mrd $::REG_ID] 0xADE50100

# config-integrity guard (2026-10-20 anomaly: one boot came up with garbage
# nonzero config defaults — refresh_div=15 stormed the backend to death)
# CFG_MIN_PERIOD counts ui_clk cycles (TARGET_PERIOD_500K=600) — independent
# of the gear source, so it is 600 on SYNC and ASYNC builds alike.
check_eq "CFG_REFRESH_DIV default" [mrd $::REG_CFG_REFRESH_DIV] 2100
check_eq "CFG_ZQ_DIV default" [mrd $::REG_CFG_ZQ_DIV] 32000
check_eq "CFG_MIN_PERIOD default" [mrd $::REG_CFG_MIN_PERIOD] 600

# clock gear
set_gear $div
after 100
check_meas [gear_ui_cycles $div]

# STATUS before enable: CALIB=1, READY=0
set s [mrd $::REG_STATUS]
check_eq "STATUS.CALIB before ENABLE" [expr {$s & 1}] 1
check_eq "STATUS.READY before ENABLE" [expr {($s >> 1) & 1}] 0

hades_enable 2 64
set s [mrd $::REG_STATUS]
check_eq "STATUS after ENABLE (CALIB|READY)" [expr {$s & 0x3}] 0x3
check_meas [gear_ui_cycles $div]

hades_disable
hades_summary "A2"
hw_close
exit [expr {$::g_fail_count != 0}]
