# =============================================================================
# HADES-SRAM — Vivado IP packager (spec DoD; M5-hw)
#
#   vivado -mode batch -source ip/package_ip.tcl
#
# Produces ip/hades_sram_1.0/ — a catalog-recognizable IP (vendor rismd.cn,
# VLNV version 1.1, default CLK_MODE=SYNC), bundling:
#   - rtl/*.sv (product RTL only; board/fpga files are NOT part of the IP)
#   - the custom SRAM bus/abstraction definitions under interfaces/
#   - constraints/hades_sram_clocks_{sync,async}.xdc and csr/csr_regmap.md
# Verification: catalog import, N-dependent IPI interface tags, and packaged-
# source OOC synthesis at both the default and a mixed-width/BE configuration.
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
set_property version 1.1 $core
set_property display_name "HADES-SRAM v1.1" $core
set_property description "HADES (Hybrid Accelerated and Distributed Emulation System): 1-64 separated deterministic-latency SRAM ports, per-port 1-512-bit data and optional byte enables, backed by one MIG DDR4 channel" $core
set_property company_url {} $core
set_property supported_families {virtexuplus Production} $core

proc hades_user_param {core name} {
  set p [ipx::get_user_parameters -quiet $name -of_objects $core]
  if {![llength $p]} { set p [ipx::add_user_parameter $name $core] }
  return $p
}

proc hades_bus_param {bus name value} {
  set p [ipx::get_bus_parameters -quiet $name -of_objects $bus]
  if {![llength $p]} { set p [ipx::add_bus_parameter $name $bus] }
  set_property value $value $p
}

# ---- custom SRAM interface definition, shipped beside the component so an
# exported repository remains self-contained.
set ifdir [file normalize $outdir/interfaces]
file mkdir $ifdir
set oldpwd [pwd]
cd $ifdir
set busdef [ipx::create_bus_definition -set_current true rismd.cn interface hades_sram 1.0]
set_property xml_file_name hades_sram.xml $busdef
set_property display_name {HADES-SRAM Port} $busdef
set_property description {Deterministic-latency emulated SRAM request/response port} $busdef
set_property direct_connection false $busdef
set_property is_addressable false $busdef
set_property max_masters 1 $busdef
set_property max_slaves 1 $busdef
ipx::save_bus_definition $busdef

set absdef [ipx::create_abstraction_definition -set_current true rismd.cn interface hades_sram_rtl 1.0]
set_property xml_file_name hades_sram_rtl.xml $absdef
set_property bus_type_vlnv rismd.cn:interface:hades_sram:1.0 $absdef
set_property display_name {HADES-SRAM Port RTL} $absdef
foreach {name description master_dir slave_dir width} {
  EN     {Port enable}          out in  1
  WE     {Write enable}         out in  1
  BE     {Byte enables}         out in  64
  ADDR   {Port word address}    out in  -1
  WDATA  {Write data}           out in  -1
  RDATA  {Read data}            in  out -1
  RVALID {Read response valid}  in  out 1
} {
  set p [ipx::add_bus_abstraction_port $name $absdef]
  set_property description $description $p
  set_property master_direction $master_dir $p
  set_property slave_direction $slave_dir $p
  set_property master_presence required $p
  set_property slave_presence required $p
  set_property master_width $width $p
  set_property slave_width $width $p
}
ipx::save_abstraction_definition $absdef
cd $oldpwd

# ---- separated slave interfaces.  Only ports below N are visible in IPI;
# disabled input pins receive a safe zero tie-off.
set sram_ifnames {}
for {set i 0} {$i < 64} {incr i} {
  set name "sram$i"
  lappend sram_ifnames $name
  set bif [ipx::add_bus_interface $name $core]
  set_property abstraction_type_vlnv rismd.cn:interface:hades_sram_rtl:1.0 $bif
  set_property bus_type_vlnv rismd.cn:interface:hades_sram:1.0 $bif
  set_property interface_mode slave $bif
  set_property display_name "SRAM Port $i" $bif
  set_property description "Separated SRAM port $i; data width W$i, optional byte enable BE${i}_EN" $bif
  set dep "(spirit:decode(id('MODELPARAM_VALUE.N')) > $i)"
  set_property enablement_dependency $dep $bif
  foreach {logical physical} {
    EN en WE we BE be ADDR addr WDATA wdata RDATA rdata RVALID rvalid
  } {
    set pm [ipx::add_port_map $logical $bif]
    set_property logical_name $logical $pm
    set_property physical_name "sram${i}_${physical}" $pm
  }
  foreach sig {en we be addr wdata rdata rvalid} {
    set port [ipx::get_ports "sram${i}_${sig}" -of_objects $core]
    set_property enablement_dependency $dep $port
    if {$sig ni {rdata rvalid}} { set_property driver_value 0 $port }
  }
}

