from __future__ import annotations

import argparse
import sys
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from .model import ConfigError, Diagnostic

RTL_NAMES = (
    "hades_sram_pkg.sv", "hades_sram_cdc.sv", "hades_sram_freq_mon.sv",
    "hades_sram_selftest.sv", "hades_sram_csr.sv", "hades_sram_port.sv",
    "hades_sram_timing_shaper.sv", "hades_sram_mig_if.sv",
    "hades_sram_refresh_sched.sv", "hades_sram_arbiter.sv",
    "hades_sram_backdoor.sv", "hades_sram_top.sv",
)
CONSTRAINT_NAMES = (
    "hades_sram_clocks_sync.xdc",
    "hades_sram_clocks_async.xdc",
)


@dataclass(frozen=True)
class PayloadEntry:
    canonical: str
    destination: str
    alternatives: tuple[str, ...] = ()


@dataclass(frozen=True)
class PayloadBytes:
    entry: PayloadEntry
    data: bytes


def _rtl_entry(name: str) -> PayloadEntry:
    return PayloadEntry(f"rtl/{name}", f"logical/{name}", (f"src/{name}",))


PAYLOAD_ENTRIES = (
    *tuple(_rtl_entry(name) for name in RTL_NAMES),
    *tuple(
        PayloadEntry(
            f"constraints/{name}",
            f"constraints/{name}",
            (f"doc/{name}",),
        )
        for name in CONSTRAINT_NAMES
    ),
    PayloadEntry(
        "docs/INTEGRATION_GUIDE.md",
        "docs/INTEGRATION_GUIDE.md",
        ("INTEGRATION_GUIDE.md", "doc/INTEGRATION_GUIDE.md"),
    ),
    PayloadEntry(
        "docs/csr_regmap.md",
        "docs/csr_regmap.md",
        ("csr/csr_regmap.md", "doc/csr_regmap.md"),
    ),
)


def _default_source() -> Path:
    package_dir = Path(__file__).resolve().parent
    staged = package_dir.parent / "payload"
    if staged.is_dir():
        return staged
    return package_dir.parent.parent


def _missing(root: Path, entry: PayloadEntry) -> Diagnostic:
    searched = ", ".join(
        str(root / relative)
        for relative in (entry.canonical, *entry.alternatives)
    )
    return Diagnostic(
        "error",
        "E_PAYLOAD_MISSING",
        str(root / entry.canonical),
        f"Required integration payload input {entry.canonical!r} is missing; searched: {searched}.",
    )


def load_payload(source: str | Path | None = None) -> tuple[PayloadBytes, ...]:
    root = _default_source() if source is None else Path(source)
    loaded: list[PayloadBytes] = []
    diagnostics: list[Diagnostic] = []
    for entry in PAYLOAD_ENTRIES:
        candidates = tuple(
            root / relative
            for relative in (entry.canonical, *entry.alternatives)
        )
        path = next((candidate for candidate in candidates if candidate.is_file()), None)
        if path is None:
            diagnostics.append(_missing(root, entry))
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            diagnostics.append(Diagnostic(
                "error", "E_PAYLOAD_READ", str(path),
                f"Cannot read integration payload input: {exc}",
            ))
            continue
        loaded.append(PayloadBytes(entry, data))
    if diagnostics:
        raise ConfigError(diagnostics)
    return tuple(loaded)


def payload_artifacts(source: str | Path | None = None) -> OrderedDict[str, bytes]:
    return OrderedDict(
        (item.entry.destination, item.data)
        for item in load_payload(source)
    )


def stage_payload(destination: str | Path, source: str | Path | None = None) -> int:
    loaded = load_payload(source)
    root = Path(destination)
    try:
        for item in loaded:
            path = root / item.entry.canonical
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(item.data)
    except OSError as exc:
        raise ConfigError([Diagnostic(
            "error", "E_PAYLOAD_WRITE", str(root),
            f"Cannot stage integration payload: {exc}",
        )]) from exc
    return len(loaded)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Stage the canonical HADES-SRAM integration payload")
    subparsers = parser.add_subparsers(dest="command", required=True)
    stage = subparsers.add_parser("stage", help="copy payload inputs into a provider payload directory")
    stage.add_argument("destination")
    stage.add_argument("--source", help="source checkout, packaged IP, or canonical payload root")
    args = parser.parse_args(argv)
    try:
        if args.command == "stage":
            count = stage_payload(args.destination, args.source)
            print(f"Staged {count} HADES-SRAM payload files in {args.destination}")
            return 0
    except ConfigError as exc:
        for diagnostic in exc.diagnostics:
            print(
                f"{diagnostic.severity.upper()} {diagnostic.code} "
                f"{diagnostic.path}: {diagnostic.message}",
                file=sys.stderr,
            )
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
