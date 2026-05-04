// Tiara synthesis-only top.
//
// Wraps the data-path core (MP, dispatcher, register file, instruction
// store, ALU, loop stack) with a minimal single-slot memory subsystem
// stub.  Intended for `make synth` to produce representative resource
// numbers for the *Tiara-specific* logic on Alveo U50 — not the
// elaborate behavioural BFM used by the simulator.
//
// In a real bitstream, replace the `tiara_mem_simple` instance with the
// AXI master path that connects to the Xilinx XDMA + Corundum RDMA
// stack (see docs/FPGA_BUILD.md).

`include "tiara_pkg.svh"

module tiara_synth_top
  import tiara_pkg::*;
#(
    parameter int unsigned LOCAL_LATENCY_CYCLES = 150,
    parameter int unsigned RTT_CYCLES           = 500,
    parameter int unsigned LOCAL_MEM_DEPTH      = 1024,
    parameter int unsigned PEER_MEM_DEPTH       = 256
)
(
    input  logic                                clk,
    input  logic                                rst_n,

    // Operator load port
    input  logic                                load_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] load_addr,
    input  logic [63:0]                          load_data,

    // Invocation port
    input  logic                                            inv_valid,
    input  logic [63:0]                                     inv_args [0:7],
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            inv_start_pc,
    output logic                                            inv_busy,
    output logic                                            done,
    output logic [63:0]                                     done_result [0:3],
    output logic                                            done_err,

    // Telemetry
    output logic [31:0]                                     instr_retired
);

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

  logic                                            mp_start;
  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            mp_start_pc;
  logic [63:0]                                     mp_args   [0:7];
  logic                                            mp_done_w;
  logic [63:0]                                     mp_result [0:3];
  logic                                            mp_err_w;
  logic [31:0]                                     mp_cycles;

  tiara_dispatcher u_disp (
      .clk         (clk),
      .rst_n       (rst_n),
      .inv_valid   (inv_valid),
      .inv_args    (inv_args),
      .inv_start_pc(inv_start_pc),
      .inv_busy    (inv_busy),
      .done        (done),
      .done_result (done_result),
      .done_err    (done_err),
      .mp_start    (mp_start),
      .mp_start_pc (mp_start_pc),
      .mp_args     (mp_args),
      .mp_done     (mp_done_w),
      .mp_result   (mp_result),
      .mp_err      (mp_err_w)
  );

  tiara_mp #(.MP_ID(0)) u_mp (
      .clk             (clk),
      .rst_n           (rst_n),
      .task_start      (mp_start),
      .task_start_pc   (mp_start_pc),
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
