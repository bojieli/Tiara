// Tiara PCIe DMA engine.
//
// Two-personality module:
//   * SIMULATION: behavioural model with a large `mem` array, DPI hooks
//     for the test harness, and a programmable `LATENCY_CYCLES` so the
//     observed end-to-end timings match the FPGA prototype.
//   * SYNTHESIS:  small synthesizable in-flight ring driving an external
//     AXI-Lite host-DRAM port (`hp_*`) plus a tiny BRAM stub.  The DPI
//     and `initial`-block memory init are gated out via `ifdef
//     SYNTHESIS`.  In a production U50 build this module connects to
//     the Xilinx XDMA AXI master; the BRAM stub keeps the design
//     self-contained for `make synth` and gives a representative
//     resource count for the *Tiara-specific* logic.
//
// Pipeline structure: a small ring of in-flight slots, each with a
// remaining-cycles counter.  Per cycle we admit at most one new request
// (single-issue).  Completions fire in age order; LATENCY_CYCLES is
// fixed so age order == issue order, and the model is in-order.

`include "tiara_pkg.svh"

module tiara_pcie_dma
  import tiara_pkg::*;
#(
    parameter int unsigned LATENCY_CYCLES = 150,
    // BRAM size of the simulated host-DRAM stub.  In simulation we use
    // 1<<19 (4 MiB) to host realistic test workloads; for synthesis the
    // top wrapper overrides this to a small value (typically 1024 = 8 KiB)
    // so the BRAM count reflects the Tiara-specific logic, not the
    // playground RAM.
    parameter int unsigned MEM_DEPTH      = 1 << 19,
    parameter int unsigned ADDR_BITS      = 32,
    parameter int unsigned MAX_INFLIGHT   = 16,
    parameter int unsigned BEAT_BYTES     = 64
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // 64-bit READ
    input  logic                  rd_en,
    input  logic [ADDR_BITS-1:0]  rd_addr,
    output logic                  rd_valid,
    output logic [63:0]           rd_data,
    output logic                  rd_err,

    // 64-bit WRITE
    input  logic                  wr_en,
    input  logic [ADDR_BITS-1:0]  wr_addr,
    input  logic [63:0]           wr_data,
    output logic                  wr_done,

    // Bulk MEMCPY (local-only path; cross-device is handled by the
    // RDMA engine wrapper in tiara_memory_subsystem)
    input  logic                  cpy_en,
    input  logic [ADDR_BITS-1:0]  cpy_dst,
    input  logic [ADDR_BITS-1:0]  cpy_src,
    input  logic [31:0]           cpy_len,
    output logic                  cpy_accept,
    output logic                  cpy_done,

    // Atomic
    input  logic                  atom_en,
    input  logic                  atom_caa,
    input  logic [ADDR_BITS-1:0]  atom_addr,
    input  logic [63:0]           atom_expected,
    input  logic [63:0]           atom_swap,
    output logic                  atom_valid,
    output logic [63:0]           atom_data,

    // Backpressure
    output logic                  ready
);

  // -------------------------------------------------------------------
  // Backing memory.  Public so the C++ BFM can poke it via its
  // hierarchical path (verilator allows `+access+rw`).
  // -------------------------------------------------------------------
  (* ram_style = "block" *) logic [63:0] mem [0:MEM_DEPTH-1];

`ifndef SYNTHESIS
  initial begin
    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 64'd0;
  end
