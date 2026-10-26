import hashlib
import json
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen import contract as c
from hades_sram_gen.emit_tcl import emit_configure_ip, emit_csr_init
from hades_sram_gen.generate import generate_artifacts
from hades_sram_gen.model import ConfigError, default_config, dumps_config, resize_ports
from hades_sram_gen.output import generate_files
from hades_sram_gen.payload import (
    CONSTRAINT_NAMES,
    PAYLOAD_ENTRIES,
    RTL_NAMES,
    stage_payload,
)

GRAPH_NAMES = tuple(
    f"report/{name}"
    for name in ("overview.svg", "timing.svg", "slot_budget.svg", "memory_map.svg", "bandwidth.svg")
)


def text(artifacts, name):
    return artifacts[name].decode("utf-8")


def write_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def make_packaged_payload(root):
    for name in RTL_NAMES:
        write_bytes(root / "src" / name, (ROOT / "rtl" / name).read_bytes())
    for name in CONSTRAINT_NAMES:
        write_bytes(root / "doc" / name, (ROOT / "constraints" / name).read_bytes())
    write_bytes(root / "doc/INTEGRATION_GUIDE.md", (ROOT / "INTEGRATION_GUIDE.md").read_bytes())
    write_bytes(root / "doc/csr_regmap.md", (ROOT / "csr/csr_regmap.md").read_bytes())


