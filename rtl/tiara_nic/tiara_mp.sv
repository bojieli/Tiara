// Tiara Memory Processor (MP)
//
// Lightweight scalar core with a 16x64b register file, an integer ALU,
// a private 1024-entry instruction store, and a single-port memory
// interface to the shared memory subsystem.  No branch prediction, no
// out-of-order, no data cache.  Targets ~200 MHz on Alveo U50.
//
// Pipeline (functional, not micro-architectural):
//   IDLE   -> FETCH1
//   FETCH1 -> (single-word op) EXECUTE
//          -> (two-word op) FETCH2 -> EXECUTE
//   EXECUTE -> issues memory request if needed; otherwise writeback and
//              advance PC in the same cycle.  For ops that need data
//              back (LOAD, CAS, CAA, sync MEMCPY) we transition to
//              MEM_WAIT and stall there for `sync_valid`.  For async
//              MEMCPY we transition to MEM_ASYNC briefly to capture the
//              `accept` pulse, then go straight back to FETCH1.
//   WAIT   -> stall while inflight > threshold.
//   DONE   -> latch return values, raise `task_done`.

`include "tiara_pkg.svh"

module tiara_mp
  import tiara_pkg::*;
#(
    parameter int unsigned MP_ID = 0
)
(
    input  logic                  clk,
    input  logic                  rst_n,

    // Task dispatch ----------------------------------------------------
    input  logic                                            task_start,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0]            task_start_pc,
    input  logic [63:0]                                     task_args [0:7],
    output logic                                            task_done,
    output logic [63:0]                                     task_result [0:3],
    output logic                                            task_err,

    // Instruction store side (write at registration) ------------------
    input  logic                                wr_en,
    input  logic [$clog2(INSTR_STORE_DEPTH)-1:0] wr_addr,
    input  logic [63:0]                          wr_data,

    // Memory subsystem -------------------------------------------------
    tiara_mem_if.mp               mem,

    // Telemetry --------------------------------------------------------
    output logic [31:0]           cycles_executed,
    output logic [31:0]           instr_retired
);

  // -------------------------------------------------------------------
  // Architectural state
  // -------------------------------------------------------------------
  localparam int PC_W = $clog2(INSTR_STORE_DEPTH);

  typedef enum logic [3:0] {
      S_IDLE      = 4'd0,
      S_FETCH1    = 4'd1,
      S_FETCH1_W  = 4'd2,
      S_FETCH2    = 4'd3,
      S_FETCH2_W  = 4'd4,
      S_EXECUTE   = 4'd5,
      S_MEM_WAIT  = 4'd6,
      S_MEM_ASYNC = 4'd7,
      S_WAIT      = 4'd8,
      S_MUL_WAIT  = 4'd9,    // 2-cycle pipelined MUL: stall one cycle
      S_DONE      = 4'd10,
      S_FAULT     = 4'd11
  } state_e;

  state_e state, next_state;

  logic [PC_W-1:0]  pc, next_pc;
  logic [5:0]       inflight;
  logic [3:0]       wait_threshold;

  // Latched instruction words
  logic [63:0]      iw0, iw1;
  logic             have_iw1;

  // Decoded fields (combinational from iw0)
  logic [7:0]       op;
  logic [3:0]       rd, rs1, rs2, sub;
  logic [63:0]      imm_signed;
  // Two-word follow-on
  logic [3:0]       rd2, rs1_2, rs2_2, sub2;
  logic [63:0]      imm2_signed;

  function automatic logic [63:0] sext40(logic [39:0] v);
    sext40 = {{24{v[39]}}, v};
  endfunction

  always_comb begin
    op   = iw0[63:56];
    rd   = iw0[55:52];
    rs1  = iw0[51:48];
    rs2  = iw0[47:44];
    sub  = iw0[43:40];
    imm_signed = sext40(iw0[39:0]);

    rd2  = iw1[55:52];
    rs1_2= iw1[51:48];
    rs2_2= iw1[47:44];
    sub2 = iw1[43:40];
    imm2_signed = sext40(iw1[39:0]);
  end

  // -------------------------------------------------------------------
  // Instruction store
  // -------------------------------------------------------------------
  logic            ifetch_en;
  logic [PC_W-1:0] ifetch_addr;
  logic [63:0]     ifetch_data;
  logic            ifetch_valid;

  tiara_istore #(.DEPTH(INSTR_STORE_DEPTH)) u_istore (
      .clk     (clk),
      .wr_en   (wr_en),
      .wr_addr (wr_addr),
      .wr_data (wr_data),
      .rd_en   (ifetch_en),
      .rd_addr (ifetch_addr),
      .rd_data (ifetch_data),
      .rd_valid(ifetch_valid)
  );

  // -------------------------------------------------------------------
  // Register file
  // -------------------------------------------------------------------
  logic [3:0]   rf_ra_idx, rf_rb_idx;
  logic [63:0]  rf_ra, rf_rb;
  logic         rf_we;
  logic [3:0]   rf_w_idx;
  logic [63:0]  rf_w_data;
  logic         rf_bulk_clear;
  logic         args_loaded;

  logic [63:0] r1_v, r2_v, r3_v, r4_v;
  tiara_regfile u_rf (
      .clk        (clk),
      .rst_n      (rst_n),
      .ra_idx     (rf_ra_idx),
      .ra_data    (rf_ra),
      .rb_idx     (rf_rb_idx),
      .rb_data    (rf_rb),
      .we         (rf_we),
      .w_idx      (rf_w_idx),
      .w_data     (rf_w_data),
      .bulk_clear (rf_bulk_clear),
      .r1_out     (r1_v),
      .r2_out     (r2_v),
      .r3_out     (r3_v),
      .r4_out     (r4_v)
  );

  // -------------------------------------------------------------------
  // ALU
  // -------------------------------------------------------------------
  logic [63:0] alu_y;
  logic        alu_z, alu_n;
  logic        mul_issue;
  tiara_alu u_alu (
      .clk      (clk),
      .rst_n    (rst_n),
      .sub      (sub),
      .mul_issue(mul_issue),
      .rs1      (rf_ra),
      .rs2      (rf_rb),
      .imm      (imm_signed),
      .result   (alu_y),
      .z_flag   (alu_z),
      .n_flag   (alu_n)
  );

  // -------------------------------------------------------------------
  // Loop stack
  // -------------------------------------------------------------------
  logic                ls_push, ls_pop, ls_dec, ls_flush;
  logic [PC_W-1:0]     ls_in_begin, ls_in_end;
  logic [31:0]         ls_in_remain;
  logic                ls_empty, ls_full;
  logic [PC_W-1:0]     ls_top_begin, ls_top_end;
  logic [31:0]         ls_top_remain;

  tiara_loop_stack #(.PC_W(PC_W)) u_ls (
      .clk          (clk),
      .rst_n        (rst_n),
      .flush        (ls_flush),
      .push         (ls_push),
      .in_begin_pc  (ls_in_begin),
      .in_end_pc    (ls_in_end),
      .in_remaining (ls_in_remain),
      .pop          (ls_pop),
      .decrement    (ls_dec),
      .empty        (ls_empty),
      .full         (ls_full),
      .top_begin_pc (ls_top_begin),
      .top_end_pc   (ls_top_end),
      .top_remaining(ls_top_remain)
  );

  // -------------------------------------------------------------------
  // Argument load helper.  When task_start fires we copy task_args[0..7]
  // into r0..r7.  This takes 8 cycles using a small counter.
  // -------------------------------------------------------------------
  logic [3:0] arg_idx;

  // -------------------------------------------------------------------
  // Main FSM
  // -------------------------------------------------------------------
  logic       advance_pc;
  logic [PC_W-1:0] adv_target_pc;
  logic       use_target;
  logic       pc_will_advance;
  logic [PC_W-1:0] linear_next_pc;
  logic [PC_W-1:0] raw_next_pc;
  logic [PC_W-1:0] adjusted_next_pc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      pc            <= '0;
      inflight      <= '0;
      wait_threshold<= '0;
      iw0           <= '0;
      iw1           <= '0;
      have_iw1      <= 1'b0;
      task_done     <= 1'b0;
      task_err      <= 1'b0;
      args_loaded   <= 1'b0;
      arg_idx       <= '0;
      cycles_executed <= '0;
      instr_retired   <= '0;
      for (int i = 0; i < 4; i++) task_result[i] <= 64'd0;
    end else begin
      cycles_executed <= cycles_executed + 1'b1;

      // Inflight tracking
      // Async MEMCPY in-flight tracking.  cpy_accept can pulse one
      // cycle after cpy_en (i.e. while the MP is in S_MEM_ASYNC, where
      // mem.cpy_async has dropped back to 0 by default).  We therefore
      // use the FSM state as the truth source: any cpy_accept while
      // we're in S_MEM_ASYNC came from an *async* MEMCPY (sync ones
      // would have transitioned to S_MEM_WAIT instead).
      if (mem.cpy_accept && (state == S_MEM_ASYNC ||
                              (state == S_EXECUTE && mem.cpy_async))) begin
        inflight <= inflight + 1'b1;
      end
      if (mem.cpy_done) begin
        if (inflight != '0) inflight <= inflight - 1'b1;
      end

      task_done <= 1'b0;
      state     <= next_state;

      unique case (state)
        S_IDLE: begin
          if (task_start) begin
            // Start at the operator's registered offset.  When only
            // one operator is loaded, callers pass task_start_pc=0
            // and the operator lives at istore[0..N-1].
            pc            <= task_start_pc;
            args_loaded   <= 1'b0;
            arg_idx       <= '0;
            inflight      <= '0;
            task_err      <= 1'b0;
            for (int i = 0; i < 4; i++) task_result[i] <= 64'd0;
          end
        end
        S_FETCH1, S_FETCH1_W: begin
          if (ifetch_valid && state == S_FETCH1_W) begin
            iw0      <= ifetch_data;
            have_iw1 <= 1'b0;
          end
        end
        S_FETCH2, S_FETCH2_W: begin
          if (ifetch_valid && state == S_FETCH2_W) begin
            iw1      <= ifetch_data;
            have_iw1 <= 1'b1;
          end
        end
        S_EXECUTE: begin
          if (advance_pc) begin
            pc <= adjusted_next_pc;
            instr_retired <= instr_retired + 1'b1;
          end
          if (op == OP_WAIT) begin
            wait_threshold <= sub == 4'd0 ? imm_signed[3:0] : '0;
          end
        end
        S_MEM_WAIT: begin
          if (mem.sync_valid) begin
            instr_retired <= instr_retired + 1'b1;
            pc <= adjusted_next_pc;
            if (mem.sync_err) task_err <= 1'b1;
          end
        end
        S_MEM_ASYNC: begin
          if (mem.cpy_accept) begin
            instr_retired <= instr_retired + 1'b1;
            pc <= adjusted_next_pc;
          end
        end
        S_WAIT: begin
          if (inflight <= wait_threshold) begin
            instr_retired <= instr_retired + 1'b1;
            pc <= adjusted_next_pc;
          end
        end
        S_MUL_WAIT: begin
          instr_retired <= instr_retired + 1'b1;
          pc <= adjusted_next_pc;
        end
        S_DONE: begin
          task_done <= 1'b1;
        end
        default: ;
      endcase

      // Argument loading: a small counter that runs once per task.
      if (state == S_IDLE && task_start) begin
        args_loaded <= 1'b0;
        arg_idx     <= 4'd0;
      end else if (!args_loaded && state != S_IDLE) begin
        if (arg_idx == 4'd7) args_loaded <= 1'b1;
        arg_idx <= arg_idx + 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------
  // Combinational next-state and datapath control
  // -------------------------------------------------------------------
  always_comb begin
    next_state = state;
    advance_pc = 1'b0;
    use_target = 1'b0;
    adv_target_pc = pc + 1'b1;

    ifetch_en   = 1'b0;
    ifetch_addr = pc;

    // default mem/regfile signals
    mem.ld_en = 1'b0; mem.st_en = 1'b0;
    mem.cpy_en = 1'b0; mem.cas_en = 1'b0; mem.caa_mode = 1'b0;
    mem.cpy_async = 1'b0;
    mem.ld_addr = '0; mem.st_addr = '0; mem.st_data = '0;
    mem.cpy_dst_addr = '0; mem.cpy_src_addr = '0; mem.cpy_len = '0;
    mem.atom_addr = '0; mem.atom_expected = '0; mem.atom_swap = '0;

    rf_ra_idx = rs1;
    rf_rb_idx = rs2;
    rf_we     = 1'b0;
    rf_w_idx  = rd;
    rf_w_data = '0;
    rf_bulk_clear = 1'b0;
    mul_issue     = 1'b0;

    ls_push = 1'b0; ls_pop = 1'b0; ls_dec = 1'b0; ls_flush = 1'b0;
    ls_in_begin = '0; ls_in_end = '0; ls_in_remain = '0;

    case (state)
      S_IDLE: begin
        if (task_start) begin
          rf_bulk_clear = 1'b1;
          next_state    = S_FETCH1;
        end
      end

      S_FETCH1: begin
        // Argument loading: write task_args[arg_idx] to register arg_idx+1
        // (r1..r8 hold incoming arguments; r0 stays hard-wired to zero).
        // We stay in this state for 8 cycles, then on the cycle after the
        // last write `args_loaded` is set and we issue the instruction
        // fetch.
        if (!args_loaded) begin
          rf_we     = 1'b1;
          rf_w_idx  = arg_idx + 4'd1;
          rf_w_data = task_args[arg_idx];
          next_state = S_FETCH1;
        end else begin
          ifetch_en  = 1'b1;
          next_state = S_FETCH1_W;
        end
      end

      S_FETCH1_W: begin
        // capture and decide if we need a second word
        if (ifetch_valid) begin
          if (ifetch_data[63] == 1'b1) begin
            // two-word op: fetch the next word
            next_state = S_FETCH2;
          end else begin
            next_state = S_EXECUTE;
          end
        end
      end

      S_FETCH2: begin
        ifetch_en   = 1'b1;
        ifetch_addr = pc + 1'b1;
        next_state  = S_FETCH2_W;
      end

      S_FETCH2_W: begin
        if (ifetch_valid) next_state = S_EXECUTE;
      end

      S_EXECUTE: begin
        unique case (op)
          OP_NOP: begin
            advance_pc = 1'b1;
            next_state = S_FETCH1;
          end

          OP_COMPUTE: begin
            // MUL takes one extra cycle through the pipelined ALU.
            if (sub == SUB_MUL) begin
              mul_issue  = 1'b1;
              next_state = S_MUL_WAIT;
            end else begin
              rf_we      = 1'b1;
              rf_w_idx   = rd;
              rf_w_data  = alu_y;
              advance_pc = 1'b1;
              next_state = S_FETCH1;
            end
          end

          OP_LOAD: begin
            mem.ld_en   = 1'b1;
            mem.ld_addr = rf_ra + imm_signed;
            if (mem.ready) next_state = S_MEM_WAIT;
          end

          OP_STORE: begin
            mem.st_en   = 1'b1;
            mem.st_addr = rf_ra + imm_signed;
            mem.st_data = rf_rb;
            if (mem.ready) begin
              advance_pc = 1'b1;
              next_state = S_FETCH1;
            end
          end

          OP_MEMCPY: begin
            mem.cpy_en       = 1'b1;
            mem.cpy_async    = (sub & MEMCPY_FLAG_ASYNC) != 4'h0;
            mem.cpy_dst_addr = rf_ra;
            mem.cpy_src_addr = rf_rb;
            mem.cpy_len      = imm_signed[31:0];
            if (mem.ready) begin
              if (mem.cpy_async) next_state = S_MEM_ASYNC;
              else               next_state = S_MEM_WAIT;
            end
          end

          OP_CAS: begin
            mem.cas_en        = 1'b1;
            mem.caa_mode      = 1'b0;
            mem.atom_addr     = rf_ra;
            mem.atom_expected = rf_rb;
            // rs2 of follow-on word holds the new value register index
            mem.atom_swap     = '0;  // overridden by the second-word read
            if (mem.ready) next_state = S_MEM_WAIT;
          end

          OP_CAA: begin
            mem.cas_en        = 1'b1;
            mem.caa_mode      = 1'b1;
            mem.atom_addr     = rf_ra;
            mem.atom_expected = rf_rb;
            if (mem.ready) next_state = S_MEM_WAIT;
          end

          OP_JUMP: begin
            // forward-only: imm_signed > 0 enforced by verifier; we
            // re-check at runtime: if imm_signed <= 0 we ignore.
            if (rf_ra != 64'd0 && imm_signed[63] == 1'b0 && imm_signed != 64'd0) begin
              use_target    = 1'b1;
              adv_target_pc = pc + imm_signed[PC_W-1:0];
            end
            advance_pc = 1'b1;
            next_state = S_FETCH1;
          end

          OP_LOOP: begin
            ls_push      = !ls_full && (rf_ra != 64'd0);
            ls_in_begin  = pc + 1'b1;
            ls_in_end    = pc + imm_signed[PC_W-1:0] + 1'b1;
            ls_in_remain = (rf_ra != 64'd0) ? rf_ra[31:0] - 32'd1 : 32'd0;
            advance_pc   = 1'b1;
            next_state   = S_FETCH1;
          end

          OP_WAIT: begin
            // imm[3:0] used as threshold (small values only)
            advance_pc = 1'b1;
            next_state = S_WAIT;
          end

          OP_RET: begin
            next_state = S_DONE;
          end

          default: begin
            next_state = S_FAULT;
          end
        endcase
      end

      S_MEM_WAIT: begin
        if (mem.sync_valid) begin
          // Writeback for ops that produce a value.
          if (op == OP_LOAD || op == OP_CAS || op == OP_CAA) begin
            rf_we     = 1'b1;
            rf_w_idx  = rd;
            rf_w_data = mem.sync_data;
          end
          if (op == OP_MEMCPY) begin
            // status to rd
            rf_we     = 1'b1;
            rf_w_idx  = rd;
            rf_w_data = mem.sync_err ? 64'd1 : 64'd0;
          end
          next_state = S_FETCH1;
        end
      end

      S_MEM_ASYNC: begin
        if (mem.cpy_accept) begin
          rf_we     = 1'b1;
          rf_w_idx  = rd;
          rf_w_data = mem.cpy_err ? 64'd1 : 64'd0;
          next_state = S_FETCH1;
        end
      end

      S_WAIT: begin
        if (inflight <= wait_threshold) begin
          next_state = S_FETCH1;
        end
      end

      S_MUL_WAIT: begin
        // After one cycle the pipelined product is ready in alu_y.
        rf_we      = 1'b1;
        rf_w_idx   = rd;
        rf_w_data  = alu_y;
        advance_pc = 1'b1;
        next_state = S_FETCH1;
      end

      S_DONE: begin
        // hold one cycle, then return to idle
        next_state = S_IDLE;
      end

      S_FAULT: begin
        next_state = S_DONE;
      end

      default: next_state = S_IDLE;
    endcase

    // ----- Centralized PC advance + loop-end fix-up --------------------
    // For two-word ops the linear successor is +2; otherwise +1.  JUMP
    // and LOOP can override via use_target.
    linear_next_pc = (op == OP_MEMCPY || op == OP_CAS || op == OP_CAA)
                     ? pc + 2'd2 : pc + 1'd1;
    raw_next_pc    = use_target ? adv_target_pc : linear_next_pc;
    adjusted_next_pc = raw_next_pc;

    // pc_will_advance is true on the cycle we will commit a new PC.
    pc_will_advance = (state == S_EXECUTE && advance_pc)
                    || (state == S_MEM_WAIT  && mem.sync_valid)
                    || (state == S_MEM_ASYNC && mem.cpy_accept)
                    || (state == S_WAIT      && (inflight <= wait_threshold))
                    || (state == S_MUL_WAIT);

    // End-of-loop: only adjust on the cycle that actually advances PC.
    if (pc_will_advance && !ls_empty && (raw_next_pc == ls_top_end)) begin
      if (ls_top_remain != '0) begin
        ls_dec           = 1'b1;
        adjusted_next_pc = ls_top_begin;
      end else begin
        ls_pop = 1'b1;
      end
    end
  end

  // -------------------------------------------------------------------
  // Result readout: r0..r3 are continuously exposed by the regfile.
  // -------------------------------------------------------------------
  always_comb begin
    task_result[0] = r1_v;
    task_result[1] = r2_v;
    task_result[2] = r3_v;
    task_result[3] = r4_v;
  end

endmodule
