proc hades_validate_integer {param lo hi label} {
  set value [get_property value $param]
  if {![string is integer -strict $value] || $value < $lo || $value > $hi} {
    set_property errmsg "$label must be an integer in the range $lo..$hi" $param
    return false
  }
  set_property errmsg "" $param
  return true
}

proc hades_set_enabled {IPINST name enabled domain} {
  if {$domain eq "gui"} {
    set_property enabled $enabled [ipgui::get_guiparamspec $name -of $IPINST]
  } else {
    set_property enabled $enabled [ipgui::get_paramspec $name -of $IPINST]
  }
}

proc hades_update_n {IPINST domain} {
  set n [get_property value [ipgui::get_paramspec N -of $IPINST]]
  for {set i 0} {$i < 64} {incr i} {
    set enabled [expr {$i < $n ? "true" : "false"}]
    hades_set_enabled $IPINST "W$i" $enabled $domain
    hades_set_enabled $IPINST "BE${i}_EN" $enabled $domain
  }
}

proc hades_update_csr {IPINST domain} {
  set csr [get_property value [ipgui::get_paramspec CSR_EN -of $IPINST]]
  if {$csr eq "true" || $csr eq "1"} { set enabled false } else { set enabled true }
  foreach name {P_L P_MIN_PERIOD P_REFRESH_DIV P_ZQ_DIV P_PORT_EN P_PORT_BASE P_PORT_SIZE} {
    hades_set_enabled $IPINST $name $enabled $domain
  }
}

proc hades_update_selftest {IPINST domain} {
  set selftest [get_property value [ipgui::get_paramspec SELFTEST_EN -of $IPINST]]
  if {$selftest eq "true" || $selftest eq "1"} { set enabled true } else { set enabled false }
  hades_set_enabled $IPINST SELFTEST_BLK $enabled $domain
}

proc init_params {IPINST} {
  set choices {}
  for {set i 1} {$i <= 64} {incr i} { lappend choices $i }
  set_property range [join $choices ","] [ipgui::get_paramspec N -of $IPINST]
  set_property range "1,2" [ipgui::get_paramspec P_L -of $IPINST]
}

proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name Component_Name

  set general [ipgui::add_page $IPINST -name General -display_name "General" -layout vertical]
  ipgui::add_static_text $IPINST -name General_Info -parent $general \
    -text {Configure 1-64 separated SRAM ports. Each port accepts any data width from 1 to 512 bits; widths need not be powers of two.}
  set n_widget [ipgui::add_param $IPINST -parent $general -name N -widget comboBox]
  set_property tooltip "Number of active SRAM interfaces exposed on the module graph" $n_widget
  ipgui::add_param $IPINST -parent $general -name AW -widget textEdit

  set behavior [ipgui::add_group $IPINST -parent $general -name Behavior \
    -display_name "Clocking and built-in features" -layout vertical]
  ipgui::add_param $IPINST -parent $behavior -name IS_SYNC -widget checkBox
  ipgui::add_param $IPINST -parent $behavior -name CSR_EN -widget checkBox
  ipgui::add_param $IPINST -parent $behavior -name P_L -widget comboBox
  ipgui::add_param $IPINST -parent $behavior -name SELFTEST_EN -widget checkBox
  ipgui::add_param $IPINST -parent $behavior -name SELFTEST_BLK -widget textEdit

  set ports_page [ipgui::add_page $IPINST -name SRAM_Ports -display_name "SRAM Ports" -layout vertical]
  set ports_panel [ipgui::add_panel $IPINST -parent $ports_page -name Port_Groups -layout vertical]
  for {set base 0} {$base < 64} {incr base 8} {
    set end [expr {$base + 7}]
    set page [ipgui::add_page $IPINST -parent $ports_panel -name "Ports_${base}_${end}" \
      -display_name "Ports $base-$end" -layout vertical]
    for {set i $base} {$i <= $end} {incr i} {
      set group [ipgui::add_group $IPINST -parent $page -name "Port_${i}" \
        -display_name "Port $i" -collapsed true -layout vertical]
      set width [ipgui::add_param $IPINST -parent $group -name "W$i" \
        -widget textEdit -show_range true]
      set_property tooltip "Any integer width from 1 to 512 bits; non-power-of-2 widths are supported" $width
      set be [ipgui::add_param $IPINST -parent $group -name "BE${i}_EN" -widget checkBox]
      set_property tooltip "When disabled, writes affect the complete port word and BE is ignored" $be
    }
  }

  set maintenance [ipgui::add_page $IPINST -name Maintenance -display_name "Maintenance" -layout vertical]
  set timing [ipgui::add_group $IPINST -parent $maintenance -name Timing \
    -display_name "Port timing" -layout vertical]
  ipgui::add_param $IPINST -parent $timing -name TARGET_PERIOD_CYCLES -widget textEdit
  set static_timing [ipgui::add_group $IPINST -parent $maintenance -name Static_Timing \
    -display_name "Static configuration (CSR disabled)" -collapsed true -layout vertical]
  foreach name {P_MIN_PERIOD P_REFRESH_DIV P_ZQ_DIV} {
    ipgui::add_param $IPINST -parent $static_timing -name $name -widget textEdit
  }

  set addressing [ipgui::add_page $IPINST -name Static_Addressing \
    -display_name "Static Addressing" -layout vertical]
  ipgui::add_static_text $IPINST -name Addressing_Info -parent $addressing \
    -text {These packed parameters apply only when the CSR configuration interface is disabled.}
  set address_group [ipgui::add_group $IPINST -parent $addressing -name Address_Map \
    -display_name "Port address map" -collapsed true -layout vertical]
  foreach name {P_PORT_EN P_PORT_BASE P_PORT_SIZE} {
    ipgui::add_param $IPINST -parent $address_group -name $name -widget textEdit
  }
  hades_update_n $IPINST gui
  hades_update_csr $IPINST gui
  hades_update_selftest $IPINST gui
}

