# Probe: find the VCU1525 PCIe slot refclk package pins by generating the
# pcie4 IP with the board interface and reading its pin constraints.
set proj_dir [file normalize ./work_pcie_probe]
file delete -force $proj_dir
create_project -force -part xcvu9p-fsgd2104-2L-e pcieprobe $proj_dir
set_property board_part xilinx.com:vcu1525:part0:1.3 [current_project]
create_ip -name pcie4_uscale_plus -vendor xilinx.com -library ip -module_name pcie4_0
set_property -dict [list \
  CONFIG.PCIE_BOARD_INTERFACE {pci_express_x16} \
  CONFIG.SYS_RST_N_BOARD_INTERFACE {pcie_perstn} \
] [get_ips pcie4_0]
generate_target all [get_ips pcie4_0]
puts "PROBE_PCIE_DONE"
exit
