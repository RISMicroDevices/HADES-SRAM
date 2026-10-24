# HADES-SRAM CSR Register Map (`CSR_EN=1`)

The AXI4-Lite slave uses 32-bit data in the `ui_clk` domain (300 MHz). On VCU1525 it is reached through JTAG-AXI at `0x0000_0000`; board-control registers are at `0x0001_0000`. Offsets below are byte offsets.

## General rules

- Unimplemented bits and unlisted offsets read as 0; writes to them are ignored without a bus error or side effect.
- Reset defaults are safe: `ENABLE=0` and all runtime port-enable masks are 0.
- `ENABLE` is rejected unless calibration is complete and the port clock is running within the configured frequency bound. Rejection sets `ERR_STATUS.bit4`.
- Loss or over-frequency of `port_clk` drops effective enable and sets bit4; enable recovers automatically when the clock is healthy.
- `SOFT_RESET` is self-clearing and clears ENABLE, errors, and statistics while retaining configuration. Poll `STATUS.READY` after reset; reset stretching and CDC delay availability.
- `CFG_LATENCY` takes effect on the next ENABLE 0-to-1 transition.
- A backend read unanswered for 768 `ui_clk` cycles returns synthetic zeros and sets `ERR_STATUS.bit1`. At `L=1`, the response-window sentinel may fire first. Treat either condition as a fatal backend error.

Physical port count, `W0`–`W63`, `BE0_EN`–`BE63_EN`, `AW`, and `IS_SYNC` are elaboration parameters. CSR cannot change physical widths or byte-enable switches.

For port width `W`, define `LC = 2^ceil(log2(ceil(W/32)))`. `PORT_SIZE` and backdoor addresses use **32-bit lane words**. A frontend `W`-bit port-word address is legal when `addr < floor(PORT_SIZE/LC)`.

## Global registers

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | `CTRL` | RW | 0 | bit0 `ENABLE`; bit1 `SOFT_RESET`; bit2 `SELFTEST` (implemented only with `SELFTEST_EN=1`) |
| 0x04 | `STATUS` | RO | — | bit0 `CALIB_DONE`; bit1 `READY`; bit2 `REFRESH_ACTIVE`; bit3 `ZQ_ACTIVE` |
| 0x08 | `CFG_LATENCY` | RW | 2 | Read latency in `port_clk` cycles; bits[1:0] are 1 or 2; other values are ignored; bits[8:15] reserved |
| 0x0C | `CFG_PORTS` | RW | 0 | Runtime active-port count, bits[7:0]. Limit to elaborated `N`; this cannot create physical ports |
| 0x10 | `MEAS_PERIOD` | RO | — | Measured `port_clk` period in `ui_clk` cycles |
| 0x14 | `PORT_EN_LO` | RW | 0 | Runtime enable bitmap for ports 31:0 |
| 0x18 | `PORT_EN_HI` | RW | 0 | Runtime enable bitmap for ports 63:32 |
| 0x1C | `CFG_MIN_PERIOD` | RW | 600 | Minimum legal period in `ui_clk` cycles; a shorter measured period rejects enable |
| 0x40 | `CFG_REFRESH_DIV` | RW | 2100 | Refresh interval in `ui_clk` cycles (2100 = 7 microseconds at 300 MHz) |
| 0x44 | `CFG_ZQ_DIV` | RW | 32000 | ZQCS interval in target periods (about 64 ms at 500 KHz) |
| 0x50 | `ERR_STATUS` | W1C | 0 | bit0 illegal address; bit1 backend timeout; bit2 dropped request; bit3 AXI SLVERR; bit4 enable rejected/clock lost; bit5 response-window violation; bits[13:8] first-error port. New events re-set cleared bits |
| 0x54 | `ERR_ADDR` | RO | 0 | First-error address, including port information |
| 0x58 | `STAT_MAXLAT` | RO | 0 | Maximum observed backend read latency in `ui_clk` cycles |
| 0x5C | `STAT_REFCNT` | RO | 0 | Cumulative refresh count |
| 0x60 | `STAT_TOT_RD_LO` | RO | 0 | Global read count [31:0] |
| 0x64 | `STAT_TOT_WR_LO` | RO | 0 | Global write count [31:0] |
| 0x68 | `STAT_TOT_RD_HI` | RO | 0 | Global read count [63:32] |
| 0x6C | `STAT_TOT_WR_HI` | RO | 0 | Global write count [63:32] |
| 0x80 | `ID` | RO | 0xADE50110 | HADES magic and version: [31:16] magic, [15:12] major=1, [11:8] minor=1, [7:0] patch=0 |
| 0x84 | `PARAMS` | RO | — | bit31 `CLK_MODE` (0=ASYNC, 1=SYNC); [30:20] `ui_clk` MHz; [19:12] default port MiB; [11:8] default 32-bit lane bytes (=4); [7:0] `N_MAX`. Use `PORT_WIDTH` for per-port widths |

