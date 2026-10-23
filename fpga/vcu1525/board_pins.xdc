# =============================================================================
# HADES-SRAM VCU1525 — board pins (both builds)
# DDR4 C0 + c0_sys_clk pins come from the MIG's board-interface XDC; the
# MIG sys_rst is driven internally (inverted CPU_RESET), so the button pin is
# constrained here (same pattern as the spike).
# =============================================================================

# CPU_RESET push button (active low, idles high)
set_property PACKAGE_PIN AL20 [get_ports cpu_resetn]
set_property IOSTANDARD  LVCMOS12 [get_ports cpu_resetn]

# User LEDs 2..0 (active high)
set_property PACKAGE_PIN BC21 [get_ports {led[0]}]
set_property IOSTANDARD  LVCMOS12 [get_ports {led[0]}]
set_property PACKAGE_PIN BB21 [get_ports {led[1]}]
set_property IOSTANDARD  LVCMOS12 [get_ports {led[1]}]
set_property PACKAGE_PIN BA20 [get_ports {led[2]}]
set_property IOSTANDARD  LVCMOS12 [get_ports {led[2]}]

# ASYNC clock-source input pairs are constrained per build (they are unused
# in the SYNC project): see pins_async_mmcm.xdc / pins_async_pcie.xdc.
