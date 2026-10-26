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
from hades_sram_gen.model import Config, default_config, default_port, resize_ports


def filelist_sources(root: Path, name: str) -> list[Path]:
    sources: list[Path] = []
    for line in (root / name).read_text(encoding="utf-8").splitlines():
        relative = Path(line)
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"Unsafe path in generated {name}: {line}")
        source = (root / relative).resolve()
        source.relative_to(root)
        if not source.is_file():
            raise RuntimeError(f"Missing source from generated {name}: {source}")
        sources.append(source)
    return sources


def configurations() -> dict[str, tuple[Config, bool]]:
    mixed = resize_ports(default_config(), 4)
    mixed = replace(
        mixed,
        configuration_mode="STATIC",
        clock_mode="ASYNC",
        port_clock_hz=100_000,
        target_period_cycles=3000,
        min_period_cycles=3000,
        read_latency=1,
        ports=(
            replace(default_port(0), width=1),
            replace(default_port(1), width=13, byte_enable=True),
            replace(default_port(2), width=300),
            replace(default_port(3), width=512),
        ),
    )
    smoke = replace(
        default_config(),
        configuration_mode="STATIC",
        clock_mode="ASYNC",
        read_latency=1,
        ports=(replace(default_port(0), width=40, byte_enable=True),),
    )
    return {
        "default_csr": (default_config(), False),
        "mixed_static": (mixed, False),
        "smoke_w40_be": (smoke, True),
    }


def run_command(command: list[str], cwd: Path, log_name: str, timeout: int = 240) -> None:
    with (cwd / log_name).open("w", encoding="utf-8") as log:
        result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        lines = (cwd / log_name).read_text(encoding="utf-8", errors="replace").splitlines()
        raise RuntimeError(f"Command failed ({result.returncode}) in {cwd}: {' '.join(command)}\n" + "\n".join(lines[-50:]))


def main() -> int:
    parser = argparse.ArgumentParser(description="Compile and smoke-test real HADES-SRAM generator output")
    parser.add_argument("--sim", choices=("vcs", "xsim"), default="vcs")
    parser.add_argument("--only", choices=tuple(configurations()), action="append")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = args.output_dir or ROOT / "sim" / "build" / f"generator_{args.sim}"
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    selected = args.only or list(configurations())
    vcs = os.environ.get("VCS", "/home/kumon/Synopsys/vcs/X-2025.06/bin/vcs")
    vivado_bin = Path(os.environ.get("VIVADO", "/home/kumon/Xilinx/Vivado/2024.1")) / "bin"
    for name in selected:
        config, smoke = configurations()[name]
        work = output / name
        work.mkdir(parents=True, exist_ok=True)
        for filename, data in generate_artifacts(config, full_copy=True).items():
            path = work / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        sources = filelist_sources(work, "static_rtl.f") + filelist_sources(work, "wrapper.f")
        top = config.module_name
        if smoke:
            sources += [ROOT / "sim" / "model" / "mig_axi4_model.sv", ROOT / "tools" / "tests" / "tb_generated_wrapper.sv"]
            top = "tb_generated_wrapper"
        if args.sim == "vcs":
            command = [vcs, "-full64", "-sverilog", "-timescale=1ns/1ps", "-top", top]
            if smoke:
                command.append("+define+GENERATED_MODULE=hades_sram_user")
            command += [str(path) for path in sources] + ["-o", "simv"]
            run_command(command, work, "compile.log")
            if smoke:
                run_command([str(work / "simv")], work, "run.log")
        else:
            command = [str(vivado_bin / "xvlog"), "--sv"]
            if smoke:
                command += ["--define", "GENERATED_MODULE=hades_sram_user"]
            command += [str(path) for path in sources]
            run_command(command, work, "compile.log")
            run_command([
                str(vivado_bin / "xelab"), "--timescale", "1ns/1ps",
                "-top", top, "-snapshot", "snap",
            ], work, "compile.log")
            if smoke:
                run_command([str(vivado_bin / "xsim"), "snap", "-R"], work, "run.log")
        if smoke:
            log = (work / "run.log").read_text(encoding="utf-8", errors="replace")
            if "HADES_GENERATED_WRAPPER_PASS" not in log:
                raise RuntimeError(f"Generated wrapper smoke did not pass; see {work / 'run.log'}\n{log}")
            print(f"{args.sim} {name}: READ/WRITE/BE/LATENCY PASS")
        else:
            print(f"{args.sim} {name}: ELAB PASS")
    print(f"HADES_GENERATOR_RTL_PASS SIM={args.sim}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
