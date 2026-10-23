# HADES-SRAM Integration Guide

Status: **M5-sim done** (sections marked [*M-later*] are filled by the named milestone).

## 1. Overview

HADES-SRAM emulates N (≤ 64, architecturally 128) independent synchronous-SRAM ports on one MIG DDR4 channel. Deterministic read latency L ∈ {1, 2} `port_clk` cycles (exact per access, not average); posted writes; all refresh/ZQCS maintenance scheduled in a fixed per-period window with zero jitter in the emulated domain.

- Clock domains: `ui_clk` = 300 MHz (MIG user clock), `port_clk` = 100–500 KHz (emulated SRAM clock, shared by all ports in this revision)
- `CLK_MODE=SYNC` (default): same-source clocks, phase declared in XDC — see §4
- `CLK_MODE=ASYNC`: independent sources; whitelist CDC (`rtl/hades_sram_cdc.sv`)
- `CSR_EN=1` (default): AXI4-Lite CSR (see `csr/csr_regmap.md`)
- `CSR_EN=0`: static hard-wired configuration via parameters — see §5

## 2. MIG configuration checklist [*M5-hw*]

Production configuration (as built by `fpga/vcu1525/build.tcl`; resolved config dump: `fpga/vcu1525/mig_config_prod.txt`):

- VCU1525 C0 channel (`ddr4_sdram_c0`), DDR4-2400 (833 ps), RDIMM MTA18ASF2G72PZ-2G3 (16 GB), 72-bit data
- **ECC = OFF** (`CONFIG.C0.DDR4_Ecc=false`) and **DataMask is unavailable on this RDIMM** (the MIG part database forces `DataMask=NONE` — no byte-lane DM pins): every 32-bit partial-beat WSTRB write is a read-modify-write inside the MIG (~20 cycles vs ~6 for a full beat).  Hardware evidence (A4, 2026-10-19/20): under 64-port selftest load the write path starves first and FCFS lowest-index priority starves high ports.  Working mitigations: bank staggering + engine phase decorrelation (both in §11).  ECC re-enable would need a write-coalescing front end, which spec §9 excludes — ECC stays off
- **AXI4 user interface enabled** (`CONFIG.C0.DDR4_AxiSelection=true`; the stock spike ran the native app interface): 512-bit data / 4-bit ID / 34-bit byte address; the IP drives all 40-bit addresses below 2^34
- ui_clk 300 MHz (4:1), differential onboard 300 MHz sysclk (`default_300mhz_clk0`)
- **"User Refresh and ZQCS Input" = `CONFIG.C0.DDR4_UserRefresh_ZQCS=true`** — in this mode the MIG never auto-refreshes; the IP is solely responsible for DRAM retention (M3 drives `app_ref_req/app_ref_ack`, `app_zq_req/app_zq_ack`)
- ECC/parity management AXI4-Lite port (`c0_ddr4_s_axi_ctrl_*`) tied off (present even with Ecc=false; RDIMM mandates `EN_PARITY=true` — `false` is rejected)
- **Reset polarity**: MIG `sys_rst` is ACTIVE-HIGH but the CPU_RESET button (AL20) idles high → drive it **inverted** — and **filtered**: the raw line spontaneously re-calibrated the MIG three times in one day of testing, so `mig_sys_rst` now asserts only after `cpu_resetn` stays low for 2^20 ui_clk cycles (~3.5 ms)
- Placement: MIG C0 controller+PHY sit in SLR0 (board-fixed I/O); a ranged user pblock cannot be used (see §6)

## 3. Slot budget (static bound, spec §4.3) [*M3/M4*]

Per target period, in `ui_clk` cycles:
`MAINT_SLOTS(150) + FIRST_LAT(36) + CDC_OVHD(4 SYNC / 12 ASYNC) + N·SLOT_PER_PORT(4) + MARGIN(100) < TARGET_PERIOD`

