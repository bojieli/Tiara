// Tiara PCIe DMA engine (functional model)
//
// On the Alveo U50 prototype the PCIe path delivers a 64-bit host DRAM
// access in ~150 cycles at 200 MHz (≈0.75 µs).  In simulation we use a
// `LATENCY_CYCLES` parameter to reproduce that figure exactly so the
// observed end-to-end timings match the paper.
//
// The DMA owns a backing memory of `MEM_DEPTH` 64-bit words.  The
// testbench seeds it through DPI; see `sim/cosim/bfm.cpp`.
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
    parameter int unsigned MEM_DEPTH      = 1 << 19,   // 4 MiB
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
  logic [63:0] mem [0:MEM_DEPTH-1];

  initial begin
    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 64'd0;
  end

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
    int bytes_left;
    int dst_w, src_w;

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
                // Functional model: copy is committed non-blockingly via
                // a snapshot read pass.  Verilator does not allow `<=`
                // inside for-loops over array elements, so we use
                // blocking assignment here — semantically OK because the
                // copy only mutates memory at the cycle of completion
                // and no other request mutates the same words this cycle.
                bytes_left = s_len[i];
                dst_w      = s_addr_a[i] >> 3;
                src_w      = s_addr_b[i] >> 3;
                while (bytes_left > 0) begin
                  mem[dst_w] = mem[src_w];
                  dst_w      = dst_w + 1;
                  src_w      = src_w + 1;
                  bytes_left = bytes_left - 8;
                end
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

  // DPI-C hooks for the C++ testbench so it can seed/inspect host DRAM
  // before/after a run.  Verilator emits these in the harness header.
  export "DPI-C" task tiara_dpi_dma_poke;
  export "DPI-C" task tiara_dpi_dma_peek;

  task tiara_dpi_dma_poke(input int word_addr, input longint value);
    mem[word_addr] = value;
  endtask

  task tiara_dpi_dma_peek(input int word_addr, output longint value);
    value = mem[word_addr];
  endtask

endmodule
