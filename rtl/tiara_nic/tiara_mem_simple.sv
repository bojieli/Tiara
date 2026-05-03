// Tiara minimal memory subsystem (synthesis-friendly).
//
// Implements `tiara_mem_if.mem` with a single in-flight request and a
// fixed-cycle latency model.  No in-flight ring, no parallel writes to
// shared counters — synthesizes cleanly into a small FSM.
//
// In a production U50 build this module is replaced by the AXI master
// pipeline that connects to Xilinx XDMA (host DRAM) and the Corundum
// RDMA stack (peer hosts).  Both engines naturally support multiple
// in-flight requests via AXI's outstanding-transaction protocol; we do
// not need to model that here in the BFM stub.

`include "tiara_pkg.svh"

module tiara_mem_simple
  import tiara_pkg::*;
#(
    parameter int unsigned LOCAL_LATENCY_CYCLES = 150,
    parameter int unsigned RTT_CYCLES           = 500,
    parameter int unsigned LOCAL_MEM_DEPTH      = 1024,
    parameter int unsigned PEER_MEM_DEPTH       = 256
)
(
    input  logic       clk,
    input  logic       rst_n,

    tiara_mem_if.mem   mem
);

  function automatic logic [15:0] dev_of(logic [63:0] a);
    dev_of = a[63:48];
  endfunction
  function automatic logic [29:0] off_of(logic [63:0] a);
    off_of = a[31:2];   // 32-bit byte offset, but we index in 64-bit
                        // words (drop bottom 3 bits) — keep 30 bits to
                        // be safe.
  endfunction

  localparam int unsigned LOCAL_AW = $clog2(LOCAL_MEM_DEPTH);
  localparam int unsigned PEER_AW  = $clog2(PEER_MEM_DEPTH);

  (* ram_style = "block" *) logic [63:0] local_mem [0:LOCAL_MEM_DEPTH-1];
  (* ram_style = "block" *) logic [63:0] peer_mem  [0:PEER_MEM_DEPTH-1];

  // Single-slot in-flight tracking: one request at a time.  ready=1
  // when no request is pending.
  typedef enum logic [2:0] {
      M_IDLE   = 3'd0,
      M_WAIT   = 3'd1,
      M_DRIVE  = 3'd2
  } mstate_e;

  mstate_e          state;
  logic [15:0]      cnt;
  logic [3:0]       cur_kind;
  logic             cur_local;
  logic             cur_async;
  logic [LOCAL_AW-1:0] cur_addr_local;
  logic [PEER_AW-1:0]  cur_addr_peer;
  logic [63:0]      cur_wdata;
  logic [63:0]      cur_atom_exp;
  logic [63:0]      cur_atom_swap;
  logic             cur_caa;

  localparam logic [3:0] K_LOAD = 4'd1, K_STORE = 4'd2,
                         K_CPY  = 4'd3, K_ATOM  = 4'd4;

  // Outputs ----------------------------------------------------------
  assign mem.ready      = (state == M_IDLE);
  // sync_data / sync_valid asserted in M_DRIVE for one cycle
  // cpy_accept asserted on issue, cpy_done in M_DRIVE for async copies
  // We compute below.

  logic [63:0] read_word;
  // Read both possible memories combinationally; the right one is
  // selected by cur_local.
  logic [63:0] local_rd, peer_rd;
  always_ff @(posedge clk) begin
    local_rd <= local_mem[cur_addr_local];
    peer_rd  <= peer_mem [cur_addr_peer];
  end
  assign read_word = cur_local ? local_rd : peer_rd;

  // FSM
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state            <= M_IDLE;
      cnt              <= 0;
      cur_kind         <= 4'd0;
      cur_local        <= 1'b0;
      cur_async        <= 1'b0;
      cur_addr_local   <= '0;
      cur_addr_peer    <= '0;
      cur_wdata        <= '0;
      cur_atom_exp     <= '0;
      cur_atom_swap    <= '0;
      cur_caa          <= 1'b0;
      mem.sync_valid   <= 1'b0;
      mem.sync_data    <= '0;
      mem.sync_err     <= 1'b0;
      mem.cpy_accept   <= 1'b0;
      mem.cpy_done     <= 1'b0;
      mem.cpy_err      <= 1'b0;
    end else begin
      mem.sync_valid <= 1'b0;
      mem.cpy_accept <= 1'b0;
      mem.cpy_done   <= 1'b0;

      unique case (state)
        M_IDLE: begin
          if (mem.ld_en) begin
            cur_kind  <= K_LOAD;
            cur_local <= (dev_of(mem.ld_addr) == 16'd0);
            cur_addr_local <= mem.ld_addr[2 +: LOCAL_AW];
            cur_addr_peer  <= mem.ld_addr[2 +: PEER_AW];
            cnt   <= (dev_of(mem.ld_addr) == 16'd0) ?
                     LOCAL_LATENCY_CYCLES : RTT_CYCLES;
            state <= M_WAIT;
          end else if (mem.st_en) begin
            cur_kind  <= K_STORE;
            cur_local <= (dev_of(mem.st_addr) == 16'd0);
            cur_addr_local <= mem.st_addr[2 +: LOCAL_AW];
            cur_addr_peer  <= mem.st_addr[2 +: PEER_AW];
            cur_wdata <= mem.st_data;
            cnt   <= (dev_of(mem.st_addr) == 16'd0) ?
                     LOCAL_LATENCY_CYCLES : RTT_CYCLES;
            state <= M_WAIT;
          end else if (mem.cpy_en) begin
            cur_kind  <= K_CPY;
            cur_local <= (dev_of(mem.cpy_dst_addr) == 16'd0)
                       && (dev_of(mem.cpy_src_addr) == 16'd0);
            cur_addr_local <= mem.cpy_dst_addr[2 +: LOCAL_AW];
            cur_addr_peer  <= mem.cpy_dst_addr[2 +: PEER_AW];
            cur_async <= mem.cpy_async;
            cnt   <= LOCAL_LATENCY_CYCLES + (mem.cpy_len[15:6]);
            mem.cpy_accept <= 1'b1;
            state <= M_WAIT;
          end else if (mem.cas_en) begin
            cur_kind  <= K_ATOM;
            cur_local <= (dev_of(mem.atom_addr) == 16'd0);
            cur_addr_local <= mem.atom_addr[2 +: LOCAL_AW];
            cur_addr_peer  <= mem.atom_addr[2 +: PEER_AW];
            cur_atom_exp  <= mem.atom_expected;
            cur_atom_swap <= mem.atom_swap;
            cur_caa       <= mem.caa_mode;
            cnt   <= (dev_of(mem.atom_addr) == 16'd0) ?
                     LOCAL_LATENCY_CYCLES : RTT_CYCLES;
            state <= M_WAIT;
          end
        end
        M_WAIT: begin
          if (cnt > 16'd0) cnt <= cnt - 16'd1;
          else             state <= M_DRIVE;
        end
        M_DRIVE: begin
          unique case (cur_kind)
            K_LOAD: begin
              mem.sync_valid <= 1'b1;
              mem.sync_data  <= read_word;
              mem.sync_err   <= 1'b0;
            end
            K_STORE: begin
              mem.sync_valid <= 1'b1;
              mem.sync_data  <= 64'd0;
              if (cur_local) local_mem[cur_addr_local] <= cur_wdata;
              else           peer_mem [cur_addr_peer]  <= cur_wdata;
            end
            K_CPY: begin
              if (cur_async) begin
                mem.cpy_done <= 1'b1;
              end else begin
                mem.sync_valid <= 1'b1;
                mem.sync_data  <= 64'd0;
              end
            end
            K_ATOM: begin
              mem.sync_valid <= 1'b1;
              mem.sync_data  <= read_word;
              if (cur_caa) begin
                if (cur_local) local_mem[cur_addr_local] <= read_word + cur_atom_exp;
                else           peer_mem [cur_addr_peer]  <= read_word + cur_atom_exp;
              end else begin
                if (read_word == cur_atom_exp) begin
                  if (cur_local) local_mem[cur_addr_local] <= cur_atom_swap;
                  else           peer_mem [cur_addr_peer]  <= cur_atom_swap;
                end
              end
            end
            default: ;
          endcase
          state <= M_IDLE;
        end
        default: state <= M_IDLE;
      endcase
    end
  end

endmodule
