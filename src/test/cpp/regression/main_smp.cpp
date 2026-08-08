// Linux SoC SMP harness for VexRiscvSmp2Gen.
//
// Goals for riscv_fuzz_test:
// - Accept an ELF/HEX argument.
// - Provide a simple external DRAM model for iBridge/dBridge.
// - Detect tohost writes (0xF00FFF20) on the peripheral Wishbone bus.
// - Emit run.memTrace lines (PC=0) so perf extraction works for both harts.

#include "VVexRiscv.h"
#include "VVexRiscv_VexRiscv.h"
#if defined(RVF) || defined(RVD)
#include "VVexRiscv_FpuCore.h"
#endif
#include "VVexRiscv_VexRiscvCore_0.h"
#include "VVexRiscv_VexRiscvCore_1.h"
#include "verilated.h"

#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <unordered_map>
#include <string>
#include <vector>

using std::string;

static constexpr uint32_t kTohostAddr = 0xF00FFF20u;
static constexpr uint32_t kDramBase = 0x80000000u;
// LiteDRAM native ports in this SMP cluster use 128-bit words; cmd_payload_addr is a word index.
static constexpr uint32_t kDramWordBytes = 16u;

static const char *cx_trace_isa() {
#ifdef RVD
    return "rv32fd";
#elif defined(RVF)
    return "rv32f";
#else
    return "rv32";
#endif
}

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

static void log_mem_write_groups(
    FILE *f,
    uint64_t time,
    uint32_t pc,
    uint32_t base,
    const uint8_t bytes[16],
    uint16_t mask,
    uint64_t clk_start,
    uint64_t clk_end,
    uint32_t hart_id,
    uint64_t token,
    bool token_valid = true) {
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
            "%llu PC %08x : MEM[0x%08x] <= %d bytes : 0x%s clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu token_valid=%u event=store_visible store_visible_cycle=%llu start_kind=backend_alloc end_kind=store_visible\n",
            static_cast<unsigned long long>(time),
            static_cast<unsigned int>(pc),
            static_cast<unsigned int>(base + static_cast<uint32_t>(start)),
            len,
            hex.c_str(),
            static_cast<unsigned long long>(clk_start),
            static_cast<unsigned long long>(clk_end),
            static_cast<unsigned long long>(clk_end - clk_start + 1),
            static_cast<unsigned int>(hart_id),
            static_cast<unsigned long long>(token),
            static_cast<unsigned int>(token_valid ? 1u : 0u),
            static_cast<unsigned long long>(clk_end));
    }
}

static void log_mem_write_masked32(
    FILE *f,
    uint64_t time,
    uint32_t pc,
    uint32_t addr,
    uint32_t data,
    uint8_t mask,
    uint64_t clk_start,
    uint64_t clk_end,
    uint32_t hart_id,
    uint64_t token,
    bool token_valid = true) {
    uint8_t bytes[4];
    bytes[0] = static_cast<uint8_t>((data >> 0) & 0xFF);
    bytes[1] = static_cast<uint8_t>((data >> 8) & 0xFF);
    bytes[2] = static_cast<uint8_t>((data >> 16) & 0xFF);
    bytes[3] = static_cast<uint8_t>((data >> 24) & 0xFF);

    int i = 0;
    while (i < 4) {
        while (i < 4 && ((mask >> i) & 1u) == 0) i++;
        if (i >= 4) break;
        int start = i;
        int len = 0;
        while (i < 4 && ((mask >> i) & 1u) != 0) {
            len++;
            i++;
        }
        std::string hex;
        hex.reserve(static_cast<size_t>(len) * 2);
        for (int j = len - 1; j >= 0; j--) {
            char buf[3];
            std::snprintf(buf, sizeof(buf), "%02x", bytes[start + j]);
            hex += buf;
        }
        std::fprintf(
            f,
            "%llu PC %08x : MEM[0x%08x] <= %d bytes : 0x%s clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu token_valid=%u event=store_visible store_visible_cycle=%llu start_kind=backend_alloc end_kind=store_visible\n",
            static_cast<unsigned long long>(time),
            static_cast<unsigned int>(pc),
            static_cast<unsigned int>(addr + static_cast<uint32_t>(start)),
            len,
            hex.c_str(),
            static_cast<unsigned long long>(clk_start),
            static_cast<unsigned long long>(clk_end),
            static_cast<unsigned long long>(clk_end - clk_start + 1),
            static_cast<unsigned int>(hart_id),
            static_cast<unsigned long long>(token),
            static_cast<unsigned int>(token_valid ? 1u : 0u),
            static_cast<unsigned long long>(clk_end));
    }
}

struct DramReadResp {
    uint32_t addr;
    uint32_t words[4];
};

struct DramWriteCmd {
    uint32_t addr;
    uint32_t source;
};

struct DramState {
    // Writes are split cmd + wdata; preserve cmd order until wdata arrives.
    std::deque<DramWriteCmd> write_addr_q;
    std::deque<DramReadResp> rdata_q;
};

struct PendingStore {
    uint32_t hart_id;
    uint32_t pc;
    uint32_t insn;
    uint32_t addr;
    uint32_t expected_size;
    bool suppress_bus_log;
    uint64_t clk_start;
    uint64_t clk_end;
    uint64_t token;
    uint64_t observed_cycle;
};

