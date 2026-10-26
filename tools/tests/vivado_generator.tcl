set ip_repo [file normalize [lindex $argv 0]]
set out_root [file normalize [lindex $argv 1]]
set part xcvu9p-fsgd2104-2L-e

proc require_file {path} {
    if {![file exists $path]} { error "HADES generator test: missing $path" }
}

proc check_ip_wrapper {work ip_name count widths} {
    set path [file join $work generator_verify.gen sources_1 ip $ip_name synth ${ip_name}.v]
    require_file $path
    set stream [open $path r]
    set text [read $stream]
    close $stream
    set text [regsub -all {\s+} $text " "]
    set header [string range $text 0 [string first ");" $text]]
    for {set i 0} {$i < $count} {incr i} {
        if {[llength $widths] == 1} { set width [lindex $widths 0] } else { set width [lindex $widths $i] }
        set bounds [expr {$width - 1}]
        foreach fragment [list \
            "input wire \[21 : 0\] sram${i}_addr;" \
            "input wire \[63 : 0\] sram${i}_be;" \
            "input wire \[${bounds} : 0\] sram${i}_wdata;" \
            "output wire \[${bounds} : 0\] sram${i}_rdata;"] {
            if {[string first $fragment $text] < 0} {
                error "HADES generator test: $ip_name missing declaration: $fragment"
            }
        }
    }
    if {[string first "sram${count}_" $header] >= 0} {
        error "HADES generator test: $ip_name exposes inactive sram${count} pins"
    }
    puts "HADES_GENERATOR_WRAPPER_PASS: $ip_name N=$count"
}

proc check_strict_xdc {generated count widths} {
    if {![llength [get_clocks -quiet -of_objects [get_ports ui_clk]]]} {
        create_clock -name hades_verify_ui_clk -period 3.333 [get_ports ui_clk]
    }
    if {![llength [get_clocks -quiet -of_objects [get_ports port_clk]]]} {
        create_clock -name hades_verify_port_clk -period 2000.000 [get_ports port_clk]
    }
    for {set i 0} {$i < $count} {incr i} {
        if {[llength $widths] == 1} { set width [lindex $widths 0] } else { set width [lindex $widths $i] }
        set inputs [get_ports [list \
            sram${i}_en sram${i}_we \
            "sram${i}_addr\[*]" "sram${i}_wdata\[*]" "sram${i}_be\[*]"]]
        set outputs [get_ports [list "sram${i}_rdata\[*]" sram${i}_rvalid]]
        if {[llength $inputs] != 2 + 22 + $width + 64} {
            error "HADES generator test: sram$i strict input pin count mismatch"
        }
        if {[llength $outputs] != $width + 1} {
            error "HADES generator test: sram$i strict output pin count mismatch"
        }
        source [file join $generated constraints sram${i}_strict.xdc]
        foreach delay_type {max min} {
            if {![llength [get_timing_paths -from [get_ports sram${i}_en] -delay_type $delay_type -max_paths 1 -nworst 1]]} {
                error "HADES generator test: sram$i has no $delay_type input timing path"
            }
            if {![llength [get_timing_paths -to [get_ports "sram${i}_rdata\[*]"] -delay_type $delay_type -max_paths 1 -nworst 1]]} {
                error "HADES generator test: sram$i has no $delay_type output timing path"
            }
        }
    }
}

