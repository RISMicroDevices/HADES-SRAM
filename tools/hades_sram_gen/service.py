from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import Any, Callable

from . import __version__
from . import contract as c
from .allocate import allocate_addresses, apply_depths, depth_of
from .analyze import analyze_config
from .emit_sv import module_metadata
from .generate import generate_artifacts
from .model import (
    Config,
    ConfigError,
    Diagnostic,
    config_to_dict,
    decode_config,
    default_config,
    dumps_config,
    loads_config_data,
    resize_ports,
)
from .output import atomic_write, generate_files
from .validate import IDENTIFIER_PATTERN, has_errors, validate_config

__all__ = [
    "generator_schema", "analyze_data", "analyze_text", "derive_periods",
    "resize", "apply_depth_edits", "allocate", "preview", "save_config",
    "generate",
]


def _diagnostics(diagnostics: tuple[Diagnostic, ...] | list[Diagnostic]) -> list[dict[str, str]]:
    return [item.to_dict() for item in diagnostics]


def _error(code: str, path: str, message: str) -> Diagnostic:
    return Diagnostic("error", code, path, message)


def _analysis_response(config: Config, diagnostics: tuple[Diagnostic, ...] | None = None) -> dict[str, Any]:
    diagnostics = validate_config(config) if diagnostics is None else diagnostics
    valid = not has_errors(diagnostics)
    depths = [
        depth_of(port)
        if isinstance(port.width, int) and not isinstance(port.width, bool)
        and c.WIDTH_MIN <= port.width <= c.WIDTH_MAX
        else None
        for port in config.ports
    ]
    return {
        "config": config_to_dict(config),
        "valid": valid,
        "diagnostics": _diagnostics(diagnostics),
        "analysis": analyze_config(config) if valid else None,
        "depths": depths,
        "module": module_metadata(config),
    }


def _failure(
    diagnostics: tuple[Diagnostic, ...] | list[Diagnostic],
    config: Config | None = None,
) -> dict[str, Any]:
    return {
        "config": None,
        "valid": False,
        "diagnostics": _diagnostics(diagnostics),
        "analysis": None,
        "depths": None,
        "module": module_metadata(config) if config is not None else None,
    }


def _decode_response(data: Any) -> dict[str, Any]:
    result = decode_config(data)
    if result.config is None:
        return _failure(result.diagnostics)
    return _analysis_response(result.config)


def _transform(data: Any, operation: Callable[[Config], Config]) -> dict[str, Any]:
    result = decode_config(data)
    if result.config is None:
        return _failure(result.diagnostics)
    try:
        transformed = operation(result.config)
    except ConfigError as exc:
        return _failure(exc.diagnostics, result.config)
    return _analysis_response(transformed)


def _integer(minimum: int, maximum: int, unit: str | None = None, **extra: Any) -> dict[str, Any]:
    result: dict[str, Any] = {"type": "integer", "min": minimum, "max": maximum}
    if unit is not None:
        result["unit"] = unit
    result.update(extra)
    return result


