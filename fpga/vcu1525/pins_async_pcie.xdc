# ASYNC source variant: PCIe slot 100 MHz refclk (independent motherboard
# crystal).  The slot refclk lands on a GTY quad MGTREFCLK pair (right-edge
# quad feeding the pcie4 IP's channels at GTYE4_CHANNEL_X1Y20.., i.e. common
# X1Y5 -> package pins AW8/AW9 or AV10/AV11).
#
# TODO(hw): the exact P/N split needs the VCU1525 schematic (not available
# when this was written) — verify on the bench before using this build.
# The default ASYNC build uses the MMCM2 fallback (pins_async_mmcm.xdc).
set_property PACKAGE_PIN AW8 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN AW9 [get_ports pcie_refclk_n]

create_clock -period 10.000 -name hades_pcie_refclk [get_ports pcie_refclk_p]
