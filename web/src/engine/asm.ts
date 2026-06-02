/**
 * Tiara assembler — TypeScript port of `sw/asm/tiara_asm.py`.
 *
 * Two-pass assembler: reads `.tasm` source, emits 64-bit instruction
 * words plus a symbol table. Grammar (line-oriented; `#` and `//` start
 * comments):
 *
 *     label:                       # define a label
 *     .arg name reg                # bind argument <name> to <reg>
 *     .const NAME = expr           # text-time constant (decimal / 0x...)
 *     .region NAME id              # name a region id
 *     LOAD   r1, [r2 + 16]
 *     STORE  [r2 + 16], r1
 *     ADD    r1, r2, r3
 *     ADDI   r1, r2, 8
 *     LI     r1, 0x42
 *     JUMP   r3, label             # forward-only
 *     LOOP   r4, body_label        # body length follows
 *     WAIT   0
 *     RET    r0
 *     MEMCPY r0, r2, r3, ASYNC, LEN=4096
 *     CAS    r0, r1, r2, r3        # rd, addr, expected, new
 *     CAA    r0, r1, r2            # rd, addr, addend
 */

import {
  INSTR_STORE_DEPTH,
  Instr,
  MEMCPY_FLAG_ASYNC,
  MEMCPY_FLAG_LEN_FROM_REG,
  MEMCPY_FLAG_STRIDED_GATHER,
  MEMCPY_FLAG_STRIDED_SCAT,
  NUM_REGS,
  Op,
  Sub,
} from './isa';

const REG_RE = /^r(\d+)$/i;
const HEX_RE = /^0[xX][0-9a-fA-F_]+$/;
const DEC_RE = /^-?\d[\d_]*$/;
const LABEL_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

export class AsmError extends Error {
  lineno: number;
  constructor(lineno: number, msg: string) {
    super(`line ${lineno}: ${msg}`);
    this.lineno = lineno;
    this.name = 'AsmError';
  }
}

function parseIntTok(tok: string, consts: Record<string, bigint>, lineno: number): bigint {
  tok = tok.trim();
  if (tok in consts) return consts[tok];
  if (HEX_RE.test(tok)) return BigInt(tok.replace(/_/g, ''));
  if (DEC_RE.test(tok)) return BigInt(tok.replace(/_/g, ''));
  throw new AsmError(lineno, `expected integer, got ${JSON.stringify(tok)}`);
}

function parseReg(tok: string, lineno: number): number {
  const m = REG_RE.exec(tok.trim());
  if (!m) throw new AsmError(lineno, `expected register, got ${JSON.stringify(tok)}`);
  const idx = parseInt(m[1], 10);
  if (!(idx >= 0 && idx < NUM_REGS)) {
    throw new AsmError(lineno, `register r${idx} out of range`);
  }
  return idx;
}

/** Parse `[rN + imm]` or `[rN]` -> [reg, imm]. */
function parseMemOperand(tok: string, lineno: number): [number, bigint] {
  const s = tok.trim();
  if (!(s.startsWith('[') && s.endsWith(']'))) {
    throw new AsmError(lineno, `expected [rN + imm], got ${JSON.stringify(tok)}`);
  }
  const inner = s.slice(1, -1).trim();
  if (inner.includes('+')) {
    const i = inner.indexOf('+');
    const a = inner.slice(0, i);
    const b = inner.slice(i + 1);
    return [parseReg(a.trim(), lineno), parseIntTok(b.trim(), {}, lineno)];
  }
  if (inner.includes('-') && inner.trimStart().toLowerCase().startsWith('r')) {
    const i = inner.indexOf('-');
    const a = inner.slice(0, i);
    const b = inner.slice(i + 1);
    return [parseReg(a.trim(), lineno), -parseIntTok(b.trim(), {}, lineno)];
  }
  return [parseReg(inner, lineno), 0n];
}

type MnResult = [Instr, string | null];
type Mnemonic = (args: string[], lineno: number) => MnResult;

const mnLoad: Mnemonic = (args, lineno) => {
  if (args.length !== 2) throw new AsmError(lineno, 'LOAD rd, [rs1 + imm]');
  const rd = parseReg(args[0], lineno);
  const [rs1, imm] = parseMemOperand(args[1], lineno);
  return [new Instr(Op.LOAD, { rd, rs1, imm40: imm }), null];
};

