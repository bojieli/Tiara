// Tiara ALU
//
// Combinational integer ALU used by every memory processor.  All ops
// resolve in one cycle except MUL, which uses a 2-stage pipelined
// 64x64 -> 64 multiplier mapped to UltraScale+ DSP48E2 cascades.  The
// MP's FSM stalls one extra cycle on a MUL instruction before
// committing the result (see tiara_mp.sv :: S_MUL_WAIT).

`include "tiara_pkg.svh"

module tiara_alu
  import tiara_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [3:0]  sub,
    input  logic        mul_issue,    // pulse when MP starts a MUL
    input  logic [63:0] rs1,
    input  logic [63:0] rs2,
    input  logic [63:0] imm,    // sign-extended immediate (the 40-bit field
                                // already sign-extended by the decoder)
    output logic [63:0] result,
    output logic        z_flag, // result == 0
    output logic        n_flag  // result MSB
);

  // ---- 2-stage pipelined 64-bit multiplier ----------------------------
  // Stage 1: latch operands.  Stage 2: latch the product.  Vivado will
  // map the multiply through DSP48E2 cascades and uses the
  // input + output registers to close 200 MHz.
  (* use_dsp = "yes" *) logic [63:0] mul_a, mul_b, mul_pipe;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mul_a    <= 64'd0;
      mul_b    <= 64'd0;
      mul_pipe <= 64'd0;
    end else begin
      if (mul_issue) begin
        mul_a <= rs1;
        mul_b <= rs2;
      end
      mul_pipe <= mul_a * mul_b;
    end
  end

  // Reg-reg / reg-imm dispatch — `imm` doubles as the second operand for
  // the *I family.  Shift counts use only the bottom 6 bits.
  always_comb begin
    unique case (sub)
      SUB_ADD : result = rs1 + rs2;
      SUB_SUB : result = rs1 - rs2;
      SUB_AND : result = rs1 & rs2;
      SUB_OR  : result = rs1 | rs2;
      SUB_XOR : result = rs1 ^ rs2;
      SUB_SHL : result = rs1 << rs2[5:0];
      SUB_SHR : result = rs1 >> rs2[5:0];
      SUB_MUL : result = mul_pipe;     // pre-pipelined; see below
      SUB_ADDI: result = rs1 + imm;
      SUB_ANDI: result = rs1 & imm;
      SUB_SHLI: result = rs1 << imm[5:0];
      SUB_SHRI: result = rs1 >> imm[5:0];
      SUB_LI  : result = imm;
      SUB_EQ  : result = (rs1 == rs2) ? 64'd1 : 64'd0;
      SUB_LT  : result = (rs1  < rs2) ? 64'd1 : 64'd0;
      SUB_GE  : result = (rs1 >= rs2) ? 64'd1 : 64'd0;
      default : result = 64'd0;
    endcase
  end

  assign z_flag = (result == 64'd0);
  assign n_flag = result[63];

endmodule
