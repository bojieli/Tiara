/** Every shipped preset must assemble, verify, and run to completion. */
import { describe, it, expect } from 'vitest';
import { assemble } from '../engine/asm';
import { VM, Memory } from '../engine/vm';
import { verify } from '../engine/verifier';
import { PRESETS } from './operators';

describe('all playground presets are runnable', () => {
  for (const p of PRESETS) {
    it(`${p.id} assembles, verifies, and halts`, () => {
      const prog = assemble(p.tasm, p.id);
      const rep = verify(prog, p.manifest);
      expect(rep.nInstructions).toBeGreaterThan(0);

      const mem = new Memory();
      for (const [a, w] of p.seed(p.defaultArgs)) mem.store64(a, w);
      const vm = new VM(prog, p.defaultArgs, mem, 500_000);
      const res = vm.run();
      expect(res.err).toBe(false);
      expect(vm.halted).toBe(true);
      expect(res.latencyUs).toBeGreaterThan(0);
    });
  }
});
