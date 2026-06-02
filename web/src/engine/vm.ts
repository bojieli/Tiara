/**
 * Tiara virtual machine — a single-step execution engine for the Tiara
 * ISA, faithful to `docs/ISA.md` and the Verilator reference's observable
 * behaviour (validated against golden vectors in vm.test.ts).
 *
 * The VM models per-task architectural state (16x64b GPRs, PC, flags,
 * an 8-deep loop stack, an async in-flight counter), a sparse host-DRAM
 * memory keyed by unified 64-bit address, and a transparent latency
 * model calibrated to the FPGA prototype (200 MHz; ~150-cycle PCIe DMA
 * per host-memory access; ~500-cycle RDMA round trip). Every `step()`
 * emits a structured event so the UI can highlight register writes,
 * memory touches, loop bookkeeping, and accruing latency.
 */

import {
  Decoded,
  decodeWord,
  mask64,
  MAX_INFLIGHT_PER_TASK,
  Op,
  splitAddr,
  Sub,
  U64_MASK,
  NUM_REGS,
} from './isa';
import type { Program } from './asm';

// --- latency model (cycles @ 200 MHz, 5 ns/cycle) --------------------
// Calibrated so graph-traversal latency reproduces eval/results/
// graph_traversal.dat (~158 cycles / hop = 150 DMA + 8 FSM).
export const CYCLE_NS = 5;
export const COST = {
  dispatchBase: 2, // request arrival -> first instruction
  ctrl: 8, // ALU / control-flow instruction (11-state MP FSM)
  dma: 150, // PCIe DMA to host DRAM (LOAD/STORE/atomic, local Memcpy setup)
  rdmaRtt: 500, // RDMA round trip to a peer host (remote Memcpy)
  bytesPerCycle: 60.5, // ~12.1 GB/s effective line rate @ 200 MHz
};

export function cyclesToUs(cycles: number): number {
  return (cycles * CYCLE_NS) / 1000;
}

export interface Flags {
  Z: boolean;
  N: boolean;
  ERR: boolean;
  C: boolean;
}

export interface LoopFrame {
  startPc: number;
  endPc: number;
  count: bigint;
  remaining: bigint;
}

export interface MemAccess {
  kind: 'load' | 'store' | 'cas' | 'caa' | 'memcpy';
  addr: bigint;
  value?: bigint; // value read or written (LOAD/STORE/atomic)
  device: number;
  region: number;
  offset: bigint;
  length?: number; // for memcpy
  remote: boolean;
  async?: boolean;
  src?: bigint; // memcpy source addr
}

export interface RegWrite {
  reg: number;
  before: bigint;
  after: bigint;
}

export interface StepEvent {
  pc: number; // word offset of the executed instruction
  instrIndex: number; // index into program.instrs
  mnemonic: string;
  decoded: Decoded;
  regWrites: RegWrite[];
  mem: MemAccess | null;
  loopAction: 'push' | 'iterate' | 'pop' | 'skip' | null;
  inFlightDelta: number;
  cyclesDelta: number;
  note: string | null;
  halted: boolean;
}

export interface VMState {
  regs: bigint[];
  pc: number;
  flags: Flags;
  loopStack: LoopFrame[];
  inFlight: number;
  cycles: number;
  instrRetired: number;
  halted: boolean;
  err: boolean;
  result: bigint[]; // r0..r3 captured on RET
}

export interface SimResult {
  cycles: number;
  latencyUs: number;
  instrRetired: number;
  err: boolean;
  regs: bigint[]; // full register file
  result: bigint[]; // r0..r3
  steps: number;
}

