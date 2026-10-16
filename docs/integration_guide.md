# HADES-SRAM Integration Guide

Status: **M1 skeleton** (sections marked [*M-later*] are filled by the named milestone).

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
| M2 | Single-port datapath, mig_if, timing shaper, AXI4 model | T1, T2(L=2), T13a |
| M3 | Refresh/ZQCS scheduling, determinism guards | T2(L=1), T3, T11, T14 |
| M4 | TDMA arbiter, N=8→32→64, backdoor | T4, T5, T7, T9, T11 |
| M5 | Hardening, coverage, VCU1525 acceptance, IP package | T8–T13, A1–A10 |
