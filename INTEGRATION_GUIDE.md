# HADES-SRAM Integration Guide

HADES-SRAM is the SRAM-emulation sub-project of **HADES** (Hybrid Accelerated and Distributed Emulation System): an FPGA IP core that emulates many independent, deterministic-latency SRAM ports on a **single AMD/Xilinx MIG DDR4 channel**.

## 1. Overview

The core presents up to **64 independent SRAM ports** (`N_MAX = 64`; the architecture scales to 128) toward the user logic, each a simple synchronous SRAM-style interface in the `port_clk` domain, and funnels all of them through one DDR4 channel via a per-ID AXI4 backend engine.

Key properties:

- **Deterministic read latency**: exactly **L ∈ {1, 2} `port_clk` cycles** — cycle-exact, not statistical. Refresh and ZQ calibration maintenance is scheduled inside the same bound.
- **Full pipelining**: initiation interval 1 — a port accepts a new request on every `port_clk` edge, reads included.
- **Posted writes**: a write is complete from the port's perspective at the accepting edge.
- **Port clock**: 100–500 KHz; backend `ui_clk` 300 MHz (MIG user clock).
- **Per-port window**: `DW = 32`-bit data, `AW = 22`-bit word address (16 MiB per port), each port mapped to a configurable base/size window in the DDR4 address space.
- **Clock modes**: `SYNC` (port_clk derived from ui_clk, same source) or `ASYNC` (independent port_clk source, whitelist CDC).
- **Configuration**: AXI4-Lite CSR variant (`CSR_EN = 1`) or a static parameter-only variant (`CSR_EN = 0`, no bus, no boot sequence).
- **Self-checking**: optional per-port PRBS selftest engines (`SELFTEST_EN`) with per-port error CSRs.
- **Backdoor** channel for content load/readout (CSR-driven or pin-level).

## 2. Deliverables

| Path | Content |
|---|---|
| `rtl/` | Synthesizable SystemVerilog-2012 (`hades_sram_top` + submodules) |
| `constraints/` | `hades_sram_clocks_{sync,async}.xdc` — per-clock-mode timing constraints shipped with the IP |
| `csr/csr_regmap.md` | Full CSR register map (CSR_EN=1) and static-variant parameter list |
| `ip/` | `package_ip.tcl` — Vivado IP packager flow (catalog-ready `hades_sram_1.0`) |
| `fpga/vcu1525/` | VCU1525 reference build (bitstream flow + host scripts) |
| `sim/` | SystemVerilog + DPI-C testbench (VCS and Vivado xsim) |

## 3. Parameters and configuration

### 3.1 Generics (hades_sram_top)

| Parameter | Default | Meaning |
|---|---|---|
| `N` | 64 | Active ports (≤ `N_MAX`) |
| `DW` / `AW` | 32 / 22 | Port data width / word-address width |
| `IS_SYNC` | 1 | Clock mode: 1 = SYNC, 0 = ASYNC |
| `CSR_EN` | 1 | 1 = AXI4-Lite CSR; 0 = static parameters |
| `SELFTEST_EN` | 0 | Per-port PRBS self-check engines |
| `SELFTEST_BLK` | 256 | Selftest words per pass |
| `TARGET_PERIOD_CYCLES` | 600 | Port period in `ui_clk` cycles (600 = 500 KHz @ 300 MHz) |
| `P_L` | 2 | Read latency L (static variant) |
| `P_PORT_EN` | all ones | Per-port enable mask |
| `P_MIN_PERIOD` | 600 | Over-frequency interlock threshold (ui_clk cycles) |
| `P_REFRESH_DIV` | 2100 | Refresh gearing (ui_clk cycles per refresh-window tick) |
| `P_ZQ_DIV` | 32000 | ZQCS gearing |
| `P_PORT_BASE` / `P_PORT_SIZE` | flat vectors | Per-port window base (AXI beats) and size (static variant) |

### 3.2 Slot budget (elaboration-time guard)

Every enabled port must own enough TDMA slots in the target port period to cover its worst-case demand, and the maintenance (refresh/ZQCS) window must fit as well. `hades_sram_top` evaluates this statically (`budget_ok`): an over-subscribed parameter set **fails elaboration**, so an illegal configuration can never reach hardware. The same bound backs the latency contract: a legal configuration never misses L.

### 3.3 CSR variant vs static variant

- **`CSR_EN = 1`** (default): AXI4-Lite slave exposes all configuration (latency, port enables, per-port base/size, refresh/ZQ gearing, min-period interlock) plus status, error, and statistics registers and the backdoor channel. See `csr/csr_regmap.md`.
- **`CSR_EN = 0`**: no bus at all. All configuration comes from the `P_*` parameters (including the flat per-port `P_PORT_BASE`/`P_PORT_SIZE` vectors) and is folded into the same internal configuration structure — the core is ready out of reset with no programming sequence. Observability is via pins: `stat_calib_done`, `stat_ready`, `stat_refresh_active`, `stat_zq_active`, `stat_err[7:0]`. Content load/readout uses the pin-level backdoor (`bkp_*`).

