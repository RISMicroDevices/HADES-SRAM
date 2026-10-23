# HADES-SRAM — ui_clk (300 MHz) pipelining feasibility study

Date: 2026-10-21. Scope: read-only analysis of pipelining options for 300 MHz closure on the
VCU1525 SYNC build, the 250 MHz fallback, and a ranked recommendation. No RTL/sim/build files
were modified.

## 0. Evidence base

- Full read of `rtl/hades_mig_if.sv` (900 lines), `hades_arbiter.sv`, `hades_refresh_sched.sv`,
  `hades_port.sv`, `hades_timing_shaper.sv`, `hades_csr.sv`, `hades_backdoor.sv`, `hades_cdc.sv`,
  `hades_freq_mon.sv`, `hades_pkg.sv`, `hades_sram_top.sv`; spec §1/§3/§4
  (`HADES-SRAM_PlanMode.md`); `fpga/vcu1525/build.tcl`, `timing_sync.xdc`, `mig_config_prod.txt`;
  `sim/Makefile`, `sim/model/mig_axi4_model.sv`, `sim/tb/tb_hades_top.sv`.
- `fpga/vcu1525/build/sync/reports/timing_summary.rpt` does not exist: the iter-6 build
  (lane_full/wl_full registered flags) is in flight — started 17:09, in route at analysis time;
  its intermediate route summaries (−0.36…−0.46 ns) are pre-cleanup numbers and are not
  predictive of final WNS.
- One read-only Vivado query was run against a `/tmp` copy of the preserved last-known-good
  checkpoint `fpga/vcu1525/build/sync_lastmile/post_route_lastmile.dcp` (the iter-4 last-mile
  result, pre-dating today's RTL edits: `hades_refresh_sched.sv` 13:18, `hades_arbiter.sv` 14:21,
  `hades_mig_if.sv` 16:56). The live build directory was not touched. Results:
  - **WNS +0.002 ns, TNS 0, 0 / 197,868 setup endpoints failing; hold clean.** All constraints met.
  - The 40 hottest paths (slack ≤ +0.029 ns) are **all one family** in `u_mig_if`:
    36 × `rid_q_reg[*]` → `rsp_data_reg[*][*]/D` and 4 × `rid_q_reg[*]` → `stat_maxlat_reg[*]/CE`.
    Representative path: 9 logic levels (LUT6×3, MUXF7×3, MUXF8×2, LUT5), **route 80 %** of the
    3.325 ns data delay — `rid_q → trk_lane[h_id][trk_rptr[h_id]] head mux → 512:32 barrel
    shifter → rsp_data[port] D`. The `stat_maxlat` variant adds CARRY8×3 (the
    `cyc_cnt − trk_ts[…]` subtract) plus the max compare into the CE.
  - `report_high_fanout_nets`: **`rid_q[0]` and `rid_q[1]` each fan out to 932 pins** (the select
    of the 16-lane × 8-entry head muxes for `trk_port/trk_lane/trk_ts/trk_synth` plus
    `lane_open`/maxlat consumers). Reset structure: one `ui_rst` replica drives 15,871 SR pins,
    a second copy sits on a BUFG with 7,661 — tool-managed replication is already in effect.
- iter-5 reference point (`fpga/vcu1525/vivado_938083.backup.log`): WNS **−0.180** after the
  post-route phys_opt + NoTimingRelaxation loop, with the documented worst cone
  "port-FIFO CDC sync registers → request mask (`vld & port_en & enable`) → 64-input OR → live
  per-lane counter mux + full compare → state gate → `rd_pick_q`/`wr_pick_q` CE (13 levels)".
  iter-6 (in flight) replaces the "live counter mux + compare" segment with a 16:1 mux of
  registered `lane_full`/`wl_full` bits (`rtl/hades_mig_if.sv:217-223`, maintenance at
  `:724-753`), removing ~3–4 of those 13 levels.

Takeaway: in the *passing* build the design sits at **zero margin**, and its structural floor is
the **pop_real response datapath**, not the request front-end. iter-5/6 show the front-end pick
cone is the *swing* family. Both are addressed below.

## 1. Candidate pipeline points

### C1 — Request front-end snapshot pipe (rd/wr pick path) — PRIMARY

