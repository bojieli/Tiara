// Tiara synthesis-only top, XDMA flavor.
//
// Same as `tiara_synth_top` but the local-memory engine is the
// descriptor-driven `tiara_xdma_engine` paired with the Verilator-only
// `tiara_xdma_host_stub`.  This proves the descriptor protocol against
// the existing Tiara MP without needing the full Corundum DMA fabric.

`include "tiara_pkg.svh"

module tiara_synth_top_xdma
  import tiara_pkg::*;
#(
    parameter int unsigned LOCAL_LATENCY_CYCLES = 150,
    parameter int unsigned RTT_CYCLES           = 500,
    parameter int unsigned LOCAL_MEM_DEPTH      = 1 << 19,
    parameter int unsigned PEER_MEM_DEPTH       = 1 << 17,
    parameter int unsigned NUM_PEERS            = 4
)
(
    input  logic                                 clk,
    input  logic                                 rst_n,

    input  logic                                 load_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] load_addr,
    input  logic [63:0]                          load_data,

    input  logic                                 inv_valid,
    input  logic [63:0]                          inv_args [0:7],
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] inv_start_pc,
    output logic                                 inv_busy,
    output logic                                 done,
    output logic [63:0]                          done_result [0:3],
    output logic                                 done_err,

    output logic [31:0]                          instr_retired
);

  // -----------------------------------------------------------------
  // MP <-> mem interface
  // -----------------------------------------------------------------
  tiara_mem_if mp_mem();

  // Engine-side ports (same naming as tiara_pcie_dma)
  logic                  pdma_rd_en;
  logic [31:0]           pdma_rd_addr;
  logic                  pdma_rd_valid;
  logic [63:0]           pdma_rd_data;
  logic                  pdma_rd_err;
  logic                  pdma_wr_en;
  logic [31:0]           pdma_wr_addr;
  logic [63:0]           pdma_wr_data;
  logic                  pdma_wr_done;
  logic                  pdma_cpy_en;
  logic [31:0]           pdma_cpy_dst, pdma_cpy_src;
  logic [31:0]           pdma_cpy_len;
  logic                  pdma_cpy_accept, pdma_cpy_done;
  logic                  pdma_atom_en, pdma_atom_caa;
  logic [31:0]           pdma_atom_addr;
  logic [63:0]           pdma_atom_expected, pdma_atom_swap;
  logic                  pdma_atom_valid;
  logic [63:0]           pdma_atom_data;
  logic                  pdma_ready;

  // Tie the simple memory subsystem's local-engine slot to the XDMA
  // engine.  Cross-device traffic still uses the existing RDMA engine.
  logic                  rdma_rd_en;
  logic [15:0]           rdma_rd_dev;
  logic [31:0]           rdma_rd_addr;
  logic                  rdma_rd_valid;
  logic [63:0]           rdma_rd_data;
  logic                  rdma_rd_err;
  logic                  rdma_wr_en;
  logic [15:0]           rdma_wr_dev;
  logic [31:0]           rdma_wr_addr;
  logic [63:0]           rdma_wr_data;
  logic                  rdma_wr_done;
  logic                  rdma_cpy_en, rdma_cpy_async;
  logic [15:0]           rdma_cpy_dst_dev, rdma_cpy_src_dev;
  logic [31:0]           rdma_cpy_dst_addr, rdma_cpy_src_addr;
  logic [31:0]           rdma_cpy_len;
  logic                  rdma_cpy_accept, rdma_cpy_done, rdma_cpy_err;
  logic                  rdma_atom_en, rdma_atom_caa;
  logic [15:0]           rdma_atom_dev;
  logic [31:0]           rdma_atom_addr;
  logic [63:0]           rdma_atom_expected, rdma_atom_swap;
  logic                  rdma_atom_valid;
  logic [63:0]           rdma_atom_data;
  logic                  rdma_ready;

  function automatic logic [15:0] dev_of(logic [63:0] a); dev_of = a[63:48]; endfunction
  function automatic logic [31:0] off_of(logic [63:0] a); off_of = a[31:0];  endfunction

  wire is_local_ld   = (dev_of(mp_mem.ld_addr)      == 16'd0);
  wire is_local_st   = (dev_of(mp_mem.st_addr)      == 16'd0);
  wire is_local_cpy  = (dev_of(mp_mem.cpy_dst_addr) == 16'd0)
                    && (dev_of(mp_mem.cpy_src_addr) == 16'd0);
  wire is_local_atom = (dev_of(mp_mem.atom_addr)    == 16'd0);

  assign pdma_rd_en        = mp_mem.ld_en  & is_local_ld;
  assign pdma_rd_addr      = off_of(mp_mem.ld_addr);
  assign pdma_wr_en        = mp_mem.st_en  & is_local_st;
  assign pdma_wr_addr      = off_of(mp_mem.st_addr);
  assign pdma_wr_data      = mp_mem.st_data;
  assign pdma_cpy_en       = mp_mem.cpy_en & is_local_cpy;
  assign pdma_cpy_dst      = off_of(mp_mem.cpy_dst_addr);
  assign pdma_cpy_src      = off_of(mp_mem.cpy_src_addr);
  assign pdma_cpy_len      = mp_mem.cpy_len;
  assign pdma_atom_en      = mp_mem.cas_en & is_local_atom;
  assign pdma_atom_caa     = mp_mem.caa_mode;
  assign pdma_atom_addr    = off_of(mp_mem.atom_addr);
  assign pdma_atom_expected= mp_mem.atom_expected;
  assign pdma_atom_swap    = mp_mem.atom_swap;

  assign rdma_rd_en        = mp_mem.ld_en  & ~is_local_ld;
  assign rdma_rd_dev       = dev_of(mp_mem.ld_addr);
  assign rdma_rd_addr      = off_of(mp_mem.ld_addr);
  assign rdma_wr_en        = mp_mem.st_en  & ~is_local_st;
  assign rdma_wr_dev       = dev_of(mp_mem.st_addr);
  assign rdma_wr_addr      = off_of(mp_mem.st_addr);
  assign rdma_wr_data      = mp_mem.st_data;
  assign rdma_cpy_en       = mp_mem.cpy_en & ~is_local_cpy;
  assign rdma_cpy_async    = mp_mem.cpy_async;
  assign rdma_cpy_dst_dev  = dev_of(mp_mem.cpy_dst_addr);
  assign rdma_cpy_dst_addr = off_of(mp_mem.cpy_dst_addr);
  assign rdma_cpy_src_dev  = dev_of(mp_mem.cpy_src_addr);
  assign rdma_cpy_src_addr = off_of(mp_mem.cpy_src_addr);
  assign rdma_cpy_len      = mp_mem.cpy_len;
  assign rdma_atom_en      = mp_mem.cas_en & ~is_local_atom;
  assign rdma_atom_caa     = mp_mem.caa_mode;
  assign rdma_atom_dev     = dev_of(mp_mem.atom_addr);
  assign rdma_atom_addr    = off_of(mp_mem.atom_addr);
  assign rdma_atom_expected= mp_mem.atom_expected;
  assign rdma_atom_swap    = mp_mem.atom_swap;

  assign mp_mem.ready       = pdma_ready & rdma_ready;
  assign mp_mem.sync_valid  = pdma_rd_valid | pdma_atom_valid | pdma_wr_done
                            | rdma_rd_valid | rdma_atom_valid | rdma_wr_done
                            | (pdma_cpy_done & ~mp_mem.cpy_async)
                            | (rdma_cpy_done & ~mp_mem.cpy_async);
  assign mp_mem.sync_data   = pdma_rd_valid    ? pdma_rd_data    :
                              rdma_rd_valid    ? rdma_rd_data    :
                              pdma_atom_valid  ? pdma_atom_data  :
                              rdma_atom_valid  ? rdma_atom_data  :
                                                 64'd0;
  assign mp_mem.sync_err    = pdma_rd_err | rdma_rd_err;
  assign mp_mem.cpy_accept  = pdma_cpy_accept | rdma_cpy_accept;
  assign mp_mem.cpy_done    = pdma_cpy_done   | rdma_cpy_done;
  assign mp_mem.cpy_err     = rdma_cpy_err;

  // -----------------------------------------------------------------
  // XDMA engine + host stub
  // -----------------------------------------------------------------
  localparam int unsigned DMA_ADDR_WIDTH  = 64;
  localparam int unsigned DMA_LEN_WIDTH   = 16;
  localparam int unsigned DMA_TAG_WIDTH   = 8;
  localparam int unsigned RAM_SEL_WIDTH   = 1;
  localparam int unsigned RAM_ADDR_WIDTH  = 12;
  localparam int unsigned RAM_SEG_COUNT   = 2;
  localparam int unsigned RAM_SEG_DATA_W  = 256;
  localparam int unsigned RAM_SEG_BE_W    = RAM_SEG_DATA_W/8;
  localparam int unsigned RAM_SEG_ADDR_W  = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_DATA_W/8);

  logic [DMA_ADDR_WIDTH-1:0]  rd_dma_addr;
  logic [RAM_SEL_WIDTH-1:0]   rd_ram_sel;
  logic [RAM_ADDR_WIDTH-1:0]  rd_ram_addr;
  logic [DMA_LEN_WIDTH-1:0]   rd_len;
  logic [DMA_TAG_WIDTH-1:0]   rd_tag;
  logic                       rd_valid_w, rd_ready_w;
  logic [DMA_TAG_WIDTH-1:0]   rd_st_tag;
  logic [3:0]                 rd_st_err;
  logic                       rd_st_valid;

  logic [DMA_ADDR_WIDTH-1:0]  wr_dma_addr;
  logic [RAM_SEL_WIDTH-1:0]   wr_ram_sel;
  logic [RAM_ADDR_WIDTH-1:0]  wr_ram_addr;
  logic [31:0]                wr_imm;
  logic                       wr_imm_en;
  logic [DMA_LEN_WIDTH-1:0]   wr_len;
  logic [DMA_TAG_WIDTH-1:0]   wr_tag;
  logic                       wr_valid_w, wr_ready_w;
  logic [DMA_TAG_WIDTH-1:0]   wr_st_tag;
  logic [3:0]                 wr_st_err;
  logic                       wr_st_valid;

  logic [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]   ram_wr_sel;
  logic [RAM_SEG_COUNT*RAM_SEG_BE_W-1:0]    ram_wr_be;
  logic [RAM_SEG_COUNT*RAM_SEG_ADDR_W-1:0]  ram_wr_addr;
  logic [RAM_SEG_COUNT*RAM_SEG_DATA_W-1:0]  ram_wr_data;
  logic [RAM_SEG_COUNT-1:0]                 ram_wr_valid;
  logic [RAM_SEG_COUNT-1:0]                 ram_wr_ready;
  logic [RAM_SEG_COUNT-1:0]                 ram_wr_done;
  logic [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]   ram_rd_sel;
  logic [RAM_SEG_COUNT*RAM_SEG_ADDR_W-1:0]  ram_rd_addr;
  logic [RAM_SEG_COUNT-1:0]                 ram_rd_valid;
  logic [RAM_SEG_COUNT-1:0]                 ram_rd_ready;
  logic [RAM_SEG_COUNT*RAM_SEG_DATA_W-1:0]  ram_rd_resp_data;
  logic [RAM_SEG_COUNT-1:0]                 ram_rd_resp_valid;
  logic [RAM_SEG_COUNT-1:0]                 ram_rd_resp_ready;

  tiara_xdma_engine #(
      .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
      .DMA_LEN_WIDTH (DMA_LEN_WIDTH),
      .DMA_TAG_WIDTH (DMA_TAG_WIDTH),
      .RAM_SEL_WIDTH (RAM_SEL_WIDTH),
      .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
      .RAM_SEG_COUNT (RAM_SEG_COUNT),
      .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_W)
  ) u_pdma (
      .clk(clk), .rst_n(rst_n),
      .rd_en   (pdma_rd_en),    .rd_addr   (pdma_rd_addr),
      .rd_valid(pdma_rd_valid), .rd_data   (pdma_rd_data), .rd_err(pdma_rd_err),
      .wr_en   (pdma_wr_en),    .wr_addr   (pdma_wr_addr), .wr_data(pdma_wr_data),
      .wr_done (pdma_wr_done),
      .cpy_en  (pdma_cpy_en),   .cpy_dst   (pdma_cpy_dst), .cpy_src(pdma_cpy_src),
      .cpy_len (pdma_cpy_len),  .cpy_accept(pdma_cpy_accept), .cpy_done(pdma_cpy_done),
      .atom_en (pdma_atom_en),  .atom_caa  (pdma_atom_caa),
      .atom_addr(pdma_atom_addr), .atom_expected(pdma_atom_expected),
      .atom_swap(pdma_atom_swap), .atom_valid(pdma_atom_valid),
      .atom_data(pdma_atom_data),
      .ready   (pdma_ready),
      .m_axis_dma_read_desc_dma_addr(rd_dma_addr),
      .m_axis_dma_read_desc_ram_sel (rd_ram_sel),
      .m_axis_dma_read_desc_ram_addr(rd_ram_addr),
      .m_axis_dma_read_desc_len     (rd_len),
      .m_axis_dma_read_desc_tag     (rd_tag),
      .m_axis_dma_read_desc_valid   (rd_valid_w),
      .m_axis_dma_read_desc_ready   (rd_ready_w),
      .s_axis_dma_read_desc_status_tag  (rd_st_tag),
      .s_axis_dma_read_desc_status_error(rd_st_err),
      .s_axis_dma_read_desc_status_valid(rd_st_valid),
      .m_axis_dma_write_desc_dma_addr(wr_dma_addr),
      .m_axis_dma_write_desc_ram_sel (wr_ram_sel),
      .m_axis_dma_write_desc_ram_addr(wr_ram_addr),
      .m_axis_dma_write_desc_imm     (wr_imm),
      .m_axis_dma_write_desc_imm_en  (wr_imm_en),
      .m_axis_dma_write_desc_len     (wr_len),
      .m_axis_dma_write_desc_tag     (wr_tag),
      .m_axis_dma_write_desc_valid   (wr_valid_w),
      .m_axis_dma_write_desc_ready   (wr_ready_w),
      .s_axis_dma_write_desc_status_tag  (wr_st_tag),
      .s_axis_dma_write_desc_status_error(wr_st_err),
      .s_axis_dma_write_desc_status_valid(wr_st_valid),
      .dma_ram_wr_cmd_sel  (ram_wr_sel),
      .dma_ram_wr_cmd_be   (ram_wr_be),
      .dma_ram_wr_cmd_addr (ram_wr_addr),
      .dma_ram_wr_cmd_data (ram_wr_data),
      .dma_ram_wr_cmd_valid(ram_wr_valid),
      .dma_ram_wr_cmd_ready(ram_wr_ready),
      .dma_ram_wr_done     (ram_wr_done),
      .dma_ram_rd_cmd_sel  (ram_rd_sel),
      .dma_ram_rd_cmd_addr (ram_rd_addr),
      .dma_ram_rd_cmd_valid(ram_rd_valid),
      .dma_ram_rd_cmd_ready(ram_rd_ready),
      .dma_ram_rd_resp_data(ram_rd_resp_data),
      .dma_ram_rd_resp_valid(ram_rd_resp_valid),
      .dma_ram_rd_resp_ready(ram_rd_resp_ready)
  );

  tiara_xdma_host_stub #(
      .MEM_DEPTH       (LOCAL_MEM_DEPTH),
      .LATENCY_CYCLES  (LOCAL_LATENCY_CYCLES),
      .RAM_SEG_COUNT   (RAM_SEG_COUNT),
      .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_W)
  ) u_pdma_host (
      .clk(clk), .rst_n(rst_n),
      .s_read_dma_addr (rd_dma_addr),
      .s_read_ram_sel  (rd_ram_sel),
      .s_read_ram_addr (rd_ram_addr),
      .s_read_len      (rd_len),
      .s_read_tag      (rd_tag),
      .s_read_valid    (rd_valid_w),
      .s_read_ready    (rd_ready_w),
      .m_read_status_tag  (rd_st_tag),
      .m_read_status_error(rd_st_err),
      .m_read_status_valid(rd_st_valid),
      .s_write_dma_addr(wr_dma_addr),
      .s_write_ram_sel (wr_ram_sel),
      .s_write_ram_addr(wr_ram_addr),
      .s_write_imm     (wr_imm),
      .s_write_imm_en  (wr_imm_en),
      .s_write_len     (wr_len),
      .s_write_tag     (wr_tag),
      .s_write_valid   (wr_valid_w),
      .s_write_ready   (wr_ready_w),
      .m_write_status_tag  (wr_st_tag),
      .m_write_status_error(wr_st_err),
      .m_write_status_valid(wr_st_valid),
      .m_ram_wr_cmd_sel  (ram_wr_sel),
      .m_ram_wr_cmd_be   (ram_wr_be),
      .m_ram_wr_cmd_addr (ram_wr_addr),
      .m_ram_wr_cmd_data (ram_wr_data),
      .m_ram_wr_cmd_valid(ram_wr_valid),
      .m_ram_wr_cmd_ready(ram_wr_ready),
      .m_ram_wr_done     (ram_wr_done),
      .m_ram_rd_cmd_sel  (ram_rd_sel),
      .m_ram_rd_cmd_addr (ram_rd_addr),
      .m_ram_rd_cmd_valid(ram_rd_valid),
      .m_ram_rd_cmd_ready(ram_rd_ready),
      .m_ram_rd_resp_data(ram_rd_resp_data),
      .m_ram_rd_resp_valid(ram_rd_resp_valid),
      .m_ram_rd_resp_ready(ram_rd_resp_ready)
  );

  // -----------------------------------------------------------------
  // RDMA engine for cross-device traffic (unchanged)
  // -----------------------------------------------------------------
  tiara_rdma_engine #(
      .RTT_CYCLES(RTT_CYCLES),
      .NUM_PEERS (NUM_PEERS),
      .MEM_DEPTH (PEER_MEM_DEPTH)
  ) u_rdma (
      .clk(clk), .rst_n(rst_n),
      .rd_en(rdma_rd_en), .rd_dev(rdma_rd_dev), .rd_addr(rdma_rd_addr),
      .rd_valid(rdma_rd_valid), .rd_data(rdma_rd_data), .rd_err(rdma_rd_err),
      .wr_en(rdma_wr_en), .wr_dev(rdma_wr_dev), .wr_addr(rdma_wr_addr),
      .wr_data(rdma_wr_data), .wr_done(rdma_wr_done),
      .cpy_en(rdma_cpy_en), .cpy_async(rdma_cpy_async),
      .cpy_dst_dev(rdma_cpy_dst_dev), .cpy_dst_addr(rdma_cpy_dst_addr),
      .cpy_src_dev(rdma_cpy_src_dev), .cpy_src_addr(rdma_cpy_src_addr),
      .cpy_len(rdma_cpy_len), .cpy_accept(rdma_cpy_accept),
      .cpy_done(rdma_cpy_done), .cpy_err(rdma_cpy_err),
      .atom_en(rdma_atom_en), .atom_caa(rdma_atom_caa),
      .atom_dev(rdma_atom_dev), .atom_addr(rdma_atom_addr),
      .atom_expected(rdma_atom_expected), .atom_swap(rdma_atom_swap),
      .atom_valid(rdma_atom_valid), .atom_data(rdma_atom_data),
      .ready(rdma_ready)
  );

  // -----------------------------------------------------------------
  // Dispatcher + MP
  // -----------------------------------------------------------------
  logic                                            mp_start;
  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            mp_start_pc;
  logic [63:0]                                     mp_args   [0:7];
  logic                                            mp_done_w;
  logic [63:0]                                     mp_result [0:3];
  logic                                            mp_err_w;
  logic [31:0]                                     mp_cycles;

  tiara_dispatcher u_disp (
      .clk(clk), .rst_n(rst_n),
      .inv_valid(inv_valid), .inv_args(inv_args),
      .inv_start_pc(inv_start_pc),
      .inv_busy(inv_busy),
      .done(done), .done_result(done_result), .done_err(done_err),
      .mp_start(mp_start), .mp_start_pc(mp_start_pc), .mp_args(mp_args),
      .mp_done(mp_done_w), .mp_result(mp_result), .mp_err(mp_err_w)
  );

  tiara_mp #(.MP_ID(0)) u_mp (
      .clk(clk), .rst_n(rst_n),
      .task_start(mp_start),
      .task_start_pc(mp_start_pc),
      .task_args(mp_args),
      .task_done(mp_done_w),
      .task_result(mp_result),
      .task_err(mp_err_w),
      .wr_en(load_en), .wr_addr(load_addr), .wr_data(load_data),
      .mem(mp_mem.mp),
      .cycles_executed(mp_cycles),
      .instr_retired(instr_retired)
  );

endmodule
