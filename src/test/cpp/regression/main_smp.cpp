// Linux SoC SMP harness for VexRiscvSmp2Gen.
//
// Goals for riscv_fuzz_test:
// - Accept an ELF/HEX argument.
// - Provide a simple external DRAM model for iBridge/dBridge.
// - Detect tohost writes (0xF00FFF20) on the peripheral Wishbone bus.
// - Emit run.memTrace lines (PC=0) so perf extraction works for both harts.

#include "VVexRiscv.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using std::string;

static constexpr uint32_t kTohostAddr = 0xF00FFF20u;
static constexpr uint32_t kDramBase = 0x80000000u;
// LiteDRAM native ports in this SMP cluster use 128-bit words; cmd_payload_addr is a word index.
static constexpr uint32_t kDramWordBytes = 16u;

static bool ends_with(const string &s, const string &suffix) {
    if (suffix.size() > s.size()) return false;
    return s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

static uint32_t hti(char c) {
    if (c >= 'A' && c <= 'F') return static_cast<uint32_t>(c - 'A' + 10);
    if (c >= 'a' && c <= 'f') return static_cast<uint32_t>(c - 'a' + 10);
    return static_cast<uint32_t>(c - '0');
}

static uint32_t hToI(const char *c, uint32_t size) {
    uint32_t value = 0;
    for (uint32_t i = 0; i < size; i++) {
        value += hti(c[i]) << ((size - i - 1) * 4);
    }
    return value;
}

class Memory {
public:
    uint8_t *mem[1 << 12];
    Memory() {
        for (uint32_t i = 0; i < (1u << 12); i++) mem[i] = NULL;
    }
    ~Memory() {
        for (uint32_t i = 0; i < (1u << 12); i++) {
            if (mem[i]) delete[] mem[i];
        }
    }
    uint8_t *get(uint32_t address) {
        if (mem[address >> 20] == NULL) {
            uint8_t *ptr = new uint8_t[1024 * 1024];
            for (uint32_t i = 0; i < 1024 * 1024; i++) ptr[i] = 0xFF;
            mem[address >> 20] = ptr;
        }
        return &mem[address >> 20][address & 0xFFFFF];
    }
    uint8_t &operator[](uint32_t address) { return *get(address); }
};

static void loadHexImpl(const string &path, Memory *mem) {
    std::ifstream file(path);
    if (!file.is_open()) {
        std::cerr << "Failed to open HEX file: " << path << std::endl;
        std::exit(2);
    }

    string line;
    uint32_t upper = 0;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] != ':') continue;
        const char *s = line.c_str();
        uint32_t byteCount = hToI(s + 1, 2);
        uint32_t addr = hToI(s + 3, 4);
        uint32_t recordType = hToI(s + 7, 2);
        if (recordType == 0x00) {
            uint32_t base = (upper << 16) | addr;
            for (uint32_t i = 0; i < byteCount; i++) {
                uint32_t v = hToI(s + 9 + i * 2, 2);
                (*mem)[base + i] = static_cast<uint8_t>(v);
            }
        } else if (recordType == 0x04) {
            upper = hToI(s + 9, 4);
        } else if (recordType == 0x01) {
            break;
        }
    }
}

static string pick_objcopy() {
    const char *env = std::getenv("RISCV_OBJCOPY");
    if (env && env[0] != '\0') return string(env);
    // Prefer 64-bit toolchain name; 32-bit works too.
    return string("riscv64-unknown-elf-objcopy");
}

static string elf_to_hex(const string &elf_path) {
    const string out_hex = elf_path + ".hex";
    const string objcopy = pick_objcopy();
    string cmd = objcopy + " -O ihex \"" + elf_path + "\" \"" + out_hex + "\"";
    int ret = std::system(cmd.c_str());
    if (ret != 0) {
        std::cerr << "objcopy failed: " << cmd << std::endl;
        std::exit(2);
    }
    return out_hex;
}

static void pack_u32_words_from_bytes(const uint8_t bytes[16], uint32_t words[4]) {
    for (int w = 0; w < 4; w++) {
        uint32_t v = 0;
        v |= static_cast<uint32_t>(bytes[w * 4 + 0]) << 0;
        v |= static_cast<uint32_t>(bytes[w * 4 + 1]) << 8;
        v |= static_cast<uint32_t>(bytes[w * 4 + 2]) << 16;
        v |= static_cast<uint32_t>(bytes[w * 4 + 3]) << 24;
        words[w] = v;
    }
}

