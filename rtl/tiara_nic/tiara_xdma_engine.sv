// Tiara XDMA engine.
//
// Synthesizable PCIe DMA engine that talks to Corundum's per-app DMA
// descriptor + ram interface (the same one mqnic uses for its
// transmit/receive data engines).  Every Tiara LOAD/STORE/MEMCPY/CAS/CAA
// against device 0 (host DRAM) goes through this module:
//
//   * LOAD64  -> emit read-desc(host_addr, ram_addr=stg, len=8); on
//                read-status, read scratchpad; return rd_data.
//   * STORE64 -> write scratchpad; emit write-desc; on status, ack.
//   * MEMCPY  -> for dst=src=device-0, issue back-to-back read-desc
//                followed by write-desc; the scratchpad holds the
//                in-flight bytes.  Length is capped at the scratchpad
//                size; longer copies are split internally.
//   * CAS/CAA -> read-modify-write triplet through scratchpad.  We
//                cannot get hardware-level atomicity over the host PCIe
//                bus, so the verifier flags that CAS targets in the
//                local-host region are best-effort.  Cross-device CAS
//                (RDMA) goes through the RDMA engine, which has true
//                atomicity via its peer NIC.
//
// On the Corundum side this module exposes:
//   * descriptor master ports (mirrors `m_axis_data_dma_*` from
//     mqnic_app_block) — read/write desc + status streams.
//   * data_dma_ram slave ports — Corundum reads/writes our scratchpad
//     during DMA transfers, segmented as RAM_SEG_COUNT * RAM_SEG_DATA_WIDTH.
//
// The interface deliberately matches Corundum's so we can splice this
// module straight into `mqnic_app_block`: see
// `integration/corundum_app/rtl/mqnic_app_block.sv` for the
// instantiation point, currently tied off.

