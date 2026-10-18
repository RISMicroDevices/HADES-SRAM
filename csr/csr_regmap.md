# HADES-SRAM CSR Register Map (CSR_EN=1)

AXI4-Lite slave, 32-bit data, `ui_clk` domain (300 MHz). On VCU1525 reached via the XDMA AXI4-Lite BAR (base 0x0_0000 by default). All offsets are byte offsets.

General rules (spec §3.3):
- Unimplemented bits and unlisted offsets read as 0; writes to them are ignored (no bus error, no side effect).
- All registers power-on to safe defaults: `ENABLE=0`, all ports disabled.
- `ENABLE` (CTRL.bit0) is rejected — stays 0 and sets `ERR_STATUS.bit4` — unless `CALIB_DONE && clk_running && !over_freq`.
- While enabled, losing the port clock or going over-frequency drops the effective enable and sets `ERR_STATUS.bit4`; the enable **auto-recovers** when the clock is healthy again (no software rewrite needed).
- `SOFT_RESET` (CTRL.bit1) is a self-clearing strobe: clears ENABLE, error and statistic accumulation; configuration registers are retained. The port-domain reset stretch (~2^14 `ui_clk` cycles + CDC) gates `ENABLE`: `STATUS.READY` reads 0 until the datapath has actually exited reset — after a SOFT_RESET, poll READY rather than assuming immediate availability.
- `CFG_LATENCY` takes effect on the next ENABLE 0→1 transition only.
- Backend read timeout (ERR_STATUS.bit1): a read with no backend response for 768 `ui_clk` cycles (worst legal is ~136 at full load, >5x margin) completes with synthetic zeros and sets bit1 — the IP never hangs. At L=2 the synthetic zero lands before the release edge (deadline 1200 cycles), so a dead backend surfaces as bit1 without the bit5 sentinel; at L=1 the sentinel fires first (deadline 600 < 768). A MIG that is late-but-alive past the timeout is outside the legal model.

## Global registers

| Offset | Name | Acc | Reset | Description |
|---|---|---|---|---|
| 0x00 | `CTRL` | RW | 0 | bit0 `ENABLE`; bit1 `SOFT_RESET` (self-clearing strobe) |
| 0x04 | `STATUS` | RO | — | bit0 `CALIB_DONE`; bit1 `READY` (effective enable); bit2 `REFRESH_ACTIVE`; bit3 `ZQ_ACTIVE` |
| 0x08 | `CFG_LATENCY` | RW | 2 | Read latency L in `port_clk` cycles, bits[1:0] ∈ {1,2}; illegal values ignored; bits[8:15] reserved for per-group extension |
| 0x0C | `CFG_PORTS` | RW | 0 | Active port count (≤ N_MAX), bits[7:0] |
| 0x10 | `MEAS_PERIOD` | RO | — | Measured `port_clk` period in `ui_clk` cycles (continuous frequency meter) |
| 0x14 | `PORT_EN_LO` | RW | 0 | Port enable bitmap, ports 31:0 |
| 0x18 | `PORT_EN_HI` | RW | 0 | Port enable bitmap, ports 63:32 |
| 0x1C | `CFG_MIN_PERIOD` | RW | 600 | Shortest allowed `port_clk` period in `ui_clk` cycles (600 = 500 KHz); measured period below this ⇒ `over_freq`, ENABLE rejected |
| 0x40 | `CFG_REFRESH_DIV` | RW | 2100 | Refresh slot interval in `ui_clk` cycles (2100 = 7 µs @ 300 MHz) |
| 0x44 | `CFG_ZQ_DIV` | RW | 32000 | ZQCS interval in target periods (32000 ≈ 64 ms @ 500 KHz) |
| 0x50 | `ERR_STATUS` | W1C | 0 | bit0 illegal address; bit1 backend timeout; bit2 dropped request (must stay 0); bit3 AXI SLVERR; bit4 ENABLE rejected / clock lost while armed; bit5 response-window sentinel (must stay 0); bits[13:8] = first-error port number. All bits are **event-latched**: a W1C clear sticks (the per-port sticky state in `PORT_STAT_ERR`/`stat_err` is independent and need not be cleared first); a later new violation re-sets the bit. Clearing the last set bit also clears the port field and `ERR_ADDR` |
| 0x54 | `ERR_ADDR` | RO | 0 | First-error address (incl. port field) |
| 0x58 | `STAT_MAXLAT` | RO | 0 | Max observed backend read latency, `ui_clk` cycles |
| 0x5C | `STAT_REFCNT` | RO | 0 | Cumulative refresh count (cross-check refresh rate) |
| 0x60 | `STAT_TOT_RD_LO` | RO | 0 | Global read count [31:0] |
| 0x64 | `STAT_TOT_WR_LO` | RO | 0 | Global write count [31:0] |
| 0x68 | `STAT_TOT_RD_HI` | RO | 0 | Global read count [63:32] |
| 0x6C | `STAT_TOT_WR_HI` | RO | 0 | Global write count [63:32] |
| 0x80 | `ID` | RO | 0xADE50100 | Magic + version (v1.0) |
| 0x84 | `PARAMS` | RO | — | bit31 `CLK_MODE` (0=ASYNC, 1=SYNC); bits[30:20] ui_clk MHz; bits[19:12] default per-port MiB; bits[11:8] DW/8; bits[7:0] N_MAX |

## Indexed port window