static void unpack_bytes_from_u32_words(const uint32_t words[4], uint8_t bytes[16]) {
    for (int w = 0; w < 4; w++) {
        uint32_t v = words[w];
        bytes[w * 4 + 0] = static_cast<uint8_t>((v >> 0) & 0xFF);
        bytes[w * 4 + 1] = static_cast<uint8_t>((v >> 8) & 0xFF);
        bytes[w * 4 + 2] = static_cast<uint8_t>((v >> 16) & 0xFF);
        bytes[w * 4 + 3] = static_cast<uint8_t>((v >> 24) & 0xFF);
    }
}

static void log_mem_write_groups(FILE *f, uint64_t time, uint32_t base, const uint8_t bytes[16], uint16_t mask) {
    // Group contiguous enabled bytes and emit one line per group.
    int i = 0;
    while (i < 16) {
        while (i < 16 && ((mask >> i) & 1u) == 0) i++;
        if (i >= 16) break;
        int start = i;
        int len = 0;
        while (i < 16 && ((mask >> i) & 1u) != 0) {
            len++;
            i++;
        }
        // Print hex bytes high->low so the parser reconstructs little-endian correctly.
        std::string hex;
        hex.reserve(static_cast<size_t>(len) * 2);
        for (int j = len - 1; j >= 0; j--) {
            char buf[3];
            std::snprintf(buf, sizeof(buf), "%02x", bytes[start + j]);
            hex += buf;
        }
        std::fprintf(
            f,
            "%llu PC 0 : MEM[0x%08x] <= %d bytes : 0x%s\n",
            static_cast<unsigned long long>(time),
            static_cast<unsigned int>(base + static_cast<uint32_t>(start)),
            len,
            hex.c_str());
    }
}

struct DramReadResp {
    uint32_t addr;
    uint32_t words[4];
};

struct DramState {
    // Writes are split cmd + wdata; preserve cmd order until wdata arrives.
    std::deque<uint32_t> write_addr_q;
    std::deque<DramReadResp> rdata_q;
};

