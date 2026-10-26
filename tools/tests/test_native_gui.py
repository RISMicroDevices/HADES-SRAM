import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "tools/hades-sram-gen"
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen import native_gui
from hades_sram_gen.model import ConfigError


class NativeGuiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.record = self.directory / "arguments.txt"
        self.env = os.environ.copy()
        self.env["PYTHONDONTWRITEBYTECODE"] = "1"
        self.env["FAKE_WIZARD_RECORD"] = str(self.record)
        self.env.pop("HADES_WIZARD", None)
        self.env.pop("HADES_WIZARD_HOME", None)

    def fake(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$@\" > \"$FAKE_WIZARD_RECORD\"\n"
            "exit \"${FAKE_WIZARD_STATUS:-0}\"\n",
            encoding="utf-8",
        )
        path.chmod(0o755)
        return path

    def run_cli(self, *arguments, expected=0):
        result = subprocess.run(
            [sys.executable, str(CLI), *map(str, arguments)],
            cwd=self.directory, env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=15, check=False,
        )
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def test_environment_home_and_sibling_precedence(self):
        source_root = self.directory / "HADES-SRAM"
        configured = self.fake(self.directory / "configured" / "hades-wizard")
        home = self.fake(self.directory / "home" / "hades-wizard")
        sibling = self.fake(
            source_root.parent / "HADES-Wizard" / native_gui._PRODUCT /
            "linux/gtk/x86_64/hades-wizard"
        )
        with patch.object(native_gui, "SOURCE_ROOT", source_root), patch.dict(
            os.environ,
            {"HADES_WIZARD": str(configured), "HADES_WIZARD_HOME": str(home.parent)},
        ):
            self.assertEqual(native_gui.resolve_wizard(), configured)
            del os.environ["HADES_WIZARD"]
            self.assertEqual(native_gui.resolve_wizard(), home)
            del os.environ["HADES_WIZARD_HOME"]
            self.assertEqual(native_gui.resolve_wizard(), sibling)

    def test_normal_exit_and_absolute_forwarded_arguments(self):
        executable = self.fake(self.directory / "native" / "hades-wizard")
        self.env["HADES_WIZARD"] = str(executable)
        self.env["FAKE_WIZARD_STATUS"] = "23"
        self.run_cli("gui", "--config", "input.json", "--output", "generated", expected=23)
        arguments = self.record.read_text(encoding="utf-8").splitlines()
        self.assertEqual(arguments, [
            "--provider", str(ROOT / "tools/hades_sram_wizard.json"),
            "--python", str(Path(sys.executable).absolute()),
            "--config", str(self.directory / "input.json"),
            "--output", str(self.directory / "generated"),
        ])
        self.assertTrue(all(Path(value).is_absolute() for value in (
            arguments[1], arguments[3], arguments[5], arguments[7],
        )))

    def test_missing_executable_has_actionable_diagnostic(self):
        self.env["HADES_WIZARD"] = str(self.directory / "missing")
        result = self.run_cli("gui", expected=1)
        self.assertIn("E_WIZARD_NOT_FOUND", result.stderr)
        self.assertIn("HADES_WIZARD_HOME", result.stderr)
        self.assertFalse(self.record.exists())
        with patch.dict(os.environ, {}, clear=True), patch.object(
            native_gui, "SOURCE_ROOT", self.directory / "empty"
        ):
            with self.assertRaises(ConfigError) as caught:
                native_gui.resolve_wizard()
        self.assertEqual(caught.exception.diagnostics[0].code, "E_WIZARD_NOT_FOUND")

    @unittest.skipIf(os.name == "nt", "Linux-specific sibling selection")
    def test_sibling_does_not_select_windows_executable_on_linux(self):
        source_root = self.directory / "HADES-SRAM"
        self.fake(
            source_root.parent / "HADES-Wizard" / native_gui._PRODUCT /
            "win32/win32/x86_64/hades-wizard.exe"
        )
        with patch.object(native_gui, "SOURCE_ROOT", source_root), patch.dict(
            os.environ, {}, clear=True
        ):
            with self.assertRaises(ConfigError) as caught:
                native_gui.resolve_wizard()
        self.assertEqual(caught.exception.diagnostics[0].code, "E_WIZARD_NOT_FOUND")

    def test_direct_process_arguments_and_normal_status(self):
        executable = self.fake(self.directory / "native" / "hades-wizard")
        process = Mock()
        process.wait.return_value = 7
        with patch.dict(os.environ, {"HADES_WIZARD": str(executable)}), patch(
            "hades_sram_gen.native_gui.subprocess.Popen", return_value=process
        ) as popen:
            self.assertEqual(native_gui.run_gui(), 7)
        command = popen.call_args.args[0]
        self.assertIsInstance(command, list)
        self.assertEqual(command[0], str(executable))
        self.assertIs(popen.call_args.kwargs["shell"], False)
        self.assertIsNotNone(popen.call_args.kwargs["env"])
        source = (ROOT / "tools/hades_sram_gen/native_gui.py").read_text(encoding="utf-8")
        self.assertNotIn("webbrowser", source)
        self.assertNotIn("http.server", source)
        self.assertNotIn("socket", source)

    @unittest.skipIf(os.name == "nt", "WSL display backend selection")
    def test_wsl_display_backend_default_and_explicit_override(self):
        executable = self.fake(self.directory / "native" / "hades-wizard")
        for explicit, expected in ((None, "x11"), ("wayland", "wayland")):
            with self.subTest(explicit=explicit):
                process = Mock()
                process.wait.return_value = 0
                environment = {"HADES_WIZARD": str(executable), "WSL_DISTRO_NAME": "Ubuntu-24.04"}
                if explicit is not None:
                    environment["GDK_BACKEND"] = explicit
                with patch.dict(os.environ, environment, clear=True), patch(
                    "hades_sram_gen.native_gui.subprocess.Popen", return_value=process
                ) as popen:
                    self.assertEqual(native_gui.run_gui(), 0)
                self.assertEqual(popen.call_args.kwargs["env"]["GDK_BACKEND"], expected)

    def test_interruption_cleans_only_owned_process(self):
        executable = self.fake(self.directory / "native" / "hades-wizard")
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [KeyboardInterrupt, 0]
        with patch.dict(os.environ, {"HADES_WIZARD": str(executable)}), patch(
            "hades_sram_gen.native_gui.subprocess.Popen", return_value=process
        ):
            with self.assertRaises(KeyboardInterrupt):
                native_gui.run_gui()
        process.terminate.assert_called_once_with()
        process.kill.assert_not_called()
        self.assertEqual(process.wait.call_count, 2)

    def test_removed_browser_flags_are_rejected_without_launch(self):
        executable = self.fake(self.directory / "native" / "hades-wizard")
        self.env["HADES_WIZARD"] = str(executable)
        self.run_cli("gui", "--no-browser", expected=2)
        self.run_cli("gui", "--port", "0", expected=2)
        self.assertFalse(self.record.exists())


if __name__ == "__main__":
    unittest.main()
