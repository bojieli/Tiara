// Tiara datapath top — slim wrapper for the RX→core→TX path.
//
// This is the same set of modules wired into mqnic_app_block but with
// Corundum's interface boilerplate stripped out, so a Verilator
// testbench can drive realistic AXIS RX traffic and observe the AXIS
// TX response without dragging in the entire mqnic.
//
// Operator loading is via the same `load_*` ports as `tiara_synth_top`
// (the testbench bypasses the AXI-Lite slave for this).  Invocations
// arrive only via the RX AXIS path.

`include "tiara_pkg.svh"
`include "tiara_packet.svh"

module tiara_datapath_top
  import tiara_pkg::*;
#(
    parameter int unsigned DATA_WIDTH = 512,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH/8,
    parameter int unsigned ID_WIDTH   = 8,
    parameter int unsigned DEST_WIDTH = 8,
    parameter int unsigned USER_WIDTH = 1
)
(
    input  logic clk,
    input  logic rst_n,

    // Operator load (testbench writes the istore directly)
    input  logic                                 load_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] load_addr,
    input  logic [63:0]                          load_data,

    // Local NIC MAC (driven into the response packet)
    input  logic [47:0]                          local_mac,

    // RX AXIS in
    input  logic [DATA_WIDTH-1:0]      s_axis_rx_tdata,
    input  logic [KEEP_WIDTH-1:0]      s_axis_rx_tkeep,
    input  logic                       s_axis_rx_tvalid,
    output logic                       s_axis_rx_tready,
    input  logic                       s_axis_rx_tlast,

    // RX AXIS out (passthrough — non-Tiara packets)
    output logic [DATA_WIDTH-1:0]      m_axis_rx_tdata,
    output logic [KEEP_WIDTH-1:0]      m_axis_rx_tkeep,
    output logic                       m_axis_rx_tvalid,
    input  logic                       m_axis_rx_tready,
    output logic                       m_axis_rx_tlast,

    // TX AXIS out (Tiara response)
    output logic [DATA_WIDTH-1:0]      m_axis_tx_tdata,
    output logic [KEEP_WIDTH-1:0]      m_axis_tx_tkeep,
    output logic                       m_axis_tx_tvalid,
    input  logic                       m_axis_tx_tready,
    output logic                       m_axis_tx_tlast,

    // Telemetry
    output logic [31:0]                instr_retired,
    // Debug taps for the testbench
    output logic                       dbg_rx_inv_valid,
    output logic                       dbg_tia_busy,
    output logic                       dbg_tia_done
);

  wire rst = ~rst_n;

  wire        rx_inv_valid;
  wire [63:0] rx_inv_args [0:7];
  wire [31:0] rx_inv_op_id;
  wire [31:0] rx_inv_task_id;
  wire [47:0] rx_inv_src_mac;

  wire        tia_busy;
  wire        tia_done;
  wire [63:0] tia_done_result [0:3];
  wire        tia_done_err;

  tiara_rx_filter #(
      .DATA_WIDTH(DATA_WIDTH),
      .KEEP_WIDTH(KEEP_WIDTH),
      .ID_WIDTH  (ID_WIDTH),
      .DEST_WIDTH(DEST_WIDTH),
      .USER_WIDTH(USER_WIDTH)
  ) u_rx (
      .clk          (clk),
      .rst          (rst),
      .s_axis_tdata (s_axis_rx_tdata),
      .s_axis_tkeep (s_axis_rx_tkeep),
      .s_axis_tvalid(s_axis_rx_tvalid),
      .s_axis_tready(s_axis_rx_tready),
      .s_axis_tlast (s_axis_rx_tlast),
      .s_axis_tid   ('0),
      .s_axis_tdest ('0),
      .s_axis_tuser ('0),
      .m_axis_tdata (m_axis_rx_tdata),
      .m_axis_tkeep (m_axis_rx_tkeep),
      .m_axis_tvalid(m_axis_rx_tvalid),
      .m_axis_tready(m_axis_rx_tready),
      .m_axis_tlast (m_axis_rx_tlast),
      .m_axis_tid   (),
      .m_axis_tdest (),
      .m_axis_tuser (),
      .inv_valid    (rx_inv_valid),
      .inv_args     (rx_inv_args),
      .inv_op_id    (rx_inv_op_id),
      .inv_task_id  (rx_inv_task_id),
      .inv_src_mac  (rx_inv_src_mac),
      .mp_busy      (tia_busy)
  );

  tiara_synth_top #(
      .LOCAL_LATENCY_CYCLES(150),
      .RTT_CYCLES          (500),
      .LOCAL_MEM_DEPTH     (1024),
      .PEER_MEM_DEPTH      (256)
  ) u_core (
      .clk          (clk),
      .rst_n        (rst_n),
      .load_en      (load_en),
      .load_addr    (load_addr),
      .load_data    (load_data),
      .inv_valid    (rx_inv_valid),
      .inv_args     (rx_inv_args),
      .inv_start_pc ('0),                  // single-op via wire path; for
                                           // multi-op route op_id->start_pc
                                           // through tiara_op_table here.
      .inv_busy     (tia_busy),
      .done         (tia_done),
      .done_result  (tia_done_result),
      .done_err     (tia_done_err),
      .instr_retired(instr_retired)
  );

  assign dbg_rx_inv_valid = rx_inv_valid;
  assign dbg_tia_busy     = tia_busy;
  assign dbg_tia_done     = tia_done;

  tiara_tx_resp #(
      .DATA_WIDTH(DATA_WIDTH),
      .KEEP_WIDTH(KEEP_WIDTH),
      .ID_WIDTH  (ID_WIDTH),
      .DEST_WIDTH(DEST_WIDTH),
      .USER_WIDTH(USER_WIDTH)
  ) u_tx (
      .clk          (clk),
      .rst          (rst),
      .mp_done      (tia_done),
      .mp_done_err  (tia_done_err),
      .mp_done_result(tia_done_result),
      .src_mac      (rx_inv_src_mac),
      .local_mac    (local_mac),
      .op_id        (rx_inv_op_id),
      .task_id      (rx_inv_task_id),
      .m_axis_tdata (m_axis_tx_tdata),
      .m_axis_tkeep (m_axis_tx_tkeep),
      .m_axis_tvalid(m_axis_tx_tvalid),
      .m_axis_tready(m_axis_tx_tready),
      .m_axis_tlast (m_axis_tx_tlast),
      .m_axis_tid   (),
      .m_axis_tdest (),
      .m_axis_tuser ()
  );

endmodule