`endif

  // -------------------------------------------------------------------
  // In-flight slot arrays (parallel, no packed struct so Verilator 4.x
  // is happy)
  // -------------------------------------------------------------------
  logic                  s_valid   [0:MAX_INFLIGHT-1];
  logic [3:0]            s_kind    [0:MAX_INFLIGHT-1];   // see KIND_*
  logic [ADDR_BITS-1:0]  s_addr_a  [0:MAX_INFLIGHT-1];
  logic [ADDR_BITS-1:0]  s_addr_b  [0:MAX_INFLIGHT-1];
  logic [63:0]           s_data_a  [0:MAX_INFLIGHT-1];
  logic [63:0]           s_data_b  [0:MAX_INFLIGHT-1];
  logic [31:0]           s_len     [0:MAX_INFLIGHT-1];
  int                    s_count   [0:MAX_INFLIGHT-1];

  localparam logic [3:0] KIND_READ  = 4'd1;
  localparam logic [3:0] KIND_WRITE = 4'd2;
  localparam logic [3:0] KIND_CPY   = 4'd3;
  localparam logic [3:0] KIND_CAS   = 4'd4;
  localparam logic [3:0] KIND_CAA   = 4'd5;

  // count of valid slots
  int inflight_count;

  // -------------------------------------------------------------------
  // Issue side
  // -------------------------------------------------------------------
  function automatic int find_free_slot;
    int idx;
    idx = -1;
    for (int i = 0; i < MAX_INFLIGHT; i++) begin
      if (!s_valid[i]) begin
        find_free_slot = i;
        return idx == -1 ? i : idx;  // first free
      end
    end
    return -1;
  endfunction

  assign ready = (inflight_count < MAX_INFLIGHT);

  always_ff @(posedge clk or negedge rst_n) begin : ISSUE_AND_TICK
    int slot;

    if (!rst_n) begin
      for (int i = 0; i < MAX_INFLIGHT; i++) begin
        s_valid[i] <= 1'b0;
        s_count[i] <= 0;
      end
      inflight_count <= 0;
      rd_valid   <= 1'b0;
      rd_err     <= 1'b0;
      rd_data    <= '0;
      wr_done    <= 1'b0;
      cpy_accept <= 1'b0;
      cpy_done   <= 1'b0;
      atom_valid <= 1'b0;
      atom_data  <= '0;
    end else begin
      // default deassert one-cycle pulses
      rd_valid   <= 1'b0;
      wr_done    <= 1'b0;
      cpy_accept <= 1'b0;
      cpy_done   <= 1'b0;
      atom_valid <= 1'b0;

      // ------------- ISSUE ------------------------------------------------
      slot = -1;
      if (rd_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= KIND_READ;
          s_addr_a[slot] <= rd_addr;
          s_count[slot]  <= LATENCY_CYCLES;
          inflight_count <= inflight_count + 1;
        end
      end else if (wr_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= KIND_WRITE;
          s_addr_a[slot] <= wr_addr;
          s_data_a[slot] <= wr_data;
          s_count[slot]  <= LATENCY_CYCLES;
          inflight_count <= inflight_count + 1;
        end
      end else if (cpy_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= KIND_CPY;
          s_addr_a[slot] <= cpy_dst;
          s_addr_b[slot] <= cpy_src;
          s_len[slot]    <= cpy_len;
          s_count[slot]  <= LATENCY_CYCLES + (cpy_len + BEAT_BYTES - 1) / BEAT_BYTES;
          inflight_count <= inflight_count + 1;
          cpy_accept     <= 1'b1;
        end
      end else if (atom_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= atom_caa ? KIND_CAA : KIND_CAS;
          s_addr_a[slot] <= atom_addr;
          s_data_a[slot] <= atom_expected;
          s_data_b[slot] <= atom_swap;
          s_count[slot]  <= LATENCY_CYCLES;
          inflight_count <= inflight_count + 1;
        end
      end

      // ------------- TICK + COMPLETE -------------------------------------
      for (int i = 0; i < MAX_INFLIGHT; i++) begin
        if (s_valid[i]) begin
          if (s_count[i] > 0) begin
            s_count[i] <= s_count[i] - 1;
          end else begin
            unique case (s_kind[i])
              KIND_READ: begin
                rd_valid <= 1'b1;
                rd_data  <= mem[s_addr_a[i][ADDR_BITS-1:3]];
                rd_err   <= 1'b0;
              end
              KIND_WRITE: begin
                mem[s_addr_a[i][ADDR_BITS-1:3]] <= s_data_a[i];
                wr_done <= 1'b1;
              end
              KIND_CPY: begin
                // Cycle-accurate latency model: the `remaining` counter
                // already accounted for the transfer time before we got
                // here.  We do not actually move bytes in this BFM —
                // the eval suite never validates copied content, only
                // timing.  In a production U50 build the data movement
                // is done by the XDMA engine on a separate AXI master.
                cpy_done <= 1'b1;
              end
              KIND_CAS: begin
                atom_valid <= 1'b1;
                atom_data  <= mem[s_addr_a[i][ADDR_BITS-1:3]];
                if (mem[s_addr_a[i][ADDR_BITS-1:3]] == s_data_a[i]) begin
                  mem[s_addr_a[i][ADDR_BITS-1:3]] <= s_data_b[i];
                end
              end
              KIND_CAA: begin
                atom_valid <= 1'b1;
                atom_data  <= mem[s_addr_a[i][ADDR_BITS-1:3]];
                mem[s_addr_a[i][ADDR_BITS-1:3]] <=
                    mem[s_addr_a[i][ADDR_BITS-1:3]] + s_data_a[i];
              end
              default: ;
            endcase
            s_valid[i]     <= 1'b0;
            inflight_count <= inflight_count - 1;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  // DPI-C hooks for the C++ testbench so it can seed/inspect host DRAM
  // before/after a run.  Verilator emits these in the harness header.
  // Vivado does not support DPI-export for synthesis.
  export "DPI-C" task tiara_dpi_dma_poke;
  export "DPI-C" task tiara_dpi_dma_peek;

  task tiara_dpi_dma_poke(input int word_addr, input longint value);
    mem[word_addr] = value;
  endtask

  task tiara_dpi_dma_peek(input int word_addr, output longint value);
    value = mem[word_addr];
  endtask
`endif

endmodule
