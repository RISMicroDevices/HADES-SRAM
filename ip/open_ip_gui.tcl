# =============================================================================
# HADES-SRAM — open the hades_sram IP configurator in the Vivado GUI.
#   vivado -source ip/open_ip_gui.tcl          (GUI mode; needs a display)
# Creates a throwaway empty project (ip/work_gui/), registers the packaged IP
# (ip/hades_sram_1.0 — rebuild it with package_ip.tcl) in the IP catalog, and
# opens the customization dialog for a new instance named hades_sram_0.
# =============================================================================
set here [file dirname [file normalize [info script]]]

create_project -force hades_ip_gui $here/work_gui -part xcvu9p-fsgd2104-2L-e
set_property ip_repo_paths [list $here/hades_sram_1.0] [current_project]
update_ip_catalog
if {![llength [get_ipdefs -quiet rismd.cn:hades:hades_sram:1.0]]} {
  puts "HADES-GUI FAIL: rismd.cn:hades:hades_sram:1.0 not in catalog — run ip/package_ip.tcl first"
  exit 1
}

start_gui
start_ip_gui -vlnv rismd.cn:hades:hades_sram:1.0 -module_name hades_sram_0
# The customization scope builds in an ASYNC GUI event after this command
# returns — a Tcl-clean return proves nothing (failure signature: Common
# 17-190 rdi::create_slave + IP_Flow 19-883/19-3428 + rollback per 19-5622).
# Let events drain, then verify the instance actually exists; on failure,
# fall back to a plain create_ip (the GUI-then-double-click path is robust).
after 3000
if {[llength [get_ips -quiet hades_sram_0]]} {
  puts "HADES-GUI PASS: hades_sram_0 customization dialog opened (scratch project: $here/work_gui)"
} else {
  puts "HADES-GUI: start_ip_gui scope failed (see IP_Flow errors above) — fell back to create_ip; double-click hades_sram_0 under Design Sources to customize"
  create_ip -name hades_sram -vendor rismd.cn -library hades -module_name hades_sram_0
}