export class Memory {
  private map = new Map<string, bigint>();
  /** Read a 64-bit little-endian word at a byte address (8-aligned). */
  load64(addr: bigint): bigint {
    return this.map.get(addr.toString()) ?? 0n;
  }
  store64(addr: bigint, value: bigint): void {
    this.map.set(addr.toString(), mask64(value));
  }
  /** Seed device-0 host DRAM: word i at byte offset i*8. */
  seedWords(words: bigint[], base: bigint = 0n): void {
    words.forEach((w, i) => this.store64(base + BigInt(i) * 8n, w));
  }
  /** Seed a sparse map of byte-address -> word. */
  seedMap(entries: Record<string, bigint | number>): void {
    for (const [k, v] of Object.entries(entries)) {
      this.store64(BigInt(k), BigInt(v));
    }
  }
  entries(): [bigint, bigint][] {
    return [...this.map.entries()]
      .map(([k, v]) => [BigInt(k), v] as [bigint, bigint])
      .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  }
  clear(): void {
    this.map.clear();
  }
}

const DATA_COPY_WORD_CAP = 512; // bound memcpy data mirroring for huge transfers

export class VM {
  prog: Program;
  mem: Memory;
  regs: bigint[] = new Array(NUM_REGS).fill(0n);
  pc = 0;
  flags: Flags = { Z: false, N: false, ERR: false, C: false };
  loopStack: LoopFrame[] = [];
  inFlight = 0;
  cycles = 0;
  instrRetired = 0;
  halted = false;
  err = false;
  result: bigint[] = [0n, 0n, 0n, 0n];
  steps = 0;
  maxSteps: number;

  // completion cycle timestamps of outstanding async Memcpy ops
  private inflightCompletions: number[] = [];

  constructor(prog: Program, args: bigint[] = [], mem?: Memory, maxSteps = 2_000_000) {
    this.prog = prog;
    this.mem = mem ?? new Memory();
    this.maxSteps = maxSteps;
    this.reset(args);
  }

  reset(args: bigint[] = []): void {
    this.regs = new Array(NUM_REGS).fill(0n);
    // r1..r8 receive incoming arguments
    for (let i = 0; i < 8 && i < args.length; i++) {
      this.regs[i + 1] = mask64(args[i]);
    }
    this.pc = 0;
    this.flags = { Z: false, N: false, ERR: false, C: false };
    this.loopStack = [];
    this.inFlight = 0;
    this.inflightCompletions = [];
    this.cycles = COST.dispatchBase;
    this.instrRetired = 0;
    this.halted = false;
    this.err = false;
    this.result = [0n, 0n, 0n, 0n];
    this.steps = 0;
  }

  state(): VMState {
    return {
      regs: [...this.regs],
      pc: this.pc,
      flags: { ...this.flags },
      loopStack: this.loopStack.map((f) => ({ ...f })),
      inFlight: this.inFlight,
      cycles: this.cycles,
      instrRetired: this.instrRetired,
      halted: this.halted,
      err: this.err,
      result: [...this.result],
    };
  }

  private setReg(reg: number, value: bigint, writes: RegWrite[]): void {
    if (reg === 0) return; // r0 hard-wired to zero
    const before = this.regs[reg];
    const after = mask64(value);
    this.regs[reg] = after;
    writes.push({ reg, before, after });
  }

  private setALUFlags(v: bigint): void {
    this.flags.Z = v === 0n;
    this.flags.N = (v >> 63n & 1n) === 1n;
  }

  /** The instruction word offset is the current PC. Returns the decoded
   * head word plus the optional second (extra) word. */
  private fetch(): { head: Decoded; extra: Decoded | null } {
    const head = decodeWord(this.prog.words[this.pc]);
    let extra: Decoded | null = null;
    if (head.op === Op.MEMCPY || head.op === Op.CAS || head.op === Op.CAA) {
      extra = decodeWord(this.prog.words[this.pc + 1]);
    }
    return { head, extra };
  }

  private width(op: number): number {
    return op === Op.MEMCPY || op === Op.CAS || op === Op.CAA ? 2 : 1;
  }

