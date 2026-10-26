import json
import sys
import unittest
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen import contract as c
from hades_sram_gen.analyze import analyze_config
from hades_sram_gen.model import (
    ConfigError,
    config_to_dict,
    decode_config,
    default_config,
    default_port,
    dumps_config,
    loads_config,
    resize_ports,
)
from hades_sram_gen.parameters import (
    expanded_ports,
    flat_vectors,
    port_enable_mask,
    runtime_active_limit,
)
from hades_sram_gen.validate import backend_window_beats, has_errors, lane_count, validate_config


class ModelTestCase(unittest.TestCase):
    def assertDiagnostic(self, config, code, path=None, severity=None):
        diagnostics = validate_config(config)
        matches = [d for d in diagnostics if d.code == code]
        self.assertTrue(matches, f"missing {code}: {diagnostics}")
        if path is not None:
            self.assertEqual(matches[0].path, path)
        if severity is not None:
            self.assertEqual(matches[0].severity, severity)
        return matches[0]

    def assertValid(self, config):
        diagnostics = validate_config(config)
        self.assertFalse(has_errors(diagnostics), diagnostics)
        return diagnostics


class DecodeTests(ModelTestCase):
    def test_default_and_canonical_roundtrip(self):
        config = default_config()
        text = dumps_config(config)
        self.assertTrue(text.endswith("\n"))
        self.assertEqual(loads_config(text), config)
        self.assertEqual(dumps_config(loads_config(text)), text)
        self.assertEqual(json.loads(text), config_to_dict(config))
        self.assertValid(config)

    def test_clock_cycles_derive_when_overrides_are_omitted(self):
        result = decode_config({"schema_version": 1, "port_clock_hz": 100000})
        self.assertIsNotNone(result.config)
        self.assertEqual(result.config.target_period_cycles, 3000)
        self.assertEqual(result.config.min_period_cycles, 3000)
        result = decode_config({"schema_version": 1, "port_clock_hz": 100000, "target_period_cycles": 2500})
        self.assertEqual(result.config.target_period_cycles, 2500)
        self.assertEqual(result.config.min_period_cycles, 3000)

    def test_duplicate_keys_are_rejected_at_every_object_level(self):
        for text in (
            '{"port_count": 1, "port_count": 2}',
            '{"ports": [{"width": 32, "width": 64}]}',
        ):
            with self.subTest(text=text), self.assertRaises(ConfigError) as caught:
                loads_config(text)
            self.assertEqual(caught.exception.diagnostics[0].code, "E_JSON")
            self.assertIn("Duplicate JSON key", str(caught.exception))

    def test_unknown_fields_and_wrong_container_types(self):
        cases = (
            ([], "$", "E_TYPE_OBJECT"),
            ({"mystery": 1}, "mystery", "E_UNKNOWN_FIELD"),
            ({"ports": {}}, "ports", "E_TYPE_ARRAY"),
            ({"ports": [32]}, "ports[0]", "E_TYPE_OBJECT"),
            ({"ports": [{"mystery": 1}]}, "ports[0].mystery", "E_UNKNOWN_FIELD"),
        )
        for data, path, code in cases:
            with self.subTest(path=path):
                result = decode_config(data)
                self.assertIsNone(result.config)
                diagnostic = next(d for d in result.diagnostics if d.code == code)
                self.assertEqual(diagnostic.path, path)

    def test_wrong_scalar_types_and_bool_as_int(self):
        integer_fields = (
            "schema_version", "port_count", "address_width", "port_clock_hz",
            "target_period_cycles", "min_period_cycles", "selftest_block_words",
            "refresh_cycles", "zq_periods",
        )
        for field in integer_fields:
            for value in (True, 1.5, "1"):
                data = config_to_dict(default_config())
                data[field] = value
                with self.subTest(field=field, value=value):
                    result = decode_config(data)
                    self.assertIsNone(result.config)
                    self.assertTrue(any(d.code == "E_TYPE_INTEGER" and d.path == field for d in result.diagnostics))
        for field in ("width", "base_beats", "size_lanes"):
            data = config_to_dict(default_config())
            data["ports"][0][field] = False
            with self.subTest(field=field):
                result = decode_config(data)
                self.assertTrue(any(d.code == "E_TYPE_INTEGER" and d.path == f"ports[0].{field}" for d in result.diagnostics))
        for field in ("byte_enable", "enabled"):
            data = config_to_dict(default_config())
            data["ports"][0][field] = 1
            with self.subTest(field=field):
                result = decode_config(data)
                self.assertTrue(any(d.code == "E_TYPE_BOOLEAN" and d.path == f"ports[0].{field}" for d in result.diagnostics))
        data = config_to_dict(default_config())
        data["selftest_enabled"] = 0
        self.assertTrue(any(d.code == "E_TYPE_BOOLEAN" for d in decode_config(data).diagnostics))
        data = config_to_dict(default_config())
        data["module_name"] = 7
        self.assertTrue(any(d.code == "E_TYPE_STRING" and d.path == "module_name" for d in decode_config(data).diagnostics))

    def test_schema_choices_and_port_list_length(self):
        result = decode_config({"schema_version": 2})
        self.assertTrue(any(d.code == "E_SCHEMA_VERSION" for d in result.diagnostics))
        for field in ("target", "clock_mode", "configuration_mode"):
            data = config_to_dict(default_config())
            data[field] = "invalid"
            with self.subTest(field=field):
                result = decode_config(data)
                self.assertTrue(any(d.code == "E_CHOICE" and d.path == field for d in result.diagnostics))
        data = config_to_dict(default_config())
        data["port_count"] = 2
        result = decode_config(data)
        self.assertIsNone(result.config)
        self.assertTrue(any(d.code == "E_PORT_LIST_LENGTH" and d.path == "ports" for d in result.diagnostics))

    def test_defaults_and_resize_preserve_existing_ports(self):
        config = decode_config({"port_count": 2}).config
        self.assertEqual(config.ports, (default_port(0), default_port(1)))
        custom = replace(config.ports[0], width=13, byte_enable=True)
        config = replace(config, ports=(custom, config.ports[1]))
        grown = resize_ports(config, 4)
        self.assertEqual(grown.ports[:2], config.ports)
        self.assertEqual(grown.ports[2:], (default_port(2), default_port(3)))
        self.assertEqual(resize_ports(grown, 1).ports, (custom,))