class ArtifactTests(unittest.TestCase):
    def expected_names(self, config, full_copy=True):
        names = [
            "config.json",
            "logical/hades_sram_config_pkg.sv",
            f"logical/{config.module_name}.sv",
            "wrapper.f",
        ]
        if config.target == "ip":
            names.append("configure_ip.tcl")
        if config.configuration_mode == "CSR":
            names.append("csr_init.tcl")
        names += ["report/analysis.json", "report/summary.txt", "report/report.html", *GRAPH_NAMES]
        names += [f"constraints/sram{index}_strict.xdc" for index in range(config.port_count)]
        if full_copy:
            names += [entry.destination for entry in PAYLOAD_ENTRIES]
            names.append("static_rtl.f")
        names.append("manifest.json")
        return names

    def test_default_artifact_order_types_and_config(self):
        config = default_config()
        artifacts = generate_artifacts(config)
        self.assertEqual(list(artifacts), self.expected_names(config))
        self.assertTrue(all(isinstance(data, bytes) for data in artifacts.values()))
        self.assertEqual(artifacts["config.json"], dumps_config(config).encode("utf-8"))
        self.assertNotIn("full_copy", json.loads(artifacts["config.json"]))
        analysis = json.loads(artifacts["report/analysis.json"])
        self.assertEqual(analysis["diagnostics"], [])
        self.assertIs(analysis["analytical_only"], True)
        self.assertNotIn("configure_ip.tcl", artifacts)

    def test_mode_dependent_artifacts(self):
        ip = replace(default_config(), target="ip")
        ip_artifacts = generate_artifacts(ip)
        self.assertEqual(list(ip_artifacts), self.expected_names(ip))
        self.assertIn("configure_ip.tcl", ip_artifacts)
        static = replace(default_config(), configuration_mode="STATIC")
        static_artifacts = generate_artifacts(static)
        self.assertEqual(list(static_artifacts), self.expected_names(static))
        self.assertNotIn("csr_init.tcl", static_artifacts)

    def test_opt_out_has_only_configuration_artifacts(self):
        config = default_config()
        artifacts = generate_artifacts(config, full_copy=False)
        self.assertEqual(list(artifacts), self.expected_names(config, full_copy=False))
        self.assertNotIn("static_rtl.f", artifacts)
        self.assertEqual(
            [name for name in artifacts if name.startswith("logical/")],
            ["logical/hades_sram_config_pkg.sv", f"logical/{config.module_name}.sv"],
        )
        self.assertFalse(any(name.startswith("docs/") for name in artifacts))
        self.assertEqual(
            [name for name in artifacts if name.startswith("constraints/")],
            ["constraints/sram0_strict.xdc"],
        )
        self.assertIs(json.loads(artifacts["manifest.json"])["full_copy"], False)

    def test_determinism_and_manifest_hashes(self):
        config = replace(resize_ports(default_config(), 3), target="ip")
        first = generate_artifacts(config)
        second = generate_artifacts(config)
        self.assertEqual(first, second)
        self.assertEqual(list(first), list(second))
        manifest = json.loads(first["manifest.json"])
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["module_name"], config.module_name)
        self.assertEqual(manifest["target"], config.target)
        self.assertIs(manifest["full_copy"], True)
        self.assertEqual([item["path"] for item in manifest["files"]], list(first)[:-1])
        self.assertNotIn("manifest.json", {item["path"] for item in manifest["files"]})
        for item in manifest["files"]:
            with self.subTest(path=item["path"]):
                self.assertEqual(item["sha256"], hashlib.sha256(first[item["path"]]).hexdigest())
                self.assertRegex(item["sha256"], r"^[0-9a-f]{64}$")

    def test_filelists_and_exact_maintained_source_bytes(self):
        config = default_config()
        artifacts = generate_artifacts(config)
        self.assertEqual(text(artifacts, "wrapper.f").splitlines(), [
            "logical/hades_sram_config_pkg.sv",
            f"logical/{config.module_name}.sv",
        ])
        self.assertEqual(
            text(artifacts, "static_rtl.f").splitlines(),
            [f"logical/{name}" for name in RTL_NAMES],
        )
        for name in RTL_NAMES:
            with self.subTest(rtl=name):
                self.assertEqual(artifacts[f"logical/{name}"], (ROOT / "rtl" / name).read_bytes())
        for name in CONSTRAINT_NAMES:
            with self.subTest(constraint=name):
                self.assertEqual(artifacts[f"constraints/{name}"], (ROOT / "constraints" / name).read_bytes())
        self.assertEqual(artifacts["docs/INTEGRATION_GUIDE.md"], (ROOT / "INTEGRATION_GUIDE.md").read_bytes())
        self.assertEqual(artifacts["docs/csr_regmap.md"], (ROOT / "csr/csr_regmap.md").read_bytes())

    def test_packaged_and_staged_payloads_are_byte_identical(self):
        config = replace(default_config(), module_name="payload_parity")
        reference = generate_artifacts(config)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            packaged = root / "packaged"
            make_packaged_payload(packaged)
            self.assertEqual(generate_artifacts(config, payload_source=packaged), reference)
            with patch(
                "hades_sram_gen.payload.__file__",
                str(packaged / "tools/hades_sram_gen/payload.py"),
            ):
                self.assertEqual(generate_artifacts(config), reference)
            staged = root / "provider/payload"
            self.assertEqual(stage_payload(staged, packaged), len(PAYLOAD_ENTRIES))
            self.assertEqual(generate_artifacts(config, payload_source=staged), reference)
            with patch(
                "hades_sram_gen.payload.__file__",
                str(root / "provider/hades_sram_gen/payload.py"),
            ):
                self.assertEqual(generate_artifacts(config), reference)
            for entry in PAYLOAD_ENTRIES:
                with self.subTest(staged=entry.canonical):
                    self.assertEqual((staged / entry.canonical).read_bytes(), reference[entry.destination])

    def test_missing_payload_is_structured_and_precedes_all_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            packaged = root / "packaged"
            make_packaged_payload(packaged)
            (packaged / "src" / RTL_NAMES[0]).unlink()
            output = root / "output"
            output.mkdir()
            (output / "unmanaged.txt").write_bytes(b"preserve\n")
            with self.assertRaises(ConfigError) as caught:
                generate_files(
                    default_config(), output, check=False, force=True,
                    payload_source=packaged,
                )
            self.assertIn("E_PAYLOAD_MISSING", {item.code for item in caught.exception.diagnostics})
            self.assertEqual([path.name for path in output.iterdir()], ["unmanaged.txt"])
            self.assertEqual((output / "unmanaged.txt").read_bytes(), b"preserve\n")
            self.assertEqual(
                list(generate_artifacts(default_config(), False, payload_source=packaged)),
                self.expected_names(default_config(), full_copy=False),
            )

    def test_invalid_generation_raises_config_error(self):
        config = replace(default_config(), address_width=0)
        with self.assertRaises(ConfigError) as caught:
            generate_artifacts(config)
        self.assertTrue(any(d.code == "E_AW_RANGE" and d.path == "address_width" for d in caught.exception.diagnostics))

    def test_reports_state_analytical_only(self):
        artifacts = generate_artifacts(default_config())
        summary = text(artifacts, "report/summary.txt")
        report = text(artifacts, "report/report.html")
        self.assertIn("configuration and analytical timing", summary)
        self.assertIn("not post-route WNS/TNS", summary)
        self.assertIn("Analytical model only.", report)
        self.assertIn("not contain post-route WNS/TNS", report)


