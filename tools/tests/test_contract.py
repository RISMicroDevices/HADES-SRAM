import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from hades_sram_gen import contract as c
from hades_sram_gen.model import default_config, default_port
from hades_sram_gen.parameters import flat_vectors


def rtl_number(text):
    return int(text.replace("_", ""), 0)


class RtlContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pkg = (ROOT / "rtl/hades_sram_pkg.sv").read_text(encoding="utf-8")
        cls.top = (ROOT / "rtl/hades_sram_top.sv").read_text(encoding="utf-8")
        cls.mig_if = (ROOT / "rtl/hades_sram_mig_if.sv").read_text(encoding="utf-8")
        cls.arbiter = (ROOT / "rtl/hades_sram_arbiter.sv").read_text(encoding="utf-8")

    def rtl_localparam(self, name):
        match = re.search(
            rf"localparam\s+(?:int|logic\s*\[[^]]+\])\s+{re.escape(name)}\s*=\s*([^;]+);",
            self.pkg,
        )
        self.assertIsNotNone(match, name)
        value = match.group(1).strip()
        sized = re.fullmatch(r"\d+'h([0-9a-fA-F_]+)", value)
        if sized:
            return int(sized.group(1).replace("_", ""), 16)
        return rtl_number(value)

    def test_clock_address_and_vector_contract(self):
        self.assertEqual(c.UI_HZ, self.rtl_localparam("UI_CLK_MHZ") * 1_000_000)
        self.assertEqual(c.N_MAX, self.rtl_localparam("N_MAX"))
        self.assertEqual(c.AW_DEFAULT, self.rtl_localparam("AW_DEFAULT"))
        self.assertEqual(c.WORD_BYTES, self.rtl_localparam("WORD_BYTES"))
        self.assertEqual(c.BASE_W, self.rtl_localparam("BASE_W"))
        self.assertEqual((c.LANE_BYTES, c.LANES_PER_BEAT), (4, 16))
        self.assertEqual((c.SIZE_W, c.MASK_W), (32, 64))
        self.assertEqual(c.BASE_VECTOR_W, c.N_MAX * 34)
        self.assertEqual(c.SIZE_VECTOR_W, c.N_MAX * 32)
        self.assertIn("32'(rd_addr_q) >= rd_size_w", self.mig_if)
        self.assertIn("32'(wr_addr_q) >= wr_size_w", self.mig_if)
        self.assertEqual((c.AW_MIN, c.AW_MAX), (1, 32))
        self.assertEqual((c.WIDTH_MIN, c.WIDTH_MAX), (1, 512))

    def test_timing_budget_constants_and_slot_formula(self):
        expected = {
            "MAINT_SLOTS": 150,
            "FIRST_LAT": 36,
            "SLOT_PER_PORT": 4,
            "CDC_OVHD_SYNC": 4,
            "CDC_OVHD_ASYNC": 12,
            "MARGIN": 100,
        }
        for name, value in expected.items():
            with self.subTest(name=name):
                self.assertEqual(getattr(c, name), self.rtl_localparam(name))
                self.assertEqual(getattr(c, name), value)
        self.assertEqual(c.TARGET_DEFAULT, self.rtl_localparam("TARGET_PERIOD_500K"))
        self.assertEqual(c.MIN_PERIOD_DEFAULT, c.TARGET_DEFAULT)
        self.assertIn("slot_of(i, MODE)", self.arbiter)
        self.assertIn("MAINT_SLOTS + FIRST_LAT + cdc_ovhd(MODE)", self.arbiter)
        self.assertRegex(self.pkg, r"\+ MARGIN\)\s*< target_period")

    def test_default_geometry_matches_rtl(self):
        self.assertEqual(c.PORT_HZ_MIN, 100_000)
        self.assertEqual(c.PORT_HZ_MAX, 500_000)
        self.assertEqual(c.LATENCY_DEFAULT, 2)
        self.assertEqual(c.SELFTEST_BLOCK_DEFAULT, 256)
        self.assertEqual(c.REFRESH_DEFAULT, 2100)
        self.assertEqual(c.ZQ_DEFAULT, 32_000)
        self.assertEqual(c.PORT_BASE_STRIDE, 1 << 18)
        self.assertEqual(c.PORT_SIZE_DEFAULT, (16 * 1024 * 1024) // 4)
        for index in (0, 1, 31, 63):
            with self.subTest(index=index):
                port = default_port(index)
                self.assertEqual((port.width, port.byte_enable, port.enabled), (32, False, True))
                self.assertEqual(port.base_beats, index * c.PORT_BASE_STRIDE)
                self.assertEqual(port.size_lanes, c.PORT_SIZE_DEFAULT)
        base, size = flat_vectors(default_config())
        top_base = re.search(r"P_PORT_BASE\s*=\s*2176'h([0-9A-Fa-f]+)", self.top)
        top_size = re.search(r"P_PORT_SIZE\s*=\s*2048'h([0-9A-Fa-f]+)", self.top)
        self.assertIsNotNone(top_base)
        self.assertIsNotNone(top_size)
        self.assertEqual(base, int(top_base.group(1), 16))
        self.assertEqual(size, int(top_size.group(1), 16))

    def test_all_width_and_byte_enable_declarations(self):
        widths = {
            int(index): int(value)
            for index, value in re.findall(r"parameter\s+int\s+W(\d+)\s*=\s*(\d+)", self.top)
        }
        enables = {
            int(index): int(value)
            for index, value in re.findall(r"parameter\s+bit\s+BE(\d+)_EN\s*=\s*1'b([01])", self.top)
        }
        self.assertEqual(set(widths), set(range(c.N_MAX)))
        self.assertEqual(set(enables), set(range(c.N_MAX)))
        self.assertEqual(set(widths.values()), {32})
        self.assertEqual(set(enables.values()), {0})
        self.assertIn("10'(W0)", self.top)
        self.assertIn("BE0_EN", self.top)
        self.assertIn("BE63_EN", self.top)

    def test_identity_and_csr_map(self):
        self.assertEqual(c.VLNV, "rismd.cn:hades:hades_sram:1.1")
        self.assertEqual(c.CORE_ID, self.rtl_localparam("ID_MAGIC"))
        self.assertEqual(c.CORE_ID, 0xADE50110)
        for name in (
            "CSR_CTRL", "CSR_STATUS", "CSR_CFG_LATENCY", "CSR_CFG_PORTS",
            "CSR_MEAS_PERIOD", "CSR_PORT_EN_LO", "CSR_PORT_EN_HI",
            "CSR_CFG_MIN_PERIOD", "CSR_PORT_SEL", "CSR_PORT_BASE",
            "CSR_PORT_BASE_HI", "CSR_PORT_SIZE", "CSR_CFG_REFRESH_DIV",
            "CSR_CFG_ZQ_DIV", "CSR_ERR_STATUS", "CSR_ID",
        ):
            with self.subTest(register=name):
                self.assertEqual(getattr(c, name), self.rtl_localparam(name))

    def test_default_configuration_baseline(self):
        config = default_config()
        self.assertEqual(config.port_count, 1)
        self.assertEqual(config.ports[0].width, 32)
        self.assertEqual(config.configuration_mode, "CSR")
        self.assertEqual(config.clock_mode, "SYNC")
        self.assertEqual(config.port_clock_hz, 500_000)
        self.assertEqual(config.target_period_cycles, 600)
        self.assertEqual(config.min_period_cycles, 600)
        self.assertEqual(config.address_width, c.AW_DEFAULT)


if __name__ == "__main__":
    unittest.main()
