// Tiara XDMA host stub.
//
// Sim-only.  Acts as a fake Corundum DMA fabric for tiara_xdma_engine:
// consumes read/write descriptors, transfers between an internal "host
// DRAM" array and the engine's scratchpad via the dma_ram cmd ports,
// and emits status responses.
//
// Latency model is fixed at LATENCY_CYCLES so the paper-calibrated
// timing applies to the XDMA path too.  DPI hooks let the C++ harness
// seed and inspect the host array directly.

`include "tiara_pkg.svh"

module tiara_xdma_host_stub
#(
    parameter int unsigned MEM_DEPTH         = 1 << 19,    // 8-byte words
    parameter int unsigned LATENCY_CYCLES    = 150,

    parameter int unsigned DMA_ADDR_WIDTH    = 64,
    parameter int unsigned DMA_LEN_WIDTH     = 16,
    parameter int unsigned DMA_TAG_WIDTH     = 8,
    parameter int unsigned RAM_SEL_WIDTH     = 1,
    parameter int unsigned RAM_ADDR_WIDTH    = 12,
    parameter int unsigned RAM_SEG_COUNT     = 2,
    parameter int unsigned RAM_SEG_DATA_WIDTH= 256,
    parameter int unsigned RAM_SEG_BE_WIDTH  = RAM_SEG_DATA_WIDTH/8,
    parameter int unsigned RAM_SEG_ADDR_WIDTH= RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH/8),
    parameter int unsigned DMA_IMM_WIDTH     = 32
)
(
    input  logic clk,
    input  logic rst_n,

    // Read descriptor slave  (engine -> host stub)
    input  logic [DMA_ADDR_WIDTH-1:0]   s_read_dma_addr,
    input  logic [RAM_SEL_WIDTH-1:0]    s_read_ram_sel,
    input  logic [RAM_ADDR_WIDTH-1:0]   s_read_ram_addr,
    input  logic [DMA_LEN_WIDTH-1:0]    s_read_len,
    input  logic [DMA_TAG_WIDTH-1:0]    s_read_tag,
    input  logic                        s_read_valid,
    output logic                        s_read_ready,
    output logic [DMA_TAG_WIDTH-1:0]    m_read_status_tag,
    output logic [3:0]                  m_read_status_error,
    output logic                        m_read_status_valid,

    // Write descriptor slave (engine -> host stub)
    input  logic [DMA_ADDR_WIDTH-1:0]   s_write_dma_addr,
    input  logic [RAM_SEL_WIDTH-1:0]    s_write_ram_sel,
    input  logic [RAM_ADDR_WIDTH-1:0]   s_write_ram_addr,
    input  logic [DMA_IMM_WIDTH-1:0]    s_write_imm,
    input  logic                        s_write_imm_en,
    input  logic [DMA_LEN_WIDTH-1:0]    s_write_len,
    input  logic [DMA_TAG_WIDTH-1:0]    s_write_tag,
    input  logic                        s_write_valid,
    output logic                        s_write_ready,
    output logic [DMA_TAG_WIDTH-1:0]    m_write_status_tag,
    output logic [3:0]                  m_write_status_error,
    output logic                        m_write_status_valid,

    // DMA RAM cmd master (host stub -> engine scratchpad)
    output logic [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      m_ram_wr_cmd_sel,
    output logic [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   m_ram_wr_cmd_be,
    output logic [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] m_ram_wr_cmd_addr,
    output logic [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] m_ram_wr_cmd_data,
    output logic [RAM_SEG_COUNT-1:0]                    m_ram_wr_cmd_valid,
    input  logic [RAM_SEG_COUNT-1:0]                    m_ram_wr_cmd_ready,
    input  logic [RAM_SEG_COUNT-1:0]                    m_ram_wr_done,
    output logic [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      m_ram_rd_cmd_sel,
    output logic [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] m_ram_rd_cmd_addr,
    output logic [RAM_SEG_COUNT-1:0]                    m_ram_rd_cmd_valid,
    input  logic [RAM_SEG_COUNT-1:0]                    m_ram_rd_cmd_ready,
    input  logic [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] m_ram_rd_resp_data,
    input  logic [RAM_SEG_COUNT-1:0]                    m_ram_rd_resp_valid,
    output logic [RAM_SEG_COUNT-1:0]                    m_ram_rd_resp_ready
);

  localparam int unsigned AW = $clog2(MEM_DEPTH);
  localparam int unsigned SEG_BYTES = RAM_SEG_DATA_WIDTH/8;
  localparam int unsigned BEAT_BYTES = RAM_SEG_COUNT * SEG_BYTES;

  (* ram_style = "block" *) logic [63:0] hostmem [0:MEM_DEPTH-1];

`ifndef SYNTHESIS
  initial for (int i = 0; i < MEM_DEPTH; i++) hostmem[i] = 64'd0;
