from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .model import ConfigError, Diagnostic

__all__ = ["resolve_wizard", "run_gui"]

SOURCE_ROOT = Path(__file__).resolve().parents[2]
_PRODUCT = Path("products/cn.rismd.hades.wizard.product/target/products/cn.rismd.hades.wizard.product")


def _executable(path: Path) -> Path | None:
    path = path.expanduser().absolute()
    if path.is_file() and os.access(path, os.X_OK):
        return path
    return None


def _not_found(message: str) -> ConfigError:
    return ConfigError([Diagnostic(
        "error", "E_WIZARD_NOT_FOUND", "gui",
        message + " Set HADES_WIZARD to the native executable or HADES_WIZARD_HOME to its product directory; alternatively build the sibling HADES-Wizard products.",
    )])


def _home_executable(home: Path) -> Path | None:
    name = "hades-wizard.exe" if os.name == "nt" else "hades-wizard"
    return _executable(home / name)


def _sibling_executable() -> Path | None:
    root = SOURCE_ROOT.parent / "HADES-Wizard" / _PRODUCT
    relative = (
        "win32/win32/x86_64/hades-wizard.exe"
        if os.name == "nt" else
        "linux/gtk/x86_64/hades-wizard"
    )
    return _executable(root / relative)


def resolve_wizard() -> Path:
    configured = os.environ.get("HADES_WIZARD")
    if configured:
        executable = _executable(Path(configured))
        if executable is None:
            raise _not_found(f"HADES_WIZARD is not an executable file: {configured}.")
        return executable
    home = os.environ.get("HADES_WIZARD_HOME")
    if home:
        executable = _home_executable(Path(home))
        if executable is None:
            raise _not_found(f"HADES_WIZARD_HOME does not contain hades-wizard or hades-wizard.exe: {home}.")
        return executable
    executable = _sibling_executable()
    if executable is None:
        raise _not_found("The native HADES-Wizard executable was not found.")
    return executable


def _launch_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if os.name != "nt" and os.environ.get("WSL_DISTRO_NAME") and not os.environ.get("GDK_BACKEND"):
        environment["GDK_BACKEND"] = "x11"
    return environment


def run_gui(config_path: str | None = None, output_path: str | None = None) -> int:
    executable = resolve_wizard()
    provider = (Path(__file__).resolve().parent.parent / "hades_sram_wizard.json").absolute()
    command = [
        str(executable),
        "--provider", str(provider),
        "--python", str(Path(sys.executable).absolute()),
    ]
    if config_path:
        command += ["--config", str(Path(config_path).expanduser().absolute())]
    if output_path:
        command += ["--output", str(Path(output_path).expanduser().absolute())]
    process = subprocess.Popen(command, shell=False, env=_launch_environment())
    try:
        return int(process.wait())
    except KeyboardInterrupt:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise
