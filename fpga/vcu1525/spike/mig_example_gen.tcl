# =============================================================================
# HADES-SRAM HW spike - step A: generate stock VCU1525 MIG (DDR4) example design
#
# Creates a throwaway project, instantiates the DDR4 MIG with VCU1525 board
# presets (channel c0, 300 MHz system clock, CPU_RESET button), then generates
# the IP example design project (MIG + basic traffic generator).
#
# Usage:  vivado -mode batch -source mig_example_gen.tcl
# Run from: fpga/vcu1525/spike/
# Outputs:  work/           (scratch project, gitignored)
#           ex_proj/        (example design project, gitignored)
#           mig_config_dump.txt (full resolved MIG config, for M5 reference)
# =============================================================================
set proj_dir [file normalize ./work]
create_project -force -part xcvu9p-fsgd2104-2L-e spike $proj_dir
set_property board_part xilinx.com:vcu1525:part0:1.3 [current_project]

create_ip -name ddr4 -vendor xilinx.com -library ip -module_name mig_0
set_property -dict [list \
  CONFIG.C0_CLOCK_BOARD_INTERFACE {default_300mhz_clk0} \
  CONFIG.C0_DDR4_BOARD_INTERFACE {ddr4_sdram_c0} \
  CONFIG.RESET_BOARD_INTERFACE {resetn} \
] [get_ips mig_0]

# Dump full resolved config (reference for the real build.tcl in M5)
set fh [open ./mig_config_dump.txt w]
foreach p [lsort [list_property [get_ips mig_0]]] {
  if {[string match "CONFIG.*" $p]} {
    puts $fh "$p = [get_property $p [get_ips mig_0]]"
  }
}
close $fh

generate_target all [get_ips mig_0]
open_example_project -dir [file normalize ./ex_proj] -force [get_ips mig_0]
close_project
puts "SPIKE_A_DONE: example project at ./ex_proj/mig_0_ex/mig_0_ex.xpr"
exit
