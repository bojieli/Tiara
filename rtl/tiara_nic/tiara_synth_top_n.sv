// Tiara N-MP synthesis top.
//
// Same external port shape as `tiara_synth_top` but with a NUM_MPS
// parameter exposed.  Used for the paper's 8-MP build.

`include "tiara_pkg.svh"

module tiara_synth_top_n
  import tiara_pkg::*;
#(
    parameter int unsigned NUM_MPS              = 8,
    parameter int unsigned LOCAL_LATENCY_CYCLES = 150,
    parameter int unsigned RTT_CYCLES           = 500,
    parameter int unsigned LOCAL_MEM_DEPTH      = 1024,
    parameter int unsigned PEER_MEM_DEPTH       = 256,
    parameter int unsigned TAG_W                = 32
)
(
    input  logic                                clk,
    input  logic                                rst_n,

    input  logic                                load_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] load_addr,
    input  logic [63:0]                          load_data,

    input  logic                                inv_valid,
    input  logic [63:0]                         inv_args [0:7],
    input  logic [TAG_W-1:0]                    inv_tag,
    output logic                                inv_busy,
    output logic                                inv_accept,

    output logic                                done,
    output logic [TAG_W-1:0]                    done_tag,
    output logic [63:0]                         done_result [0:3],
    output logic                                done_err,

    output logic [31:0]                         instr_retired_total
);

  tiara_mp_array #(
      .NUM_MPS             (NUM_MPS),
      .LOCAL_LATENCY_CYCLES(LOCAL_LATENCY_CYCLES),
      .RTT_CYCLES          (RTT_CYCLES),
      .LOCAL_MEM_DEPTH     (LOCAL_MEM_DEPTH),
      .PEER_MEM_DEPTH      (PEER_MEM_DEPTH),
      .TAG_W               (TAG_W)
  ) u_array (
      .clk                (clk),
      .rst_n              (rst_n),
      .load_en            (load_en),
      .load_addr          (load_addr),
      .load_data          (load_data),
      .inv_valid          (inv_valid),
      .inv_args           (inv_args),
      .inv_tag            (inv_tag),
      .inv_busy           (inv_busy),
      .inv_accept         (inv_accept),
      .done               (done),
      .done_tag           (done_tag),
      .done_result        (done_result),
      .done_err           (done_err),
      .instr_retired_total(instr_retired_total)
  );

endmodule
