// Tiara per-task register file: 16 x 64-bit, 2R1W with write-first
// behavior (a read in the same cycle as a write returns the new value).
// Register r0 reads as zero; writes to r0 are silently dropped.

`include "tiara_pkg.svh"

module tiara_regfile
  import tiara_pkg::*;
#(
    parameter int unsigned N = NUM_REGS
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // Read port A
    input  logic [3:0]            ra_idx,
    output logic [63:0]           ra_data,
    // Read port B
    input  logic [3:0]            rb_idx,
    output logic [63:0]           rb_data,
    // Read port C — used by two-word ops (CAS new-value, MEMCPY len/stride)
    input  logic [3:0]            rc_idx,
    output logic [63:0]           rc_data,

    // Write port
    input  logic                  we,
    input  logic [3:0]            w_idx,
    input  logic [63:0]           w_data,

    // Bulk reset of the register file (used at task dispatch)
    input  logic                  bulk_clear,

    // Direct taps on r1..r4 for the result-readout path
    output logic [63:0]           r1_out,
    output logic [63:0]           r2_out,
    output logic [63:0]           r3_out,
    output logic [63:0]           r4_out
);

  logic [63:0] regs [0:N-1];

  assign r1_out = regs[1];
  assign r2_out = regs[2];
  assign r3_out = regs[3];
  assign r4_out = regs[4];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < N; i++) regs[i] <= 64'd0;
    end else if (bulk_clear) begin
      for (int i = 0; i < N; i++) regs[i] <= 64'd0;
    end else if (we && w_idx != 4'd0) begin
      regs[w_idx] <= w_data;
    end
  end

  // Read returns the pre-write value (no forwarding).  Forwarding
  // would create a combinational loop on instructions like
  //   SHLI r4, r4, 3
  // where the same register is both the source and destination — the
  // write data depends on `ra_data`, but `ra_data` would depend on
  // `w_data`.  The MP's pipeline guarantees reads always see the
  // committed value: writes happen at the clock edge that takes the
  // FSM out of S_EXECUTE / S_MEM_WAIT, and the next read happens one
  // or more cycles later in S_EXECUTE of the following instruction.
  always_comb begin
    if (ra_idx == 4'd0) ra_data = 64'd0;
    else                ra_data = regs[ra_idx];
    if (rb_idx == 4'd0) rb_data = 64'd0;
    else                rb_data = regs[rb_idx];
    if (rc_idx == 4'd0) rc_data = 64'd0;
    else                rc_data = regs[rc_idx];
  end

endmodule