## 4. Architecture

### 4.1 Clock domains

- `ui_clk` (300 MHz): backend, arbiter, refresh scheduler, CSR, backend AXI to the MIG.
- `port_clk` (100–500 KHz): the N emulated SRAM ports. All N ports share one `port_clk`.
- `SYNC`: port_clk is a divided ui_clk (same source; the divider reloads only at a counter wrap, so every port period has an exact integer length).
- `ASYNC`: port_clk comes from an independent source; the domains cross only through the CDC whitelist (§5).

### 4.2 Per-port datapath

Each port has: request capture (enable/we/addr/wdata on the port edge), a response path with a timing shaper that releases read data at exactly L cycles, and CDC built from Gray-pointer async FIFOs plus quasi-static hold slots. A port accepts one operation per `port_clk` cycle (read or write) with responses in flight — back-to-back at full rate is the design point.

### 4.3 TDMA arbiter and maintenance

A static TDMA table grants each enabled port its backend slots; per-port eligibility latches feed the table. The refresh/ZQCS scheduler issues DDR4 maintenance through the MIG user-refresh/ZQCS interface, window-geared by `CFG_REFRESH_DIV`/`CFG_ZQ_DIV`, idle-gated and debt-bounded so that maintenance can never push a response past the latency bound. The latency contract holds at every port_clk edge, at both gears and across stop/start.

### 4.4 Backend AXI4 engine and error model

The backend runs multiple outstanding AXI4 transactions (per-ID channels) to the MIG with sub-word lane handling for 32-bit accesses on the 512-bit bus. Error model:

- Illegal/unmapped access → SLVERR-style error record (port error CSR + sticky global status).
- Backend response timeout (768 `ui_clk` cycles) → the read completes with synthetic zeros and sets `ERR_STATUS.bit1`. This is a liveness backstop with ~5× margin over the worst legal latency — treat bit1 as a fatal alarm: a backend late-but-alive past the timeout is outside the legal model.

### 4.5 Backdoor

A lowest-priority requester for bulk content load/readout that shares the backend without disturbing the latency contract (CSR-driven in the CSR variant, pin-level `bkp_*` in the static variant).

### 4.6 Selftest

`SELFTEST_EN` adds a per-port PRBS generator/checker. A run: clear error state, enable selftest, let engines run, stop, drain (≥16 port periods), read per-port error CSRs and the sticky global status. On-board acceptance traffic uses these engines (the control plane is narrow by design).

## 5. Clocks, resets, CDC

- Resets: synchronous assertion, synchronous deassertion in each domain (`ui_rst_n`, `port_rst_n`); hold both in reset until `calib_done` from the MIG is stable.
- Constraints: use `constraints/hades_sram_clocks_sync.xdc` for SYNC builds, `constraints/hades_sram_clocks_async.xdc` for ASYNC builds (the packager auto-loads per clock mode).
- ASYNC crossings use only the whitelist cells in `rtl/hades_sram_cdc.sv` (`hades_sram_sync2`, `hades_sram_qs_bus`, `hades_sram_rst_sync`) — no bare cross-domain wires. The quasi-static buses and async-FIFO arrays are deliberate structures (config written only while quiesced; hold slots stable hold→release; wire delay bounded by max-delay constraints), so a raw `report_cdc` will flag them; reviewed, justified dispositions ship as `fpga/vcu1525/cdc_waivers.tcl` in the reference build. Reuse or review-equivalent them in your own flow.

## 6. Register interface and host protocol

CSR base in the reference build: `0x0000_0000`. Groups: control/status (`CTRL`, `STATUS`), configuration (`CFG_*`, `PORT_EN_*`, per-port window via `PORT_SEL` + `PORT_BASE`/`PORT_SIZE`), measurement (`MEAS_PERIOD`), error/status (`ERR_STATUS`, `PORT_STAT_ERR`, `ERR_ADDR`), statistics (`STAT_*`), identity (`ID`, `PARAMS`). Full map: `csr/csr_regmap.md`.

Host protocol essentials:

1. Program configuration, then set `CTRL.ENABLE`; poll `STATUS` until `CALIB|READY`.
2. Selftest: clear error state (any write to `PORT_STAT_ERR` per port; write mask to `ERR_STATUS`), set `CTRL.SELFTEST`, wait, clear `SELFTEST`, drain ≥ 16 port periods, then read error registers.
3. **Quiesce before disable or reconfiguration**: clear `SELFTEST`, wait ≥ 16 port periods, then issue `SOFT_RESET`. Dropping ENABLE with accepted-but-ungranted requests in flight trips the bit5 sentinel — the same rule as for pin traffic.
4. Error registers are W1C (write-to-clear) and sticky by design.

