// Tiara N-MP dispatcher.
//
// Routes incoming invocations to the first free MP.  Tracks per-MP
// busy state and tags returning results so the caller knows which task
// completed (used at scale when multiple invocations are in flight).
//
// Per-task tag carried through MP execution:
//   * On invocation, the dispatcher allocates a free MP slot, latches
//     the caller's tag (operator_id + task_id) into a small tag array
//     indexed by MP slot.
//   * When that MP signals task_done, the dispatcher pops the tag and
//     emits a single done-event with the original tag + result.
//
// First-free arbitration prefers low-numbered MPs so simulation
// behavior is deterministic.

`include "tiara_pkg.svh"

module tiara_dispatcher_n
  import tiara_pkg::*;
#(
    parameter int unsigned NUM_MPS = 8,
    parameter int unsigned TAG_W   = 32
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // Host invocation port
    input  logic                  inv_valid,
    input  logic [63:0]           inv_args [0:7],
    input  logic [TAG_W-1:0]      inv_tag,        // arbitrary per-call tag
    output logic                  inv_busy,        // all MPs busy
    output logic                  inv_accept,      // pulse when accepted

    // Result port (one-cycle pulse per completion)
    output logic                  done,
    output logic [TAG_W-1:0]      done_tag,
    output logic [63:0]           done_result [0:3],
    output logic                  done_err,

    // Fan-out to N MPs
    output logic                  mp_start [0:NUM_MPS-1],
    output logic [63:0]           mp_args  [0:NUM_MPS-1][0:7],
    input  logic                  mp_done  [0:NUM_MPS-1],
    input  logic [63:0]           mp_result[0:NUM_MPS-1][0:3],
    input  logic                  mp_err   [0:NUM_MPS-1]
);

  // Per-MP busy state (in-flight task)
  logic [NUM_MPS-1:0]   busy;
  // Per-MP tag (latched when we dispatched a task to that MP)
  logic [TAG_W-1:0]     tag_q [0:NUM_MPS-1];

  // First-free MP index (combinational priority encoder)
  logic                 any_free;
  logic [$clog2(NUM_MPS)-1:0] free_idx;
  always_comb begin
    any_free = 1'b0;
    free_idx = '0;
    for (int i = 0; i < NUM_MPS; i++) begin
      if (!busy[i] && !any_free) begin
        any_free = 1'b1;
        free_idx = i[$clog2(NUM_MPS)-1:0];
      end
    end
  end

  assign inv_busy   = ~any_free;
  assign inv_accept = inv_valid & any_free;

  // Pick a single MP to report a done event each cycle (priority by
  // index).  In normal operation only one MP completes per cycle
  // because they are serialized through Tiara's MP latency, so this
  // never starves.
  logic [$clog2(NUM_MPS+1)-1:0] done_idx;
  logic                         done_any;
  always_comb begin
    done_any = 1'b0;
    done_idx = '0;
    for (int i = 0; i < NUM_MPS; i++) begin
      if (mp_done[i] && !done_any) begin
        done_any = 1'b1;
        done_idx = i[$clog2(NUM_MPS+1)-1:0];
      end
    end
  end

  // ----- Sequential update --------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= '0;
      done <= 1'b0;
      done_err <= 1'b0;
      done_tag <= '0;
      for (int i = 0; i < NUM_MPS; i++) begin
        tag_q[i]    <= '0;
        mp_start[i] <= 1'b0;
        for (int j = 0; j < 4; j++) done_result[j] <= 64'd0;
        for (int j = 0; j < 8; j++) mp_args[i][j]  <= 64'd0;
      end
    end else begin
      // Default: deassert one-cycle pulses
      done <= 1'b0;
      for (int i = 0; i < NUM_MPS; i++) mp_start[i] <= 1'b0;

      // Dispatch
      if (inv_valid && any_free) begin
        for (int j = 0; j < 8; j++) mp_args[free_idx][j] <= inv_args[j];
        mp_start[free_idx] <= 1'b1;
        busy[free_idx]     <= 1'b1;
        tag_q[free_idx]    <= inv_tag;
      end

      // Completion
      if (done_any) begin
        done     <= 1'b1;
        done_tag <= tag_q[done_idx];
        for (int j = 0; j < 4; j++) done_result[j] <= mp_result[done_idx][j];
        done_err <= mp_err[done_idx];
        busy[done_idx] <= 1'b0;
      end
    end
  end

endmodule
