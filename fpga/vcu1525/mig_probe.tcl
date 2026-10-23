# M5-hw: probe — generate the production MIG config in a scratch project and
# dump the resulting port list (stub), so hades_sram_board_top.sv can be written
# against exact names.  Not part of the build; run once by hand.
set proj_dir [file normalize ./work_mig_probe]
create_project -force -part xcvu9p-fsgd2104-2L-e probe $proj_dir
set_property board_part xilinx.com:vcu1525:part0:1.3 [current_project]

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
  CONFIG.C0.DDR4_DataMask {dm_no_dbi} \
] [get_ips mig_0]

generate_target all [get_ips mig_0]

# resolved config dump (compare against spike baseline)
set fh [open ./mig_config_prod.txt w]
foreach p [lsort [list_property [get_ips mig_0]]] {
  if {[string match "CONFIG.*" $p]} { puts $fh "$p = [get_property $p [get_ips mig_0]]" }
}
close $fh
puts "PROBE_DONE"
exit