static uint32_t decode_store_size(uint32_t insn) {
    if ((insn & 0x3u) != 0x3u) {
        const uint32_t quadrant = insn & 0x3u;
        const uint32_t funct3 = (insn >> 13) & 0x7u;
        if (quadrant == 0u) {
            if (funct3 == 0x5u) return 8u; // c.fsd
            if (funct3 == 0x6u || funct3 == 0x7u) return 4u; // c.sw / c.fsw
        } else if (quadrant == 2u) {
            if (funct3 == 0x5u) return 8u; // c.fsdsp
            if (funct3 == 0x6u || funct3 == 0x7u) return 4u; // c.swsp / c.fswsp
        }
        return 0u;
    }

    const uint32_t opcode = insn & 0x7fu;
    const uint32_t funct3 = (insn >> 12) & 0x7u;
    if (opcode == 0x23u) { // STORE
        if (funct3 <= 3u) return 1u << funct3; // sb/sh/sw/sd
        return 0u;
    }
    if (opcode == 0x27u || opcode == 0x2fu) { // STORE-FP / AMO/LRSC
        if (funct3 == 0x2u) return 4u;
        if (funct3 == 0x3u) return 8u;
    }
    return 0u;
}

static bool is_direct_integer_store(uint32_t insn) {
    if ((insn & 0x3u) != 0x3u) {
        const uint32_t quadrant = insn & 0x3u;
        const uint32_t funct3 = (insn >> 13) & 0x7u;
        if (quadrant == 0u && funct3 == 0x6u) return true; // c.sw
        if (quadrant == 2u && funct3 == 0x6u) return true; // c.swsp
        return false;
    }
    return (insn & 0x7fu) == 0x23u; // integer STORE
}

static void log_direct_store_write(
    FILE *mem_trace,
    uint64_t cycle,
    uint32_t pc,
    uint32_t addr,
    uint32_t size,
    uint64_t data,
    uint64_t clk_start,
    uint64_t clk_end,
    uint32_t hart_id,
    uint64_t token) {
    if (size == 0u || size > 8u) return;
    const uint64_t mask = size == 8u ? UINT64_MAX : ((1ULL << (size * 8u)) - 1ULL);
    const uint64_t masked_data = data & mask;
    char hex[17];
    std::snprintf(
        hex,
        sizeof(hex),
        "%0*llx",
        static_cast<int>(size * 2u),
        static_cast<unsigned long long>(masked_data));
    std::fprintf(
        mem_trace,
        "%llu PC %08x : MEM[0x%08x] <= %u bytes : 0x%s clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu token_valid=1 event=arch_store start_kind=backend_alloc end_kind=arch_commit\n",
        static_cast<unsigned long long>(cycle),
        static_cast<unsigned int>(pc),
        static_cast<unsigned int>(addr),
        static_cast<unsigned int>(size),
        hex,
        static_cast<unsigned long long>(clk_start),
        static_cast<unsigned long long>(clk_end),
        static_cast<unsigned long long>(clk_end - clk_start + 1),
        static_cast<unsigned int>(hart_id),
        static_cast<unsigned long long>(token));
}

static bool mask_span(uint16_t mask, uint32_t *start, uint32_t *len) {
    uint32_t first = 16u;
    uint32_t count = 0u;
    uint32_t last = 0u;
    for (uint32_t i = 0; i < 16u; ++i) {
        if (((mask >> i) & 1u) == 0u) continue;
        if (first == 16u) first = i;
        last = i;
        count++;
    }
    if (count == 0u) return false;
    if (count != (last - first + 1u)) return false;
    *start = first;
    *len = count;
    return true;
}

static void retire_stale_pending_stores(
    std::deque<PendingStore> *pending_stores,
    FILE *log_trace,
    uint64_t cycle) {
    static constexpr uint64_t kPendingStoreMaxAge = 256u;
    while (!pending_stores->empty() &&
           cycle > pending_stores->front().observed_cycle &&
           (cycle - pending_stores->front().observed_cycle) > kPendingStoreMaxAge) {
        const PendingStore &stale = pending_stores->front();
        std::fprintf(
            log_trace,
            "WARN pending_store_timeout hart=%u pc=0x%08x addr=0x%08x size=%u observed=%llu now=%llu\n",
            static_cast<unsigned int>(stale.hart_id),
            static_cast<unsigned int>(stale.pc),
            static_cast<unsigned int>(stale.addr),
            static_cast<unsigned int>(stale.expected_size),
            static_cast<unsigned long long>(stale.observed_cycle),
            static_cast<unsigned long long>(cycle));
        pending_stores->pop_front();
    }
}

