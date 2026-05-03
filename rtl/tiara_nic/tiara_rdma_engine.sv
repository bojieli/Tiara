// Tiara RDMA engine (functional model)
//
// Models the network-side path: outbound RDMA Read/Write/CAS to peer
// memory, plus the inbound dispatcher that hands incoming Tiara
// invocation messages to the task dispatcher.
//
// The peer-memory side is modeled as a separate backing array per
// device_id.  The simulator pre-populates these via DPI before a run.
// Each access pays `RTT_CYCLES` of latency to model the network round
// trip (default 500 cycles = 2.5 µs at 200 MHz).

`include "tiara_pkg.svh"

module tiara_rdma_engine
  import tiara_pkg::*;
#(
    parameter int unsigned RTT_CYCLES   = 500,
    // BRAM size of the simulated peer-DRAM stub.  Sim uses large values;
    // synthesis overrides these via the top module.
    parameter int unsigned MEM_DEPTH    = 1 << 17,
    parameter int unsigned NUM_PEERS    = 4,
    parameter int unsigned MAX_INFLIGHT = 32,
    parameter int unsigned BEAT_BYTES   = 64
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // From memory subsystem (when an MP issues an op to a remote device)
    input  logic                  rd_en,
    input  logic [15:0]           rd_dev,
    input  logic [31:0]           rd_addr,
    output logic                  rd_valid,
    output logic [63:0]           rd_data,
    output logic                  rd_err,

    input  logic                  wr_en,
    input  logic [15:0]           wr_dev,
    input  logic [31:0]           wr_addr,
    input  logic [63:0]           wr_data,
    output logic                  wr_done,

    input  logic                  cpy_en,
    input  logic                  cpy_async,
    input  logic [15:0]           cpy_dst_dev,
    input  logic [31:0]           cpy_dst_addr,
    input  logic [15:0]           cpy_src_dev,
    input  logic [31:0]           cpy_src_addr,
    input  logic [31:0]           cpy_len,
    output logic                  cpy_accept,
    output logic                  cpy_done,
    output logic                  cpy_err,

    input  logic                  atom_en,
    input  logic                  atom_caa,
    input  logic [15:0]           atom_dev,
    input  logic [31:0]           atom_addr,
    input  logic [63:0]           atom_expected,
    input  logic [63:0]           atom_swap,
    output logic                  atom_valid,
    output logic [63:0]           atom_data,

    output logic                  ready
);

  // -------------------------------------------------------------------
  // Per-peer backing memory (NUM_PEERS x MEM_DEPTH 64-bit words)
  // -------------------------------------------------------------------
  (* ram_style = "block" *) logic [63:0] peer_mem [0:NUM_PEERS-1][0:MEM_DEPTH-1];

`ifndef SYNTHESIS
  initial begin
    for (int p = 0; p < NUM_PEERS; p++)
      for (int i = 0; i < MEM_DEPTH; i++)
        peer_mem[p][i] = 64'd0;
  end