| N | 500 KHz (600 cyc) | 100 KHz (3000 cyc) |
|---|---|---|
| 64 | 546 ✓ | ✓ |
| 128 | 802 ✗ (elaboration `$error`) | 802 ✓ |

Feasibility is enforced at elaboration (T11); N=128 @ 500 KHz is unreachable on one channel — scale down frequency or wait for the multi-channel path.

### 3.1 Maintenance window and refresh gearing (M3)

`hades_sram_refresh_sched` owns `app_ref_req`/`app_zq_req` (User Refresh and ZQCS Input mode — in this mode the MIG never auto-refreshes; the IP is solely responsible for DRAM retention).

- Period tick: `port_clk` is sampled through a 2FF synchronizer and rising-edge detected in the `ui_clk` domain (≤ 2-cycle jitter in ASYNC, absorbed by the slot margin). The maintenance window is the first `MAINT_SLOTS` (150) `ui_clk` cycles after each tick — the slot-table head; port service slots begin at 150 + `FIRST_LAT` + `CDC_OVHD`.
- Refresh: a free-running `ui_clk` timer pends one debt every `CFG_REFRESH_DIV` cycles (default 2100 ≈ 7 µs). While enabled, debts are serviced only inside the maintenance window (zero maintenance jitter in the emulated domain), at most 2 per window — 100 KHz needs ≈ 1.43 refreshes per target period. A debt ≥ 4 (misconfiguration or clock stutter) overrides the window gate: a mid-period refresh beats losing DRAM contents. While DISABLED the window gate is open, so memory contents survive DISABLE→ENABLE reconfiguration. The timer never re-gears on service, so the long-run refresh rate is exactly 1/`CFG_REFRESH_DIV` (A6: `STAT_REFCNT` vs configured rate ±1%).
- ZQCS: one due every `CFG_ZQ_DIV` target periods (default 32000 ≈ 64 ms @ 500 KHz), serviced after any pending refresh in the same window. Dues are counted in ticks, so ZQCS requires a running `port_clk` (refresh does not — it free-runs while disabled).
- Configuration rule (not elaboration-enforced): `CFG_REFRESH_DIV` ≥ `TARGET_PERIOD`/2, otherwise the 2-per-window cap saturates the debt. Defaults satisfy this at both frequency gears by a wide margin.
- JEDEC margin: worst refresh spacing is at 100 KHz = 7 µs + one 10 µs period = 17 µs ≪ 9×tREFI (70.2 µs postponement limit).
- Worst-case window occupancy: refresh (105) + ZQCS (32) + periodic read (12) + handshakes ≈ 155 `ui_clk` cycles ≤ `MAINT_SLOTS` + slack; T3 repeats T2 under exactly this combination every window (plus a model-forced periodic read, `+MAINT_STRESS=1`) and the bit5 sentinel must stay silent.
- `STATUS.REFRESH_ACTIVE`/`ZQ_ACTIVE` (and the static-variant pins) are high while the respective handshake is in flight; the MIG owns the tRFC/tZQCS dead time after the ack.

## 4. Dual clock domains [*M2+, M5-hw*]

