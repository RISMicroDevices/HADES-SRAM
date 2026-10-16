//-----------------------------------------------------------------------------
// HADES-SRAM testbench — C++ side (DPI-C).
// Owns "test intent": expected-value models (ID/PARAMS, indexed-window
// register model), pass/fail accounting.  Pin-level protocol lives in
// sim/tb/tb_hades_top.sv.  Compiles for both VCS and Vivado xsim.
//-----------------------------------------------------------------------------
#include "svdpi.h"
#include <cstdint>
#include <cstdio>

namespace {

constexpr int kMaxPorts = 64;

int      g_err   = 0;
int      g_check = 0;
uint64_t g_base[kMaxPorts];
uint32_t g_size[kMaxPorts];

}  // namespace

extern "C" {

void hades_init() {
  g_err = 0;
  g_check = 0;
  for (int i = 0; i < kMaxPorts; i++) {
    g_base[i] = 0;
    g_size[i] = 0;
  }
  printf("[HADES-TB] C++ model initialized\n");
}

// ---------------------------------------------------------------- models ---

long long hades_exp_id() { return 0xADE50100LL; }

// PARAMS word: bit31=CLK_MODE(1=SYNC), [30:20]=ui_mhz, [19:12]=port_mib,
// [11:8]=dw/8, [7:0]=n_max
long long hades_exp_params(int is_sync, int ui_mhz, int port_mib, int dw, int n_max) {
  uint32_t v = ((uint32_t)(is_sync & 0x1) << 31) | (((uint32_t)ui_mhz & 0x7FF) << 20) |
               (((uint32_t)port_mib & 0xFF) << 12) | (((uint32_t)(dw / 8) & 0xF) << 8) |
               ((uint32_t)n_max & 0xFF);
  return (long long)(uint64_t)v;   // zero-extended: SV register reads are unsigned
}

void hades_set_port_cfg(int port, long long base, int size) {
  if (port >= 0 && port < kMaxPorts) {
    g_base[port] = (uint64_t)base;
    g_size[port] = (uint32_t)size;
  }
}

long long hades_exp_base(int port) { return (long long)g_base[port & (kMaxPorts - 1)]; }
int       hades_exp_size(int port) { return (int)g_size[port & (kMaxPorts - 1)]; }

// ---------------------------------------------------------------- checks ---

void hades_check_eq(const char* what, long long got, long long exp) {
  g_check++;
  if ((uint64_t)got != (uint64_t)exp) {
    g_err++;
    printf("[HADES-TB] FAIL: %-28s got=0x%llx exp=0x%llx\n", what,
           (unsigned long long)got, (unsigned long long)exp);
  } else {
    printf("[HADES-TB] ok:   %-28s = 0x%llx\n", what, (unsigned long long)got);
  }
}

void hades_check_range(const char* what, long long got, long long lo, long long hi) {
  g_check++;
  if (got < lo || got > hi) {
    g_err++;
    printf("[HADES-TB] FAIL: %-28s got=%lld, want [%lld, %lld]\n", what, got, lo, hi);
  } else {
    printf("[HADES-TB] ok:   %-28s = %lld in [%lld, %lld]\n", what, got, lo, hi);
  }
}

void hades_log(const char* msg) { printf("[HADES-TB] %s\n", msg); }

int  hades_err_count() { return g_err; }

void hades_report() {
  printf("[HADES-TB] checks=%d errors=%d\n", g_check, g_err);
}

}  // extern "C"
