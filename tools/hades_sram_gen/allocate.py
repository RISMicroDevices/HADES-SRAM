from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import replace

from . import contract as c
from .model import Config, ConfigError, Diagnostic, PortConfig
from .validate import backend_window_beats, lane_count

__all__ = ["apply_depths", "allocate_addresses", "depth_of"]

_DEPTH_LIMIT = (1 << c.SIZE_W) - 1
_BASE_LIMIT = 1 << c.BASE_W


def _diagnostic(code: str, path: str, message: str) -> Diagnostic:
    return Diagnostic("error", code, path, message)


def _depth_size(index: int, depth: object, port: PortConfig,
                diagnostics: list[Diagnostic]) -> int | None:
    path = f"ports[{index}].depth"
    depth_valid = True
    if isinstance(depth, bool) or not isinstance(depth, int):
        diagnostics.append(_diagnostic("E_DEPTH_TYPE", path, "Depth must be an integer frontend-word count."))
        depth_valid = False
    elif depth < 1:
        diagnostics.append(_diagnostic("E_DEPTH_RANGE", path, "Depth must be at least one frontend word."))
        depth_valid = False
    if isinstance(port.width, bool) or not isinstance(port.width, int) or not c.WIDTH_MIN <= port.width <= c.WIDTH_MAX:
        diagnostics.append(_diagnostic(
            "E_WIDTH_RANGE", f"ports[{index}].width",
            f"Port width must be an integer in {c.WIDTH_MIN}..{c.WIDTH_MAX} bits before depth sizing.",
        ))
        return None
    if not depth_valid:
        return None
    size = depth * lane_count(port.width)
    if size > _DEPTH_LIMIT:
        diagnostics.append(_diagnostic(
            "E_DEPTH_RANGE", path,
            f"Depth produces size_lanes={size}, exceeding the unsigned {c.SIZE_W}-bit limit {_DEPTH_LIMIT}.",
        ))
        return None
    return size


def depth_of(port: PortConfig) -> int:
    return port.size_lanes // lane_count(port.width)


def apply_depths(config: Config, changes: Mapping[int, int]) -> Config:
    diagnostics: list[Diagnostic] = []
    if not isinstance(changes, Mapping):
        raise ConfigError([_diagnostic("E_DEPTH_TYPE", "ports", "Depth edits must be an index-to-depth mapping.")])
    sizes: dict[int, int] = {}
    for index, depth in changes.items():
        if isinstance(index, bool) or not isinstance(index, int):
            diagnostics.append(_diagnostic("E_DEPTH_INDEX", "ports", "Depth edit indices must be zero-based integers."))
            continue
        path = f"ports[{index}].depth"
        if not 0 <= index < config.port_count or index >= len(config.ports):
            diagnostics.append(_diagnostic(
                "E_DEPTH_INDEX", path,
                f"Depth edit index must be in 0..{config.port_count - 1} for port_count={config.port_count}.",
            ))
            continue
        size = _depth_size(index, depth, config.ports[index], diagnostics)
        if size is not None:
            sizes[index] = size
    if diagnostics:
        raise ConfigError(diagnostics)
    ports = tuple(
        replace(port, size_lanes=sizes[index]) if index in sizes else port
        for index, port in enumerate(config.ports)
    )
    return replace(config, ports=ports)


def allocate_addresses(config: Config, depths: Sequence[int]) -> Config:
    diagnostics: list[Diagnostic] = []
    if isinstance(depths, (str, bytes, bytearray)) or not isinstance(depths, Sequence):
        raise ConfigError([_diagnostic("E_DEPTH_TYPE", "ports", "Automatic allocation requires a depth array.")])
    if not c.N_MIN <= config.port_count <= c.N_MAX:
        diagnostics.append(_diagnostic(
            "E_N_RANGE", "port_count",
            f"Physical port count must be in {c.N_MIN}..{c.N_MAX} for automatic allocation.",
        ))
    if len(config.ports) != config.port_count:
        diagnostics.append(_diagnostic(
            "E_PORT_LIST_LENGTH", "ports",
            "The physical port list length must equal port_count before automatic allocation.",
        ))
    if len(depths) != config.port_count:
        diagnostics.append(_diagnostic(
            "E_DEPTH_LIST_LENGTH", "ports",
            f"Expected exactly port_count={config.port_count} depths; found {len(depths)}.",
        ))

    sizes: dict[int, int] = {}
    for index in range(max(0, min(config.port_count, len(config.ports)))):
        depth = depths[index] if index < len(depths) else None
        size = _depth_size(index, depth, config.ports[index], diagnostics)
        if size is not None:
            sizes[index] = size
    for index in range(max(0, config.port_count), len(depths)):
        _depth_size(index, depths[index], PortConfig(32, False, True, 0, 0), diagnostics)
    if diagnostics:
        raise ConfigError(diagnostics)

    bases: list[int] = []
    base = 0
    for index in range(config.port_count):
        window = backend_window_beats(sizes[index])
        end = base + window
        if base >= _BASE_LIMIT or end > _BASE_LIMIT:
            diagnostics.append(_diagnostic(
                "E_AUTO_MAP_OVERFLOW", f"ports[{index}].depth",
                f"Automatic address window [{base}, {end}) exceeds the unsigned {c.BASE_W}-bit beat address space.",
            ))
        bases.append(base)
        base = end
    if diagnostics:
        raise ConfigError(diagnostics)
    ports = tuple(
        replace(port, base_beats=bases[index], size_lanes=sizes[index])
        for index, port in enumerate(config.ports)
    )
    return replace(config, ports=ports)
