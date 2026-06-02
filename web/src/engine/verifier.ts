/**
 * Tiara static verifier — TypeScript port of `sw/verifier/tiara_verifier.py`.
 *
 * Pre-registration checks (paper §3.3): (1) termination via forward-only
 * jumps + bounded loops + a static instruction-count bound; (2) memory
 * bounds — every Load/Store/Memcpy address must be provably inside a
 * declared region; (3) resource caps. The headline rule the playground
 * showcases: a value produced by a LOAD is *opaque* and must pass through
 * an ANDI mask into a declared region before it can be used as an address.
 */

import {
  DEFAULT_MAX_DYNAMIC,
  decodeWord,
  INSTR_STORE_DEPTH,
  MAX_INFLIGHT_PER_TASK,
  MAX_LOOP_NEST,
  MEMCPY_FLAG_LEN_FROM_REG,
  NUM_REGS,
  Op,
  Sub,
  U64_MASK,
} from './isa';
import type { Program } from './asm';

export interface Region {
  id: number;
  device: number;
  name: string;
  size: bigint;
  base?: bigint;
}

export interface Argument {
  name: string;
  reg: number;
  lo: bigint;
  hi: bigint;
  region?: [number, number]; // (device, region_id)
}

export interface Manifest {
  name: string;
  version: number;
  maxDynamic: number;
  regions: Region[];
  arguments: Argument[];
}

// --- abstract value lattice ------------------------------------------

class AbsVal {
  lo: bigint;
  hi: bigint;
  region: [number, number] | null;
  opaque: boolean;
  constructor(lo: bigint, hi: bigint, region: [number, number] | null = null, opaque = false) {
    this.lo = lo;
    this.hi = hi;
    this.region = region;
    this.opaque = opaque;
  }
  static top(): AbsVal {
    return new AbsVal(0n, U64_MASK, null, true);
  }
  static const(v: bigint): AbsVal {
    v &= U64_MASK;
    return new AbsVal(v, v);
  }
  add(o: AbsVal): AbsVal {
    if (this.opaque || o.opaque) return AbsVal.top();
    return new AbsVal((this.lo + o.lo) & U64_MASK, (this.hi + o.hi) & U64_MASK, this.region || o.region);
  }
  shl(sh: bigint): AbsVal {
    sh &= 63n;
    if (this.opaque) return AbsVal.top();
    return new AbsVal((this.lo << sh) & U64_MASK, (this.hi << sh) & U64_MASK);
  }
  andi(mask: bigint): AbsVal {
    if (mask === 0n) return AbsVal.const(0n);
    return new AbsVal(0n, mask);
  }
}

export interface VerifyReport {
  ok: boolean;
  name: string;
  version: number;
  nWords: number;
  nInstructions: number;
  staticStepBound: number;
  maxInflightAsync: number;
  issues: string[];
  notes: string[];
}

function absBase(r: Region): bigint {
  return (BigInt(r.device) << 48n) | (BigInt(r.id) << 32n) | (r.base ?? 0n);
}

