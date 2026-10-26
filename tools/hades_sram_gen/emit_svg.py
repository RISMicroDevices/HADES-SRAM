from __future__ import annotations

from html import escape
from math import ceil
from typing import Any

from . import contract as c
from .model import Config


BG = "#151a20"
PANEL = "#202832"
GRID = "#3a4654"
TEXT = "#d7dee7"
MUTED = "#8f9dad"
BLUE = "#63a9d8"
CYAN = "#59c2c9"
AMBER = "#d5a34f"
GREEN = "#71b88b"
RED = "#d66b6b"


def _number(value: float) -> str:
    if value == 0:
        return "0"
    for scale, suffix in ((1e9, "G"), (1e6, "M"), (1e3, "k")):
        if abs(value) >= scale:
            return f"{value / scale:.3f} {suffix}".replace(".000 ", " ")
    return f"{value:.3f}".rstrip("0").rstrip(".")


def _start(title: str, width: int, height: int, **data: Any) -> list[str]:
    attrs = " ".join(f'data-{key.replace("_", "-")}="{escape(str(value))}"' for key, value in data.items())
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}" {attrs}>',
        "<style>",
        "text { font-family: 'DejaVu Sans', Arial, sans-serif; font-size: 12px; fill: #d7dee7; }",
        ".mono { font-family: 'DejaVu Sans Mono', monospace; font-size: 11px; }",
        ".title { font-size: 18px; font-weight: 600; }",
        ".subtitle { font-size: 12px; fill: #8f9dad; }",
        ".small { font-size: 10px; }",
        "</style>",
        f'<rect width="{width}" height="{height}" fill="{BG}"/>',
        f'<text x="24" y="30" class="title">{escape(title)}</text>',
        f'<text x="24" y="50" class="subtitle">Analytical configuration model — not post-route timing or on-board measurement</text>',
    ]


def _finish(lines: list[str]) -> str:
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def _text(lines: list[str], x: float, y: float, value: str, cls: str = "", anchor: str = "start", fill: str | None = None) -> None:
    attrs = f' class="{cls}"' if cls else ""
    if fill:
        attrs += f' fill="{fill}"'
    lines.append(f'<text x="{x:.2f}" y="{y:.2f}" text-anchor="{anchor}"{attrs}>{escape(value)}</text>')


