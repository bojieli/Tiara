// Tiara memory subsystem
//
// Bridges a single MP's `tiara_mem_if` to the PCIe DMA engine (local
// device 0) and the RDMA engine (any non-zero device id).  Routing is
// purely combinational on the address's `device_id` field.
//
// Functional simplification: each memory subsystem instance services a
// single MP.  In a real NIC, multiple MPs would share both engines
// through an arbiter; for the cycle-accurate per-MP timing measurements
// the paper reports, a 1:1 binding is sufficient and avoids spurious
// arbitration jitter.  The throughput-vs-MPs scaling reported in the
// paper is reproduced by the analytical model in `eval/`.

`include "tiara_pkg.svh"

module tiara_memory_subsystem
  import tiara_pkg::*;
#(
    parameter int unsigned LOCAL_LATENCY_CYCLES = 150,   // 0.75 µs @ 200 MHz
    parameter int unsigned RTT_CYCLES           = 500,   // 2.5  µs @ 200 MHz
    parameter int unsigned NUM_PEERS            = 4,
    parameter int unsigned LOCAL_MEM_DEPTH      = 1 << 19,  // sim default
    parameter int unsigned PEER_MEM_DEPTH       = 1 << 17   // sim default
)
(
    input  logic        clk,
    input  logic        rst_n,

    tiara_mem_if.mem    mem
);

  // Decode the unified 64-bit address into device_id / region_id /
  // offset.  region_id is currently informational; the offset directly
  // maps into the backing memory of the chosen device.
  function automatic logic [15:0] dev_of(logic [63:0] a);
    dev_of = a[63:48];
  endfunction
  function automatic logic [31:0] off_of(logic [63:0] a);
    off_of = a[31:0];
  endfunction

  // -------------------------------------------------------------------
  // PCIe DMA (device 0)
  // -------------------------------------------------------------------
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
  logic                  pdma_cpy_accept;
  logic                  pdma_cpy_done;

  logic                  pdma_atom_en;
  logic                  pdma_atom_caa;
  logic [31:0]           pdma_atom_addr;
  logic [63:0]           pdma_atom_expected;
  logic [63:0]           pdma_atom_swap;
  logic                  pdma_atom_valid;
  logic [63:0]           pdma_atom_data;

  logic                  pdma_ready;

  tiara_pcie_dma #(
      .LATENCY_CYCLES(LOCAL_LATENCY_CYCLES),
      .MEM_DEPTH     (LOCAL_MEM_DEPTH)
  )
  u_pdma (
      .clk          (clk),
      .rst_n        (rst_n),
      .rd_en        (pdma_rd_en),
      .rd_addr      (pdma_rd_addr),
      .rd_valid     (pdma_rd_valid),
      .rd_data      (pdma_rd_data),
      .rd_err       (pdma_rd_err),
      .wr_en        (pdma_wr_en),
      .wr_addr      (pdma_wr_addr),
      .wr_data      (pdma_wr_data),
      .wr_done      (pdma_wr_done),
      .cpy_en       (pdma_cpy_en),
      .cpy_dst      (pdma_cpy_dst),
      .cpy_src      (pdma_cpy_src),
      .cpy_len      (pdma_cpy_len),
      .cpy_accept   (pdma_cpy_accept),
      .cpy_done     (pdma_cpy_done),
      .atom_en      (pdma_atom_en),
      .atom_caa     (pdma_atom_caa),
      .atom_addr    (pdma_atom_addr),
      .atom_expected(pdma_atom_expected),
      .atom_swap    (pdma_atom_swap),
      .atom_valid   (pdma_atom_valid),
      .atom_data    (pdma_atom_data),
      .ready        (pdma_ready)
  );

  // -------------------------------------------------------------------
  // RDMA engine (any non-zero device)
  // -------------------------------------------------------------------
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

  logic                  rdma_cpy_en;
  logic                  rdma_cpy_async;
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

  tiara_rdma_engine #(
      .RTT_CYCLES(RTT_CYCLES),
      .NUM_PEERS (NUM_PEERS),
      .MEM_DEPTH (PEER_MEM_DEPTH)
  ) u_rdma (
      .clk          (clk),
      .rst_n        (rst_n),
      .rd_en        (rdma_rd_en),
      .rd_dev       (rdma_rd_dev),
      .rd_addr      (rdma_rd_addr),
      .rd_valid     (rdma_rd_valid),
      .rd_data      (rdma_rd_data),
      .rd_err       (rdma_rd_err),
      .wr_en        (rdma_wr_en),
      .wr_dev       (rdma_wr_dev),
      .wr_addr      (rdma_wr_addr),
      .wr_data      (rdma_wr_data),
      .wr_done      (rdma_wr_done),
      .cpy_en       (rdma_cpy_en),
      .cpy_async    (rdma_cpy_async),
      .cpy_dst_dev  (rdma_cpy_dst_dev),
      .cpy_dst_addr (rdma_cpy_dst_addr),
      .cpy_src_dev  (rdma_cpy_src_dev),
      .cpy_src_addr (rdma_cpy_src_addr),
      .cpy_len      (rdma_cpy_len),
      .cpy_accept   (rdma_cpy_accept),
      .cpy_done     (rdma_cpy_done),
      .cpy_err      (rdma_cpy_err),
      .atom_en      (rdma_atom_en),
      .atom_caa     (rdma_atom_caa),
      .atom_dev     (rdma_atom_dev),
      .atom_addr    (rdma_atom_addr),
      .atom_expected(rdma_atom_expected),
      .atom_swap    (rdma_atom_swap),
      .atom_valid   (rdma_atom_valid),
      .atom_data    (rdma_atom_data),
      .ready        (rdma_ready)
  );

  // -------------------------------------------------------------------
  // Route from `mem` interface to PDMA / RDMA based on device_id.
  // -------------------------------------------------------------------
  wire is_local_ld   = (dev_of(mem.ld_addr)      == 16'd0);
  wire is_local_st   = (dev_of(mem.st_addr)      == 16'd0);
  wire is_local_cpy  = (dev_of(mem.cpy_dst_addr) == 16'd0)
                    && (dev_of(mem.cpy_src_addr) == 16'd0);
  wire is_local_atom = (dev_of(mem.atom_addr)    == 16'd0);

  // PCIe DMA wires
  assign pdma_rd_en        = mem.ld_en  && is_local_ld;
  assign pdma_rd_addr      = off_of(mem.ld_addr);
  assign pdma_wr_en        = mem.st_en  && is_local_st;
  assign pdma_wr_addr      = off_of(mem.st_addr);
  assign pdma_wr_data      = mem.st_data;
  assign pdma_cpy_en       = mem.cpy_en && is_local_cpy;
  assign pdma_cpy_dst      = off_of(mem.cpy_dst_addr);
  assign pdma_cpy_src      = off_of(mem.cpy_src_addr);
  assign pdma_cpy_len      = mem.cpy_len;
  assign pdma_atom_en      = mem.cas_en && is_local_atom;
  assign pdma_atom_caa     = mem.caa_mode;
  assign pdma_atom_addr    = off_of(mem.atom_addr);
  assign pdma_atom_expected= mem.atom_expected;
  assign pdma_atom_swap    = mem.atom_swap;

  // RDMA wires
  assign rdma_rd_en        = mem.ld_en  && !is_local_ld;
  assign rdma_rd_dev       = dev_of(mem.ld_addr);
  assign rdma_rd_addr      = off_of(mem.ld_addr);
  assign rdma_wr_en        = mem.st_en  && !is_local_st;
  assign rdma_wr_dev       = dev_of(mem.st_addr);
  assign rdma_wr_addr      = off_of(mem.st_addr);
  assign rdma_wr_data      = mem.st_data;
  assign rdma_cpy_en       = mem.cpy_en && !is_local_cpy;
  assign rdma_cpy_async    = mem.cpy_async;
  assign rdma_cpy_dst_dev  = dev_of(mem.cpy_dst_addr);
  assign rdma_cpy_dst_addr = off_of(mem.cpy_dst_addr);
  assign rdma_cpy_src_dev  = dev_of(mem.cpy_src_addr);
  assign rdma_cpy_src_addr = off_of(mem.cpy_src_addr);
  assign rdma_cpy_len      = mem.cpy_len;
  assign rdma_atom_en      = mem.cas_en && !is_local_atom;
  assign rdma_atom_caa     = mem.caa_mode;
  assign rdma_atom_dev     = dev_of(mem.atom_addr);
  assign rdma_atom_addr    = off_of(mem.atom_addr);
  assign rdma_atom_expected= mem.atom_expected;
  assign rdma_atom_swap    = mem.atom_swap;

  // Combine status / completions
  assign mem.ready       = pdma_ready & rdma_ready;
  assign mem.sync_valid  = pdma_rd_valid | pdma_atom_valid | pdma_wr_done
                         | rdma_rd_valid | rdma_atom_valid | rdma_wr_done
                         | (pdma_cpy_done & ~mem.cpy_async)
                         | (rdma_cpy_done & ~mem.cpy_async);
  assign mem.sync_data   = pdma_rd_valid    ? pdma_rd_data    :
                           rdma_rd_valid    ? rdma_rd_data    :
                           pdma_atom_valid  ? pdma_atom_data  :
                           rdma_atom_valid  ? rdma_atom_data  :
                                              64'd0;
  assign mem.sync_err    = pdma_rd_err | rdma_rd_err;

  assign mem.cpy_accept  = pdma_cpy_accept | rdma_cpy_accept;
  assign mem.cpy_done    = pdma_cpy_done   | rdma_cpy_done;
  assign mem.cpy_err     = rdma_cpy_err;

endmodule