class ConstraintEmissionTests(unittest.TestCase):
    def test_every_physical_port_has_exact_straight_line_constraints(self):
        config = resize_ports(default_config(), 64)
        config = replace(config, ports=tuple(
            replace(port, width=(13 if index == 0 else 300 if index == 63 else port.width), enabled=index % 2 == 0)
            for index, port in enumerate(config.ports)
        ))
        artifacts = generate_artifacts(config, full_copy=False)
        names = [name for name in artifacts if name.startswith("constraints/")]
        self.assertEqual(names, [f"constraints/sram{index}_strict.xdc" for index in range(64)])
        for index in range(64):
            with self.subTest(port=index):
                name = f"constraints/sram{index}_strict.xdc"
                script = text(artifacts, name)
                self.assertTrue(name.endswith(".xdc"))
                self.assertFalse(name.endswith(".xpr"))
                inputs = (
                    f"sram{index}_en sram{index}_we "
                    f"{{sram{index}_addr[*]}} {{sram{index}_wdata[*]}} {{sram{index}_be[*]}}"
                )
                outputs = f"{{sram{index}_rdata[*]}} sram{index}_rvalid"
                self.assertIn(f"set sram{index}_port_clk [get_clocks -of_objects [get_ports port_clk]]", script)
                for direction in ("input", "output"):
                    for bound in ("max", "min"):
                        self.assertIn(f"set sram{index}_{direction}_delay_{bound}_ns 0.000", script)
                self.assertIn(f"set_input_delay -clock $sram{index}_port_clk -max $sram{index}_input_delay_max_ns [get_ports [list {inputs}]]", script)
                self.assertIn(f"set_input_delay -clock $sram{index}_port_clk -min $sram{index}_input_delay_min_ns [get_ports [list {inputs}]]", script)
                self.assertIn(f"set_output_delay -clock $sram{index}_port_clk -max $sram{index}_output_delay_max_ns [get_ports [list {outputs}]]", script)
                self.assertIn(f"set_output_delay -clock $sram{index}_port_clk -min $sram{index}_output_delay_min_ns [get_ports [list {outputs}]]", script)
                self.assertEqual(len(re.findall(r"(?m)^set_input_delay ", script)), 2)
                self.assertEqual(len(re.findall(r"(?m)^set_output_delay ", script)), 2)
                self.assertNotRegex(script, r"(?m)^\s*(if|foreach|for|proc)\s")
                for forbidden in ("-quiet", "set_false_path", "set_multicycle_path", "set_clock_groups", "get_cells"):
                    self.assertNotIn(forbidden, script)


