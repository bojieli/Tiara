// Tiara TX response builder.
//
// On `mp_done`, emits a single-beat 64-byte AXIS packet on the
// outgoing TX stream addressed back to the original invoker.  Layout
// matches the response section of `tiara_packet.svh`.

`include "tiara_packet.svh"

module tiara_tx_resp
#(
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH/8,
    parameter int unsigned ID_WIDTH   = 8,
    parameter int unsigned DEST_WIDTH = 8,
    parameter int unsigned USER_WIDTH = 1
)
(
    input  logic                       clk,
    input  logic                       rst,

    // From dispatcher
    input  logic                       mp_done,
    input  logic                       mp_done_err,
    input  logic [63:0]                mp_done_result [0:3],

    // Captured from the matching invocation
    input  logic [47:0]                src_mac,    // -> response dst
    input  logic [47:0]                local_mac,  // our MAC (response src)
    input  logic [31:0]                op_id,
    input  logic [31:0]                task_id,

    // TX AXIS out
    output logic [DATA_WIDTH-1:0]      m_axis_tdata,
    output logic [KEEP_WIDTH-1:0]      m_axis_tkeep,
    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,
    output logic                       m_axis_tlast,
    output logic [ID_WIDTH-1:0]        m_axis_tid,
    output logic [DEST_WIDTH-1:0]      m_axis_tdest,
    output logic [USER_WIDTH-1:0]      m_axis_tuser
);

  typedef enum logic [1:0] {
      T_IDLE = 2'd0,
      T_DRIVE = 2'd1
  } tstate_e;
  tstate_e state, next_state;

  // Latched response payload
  logic [47:0] dst_mac_q, src_mac_q;
  logic [31:0] op_id_q, task_id_q;
  logic [15:0] status_q;
  logic [63:0] result_q [0:3];

  always_comb begin
    next_state = state;
    case (state)
      T_IDLE:  if (mp_done) next_state = T_DRIVE;
      T_DRIVE: if (m_axis_tready) next_state = T_IDLE;
      default: next_state = T_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state    <= T_IDLE;
      dst_mac_q<= '0; src_mac_q <= '0;
      op_id_q  <= '0; task_id_q <= '0; status_q <= '0;
      for (int i = 0; i < 4; i++) result_q[i] <= '0;
    end else begin
      state <= next_state;
      if (state == T_IDLE && mp_done) begin
        dst_mac_q <= src_mac;
        src_mac_q <= local_mac;
        op_id_q   <= op_id;
        task_id_q <= task_id;
        status_q  <= {14'd0, mp_done_err, 1'b1};   // bit 0 = done, bit 1 = err
        for (int i = 0; i < 4; i++) result_q[i] <= mp_done_result[i];
      end
    end
  end

  // -------------------------------------------------------------------
  // Drive the AXIS beat (64 bytes, single beat).  Layout per
  // tiara_packet.svh response section.  Localparams hold the literal
  // values so we can bit-select across them (Verilog disallows part-
  // selecting a `define-d numeric literal directly).
  // -------------------------------------------------------------------
  localparam logic [15:0] ETYPE   = `TIARA_ETHERTYPE;
  localparam logic [31:0] MAGIC   = `TIARA_MAGIC;
  localparam logic [15:0] RESPK   = `TIARA_KIND_RESPONSE;

  logic [DATA_WIDTH-1:0] beat;
  always_comb begin
    beat = '0;
    beat[ 47:  0] = dst_mac_q;
    beat[ 95: 48] = src_mac_q;
    beat[103: 96] = ETYPE[15:8];   // byte 12 = 0x88
    beat[111:104] = ETYPE[ 7:0];   // byte 13 = 0xB5
    beat[143:112] = MAGIC;         // little-endian payload
    // op_kind little-endian
    beat[151:144] = RESPK[ 7:0];
    beat[159:152] = RESPK[15:8];
    beat[191:160] = op_id_q;
    beat[223:192] = task_id_q;
    beat[239:224] = status_q;
    beat[255:240] = 16'd0;          // reserved
    beat[319:256] = result_q[0];
    beat[383:320] = result_q[1];
    beat[447:384] = result_q[2];
    beat[511:448] = result_q[3];
  end

  assign m_axis_tdata  = beat;
  assign m_axis_tkeep  = {KEEP_WIDTH{1'b1}};   // all 64 bytes valid
  assign m_axis_tvalid = (state == T_DRIVE);
  assign m_axis_tlast  = 1'b1;
  assign m_axis_tid    = '0;
  assign m_axis_tdest  = '0;
  assign m_axis_tuser  = '0;

endmodule
