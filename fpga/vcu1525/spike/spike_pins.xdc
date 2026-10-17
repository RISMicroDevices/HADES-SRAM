# Spike status LEDs (VCU1525 GPIO_LED_0..2, LVCMOS12, active high)
set_property PACKAGE_PIN BC21 [get_ports c0_init_calib_complete]
set_property IOSTANDARD  LVCMOS12 [get_ports c0_init_calib_complete]
set_property PACKAGE_PIN BB21 [get_ports c0_data_compare_error]
set_property IOSTANDARD  LVCMOS12 [get_ports c0_data_compare_error]

# CPU_RESET button (AL20, LVCMOS12) - observed on VIO probe rst_pin only;
# the MIG sys_rst itself is VIO-driven in the spike (see spike_top.sv).
# The scoped BOARD_PART_PIN in mig_0_board.xdc cannot map sys_rst anymore
# (no direct top-port connection), so constrain the port here explicitly.
set_property PACKAGE_PIN AL20 [get_ports sys_rst]
set_property IOSTANDARD  LVCMOS12 [get_ports sys_rst]
