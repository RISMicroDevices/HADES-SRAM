import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen import contract as c
from hades_sram_gen.allocate import allocate_addresses, apply_depths, depth_of
from hades_sram_gen.analyze import analyze_config
from hades_sram_gen.model import ConfigError, default_config, default_port, resize_ports
from hades_sram_gen.validate import has_errors, lane_count, validate_config


class AllocationTests(unittest.TestCase):
    def config_with_widths(self, widths):
        config = resize_ports(default_config(), len(widths))
        ports = tuple(
            replace(config.ports[index], width=width, enabled=index % 2 == 0)
            for index, width in enumerate(widths)
        )
        return replace(config, ports=ports, address_width=20)

    def assert_codes(self, caught, *codes):
        actual = {item.code for item in caught.exception.diagnostics}
        for code in codes:
            self.assertIn(code, actual)

    def test_apply_depths_widths_depths_and_large_valid_sizes(self):
        widths = (1, 13, 40, 300, 512)
        for width in widths:
            for depth in (1, 17):
                with self.subTest(width=width, depth=depth):
                    config = self.config_with_widths([width])
                    original = config.ports[0]
                    result = apply_depths(config, {0: depth})
                    self.assertIsNot(result, config)
                    self.assertEqual(result.ports[0].size_lanes, depth * lane_count(width))
                    self.assertEqual(result.ports[0].base_beats, original.base_beats)
                    self.assertEqual(result.ports[0].width, width)
                    self.assertEqual(depth_of(result.ports[0]), depth)
                    self.assertEqual(config.ports[0], original)

        for width, depth, expected in (
            (1, 0xFFFF_FFFF, 0xFFFF_FFFF),
            (512, 0xFFFF_FFFF // 16, 0xFFFF_FFF0),
        ):
            with self.subTest(width=width, large=True):
                result = apply_depths(self.config_with_widths([width]), {0: depth})
                self.assertEqual(result.ports[0].size_lanes, expected)

    def test_manual_edit_changes_only_selected_sizes(self):
        config = self.config_with_widths([13, 40, 300])
        original = config.ports
        result = apply_depths(config, {0: 3, 2: 5})
        self.assertEqual(result.ports[0].size_lanes, 3)
        self.assertEqual(result.ports[1], original[1])
        self.assertEqual(result.ports[2].size_lanes, 80)
        self.assertEqual([port.base_beats for port in result.ports], [port.base_beats for port in original])
        self.assertEqual(result.ports[0].enabled, original[0].enabled)
        self.assertEqual(result.ports[2].enabled, original[2].enabled)
        self.assertEqual(depth_of(replace(original[1], size_lanes=5)), 2)

    def test_allocate_exact_sizes_beat_windows_padding_and_determinism(self):
        config = self.config_with_widths([1, 13, 40, 300, 512])
        depths = [1, 17, 17, 3, 2]
        result = allocate_addresses(config, depths)
        self.assertEqual([port.size_lanes for port in result.ports], [1, 17, 34, 48, 32])
        self.assertEqual([port.base_beats for port in result.ports], [0, 1, 3, 6, 9])
        analysis = analyze_config(result)
        self.assertEqual([port["backend_window_beats"] for port in analysis["ports"]], [1, 2, 3, 3, 2])
        self.assertEqual([port["backend_end_beats"] for port in analysis["ports"]], [1, 3, 6, 9, 11])
        self.assertEqual([port["backend_window_padding_lanes"] for port in analysis["ports"]], [15, 15, 14, 0, 0])
        self.assertEqual([port["capacity_words"] for port in analysis["ports"]], depths)
        self.assertEqual(analysis["ports"][2]["padding_bytes_per_lane_group"], 3)
        self.assertFalse(has_errors(validate_config(result)))
        self.assertEqual(allocate_addresses(config, depths), result)

    def test_allocate_all_64_ports_including_runtime_disabled(self):
        config = self.config_with_widths([13] * 64)
        depths = [index + 1 for index in range(64)]
        result = allocate_addresses(config, depths)
        base = 0
        for index, port in enumerate(result.ports):
            self.assertEqual(port.size_lanes, depths[index])
            self.assertEqual(port.base_beats, base)
            self.assertEqual(port.enabled, index % 2 == 0)
            base += (port.size_lanes + 15) // 16
            if index:
                previous = result.ports[index - 1]
                previous_end = previous.base_beats + (previous.size_lanes + 15) // 16
                self.assertEqual(port.base_beats, previous_end)
        self.assertFalse(has_errors(validate_config(result)))

    def test_uint32_aggregate_exactly_fills_unsigned34_space(self):
        config = self.config_with_widths([1] * 64)
        result = allocate_addresses(config, [0xFFFF_FFFF] * 64)
        self.assertEqual(result.ports[-1].base_beats, 63 * (1 << 28))
        analysis = analyze_config(result)
        self.assertEqual(analysis["ports"][-1]["backend_end_beats"], 1 << 34)

    def test_final_address_overflow_guard(self):
        config = self.config_with_widths([1, 1])
        with patch("hades_sram_gen.allocate._DEPTH_LIMIT", (1 << 40) - 1):
            with self.assertRaises(ConfigError) as caught:
                allocate_addresses(config, [1 << 38, 1 << 38])
        self.assert_codes(caught, "E_AUTO_MAP_OVERFLOW")
        diagnostic = caught.exception.diagnostics[0]
        self.assertEqual(diagnostic.path, "ports[1].depth")

    def test_apply_rejects_bad_indices_depths_widths_and_uint32_overflow(self):
        config = self.config_with_widths([32])
        for changes, code in (
            ({-1: 1}, "E_DEPTH_INDEX"),
            ({1: 1}, "E_DEPTH_INDEX"),
            ({True: 1}, "E_DEPTH_INDEX"),
            ({"0": 1}, "E_DEPTH_INDEX"),
            ({0: True}, "E_DEPTH_TYPE"),
            ({0: 1.5}, "E_DEPTH_TYPE"),
            ({0: "1"}, "E_DEPTH_TYPE"),
            ({0: 0}, "E_DEPTH_RANGE"),
            ({0: -1}, "E_DEPTH_RANGE"),
            ({0: 0x1_0000_0000}, "E_DEPTH_RANGE"),
        ):
            with self.subTest(changes=changes):
                with self.assertRaises(ConfigError) as caught:
                    apply_depths(config, changes)
                self.assert_codes(caught, code)
                self.assertTrue(all(item.path.startswith("ports") for item in caught.exception.diagnostics))

        for width in (0, 513):
            with self.subTest(width=width):
                with self.assertRaises(ConfigError) as caught:
                    apply_depths(self.config_with_widths([width]), {0: 1})
                self.assert_codes(caught, "E_WIDTH_RANGE")
                self.assertEqual(caught.exception.diagnostics[0].path, "ports[0].width")

        with self.assertRaises(ConfigError) as caught:
            apply_depths(config, {0: 0, 1: 1})
        self.assertGreaterEqual(len(caught.exception.diagnostics), 2)

    def test_allocate_rejects_bad_list_depths_widths_and_count(self):
        config = self.config_with_widths([32])
        for depths, code in (
            ([], "E_DEPTH_LIST_LENGTH"),
            ([1, 1], "E_DEPTH_LIST_LENGTH"),
            ([True], "E_DEPTH_TYPE"),
            ([0], "E_DEPTH_RANGE"),
            ([0x1_0000_0000], "E_DEPTH_RANGE"),
            ("1", "E_DEPTH_TYPE"),
        ):
            with self.subTest(depths=depths):
                with self.assertRaises(ConfigError) as caught:
                    allocate_addresses(config, depths)
                self.assert_codes(caught, code)
        for width in (0, 513):
            with self.subTest(width=width):
                with self.assertRaises(ConfigError) as caught:
                    allocate_addresses(self.config_with_widths([width]), [1])
                self.assert_codes(caught, "E_WIDTH_RANGE")
        for count in (0, 65):
            with self.subTest(count=count):
                with self.assertRaises(ConfigError) as caught:
                    allocate_addresses(resize_ports(default_config(), count), [])
                self.assert_codes(caught, "E_N_RANGE")


if __name__ == "__main__":
    unittest.main()
