// Minimal harness for the SMP Linux SoC top-level.
// This keeps the build flow working without depending on single-core signals.

#include "VVexRiscv.h"
#include "verilated.h"

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    VVexRiscv* top = new VVexRiscv;

    // Provide basic reset/clock toggles on the debug clock domain.
    top->debugCd_external_clk = 0;
    top->debugCd_external_reset = 1;
    top->eval();
    top->debugCd_external_reset = 0;

    for (int i = 0; i < 10; ++i) {
        top->debugCd_external_clk ^= 1;
        top->eval();
    }

    delete top;
    return 0;
}
