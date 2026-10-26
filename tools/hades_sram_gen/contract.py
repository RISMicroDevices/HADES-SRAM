SCHEMA_VERSION = 1
GENERATOR_NAME = "HADES-SRAM Generator"
VLNV = "rismd.cn:hades:hades_sram:1.1"
CORE_ID = 0xADE50110

N_MIN = 1
N_MAX = 64
WIDTH_MIN = 1
WIDTH_MAX = 512
AW_MIN = 1
AW_MAX = 32
UI_HZ = 300_000_000
PORT_HZ_MIN = 100_000
PORT_HZ_MAX = 500_000
TARGET_DEFAULT = 600
MIN_PERIOD_DEFAULT = 600
AW_DEFAULT = 22
LATENCY_DEFAULT = 2
SELFTEST_BLOCK_DEFAULT = 256
REFRESH_DEFAULT = 2100
ZQ_DEFAULT = 32_000
PORT_BASE_STRIDE = 1 << 18
PORT_SIZE_DEFAULT = 1 << 22

WORD_BYTES = 64
LANE_BYTES = 4
LANES_PER_BEAT = 16
BASE_W = 34
SIZE_W = 32
MASK_W = 64
BASE_VECTOR_W = N_MAX * BASE_W
SIZE_VECTOR_W = N_MAX * SIZE_W

MAINT_SLOTS = 150
FIRST_LAT = 36
SLOT_PER_PORT = 4
CDC_OVHD_SYNC = 4
CDC_OVHD_ASYNC = 12
MARGIN = 100
STOP_TIMEOUT = 16_384
FREQ_MONITOR_MARGIN = 4

CSR_CTRL = 0x0000
CSR_STATUS = 0x0004
CSR_CFG_LATENCY = 0x0008
CSR_CFG_PORTS = 0x000C
CSR_MEAS_PERIOD = 0x0010
CSR_PORT_EN_LO = 0x0014
CSR_PORT_EN_HI = 0x0018
CSR_CFG_MIN_PERIOD = 0x001C
CSR_PORT_SEL = 0x0020
CSR_PORT_BASE = 0x0024
CSR_PORT_BASE_HI = 0x0028
CSR_PORT_SIZE = 0x002C
CSR_CFG_REFRESH_DIV = 0x0040
CSR_CFG_ZQ_DIV = 0x0044
CSR_ERR_STATUS = 0x0050
CSR_ID = 0x0080

SV_RESERVED = frozenset({
    "always", "always_comb", "always_ff", "always_latch", "and", "assert",
    "assign", "assume", "automatic", "begin", "bit", "buf", "byte", "case",
    "casex", "casez", "clocking", "const", "cover", "default", "disable",
    "else", "end", "endcase", "endfunction", "endgenerate", "endinterface",
    "endmodule", "endpackage", "endproperty", "endsequence", "endtask", "enum",
    "event", "export", "final", "for", "function", "generate", "genvar", "if",
    "import", "initial", "inout", "input", "int", "integer", "interface",
    "localparam", "logic", "longint", "modport", "module", "nand", "negedge",
    "nor", "not", "or", "output", "package", "parameter", "posedge", "property",
    "real", "ref", "reg", "return", "sequence", "shortint", "shortreal", "signed",
    "static", "string", "struct", "supply0", "supply1", "task", "time", "typedef",
    "union", "unsigned", "var", "void", "while", "wire", "xnor", "xor",
})
