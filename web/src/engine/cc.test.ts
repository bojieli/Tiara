/** Unit tests for the restricted-C compiler. */
import { describe, it, expect } from 'vitest';
import { compileC, CompileError } from './cc';
import { assemble } from './asm';
import { VM, Memory } from './vm';

function compileRun(src: string, args: bigint[] = [], seed?: [bigint, bigint][]) {
  const { tasm } = compileC(src);
  const prog = assemble(tasm, 't');
  const mem = new Memory();
  if (seed) for (const [a, w] of seed) mem.store64(a, w);
  return { tasm, res: new VM(prog, args, mem).run(), mem };
}

describe('expressions and returns', () => {
  it('arithmetic with immediate folding', () => {
    expect(compileRun('uint64_t f(uint64_t a){ return a + 5; }', [10n]).res.result[0]).toBe(15n);
  });
  it('register-register ops and precedence', () => {
    // 2 + 3*4 = 14
    expect(compileRun('uint64_t f(uint64_t a){ return a + 3 * 4; }', [2n]).res.result[0]).toBe(14n);
  });
  it('bitwise and shifts', () => {
    expect(compileRun('uint64_t f(uint64_t a){ return (a & 0xF) << 2; }', [0xabn]).res.result[0]).toBe(0x2cn);
  });
  it('unary minus', () => {
    expect(compileRun('uint64_t f(uint64_t a){ return -a; }', [1n]).res.result[0]).toBe((1n << 64n) - 1n);
  });
});

describe('control flow', () => {
  it('for loop sums an array', () => {
    const seed: [bigint, bigint][] = [
      [0n, 10n],
      [8n, 20n],
      [16n, 30n],
    ];
    const src = `uint64_t f(uint64_t* base_in_pool_0x80000000, uint64_t n){
      uint64_t s = 0;
      for (int i = 0; i < n; i++) { s = s + base_in_pool_0x80000000[i]; }
      return s;
    }`;
    expect(compileRun(src, [0n, 3n], seed).res.result[0]).toBe(60n);
  });

  it('if with == condition (forward jump)', () => {
    const src = `uint64_t f(uint64_t a){ uint64_t r = 0; if (a == 5) { r = 99; } return r; }`;
    expect(compileRun(src, [5n]).res.result[0]).toBe(99n);
    expect(compileRun(src, [3n]).res.result[0]).toBe(0n);
  });
});

describe('pointer dereference', () => {
  it('constant index', () => {
    const src = `uint64_t f(uint64_t* p_in_pool_0x80000000){ return p_in_pool_0x80000000[2]; }`;
    expect(compileRun(src, [0n], [[16n, 0x77n]]).res.result[0]).toBe(0x77n);
  });
  it('variable index', () => {
    const src = `uint64_t f(uint64_t* p_in_pool_0x80000000, uint64_t i){ return p_in_pool_0x80000000[i]; }`;
    expect(compileRun(src, [0n, 3n], [[24n, 0x99n]]).res.result[0]).toBe(0x99n);
  });
});

describe('builtins', () => {
  it('tiara_caa lowers to CAA', () => {
    const src = `uint64_t f(uint64_t base_in_c_0x10000, uint64_t d){ return tiara_caa(base_in_c_0x10000, d); }`;
    const { tasm, res, mem } = compileRun(src, [0n, 5n], [[0n, 100n]]);
    expect(tasm).toMatch(/CAA/);
    expect(res.result[0]).toBe(100n);
    expect(mem.load64(0n)).toBe(105n);
  });
  it('tiara_andi + tiara_set_result', () => {
    const src = `uint64_t f(uint64_t a){ uint64_t m = tiara_andi(a, 0xFF); tiara_set_result(2, m); return a; }`;
    const { tasm, res } = compileRun(src, [0x1234n]);
    expect(tasm).toMatch(/ANDI/);
    expect(res.result[1]).toBe(0x34n); // r2 = a & 0xFF
  });
  it('tiara_memcpy + tiara_wait emit MEMCPY/WAIT', () => {
    const src = `uint64_t f(uint64_t d, uint64_t s){ tiara_memcpy(d, s, 64, 1); tiara_wait(0); return 0; }`;
    const { tasm } = compileRun(src, [64n, 0n]);
    expect(tasm).toMatch(/MEMCPY/);
    expect(tasm).toMatch(/ASYNC/);
    expect(tasm).toMatch(/WAIT 0/);
  });
});

describe('region naming convention', () => {
  it('emits a .region directive and .arg bindings', () => {
    const { tasm } = compileC('uint64_t f(uint64_t* cur_in_graph_pool_0x80000000){ return cur_in_graph_pool_0x80000000[0]; }');
    expect(tasm).toMatch(/\.region graph_pool 0/);
    expect(tasm).toMatch(/\.arg cur_in_graph_pool_0x80000000 r1/);
  });
});

describe('compile errors', () => {
  it('rejects an unsupported operator', () => {
    expect(() => compileC('uint64_t f(uint64_t a){ return a / 2; }')).toThrow(CompileError);
  });
  it('rejects too many arguments', () => {
    const args = Array.from({ length: 9 }, (_, i) => `uint64_t a${i}`).join(', ');
    expect(() => compileC(`uint64_t f(${args}){ return a0; }`)).toThrow(CompileError);
  });
  it('rejects an unknown builtin', () => {
    expect(() => compileC('uint64_t f(uint64_t a){ return tiara_bogus(a); }')).toThrow(/unknown function/);
  });
});
