from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from . import __version__
from . import contract as c
from .analyze import analyze_config
from .emit_report import emit_summary
from .generate import generate_artifacts
from .model import (
    Config,
    ConfigError,
    Diagnostic,
    decode_config,
    default_port,
    dumps_config,
    load_config_data,
    port_to_dict,
)
from .output import atomic_write, generate_files
from .validate import has_errors, validate_config


def _print_diagnostics(diagnostics: tuple[Diagnostic, ...]) -> None:
    for d in diagnostics:
        print(f"{d.severity.upper()} {d.code} {d.path}: {d.message}", file=sys.stderr)


_GLOBAL_OPTIONS = (
    "schema_version", "target", "module_name", "ip_name", "port_count",
    "address_width", "clock_mode", "configuration_mode", "port_clock_hz",
    "target_period_cycles", "min_period_cycles", "read_latency",
    "selftest_enabled", "selftest_block_words", "refresh_cycles", "zq_periods",
)
_PORT_OPTIONS = (
    ("port_width", "width"),
    ("port_byte_enable", "byte_enable"),
    ("port_enabled", "enabled"),
    ("port_base_beats", "base_beats"),
    ("port_size_lanes", "size_lanes"),
)


def _usable_port_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and c.N_MIN <= value <= c.N_MAX


def _default_ports(count: int) -> list[dict[str, Any]]:
    return [port_to_dict(default_port(index)) for index in range(count)]


def _resolve_overrides(raw: Any, args: argparse.Namespace) -> Config:
    if not isinstance(raw, dict):
        result = decode_config(raw)
        raise ConfigError(result.diagnostics)

    data = dict(raw)
    for option in _GLOBAL_OPTIONS:
        value = getattr(args, option)
        if value is not None:
            data[option] = value

    count = data.get("port_count", 1)
    if args.port_count is not None and _usable_port_count(count):
        ports = data.get("ports")
        if ports is None:
            data["ports"] = _default_ports(count)
        elif isinstance(ports, list):
            resized = list(ports[:count])
            resized.extend(port_to_dict(default_port(index)) for index in range(len(resized), count))
            data["ports"] = resized

    indexed = [
        (option, field, index, value)
        for option, field in _PORT_OPTIONS
        for index, value in (getattr(args, option) or [])
    ]
    if indexed and _usable_port_count(count):
        for _, _, index, _ in indexed:
            if not 0 <= index < count:
                raise ConfigError([Diagnostic(
                    "error", "E_PORT_INDEX", f"ports[{index}]",
                    f"Port index must be in 0..{count - 1} for port_count={count}.",
                )])
        ports = data.get("ports")
        if ports is None:
            ports = _default_ports(count)
        elif isinstance(ports, list):
            ports = list(ports)
        if isinstance(ports, list):
            for _, field, index, value in indexed:
                if index < len(ports) and isinstance(ports[index], dict):
                    port = dict(ports[index])
                    port[field] = value
                    ports[index] = port
            data["ports"] = ports

    result = decode_config(data)
    if result.config is None:
        raise ConfigError(result.diagnostics)
    return result.config


def _read_config(args: argparse.Namespace) -> Config:
    raw = load_config_data(args.config) if args.config else {}
    return _resolve_overrides(raw, args)


def _command_init(args: argparse.Namespace) -> int:
    config = _read_config(args)
    diagnostics = validate_config(config)
    if has_errors(diagnostics):
        raise ConfigError(diagnostics)
    output = Path(args.output)
    if output.exists() and not args.force:
        raise ConfigError([Diagnostic("error", "E_OUTPUT_EXISTS", str(output), "Configuration exists; use --force to replace it.")])
    atomic_write(output, dumps_config(config).encode("utf-8"))
    print(f"Wrote default configuration: {output}")
    return 0


def _command_validate(args: argparse.Namespace) -> int:
    config = _read_config(args)
    diagnostics = validate_config(config)
    valid = not has_errors(diagnostics)
    if args.json:
        print(json.dumps({"valid": valid, "diagnostics": [d.to_dict() for d in diagnostics]}, indent=2))
    else:
        _print_diagnostics(diagnostics)
        warnings = sum(d.severity == "warning" for d in diagnostics)
        errors = sum(d.severity == "error" for d in diagnostics)
        print(f"{'VALID' if valid else 'INVALID'}: {errors} error(s), {warnings} warning(s)")
    return 0 if valid else 1