class ValidationTests(ModelTestCase):
    def test_port_count_and_width_boundaries(self):
        for count in (1, 64):
            with self.subTest(count=count):
                self.assertValid(resize_ports(default_config(), count))
        for count in (0, 65):
            with self.subTest(count=count):
                self.assertDiagnostic(resize_ports(default_config(), count), "E_N_RANGE", "port_count")
        lanes = {1: 1, 13: 1, 40: 2, 100: 4, 300: 16, 512: 16}
        for width, expected_lanes in lanes.items():
            with self.subTest(width=width):
                config = replace(default_config(), ports=(replace(default_port(0), width=width),))
                self.assertValid(config)
                self.assertEqual(lane_count(width), expected_lanes)
        for width in (0, 513):
            with self.subTest(width=width):
                config = replace(default_config(), ports=(replace(default_port(0), width=width),))
                self.assertDiagnostic(config, "E_WIDTH_RANGE", "ports[0].width")

    def test_address_width_and_latency_boundaries(self):
        for width in (1, 32):
            with self.subTest(width=width):
                config = replace(default_config(), address_width=width)
                if width == 1:
                    config = replace(config, ports=(replace(config.ports[0], size_lanes=2),))
                self.assertValid(config)
        for width in (0, 33):
            with self.subTest(width=width):
                self.assertDiagnostic(replace(default_config(), address_width=width), "E_AW_RANGE", "address_width")
        for latency in (1, 2):
            with self.subTest(latency=latency):
                self.assertValid(replace(default_config(), read_latency=latency))
        for latency in (0, 3):
            with self.subTest(latency=latency):
                self.assertDiagnostic(replace(default_config(), read_latency=latency), "E_LATENCY", "read_latency")

    def test_identifiers(self):
        for field in ("module_name", "ip_name"):
            for value in ("1bad", "bad-name", "module", "has space"):
                with self.subTest(field=field, value=value):
                    self.assertDiagnostic(replace(default_config(), **{field: value}), "E_IDENTIFIER", field)
        self.assertValid(replace(default_config(), module_name="_valid_9", ip_name="ip_0"))

    def test_selftest_capacity_and_empty_ports(self):
        config = replace(default_config(), selftest_enabled=True, selftest_block_words=5)
        config = replace(config, ports=(replace(config.ports[0], size_lanes=4),))
        self.assertDiagnostic(config, "E_SELFTEST_CAPACITY", "selftest_block_words")
        self.assertValid(replace(config, selftest_block_words=4))
        enabled_empty = replace(default_config(), ports=(replace(default_port(0), size_lanes=0),))
        self.assertDiagnostic(enabled_empty, "E_EMPTY_PORT", "ports[0].size_lanes", "error")
        disabled_empty = replace(default_config(), ports=(replace(default_port(0), size_lanes=0, enabled=False),))
        self.assertDiagnostic(disabled_empty, "W_EMPTY_DISABLED_PORT", "ports[0].size_lanes", "warning")

    def test_base_size_backend_and_overlap_ranges(self):
        for base in (-1, 1 << c.BASE_W):
            with self.subTest(base=base):
                config = replace(default_config(), ports=(replace(default_port(0), base_beats=base),))
                self.assertDiagnostic(config, "E_BASE_RANGE", "ports[0].base_beats")
        for size in (-1, 1 << 32):
            with self.subTest(size=size):
                config = replace(default_config(), ports=(replace(default_port(0), size_lanes=size),))
                self.assertDiagnostic(config, "E_SIZE_RANGE", "ports[0].size_lanes")
        config = replace(default_config(), ports=(replace(default_port(0), base_beats=(1 << c.BASE_W) - 1, size_lanes=32),))
        self.assertDiagnostic(config, "E_BACKEND_OVERFLOW", "ports[0].base_beats")
        self.assertValid(replace(config, ports=(replace(config.ports[0], base_beats=(1 << c.BASE_W) - 2),)))
        config = resize_ports(default_config(), 2)
        self.assertValid(config)
        overlapped = replace(config, ports=(config.ports[0], replace(config.ports[1], base_beats=config.ports[0].base_beats)))
        self.assertDiagnostic(overlapped, "E_ADDRESS_OVERLAP", "ports[1].base_beats")
        self.assertEqual(backend_window_beats(17), 2)

    def test_address_reach_size_tail_and_disabled_overflow(self):
        config = replace(default_config(), address_width=1)
        self.assertDiagnostic(config, "E_AW_REACH", "ports[0].size_lanes")
        config = replace(default_config(), ports=(replace(default_port(0), width=40, size_lanes=5),))
        self.assertDiagnostic(config, "W_SIZE_TAIL", "ports[0].size_lanes", "warning")
        config = replace(default_config(), ports=(replace(default_port(0), enabled=False, base_beats=(1 << c.BASE_W) - 1, size_lanes=32),))
        self.assertDiagnostic(config, "W_DISABLED_BACKEND_OVERFLOW", severity="warning")

    def test_maintenance_intervals(self):
        for field, code in (("refresh_cycles", "E_REFRESH_RANGE"), ("zq_periods", "E_ZQ_RANGE")):
            for value in (0, -1):
                with self.subTest(field=field, value=value):
                    self.assertDiagnostic(replace(default_config(), **{field: value}), code, field)
        self.assertValid(replace(default_config(), refresh_cycles=2340))
        self.assertDiagnostic(replace(default_config(), refresh_cycles=2341), "W_REFRESH_INTERVAL", "refresh_cycles", "warning")

    def test_frequency_ratio_and_target_min_consistency(self):
        low = replace(default_config(), port_clock_hz=100_000, target_period_cycles=3000, min_period_cycles=3000)
        self.assertValid(low)
        self.assertValid(default_config())
        for frequency in (99_999, 500_001):
            with self.subTest(frequency=frequency):
                self.assertDiagnostic(replace(default_config(), port_clock_hz=frequency), "E_PORT_FREQUENCY", "port_clock_hz")
        fractional = replace(default_config(), port_clock_hz=333_333, target_period_cycles=900, min_period_cycles=900)
        self.assertDiagnostic(fractional, "W_FRACTIONAL_RATIO", "port_clock_hz", "warning")
        self.assertNotIn("W_FRACTIONAL_RATIO", {d.code for d in validate_config(replace(default_config(), port_clock_hz=400_000, target_period_cycles=750, min_period_cycles=750))})
        self.assertDiagnostic(replace(default_config(), target_period_cycles=601, min_period_cycles=601), "E_TARGET_OPTIMISTIC", "target_period_cycles")
        self.assertDiagnostic(replace(default_config(), target_period_cycles=500), "W_TARGET_CONSERVATIVE", "target_period_cycles", "warning")
        self.assertDiagnostic(replace(default_config(), min_period_cycles=601), "E_MIN_PERIOD_CLOCK", "min_period_cycles")
        self.assertDiagnostic(replace(default_config(), target_period_cycles=599, min_period_cycles=598), "E_MIN_BELOW_TARGET", "min_period_cycles")
        self.assertDiagnostic(replace(default_config(), min_period_cycles=599), "E_MIN_PERIOD_500K", "min_period_cycles")
        for field, code in (("target_period_cycles", "E_TARGET_PERIOD"), ("min_period_cycles", "E_MIN_PERIOD")):
            self.assertDiagnostic(replace(default_config(), **{field: 0}), code, field)

    def test_strict_slot_budget_equality(self):
        self.assertEqual(analyze_config(default_config())["timing"]["budget_used_cycles"], 294)
        self.assertDiagnostic(replace(default_config(), target_period_cycles=294), "E_SLOT_BUDGET", "target_period_cycles")
        self.assertValid(replace(default_config(), target_period_cycles=295))
        for mode, used in (("SYNC", 546), ("ASYNC", 554)):
            with self.subTest(mode=mode):
                config = replace(resize_ports(default_config(), 64), clock_mode=mode)
                analysis = analyze_config(config)
                self.assertEqual(analysis["timing"]["budget_used_cycles"], used)
                self.assertDiagnostic(replace(config, target_period_cycles=used), "E_SLOT_BUDGET")
                self.assertValid(replace(config, target_period_cycles=used + 1))

    def test_selftest_width_limit(self):
        for width in (32, 64):
            config = replace(default_config(), selftest_enabled=True, ports=(replace(default_port(0), width=width),))
            self.assertValid(config)
        for width in (1, 13, 40, 100, 300, 512):
            config = replace(default_config(), selftest_enabled=True, ports=(replace(default_port(0), width=width),))
            self.assertDiagnostic(config, "E_SELFTEST_WIDTH", "ports[0].width")

    def test_sparse_masks_and_no_runtime_ports(self):
        config = resize_ports(default_config(), 3)
        ports = tuple(replace(port, enabled=index != 1) for index, port in enumerate(config.ports))
        csr = replace(config, ports=ports)
        self.assertValid(csr)
        self.assertEqual(port_enable_mask(csr), 0b101)
        self.assertEqual(runtime_active_limit(csr), 3)
        self.assertEqual(analyze_config(csr)["runtime"]["active_port_limit"], 3)
        static = replace(csr, configuration_mode="STATIC")
        self.assertDiagnostic(static, "E_STATIC_MASK", "ports")
        self.assertEqual(runtime_active_limit(static), 2)
        empty = replace(config, ports=tuple(replace(port, enabled=False) for port in config.ports))
        self.assertDiagnostic(empty, "W_NO_RUNTIME_PORTS", "ports", "warning")
        self.assertEqual(runtime_active_limit(empty), 0)


