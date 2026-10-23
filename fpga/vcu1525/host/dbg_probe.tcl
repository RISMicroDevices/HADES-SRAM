# Debug probe: read traffic/error counters to distinguish write starvation
# from read-path failure on the currently programmed (failing) build.
set here [file dirname [file normalize [info script]]]
source $here/common.tcl

hw_open
reset_hw_axi [hw_axi]

foreach p {0 4 6 8 12 20 40 63} {
  mwr $::REG_PORT_SEL $p
  set rd  [mrd $::REG_PORT_STAT_RD]
  set wr  [mrd $::REG_PORT_STAT_WR]
  set err [mrd $::REG_PORT_STAT_ERR]
  puts [format "port %2d: RD=%9d WR=%9d ERR=%9d" $p $rd $wr $err]
}
puts [format "TOT_RD_LO = %d" [mrd $::REG_STAT_TOT_RD_LO]]
puts [format "TOT_WR_LO = %d" [mrd $::REG_STAT_TOT_WR_LO]]
puts [format "MAXLAT    = %d (ui cycles)" [mrd $::REG_STAT_MAXLAT]]
puts [format "REFCNT    = %d" [mrd $::REG_STAT_REFCNT]]
puts [format "ERR_STATUS= 0x%02X  ERR_ADDR=0x%08X" [mrd $::REG_ERR_STATUS] [mrd $::REG_ERR_ADDR]]

hw_close
exit 0