`include "tiara_pkg.svh"

module tiara_xdma_engine
  import tiara_pkg::*;
#(
    // Tiara MP-side
    parameter int unsigned ADDR_BITS         = 32,

    // Corundum DMA descriptor widths (defaults match mqnic_app_block)
    parameter int unsigned DMA_ADDR_WIDTH    = 64,
    parameter int unsigned DMA_LEN_WIDTH     = 16,
    parameter int unsigned DMA_TAG_WIDTH     = 8,
    parameter int unsigned RAM_SEL_WIDTH     = 1,
    parameter int unsigned RAM_ADDR_WIDTH    = 12,
    parameter int unsigned RAM_SEG_COUNT     = 2,
    parameter int unsigned RAM_SEG_DATA_WIDTH= 256,
    parameter int unsigned RAM_SEG_BE_WIDTH  = RAM_SEG_DATA_WIDTH/8,
    parameter int unsigned RAM_SEG_ADDR_WIDTH= RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH/8),
    parameter int unsigned DMA_IMM_WIDTH     = 32,

    // Per-engine scratchpad in 8-byte words.  Sized to accommodate the
    // longest single MEMCPY we admit; everything beyond this is split
    // into multiple descriptor pairs.
    parameter int unsigned SCRATCH_WORDS     = 256
)
(
    input  logic                              clk,
    input  logic                              rst_n,

    // ----------------------- Tiara MP side ---------------------------
    input  logic                              rd_en,
    input  logic [ADDR_BITS-1:0]              rd_addr,
    output logic                              rd_valid,
    output logic [63:0]                       rd_data,
    output logic                              rd_err,

    input  logic                              wr_en,
    input  logic [ADDR_BITS-1:0]              wr_addr,
    input  logic [63:0]                       wr_data,
    output logic                              wr_done,

    input  logic                              cpy_en,
    input  logic [ADDR_BITS-1:0]              cpy_dst,
    input  logic [ADDR_BITS-1:0]              cpy_src,
    input  logic [31:0]                       cpy_len,
    output logic                              cpy_accept,
    output logic                              cpy_done,

    input  logic                              atom_en,
    input  logic                              atom_caa,
    input  logic [ADDR_BITS-1:0]              atom_addr,
    input  logic [63:0]                       atom_expected,
    input  logic [63:0]                       atom_swap,
    output logic                              atom_valid,
    output logic [63:0]                       atom_data,

    output logic                              ready,

    // ----------------------- Corundum DMA descriptor master ----------
    output logic [DMA_ADDR_WIDTH-1:0]         m_axis_dma_read_desc_dma_addr,
    output logic [RAM_SEL_WIDTH-1:0]          m_axis_dma_read_desc_ram_sel,
    output logic [RAM_ADDR_WIDTH-1:0]         m_axis_dma_read_desc_ram_addr,
    output logic [DMA_LEN_WIDTH-1:0]          m_axis_dma_read_desc_len,
    output logic [DMA_TAG_WIDTH-1:0]          m_axis_dma_read_desc_tag,
    output logic                              m_axis_dma_read_desc_valid,
    input  logic                              m_axis_dma_read_desc_ready,

    input  logic [DMA_TAG_WIDTH-1:0]          s_axis_dma_read_desc_status_tag,
    input  logic [3:0]                        s_axis_dma_read_desc_status_error,
    input  logic                              s_axis_dma_read_desc_status_valid,

    output logic [DMA_ADDR_WIDTH-1:0]         m_axis_dma_write_desc_dma_addr,
    output logic [RAM_SEL_WIDTH-1:0]          m_axis_dma_write_desc_ram_sel,
    output logic [RAM_ADDR_WIDTH-1:0]         m_axis_dma_write_desc_ram_addr,
    output logic [DMA_IMM_WIDTH-1:0]          m_axis_dma_write_desc_imm,
    output logic                              m_axis_dma_write_desc_imm_en,
    output logic [DMA_LEN_WIDTH-1:0]          m_axis_dma_write_desc_len,
    output logic [DMA_TAG_WIDTH-1:0]          m_axis_dma_write_desc_tag,
    output logic                              m_axis_dma_write_desc_valid,
    input  logic                              m_axis_dma_write_desc_ready,

    input  logic [DMA_TAG_WIDTH-1:0]          s_axis_dma_write_desc_status_tag,
    input  logic [3:0]                        s_axis_dma_write_desc_status_error,
    input  logic                              s_axis_dma_write_desc_status_valid,

    // ----------------------- Corundum DMA-RAM slave ------------------
    // Corundum issues writes into our scratchpad on completed reads,
    // and reads from our scratchpad on outgoing writes.
    input  logic [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      dma_ram_wr_cmd_sel,
    input  logic [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   dma_ram_wr_cmd_be,
    input  logic [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] dma_ram_wr_cmd_addr,
    input  logic [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] dma_ram_wr_cmd_data,
    input  logic [RAM_SEG_COUNT-1:0]                    dma_ram_wr_cmd_valid,
    output logic [RAM_SEG_COUNT-1:0]                    dma_ram_wr_cmd_ready,
    output logic [RAM_SEG_COUNT-1:0]                    dma_ram_wr_done,
    input  logic [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      dma_ram_rd_cmd_sel,
    input  logic [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] dma_ram_rd_cmd_addr,
    input  logic [RAM_SEG_COUNT-1:0]                    dma_ram_rd_cmd_valid,
    output logic [RAM_SEG_COUNT-1:0]                    dma_ram_rd_cmd_ready,
    output logic [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] dma_ram_rd_resp_data,
    output logic [RAM_SEG_COUNT-1:0]                    dma_ram_rd_resp_valid,
    input  logic [RAM_SEG_COUNT-1:0]                    dma_ram_rd_resp_ready
);

  // -------------------------------------------------------------------
  // Scratchpad — Corundum's DMA RAM interface backs onto this BRAM.
  // We index in 8-byte words on the Tiara side; Corundum sees a
  // segment-of-32-byte interface.
  // -------------------------------------------------------------------
  localparam int unsigned SP_AW = $clog2(SCRATCH_WORDS);
  (* ram_style = "block" *) logic [63:0] scratch [0:SCRATCH_WORDS-1];

  // Convert a Corundum segment address (counts segments, where each
  // segment is RAM_SEG_DATA_WIDTH/8 bytes) into a base 8-byte word
  // index in the scratchpad.
  function automatic logic [SP_AW-1:0] seg_word(input logic [RAM_SEG_ADDR_WIDTH-1:0] sa,
                                                 input int seg);
    int w_per_seg = RAM_SEG_DATA_WIDTH / 64;
    seg_word = (sa * (RAM_SEG_COUNT*w_per_seg)) + (seg * w_per_seg);
  endfunction

  // -------- DMA RAM write command — Corundum→scratchpad ---------------
  // We accept every cycle; a one-bit done pulse comes back next cycle.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dma_ram_wr_done <= '0;
    end else begin
      dma_ram_wr_done <= dma_ram_wr_cmd_valid;
      for (int seg = 0; seg < RAM_SEG_COUNT; seg++) begin
        if (dma_ram_wr_cmd_valid[seg]) begin
          logic [RAM_SEG_ADDR_WIDTH-1:0] sa;
          sa = dma_ram_wr_cmd_addr[seg*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH];
          for (int w = 0; w < RAM_SEG_DATA_WIDTH/64; w++) begin
            int  byte_lo = w * 8;
            logic any_be = |dma_ram_wr_cmd_be[seg*RAM_SEG_BE_WIDTH + byte_lo +: 8];
            if (any_be) begin
              int word_idx = seg_word(sa, seg) + w;
              scratch[word_idx] <=
                dma_ram_wr_cmd_data[seg*RAM_SEG_DATA_WIDTH + w*64 +: 64];
            end
          end
        end
      end
    end
  end
  assign dma_ram_wr_cmd_ready = '1;

  // -------- DMA RAM read command — scratchpad→Corundum ---------------
  // Two-cycle pipelined read so block-RAM inference is clean.
  logic [RAM_SEG_COUNT-1:0]                    rd_resp_valid_q;
  logic [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] rd_resp_data_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_resp_valid_q <= '0;
      rd_resp_data_q  <= '0;
    end else begin
      for (int seg = 0; seg < RAM_SEG_COUNT; seg++) begin
        if (dma_ram_rd_cmd_valid[seg] && dma_ram_rd_cmd_ready[seg]) begin
          logic [RAM_SEG_ADDR_WIDTH-1:0] sa;
          sa = dma_ram_rd_cmd_addr[seg*RAM_SEG_ADDR_WIDTH +: RAM_SEG_ADDR_WIDTH];
          for (int w = 0; w < RAM_SEG_DATA_WIDTH/64; w++) begin
            rd_resp_data_q[seg*RAM_SEG_DATA_WIDTH + w*64 +: 64] <=
              scratch[seg_word(sa, seg) + w];
          end
          rd_resp_valid_q[seg] <= 1'b1;
        end else if (rd_resp_valid_q[seg] && dma_ram_rd_resp_ready[seg]) begin
          rd_resp_valid_q[seg] <= 1'b0;
        end
      end
    end
  end
  assign dma_ram_rd_cmd_ready = ~rd_resp_valid_q;
  assign dma_ram_rd_resp_data  = rd_resp_data_q;
  assign dma_ram_rd_resp_valid = rd_resp_valid_q;

  // -------------------------------------------------------------------
  // FSM — single in-flight transaction.  This is conservative; a future
  // version pipelines via per-tag tracking.  The paper's per-MP latency
  // numbers come from the LATENCY_CYCLES model in tiara_pcie_dma; the
  // XDMA path inherits the host PCIe round-trip (~150 cycles @ 200 MHz).
  // -------------------------------------------------------------------
  typedef enum logic [3:0] {
      X_IDLE       = 4'd0,
      X_RD_DESC    = 4'd1,   // emit read descriptor
      X_RD_WAIT    = 4'd2,   // wait for read status
      X_RD_DRIVE   = 4'd3,   // present rd_data
      X_WR_PREP    = 4'd4,   // populate scratch with wr_data
      X_WR_DESC    = 4'd5,   // emit write descriptor
      X_WR_WAIT    = 4'd6,   // wait for write status
      X_WR_DRIVE   = 4'd7,   // pulse wr_done
      X_CPY_RD     = 4'd8,
      X_CPY_RDW    = 4'd9,
      X_CPY_WD     = 4'd10,
      X_CPY_WW     = 4'd11,
      X_CPY_DRIVE  = 4'd12,
      X_AT_RD      = 4'd13,  // CAS/CAA: read-modify-write triplet
      X_AT_RDW     = 4'd14,
      X_AT_MOD     = 4'd15
  } xstate_e;

  xstate_e state, state_q;

  logic [DMA_ADDR_WIDTH-1:0] cur_host_addr;
  logic [DMA_LEN_WIDTH-1:0]  cur_len;
  logic [63:0]               cur_wdata;
  logic [DMA_ADDR_WIDTH-1:0] cur_dst, cur_src;
  logic [31:0]               cur_cpy_remaining;
  logic                      cur_caa;
  logic [63:0]               cur_atom_exp, cur_atom_swap;
  logic                      cur_async;
  logic [DMA_TAG_WIDTH-1:0]  next_tag;

  // Single-slot tag book-keeping.  Tag bit 7 selects rd vs wr stream so
  // both can be in-flight concurrently when needed.
  localparam logic [DMA_TAG_WIDTH-1:0] TAG_RD = 8'h10;
  localparam logic [DMA_TAG_WIDTH-1:0] TAG_WR = 8'h90;

  assign ready = (state == X_IDLE);

  // Default-deassert pulse outputs
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= X_IDLE;
      rd_valid       <= 1'b0;
      rd_data        <= '0;
      rd_err         <= 1'b0;
      wr_done        <= 1'b0;
      cpy_accept     <= 1'b0;
      cpy_done       <= 1'b0;
      atom_valid     <= 1'b0;
      atom_data      <= '0;
      next_tag       <= 8'd0;
      cur_host_addr  <= '0;
      cur_len        <= '0;
      cur_wdata      <= '0;
      cur_dst        <= '0;
      cur_src        <= '0;
      cur_cpy_remaining <= '0;
      cur_caa        <= 1'b0;
      cur_atom_exp   <= '0;
      cur_atom_swap  <= '0;
      cur_async      <= 1'b0;
      m_axis_dma_read_desc_valid  <= 1'b0;
      m_axis_dma_write_desc_valid <= 1'b0;
    end else begin
      // Default deassert pulse outputs
      rd_valid    <= 1'b0;
      wr_done     <= 1'b0;
      cpy_accept  <= 1'b0;
      cpy_done    <= 1'b0;
      atom_valid  <= 1'b0;
      // descriptor handshakes managed below

      unique case (state)
        X_IDLE: begin
          if (rd_en) begin
            cur_host_addr <= rd_addr;
            cur_len       <= 16'd8;
            state         <= X_RD_DESC;
          end else if (wr_en) begin
            cur_host_addr <= wr_addr;
            cur_wdata     <= wr_data;
            cur_len       <= 16'd8;
            scratch[0]    <= wr_data;        // stage in scratchpad slot 0
            state         <= X_WR_DESC;
          end else if (cpy_en) begin
            cur_dst <= cpy_dst;
            cur_src <= cpy_src;
            cur_cpy_remaining <= cpy_len;
            cur_async  <= 1'b0;     // sync MEMCPY (operator owns async)
            cpy_accept <= 1'b1;
            state      <= X_CPY_RD;
          end else if (atom_en) begin
            cur_host_addr <= atom_addr;
            cur_caa       <= atom_caa;
            cur_atom_exp  <= atom_expected;
            cur_atom_swap <= atom_swap;
            cur_len       <= 16'd8;
            state         <= X_AT_RD;
          end
        end

        X_RD_DESC: begin
          m_axis_dma_read_desc_dma_addr <= cur_host_addr;
          m_axis_dma_read_desc_ram_sel  <= '0;
          m_axis_dma_read_desc_ram_addr <= '0;
          m_axis_dma_read_desc_len      <= cur_len;
          m_axis_dma_read_desc_tag      <= TAG_RD;
          m_axis_dma_read_desc_valid    <= 1'b1;
          // Wait until the *registered* valid was seen by the slave.
          if (m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready) begin
            m_axis_dma_read_desc_valid <= 1'b0;
            state <= X_RD_WAIT;
          end
        end
        X_RD_WAIT: begin
          if (s_axis_dma_read_desc_status_valid &&
              s_axis_dma_read_desc_status_tag == TAG_RD) begin
            rd_data  <= scratch[0];
            rd_err   <= |s_axis_dma_read_desc_status_error;
            rd_valid <= 1'b1;
            state    <= X_IDLE;
          end
        end

        X_WR_DESC: begin
          m_axis_dma_write_desc_dma_addr <= cur_host_addr;
          m_axis_dma_write_desc_ram_sel  <= '0;
          m_axis_dma_write_desc_ram_addr <= '0;
          m_axis_dma_write_desc_imm      <= '0;
          m_axis_dma_write_desc_imm_en   <= 1'b0;
          m_axis_dma_write_desc_len      <= cur_len;
          m_axis_dma_write_desc_tag      <= TAG_WR;
          m_axis_dma_write_desc_valid    <= 1'b1;
          if (m_axis_dma_write_desc_valid && m_axis_dma_write_desc_ready) begin
            m_axis_dma_write_desc_valid <= 1'b0;
            state <= X_WR_WAIT;
          end
        end
        X_WR_WAIT: begin
          if (s_axis_dma_write_desc_status_valid &&
              s_axis_dma_write_desc_status_tag == TAG_WR) begin
            wr_done <= 1'b1;
            state   <= X_IDLE;
          end
        end

        // ----- MEMCPY: read host[src] -> scratch -> write host[dst] ---
        X_CPY_RD: begin
          int seg_words = SCRATCH_WORDS;
          logic [DMA_LEN_WIDTH-1:0] this_len;
          this_len = (cur_cpy_remaining > seg_words*8) ? seg_words*8
                                                       : cur_cpy_remaining[DMA_LEN_WIDTH-1:0];
          m_axis_dma_read_desc_dma_addr <= cur_src;
          m_axis_dma_read_desc_ram_sel  <= '0;
          m_axis_dma_read_desc_ram_addr <= '0;
          m_axis_dma_read_desc_len      <= this_len;
          m_axis_dma_read_desc_tag      <= TAG_RD;
          m_axis_dma_read_desc_valid    <= 1'b1;
          cur_len <= this_len;
          if (m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready) begin
            m_axis_dma_read_desc_valid <= 1'b0;
            state <= X_CPY_RDW;
          end
        end
        X_CPY_RDW: begin
          if (s_axis_dma_read_desc_status_valid &&
              s_axis_dma_read_desc_status_tag == TAG_RD) state <= X_CPY_WD;
        end
        X_CPY_WD: begin
          m_axis_dma_write_desc_dma_addr <= cur_dst;
          m_axis_dma_write_desc_ram_sel  <= '0;
          m_axis_dma_write_desc_ram_addr <= '0;
          m_axis_dma_write_desc_imm      <= '0;
          m_axis_dma_write_desc_imm_en   <= 1'b0;
          m_axis_dma_write_desc_len      <= cur_len;
          m_axis_dma_write_desc_tag      <= TAG_WR;
          m_axis_dma_write_desc_valid    <= 1'b1;
          if (m_axis_dma_write_desc_valid && m_axis_dma_write_desc_ready) begin
            m_axis_dma_write_desc_valid <= 1'b0;
            state <= X_CPY_WW;
          end
        end
        X_CPY_WW: begin
          if (s_axis_dma_write_desc_status_valid &&
              s_axis_dma_write_desc_status_tag == TAG_WR) begin
            cur_dst <= cur_dst + cur_len;
            cur_src <= cur_src + cur_len;
            if (cur_cpy_remaining <= cur_len) begin
              cpy_done <= 1'b1;
              state    <= X_IDLE;
            end else begin
              cur_cpy_remaining <= cur_cpy_remaining - cur_len;
              state <= X_CPY_RD;
            end
          end
        end

        // ----- CAS / CAA: read, modify in scratch, write back ---------
        X_AT_RD: begin
          m_axis_dma_read_desc_dma_addr <= cur_host_addr;
          m_axis_dma_read_desc_ram_sel  <= '0;
          m_axis_dma_read_desc_ram_addr <= '0;
          m_axis_dma_read_desc_len      <= 16'd8;
          m_axis_dma_read_desc_tag      <= TAG_RD;
          m_axis_dma_read_desc_valid    <= 1'b1;
          if (m_axis_dma_read_desc_valid && m_axis_dma_read_desc_ready) begin
            m_axis_dma_read_desc_valid <= 1'b0;
            state <= X_AT_RDW;
          end
        end
        X_AT_RDW: begin
          if (s_axis_dma_read_desc_status_valid &&
              s_axis_dma_read_desc_status_tag == TAG_RD) state <= X_AT_MOD;
        end
        X_AT_MOD: begin
          atom_data  <= scratch[0];
          atom_valid <= 1'b1;
          if (cur_caa) begin
            scratch[0] <= scratch[0] + cur_atom_exp;
          end else if (scratch[0] == cur_atom_exp) begin
            scratch[0] <= cur_atom_swap;
          end
          state <= X_WR_DESC;            // reuse write-back path
        end
        default: state <= X_IDLE;
      endcase
    end
  end

endmodule