def _command_analyze(args: argparse.Namespace) -> int:
    config = _read_config(args)
    diagnostics = validate_config(config)
    if has_errors(diagnostics):
        if args.json:
            print(json.dumps({"valid": False, "diagnostics": [d.to_dict() for d in diagnostics], "analysis": None}, indent=2))
        else:
            _print_diagnostics(diagnostics)
        return 1
    analysis = analyze_config(config)
    if args.json:
        payload = dict(analysis)
        payload["diagnostics"] = [d.to_dict() for d in diagnostics]
        print(json.dumps(payload, indent=2))
    else:
        _print_diagnostics(diagnostics)
        print(emit_summary(config, analysis), end="")
    return 0


def _command_generate(args: argparse.Namespace) -> int:
    config = _read_config(args)
    status, problems = generate_files(
        config, Path(args.output), args.check, args.force, args.full_copy,
    )
    for problem in problems:
        print(problem, file=sys.stderr)
    if status:
        return status
    if args.check:
        print(f"GENERATOR CHECK PASS: {args.output} is up to date")
    else:
        print(emit_summary(config, analyze_config(config)), end="")
        count = len(generate_artifacts(config, args.full_copy))
        print(f"GENERATOR PASS: wrote {count} artifacts to {args.output}")
    return 0


def _indexed_integer(text: str) -> tuple[int, int]:
    index, separator, value = text.partition("=")
    if not separator or not index or not value:
        raise argparse.ArgumentTypeError("expected INDEX=VALUE, for example 0=32")
    try:
        return int(index, 10), int(value, 10)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("INDEX and VALUE must be decimal integers") from exc


def _indexed_boolean(text: str) -> tuple[int, bool]:
    index, separator, value = text.partition("=")
    if not separator or not index or value not in {"true", "false"}:
        raise argparse.ArgumentTypeError("expected INDEX=true or INDEX=false")
    try:
        return int(index, 10), value == "true"
    except ValueError as exc:
        raise argparse.ArgumentTypeError("INDEX must be a decimal integer") from exc


