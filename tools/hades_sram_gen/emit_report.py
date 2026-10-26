from __future__ import annotations

from html import escape
from typing import Any, Iterable

from .model import Config, Diagnostic


def _si(value: float, unit: str) -> str:
    for scale, prefix in ((1e9, "G"), (1e6, "M"), (1e3, "k")):
        if abs(value) >= scale:
            return f"{value / scale:.3f} {prefix}{unit}"
    return f"{value:.3f} {unit}"


def emit_summary(config: Config, analysis: dict[str, Any]) -> str:
    clock = analysis["clock"]
    timing = analysis["timing"]
    maintenance = analysis["maintenance"]
    bandwidth = analysis["bandwidth"]
    lines = [
        "HADES-SRAM configuration and analytical timing summary",
        "======================================================",
        f"Target:              {config.target}",
        f"Module / IP:         {config.module_name} / {config.ip_name}",
        f"Catalog VLNV:        {analysis['vlnv']}",
        f"Modes:               {config.clock_mode} / {config.configuration_mode}",
        f"Physical ports:      {config.port_count}",
        f"Runtime enabled:     {analysis['runtime']['enabled_ports']}",
        f"Runtime port limit:  {analysis['runtime']['active_port_limit']}",
        "",
        "Clocks and frontend timing",
        "--------------------------",
        f"ui_clk:              {clock['ui_hz']:,} Hz ({clock['ui_period_ns_text']} ns)",
        f"Requested port_clk:  {clock['port_requested_hz']:,} Hz ({clock['port_period_ns_text']} ns)",
        f"ui:port ratio:       {clock['frequency_ratio_text']} (exact reduced ratio {clock['frequency_ratio_exact']})",
        f"Target period:       {clock['target_period_cycles']} ui_clk cycles",
        f"Cycle-model rate:    {clock['cycle_model_port_hz_text']} Hz",
        f"Minimum period:      {clock['min_period_cycles']} ui_clk cycles",
        f"Monitor tolerance:   {clock['monitor_margin_cycles']} cycles; accepts measured periods >= {clock['monitor_min_accepted_period_cycles']} cycles",
        f"Read response:       L={timing['read_latency_cycles']} port_clk cycles ({timing['read_latency_ns_text']} ns)",
        "Write behavior:      posted; requests can be accepted on consecutive port_clk edges",
        "",
        "Analytical TDMA budget",
        "----------------------",
        f"Maintenance:         {timing['maintenance_cycles']} cycles",
        f"First-data reserve:  {timing['first_data_cycles']} cycles",
        f"CDC overhead:        {timing['cdc_overhead_cycles']} cycles",
        f"Port slots:          {timing['port_slot_cycles']} cycles",
        f"Required margin:     {timing['margin_cycles']} cycles",
        f"Total used:          {timing['budget_used_cycles']} cycles",
        f"Target / headroom:   {timing['target_period_cycles']} / {timing['headroom_cycles']} cycles",
        f"Strict budget:       {'PASS' if timing['strict_budget_passes'] else 'FAIL'}",
        "Slot offsets are nominal eligibility, not guaranteed backend completion times.",
        "",
        "Maintenance and configured demand",
        "---------------------------------",
        f"Refresh interval:    {maintenance['refresh_interval_us']:.6f} us ({maintenance['refresh_cycles']} ui_clk cycles)",
        f"ZQ interval:         {maintenance['zq_interval_ms']:.6f} ms ({maintenance['zq_periods']} requested port periods)",
        f"Useful payload:      {_si(bandwidth['useful_payload_bps'], 'bit/s')}",
        f"Frontend bytes:      {_si(bandwidth['frontend_payload_bytes_per_second'], 'B/s')}",
        f"Allocated backend:   {_si(bandwidth['allocated_backend_bytes_per_second'], 'B/s')}",
        "Bandwidth is configured demand, not a full-load hardware qualification.",
        "",
        "Ports (base=64-byte beats, size=32-bit lanes)",
        "---------------------------------------------",
        "Idx  En  BE   Width  LC   Base              Size          Frontend words",
    ]
    for p in analysis["ports"]:
        lines.append(
            f"{p['index']:>3}  {'Y' if p['enabled'] else 'N':>2}  {'Y' if p['byte_enable'] else 'N':>2}  "
            f"{p['width']:>5}  {p['lane_count']:>2}   0x{p['base_beats']:012X}  {p['size_lanes']:>10}  {p['capacity_words']:>14}"
        )
    lines += [
        "",
        "Integration",
        "-----------",
        analysis["integration"]["ui_clock_requirement"],
        analysis["integration"]["port_clock_requirement"],
        analysis["integration"]["sync_requirement"],
        analysis["integration"]["csr_action"],
    ]
    if analysis["integration"]["async_action"]:
        lines.append(analysis["integration"]["async_action"])
    lines += [
        "",
        "These are configuration and analytical timing results only. They are not post-route WNS/TNS, CDC signoff, or on-board measurements.",
        "",
    ]
    return "\n".join(lines)