  /** Resolve loop-stack bookkeeping after computing the fall-through PC. */
  private resolveLoops(np: number): { pc: number; action: 'iterate' | 'pop' | null } {
    let action: 'iterate' | 'pop' | null = null;
    while (this.loopStack.length) {
      const top = this.loopStack[this.loopStack.length - 1];
      if (np !== top.endPc) break;
      if (top.remaining > 1n) {
        top.remaining -= 1n;
        np = top.startPc;
        action = 'iterate';
        break;
      } else {
        this.loopStack.pop();
        action = 'pop';
        // keep checking in case an outer loop also ends here
      }
    }
    return { pc: np, action };
  }

  step(): StepEvent {
    if (this.halted) {
      return {
        pc: this.pc,
        instrIndex: -1,
        mnemonic: 'HALT',
        decoded: { op: 0, rd: 0, rs1: 0, rs2: 0, sub: 0, imm: 0n },
        regWrites: [],
        mem: null,
        loopAction: null,
        inFlightDelta: 0,
        cyclesDelta: 0,
        note: 'task halted',
        halted: true,
      };
    }
    this.steps++;
    if (this.steps > this.maxSteps) {
      this.halted = true;
      this.err = true;
      return this.mkEvent(this.pc, -1, 'ABORT', this.fetch().head, [], null, null, 0, 0, 'step limit exceeded — possible non-termination', true);
    }

    const startPc = this.pc;
    const instrIndex = this.prog.pcToInstr.get(startPc) ?? -1;
    const { head, extra } = this.fetch();
    const writes: RegWrite[] = [];
    let mem: MemAccess | null = null;
    let loopAction: StepEvent['loopAction'] = null;
    let inFlightDelta = 0;
    let cyclesDelta = 0;
    let note: string | null = null;
    const startCycles = this.cycles;
    const startInFlight = this.inFlight;

    let nextPc = startPc + this.width(head.op);
    const R = (i: number) => this.regs[i];

    switch (head.op) {
      case Op.NOP:
        this.cycles += COST.ctrl;
        break;

      case Op.LOAD: {
        const addr = mask64(R(head.rs1) + head.imm);
        const value = this.mem.load64(addr);
        this.setReg(head.rd, value, writes);
        const { device, region, offset } = splitAddr(addr);
        mem = { kind: 'load', addr, value, device, region, offset, remote: device !== 0 };
        this.cycles += device !== 0 ? COST.rdmaRtt : COST.dma;
        break;
      }

      case Op.STORE: {
        const addr = mask64(R(head.rs1) + head.imm);
        const value = R(head.rs2);
        this.mem.store64(addr, value);
        const { device, region, offset } = splitAddr(addr);
        mem = { kind: 'store', addr, value, device, region, offset, remote: device !== 0 };
        this.cycles += device !== 0 ? COST.rdmaRtt : COST.dma;
        break;
      }

      case Op.COMPUTE: {
        const v = this.compute(head.sub, R(head.rs1), R(head.rs2), head.imm);
        this.setReg(head.rd, v, writes);
        this.setALUFlags(mask64(v));
        this.cycles += COST.ctrl;
        break;
      }

      case Op.JUMP: {
        this.cycles += COST.ctrl;
        if (R(head.rs1) !== 0n) {
          nextPc = startPc + Number(head.imm);
          note = `branch taken (r${head.rs1} != 0) -> +${head.imm}`;
        } else {
          note = `branch not taken (r${head.rs1} == 0)`;
        }
        break;
      }

      case Op.LOOP: {
        this.cycles += COST.ctrl;
        const bodyLen = Number(head.imm);
        const count = R(head.rs1);
        const endPc = startPc + 1 + bodyLen;
        if (count === 0n) {
          nextPc = endPc;
          loopAction = 'skip';
          note = `loop count r${head.rs1} == 0 -> skip body`;
        } else {
          this.loopStack.push({ startPc: startPc + 1, endPc, count, remaining: count });
          nextPc = startPc + 1;
          loopAction = 'push';
          note = `loop ${count}x over [${startPc + 1}..${endPc})`;
        }
        break;
      }

      case Op.WAIT: {
        this.cycles += COST.ctrl;
        const threshold = Number(head.imm);
        let drained = 0;
        while (this.inFlight > threshold && this.inflightCompletions.length) {
          const c = this.inflightCompletions.shift()!;
          this.cycles = Math.max(this.cycles, c);
          this.inFlight--;
          drained++;
        }
        inFlightDelta = this.inFlight - startInFlight;
        note = `wait until in-flight <= ${threshold}; drained ${drained}`;
        break;
      }

      case Op.RET: {
        this.cycles += COST.ctrl;
        // Drain any outstanding async ops (task completion barrier).
        while (this.inflightCompletions.length) {
          const c = this.inflightCompletions.shift()!;
          this.cycles = Math.max(this.cycles, c);
          this.inFlight--;
        }
        // Result convention (matches the Verilator testbench): the dumped
        // r0..r3 are GPR1..GPR4 — the operator's return-value registers.
        this.result = [this.regs[1], this.regs[2], this.regs[3], this.regs[4]];
        this.halted = true;
        note = 'return r0..r3 to caller';
        break;
      }

      case Op.MEMCPY: {
        const flags = head.sub;
        const async_ = (flags & 1) !== 0;
        const lenFromReg = (flags & 2) !== 0;
        const dstAddr = R(head.rs1);
        const srcAddr = R(head.rs2);
        const length = lenFromReg ? Number(R(extra!.rd)) : Number(head.imm);
        this.doMemcpy(dstAddr, srcAddr, length);
        this.setReg(head.rd, 0n, writes); // status = success
        const { device, region, offset } = splitAddr(dstAddr);
        const srcDev = splitAddr(srcAddr).device;
        const remote = device !== 0 || srcDev !== 0;
        mem = {
          kind: 'memcpy',
          addr: dstAddr,
          src: srcAddr,
          device,
          region,
          offset,
          length,
          remote,
          async: async_,
        };
        const xferCycles = Math.ceil(length / COST.bytesPerCycle);
        const opCycles = (remote ? COST.rdmaRtt : COST.dma) + xferCycles;
        if (async_) {
          // fire-and-forget: issue cost only; completion tracked for Wait
          this.cycles += COST.ctrl;
          this.inFlight = Math.min(MAX_INFLIGHT_PER_TASK, this.inFlight + 1);
          this.inflightCompletions.push(this.cycles + opCycles);
          this.inflightCompletions.sort((a, b) => a - b);
          inFlightDelta = 1;
          note = `async ${remote ? 'RDMA' : 'DMA'} ${length}B (completes @cycle ${this.cycles + opCycles})`;
        } else {
          this.cycles += opCycles;
          note = `${remote ? 'RDMA' : 'DMA'} ${length}B (blocking)`;
        }
        break;
      }

      case Op.CAS: {
        const addr = R(head.rs1);
        const expected = R(head.rs2);
        const newVal = R(extra!.rd);
        const cur = this.mem.load64(addr);
        this.setReg(head.rd, cur, writes); // returns previous value
        let swapped = false;
        if (cur === expected) {
          this.mem.store64(addr, newVal);
          swapped = true;
        }
        const { device, region, offset } = splitAddr(addr);
        mem = { kind: 'cas', addr, value: cur, device, region, offset, remote: device !== 0 };
        this.cycles += device !== 0 ? COST.rdmaRtt : COST.dma;
        note = swapped ? `CAS success: ${cur} -> ${newVal}` : `CAS fail: found ${cur}, expected ${expected}`;
        break;
      }

      case Op.CAA: {
        const addr = R(head.rs1);
        const addend = R(head.rs2);
        const cur = this.mem.load64(addr);
        this.setReg(head.rd, cur, writes); // returns previous value
        this.mem.store64(addr, mask64(cur + addend));
        const { device, region, offset } = splitAddr(addr);
        mem = { kind: 'caa', addr, value: cur, device, region, offset, remote: device !== 0 };
        this.cycles += device !== 0 ? COST.rdmaRtt : COST.dma;
        note = `CAA: ${cur} += ${addend}`;
        break;
      }

      default:
        this.halted = true;
        this.err = true;
        note = `illegal opcode 0x${head.op.toString(16)}`;
    }

    if (!this.halted) {
      const r = this.resolveLoops(nextPc);
      this.pc = r.pc;
      if (r.action) loopAction = r.action;
      if (this.pc >= this.prog.words.length) {
        // fell off the end without RET
        this.halted = true;
        this.err = true;
        note = (note ? note + '; ' : '') + 'ran past end of program (missing RET)';
      }
    }

    this.instrRetired++;
    cyclesDelta = this.cycles - startCycles;
    inFlightDelta = this.inFlight - startInFlight;

    return this.mkEvent(
      startPc,
      instrIndex,
      this.mnemonicOf(head),
      head,
      writes,
      mem,
      loopAction,
      inFlightDelta,
      cyclesDelta,
      note,
      this.halted,
    );
  }

