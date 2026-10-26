from __future__ import annotations

import hashlib
import json
from collections import OrderedDict
from pathlib import Path

from .analyze import analyze_config
from .emit_constraints import emit_strict_constraints
from .emit_report import emit_report, emit_summary
from .emit_sv import emit_config_package, emit_wrapper
from .emit_svg import emit_graphs
from .emit_tcl import emit_configure_ip, emit_csr_init
from .model import Config, ConfigError, Diagnostic, dumps_config
from .payload import RTL_NAMES, payload_artifacts
from .validate import has_errors, validate_config


def generate_artifacts(
    config: Config,
    full_copy: bool = True,
    *,
    payload_source: str | Path | None = None,
) -> OrderedDict[str, bytes]:
    if not isinstance(full_copy, bool):
        raise ConfigError([Diagnostic(
            "error", "E_TYPE_BOOLEAN", "full_copy", "Expected true or false.",
        )])
    diagnostics = validate_config(config)
    if has_errors(diagnostics):
        raise ConfigError(diagnostics)
    copied = payload_artifacts(payload_source) if full_copy else OrderedDict()
    analysis = analyze_config(config)
    graphs = emit_graphs(config, analysis)
    analysis_with_diagnostics = dict(analysis)
    analysis_with_diagnostics["diagnostics"] = [d.to_dict() for d in diagnostics]
    artifacts: OrderedDict[str, bytes] = OrderedDict()
    artifacts["config.json"] = dumps_config(config).encode("utf-8")
    artifacts["logical/hades_sram_config_pkg.sv"] = emit_config_package(config).encode("utf-8")
    artifacts[f"logical/{config.module_name}.sv"] = emit_wrapper(config).encode("utf-8")
    artifacts["wrapper.f"] = (
        "logical/hades_sram_config_pkg.sv\n"
        f"logical/{config.module_name}.sv\n"
    ).encode("utf-8")
    if config.target == "ip":
        artifacts["configure_ip.tcl"] = emit_configure_ip(config).encode("utf-8")
    if config.configuration_mode == "CSR":
        artifacts["csr_init.tcl"] = emit_csr_init(config).encode("utf-8")
    artifacts["report/analysis.json"] = (json.dumps(analysis_with_diagnostics, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    artifacts["report/summary.txt"] = emit_summary(config, analysis).encode("utf-8")
    artifacts["report/report.html"] = emit_report(config, analysis, diagnostics, graphs).encode("utf-8")
    for name, text in graphs.items():
        artifacts[f"report/{name}"] = text.encode("utf-8")
    for name, text in emit_strict_constraints(config).items():
        artifacts[name] = text.encode("utf-8")
    artifacts.update(copied)
    if full_copy:
        artifacts["static_rtl.f"] = (
            "".join(f"logical/{name}\n" for name in RTL_NAMES)
        ).encode("utf-8")
    manifest = {
        "schema_version": 1,
        "module_name": config.module_name,
        "target": config.target,
        "full_copy": full_copy,
        "files": [
            {"path": name, "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in artifacts.items()
        ],
    }
    artifacts["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode("utf-8")
    return artifacts