class SystemVerilogEmissionTests(unittest.TestCase):
    def test_direct_and_packaged_wrapper_boundaries(self):
        direct = generate_artifacts(default_config())
        direct_wrapper = text(direct, "logical/hades_sram_user.sv")
        self.assertIn("hades_sram_top #(", direct_wrapper)
        self.assertIn(") u_hades_sram (", direct_wrapper)
        for index in range(1, 64):
            self.assertIn(f".sram{index}_en(1'b0)", direct_wrapper)
            self.assertIn(f".sram{index}_wdata('0)", direct_wrapper)
            self.assertIn(f".sram{index}_rdata()", direct_wrapper)
        ip = replace(default_config(), target="ip", ip_name="hades_custom_0")
        ip_wrapper = text(generate_artifacts(ip), "logical/hades_sram_user.sv")
        self.assertNotIn("hades_sram_top #(", ip_wrapper)
        self.assertIn("hades_custom_0 u_hades_sram (", ip_wrapper)
        self.assertNotIn(".sram1_en(1'b0)", ip_wrapper)
        self.assertNotIn(".sram1_", ip_wrapper)

    def test_width_one_and_all_direct_parameter_assignments(self):
        config = replace(default_config(), ports=(replace(default_config().ports[0], width=1, byte_enable=True),))
        artifacts = generate_artifacts(config)
        package = text(artifacts, "logical/hades_sram_config_pkg.sv")
        wrapper = text(artifacts, "logical/hades_sram_user.sv")
        self.assertIn("localparam int W0 = 1;", package)
        self.assertIn("localparam bit BE0_EN = 1'b1;", package)
        self.assertIn("input  wire [W0-1:0] sram0_wdata", wrapper)
        self.assertIn("output logic [W0-1:0] sram0_rdata", wrapper)
        for index in range(64):
            self.assertIn(f"localparam int W{index} =", package)
            self.assertIn(f"localparam bit BE{index}_EN =", package)
            self.assertIn(f".W{index}(W{index})", wrapper)
            self.assertIn(f".BE{index}_EN(BE{index}_EN)", wrapper)

    def test_static_parameters_only_override_static_core(self):
        fields = ("P_L", "P_PORT_EN", "P_MIN_PERIOD", "P_REFRESH_DIV", "P_ZQ_DIV", "P_PORT_BASE", "P_PORT_SIZE")
        csr = replace(default_config(), target="rtl")
        csr_wrapper = text(generate_artifacts(csr), "logical/hades_sram_user.sv")
        static = replace(csr, configuration_mode="STATIC")
        static_wrapper = text(generate_artifacts(static), "logical/hades_sram_user.sv")
        for field in fields:
            with self.subTest(field=field):
                self.assertNotIn(f".{field}({field})", csr_wrapper)
                self.assertIn(f".{field}({field})", static_wrapper)
        for target in ("rtl", "ip"):
            config = replace(static, target=target)
            configure = emit_configure_ip(config)
            for field in fields:
                self.assertIn(f'hades_set "{field}"', configure)
            self.assertNotIn("csr_init.tcl", generate_artifacts(config))


