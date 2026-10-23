# HADES-SRAM simulation entry point.
#   make              -> SIM=vcs (default): all variants + T11 check_bounds
#   make SIM=xsim     -> same tests under Vivado xsim (reduced OPS)
#   make lint         -> xvlog/xelab elaboration gate, both CSR_EN variants
#   make check_bounds -> static slot-budget assertion spot-checks (T11)
#   make clean
#
# Variants:  csr (CSR_EN=1 SYNC) | csr_async (CSR_EN=1 ASYNC) |
#            static (CSR_EN=0 SYNC) | ovrd (CSR_EN=0 SYNC + param override) |
#            st (CSR_EN=1 SYNC + SELFTEST_EN=1: TEST=selftest smoke + a t2
#            pins-transparent sanity run)
# Extra runs per csr/csr_async/static build: T3 with +MAINT_STRESS=1 (worst
# maintenance alignment), T14 with +RD_LAT_ADD=1500 (bit5 sentinel fault),
# T8 with +DROP_RD_BEAT/+SLVERR_RD_BEAT/+SLVERR_WR_BEAT (error paths).
# T10 long regression: VCS csr 1e6 periods (spec), csr_async 1e5 smoke;
# xsim csr 5e4 smoke (VCS is the authoritative simulator for length).

SIM      ?= vcs
VCS      := /home/kumon/Synopsys/vcs/X-2025.06/bin/vcs
VIVADO   := /home/kumon/Xilinx/Vivado/2024.1
VIVADO_BIN := $(VIVADO)/bin
BUILD    := build

RTL := ../rtl/hades_pkg.sv ../rtl/hades_cdc.sv ../rtl/hades_freq_mon.sv \
       ../rtl/hades_selftest.sv ../rtl/hades_csr.sv ../rtl/hades_port.sv \
       ../rtl/hades_timing_shaper.sv \
       ../rtl/hades_mig_if.sv ../rtl/hades_refresh_sched.sv \
       ../rtl/hades_arbiter.sv ../rtl/hades_backdoor.sv ../rtl/hades_sram_top.sv
TB  := tb/tb_hades_top.sv
MDL := model/mig_axi4_model.sv
CPP := cpp/hades_tb.cpp

RTL_ABS := $(abspath $(RTL))
TB_ABS  := $(abspath $(TB))
MDL_ABS := $(abspath $(MDL))
CPP_ABS := $(abspath $(CPP))

OPS_vcs  := 100000
OPS_xsim := 10000

.PHONY: test test-vcs test-xsim lint check_bounds cov clean
# the one-command gate (spec section 7): full suite + bounds; coverage on VCS
ifeq ($(SIM),vcs)
test: test-$(SIM) check_bounds cov
else
test: test-$(SIM) check_bounds
endif

# ----------------------------------------------------------------- VCS -----
VCS_COMMON := -full64 -sverilog -timescale=1ns/1ps -top tb_hades_top

DEF_csr       :=
DEF_csr_async := +define+ASYNC
DEF_static    := +define+CSR_STATIC
DEF_ovrd      := +define+CSR_STATIC+PARAM_OVRD
DEF_st        := +define+SELFTEST

TEST_csr       := all_csr
TEST_csr_async := all_csr
TEST_static    := all_static
TEST_ovrd      := all_static
TEST_st        := selftest

VCS_VARIANTS := csr csr_async static ovrd st

$(BUILD)/vcs_%/simv: $(RTL) $(TB) $(MDL) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VCS) $(VCS_COMMON) $(DEF_$*) $(RTL_ABS) $(TB_ABS) $(MDL_ABS) $(CPP_ABS) \
	  -o simv > compile.log 2>&1 \
	  || { echo "VCS compile FAILED ($@)"; tail -40 compile.log; exit 1; }

