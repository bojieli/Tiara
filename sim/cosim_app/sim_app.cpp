// Tiara datapath end-to-end testbench (Verilator).
//
// Builds against `tiara_datapath_top` from
// integration/corundum_app/rtl.  Drives a synthetic Tiara invocation
// packet onto the RX AXIS and captures the TX response.
//
//   ./Vtiara_datapath_top --selftest
//
// Tests:
//   1. Loads a 2-instruction operator (LI r1, 42 ; RET r1).
//   2. Builds a 96-byte invocation packet for that operator with
//      task_id=0xCAFE and arbitrary args.
//   3. Drives the packet onto the RX AXIS in two beats.
//   4. Waits for the TX AXIS response, parses it, verifies the
//      result matches.

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "Vtiara_datapath_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

namespace {

constexpr uint16_t TIARA_ETHERTYPE     = 0x88B5;
constexpr uint32_t TIARA_MAGIC         = 0x010071A5;
constexpr uint16_t TIARA_KIND_INVOKE   = 0x0001;
constexpr uint16_t TIARA_KIND_RESPONSE = 0x0002;

constexpr uint64_t encode_word(uint64_t op, uint64_t rd, uint64_t rs1,
                               uint64_t rs2, uint64_t sub, int64_t imm) {
    uint64_t i40 = static_cast<uint64_t>(imm) & ((1ULL << 40) - 1);
    return (op << 56) | (rd << 52) | (rs1 << 48) | (rs2 << 44) |
           (sub << 40) | i40;
}

class App {
public:
    App() : top_(new Vtiara_datapath_top) {
        Verilated::traceEverOn(true);
        vcd_ = new VerilatedVcdC;
        top_->trace(vcd_, 99);
        vcd_->open("/tmp/tiara_app.vcd");
        top_->clk = 0;
        top_->rst_n = 0;
        top_->load_en = 0;
        top_->load_addr = 0;
        top_->load_data = 0;
        top_->local_mac = 0xAABBCCDDEE01ULL;
        for (int w = 0; w < 16; w++) top_->s_axis_rx_tdata[w] = 0;
        top_->s_axis_rx_tkeep  = 0;
        top_->s_axis_rx_tvalid = 0;
        top_->s_axis_rx_tlast  = 0;
        top_->m_axis_rx_tready = 1;
        top_->m_axis_tx_tready = 1;
        reset();
    }
    ~App() { vcd_->close(); delete vcd_; delete top_; }

    void tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top_->clk = 0; top_->eval();
            vcd_->dump(cycles_ * 10);
            top_->clk = 1; top_->eval();
            vcd_->dump(cycles_ * 10 + 5);
            cycles_++;
        }
    }
    void reset() {
        top_->rst_n = 0;
        tick(8);
        top_->rst_n = 1;
        tick(2);
    }

    void load_operator(const std::vector<uint64_t>& words) {
        for (uint32_t i = 0; i < words.size(); i++) {
            top_->load_en = 1;
            top_->load_addr = i;
            top_->load_data = words[i];
            tick(1);
        }
        top_->load_en = 0;
        tick(2);
    }

    void send_rx_packet(const std::vector<uint8_t>& bytes) {
        // 64 bytes per beat
        size_t pos = 0;
        while (pos < bytes.size()) {
            std::array<uint8_t, 64> beat{};
            std::array<uint8_t, 64> keep{};
            keep.fill(0);
            size_t n = std::min<size_t>(64, bytes.size() - pos);
            for (size_t i = 0; i < n; i++) {
                beat[i] = bytes[pos + i];
                keep[i] = 1;
            }
            // Pack into VL_WDATA_T (Verilator generates a uint32_t[]
            // for wide signals).  tdata is 512 bits = 16 x 32-bit words.
            for (int w = 0; w < 16; w++) {
                uint32_t word = 0;
                for (int b = 0; b < 4; b++) {
                    word |= static_cast<uint32_t>(beat[w*4 + b]) << (b * 8);
                }
                top_->s_axis_rx_tdata[w] = word;
            }
            uint64_t kbits = 0;
            for (int b = 0; b < 64; b++) if (keep[b]) kbits |= (1ULL << b);
            top_->s_axis_rx_tkeep = kbits;

            top_->s_axis_rx_tvalid = 1;
            top_->s_axis_rx_tlast  = (pos + n == bytes.size()) ? 1 : 0;
            // Wait until accepted
            int guard = 0;
            do {
                tick(1); guard++;
                if (guard > 1000) {
                    std::fprintf(stderr, "RX backpressure timeout\n");
                    return;
                }
            } while (!top_->s_axis_rx_tready);
            pos += n;
        }
        top_->s_axis_rx_tvalid = 0;
        top_->s_axis_rx_tlast  = 0;
    }

    bool wait_tx_response(std::array<uint8_t, 64>& out, uint64_t max_cycles = 5000) {
        uint64_t start = cycles_;
        while (cycles_ - start < max_cycles) {
            if (top_->m_axis_tx_tvalid && top_->m_axis_tx_tready) {
                for (int w = 0; w < 16; w++) {
                    uint32_t word = top_->m_axis_tx_tdata[w];
                    for (int b = 0; b < 4; b++) {
                        out[w*4 + b] = (word >> (b * 8)) & 0xFF;
                    }
                }
                tick(1);
                return true;
            }
            tick(1);
            if ((cycles_ - start) % 50 == 0) {
                std::fprintf(stderr,
                    "  [t=%llu] rx_inv=%u busy=%u done=%u retired=%u tx_valid=%u\n",
                    static_cast<unsigned long long>(cycles_),
                    top_->dbg_rx_inv_valid, top_->dbg_tia_busy,
                    top_->dbg_tia_done, top_->instr_retired,
                    top_->m_axis_tx_tvalid);
            }
        }
        return false;
    }

    uint64_t cycles() const { return cycles_; }