# name module ip_name N widths synth
set cases {
    {default hades_sram_default_wrapper hades_sram_gen_default 1 {32} 1}
    {mixed hades_sram_mixed_wrapper hades_sram_gen_mixed 4 {1 40 300 512} 1}
    {max64 hades_sram_max64_wrapper hades_sram_gen_max64 64 {32} 0}
}
if {[lindex $argv 2] eq "csr_only"} { set cases {} }
foreach case $cases {
    lassign $case name module ip_name count widths synthesize
    set generated [file join $out_root $name]
    set work [file join $out_root work_$name]
    file delete -force $work
    create_project -force generator_verify $work -part $part
    source [file join $generated configure_ip.tcl]
    set ip [get_ips -quiet $ip_name]
    if {![llength $ip]} { error "HADES generator test: $ip_name was not created" }
    check_ip_wrapper $work $ip_name $count $widths
    if {$synthesize} {
        add_files -norecurse [file join $generated logical hades_sram_config_pkg.sv]
        add_files -norecurse [file join $generated logical ${module}.sv]
        set_property top $module [current_fileset]
        update_compile_order -fileset sources_1
        launch_runs synth_1 -jobs 1
        wait_on_run synth_1
        set run [get_runs synth_1]
        if {[get_property PROGRESS $run] ne "100%"} {
            error "HADES generator test: synthesis failed for $name: [get_property STATUS $run]"
        }
        require_file [file join $work generator_verify.runs ${ip_name}_synth_1 ${ip_name}.dcp]
        require_file [file join $work generator_verify.runs synth_1 ${module}.dcp]
        puts "HADES_GENERATOR_SYNTH_PASS: $name"
        open_run synth_1
        check_strict_xdc $generated $count $widths
        puts "HADES_GENERATOR_XDC_PASS: $name"
    }
    close_project
}

namespace eval hades_gen_fake {
    variable widths
    variable regs
    variable port_base
    variable port_base_hi
    variable port_size
    array set regs {}
    set regs(32) 0
    array set port_base {}
    array set port_base_hi {}
    array set port_size {}
    set writes {}
    set status 3
    set measured 600
    set errors 0
    array set widths {0 1 1 40 2 300 3 512}
}
proc fake_write {addr data} {
    set addr [expr {$addr + 0}]
    set hades_gen_fake::regs($addr) $data
    set selected [expr {$hades_gen_fake::regs(32) + 0}]
    if {$addr == 0x24} { set hades_gen_fake::port_base($selected) $data }
    if {$addr == 0x28} { set hades_gen_fake::port_base_hi($selected) $data }
    if {$addr == 0x2C} { set hades_gen_fake::port_size($selected) $data }
    lappend hades_gen_fake::writes [list $addr $data]
}
proc fake_read {addr} {
    set addr [expr {$addr + 0}]
    if {$addr == 0x80} { return 0xADE50110 }
    if {$addr == 0x04} { return $hades_gen_fake::status }
    if {$addr == 0x10} { return $hades_gen_fake::measured }
    if {$addr == 0x50} { return $hades_gen_fake::errors }
    set selected [expr {$hades_gen_fake::regs(32) + 0}]
    if {$addr == 0x24} { return $hades_gen_fake::port_base($selected) }
    if {$addr == 0x28} { return $hades_gen_fake::port_base_hi($selected) }
    if {$addr == 0x2C} { return $hades_gen_fake::port_size($selected) }
    if {$addr == 0x3C} { return $hades_gen_fake::widths($selected) }
    if {[info exists hades_gen_fake::regs($addr)]} { return $hades_gen_fake::regs($addr) }
    return 0
}

source [file join $out_root csr_fake csr_init.tcl]
if {[llength $hades_gen_fake::writes] != 0} { error "CSR source had hardware side effects" }
set status [hades_sram_init fake_write fake_read 0 30]
if {$status != 3} { error "CSR fake READY status $status" }
if {[fake_read 0x14] != 0xA || [fake_read 0x18] != 0 || [fake_read 0x0C] != 4} {
    error "CSR sparse mask/active-limit mismatch"
}
if {[fake_read 0x00] != 1} { error "CSR did not finish with ENABLE only" }
if {[lindex $hades_gen_fake::writes 0 0] != 0 || [lindex $hades_gen_fake::writes 0 1] != 0} {
    error "CSR initialization did not begin with CTRL=0"
}
set hades_gen_fake::status 1
set hades_gen_fake::measured 0
set result [catch {hades_sram_init fake_write fake_read 0 20} message]
if {!$result || ![string match "*calibration/frequency timeout*" $message]} {
    error "CSR calibration failure was not detected: $message"
}
set hades_gen_fake::measured 600
set result [catch {hades_sram_init fake_write fake_read 0 20} message]
if {!$result || ![string match "*READY timeout*" $message]} {
    error "CSR READY failure was not detected: $message"
}
puts "HADES_CSR_FAKE_PASS"
puts "HADES_GENERATOR_IP_PASS"
exit 0
