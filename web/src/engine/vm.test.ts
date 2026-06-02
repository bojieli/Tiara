/** Unit tests for the VM: every opcode, ALU op, and control-flow edge case. */
import { describe, it, expect } from 'vitest';
import { assemble } from './asm';
import { VM, Memory } from './vm';
import { makeAddr, U64_MASK } from './isa';

function run(src: string, args: bigint[] = [], seed?: [bigint, bigint][]) {
  const prog = assemble(src, 't');
  const mem = new Memory();
  if (seed) for (const [a, w] of seed) mem.store64(a, w);
  const vm = new VM(prog, args, mem);
  const res = vm.run();
  return { vm, res, mem };
}

describe('ALU sub-ops', () => {
  const cases: [string, bigint][] = [
    ['LI r1, 5\nADD r1, r1, r1\nRET r1', 10n],
    ['LI r1, 9\nLI r2, 4\nSUB r1, r1, r2\nRET r1', 5n],
    ['LI r1, 12\nLI r2, 10\nAND r1, r1, r2\nRET r1', 8n],
    ['LI r1, 12\nLI r2, 3\nOR r1, r1, r2\nRET r1', 15n],
    ['LI r1, 12\nLI r2, 10\nXOR r1, r1, r2\nRET r1', 6n],
    ['LI r1, 1\nLI r2, 4\nSHL r1, r1, r2\nRET r1', 16n],
    ['LI r1, 64\nLI r2, 2\nSHR r1, r1, r2\nRET r1', 16n],
    ['LI r1, 6\nLI r2, 7\nMUL r1, r1, r2\nRET r1', 42n],
    ['LI r1, 10\nADDI r1, r1, 5\nRET r1', 15n],
    ['LI r1, 0xFF\nANDI r1, r1, 0x0F\nRET r1', 0xfn],
    ['LI r1, 3\nSHLI r1, r1, 4\nRET r1', 48n],
    ['LI r1, 256\nSHRI r1, r1, 4\nRET r1', 16n],
    ['LI r1, 5\nLI r2, 5\nEQ r1, r1, r2\nRET r1', 1n],
    ['LI r1, 3\nLI r2, 5\nLT r1, r1, r2\nRET r1', 1n],
    ['LI r1, 5\nLI r2, 3\nGE r1, r1, r2\nRET r1', 1n],
  ];
  for (const [src, expected] of cases) {
    it(`${src.split('\n')[1] ?? src.split('\n')[0]} -> ${expected}`, () => {
      expect(run(src).res.result[0]).toBe(expected);
    });
  }

  it('arithmetic wraps at 64 bits', () => {
    // (2^63) * 2 wraps to 0
    expect(run('LI r1, 1\nSHLI r1, r1, 63\nLI r2, 2\nMUL r1, r1, r2\nRET r1').res.result[0]).toBe(0n);
  });

  it('r0 is hard-wired to zero (writes dropped)', () => {
    const { vm } = run('LI r0, 99\nADDI r1, r0, 7\nRET r1');
    expect(vm.regs[0]).toBe(0n);
    expect(vm.result[0]).toBe(7n);
  });
});

describe('memory', () => {
  it('LOAD reads seeded memory', () => {
    expect(run('LOAD r1, [r1 + 0]\nRET r1', [0n], [[0n, 0xcafen]]).res.result[0]).toBe(0xcafen);
  });
  it('STORE then LOAD round-trips', () => {
    const { mem } = run('LI r2, 0x1234\nSTORE [r1 + 0], r2\nLOAD r1, [r1 + 0]\nRET r1', [64n]);
    expect(mem.load64(64n)).toBe(0x1234n);
  });
  it('register-chained loads (pointer chase)', () => {
    // mem[0]=8 -> mem[8]=16 -> mem[16]=0xBEEF
    const seed: [bigint, bigint][] = [
      [0n, 8n],
      [8n, 16n],
      [16n, 0xbeefn],
    ];
    const src = 'LOAD r1, [r1 + 0]\nLOAD r1, [r1 + 0]\nLOAD r1, [r1 + 0]\nRET r1';
    expect(run(src, [0n], seed).res.result[0]).toBe(0xbeefn);
  });
});

describe('control flow', () => {
  it('LOOP runs the body N times', () => {
    expect(run('LOOP r1, e\nADDI r2, r2, 1\ne:\nADDI r1, r2, 0\nRET r1', [5n]).res.result[0]).toBe(5n);
  });
  it('LOOP with count 0 skips the body', () => {
    expect(run('LOOP r1, e\nADDI r2, r2, 100\ne:\nADDI r1, r2, 0\nRET r1', [0n]).res.result[0]).toBe(0n);
  });
  it('nested loops multiply iterations', () => {
    // outer r1=3, inner r2=4 -> r3 incremented 12 times
    const src = 'LOOP r1, oe\nLOOP r2, ie\nADDI r3, r3, 1\nie:\nADDI r9, r9, 0\noe:\nADDI r1, r3, 0\nRET r1';
    expect(run(src, [3n, 4n]).res.result[0]).toBe(12n);
  });
  it('forward JUMP taken when cond != 0', () => {
    expect(run('LI r1, 1\nJUMP r1, skip\nLI r2, 99\nskip:\nADDI r1, r2, 0\nRET r1').res.result[0]).toBe(0n);
  });
  it('forward JUMP not taken when cond == 0', () => {
    expect(run('LI r1, 0\nJUMP r1, skip\nLI r2, 7\nskip:\nADDI r1, r2, 0\nRET r1').res.result[0]).toBe(7n);
  });
});

