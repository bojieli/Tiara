// Tiara TX arbiter.
//
// 2-input AXIS arbiter with priority for the Tiara response stream.
// Per-frame arbitration: once an input wins, it holds the channel until
// it asserts tlast.

module tiara_tx_arb
#(
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH/8,
    parameter int unsigned ID_WIDTH   = 8,
    parameter int unsigned DEST_WIDTH = 8,
    parameter int unsigned USER_WIDTH = 1
)
(
    input  logic clk,
    input  logic rst,

    // Input 0 — Tiara response (priority high)
    input  logic [DATA_WIDTH-1:0]      s0_tdata,
    input  logic [KEEP_WIDTH-1:0]      s0_tkeep,
    input  logic                       s0_tvalid,
    output logic                       s0_tready,
    input  logic                       s0_tlast,
    input  logic [ID_WIDTH-1:0]        s0_tid,
    input  logic [DEST_WIDTH-1:0]      s0_tdest,
    input  logic [USER_WIDTH-1:0]      s0_tuser,

    // Input 1 — host TX (priority low)
    input  logic [DATA_WIDTH-1:0]      s1_tdata,
    input  logic [KEEP_WIDTH-1:0]      s1_tkeep,
    input  logic                       s1_tvalid,
    output logic                       s1_tready,
    input  logic                       s1_tlast,
    input  logic [ID_WIDTH-1:0]        s1_tid,
    input  logic [DEST_WIDTH-1:0]      s1_tdest,
    input  logic [USER_WIDTH-1:0]      s1_tuser,

    // Output
    output logic [DATA_WIDTH-1:0]      m_tdata,
    output logic [KEEP_WIDTH-1:0]      m_tkeep,
    output logic                       m_tvalid,
    input  logic                       m_tready,
    output logic                       m_tlast,
    output logic [ID_WIDTH-1:0]        m_tid,
    output logic [DEST_WIDTH-1:0]      m_tdest,
    output logic [USER_WIDTH-1:0]      m_tuser
);

  typedef enum logic [1:0] {
      A_IDLE = 2'd0,
      A_S0   = 2'd1,
      A_S1   = 2'd2
  } astate_e;

  astate_e state, next_state;

  always_comb begin
    next_state = state;
    case (state)
      A_IDLE:
        if      (s0_tvalid) next_state = A_S0;
        else if (s1_tvalid) next_state = A_S1;
      A_S0:
        if (s0_tvalid && s0_tlast && m_tready) next_state = A_IDLE;
      A_S1:
        if (s1_tvalid && s1_tlast && m_tready) next_state = A_IDLE;
      default: next_state = A_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) state <= A_IDLE;
    else     state <= next_state;
  end

  // Mux based on which input owns the channel (or about to)
  wire pick_s0 = (state == A_S0) || (state == A_IDLE && s0_tvalid);
  wire pick_s1 = (state == A_S1) || (state == A_IDLE && !s0_tvalid && s1_tvalid);

  assign m_tdata  = pick_s0 ? s0_tdata  : s1_tdata;
  assign m_tkeep  = pick_s0 ? s0_tkeep  : s1_tkeep;
  assign m_tvalid = pick_s0 ? s0_tvalid : (pick_s1 ? s1_tvalid : 1'b0);
  assign m_tlast  = pick_s0 ? s0_tlast  : s1_tlast;
  assign m_tid    = pick_s0 ? s0_tid    : s1_tid;
  assign m_tdest  = pick_s0 ? s0_tdest  : s1_tdest;
  assign m_tuser  = pick_s0 ? s0_tuser  : s1_tuser;

  assign s0_tready = pick_s0 && m_tready;
  assign s1_tready = pick_s1 && m_tready;

endmodule
