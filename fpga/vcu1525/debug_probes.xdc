# =============================================================================
# HADES-SRAM VCU1525 — debug probe marks (board builds only), applied
# pre-synthesis so the nets resolve by their RTL names and are preserved.
# The port_clk ILA (created post-synthesis in build.tcl/impl_from_synth.tcl)
# connects to these nets:
#   probe0 = rd_req_p[3:0]  (accepted request, port_clk domain)
#   probe1 = rvalid[3:0]
# NOTE: XDC files do not support foreach loops — the 8 marks are unrolled.
# =============================================================================
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[0].u_port/rd_req_p"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[0].u_port/rvalid"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[1].u_port/rd_req_p"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[1].u_port/rvalid"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[2].u_port/rd_req_p"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[2].u_port/rvalid"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[3].u_port/rd_req_p"]
set_property MARK_DEBUG TRUE [get_nets "u_hades/g_ports[3].u_port/rvalid"]

# phys_opt replicates the drivers and strands the post-synth ILA tap on a dead
# replica (2026-10-22: armed/triggered ILA, 178k requests flowing, all-0
# capture).  DONT_TOUCH the tapped nets so the tap's load stays live.
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[0].u_port/rd_req_p"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[0].u_port/rvalid"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[1].u_port/rd_req_p"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[1].u_port/rvalid"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[2].u_port/rd_req_p"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[2].u_port/rvalid"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[3].u_port/rd_req_p"]
set_property DONT_TOUCH TRUE [get_nets "u_hades/g_ports[3].u_port/rvalid"]