- **Location**: `rtl/hades_mig_if.sv:230-246` (read) and `:388-396` (write); consumers at
  `RD_IDLE` `:300-305`, `RD_POP` `:344-351`, `WR_IDLE` `:474-478`, `WR_POP` `:514-521`.
- **The cone**: port FIFO `rempty` (Gray-pointer equality off the `hades_sync2` stages,
  `rtl/hades_cdc.sv:192`, `rtl/hades_port.sv:134`) → arbiter slot gate `rd_vld_i[i] & rd_open[i]`
  (`rtl/hades_arbiter.sv:106`) → `rd_vld[i] & cfg.port_en[i] & enable` (`:231`) → `& ~rd_gnt`
  live-grant mask (`:243`) → 64-input OR (`:244`) + 64:1 `first_set` (`:209-215`) →
  `pick==BKP_ID` compare → `lane_full[pick]` 16:1 mux (`:301`,`:345`) → `rd_pick_q`/`rd_state`
  CE/D. ~13 levels with long routes from the spread-out port array (iter-5 WNS cone).
- **The cut**: register the masked request view every cycle, and — the crucial detail — mask the
  **about-to-fire** grant instead of the live grant pulse:
  ```
  // rd_push already exists (:226) and exactly names every cycle that sets rd_gnt next cycle
  rd_req_m_q  <= rd_req_masked & ~(rd_push ? onehot(rd_sel) : '0);   // port x excluded from T+1 on
  rd_any_q    <= |rd_req_m;                                          // OR64 moves to a full-cycle D cone
  rd_pick_q2  <= first_set(rd_req_m);                                // priority encode moves off the path
  ```
  `rd_push` at `:226` is `(RD_ISSUE && arvalid && arready) || RD_SYNTH` — precisely the condition
  under which `rd_gnt[rd_sel]`/`bkp_rd_gnt` is registered at `:326-327`/`:338`. The snapshot taken
  at the end of the ISSUE/SYNTH cycle therefore already excludes the granted port when `RD_POP`
  consumes it one cycle later — preserving the exact semantics of today's live `& ~rd_gnt` mask
  (the arbiter's `rd_open` latch and the FIFO head both clear one cycle after the grant, so the
  port is double-masked from the next cycle on, exactly as now). Backdoor folds in symmetrically
  (`bkp_rd_req && !(rd_push && rd_sel==BKP_ID)`). POP/IDLE then evaluate
  `rd_any_q && !lane_full[rd_pick_q2[3:0]]` — **snapshot register → 16:1 mux of registered bits →
  CE ≈ 3–4 levels**, and the OR64/first_set compute in a free-running full-cycle D-cone where
  even 10 levels fit 3.332 ns.
- **4-cycle re-pick spacing**: preserved. Under load the loop POP→PICK→PREP→ISSUE→POP stays
  4 cycles/op; picks draw from a snapshot refreshed every cycle, so a request becomes pickable
  one cycle after it becomes eligible (today: same cycle). Whole-drain shift ≤ 1–2 cycles,
  inside the budget's MARGIN (current slack 600−546 = 54 cycles).
- **Slot-schedule legality**: the 1-cycle-older eligible view can carry a pick across
  `period_tick` — but the in-flight PICK→ISSUE already does that today (grant lands after the
  tick while `rd_open` cleared at the tick); behavior is the same class, and the request itself
  stays valid (FIFO head is held until grant).
- **Est. gain**: −9 to −11 logic levels on both engines' pick CE/D cones; also de-routes the
  64-source CDC fan-in from the state FFs. This converts the iter-5 failing family outright.
- **Latency cost**: +1 ui cycle worst-case grant latency. Contract-safe (backend-internal; the
  deterministic contract is counted in port_clk periods at the shaper, and the slot budget has
  54 cycles of explicit MARGIN).
- **Functional risk**: MODERATE. The `gnt_next` decode must mirror grant conditions bit-exactly
  (including BKP_ID and the SYNTH grant) or the double-grant bug the live mask was built to kill
  (`:234-242`) returns. Small, reviewable delta (~30 lines, one module).
- **Sim re-verification**: full `make -C sim` (VCS 5 variants + T3-stress/T8/T14/ovf/st_full
  extras + T10 1e6-period regression + `check_bounds` + coverage gate) + `make -C sim lint`.
  The TB's per-cycle phase checker makes any scheduling drift a hard failure, so a green suite
  is strong evidence.