static bool emit_pending_store_write(
    std::deque<PendingStore> *pending_stores,
    FILE *mem_trace,
    FILE *log_trace,
    FILE *cx_trace,
    uint64_t cycle,
    uint32_t base_addr,
    const uint8_t bytes[16],
    uint16_t mask,
    bool prefer_hart,
    uint32_t hart_id) {
    retire_stale_pending_stores(pending_stores, log_trace, cycle);

    uint32_t span_start = 0u;
    uint32_t span_len = 0u;
    const bool contiguous = mask_span(mask, &span_start, &span_len);
    if (!contiguous) {
        std::fprintf(
            log_trace,
            "WARN pending_store_noncontiguous base=0x%08x mask=0x%04x cycle=%llu\n",
            static_cast<unsigned int>(base_addr),
            static_cast<unsigned int>(mask),
            static_cast<unsigned long long>(cycle));
    }

    auto exact_match = [&](bool same_hart_only) -> size_t {
        if (same_hart_only) {
            for (int prefer_suppressed = 0; prefer_suppressed <= 1; ++prefer_suppressed) {
                for (size_t i = 0; i < pending_stores->size(); ++i) {
                    const PendingStore &store = (*pending_stores)[i];
                    if (store.observed_cycle > cycle) continue;
                    if (!contiguous) continue;
                    if (store.expected_size != span_len) continue;
                    if (store.addr != (base_addr + span_start)) continue;
                    if (store.hart_id != hart_id) continue;
                    if (store.suppress_bus_log != static_cast<bool>(prefer_suppressed)) continue;
                    return i;
                }
            }
        } else {
            for (int prefer_suppressed = 0; prefer_suppressed <= 1; ++prefer_suppressed) {
                for (size_t i = pending_stores->size(); i-- > 0;) {
                    const PendingStore &store = (*pending_stores)[i];
                    if (store.observed_cycle > cycle) continue;
                    if (!contiguous) continue;
                    if (store.expected_size != span_len) continue;
                    if (store.addr != (base_addr + span_start)) continue;
                    if (store.suppress_bus_log != static_cast<bool>(prefer_suppressed)) continue;
                    return i;
                }
            }
        }
        return pending_stores->size();
    };

    size_t best_index = pending_stores->size();
    // The shared dBridge/peripheral writeback path is not strictly ordered by
    // source-PC age when the two harts interleave AMO/LRSC traffic to the same
    // word. Prefer the most recently observed compatible pending store so later
    // same-address atomics do not get back-attributed to earlier init stores.
    if (prefer_hart) {
        best_index = exact_match(true);
    }
    if (best_index == pending_stores->size()) {
        best_index = exact_match(false);
    }

    if (best_index == pending_stores->size() && contiguous) {
        auto covered_match = [&](bool same_hart_only) -> std::vector<size_t> {
            std::vector<size_t> covered_indices;
            uint32_t cursor = base_addr + span_start;
            const uint32_t span_end = cursor + span_len;
            while (cursor < span_end) {
                size_t covered_index = pending_stores->size();
                if (same_hart_only) {
                    for (int prefer_suppressed = 0; prefer_suppressed <= 1 && covered_index == pending_stores->size(); ++prefer_suppressed) {
                        for (size_t i = 0; i < pending_stores->size(); ++i) {
                            const PendingStore &store = (*pending_stores)[i];
                            if (store.observed_cycle > cycle) continue;
                            if (store.expected_size == 0u) continue;
                            if (store.addr != cursor) continue;
                            if (store.expected_size > (span_end - cursor)) continue;
                            if (store.hart_id != hart_id) continue;
                            if (store.suppress_bus_log != static_cast<bool>(prefer_suppressed)) continue;
                            covered_index = i;
                            break;
                        }
                    }
                } else {
                    for (int prefer_suppressed = 0; prefer_suppressed <= 1 && covered_index == pending_stores->size(); ++prefer_suppressed) {
                        for (size_t i = pending_stores->size(); i-- > 0;) {
                            const PendingStore &store = (*pending_stores)[i];
                            if (store.observed_cycle > cycle) continue;
                            if (store.expected_size == 0u) continue;
                            if (store.addr != cursor) continue;
                            if (store.expected_size > (span_end - cursor)) continue;
                            if (store.suppress_bus_log != static_cast<bool>(prefer_suppressed)) continue;
                            covered_index = i;
                            break;
                        }
                    }
                }
                if (covered_index == pending_stores->size()) {
                    covered_indices.clear();
                    break;
                }
                covered_indices.push_back(covered_index);
                cursor += (*pending_stores)[covered_index].expected_size;
            }
            if (covered_indices.empty() || cursor != span_end) return {};
            return covered_indices;
        };

        std::vector<size_t> covered_indices;
        if (prefer_hart) {
            covered_indices = covered_match(true);
        }
        if (covered_indices.empty()) {
            covered_indices = covered_match(false);
        }

        if (!covered_indices.empty()) {
            for (size_t covered_index : covered_indices) {
                const PendingStore &matched = (*pending_stores)[covered_index];
                const uint32_t offset = matched.addr - base_addr;
                const uint16_t submask = static_cast<uint16_t>(
                    ((1u << matched.expected_size) - 1u) << offset);
                std::fprintf(
                    log_trace,
                    "TRACE pending_store_match kind=covered base=0x%08x cycle=%llu req_hart=%u matched_hart=%u pc=0x%08x size=%u mask=0x%04x\n",
                    static_cast<unsigned int>(base_addr),
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(hart_id),
                    static_cast<unsigned int>(matched.hart_id),
                    static_cast<unsigned int>(matched.pc),
                    static_cast<unsigned int>(matched.expected_size),
                    static_cast<unsigned int>(submask));
                std::fprintf(
                    cx_trace,
                    "CXTRACE v=2 event=store_visible core=VexRiscv hart=%u token=%llu cycle=%llu addr=0x%08x size=%u\n",
                    static_cast<unsigned int>(matched.hart_id),
                    static_cast<unsigned long long>(matched.token),
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(matched.addr),
                    static_cast<unsigned int>(matched.expected_size));
                if (!matched.suppress_bus_log) {
                    log_mem_write_groups(
                        mem_trace,
                        cycle,
                        matched.pc,
                        base_addr,
                        bytes,
                        submask,
                        matched.clk_start,
                        matched.clk_end,
                        matched.hart_id,
                        matched.token);
                }
            }
            for (auto it = covered_indices.rbegin(); it != covered_indices.rend(); ++it) {
                pending_stores->erase(pending_stores->begin() + static_cast<std::ptrdiff_t>(*it));
            }
            return true;
        }
    }

    if (best_index == pending_stores->size() && contiguous) {
        auto same_line_match = [&](bool same_hart_only) -> size_t {
            if (same_hart_only) {
                for (int prefer_suppressed = 0; prefer_suppressed <= 1; ++prefer_suppressed) {
                    for (size_t i = 0; i < pending_stores->size(); ++i) {
                        const PendingStore &store = (*pending_stores)[i];
                        if (store.observed_cycle > cycle) continue;
                        if (store.expected_size != span_len) continue;
                        if (store.addr < base_addr || store.addr >= (base_addr + 16u)) continue;
                        if (store.hart_id != hart_id) continue;
                        if (store.suppress_bus_log != static_cast<bool>(prefer_suppressed)) continue;
                        return i;
                    }
                }
            } else {
                for (int prefer_suppressed = 0; prefer_suppressed <= 1; ++prefer_suppressed) {
                    for (size_t i = pending_stores->size(); i-- > 0;) {
                        const PendingStore &store = (*pending_stores)[i];
                        if (store.observed_cycle > cycle) continue;
                        if (store.expected_size != span_len) continue;
                        if (store.addr < base_addr || store.addr >= (base_addr + 16u)) continue;
                        if (store.suppress_bus_log != static_cast<bool>(prefer_suppressed)) continue;
                        return i;
                    }
                }
            }
            return pending_stores->size();
        };
        if (prefer_hart) {
            best_index = same_line_match(true);
        }
        if (best_index == pending_stores->size()) {
            best_index = same_line_match(false);
        }
    }

    if (best_index == pending_stores->size()) {
        std::fprintf(
            log_trace,
            "WARN pending_store_unmatched base=0x%08x mask=0x%04x cycle=%llu pending=%zu prefer_hart=%u hart=%u\n",
            static_cast<unsigned int>(base_addr),
            static_cast<unsigned int>(mask),
            static_cast<unsigned long long>(cycle),
            pending_stores->size(),
            static_cast<unsigned int>(prefer_hart ? 1u : 0u),
            static_cast<unsigned int>(hart_id));
        log_mem_write_groups(
            mem_trace,
            cycle,
            0u,
            base_addr,
            bytes,
            mask,
            cycle,
            cycle,
            hart_id,
            0u,
            false);
        return false;
    }

    const PendingStore matched = (*pending_stores)[best_index];
    pending_stores->erase(pending_stores->begin() + static_cast<std::ptrdiff_t>(best_index));
    std::fprintf(
        log_trace,
        "TRACE pending_store_match kind=single base=0x%08x cycle=%llu req_hart=%u matched_hart=%u pc=0x%08x size=%u mask=0x%04x prefer_hart=%u suppress=%u\n",
        static_cast<unsigned int>(base_addr),
        static_cast<unsigned long long>(cycle),
        static_cast<unsigned int>(hart_id),
        static_cast<unsigned int>(matched.hart_id),
        static_cast<unsigned int>(matched.pc),
        static_cast<unsigned int>(matched.expected_size),
        static_cast<unsigned int>(mask),
        static_cast<unsigned int>(prefer_hart ? 1u : 0u),
        static_cast<unsigned int>(matched.suppress_bus_log ? 1u : 0u));
    std::fprintf(
        cx_trace,
        "CXTRACE v=2 event=store_visible core=VexRiscv hart=%u token=%llu cycle=%llu addr=0x%08x size=%u\n",
        static_cast<unsigned int>(matched.hart_id),
        static_cast<unsigned long long>(matched.token),
        static_cast<unsigned long long>(cycle),
        static_cast<unsigned int>(matched.addr),
        static_cast<unsigned int>(matched.expected_size));
    if (!matched.suppress_bus_log) {
        log_mem_write_groups(
            mem_trace,
            cycle,
            matched.pc,
            base_addr,
            bytes,
            mask,
            matched.clk_start,
            matched.clk_end,
            matched.hart_id,
            matched.token);
    }
    return true;
}

