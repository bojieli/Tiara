/** Unit tests for the static verifier: acceptance and every rejection path. */
import { describe, it, expect } from 'vitest';
import { assemble, Program } from './asm';
import { verify, Manifest, defaultManifest } from './verifier';
import { encodeWord, Op } from './isa';

const region0 = (size = 0x80000000n): Manifest => ({
  name: 't',
  version: 1,
  maxDynamic: 4096,
  regions: [{ id: 0, device: 0, name: 'r0', size }],
  arguments: [{ name: 'p', reg: 1, lo: 0n, hi: 0x1000n, region: [0, 0] }],
});

function rawProg(words: bigint[]): Program {
  return {
    name: 't',
    words,
    labels: {},
    args: {},
    consts: {},
    regions: {},
    instrs: words.map(() => ({}) as any),
    pcToInstr: new Map(),
  };
}

describe('acceptance', () => {
  it('accepts a simple in-region access', () => {
    const prog = assemble('LOAD r2, [r1 + 0]\nADDI r1, r2, 0\nRET r1', 't');
    const m = region0();
    m.arguments = [{ name: 'p', reg: 1, lo: 0n, hi: 0x100n, region: [0, 0] }];
    const rep = verify(prog, m);
    expect(rep.ok).toBe(true);
    expect(rep.staticStepBound).toBeGreaterThan(0);
  });

  it('accepts a masked opaque load used as an address', () => {
    const prog = assemble('LOAD r1, [r1 + 0]\nANDI r1, r1, 0x7FFFFFF8\nLOAD r1, [r1 + 0]\nRET r1', 't');
    expect(verify(prog, region0()).ok).toBe(true);
  });

  it('computes a loop-multiplied step bound', () => {
    const prog = assemble('LOOP r2, e\nADDI r3, r3, 1\ne:\nRET r3', 't');
    const m = region0();
    m.arguments.push({ name: 'd', reg: 2, lo: 0n, hi: 8n });
    const rep = verify(prog, m);
    // LOOP + 8*body + RET-ish
    expect(rep.staticStepBound).toBeGreaterThanOrEqual(8);
  });
});

describe('rejections', () => {
  it('rejects an opaque LOAD used as an address (no ANDI)', () => {
    const prog = assemble('LOAD r2, [r1 + 0]\nLOAD r3, [r2 + 0]\nADDI r1, r3, 0\nRET r1', 't');
    const rep = verify(prog, region0());
    expect(rep.ok).toBe(false);
    expect(rep.issues.join(' ')).toMatch(/opaque/);
  });

  it('rejects an address range that escapes its region', () => {
    const prog = assemble('ADDI r1, r1, 0x100000\nLOAD r2, [r1 + 0]\nADDI r1, r2, 0\nRET r1', 't');
    const m = region0(0x1000n); // tiny region
    m.arguments = [{ name: 'p', reg: 1, lo: 0n, hi: 0x100n, region: [0, 0] }];
    const rep = verify(prog, m);
    expect(rep.ok).toBe(false);
    expect(rep.issues.join(' ')).toMatch(/escapes region/);
  });

  it('rejects a program with no RET', () => {
    const prog = assemble('LI r1, 1', 't');
    expect(verify(prog, region0()).ok).toBe(false);
    expect(verify(prog, region0()).issues.join(' ')).toMatch(/no RET/);
  });

  it('rejects a backward JUMP (constructed)', () => {
    const words = [encodeWord(Op.JUMP, 0, 1, 0, 0, -1n), encodeWord(Op.RET)];
    const rep = verify(rawProg(words), defaultManifest());
    expect(rep.ok).toBe(false);
    expect(rep.issues.join(' ')).toMatch(/backward JUMP/);
  });

  it('rejects loop nesting beyond 8', () => {
    // 9 nested loops
    let src = '';
    for (let i = 0; i < 9; i++) src += `LOOP r2, e${i}\n`;
    src += 'ADDI r3, r3, 1\n';
    for (let i = 8; i >= 0; i--) src += `e${i}:\n`;
    src += 'RET r3';
    const m = region0();
    m.arguments.push({ name: 'd', reg: 2, lo: 0n, hi: 2n });
    const rep = verify(assemble(src, 't'), m);
    expect(rep.ok).toBe(false);
    expect(rep.issues.join(' ')).toMatch(/loop nesting/);
  });

  it('rejects when the static step bound exceeds max_dynamic', () => {
    const prog = assemble('LOOP r2, e\nADDI r3, r3, 1\ne:\nRET r3', 't');
    const m = region0();
    m.maxDynamic = 5;
    m.arguments.push({ name: 'd', reg: 2, lo: 0n, hi: 1000n });
    const rep = verify(prog, m);
    expect(rep.ok).toBe(false);
    expect(rep.issues.join(' ')).toMatch(/max_dynamic/);
  });
});