proc update_gui_for_PARAM_VALUE.N {IPINST PARAM_VALUE.N} {
  hades_update_n $IPINST gui
}

proc update_gui_for_PARAM_VALUE.CSR_EN {IPINST PARAM_VALUE.CSR_EN} {
  hades_update_csr $IPINST gui
}

proc update_gui_for_PARAM_VALUE.SELFTEST_EN {IPINST PARAM_VALUE.SELFTEST_EN} {
  hades_update_selftest $IPINST gui
}

proc update_PARAM_VALUE.N {IPINST PARAM_VALUE.N} {
  hades_update_n $IPINST param
}

proc update_PARAM_VALUE.CSR_EN {IPINST PARAM_VALUE.CSR_EN} {
  hades_update_csr $IPINST param
}

proc update_PARAM_VALUE.SELFTEST_EN {IPINST PARAM_VALUE.SELFTEST_EN} {
  hades_update_selftest $IPINST param
}

proc validate_PARAM_VALUE.N {PARAM_VALUE.N} {
  return [hades_validate_integer ${PARAM_VALUE.N} 1 64 "SRAM port count"]
}

proc validate_PARAM_VALUE.P_L {PARAM_VALUE.P_L} {
  set value [get_property value ${PARAM_VALUE.P_L}]
  if {$value ni {1 2}} {
    set_property errmsg "Read latency must be 1 or 2 port_clk cycles" ${PARAM_VALUE.P_L}
    return false
  }
  set_property errmsg "" ${PARAM_VALUE.P_L}
  return true
}

for {set i 0} {$i < 64} {incr i} {
  proc "validate_PARAM_VALUE.W$i" [list "PARAM_VALUE.W$i"] \
    [format {return [hades_validate_integer ${PARAM_VALUE.W%d} 1 512 "Port data width"]} $i]
}

set hades_model_params {
  N AW IS_SYNC CSR_EN SELFTEST_EN SELFTEST_BLK TARGET_PERIOD_CYCLES
  P_L P_PORT_EN P_MIN_PERIOD P_REFRESH_DIV P_ZQ_DIV P_PORT_BASE P_PORT_SIZE
}
for {set i 0} {$i < 64} {incr i} {
  lappend hades_model_params "W$i" "BE${i}_EN"
}
foreach name $hades_model_params {
  proc "update_MODELPARAM_VALUE.$name" \
    [list "MODELPARAM_VALUE.$name" "PARAM_VALUE.$name"] \
    [format {set_property value [get_property value ${PARAM_VALUE.%s}] ${MODELPARAM_VALUE.%s}} $name $name]
}

proc hades_sync_bool {model param} {
  set value [get_property value $param]
  if {$value eq "true" || $value eq "1"} {
    set_property value 1 $model
  } else {
    set_property value 0 $model
  }
}

# Raw true/false strings are not valid values for bit-typed HDL parameters.
set hades_bool_params {IS_SYNC CSR_EN SELFTEST_EN}
for {set i 0} {$i < 64} {incr i} { lappend hades_bool_params "BE${i}_EN" }
foreach name $hades_bool_params {
  proc "update_MODELPARAM_VALUE.$name" \
    [list "MODELPARAM_VALUE.$name" "PARAM_VALUE.$name"] \
    [format {hades_sync_bool ${MODELPARAM_VALUE.%s} ${PARAM_VALUE.%s}} $name $name]
}
