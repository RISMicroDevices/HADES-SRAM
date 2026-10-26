import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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
from hades_sram_gen.model import (
    default_config,
    default_port,
    dumps_config,
    loads_config,
    port_to_dict,
)


class OverrideCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.env = os.environ.copy()
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"

    def run_cli(self, *arguments, expected=0):
        result = subprocess.run(
            [sys.executable, str(CLI), *map(str, arguments)],
            cwd=ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
        if expected is None:
            self.assertNotEqual(
                result.returncode, 0,
                f"command unexpectedly passed: {arguments}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
        else:
            self.assertEqual(
                result.returncode, expected,
                f"command: {arguments}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
        return result

    def write_json(self, name, data):
        path = self.directory / name
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        return path

    def init_config(self, name, *arguments):
        output = self.directory / name
        self.run_cli("init", "--output", output, *arguments)
        text = output.read_text(encoding="utf-8")
        self.assertEqual(text, dumps_config(loads_config(text)))
        return json.loads(text)

    def assert_init_fails_without_output(self, *arguments):
        output = self.directory / "must-not-exist.json"
        self.run_cli("init", "--output", output, *arguments, expected=None)
        self.assertFalse(output.exists())

    def assert_generate_fails_without_output(self, *arguments):
        output = self.directory / "must-not-exist"
        self.run_cli("generate", "--output", output, *arguments, expected=None)
        self.assertFalse(output.exists())

    def test_every_global_option_is_applied_to_canonical_init(self):
        base = self.write_json("base.json", {"port_clock_hz": 100_000})
        cases = (
            (("--schema-version", "1"), "schema_version", 1),
            (("--target", "ip"), "target", "ip"),
            (("--module-name", "cli_module"), "module_name", "cli_module"),
            (("--ip-name", "cli_ip"), "ip_name", "cli_ip"),
            (("--port-count", "2"), "port_count", 2),
            (("--address-width", "23"), "address_width", 23),
            (("--clock-mode", "ASYNC"), "clock_mode", "ASYNC"),
            (("--configuration-mode", "STATIC"), "configuration_mode", "STATIC"),
            (("--port-clock-hz", "250000"), "port_clock_hz", 250_000),
            (("--target-period-cycles", "2500"), "target_period_cycles", 2500),
            (("--min-period-cycles", "3000"), "min_period_cycles", 3000),
            (("--read-latency", "1"), "read_latency", 1),
            (("--selftest-enabled",), "selftest_enabled", True),
            (("--no-selftest-enabled",), "selftest_enabled", False),
            (("--selftest-block-words", "128"), "selftest_block_words", 128),
            (("--refresh-cycles", "2200"), "refresh_cycles", 2200),
            (("--zq-periods", "32001"), "zq_periods", 32_001),
        )
        for index, (arguments, field, expected) in enumerate(cases):
            with self.subTest(option=arguments[0]):
                data = self.init_config(f"global-{index}.json", "--config", base, *arguments)
                self.assertEqual(data[field], expected)

    def test_every_indexed_port_option_and_boolean_form_at_indices_0_and_63(self):
        data = self.init_config(
            "widths.json", "--port-count", "64",
            "--port-width", "0=13", "--port-width", "63=512",
        )
        self.assertEqual(data["ports"][0]["width"], 13)
        self.assertEqual(data["ports"][63]["width"], 512)

        data = self.init_config(
            "byte-enables.json", "--port-count", "64",
            "--port-byte-enable", "0=true", "--port-byte-enable", "63=false",
        )
        self.assertIs(data["ports"][0]["byte_enable"], True)
        self.assertIs(data["ports"][63]["byte_enable"], False)

        data = self.init_config(
            "enables.json", "--port-count", "64",
            "--port-enabled", "0=false", "--port-enabled", "63=true",
        )
        self.assertIs(data["ports"][0]["enabled"], False)
        self.assertIs(data["ports"][63]["enabled"], True)

        data = self.init_config(
            "bases.json", "--port-count", "64",
            "--port-base-beats", "0=0", "--port-base-beats", f"63={63 * (1 << 18) + 1}",
        )
        self.assertEqual(data["ports"][0]["base_beats"], 0)
        self.assertEqual(data["ports"][63]["base_beats"], 63 * (1 << 18) + 1)

        data = self.init_config(
            "sizes.json", "--port-count", "64",
            "--port-size-lanes", "0=32", "--port-size-lanes", "63=64",
        )
        self.assertEqual(data["ports"][0]["size_lanes"], 32)
        self.assertEqual(data["ports"][63]["size_lanes"], 64)

    def test_no_config_validate_analyze_and_generate_use_defaults(self):
        result = self.run_cli("validate", "--json")
        self.assertIs(json.loads(result.stdout)["valid"], True)
        result = self.run_cli("analyze", "--json")
        analysis = json.loads(result.stdout)
        self.assertEqual(analysis["clock"]["port_requested_hz"], 500_000)
        self.assertEqual(analysis["timing"]["budget_used_cycles"], 294)

        output = self.directory / "default-generated"
        self.run_cli("generate", "--output", output)
        self.assertEqual(
            (output / "config.json").read_bytes(),
            dumps_config(default_config()).encode("utf-8"),
        )
        self.run_cli("generate", "--output", output, "--check")

    def test_full_cli_only_mixed_generation_matches_generator_api_byte_for_byte(self):
        expected = {
            "schema_version": 1,
            "target": "ip",
            "module_name": "cli_wrapper",
            "ip_name": "cli_ip",
            "port_count": 2,
            "address_width": 12,
            "clock_mode": "ASYNC",
            "configuration_mode": "CSR",
            "port_clock_hz": 100_000,
            "target_period_cycles": 2900,
            "min_period_cycles": 3000,
            "read_latency": 1,
            "selftest_enabled": True,
            "selftest_block_words": 4,
            "refresh_cycles": 2000,
            "zq_periods": 31_000,
            "ports": [
                {"width": 32, "byte_enable": True, "enabled": True, "base_beats": 16, "size_lanes": 16},
                {"width": 64, "byte_enable": False, "enabled": False, "base_beats": 32, "size_lanes": 32},
            ],
        }
        arguments = (
            "--port-width", "0=32", "--port-byte-enable", "0=true",
            "--port-enabled", "0=true", "--port-base-beats", "0=16",
            "--port-size-lanes", "0=16", "--port-width", "1=64",
            "--port-byte-enable", "1=false", "--port-enabled", "1=false",
            "--port-base-beats", "1=32", "--port-size-lanes", "1=32",
            "--schema-version", "1", "--target", "ip",
            "--module-name", "cli_wrapper", "--ip-name", "cli_ip",
            "--address-width", "12", "--clock-mode", "ASYNC",
            "--configuration-mode", "CSR", "--port-clock-hz", "100000",
            "--target-period-cycles", "2900", "--min-period-cycles", "3000",
            "--read-latency", "1", "--selftest-enabled",
            "--selftest-block-words", "4", "--refresh-cycles", "2000",
            "--zq-periods", "31000", "--port-count", "2",
        )
        output = self.directory / "mixed-generated"
        self.run_cli("generate", "--output", output, *arguments)
        reference = generate_artifacts(loads_config(json.dumps(expected)))
        actual = output_files(output)
        self.assertEqual(actual, dict(reference))
        self.run_cli("generate", "--output", output, "--check", *arguments)

    def test_json_global_and_indexed_precedence_with_order_independent_resize(self):
        base = self.write_json("precedence.json", {
            "module_name": "json_module",
            "port_clock_hz": 100_000,
            "ports": [{
                "width": 16, "byte_enable": True, "enabled": True,
                "base_beats": 7, "size_lanes": 8,
            }],
        })
        common = (
            "--config", base, "--module-name", "cli_module",
            "--port-width", "0=64", "--port-byte-enable", "0=false",
            "--port-enabled", "0=false", "--port-base-beats", "0=99",
            "--port-size-lanes", "0=24",
        )
        first_path = self.directory / "precedence-first.json"
        second_path = self.directory / "precedence-second.json"
        self.run_cli("init", "--output", first_path, *common, "--port-count", "2")
        self.run_cli("init", "--output", second_path, "--port-count", "2", *common)
        self.assertEqual(first_path.read_bytes(), second_path.read_bytes())
        data = json.loads(first_path.read_text(encoding="utf-8"))
        self.assertEqual(data["module_name"], "cli_module")
        self.assertEqual(data["target_period_cycles"], 3000)
        self.assertEqual(data["min_period_cycles"], 3000)
        self.assertEqual(data["ports"][0], {
            "width": 64, "byte_enable": False, "enabled": False,
            "base_beats": 99, "size_lanes": 24,
        })
        self.assertEqual(data["ports"][1], port_to_dict(default_port(1)))

    def test_sparse_derivation_and_explicit_cycle_preservation(self):
        data = self.init_config("derived-cli.json", "--port-clock-hz", "100000")
        self.assertEqual((data["target_period_cycles"], data["min_period_cycles"]), (3000, 3000))

        sparse = self.write_json("sparse.json", {
            "port_clock_hz": 100_000, "target_period_cycles": 2500,
        })
        data = self.init_config("derived-source.json", "--config", sparse)
        self.assertEqual((data["target_period_cycles"], data["min_period_cycles"]), (2500, 3000))

        explicit = self.write_json("explicit.json", {
            "port_clock_hz": 100_000,
            "target_period_cycles": 2500,
            "min_period_cycles": 2600,
        })
        data = self.init_config("preserved-source.json", "--config", explicit)
        self.assertEqual((data["target_period_cycles"], data["min_period_cycles"]), (2500, 2600))
        data = self.init_config(
            "preserved-cli.json", "--config", explicit,
            "--target-period-cycles", "2400", "--min-period-cycles", "2450",
        )
        self.assertEqual((data["target_period_cycles"], data["min_period_cycles"]), (2400, 2450))

    def test_resize_growth_and_shrink_preserve_records_and_default_new_geometry(self):
        one = self.write_json("one.json", {
            "port_count": 1,
            "ports": [{"width": 40, "byte_enable": True, "base_beats": 17, "size_lanes": 48}],
        })
        grown = self.init_config("grown.json", "--config", one, "--port-count", "3")
        self.assertEqual(grown["ports"][0], {
            "width": 40, "byte_enable": True, "enabled": True,
            "base_beats": 17, "size_lanes": 48,
        })
        self.assertEqual(grown["ports"][1:], [port_to_dict(default_port(1)), port_to_dict(default_port(2))])

        three = self.write_json("three.json", {
            "port_count": 3,
            "ports": [port_to_dict(default_port(index)) for index in range(3)],
        })
        shrunk = self.init_config("shrunk.json", "--config", three, "--port-count", "1")
        self.assertEqual(shrunk["port_count"], 1)
        self.assertEqual(shrunk["ports"], [port_to_dict(default_port(0))])

    def test_malformed_indexed_values_and_global_values_do_not_write(self):
        cases = (
            ("--port-width", "0"),
            ("--port-width", "=32"),
            ("--port-width", "0="),
            ("--port-width", "x=32"),
            ("--port-width", "0=x"),
            ("--port-byte-enable", "0=1"),
            ("--port-byte-enable", "0=TRUE"),
            ("--port-enabled", "0=yes"),
            ("--port-base-beats", "0=1.5"),
            ("--port-size-lanes", "zero=32"),
            ("--port-clock-hz", "fast"),
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assert_init_fails_without_output(*arguments)
                self.assert_generate_fails_without_output(*arguments)

    def test_invalid_indices_unknown_options_conflicts_and_semantics_do_not_write(self):
        cases = (
            ("--port-width", "1=32"),
            ("--port-width", "64=32", "--port-count", "64"),
            ("--port-enabled=-1=true"),
            ("--unknown-override", "1"),
            ("--selftest-enabled", "--no-selftest-enabled"),
            ("--address-width", "0"),
            ("--port-count", "0"),
            ("--target", "invalid"),
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                self.assert_init_fails_without_output(*arguments)
                self.assert_generate_fails_without_output(*arguments)

    def test_invalid_forced_init_preserves_existing_file(self):
        output = self.directory / "existing.json"
        output.write_bytes(b"keep me\n")
        self.run_cli(
            "init", "--output", output, "--force", "--address-width", "0",
            expected=1,
        )
        self.assertEqual(output.read_bytes(), b"keep me\n")

    def test_indexed_overrides_do_not_repair_port_list_length(self):
        malformed = self.write_json("bad-port-list.json", {
            "port_count": 2,
            "ports": [port_to_dict(default_port(0))],
        })
        for indexed in (("0=40"), ("1=40")):
            with self.subTest(indexed=indexed):
                output = self.directory / "must-not-exist.json"
                result = self.run_cli(
                    "init", "--output", output, "--config", malformed,
                    "--port-width", indexed, expected=1,
                )
                self.assertIn("E_PORT_LIST_LENGTH", result.stderr)
                self.assertFalse(output.exists())

    def test_strict_json_errors_survive_overrides_without_output(self):
        duplicate = self.directory / "duplicate.json"
        duplicate.write_text('{"port_count": 1, "port_count": 2}\n', encoding="utf-8")
        unknown = self.write_json("unknown.json", {"mystery": True})
        for source in (duplicate, unknown):
            with self.subTest(source=source.name):
                self.assert_init_fails_without_output("--config", source, "--module-name", "valid_name")
                self.assert_generate_fails_without_output("--config", source, "--module-name", "valid_name")

    def test_force_check_and_stale_manifest_behavior_with_overrides(self):
        output = self.directory / "managed"
        self.run_cli("generate", "--output", output)
        original = output_files(output)
        result = self.run_cli("generate", "--output", output, expected=1)
        self.assertIn("E_OUTPUT_EXISTS", result.stderr)
        self.assertEqual(output_files(output), original)

        self.run_cli("generate", "--output", output, "--force", "--configuration-mode", "STATIC")
        self.assertFalse((output / "csr_init.tcl").exists())
        result = self.run_cli("generate", "--output", output, "--check", "--configuration-mode", "STATIC")
        self.assertIn("GENERATOR CHECK PASS", result.stdout)
        result = self.run_cli(
            "generate", "--output", output, "--check", "--configuration-mode", "CSR",
            expected=1,
        )
        self.assertIn("missing artifact: csr_init.tcl", result.stderr)
        self.assertFalse((output / "csr_init.tcl").exists())


if __name__ == "__main__":
    unittest.main()