# Interface associations are required for reliable customization-scope creation.
foreach {ifc pname pval} {
  ui_clk   FREQ_HZ          300000000
  ui_clk   ASSOCIATED_BUSIF m_axi:s_axil
  port_clk FREQ_HZ          500000
  m_axi    ASSOCIATED_CLOCK ui_clk
  s_axil   ASSOCIATED_CLOCK ui_clk
} {
  set b [ipx::get_bus_interfaces $ifc -of_objects $core]
  hades_bus_param $b $pname $pval
}
set b [ipx::get_bus_interfaces port_clk -of_objects $core]
hades_bus_param $b ASSOCIATED_BUSIF [join $sram_ifnames ":"]

# ---- parameter metadata, ranges, defaults, and human-readable names.
set p [hades_user_param $core N]
set_property value 1 $p
set_property value_format long $p
set_property value_validation_type range_long $p
set_property value_validation_range_minimum 1 $p
set_property value_validation_range_maximum 64 $p
set_property display_name "Number of SRAM ports" $p

for {set i 0} {$i < 64} {incr i} {
  set dep "(spirit:decode(id('MODELPARAM_VALUE.N')) > $i)"
  set p [hades_user_param $core "W$i"]
  set_property value 32 $p
  set_property value_format long $p
  set_property value_validation_type range_long $p
  set_property value_validation_range_minimum 1 $p
  set_property value_validation_range_maximum 512 $p
  set_property display_name "Port $i data width (bits)" $p
  set_property enablement_value 1 $p
  set_property enablement_dependency $dep [ipx::get_hdl_parameters "W$i" -of_objects $core]

  set p [hades_user_param $core "BE${i}_EN"]
  set_property value false $p
  set_property value_format bool $p
  set_property display_name "Enable byte enables on port $i" $p
  set_property enablement_value 1 $p
  set_property enablement_dependency $dep [ipx::get_hdl_parameters "BE${i}_EN" -of_objects $core]
}

foreach {name value text} {
  IS_SYNC     true  "Synchronous clocking (SYNC)"
  CSR_EN      true  "Enable CSR configuration interface"
  SELFTEST_EN false "Include built-in self-test engines"
} {
  set p [hades_user_param $core $name]
  set_property value $value $p
  set_property value_format bool $p
  set_property display_name $text $p
}

set p [hades_user_param $core P_L]
set_property value 2 $p
set_property value_format long $p
set_property value_validation_type pairs $p
set_property value_validation_pairs {1 1 2 2} $p
set_property display_name "Read latency in port_clk cycles (static configuration)" $p

set static_dep "(spirit:decode(id('MODELPARAM_VALUE.CSR_EN')) == 0)"
foreach name {P_L P_MIN_PERIOD P_REFRESH_DIV P_ZQ_DIV P_PORT_EN P_PORT_BASE P_PORT_SIZE} {
  set_property enablement_value 1 [hades_user_param $core $name]
  set_property enablement_dependency $static_dep [ipx::get_hdl_parameters $name -of_objects $core]
}
set selftest_dep "(spirit:decode(id('MODELPARAM_VALUE.SELFTEST_EN')) == 1)"
set_property enablement_value 1 [hades_user_param $core SELFTEST_BLK]
set_property enablement_dependency $selftest_dep [ipx::get_hdl_parameters SELFTEST_BLK -of_objects $core]

foreach {name text} {
  AW                   "SRAM address width (bits)"
  SELFTEST_BLK         "Self-test block size (words)"
  TARGET_PERIOD_CYCLES "Target port period (ui_clk cycles)"
  P_PORT_EN            "Static port-enable mask"
  P_MIN_PERIOD         "Minimum port period (ui_clk cycles, static)"
  P_REFRESH_DIV        "Refresh interval divider (static)"
  P_ZQ_DIV             "ZQ calibration interval divider (static)"
  P_PORT_BASE          "Static packed per-port base addresses"
  P_PORT_SIZE          "Static packed per-port sizes"
} {
  set_property display_name $text [hades_user_param $core $name]
}

# ---- per-CLK_MODE constraints (spec DoD): ship both files in the IP.  The
# SYNC file sits in the synthesis group (auto-loaded; CLK_MODE=SYNC is the
# default).  The ASYNC file ships in the documentation group: an integrator
# building with IS_SYNC=0 swaps it in for the SYNC one (see the file headers
# and INTEGRATION_GUIDE.md) — the 2024.1 packager API has no
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

set f_doc_grp [ipx::add_file_group -type documentation hades_doc $core]
ipx::add_file $outdir/doc/csr_regmap.md $f_doc_grp
ipx::add_file $outdir/doc/hades_sram_clocks_async.xdc $f_doc_grp

# ---- AXI4-Lite memory map: reserve a 64 KiB CSR window.
set mmaps [ipx::get_memory_maps -of_objects $core]
foreach mm $mmaps {
  set abs [ipx::get_address_blocks -of_objects $mm]
  if {![llength $abs]} {
    ipx::add_address_block csr $mm
    set abs [ipx::get_address_blocks -of_objects $mm]
  }
  foreach ab $abs { set_property range 64K $ab }
}