function checkAddrReg(
  report: VerifyReport,
  absState: Map<number, AbsVal>,
  reg: number,
  regionSet: Map<string, Region>,
  pc: number,
  kind: string,
): void {
  const av = absState.get(reg) ?? AbsVal.top();
  if (av.opaque) {
    report.ok = false;
    report.issues.push(
      `pc 0x${pc.toString(16)}: ${kind} via r${reg} is opaque (post-LOAD). ` +
        `Insert \`ANDI r${reg}, r${reg}, MASK\` to clamp into a declared region's offset window before using as address.`,
    );
    return;
  }
  if (av.region !== null) {
    const region = regionSet.get(`${av.region[0]},${av.region[1]}`);
    if (!region) {
      report.ok = false;
      report.issues.push(`pc 0x${pc.toString(16)}: ${kind} targets undeclared region ${av.region}`);
      return;
    }
    const ab = absBase(region);
    if (av.lo < ab || av.hi > ab + region.size) {
      report.ok = false;
      report.issues.push(
        `pc 0x${pc.toString(16)}: ${kind} addr range [0x${av.lo.toString(16)},0x${av.hi.toString(16)}] ` +
          `escapes region ${region.name} [0x${ab.toString(16)},0x${(ab + region.size).toString(16)})`,
      );
    }
    return;
  }
  // bounded but region-less: find smallest declared region containing [lo,hi]
  const candidates = [...regionSet.values()].filter(
    (r) => av.lo >= absBase(r) && av.hi <= absBase(r) + r.size,
  );
  if (candidates.length === 0) {
    report.ok = false;
    report.issues.push(
      `pc 0x${pc.toString(16)}: ${kind} via r${reg} masked range ` +
        `[0x${av.lo.toString(16)},0x${av.hi.toString(16)}] does not fit in any declared region`,
    );
    return;
  }
  const chosen = candidates.reduce((a, b) => (a.size <= b.size ? a : b));
  report.notes.push(
    `pc 0x${pc.toString(16)}: ${kind} via r${reg} matched implicit region ${chosen.name} ` +
      `(range [0x${av.lo.toString(16)},0x${av.hi.toString(16)}])`,
  );
}

function absCompute(sub: number, a: AbsVal, b: AbsVal, imm: bigint): AbsVal {
  switch (sub) {
    case Sub.LI:
      return AbsVal.const(imm & U64_MASK);
    case Sub.ADDI:
      return a.add(AbsVal.const(imm & U64_MASK));
    case Sub.ANDI:
      return a.andi(imm & U64_MASK);
    case Sub.SHLI:
      return a.shl(imm);
    case Sub.ADD:
      return a.add(b);
    default:
      return AbsVal.top();
  }
}

