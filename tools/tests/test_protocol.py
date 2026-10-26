import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tools/hades-sram-gen"
sys.path.insert(0, str(ROOT / "tools"))


def output_files(root):
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file()
    }

from hades_sram_gen.generate import generate_artifacts
from hades_sram_gen.model import dumps_config, loads_config
from hades_sram_gen.protocol import MAX_REQUEST_BYTES, run_protocol


class ProtocolSubprocessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.env = os.environ.copy()
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.process = subprocess.Popen(
            [sys.executable, str(CLI), "protocol"],
            cwd=ROOT,
            env=self.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def tearDown(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        elif not self.process.stdin.closed:
            self.process.stdin.close()
        remaining_stdout = self.process.stdout.read()
        remaining_stderr = self.process.stderr.read()
        self.process.stdout.close()
        self.process.stderr.close()
        self.assertEqual(self.process.returncode, 0)
        self.assertEqual(remaining_stdout, b"")
        self.assertEqual(remaining_stderr, b"")
        self.assertIsNotNone(self.process.poll())

    def send_raw(self, frame):
        self.process.stdin.write(frame)
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        self.assertTrue(line, "protocol process closed stdout unexpectedly")
        self.assertTrue(line.endswith(b"\n"))
        return json.loads(line)

    def send(self, request):
        return self.send_raw(json.dumps(request).encode("utf-8") + b"\n")

    def request(self, operation, request_id, **payload):
        response = self.send({
            "protocol_version": 1, "id": request_id,
            "operation": operation, **payload,
        })
        self.assertEqual(response["protocol_version"], 1)
        self.assertEqual(response["id"], request_id)
        return response

    def assert_protocol_error(self, response, code, request_id=None):
        self.assertIs(response["ok"], False)
        self.assertEqual(response["id"], request_id)
        self.assertEqual(response["error"]["code"], code)
        self.assertIsInstance(response["error"]["message"], str)
        self.assertIsInstance(response["error"]["diagnostics"], list)

    def test_persistent_requests_and_analysis_operations(self):
        schema = self.request("schema", 1)
        self.assertTrue(schema["ok"])
        self.assertEqual(schema["result"]["protocol_version"], 1)
        analysis = self.request("analyze", 7, config={})
        self.assertTrue(analysis["ok"])
        self.assertTrue(analysis["result"]["valid"])
        derived = self.request("derive_periods", 3, config={
            "port_clock_hz": 100_000,
            "target_period_cycles": 2500,
            "min_period_cycles": 2600,
        })
        self.assertEqual(derived["result"]["config"]["target_period_cycles"], 3000)
        self.assertEqual(derived["result"]["config"]["min_period_cycles"], 3000)
        resized = self.request("resize", 9, config={}, count=2)
        self.assertEqual(resized["result"]["config"]["port_count"], 2)
        edited = self.request("apply_depths", 4, config={}, changes={"0": 17})
        self.assertEqual(edited["result"]["config"]["ports"][0]["size_lanes"], 17)
        allocated = self.request("allocate", 12, config={"address_width": 8}, depths=[17])
        self.assertTrue(allocated["result"]["valid"])
        self.assertEqual(allocated["result"]["config"]["ports"][0]["base_beats"], 0)
        self.assertEqual(allocated["result"]["analysis"]["ports"][0]["capacity_words"], 17)

    def test_malformed_duplicate_unknown_bad_types_then_valid(self):
        self.assert_protocol_error(self.send_raw(b"{bad\n"), "E_JSON")
        duplicate = b'{"protocol_version":1,"id":9,"id":10,"operation":"schema"}\n'
        self.assert_protocol_error(self.send_raw(duplicate), "E_JSON")
        response = self.send({"protocol_version": 2, "id": 11, "operation": "schema"})
        self.assert_protocol_error(response, "E_PROTOCOL_VERSION", 11)
        response = self.send({"protocol_version": 1, "id": 12, "operation": "unknown"})
        self.assert_protocol_error(response, "E_UNKNOWN_OPERATION", 12)
        response = self.send({"protocol_version": 1, "id": True, "operation": "schema"})
        self.assert_protocol_error(response, "E_REQUEST_ID")
        response = self.send({"protocol_version": True, "id": 13, "operation": "schema"})
        self.assert_protocol_error(response, "E_PROTOCOL_VERSION", 13)
        response = self.request("generate", 14, config={}, output="unused", check="yes")
        self.assert_protocol_error(response, "E_REQUEST", 14)
        response = self.request("schema", 15, unexpected=True)
        self.assert_protocol_error(response, "E_REQUEST", 15)
        self.assert_protocol_error(self.send_raw(b"\xff\n"), "E_UTF8")
        self.assert_protocol_error(self.send_raw(b"[]\n"), "E_REQUEST")
        response = self.request("analyze_text", 16, text='{"port_count":1,"port_count":2}')
        self.assertTrue(response["ok"])
        self.assertFalse(response["result"]["valid"])
        response = self.request("analyze", 17, config=[])
        self.assertTrue(response["ok"])
        self.assertFalse(response["result"]["valid"])
        response = self.request("analyze", 18, config={})
        self.assertTrue(response["ok"])
        self.assertTrue(response["result"]["valid"])

    def test_overlong_frame_drains_and_recovers(self):
        response = self.send_raw(b" " * (MAX_REQUEST_BYTES + 4096) + b"\n")
        self.assert_protocol_error(response, "E_REQUEST_TOO_LARGE")
        response = self.request("schema", 22)
        self.assertTrue(response["ok"])
        self.assertEqual(response["result"]["schema_version"], 1)

    def test_allocate_preview_save_generate_check_and_parity(self):
        allocated = self.request("allocate", 1, config={"address_width": 8}, depths=[17])
        config = allocated["result"]["config"]
        reference_config = loads_config(json.dumps(config))
        reference = generate_artifacts(reference_config)

        preview = self.request("preview", 2, config=config)
        self.assertTrue(preview["ok"])
        self.assertEqual(preview["result"]["artifacts"], {
            name: data.decode("utf-8") for name, data in reference.items()
        })

        config_path = self.directory / "saved.json"
        saved = self.request("save", 3, config=config, path=str(config_path))
        self.assertTrue(saved["result"]["saved"])
        self.assertEqual(config_path.read_bytes(), dumps_config(reference_config).encode("utf-8"))
        original = config_path.read_bytes()
        refused = self.request("save", 4, config=config, path=str(config_path))
        self.assertTrue(refused["ok"])
        self.assertFalse(refused["result"]["saved"])
        self.assertFalse(refused["result"]["valid"])
        self.assertEqual(config_path.read_bytes(), original)
        forced = self.request("save", 5, config=config, path=str(config_path), force=True)
        self.assertTrue(forced["result"]["saved"])

        output = self.directory / "generated"
        generated = self.request("generate", 6, config=config, output=str(output))
        self.assertEqual(generated["result"]["outcome"], "generated")
        self.assertEqual(output_files(output), dict(reference))
        checked = self.request("generate", 7, config=config, output=str(output), check=True)
        self.assertEqual(checked["result"]["outcome"], "checked")
        self.assertEqual(checked["result"]["status"], 0)

        minimal_reference = generate_artifacts(reference_config, full_copy=False)
        minimal_preview = self.request("preview", 8, config=config, full_copy=False)
        self.assertEqual(minimal_preview["result"]["artifacts"], {
            name: data.decode("utf-8") for name, data in minimal_reference.items()
        })
        minimal_output = self.directory / "generated-minimal"
        minimal = self.request(
            "generate", 9, config=config, output=str(minimal_output), full_copy=False,
        )
        self.assertEqual(minimal["result"]["outcome"], "generated")
        self.assertEqual(output_files(minimal_output), dict(minimal_reference))
        minimal_check = self.request(
            "generate", 10, config=config, output=str(minimal_output),
            check=True, full_copy=False,
        )
        self.assertEqual(minimal_check["result"]["outcome"], "checked")
        for request_id, value in ((11, "yes"), (12, 0), (13, None), (14, [])):
            with self.subTest(full_copy=value):
                response = self.request("preview", request_id, config=config, full_copy=value)
                self.assert_protocol_error(response, "E_REQUEST", request_id)
        response = self.request(
            "generate", 15, config=config, output=str(self.directory / "must-not-exist"),
            full_copy=1,
        )
        self.assert_protocol_error(response, "E_REQUEST", 15)
        self.assertFalse((self.directory / "must-not-exist").exists())


class ProtocolFramingTests(unittest.TestCase):
    def test_response_cap_returns_bounded_error(self):
        request = json.dumps({"protocol_version": 1, "id": 1, "operation": "schema"}).encode() + b"\n"
        output = io.BytesIO()
        with patch("hades_sram_gen.protocol.MAX_RESPONSE_BYTES", 512):
            status = run_protocol(io.BytesIO(request), output)
        self.assertEqual(status, 0)
        self.assertLessEqual(len(output.getvalue()), 512)
        response = json.loads(output.getvalue())
        self.assertEqual(response["id"], 1)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "E_RESPONSE_TOO_LARGE")

    def test_empty_eof_exits_cleanly(self):
        result = subprocess.run(
            [sys.executable, str(CLI), "protocol"], cwd=ROOT,
            input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=10, check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