# Generate the callback skeleton first, then install the maintained layout.
# Do not call create_xgui_files again after this copy.
ipx::create_xgui_files $core
file copy -force $here/xgui/hades_sram_v1_1.tcl $outdir/xgui/hades_sram_v1_1.tcl
ipx::update_checksums $core
ipx::save_core $core
close_project

# ------------------------------------------------------------------ check --
set vdir [file normalize $here/work_verify]
file delete -force $vdir
create_project -force verify $vdir -part xcvu9p-fsgd2104-2L-e
set_property ip_repo_paths [list $outdir $ifdir] [current_project]
update_ip_catalog -rebuild
set defs [get_ipdefs -quiet rismd.cn:hades:hades_sram:1.1]
if {![llength $defs]} { puts "HADES-IP FAIL: core 1.1 not in catalog"; exit 1 }
puts "HADES-IP: catalog sees $defs"

foreach f [list $ifdir/hades_sram.xml $ifdir/hades_sram_rtl.xml \
                $outdir/xgui/hades_sram_v1_1.tcl] {
  if {![file exists $f]} { puts "HADES-IP FAIL: missing payload $f"; exit 1 }
}

# Prove that the custom definition resolves into real IPI interface pins and
# that N controls their visibility, not merely that component.xml imports.
create_bd_design hades_if_probe
set bdcell [create_bd_cell -type ip -vlnv rismd.cn:hades:hades_sram:1.1 hades]
proc hades_check_intf_count {cell expected} {
  set got [llength [get_bd_intf_pins -quiet ${cell}/sram*]]
  if {$got != $expected} {
    puts "HADES-IP FAIL: $cell has $got SRAM interface pins, expected $expected"
    exit 1
  }
  puts "HADES-IP: $cell exposes $expected SRAM interface pins"
}
if {[get_property CONFIG.N $bdcell] != 1} {
  puts "HADES-IP FAIL: IPI default N is not 1"; exit 1
}
hades_check_intf_count hades 1
set_property CONFIG.N 4 $bdcell
hades_check_intf_count hades 4
set_property CONFIG.N 64 $bdcell
hades_check_intf_count hades 64

# Elaborate and synthesize packaged sources at the default and at a mixed
# non-power-of-2 configuration with byte enables on two ports.
create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1 \
  -module_name hades_ip_inst
if {[get_property CONFIG.N [get_ips hades_ip_inst]] != 1} {
  puts "HADES-IP FAIL: standalone default N is not 1"; exit 1
}
proc hades_set_checked {ip name value} {
  set_property "CONFIG.$name" $value $ip
  set got [get_property "CONFIG.$name" $ip]
  if {$got ne $value} {
    puts "HADES-IP FAIL: sequential $name update produced $got, expected $value"
    exit 1
  }
}
create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1 \
  -module_name hades_ip_mixed
hades_set_checked [get_ips hades_ip_mixed] N 4
foreach {name value} {W0 40 W1 1 W2 300 W3 512 BE0_EN true BE3_EN true} {
  hades_set_checked [get_ips hades_ip_mixed] $name $value
}
create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1 \
  -module_name hades_ip_static
foreach {name value} {CSR_EN false P_L 1 SELFTEST_EN true SELFTEST_BLK 128} {
  hades_set_checked [get_ips hades_ip_static] $name $value
}
puts "HADES-IP: sequential GUI-style parameter updates verified"
set ip_objs [get_ips -quiet {hades_ip_inst hades_ip_mixed}]
generate_target all [get_ips -quiet {hades_ip_inst hades_ip_mixed hades_ip_static}]
synth_ip $ip_objs

# Synthesis alone would not catch a malformed external interface.  Check the
# actual generated wrapper widths at the mixed configuration as well.
set wrapper [file normalize $vdir/verify.gen/sources_1/ip/hades_ip_mixed/synth/hades_ip_mixed.v]
set f [open $wrapper r]
set wrapper_text [read $f]
close $f
set wrapper_text [regsub -all {\s+} $wrapper_text " "]
foreach fragment {
  {input wire [21 : 0] sram0_addr;}
  {input wire [21 : 0] sram3_addr;}
  {input wire [63 : 0] sram0_be;}
  {input wire [39 : 0] sram0_wdata;}
  {output wire [39 : 0] sram0_rdata;}
  {input wire [0 : 0] sram1_wdata;}
  {output wire [0 : 0] sram1_rdata;}
  {input wire [299 : 0] sram2_wdata;}
  {output wire [299 : 0] sram2_rdata;}
  {input wire [511 : 0] sram3_wdata;}
  {output wire [511 : 0] sram3_rdata;}
} {
  if {[string first $fragment $wrapper_text] < 0} {
    puts "HADES-IP FAIL: generated wrapper missing exact declaration: $fragment"
    exit 1
  }
}
puts "HADES-IP: generated mixed wrapper widths verified"
puts "HADES-IP PASS: packaged at $outdir (catalog + IPI tags + default/mixed OOC synth + wrapper widths verified)"
close_project
exit 0