`endif

  // -------------------------------------------------------------------
  // In-flight tracking — same pattern as the PCIe DMA
  // -------------------------------------------------------------------
  localparam logic [3:0] KIND_READ  = 4'd1;
  localparam logic [3:0] KIND_WRITE = 4'd2;
  localparam logic [3:0] KIND_CPY   = 4'd3;
  localparam logic [3:0] KIND_CAS   = 4'd4;
  localparam logic [3:0] KIND_CAA   = 4'd5;

  logic                 s_valid     [0:MAX_INFLIGHT-1];
  logic [3:0]           s_kind      [0:MAX_INFLIGHT-1];
  logic                 s_async     [0:MAX_INFLIGHT-1];
  logic [15:0]          s_dev_a     [0:MAX_INFLIGHT-1];
  logic [15:0]          s_dev_b     [0:MAX_INFLIGHT-1];
  logic [31:0]          s_addr_a    [0:MAX_INFLIGHT-1];
  logic [31:0]          s_addr_b    [0:MAX_INFLIGHT-1];
  logic [63:0]          s_data_a    [0:MAX_INFLIGHT-1];
  logic [63:0]          s_data_b    [0:MAX_INFLIGHT-1];
  logic [31:0]          s_len       [0:MAX_INFLIGHT-1];
  int                   s_count     [0:MAX_INFLIGHT-1];

  int inflight_count;

  function automatic int find_free_slot;
    for (int i = 0; i < MAX_INFLIGHT; i++) begin
      if (!s_valid[i]) return i;
    end
    return -1;
  endfunction

  assign ready = (inflight_count < MAX_INFLIGHT);

  always_ff @(posedge clk or negedge rst_n) begin
    int slot;
    int dev_a_idx, dev_b_idx;
    if (!rst_n) begin
      for (int i = 0; i < MAX_INFLIGHT; i++) begin
        s_valid[i] <= 1'b0;
        s_count[i] <= 0;
      end
      inflight_count <= 0;
      rd_valid   <= 1'b0; rd_data <= '0; rd_err <= 1'b0;
      wr_done    <= 1'b0;
      cpy_accept <= 1'b0; cpy_done <= 1'b0; cpy_err <= 1'b0;
      atom_valid <= 1'b0; atom_data <= '0;
    end else begin
      rd_valid   <= 1'b0;
      wr_done    <= 1'b0;
      cpy_accept <= 1'b0;
      cpy_done   <= 1'b0;
      atom_valid <= 1'b0;

      slot = -1;
      if (rd_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= KIND_READ;
          s_dev_a[slot]  <= rd_dev;
          s_addr_a[slot] <= rd_addr;
          s_count[slot]  <= RTT_CYCLES;
          inflight_count <= inflight_count + 1;
        end
      end else if (wr_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= KIND_WRITE;
          s_dev_a[slot]  <= wr_dev;
          s_addr_a[slot] <= wr_addr;
          s_data_a[slot] <= wr_data;
          s_count[slot]  <= RTT_CYCLES;
          inflight_count <= inflight_count + 1;
        end
      end else if (cpy_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= KIND_CPY;
          s_async[slot]  <= cpy_async;
          s_dev_a[slot]  <= cpy_dst_dev;
          s_dev_b[slot]  <= cpy_src_dev;
          s_addr_a[slot] <= cpy_dst_addr;
          s_addr_b[slot] <= cpy_src_addr;
          s_len[slot]    <= cpy_len;
          s_count[slot]  <= RTT_CYCLES + (cpy_len + BEAT_BYTES - 1) / BEAT_BYTES;
          inflight_count <= inflight_count + 1;
          cpy_accept     <= 1'b1;
        end
      end else if (atom_en && ready) begin
        slot = find_free_slot();
        if (slot >= 0) begin
          s_valid[slot]  <= 1'b1;
          s_kind[slot]   <= atom_caa ? KIND_CAA : KIND_CAS;
          s_dev_a[slot]  <= atom_dev;
          s_addr_a[slot] <= atom_addr;
          s_data_a[slot] <= atom_expected;
          s_data_b[slot] <= atom_swap;
          s_count[slot]  <= RTT_CYCLES;
          inflight_count <= inflight_count + 1;
        end
      end

      for (int i = 0; i < MAX_INFLIGHT; i++) begin
        if (s_valid[i]) begin
          if (s_count[i] > 0) begin
            s_count[i] <= s_count[i] - 1;
          end else begin
            dev_a_idx = (s_dev_a[i] == 16'd0) ? 0 :
                        (s_dev_a[i] >= NUM_PEERS) ? 0 : s_dev_a[i];
            dev_b_idx = (s_dev_b[i] == 16'd0) ? 0 :
                        (s_dev_b[i] >= NUM_PEERS) ? 0 : s_dev_b[i];
            unique case (s_kind[i])
              KIND_READ: begin
                rd_valid <= 1'b1;
                rd_data  <= peer_mem[dev_a_idx][s_addr_a[i][31:3]];
                rd_err   <= (s_dev_a[i] >= NUM_PEERS);
              end
              KIND_WRITE: begin
                peer_mem[dev_a_idx][s_addr_a[i][31:3]] <= s_data_a[i];
                wr_done <= 1'b1;
              end
              KIND_CPY: begin
                // See note in tiara_pcie_dma.sv KIND_CPY: latency only.
                cpy_done <= 1'b1;
                cpy_err  <= 1'b0;
              end
              KIND_CAS: begin
                atom_valid <= 1'b1;
                atom_data  <= peer_mem[dev_a_idx][s_addr_a[i][31:3]];
                if (peer_mem[dev_a_idx][s_addr_a[i][31:3]] == s_data_a[i]) begin
                  peer_mem[dev_a_idx][s_addr_a[i][31:3]] <= s_data_b[i];
                end
              end
              KIND_CAA: begin
                atom_valid <= 1'b1;
                atom_data  <= peer_mem[dev_a_idx][s_addr_a[i][31:3]];
                peer_mem[dev_a_idx][s_addr_a[i][31:3]] <=
                    peer_mem[dev_a_idx][s_addr_a[i][31:3]] + s_data_a[i];
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
  // BFM hooks for the testbench (sim only).
  export "DPI-C" task tiara_dpi_rdma_poke;
  export "DPI-C" task tiara_dpi_rdma_peek;

  task tiara_dpi_rdma_poke(input int dev, input int word_addr,
                           input longint value);
    if (dev >= 0 && dev < NUM_PEERS) peer_mem[dev][word_addr] = value;
  endtask

  task tiara_dpi_rdma_peek(input int dev, input int word_addr,
                           output longint value);
    if (dev >= 0 && dev < NUM_PEERS) value = peer_mem[dev][word_addr];
    else                              value = 64'd0;
  endtask
`endif

endmodule