def emit_report(config: Config, analysis: dict[str, Any], diagnostics: Iterable[Diagnostic], graphs: dict[str, str]) -> str:
    clock = analysis["clock"]
    timing = analysis["timing"]
    diag = list(diagnostics)
    diagnostic_html = "".join(
        f'<li class="{d.severity}"><strong>{escape(d.severity.upper())} {escape(d.code)}</strong> <code>{escape(d.path)}</code>: {escape(d.message)}</li>'
        for d in diag
    ) or '<li class="pass">No validation errors or warnings.</li>'
    port_rows = "".join(
        "<tr>"
        f"<td>{p['index']}</td><td>{'yes' if p['enabled'] else 'no'}</td><td>{p['width']}</td>"
        f"<td>{'yes' if p['byte_enable'] else 'no'}</td><td>{p['lane_count']}</td><td>{p['used_bytes']}</td>"
        f"<td>0x{p['base_beats']:X}</td><td>{p['size_lanes']}</td><td>{p['capacity_words']}</td>"
        f"<td>{p['payload_bandwidth_bps']:,}</td></tr>"
        for p in analysis["ports"]
    )
    graph_sections = "".join(
        f'<section><h2>{escape(title)}</h2><div class="graph">{graphs[name]}</div></section>'
        for title, name in (
            ("Configuration overview", "overview.svg"),
            ("Frontend exact-L timing", "timing.svg"),
            ("TDMA slot budget", "slot_budget.svg"),
            ("Backend memory map", "memory_map.svg"),
            ("Configured bandwidth", "bandwidth.svg"),
        )
    )
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>HADES-SRAM configuration report — {escape(config.module_name)}</title>
<style>
body {{ background: #11161c; color: #d7dee7; font-family: 'DejaVu Sans', Arial, sans-serif; font-size: 13px; margin: 24px; }}
main {{ max-width: 1500px; margin: auto; }} h1 {{ font-size: 24px; }} h2 {{ font-size: 18px; border-bottom: 1px solid #3a4654; padding-bottom: 6px; }}
section {{ margin: 22px 0; }} .notice {{ border-left: 4px solid #d5a34f; background: #202832; padding: 12px; }}
.summary {{ display: grid; grid-template-columns: repeat(auto-fit,minmax(260px,1fr)); gap: 1px; background: #3a4654; border: 1px solid #3a4654; }}
.summary div {{ background: #202832; padding: 10px; }} .summary span {{ display: block; color: #8f9dad; font-size: 11px; }}
.value {{ font-family: 'DejaVu Sans Mono', monospace; font-size: 15px; }} table {{ border-collapse: collapse; width: 100%; font-family: 'DejaVu Sans Mono', monospace; font-size: 11px; }}
th, td {{ border: 1px solid #3a4654; padding: 5px 7px; text-align: right; }} th {{ background: #202832; position: sticky; top: 0; }} td:nth-child(-n+4) {{ text-align: left; }}
.graph {{ overflow: auto; border: 1px solid #3a4654; }} .graph svg {{ display: block; width: 100%; height: auto; min-width: 900px; }}
ul {{ list-style: none; padding: 0; }} li {{ padding: 7px; border-bottom: 1px solid #3a4654; }} li.error {{ color: #ef9a9a; }} li.warning {{ color: #e7bd72; }} li.pass {{ color: #71b88b; }}
code {{ font-family: 'DejaVu Sans Mono', monospace; }} footer {{ color: #8f9dad; border-top: 1px solid #3a4654; padding-top: 12px; }}
@media print {{ body {{ background: white; color: black; }} .notice,.summary div {{ background: #f3f3f3; }} .graph {{ overflow: visible; }} }}
</style></head><body><main>
<h1>HADES-SRAM configuration report</h1>
<p><code>{escape(config.module_name)}</code> / <code>{escape(config.ip_name)}</code> / {escape(analysis['vlnv'])}</p>
<div class="notice"><strong>Analytical model only.</strong> This report does not contain post-route WNS/TNS, CDC signoff, measured MIG latency, or on-board qualification results. Slot offsets are nominal eligibility, not guaranteed backend completion times.</div>
<section><h2>Clock and timing summary</h2><div class="summary">
<div><span>Backend clock</span><div class="value">{clock['ui_hz']:,} Hz / {clock['ui_period_ns_text']} ns</div></div>
<div><span>Requested frontend clock</span><div class="value">{clock['port_requested_hz']:,} Hz / {clock['port_period_ns_text']} ns</div></div>
<div><span>ui:port frequency ratio</span><div class="value">{clock['frequency_ratio_text']}</div></div>
<div><span>Cycle model</span><div class="value">{clock['target_period_cycles']} cycles / {clock['cycle_model_port_hz_text']} Hz</div></div>
<div><span>Read response</span><div class="value">L={timing['read_latency_cycles']} / {timing['read_latency_ns_text']} ns</div></div>
<div><span>Strict TDMA budget</span><div class="value">{timing['budget_used_cycles']} &lt; {timing['target_period_cycles']} cycles; headroom {timing['headroom_cycles']}</div></div>
</div></section>
<section><h2>Validation diagnostics</h2><ul>{diagnostic_html}</ul></section>
{graph_sections}
<section><h2>Port configuration and derived values</h2><table><thead><tr><th>Port</th><th>Enabled</th><th>W</th><th>BE</th><th>LC</th><th>Used bytes</th><th>Base beats</th><th>Size lanes</th><th>Frontend words</th><th>Payload bit/s</th></tr></thead><tbody>{port_rows}</tbody></table></section>
<footer>HADES-SRAM Generator. External clocks must match this configuration. {escape(analysis['integration']['csr_action'])} {escape(analysis['integration']['async_action'] or '')}</footer>
</main></body></html>
'''
