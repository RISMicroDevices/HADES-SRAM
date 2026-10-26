from __future__ import annotations

import json
import sys
from typing import Any, BinaryIO

from . import service
from .model import ConfigError, Diagnostic, loads_config_data

__all__ = ["PROTOCOL_VERSION", "MAX_REQUEST_BYTES", "MAX_RESPONSE_BYTES", "run_protocol"]

PROTOCOL_VERSION = 1
MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
_ENVELOPE_KEYS = {"protocol_version", "id", "operation"}
_OPERATIONS = {
    "schema": (set(), set()),
    "analyze": ({"config"}, set()),
    "analyze_text": ({"text"}, set()),
    "derive_periods": ({"config"}, set()),
    "resize": ({"config", "count"}, set()),
    "apply_depths": ({"config", "changes"}, set()),
    "allocate": ({"config", "depths"}, set()),
    "preview": ({"config"}, {"full_copy"}),
    "save": ({"config", "path"}, {"force"}),
    "generate": ({"config", "output"}, {"check", "force", "full_copy"}),
}


class _ProtocolError(ValueError):
    def __init__(self, code: str, message: str,
                 diagnostics: tuple[Diagnostic, ...] = ()):
        self.code = code
        self.message = message
        self.diagnostics = diagnostics
        super().__init__(message)


def _error_response(request_id: int | None, code: str, message: str,
                    diagnostics: tuple[Diagnostic, ...] = ()) -> dict[str, Any]:
    return {
        "protocol_version": PROTOCOL_VERSION,
        "id": request_id,
        "ok": False,
        "error": {
            "code": code,
            "message": message,
            "diagnostics": [item.to_dict() for item in diagnostics],
        },
    }


def _payload(request: dict[str, Any], operation: str) -> dict[str, Any]:
    required, optional = _OPERATIONS[operation]
    payload = {key: value for key, value in request.items() if key not in _ENVELOPE_KEYS}
    missing = sorted(required - payload.keys())
    unknown = sorted(payload.keys() - required - optional)
    if missing:
        raise _ProtocolError("E_REQUEST", f"Missing {operation} payload field(s): {', '.join(missing)}.")
    if unknown:
        raise _ProtocolError("E_REQUEST", f"Unknown {operation} payload field(s): {', '.join(unknown)}.")
    return payload


def _boolean(payload: dict[str, Any], key: str, default: bool = False) -> bool:
    value = payload.get(key, default)
    if not isinstance(value, bool):
        raise _ProtocolError("E_REQUEST", f"{key} must be a boolean.")
    return value


def _string(payload: dict[str, Any], key: str) -> str:
    value = payload[key]
    if not isinstance(value, str):
        raise _ProtocolError("E_REQUEST", f"{key} must be a string.")
    return value


def _dispatch(request: Any) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise _ProtocolError("E_REQUEST", "A protocol request must be a JSON object.")
    request_id = request.get("id")
    if isinstance(request_id, bool) or not isinstance(request_id, int) or request_id < 1:
        raise _ProtocolError("E_REQUEST_ID", "id must be a positive integer.")
    if request.get("protocol_version") != PROTOCOL_VERSION or isinstance(request.get("protocol_version"), bool):
        raise _ProtocolError("E_PROTOCOL_VERSION", "protocol_version must be integer 1.")
    operation = request.get("operation")
    if not isinstance(operation, str):
        raise _ProtocolError("E_REQUEST", "operation must be a string.")
    if operation not in _OPERATIONS:
        raise _ProtocolError("E_UNKNOWN_OPERATION", f"Unknown operation: {operation}.")
    payload = _payload(request, operation)
    config = payload.get("config")
    if operation == "schema":
        return service.generator_schema()
    if operation == "analyze":
        return service.analyze_data(config)
    if operation == "analyze_text":
        return service.analyze_text(_string(payload, "text"))
    if operation == "derive_periods":
        return service.derive_periods(config)
    if operation == "resize":
        return service.resize(config, payload["count"])
    if operation == "apply_depths":
        return service.apply_depth_edits(config, payload["changes"])
    if operation == "allocate":
        return service.allocate(config, payload["depths"])
    if operation == "preview":
        return service.preview(
            config, _boolean(payload, "full_copy", True),
        )
    if operation == "save":
        return service.save_config(config, _string(payload, "path"), _boolean(payload, "force"))
    if operation == "generate":
        return service.generate(
            config, _string(payload, "output"),
            _boolean(payload, "check"), _boolean(payload, "force"),
            _boolean(payload, "full_copy", True),
        )
    raise _ProtocolError("E_UNKNOWN_OPERATION", f"Unknown operation: {operation}.")


def _request_id(request: Any) -> int | None:
    if not isinstance(request, dict):
        return None
    value = request.get("id")
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        return None
    return value


def _drain_line(stream: BinaryIO) -> None:
    while True:
        chunk = stream.readline(64 * 1024)
        if not chunk or chunk.endswith(b"\n"):
            return


def _write_response(stream: BinaryIO, response: dict[str, Any]) -> None:
    request_id = response.get("id")
    try:
        encoded = json.dumps(
            response, ensure_ascii=False, separators=(",", ":"), allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError):
        response = _error_response(
            request_id if isinstance(request_id, int) else None,
            "E_INTERNAL", "The response could not be encoded.",
        )
        encoded = json.dumps(response, separators=(",", ":")).encode("utf-8")
    if len(encoded) + 1 > MAX_RESPONSE_BYTES:
        response = _error_response(
            request_id if isinstance(request_id, int) else None,
            "E_RESPONSE_TOO_LARGE", "The serialized response exceeds the 32 MiB protocol limit.",
        )
        encoded = json.dumps(response, separators=(",", ":")).encode("utf-8")
    stream.write(encoded + b"\n")
    stream.flush()


def run_protocol(input_stream: BinaryIO | None = None,
                 output_stream: BinaryIO | None = None) -> int:
    input_stream = sys.stdin.buffer if input_stream is None else input_stream
    output_stream = sys.stdout.buffer if output_stream is None else output_stream
    while True:
        line = input_stream.readline(MAX_REQUEST_BYTES + 1)
        if not line:
            return 0
        if len(line) > MAX_REQUEST_BYTES:
            if not line.endswith(b"\n"):
                _drain_line(input_stream)
            _write_response(output_stream, _error_response(
                None, "E_REQUEST_TOO_LARGE",
                "The request frame exceeds the 2 MiB protocol limit.",
            ))
            continue
        request_id: int | None = None
        try:
            try:
                text = line.decode("utf-8", errors="strict")
            except UnicodeDecodeError as exc:
                raise _ProtocolError("E_UTF8", "Request frames must contain valid UTF-8.") from exc
            try:
                request = loads_config_data(text)
            except ConfigError as exc:
                raise _ProtocolError("E_JSON", str(exc), exc.diagnostics) from exc
            request_id = _request_id(request)
            result = _dispatch(request)
            response = {
                "protocol_version": PROTOCOL_VERSION,
                "id": request_id,
                "ok": True,
                "result": result,
            }
        except _ProtocolError as exc:
            response = _error_response(request_id, exc.code, exc.message, exc.diagnostics)
        except ConfigError as exc:
            response = _error_response(request_id, "E_CONFIG", str(exc), exc.diagnostics)
        except Exception:
            response = _error_response(request_id, "E_INTERNAL", "The request could not be completed.")
        _write_response(output_stream, response)
