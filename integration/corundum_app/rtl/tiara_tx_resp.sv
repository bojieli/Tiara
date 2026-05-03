// Tiara TX response builder (parameterized AXIS width).
//
// On `mp_done`, assembles a 64-byte response packet into a byte buffer
// then drives it onto AXIS as ⌈64 / BEAT_BYTES⌉ beats.
// Width-agnostic: works at 128-bit (Corundum AU50 25g) and 512-bit
// (Verilator app testbench) without rebuild.

`include "tiara_packet.svh"

module tiara_tx_resp
#(
    parameter int unsigned DATA_WIDTH  = 512,
    parameter int unsigned KEEP_WIDTH  = DATA_WIDTH/8,
    parameter int unsigned ID_WIDTH    = 8,
    parameter int unsigned DEST_WIDTH  = 8,
    parameter int unsigned USER_WIDTH  = 1,
    parameter int unsigned RESP_BYTES  = 64
)
(
    input  logic                       clk,
    input  logic                       rst,

    // From dispatcher
    input  logic                       mp_done,
    input  logic                       mp_done_err,
    input  logic [63:0]                mp_done_result [0:3],

    // Captured from the matching invocation
    input  logic [47:0]                src_mac,
    input  logic [47:0]                local_mac,
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

  localparam int unsigned BEAT_BYTES = DATA_WIDTH / 8;
  localparam int unsigned NBEATS     = (RESP_BYTES + BEAT_BYTES - 1) / BEAT_BYTES;

  // Localparams hold the literal protocol values so we can bit-select
  // them (Verilog disallows part-selecting a `define-d numeric).
  localparam logic [15:0] ETYPE = `TIARA_ETHERTYPE;
  localparam logic [31:0] MAGIC = `TIARA_MAGIC;
  localparam logic [15:0] RESPK = `TIARA_KIND_RESPONSE;

  // Byte-level assembly buffer (LE byte order, matches the spec)
  logic [7:0] pkt [0:RESP_BYTES-1];

  typedef enum logic [1:0] {
      T_IDLE  = 2'd0,
      T_DRIVE = 2'd1
  } tstate_e;
  tstate_e state, next_state;

  logic [$clog2(NBEATS+1)-1:0] beat_idx;

  // ----- Build the packet bytes on mp_done ----------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      state    <= T_IDLE;
      beat_idx <= '0;
      for (int i = 0; i < RESP_BYTES; i++) pkt[i] <= 8'd0;
    end else begin
      case (state)
        T_IDLE: begin
          if (mp_done) begin
            // Ethernet header (big-endian)
            pkt[ 0] <= src_mac[ 7: 0];   // dst = original src MAC
            pkt[ 1] <= src_mac[15: 8];
            pkt[ 2] <= src_mac[23:16];
            pkt[ 3] <= src_mac[31:24];
            pkt[ 4] <= src_mac[39:32];
            pkt[ 5] <= src_mac[47:40];
            pkt[ 6] <= local_mac[ 7: 0];
            pkt[ 7] <= local_mac[15: 8];
            pkt[ 8] <= local_mac[23:16];
            pkt[ 9] <= local_mac[31:24];
            pkt[10] <= local_mac[39:32];
            pkt[11] <= local_mac[47:40];
            // Ethertype big-endian: byte 12 = MSB
            pkt[12] <= ETYPE[15:8];
            pkt[13] <= ETYPE[ 7:0];
            // Tiara header (little-endian payload)
            pkt[14] <= MAGIC[ 7: 0];
            pkt[15] <= MAGIC[15: 8];
            pkt[16] <= MAGIC[23:16];
            pkt[17] <= MAGIC[31:24];
            pkt[18] <= RESPK[ 7:0];
            pkt[19] <= RESPK[15:8];
            pkt[20] <= op_id [ 7: 0];
            pkt[21] <= op_id [15: 8];
            pkt[22] <= op_id [23:16];
            pkt[23] <= op_id [31:24];
            pkt[24] <= task_id[ 7: 0];
            pkt[25] <= task_id[15: 8];
            pkt[26] <= task_id[23:16];
            pkt[27] <= task_id[31:24];
            pkt[28] <= {7'b0, mp_done_err, 1'b1} & 8'hFF; // status low
            pkt[29] <= 8'd0;
            pkt[30] <= 8'd0;
            pkt[31] <= 8'd0;
            // Result registers (little-endian, 32..63)
            for (int r = 0; r < 4; r++) begin
              for (int b = 0; b < 8; b++) begin
                pkt[32 + 8*r + b] <= mp_done_result[r][8*b + 7 -: 8];
              end
            end
            beat_idx <= '0;
            state    <= T_DRIVE;
          end
        end

        T_DRIVE: begin
          if (m_axis_tready) begin
            if (beat_idx == NBEATS - 1) begin
              state    <= T_IDLE;
              beat_idx <= '0;
            end else begin
              beat_idx <= beat_idx + 1;
            end
          end
        end

        default: state <= T_IDLE;
      endcase
    end
  end

  // ----- Drive the current beat from pkt[beat_idx*BB .. ...] ---------
  always_comb begin
    m_axis_tdata  = '0;
    m_axis_tkeep  = '0;
    m_axis_tvalid = 1'b0;
    m_axis_tlast  = 1'b0;
    m_axis_tid    = '0;
    m_axis_tdest  = '0;
    m_axis_tuser  = '0;
    if (state == T_DRIVE) begin
      m_axis_tvalid = 1'b1;
      m_axis_tlast  = (beat_idx == NBEATS - 1);
      for (int i = 0; i < BEAT_BYTES; i++) begin
        if ((beat_idx * BEAT_BYTES + i) < RESP_BYTES) begin
          m_axis_tdata[8*i + 7 -: 8] = pkt[beat_idx * BEAT_BYTES + i];
          m_axis_tkeep[i]            = 1'b1;
        end
      end
    end
  end

endmodule