class TclEmissionTests(unittest.TestCase):
    def test_configure_ip_ordered_updates(self):
        config = replace(resize_ports(default_config(), 2), target="ip", clock_mode="ASYNC", selftest_enabled=True)
        config = replace(config, ports=(replace(config.ports[0], width=13, byte_enable=True), config.ports[1]))
        script = emit_configure_ip(config)
        names = re.findall(r'hades_set "([^"]+)"', script)
        expected = ["N", "AW", "IS_SYNC", "CSR_EN", "SELFTEST_EN", "SELFTEST_BLK", "TARGET_PERIOD_CYCLES"]
        for port in config.ports:
            index = config.ports.index(port)
            expected += [f"W{index}", f"BE{index}_EN"]
        self.assertEqual(names, expected)
        self.assertIn('hades_set "IS_SYNC" "false" $hades_ip', script)
        self.assertIn('hades_set "SELFTEST_EN" "true" $hades_ip', script)
        self.assertIn('hades_set "W0" "13" $hades_ip', script)
        self.assertIn('hades_set "BE0_EN" "true" $hades_ip', script)
        self.assertIn(c.VLNV, script)
        self.assertIn("create_ip -name hades_sram -vendor rismd.cn -library hades -version 1.1", script)
        self.assertNotIn('hades_set "W2"', script)

    def test_csr_init_id_masks_runtime_limit_and_width_readbacks(self):
        config = resize_ports(default_config(), 3)
        ports = tuple(replace(port, enabled=index != 1) for index, port in enumerate(config.ports))
        config = replace(config, ports=ports)
        script = emit_csr_init(config)
        self.assertIn("hades_sram_expect $read_cmd $base 0x0080 0xADE50110", script)
        for offset, value in (
            (c.CSR_CFG_PORTS, 3),
            (c.CSR_PORT_EN_LO, 5),
            (c.CSR_PORT_EN_HI, 0),
            (c.CSR_CFG_MIN_PERIOD, config.min_period_cycles),
            (c.CSR_CFG_REFRESH_DIV, config.refresh_cycles),
            (c.CSR_CFG_ZQ_DIV, config.zq_periods),
        ):
            expected = f"0x{offset:04X} 0x{value:08X}"
            with self.subTest(offset=offset):
                self.assertIn(f"hades_sram_write $write_cmd $base {expected}", script)
                self.assertIn(f"hades_sram_expect $read_cmd $base {expected}", script)
        for index, port in enumerate(config.ports):
            self.assertIn(f"hades_sram_write $write_cmd $base 0x{c.CSR_PORT_SEL:04X} {index}", script)
            self.assertIn(f"hades_sram_expect $read_cmd $base 0x003C 0x{port.width:08X}", script)
        self.assertIn("HADES_CSR_INIT_PASS: N=3 L=2 PORT_HZ=500000", script)

    def test_sourcing_csr_script_defines_procedures_without_hardware_access(self):
        script = emit_csr_init(default_config())
        self.assertIn("Sourcing only defines the procedures", script)
        self.assertNotRegex(script, r"(?m)^hades_sram_init\s")
        for command in ("open_hw", "connect_hw_server", "create_hw_target", "refresh_hw_device"):
            self.assertNotIn(command, script)
        self.assertIn("proc hades_sram_init {write_cmd read_cmd", script)


class SvgEmissionTests(unittest.TestCase):
    def test_all_graphs_are_xml_and_scaled_graphs_have_domains(self):
        config = resize_ports(default_config(), 2)
        artifacts = generate_artifacts(config)
        expected_graphs = {
            "report/overview.svg": "overview",
            "report/timing.svg": "timing",
            "report/slot_budget.svg": "slot_budget",
            "report/memory_map.svg": "memory_map",
            "report/bandwidth.svg": "bandwidth",
        }
        for name, graph in expected_graphs.items():
            with self.subTest(name=name):
                root = ET.fromstring(artifacts[name])
                self.assertEqual(root.tag, "{http://www.w3.org/2000/svg}svg")
                self.assertEqual(root.attrib.get("role"), "img")
                self.assertEqual(root.attrib.get("data-graph"), graph)
                if graph != "overview":
                    self.assertEqual(root.attrib.get("data-domain-min"), "0")
                    self.assertGreater(float(root.attrib["data-domain-max"]), 0)
                    self.assertGreater(float(root.attrib["data-plot-width"]), 0)
                    self.assertIn("data-domain-unit", root.attrib)
        timing = ET.fromstring(artifacts["report/timing.svg"])
        self.assertEqual(timing.attrib["data-domain-max"], "4")
        self.assertEqual(timing.attrib["data-domain-unit"], "port_clk cycles")
        self.assertEqual(float(timing.attrib["data-time-scale-ns"]), 2000.0)
        slots = ET.fromstring(artifacts["report/slot_budget.svg"])
        self.assertEqual(slots.attrib["data-domain-max"], "600")
        port_groups = [element for element in slots.iter() if element.attrib.get("data-port") is not None]
        self.assertEqual({element.attrib["data-port"] for element in port_groups}, {"0", "1"})


if __name__ == "__main__":
    unittest.main()