`endif

  // ---- Read descriptor: latency, fetch from hostmem, push into scratch ----
  typedef enum logic [2:0] {
      R_IDLE = 3'd0,
      R_LAT  = 3'd1,
      R_DRV  = 3'd2,
      R_DONE = 3'd3
  } rstate_e;

  rstate_e r_state;
  logic [15:0] r_cnt;
  logic [DMA_ADDR_WIDTH-1:0] r_host;
  logic [RAM_ADDR_WIDTH-1:0] r_ram;
  logic [DMA_LEN_WIDTH-1:0]  r_len;
  logic [DMA_TAG_WIDTH-1:0]  r_tag;
  logic [DMA_LEN_WIDTH-1:0]  r_byte_off;       // bytes already pushed

  assign s_read_ready = (r_state == R_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_state <= R_IDLE;
      r_cnt   <= '0;
      m_read_status_valid <= 1'b0;
      m_read_status_tag   <= '0;
      m_read_status_error <= '0;
      r_byte_off <= '0;
      m_ram_wr_cmd_valid <= '0;
    end else begin
      m_read_status_valid <= 1'b0;
      m_ram_wr_cmd_valid  <= '0;

      unique case (r_state)
        R_IDLE: if (s_read_valid) begin
            r_host   <= s_read_dma_addr;
            r_ram    <= s_read_ram_addr;
            r_len    <= s_read_len;
            r_tag    <= s_read_tag;
            r_cnt    <= LATENCY_CYCLES[15:0];
            r_byte_off <= '0;
            r_state  <= R_LAT;
        end
        R_LAT: begin
          if (r_cnt > 0) r_cnt <= r_cnt - 1;
          else           r_state <= R_DRV;
        end
        R_DRV: begin
          // Push one beat (RAM_SEG_COUNT*SEG_BYTES) into scratchpad.
          for (int seg = 0; seg < RAM_SEG_COUNT; seg++) begin
            // Compose a beat by reading consecutive 8-byte words from hostmem.
            for (int w = 0; w < RAM_SEG_DATA_WIDTH/64; w++) begin
              logic [DMA_ADDR_WIDTH-1:0] word_addr;
              word_addr = r_host + r_byte_off + seg*SEG_BYTES + w*8;
              m_ram_wr_cmd_data[seg*RAM_SEG_DATA_WIDTH + w*64 +: 64] <=
                hostmem[word_addr[AW+2:3] & {AW{1'b1}}];
            end
            m_ram_wr_cmd_be[seg*RAM_SEG_BE_WIDTH +: RAM_SEG_BE_WIDTH] <= '1;
            m_ram_wr_cmd_addr[seg*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH] <=
              (r_ram + r_byte_off + seg*SEG_BYTES) >> $clog2(BEAT_BYTES);
            m_ram_wr_cmd_sel[seg*RAM_SEL_WIDTH +: RAM_SEL_WIDTH] <= '0;
          end
          m_ram_wr_cmd_valid <= '1;
          // Advance only when a *registered* valid was paired with ready
          // last cycle.  This preserves correctness in the face of
          // non-blocking propagation.
          if ((&m_ram_wr_cmd_valid) && (&m_ram_wr_cmd_ready)) begin
            if (r_byte_off + BEAT_BYTES >= r_len) begin
              r_state <= R_DONE;
            end else begin
              r_byte_off <= r_byte_off + BEAT_BYTES;
            end
          end
        end
        R_DONE: begin
          m_read_status_tag   <= r_tag;
          m_read_status_error <= 4'd0;
          m_read_status_valid <= 1'b1;
          r_state <= R_IDLE;
        end
        default: r_state <= R_IDLE;
      endcase
    end
  end

  // ---- Write descriptor: read from scratch, push into hostmem ----------
  typedef enum logic [2:0] {
      W_IDLE = 3'd0,
      W_REQ  = 3'd1,
      W_RESP = 3'd2,
      W_LAT  = 3'd3,
      W_DONE = 3'd4
  } wstate_e;

  wstate_e w_state;
  logic [15:0] w_cnt;
  logic [DMA_ADDR_WIDTH-1:0] w_host;
  logic [RAM_ADDR_WIDTH-1:0] w_ram;
  logic [DMA_LEN_WIDTH-1:0]  w_len;
  logic [DMA_TAG_WIDTH-1:0]  w_tag;
  logic [DMA_LEN_WIDTH-1:0]  w_byte_off;

  assign s_write_ready = (w_state == W_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_state <= W_IDLE;
      w_cnt   <= '0;
      m_write_status_valid <= 1'b0;
      m_write_status_tag   <= '0;
      m_write_status_error <= '0;
      m_ram_rd_cmd_valid   <= '0;
      m_ram_rd_resp_ready  <= '0;
      w_byte_off           <= '0;
    end else begin
      m_write_status_valid <= 1'b0;
      m_ram_rd_cmd_valid   <= '0;
      m_ram_rd_resp_ready  <= '1;     // always accept

      unique case (w_state)
        W_IDLE: if (s_write_valid) begin
            w_host <= s_write_dma_addr;
            w_ram  <= s_write_ram_addr;
            w_len  <= s_write_len;
            w_tag  <= s_write_tag;
            w_byte_off <= '0;
            w_state <= W_REQ;
        end
        W_REQ: begin
          // Issue read for one beat from scratchpad
          for (int seg = 0; seg < RAM_SEG_COUNT; seg++) begin
            m_ram_rd_cmd_addr[seg*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH] <=
              (w_ram + w_byte_off + seg*SEG_BYTES) >> $clog2(BEAT_BYTES);
            m_ram_rd_cmd_sel[seg*RAM_SEL_WIDTH +: RAM_SEL_WIDTH] <= '0;
          end
          m_ram_rd_cmd_valid <= '1;
          // Wait for the registered valid to land on the bus.
          if ((&m_ram_rd_cmd_valid) && (&m_ram_rd_cmd_ready)) begin
            m_ram_rd_cmd_valid <= '0;
            w_state <= W_RESP;
          end
        end
        W_RESP: begin
          if (&m_ram_rd_resp_valid) begin
            for (int seg = 0; seg < RAM_SEG_COUNT; seg++) begin
              for (int w = 0; w < RAM_SEG_DATA_WIDTH/64; w++) begin
                logic [DMA_LEN_WIDTH-1:0] this_byte_off;
                logic [DMA_ADDR_WIDTH-1:0] word_addr;
                this_byte_off = w_byte_off + seg*SEG_BYTES + w*8;
                word_addr = w_host + this_byte_off;
                // Only write words that lie within w_len of the start.
                if (this_byte_off < w_len) begin
                  hostmem[word_addr[AW+2:3] & {AW{1'b1}}] <=
                    m_ram_rd_resp_data[seg*RAM_SEG_DATA_WIDTH + w*64 +: 64];
                end
              end
            end
            if (w_byte_off + BEAT_BYTES >= w_len) begin
              w_cnt <= LATENCY_CYCLES[15:0];
              w_state <= W_LAT;
            end else begin
              w_byte_off <= w_byte_off + BEAT_BYTES;
              w_state <= W_REQ;
            end
          end
        end
        W_LAT: begin
          if (w_cnt > 0) w_cnt <= w_cnt - 1;
          else           w_state <= W_DONE;
        end
        W_DONE: begin
          m_write_status_tag   <= w_tag;
          m_write_status_error <= 4'd0;
          m_write_status_valid <= 1'b1;
          w_state <= W_IDLE;
        end
        default: w_state <= W_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // DPI hooks for the C++ testbench
  export "DPI-C" task tiara_dpi_xdma_poke;
  export "DPI-C" task tiara_dpi_xdma_peek;

  task tiara_dpi_xdma_poke(input int word_addr, input longint value);
    hostmem[word_addr] = value;
  endtask
  task tiara_dpi_xdma_peek(input int word_addr, output longint value);
    value = hostmem[word_addr];
  endtask
`endif

endmodule
