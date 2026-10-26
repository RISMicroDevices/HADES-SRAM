from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from . import contract as c
from .model import Config
from .parameters import expanded_ports, flat_vectors, hex_literal, port_enable_mask


@dataclass(frozen=True)
class ExternalPort:
    name: str
    direction: str
    width: int | str
    description: str


def _declarations(*rows: tuple[str, str, int | str, str]) -> tuple[ExternalPort, ...]:
    return tuple(ExternalPort(*row) for row in rows)


AXI_PORTS = _declarations(
    ("m_axi_awid", "out", 4, "AXI4 write-address transaction identifier."),
    ("m_axi_awaddr", "out", 40, "AXI4 write-address byte address."),
    ("m_axi_awlen", "out", 8, "AXI4 write burst length, encoded as transfers minus one."),
    ("m_axi_awsize", "out", 3, "AXI4 write burst transfer size."),
    ("m_axi_awburst", "out", 2, "AXI4 write burst type."),
    ("m_axi_awvalid", "out", 1, "AXI4 write-address valid."),
    ("m_axi_awready", "in", 1, "AXI4 write-address ready."),
    ("m_axi_wdata", "out", 512, "AXI4 write data."),
    ("m_axi_wstrb", "out", 64, "AXI4 write-byte strobes."),
    ("m_axi_wlast", "out", 1, "AXI4 final write-data transfer indication."),
    ("m_axi_wvalid", "out", 1, "AXI4 write-data valid."),
    ("m_axi_wready", "in", 1, "AXI4 write-data ready."),
    ("m_axi_bid", "in", 4, "AXI4 write-response transaction identifier."),
    ("m_axi_bresp", "in", 2, "AXI4 write-response status."),
    ("m_axi_bvalid", "in", 1, "AXI4 write-response valid."),
    ("m_axi_bready", "out", 1, "AXI4 write-response ready."),
    ("m_axi_arid", "out", 4, "AXI4 read-address transaction identifier."),
    ("m_axi_araddr", "out", 40, "AXI4 read-address byte address."),
    ("m_axi_arlen", "out", 8, "AXI4 read burst length, encoded as transfers minus one."),
    ("m_axi_arsize", "out", 3, "AXI4 read burst transfer size."),
    ("m_axi_arburst", "out", 2, "AXI4 read burst type."),
    ("m_axi_arvalid", "out", 1, "AXI4 read-address valid."),
    ("m_axi_arready", "in", 1, "AXI4 read-address ready."),
    ("m_axi_rid", "in", 4, "AXI4 read-data transaction identifier."),
    ("m_axi_rdata", "in", 512, "AXI4 read data."),
    ("m_axi_rresp", "in", 2, "AXI4 read-response status."),
    ("m_axi_rlast", "in", 1, "AXI4 final read-data transfer indication."),
    ("m_axi_rvalid", "in", 1, "AXI4 read-data valid."),
    ("m_axi_rready", "out", 1, "AXI4 read-data ready."),
)

MAINTENANCE_PORTS = _declarations(
    ("app_ref_req", "out", 1, "MIG refresh request."),
    ("app_ref_ack", "in", 1, "MIG refresh acknowledgement."),
    ("app_zq_req", "out", 1, "MIG ZQ calibration request."),
    ("app_zq_ack", "in", 1, "MIG ZQ calibration acknowledgement."),
)