### C2 — pop_real head-descriptor registers (fall-through head cache) — PRIMARY (margin floor)

- **Location**: live head reads `rtl/hades_mig_if.sv:547-555` (`trk_port/trk_lane/trk_ts/
  trk_synth[h_id][trk_rptr[h_id]]`, `lane_empty`); consumers: pop fire block `:676-720`,
  `stat_maxlat` `:867-868`, `err_*` `:878-885`.
- **The cone** (dcp-proven #1, +0.002 ns in the passing build): `rid_q` (932-pin fanout) →
  128:1 head muxes (~3 MUXF levels, nets physically spanning ~14 CLB columns) → 512:32 lane
  shifter (~4–5 levels, shared with `bkp_rd_data`) → 64-port demux → `rsp_data` D; and the
  `trk_ts` mux → 16-bit subtract (CARRY8×3) → 32-bit compare → `stat_maxlat` CE (10 levels).
- **The cut**: maintain per-lane head descriptors in registers:
  ```
  hd_port_r[l], hd_lane_r[l], hd_ts_r[l], hd_synth_r[l], hd_mt_r[l]
  ```
  updated only on lane events: push into an empty lane loads the pushed descriptor (all sources
  registered: `rd_sel/rd_lane/cyc_cnt`); any pop (`popv[l]`, `:644-664`) loads entry
  `trk_*[l][trk_rptr[l]+1]` — a full-cycle D-cone read, not a fire-path read. One bypass corner:
  push+pop on a lane with `cnt==1` must forward the pushed descriptor (the array read would
  return the pre-push value). The pop/fire path then reads `hd_*_r[rid_q]`: a 16:1 mux of
  registers (~2 levels) — `rid_q` fanout collapses from 932 to ~70 pins and the muxes cluster
  next to the shifter.
- **Staleness**: none by construction for real pops — unlike the `hd_*_q` snapshot (`:569-581`),
  which lags a pop by 2 cycles and therefore can only serve synth/timeout pops, these registers
  update on the pop edge itself and are exact for back-to-back same-lane beats.
- **Est. gain**: −3 to −4 levels and −80 %-class route on the `rsp_data` D cone (9 levels,
  route-dominated → ~6, physically local); `stat_maxlat` CE cone 10 → ~6 levels.
- **Latency cost**: 0.
- **Functional risk**: MODERATE-HIGH — the update must cover all three pop sources
  (`pop_real/fire_synth/fire_tmo`) plus both push types plus the cnt==1 bypass; a tracking bug
  misroutes response data. Mitigation: the TB scoreboard checks per-port data on every response
  (T1/T2/T5/T9), and fault paths (T8/T14) exercise synth/tmo pops heavily.
- **Sim re-verification**: full `make -C sim`.

### C3 — Response output pipe stage (RSP_PIPE) — pairs with or substitutes for C2

- **Location**: `rsp_vld`/`rsp_data`/`bkp_rd_done`/`bkp_rd_data` fire at `rtl/hades_mig_if.sv:
  694-718`.
- **The cut**: keep the pop (rptr/counters/`popv`) on the exact accepted-beat cycle — required,
  since `rvalid_q` is a 1-cycle window — but capture `{head_port, head_lane, rdata_q}` into
  `rdata_qq`/`port_qq`/`lane_qq` and fire `rsp_vld`/`rsp_data` one cycle later. The shifter then
  computes from registers only, in its own cycle: cone ≈ 5 levels, all local; no head mux, no
  `rid_q` on the rsp D cone at all. Back-to-back pops pipeline cleanly (one R channel ⇒ ≤1
  pop/cycle; same-port consecutive responses are separate cycles and legal). The synth/timeout
  path (`:704-718`) can stay as-is (different cycles; ≤1 outstanding read per port by contract
  prevents same-port same-cycle collisions with the piped real path — assert this in sim).
  `stat_maxlat`/`err_*` stay on the live pop cycle.
- **Est. gain**: rsp family → ~5 levels even without C2; with C2 the shifter input mux shrinks
  further. **Latency cost**: +1 ui cycle response delivery — contract-safe: the hold slot is
  sampled by the port_clk shaper ≥ 1.37 µs later (spec §1), and the slot budget absorbs it.
  **Risk**: LOW-MODERATE (~25 lines). **Sim**: full suite.

### C4 — `first_set` tree restructure (`:209-215`)

The ripple loop maps to a LUT+MUXF7/F8 cascade. A balanced tree (8 groups of 8 + 8:1 combine)
saves ~2–4 serial elements with **zero latency and zero functional risk** (pure combinational
equivalence). **Only worth doing standalone if C1 is rejected** — with C1 the encode leaves the
critical path entirely.

### C5 — trk array structure (`:166-172`)

16 lanes × 8 entries of {8,6,16,1}-bit FF arrays. Do not convert to LUT-RAM (the multi-source
variable-index write structure doesn't map, and async-read DRAM still leaves a select cone).
The right "banking" is C2's head cache; after C2 the arrays are read only in full-cycle D-cones.
No separate action.

### C6 — CSR readback muxes (`rtl/hades_csr.sv:161-205`)

`s_axil_rdata` is combinational: case decode + 64:1 32-bit muxes on `port_stat_*`/quasi-static
config, off the registered `ar_a`, into the JTAG-AXI master at ui_clk. Not in the dcp top-40;
if it surfaces post-C1–C3, register `s_axil_rdata` (+1 AXI-Lite read cycle — host-paced,
invisible). The counter-increment side is already fixed (registered one-hots, mig_if
`:758-824`). Low priority.

### C7 — Refresh scheduler / arbiter combinational outputs

`period_tick` (`hades_refresh_sched.sv:68`) is 1 LUT off sync registers; fanout ~130
(arbiter `per_cnt` + 128 latch clears + zq counter) but 1–2 logic levels — fine.
`slots_done`/`maint_fire_ok` (`hades_arbiter.sv:64-80`) are 16-bit compares off the registered
`per_cnt` and quasi-static cfg (~3 levels) into the refresh FSM — fine. `backend_idle`
(`hades_mig_if.sv:415-429`) keeps the live `rd_any/wr_any` OR64s; its sink is the idle-gated
refresh FSM, not a WNS cone — keep it live (a late-asserted idle view is the safe direction).
Optional insurance only: register `maint_fire_ok`. No action now.

### C8 — port/shaper side — confirmed irrelevant to 300 MHz closure

Everything in `hades_timing_shaper.sv` and the port_clk half of `hades_port.sv` runs at
100–500 KHz: the routed dcp shows the port_clk domain at WNS **+1992.986 ns** (51,731
endpoints). The only ui_clk-side logic in `hades_port` is the FIFO read side (`rempty` Gray
compare — the *source* of the C1 cone, cut there) and the response slot-write CE (1 level,
`:203-221`). No work.

### C9 — ui_rst / high-fanout control nets

Dcp evidence: one `ui_rst` fabric replica at 15,871 SR pins + a BUFG-routed copy at 7,661 —
place/phys_opt (`ExtraNetDelay_high` + `AggressiveFanoutOpt`, `build.tcl:155-168`) already
manage this, and no R-pin cone appears in the top-40. RTL-level insurance if route near-misses
persist after C1–C3: instantiate per-cluster `hades_rst_sync` replicas in `hades_sram_top`
(e.g., 4 port quadrants + mig_if + csr/arbiter/refresh) — identical assert/deassert timing from
the same source, style-rule clean (still synchronous), deterministic drivers of ~2k loads each.
Also consider an `enable_eff` replica pair. Defer unless needed.

## 2. Parameterization

- **C1 (`REQ_PIPE`)** and **C3 (`RSP_PIPE`)**: cleanly parameterizable — each is a
  `generate` choosing a registered vs live view at one or two signal boundaries (~10 extra
  lines each). A build-time A/B knob is legitimate *during bring-up*.
- **C2 (head cache)**: do **not** parameterize — the maintenance/bypass logic must exist in
  both modes and a mode switch doubles the highest-risk code for no shipped benefit.
- Recommendation: land the changes **unconditionally** once sim-green (git history is the A/B
  record). Every always-on parameter doubles the sim variant matrix (already 5 builds × extras)
  and leaves dead paths in a DoD-gated IP. If a knob is wanted for the first board bring-up,
  use a `define`, and remove it before `ip/package_ip.tcl` packaging (no `TODO`/dead logic in
  `rtl/` per spec §7).

## 3. Feasibility verdict — 300 MHz

**YES — conditional, and the conditions are concrete:**

1. iter-6 (in flight) may already pass; its intermediate route numbers are not predictive. The
   passing iter-4 build proves the architecture closes at 300 MHz — with **zero margin**
   (+0.002 ns, 129,108 ui_clk endpoints).
2. If iter-6 misses or scrapes: **C1** deterministically removes ~9–11 levels from exactly the
   cone family that failed at −0.180 (iter-5) — this is a logic-level fix, not a directive
   lottery.
3. Regardless of iter-6: **C3** (and ideally **C2**) should land before the A2–A10 hardware
   campaign. The dcp proves the pop_real family is the zero-margin floor of *every* build;
   buying 3–5 levels and collapsing the 932-pin `rid_q` select converts "passes by 2 ps" into
   the ≥ +0.1–0.2 ns headroom that build-to-build variance on a 3-SLR VU9P demands.

Residual risk after C1+C2+C3: (a) route-dominated near-misses remain possible on the
SLR0-MIG boundary, but every crossing is already FF→FF by construction (integration_guide §6);
(b) high-fanout reset/enable nets rely on tool replication — C9 is the staged insurance;
(c) one full sim regression + one ~2 h bitstream build per landing. Timing-closure risk after
the three cuts is LOW. No pblock (ranged pblocks are forbidden — Place 30-881/30-99), no new
dependencies, SV-2012/2-process-FSM style preserved.

Note on timing: no A2–A10 evidence exists yet (M5-hw in flight), so RTL changes now invalidate
nothing — this is the cheapest possible window for C1–C3.

## 4. The 250 MHz fallback (and a better middle option)

**MIG feasibility — confirmed compatible.** ui_clk is hard-geared 4:1 to the memory clock
(PG150), so 250 MHz ui ⇔ DDR4 at tCK = 1000 ps ("DDR4-2000"). The installed MIG part-database
entry for the VCU1525 RDIMM `MTA18ASF2G72PZ-2G3` declares **min period 833 ps / max 1600 ps**
(`/home/kumon/Xilinx/Vivado/2024.1/data/ip/xilinx/mem_v1_4/csv/ddr4_sdram/memparts.csv:37`),
so `CONFIG.C0.DDR4_TimePeriod=1000` is a legal derate of the stock part — no custom-part CSV,
same pins/board preset; MIG recomputes CL/CWL (tCK 1000 ps sits in the JEDEC DDR4-2133 bin
envelope 938–1071 ps, which any -2G3 part must support). Bandwidth is a non-issue either way
(16 GB/s raw vs 0.26 GB/s required).

**What changes (cycle-domain constants scale by 5/6):**
- `hades_pkg.sv`: `UI_CLK_MHZ` 300→250 (`:16`); `TARGET_PERIOD_500K` 600→**500**,
  `TARGET_PERIOD_100K` 3000→2500 (`:48-49`); ns-fixed reservations `MAINT_SLOTS` 150→~125,
  `FIRST_LAT` 36→~30, `MAINT_BLOCK_EST` 150→~125 (`:42-54`); `CDC_OVHD_SYNC`=4 and
  `SLOT_PER_PORT`=4 stay (CDC overhead is ns-fixed ≈ 13 ns ⇒ 3.3 cycles; engine cadence is
  clock-independent).
- **The slot budget then marginally FAILS the spec guardrail**: 125+30+4+256+100 = **515 > 500**
  (`budget_ok`, `hades_pkg.sv:67-71`; static assert `hades_sram_top.sv:138-145`; sim
  `check_bounds`). Fixing it requires MARGIN 100→≤84 — a spec-visible weakening of the §4.3
  guardrail and a documented deviation — or shaving `MAINT_SLOTS` toward the measured block max
  (~106 cycles at 250 MHz) which guts the head-window reserve. Tight either way.
- `hades_mig_if.sv:545` `TRK_TIMEOUT` 768→~640 (must stay > L=1 deadline 500, < L=2 edge 1000).
- CSR/param defaults: `refresh_div` 2100→**1750** (7 µs; `hades_csr.sv:227`,
  `hades_sram_top.sv:41`); `min_period` defaults follow `TARGET_PERIOD_500K`; `zq_div`
  unchanged (counts periods); PARAMS ui-MHz field follows `UI_CLK_MHZ`.
- `hades_freq_mon.sv:24` `STOP_TIMEOUT`=16384 still covers the 2500-cycle 100 KHz period ✓;
  OF_MARGIN=4 ✓. Soft-reset stretch 8192 cycles = 32.8 µs at 250 MHz (> 2 slowest periods ✓);
  the `evt_blk` 10000-cycle blanking (`hades_sram_top.sv:729-733`) needs a re-check against the
  stretched timing.
- Sim: MIG model cycle parameters ×5/6 (`sim/model/mig_axi4_model.sv:33-42`: RD_LAT_TYP 30,
  ROW_LAT 33, WR_LAT 17, REF_BLOCK 88, ZQ_BLOCK 27, PRD_BLOCK 10, PRD_PERIOD 831); TB `pc_div`
  600→500 (`tb_hades_top.sv:125`), MEAS_PERIOD expectations (`:663-669`), the per-test
  refresh_div 600→500 (`:849`) and the `exp_ref` formula (`:1450-1452`).
- FPGA/docs: `timing_sync.xdc` `divide_by 600`→500 (worst-case gear), host `CLK_DIV`
  programming, `mig_config_prod.txt` regeneration; spec §1 cycle arithmetic (500 cycles/period;
  port-capacity model ~85 ports @500 KHz), §4.3 constants, `integration_guide.md` §1/§3/§4/§8,
  `csr/csr_regmap.md` defaults. A-series: A1 easier; A4's op cadence unchanged (drain = 256 of
  500 cycles = 51 % vs 42.7 %; the refresh fire-deadline invariant `fire_latest +
  MAINT_BLOCK_EST = min_period + MAINT_SLOTS + FIRST_LAT` carries over exactly); A6/A7/A9
  thresholds re-derived; all hardware evidence re-collected.

**Better middle option — 266.7 MHz (DDR4-2133, tCK=938 ps)**: period 533 cycles;
125→133/30→32 scaling gives 133+32+4+256+100 = **525 < 533 with MARGIN=100 fully intact**
(+0.42 ns of clock period vs the −0.180 worst observed miss). Cost: the SYNC 500 KHz gear is
non-integer (ui/533 = 500.3 KHz — freq-mon/`min_period` retune; ASYNC unaffected). Document as
the contingency before 250 MHz.

**Verdict on the fallback**: it is real but strictly more expensive than the pipeline work —
a MIG re-spin, a guardrail deviation (at 250 MHz), sim-model retune, spec/regmap/guide churn,
and a full re-validation — to buy +0.83 ns of period, less than C1+C2+C3 deliver structurally.

## 5. Recommendation (ranked)

1. **Wait for iter-6** (in flight). If WNS < ~+0.1 ns, implement **C1** (front-end snapshot
   pipe): deterministic −9 to −11 levels on the exact failing family, +1 ui cycle inside the
   slot MARGIN, ~30 lines in one module. Re-run full `make -C sim` + lint + one bitstream
   build.
2. **Before A2–A10, land C3** (RSP_PIPE; cheap, low-risk) **and preferably C2** (head
   registers; kills the dcp-proven zero-margin floor and the 932-pin `rid_q` select). C2 first
   if only one: it also fixes `stat_maxlat` and needs no latency. If risk appetite is minimal:
   C3 alone still cuts the rsp family to ~5 local levels.
3. **C9** (reset/enable replicas) only if post-C1–C3 builds still show R/CE-pin route
   near-misses. **C4/C6/C7**: skip unless a future report names those cones.
4. **Do not move to 250 MHz now.** Keep 266.7 MHz (MARGIN intact) as the documented
   contingency if C1+C2+C3 somehow still miss; 250 MHz (MARGIN deviation required) only as the
   last resort.

Bottom line: with C1 (+C2/C3) the architecture closes 300 MHz robustly — the failing cones are
well-understood, shallow-after-cut structures, and every required change stays inside the slot
budget, the exact-cycle pop contract, and the coding rules.
