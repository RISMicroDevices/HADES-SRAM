# =============================================================================
# HADES-SRAM VCU1525 — implement from an existing post-synth checkpoint
# (iteration helper; the one-command flow is build.tcl).
#   vivado -mode batch -source impl_from_synth.tcl -tclargs <tag> <SYNC|ASYNC>
# Reads build/<tag>/post_synth.dcp; writes bit/ltx + reports into build/<tag>.
# =============================================================================

set tag  [lindex $argv 0]
set mode [string toupper [lindex $argv 1]]
if {$mode ni {SYNC ASYNC}} { set mode "SYNC" }
set is_sync [expr {$mode eq "SYNC"}]

set here [file dirname [file normalize [info script]]]
set bdir [file normalize $here/build/$tag]

open_checkpoint $bdir/post_synth.dcp

# -------------------------------------------- post-synth ILA (port_clk) ----
# A4 spot-check witness: request edge + rvalid for ports 0..3, on the nets
# preserved by debug_probes.xdc (MARK_DEBUG applied pre-synthesis).
set pc_nets_p0 [list]
set pc_nets_p1 [list]
foreach i {0 1 2 3} {
  set rq [get_nets "u_hades/g_ports[$i].u_port/rd_req_p"]
  set rv [get_nets "u_hades/g_ports[$i].u_port/rvalid"]
  if {![llength $rq] || ![llength $rv]} {
    puts "HADES-BUILD FAIL: ILA probe nets not found for port $i"; exit 1
  }
  lappend pc_nets_p0 $rq
  lappend pc_nets_p1 $rv
}
set pc_nets [concat $pc_nets_p0 $pc_nets_p1]
foreach n $pc_nets { set_property MARK_DEBUG true $n }

create_debug_core u_ila_pc ila
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_pc]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_ila_pc]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_pc]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_pc]
set_property C_EN_STRG_QUAL 1 [get_debug_cores u_ila_pc]
set_property ALL_PROBE_SAME_MU_CNT 2 [get_debug_cores u_ila_pc]
connect_debug_port u_ila_pc/clk [get_nets port_clk]
set_property port_width 4 [get_debug_ports u_ila_pc/probe0]
connect_debug_port u_ila_pc/probe0 $pc_nets_p0
create_debug_port u_ila_pc probe
set_property port_width 4 [get_debug_ports u_ila_pc/probe1]
connect_debug_port u_ila_pc/probe1 $pc_nets_p1

# ------------------------------------------------------------- implement --
opt_design
place_design
phys_opt_design
# post-place: the domain-crossing constraints (see timing_sync.xdc /
# timing_async.xdc for why they are not in the pre-synth set)
if {$is_sync} { read_xdc $here/timing_multicycle.xdc } \
else          { read_xdc $here/timing_async_cross.xdc }
route_design -directive AggressiveExplore
write_debug_probes -force $bdir/hades_sram_vcu1525_${tag}.ltx

file mkdir $bdir/reports
report_timing_summary -file $bdir/reports/timing_summary.rpt
report_utilization    -file $bdir/reports/utilization.rpt
report_drc            -file $bdir/reports/drc.rpt
if {!$is_sync} {
  report_cdc -details -file $bdir/reports/cdc.rpt
}

write_bitstream -force $bdir/hades_sram_vcu1525_${tag}.bit

# ---------------------------------------------------------------- A1 gate --
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "HADES-BUILD: WNS=$wns"
if {$wns < 0} { puts "HADES-BUILD FAIL: timing (WNS=$wns)"; exit 1 }

if {!$is_sync} {
  set cdc_viol [llength [get_cdc_violations]]
  puts "HADES-BUILD: CDC violations=$cdc_viol"
  if {$cdc_viol != 0} { puts "HADES-BUILD FAIL: report_cdc violations"; exit 1 }
}

puts "HADES-BUILD PASS: $bdir/hades_sram_vcu1525_${tag}.bit"
exit 0