private:
    Vtiara_datapath_top* top_;
    VerilatedVcdC*       vcd_ = nullptr;
    uint64_t cycles_ = 0;
};

std::vector<uint8_t> build_invocation(uint64_t src_mac,
                                       uint64_t dst_mac,
                                       uint32_t op_id,
                                       uint32_t task_id,
                                       const std::array<uint64_t, 8>& args) {
    std::vector<uint8_t> p(96, 0);
    auto put_u8  = [&](size_t off, uint8_t  v) { p[off] = v; };
    auto put_u16_be = [&](size_t off, uint16_t v) {
        p[off]   = static_cast<uint8_t>(v >> 8);
        p[off+1] = static_cast<uint8_t>(v & 0xFF);
    };
    auto put_u16_le = [&](size_t off, uint16_t v) {
        p[off]   = static_cast<uint8_t>(v & 0xFF);
        p[off+1] = static_cast<uint8_t>(v >> 8);
    };
    auto put_u32_le = [&](size_t off, uint32_t v) {
        for (int i = 0; i < 4; i++) p[off + i] = (v >> (8 * i)) & 0xFF;
    };
    auto put_u48 = [&](size_t off, uint64_t v) {
        for (int i = 0; i < 6; i++) p[off + i] = (v >> (8 * i)) & 0xFF;
    };
    auto put_u64_le = [&](size_t off, uint64_t v) {
        for (int i = 0; i < 8; i++) p[off + i] = (v >> (8 * i)) & 0xFF;
    };

    put_u48(0, dst_mac);
    put_u48(6, src_mac);
    put_u16_be(12, TIARA_ETHERTYPE);
    put_u32_le(14, TIARA_MAGIC);
    put_u16_le(18, TIARA_KIND_INVOKE);
    put_u32_le(20, op_id);
    put_u32_le(24, task_id);
    put_u32_le(28, 0);                 // flags
    for (int i = 0; i < 8; i++) put_u64_le(32 + i*8, args[i]);
    return p;
}

bool parse_response(const std::array<uint8_t, 64>& p,
                    uint32_t& op_id, uint32_t& task_id,
                    uint16_t& status, std::array<uint64_t, 4>& result) {
    auto get_u16_be = [&](size_t off) -> uint16_t {
        return (uint16_t(p[off]) << 8) | p[off+1];
    };
    auto get_u16_le = [&](size_t off) -> uint16_t {
        return uint16_t(p[off]) | (uint16_t(p[off+1]) << 8);
    };
    auto get_u32_le = [&](size_t off) -> uint32_t {
        uint32_t v = 0;
        for (int i = 0; i < 4; i++) v |= uint32_t(p[off+i]) << (8*i);
        return v;
    };
    auto get_u64_le = [&](size_t off) -> uint64_t {
        uint64_t v = 0;
        for (int i = 0; i < 8; i++) v |= uint64_t(p[off+i]) << (8*i);
        return v;
    };

    if (get_u16_be(12) != TIARA_ETHERTYPE) return false;
    if (get_u32_le(14) != TIARA_MAGIC)     return false;
    if (get_u16_le(18) != TIARA_KIND_RESPONSE) return false;
    op_id   = get_u32_le(20);
    task_id = get_u32_le(24);
    status  = get_u16_le(28);
    for (int i = 0; i < 4; i++) result[i] = get_u64_le(32 + i*8);
    return true;
}

