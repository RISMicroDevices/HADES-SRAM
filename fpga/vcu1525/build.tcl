# =============================================================================
# HADES-SRAM VCU1525 — one-command FPGA build (spec A1; M5-hw)
#
#   vivado -mode batch -source build.tcl -tclargs SYNC  [PCIE|MMCM]
#   vivado -mode batch -source build.tcl -tclargs ASYNC [PCIE|MMCM]
#
#   SYNC  (primary): port_clk = ui_clk/600 fabric divider (same-source)
#   ASYNC (second) : port_clk = PCIe slot refclk (default) or second MMCM on
#                    the other onboard 300 MHz input (fallback; documented
#                    A10b deviation)
#
# Outputs under build/<MODE>[-<SRC>]/ :
#   hades_vcu1525_<tag>.bit / .ltx, reports/ (timing, cdc [ASYNC], util, drc)
#
# A1 gates (scripted): WNS >= 0 everywhere; ASYNC additionally requires
# report_cdc zero violations.
# =============================================================================

set mode   [string toupper [lindex $argv 0]]
if {$mode ni {SYNC ASYNC}} { set mode "SYNC" }
# ASYNC clock source: MMCM (default, standalone-safe) | PCIE (slot refclk —
# needs the TBD pin verification in pins_async_pcie.xdc first)
set clksrc [string toupper [lindex $argv 1]]
if {$clksrc ni {PCIE MMCM}} { set clksrc "MMCM" }
set is_sync [expr {$mode eq "SYNC"}]
set tag     [string tolower $mode]
if {!$is_sync} { set tag "${tag}_$clksrc" }

set here   [file dirname [file normalize [info script]]]
set root   [file normalize $here/../..]
set bdir   [file normalize $here/build/$tag]
file delete -force $bdir
file mkdir $bdir

puts "HADES-BUILD: mode=$mode clksrc=$clksrc -> $bdir"

# ---------------------------------------------------------------- project --
create_project -force hades_vcu1525_$tag $bdir/proj -part xcvu9p-fsgd2104-2L-e
set_property board_part xilinx.com:vcu1525:part0:1.3 [current_project]
set_property target_language Verilog [current_project]

# --------------------------------------------------------------------- IP --
# MIG C0: DDR4-2400 RDIMM (board presets), AXI4 512-bit x ID4 x 34-bit
# byte address, User Refresh and ZQCS Input ON (spec 3.2 requirement).
# ECC = OFF: with ECC on, every 32-bit partial-beat WSTRB write costs a
# DRAM read-modify-write cycle inside the MIG — measured on hardware
# (A4, 2026-10-19): the write engine starved ~10x under 64-port load and
# FCFS lowest-index priority starved ports 7+.  ECC is not a spec
# requirement; the on-chip selftest covers data integrity.  (Re-enabling
# ECC would need a write-coalescing front end — documented in the guide.)
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name mig_0
set_property -dict [list \
  CONFIG.C0_CLOCK_BOARD_INTERFACE {default_300mhz_clk0} \
  CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram_c0} \
  CONFIG.RESET_BOARD_INTERFACE {resetn} \
  CONFIG.C0.DDR4_AxiSelection {true} \
  CONFIG.C0.DDR4_AxiDataWidth {512} \
  CONFIG.C0.DDR4_AxiIDWidth {4} \
  CONFIG.C0.DDR4_UserRefresh_ZQCS {true} \
  CONFIG.C0.DDR4_Ecc {false} \
  CONFIG.C0.DDR4_DataMask {true} \
] [get_ips mig_0]

# JTAG-AXI master, AXI4-Lite (PROTOCOL=2; single-outstanding queues)
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name jtag_axi_0
set_property -dict [list \
  CONFIG.PROTOCOL {2} \
  CONFIG.M_AXI_DATA_WIDTH {32} \
  CONFIG.M_AXI_ADDR_WIDTH {32} \
] [get_ips jtag_axi_0]

# ui_clk ILA: refresh/ZQCS handshake + backend AXI activity + calib
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_ui_0
set_property -dict [list \
  CONFIG.C_DATA_DEPTH {4096} \
  CONFIG.C_NUM_OF_PROBES {3} \
  CONFIG.C_PROBE0_WIDTH {4} \
  CONFIG.C_PROBE1_WIDTH {9} \
  CONFIG.C_PROBE2_WIDTH {3} \
  CONFIG.C_INPUT_PIPE_STAGES {1} \
] [get_ips ila_ui_0]

