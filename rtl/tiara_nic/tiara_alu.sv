// Tiara ALU
//
// Pure combinational integer ALU used by every memory processor.
// The sub-opcode space matches `Sub` in `sw/asm/tiara_isa.py`.

`include "tiara_pkg.svh"

module tiara_alu
  import tiara_pkg::*;
(
    input  logic [3:0]  sub,
    input  logic [63:0] rs1,
    input  logic [63:0] rs2,
    input  logic [63:0] imm,    // sign-extended immediate (the 40-bit field
                                // already sign-extended by the decoder)
    output logic [63:0] result,
    output logic        z_flag, // result == 0
    output logic        n_flag  // result MSB
);

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
      SUB_MUL : result = rs1 * rs2;
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
