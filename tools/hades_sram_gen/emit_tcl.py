from __future__ import annotations

from . import contract as c
from .model import Config
from .parameters import flat_vectors, port_enable_mask, runtime_active_limit, vivado_hex


def emit_configure_ip(config: Config) -> str:
    base, size = flat_vectors(config)
    parameters: list[tuple[str, str]] = [
        ("N", str(config.port_count)),
        ("AW", str(config.address_width)),
        ("IS_SYNC", "true" if config.clock_mode == "SYNC" else "false"),
        ("CSR_EN", "true" if config.configuration_mode == "CSR" else "false"),
        ("SELFTEST_EN", "true" if config.selftest_enabled else "false"),
        ("SELFTEST_BLK", str(config.selftest_block_words)),
        ("TARGET_PERIOD_CYCLES", str(config.target_period_cycles)),
    ]
    if config.configuration_mode == "STATIC":
        parameters += [
            ("P_L", str(config.read_latency)),
            ("P_PORT_EN", vivado_hex(c.MASK_W, port_enable_mask(config))),
            ("P_MIN_PERIOD", str(config.min_period_cycles)),
            ("P_REFRESH_DIV", str(config.refresh_cycles)),
            ("P_ZQ_DIV", str(config.zq_periods)),
            ("P_PORT_BASE", vivado_hex(c.BASE_VECTOR_W, base)),
            ("P_PORT_SIZE", vivado_hex(c.SIZE_VECTOR_W, size)),
        ]
    for i, port in enumerate(config.ports):
        parameters.append((f"W{i}", str(port.width)))
        parameters.append((f"BE{i}_EN", "true" if port.byte_enable else "false"))
    updates = "\n".join(f'    hades_set "{name}" "{value}" $hades_ip' for name, value in parameters)
    template = r'''# Source in an open Vivado project. Optional argument: IP repository path.
proc hades_bit_value {value} {
    set v [string trim $value]
    if {[regexp {^"([01]+)"$} $v -> bits]} { return "0b$bits" }
    if {[regexp -nocase {^[0-9]+'b([01_]+)$} $v -> bits]} {
        return "0b[string map {_ {}} $bits]"
    }
    if {[regexp -nocase {^[0-9]+'h([0-9a-f_]+)$} $v -> digits]} {
        return "0x[string map {_ {}} $digits]"
    }
    return $v
}
proc hades_equal {a b} {
    set aa [hades_bit_value $a]
    set bb [hades_bit_value $b]
    if {![catch {expr {$aa == $bb}} equal] && $equal} { return true }
    return [expr {[string toupper $aa] eq [string toupper $bb]}]
}
proc hades_set {name value ip} {
    set_property "CONFIG.$name" $value $ip
    set got [get_property "CONFIG.$name" $ip]
    if {![hades_equal $got $value]} {
        error "HADES generator: CONFIG.$name readback '$got', expected '$value'"
    }
}
proc hades_sram_configure_ip {{ip_repo ""}} {
    if {[catch {current_project -quiet} project] || $project eq ""} {
        error "HADES generator: open or create a Vivado project before sourcing configure_ip.tcl"
    }
    if {$ip_repo eq "" && [info exists ::env(HADES_SRAM_IP_REPO)]} {
        set ip_repo $::env(HADES_SRAM_IP_REPO)
    }
    if {$ip_repo eq ""} {
        set candidate [file normalize [file join [file dirname [info script]] .. .. ip hades_sram_1.0]]
        if {[file isdirectory $candidate]} { set ip_repo $candidate }
    }
    if {$ip_repo eq "" || ![file isdirectory $ip_repo]} {
        error "HADES generator: pass the generated ip/hades_sram_1.0 repository as the first Tcl argument or set HADES_SRAM_IP_REPO"
    }
    set ip_repo [file normalize $ip_repo]
    set paths [get_property ip_repo_paths $project]
    if {$ip_repo ni $paths} { lappend paths $ip_repo }
    set_property ip_repo_paths $paths $project
    update_ip_catalog
    if {![llength [get_ipdefs -quiet @VLNV@]]} {
        error "HADES generator: @VLNV@ not found in $ip_repo"
    }
    if {[llength [get_ips -quiet @IP_NAME@]]} {
        error "HADES generator: IP instance @IP_NAME@ already exists; choose another ip_name or remove it explicitly"
    }
    create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1 -module_name @IP_NAME@
    set hades_ip [get_ips -quiet @IP_NAME@]
    if {![llength $hades_ip]} { error "HADES generator: failed to create @IP_NAME@" }
@UPDATES@
    generate_target all $hades_ip
    puts "HADES_GEN_IP_PASS: @IP_NAME@ (@VLNV@)"
    return $hades_ip
}
if {![info exists ::HADES_SRAM_NO_AUTO_CONFIGURE]} {
    hades_sram_configure_ip [lindex $argv 0]
}
'''
    return template.replace("@VLNV@", c.VLNV).replace("@IP_NAME@", config.ip_name).replace("@UPDATES@", updates)


