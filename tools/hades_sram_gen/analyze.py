from __future__ import annotations

from decimal import Decimal, localcontext
from fractions import Fraction
from typing import Any

from . import contract as c
from .model import Config
from .validate import backend_window_beats, lane_count


def decimal_text(value: Fraction, places: int = 6) -> str:
    with localcontext() as ctx:
        ctx.prec = 50
        number = Decimal(value.numerator) / Decimal(value.denominator)
        quantum = Decimal(1).scaleb(-places)
        text = format(number.quantize(quantum), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def analyze_config(config: Config) -> dict[str, Any]:
    ratio = Fraction(c.UI_HZ, config.port_clock_hz)
    port_period_ns = Fraction(1_000_000_000, config.port_clock_hz)
    model_frequency = Fraction(c.UI_HZ, config.target_period_cycles)
    monitor_period = max(1, config.min_period_cycles - c.FREQ_MONITOR_MARGIN)
    overhead = c.CDC_OVHD_SYNC if config.clock_mode == "SYNC" else c.CDC_OVHD_ASYNC
    slot_cycles = c.SLOT_PER_PORT * config.port_count
    used = c.MAINT_SLOTS + c.FIRST_LAT + overhead + slot_cycles + c.MARGIN
    enabled = [i for i, p in enumerate(config.ports) if p.enabled]
    runtime_limit = (max(enabled) + 1) if config.configuration_mode == "CSR" and enabled else len(enabled)

    ports: list[dict[str, Any]] = []
    payload_bps = 0
    frontend_bytes_per_second = 0
    for i, port in enumerate(config.ports):
        lc = lane_count(port.width)
        used_bytes = (port.width + 7) // 8
        capacity_words = port.size_lanes // lc
        window_beats = backend_window_beats(port.size_lanes)
        if port.enabled:
            payload_bps += port.width * config.port_clock_hz
            frontend_bytes_per_second += used_bytes * config.port_clock_hz
        ports.append({
            "index": i,
            "width": port.width,
            "byte_enable": port.byte_enable,
            "enabled": port.enabled,
            "lane_count": lc,
            "used_bytes": used_bytes,
            "padding_bytes_per_lane_group": lc * c.LANE_BYTES - used_bytes,
            "base_beats": port.base_beats,
            "base_bytes": port.base_beats * c.WORD_BYTES,
            "size_lanes": port.size_lanes,
            "size_backend_bytes": port.size_lanes * c.LANE_BYTES,
            "backend_window_beats": window_beats,
            "backend_window_padding_lanes": window_beats * c.LANES_PER_BEAT - port.size_lanes,
            "backend_end_beats": port.base_beats + window_beats,
            "capacity_words": capacity_words,
            "capacity_payload_bytes": capacity_words * used_bytes,
            "size_tail_lanes": port.size_lanes % lc,
            "address_reach_words": 1 << config.address_width,
            "addressable": capacity_words <= (1 << config.address_width),
            "nominal_slot_offset_cycles": c.MAINT_SLOTS + c.FIRST_LAT + overhead + c.SLOT_PER_PORT * i,
            "payload_bandwidth_bps": port.width * config.port_clock_hz if port.enabled else 0,
            "frontend_payload_bytes_per_second": used_bytes * config.port_clock_hz if port.enabled else 0,
            "allocated_backend_bytes_per_second": c.WORD_BYTES * config.port_clock_hz if port.enabled else 0,
        })

    allocated_bps = len(enabled) * c.WORD_BYTES * config.port_clock_hz
    return {
        "schema_version": c.SCHEMA_VERSION,
        "model": "configuration-and-analytical-timing",
        "analytical_only": True,
        "post_route_timing": None,
        "target": config.target,
        "module_name": config.module_name,
        "ip_name": config.ip_name,
        "vlnv": c.VLNV,
        "clock": {
            "ui_hz": c.UI_HZ,
            "ui_period_ns": float(Fraction(1_000_000_000, c.UI_HZ)),
            "ui_period_ns_text": decimal_text(Fraction(1_000_000_000, c.UI_HZ), 9),
            "port_requested_hz": config.port_clock_hz,
            "port_period_ns": float(port_period_ns),
            "port_period_ns_text": decimal_text(port_period_ns, 6),
            "frequency_ratio": float(ratio),
            "frequency_ratio_exact": f"{ratio.numerator}:{ratio.denominator}",
            "frequency_ratio_text": f"{decimal_text(ratio, 6)}:1",
            "target_period_cycles": config.target_period_cycles,
            "cycle_model_port_hz": float(model_frequency),
            "cycle_model_port_hz_text": decimal_text(model_frequency, 6),
            "min_period_cycles": config.min_period_cycles,
            "monitor_margin_cycles": c.FREQ_MONITOR_MARGIN,
            "monitor_min_accepted_period_cycles": monitor_period,
            "monitor_max_accepted_frequency_hz": float(Fraction(c.UI_HZ, monitor_period)),
            "monitor_stop_timeout_cycles": c.STOP_TIMEOUT,
            "monitor_stop_timeout_us": float(Fraction(c.STOP_TIMEOUT * 1_000_000, c.UI_HZ)),
        },
        "timing": {
            "read_latency_cycles": config.read_latency,
            "read_latency_ns": float(config.read_latency * port_period_ns),
            "read_latency_ns_text": decimal_text(config.read_latency * port_period_ns, 6),
            "posted_writes": True,
            "pipelined_requests": True,
            "maintenance_cycles": c.MAINT_SLOTS,
            "first_data_cycles": c.FIRST_LAT,
            "cdc_overhead_cycles": overhead,
            "port_slot_cycles": slot_cycles,
            "margin_cycles": c.MARGIN,
            "budget_used_cycles": used,
            "target_period_cycles": config.target_period_cycles,
            "headroom_cycles": config.target_period_cycles - used,
            "strict_budget_passes": used < config.target_period_cycles,
            "nominal_slots": [
                {
                    "port": i,
                    "offset_cycles": c.MAINT_SLOTS + c.FIRST_LAT + overhead + c.SLOT_PER_PORT * i,
                    "offset_ns": float(Fraction((c.MAINT_SLOTS + c.FIRST_LAT + overhead + c.SLOT_PER_PORT * i) * 1_000_000_000, c.UI_HZ)),
                }
                for i in range(config.port_count)
            ],
            "note": "Slot offsets are nominal eligibility times, not guaranteed backend completion times. Exact-L describes frontend response edges, not backend latency.",
        },
        "maintenance": {
            "refresh_cycles": config.refresh_cycles,
            "refresh_interval_us": float(Fraction(config.refresh_cycles * 1_000_000, c.UI_HZ)),
            "zq_periods": config.zq_periods,
            "zq_interval_ms": float(config.zq_periods * port_period_ns / 1_000_000),
        },
        "runtime": {
            "configuration_mode": config.configuration_mode,
            "clock_mode": config.clock_mode,
            "physical_ports": config.port_count,
            "enabled_ports": len(enabled),
            "active_port_limit": runtime_limit,
            "port_enable_mask": sum((1 << i) for i in enabled),
            "selftest_enabled": config.selftest_enabled,
            "selftest_block_words": config.selftest_block_words,
        },
        "bandwidth": {
            "useful_payload_bps": payload_bps,
            "frontend_payload_bytes_per_second": frontend_bytes_per_second,
            "allocated_backend_bytes_per_second": allocated_bps,
            "backend_theoretical_bytes_per_second": c.WORD_BYTES * c.UI_HZ,
            "allocated_backend_fraction": allocated_bps / (c.WORD_BYTES * c.UI_HZ),
            "note": "Configured demand, not a full-load implementation or on-board qualification result.",
        },
        "ports": ports,
        "integration": {
            "ui_clock_requirement": "External MIG user clock must be 300 MHz.",
            "port_clock_requirement": "External shared port_clk must match the requested frequency; TARGET_PERIOD_CYCLES does not create a clock.",
            "sync_requirement": "SYNC requires same-source clocks with a static phase relationship.",
            "constraint_file": "hades_sram_clocks_sync.xdc" if config.clock_mode == "SYNC" else "doc/hades_sram_clocks_async.xdc",
            "async_action": None if config.clock_mode == "SYNC" else "Disable the packaged SYNC constraint and add the ASYNC constraint; never apply both.",
            "csr_action": "Apply csr_init.tcl through the integration's AXI4-Lite host after reset." if config.configuration_mode == "CSR" else "No CSR boot bus is required; static parameters configure the core.",
        },
    }