test-vcs: $(foreach v,$(VCS_VARIANTS),$(BUILD)/vcs_$(v)/simv)
	@fail=0; \
	for v in $(VCS_VARIANTS); do \
	  case $$v in static|ovrd) t=all_static;; st) t=selftest;; *) t=all_csr;; esac; \
	  echo "=== VCS $$v TEST=$$t OPS=$(OPS_vcs) ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=$$t +OPS=$(OPS_vcs) > $(BUILD)/vcs_$$v/run.log 2>&1; \
	  grep -E "HADES-TB\] (FAIL|checks)" $(BUILD)/vcs_$$v/run.log | tail -8; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run.log \
	    && echo "VCS $$v: PASS" || { echo "VCS $$v: FAIL (see $(BUILD)/vcs_$$v/run.log)"; fail=1; }; \
	done; \
	for v in csr csr_async; do \
	  echo "=== VCS $$v TEST=t3 +MAINT_STRESS=1 ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=t3 +MAINT_STRESS=1 > $(BUILD)/vcs_$$v/run_t3s.log 2>&1; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run_t3s.log \
	    && echo "VCS $$v t3-stress: PASS" \
	    || { echo "VCS $$v t3-stress: FAIL (see $(BUILD)/vcs_$$v/run_t3s.log)"; fail=1; }; \
	done; \
	for v in csr csr_async static; do \
	  echo "=== VCS $$v TEST=t14 +RD_LAT_ADD=1500 ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=t14 +RD_LAT_ADD=1500 > $(BUILD)/vcs_$$v/run_t14.log 2>&1; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run_t14.log \
	    && echo "VCS $$v t14: PASS" \
	    || { echo "VCS $$v t14: FAIL (see $(BUILD)/vcs_$$v/run_t14.log)"; fail=1; }; \
	done; \
	for v in csr csr_async static; do \
	  echo "=== VCS $$v TEST=t8 (fault knobs) ==="; \
	  ./$(BUILD)/vcs_$$v/simv +TEST=t8 +DROP_RD_BEAT=7777 +DROP_RD_BEAT2=C0ACE +SLVERR_RD_BEAT=40555 \
	    +SLVERR_WR_BEAT=999 > $(BUILD)/vcs_$$v/run_t8.log 2>&1; \
	  grep -q HADES_TEST_PASS $(BUILD)/vcs_$$v/run_t8.log \
	    && echo "VCS $$v t8: PASS" \
	    || { echo "VCS $$v t8: FAIL (see $(BUILD)/vcs_$$v/run_t8.log)"; fail=1; }; \
	done; \
	echo "=== VCS csr TEST=ovf +AR_STALL_LEN=8000 ==="; \
	./$(BUILD)/vcs_csr/simv +TEST=ovf +AR_STALL_LEN=8000 > $(BUILD)/vcs_csr/run_ovf.log 2>&1; \
	grep -q HADES_TEST_PASS $(BUILD)/vcs_csr/run_ovf.log \
	  && echo "VCS csr ovf: PASS" \
	  || { echo "VCS csr ovf: FAIL (see $(BUILD)/vcs_csr/run_ovf.log)"; fail=1; }; \
	echo "=== VCS st TEST=t2 (engine idle: pins transparent) ==="; \
	./$(BUILD)/vcs_st/simv +TEST=t2 > $(BUILD)/vcs_st/run_t2.log 2>&1; \
	grep -q HADES_TEST_PASS $(BUILD)/vcs_st/run_t2.log \
	  && echo "VCS st t2: PASS" \
	  || { echo "VCS st t2: FAIL (see $(BUILD)/vcs_st/run_t2.log)"; fail=1; }; \
	echo "=== VCS st TEST=st_full +REF_BLOCK=300 (A4-in-sim: 64-port drain vs refresh) ==="; \
	./$(BUILD)/vcs_st/simv +TEST=st_full +REF_BLOCK=300 > $(BUILD)/vcs_st/run_st_full.log 2>&1; \
	grep -q HADES_TEST_PASS $(BUILD)/vcs_st/run_st_full.log \
	  && echo "VCS st st_full: PASS" \
	  || { echo "VCS st st_full: FAIL (see $(BUILD)/vcs_st/run_st_full.log)"; fail=1; }; \
	echo "=== VCS csr TEST=t10 T10_PER=1000000 (long regression) ==="; \
	./$(BUILD)/vcs_csr/simv +TEST=t10 +T10_PER=1000000 +WDOG_MS=4000 \
	  > $(BUILD)/vcs_csr/run_t10.log 2>&1; \
	grep -q HADES_TEST_PASS $(BUILD)/vcs_csr/run_t10.log \
	  && echo "VCS csr t10: PASS" \
	  || { echo "VCS csr t10: FAIL (see $(BUILD)/vcs_csr/run_t10.log)"; fail=1; }; \
	echo "=== VCS csr_async TEST=t10 T10_PER=100000 (reduced smoke) ==="; \
	./$(BUILD)/vcs_csr_async/simv +TEST=t10 +T10_PER=100000 +WDOG_MS=600 \
	  > $(BUILD)/vcs_csr_async/run_t10.log 2>&1; \
	grep -q HADES_TEST_PASS $(BUILD)/vcs_csr_async/run_t10.log \
	  && echo "VCS csr_async t10: PASS" \
	  || { echo "VCS csr_async t10: FAIL (see $(BUILD)/vcs_csr_async/run_t10.log)"; fail=1; }; \
	[ $$fail -eq 0 ] && echo "ALL VCS TESTS PASS" || exit 1