  private mkEvent(
    pc: number,
    instrIndex: number,
    mnemonic: string,
    decoded: Decoded,
    regWrites: RegWrite[],
    mem: MemAccess | null,
    loopAction: StepEvent['loopAction'],
    inFlightDelta: number,
    cyclesDelta: number,
    note: string | null,
    halted: boolean,
  ): StepEvent {
    return { pc, instrIndex, mnemonic, decoded, regWrites, mem, loopAction, inFlightDelta, cyclesDelta, note, halted };
  }

  private mnemonicOf(d: Decoded): string {
    if (d.op === Op.COMPUTE) return Sub[d.sub] ?? `COMPUTE.${d.sub}`;
    return Op[d.op] ?? `0x${d.op.toString(16)}`;
  }

  private doMemcpy(dst: bigint, src: bigint, length: number): void {
    const nWords = Math.min(Math.ceil(length / 8), DATA_COPY_WORD_CAP);
    for (let i = 0; i < nWords; i++) {
      const w = this.mem.load64(mask64(src + BigInt(i) * 8n));
      this.mem.store64(mask64(dst + BigInt(i) * 8n), w);
    }
  }

  private compute(sub: number, a: bigint, b: bigint, imm: bigint): bigint {
    switch (sub) {
      case Sub.ADD:
        return mask64(a + b);
      case Sub.SUB:
        return mask64(a - b);
      case Sub.AND:
        return a & b;
      case Sub.OR:
        return a | b;
      case Sub.XOR:
        return a ^ b;
      case Sub.SHL:
        return mask64(a << (b & 63n));
      case Sub.SHR:
        return a >> (b & 63n);
      case Sub.MUL:
        return mask64(a * b);
      case Sub.ADDI:
        return mask64(a + imm);
      case Sub.ANDI:
        return a & BigInt.asUintN(40, imm);
      case Sub.SHLI:
        return mask64(a << (imm & 63n));
      case Sub.SHRI:
        return a >> (imm & 63n);
      case Sub.LI:
        return mask64(imm);
      case Sub.EQ:
        return a === b ? 1n : 0n;
      case Sub.LT:
        return a < b ? 1n : 0n;
      case Sub.GE:
        return a >= b ? 1n : 0n;
      default:
        return 0n;
    }
  }

  /** Run to completion, returning a summary. */
  run(): SimResult {
    while (!this.halted) this.step();
    return {
      cycles: this.cycles,
      latencyUs: cyclesToUs(this.cycles),
      instrRetired: this.instrRetired,
      err: this.err,
      regs: [...this.regs],
      result: [...this.result],
      steps: this.steps,
    };
  }
}
