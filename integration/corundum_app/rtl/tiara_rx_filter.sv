// Tiara RX filter.
//
// Snoops Corundum's RX AXIS interface (s_axis_if_rx_*).  Packets whose
// Ethertype + magic match the Tiara protocol are diverted into the
// Tiara dispatcher; everything else is forwarded unmodified to
// m_axis_if_rx_* so the rest of the NIC stack still sees normal
// network traffic.
//
// AXIS data layout (Corundum convention, little-endian byte numbering):
//   tdata[8*i+7 -: 8]  is byte i of the frame
//   tkeep[i]           = 1 when byte i is valid
//
// Invocation packets are exactly 96 bytes — 14 Ethernet header + 18 Tiara
// header + 64 args — spanning two 64-byte AXIS beats:
//   beat 0: bytes  0.. 63 (full)
//   beat 1: bytes 64.. 95 (32 bytes used, lower 32 of tkeep set, tlast=1)
//
// We classify on beat 0 by checking ethertype + magic byte positions.
// Unmatched packets pass through; matched ones are buffered, the args
// are extracted, and a single mp_inv_valid pulse is fired with all 8
// arg registers.  We capture the source MAC for the eventual response.

`include "tiara_packet.svh"

module tiara_rx_filter
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

    // RX AXIS in (from Corundum)
    input  logic [DATA_WIDTH-1:0]      s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]      s_axis_tkeep,
    input  logic                       s_axis_tvalid,
    output logic                       s_axis_tready,
    input  logic                       s_axis_tlast,
    input  logic [ID_WIDTH-1:0]        s_axis_tid,
    input  logic [DEST_WIDTH-1:0]      s_axis_tdest,
    input  logic [USER_WIDTH-1:0]      s_axis_tuser,

    // RX AXIS out (passthrough for non-Tiara packets)
    output logic [DATA_WIDTH-1:0]      m_axis_tdata,
    output logic [KEEP_WIDTH-1:0]      m_axis_tkeep,
    output logic                       m_axis_tvalid,
    input  logic                       m_axis_tready,
    output logic                       m_axis_tlast,
    output logic [ID_WIDTH-1:0]        m_axis_tid,
    output logic [DEST_WIDTH-1:0]      m_axis_tdest,
    output logic [USER_WIDTH-1:0]      m_axis_tuser,

    // To Tiara dispatcher
    output logic                       inv_valid,
    output logic [63:0]                inv_args [0:7],
    output logic [31:0]                inv_op_id,
    output logic [31:0]                inv_task_id,
    output logic [47:0]                inv_src_mac,    // for response
    input  logic                       mp_busy
);

  // -------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------
  typedef enum logic [2:0] {
      S_IDLE     = 3'd0,
      S_PASS     = 3'd1,   // forwarding non-Tiara frame
      S_TIARA_B1 = 3'd2,   // need beat 1 to capture args[4..7]
      S_DROP     = 3'd3,   // tail of a Tiara frame after diversion
      S_FIRE     = 3'd4    // pulse inv_valid for one cycle
  } state_e;

  state_e state, next_state;

  // Latched fields from beat 0
  logic [47:0] src_mac_q;
  logic [31:0] op_id_q;
  logic [31:0] task_id_q;
  logic [63:0] args_q [0:7];

  // Beat-0 byte extracts (little-endian byte numbering)
  wire [47:0] beat0_dst_mac     = s_axis_tdata[ 47:  0];
  wire [47:0] beat0_src_mac     = s_axis_tdata[ 95: 48];
  wire [15:0] beat0_ethertype   = {s_axis_tdata[103: 96], s_axis_tdata[111:104]};
  wire [31:0] beat0_magic       = s_axis_tdata[143:112];
  // op_kind is little-endian (byte 18 = LSB, byte 19 = MSB) per
  // tiara_packet.svh
  wire [15:0] beat0_op_kind     = {s_axis_tdata[159:152], s_axis_tdata[151:144]};
  wire [31:0] beat0_op_id       = s_axis_tdata[191:160];
  wire [31:0] beat0_task_id     = s_axis_tdata[223:192];
  wire [31:0] beat0_flags       = s_axis_tdata[255:224];
  wire [63:0] beat0_arg0        = s_axis_tdata[319:256];
  wire [63:0] beat0_arg1        = s_axis_tdata[383:320];
  wire [63:0] beat0_arg2        = s_axis_tdata[447:384];
  wire [63:0] beat0_arg3        = s_axis_tdata[511:448];

  // Classification of beat 0
  wire is_tiara_beat0 =
        (beat0_ethertype == `TIARA_ETHERTYPE)
     && (beat0_magic     == `TIARA_MAGIC)
     && (beat0_op_kind   == `TIARA_KIND_INVOKE);

  // Beat 1 extracts (args 4..7 in low 32 bytes)
  wire [63:0] beat1_arg4 = s_axis_tdata[ 63:  0];
  wire [63:0] beat1_arg5 = s_axis_tdata[127: 64];
  wire [63:0] beat1_arg6 = s_axis_tdata[191:128];
  wire [63:0] beat1_arg7 = s_axis_tdata[255:192];

  // -------------------------------------------------------------------
  // FSM next state
  // -------------------------------------------------------------------
  always_comb begin
    next_state = state;
    case (state)
      S_IDLE: begin
        if (s_axis_tvalid) begin
          if (is_tiara_beat0) begin
            if (s_axis_tlast) next_state = S_FIRE;       // single-beat (illegal but tolerate)
            else              next_state = S_TIARA_B1;
          end else begin
            if (s_axis_tlast) next_state = S_IDLE;
            else              next_state = S_PASS;
          end
        end
      end
      S_PASS: begin
        if (s_axis_tvalid && s_axis_tlast && m_axis_tready) next_state = S_IDLE;
      end
      S_TIARA_B1: begin
        if (s_axis_tvalid) begin
          if (s_axis_tlast) next_state = S_FIRE;
          else              next_state = S_DROP;
        end
      end
      S_DROP: begin
        if (s_axis_tvalid && s_axis_tlast) next_state = S_FIRE;
      end
      S_FIRE: begin
        // Wait for the dispatcher to be free, then pulse inv_valid for
        // one cycle and return to IDLE.
        if (!mp_busy) next_state = S_IDLE;
      end
      default: next_state = S_IDLE;
    endcase
  end

  // -------------------------------------------------------------------
  // FSM register + data latches
  // -------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= S_IDLE;
      inv_valid <= 1'b0;
      src_mac_q <= 48'd0;
      op_id_q   <= 32'd0;
      task_id_q <= 32'd0;
      for (int i = 0; i < 8; i++) args_q[i] <= 64'd0;
    end else begin
      state     <= next_state;
      inv_valid <= 1'b0;

      // Latch fields when we're consuming beat 0 of a Tiara frame
      if (state == S_IDLE && s_axis_tvalid && is_tiara_beat0) begin
        src_mac_q   <= beat0_src_mac;
        op_id_q     <= beat0_op_id;
        task_id_q   <= beat0_task_id;
        args_q[0]   <= beat0_arg0;
        args_q[1]   <= beat0_arg1;
        args_q[2]   <= beat0_arg2;
        args_q[3]   <= beat0_arg3;
      end
      if (state == S_TIARA_B1 && s_axis_tvalid) begin
        args_q[4] <= beat1_arg4;
        args_q[5] <= beat1_arg5;
        args_q[6] <= beat1_arg6;
        args_q[7] <= beat1_arg7;
      end

      // One-cycle inv_valid pulse on the FIRE -> IDLE transition
      if (state == S_FIRE && !mp_busy) inv_valid <= 1'b1;
    end
  end

  // -------------------------------------------------------------------
  // RX passthrough (only when not inside a Tiara frame)
  // -------------------------------------------------------------------
  // The downstream consumer sees Tiara frames as "absent" — we strip
  // them entirely from the host's RX path.  Non-Tiara frames are
  // forwarded transparently.
  wire passthrough = (state == S_IDLE && s_axis_tvalid && !is_tiara_beat0)
                   || (state == S_PASS);
  wire absorb     = (state == S_IDLE && s_axis_tvalid && is_tiara_beat0)
                   || (state == S_TIARA_B1)
                   || (state == S_DROP);

  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tkeep  = s_axis_tkeep;
  assign m_axis_tvalid = s_axis_tvalid && passthrough;
  assign m_axis_tlast  = s_axis_tlast;
  assign m_axis_tid    = s_axis_tid;
  assign m_axis_tdest  = s_axis_tdest;
  assign m_axis_tuser  = s_axis_tuser;
  assign s_axis_tready = (passthrough && m_axis_tready) || absorb || (state == S_FIRE);

  // Outputs to the dispatcher
  assign inv_args   = args_q;
  assign inv_op_id  = op_id_q;
  assign inv_task_id= task_id_q;
  assign inv_src_mac= src_mac_q;

endmodule
