/**
 * Tiara ISA encoding primitives.
 *
 * Direct TypeScript port of `sw/asm/tiara_isa.py` — the single source of
 * truth for opcode and sub-opcode numbering shared by the RTL, assembler,
 * verifier, and client library. 64-bit words are represented as `bigint`
 * so encode/decode is byte-exact with the Python reference.
 */

// --- opcodes ---------------------------------------------------------

export enum Op {
  NOP = 0x00,
  LOAD = 0x01,
  STORE = 0x02,
  JUMP = 0x10,
  LOOP = 0x11,
  WAIT = 0x12,
  RET = 0x13,
  COMPUTE = 0x20,
  // Two-word opcodes (top bit set)
  MEMCPY = 0x83,
  CAS = 0x84,
  CAA = 0x85,
}

export const TWO_WORD_OPCODES = new Set<number>([Op.MEMCPY, Op.CAS, Op.CAA]);

/** COMPUTE sub-opcodes. */
export enum Sub {
  ADD = 0x0,
  SUB = 0x1,
  AND = 0x2,
  OR = 0x3,
  XOR = 0x4,
  SHL = 0x5,
  SHR = 0x6,
  MUL = 0x7,
  ADDI = 0x8,
  ANDI = 0x9,
  SHLI = 0xa,
  SHRI = 0xb,
  LI = 0xc,
  EQ = 0xd,
  LT = 0xe,
  GE = 0xf,
}

export const SUB_NAME: Record<number, string> = Object.fromEntries(
  Object.entries(Sub)
    .filter(([, v]) => typeof v === 'number')
    .map(([k, v]) => [v as number, k]),
);

export const OP_NAME: Record<number, string> = Object.fromEntries(
  Object.entries(Op)
    .filter(([, v]) => typeof v === 'number')
    .map(([k, v]) => [v as number, k]),
);

// --- MEMCPY flag bits ------------------------------------------------

export const MEMCPY_FLAG_ASYNC = 1 << 0;
export const MEMCPY_FLAG_LEN_FROM_REG = 1 << 1;
export const MEMCPY_FLAG_STRIDED_GATHER = 1 << 2;
export const MEMCPY_FLAG_STRIDED_SCAT = 1 << 3;

// --- limits ----------------------------------------------------------

export const NUM_REGS = 16;
export const INSTR_STORE_DEPTH = 1024;
export const MAX_LOOP_NEST = 8;
export const MAX_INFLIGHT_PER_TASK = 32;
export const DEFAULT_MAX_DYNAMIC = 4096;

export const ADDR_DEVICE_BITS = 16;
export const ADDR_REGION_BITS = 16;
export const ADDR_OFFSET_BITS = 32;

export const INSTR_BYTES = 8;

// --- 64-bit helpers --------------------------------------------------

export const U64_MASK = (1n << 64n) - 1n;
export const mask64 = (v: bigint): bigint => v & U64_MASK;

// --- encoding --------------------------------------------------------

const OPCODE_SHIFT = 56n;
const RD_SHIFT = 52n;
const RS1_SHIFT = 48n;
const RS2_SHIFT = 44n;
const SUB_SHIFT = 40n;
const IMM_MASK = (1n << 40n) - 1n;

function checkReg(name: string, idx: number): number {
  if (!(idx >= 0 && idx < NUM_REGS)) {
    throw new Error(`${name} = ${idx} is out of range [0, ${NUM_REGS - 1}]`);
  }
  return idx;
}

/** Convert a signed integer to a 40-bit two's-complement field. */
function checkImm40(value: bigint): bigint {
  const lo = -(1n << 39n);
  const hi = (1n << 40n) - 1n;
  if (!(value >= lo && value <= hi)) {
    throw new Error(`imm40 = ${value} does not fit in signed 40 bits`);
  }
  return value & IMM_MASK;
}