# ---------------------------------------------------------------- xsim -----
$(BUILD)/xsim_%/snap: $(RTL) $(TB) $(MDL) $(CPP)
	@mkdir -p $(@D)
	cd $(@D) && $(VIVADO_BIN)/xvlog --sv $(XSIM_DEF_$*) $(RTL_ABS) $(TB_ABS) $(MDL_ABS) > compile.log 2>&1 \
	  || { echo "xvlog FAILED ($@)"; tail -30 compile.log; exit 1; }
	cd $(@D) && g++ -shared -fPIC -static-libstdc++ -static-libgcc \
	  -I$(VIVADO)/data/xsim/include $(CPP_ABS) -o hadesdpi.so >> compile.log 2>&1
	cd $(@D) && $(VIVADO_BIN)/xelab --timescale 1ns/1ps -top tb_hades_top -snapshot snap \
	  -sv_root . -sv_lib hadesdpi >> compile.log 2>&1 \
	  || { echo "xelab FAILED ($@)"; tail -30 compile.log; exit 1; }

XSIM_DEF_csr       :=
XSIM_DEF_csr_async := --define ASYNC
XSIM_DEF_static    := --define CSR_STATIC
XSIM_DEF_ovrd      := --define CSR_STATIC --define PARAM_OVRD
XSIM_DEF_st        := --define SELFTEST

XSIM_VARIANTS := csr csr_async static ovrd st

test-xsim: $(foreach v,$(XSIM_VARIANTS),$(BUILD)/xsim_$(v)/snap)
	@fail=0; \
	for v in $(XSIM_VARIANTS); do \
	  case $$v in static|ovrd) t=all_static;; st) t=selftest;; *) t=all_csr;; esac; \
	  echo "=== xsim $$v TEST=$$t OPS=$(OPS_xsim) ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=$$t \
	    -testplusarg OPS=$(OPS_xsim) > run.log 2>&1; cd ../..; \
	  grep -E "HADES-TB\] (FAIL|checks)" $(BUILD)/xsim_$$v/run.log | tail -8; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run.log \
	    && echo "xsim $$v: PASS" || { echo "xsim $$v: FAIL (see $(BUILD)/xsim_$$v/run.log)"; fail=1; }; \
	done; \
	for v in csr csr_async; do \
	  echo "=== xsim $$v TEST=t3 MAINT_STRESS=1 ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t3 \
	    -testplusarg MAINT_STRESS=1 > run_t3s.log 2>&1; cd ../..; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run_t3s.log \
	    && echo "xsim $$v t3-stress: PASS" \
	    || { echo "xsim $$v t3-stress: FAIL (see $(BUILD)/xsim_$$v/run_t3s.log)"; fail=1; }; \
	done; \
	for v in csr csr_async static; do \
	  echo "=== xsim $$v TEST=t14 RD_LAT_ADD=1500 ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t14 \
	    -testplusarg RD_LAT_ADD=1500 > run_t14.log 2>&1; cd ../..; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run_t14.log \
	    && echo "xsim $$v t14: PASS" \
	    || { echo "xsim $$v t14: FAIL (see $(BUILD)/xsim_$$v/run_t14.log)"; fail=1; }; \
	done; \
	for v in csr csr_async static; do \
	  echo "=== xsim $$v TEST=t8 (fault knobs) ==="; \
	  cd $(BUILD)/xsim_$$v && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t8 \
	    -testplusarg DROP_RD_BEAT=7777 -testplusarg DROP_RD_BEAT2=C0ACE \
	    -testplusarg SLVERR_RD_BEAT=40555 -testplusarg SLVERR_WR_BEAT=999 > run_t8.log 2>&1; cd ../..; \
	  grep -q HADES_TEST_PASS $(BUILD)/xsim_$$v/run_t8.log \
	    && echo "xsim $$v t8: PASS" \
	    || { echo "xsim $$v t8: FAIL (see $(BUILD)/xsim_$$v/run_t8.log)"; fail=1; }; \
	done; \
	echo "=== xsim csr TEST=ovf AR_STALL_LEN=8000 ==="; \
	cd $(BUILD)/xsim_csr && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=ovf \
	  -testplusarg AR_STALL_LEN=8000 > run_ovf.log 2>&1; cd ../..; \
	grep -q HADES_TEST_PASS $(BUILD)/xsim_csr/run_ovf.log \
	  && echo "xsim csr ovf: PASS" \
	  || { echo "xsim csr ovf: FAIL (see $(BUILD)/xsim_csr/run_ovf.log)"; fail=1; }; \
	echo "=== xsim st TEST=t2 (engine idle: pins transparent) ==="; \
	cd $(BUILD)/xsim_st && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t2 \
	  > run_t2.log 2>&1; cd ../..; \
	grep -q HADES_TEST_PASS $(BUILD)/xsim_st/run_t2.log \
	  && echo "xsim st t2: PASS" \
	  || { echo "xsim st t2: FAIL (see $(BUILD)/xsim_st/run_t2.log)"; fail=1; }; \
	echo "=== xsim st TEST=st_full REF_BLOCK=300 (A4-in-sim: 64-port drain vs refresh) ==="; \
	cd $(BUILD)/xsim_st && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=st_full \
	  -testplusarg REF_BLOCK=300 > run_st_full.log 2>&1; cd ../..; \
	grep -q HADES_TEST_PASS $(BUILD)/xsim_st/run_st_full.log \
	  && echo "xsim st st_full: PASS" \
	  || { echo "xsim st st_full: FAIL (see $(BUILD)/xsim_st/run_st_full.log)"; fail=1; }; \
	echo "=== xsim csr TEST=t10 T10_PER=50000 (reduced) ==="; \
	cd $(BUILD)/xsim_csr && $(VIVADO_BIN)/xsim snap -R -testplusarg TEST=t10 \
	  -testplusarg T10_PER=50000 -testplusarg WDOG_MS=300 > run_t10.log 2>&1; cd ../..; \
	grep -q HADES_TEST_PASS $(BUILD)/xsim_csr/run_t10.log \
	  && echo "xsim csr t10: PASS" \
	  || { echo "xsim csr t10: FAIL (see $(BUILD)/xsim_csr/run_t10.log)"; fail=1; }; \
	[ $$fail -eq 0 ] && echo "ALL XSIM TESTS PASS" || exit 1

