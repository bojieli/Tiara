// Tiara loop stack.
//
// Tiny LIFO that records active LOOP frames.  Each frame stores:
//   begin_pc — the PC of the first instruction inside the loop body,
//   end_pc   — the PC just past the loop body,
//   remaining — number of additional iterations left after the current.
//
// The MP's main FSM pushes on LOOP, pops when the iterator reaches 0,
// and snaps PC back to `begin_pc` at the end of every body iteration
// while `remaining > 0`.

`include "tiara_pkg.svh"

module tiara_loop_stack
  import tiara_pkg::*;
#(
    parameter int unsigned DEPTH = MAX_LOOP_NEST,
    parameter int unsigned PC_W  = 12
)
(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  flush,

    input  logic                  push,
    input  logic [PC_W-1:0]       in_begin_pc,
    input  logic [PC_W-1:0]       in_end_pc,
    input  logic [31:0]           in_remaining,

    input  logic                  pop,
    input  logic                  decrement,    // remaining-- on top frame

    output logic                  empty,
    output logic                  full,
    output logic [PC_W-1:0]       top_begin_pc,
    output logic [PC_W-1:0]       top_end_pc,
    output logic [31:0]           top_remaining
);

  logic [PC_W-1:0] sBegin    [0:DEPTH-1];
  logic [PC_W-1:0] sEnd      [0:DEPTH-1];
  logic [31:0]     sRemain   [0:DEPTH-1];
  logic [$clog2(DEPTH+1)-1:0] sp;

  assign empty         = (sp == '0);
  assign full          = (sp == DEPTH[$clog2(DEPTH+1)-1:0]);
  assign top_begin_pc  = empty ? '0 : sBegin   [sp - 1];
  assign top_end_pc    = empty ? '0 : sEnd     [sp - 1];
  assign top_remaining = empty ? '0 : sRemain  [sp - 1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sp <= '0;
    end else if (flush) begin
      sp <= '0;
    end else begin
      if (push && !full) begin
        sBegin [sp] <= in_begin_pc;
        sEnd   [sp] <= in_end_pc;
        sRemain[sp] <= in_remaining;
        sp <= sp + 1'b1;
      end else if (pop && !empty) begin
        sp <= sp - 1'b1;
      end else if (decrement && !empty) begin
        sRemain[sp - 1] <= sRemain[sp - 1] - 1'b1;
      end
    end
  end

endmodule