export function encodeWord(
  opcode: number,
  rd = 0,
  rs1 = 0,
  rs2 = 0,
  sub = 0,
  imm40: bigint = 0n,
): bigint {
  if (!(opcode >= 0 && opcode <= 0xff)) {
    throw new Error(`opcode ${opcode} out of range`);
  }
  rd = checkReg('rd', rd);
  rs1 = checkReg('rs1', rs1);
  rs2 = checkReg('rs2', rs2);
  if (!(sub >= 0 && sub <= 0xf)) {
    throw new Error(`sub ${sub} out of range`);
  }
  const imm = checkImm40(imm40);
  return (
    (BigInt(opcode & 0xff) << OPCODE_SHIFT) |
    (BigInt(rd & 0xf) << RD_SHIFT) |
    (BigInt(rs1 & 0xf) << RS1_SHIFT) |
    (BigInt(rs2 & 0xf) << RS2_SHIFT) |
    (BigInt(sub & 0xf) << SUB_SHIFT) |
    imm
  );
}

export interface Decoded {
  op: number;
  rd: number;
  rs1: number;
  rs2: number;
  sub: number;
  imm: bigint; // sign-extended from 40 bits
}

export function decodeWord(word: bigint): Decoded {
  const op = Number((word >> OPCODE_SHIFT) & 0xffn);
  const rd = Number((word >> RD_SHIFT) & 0xfn);
  const rs1 = Number((word >> RS1_SHIFT) & 0xfn);
  const rs2 = Number((word >> RS2_SHIFT) & 0xfn);
  const sub = Number((word >> SUB_SHIFT) & 0xfn);
  let imm = word & IMM_MASK;
  if (imm & (1n << 39n)) {
    imm -= 1n << 40n;
  }
  return { op, rd, rs1, rs2, sub, imm };
}

// --- assembled-instruction representation ---------------------------

export class Instr {
  opcode: Op;
  rd: number;
  rs1: number;
  rs2: number;
  sub: number;
  imm40: bigint;
  extra: Instr | null = null;
  label: string | null = null;
  src: string | null = null;

  constructor(
    opcode: Op,
    opts: {
      rd?: number;
      rs1?: number;
      rs2?: number;
      sub?: number;
      imm40?: bigint;
    } = {},
  ) {
    this.opcode = opcode;
    this.rd = opts.rd ?? 0;
    this.rs1 = opts.rs1 ?? 0;
    this.rs2 = opts.rs2 ?? 0;
    this.sub = opts.sub ?? 0;
    this.imm40 = opts.imm40 ?? 0n;
  }

  get width(): number {
    return TWO_WORD_OPCODES.has(this.opcode) ? 2 : 1;
  }

  encode(): bigint[] {
    const words = [
      encodeWord(this.opcode, this.rd, this.rs1, this.rs2, this.sub, this.imm40),
    ];
    if (TWO_WORD_OPCODES.has(this.opcode)) {
      if (this.extra === null) {
        throw new Error(`two-word opcode ${this.opcode} missing extra`);
      }
      words.push(
        encodeWord(
          0,
          this.extra.rd,
          this.extra.rs1,
          this.extra.rs2,
          this.extra.sub,
          this.extra.imm40,
        ),
      );
    }
    return words;
  }
}

// --- unified address helpers ----------------------------------------

export function makeAddr(device: number, region: number, offset: number | bigint): bigint {
  const off = BigInt(offset);
  if (!(device >= 0 && device < 1 << ADDR_DEVICE_BITS)) {
    throw new Error(`device ${device} out of range`);
  }
  if (!(region >= 0 && region < 1 << ADDR_REGION_BITS)) {
    throw new Error(`region ${region} out of range`);
  }
  if (!(off >= 0n && off < 1n << BigInt(ADDR_OFFSET_BITS))) {
    throw new Error(`offset ${off} out of range`);
  }
  return (
    (BigInt(device) << BigInt(ADDR_REGION_BITS + ADDR_OFFSET_BITS)) |
    (BigInt(region) << BigInt(ADDR_OFFSET_BITS)) |
    off
  );
}

export function splitAddr(addr: bigint): {
  device: number;
  region: number;
  offset: bigint;
} {
  const offset = addr & ((1n << BigInt(ADDR_OFFSET_BITS)) - 1n);
  const region = Number(
    (addr >> BigInt(ADDR_OFFSET_BITS)) & ((1n << BigInt(ADDR_REGION_BITS)) - 1n),
  );
  const device = Number(
    (addr >> BigInt(ADDR_OFFSET_BITS + ADDR_REGION_BITS)) &
      ((1n << BigInt(ADDR_DEVICE_BITS)) - 1n),
  );
  return { device, region, offset };
}