Port-level registers never flatten into the address space. Write `PORT_SEL` first; subsequent accesses to `PORT_BASE*` / `PORT_SIZE` / `PORT_STAT_*` act on the selected port. `PORT_SEL` ≥ N_MAX ⇒ reads return 0, writes ignored.

| Offset | Name | Acc | Reset | Description |
|---|---|---|---|---|
| 0x20 | `PORT_SEL` | RW | 0 | Window selector, port index 0 … N-1 |
| 0x24 | `PORT_BASE` | RW | p·2^18 | Selected port base, 512-bit-beat address bits [31:0] |
| 0x28 | `PORT_BASE_HI` | RW | 0 | Selected port base bits [33:32] |
| 0x2C | `PORT_SIZE` | RW | 2^22 | Selected port size in **DW-bit words** (2^22 words = 16 MiB at DW=32) |
| 0x30 | `PORT_STAT_RD` | RO | 0 | Selected port read count |
| 0x34 | `PORT_STAT_WR` | RO | 0 | Selected port write count |
| 0x38 | `PORT_STAT_ERR` | RO/W1C | 0 | Selected port error count (illegal addr / timeout / SLVERR); any write clears it |

## Backdoor channel

Host-side content load/readout without the target ports (spec §3.3). The engine (`hades_backdoor`) translates `port`+word-address exactly like a port access and enters the backend as the **lowest-priority requester** — it is served only in the maintenance window and idle slots, so in-flight target traffic never feels it (T9 checks `ERR_STATUS` stays 0 under concurrent backdoor+traffic). It works while the IP is disabled (pre-ENABLE initialization). Backdoor traffic counts in `STAT_TOT_*` but not in per-port stats; backdoor errors do not set `ERR_STATUS` bits.

| Offset | Name | Acc | Reset | Description |
|---|---|---|---|---|
| 0x90 | `BKP_PORT` | RW | 0 | Backdoor target port (0 … N_MAX-1) |
| 0x94 | `BKP_ADDR` | RW | 0 | Backdoor word address bits [31:0], in **DW-bit words** within the port |
| 0x98 | `BKP_ADDR_HI` | RW | 0 | Backdoor word address bits [39:32] |
| 0x9C | `BKP_WDATA` | RW | 0 | Backdoor write data (32-bit; for DW=64 only the low half of each word is reachable) |
| 0xA0 | `BKP_CMD` | WO | — | bit0 = write trigger, bit1 = read trigger (self-clearing strobes; clears `BKP_STATUS.done`) |
| 0xA4 | `BKP_RDATA` | RO | 0 | Backdoor read result, valid when `BKP_STATUS.done` |
| 0xA8 | `BKP_STATUS` | RO | 0 | bit0 busy, bit1 done (sticky until the next command), bit2 error — port ≥ N_MAX or address ≥ `PORT_SIZE`; an illegal command completes immediately with no AXI traffic |

Command sequence: write `BKP_PORT`/`BKP_ADDR`/`BKP_WDATA` → write `BKP_CMD` → poll `BKP_STATUS.done` (or wait for the `bkp_ack` pin on the static variant) → read `BKP_RDATA` on reads. Commands issued while busy are ignored. Static variant: drive `bkp_port/addr/wdata/we` and pulse `bkp_req` (hold until `bkp_ack`); the static pins have no error flag — an illegal access acks immediately with undefined `bkp_rdata`.

# Static variant (CSR_EN=0) — parameters instead of registers

With `CSR_EN=0` there is no bus interface. The whole configuration is hard-wired from elaboration parameters, and the block auto-enables when `calib_done && clk_running && !over_freq`.

| Parameter | Default | Mirrors | Notes |
|---|---|---|---|
| `P_L` | 2 | `CFG_LATENCY` | read latency in `port_clk` cycles |
| `P_PORT_EN` | all ones | `PORT_EN_*` | per-port enable bitmap |
| `P_MIN_PERIOD` | 600 | `CFG_MIN_PERIOD` | frequency interlock |
| `P_REFRESH_DIV` | 2100 | `CFG_REFRESH_DIV` | |
| `P_ZQ_DIV` | 32000 | `CFG_ZQ_DIV` | |
| `P_PORT_BASE` | equal 16 MiB partitions | `PORT_BASE[+HI]` per port | **flat packed vector** `[N_MAX*34-1:0]`; port i = bits `[i*34 +: 34]`; 512-bit-beat units; fully user-overridable per port |
| `P_PORT_SIZE` | 2^22 per port | `PORT_SIZE` per port | flat packed vector `[N_MAX*32-1:0]`; port i = bits `[i*32 +: 32]`; **DW-bit word** units (2^22 = 16 MiB at DW=32) |

Status is exposed on pins instead of a bus: `stat_calib_done`, `stat_ready`, `stat_refresh_active`, `stat_zq_active`, `stat_err[7:0]` (level-style mirror of `ERR_STATUS[5:0]`; bit4 = enable withheld because the clock is stopped/over-freq). A pin-level backdoor port (`bkp_req/we/port/addr/wdata/rdata/ack`) keeps content load/readout possible without a bus: hold the fields stable, raise `bkp_req` until `bkp_ack` pulses, then drop it; reads return `bkp_rdata` with the ack.

Flat vectors are used (not SV array parameters) because they elaborate identically in VCS, xelab, Vivado synthesis, and survive the Vivado IP packager GUI.