struct TestCase {
    const char*               name;
    std::vector<uint64_t>     prog;
    std::array<uint64_t, 8>   args;
    uint64_t                  expected_r1;
};

bool run_case(App& app, const TestCase& tc, uint32_t task_id) {
    app.load_operator(tc.prog);
    auto pkt = build_invocation(0x112233445566ULL, 0xAABBCCDDEE01ULL,
                                /*op_id=*/0x42, task_id, tc.args);
    app.send_rx_packet(pkt);
    std::array<uint8_t, 64> resp{};
    bool got = app.wait_tx_response(resp);
    if (!got) {
        std::fprintf(stderr, "  [%s] TIMEOUT\n", tc.name);
        return false;
    }
    uint32_t op_id, tid;
    uint16_t status;
    std::array<uint64_t, 4> result{};
    if (!parse_response(resp, op_id, tid, status, result)) {
        std::fprintf(stderr, "  [%s] response parse failed\n", tc.name);
        return false;
    }
    bool ok = (tid == task_id) && (status & 1) && (result[0] == tc.expected_r1);
    std::printf("  [%-22s] task=%#x status=%#x r1=%lu  %s\n",
                tc.name, tid, status,
                static_cast<unsigned long>(result[0]),
                ok ? "PASS" : "FAIL");
    return ok;
}

int run_selftest() {
    App app;
    int passed = 0, total = 0;

    // 1) LI r1, 42 ; RET r1  -> r1 = 42
    {
        TestCase tc;
        tc.name = "LI42";
        tc.prog = { encode_word(0x20, 1, 0, 0, 0xC, 42),
                    encode_word(0x13, 0, 1, 0, 0, 0) };
        tc.args = {{0,0,0,0,0,0,0,0}};
        tc.expected_r1 = 42;
        total++; if (run_case(app, tc, 0x1001)) passed++;
    }

    // 2) ADDI r1, r1, 100 ; RET r1   args[0]=7  -> r1 = 107
    {
        TestCase tc;
        tc.name = "ADDI 7+100";
        tc.prog = { encode_word(0x20, 1, 1, 0, 0x8, 100),
                    encode_word(0x13, 0, 1, 0, 0, 0) };
        tc.args = {{7,0,0,0,0,0,0,0}};
        tc.expected_r1 = 107;
        total++; if (run_case(app, tc, 0x1002)) passed++;
    }

    // 3) Sum first two args:  ADD r1, r1, r2 ; RET r1   args=(5,11) -> 16
    {
        TestCase tc;
        tc.name = "ADD args[0]+args[1]";
        tc.prog = { encode_word(0x20, 1, 1, 2, 0x0, 0),
                    encode_word(0x13, 0, 1, 0, 0, 0) };
        tc.args = {{5,11,0,0,0,0,0,0}};
        tc.expected_r1 = 16;
        total++; if (run_case(app, tc, 0x1003)) passed++;
    }

    // 4) Bounded loop: LOOP r1, body_end ; ADDI r2, r2, 1 ; body_end: ADDI r1, r2, 0 ; RET r1
    //    args[0] = 5  -> loop 5 times -> r2 = 5 -> r1 = 5
    {
        TestCase tc;
        tc.name = "LOOP iter=5";
        tc.prog = {
            encode_word(0x11, 0, 1, 0, 0, 1),     // LOOP r1, body_end (body_len = 1)
            encode_word(0x20, 2, 2, 0, 0x8, 1),   // ADDI r2, r2, 1
            encode_word(0x20, 1, 2, 0, 0x8, 0),   // ADDI r1, r2, 0
            encode_word(0x13, 0, 1, 0, 0, 0),     // RET r1
        };
        tc.args = {{5,0,0,0,0,0,0,0}};
        tc.expected_r1 = 5;
        total++; if (run_case(app, tc, 0x1004)) passed++;
    }

    std::printf("\n%d/%d test cases passed (%llu cycles total).\n",
                passed, total, static_cast<unsigned long long>(app.cycles()));
    return (passed == total) ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool selftest = false;
    for (int i = 1; i < argc; i++)
        if (std::string(argv[i]) == "--selftest") selftest = true;
    if (selftest) return run_selftest();
    std::printf("usage: tiara_app_sim --selftest\n");
    return 0;
}