# ---------------------------------------------------------------- gates ----
# VCS coverage (DUT subtree only, see cm_hier.txt): line+fsm over the full
# CSR-variant test set on the SYNC build PLUS the static-variant build
# (covers the g_static branch), merged and gated at line >= 95% / FSM 100%
# (spec section 6.1).
COVDIR  := $(BUILD)/cov
COVDIRS := $(BUILD)/cov_static

$(COVDIR)/simv: $(RTL) $(TB) $(MDL) $(CPP) cm_hier.txt
	@mkdir -p $(COVDIR)
	@rm -rf $(COVDIR)/simv.vdb   # stale design+test data would mismatch
	cd $(COVDIR) && $(VCS) $(VCS_COMMON) -cm line+fsm -cm_hier $(abspath cm_hier.txt) \
	  $(RTL_ABS) $(TB_ABS) $(MDL_ABS) $(CPP_ABS) -o simv > compile.log 2>&1 \
	  || { echo "VCS cov compile FAILED"; tail -40 $(COVDIR)/compile.log; exit 1; }

$(COVDIRS)/simv: $(RTL) $(TB) $(MDL) $(CPP) cm_hier.txt
	@mkdir -p $(COVDIRS)
	@rm -rf $(COVDIRS)/simv.vdb
	cd $(COVDIRS) && $(VCS) $(VCS_COMMON) +define+CSR_STATIC \
	  -cm line+fsm -cm_hier $(abspath cm_hier.txt) \
	  $(RTL_ABS) $(TB_ABS) $(MDL_ABS) $(CPP_ABS) -o simv > compile.log 2>&1 \
	  || { echo "VCS cov-static compile FAILED"; tail -40 $(COVDIRS)/compile.log; exit 1; }

COV_RUN = cd $(1) && ./simv $2 -cm line+fsm -cm_name $3 >> cov_run.log 2>&1 \
            || { echo "cov run $3 FAILED ($(1))"; tail -20 $(1)/cov_run.log; exit 1; }