CSR_PORTS = _declarations(
    ("s_axil_awaddr", "in", 16, "AXI4-Lite CSR write-address byte address."),
    ("s_axil_awvalid", "in", 1, "AXI4-Lite CSR write-address valid."),
    ("s_axil_awready", "out", 1, "AXI4-Lite CSR write-address ready."),
    ("s_axil_wdata", "in", 32, "AXI4-Lite CSR write data."),
    ("s_axil_wstrb", "in", 4, "AXI4-Lite CSR write-byte strobes."),
    ("s_axil_wvalid", "in", 1, "AXI4-Lite CSR write-data valid."),
    ("s_axil_wready", "out", 1, "AXI4-Lite CSR write-data ready."),
    ("s_axil_bresp", "out", 2, "AXI4-Lite CSR write-response status."),
    ("s_axil_bvalid", "out", 1, "AXI4-Lite CSR write-response valid."),
    ("s_axil_bready", "in", 1, "AXI4-Lite CSR write-response ready."),
    ("s_axil_araddr", "in", 16, "AXI4-Lite CSR read-address byte address."),
    ("s_axil_arvalid", "in", 1, "AXI4-Lite CSR read-address valid."),
    ("s_axil_arready", "out", 1, "AXI4-Lite CSR read-address ready."),
    ("s_axil_rdata", "out", 32, "AXI4-Lite CSR read data."),
    ("s_axil_rresp", "out", 2, "AXI4-Lite CSR read-response status."),
    ("s_axil_rvalid", "out", 1, "AXI4-Lite CSR read-data valid."),
    ("s_axil_rready", "in", 1, "AXI4-Lite CSR read-data ready."),
)

STATIC_PORTS = _declarations(
    ("stat_calib_done", "out", 1, "Static calibration-complete status."),
    ("stat_ready", "out", 1, "Static core-ready status."),
    ("stat_refresh_active", "out", 1, "Static refresh-in-progress status."),
    ("stat_zq_active", "out", 1, "Static ZQ-calibration-in-progress status."),
    ("stat_err", "out", 8, "Static core error-status flags."),
    ("bkp_req", "in", 1, "Backdoor access request."),
    ("bkp_we", "in", 1, "Backdoor write enable; low selects a read."),
    ("bkp_port", "in", 8, "Backdoor SRAM port index."),
    ("bkp_addr", "in", 34, "Backdoor 32-bit lane offset within the selected port."),
    ("bkp_wdata", "in", 32, "Backdoor 32-bit lane write data."),
    ("bkp_rdata", "out", 32, "Backdoor 32-bit lane read data."),
    ("bkp_ack", "out", 1, "Backdoor access completion acknowledgement."),
)

COMMON_PORTS = _declarations(
    ("ui_clk", "in", 1, "300 MHz MIG user clock for backend logic."),
    ("ui_rst_n", "in", 1, "Active-low synchronous reset for the ui_clk domain."),
    ("port_clk", "in", 1, "Shared clock for all external SRAM ports."),
    ("port_rst_n", "in", 1, "Active-low synchronous reset for the port_clk domain."),
    ("calib_done", "in", 1, "MIG calibration-complete indication."),
)


def _declaration(name: str, direction: str, width: int | str) -> str:
    if isinstance(width, int):
        bounds = "" if width == 1 else f"[{width - 1}:0] "
    else:
        bounds = f"[{width}-1:0] "
    if direction == "in":
        return f"input  wire {bounds}{name}"
    return f"output logic {bounds}{name}"


def emit_config_package(config: Config) -> str:
    base, size = flat_vectors(config)
    lines = [
        "`default_nettype none",
        "package hades_sram_config_pkg;",
        f"  localparam int N = {config.port_count};",
        f"  localparam int AW = {config.address_width};",
        f"  localparam bit IS_SYNC = 1'b{1 if config.clock_mode == 'SYNC' else 0};",
        f"  localparam bit CSR_EN = 1'b{1 if config.configuration_mode == 'CSR' else 0};",
        f"  localparam bit SELFTEST_EN = 1'b{1 if config.selftest_enabled else 0};",
        f"  localparam int SELFTEST_BLK = {config.selftest_block_words};",
        f"  localparam int TARGET_PERIOD_CYCLES = {config.target_period_cycles};",
        f"  localparam logic [1:0] P_L = 2'd{config.read_latency};",
        f"  localparam logic [63:0] P_PORT_EN = {hex_literal(c.MASK_W, port_enable_mask(config))};",
        f"  localparam logic [31:0] P_MIN_PERIOD = 32'd{config.min_period_cycles};",
        f"  localparam logic [31:0] P_REFRESH_DIV = 32'd{config.refresh_cycles};",
        f"  localparam logic [31:0] P_ZQ_DIV = 32'd{config.zq_periods};",
        f"  localparam logic [{c.BASE_VECTOR_W - 1}:0] P_PORT_BASE = {hex_literal(c.BASE_VECTOR_W, base)};",
        f"  localparam logic [{c.SIZE_VECTOR_W - 1}:0] P_PORT_SIZE = {hex_literal(c.SIZE_VECTOR_W, size)};",
    ]
    for i, port in enumerate(expanded_ports(config)):
        lines.append(f"  localparam int W{i} = {port.width};")
        lines.append(f"  localparam bit BE{i}_EN = 1'b{1 if port.byte_enable else 0};")
    lines += ["endpackage", "`default_nettype wire", ""]
    return "\n".join(lines)