def _add_override_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--config", help="base JSON configuration; built-in defaults and derivation are used when omitted")
    parser.add_argument("--schema-version", type=int, metavar="VERSION", help=f"configuration schema version (supported: {c.SCHEMA_VERSION})")
    parser.add_argument("--target", metavar="TARGET", help="generation target: rtl or ip")
    parser.add_argument("--module-name", metavar="IDENTIFIER", help="generated SystemVerilog wrapper module name")
    parser.add_argument("--ip-name", metavar="IDENTIFIER", help="packaged Vivado IP instance name")
    parser.add_argument("--port-count", type=int, metavar="N", help=f"physical port count ({c.N_MIN}..{c.N_MAX})")
    parser.add_argument("--address-width", type=int, metavar="BITS", help=f"frontend address width ({c.AW_MIN}..{c.AW_MAX} bits)")
    parser.add_argument("--clock-mode", metavar="MODE", help="clock relationship: SYNC or ASYNC")
    parser.add_argument("--configuration-mode", metavar="MODE", help="configuration mode: CSR or STATIC")
    parser.add_argument("--port-clock-hz", type=int, metavar="HZ", help=f"requested port clock ({c.PORT_HZ_MIN}..{c.PORT_HZ_MAX} Hz)")
    parser.add_argument("--target-period-cycles", type=int, metavar="CYCLES", help="target period in ui_clk cycles (positive signed 32-bit)")
    parser.add_argument("--min-period-cycles", type=int, metavar="CYCLES", help="minimum accepted period in ui_clk cycles (nonzero unsigned 32-bit)")
    parser.add_argument("--read-latency", type=int, metavar="CYCLES", help="read latency in port_clk cycles (1 or 2)")
    selftest = parser.add_mutually_exclusive_group()
    selftest.add_argument("--selftest-enabled", dest="selftest_enabled", action="store_true", default=None, help="enable the built-in self-test")
    selftest.add_argument("--no-selftest-enabled", dest="selftest_enabled", action="store_false", default=None, help="disable the built-in self-test")
    parser.add_argument("--selftest-block-words", type=int, metavar="WORDS", help="self-test block size in frontend words (positive signed 32-bit)")
    parser.add_argument("--refresh-cycles", type=int, metavar="CYCLES", help="refresh interval in ui_clk cycles (nonzero unsigned 32-bit)")
    parser.add_argument("--zq-periods", type=int, metavar="PERIODS", help="ZQ calibration interval in requested port_clk periods (nonzero unsigned 32-bit)")
    parser.add_argument("--port-width", action="append", type=_indexed_integer, metavar="INDEX=BITS", help=f"set a zero-based port width ({c.WIDTH_MIN}..{c.WIDTH_MAX} bits); repeatable")
    parser.add_argument("--port-byte-enable", action="append", type=_indexed_boolean, metavar="INDEX=true|false", help="set a zero-based port byte-enable switch; repeatable")
    parser.add_argument("--port-enabled", action="append", type=_indexed_boolean, metavar="INDEX=true|false", help="set a zero-based runtime port enable; repeatable")
    parser.add_argument("--port-base-beats", action="append", type=_indexed_integer, metavar="INDEX=BEATS", help=f"set a zero-based port base address (0..{(1 << c.BASE_W) - 1} backend beats); repeatable")
    parser.add_argument("--port-size-lanes", action="append", type=_indexed_integer, metavar="INDEX=LANES", help="set a zero-based port size (unsigned 32-bit count of 32-bit lanes); repeatable")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hades-sram-gen", description="Generate validated HADES-SRAM parameters, wrappers, and analytical timing reports.")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = parser.add_subparsers(dest="command", required=True)
    shared = argparse.ArgumentParser(add_help=False)
    _add_override_arguments(shared)
    init = commands.add_parser("init", parents=[shared], help="write a JSON configuration")
    init.add_argument("--output", required=True)
    init.add_argument("--force", action="store_true")
    init.set_defaults(handler=_command_init)
    validate = commands.add_parser("validate", parents=[shared], help="validate a JSON configuration")
    validate.add_argument("--json", action="store_true")
    validate.set_defaults(handler=_command_validate)
    analyze = commands.add_parser("analyze", parents=[shared], help="display frequency, timing, capacity, and bandwidth analysis")
    analyze.add_argument("--json", action="store_true")
    analyze.set_defaults(handler=_command_analyze)
    generate = commands.add_parser("generate", parents=[shared], help="generate parameters, wrapper, Tcl, and reports")
    generate.add_argument("--output", required=True)
    generate.add_argument("--check", action="store_true", help="compare managed artifacts without writing")
    generate.add_argument("--force", action="store_true", help="atomically replace managed artifacts")
    copy_mode = generate.add_mutually_exclusive_group()
    copy_mode.add_argument("--full-copy", dest="full_copy", action="store_true", default=True, help="copy all integration RTL, constraints, and reference documents (default)")
    copy_mode.add_argument("--no-full-copy", dest="full_copy", action="store_false", help="generate configuration-specific artifacts without copied integration sources")
    generate.set_defaults(handler=_command_generate)
    gui = commands.add_parser("gui", help="launch the native HADES-Wizard application")
    gui.add_argument("--config", help="configuration to open in the native wizard")
    gui.add_argument("--output", help="initial native-wizard generation directory")
    gui.set_defaults(handler=_command_gui)
    protocol = commands.add_parser("protocol", help="serve the native stdin/stdout NDJSON protocol")
    protocol.set_defaults(handler=_command_protocol)
    return parser


def _command_gui(args: argparse.Namespace) -> int:
    from .native_gui import run_gui

    return run_gui(args.config, args.output)


def _command_protocol(args: argparse.Namespace) -> int:
    from .protocol import run_protocol

    return run_protocol()


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except ConfigError as exc:
        _print_diagnostics(exc.diagnostics)
        return 1
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except OSError as exc:
        print(f"ERROR E_IO: {exc}", file=sys.stderr)
        return 1
