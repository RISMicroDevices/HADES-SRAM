from __future__ import annotations

from dataclasses import replace

from . import contract as c
from .model import Config, PortConfig, default_port


def expanded_ports(config: Config) -> tuple[PortConfig, ...]:
    return tuple(
        config.ports[i] if i < config.port_count else replace(default_port(i), enabled=False)
        for i in range(c.N_MAX)
    )


def port_enable_mask(config: Config) -> int:
    return sum((1 << i) for i, port in enumerate(config.ports) if port.enabled)


def runtime_active_limit(config: Config) -> int:
    enabled = [i for i, port in enumerate(config.ports) if port.enabled]
    if config.configuration_mode == "STATIC":
        return len(enabled)
    return max(enabled) + 1 if enabled else 0


def flat_vectors(config: Config) -> tuple[int, int]:
    base = 0
    size = 0
    for i, port in enumerate(expanded_ports(config)):
        base |= port.base_beats << (i * c.BASE_W)
        size |= port.size_lanes << (i * c.SIZE_W)
    return base, size


def hex_literal(width: int, value: int) -> str:
    return f"{width}'h{value:0{width // 4}X}"


def vivado_hex(width: int, value: int) -> str:
    return f"0x{value:0{width // 4}X}"
