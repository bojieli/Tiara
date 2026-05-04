// Tiara N-MP array.
//
// Instantiates `NUM_MPS` `tiara_mp` instances, each with its own
// memory subsystem stub, and routes invocation/completion through a
// shared N-MP dispatcher.  This matches paper §3 (8 MPs at 200 MHz on
// Alveo U50).
//
// Operator load (`load_*`) is broadcast to all MPs — every MP holds an
// identical copy of the registered operators.  In a real deployment
// the host loader broadcasts each operator binary once at registration
// time and the dispatcher routes invocations to whichever MP is free.

`include "tiara_pkg.svh"

module tiara_mp_array
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

    // Operator load — broadcast
    input  logic                                load_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] load_addr,
    input  logic [63:0]                          load_data,

    // Invocation port
    input  logic                                            inv_valid,
    input  logic [63:0]                                     inv_args [0:7],
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            inv_start_pc,
    input  logic [TAG_W-1:0]                                inv_tag,
    output logic                                            inv_busy,
    output logic                                            inv_accept,

    // Completion port
    output logic                                done,
    output logic [TAG_W-1:0]                    done_tag,
    output logic [63:0]                         done_result [0:3],
    output logic                                done_err,

    // Aggregate telemetry
    output logic [31:0]                         instr_retired_total
);

  // Per-MP wires
  logic                                            mp_start    [0:NUM_MPS-1];
  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            mp_start_pc [0:NUM_MPS-1];
  logic [63:0]                                     mp_args     [0:NUM_MPS-1][0:7];
  logic                                            mp_done     [0:NUM_MPS-1];
  logic [63:0]                                     mp_result   [0:NUM_MPS-1][0:3];
  logic                                            mp_err      [0:NUM_MPS-1];
  logic [31:0]                                     mp_retired  [0:NUM_MPS-1];

  // ---- Dispatcher ----
  tiara_dispatcher_n #(
      .NUM_MPS(NUM_MPS),
      .TAG_W  (TAG_W)
  ) u_disp (
      .clk          (clk),
      .rst_n        (rst_n),
      .inv_valid    (inv_valid),
      .inv_args     (inv_args),
      .inv_start_pc (inv_start_pc),
      .inv_tag      (inv_tag),
      .inv_busy     (inv_busy),
      .inv_accept   (inv_accept),
      .done         (done),
      .done_tag     (done_tag),
      .done_result  (done_result),
      .done_err     (done_err),
      .mp_start     (mp_start),
      .mp_start_pc  (mp_start_pc),
      .mp_args      (mp_args),
      .mp_done      (mp_done),
      .mp_result    (mp_result),
      .mp_err       (mp_err)
  );

  // ---- N memory processors, each with private memory subsystem ----
  generate
    for (genvar gi = 0; gi < NUM_MPS; gi = gi + 1) begin : g_mp
      tiara_mem_if mp_mem();

      tiara_mem_simple #(
          .LOCAL_LATENCY_CYCLES(LOCAL_LATENCY_CYCLES),
          .RTT_CYCLES          (RTT_CYCLES),
          .LOCAL_MEM_DEPTH     (LOCAL_MEM_DEPTH),
          .PEER_MEM_DEPTH      (PEER_MEM_DEPTH)
      ) u_mem (
          .clk  (clk),
          .rst_n(rst_n),
          .mem  (mp_mem.mem)
      );

      logic [31:0] mp_cycles_unused;
      tiara_mp #(.MP_ID(gi)) u_mp (
          .clk             (clk),
          .rst_n           (rst_n),
          .task_start      (mp_start[gi]),
          .task_start_pc   (mp_start_pc[gi]),
          .task_args       (mp_args [gi]),
          .task_done       (mp_done [gi]),
          .task_result     (mp_result[gi]),
          .task_err        (mp_err  [gi]),
          .wr_en           (load_en),
          .wr_addr         (load_addr),
          .wr_data         (load_data),
          .mem             (mp_mem.mp),
          .cycles_executed (mp_cycles_unused),
          .instr_retired   (mp_retired[gi])
      );
    end
  endgenerate

  // Aggregate retired-instruction counter
  always_comb begin
    instr_retired_total = 32'd0;
    for (int i = 0; i < NUM_MPS; i++)
      instr_retired_total = instr_retired_total + mp_retired[i];
  end

endmodule
