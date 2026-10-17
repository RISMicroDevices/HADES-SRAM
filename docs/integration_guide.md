# HADES-SRAM Integration Guide

Status: **HW spike** (sections marked [*M-later*] are filled by the named milestone).

## 1. Overview

HADES-SRAM emulates N (≤ 64, architecturally 128) independent synchronous-SRAM ports on one MIG DDR4 channel. Deterministic read latency L ∈ {1, 2} `port_clk` cycles (exact per access, not average); posted writes; all refresh/ZQCS maintenance scheduled in a fixed per-period window with zero jitter in the emulated domain.

- Clock domains: `ui_clk` = 300 MHz (MIG user clock), `port_clk` = 100–500 KHz (emulated SRAM clock, shared by all ports in this revision)
- `CLK_MODE=SYNC` (default): same-source clocks, phase declared in XDC — see §4
- `CLK_MODE=ASYNC`: independent sources; whitelist CDC (`rtl/hades_cdc.sv`)
- `CSR_EN=1` (default): AXI4-Lite CSR (see `csr/csr_regmap.md`)
- `CSR_EN=0`: static hard-wired configuration via parameters — see §5

## 2. MIG configuration checklist [*M5-hw*]

- VCU1525 C0 channel, DDR4 2400 MT/s, ui_clk 300 MHz (4:1), 512-bit AXI4 user interface
- **Enable "User Refresh and ZQCS Input"** (the UltraScale+ equivalent of USER_REFRESH) — the IP drives `app_ref_req/app_ref_ack` and `app_zq_req/app_zq_ack` (M3)
- Reference: board SYSCLK0 300 MHz; SLR2 placement (see §6)

## 3. Slot budget (static bound, spec §4.3) [*M3/M4*]

Per target period, in `ui_clk` cycles:
`MAINT_SLOTS(150) + FIRST_LAT(36) + CDC_OVHD(4 SYNC / 12 ASYNC) + N·SLOT_PER_PORT(4) + MARGIN(100) < TARGET_PERIOD`

| N | 500 KHz (600 cyc) | 100 KHz (3000 cyc) |
|---|---|---|
| 64 | 546 ✓ | ✓ |
| 128 | 802 ✗ (elaboration `$error`) | 802 ✓ |

Feasibility is enforced at elaboration (T11); N=128 @ 500 KHz is unreachable on one channel — scale down frequency or wait for the multi-channel path.

## 4. Dual clock domains [*M2+*]

- SYNC: both clocks from one MMCM/BUFGCE_DIV; no spread spectrum, no runtime phase drift; if that cannot be guaranteed, rebuild `CLK_MODE=ASYNC` (violation is an integration error; not detected at runtime)
- ASYNC: CDC only via `hades_sync2` / `hades_qs_bus` / `hades_rst_sync`; MTBF discussion and `report_cdc` acceptance [*M5*]
- `CFG_MIN_PERIOD` / `P_MIN_PERIOD`: frequency interlock in `ui_clk` cycles (default 600 = 500 KHz)

## 5. CSR vs static variant

- `CSR_EN=1`: program per `csr/csr_regmap.md`; init sequence: wait `CALIB_DONE` → check `MEAS_PERIOD` against expected frequency → configure ports (indexed window) → `CFG_LATENCY`/`PORT_EN_*` → `ENABLE` → poll `STATUS.READY`.
- `CSR_EN=0`: no bus. Set parameters (`P_L`, `P_PORT_EN`, `P_MIN_PERIOD`, `P_REFRESH_DIV`, `P_ZQ_DIV`, `P_PORT_BASE`, `P_PORT_SIZE` — flat per-port vectors, any mix of bases/sizes). Auto-enables once calibrated with a healthy clock. Status pins: `stat_calib_done/ready/refresh_active/zq_active`, `stat_err[7:0]`; pin-level backdoor `bkp_*`.

## 6. SLR / placement [*M5-hw*]

VU9P = 3 SLRs; all IP logic + MIG C0 constrained to SLR2 pblock; per-port local registering in `hades_port`; XDMA→CSR path may cross SLRs (pipelined).

## 7. Backdoor content load/readout [*M4*]

64 ports × 16 MiB full initialization estimate: 64 × 2^18 beats ≈ 16.8 M AXI beats ≈ 56 ms of bus time at full rate; at maintenance-window-only insertion (≈10% duty) ≈ 0.6 s. (Estimate; confirmed in M4.)

## 8. Known limitations

