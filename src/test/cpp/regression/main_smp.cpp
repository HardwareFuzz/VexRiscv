// Minimal harness for the SMP Linux SoC top-level.
// SMP harness using a minimal driver for the SMP top-level.

#include "VVexRiscv.h"
#include "verilated.h"

static void toggle_debug_clock(VVexRiscv* top) {
    top->debugCd_external_clk = 0;
    top->eval();
    top->debugCd_external_clk = 1;
    top->eval();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VVexRiscv* top = new VVexRiscv;

    top->debugCd_external_clk = 0;
    top->debugCd_external_reset = 1;
    top->interrupts = 0;
    top->debugPort_tdi = 0;
    top->debugPort_enable = 0;
    top->debugPort_capture = 0;
    top->debugPort_shift = 0;
    top->debugPort_update = 0;
    top->debugPort_reset = 0;
    top->jtag_clk = 0;

    // No external memory model in this harness; keep buses idle.
    top->iBridge_dram_cmd_ready = 0;
    top->iBridge_dram_wdata_ready = 0;
    top->iBridge_dram_rdata_valid = 0;
    top->iBridge_dram_rdata_payload_data[0] = 0;
    top->iBridge_dram_rdata_payload_data[1] = 0;
    top->iBridge_dram_rdata_payload_data[2] = 0;
    top->iBridge_dram_rdata_payload_data[3] = 0;
    top->dBridge_dram_cmd_ready = 0;
    top->dBridge_dram_wdata_ready = 0;
    top->dBridge_dram_rdata_valid = 0;
    top->dBridge_dram_rdata_payload_data[0] = 0;
    top->dBridge_dram_rdata_payload_data[1] = 0;
    top->dBridge_dram_rdata_payload_data[2] = 0;
    top->dBridge_dram_rdata_payload_data[3] = 0;

    top->peripheral_ACK = 0;
    top->peripheral_ERR = 0;
    top->peripheral_DAT_MISO = 0;

    // Reset sequence on debug clock domain.
    toggle_debug_clock(top);
    top->debugCd_external_reset = 0;
    toggle_debug_clock(top);

    for (int i = 0; i < 10; ++i) {
        toggle_debug_clock(top);
    }

    delete top;
    return 0;
}