## 7. MIG integration checklist

- DDR4-2400 (833 ps), RDIMM with ECC (MTA18ASF2G72PZ-2G3 class), 72-bit.
- User interface: AXI4, 512-bit data, ui_clk 300 MHz (4:1).
- **Enable "User Refresh and ZQCS Input"** (`CONFIG.C0.DDR4_UserRefresh_ZQCS = true`) — the core drives `app_ref_req`/`app_zq_req` and expects the acks.
- `sys_rst` is **active-high** on the MIG; check your board reset polarity (a board `resetn` idles high and would hold the MIG in reset if wired directly).
- `calib_done` (MIG `init_calib_complete`) must be wired in; `STATUS.READY` asserts only after calibration with legal configuration.

## 8. VCU1525 reference build

`fpga/vcu1525/build.tcl` builds a complete board image around the core:

```
vivado -mode batch -source fpga/vcu1525/build.tcl -tclargs SYNC|ASYNC [PCIE|MMCM]
```

Products: `fpga/vcu1525/build/<tag>/hades_sram_vcu1525_<tag>.bit` + `.ltx` + `reports/` (timing, utilization, DRC, CDC for ASYNC). Scripted gates: route WNS ≥ 0; ASYNC additionally report_cdc with zero unwaived Critical/Warning findings (waivers per §5).

Reference-build specifics:

- **Part**: xcvu9p-**fsgd2104-2L-e** (low-voltage grade, board-file authoritative).
- **Control path: JTAG-AXI only** (no PCIe/XDMA). CSRs sit at JTAG-AXI `0x0000_0000`, board control at `0x0001_0000`; bandwidth acceptance runs on the on-chip selftest engines.
- **Port clock**: SYNC = ui_clk/600 fabric divider; ASYNC = second MMCM on another onboard oscillator input (same crystal family — the PCIe-slot-refclk variant is prepared in RTL/XDC but pin-unverified). ASYNC boots at a safe ~167 KHz gear until the host programs the divider.
- **Write-supply note (this platform)**: the fitted RDIMM is x4-class and the board routes no DM/DBI pins, so every 32-bit write is a MIG-internal read-modify-write. Measured full-load capacity supports **56 ports at full rate**; reads alone are clean at 64. Plan port count accordingly on this board.
- **Host scripts** (`fpga/vcu1525/host/`, run with `vivado -mode batch -source host/<script>.tcl -tclargs ...`; args in each header): `program` (bitstream), `smoke`, `a2_init` (power-up init), `a4_latency` (latency accuracy), `a5_soak` / `a9_soak` (sustained-load and endurance), `a6_refresh` (refresh rate), `a7_dualfreq` (dual gears), `a8_config` (config loop + over-frequency interlock), `a10_clock` (clock stop/start + gear sweep). Conventions: 6 MHz TCK; `HADES_LTX` points at the probes file; `HADES_SRC_UI_RATIO=3` when testing an ASYNC/MMCM image (the frequency monitor counts ui_clk cycles, the divider counts source cycles).

## 9. Known limitations

- All ports share one `port_clk` (per-port clocks are a future parameterization; the cross-domain structures are already per-port).
- DDR4 channels C1–C3 unused (multi-channel is the documented expansion path when N exceeds one channel's slot budget).
- No caching/prefetch/write-combining (aggregate port demand is a small fraction of the DDR4 channel).
- L is global across ports (per-group extension bits reserved).
- Backend timeout fault model: see §4.4 — bit1 is a fatal alarm.
- Static variant: per-port selftest error counters have no readout bus; only the aggregated `stat_err` pins are visible.
- On the VCU1525 platform, full read+write load is practical up to 56 ports (§8); reads alone are clean at 64.

## 10. Design headroom

- If a future target needs more timing margin, the architecture admits deeper parameterized pipelining in the backend engines (request prepare/issue stages) and in the arbiter/release paths without touching the port contract. A conservative fallback frequency target (~266 MHz) is documented as an option.
- Write coalescing at the backend would lift the platform's 64-port full-load ceiling (§8) by removing the read-modify-write penalty on sub-beat writes.

## 11. Verification

The core ships with a SystemVerilog + DPI-C testbench covering the datapath, determinism, error paths, reset recovery, and CDC, green on both VCS and Vivado xsim with coverage gates (line ≥ 95%, FSM 100%). On VCU1525 hardware, both clock modes passed acceptance: power-up init, latency accuracy with ILA witness, refresh rate, dual frequency gears, configuration loop with over-frequency interlock, clock stop/start and sweep dynamics, and multi-hour full-load endurance with temperature logging.