- All ports share one `port_clk` (per-port clocks are a future parameterization; cross-domain structures are already per-port)
- C1–C3 channels unused (multi-channel = documented expansion path when N exceeds one channel's slot budget)
- No caching/prefetch/write-combining (bandwidth usage ≈1.3% — unnecessary)
- L is global (per-group extension bits reserved)

## 9. Roadmap

| Milestone | Content | Tests |
|---|---|---|
| M1 (done) | Skeleton: pkg/CDC/freq-mon/CSR, empty datapath, CSR_EN variants | T6-basic, static smoke, bounds |
| M2 (done) | Full per-port datapath: hades_port (CDC: Gray-FIFO + quasi-static slots), timing shaper (L=1/2, back-to-back), mig_if (FCFS AXI4 engine, 32-deep outstanding, sub-word lanes, stats + illegal/SLVERR/drop errors), AXI4 MIG model with refresh/periodic-read/ZQCS occupancy | T1 (1e5 ops), T2 (L=1/2 exact), T13a-lite — SYNC+ASYNC, CSR+static, VCS+xsim |
| M3 | Refresh/ZQCS scheduling, determinism guards | T2(L=1), T3, T11, T14 |
| M4 | TDMA arbiter, N=8→32→64, backdoor | T4, T5, T7, T9, T11 |
| M5 | Hardening, coverage, VCU1525 acceptance, IP package | T8–T13, A1–A10 |

## 10. VCU1525 hardware spike (2026-10-17)

Stock MIG DDR4 example design, built and probed to validate the board, license, and JTAG path before M5-hw. Scripts: `fpga/vcu1525/spike/` (`mig_example_gen.tcl` → `build_example.tcl` → `program_spike.tcl`).

Resolved board facts (Vivado 2024.1, board files vcu1525:part0:1.3):

- FPGA part is `xcvu9p-fsgd2104-2L-e` (**-2L** low-voltage grade; the spec's `flgb2104` is wrong — deviation, board file wins)
- 4 independent DDR4 channels `ddr4_sdram_c0..c3`, each with its own `default_300mhz_clk0..3` differential reference; HADES uses c0
- MIG c0 board preset: DDR4-2400 (833 ps), RDIMM MTA18ASF2G72PZ-2G3 (16 GB), 72-bit with **ECC enabled**, AXI4 user interface 512-bit data / 34-bit address, ui_clk 300 MHz (4:1), differential 300 MHz sysclk, `sys_rst` = CPU_RESET button (AL20, LVCMOS12)
- **"User Refresh and ZQCS Input" = `CONFIG.C0.DDR4_UserRefresh_ZQCS`** (false in stock; must be true in the M5-hw build — M3 drives `app_ref_req`/`app_zq_req`)
- Stock example: `example_top` + traffic generator; pins auto-constrained from board presets except the two status outputs, mapped by `spike_pins.xdc`: GPIO_LED_0 (BC21) = `c0_init_calib_complete`, GPIO_LED_1 (BB21) = `c0_data_compare_error`
- MIG calib debug XSDB is off in the board preset (`Debug_Signal = Disable`); calib observation = LEDs. MCS UART not pinned out in the stock example.
- **Reset polarity trap**: the MIG `sys_rst` port is ACTIVE_HIGH, but the VCU1525 `resetn` board interface (CPU_RESET button, AL20) has `rst_polarity=0` — the button idles **high**, so a direct hookup holds the MIG in reset forever (observed: `init_calib_complete` stuck at 0 with live ui_clk). M5-hw must invert the reset (or drive it from a GPIO/VIO during bring-up). The spike `spike_top` works around it with a VIO-driven reset.

Host access decisions (2026-10-17, user):

- **JTAG**: Windows-side `hw_server` (from `C:\Xilinx\Vivado\2024.1\bin`) + `connect_hw_server -url <win-host>:3121` from WSL2 Vivado; no usbipd-win. First hw_server run may need a firewall allow on Windows.
- **Host control path: JTAG-AXI only — no PCIe/XDMA in the final design** (deviation from the spec's XDMA assumption). CSR read/write via a JTAG-to-AXI-Master IP driven by hw_server Tcl (`fpga/vcu1525/host/`); bandwidth acceptance runs on the on-chip SELFTEST_EN PRBS engines with CSR counters. Consequences: M5-hw build drops XDMA; `sw/` becomes Tcl host scripts instead of a C driver; PCIe slot only supplies power.
- PCIe is not passed through to WSL2 and stays unused.

Board bring-up log:

- Stock build: synth+impl+bitstream green, WNS +0.092 ns; Vivado license covers xcvu9p for Synthesis and Implementation
- JTAG chain verified: Windows hw_server reachable from WSL2 at `localhost:3121` (mirrored networking — no firewall rule needed), FTDI target `xilinx_tcf/Xilinx/12809621t033A`, 80 MB bitstream programmed in ~3.5 min
- First program: user could not visually confirm LEDs; both status outputs are latched levels in `example_tb`, and the observed blinking green LED is the FTDI JTAG-activity LED (hw_server polls). Added `spike_top.sv` + VIO (`add_vio_and_build.tcl`, `program_and_read.tcl`, `read_vio.tcl`) for definitive JTAG readout: probes `calib` / `cmperr` / `hb[31:0]` / `rst_pin`, VIO output `rst_drv` drives MIG sys_rst (VIO probe names follow the connected RTL net names, not the VIO port names)
- **2026-10-17 PASS**: `calib=1`, `compare_err=0`, heartbeat incrementing, `rst_pin=1` (confirms the reset polarity trap on silicon). VIO build WNS +0.244 ns. Gotchas hit: Tcl `regsub` brace-quoted subSpec keeps `\n` literal (corrupted the patched RTL — always syntax-check generated files); files dropped into a project's managed `imports/` dir get auto-disabled; scoped `BOARD_PART_PIN` constraints fail when the top-level port is no longer wired straight to the IP cell (constrain the port directly); `refresh_hw_device -update_hw_probes false` suppresses VIO probe enumeration.