export function verify(prog: Program, manifest: Manifest): VerifyReport {
  const report: VerifyReport = {
    ok: true,
    name: manifest.name,
    version: manifest.version,
    nWords: prog.words.length,
    nInstructions: prog.instrs.length,
    staticStepBound: 0,
    maxInflightAsync: 0,
    issues: [],
    notes: [],
  };

  if (prog.words.length > INSTR_STORE_DEPTH) {
    report.ok = false;
    report.issues.push(`binary ${prog.words.length} words exceeds store depth ${INSTR_STORE_DEPTH}`);
  }

  // decode
  const decoded: { pc: number; d: ReturnType<typeof decodeWord> }[] = [];
  let pc = 0;
  while (pc < prog.words.length) {
    const d = decodeWord(prog.words[pc]);
    decoded.push({ pc, d });
    pc += d.op === Op.MEMCPY || d.op === Op.CAS || d.op === Op.CAA ? 2 : 1;
  }

  let bound = 0;
  let inflightMax = 0;
  let inflightNow = 0;
  const loopFrames: [number, number][] = []; // [endWordPc, maxIters]
  const regionSet = new Map<string, Region>();
  for (const r of manifest.regions) regionSet.set(`${r.device},${r.id}`, r);

  const absState = new Map<number, AbsVal>();
  for (let r = 0; r < NUM_REGS; r++) absState.set(r, AbsVal.top());
  absState.set(0, AbsVal.const(0n));
  for (const arg of manifest.arguments) {
    absState.set(arg.reg, new AbsVal(arg.lo, arg.hi, arg.region ?? null));
  }

  let sawRet = false;
  for (const { pc, d } of decoded) {
    const { op, rd, rs1, rs2, sub, imm } = d;

    while (loopFrames.length && pc >= loopFrames[loopFrames.length - 1][0]) {
      loopFrames.pop();
    }
    let outer = 1;
    for (const [, iters] of loopFrames) outer *= Math.max(1, iters);
    bound += outer;

    if (op === Op.JUMP) {
      if (imm <= 0n) {
        report.ok = false;
        report.issues.push(`pc 0x${pc.toString(16)}: backward JUMP not allowed (imm=${imm})`);
      }
      if (pc + Number(imm) >= prog.words.length) {
        report.ok = false;
        report.issues.push(`pc 0x${pc.toString(16)}: JUMP out of range`);
      }
    } else if (op === Op.LOOP) {
      const bodyLen = Number(imm);
      if (bodyLen <= 0) {
        report.ok = false;
        report.issues.push(`pc 0x${pc.toString(16)}: LOOP body must be > 0`);
      }
      if (pc + 1 + bodyLen > prog.words.length) {
        report.ok = false;
        report.issues.push(`pc 0x${pc.toString(16)}: LOOP body extends past end`);
      }
      if (loopFrames.length >= MAX_LOOP_NEST) {
        report.ok = false;
        report.issues.push(`pc 0x${pc.toString(16)}: loop nesting exceeds ${MAX_LOOP_NEST}`);
      }
      const cntAv = absState.get(rs1) ?? AbsVal.top();
      let iters = cntAv.opaque ? manifest.maxDynamic : Number(cntAv.hi);
      iters = Math.max(1, Math.min(iters, manifest.maxDynamic));
      loopFrames.push([pc + 1 + bodyLen, iters]);
    } else if (op === Op.RET) {
      sawRet = true;
    } else if (op === Op.WAIT) {
      inflightNow = Math.min(inflightNow, Number(imm));
    } else if (op === Op.MEMCPY) {
      const flags = sub;
      inflightNow = Math.min(MAX_INFLIGHT_PER_TASK, inflightNow + 1);
      inflightMax = Math.max(inflightMax, inflightNow);
      checkAddrReg(report, absState, rs1, regionSet, pc, 'MEMCPY dst');
      checkAddrReg(report, absState, rs2, regionSet, pc, 'MEMCPY src');
      if (!(flags & MEMCPY_FLAG_LEN_FROM_REG)) {
        if (imm < 0n || imm > 1n << 32n) {
          report.ok = false;
          report.issues.push(`pc 0x${pc.toString(16)}: MEMCPY length ${imm} unreasonable`);
        }
      }
    } else if (op === Op.LOAD || op === Op.STORE) {
      checkAddrReg(report, absState, rs1, regionSet, pc, op === Op.LOAD ? 'LOAD' : 'STORE');
      if (op === Op.LOAD) absState.set(rd, AbsVal.top());
    } else if (op === Op.CAS || op === Op.CAA) {
      checkAddrReg(report, absState, rs1, regionSet, pc, 'CAS/CAA addr');
      absState.set(rd, AbsVal.top());
    } else if (op === Op.COMPUTE) {
      const v = absCompute(sub, absState.get(rs1) ?? AbsVal.top(), absState.get(rs2) ?? AbsVal.top(), imm);
      if (rd !== 0) absState.set(rd, v);
    } else if (op === Op.NOP) {
      // no-op
    } else {
      report.ok = false;
      report.issues.push(`pc 0x${pc.toString(16)}: unknown opcode 0x${op.toString(16)}`);
    }

    if (bound > manifest.maxDynamic) {
      report.ok = false;
      report.issues.push(`static step bound ${bound} exceeds max_dynamic ${manifest.maxDynamic}`);
      break;
    }
  }

  if (!sawRet) {
    report.ok = false;
    report.issues.push('operator has no RET on at least one path');
  }
  if (inflightMax > MAX_INFLIGHT_PER_TASK) {
    report.ok = false;
    report.issues.push(`max in-flight async ${inflightMax} > ${MAX_INFLIGHT_PER_TASK}`);
  }

  report.staticStepBound = bound;
  report.maxInflightAsync = inflightMax;
  return report;
}

/** A permissive default manifest for user programs: a couple of generous
 * local regions and unconstrained arguments. */
export function defaultManifest(name = 'user_op'): Manifest {
  return {
    name,
    version: 1,
    maxDynamic: DEFAULT_MAX_DYNAMIC,
    regions: [
      { id: 0, device: 0, name: 'region0', size: 0x80000000n },
      { id: 1, device: 0, name: 'region1', size: 0x20000000n },
      { id: 0, device: 1, name: 'peer1', size: 0x80000000n },
      { id: 0, device: 2, name: 'peer2', size: 0x80000000n },
    ],
    arguments: [],
  };
}