## Indexed port window

Write `PORT_SEL`, then access the selected port's map and statistics. `PORT_SEL >= N_MAX` reads as 0 and ignores writes. Select only physically implemented ports below `N`.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x20 | `PORT_SEL` | RW | 0 | Port index selector |
| 0x24 | `PORT_BASE` | RW | `port*2^18` | Selected port base in 64-byte beats, bits[31:0] |
| 0x28 | `PORT_BASE_HI` | RW | 0 | Selected port base bits[33:32] |
| 0x2C | `PORT_SIZE` | RW | `2^22` | Selected port size in **32-bit lane words**. Frontend capacity is `PORT_SIZE/LC` port words |
| 0x30 | `PORT_STAT_RD` | RO | 0 | Selected port read count |
| 0x34 | `PORT_STAT_WR` | RO | 0 | Selected port write count |
| 0x38 | `PORT_STAT_ERR` | RO/W1C | 0 | Selected port error count, including self-test errors when built; any write clears it |
| 0x3C | `PORT_WIDTH` | RO | `W<port>` | Selected port width in bits, bits[9:0]. This is the elaboration `W<port>` value |

Default bases provide 16 MiB of address spacing per port. Default sizes span 16 MiB of 32-bit lanes. Non-32-bit widths can change usable port-word capacity because of lane grouping and padding; adjust the map for the desired capacity.

## On-chip self-test (`SELFTEST_EN=1`)

Each implemented port has a `port_clk`-domain checker. `CTRL.SELFTEST` starts all enabled ports: each writes and reads `SELFTEST_BLK` words with a per-port PRBS pattern and checks exact response phase and data. Errors increment `PORT_STAT_ERR`; they do not set `ERR_STATUS`.

Stop `SELFTEST` and wait at least 16 `port_clk` periods before clearing ENABLE or issuing `SOFT_RESET`. In the static variant, self-test runs automatically when enabled; its per-port counters have no bus readout.

## Backdoor channel

The backdoor is the lowest-priority requester, served during maintenance windows and idle slots. It works while disabled and does not disturb the frontend latency contract. Backdoor traffic increments global statistics but not per-port statistics.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x90 | `BKP_PORT` | RW | 0 | Target port index |
| 0x94 | `BKP_ADDR` | RW | 0 | Target **32-bit lane offset** [31:0], not necessarily a `W`-bit frontend address |
| 0x98 | `BKP_ADDR_HI` | RW | 0 | Target lane offset [39:32] |
| 0x9C | `BKP_WDATA` | RW | 0 | 32-bit lane write data |
| 0xA0 | `BKP_CMD` | WO | — | bit0 write trigger; bit1 read trigger; self-clearing |
| 0xA4 | `BKP_RDATA` | RO | 0 | 32-bit lane read result, valid when done |
| 0xA8 | `BKP_STATUS` | RO | 0 | bit0 busy; bit1 done; bit2 error (port out of range or address >= `PORT_SIZE`) |

Write the command fields, trigger it, poll done, and read the result on reads. Commands while busy are ignored. At `W=32`, backdoor addresses equal frontend addresses. At other widths, use the lane-group mapping in `INTEGRATION_GUIDE.md` §4.

Static mode uses `bkp_port`, `bkp_addr`, `bkp_wdata`, `bkp_we`, and `bkp_req`; hold them until `bkp_ack`. Read data returns on `bkp_rdata` with the acknowledgment.

# Static configuration (`CSR_EN=0`)

No CSR bus or boot sequence is required. Configuration is hard-wired and the core auto-enables after calibration with a healthy clock.

| Parameter | Default | Purpose |
|---|---|---|
| `P_L` | 2 | Read latency in `port_clk` cycles |
| `P_PORT_EN` | all ones | Runtime-equivalent port-enable bitmap |
| `P_MIN_PERIOD` | 600 | Minimum legal `port_clk` period |
| `P_REFRESH_DIV` | 2100 | Refresh interval |
| `P_ZQ_DIV` | 32000 | ZQCS interval |
| `P_PORT_BASE` | equal 16 MiB partitions | Flat `[N_MAX*34-1:0]` vector; port `i` uses `[i*34 +: 34]` in 64-byte beats |
| `P_PORT_SIZE` | `2^22` per port | Flat `[N_MAX*32-1:0]` vector; port `i` uses `[i*32 +: 32]` in **32-bit lane words** |

`N`, `AW`, `IS_SYNC`, `SELFTEST_EN`, `SELFTEST_BLK`, `TARGET_PERIOD_CYCLES`, `W0`–`W63`, and `BE0_EN`–`BE63_EN` are also elaboration parameters.

Status uses `stat_calib_done`, `stat_ready`, `stat_refresh_active`, `stat_zq_active`, and `stat_err[7:0]`. Pin-level backdoor access remains available without a bus. Static self-test counters have no CSR readout.