cov: $(COVDIR)/simv $(COVDIRS)/simv
	@rm -f $(COVDIR)/cov_run.log $(COVDIRS)/cov_run.log
	@$(call COV_RUN,$(COVDIR),+TEST=all_csr +OPS=100000,all_csr)
	@$(call COV_RUN,$(COVDIR),+TEST=t3 +MAINT_STRESS=1,t3s)
	@$(call COV_RUN,$(COVDIR),+TEST=t14 +RD_LAT_ADD=1500,t14)
	@$(call COV_RUN,$(COVDIR),+TEST=t8 +DROP_RD_BEAT=7777 +DROP_RD_BEAT2=C0ACE +SLVERR_RD_BEAT=40555 +SLVERR_WR_BEAT=999,t8)
	@$(call COV_RUN,$(COVDIR),+TEST=ovf +AR_STALL_LEN=8000,ovf)
	@$(call COV_RUN,$(COVDIR),+TEST=t10 +T10_PER=3000 +WDOG_MS=1200,t10)
	@$(call COV_RUN,$(COVDIRS),+TEST=all_static,all_static)
	@$(call COV_RUN,$(COVDIRS),+TEST=t14 +RD_LAT_ADD=1500,t14s)
	@$(call COV_RUN,$(COVDIRS),+TEST=t8 +DROP_RD_BEAT=7777 +DROP_RD_BEAT2=C0ACE +SLVERR_RD_BEAT=40555 +SLVERR_WR_BEAT=999,t8s)
	cd $(COVDIR) && $(dir $(VCS))urg -dir simv.vdb -dir ../cov_static/simv.vdb \
	  -report urg -format text -elfile $(abspath cov_excl.el) -excl_bypass_checks > urg.log 2>&1
	@echo "--- coverage summary (DUT modules) ---"
	@sed -n '/Total Module Definition Coverage Summary/,/Total modules/p' $(COVDIR)/urg/modlist.txt
	@python3 cov_check.py $(COVDIR)/urg/modlist.txt

lint:
	@mkdir -p $(BUILD)/lint_csr $(BUILD)/lint_static $(BUILD)/lint_st
	cd $(BUILD)/lint_csr    && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > compile.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "CSR_EN=1" >> compile.log 2>&1 \
	  && echo "lint csr:    ELAB OK" || { echo "lint csr FAILED"; tail -20 compile.log; exit 1; }
	cd $(BUILD)/lint_static && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > compile.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "CSR_EN=0" >> compile.log 2>&1 \
	  && echo "lint static: ELAB OK" || { echo "lint static FAILED"; tail -20 compile.log; exit 1; }
	cd $(BUILD)/lint_st     && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > compile.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "CSR_EN=1" \
	    -generic_top "SELFTEST_EN=1" >> compile.log 2>&1 \
	  && echo "lint st:     ELAB OK (SELFTEST_EN=1)" || { echo "lint st FAILED"; tail -20 compile.log; exit 1; }

check_bounds:
	@mkdir -p $(BUILD)/bounds
	@echo "--- N=64 @500KHz must PASS elaboration ---"
	@cd $(BUILD)/bounds && $(VCS) -full64 -sverilog -timescale=1ns/1ps $(RTL_ABS) \
	    -top hades_sram_top -o nb_ok64 > nb_ok64.log 2>&1 \
	  && echo "PASS: VCS accepted N=64@500KHz" \
	  || { echo "FAIL: N=64@500KHz should elaborate"; tail -20 nb_ok64.log; exit 1; }
	@echo "--- N=128 @500KHz must FAIL elaboration ---"
	@if cd $(BUILD)/bounds && $(VCS) -full64 -sverilog -timescale=1ns/1ps $(RTL_ABS) \
	    -top hades_sram_top -pvalue+hades_sram_top.N=128 -o nb_fail > nb_fail.log 2>&1; \
	  then echo "FAIL: budget assertion did not fire (VCS)"; exit 1; \
	  else echo "PASS: VCS rejected N=128@500KHz"; fi
	@if cd $(BUILD)/bounds && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > nb_xfail.log 2>&1 \
	    && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "N=128" >> nb_xfail.log 2>&1; \
	  then echo "FAIL: budget assertion did not fire (xelab)"; exit 1; \
	  else echo "PASS: xelab rejected N=128@500KHz"; fi
	@echo "--- N=128 @100KHz must PASS elaboration ---"
	@cd $(BUILD)/bounds && $(VCS) -full64 -sverilog -timescale=1ns/1ps $(RTL_ABS) \
	    -top hades_sram_top -pvalue+hades_sram_top.N=128 \
	    -pvalue+hades_sram_top.TARGET_PERIOD_CYCLES=3000 -o nb_pass > nb_pass.log 2>&1 \
	  && echo "PASS: VCS accepted N=128@100KHz" || { echo "FAIL: N=128@100KHz should elaborate"; exit 1; }
	@cd $(BUILD)/bounds && $(VIVADO_BIN)/xvlog --sv $(RTL_ABS) > nb_xpass.log 2>&1 \
	  && $(VIVADO_BIN)/xelab --timescale 1ns/1ps hades_sram_top -generic_top "N=128" \
	    -generic_top "TARGET_PERIOD_CYCLES=3000" >> nb_xpass.log 2>&1 \
	  && echo "PASS: xelab accepted N=128@100KHz" || { echo "FAIL: N=128@100KHz should elaborate (xelab)"; exit 1; }

clean:
	rm -rf $(BUILD)
