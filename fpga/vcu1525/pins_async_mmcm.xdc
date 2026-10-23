# ASYNC fallback source: default_300mhz_clk1 (AW20/AW19) feeding MMCM2.
# Same crystal as the MIG reference — documented A10b deviation (see
# docs/integration_guide.md); used only when the PCIe slot refclk is
# unavailable.
set_property PACKAGE_PIN AW20 [get_ports clk1_p]
set_property PACKAGE_PIN AW19 [get_ports clk1_n]
set_property IOSTANDARD  LVDS [get_ports clk1_p]
set_property IOSTANDARD  LVDS [get_ports clk1_n]

create_clock -period 3.333 -name hades_clk1 [get_ports clk1_p]
