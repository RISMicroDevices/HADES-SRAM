from __future__ import annotations

import json
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from . import contract as c


@dataclass(frozen=True)
class Diagnostic:
    severity: str
    code: str
    path: str
    message: str

    def to_dict(self) -> dict[str, str]:
        return {
            "severity": self.severity,
            "code": self.code,
            "path": self.path,
            "message": self.message,
        }


@dataclass(frozen=True)
class PortConfig:
    width: int
    byte_enable: bool
    enabled: bool
    base_beats: int
    size_lanes: int


@dataclass(frozen=True)
class Config:
    schema_version: int
    target: str
    module_name: str
    ip_name: str
    port_count: int
    address_width: int
    clock_mode: str
    configuration_mode: str
    port_clock_hz: int
    target_period_cycles: int
    min_period_cycles: int
    read_latency: int
    selftest_enabled: bool
    selftest_block_words: int
    refresh_cycles: int
    zq_periods: int
    ports: tuple[PortConfig, ...]


@dataclass(frozen=True)
class DecodeResult:
    config: Config | None
    diagnostics: tuple[Diagnostic, ...]


class ConfigError(ValueError):
    def __init__(self, diagnostics: list[Diagnostic] | tuple[Diagnostic, ...]):
        self.diagnostics = tuple(diagnostics)
        super().__init__("\n".join(
            f"{d.path}: {d.message}" for d in self.diagnostics
        ))


def default_port(index: int) -> PortConfig:
    return PortConfig(
        width=32,
        byte_enable=False,
        enabled=True,
        base_beats=index * c.PORT_BASE_STRIDE,
        size_lanes=c.PORT_SIZE_DEFAULT,
    )


def default_config() -> Config:
    return Config(
        schema_version=c.SCHEMA_VERSION,
        target="rtl",
        module_name="hades_sram_user",
        ip_name="hades_sram_0",
        port_count=1,
        address_width=c.AW_DEFAULT,
        clock_mode="SYNC",
        configuration_mode="CSR",
        port_clock_hz=c.PORT_HZ_MAX,
        target_period_cycles=c.TARGET_DEFAULT,
        min_period_cycles=c.MIN_PERIOD_DEFAULT,
        read_latency=c.LATENCY_DEFAULT,
        selftest_enabled=False,
        selftest_block_words=c.SELFTEST_BLOCK_DEFAULT,
        refresh_cycles=c.REFRESH_DEFAULT,
        zq_periods=c.ZQ_DEFAULT,
        ports=(default_port(0),),
    )


def error(path: str, code: str, message: str) -> Diagnostic:
    return Diagnostic("error", code, path, message)


def port_to_dict(port: PortConfig) -> dict[str, Any]:
    return {
        "width": port.width,
        "byte_enable": port.byte_enable,
        "enabled": port.enabled,
        "base_beats": port.base_beats,
        "size_lanes": port.size_lanes,
    }


def config_to_dict(config: Config) -> dict[str, Any]:
    return {
        "schema_version": config.schema_version,
        "target": config.target,
        "module_name": config.module_name,
        "ip_name": config.ip_name,
        "port_count": config.port_count,
        "address_width": config.address_width,
        "clock_mode": config.clock_mode,
        "configuration_mode": config.configuration_mode,
        "port_clock_hz": config.port_clock_hz,
        "target_period_cycles": config.target_period_cycles,
        "min_period_cycles": config.min_period_cycles,
        "read_latency": config.read_latency,
        "selftest_enabled": config.selftest_enabled,
        "selftest_block_words": config.selftest_block_words,
        "refresh_cycles": config.refresh_cycles,
        "zq_periods": config.zq_periods,
        "ports": [port_to_dict(p) for p in config.ports],
    }


def dumps_config(config: Config) -> str:
    return json.dumps(config_to_dict(config), indent=2, ensure_ascii=False) + "\n"


def resize_ports(config: Config, count: int) -> Config:
    old = config.ports
    ports = tuple(old[i] if i < len(old) else default_port(i) for i in range(count))
    return replace(config, port_count=count, ports=ports)


