// Tiara task dispatcher
//
// Routes incoming Tiara invocation messages to a free MP and waits for
// completion.  In a real NIC this lives between the RDMA engine and
// the MP array; in simulation it is driven directly by the testbench so
// we can characterise per-MP timing without arbitration noise.
//
// Single-MP variant: the dispatcher accepts one task at a time, hands
// it to MP[0], and returns the result.  A multi-MP wrapper is in
// `tiara_nic_top.sv`.

`include "tiara_pkg.svh"

module tiara_dispatcher
  import tiara_pkg::*;
#(
    parameter int unsigned NUM_MPS = 1
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // Host-side invocation port
    input  logic                                            inv_valid,
    input  logic [63:0]                                     inv_args [0:7],
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            inv_start_pc,
    output logic                                            inv_busy,
    output logic                                            done,
    output logic [63:0]                                     done_result [0:3],
    output logic                                            done_err,

    // To/from MP[0]
    output logic                                            mp_start,
    output logic [$clog2(INSTR_STORE_DEPTH)-1:0]            mp_start_pc,
    output logic [63:0]                                     mp_args [0:7],
    input  logic                                            mp_done,
    input  logic [63:0]                                     mp_result [0:3],
    input  logic                                            mp_err
);

  typedef enum logic [1:0] {
    D_IDLE = 2'd0,
    D_RUN  = 2'd1,
    D_OUT  = 2'd2
  } state_e;

  state_e state;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= D_IDLE;
      mp_start    <= 1'b0;
      mp_start_pc <= '0;
      done        <= 1'b0;
      done_err    <= 1'b0;
      inv_busy    <= 1'b0;
      for (int i = 0; i < 8; i++) mp_args[i] <= 64'd0;
      for (int i = 0; i < 4; i++) done_result[i] <= 64'd0;
    end else begin
      mp_start <= 1'b0;
      done     <= 1'b0;
      case (state)
        D_IDLE: begin
          if (inv_valid) begin
            for (int i = 0; i < 8; i++) mp_args[i] <= inv_args[i];
            mp_start    <= 1'b1;
            mp_start_pc <= inv_start_pc;
            inv_busy    <= 1'b1;
            state       <= D_RUN;
          end
        end
        D_RUN: begin
          if (mp_done) begin
            for (int i = 0; i < 4; i++) done_result[i] <= mp_result[i];
            done_err <= mp_err;
            state    <= D_OUT;
          end
        end
        D_OUT: begin
          done     <= 1'b1;
          inv_busy <= 1'b0;
          state    <= D_IDLE;
        end
        default: state <= D_IDLE;
      endcase
    end
  end

endmodule
