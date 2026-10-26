import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen import contract as c
from hades_sram_gen.generate import generate_artifacts
from hades_sram_gen.model import config_to_dict, default_config, default_port, dumps_config, resize_ports
from hades_sram_gen.service import (
    allocate,
    analyze_data,
    analyze_text,
    apply_depth_edits,
    derive_periods,
    generate,
    generator_schema,
    preview,
    resize,
    save_config,
)


def output_files(root):
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file()
    }


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def assert_diagnostic(self, response, code, path=None):
        matches = [item for item in response["diagnostics"] if item["code"] == code]
        self.assertTrue(matches, response["diagnostics"])
        if path is not None:
            self.assertEqual(matches[0]["path"], path)
        self.assertFalse(response["valid"])

    def test_schema_exposes_all_fields_constants_and_capabilities(self):
        schema = generator_schema()
        self.assertEqual(schema["name"], c.GENERATOR_NAME)
        self.assertEqual(schema["protocol_version"], 1)
        self.assertEqual(schema["schema_version"], c.SCHEMA_VERSION)
        self.assertEqual(schema["vlnv"], c.VLNV)
        self.assertTrue(schema["version"])
        self.assertEqual(schema["defaults"], config_to_dict(default_config()))
        self.assertEqual(set(schema["fields"]["global"]), {
            "schema_version", "target", "module_name", "ip_name", "port_count",
            "address_width", "clock_mode", "configuration_mode", "port_clock_hz",
            "target_period_cycles", "min_period_cycles", "read_latency",
            "selftest_enabled", "selftest_block_words", "refresh_cycles", "zq_periods", "ports",
        })
        self.assertEqual(set(schema["fields"]["port"]), {"width", "byte_enable", "enabled", "base_beats", "size_lanes"})
        self.assertEqual(schema["fields"]["global"]["port_count"], {
            "type": "integer", "min": 1, "max": 64, "unit": "physical ports",
        })
        self.assertEqual(schema["fields"]["global"]["port_clock_hz"]["unit"], "Hz")
        self.assertEqual(schema["fields"]["port"]["width"]["max"], 512)
        self.assertEqual(schema["fields"]["port"]["base_beats"]["bits"], 34)
        self.assertIn("module", schema["fields"]["global"]["module_name"]["reserved_words"])
        self.assertEqual((schema["ui_hz"], schema["lane_bytes"], schema["beat_bytes"]), (300_000_000, 4, 64))
        self.assertEqual(schema["lanes_per_beat"], 16)
        self.assertIs(schema["capabilities"]["depth_capacity"], True)
        self.assertIs(schema["capabilities"]["automatic_addressing"], True)

    def test_analyze_data_text_warnings_and_structural_errors(self):
        warning = config_to_dict(replace(default_config(), refresh_cycles=3000))
        response = analyze_data(warning)
        self.assertTrue(response["valid"])
        self.assertIsNotNone(response["analysis"])
        self.assertIn("W_REFRESH_INTERVAL", {item["code"] for item in response["diagnostics"]})

        response = analyze_data({"unknown": True})
        self.assertIsNone(response["config"])
        self.assertIsNone(response["analysis"])
        self.assert_diagnostic(response, "E_UNKNOWN_FIELD", "unknown")
        for text in ('{"port_count": 1, "port_count": 2}', '{bad'):
            with self.subTest(text=text):
                response = analyze_text(text)
                self.assertIsNone(response["config"])
                self.assert_diagnostic(response, "E_JSON")
        response = analyze_text(dumps_config(default_config()))
        self.assertEqual(response["config"], config_to_dict(default_config()))
        self.assertTrue(response["valid"])

    def test_depth_metadata_is_available_for_invalid_configuration_repair(self):
        response = analyze_data({"address_width": 0})
        self.assertFalse(response["valid"])
        self.assertIsNone(response["analysis"])
        self.assertEqual(response["depths"], [c.PORT_SIZE_DEFAULT])

        response = analyze_data({"ports": [{"width": 513}]})
        self.assertFalse(response["valid"])
        self.assertEqual(response["depths"], [None])
        response = analyze_data({"unknown": True})
        self.assertIsNone(response["depths"])

    def test_derive_periods_discards_explicit_raw_values(self):
        response = derive_periods({
            "port_clock_hz": 100_000,
            "target_period_cycles": 2500,
            "min_period_cycles": 2600,
        })
        self.assertTrue(response["valid"])
        self.assertEqual(response["config"]["target_period_cycles"], 3000)
        self.assertEqual(response["config"]["min_period_cycles"], 3000)
        self.assertEqual(response["analysis"]["clock"]["target_period_cycles"], 3000)

    def test_resize_preserves_records_and_defaults_new_ports(self):
        original = config_to_dict(default_config())
        original["ports"][0]["width"] = 40
        grown = resize(original, 3)
        self.assertTrue(grown["valid"])
        self.assertEqual(grown["config"]["ports"][0]["width"], 40)
        self.assertEqual(grown["config"]["ports"][1]["base_beats"], 1 << 18)
        self.assertEqual(grown["config"]["ports"][2]["size_lanes"], c.PORT_SIZE_DEFAULT)
        shrunk = resize(grown["config"], 1)
        self.assertEqual(shrunk["config"]["ports"], [grown["config"]["ports"][0]])
        for count in (True, 0, 65, "2"):
            with self.subTest(count=count):
                self.assertFalse(resize({}, count)["valid"])

    def test_depth_edits_normalize_only_explicit_ports_and_preserve_raw_tail_behavior(self):
        config = replace(default_config(), ports=(replace(default_port(0), width=40, base_beats=99, size_lanes=5),))
        raw = analyze_data(config_to_dict(config))
        self.assertTrue(raw["valid"])
        self.assertEqual(raw["config"]["ports"][0]["size_lanes"], 5)
        self.assertEqual(raw["analysis"]["ports"][0]["capacity_words"], 2)
        self.assertEqual(raw["analysis"]["ports"][0]["size_tail_lanes"], 1)

        edited = apply_depth_edits(raw["config"], {"0": 3})
        self.assertTrue(edited["valid"])
        self.assertEqual(edited["config"]["ports"][0]["size_lanes"], 6)
        self.assertEqual(edited["config"]["ports"][0]["base_beats"], 99)
        self.assertEqual(edited["analysis"]["ports"][0]["capacity_words"], 3)
        self.assertEqual(edited["analysis"]["ports"][0]["size_tail_lanes"], 0)
        for changes in ({"00": 1}, {"x": 1}, {"0": True}, {"1": 1}, [], {0: 1}):
            with self.subTest(changes=changes):
                response = apply_depth_edits({}, changes)
                self.assertIsNone(response["config"])
                self.assertFalse(response["valid"])

    def test_allocate_returns_analysis_and_post_transform_semantic_diagnostics(self):
        config = resize_ports(default_config(), 2)
        config = replace(config, address_width=8)
        config = replace(config, ports=(replace(config.ports[0], width=40), replace(config.ports[1], enabled=False)))
        response = allocate(config_to_dict(config), [17, 3])
        self.assertTrue(response["valid"], response["diagnostics"])
        self.assertEqual([port["size_lanes"] for port in response["config"]["ports"]], [34, 3])
        self.assertEqual([port["base_beats"] for port in response["config"]["ports"]], [0, 3])
        self.assertEqual(response["analysis"]["ports"][0]["capacity_words"], 17)
        self.assertEqual(response["analysis"]["ports"][1]["capacity_words"], 3)
        self.assertFalse(response["analysis"]["ports"][1]["enabled"])
        self.assertFalse(allocate({}, [])["valid"])

        aw = config_to_dict(replace(default_config(), address_width=1))
        self.assert_diagnostic(apply_depth_edits(aw, {"0": 3}), "E_AW_REACH", "ports[0].size_lanes")
        selftest = config_to_dict(replace(default_config(), selftest_enabled=True))
        self.assert_diagnostic(apply_depth_edits(selftest, {"0": 1}), "E_SELFTEST_CAPACITY", "selftest_block_words")
        narrow = config_to_dict(replace(default_config(), selftest_enabled=True, ports=(replace(default_port(0), width=40),)))
        self.assert_diagnostic(apply_depth_edits(narrow, {"0": 1}), "E_SELFTEST_WIDTH", "ports[0].width")

        overlapped = resize_ports(default_config(), 2)
        overlapped = replace(overlapped, ports=(overlapped.ports[0], replace(overlapped.ports[1], base_beats=0)))
        self.assert_diagnostic(apply_depth_edits(config_to_dict(overlapped), {"0": 1}), "E_ADDRESS_OVERLAP")

    def test_preview_matches_artifacts_and_rejects_invalid_or_binary(self):
        response = preview({})
        self.assertTrue(response["valid"])
        reference = generate_artifacts(default_config())
        self.assertEqual(list(response["artifacts"]), list(reference))
        self.assertEqual(response["artifacts"], {name: data.decode("utf-8") for name, data in reference.items()})
        minimal = preview({}, full_copy=False)
        minimal_reference = generate_artifacts(default_config(), full_copy=False)
        self.assertEqual(minimal["artifacts"], {
            name: data.decode("utf-8") for name, data in minimal_reference.items()
        })
        self.assertIs(json.loads(minimal["artifacts"]["manifest.json"])["full_copy"], False)
        invalid = preview({"address_width": 0})
        self.assertFalse(invalid["valid"])
        self.assertIsNone(invalid["artifacts"])
        self.assertIsNotNone(invalid["module"])
        with patch("hades_sram_gen.service.generate_artifacts", return_value={"bad.bin": b"\xff"}):
            binary = preview({})
        self.assert_diagnostic(binary, "E_ARTIFACT_ENCODING", "bad.bin")
        self.assertIsNone(binary["artifacts"])
        self.assertIsNotNone(binary["module"])

    def test_module_metadata_matches_wrapper_groups_and_resolved_widths(self):
        config = resize_ports(default_config(), 2)
        config = replace(config, ports=(
            replace(config.ports[0], width=13),
            replace(config.ports[1], width=300),
        ))
        response = analyze_data(config_to_dict(config))
        self.assertTrue(response["valid"], response["diagnostics"])
        module = response["module"]
        self.assertEqual(set(module), {"name", "groups"})
        self.assertEqual(module["name"], config.module_name)
        groups = module["groups"]
        self.assertEqual([group["id"] for group in groups], [
            "clock_reset", "sram0", "sram1", "m_axi", "maintenance", "s_axil",
        ])
        for group in groups:
            self.assertEqual(set(group), {"id", "label", "clock_domain", "expanded", "signals"})
            self.assertIs(group["expanded"], group["id"] == "clock_reset")
            for signal in group["signals"]:
                self.assertEqual(set(signal), {"name", "direction", "width", "description"})
                self.assertIn(signal["direction"], {"in", "out"})
                self.assertIsInstance(signal["width"], str)
                self.assertTrue(signal["description"])
        common = groups[0]
        self.assertEqual(common["clock_domain"], "ui_clk / port_clk")
        self.assertEqual([signal["name"] for signal in common["signals"]], [
            "ui_clk", "ui_rst_n", "port_clk", "port_rst_n", "calib_done",
        ])
        self.assertEqual([signal["description"] for signal in common["signals"]], [
            "300 MHz MIG user clock for backend logic.",
            "Active-low synchronous reset for the ui_clk domain.",
            "Shared clock for all external SRAM ports.",
            "Active-low synchronous reset for the port_clk domain.",
            "MIG calibration-complete indication.",
        ])
        for index, width in ((0, "13"), (1, "300")):
            group = groups[index + 1]
            self.assertEqual(group["clock_domain"], "port_clk")
            self.assertEqual([signal["name"] for signal in group["signals"]], [
                f"sram{index}_en", f"sram{index}_we", f"sram{index}_addr",
                f"sram{index}_wdata", f"sram{index}_be", f"sram{index}_rdata",
                f"sram{index}_rvalid",
            ])
            self.assertEqual([signal["direction"] for signal in group["signals"]], [
                "in", "in", "in", "in", "in", "out", "out",
            ])
            self.assertEqual([signal["width"] for signal in group["signals"]], [
                "1", "1", "22", width, "64", width, "1",
            ])
        axi = groups[3]
        self.assertEqual(axi["clock_domain"], "ui_clk")
        self.assertEqual(len(axi["signals"]), 29)
        axi_by_name = {signal["name"]: signal for signal in axi["signals"]}
        self.assertEqual(axi_by_name["m_axi_awaddr"]["width"], "40")
        self.assertEqual(axi_by_name["m_axi_rdata"]["direction"], "in")
        self.assertEqual(axi_by_name["m_axi_rdata"]["width"], "512")
        self.assertEqual(len(groups[4]["signals"]), 4)
        self.assertEqual(len(groups[5]["signals"]), 17)
        self.assertEqual(groups[5]["signals"][0]["name"], "s_axil_awaddr")
        self.assertEqual(groups[5]["signals"][0]["direction"], "in")
        wrapper = generate_artifacts(config, False)[f"logical/{config.module_name}.sv"].decode("utf-8")
        for signal in [signal for group in groups for signal in group["signals"]]:
            self.assertRegex(wrapper, rf"\b{signal['name']}\b")

        static = analyze_data({**config_to_dict(config), "configuration_mode": "STATIC"})
        self.assertTrue(static["valid"], static["diagnostics"])
        static_ids = [group["id"] for group in static["module"]["groups"]]
        self.assertEqual(static_ids[-1], "static_io")
        self.assertNotIn("s_axil", static_ids)
        self.assertEqual(len(static["module"]["groups"][-1]["signals"]), 12)

    def test_module_metadata_is_bounded_and_null_on_structural_failures(self):
        maximum = analyze_data(config_to_dict(resize_ports(default_config(), 64)))
        self.assertTrue(maximum["valid"], maximum["diagnostics"])
        self.assertEqual(len(maximum["module"]["groups"]), 68)
        self.assertEqual(sum(
            len(group["signals"]) for group in maximum["module"]["groups"]
            if group["id"].startswith("sram")
        ), 64 * 7)
        for raw in (
            {"unknown": True}, {"port_count": 0}, {"port_count": 65},
            {"configuration_mode": "invalid"}, {"ports": []},
        ):
            with self.subTest(raw=raw):
                self.assertIsNone(analyze_data(raw)["module"])
        self.assertIsNone(analyze_text("{bad")["module"])
        self.assertIsNotNone(analyze_data({"address_width": 0})["module"])
        failed_transform = resize({}, 0)
        self.assertIsNone(failed_transform["config"])
        self.assertIsNotNone(failed_transform["module"])
        self.assertIsNotNone(apply_depth_edits({}, {"bad": 1})["module"])

    def test_save_atomic_overwrite_and_invalid_safety(self):
        path = self.directory / "nested" / "config.json"
        response = save_config({}, path)
        self.assertTrue(response["valid"])
        self.assertTrue(response["saved"])
        self.assertEqual(response["path"], str(path))
        self.assertEqual(path.read_bytes(), dumps_config(default_config()).encode("utf-8"))
        original = path.read_bytes()
        response = save_config({"module_name": "changed"}, path)
        self.assertFalse(response["valid"])
        self.assertFalse(response["saved"])
        self.assertEqual(path.read_bytes(), original)
        response = save_config({"module_name": "changed"}, path, force=True)
        self.assertTrue(response["saved"])
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["module_name"], "changed")
        invalid = self.directory / "invalid.json"
        response = save_config({"address_width": 0}, invalid)
        self.assertFalse(response["saved"])
        self.assertFalse(invalid.exists())
        path.write_bytes(b"preserve\n")
        save_config({"address_width": 0}, path, force=True)
        self.assertEqual(path.read_bytes(), b"preserve\n")

    def test_generate_check_force_stale_and_artifact_parity(self):
        output = self.directory / "generated"
        response = generate({}, output)
        self.assertEqual(response["outcome"], "generated")
        self.assertTrue(response["generated"])
        self.assertFalse(response["checked"])
        self.assertEqual(response["status"], 0)
        reference = generate_artifacts(default_config())
        self.assertEqual(output_files(output), dict(reference))
        before = output_files(output)
        response = generate({}, output)
        self.assertEqual(response["outcome"], "error")
        self.assertEqual(response["status"], 1)
        self.assertFalse(response["generated"])
        self.assertEqual(output_files(output), before)

        response = generate({"configuration_mode": "STATIC"}, output, force=True)
        self.assertTrue(response["generated"])
        self.assertFalse((output / "csr_init.tcl").exists())
        response = generate({"configuration_mode": "STATIC"}, output, check=True)
        self.assertEqual(response["outcome"], "checked")
        self.assertTrue(response["checked"])
        summary = output / "report/summary.txt"
        summary.write_bytes(summary.read_bytes() + b"local edit\n")
        response = generate({"configuration_mode": "STATIC"}, output, check=True)
        self.assertEqual(response["status"], 1)
        self.assertEqual(response["outcome"], "error")
        self.assertIn("changed artifact: report/summary.txt", response["problems"])
        self.assertTrue(summary.read_bytes().endswith(b"local edit\n"))
        invalid = self.directory / "invalid-output"
        response = generate({"address_width": 0}, invalid)
        self.assertFalse(response["valid"])
        self.assertFalse(response["generated"])
        self.assertFalse(invalid.exists())

    def test_full_copy_transition_checks_stale_and_preserves_unmanaged_files(self):
        output = self.directory / "copy-transition"
        self.assertTrue(generate({}, output)["generated"])
        unmanaged = {
            "user.txt": b"root user file\n",
            "logical/user.sv": b"// user source\n",
            "docs/user.md": b"user documentation\n",
        }
        for name, data in unmanaged.items():
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        before = output_files(output)
        checked = generate({}, output, check=True, full_copy=False)
        self.assertEqual(checked["status"], 1)
        self.assertIn("stale managed artifact: static_rtl.f", checked["problems"])
        self.assertIn("stale managed artifact: logical/hades_sram_top.sv", checked["problems"])
        self.assertIn("changed artifact: manifest.json", checked["problems"])
        self.assertEqual(output_files(output), before)

        generated = generate({}, output, force=True, full_copy=False)
        self.assertTrue(generated["generated"], generated["diagnostics"])
        expected = dict(generate_artifacts(default_config(), full_copy=False))
        expected.update(unmanaged)
        self.assertEqual(output_files(output), expected)
        self.assertFalse((output / "static_rtl.f").exists())
        self.assertFalse((output / "logical/hades_sram_top.sv").exists())
        self.assertFalse((output / "constraints/hades_sram_clocks_sync.xdc").exists())
        self.assertFalse((output / "docs/INTEGRATION_GUIDE.md").exists())
        self.assertTrue((output / "constraints/sram0_strict.xdc").is_file())
        self.assertIs(json.loads((output / "manifest.json").read_text())["full_copy"], False)
        self.assertEqual(generate({}, output, check=True, full_copy=False)["outcome"], "checked")

    def test_service_apis_keep_stdout_clean(self):
        stream = io.StringIO()
        with redirect_stdout(stream):
            generator_schema()
            analyze_data({})
            derive_periods({})
            resize({}, 1)
            apply_depth_edits({}, {"0": 1})
            allocate({}, [1])
            preview({})
            save_config({}, self.directory / "quiet.json")
            generate({}, self.directory / "quiet-generated")
        self.assertEqual(stream.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
