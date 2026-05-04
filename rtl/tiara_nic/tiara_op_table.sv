// Tiara operator table.
//
// A small (NUM_OPS-entry) lookup mapping `operator_id` -> `start_pc`.
// The host fills this at registration time via `wr_*`; the dispatcher
// reads `start_pc` for an incoming invocation via `lookup_*`.
//
// `op_id` is 8 bits in the wire protocol (bytes 20..23 of the
// invocation packet are the full 32-bit op_id, but we only key on the
// low 8 bits here — a single NIC supports up to 256 registered
// operators, more than enough).

`include "tiara_pkg.svh"

module tiara_op_table
  import tiara_pkg::*;
#(
    parameter int unsigned NUM_OPS = 32,
    parameter int unsigned PC_W    = $clog2(INSTR_STORE_DEPTH)
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // Host registration port
    input  logic                  wr_en,
    input  logic [7:0]            wr_op_id,         // index (low 8 bits)
    input  logic [PC_W-1:0]       wr_start_pc,
    input  logic                  wr_valid_bit,     // 1 = present, 0 = unmap

    // Dispatcher lookup port (combinational)
    input  logic [7:0]            lookup_op_id,
    output logic                  lookup_valid,
    output logic [PC_W-1:0]       lookup_start_pc
);

  localparam int unsigned IDX_W = $clog2(NUM_OPS);

  logic [PC_W-1:0] tbl_pc    [0:NUM_OPS-1];
  logic            tbl_valid [0:NUM_OPS-1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_OPS; i++) begin
        tbl_pc[i]    <= '0;
        tbl_valid[i] <= 1'b0;
      end
    end else if (wr_en && wr_op_id < NUM_OPS) begin
      tbl_pc   [wr_op_id[IDX_W-1:0]] <= wr_start_pc;
      tbl_valid[wr_op_id[IDX_W-1:0]] <= wr_valid_bit;
    end
  end

  // Combinational lookup
  always_comb begin
    if (lookup_op_id < NUM_OPS) begin
      lookup_valid    = tbl_valid[lookup_op_id[IDX_W-1:0]];
      lookup_start_pc = tbl_pc   [lookup_op_id[IDX_W-1:0]];
    end else begin
      lookup_valid    = 1'b0;
      lookup_start_pc = '0;
    end
  end

endmodule