def generator_schema() -> dict[str, Any]:
    identifier = {
        "type": "string",
        "pattern": IDENTIFIER_PATTERN,
        "reserved_words": sorted(c.SV_RESERVED),
    }
    globals_metadata = {
        "schema_version": _integer(c.SCHEMA_VERSION, c.SCHEMA_VERSION),
        "target": {"type": "string", "choices": ["rtl", "ip"]},
        "module_name": identifier,
        "ip_name": identifier,
        "port_count": _integer(c.N_MIN, c.N_MAX, "physical ports"),
        "address_width": _integer(c.AW_MIN, c.AW_MAX, "bits"),
        "clock_mode": {"type": "string", "choices": ["SYNC", "ASYNC"]},
        "configuration_mode": {"type": "string", "choices": ["CSR", "STATIC"]},
        "port_clock_hz": _integer(c.PORT_HZ_MIN, c.PORT_HZ_MAX, "Hz"),
        "target_period_cycles": _integer(1, 0x7FFF_FFFF, "ui_clk cycles", derived_when_omitted=True),
        "min_period_cycles": _integer(1, 0xFFFF_FFFF, "ui_clk cycles", derived_when_omitted=True),
        "read_latency": {"type": "integer", "choices": [1, 2], "unit": "port_clk cycles"},
        "selftest_enabled": {"type": "boolean"},
        "selftest_block_words": _integer(1, 0x7FFF_FFFF, "frontend words"),
        "refresh_cycles": _integer(1, 0xFFFF_FFFF, "ui_clk cycles"),
        "zq_periods": _integer(1, 0xFFFF_FFFF, "port_clk periods"),
        "ports": {"type": "array", "items": "port", "min_items": c.N_MIN, "max_items": c.N_MAX},
    }
    ports_metadata = {
        "width": _integer(c.WIDTH_MIN, c.WIDTH_MAX, "bits"),
        "byte_enable": {"type": "boolean"},
        "enabled": {"type": "boolean"},
        "base_beats": _integer(0, (1 << c.BASE_W) - 1, "64-byte beats", bits=c.BASE_W),
        "size_lanes": _integer(0, 0xFFFF_FFFF, "32-bit lanes", bits=c.SIZE_W),
    }
    return {
        "name": c.GENERATOR_NAME,
        "version": __version__,
        "protocol_version": 1,
        "schema_version": c.SCHEMA_VERSION,
        "vlnv": c.VLNV,
        "defaults": config_to_dict(default_config()),
        "fields": {"global": globals_metadata, "port": ports_metadata},
        "ui_hz": c.UI_HZ,
        "lane_bytes": c.LANE_BYTES,
        "beat_bytes": c.WORD_BYTES,
        "lanes_per_beat": c.LANES_PER_BEAT,
        "base_bits": c.BASE_W,
        "size_bits": c.SIZE_W,
        "capabilities": {
            "depth_capacity": True,
            "automatic_addressing": True,
            "manual_addressing": True,
            "artifact_preview": True,
            "atomic_save": True,
            "managed_generation": True,
        },
    }


def analyze_data(data: Any) -> dict[str, Any]:
    return _decode_response(data)


def analyze_text(text: str) -> dict[str, Any]:
    if not isinstance(text, str):
        return _failure([_error("E_TYPE_STRING", "$", "Configuration text must be a string.")])
    try:
        data = loads_config_data(text)
    except ConfigError as exc:
        return _failure(exc.diagnostics)
    return analyze_data(data)


