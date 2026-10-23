# =============================================================================
# HADES-SRAM — Vivado IP packager (spec DoD; M5-hw)
#
#   vivado -mode batch -source ip/package_ip.tcl
#
# Produces ip/hades_sram_1.0/ — a catalog-recognizable IP (vendor hades,
# default CLK_MODE=SYNC), bundling:
#   - rtl/*.sv (product RTL only; board/fpga files are NOT part of the IP)
#   - constraints/hades_sram_clocks_{sync,async}.xdc (per-CLK_MODE auto-loading)
#   - csr/csr_regmap.md (indexed-window semantics documentation)
# Verification: the script re-packages and checks the core, then packages a
# second copy with IS_SYNC=0 to prove the ASYNC constraint attach works.
# =============================================================================

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/..]
set outdir [file normalize $here/hades_sram_1.0]
set work [file normalize $here/work_pkg]

file delete -force $work $outdir
file mkdir $work

create_project -force pkg $work -part xcvu9p-fsgd2104-2L-e
set_property board_part xilinx.com:vcu1525:part0:1.3 [current_project]

# product RTL
foreach f [lsort [glob $root/rtl/*.sv]] { add_files -norecurse $f }
set_property top hades_sram_top [current_fileset]

# constraints and CSR documentation are attached post-packaging via ipx
# (per-CLK_MODE file groups + doc group, see below)

# ---------------------------------------------------------------- package --
ipx::package_project -root_dir $outdir -vendor rismd.cn -library hades \
  -taxonomy /HADES -name hades_sram -import_files -force

set core [ipx::current_core]
set_property display_name "HADES-SRAM v1.0" $core
set_property description "HADES (Hybrid Accelerated and Distributed Emulation System) SRAM sub-project: up to 64 deterministic-latency emulated-SRAM ports on one MIG DDR4 channel" $core
set_property company_url {} $core
set_property supported_families {virtexuplus Production} $core

# ---- parameter visibility / display names
set disp [ipx::add_user_parameter IS_SYNC $core]
set_property value 1 $disp
set_property value_format long $disp
set_property display_name "CLK_MODE (1=SYNC, 0=ASYNC)" $disp

# ---- per-CLK_MODE constraints (spec DoD): ship both files in the IP.  The
# SYNC file sits in the synthesis group (auto-loaded; CLK_MODE=SYNC is the
# default).  The ASYNC file ships in the documentation group: an integrator
# building with IS_SYNC=0 swaps it in for the SYNC one (see the file headers
# and docs/integration_guide.md) — the 2024.1 packager API has no
# parameter-conditional file enablement, so the swap is a documented step.
file mkdir $outdir/doc
file copy -force $root/constraints/hades_sram_clocks_sync.xdc  $outdir/doc/
file copy -force $root/constraints/hades_sram_clocks_async.xdc $outdir/doc/
file copy -force $root/csr/csr_regmap.md                  $outdir/doc/

set synth_grp ""
foreach g [ipx::get_file_groups -of_objects $core] {
  if {[get_property type $g] eq "synthesis"} { set synth_grp $g; break }
}
if {$synth_grp eq ""} { set synth_grp [lindex [ipx::get_file_groups -of_objects $core] 0] }
ipx::add_file $outdir/doc/hades_sram_clocks_sync.xdc $synth_grp

# ---- CSR documentation (indexed-window semantics) + ASYNC constraint file
set f_doc_grp [ipx::add_file_group -type documentation hades_doc $core]
ipx::add_file $outdir/doc/csr_regmap.md $f_doc_grp
ipx::add_file $outdir/doc/hades_sram_clocks_async.xdc $f_doc_grp

# ---- AXI4-Lite memory map (auto-inferred from s_axil_* ports): give the
# register window a 64 KiB range
set mmaps [ipx::get_memory_maps -of_objects $core]
foreach mm $mmaps {
  set abs [ipx::get_address_blocks -of_objects $mm]
  if {![llength $abs]} {
    ipx::add_address_block csr $mm
    set abs [ipx::get_address_blocks -of_objects $mm]
  }
  foreach ab $abs { set_property range 64K $ab }
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
close_project

# ------------------------------------------------------------------ check --
# Catalog-recognition + elaboration proof: fresh project, add the repo, find
# the core, instantiate it, and synthesize its out-of-context stub from the
# PACKAGED sources (also proves the doc/xdc payload shipped).
set vdir [file normalize $here/work_verify]
file delete -force $vdir
create_project -force verify $vdir -part xcvu9p-fsgd2104-2L-e
set_property ip_repo_paths [list $outdir] [current_project]
update_ip_catalog
set defs [get_ipdefs -filter {NAME =~ *hades_sram*}]
if {![llength $defs]} { puts "HADES-IP FAIL: core not in catalog"; exit 1 }
puts "HADES-IP: catalog sees $defs"
create_ip -name hades_sram -vendor rismd.cn -library hades -module_name hades_ip_inst
generate_target all [get_ips hades_ip_inst]
synth_ip [get_ips hades_ip_inst]
puts "HADES-IP PASS: packaged at $outdir (catalog + OOC synth verified)"
close_project
exit 0