const mnStore: Mnemonic = (args, lineno) => {
  if (args.length !== 2) throw new AsmError(lineno, 'STORE [rs1 + imm], rs2');
  const [rs1, imm] = parseMemOperand(args[0], lineno);
  const rs2 = parseReg(args[1], lineno);
  return [new Instr(Op.STORE, { rs1, rs2, imm40: imm }), null];
};

function mnCompute(sub: Sub, hasImm: boolean): Mnemonic {
  return (args, lineno) => {
    if (sub === Sub.LI) {
      if (args.length !== 2) throw new AsmError(lineno, 'LI rd, imm');
      const rd = parseReg(args[0], lineno);
      const imm = parseIntTok(args[1], {}, lineno);
      return [new Instr(Op.COMPUTE, { rd, sub, imm40: imm }), null];
    }
    if (hasImm) {
      if (args.length !== 3) throw new AsmError(lineno, `${Sub[sub]} rd, rs1, imm`);
      const rd = parseReg(args[0], lineno);
      const rs1 = parseReg(args[1], lineno);
      const imm = parseIntTok(args[2], {}, lineno);
      return [new Instr(Op.COMPUTE, { rd, rs1, sub, imm40: imm }), null];
    }
    if (args.length !== 3) throw new AsmError(lineno, `${Sub[sub]} rd, rs1, rs2`);
    const rd = parseReg(args[0], lineno);
    const rs1 = parseReg(args[1], lineno);
    const rs2 = parseReg(args[2], lineno);
    return [new Instr(Op.COMPUTE, { rd, rs1, rs2, sub }), null];
  };
}

const mnJump: Mnemonic = (args, lineno) => {
  if (args.length !== 2) throw new AsmError(lineno, 'JUMP cond_reg, label');
  const rs1 = parseReg(args[0], lineno);
  const target = args[1].trim();
  if (!LABEL_RE.test(target)) {
    throw new AsmError(lineno, `JUMP target must be a label, got ${JSON.stringify(target)}`);
  }
  return [new Instr(Op.JUMP, { rs1 }), target];
};

const mnLoop: Mnemonic = (args, lineno) => {
  if (args.length !== 2) throw new AsmError(lineno, 'LOOP count_reg, body_label');
  const rs1 = parseReg(args[0], lineno);
  const target = args[1].trim();
  if (!LABEL_RE.test(target)) {
    throw new AsmError(lineno, `LOOP body must be a label, got ${JSON.stringify(target)}`);
  }
  return [new Instr(Op.LOOP, { rs1 }), target];
};

const mnWait: Mnemonic = (args, lineno) => {
  if (args.length !== 1) throw new AsmError(lineno, 'WAIT threshold');
  const threshold = parseIntTok(args[0], {}, lineno);
  return [new Instr(Op.WAIT, { imm40: threshold }), null];
};

const mnRet: Mnemonic = (args, lineno) => {
  if (args.length > 1) throw new AsmError(lineno, 'RET [rN]');
  const rs1 = args.length ? parseReg(args[0], lineno) : 0;
  return [new Instr(Op.RET, { rs1 }), null];
};

const MEMCPY_FLAGS: Record<string, number> = {
  ASYNC: MEMCPY_FLAG_ASYNC,
  LEN_REG: MEMCPY_FLAG_LEN_FROM_REG,
  STRIDED_GATHER: MEMCPY_FLAG_STRIDED_GATHER,
  STRIDED_SCAT: MEMCPY_FLAG_STRIDED_SCAT,
};