class AnalysisAndParameterTests(ModelTestCase):
    def test_flat_vectors_expansion_and_mask(self):
        config = resize_ports(default_config(), 3)
        ports = (
            replace(config.ports[0], base_beats=0x12, size_lanes=0x3456, enabled=True),
            replace(config.ports[1], base_beats=0x1_2345, size_lanes=0x789ABCDE, enabled=False),
            replace(config.ports[2], base_beats=0x2_3456789A, size_lanes=7, enabled=True),
        )
        config = replace(config, ports=ports)
        base, size = flat_vectors(config)
        expanded = expanded_ports(config)
        self.assertEqual(len(expanded), 64)
        for index, port in enumerate(expanded):
            self.assertEqual((base >> (index * 34)) & ((1 << 34) - 1), port.base_beats)
            self.assertEqual((size >> (index * 32)) & 0xFFFFFFFF, port.size_lanes)
            if index >= 3:
                self.assertFalse(port.enabled)
                self.assertEqual(port, replace(default_port(index), enabled=False))
        self.assertEqual(port_enable_mask(config), 0b101)
        self.assertLess(base, 1 << (64 * 34))
        self.assertLess(size, 1 << (64 * 32))

    def test_lane_capacity_bytes_and_bandwidth(self):
        config = resize_ports(default_config(), 2)
        ports = (
            replace(config.ports[0], width=13, size_lanes=5),
            replace(config.ports[1], width=100, size_lanes=9, enabled=False),
        )
        analysis = analyze_config(replace(config, ports=ports))
        first, second = analysis["ports"]
        self.assertEqual((first["lane_count"], first["used_bytes"]), (1, 2))
        self.assertEqual((first["capacity_words"], first["size_tail_lanes"]), (5, 0))
        self.assertEqual(first["capacity_payload_bytes"], 10)
        self.assertEqual((second["lane_count"], second["used_bytes"]), (4, 13))
        self.assertEqual((second["capacity_words"], second["size_tail_lanes"]), (2, 1))
        self.assertEqual(second["padding_bytes_per_lane_group"], 3)
        self.assertEqual(analysis["bandwidth"]["useful_payload_bps"], 13 * 500_000)
        self.assertEqual(analysis["bandwidth"]["frontend_payload_bytes_per_second"], 1_000_000)
        self.assertEqual(analysis["bandwidth"]["allocated_backend_bytes_per_second"], 32_000_000)
        self.assertEqual(analysis["bandwidth"]["backend_theoretical_bytes_per_second"], 19_200_000_000)
        self.assertEqual(second["payload_bandwidth_bps"], 0)
        self.assertEqual(second["allocated_backend_bytes_per_second"], 0)

    def test_nominal_slots_latency_and_maintenance(self):
        config = resize_ports(default_config(), 3)
        analysis = analyze_config(config)
        self.assertEqual([slot["offset_cycles"] for slot in analysis["timing"]["nominal_slots"]], [190, 194, 198])
        self.assertEqual([port["nominal_slot_offset_cycles"] for port in analysis["ports"]], [190, 194, 198])
        async_slots = analyze_config(replace(config, clock_mode="ASYNC"))["timing"]["nominal_slots"]
        self.assertEqual([slot["offset_cycles"] for slot in async_slots], [198, 202, 206])
        for latency, expected_ns in ((1, 2000.0), (2, 4000.0)):
            with self.subTest(latency=latency):
                timing = analyze_config(replace(config, read_latency=latency))["timing"]
                self.assertEqual(timing["read_latency_cycles"], latency)
                self.assertEqual(timing["read_latency_ns"], expected_ns)
                self.assertEqual(timing["read_latency_ns_text"], str(int(expected_ns)))
        maintenance = analysis["maintenance"]
        self.assertAlmostEqual(maintenance["refresh_interval_us"], 7.0)
        self.assertAlmostEqual(maintenance["zq_interval_ms"], 64.0)

    def test_analysis_is_explicitly_analytical(self):
        analysis = analyze_config(default_config())
        self.assertIs(analysis["analytical_only"], True)
        self.assertIsNone(analysis["post_route_timing"])
        self.assertEqual(analysis["vlnv"], c.VLNV)
        self.assertIn("not a full-load", analysis["bandwidth"]["note"])
        self.assertIn("not guaranteed backend completion", analysis["timing"]["note"])


if __name__ == "__main__":
    unittest.main()
