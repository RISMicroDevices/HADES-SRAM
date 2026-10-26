from __future__ import annotations

import argparse
from dataclasses import replace
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen.generate import generate_artifacts
from hades_sram_gen.model import default_config, default_port, resize_ports


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate generated IP Tcl and CSR initialization in Vivado")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = (args.output_dir or ROOT / "sim" / "build" / "generator_ip").resolve()
    output.mkdir(parents=True, exist_ok=True)
    repository = ROOT / "ip" / "hades_sram_1.0"
    if not (repository / "component.xml").is_file():
        raise RuntimeError(f"Missing {repository / 'component.xml'}; run vivado -mode batch -source ip/package_ip.tcl first")

    default = replace(default_config(), target="ip", module_name="hades_sram_default_wrapper", ip_name="hades_sram_gen_default", selftest_enabled=True, selftest_block_words=16)
    mixed = resize_ports(default, 4)
    mixed = replace(
        mixed,
        module_name="hades_sram_mixed_wrapper",
        ip_name="hades_sram_gen_mixed",
        configuration_mode="STATIC",
        clock_mode="ASYNC",
        read_latency=1,
        selftest_enabled=False,
        ports=(
            replace(default_port(0), width=1),
            replace(default_port(1), width=40, byte_enable=True),
            replace(default_port(2), width=300),
            replace(default_port(3), width=512),
        ),
    )
    maximum = replace(resize_ports(default, 64), module_name="hades_sram_max64_wrapper", ip_name="hades_sram_gen_max64")
    csr = resize_ports(default_config(), 4)
    csr = replace(csr, ports=(
        replace(default_port(0), width=1, enabled=False),
        replace(default_port(1), width=40, byte_enable=True),
        replace(default_port(2), width=300, enabled=False),
        replace(default_port(3), width=512),
    ))
    for name, config in (("default", default), ("mixed", mixed), ("max64", maximum), ("csr_fake", csr)):
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        for filename, data in generate_artifacts(config).items():
            path = directory / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    vivado = Path(os.environ.get("VIVADO", "/home/kumon/Xilinx/Vivado/2024.1")) / "bin" / "vivado"
    command = [
        str(vivado), "-mode", "batch", "-source", str(ROOT / "tools" / "tests" / "vivado_generator.tcl"),
        "-tclargs", str(repository), str(output),
    ]
    log_path = output / "vivado_generator.log"
    with log_path.open("w", encoding="utf-8") as log:
        result = subprocess.run(command, cwd=output, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    text = log_path.read_text(encoding="utf-8", errors="replace")
    if result.returncode or "HADES_GENERATOR_IP_PASS" not in text:
        raise RuntimeError(f"Generated IP integration failed; see {log_path}\n" + "\n".join(text.splitlines()[-80:]))
    for marker in (
        "HADES_CSR_FAKE_PASS",
        "HADES_GENERATOR_SYNTH_PASS: default",
        "HADES_GENERATOR_SYNTH_PASS: mixed",
        "HADES_GENERATOR_XDC_PASS: default",
        "HADES_GENERATOR_XDC_PASS: mixed",
        "HADES_GENERATOR_IP_PASS",
    ):
        if marker not in text:
            raise RuntimeError(f"Missing marker {marker} in {log_path}")
    print("HADES_CSR_FAKE_PASS")
    print("default/mixed generated IP configuration, wrapper widths, and synthesis: PASS")
    print("maximum-N generated IP wrapper: PASS")
    print("HADES_GENERATOR_IP_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
