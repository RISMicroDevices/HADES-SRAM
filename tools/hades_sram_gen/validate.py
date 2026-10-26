from __future__ import annotations

import re

from . import contract as c
from .model import Config, Diagnostic


IDENTIFIER_PATTERN = r"^[A-Za-z_][A-Za-z0-9_]*$"
_IDENTIFIER = re.compile(IDENTIFIER_PATTERN)


def _error(code: str, path: str, message: str) -> Diagnostic:
    return Diagnostic("error", code, path, message)


def _warning(code: str, path: str, message: str) -> Diagnostic:
    return Diagnostic("warning", code, path, message)


def lane_count(width: int) -> int:
    lanes = (width + 31) // 32
    return 1 << (lanes - 1).bit_length()


def backend_window_beats(size_lanes: int) -> int:
    return (size_lanes + c.LANES_PER_BEAT - 1) // c.LANES_PER_BEAT


def has_errors(diagnostics: list[Diagnostic] | tuple[Diagnostic, ...]) -> bool:
    return any(d.severity == "error" for d in diagnostics)


def _check_identifier(value: str, path: str, diagnostics: list[Diagnostic]) -> None:
    if not _IDENTIFIER.fullmatch(value) or value in c.SV_RESERVED:
        diagnostics.append(_error(
            "E_IDENTIFIER", path,
            "Use a portable SystemVerilog identifier: a letter or underscore followed by letters, digits, or underscores; reserved words are not allowed.",
        ))