def _line(lines: list[str], x1: float, y1: float, x2: float, y2: float, color: str = GRID, width: float = 1, dash: str = "") -> None:
    extra = f' stroke-dasharray="{dash}"' if dash else ""
    lines.append(f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" stroke="{color}" stroke-width="{width}"{extra}/>')


def _rect(lines: list[str], x: float, y: float, width: float, height: float, fill: str, stroke: str = GRID) -> None:
    lines.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{max(0, width):.2f}" height="{height:.2f}" fill="{fill}" stroke="{stroke}" stroke-width="1"/>')


def emit_overview(config: Config, analysis: dict[str, Any]) -> str:
    rows = ceil(config.port_count / 3)
    height = max(590, 310 + rows * 44)
    lines = _start("HADES-SRAM configuration overview", 1280, height, graph="overview")
    _rect(lines, 24, 76, 650, height - 104, "#18232b", "#386b80")
    _rect(lines, 696, 76, 560, height - 104, "#211f27", "#695477")
    _text(lines, 38, 102, f"port_clk domain — {config.port_clock_hz:,} Hz", fill=CYAN)
    _text(lines, 710, 102, "ui_clk domain — 300,000,000 Hz", fill=AMBER)
    _text(lines, 38, 126, f"{config.clock_mode} / {config.configuration_mode} / L={config.read_latency}", cls="mono")
    _rect(lines, 770, 160, 190, 112, "#2c3542", BLUE)
    _text(lines, 865, 184, config.module_name, "mono", "middle")
    _text(lines, 865, 207, f"N={config.port_count}  AW={config.address_width}", "mono", "middle")
    _text(lines, 865, 230, f"TARGET={config.target_period_cycles}", "mono", "middle")
    _text(lines, 865, 253, f"BUDGET={analysis['timing']['budget_used_cycles']}", "mono", "middle")
    _rect(lines, 1040, 160, 170, 112, "#302c35", AMBER)
    _text(lines, 1125, 197, "MIG DDR4", "title", "middle")
    _text(lines, 1125, 222, "AXI4 512-bit", "mono", "middle")
    _text(lines, 1125, 246, "40-bit byte address", "mono", "middle")
    _line(lines, 674, 216, 770, 216, CYAN, 2)
    _line(lines, 960, 216, 1040, 216, AMBER, 2)
    _text(lines, 722, 205, "SRAM", "small", "middle")
    _text(lines, 1000, 205, "AXI4", "small", "middle")
    for i, port in enumerate(analysis["ports"]):
        col = i % 3
        row = i // 3
        x = 42 + col * 204
        y = 154 + row * 44
        color = BLUE if port["enabled"] else "#48515c"
        _rect(lines, x, y, 186, 34, "#202c36", color)
        _text(lines, x + 8, y + 21, f"sram{i}  W={port['width']}  BE={'on' if port['byte_enable'] else 'off'}", "mono")
        if not port["enabled"]:
            _text(lines, x + 174, y + 21, "off", "small", "end", MUTED)
    _text(lines, 40, height - 30, f"Runtime enabled: {analysis['runtime']['enabled_ports']} / physical: {config.port_count}; one shared port_clk; separated interfaces", "subtitle")
    return _finish(lines)


def emit_timing(config: Config, analysis: dict[str, Any]) -> str:
    width, height = 1280, 540
    x0, plot_w = 150, 1060
    domain = 4
    lines = _start("Frontend exact-L timing", width, height,
                   graph="timing", domain_min=0, domain_max=domain,
                   domain_unit="port_clk cycles", plot_x=x0, plot_width=plot_w,
                   time_scale_ns=analysis["clock"]["port_period_ns"])
    top, bottom = 86, 452
    for tick in range(domain + 1):
        x = x0 + plot_w * tick / domain
        _line(lines, x, top, x, bottom, GRID, 1, "4 4")
        _text(lines, x, bottom + 24, str(tick), "mono", "middle")
    _text(lines, x0 + plot_w / 2, bottom + 48, "port_clk cycles from first request edge", "subtitle", "middle")
    rows = {"port_clk": 116, "sram_en": 196, "sram_we": 256, "sram_rvalid": 336, "sram_rdata": 416}
    for name, y in rows.items():
        _text(lines, 138, y + 5, name, "mono", "end")
        _line(lines, x0, y + 28, x0 + plot_w, y + 28, GRID)
    clock_points: list[str] = []
    for half in range(domain * 2 + 1):
        x = x0 + plot_w * half / (domain * 2)
        high = half % 2 == 0
        y = rows["port_clk"] if high else rows["port_clk"] + 24
        clock_points.append(f"{x:.2f},{y:.2f}")
        if half < domain * 2:
            nx = x0 + plot_w * (half + 1) / (domain * 2)
            clock_points.append(f"{nx:.2f},{y:.2f}")
    lines.append(f'<polyline points="{" ".join(clock_points)}" fill="none" stroke="{CYAN}" stroke-width="2"/>')
    for name, start, end, color in (
        ("sram_en", 0, 2, BLUE),
        ("sram_rvalid", config.read_latency, config.read_latency + 2, GREEN),
    ):
        y = rows[name]
        pts = [(x0, y + 24)]
        sx = x0 + plot_w * start / domain
        ex = x0 + plot_w * end / domain
        pts += [(sx, y + 24), (sx, y), (ex, y), (ex, y + 24), (x0 + plot_w, y + 24)]
        lines.append(f'<polyline points="{" ".join(f"{x:.2f},{yy:.2f}" for x, yy in pts)}" fill="none" stroke="{color}" stroke-width="2"/>')
    _line(lines, x0, rows["sram_we"], x0 + plot_w, rows["sram_we"], BLUE, 2)
    _text(lines, x0 + 8, rows["sram_we"] - 8, "0 = read", "small")
    for request in (0, 1):
        response = request + config.read_latency
        rx = x0 + plot_w * response / domain
        qx = x0 + plot_w * request / domain
        _line(lines, qx, 150, rx, rows["sram_rvalid"] - 10, AMBER, 1, "5 4")
        _text(lines, qx + 5, 166, f"read D{request}", "small")
        _text(lines, rx + 5, rows["sram_rvalid"] - 12, f"D{request} valid", "small", fill=GREEN)
        dx = x0 + plot_w * response / domain
        dw = plot_w / domain
        _rect(lines, dx, rows["sram_rdata"] - 12, dw, 30, "#234236", GREEN)
        _text(lines, dx + dw / 2, rows["sram_rdata"] + 8, f"D{request}", "mono", "middle")
    _text(lines, 30, 76, f"L={config.read_latency}; rvalid is asserted on the L-th subsequent port_clk edge; back-to-back reads pipeline; writes are posted", "subtitle")
    return _finish(lines)


def emit_slot_budget(config: Config, analysis: dict[str, Any]) -> str:
    t = analysis["timing"]
    width, height = 1400, 600
    x0, plot_w = 100, 1240
    target = t["target_period_cycles"]
    lines = _start("TDMA slot budget and nominal eligibility", width, height,
                   graph="slot_budget", domain_min=0, domain_max=target,
                   domain_unit="ui_clk cycles", plot_x=x0, plot_width=plot_w,
                   time_scale_ns=1e9 / c.UI_HZ)
    segments = [
        ("Maintenance", t["maintenance_cycles"], "#586b85"),
        ("First data", t["first_data_cycles"], "#806b9e"),
        ("CDC", t["cdc_overhead_cycles"], "#4b8a91"),
        (f"{config.port_count} ports × 4", t["port_slot_cycles"], BLUE),
        ("Margin", t["margin_cycles"], AMBER),
        ("Headroom", t["headroom_cycles"], GREEN),
    ]
    cursor = 0
    for label, cycles, color in segments:
        x = x0 + plot_w * cursor / target
        w = plot_w * cycles / target
        _rect(lines, x, 130, w, 70, color)
        if w > 75:
            _text(lines, x + w / 2, 158, label, "small", "middle")
            _text(lines, x + w / 2, 180, str(cycles), "mono", "middle")
        cursor += cycles
    for i, (label, cycles, color) in enumerate(segments):
        x = 100 + (i % 3) * 410
        y = 234 + (i // 3) * 32
        _rect(lines, x, y - 13, 16, 16, color)
        _text(lines, x + 24, y, f"{label}: {cycles} cycles")
    _text(lines, 100, 310, f"Used {t['budget_used_cycles']} < target {target}; strict PASS with {t['headroom_cycles']} cycle(s) beyond required margin", "title")
    y0, y1 = 360, 476
    _line(lines, x0, y0, x0 + plot_w, y0, TEXT, 2)
    slots = t["nominal_slots"]
    for item in slots:
        i = item["port"]
        offset = item["offset_cycles"]
        x = x0 + plot_w * offset / target
        lines.append(f'<g data-port="{i}"><title>Port {i}: nominal eligibility at ui_clk cycle {offset}</title>')
        _line(lines, x, y0 - 18, x, y1 - 30, BLUE, 1)
        if config.port_count <= 16 or i % 16 == 0 or i == config.port_count - 1:
            _text(lines, x + 3, y1 - 14, f"P{i}@{offset}", "small")
        lines.append("</g>")
    for tick in range(6):
        value = round(target * tick / 5)
        x = x0 + plot_w * tick / 5
        _line(lines, x, y1 - 8, x, y1, TEXT)
        _text(lines, x, y1 + 22, str(value), "mono", "middle")
    _text(lines, x0 + plot_w / 2, y1 + 48, "ui_clk cycle offset from period tick", "subtitle", "middle")
    _text(lines, 100, 344, "Nominal slot_of(i) eligibility; latched until grant. Not backend completion timestamps.", "subtitle")
    return _finish(lines)


def emit_memory_map(config: Config, analysis: dict[str, Any]) -> str:
    width = 1500
    height = 190 + config.port_count * 36
    x0, plot_w = 260, 1010
    maximum = max((p["backend_end_beats"] for p in analysis["ports"]), default=1) or 1
    lines = _start("Backend memory map and lane allocation", width, height,
                   graph="memory_map", domain_min=0, domain_max=maximum,
                   domain_unit="64-byte beats", plot_x=x0, plot_width=plot_w)
    for tick in range(6):
        value = round(maximum * tick / 5)
        x = x0 + plot_w * tick / 5
        _line(lines, x, 90, x, height - 60, GRID, 1, "3 5")
        _text(lines, x, height - 34, f"0x{value:X}", "mono", "middle")
    for p in analysis["ports"]:
        i = p["index"]
        y = 110 + i * 36
        color = BLUE if p["enabled"] else "#48515c"
        _text(lines, 246, y + 17, f"P{i}  W{p['width']}  LC{p['lane_count']}", "mono", "end")
        x = x0 + plot_w * p["base_beats"] / maximum
        w = plot_w * p["backend_window_beats"] / maximum
        _rect(lines, x, y, max(2, w), 24, color)
        lines.append(f'<title>Port {i}: base 0x{p["base_beats"]:X} beats, window 0x{p["backend_window_beats"]:X} beats</title>')
        _text(lines, 1290, y + 17, f"{p['capacity_words']:,} words", "mono")
        _text(lines, 1460, y + 17, f"{p['used_bytes']}B/{p['lane_count'] * 4}B", "mono", "end")
    _text(lines, 260, 82, "Base and window units: 64-byte beats. Sizes are configured in 32-bit lanes; capacity uses floor(size/LC).", "subtitle")
    return _finish(lines)


def emit_bandwidth(config: Config, analysis: dict[str, Any]) -> str:
    width = 1400
    height = 230 + config.port_count * 48
    x0, plot_w = 250, 800
    maximum = max((p["allocated_backend_bytes_per_second"] for p in analysis["ports"]), default=1) or 1
    lines = _start("Configured bandwidth demand", width, height,
                   graph="bandwidth", domain_min=0, domain_max=maximum,
                   domain_unit="bytes/s", plot_x=x0, plot_width=plot_w)
    b = analysis["bandwidth"]
    _text(lines, 30, 82, f"Useful payload: {_number(b['useful_payload_bps'])} bit/s; frontend stored bytes: {_number(b['frontend_payload_bytes_per_second'])} B/s; allocated backend: {_number(b['allocated_backend_bytes_per_second'])} B/s", "subtitle")
    _text(lines, 30, 104, "Each operation allocates one 64-byte backend beat regardless of width. Demand is not an on-board full-load qualification.", "subtitle")
    for p in analysis["ports"]:
        i = p["index"]
        y = 132 + i * 48
        _text(lines, 236, y + 20, f"P{i}  W{p['width']}", "mono", "end")
        payload_w = plot_w * p["frontend_payload_bytes_per_second"] / maximum
        allocated_w = plot_w * p["allocated_backend_bytes_per_second"] / maximum
        _rect(lines, x0, y, payload_w, 14, CYAN)
        _rect(lines, x0, y + 20, allocated_w, 14, BLUE)
        _text(lines, 1070, y + 12, f"payload {_number(p['frontend_payload_bytes_per_second'])} B/s", "mono")
        _text(lines, 1070, y + 32, f"allocated {_number(p['allocated_backend_bytes_per_second'])} B/s", "mono")
    _rect(lines, 250, height - 42, 16, 12, CYAN)
    _text(lines, 274, height - 31, "Frontend stored bytes/s (ceil(W/8) × port_hz)")
    _rect(lines, 700, height - 42, 16, 12, BLUE)
    _text(lines, 724, height - 31, "Allocated backend bytes/s (64 × port_hz)")
    return _finish(lines)


def emit_graphs(config: Config, analysis: dict[str, Any]) -> dict[str, str]:
    return {
        "overview.svg": emit_overview(config, analysis),
        "timing.svg": emit_timing(config, analysis),
        "slot_budget.svg": emit_slot_budget(config, analysis),
        "memory_map.svg": emit_memory_map(config, analysis),
        "bandwidth.svg": emit_bandwidth(config, analysis),
    }