const mnMemcpy: Mnemonic = (args, lineno) => {
  if (args.length < 3) throw new AsmError(lineno, 'MEMCPY rd, rs_dst, rs_src, [flags...]');
  const rd = parseReg(args[0], lineno);
  const rsDst = parseReg(args[1], lineno);
  const rsSrc = parseReg(args[2], lineno);
  let flags = 0;
  let length = 0n;
  let lenReg = 0;
  let dstStrideReg = 0;
  let srcStrideReg = 0;
  let countReg = 0;
  for (let kv of args.slice(3)) {
    kv = kv.trim();
    if (kv.includes('=')) {
      const i = kv.indexOf('=');
      const k = kv.slice(0, i).trim().toUpperCase();
      const v = kv.slice(i + 1).trim();
      if (k === 'LEN') length = parseIntTok(v, {}, lineno);
      else if (k === 'LEN_REG') {
        lenReg = parseReg(v, lineno);
        flags |= MEMCPY_FLAG_LEN_FROM_REG;
      } else if (k === 'DST_STRIDE') {
        dstStrideReg = parseReg(v, lineno);
        flags |= MEMCPY_FLAG_STRIDED_SCAT;
      } else if (k === 'SRC_STRIDE') {
        srcStrideReg = parseReg(v, lineno);
        flags |= MEMCPY_FLAG_STRIDED_GATHER;
      } else if (k === 'COUNT') {
        countReg = parseReg(v, lineno);
      } else {
        throw new AsmError(lineno, `unknown MEMCPY key ${JSON.stringify(k)}`);
      }
    } else {
      const tok = kv.toUpperCase();
      if (tok in MEMCPY_FLAGS) flags |= MEMCPY_FLAGS[tok];
      else throw new AsmError(lineno, `unknown MEMCPY flag ${JSON.stringify(tok)}`);
    }
  }
  const head = new Instr(Op.MEMCPY, { rd, rs1: rsDst, rs2: rsSrc, sub: flags, imm40: length });
  head.extra = new Instr(Op.NOP, {
    rd: lenReg,
    rs1: dstStrideReg,
    rs2: srcStrideReg,
    sub: countReg,
  });
  return [head, null];
};

const mnCas: Mnemonic = (args, lineno) => {
  if (args.length !== 4) throw new AsmError(lineno, 'CAS rd, rs_addr, rs_expected, rs_new');
  const rd = parseReg(args[0], lineno);
  const a = parseReg(args[1], lineno);
  const e = parseReg(args[2], lineno);
  const n = parseReg(args[3], lineno);
  const head = new Instr(Op.CAS, { rd, rs1: a, rs2: e });
  head.extra = new Instr(Op.NOP, { rd: n });
  return [head, null];
};

const mnCaa: Mnemonic = (args, lineno) => {
  if (args.length !== 3) throw new AsmError(lineno, 'CAA rd, rs_addr, rs_addend');
  const rd = parseReg(args[0], lineno);
  const a = parseReg(args[1], lineno);
  const add = parseReg(args[2], lineno);
  const head = new Instr(Op.CAA, { rd, rs1: a, rs2: add });
  head.extra = new Instr(Op.NOP);
  return [head, null];
};

const MNEMONICS: Record<string, Mnemonic> = {
  NOP: () => [new Instr(Op.NOP), null],
  LOAD: mnLoad,
  STORE: mnStore,
  JUMP: mnJump,
  LOOP: mnLoop,
  WAIT: mnWait,
  RET: mnRet,
  MEMCPY: mnMemcpy,
  CAS: mnCas,
  CAA: mnCaa,
  ADD: mnCompute(Sub.ADD, false),
  SUB: mnCompute(Sub.SUB, false),
  AND: mnCompute(Sub.AND, false),
  OR: mnCompute(Sub.OR, false),
  XOR: mnCompute(Sub.XOR, false),
  SHL: mnCompute(Sub.SHL, false),
  SHR: mnCompute(Sub.SHR, false),
  MUL: mnCompute(Sub.MUL, false),
  ADDI: mnCompute(Sub.ADDI, true),
  ANDI: mnCompute(Sub.ANDI, true),
  SHLI: mnCompute(Sub.SHLI, true),
  SHRI: mnCompute(Sub.SHRI, true),
  LI: mnCompute(Sub.LI, true),
  EQ: mnCompute(Sub.EQ, false),
  LT: mnCompute(Sub.LT, false),
  GE: mnCompute(Sub.GE, false),
};

interface Pending {
  instr: Instr;
  labelRef: string | null;
  pc: number;
  lineno: number;
}

export interface Program {
  name: string;
  words: bigint[];
  labels: Record<string, number>;
  args: Record<string, number>;
  consts: Record<string, bigint>;
  regions: Record<string, number>;
  instrs: Instr[];
  /** word offset -> index into `instrs`, for the simulator's PC mapping. */
  pcToInstr: Map<number, number>;
}

export function toHex(prog: Program): string {
  return prog.words.map((w) => w.toString(16).padStart(16, '0')).join('\n') + '\n';
}

export function toBin(prog: Program): Uint8Array {
  const out = new Uint8Array(prog.words.length * 8);
  const dv = new DataView(out.buffer);
  prog.words.forEach((w, i) => dv.setBigUint64(i * 8, w, true));
  return out;
}