- SYNC (default): both clocks from one source. On the VCU1525 build `port_clk` is a fabric-divided square wave of `ui_clk` (`board_clk_gen` divider + BUFGCE), declared as a generated clock (worst gear divide_by 600 = 500 KHz); slower gears are strictly easier to close. No spread spectrum, no runtime phase drift; if that cannot be guaranteed, rebuild `CLK_MODE=ASYNC` (violation is an integration error; not detected at runtime)
- ASYNC: CDC only via `hades_sram_sync2` / `hades_sram_qs_bus` / `hades_sram_rst_sync` (ASYNC_REG marked); `report_cdc` zero violations is the build acceptance (A1). MTBF: 2-flop synchronizers at ≤ 300 MHz with 3.3 ns first-stage bound — failure interval ≫ mission time (see also T13d sim: zero output-propagating metastability in 1e5 random setup/hold violations)
- Board clock control (M5-hw): `board_ctrl` register block at JTAG-AXI `0x0001_0000`: `CLK_DIV` (src cycles per port period), `CLK_CTRL` (bit0 GATE stop/run, bit8 COMMIT apply-at-next-wrap). Divider reloads only take effect through a commit strobe at a counter wrap, so an A10-style sweep never tears a multi-bit divider mid-period — every `port_clk` period has an exact integer length and the frequency monitor never sees a phantom over/under-frequency. Gate-off holds `port_clk` low (BUFGCE), which freezes the port domain; the cycle-accurate contract is in `port_clk` cycles, so stop/start is transparent (T13b mechanism, re-proven on hardware as A10)
- **ASYNC clock source on VCU1525 (deviation)**: all four onboard 300 MHz inputs share one crystal (SI53340 fanout buffer), so the ASYNC build's `port_clk` comes from a **second MMCM on `default_300mhz_clk1`** (100.00 MHz → divider 200/1000 for 500/100 KHz). This exercises the full ASYNC CDC logic but is *not* crystal-independent as spec A10b intends; the true-independence proof is T7/T13d simulation (incommensurate clocks, phase walk, ±0.5% drift). A PCIe-slot-refclk variant (`BOARD_CLKSRC_PCIE`) is prepared in the board RTL/XDC but its MGT refclk pin split is unverified (`fpga/vcu1525/pins_async_pcie.xdc` TODO)
- `CFG_MIN_PERIOD` / `P_MIN_PERIOD`: frequency interlock in `ui_clk` cycles (default 600 = 500 KHz)

## 5. CSR vs static variant

- `CSR_EN=1`: program per `csr/csr_regmap.md`; init sequence: wait `CALIB_DONE` → check `MEAS_PERIOD` against expected frequency → configure ports (indexed window) → `CFG_LATENCY`/`PORT_EN_*` → `ENABLE` → poll `STATUS.READY`.
- `CSR_EN=0`: no bus. Set parameters (`P_L`, `P_PORT_EN`, `P_MIN_PERIOD`, `P_REFRESH_DIV`, `P_ZQ_DIV`, `P_PORT_BASE`, `P_PORT_SIZE` — flat per-port vectors, any mix of bases/sizes). Auto-enables once calibrated with a healthy clock. Status pins: `stat_calib_done/ready/refresh_active/zq_active`, `stat_err[7:0]`; pin-level backdoor `bkp_*`.

## 6. SLR / placement [*M5-hw*]

VU9P = 3 SLRs. The MIG C0 controller+PHY is board-fixed in **SLR0** (C0 I/O banks). Intended methodology (spec DoD): pblock the HADES core into SLR2 so the ui_clk AXI4 paths cross the boundary once each way through registered interfaces — the worst integration scenario. **Toolchain finding (Vivado 2024.1): the MIG's built-in automatic pblock generation fails (Place 30-881/30-99) whenever a ranged user pblock exists in the design** — whole-SLR, CLOCKREGION, and sub-rectangle forms all reproduce it (see `fpga/vcu1525/pblock_slr2.xdc` for the full note and the integrator recipe). The production build therefore ships without a ranged pblock; SLR-crossing robustness is guaranteed by construction instead (M5-hw): every MIG-side input is registered at the HADES boundary (calib, refresh acks) and inside `hades_sram_mig_if` (R/B AXI channels), every HADES AXI output is a register — all crossings are FF→FF. A1 evidence: `fpga/vcu1525/build/*/reports/timing_summary.rpt` (WNS ≥ 0) and, for the ASYNC build, `cdc.rpt` (zero violations).

## 7. Backdoor content load/readout

CSR `BKP_*` registers (CSR_EN=1) or the `bkp_*` pins (CSR_EN=0) drive `hades_sram_backdoor`, a lowest-priority requester on the backend engines: it is served only when no port is eligible — the maintenance window and idle slots — so it never disturbs the per-port latency contract (T9). It works while the IP is disabled, which is how the 64 images are loaded before ENABLE. Register semantics in `csr/csr_regmap.md`.

