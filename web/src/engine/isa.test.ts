/** Unit tests for the ISA encoding layer (encode/decode, addressing). */
import { describe, it, expect } from 'vitest';
import {
  encodeWord,
  decodeWord,
  makeAddr,
  splitAddr,
  Op,
  Sub,
  Instr,
  mask64,
  U64_MASK,
  TWO_WORD_OPCODES,
} from './isa';

describe('encode/decode round-trips', () => {
  it('packs and unpacks every field', () => {
    const w = encodeWord(Op.COMPUTE, 5, 6, 7, Sub.ADD, 0n);
    const d = decodeWord(w);
    expect(d.op).toBe(Op.COMPUTE);
    expect(d.rd).toBe(5);
    expect(d.rs1).toBe(6);
    expect(d.rs2).toBe(7);
    expect(d.sub).toBe(Sub.ADD);
    expect(d.imm).toBe(0n);
  });

  it('sign-extends a negative 40-bit immediate', () => {
    const w = encodeWord(Op.COMPUTE, 1, 0, 0, Sub.LI, -5n);
    expect(decodeWord(w).imm).toBe(-5n);
  });

  it('preserves a large positive immediate (mask)', () => {
    const w = encodeWord(Op.COMPUTE, 1, 1, 0, Sub.ANDI, 0x7ffffff8n);
    expect(decodeWord(w).imm).toBe(0x7ffffff8n);
  });

  it('round-trips a full-range imm40 boundary', () => {
    const hi = (1n << 39n) - 1n;
    const lo = -(1n << 39n);
    expect(decodeWord(encodeWord(Op.COMPUTE, 0, 0, 0, Sub.LI, hi)).imm).toBe(hi);
    expect(decodeWord(encodeWord(Op.COMPUTE, 0, 0, 0, Sub.LI, lo)).imm).toBe(lo);
  });

  it('rejects out-of-range registers and immediates', () => {
    expect(() => encodeWord(Op.LOAD, 16)).toThrow();
    expect(() => encodeWord(Op.LOAD, -1)).toThrow();
    expect(() => encodeWord(Op.COMPUTE, 0, 0, 0, 0, 1n << 40n)).toThrow();
  });
});

describe('unified addressing', () => {
  it('packs (device, region, offset) and splits back', () => {
    const a = makeAddr(2, 1, 0x1234);
    const s = splitAddr(a);
    expect(s.device).toBe(2);
    expect(s.region).toBe(1);
    expect(s.offset).toBe(0x1234n);
  });

  it('device 0 offset equals the raw offset', () => {
    expect(makeAddr(0, 0, 4096)).toBe(4096n);
  });

  it('matches the documented bit layout', () => {
    // device<<48 | region<<32 | offset
    expect(makeAddr(1, 0, 0)).toBe(1n << 48n);
    expect(makeAddr(0, 1, 0)).toBe(1n << 32n);
  });
});

describe('Instr encoding width', () => {
  it('two-word opcodes emit two words', () => {
    const m = new Instr(Op.MEMCPY, { rd: 1, rs1: 2, rs2: 3, imm40: 64n });
    m.extra = new Instr(Op.NOP);
    expect(m.width).toBe(2);
    expect(m.encode()).toHaveLength(2);
    for (const op of TWO_WORD_OPCODES) expect([Op.MEMCPY, Op.CAS, Op.CAA]).toContain(op);
  });
  it('single-word opcodes emit one word', () => {
    expect(new Instr(Op.LOAD, { rd: 1, rs1: 2 }).encode()).toHaveLength(1);
  });
  it('throws if a two-word op is missing its extra', () => {
    expect(() => new Instr(Op.CAS).encode()).toThrow();
  });
});

describe('mask64', () => {
  it('wraps to 64 bits', () => {
    expect(mask64(U64_MASK + 1n)).toBe(0n);
    expect(mask64(-1n)).toBe(U64_MASK);
  });
});
