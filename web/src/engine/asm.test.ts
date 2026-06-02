/** Unit tests for the assembler: mnemonics, operands, labels, errors. */
import { describe, it, expect } from 'vitest';
import { assemble, AsmError, toHex } from './asm';
import { decodeWord, Op, Sub } from './isa';

function one(src: string) {
  const p = assemble(src, 't');
  return { p, d: decodeWord(p.words[0]) };
}

describe('mnemonics encode correctly', () => {
  it('LOAD with offset', () => {
    const { d } = one('LOAD r3, [r4 + 16]');
    expect(d.op).toBe(Op.LOAD);
    expect(d.rd).toBe(3);
    expect(d.rs1).toBe(4);
    expect(d.imm).toBe(16n);
  });
  it('LOAD with negative offset', () => {
    expect(one('LOAD r1, [r2 - 8]').d.imm).toBe(-8n);
  });
  it('STORE', () => {
    const { d } = one('STORE [r2 + 8], r5');
    expect(d.op).toBe(Op.STORE);
    expect(d.rs1).toBe(2);
    expect(d.rs2).toBe(5);
    expect(d.imm).toBe(8n);
  });
  it('LI hex and decimal', () => {
    expect(one('LI r1, 0x42').d.imm).toBe(0x42n);
    expect(one('LI r1, 66').d.imm).toBe(66n);
  });
  it('ADDI/ANDI/SHLI immediate forms', () => {
    expect(one('ADDI r1, r2, 4').d.sub).toBe(Sub.ADDI);
    expect(one('ANDI r1, r2, 0xFF').d.imm).toBe(0xffn);
    expect(one('SHLI r1, r2, 3').d.sub).toBe(Sub.SHLI);
  });
  it('register-register ALU', () => {
    const { d } = one('ADD r1, r2, r3');
    expect(d.op).toBe(Op.COMPUTE);
    expect(d.sub).toBe(Sub.ADD);
    expect(d.rs2).toBe(3);
  });
  it('CAS emits two words (rd,addr,exp,new)', () => {
    const p = assemble('CAS r9, r1, r7, r8', 't');
    expect(p.words).toHaveLength(2);
    const head = decodeWord(p.words[0]);
    const extra = decodeWord(p.words[1]);
    expect(head.op).toBe(Op.CAS);
    expect(head.rd).toBe(9);
    expect(head.rs1).toBe(1);
    expect(head.rs2).toBe(7);
    expect(extra.rd).toBe(8); // new value reg
  });
  it('MEMCPY flags and length', () => {
    const p = assemble('MEMCPY r0, r2, r3, ASYNC, LEN=4096', 't');
    const head = decodeWord(p.words[0]);
    expect(head.op).toBe(Op.MEMCPY);
    expect(head.sub & 1).toBe(1); // ASYNC bit
    expect(head.imm).toBe(4096n);
  });
  it('MEMCPY LEN_REG sets the length-from-reg flag', () => {
    const head = decodeWord(assemble('MEMCPY r0, r2, r3, ASYNC, LEN_REG=r5', 't').words[0]);
    expect(head.sub & 2).toBe(2);
  });
});

describe('labels and control flow', () => {
  it('forward JUMP encodes a positive word delta', () => {
    const p = assemble('JUMP r1, skip\nNOP\nskip:\nRET r0', 't');
    expect(decodeWord(p.words[0]).imm).toBe(2n); // skip is 2 words ahead
  });
  it('rejects backward JUMP', () => {
    expect(() => assemble('back:\nNOP\nJUMP r1, back\nRET r0', 't')).toThrow(AsmError);
  });
  it('LOOP body length = label - (loop_pc + 1)', () => {
    const p = assemble('LOOP r2, done\nADDI r1, r1, 1\nANDI r1, r1, 7\ndone:\nRET r1', 't');
    expect(decodeWord(p.words[0]).imm).toBe(2n); // body is 2 words
  });
  it('LOOP accounts for two-word body instructions', () => {
    const p = assemble('LOOP r2, done\nMEMCPY r0, r1, r2, LEN=8\ndone:\nRET r0', 't');
    expect(decodeWord(p.words[0]).imm).toBe(2n); // MEMCPY is 2 words
  });
});

describe('directives and comments', () => {
  it('.arg / .const / .region parse; comments stripped', () => {
    const p = assemble(
      '.arg start r1\n.const N = 0x10\n.region pool 0\n// comment\nLI r2, N # trailing\nRET r2',
      't',
    );
    expect(p.args.start).toBe(1);
    expect(p.consts.N).toBe(0x10n);
    expect(p.regions.pool).toBe(0);
    expect(decodeWord(p.words[0]).imm).toBe(0x10n); // const substituted
  });
});

describe('errors', () => {
  it('unknown mnemonic', () => {
    expect(() => assemble('FOO r1', 't')).toThrow(/unknown mnemonic/);
  });
  it('register out of range', () => {
    expect(() => assemble('LI r16, 1', 't')).toThrow(/out of range/);
  });
  it('undefined label', () => {
    expect(() => assemble('JUMP r1, nowhere\nRET r0', 't')).toThrow(/undefined label/);
  });
  it('bad operand count', () => {
    expect(() => assemble('LOAD r1', 't')).toThrow(AsmError);
  });
});

describe('output helpers', () => {
  it('toHex emits 16-char little-endian words', () => {
    const p = assemble('LI r1, 0x1234\nRET r1', 't');
    const lines = toHex(p).trim().split('\n');
    expect(lines).toHaveLength(2);
    expect(lines[0]).toHaveLength(16);
  });
});