def derive_periods(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        return analyze_data(data)
    derived = dict(data)
    derived.pop("target_period_cycles", None)
    derived.pop("min_period_cycles", None)
    return analyze_data(derived)


def resize(data: Any, count: int) -> dict[str, Any]:
    result = decode_config(data)
    if result.config is None:
        return _failure(result.diagnostics)
    if isinstance(count, bool) or not isinstance(count, int):
        return _failure(
            [_error("E_TYPE_INTEGER", "port_count", "Expected an integer port count.")],
            result.config,
        )
    if not c.N_MIN <= count <= c.N_MAX:
        return _failure([_error(
            "E_N_RANGE", "port_count",
            f"Physical port count must be in {c.N_MIN}..{c.N_MAX}.",
        )], result.config)
    return _analysis_response(resize_ports(result.config, count))


def apply_depth_edits(data: Any, changes: Any) -> dict[str, Any]:
    decoded = decode_config(data)
    if not isinstance(changes, Mapping):
        return _failure(
            [_error("E_DEPTH_TYPE", "ports", "Depth edits must be an object with string indices.")],
            decoded.config,
        )
    converted: dict[int, Any] = {}
    diagnostics: list[Diagnostic] = []
    for key, depth in changes.items():
        if not isinstance(key, str):
            diagnostics.append(_error("E_DEPTH_INDEX", "ports", "Depth edit indices must be strings containing zero-based integers."))
            continue
        try:
            index = int(key, 10)
        except ValueError:
            diagnostics.append(_error("E_DEPTH_INDEX", "ports", f"Invalid depth edit index {key!r}."))
            continue
        if str(index) != key or index in converted:
            diagnostics.append(_error("E_DEPTH_INDEX", "ports", f"Invalid or duplicate depth edit index {key!r}."))
            continue
        converted[index] = depth
    if diagnostics:
        return _failure(diagnostics, decoded.config)
    return _transform(data, lambda config: apply_depths(config, converted))


def allocate(data: Any, depths: Any) -> dict[str, Any]:
    return _transform(data, lambda config: allocate_addresses(config, depths))


def preview(data: Any, full_copy: bool = True) -> dict[str, Any]:
    decoded = decode_config(data)
    if decoded.config is None:
        response = _failure(decoded.diagnostics)
        response["artifacts"] = None
        return response
    config = decoded.config
    response = _analysis_response(config)
    response["artifacts"] = None
    if not response["valid"]:
        return response
    try:
        artifacts = generate_artifacts(config, full_copy)
        text: dict[str, str] = {}
        for name, data in artifacts.items():
            try:
                text[name] = data.decode("utf-8", errors="strict")
            except UnicodeDecodeError as exc:
                raise ConfigError([_error(
                    "E_ARTIFACT_ENCODING", name,
                    "Generated artifact is not valid UTF-8 and cannot be previewed.",
                )]) from exc
    except ConfigError as exc:
        response["valid"] = False
        response["diagnostics"] = [
            *response["diagnostics"], *_diagnostics(exc.diagnostics),
        ]
        response["analysis"] = None
        return response
    response["artifacts"] = text
    return response


def save_config(data: Any, path: str | Path, force: bool = False) -> dict[str, Any]:
    destination = Path(path)
    result = decode_config(data)
    diagnostics = list(result.diagnostics)
    config = result.config
    saved = False
    if config is not None:
        diagnostics.extend(validate_config(config))
    if config is not None and not has_errors(diagnostics):
        try:
            if destination.exists() and not force:
                raise ConfigError([_error(
                    "E_OUTPUT_EXISTS", str(destination),
                    "Configuration exists; use force to replace it.",
                )])
            atomic_write(destination, dumps_config(config).encode("utf-8"))
            saved = True
        except ConfigError as exc:
            diagnostics.extend(exc.diagnostics)
        except OSError as exc:
            diagnostics.append(_error("E_IO", str(destination), str(exc)))
    return {
        "path": str(destination),
        "config": config_to_dict(config) if config is not None else None,
        "valid": not has_errors(diagnostics),
        "diagnostics": _diagnostics(diagnostics),
        "saved": saved,
    }


def generate(data: Any, output: str | Path, check: bool = False,
             force: bool = False, full_copy: bool = True) -> dict[str, Any]:
    destination = Path(output)
    result = decode_config(data)
    diagnostics = list(result.diagnostics)
    config = result.config
    status = 1
    problems: list[str] = []
    if config is not None:
        diagnostics.extend(validate_config(config))
    if config is not None and not has_errors(diagnostics):
        try:
            status, problems = generate_files(
                config, destination, check, force, full_copy,
            )
        except ConfigError as exc:
            diagnostics.extend(exc.diagnostics)
        except OSError as exc:
            diagnostics.append(_error("E_IO", str(destination), str(exc)))
    generated = status == 0 and not check
    checked = status == 0 and check
    return {
        "output": str(destination),
        "config": config_to_dict(config) if config is not None else None,
        "valid": not has_errors(diagnostics),
        "diagnostics": _diagnostics(diagnostics),
        "status": status,
        "problems": problems,
        "generated": generated,
        "checked": checked,
        "outcome": "generated" if generated else "checked" if checked else "error",
    }
