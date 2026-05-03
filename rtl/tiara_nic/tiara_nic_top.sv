// Tiara NIC top — single-MP simulator harness.
//
// Instantiates one memory processor + dispatcher + memory subsystem in
// a self-contained block whose only ports are:
//   - clock / reset
//   - operator-load port (for registering instructions)
//   - invocation port (args in / result out)
//
// All host-DRAM and peer-memory traffic is internal; the testbench
// pokes / peeks via the DPI hooks exported by the BFMs.

`include "tiara_pkg.svh"

module tiara_nic_top
  import tiara_pkg::*;
#(
    parameter int unsigned LOCAL_LATENCY_CYCLES = 150,
    parameter int unsigned RTT_CYCLES           = 500,
    parameter int unsigned NUM_PEERS            = 4
)
(
    input  logic                                clk,
    input  logic                                rst_n,

    // Operator load port
    input  logic                                load_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] load_addr,
    input  logic [63:0]                          load_data,

    // Invocation port
    input  logic                                inv_valid,
    input  logic [63:0]                         inv_args [0:7],
    output logic                                inv_busy,
    output logic                                done,
    output logic [63:0]                         done_result [0:3],
    output logic                                done_err,

    // Telemetry
    output logic [31:0]                         instr_retired
);

  // -------------------------------------------------------------------
  // Memory interface
  // -------------------------------------------------------------------
  tiara_mem_if mp_mem();

  tiara_memory_subsystem #(
      .LOCAL_LATENCY_CYCLES(LOCAL_LATENCY_CYCLES),
      .RTT_CYCLES          (RTT_CYCLES),
      .NUM_PEERS           (NUM_PEERS)
  ) u_mem (
      .clk  (clk),
      .rst_n(rst_n),
      .mem  (mp_mem.mem)
  );

  // -------------------------------------------------------------------
  // Dispatcher <-> MP wires
  // -------------------------------------------------------------------
  logic        mp_start;
  logic [63:0] mp_args   [0:7];
  logic        mp_done_w;
  logic [63:0] mp_result [0:3];
  logic        mp_err_w;
  logic [31:0] mp_cycles;

  tiara_dispatcher u_disp (
      .clk         (clk),
      .rst_n       (rst_n),
      .inv_valid   (inv_valid),
      .inv_args    (inv_args),
      .inv_busy    (inv_busy),
      .done        (done),
      .done_result (done_result),
      .done_err    (done_err),
      .mp_start    (mp_start),
      .mp_args     (mp_args),
      .mp_done     (mp_done_w),
      .mp_result   (mp_result),
      .mp_err      (mp_err_w)
  );

  tiara_mp #(.MP_ID(0)) u_mp (
      .clk             (clk),
      .rst_n           (rst_n),
      .task_start      (mp_start),
      .task_args       (mp_args),
      .task_done       (mp_done_w),
      .task_result     (mp_result),
      .task_err        (mp_err_w),
      .wr_en           (load_en),
      .wr_addr         (load_addr),
      .wr_data         (load_data),
      .mem             (mp_mem.mp),
      .cycles_executed (mp_cycles),
      .instr_retired   (instr_retired)
  );

endmodule
