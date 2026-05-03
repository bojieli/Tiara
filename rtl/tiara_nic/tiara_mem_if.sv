// Tiara memory interface.
//
// One MP -> shared memory subsystem.  The memory subsystem dispatches by
// the address's `device_id` field: 0 -> local PCIe DMA to host DRAM,
// non-zero -> RDMA engine (peer host).
//
// Operations supported:
//   - LOAD64  (rd_en, addr -> rdata, rvalid)
//   - STORE64 (wr_en, addr, wdata)
//   - MEMCPY  (cpy_en, dst_addr, src_addr, length, async)
//   - CAS     (cas_en, addr, expected, swap -> rdata=old, rvalid)
//   - CAA     (caa_en, addr, addend       -> rdata=old, rvalid)
//
// Completion semantics:
//   - For sync ops, `rvalid` pulses when result is available; the MP
//     stalls until it sees `rvalid`.
//   - For async MEMCPY, `accept` pulses after the request is admitted
//     into the in-flight queue; `cpy_done` pulses when it finally
//     completes (used to decrement the MP's in-flight counter).
//
// Errors set `err` alongside `rvalid` / `cpy_done`.

`include "tiara_pkg.svh"

interface tiara_mem_if;
  // Issue side ----------------------------------------------------------
  logic        ld_en;
  logic [63:0] ld_addr;

  logic        st_en;
  logic [63:0] st_addr;
  logic [63:0] st_data;

  logic        cpy_en;
  logic        cpy_async;
  logic [63:0] cpy_dst_addr;
  logic [63:0] cpy_src_addr;
  logic [31:0] cpy_len;

  logic        cas_en;        // 0 = CAS, 1 = CAA when caa_mode set
  logic        caa_mode;
  logic [63:0] atom_addr;
  logic [63:0] atom_expected;  // CAS old value, or CAA addend
  logic [63:0] atom_swap;      // CAS new value (unused for CAA)

  logic        ready;          // memory is ready to accept the next req

  // Completion side -----------------------------------------------------
  logic        sync_valid;     // load / atom result valid this cycle
  logic [63:0] sync_data;
  logic        sync_err;

  logic        cpy_accept;     // async accept (one cycle after issue)
  logic        cpy_done;       // async completion
  logic        cpy_err;

  modport mp (
      output ld_en,  ld_addr,
      output st_en,  st_addr, st_data,
      output cpy_en, cpy_async, cpy_dst_addr, cpy_src_addr, cpy_len,
      output cas_en, caa_mode, atom_addr, atom_expected, atom_swap,
      input  ready,
      input  sync_valid, sync_data, sync_err,
      input  cpy_accept, cpy_done, cpy_err
  );

  modport mem (
      input  ld_en,  ld_addr,
      input  st_en,  st_addr, st_data,
      input  cpy_en, cpy_async, cpy_dst_addr, cpy_src_addr, cpy_len,
      input  cas_en, caa_mode, atom_addr, atom_expected, atom_swap,
      output ready,
      output sync_valid, sync_data, sync_err,
      output cpy_accept, cpy_done, cpy_err
  );
endinterface
