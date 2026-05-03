// Tiara host-control AXI-Lite slave.
//
// Maps the Tiara MP into the mqnic application control region.
// Register layout (32-bit AXI-Lite, byte addresses):
//
//   0x0000..0x1FFF : instruction store write window
//                    word offset N (32 bit) writes the lo/hi half of
//                    instruction[N>>1] in the MP's istore.  Even N -> low
//                    32 bit of instruction; odd N -> high 32 bit (which
//                    triggers the actual istore write).
//
//   0x2000..0x203F : argument registers (16 x 32b = 8 x 64b).  Same
//                    lo/hi convention.
//
//   0x2040         : ctrl register
//                    write 1 -> issue task_start pulse
//                    write 2 -> assert reset to MP for one cycle
//
//   0x2044         : status register
//                    bit 0  : busy
//                    bit 1  : done (cleared on read)
//                    bit 2  : err
//                    bit 31:8 : current instr_retired count[15:0]
//
//   0x2050..0x206F : result registers (4 x 64b = 8 x 32b reads)
//
// The host driver (mqnic kernel module + a small Tiara character device)
// pokes operator binaries into the istore via 32-bit AXI-Lite writes,
// then writes args and the ctrl register to launch.

`include "tiara_pkg.svh"

module tiara_axil_slave
  import tiara_pkg::*;
#(
    parameter int unsigned AXIL_DATA_WIDTH = 32,
    parameter int unsigned AXIL_ADDR_WIDTH = 16,
    parameter int unsigned AXIL_STRB_WIDTH = AXIL_DATA_WIDTH/8
)
(
    input  logic                                   clk,
    input  logic                                   rst,

    // AXI-Lite slave (host-side application control)
    input  logic [AXIL_ADDR_WIDTH-1:0]             s_axil_awaddr,
    input  logic [2:0]                             s_axil_awprot,
    input  logic                                   s_axil_awvalid,
    output logic                                   s_axil_awready,
    input  logic [AXIL_DATA_WIDTH-1:0]             s_axil_wdata,
    input  logic [AXIL_STRB_WIDTH-1:0]             s_axil_wstrb,
    input  logic                                   s_axil_wvalid,
    output logic                                   s_axil_wready,
    output logic [1:0]                             s_axil_bresp,
    output logic                                   s_axil_bvalid,
    input  logic                                   s_axil_bready,

    input  logic [AXIL_ADDR_WIDTH-1:0]             s_axil_araddr,
    input  logic [2:0]                             s_axil_arprot,
    input  logic                                   s_axil_arvalid,
    output logic                                   s_axil_arready,
    output logic [AXIL_DATA_WIDTH-1:0]             s_axil_rdata,
    output logic [1:0]                             s_axil_rresp,
    output logic                                   s_axil_rvalid,
    input  logic                                   s_axil_rready,

    // Tiara control side
    output logic                                            mp_load_en,
    output logic [$clog2(INSTR_STORE_DEPTH)-1:0]            mp_load_addr,
    output logic [63:0]                                     mp_load_data,

    output logic                                            mp_inv_valid,
    output logic [63:0]                                     mp_inv_args [0:7],
    input  logic                                            mp_inv_busy,
    input  logic                                            mp_done,
    input  logic [63:0]                                     mp_done_result [0:3],
    input  logic                                            mp_done_err,
    input  logic [31:0]                                     mp_instr_retired
);

  // -----------------------------------------------------------------
  // Address decode regions
  // -----------------------------------------------------------------
  localparam logic [15:0] BASE_ISTORE  = 16'h0000;
  localparam logic [15:0] BASE_ARGS    = 16'h2000;
  localparam logic [15:0] OFFS_CTRL    = 16'h2040;
  localparam logic [15:0] OFFS_STATUS  = 16'h2044;
  localparam logic [15:0] BASE_RESULT  = 16'h2050;

  // -----------------------------------------------------------------
  // Storage for partial instruction and arg writes (lo half latched
  // until hi half arrives).
  // -----------------------------------------------------------------
  logic [31:0] istore_lo;
  logic [31:0] arg_lo [0:7];
  logic [63:0] arg_q  [0:7];

  // Done latch — sticky until read or until a new invocation clears it.
  // Consolidated single-driver block handles all three control inputs:
  //   set on mp_done, clear on a write to OFFS_CTRL[0] (new invoke)
  //   or on a read of OFFS_STATUS (RC behavior).
  logic        done_sticky;
  logic        err_sticky;
  logic        clr_done_invoke, clr_done_read;

  always_ff @(posedge clk) begin
    if (rst) begin
      done_sticky <= 1'b0;
      err_sticky  <= 1'b0;
    end else begin
      if (mp_done) begin
        done_sticky <= 1'b1;
        if (mp_done_err) err_sticky <= 1'b1;
      end else if (clr_done_invoke || clr_done_read) begin
        done_sticky <= 1'b0;
        if (clr_done_invoke) err_sticky <= 1'b0;
      end
    end
  end

  // -----------------------------------------------------------------
  // Write channel FSM
  // -----------------------------------------------------------------
  typedef enum logic [1:0] {
      W_IDLE = 2'd0,
      W_RESP = 2'd1
  } wstate_e;
  wstate_e wstate;
  logic [AXIL_ADDR_WIDTH-1:0] aw_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      wstate         <= W_IDLE;
      s_axil_awready <= 1'b0;
      s_axil_wready  <= 1'b0;
      s_axil_bvalid  <= 1'b0;
      s_axil_bresp   <= 2'b00;
      mp_load_en     <= 1'b0;
      mp_inv_valid   <= 1'b0;
      mp_load_addr   <= '0;
      mp_load_data   <= '0;
      istore_lo      <= '0;
      clr_done_invoke<= 1'b0;
      for (int i = 0; i < 8; i++) begin
        arg_lo[i] <= '0;
        arg_q [i] <= '0;
      end
    end else begin
      mp_load_en      <= 1'b0;
      mp_inv_valid    <= 1'b0;
      clr_done_invoke <= 1'b0;

      unique case (wstate)
        W_IDLE: begin
          if (s_axil_awvalid && s_axil_wvalid) begin
            s_axil_awready <= 1'b1;
            s_axil_wready  <= 1'b1;
            aw_q           <= s_axil_awaddr;

            // ---------- istore window ----------
            if (s_axil_awaddr < BASE_ARGS) begin
              automatic int wnum = s_axil_awaddr[12:2];
              if ((s_axil_awaddr & 16'h4) == 0) begin
                istore_lo <= s_axil_wdata;
              end else begin
                mp_load_en   <= 1'b1;
                mp_load_addr <= wnum >> 1;
                mp_load_data <= {s_axil_wdata, istore_lo};
              end
            end
            // ---------- arg window ----------
            else if (s_axil_awaddr >= BASE_ARGS && s_axil_awaddr < OFFS_CTRL) begin
              automatic int idx = s_axil_awaddr[5:3];   // 8 args
              if ((s_axil_awaddr & 16'h4) == 0) begin
                arg_lo[idx] <= s_axil_wdata;
              end else begin
                arg_q[idx] <= {s_axil_wdata, arg_lo[idx]};
              end
            end
            // ---------- ctrl register ----------
            else if (s_axil_awaddr == OFFS_CTRL) begin
              if (s_axil_wdata[0]) begin
                mp_inv_valid    <= 1'b1;
                clr_done_invoke <= 1'b1;
              end
            end

            s_axil_bvalid <= 1'b1;
            s_axil_bresp  <= 2'b00;
            wstate        <= W_RESP;
          end
        end
        W_RESP: begin
          s_axil_awready <= 1'b0;
          s_axil_wready  <= 1'b0;
          if (s_axil_bready && s_axil_bvalid) begin
            s_axil_bvalid <= 1'b0;
            wstate        <= W_IDLE;
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // -----------------------------------------------------------------
  // Read channel
  // -----------------------------------------------------------------
  typedef enum logic [1:0] {
      R_IDLE = 2'd0,
      R_RESP = 2'd1
  } rstate_e;
  rstate_e rstate;
  logic [AXIL_ADDR_WIDTH-1:0] ar_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      rstate         <= R_IDLE;
      s_axil_arready <= 1'b0;
      s_axil_rvalid  <= 1'b0;
      s_axil_rdata   <= '0;
      s_axil_rresp   <= 2'b00;
      clr_done_read  <= 1'b0;
    end else begin
      clr_done_read <= 1'b0;
      unique case (rstate)
        R_IDLE: begin
          if (s_axil_arvalid) begin
            s_axil_arready <= 1'b1;
            ar_q           <= s_axil_araddr;
            // Decode below in next state
            // status
            if (s_axil_araddr == OFFS_STATUS) begin
              s_axil_rdata <= {mp_instr_retired[23:0],
                               5'b0, err_sticky, done_sticky, mp_inv_busy};
            end
            // result
            else if (s_axil_araddr >= BASE_RESULT && s_axil_araddr < BASE_RESULT + 16'h20) begin
              automatic int idx = s_axil_araddr[4:3];   // 4 result regs
              if ((s_axil_araddr & 16'h4) == 0)
                s_axil_rdata <= mp_done_result[idx][31:0];
              else
                s_axil_rdata <= mp_done_result[idx][63:32];
            end
            // arg readback
            else if (s_axil_araddr >= BASE_ARGS && s_axil_araddr < OFFS_CTRL) begin
              automatic int idx = s_axil_araddr[5:3];
              if ((s_axil_araddr & 16'h4) == 0)
                s_axil_rdata <= arg_q[idx][31:0];
              else
                s_axil_rdata <= arg_q[idx][63:32];
            end
            else begin
              s_axil_rdata <= 32'hDEAD0000;
            end
            s_axil_rvalid  <= 1'b1;
            s_axil_rresp   <= 2'b00;
            rstate         <= R_RESP;
          end
        end
        R_RESP: begin
          s_axil_arready <= 1'b0;
          if (s_axil_rready && s_axil_rvalid) begin
            s_axil_rvalid <= 1'b0;
            rstate        <= R_IDLE;
            // Clear sticky done after read (consolidated driver
            // handles the actual register write).
            if (ar_q == OFFS_STATUS) begin
              clr_done_read <= 1'b1;
            end
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // Argument forwarding to MP
  assign mp_inv_args = arg_q;

endmodule
