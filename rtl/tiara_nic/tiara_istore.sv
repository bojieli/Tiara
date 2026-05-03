// Tiara per-MP instruction store.
//
// Single-port BRAM modeled with a 1-cycle read latency.  At registration
// time the host writes verified operator binaries through the `wr_*` port;
// during execution the dispatcher reads them through the `rd_*` port.
// Reads and writes never overlap by construction (the dispatcher will not
// schedule a task on an MP whose istore is being rewritten).

`include "tiara_pkg.svh"

module tiara_istore
  import tiara_pkg::*;
#(
    parameter int unsigned DEPTH = INSTR_STORE_DEPTH
)
(
    input  logic                                clk,

    // Write port (host registration path)
    input  logic                                wr_en,
    input  logic [$clog2(DEPTH)-1:0]            wr_addr,
    input  logic [63:0]                         wr_data,

    // Read port (instruction fetch)
    input  logic                                rd_en,
    input  logic [$clog2(DEPTH)-1:0]            rd_addr,
    output logic [63:0]                         rd_data,
    output logic                                rd_valid
);

  (* ram_style = "block" *) logic [63:0] mem [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    if (rd_en) begin
      rd_data  <= mem[rd_addr];
      rd_valid <= 1'b1;
    end else begin
      rd_valid <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  // Initialize to NOP so an empty simulation slot does not execute
  // random opcodes.  Synthesizers infer BRAM init from the host-side
  // load_en path (write at registration), so this is sim-only.
  initial begin
    for (int i = 0; i < DEPTH; i++) mem[i] = 64'd0;
  end
`endif

endmodule