64 ports × 16 MiB full initialization: 64 × 2^18 beats ≈ 16.8 M AXI beats ≈ 56 ms of backend bus time at full rate; the backdoor is additionally throttled by arbitration (maintenance windows + idle slots), so budget ≈ 0.1–0.2 s of chip time at 500 KHz with no target traffic. **Caveat on the JTAG-AXI host path (M5-hw):** each backdoor word costs several JTAG-AXI register transactions, so host-side throughput is the bottleneck (~10³–10⁴ words/s) — full 1 GiB initialization via backdoor is impractical on this host path; A3 uses a sparse-but-dense PRBS sweep per port (see the A3 acceptance note in §9), while full-bandwidth traffic proof is delegated to the on-chip selftest engines (A4/A5). On a future PCIe/XDMA host path the full traversal is seconds. (Mechanism sim-verified in M4.)

## 8. Known limitations

- All ports share one `port_clk` (per-port clocks are a future parameterization; cross-domain structures are already per-port)
- C1–C3 channels unused (multi-channel = documented expansion path when N exceeds one channel's slot budget)
- No caching/prefetch/write-combining (bandwidth usage ≈1.3% — unnecessary)
- L is global (per-group extension bits reserved)
- Backend fault model: a read unanswered for 768 `ui_clk` cycles completes with synthetic zeros and sets `ERR_STATUS.bit1` (liveness backstop; worst legal latency ≈ 136 cycles at full 64-port load — 5× margin). At L=2 the zero lands before the release edge, so the bit5 sentinel stays silent (bit1 is the alarm); at L=1 the sentinel fires first. A backend that is late-but-alive past the timeout is outside the legal model and may misroute the eventual response — treat bit1 as a fatal alarm.
- Host path is JTAG-AXI (M5-hw user decision): control-plane only; bulk-bandwidth acceptance runs on the on-chip selftest engines. The static variant (`CSR_EN=0`) has no selftest readout (errors accumulate in `PORT_STAT_ERR` but no bus exists to read them)
- ASYNC hardware build uses a second MMCM on the same-crystal clk1 (see §4 deviation); PCIe-slot-refclk variant prepared but pin-unverified
- ILA witnesses (A4/A6) sample 4 of 64 ports' request/rvalid + the refresh/AXI handshake; per-cycle correctness on all ports is the selftest engines' job (spec's ILA-is-sampling-only split)
- Dropping ENABLE with accepted-but-ungranted requests in flight trips the bit5 sentinel (host must quiesce first — see csr_regmap.md selftest section; same rule as for pin traffic)
- **Platform write-supply limit (DoD re-scope, user decision 2026-10-22)**: the fitted RDIMM (MTA18ASF2G72PZ) is x4-class and the VCU1525 `part0_pins.xml` routes no DM/DBI pins, so every 32-bit write is a MIG-internal read-modify-write; measured write supply ≈ 28M ops/s < 64-port full-load demand (32M/s). Reads are healthy at 64 ports (maxlat 255 ≪ 600-cycle budget). Verified full-load figure: **56 ports** (knee between 56 and 64 — at 64 the tail ports 50+ starve, ERR=0x04 overflow). Restoring 64-port full R+W load needs write coalescing (spec non-goal — parked, §9)
- **WSL2 wall-clock drift after crashes** (a 10 s sleep once measured 13.56 s real): acceptance durations and rates are cycle-domain or Windows-host-clock anchored (`host_now_s` in `fpga/vcu1525/host/common.tcl`); never use Tcl `clock` for long measurements on this host
- `BOARD_DIV_DEFAULT` is defined by `build.tcl` for ASYNC variants but consumed by no RTL — an ASYNC build boots at div 600 (166.7 KHz from the 100 MHz MMCM source) until the host sets the gear; benign (every acceptance leg sets the gear first)

## 9. Roadmap

| Milestone | Content | Tests |
|---|---|---|
| M1 (done) | Skeleton: pkg/CDC/freq-mon/CSR, empty datapath, CSR_EN variants | T6-basic, static smoke, bounds |
| M2 (done) | Full per-port datapath: hades_sram_port (CDC: Gray-FIFO + quasi-static slots), timing shaper (L=1/2, back-to-back), mig_if (FCFS AXI4 engine, 32-deep outstanding, sub-word lanes, stats + illegal/SLVERR/drop errors), AXI4 MIG model with refresh/periodic-read/ZQCS occupancy | T1 (1e5 ops), T2 (L=1/2 exact), T13a-lite — SYNC+ASYNC, CSR+static, VCS+xsim |
| M3 (done) | Refresh/ZQCS scheduling (window-geared debt scheduler, period tick), determinism guards; model maintenance now request-driven (+MAINT_STRESS / +RD_LAT_ADD knobs) | T2(L=1), T3 (+stress), T11 (5 legs), T14 — SYNC+ASYNC, CSR+static, VCS+xsim |
| M4 (done) | TDMA arbiter (static slot table, eligibility latches), backdoor (CSR + pins, lowest-priority requester), CFG_PORTS gear gating; T7 ASYNC phase walk + ±0.5% drift | T4 (64/32/16/8 + L=1), T5, T7 (100/500 KHz), T9, T11 — SYNC+ASYNC, CSR+static, VCS+xsim |
| M5-sim (done) | error paths, backend-timeout backstop, config reload, full CDC campaign, long regression, VCS coverage gate; fixed the 16-bit latency-counter wrap (false timeouts at each 2^16-cycle wrap) | T8, T10 (1e6 cycles, VCS), T12, T13 full, coverage line ≥95% / FSM 100% |
| M5-hw (done) | SELFTEST_EN on-chip checkers, VCU1525 build (SYNC+ASYNC), JTAG-AXI host path, IP package | A1–A10 |

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

## 11. VCU1525 production build (M5-hw)

`fpga/vcu1525/build.tcl` one-command build: `vivado -mode batch -source build.tcl -tclargs SYNC|ASYNC [PCIE|MMCM]` → `build/<tag>/hades_sram_vcu1525_<tag>.bit` + `.ltx` + `reports/` (timing summary, utilization, DRC, and `cdc.rpt` for ASYNC). A1 gates scripted: WNS ≥ 0; ASYNC additionally `report_cdc` with zero **unwaived Critical/Warning** violations (reviewed, justified dispositions in `fpga/vcu1525/cdc_waivers.tcl`, sourced post-route pre-report; Info-severity findings are recognized ASYNC_REG synchronizers kept as evidence, never waived). `impl_from_synth.tcl` re-implements from the post-synth checkpoint for iteration.

Architecture (`fpga/vcu1525/rtl/hades_sram_board_top.sv`):

```
CPU_RESETn ──invert──> MIG C0 (sys_rst)         DDR4 pins (board interface XDC)
300MHz sysclk0 ──────> MIG C0 ── ui_clk 300MHz ─┬─ hades_sram_top (N=64, CSR, SELFTEST_EN, SLR2 pblock)
                                               ├─ jtag_axi ─ board_axil_xbar ─┬─ 0x0000_0000 HADES CSR
                                               │                              └─ 0x0001_0000 board_ctrl
                                               ├─ board_clk_gen ── port_clk (SYNC: ui_clk/div; ASYNC: MMCM2/PCIe refclk)
                                               └─ ila_ui (refresh handshake + AXI + calib)
ILA port_clk (post-synth, debug_probes.xdc): rd_req/rvalid of ports 0..3
LEDs: 0=calib_done, 1=ui_clk heartbeat ~4.5Hz, 2=sticky SLVERR
```

- Host path: JTAG-AXI (`xilinx.com:ip:jtag_axi` in AXI4-Lite mode, single-outstanding) at `ui_clk`; `board_axil_xbar` 1→2 decode on address bit 16. Host scripts in `fpga/vcu1525/host/` (`vivado -mode batch -source host/<script>.tcl`, hw_server at `localhost:3121`).
- IP packager: `ip/package_ip.tcl` → `ip/hades_sram_1.0/` (catalog-verified + OOC synth of the packaged sources). Ships `constraints/hades_sram_clocks_{sync,async}.xdc` (sync auto-loads; async swap documented) and `csr/csr_regmap.md`.
- RTL style notes for the packager (do not regress): top-level ports use `input wire` (no compound `wire logic`); parameter defaults and port widths are plain literals, no package constants or constant-function calls (the packager's XPath parser rejects both).
- Debug probe nets for the port-domain ILA are marked via `fpga/vcu1525/debug_probes.xdc` (XDC files do **not** support `foreach` — marks are unrolled); the ILA core itself is created post-synthesis (probe1+ need `create_debug_port`; multi-probe ILA needs `ALL_PROBE_SAME_MU_CNT ≥ 2`).
- Vivado 2024.1 jtag_axi `PROTOCOL=2` = AXI4LITE (not 1). axi_interconnect is not parameterizable outside block designs in 2024.1 — hence the RTL crossbar.
- Full-design route time on KUMON-S1-HALO ≈ 1.5–2 h (VU9P + cross-SLR AXI); `route_design -directive AggressiveExplore`.

## 12. M5-hw board acceptance campaign (2026-10-20 .. 2026-10-23)

All legs at the re-scoped 56-port full load (§8) unless noted. Host scripts: `fpga/vcu1525/host/` (A2 a2_init, A4 a4_latency, A5 a5_soak, A6 a6_refresh, A7 a7_dualfreq, A8 a8_config, A9 a9_soak, A10 a10_clock).

### 12.1 Timing closure (300 MHz ui_clk, xcvu9p-2L)

| Iter | Route WNS | Key changes |
|---|---|---|
| 1–4 | −2.206 → +0.002 ns | mig_if RD/WR engines re-pipelined (IDLE→PICK→PREP→ISSUE/SYNTH→POP, fast re-pick 4 cyc/op); registered R/B view; per-ID AXI (16 IDs, 8-deep tracking FIFOs); bank-staggered port map; boundary regs + max_delay-datapath-only crossings; conditional post-route phys_opt + NoTimingRelaxation re-route |
| 6–9 | −0.038/−0.154/−0.106 → +0.045 ns | backdoor B_ACCEPT snapshot stage; lane-full eligibility mask (board A4 starvation finding); acc_port/acc_lane/acc_bkp acceptance-instant snapshot for pop routing; trk_* sync resets (X-race) |
| 9c | +0.045 ns | ILA probe taps MARK_DEBUG + DONT_TOUCH (phys_opt had stranded taps on dead replicas) |
| 10 | **+0.039 ns (SYNC ship)** | board_clk_gen gear commit = toggle *level* consumed at divider wrap — was a 1-cycle pulse sampled only at wraps, dropping ~99.7% of commits (the gear had never actually changed on board until this fix; caught by A7) |
| ASYNC | **+0.020 ns** | same core RTL; constraints/waivers per §12.3 |

Sim gates at ship: VCS 18/18 legs + coverage 99.77% line / 100% FSM; xsim 17/17 (iter-9b core RTL; 9c/10 touched board-only files).

### 12.2 Acceptance results

| Leg | Item | Result |
|---|---|---|
| A1 | build gates | SYNC WNS +0.039; ASYNC WNS +0.020 + report_cdc zero unwaived Critical/Warning (clean-flow rebuild reproduced both) |
| A2 | power-up init | PASS both builds (CALIB/READY, gear ±0.1%) |
| A4 | latency accuracy | **PASS @56** (L=1+L=2, PORT_STAT_ERR=0 on all 56, ERR_STATUS=0, ILA witness req→rvalid constant L+1, zero jitter). FAIL @64 root-caused → §8 write-supply limit → DoD re-scoped (user decision) |
| A5 | ≥10 min full load | PASS — 785 s host-anchored, 10.9G+10.9G ops, 0 errors, 36.6–37.1 °C |
| A6 | refresh rate | PASS — REFCNT 1,590,620 vs 1,578,413 expected (+0.77%), cycle-domain measurement |
| A7 | dual frequency | PASS both builds — 500 KHz + 100 KHz gears at L=1/2, 0 errors (exercises the iter-10 commit fix: MEAS_PERIOD settled at both gears) |
| A8 | config loop | PASS (SYNC) — L sweep, 16↔56 port-count sweep, over-freq interlock trips at min_period = div+5 |
| A9 | 8 h endurance | PASS — 28,925 s host-anchored, 401.8G+401.8G ops, 0 errors on all 48 polls, die 35.6–38.6 °C |
| A10 | clock stop/start + sweep | SYNC: PASS — 66 stop/start+sweep cycles in 1822 s / ASYNC: PASS — 66 cycles in 1821 s; both: zero traffic while gated, sweep 100–500 KHz with per-gear selftest |

### 12.3 ASYNC build lessons (constraints)

- **XDC is not full Tcl**: `if`/`foreach` are rejected (Designutils 20-1307) and *silently skipped* — the clk1_p fallback in `timing_async_cross.xdc` never ran, the async clock group came out empty, `set_clock_groups` was a no-op ("only one non-empty group"), and ~17.5k inter-clock paths got timed (route WNS −3.114 / WHS −4.476, 2 h 25 m route fight). Fix: source selection as one pattern list (`get_ports -quiet {pcie_refclk_p clk1_p}`); verified on the post-synth checkpoint (`report_clock_interaction`: all ui↔async crossings "Asynchronous Groups") before burning a rebuild.
- **Glob anchoring**: generate scopes join with `.` (`g_ports[i].u_port/...`), so `*/u_port/slot_data_u_reg*` never matches — qs_bus delay bounds now use bare patterns (verified 8192/256 cells on the checkpoint).
- **report_cdc disposition**: 17,772 raw findings; all Critical/Warning reviewed — qs_bus quasi-static crossings (config written only while quiesced; hold slots stable hold→release; 10 ns datapath bound), selftest_req broadcast (64 independent per-port synchronizers), async-FIFO LUTRAM arrays (gray pointers CDC-3-recognized), vendor IP internals (MIG reset filter, dbg_hub, ILA, JTAG-AXI). Waivers live in `fpga/vcu1525/cdc_waivers.tcl` with per-entry justification; the A1 gate counts *unwaived* Critical+Warning (must be 0) so any new unreviewed CDC fails the build.
- **Meas units**: the on-chip freq monitor counts ui_clk (300 MHz) cycles per port period; the divider counts src_clk cycles. SYNC ratio 1; ASYNC MMCM ratio 3 (div 200 = 500 KHz → MEAS_PERIOD 600); ASYNC PCIe ratio 6. Host scripts scale via `gear_ui_cycles` (env `HADES_SRC_UI_RATIO`).

### 12.4 Operational notes (this host)

- TCK 6 MHz mandatory (the 15 MHz default wedges the dbg_hub chain after long hot sessions)
- hw_server (Windows side) wedges after hours–days: restart from WSL via powershell stop/start; killed Vivado hw sessions can leave 99%-CPU cs_server orphans that wedge new sessions — `pkill` them; first connect after a restart takes 2–3 min
- Always associate the probes file (`HADES_LTX` or the default SYNC path): without it ILAs enumerate with generic names
- `hades_quiesce` (SELFTEST off → ≥16 port periods → SOFT_RESET) before every test — absorbs dirty state from a crashed previous session
- Long durations are Windows-host-clock anchored (§8 WSL2 drift)
- Run host scripts with output to a file: a truncated pipe (`| head`) SIGPIPE-kills Vivado mid-script
