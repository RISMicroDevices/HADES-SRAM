# =============================================================================
# HADES-SRAM — open the hades_sram IP configurator in the Vivado GUI.
#   vivado -source ip/open_ip_gui.tcl          (GUI mode; needs a display)
# Creates a throwaway empty project (ip/work_gui/), registers the packaged IP
# (ip/hades_sram_1.0 — rebuild it with package_ip.tcl) in the IP catalog, and
# opens the customization dialog for a new instance named hades_sram_0.
# =============================================================================
set here [file dirname [file normalize [info script]]]

create_project -force hades_ip_gui $here/work_gui -part xcvu9p-fsgd2104-2L-e
set_property ip_repo_paths [list $here/hades_sram_1.0 $here/hades_sram_1.0/interfaces] [current_project]
update_ip_catalog -rebuild
if {![llength [get_ipdefs -quiet rismd.cn:hades:hades_sram:1.1]]} {
  puts "HADES-GUI FAIL: rismd.cn:hades:hades_sram:1.1 not in catalog — run ip/package_ip.tcl first"
  exit 1
}

start_gui
load_features ipintegrator
if {[catch {
  create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1 \
    -module_name hades_sram_0
} result]} {
  puts "HADES-GUI FAIL: create_ip failed: $result"
  exit 1
}

# Let the GUI finish startup before creating the customization scope.
after 3000 {
  if {[catch {start_ip_gui -ip [get_ips hades_sram_0]} result]} {
    puts "HADES-GUI FAIL: start_ip_gui failed: $result"
  } else {
    puts "HADES-GUI: requested hades_sram_0 customization (scratch project: $here/work_gui)"
  }
}