static void toggle_debug_clock(VVexRiscv *top) {
    top->debugCd_external_clk = 0;
    top->eval();
    top->debugCd_external_clk = 1;
    top->eval();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    string image;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (a[0] == '+') continue; // ignore plusargs
        image = string(a);
        break;
    }
    if (image.empty()) {
        std::cerr << "Usage: VVexRiscv <program.elf|program.hex> [plusargs...]" << std::endl;
        return 2;
    }

    string to_load = image;
    if (ends_with(image, ".elf")) {
        to_load = elf_to_hex(image);
    }

    Memory mem;
    loadHexImpl(to_load, &mem);

    FILE *mem_trace = std::fopen("run.memTrace", "w");
    if (!mem_trace) {
        std::perror("failed to open run.memTrace");
        return 2;
    }

    VVexRiscv *top = new VVexRiscv;

    FILE *log_trace = std::fopen("run.logTrace", "w");
    if (!log_trace) {
        std::perror("failed to open run.logTrace");
        return 2;
    }

    // Static input tie-offs.
    top->interrupts = 0;
    top->debugPort_tdi = 0;
    top->debugPort_enable = 0;
    top->debugPort_capture = 0;
    top->debugPort_shift = 0;
    top->debugPort_update = 0;
    top->debugPort_reset = 0;
    top->jtag_clk = 0;

    // Unused wishbone inputs (keep idle).
    top->clintWishbone_CYC = 0;
    top->clintWishbone_STB = 0;
    top->clintWishbone_WE = 0;
    top->clintWishbone_ADR = 0;
    top->clintWishbone_DAT_MOSI = 0;
    top->plicWishbone_CYC = 0;
    top->plicWishbone_STB = 0;
    top->plicWishbone_WE = 0;
    top->plicWishbone_ADR = 0;
    top->plicWishbone_DAT_MOSI = 0;

    // External DRAM model: always ready (we queue write cmds until wdata arrives).
    top->iBridge_dram_cmd_ready = 1;
    top->iBridge_dram_wdata_ready = 1;
    top->dBridge_dram_cmd_ready = 1;
    top->dBridge_dram_wdata_ready = 1;

    // Peripheral slave response.
    top->peripheral_ACK = 0;
    top->peripheral_ERR = 0;
    top->peripheral_DAT_MISO = 0;

    // DRAM read data inputs default.
    top->iBridge_dram_rdata_valid = 0;
    top->iBridge_dram_rdata_payload_data[0] = 0;
    top->iBridge_dram_rdata_payload_data[1] = 0;
    top->iBridge_dram_rdata_payload_data[2] = 0;
    top->iBridge_dram_rdata_payload_data[3] = 0;
    top->dBridge_dram_rdata_valid = 0;
    top->dBridge_dram_rdata_payload_data[0] = 0;
    top->dBridge_dram_rdata_payload_data[1] = 0;
    top->dBridge_dram_rdata_payload_data[2] = 0;
    top->dBridge_dram_rdata_payload_data[3] = 0;

    // Reset sequence.
    top->debugCd_external_clk = 0;
    top->debugCd_external_reset = 1;
    top->eval();
    for (int i = 0; i < 10; i++) toggle_debug_clock(top);
    top->debugCd_external_reset = 0;
    for (int i = 0; i < 10; i++) toggle_debug_clock(top);

    DramState i_dram;
    DramState d_dram;

    bool done = false;
    int exit_code = 2;
    uint32_t tohost_reg = 0;

    // One-cycle delayed peripheral ACK.
    uint8_t peripheral_ack_next = 0;
    uint32_t peripheral_rdata_next = 0;
    uint8_t peripheral_err_next = 0;

    const uint64_t kMaxCycles = 20ull * 1000ull * 1000ull;
    uint64_t cycle = 0;

    uint64_t i_cmd_count = 0;
    uint64_t d_cmd_count = 0;
    uint64_t periph_count = 0;
    uint64_t wdata_i_count = 0;
    uint64_t wdata_d_count = 0;
    uint64_t rdata_i_count = 0;
    uint64_t rdata_d_count = 0;

    // Extra visibility: capture if data/periph ever toggles.
    uint64_t d_cmd_seen = 0;
    uint64_t d_wdata_seen = 0;
    uint64_t periph_seen = 0;
    auto log_bus_phase = [&](const char *phase, uint64_t cyc) {
        if (top->dBridge_dram_cmd_valid) {
            if (d_cmd_seen < 50) {
                uint32_t addr = kDramBase + (static_cast<uint32_t>(top->dBridge_dram_cmd_payload_addr) * kDramWordBytes);
                std::fprintf(
                    log_trace,
                    "time=%llu phase=%s d_cmd_valid=1 ready=%u addr=0x%08x we=%u\n",
                    static_cast<unsigned long long>(cyc),
                    phase,
                    static_cast<unsigned int>(top->dBridge_dram_cmd_ready ? 1 : 0),
                    static_cast<unsigned int>(addr),
                    static_cast<unsigned int>(top->dBridge_dram_cmd_payload_we ? 1 : 0));
            }
            d_cmd_seen++;
        }
        if (top->dBridge_dram_wdata_valid) {
            if (d_wdata_seen < 50) {
                std::fprintf(
                    log_trace,
                    "time=%llu phase=%s d_wdata_valid=1 ready=%u we=0x%04x\n",
                    static_cast<unsigned long long>(cyc),
                    phase,
                    static_cast<unsigned int>(top->dBridge_dram_wdata_ready ? 1 : 0),
                    static_cast<unsigned int>(static_cast<uint16_t>(top->dBridge_dram_wdata_payload_we)));
            }
            d_wdata_seen++;
        }
        if (top->peripheral_CYC && top->peripheral_STB) {
            if (periph_seen < 50) {
                uint32_t addr = static_cast<uint32_t>(top->peripheral_ADR) << 2;
                std::fprintf(
                    log_trace,
                    "time=%llu phase=%s periph_req=1 addr=0x%08x we=%u sel=0x%x wdata=0x%08x\n",
                    static_cast<unsigned long long>(cyc),
                    phase,
                    static_cast<unsigned int>(addr),
                    static_cast<unsigned int>(top->peripheral_WE ? 1 : 0),
                    static_cast<unsigned int>(static_cast<uint32_t>(top->peripheral_SEL) & 0xF),
                    static_cast<unsigned int>(static_cast<uint32_t>(top->peripheral_DAT_MOSI)));
            }
            periph_seen++;
        }
    };
    while (!done && cycle < kMaxCycles && !Verilated::gotFinish()) {
        // Drive slave responses for this cycle (stable during eval).
        top->peripheral_ACK = peripheral_ack_next;
        top->peripheral_ERR = peripheral_err_next;
        top->peripheral_DAT_MISO = peripheral_rdata_next;

        // Drive DRAM read data from queued responses.
        if (!i_dram.rdata_q.empty()) {
            top->iBridge_dram_rdata_valid = 1;
            top->iBridge_dram_rdata_payload_data[0] = i_dram.rdata_q.front().words[0];
            top->iBridge_dram_rdata_payload_data[1] = i_dram.rdata_q.front().words[1];
            top->iBridge_dram_rdata_payload_data[2] = i_dram.rdata_q.front().words[2];
            top->iBridge_dram_rdata_payload_data[3] = i_dram.rdata_q.front().words[3];
        } else {
            top->iBridge_dram_rdata_valid = 0;
        }
        if (!d_dram.rdata_q.empty()) {
            top->dBridge_dram_rdata_valid = 1;
            top->dBridge_dram_rdata_payload_data[0] = d_dram.rdata_q.front().words[0];
            top->dBridge_dram_rdata_payload_data[1] = d_dram.rdata_q.front().words[1];
            top->dBridge_dram_rdata_payload_data[2] = d_dram.rdata_q.front().words[2];
            top->dBridge_dram_rdata_payload_data[3] = d_dram.rdata_q.front().words[3];
        } else {
            top->dBridge_dram_rdata_valid = 0;
        }

        // Tick.
        top->debugCd_external_clk = 0;
        top->eval();
        log_bus_phase("L", cycle);
        top->debugCd_external_clk = 1;
        top->eval();
        log_bus_phase("H", cycle);

        // Consume read data if the DUT is ready.
        if (top->iBridge_dram_rdata_valid) {
            if (rdata_i_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu i_rdata valid=1 ready=%u data0=0x%08x data1=0x%08x\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(top->iBridge_dram_rdata_ready ? 1 : 0),
                    static_cast<unsigned int>(static_cast<uint32_t>(top->iBridge_dram_rdata_payload_data[0])),
                    static_cast<unsigned int>(static_cast<uint32_t>(top->iBridge_dram_rdata_payload_data[1])));
            }
            rdata_i_count++;
        }
        if (top->iBridge_dram_rdata_valid && top->iBridge_dram_rdata_ready) {
            i_dram.rdata_q.pop_front();
        }
        if (top->dBridge_dram_rdata_valid) {
            if (rdata_d_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu d_rdata valid=1 ready=%u\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(top->dBridge_dram_rdata_ready ? 1 : 0));
            }
            rdata_d_count++;
        }
        if (top->dBridge_dram_rdata_valid && top->dBridge_dram_rdata_ready) {
            d_dram.rdata_q.pop_front();
        }

        // Peripheral bus: issue ACK next cycle when a request is seen.
        peripheral_ack_next = (top->peripheral_CYC && top->peripheral_STB) ? 1 : 0;
        peripheral_err_next = 0;
        peripheral_rdata_next = 0;
        if (top->peripheral_CYC && top->peripheral_STB) {
            uint32_t addr = static_cast<uint32_t>(top->peripheral_ADR) << 2;
            if (periph_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu periph addr=0x%08x we=%u sel=0x%x wdata=0x%08x\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(addr),
                    static_cast<unsigned int>(top->peripheral_WE ? 1 : 0),
                    static_cast<unsigned int>(static_cast<uint32_t>(top->peripheral_SEL) & 0xF),
                    static_cast<unsigned int>(static_cast<uint32_t>(top->peripheral_DAT_MOSI)));
            }
            periph_count++;
            if (top->peripheral_WE) {
                uint32_t wdata = static_cast<uint32_t>(top->peripheral_DAT_MOSI);
                uint32_t sel = static_cast<uint32_t>(top->peripheral_SEL) & 0xF;
                uint32_t merged = tohost_reg;
                for (int b = 0; b < 4; b++) {
                    if ((sel >> b) & 1u) {
                        merged &= ~(0xFFu << (8 * b));
                        merged |= ((wdata >> (8 * b)) & 0xFFu) << (8 * b);
                    }
                }
                if (addr == kTohostAddr) {
                    tohost_reg = merged;
                    if (tohost_reg == 0) {
                        exit_code = 0;
                    } else {
                        exit_code = 1;
                    }
                    done = true;
                }
            } else {
                if (addr == kTohostAddr) {
                    peripheral_rdata_next = tohost_reg;
                } else {
                    peripheral_rdata_next = 0;
                }
            }
        }

        // iBridge DRAM commands.
        if (top->iBridge_dram_cmd_valid && top->iBridge_dram_cmd_ready) {
            uint32_t addr = kDramBase + (static_cast<uint32_t>(top->iBridge_dram_cmd_payload_addr) * kDramWordBytes);
            bool we = (top->iBridge_dram_cmd_payload_we != 0);
            if (i_cmd_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu i_cmd addr=0x%08x we=%u\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(addr),
                    static_cast<unsigned int>(we ? 1 : 0));
            }
            i_cmd_count++;
            if (we) {
                i_dram.write_addr_q.push_back(addr);
            } else {
                uint8_t bytes[16];
                for (int i = 0; i < 16; i++) bytes[i] = mem[addr + static_cast<uint32_t>(i)];
                DramReadResp r;
                r.addr = addr;
                pack_u32_words_from_bytes(bytes, r.words);
                i_dram.rdata_q.push_back(r);
            }
        }
        if (top->iBridge_dram_wdata_valid && top->iBridge_dram_wdata_ready) {
            if (wdata_i_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu i_wdata we=0x%04x\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(static_cast<uint16_t>(top->iBridge_dram_wdata_payload_we)));
            }
            wdata_i_count++;
            if (!i_dram.write_addr_q.empty()) {
                uint32_t addr = i_dram.write_addr_q.front();
                i_dram.write_addr_q.pop_front();
                uint32_t words[4] = {
                    static_cast<uint32_t>(top->iBridge_dram_wdata_payload_data[0]),
                    static_cast<uint32_t>(top->iBridge_dram_wdata_payload_data[1]),
                    static_cast<uint32_t>(top->iBridge_dram_wdata_payload_data[2]),
                    static_cast<uint32_t>(top->iBridge_dram_wdata_payload_data[3]),
                };
                uint8_t bytes[16];
                unpack_bytes_from_u32_words(words, bytes);
                uint16_t mask = static_cast<uint16_t>(top->iBridge_dram_wdata_payload_we);
                for (int i = 0; i < 16; i++) {
                    if ((mask >> i) & 1u) mem[addr + static_cast<uint32_t>(i)] = bytes[i];
                }
                log_mem_write_groups(mem_trace, cycle, addr, bytes, mask);
            }
        }

        // dBridge DRAM commands.
        if (top->dBridge_dram_cmd_valid && top->dBridge_dram_cmd_ready) {
            uint32_t addr = kDramBase + (static_cast<uint32_t>(top->dBridge_dram_cmd_payload_addr) * kDramWordBytes);
            bool we = (top->dBridge_dram_cmd_payload_we != 0);
            if (d_cmd_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu d_cmd addr=0x%08x we=%u\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(addr),
                    static_cast<unsigned int>(we ? 1 : 0));
            }
            d_cmd_count++;
            if (we) {
                d_dram.write_addr_q.push_back(addr);
            } else {
                uint8_t bytes[16];
                for (int i = 0; i < 16; i++) bytes[i] = mem[addr + static_cast<uint32_t>(i)];
                DramReadResp r;
                r.addr = addr;
                pack_u32_words_from_bytes(bytes, r.words);
                d_dram.rdata_q.push_back(r);
            }
        }
        if (top->dBridge_dram_wdata_valid && top->dBridge_dram_wdata_ready) {
            if (wdata_d_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu d_wdata we=0x%04x\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(static_cast<uint16_t>(top->dBridge_dram_wdata_payload_we)));
            }
            wdata_d_count++;
            if (!d_dram.write_addr_q.empty()) {
                uint32_t addr = d_dram.write_addr_q.front();
                d_dram.write_addr_q.pop_front();
                uint32_t words[4] = {
                    static_cast<uint32_t>(top->dBridge_dram_wdata_payload_data[0]),
                    static_cast<uint32_t>(top->dBridge_dram_wdata_payload_data[1]),
                    static_cast<uint32_t>(top->dBridge_dram_wdata_payload_data[2]),
                    static_cast<uint32_t>(top->dBridge_dram_wdata_payload_data[3]),
                };
                uint8_t bytes[16];
                unpack_bytes_from_u32_words(words, bytes);
                uint16_t mask = static_cast<uint16_t>(top->dBridge_dram_wdata_payload_we);
                for (int i = 0; i < 16; i++) {
                    if ((mask >> i) & 1u) mem[addr + static_cast<uint32_t>(i)] = bytes[i];
                }
                log_mem_write_groups(mem_trace, cycle, addr, bytes, mask);
            }
        }

        cycle++;
    }

    if (!done) {
        std::cerr << "Timeout: no tohost write after " << cycle << " cycles" << std::endl;
        exit_code = 2;
    }

    std::fprintf(
        log_trace,
        "done=%u exit_code=%d cycles=%llu i_cmds=%llu d_cmds=%llu periph=%llu i_wdata=%llu d_wdata=%llu\n",
        static_cast<unsigned int>(done ? 1 : 0),
        exit_code,
        static_cast<unsigned long long>(cycle),
        static_cast<unsigned long long>(i_cmd_count),
        static_cast<unsigned long long>(d_cmd_count),
        static_cast<unsigned long long>(periph_count),
        static_cast<unsigned long long>(wdata_i_count),
        static_cast<unsigned long long>(wdata_d_count));

    std::fflush(mem_trace);
    std::fclose(mem_trace);

    std::fflush(log_trace);
    std::fclose(log_trace);

    delete top;
    return exit_code;
}