# -------------------------------------------------------------------- RTL --
read_verilog -library work [glob $root/rtl/*.sv]
read_verilog -library work [glob $here/rtl/*.sv]

set defs [list]
if {!$is_sync && $clksrc eq "PCIE"} { lappend defs BOARD_CLKSRC_PCIE }
if {!$is_sync && $clksrc eq "PCIE"} { lappend defs BOARD_DIV_DEFAULT=100 }
if {!$is_sync && $clksrc eq "MMCM"} { lappend defs BOARD_DIV_DEFAULT=200 }
if {[llength $defs]} { set_property verilog_define $defs [get_filesets sources_1] }

# -------------------------------------------------------------------- XDC --
read_xdc $here/board_pins.xdc
read_xdc $here/debug_probes.xdc
if {$is_sync} {
  read_xdc $here/timing_sync.xdc
} else {
  read_xdc $here/timing_async.xdc
  if {$clksrc eq "PCIE"} { read_xdc $here/pins_async_pcie.xdc } \
  else                   { read_xdc $here/pins_async_mmcm.xdc }
}

set_property top hades_board_top [current_fileset]
set_property generic SYNC_MODE=$is_sync [get_filesets sources_1]

generate_target all [get_ips]

# ------------------------------------------------------------------ synth --
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "HADES-BUILD FAIL: synthesis did not complete"; exit 1
}
open_run synth_1
write_checkpoint -force $bdir/post_synth.dcp

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
# 300 MHz closure (2026-10-21 iterations): the residual failures are
# route-dominated near-misses on high-fanout control nets (ui_rst R pins,
# engine CE cones) — ExtraNetDelay_high makes the placer pay for net delay,
# AggressiveFanoutOpt replicates the high-fanout drivers post-place.
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveFanoutOpt
# post-place: the domain-crossing constraints (see timing_sync.xdc /
# timing_async.xdc for why they are not in the pre-synth set)
if {$is_sync} { read_xdc $here/timing_multicycle.xdc } \
else          { read_xdc $here/timing_async_cross.xdc }
route_design -directive AggressiveExplore
# last-mile recovery (2026-10-21: -0.053 -> +0.002 on SYNC): when the
# aggressive route misses by a small margin, post-route phys_opt plus a
# slack-focused re-route closes it.  Conditional, so clean routes stay fast.
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} {
  puts "HADES-BUILD: route WNS<0 -> post-route phys_opt + NoTimingRelaxation re-route"
  phys_opt_design -directive AggressiveExplore
  route_design -directive NoTimingRelaxation
}
write_debug_probes -force $bdir/hades_vcu1525_${tag}.ltx
# keep the routed database: post-build timing triage queries (report_timing
# on the worst cones) read this instead of re-running place+route
write_checkpoint -force $bdir/post_route.dcp

# reviewed CDC dispositions must exist before report_cdc runs (see file header)
if {!$is_sync} { source $here/cdc_waivers.tcl }

file mkdir $bdir/reports
report_timing_summary -file $bdir/reports/timing_summary.rpt
report_utilization    -file $bdir/reports/utilization.rpt
report_drc            -file $bdir/reports/drc.rpt
if {!$is_sync} {
  report_cdc -details -file $bdir/reports/cdc.rpt
}

write_bitstream -force $bdir/hades_vcu1525_${tag}.bit

# ---------------------------------------------------------------- A1 gate --
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "HADES-BUILD: WNS=$wns"
if {$wns < 0} { puts "HADES-BUILD FAIL: timing (WNS=$wns)"; exit 1 }

if {!$is_sync} {
  # gate on unwaived Critical/Warning only: Info findings are recognized
  # ASYNC_REG synchronizers (evidence of correct CDC, not problems)
  set cdc_viol [llength [get_cdc_violations -filter {SEVERITY == "Critical" || SEVERITY == "Warning"}]]
  puts "HADES-BUILD: CDC violations=$cdc_viol (unwaived Critical+Warning)"
  if {$cdc_viol != 0} { puts "HADES-BUILD FAIL: report_cdc violations"; exit 1 }
}

puts "HADES-BUILD PASS: $bdir/hades_vcu1525_${tag}.bit"
exit 0