describe('atomics', () => {
  it('CAS success swaps and returns old value', () => {
    const { mem, vm } = run('LI r2, 0\nLI r3, 1\nCAS r9, r1, r2, r3\nADDI r1, r9, 0\nRET r1', [0n], [[0n, 0n]]);
    expect(vm.result[0]).toBe(0n); // old value
    expect(mem.load64(0n)).toBe(1n); // swapped
  });
  it('CAS failure leaves memory and returns current', () => {
    const { mem, vm } = run('LI r2, 0\nLI r3, 1\nCAS r9, r1, r2, r3\nADDI r1, r9, 0\nRET r1', [0n], [[0n, 7n]]);
    expect(vm.result[0]).toBe(7n);
    expect(mem.load64(0n)).toBe(7n); // unchanged
  });
  it('CAA fetch-and-add', () => {
    const { mem, vm } = run('CAA r9, r1, r2\nADDI r1, r9, 0\nRET r1', [0n, 5n], [[0n, 100n]]);
    expect(vm.result[0]).toBe(100n); // old
    expect(mem.load64(0n)).toBe(105n);
  });
});

describe('async Memcpy + Wait', () => {
  it('async Memcpy increments in-flight; Wait drains it', () => {
    const prog = assemble('MEMCPY r0, r1, r2, ASYNC, LEN=8\nWAIT 0\nRET r0', 't');
    const vm = new VM(prog, [0n, 64n], new Memory());
    vm.step(); // MEMCPY
    expect(vm.inFlight).toBe(1);
    vm.step(); // WAIT 0
    expect(vm.inFlight).toBe(0);
  });
  it('Wait advances cycles past the async completion', () => {
    const { res } = run('MEMCPY r0, r1, r2, ASYNC, LEN=8\nWAIT 0\nRET r0', [0n, 64n]);
    expect(res.cycles).toBeGreaterThan(150); // includes a DMA completion
  });
  it('remote Memcpy (device != 0) costs an RDMA RTT', () => {
    const remote = makeAddr(1, 0, 0);
    const localSrc = 0n;
    const prog = assemble('MEMCPY r0, r1, r2, LEN=8\nRET r0', 't');
    const vm = new VM(prog, [remote, localSrc], new Memory());
    const before = vm.cycles;
    vm.step();
    expect(vm.cycles - before).toBeGreaterThanOrEqual(500); // rdmaRtt
  });
});

describe('flags and result mapping', () => {
  it('Z flag set when ALU result is zero', () => {
    const prog = assemble('LI r1, 0\nRET r1', 't');
    const vm = new VM(prog, []);
    vm.step();
    expect(vm.flags.Z).toBe(true);
  });
  it('result reports GPR1..GPR4', () => {
    const { res } = run('LI r1, 1\nLI r2, 2\nLI r3, 3\nLI r4, 4\nRET r1');
    expect(res.result).toEqual([1n, 2n, 3n, 4n]);
  });
});

describe('termination safety', () => {
  it('flags an error when running past the end without RET', () => {
    const { res } = run('LI r1, 1');
    expect(res.err).toBe(true);
  });
  it('halts cleanly on RET', () => {
    const { vm } = run('RET r0');
    expect(vm.halted).toBe(true);
    expect(vm.err).toBe(false);
  });
});

describe('step-by-step trace events (single-stepping)', () => {
  it('each step reports register writes, mem access, and cycle delta', () => {
    const prog = assemble('LOAD r1, [r1 + 0]\nRET r1', 't');
    const mem = new Memory();
    mem.store64(0n, 0xabcn);
    const vm = new VM(prog, [0n], mem);
    const ev = vm.step();
    expect(ev.mnemonic).toBe('LOAD');
    expect(ev.regWrites[0]).toMatchObject({ reg: 1, after: 0xabcn });
    expect(ev.mem?.kind).toBe('load');
    expect(ev.cyclesDelta).toBeGreaterThan(0);
  });
  it('reports loop push/iterate/pop actions', () => {
    const prog = assemble('LOOP r1, e\nADDI r2, r2, 1\ne:\nRET r2', 't');
    const vm = new VM(prog, [2n]);
    expect(vm.step().loopAction).toBe('push');
    expect(vm.step().loopAction).toBe('iterate'); // body, loops back
  });
});
