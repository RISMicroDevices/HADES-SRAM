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
puts "HADES-GUI: hades_sram customization dialog opened (scratch project: $here/work_gui)"