export function assemble(source: string, name = 'anon'): Program {
  const consts: Record<string, bigint> = {};
  const args: Record<string, number> = {};
  const regions: Record<string, number> = {};
  const pendings: Pending[] = [];
  const labels: Record<string, number> = {};

  let pc = 0;

  const lines = source.split('\n');
  for (let rawLineno = 1; rawLineno <= lines.length; rawLineno++) {
    const rawLine = lines[rawLineno - 1];
    let line = rawLine.split('//')[0].split('#')[0].replace(/\s+$/, '');
    if (!line.trim()) continue;

    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/.exec(line);
    if (m) {
      const lbl = m[1];
      if (lbl in labels) throw new AsmError(rawLineno, `duplicate label ${JSON.stringify(lbl)}`);
      labels[lbl] = pc;
      line = m[2];
      if (!line.trim()) continue;
    }
    const s = line.trim();

    if (s.startsWith('.')) {
      const tok = s.split(/\s+/);
      const d = tok[0].toLowerCase();
      if (d === '.arg') {
        if (tok.length !== 3) throw new AsmError(rawLineno, '.arg name reg');
        args[tok[1]] = parseReg(tok[2], rawLineno);
      } else if (d === '.const') {
        const m2 = /\.const\s+([A-Za-z_]\w*)\s*=\s*(.+)$/.exec(s);
        if (!m2) throw new AsmError(rawLineno, '.const NAME = expr');
        consts[m2[1]] = parseIntTok(m2[2], consts, rawLineno);
      } else if (d === '.region') {
        if (tok.length !== 3) throw new AsmError(rawLineno, '.region name id');
        regions[tok[1]] = Number(parseIntTok(tok[2], consts, rawLineno));
      } else {
        throw new AsmError(rawLineno, `unknown directive ${JSON.stringify(d)}`);
      }
      continue;
    }

    // Instruction: split head + operand string
    const headMatch = /^(\S+)(?:\s+([\s\S]*))?$/.exec(s);
    const head = headMatch![1].toUpperCase();
    const operandStr = headMatch![2] ?? '';
    const operands: string[] = [];
    if (operandStr) {
      let depth = 0;
      let buf = '';
      for (const ch of operandStr) {
        if (ch === '[') {
          depth++;
          buf += ch;
        } else if (ch === ']') {
          depth--;
          buf += ch;
        } else if (ch === ',' && depth === 0) {
          operands.push(buf.trim());
          buf = '';
        } else {
          buf += ch;
        }
      }
      if (buf.trim()) operands.push(buf.trim());
    }

    // Substitute consts in plain operands.
    const subbed = operands.map((o) => (o in consts ? consts[o].toString() : o));

    if (!(head in MNEMONICS)) {
      throw new AsmError(rawLineno, `unknown mnemonic ${JSON.stringify(head)}`);
    }
    const [instr, ref] = MNEMONICS[head](subbed, rawLineno);
    instr.src = rawLine.trim();
    pendings.push({ instr, labelRef: ref, pc, lineno: rawLineno });
    pc += instr.width;
  }

  if (pc > INSTR_STORE_DEPTH) {
    throw new AsmError(0, `program too large: ${pc} words > ${INSTR_STORE_DEPTH}`);
  }

  const instrs: Instr[] = [];
  const words: bigint[] = [];
  const pcToInstr = new Map<number, number>();
  for (const p of pendings) {
    if (p.labelRef !== null) {
      if (!(p.labelRef in labels)) {
        throw new AsmError(p.lineno, `undefined label ${JSON.stringify(p.labelRef)}`);
      }
      const target = labels[p.labelRef];
      const offset = target - p.pc;
      if (p.instr.opcode === Op.JUMP) {
        if (offset <= 0) {
          throw new AsmError(
            p.lineno,
            `forward-only JUMP, but ${JSON.stringify(p.labelRef)} is backward (delta ${offset})`,
          );
        }
        p.instr.imm40 = BigInt(offset);
      } else if (p.instr.opcode === Op.LOOP) {
        const bodyLen = target - (p.pc + 1);
        if (bodyLen <= 0) {
          throw new AsmError(
            p.lineno,
            `LOOP body label ${JSON.stringify(p.labelRef)} must be after the LOOP`,
          );
        }
        p.instr.imm40 = BigInt(bodyLen);
      } else {
        p.instr.imm40 = BigInt(offset);
      }
    }
    pcToInstr.set(p.pc, instrs.length);
    for (const w of p.instr.encode()) words.push(w);
    instrs.push(p.instr);
  }

  return { name, words, labels, args, consts, regions, instrs, pcToInstr };
}