def emit_csr_init(config: Config) -> str:
    mask = port_enable_mask(config)
    writes = [
        (c.CSR_CFG_LATENCY, config.read_latency),
        (c.CSR_CFG_PORTS, runtime_active_limit(config)),
        (c.CSR_PORT_EN_LO, mask & 0xFFFF_FFFF),
        (c.CSR_PORT_EN_HI, (mask >> 32) & 0xFFFF_FFFF),
        (c.CSR_CFG_MIN_PERIOD, config.min_period_cycles),
        (c.CSR_CFG_REFRESH_DIV, config.refresh_cycles),
        (c.CSR_CFG_ZQ_DIV, config.zq_periods),
    ]
    for i, port in enumerate(config.ports):
        writes += [
            (c.CSR_PORT_SEL, i),
            (c.CSR_PORT_BASE, port.base_beats & 0xFFFF_FFFF),
            (c.CSR_PORT_BASE_HI, (port.base_beats >> 32) & 0x3),
            (c.CSR_PORT_SIZE, port.size_lanes),
        ]
    write_lines = "\n".join(
        f"    hades_sram_write $write_cmd $base 0x{offset:04X} 0x{value & 0xFFFF_FFFF:08X}"
        for offset, value in writes
    )
    readbacks = [
        (c.CSR_CFG_LATENCY, config.read_latency),
        (c.CSR_CFG_PORTS, runtime_active_limit(config)),
        (c.CSR_PORT_EN_LO, mask & 0xFFFF_FFFF),
        (c.CSR_PORT_EN_HI, (mask >> 32) & 0xFFFF_FFFF),
        (c.CSR_CFG_MIN_PERIOD, config.min_period_cycles),
        (c.CSR_CFG_REFRESH_DIV, config.refresh_cycles),
        (c.CSR_CFG_ZQ_DIV, config.zq_periods),
    ]
    readback_lines = "\n".join(
        f"    hades_sram_expect $read_cmd $base 0x{offset:04X} 0x{value & 0xFFFF_FFFF:08X}"
        for offset, value in readbacks
    )
    port_checks: list[str] = []
    for i, port in enumerate(config.ports):
        port_checks.append(f"    hades_sram_write $write_cmd $base 0x{c.CSR_PORT_SEL:04X} {i}")
        for offset, value in (
            (c.CSR_PORT_BASE, port.base_beats & 0xFFFF_FFFF),
            (c.CSR_PORT_BASE_HI, (port.base_beats >> 32) & 0x3),
            (c.CSR_PORT_SIZE, port.size_lanes),
            (0x003C, port.width),
        ):
            port_checks.append(
                f"    hades_sram_expect $read_cmd $base 0x{offset:04X} 0x{value & 0xFFFF_FFFF:08X}"
            )
    checks = "\n".join(port_checks)
    template = r'''# Bus-independent CSR initialization. Sourcing only defines the procedures.
# Example after sourcing the VCU1525 host common script and opening JTAG:
#   hades_sram_init mwr mrd 0 3000
proc hades_sram_read {read_cmd base offset} {
    return [{*}$read_cmd [expr {$base + $offset}]]
}
proc hades_sram_write {write_cmd base offset value} {
    {*}$write_cmd [expr {$base + $offset}] $value
}
proc hades_sram_expect {read_cmd base offset expected} {
    set got [hades_sram_read $read_cmd $base $offset]
    if {($got & 0xFFFFFFFF) != ($expected & 0xFFFFFFFF)} {
        error [format "HADES CSR readback offset 0x%04X: got 0x%08X expected 0x%08X" $offset $got $expected]
    }
}
proc hades_sram_init {write_cmd read_cmd {base 0} {timeout_ms 3000}} {
    hades_sram_expect $read_cmd $base 0x0080 0x@CORE_ID@
    hades_sram_write $write_cmd $base 0x0000 0x00000000
    hades_sram_write $write_cmd $base 0x0050 0x0000003F
@WRITES@
@READBACKS@
@PORT_CHECKS@
    set started [clock milliseconds]
    while {true} {
        set status [hades_sram_read $read_cmd $base 0x0004]
        set measured [hades_sram_read $read_cmd $base 0x0010]
        if {($status & 0x1) && $measured != 0 && ($measured + 4) >= @MIN_PERIOD@} { break }
        if {[clock milliseconds] - $started > $timeout_ms} {
            error [format "HADES CSR calibration/frequency timeout: STATUS=0x%08X MEAS_PERIOD=%d" $status $measured]
        }
        after 10
    }
    hades_sram_write $write_cmd $base 0x0000 0x00000001
    set started [clock milliseconds]
    while {true} {
        set status [hades_sram_read $read_cmd $base 0x0004]
        if {($status & 0x3) == 0x3} { break }
        if {[clock milliseconds] - $started > $timeout_ms} {
            set errors [hades_sram_read $read_cmd $base 0x0050]
            error [format "HADES CSR READY timeout: STATUS=0x%08X ERR_STATUS=0x%08X" $status $errors]
        }
        after 10
    }
    set errors [hades_sram_read $read_cmd $base 0x0050]
    if {$errors & 0x3F} {
        error [format "HADES CSR initialization reported ERR_STATUS=0x%08X" $errors]
    }
    puts "HADES_CSR_INIT_PASS: N=@N@ L=@L@ PORT_HZ=@PORT_HZ@"
    return $status
}
'''
    return (template.replace("@CORE_ID@", f"{c.CORE_ID:08X}")
            .replace("@WRITES@", write_lines).replace("@READBACKS@", readback_lines)
            .replace("@PORT_CHECKS@", checks).replace("@MIN_PERIOD@", str(config.min_period_cycles))
            .replace("@N@", str(config.port_count)).replace("@L@", str(config.read_latency))
            .replace("@PORT_HZ@", str(config.port_clock_hz)))
