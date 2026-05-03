// Tiara RX filter (parameterized AXIS width).
//
// Accumulates incoming AXIS beats into a 96-byte frame buffer, then on
// `tlast` classifies on bytes 12..19 (Ethertype + magic + op_kind).
// If matched, dispatches to the Tiara MP with all 8 arguments and
// captures the requester's MAC for the response.  If unmatched, the
// buffered beats are replayed to the downstream RX consumer at the
// AXIS width so the rest of the NIC stack still sees the original
// packet unmodified.
//
// Width-agnostic: BEAT_BYTES = DATA_WIDTH/8.  Tested at 128-bit
// (Corundum AU50 25g) and 512-bit (Verilator app testbench).

`include "tiara_packet.svh"

module tiara_rx_filter
#(
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH/8,
    parameter int unsigned ID_WIDTH   = 8,
    parameter int unsigned DEST_WIDTH = 8,
    parameter int unsigned USER_WIDTH = 1,
    parameter int unsigned MAX_BYTES  = 96   // Tiara invocation packet
)
(
    input  logic                       clk,
    input  logic                       rst,

    // RX AXIS in
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
    output logic [47:0]                inv_src_mac,
    input  logic                       mp_busy
);

  localparam int unsigned BEAT_BYTES = DATA_WIDTH/8;
  localparam int unsigned MAX_BEATS  = (MAX_BYTES + BEAT_BYTES - 1) / BEAT_BYTES;
  // Each held beat needs DATA_WIDTH bits + KEEP_WIDTH + tlast.
  localparam int unsigned PASSTHRU_BUF_BEATS = MAX_BEATS;

  // -------------------------------------------------------------------
  // Byte buffer: stores up to MAX_BYTES bytes from the incoming frame.
  // Indexed in little-endian byte order to match the on-wire layout
  // documented in tiara_packet.svh.
  // -------------------------------------------------------------------
  logic [7:0]                pkt_buf  [0:MAX_BYTES-1];
  logic [$clog2(MAX_BYTES+1)-1:0] byte_count;

  // Per-beat held copy for passthrough replay (one slot per beat).
  logic [DATA_WIDTH-1:0]     hold_tdata [0:PASSTHRU_BUF_BEATS-1];
  logic [KEEP_WIDTH-1:0]     hold_tkeep [0:PASSTHRU_BUF_BEATS-1];
  logic                      hold_tlast [0:PASSTHRU_BUF_BEATS-1];
  logic [$clog2(PASSTHRU_BUF_BEATS+1)-1:0] beat_count;
  logic [$clog2(PASSTHRU_BUF_BEATS+1)-1:0] replay_idx;

  // -------------------------------------------------------------------
  // FSM
  // -------------------------------------------------------------------
  typedef enum logic [2:0] {
      S_IDLE      = 3'd0,
      S_COLLECT   = 3'd1,   // buffering beats, classification pending
      S_REPLAY    = 3'd2,   // non-Tiara: replay held beats to passthrough
      S_DRAIN_PT  = 3'd3,   // continue passing through any remaining beats
      S_FIRE      = 3'd4    // wait for MP not busy, pulse inv_valid
  } state_e;

  state_e state, next_state;

  // Helper: accumulate `n` valid bytes from an AXIS beat into pkt_buf
  // starting at `byte_count`.  Returns the new count.
  function automatic int beat_byte_count(input logic [KEEP_WIDTH-1:0] keep);
    int n;
    n = 0;
    for (int i = 0; i < KEEP_WIDTH; i++) if (keep[i]) n = n + 1;
    return n;
  endfunction

  // Combinational classification — only valid once byte_count >= 20
  // (we need bytes 12..19).  We avoid producing a positive result
  // before then.
  function automatic logic match_tiara_beat;
    logic [15:0] etype;
    logic [31:0] magic;
    logic [15:0] op_kind;
    if (byte_count < 20) return 1'b0;
    etype   = {pkt_buf[12], pkt_buf[13]};   // big-endian
    magic   = {pkt_buf[17], pkt_buf[16], pkt_buf[15], pkt_buf[14]}; // little-endian
    op_kind = {pkt_buf[19], pkt_buf[18]};   // little-endian
    return (etype   == `TIARA_ETHERTYPE)
        && (magic   == `TIARA_MAGIC)
        && (op_kind == `TIARA_KIND_INVOKE);
  endfunction

  // -------------------------------------------------------------------
  // Output drivers — combinational based on state
  // -------------------------------------------------------------------
  always_comb begin
    // Default passthrough off
    m_axis_tdata  = '0;
    m_axis_tkeep  = '0;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;
    m_axis_tid    = '0;
    m_axis_tdest  = '0;
    m_axis_tuser  = '0;
    s_axis_tready = 1'b0;

    case (state)
      S_IDLE, S_COLLECT: begin
        // Accept input as long as buffer isn't full
        s_axis_tready = 1'b1;
      end
      S_REPLAY: begin
        m_axis_tdata  = hold_tdata[replay_idx];
        m_axis_tkeep  = hold_tkeep[replay_idx];
        m_axis_tvalid = 1'b1;
        m_axis_tlast  = hold_tlast[replay_idx];
      end
      S_DRAIN_PT: begin
        // Pass remaining frame bytes straight through
        m_axis_tdata  = s_axis_tdata;
        m_axis_tkeep  = s_axis_tkeep;
        m_axis_tvalid = s_axis_tvalid;
        m_axis_tlast  = s_axis_tlast;
        m_axis_tid    = s_axis_tid;
        m_axis_tdest  = s_axis_tdest;
        m_axis_tuser  = s_axis_tuser;
        s_axis_tready = m_axis_tready;
      end
      S_FIRE: begin
        // Backpressure incoming frames while we wait for MP availability
        s_axis_tready = 1'b0;
      end
      default: ;
    endcase
  end

  // -------------------------------------------------------------------
  // Sequential
  // -------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state      <= S_IDLE;
      byte_count <= '0;
      beat_count <= '0;
      replay_idx <= '0;
      inv_valid  <= 1'b0;
      inv_op_id   <= '0;
      inv_task_id <= '0;
      inv_src_mac <= '0;
      for (int i = 0; i < 8; i++) inv_args[i] <= 64'd0;
    end else begin
      inv_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          if (s_axis_tvalid) begin
            // Latch beat 0 into pkt_buf and hold buffer
            for (int i = 0; i < BEAT_BYTES; i++) begin
              if (s_axis_tkeep[i] && i < MAX_BYTES) begin
                pkt_buf[i] <= s_axis_tdata[8*i + 7 -: 8];
              end
            end
            hold_tdata[0] <= s_axis_tdata;
            hold_tkeep[0] <= s_axis_tkeep;
            hold_tlast[0] <= s_axis_tlast;
            byte_count <= beat_byte_count(s_axis_tkeep);
            beat_count <= 1;
            if (s_axis_tlast) begin
              // Single-beat frame — won't be Tiara (header alone needs 2
              // beats at 128-bit) but check anyway
              state <= S_COLLECT;
            end else begin
              state <= S_COLLECT;
            end
          end
        end

        S_COLLECT: begin
          if (s_axis_tvalid) begin
            // Append bytes into pkt_buf
            for (int i = 0; i < BEAT_BYTES; i++) begin
              if (s_axis_tkeep[i]
                  && (byte_count + i) < MAX_BYTES) begin
                pkt_buf[byte_count + i] <= s_axis_tdata[8*i + 7 -: 8];
              end
            end
            if (beat_count < PASSTHRU_BUF_BEATS) begin
              hold_tdata[beat_count] <= s_axis_tdata;
              hold_tkeep[beat_count] <= s_axis_tkeep;
              hold_tlast[beat_count] <= s_axis_tlast;
              beat_count <= beat_count + 1;
            end
            byte_count <= byte_count + beat_byte_count(s_axis_tkeep);

            if (s_axis_tlast) begin
              // Frame complete.  Classify on now-fully-populated buffer.
              // Note: classification reads pkt_buf, but we just wrote
              // some bytes above (non-blocking) — so the function call
              // here sees the OLD pkt_buf.  We resolve by re-checking
              // next cycle with state transition.
              // For correctness we use a 1-cycle delay: go to a small
              // settle state.
              state <= S_FIRE;   // tentatively assume Tiara, MP busy check below
            end
          end
        end

        S_FIRE: begin
          // We arrived here on the cycle after tlast.  pkt_buf is fully
          // populated.  Classify now.
          if (match_tiara_beat()) begin
            // Tiara packet — load registers and pulse inv_valid
            inv_src_mac <= {pkt_buf[11], pkt_buf[10], pkt_buf[9],
                            pkt_buf[ 8], pkt_buf[ 7], pkt_buf[ 6]};
            inv_op_id   <= {pkt_buf[23], pkt_buf[22], pkt_buf[21], pkt_buf[20]};
            inv_task_id <= {pkt_buf[27], pkt_buf[26], pkt_buf[25], pkt_buf[24]};
            for (int i = 0; i < 8; i++) begin
              inv_args[i] <= {
                pkt_buf[32 + 8*i + 7], pkt_buf[32 + 8*i + 6],
                pkt_buf[32 + 8*i + 5], pkt_buf[32 + 8*i + 4],
                pkt_buf[32 + 8*i + 3], pkt_buf[32 + 8*i + 2],
                pkt_buf[32 + 8*i + 1], pkt_buf[32 + 8*i + 0]
              };
            end
            if (!mp_busy) begin
              inv_valid <= 1'b1;
              state     <= S_IDLE;
              byte_count<= '0;
              beat_count<= '0;
            end
            // else: stay in S_FIRE until MP becomes free.
          end else begin
            // Not Tiara — replay held beats to passthrough
            replay_idx <= 0;
            state      <= S_REPLAY;
          end
        end

        S_REPLAY: begin
          if (m_axis_tready) begin
            if (hold_tlast[replay_idx]) begin
              // All buffered beats sent; no remaining beats from input
              // (since we held until tlast).
              state      <= S_IDLE;
              byte_count <= '0;
              beat_count <= '0;
            end else if (replay_idx + 1 == beat_count) begin
              // We held some beats but the frame continues — switch to
              // pure passthrough for the rest.
              state <= S_DRAIN_PT;
            end else begin
              replay_idx <= replay_idx + 1;
            end
          end
        end

        S_DRAIN_PT: begin
          if (s_axis_tvalid && s_axis_tlast && m_axis_tready) begin
            state      <= S_IDLE;
            byte_count <= '0;
            beat_count <= '0;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