def _sram_ports(index: int) -> tuple[ExternalPort, ...]:
    return _declarations(
        (f"sram{index}_en", "in", 1, f"SRAM port {index} request enable."),
        (f"sram{index}_we", "in", 1, f"SRAM port {index} write enable; low selects a read."),
        (f"sram{index}_addr", "in", "AW", f"SRAM port {index} frontend word address."),
        (f"sram{index}_wdata", "in", f"W{index}", f"SRAM port {index} write data."),
        (f"sram{index}_be", "in", 64, f"SRAM port {index} byte enables; all pins remain on the boundary."),
        (f"sram{index}_rdata", "out", f"W{index}", f"SRAM port {index} read data."),
        (f"sram{index}_rvalid", "out", 1, f"SRAM port {index} read-response valid."),
    )


def _external_ports(config: Config) -> list[ExternalPort]:
    ports = list(COMMON_PORTS)
    for index in range(config.port_count):
        ports.extend(_sram_ports(index))
    ports.extend(AXI_PORTS)
    ports.extend(MAINTENANCE_PORTS)
    ports.extend(CSR_PORTS if config.configuration_mode == "CSR" else STATIC_PORTS)
    return ports


def _bounded_integer(value: Any) -> str | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    try:
        text = str(value)
    except (ValueError, OverflowError):
        return None
    return text if len(text) <= 32 else None


def _metadata_width(port: ExternalPort, config: Config) -> str | None:
    width = port.width
    if isinstance(width, int):
        return _bounded_integer(width)
    if width == "AW":
        return _bounded_integer(config.address_width)
    if width.startswith("W") and width[1:].isdigit():
        index = int(width[1:])
        if 0 <= index < len(config.ports):
            return _bounded_integer(config.ports[index].width)
    return width if 0 < len(width) <= 64 else None


def _metadata_group(
    group_id: str,
    label: str,
    clock_domain: str,
    expanded: bool,
    ports: tuple[ExternalPort, ...],
    config: Config,
) -> dict[str, Any] | None:
    signals: list[dict[str, str]] = []
    for port in ports:
        width = _metadata_width(port, config)
        if width is None:
            return None
        signals.append({
            "name": port.name,
            "direction": port.direction,
            "width": width,
            "description": port.description,
        })
    return {
        "id": group_id,
        "label": label,
        "clock_domain": clock_domain,
        "expanded": expanded,
        "signals": signals,
    }


def module_metadata(config: Config) -> dict[str, Any] | None:
    if (
        isinstance(config.port_count, bool)
        or not isinstance(config.port_count, int)
        or not c.N_MIN <= config.port_count <= c.N_MAX
        or len(config.ports) != config.port_count
        or config.configuration_mode not in {"CSR", "STATIC"}
        or not isinstance(config.module_name, str)
        or len(config.module_name) > 256
    ):
        return None
    try:
        config.module_name.encode("utf-8", errors="strict")
    except UnicodeEncodeError:
        return None
    groups: list[dict[str, Any]] = []
    common = _metadata_group(
        "clock_reset", "Clocks and resets", "ui_clk / port_clk", True,
        COMMON_PORTS, config,
    )
    if common is None:
        return None
    groups.append(common)
    for index in range(config.port_count):
        group = _metadata_group(
            f"sram{index}", f"SRAM Port {index}", "port_clk", False,
            _sram_ports(index), config,
        )
        if group is None:
            return None
        groups.append(group)
    fixed_groups = [
        ("m_axi", "AXI4 Backend (m_axi)", AXI_PORTS),
        ("maintenance", "Maintenance", MAINTENANCE_PORTS),
    ]
    if config.configuration_mode == "CSR":
        fixed_groups.append(("s_axil", "AXI4-Lite CSR (s_axil)", CSR_PORTS))
    else:
        fixed_groups.append(("static_io", "Static status and backdoor", STATIC_PORTS))
    for group_id, label, ports in fixed_groups:
        group = _metadata_group(group_id, label, "ui_clk", False, ports, config)
        if group is None:
            return None
        groups.append(group)
    return {"name": config.module_name, "groups": groups}