static void toggle_debug_clock(VVexRiscv *top) {
    top->debugCd_external_clk = 0;
    top->eval();
    top->debugCd_external_clk = 1;
    top->eval();
}

template <typename TCpu>
static uint64_t current_clock_cycle(TCpu *cpu, uint64_t fallback_cycle) {
    const uint64_t sim_cycle = static_cast<uint64_t>(cpu->traceCycle);
    return sim_cycle != 0 ? sim_cycle : (fallback_cycle + 1);
}

static uint64_t normalize_start_cycle(uint64_t raw, uint64_t current) {
    return raw != 0 ? raw : current;
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

    FILE *reg_trace = std::fopen("run.regTrace", "w");
    if (!reg_trace) {
        std::perror("failed to open run.regTrace");
        return 2;
    }

    FILE *freg_trace = nullptr;
#if defined(RVF) || defined(RVD)
    static constexpr uint32_t kFpuOpcodeLoad = 0;
    static constexpr uint32_t kFpuOpcodeFmvWX = 13;
    struct FpuTraceCommit {
        uint32_t opcode;
        uint64_t value;
    };
    freg_trace = std::fopen("run.fregTrace", "w");
    if (!freg_trace) {
        std::perror("failed to open run.fregTrace");
        return 2;
    }
    struct FpuTraceWrite {
        uint32_t pc;
        uint64_t clk_start;
        uint64_t token;
        uint64_t writeback_cycle;
        uint32_t hart_id;
        uint32_t reg;
        bool is_double;
        uint64_t data;
    };
    std::deque<FpuTraceCommit> fpu_trace_commits[2];
    std::deque<FpuTraceWrite> fpu_trace_writes[2];
#endif

    struct TerminalTrace {
        uint64_t clk_start;
        uint64_t clk_end;
    };
    std::unordered_map<uint64_t, TerminalTrace> terminal_trace_by_token[2];
    uint64_t term_seq[2] = {0u, 0u};
    uint64_t instret_seq[2] = {0u, 0u};
    bool interrupt_trace_was_high[2] = {false, false};

    VVexRiscv *top = new VVexRiscv;

    FILE *log_trace = std::fopen("run.logTrace", "w");
    if (!log_trace) {
        std::perror("failed to open run.logTrace");
        return 2;
    }
    FILE *cx_trace = std::fopen("run.cxTrace", "w");
    if (!cx_trace) {
        std::perror("failed to open run.cxTrace");
        return 2;
    }
    std::fprintf(
        cx_trace,
        "trace_version=2\n"
        "cycle_domain=core_ref_clk\n"
        "cycle_base=first_post_reset_posedge_is_1\n"
        "interval=inclusive\n"
        "start_kind=backend_alloc\n"
        "end_kind=arch_commit_or_precise_trap\n"
        "core=VexRiscv\n"
        "harts=2\n"
        "isa=%s\n"
        "build_config=regression_2c\n",
        cx_trace_isa());

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

    // Per-core store edge tracking (memory stage can be held while back-pressured).

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

        // Architectural traces (per-core) at posedge.
        // These are required by riscv_fuzz_test for per-instruction diff analysis.
        auto *soc = top->VexRiscv;
        auto *cpu0 = soc->cores_0_cpu_logic_cpu;
        auto *cpu1 = soc->cores_1_cpu_logic_cpu;

        // Both cores are clocked and reset by the same cluster domain. A
        // divergence would make cross-hart cycle comparisons meaningless.
        if (cpu0->traceCycle != cpu1->traceCycle) {
            std::fprintf(
                log_trace,
                "ERROR trace_cycle_domain_mismatch hart0=%llu hart1=%llu host_cycle=%llu\n",
                static_cast<unsigned long long>(cpu0->traceCycle),
                static_cast<unsigned long long>(cpu1->traceCycle),
                static_cast<unsigned long long>(cycle));
            std::cerr << "VexRiscv hart trace cycles diverged" << std::endl;
            exit_code = 3;
            done = true;
            break;
        }

        // Register writes and timing-only commit lines.
        auto log_commit = [&](auto *cpu, uint32_t hart_id) {
            if (!cpu->lastStageIsFiring) return;

            const uint64_t clk_end = current_clock_cycle(cpu, cycle);
            const uint64_t clk_start = static_cast<uint64_t>(cpu->lastStageStartCycle);
            const uint64_t token = static_cast<uint64_t>(cpu->lastStageToken);
            const uint32_t insn_len = cpu->lastStageIsRvc ? 2u : 4u;
            const uint32_t insn = static_cast<uint32_t>(cpu->lastStageRawInstruction) &
                (insn_len == 2u ? 0xffffu : 0xffffffffu);
            const uint32_t priv = static_cast<uint32_t>(cpu->traceCommitPrivilege);
#if defined(RVF) || defined(RVD)
            if (cpu->writeBack_FpuPlugin_commit_valid &&
                cpu->writeBack_FpuPlugin_commit_ready &&
                cpu->writeBack_FpuPlugin_commit_payload_write) {
                terminal_trace_by_token[hart_id][token] = TerminalTrace{clk_start, clk_end};
            }
#endif
            std::fprintf(
                cx_trace,
                "CXTRACE v=2 event=inst_terminal core=VexRiscv hart=%u token=%llu term_seq=%llu instret_seq=%llu commit_slot=0 pc=0x%08x insn=0x%08x insn_len=%u start_cycle=%llu end_cycle=%llu span=%llu start_kind=backend_alloc end_kind=arch_commit retired=1 trap=0 cause=none priv=%u\n",
                static_cast<unsigned int>(hart_id),
                static_cast<unsigned long long>(token),
                static_cast<unsigned long long>(term_seq[hart_id]),
                static_cast<unsigned long long>(instret_seq[hart_id]),
                static_cast<unsigned int>(cpu->lastStagePc),
                static_cast<unsigned int>(insn),
                static_cast<unsigned int>(insn_len),
                static_cast<unsigned long long>(clk_start),
                static_cast<unsigned long long>(clk_end),
                static_cast<unsigned long long>(clk_end - clk_start + 1u),
                static_cast<unsigned int>(priv));

            if (cpu->traceStoreCommit) {
                log_direct_store_write(
                    mem_trace,
                    clk_end,
                    static_cast<uint32_t>(cpu->lastStagePc),
                    static_cast<uint32_t>(cpu->traceStoreAddress),
                    1u << static_cast<uint32_t>(cpu->traceStoreSize),
                    static_cast<uint64_t>(cpu->traceStoreData),
                    clk_start,
                    clk_end,
                    hart_id,
                    token);
            }
            term_seq[hart_id]++;
            instret_seq[hart_id]++;

            if (cpu->lastStageRegFileWrite_valid &&
                cpu->lastStageRegFileWrite_payload_address != 0) {
                std::fprintf(
                    reg_trace,
                    "%llu PC %08x : reg[%2u] = %08x clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu commit_slot=0 retired=1 trap=0 event=inst_terminal start_kind=backend_alloc end_kind=arch_commit\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(cpu->lastStagePc),
                    static_cast<unsigned int>(cpu->lastStageRegFileWrite_payload_address),
                    static_cast<unsigned int>(cpu->lastStageRegFileWrite_payload_data),
                    static_cast<unsigned long long>(clk_start),
                    static_cast<unsigned long long>(clk_end),
                    static_cast<unsigned long long>(clk_end - clk_start + 1),
                    static_cast<unsigned int>(hart_id),
                    static_cast<unsigned long long>(token));
            } else {
                std::fprintf(
                    reg_trace,
                    "%llu PC %08x clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu commit_slot=0 retired=1 trap=0 event=inst_terminal start_kind=backend_alloc end_kind=arch_commit\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(cpu->lastStagePc),
                    static_cast<unsigned long long>(clk_start),
                    static_cast<unsigned long long>(clk_end),
                    static_cast<unsigned long long>(clk_end - clk_start + 1),
                    static_cast<unsigned int>(hart_id),
                    static_cast<unsigned long long>(token));
            }
        };
        log_commit(cpu0, 0u);
        log_commit(cpu1, 1u);

#if defined(RVF) || defined(RVD)
        auto capture_fpu_commit = [&](auto *cpu, uint32_t hart_id) {
            if (cpu->writeBack_FpuPlugin_commit_valid &&
                cpu->writeBack_FpuPlugin_commit_ready &&
                cpu->writeBack_FpuPlugin_commit_payload_write) {
                fpu_trace_commits[hart_id].push_back(FpuTraceCommit{
                    static_cast<uint32_t>(cpu->writeBack_FpuPlugin_commit_payload_opcode),
                    static_cast<uint64_t>(cpu->writeBack_FpuPlugin_commit_payload_value),
                });
            }
        };
        capture_fpu_commit(cpu0, 0u);
        capture_fpu_commit(cpu1, 1u);
        if (soc->fpu_0_logic && soc->fpu_0_logic->fregWriteValid) {
            const uint64_t cpu0_clk = current_clock_cycle(cpu0, cycle);
            const uint64_t cpu1_clk = current_clock_cycle(cpu1, cycle);
            const uint64_t fclk_end = cpu0_clk > cpu1_clk ? cpu0_clk : cpu1_clk;
            const uint32_t hart_id = static_cast<uint32_t>(soc->fpu_0_logic->fregWriteHart) & 1u;
            FpuTraceWrite trace_write = {
                static_cast<uint32_t>(soc->fpu_0_logic->fregWritePc),
                normalize_start_cycle(
                    static_cast<uint64_t>(soc->fpu_0_logic->fregWriteStartCycle),
                    fclk_end),
                static_cast<uint64_t>(soc->fpu_0_logic->fregWriteToken),
                fclk_end,
                hart_id,
                static_cast<uint32_t>(soc->fpu_0_logic->fregWriteReg),
                static_cast<bool>(soc->fpu_0_logic->fregWriteIsDouble),
                static_cast<uint64_t>(soc->fpu_0_logic->fregWriteData),
            };
            fpu_trace_writes[hart_id].push_back(trace_write);
        }
        for (uint32_t hart_id = 0u; hart_id < 2u; ++hart_id) {
          while (!fpu_trace_commits[hart_id].empty() && !fpu_trace_writes[hart_id].empty()) {
            const FpuTraceWrite trace_write = fpu_trace_writes[hart_id].front();
            auto terminal_it = terminal_trace_by_token[hart_id].find(trace_write.token);
            if (terminal_it == terminal_trace_by_token[hart_id].end()) break;
            const TerminalTrace terminal_trace = terminal_it->second;
            const FpuTraceCommit trace_commit = fpu_trace_commits[hart_id].front();
            const bool use_commit_value =
                trace_commit.opcode == kFpuOpcodeLoad ||
                trace_commit.opcode == kFpuOpcodeFmvWX;
#ifdef RVD
            const uint64_t fval = use_commit_value
                ? (trace_write.is_double
                    ? trace_commit.value
                    : (0xFFFFFFFF00000000ULL | static_cast<uint32_t>(trace_commit.value)))
                : trace_write.data;
            std::fprintf(
                freg_trace,
                "PC %08x : f[%2u] = 0x%016llx clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu event=writeback writeback_cycle=%llu start_kind=backend_alloc end_kind=arch_commit\n",
                static_cast<unsigned int>(trace_write.pc),
                static_cast<unsigned int>(trace_write.reg),
                static_cast<unsigned long long>(fval),
                static_cast<unsigned long long>(terminal_trace.clk_start),
                static_cast<unsigned long long>(terminal_trace.clk_end),
                static_cast<unsigned long long>(terminal_trace.clk_end - terminal_trace.clk_start + 1),
                static_cast<unsigned int>(hart_id),
                static_cast<unsigned long long>(trace_write.token),
                static_cast<unsigned long long>(trace_write.writeback_cycle));
#else
            const uint32_t fval = use_commit_value
                ? static_cast<uint32_t>(trace_commit.value)
                : static_cast<uint32_t>(trace_write.data);
            std::fprintf(
                freg_trace,
                "PC %08x : f[%2u] = 0x%08x clk_start=%llu clk_end=%llu clk_span=%llu hart=%u token=%llu event=writeback writeback_cycle=%llu start_kind=backend_alloc end_kind=arch_commit\n",
                static_cast<unsigned int>(trace_write.pc),
                static_cast<unsigned int>(trace_write.reg),
                static_cast<unsigned int>(fval),
                static_cast<unsigned long long>(terminal_trace.clk_start),
                static_cast<unsigned long long>(terminal_trace.clk_end),
                static_cast<unsigned long long>(terminal_trace.clk_end - terminal_trace.clk_start + 1),
                static_cast<unsigned int>(hart_id),
                static_cast<unsigned long long>(trace_write.token),
                static_cast<unsigned long long>(trace_write.writeback_cycle));
#endif
            std::fprintf(
                cx_trace,
                "CXTRACE v=2 event=writeback core=VexRiscv hart=%u token=%llu cycle=%llu rd_kind=f rd=%u\n",
                static_cast<unsigned int>(hart_id),
                static_cast<unsigned long long>(trace_write.token),
                static_cast<unsigned long long>(trace_write.writeback_cycle),
                static_cast<unsigned int>(trace_write.reg));
            fpu_trace_commits[hart_id].pop_front();
            fpu_trace_writes[hart_id].pop_front();
            terminal_trace_by_token[hart_id].erase(terminal_it);
          }
        }
#endif

        // Exceptions
        if (cpu0->CsrPlugin_hadException) {
            const uint64_t clk_end = current_clock_cycle(cpu0, cycle);
            const uint64_t clk_start = static_cast<uint64_t>(cpu0->CsrPlugin_exceptionPortCtrl_exceptionTraceStartCycle);
            const uint64_t token = static_cast<uint64_t>(cpu0->CsrPlugin_exceptionPortCtrl_exceptionTraceToken);
            const uint32_t pc = static_cast<uint32_t>(cpu0->CsrPlugin_exceptionPortCtrl_exceptionTracePc);
            const uint32_t insn_len = cpu0->CsrPlugin_exceptionPortCtrl_exceptionTraceIsRvc ? 2u : 4u;
            const uint32_t insn = static_cast<uint32_t>(cpu0->CsrPlugin_exceptionPortCtrl_exceptionTraceInstruction) &
                (insn_len == 2u ? 0xffffu : 0xffffffffu);
            const uint32_t cause = static_cast<uint32_t>(cpu0->CsrPlugin_trapCause);
            const uint32_t priv = static_cast<uint32_t>(cpu0->CsrPlugin_exceptionPortCtrl_exceptionTracePrivilege);
            std::fprintf(
                log_trace,
                "EXC pc=0x%08x cause=%u clk_start=%llu clk_end=%llu clk_span=%llu hart=0 token=%llu commit_slot=0 retired=0 trap=1 event=inst_terminal start_kind=backend_alloc end_kind=precise_trap\n",
                static_cast<unsigned int>(pc),
                static_cast<unsigned int>(cause),
                static_cast<unsigned long long>(clk_start),
                static_cast<unsigned long long>(clk_end),
                static_cast<unsigned long long>(clk_end - clk_start + 1),
                static_cast<unsigned long long>(token));
            std::fprintf(
                cx_trace,
                "CXTRACE v=2 event=inst_terminal core=VexRiscv hart=0 token=%llu term_seq=%llu instret_seq=- commit_slot=0 pc=0x%08x insn=0x%08x insn_len=%u start_cycle=%llu end_cycle=%llu span=%llu start_kind=backend_alloc end_kind=precise_trap retired=0 trap=1 cause=%u priv=%u\n",
                static_cast<unsigned long long>(token),
                static_cast<unsigned long long>(term_seq[0]),
                static_cast<unsigned int>(pc),
                static_cast<unsigned int>(insn),
                static_cast<unsigned int>(insn_len),
                static_cast<unsigned long long>(clk_start),
                static_cast<unsigned long long>(clk_end),
                static_cast<unsigned long long>(clk_end - clk_start + 1u),
                static_cast<unsigned int>(cause),
                static_cast<unsigned int>(priv));
            term_seq[0]++;
        }
        if (cpu1->CsrPlugin_hadException) {
            const uint64_t clk_end = current_clock_cycle(cpu1, cycle);
            const uint64_t clk_start = static_cast<uint64_t>(cpu1->CsrPlugin_exceptionPortCtrl_exceptionTraceStartCycle);
            const uint64_t token = static_cast<uint64_t>(cpu1->CsrPlugin_exceptionPortCtrl_exceptionTraceToken);
            const uint32_t pc = static_cast<uint32_t>(cpu1->CsrPlugin_exceptionPortCtrl_exceptionTracePc);
            const uint32_t insn_len = cpu1->CsrPlugin_exceptionPortCtrl_exceptionTraceIsRvc ? 2u : 4u;
            const uint32_t insn = static_cast<uint32_t>(cpu1->CsrPlugin_exceptionPortCtrl_exceptionTraceInstruction) &
                (insn_len == 2u ? 0xffffu : 0xffffffffu);
            const uint32_t cause = static_cast<uint32_t>(cpu1->CsrPlugin_trapCause);
            const uint32_t priv = static_cast<uint32_t>(cpu1->CsrPlugin_exceptionPortCtrl_exceptionTracePrivilege);
            std::fprintf(
                log_trace,
                "EXC pc=0x%08x cause=%u clk_start=%llu clk_end=%llu clk_span=%llu hart=1 token=%llu commit_slot=0 retired=0 trap=1 event=inst_terminal start_kind=backend_alloc end_kind=precise_trap\n",
                static_cast<unsigned int>(pc),
                static_cast<unsigned int>(cause),
                static_cast<unsigned long long>(clk_start),
                static_cast<unsigned long long>(clk_end),
                static_cast<unsigned long long>(clk_end - clk_start + 1),
                static_cast<unsigned long long>(token));
            std::fprintf(
                cx_trace,
                "CXTRACE v=2 event=inst_terminal core=VexRiscv hart=1 token=%llu term_seq=%llu instret_seq=- commit_slot=0 pc=0x%08x insn=0x%08x insn_len=%u start_cycle=%llu end_cycle=%llu span=%llu start_kind=backend_alloc end_kind=precise_trap retired=0 trap=1 cause=%u priv=%u\n",
                static_cast<unsigned long long>(token),
                static_cast<unsigned long long>(term_seq[1]),
                static_cast<unsigned int>(pc),
                static_cast<unsigned int>(insn),
                static_cast<unsigned int>(insn_len),
                static_cast<unsigned long long>(clk_start),
                static_cast<unsigned long long>(clk_end),
                static_cast<unsigned long long>(clk_end - clk_start + 1u),
                static_cast<unsigned int>(cause),
                static_cast<unsigned int>(priv));
            term_seq[1]++;
        }

        auto log_interrupt = [&](auto *cpu, uint32_t hart_id) {
            const bool high = static_cast<bool>(cpu->CsrPlugin_interruptJump);
            if (high && !interrupt_trace_was_high[hart_id]) {
                std::fprintf(
                    cx_trace,
                    "CXTRACE v=2 event=interrupt core=VexRiscv hart=%u cycle=%llu cause=%u priv=%u\n",
                    static_cast<unsigned int>(hart_id),
                    static_cast<unsigned long long>(current_clock_cycle(cpu, cycle)),
                    static_cast<unsigned int>(cpu->CsrPlugin_interrupt_code),
                    static_cast<unsigned int>(cpu->traceInterruptPrivilege));
            }
            interrupt_trace_was_high[hart_id] = high;
        };
        log_interrupt(cpu0, 0u);
        log_interrupt(cpu1, 1u);

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
                uint8_t bytes[16] = {};
                bytes[0] = static_cast<uint8_t>((wdata >> 0) & 0xFFu);
                bytes[1] = static_cast<uint8_t>((wdata >> 8) & 0xFFu);
                bytes[2] = static_cast<uint8_t>((wdata >> 16) & 0xFFu);
                bytes[3] = static_cast<uint8_t>((wdata >> 24) & 0xFFu);
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
                i_dram.write_addr_q.push_back(DramWriteCmd{addr, 0u});
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
                DramWriteCmd write_cmd = i_dram.write_addr_q.front();
                i_dram.write_addr_q.pop_front();
                uint32_t addr = write_cmd.addr;
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
                // Keep functional memory updates; trace architectural stores via per-core dBus.
            }
        }

        // dBridge DRAM commands.
        if (top->dBridge_dram_cmd_valid && top->dBridge_dram_cmd_ready) {
            uint32_t addr = kDramBase + (static_cast<uint32_t>(top->dBridge_dram_cmd_payload_addr) * kDramWordBytes);
            bool we = (top->dBridge_dram_cmd_payload_we != 0);
            if (d_cmd_count < 200) {
                std::fprintf(
                    log_trace,
                    "time=%llu d_cmd addr=0x%08x we=%u source=%u\n",
                    static_cast<unsigned long long>(cycle),
                    static_cast<unsigned int>(addr),
                    static_cast<unsigned int>(we ? 1 : 0),
                    static_cast<unsigned int>(
                        soc->__PVT__dBridge_bmb_slaveModel_arbiterGen_oneToOne_arbiter_cmd_s2mPipe_payload_fragment_source));
            }
            d_cmd_count++;
            if (we) {
                d_dram.write_addr_q.push_back(DramWriteCmd{
                    addr,
                    static_cast<uint32_t>(
                        soc->__PVT__dBridge_bmb_slaveModel_arbiterGen_oneToOne_arbiter_cmd_s2mPipe_payload_fragment_source),
                });
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
                DramWriteCmd write_cmd = d_dram.write_addr_q.front();
                d_dram.write_addr_q.pop_front();
                uint32_t addr = write_cmd.addr;
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

    std::fflush(reg_trace);
    std::fclose(reg_trace);

#if defined(RVF) || defined(RVD)
    std::fflush(freg_trace);
    std::fclose(freg_trace);
#endif

    std::fflush(log_trace);
    std::fclose(log_trace);

    std::fflush(cx_trace);
    std::fclose(cx_trace);

    delete top;
    return exit_code;
}
