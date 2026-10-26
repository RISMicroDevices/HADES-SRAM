from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path, PureWindowsPath

from .generate import generate_artifacts
from .model import Config, ConfigError, Diagnostic

__all__ = ["atomic_write", "previous_manifest", "managed_names", "generate_files"]


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def previous_manifest(output: Path) -> dict | None:
    path = output / "manifest.json"
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or not isinstance(value.get("files"), list):
            raise ValueError("invalid generator manifest")
        return value
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise ConfigError([Diagnostic("error", "E_MANIFEST", str(path), f"Cannot read existing generator manifest: {exc}")]) from exc


def managed_names(manifest: dict | None) -> set[str]:
    if manifest is None:
        return set()
    result: set[str] = set()
    for item in manifest["files"]:
        if isinstance(item, dict) and isinstance(item.get("path"), str):
            result.add(item["path"])
    return result


def _safe_artifact_path(output: Path, name: str) -> Path | None:
    relative = Path(name)
    windows = PureWindowsPath(name)
    if (
        not name
        or relative == Path(".")
        or relative.is_absolute()
        or windows.is_absolute()
        or bool(windows.drive)
        or ".." in relative.parts
        or ".." in windows.parts
    ):
        return None
    path = output / relative
    try:
        path.resolve().relative_to(output.resolve())
    except ValueError:
        return None
    return path


def _artifact_path(output: Path, name: str) -> Path:
    path = _safe_artifact_path(output, name)
    if path is None:
        raise ConfigError([Diagnostic(
            "error", "E_ARTIFACT_PATH", name, "Unsafe generated artifact path.",
        )])
    return path


def generate_files(
    config: Config,
    output: Path,
    check: bool,
    force: bool,
    full_copy: bool = True,
    *,
    payload_source: str | Path | None = None,
) -> tuple[int, list[str]]:
    artifacts = generate_artifacts(
        config, full_copy, payload_source=payload_source,
    )
    expected = set(artifacts)
    for name in expected:
        _artifact_path(output, name)
    previous = previous_manifest(output) if output.exists() else None
    stale = managed_names(previous) - expected
    problems: list[str] = []
    if check:
        for name in sorted(expected | stale):
            path = _safe_artifact_path(output, name)
            if path is None:
                problems.append(f"refused unsafe managed path: {name}")
            elif name in stale:
                problems.append(f"stale managed artifact: {name}")
            elif not path.is_file():
                problems.append(f"missing artifact: {name}")
            elif path.read_bytes() != artifacts[name]:
                problems.append(f"changed artifact: {name}")
        return (1 if problems else 0), problems
    if not force:
        collisions = sorted(
            name for name in expected
            if _artifact_path(output, name).exists()
        )
        if collisions:
            raise ConfigError([Diagnostic(
                "error", "E_OUTPUT_EXISTS", str(output),
                "Refusing to overwrite existing artifacts without --force: " + ", ".join(collisions),
            )])
    output.mkdir(parents=True, exist_ok=True)
    for name, data in artifacts.items():
        atomic_write(_artifact_path(output, name), data)
    for name in sorted(stale):
        path = _safe_artifact_path(output, name)
        if path is None:
            problems.append(f"refused unsafe stale path: {name}")
            continue
        if path.is_file() or path.is_symlink():
            path.unlink()
    return (1 if problems else 0), problems
