# =============================================================================
# HADES-SRAM HW spike - step B2: add VIO observability and rebuild
#
# 1. Patches the generated example_top.sv into example_top_had.sv (renamed
#    module, extra output c0_ui_clk). Written to ex_proj/patched/ — NOT into
#    imports/, which Vivado auto-disables for unregistered files.
# 2. Creates vio_0 (3 probe-ins) in the example project
# 3. Adds repo spike_top.sv, sets it as top, rebuilds to bitstream
#
# Usage:  vivado -mode batch -source add_vio_and_build.tcl
# Run from: fpga/vcu1525/spike/  (after mig_example_gen.tcl)
# =============================================================================
set exdir [file normalize ./ex_proj/mig_0_ex]

# --- 1. Patch example_top.sv -> ex_proj/patched/example_top_had.sv -----------
set srcfile $exdir/imports/example_top.sv
set fh [open $srcfile r]; set txt [read $fh]; close $fh
set n 0
incr n [regsub {module example_top #} $txt {module example_top_had #} txt]
incr n [regsub {(output +c0_data_compare_error,)} $txt {\1
    output                  c0_ui_clk,} txt]
incr n [regsub {( *wire +c0_wr_rd_complete;)} $txt {\1
  assign c0_ui_clk = c0_ddr4_clk;} txt]
if {$n != 3} { puts "SPIKE_PATCH_FAIL: only $n/3 substitutions applied"; exit 1 }
set patchdir [file normalize ./ex_proj/patched]
file mkdir $patchdir
set hadfile $patchdir/example_top_had.sv
set fh [open $hadfile w]; puts -nonewline $fh $txt; close $fh
puts "SPIKE_PATCH_OK: $hadfile"

# --- 2/3. Project edits ------------------------------------------------------
open_project $exdir/mig_0_ex.xpr

set vio_cfg [list \
  CONFIG.C_NUM_PROBE_IN {4} \
  CONFIG.C_PROBE_IN0_WIDTH {1} \
  CONFIG.C_PROBE_IN1_WIDTH {1} \
  CONFIG.C_PROBE_IN2_WIDTH {32} \
  CONFIG.C_PROBE_IN3_WIDTH {1} \
  CONFIG.C_NUM_PROBE_OUT {1} \
  CONFIG.C_PROBE_OUT0_WIDTH {1} \
  CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
]
if {[llength [get_ips -quiet vio_0]] == 0} {
  create_ip -name vio -vendor xilinx.com -library ip -module_name vio_0
}
set_property -dict $vio_cfg [get_ips vio_0]
generate_target all [get_ips vio_0]
if {[llength [get_runs -quiet vio_0_synth_1]]} { reset_run vio_0_synth_1 }

# drop any stale/auto-disabled registration, then add fresh
remove_files [get_files -quiet example_top_had.sv]
add_files -norecurse [list $hadfile [file normalize ./spike_top.sv]]
foreach f {example_top_had.sv spike_top.sv} {
  set fo [get_files -quiet $f]
  if {[llength $fo]} { set_property IS_ENABLED true $fo }
}
remove_files [get_files -quiet -of_objects [get_filesets sources_1] example_top.sv]
update_compile_order -fileset sources_1
set_property top spike_top [current_fileset]

# no incremental reuse of the previous example_top checkpoint
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]

# --- 3. Rebuild --------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "SPIKE_BUILD_FAIL: synth_1 not complete"; exit 1
}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "SPIKE_BUILD_FAIL: impl_1 not complete"; exit 1
}
puts "SPIKE_WNS: [get_property STATS.WNS [get_runs impl_1]]"
puts "SPIKE_BIT: [glob [get_property DIRECTORY [get_runs impl_1]]/*.bit]"
puts "SPIKE_BUILD_DONE"
close_project
exit