def validate_config(config: Config) -> tuple[Diagnostic, ...]:
    d: list[Diagnostic] = []
    _check_identifier(config.module_name, "module_name", d)
    _check_identifier(config.ip_name, "ip_name", d)
    if config.target not in {"rtl", "ip"}:
        d.append(_error("E_TARGET", "target", "Target must be rtl or ip."))
    if config.clock_mode not in {"SYNC", "ASYNC"}:
        d.append(_error("E_CLOCK_MODE", "clock_mode", "Clock mode must be SYNC or ASYNC."))
    if config.configuration_mode not in {"CSR", "STATIC"}:
        d.append(_error("E_CONFIGURATION_MODE", "configuration_mode", "Configuration mode must be CSR or STATIC."))
    if config.schema_version != c.SCHEMA_VERSION:
        d.append(_error("E_SCHEMA_VERSION", "schema_version", f"Expected schema {c.SCHEMA_VERSION}."))
    if not c.N_MIN <= config.port_count <= c.N_MAX:
        d.append(_error("E_N_RANGE", "port_count", f"Physical port count must be in {c.N_MIN}..{c.N_MAX}."))
    if len(config.ports) != config.port_count:
        d.append(_error("E_PORT_LIST_LENGTH", "ports", "The port list length must equal port_count."))
    if not c.AW_MIN <= config.address_width <= c.AW_MAX:
        d.append(_error("E_AW_RANGE", "address_width", f"Address width must be in {c.AW_MIN}..{c.AW_MAX} bits for the 32-bit RTL legality path."))
    if config.read_latency not in {1, 2}:
        d.append(_error("E_LATENCY", "read_latency", "Read latency must be 1 or 2 port_clk cycles."))
    if not 1 <= config.selftest_block_words <= 0x7FFF_FFFF:
        d.append(_error("E_SELFTEST_BLOCK", "selftest_block_words", "Self-test block size must be a positive signed 32-bit word count."))
    for value, path, code in (
        (config.refresh_cycles, "refresh_cycles", "E_REFRESH_RANGE"),
        (config.zq_periods, "zq_periods", "E_ZQ_RANGE"),
    ):
        if not 1 <= value <= 0xFFFF_FFFF:
            d.append(_error(code, path, "A nonzero unsigned 32-bit interval is required; disabling maintenance is unsafe with this MIG configuration."))
    if config.refresh_cycles > 2340:
        d.append(_warning("W_REFRESH_INTERVAL", "refresh_cycles", "The nominal refresh interval exceeds 7.8 us at 300 MHz; confirm the MIG/DDR4 temperature-grade requirements."))

    frequency_valid = c.PORT_HZ_MIN <= config.port_clock_hz <= c.PORT_HZ_MAX
    if not frequency_valid:
        d.append(_error("E_PORT_FREQUENCY", "port_clock_hz", f"Requested port clock must be in {c.PORT_HZ_MIN}..{c.PORT_HZ_MAX} Hz."))
    target_valid = 1 <= config.target_period_cycles <= 0x7FFF_FFFF
    min_valid = 1 <= config.min_period_cycles <= 0xFFFF_FFFF
    if not target_valid:
        d.append(_error("E_TARGET_PERIOD", "target_period_cycles", "Target period must be a positive signed 32-bit ui_clk cycle count."))
    if not min_valid:
        d.append(_error("E_MIN_PERIOD", "min_period_cycles", "Minimum period must be a positive unsigned 32-bit ui_clk cycle count."))
    if frequency_valid and target_valid and min_valid:
        physical_cycles = c.UI_HZ // config.port_clock_hz
        if c.UI_HZ % config.port_clock_hz:
            d.append(_warning("W_FRACTIONAL_RATIO", "port_clock_hz", "The clock ratio is not an integer; the physical clock and integer-cycle budget model are reported separately."))
        if config.target_period_cycles > physical_cycles:
            d.append(_error("E_TARGET_OPTIMISTIC", "target_period_cycles", f"Target period {config.target_period_cycles} exceeds the physical clock period of floor({c.UI_HZ}/{config.port_clock_hz})={physical_cycles} ui_clk cycles."))
        elif config.target_period_cycles < physical_cycles:
            d.append(_warning("W_TARGET_CONSERVATIVE", "target_period_cycles", f"Target period is below the physical clock period ({physical_cycles} cycles); the analytical budget is intentionally conservative."))
        if config.min_period_cycles > physical_cycles:
            d.append(_error("E_MIN_PERIOD_CLOCK", "min_period_cycles", f"Minimum period {config.min_period_cycles} would reject the requested clock ({physical_cycles} ui_clk cycles)."))
        if config.min_period_cycles < config.target_period_cycles:
            d.append(_error("E_MIN_BELOW_TARGET", "min_period_cycles", "Minimum accepted period must be greater than or equal to the analytical target period so the monitor cannot admit a faster, unbudgeted clock."))
        if config.min_period_cycles < c.UI_HZ // c.PORT_HZ_MAX:
            d.append(_error("E_MIN_PERIOD_500K", "min_period_cycles", "Minimum period below 600 ui_clk cycles would permit a clock above the supported 500 KHz envelope."))

    if target_valid and config.clock_mode in {"SYNC", "ASYNC"} and c.N_MIN <= config.port_count <= c.N_MAX:
        overhead = c.CDC_OVHD_SYNC if config.clock_mode == "SYNC" else c.CDC_OVHD_ASYNC
        used = c.MAINT_SLOTS + c.FIRST_LAT + overhead + c.SLOT_PER_PORT * config.port_count + c.MARGIN
        if used >= config.target_period_cycles:
            d.append(_error("E_SLOT_BUDGET", "target_period_cycles", f"Strict slot budget fails: {used} cycles must be less than TARGET_PERIOD_CYCLES={config.target_period_cycles}. Reduce N or lower the port clock."))

    enabled_indices = [i for i, p in enumerate(config.ports) if p.enabled]
    if not enabled_indices:
        d.append(_warning("W_NO_RUNTIME_PORTS", "ports", "All runtime ports are disabled; the generated core will not accept frontend traffic."))
    if config.configuration_mode == "STATIC" and enabled_indices != list(range(len(enabled_indices))):
        d.append(_error("E_STATIC_MASK", "ports", "Static mode requires a contiguous enable mask starting at port 0 because active_ports=countones(P_PORT_EN) and the arbiter also checks port index < active_ports. Use CSR mode for a sparse mask."))

    for i, port in enumerate(config.ports):
        path = f"ports[{i}]"
        width_valid = c.WIDTH_MIN <= port.width <= c.WIDTH_MAX
        if not width_valid:
            d.append(_error("E_WIDTH_RANGE", f"{path}.width", f"Port width must be in {c.WIDTH_MIN}..{c.WIDTH_MAX} bits."))
        if not isinstance(port.byte_enable, bool):
            d.append(_error("E_TYPE_BOOLEAN", f"{path}.byte_enable", "Byte enable must be true or false."))
        if not isinstance(port.enabled, bool):
            d.append(_error("E_TYPE_BOOLEAN", f"{path}.enabled", "Runtime enable must be true or false."))
        if not 0 <= port.base_beats < (1 << c.BASE_W):
            d.append(_error("E_BASE_RANGE", f"{path}.base_beats", f"Base must fit the unsigned {c.BASE_W}-bit beat-address field."))
        if not 0 <= port.size_lanes <= 0xFFFF_FFFF:
            d.append(_error("E_SIZE_RANGE", f"{path}.size_lanes", "Size must fit the unsigned 32-bit lane-count field."))
            continue
        if port.size_lanes == 0:
            diagnostic = _error if port.enabled else _warning
            d.append(diagnostic("E_EMPTY_PORT" if port.enabled else "W_EMPTY_DISABLED_PORT", f"{path}.size_lanes", "An enabled port must have a nonzero size." if port.enabled else "This disabled port has no addressable storage."))
            continue
        window = backend_window_beats(port.size_lanes)
        if port.base_beats >= 0 and port.base_beats + window > (1 << c.BASE_W):
            diagnostic = _error if port.enabled else _warning
            d.append(diagnostic("E_BACKEND_OVERFLOW" if port.enabled else "W_DISABLED_BACKEND_OVERFLOW", f"{path}.base_beats", f"Base plus the {window}-beat backend window exceeds the {c.BASE_W}-bit address space."))
        if width_valid:
            lc = lane_count(port.width)
            capacity = port.size_lanes // lc
            if port.size_lanes % lc:
                d.append(_warning("W_SIZE_TAIL", f"{path}.size_lanes", f"Size is not divisible by LC={lc}; frontend capacity is floor(size/LC)={capacity} words and the tail is not a complete frontend word."))
            if capacity > (1 << config.address_width):
                diagnostic = _error if port.enabled else _warning
                d.append(diagnostic("E_AW_REACH" if port.enabled else "W_DISABLED_AW_REACH", f"{path}.size_lanes", f"Capacity {capacity} words exceeds the {1 << config.address_width}-word address reach of AW={config.address_width}."))
            if config.selftest_enabled and port.width not in {32, 64}:
                d.append(_error("E_SELFTEST_WIDTH", f"{path}.width", "The current self-test pattern generator supports only 32- or 64-bit physical ports. Disable self-test or select a supported width."))
            if config.selftest_enabled and port.enabled and config.selftest_block_words > capacity:
                d.append(_error("E_SELFTEST_CAPACITY", "selftest_block_words", f"Self-test block {config.selftest_block_words} exceeds port {i} capacity {capacity} words."))

    for i, left in enumerate(config.ports):
        if left.size_lanes <= 0 or left.base_beats < 0:
            continue
        left_end = left.base_beats + backend_window_beats(left.size_lanes)
        for j in range(i + 1, len(config.ports)):
            right = config.ports[j]
            if right.size_lanes <= 0 or right.base_beats < 0:
                continue
            right_end = right.base_beats + backend_window_beats(right.size_lanes)
            if left.base_beats < right_end and right.base_beats < left_end:
                enabled_overlap = left.enabled or right.enabled
                diagnostic = _error if enabled_overlap else _warning
                d.append(diagnostic("E_ADDRESS_OVERLAP" if enabled_overlap else "W_DISABLED_ADDRESS_OVERLAP", f"ports[{j}].base_beats", f"Backend window overlaps port {i}; beat windows [{left.base_beats}, {left_end}) and [{right.base_beats}, {right_end}) intersect."))
    return tuple(d)