def _instance_connections(config: Config) -> list[str]:
    connections = [f".{port.name}({port.name})" for port in COMMON_PORTS]
    for index in range(c.N_MAX):
        if index < config.port_count:
            connections += [
                f".{port.name}({port.name})"
                for port in _sram_ports(index)
            ]
        elif config.target == "rtl":
            connections += [
                f".sram{index}_en(1'b0)", f".sram{index}_we(1'b0)",
                f".sram{index}_addr('0)", f".sram{index}_wdata('0)",
                f".sram{index}_be(64'd0)", f".sram{index}_rdata()",
                f".sram{index}_rvalid()",
            ]
    connections += [f".{port.name}({port.name})" for port in AXI_PORTS]
    connections += [f".{port.name}({port.name})" for port in MAINTENANCE_PORTS]
    if config.configuration_mode == "CSR":
        connections += [f".{port.name}({port.name})" for port in CSR_PORTS]
        connections += [f".{port.name}()" for port in STATIC_PORTS if port.direction == "out"]
        connections += [f".{port.name}('0)" for port in STATIC_PORTS if port.direction == "in"]
    else:
        connections += [f".{port.name}('0)" for port in CSR_PORTS if port.direction == "in"]
        connections += [f".{port.name}()" for port in CSR_PORTS if port.direction == "out"]
        connections += [f".{port.name}({port.name})" for port in STATIC_PORTS]
    return connections


def emit_wrapper(config: Config) -> str:
    declarations = [
        _declaration(port.name, port.direction, port.width)
        for port in _external_ports(config)
    ]
    lines = [
        "`default_nettype none",
        f"module {config.module_name}",
        "  import hades_sram_config_pkg::*;",
        "(",
        ",\n".join(f"  {item}" for item in declarations),
        ");",
        "",
    ]
    if config.target == "rtl":
        parameters = [
            "N(N)", "AW(AW)", "IS_SYNC(IS_SYNC)", "CSR_EN(CSR_EN)",
            "SELFTEST_EN(SELFTEST_EN)", "SELFTEST_BLK(SELFTEST_BLK)",
            "TARGET_PERIOD_CYCLES(TARGET_PERIOD_CYCLES)",
        ]
        if config.configuration_mode == "STATIC":
            parameters += [
                "P_L(P_L)", "P_PORT_EN(P_PORT_EN)", "P_MIN_PERIOD(P_MIN_PERIOD)",
                "P_REFRESH_DIV(P_REFRESH_DIV)", "P_ZQ_DIV(P_ZQ_DIV)",
                "P_PORT_BASE(P_PORT_BASE)", "P_PORT_SIZE(P_PORT_SIZE)",
            ]
        parameters += [f"W{i}(W{i})" for i in range(c.N_MAX)]
        parameters += [f"BE{i}_EN(BE{i}_EN)" for i in range(c.N_MAX)]
        lines += [
            "  hades_sram_top #(",
            ",\n".join(f"    .{item}" for item in parameters),
            "  ) u_hades_sram (",
        ]
    else:
        lines.append(f"  {config.ip_name} u_hades_sram (")
    connections = _instance_connections(config)
    lines += [
        ",\n".join(f"    {item}" for item in connections),
        "  );",
        "endmodule",
        "`default_nettype wire",
        "",
    ]
    return "\n".join(lines)