class _Decoder:
    _TOP = {
        "schema_version", "target", "module_name", "ip_name", "port_count",
        "address_width", "clock_mode", "configuration_mode", "port_clock_hz",
        "target_period_cycles", "min_period_cycles", "read_latency",
        "selftest_enabled", "selftest_block_words", "refresh_cycles",
        "zq_periods", "ports",
    }
    _PORT = {"width", "byte_enable", "enabled", "base_beats", "size_lanes"}
    _CHOICES = {
        "target": {"rtl", "ip"},
        "clock_mode": {"SYNC", "ASYNC"},
        "configuration_mode": {"CSR", "STATIC"},
    }

    def __init__(self) -> None:
        self.diagnostics: list[Diagnostic] = []

    def fail(self, path: str, code: str, message: str) -> None:
        self.diagnostics.append(error(path, code, message))

    def integer(self, data: dict[str, Any], key: str, default: int,
                path: str = "") -> int:
        value = data.get(key, default)
        where = f"{path}.{key}" if path else key
        if isinstance(value, bool) or not isinstance(value, int):
            self.fail(where, "E_TYPE_INTEGER", "Expected an integer.")
            return default
        return value

    def boolean(self, data: dict[str, Any], key: str, default: bool,
                path: str = "") -> bool:
        value = data.get(key, default)
        where = f"{path}.{key}" if path else key
        if not isinstance(value, bool):
            self.fail(where, "E_TYPE_BOOLEAN", "Expected true or false.")
            return default
        return value

    def text(self, data: dict[str, Any], key: str, default: str) -> str:
        value = data.get(key, default)
        if not isinstance(value, str):
            self.fail(key, "E_TYPE_STRING", "Expected a string.")
            return default
        if key in self._CHOICES and value not in self._CHOICES[key]:
            choices = ", ".join(sorted(self._CHOICES[key]))
            self.fail(key, "E_CHOICE", f"Expected one of: {choices}.")
            return default
        return value

    def decode(self, data: Any) -> DecodeResult:
        defaults = default_config()
        if not isinstance(data, dict):
            return DecodeResult(None, (error("$", "E_TYPE_OBJECT", "Configuration must be a JSON object."),))
        for key in data:
            if key not in self._TOP:
                self.fail(key, "E_UNKNOWN_FIELD", "Unknown configuration field.")
        version = self.integer(data, "schema_version", c.SCHEMA_VERSION)
        if version != c.SCHEMA_VERSION:
            self.fail("schema_version", "E_SCHEMA_VERSION",
                      f"Only configuration schema {c.SCHEMA_VERSION} is supported.")
        count = self.integer(data, "port_count", defaults.port_count)
        raw_ports = data.get("ports")
        ports: list[PortConfig] = []
        if raw_ports is None:
            ports = [default_port(i) for i in range(max(0, min(count, c.N_MAX)))]
        elif not isinstance(raw_ports, list):
            self.fail("ports", "E_TYPE_ARRAY", "Ports must be an array.")
        else:
            for i, raw in enumerate(raw_ports):
                path = f"ports[{i}]"
                fallback = default_port(i)
                if not isinstance(raw, dict):
                    self.fail(path, "E_TYPE_OBJECT", "Port configuration must be an object.")
                    ports.append(fallback)
                    continue
                for key in raw:
                    if key not in self._PORT:
                        self.fail(f"{path}.{key}", "E_UNKNOWN_FIELD", "Unknown port field.")
                ports.append(PortConfig(
                    width=self.integer(raw, "width", fallback.width, path),
                    byte_enable=self.boolean(raw, "byte_enable", fallback.byte_enable, path),
                    enabled=self.boolean(raw, "enabled", fallback.enabled, path),
                    base_beats=self.integer(raw, "base_beats", fallback.base_beats, path),
                    size_lanes=self.integer(raw, "size_lanes", fallback.size_lanes, path),
                ))
            if count >= 0 and len(raw_ports) != count:
                self.fail("ports", "E_PORT_LIST_LENGTH",
                          f"Expected exactly port_count={count} port records; found {len(raw_ports)}.")
        port_clock_hz = self.integer(data, "port_clock_hz", defaults.port_clock_hz)
        if c.PORT_HZ_MIN <= port_clock_hz <= c.PORT_HZ_MAX:
            derived_cycles = c.UI_HZ // port_clock_hz
        else:
            derived_cycles = defaults.target_period_cycles
        config = Config(
            schema_version=version,
            target=self.text(data, "target", defaults.target),
            module_name=self.text(data, "module_name", defaults.module_name),
            ip_name=self.text(data, "ip_name", defaults.ip_name),
            port_count=count,
            address_width=self.integer(data, "address_width", defaults.address_width),
            clock_mode=self.text(data, "clock_mode", defaults.clock_mode),
            configuration_mode=self.text(data, "configuration_mode", defaults.configuration_mode),
            port_clock_hz=port_clock_hz,
            target_period_cycles=self.integer(data, "target_period_cycles", derived_cycles),
            min_period_cycles=self.integer(data, "min_period_cycles", derived_cycles),
            read_latency=self.integer(data, "read_latency", defaults.read_latency),
            selftest_enabled=self.boolean(data, "selftest_enabled", defaults.selftest_enabled),
            selftest_block_words=self.integer(data, "selftest_block_words", defaults.selftest_block_words),
            refresh_cycles=self.integer(data, "refresh_cycles", defaults.refresh_cycles),
            zq_periods=self.integer(data, "zq_periods", defaults.zq_periods),
            ports=tuple(ports),
        )
        return DecodeResult(None if self.diagnostics else config, tuple(self.diagnostics))


def decode_config(data: Any) -> DecodeResult:
    return _Decoder().decode(data)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def loads_config_data(text: str) -> Any:
    try:
        return json.loads(text, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, ValueError) as exc:
        raise ConfigError([error("$", "E_JSON", str(exc))]) from exc


def load_config_data(path: str | Path) -> Any:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise ConfigError([error(str(path), "E_READ", str(exc))]) from exc
    return loads_config_data(text)


def loads_config(text: str) -> Config:
    result = decode_config(loads_config_data(text))
    if result.config is None:
        raise ConfigError(result.diagnostics)
    return result.config


def load_config(path: str | Path) -> Config:
    result = decode_config(load_config_data(path))
    if result.config is None:
        raise ConfigError(result.diagnostics)
    return result.config
