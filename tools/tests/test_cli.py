import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tools/hades-sram-gen"


def output_files(root):
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file()
    }


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config = self.directory / "config.json"
        self.output = self.directory / "generated"
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
        self.assertEqual(
            result.returncode,
            expected,
            f"command: {arguments}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        return result

    def init(self):
        return self.run_cli("init", "--output", self.config)

    def generate(self, *extra, expected=0):
        return self.run_cli(
            "generate", "--config", self.config, "--output", self.output,
            *extra, expected=expected,
        )

    def update_config(self, **changes):
        data = json.loads(self.config.read_text(encoding="utf-8"))
        data.update(changes)
        self.config.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def test_init_validate_analyze_generate_and_check(self):
        result = self.init()
        self.assertIn("Wrote default configuration", result.stdout)
        config = json.loads(self.config.read_text(encoding="utf-8"))
        self.assertEqual(config["port_count"], 1)
        self.assertEqual(config["ports"][0]["width"], 32)

        result = self.run_cli("validate", "--config", self.config, "--json")
        validation = json.loads(result.stdout)
        self.assertIs(validation["valid"], True)
        self.assertEqual(validation["diagnostics"], [])

        result = self.run_cli("analyze", "--config", self.config, "--json")
        analysis = json.loads(result.stdout)
        self.assertIs(analysis["analytical_only"], True)
        self.assertEqual(analysis["timing"]["budget_used_cycles"], 294)
        self.assertEqual(analysis["clock"]["port_requested_hz"], 500_000)
        self.assertEqual(analysis["diagnostics"], [])

        result = self.generate()
        self.assertIn("GENERATOR PASS", result.stdout)
        manifest = json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))
        managed = [item["path"] for item in manifest["files"]]
        self.assertIn("config.json", managed)
        self.assertIn("logical/hades_sram_config_pkg.sv", managed)
        self.assertIn("csr_init.tcl", managed)
        self.assertNotIn("configure_ip.tcl", managed)
        self.assertIs(manifest["full_copy"], True)
        self.assertEqual(set(output_files(self.output)), {*managed, "manifest.json"})
        result = self.generate("--check")
        self.assertIn("GENERATOR CHECK PASS", result.stdout)
        self.assertEqual(result.stderr, "")

    def test_generate_refuses_overwrite_and_force_replaces(self):
        self.init()
        self.generate()
        before = output_files(self.output)
        result = self.generate(expected=1)
        self.assertIn("E_OUTPUT_EXISTS", result.stderr)
        self.assertIn("without --force", result.stderr)
        self.assertEqual(output_files(self.output), before)
        result = self.generate("--force")
        self.assertIn("GENERATOR PASS", result.stdout)
        self.assertEqual(output_files(self.output), before)

    def test_check_detects_changed_artifact_without_repairing_it(self):
        self.init()
        self.generate()
        summary = self.output / "report/summary.txt"
        original = summary.read_bytes()
        summary.write_bytes(original + b"local edit\n")
        result = self.generate("--check", expected=1)
        self.assertIn("changed artifact: report/summary.txt", result.stderr)
        self.assertEqual(summary.read_bytes(), original + b"local edit\n")
        self.generate("--force")
        self.assertEqual(summary.read_bytes(), original)
        self.generate("--check")

    def test_check_detects_missing_artifact(self):
        self.init()
        self.generate()
        (self.output / "report/analysis.json").unlink()
        result = self.generate("--check", expected=1)
        self.assertIn("missing artifact: report/analysis.json", result.stderr)

    def test_full_copy_flags_opt_out_conflict_and_restore(self):
        self.init()
        self.generate()
        self.generate("--check", "--full-copy")
        before = output_files(self.output)
        result = self.generate("--check", "--no-full-copy", expected=1)
        self.assertIn("stale managed artifact: static_rtl.f", result.stderr)
        self.assertEqual(output_files(self.output), before)
        self.generate("--no-full-copy", "--force")
        self.assertFalse((self.output / "static_rtl.f").exists())
        self.assertFalse((self.output / "logical/hades_sram_top.sv").exists())
        self.assertTrue((self.output / "constraints/sram0_strict.xdc").is_file())
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertIs(manifest["full_copy"], False)
        self.assertNotIn("full_copy", json.loads((self.output / "config.json").read_text()))
        self.generate("--check", "--no-full-copy")
        before = output_files(self.output)
        result = self.generate("--full-copy", "--no-full-copy", expected=2)
        self.assertIn("not allowed with argument", result.stderr)
        self.assertEqual(output_files(self.output), before)
        self.generate("--full-copy", "--force")
        self.assertTrue((self.output / "static_rtl.f").is_file())
        self.generate("--check")

    def test_stale_managed_file_is_checked_and_removed_by_force(self):
        self.init()
        self.generate()
        csr_init = self.output / "csr_init.tcl"
        self.assertTrue(csr_init.is_file())
        self.update_config(configuration_mode="STATIC")
        result = self.generate("--check", expected=1)
        self.assertIn("stale managed artifact: csr_init.tcl", result.stderr)
        self.assertTrue(csr_init.is_file())
        self.generate("--force")
        self.assertFalse(csr_init.exists())
        self.generate("--check")
        manifest = json.loads((self.output / "manifest.json").read_text(encoding="utf-8"))
        self.assertNotIn("csr_init.tcl", {item["path"] for item in manifest["files"]})

    def test_init_refuses_overwrite_unless_forced(self):
        self.init()
        original = self.config.read_bytes()
        self.config.write_bytes(original + b" ")
        result = self.run_cli("init", "--output", self.config, expected=1)
        self.assertIn("E_OUTPUT_EXISTS", result.stderr)
        self.assertEqual(self.config.read_bytes(), original + b" ")
        self.run_cli("init", "--output", self.config, "--force")
        self.assertEqual(self.config.read_bytes(), original)

    def test_invalid_config_has_nonzero_status_and_field_diagnostics(self):
        self.init()
        self.update_config(address_width=0)
        result = self.run_cli("validate", "--config", self.config, "--json", expected=1)
        payload = json.loads(result.stdout)
        self.assertIs(payload["valid"], False)
        diagnostic = next(item for item in payload["diagnostics"] if item["code"] == "E_AW_RANGE")
        self.assertEqual(diagnostic["path"], "address_width")
        result = self.run_cli("analyze", "--config", self.config, "--json", expected=1)
        payload = json.loads(result.stdout)
        self.assertIsNone(payload["analysis"])
        result = self.generate(expected=1)
        self.assertIn("ERROR E_AW_RANGE address_width:", result.stderr)
        self.assertFalse(self.output.exists())

    def test_strict_json_type_error_has_field_diagnostic(self):
        self.init()
        self.update_config(port_count=True)
        result = self.run_cli("validate", "--config", self.config, expected=1)
        self.assertIn("ERROR E_TYPE_INTEGER port_count:", result.stderr)


if __name__ == "__main__":
    unittest.main()
