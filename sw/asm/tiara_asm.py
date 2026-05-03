"""
Tiara assembler.

A small two-pass assembler for the Tiara ISA.  Reads a `.tasm` file (or
string), emits a list of 64-bit instruction words plus a symbol table.

Grammar (line-oriented; `#` and `//` start comments):

    label:                       # define a label
    .arg name reg                # bind argument <name> to <reg> (doc only)
    .const NAME = expr           # text-time constant (decimal / 0x...)
    .region NAME id              # name a region id
    LOAD   r1, [r2 + 16]
    STORE  [r2 + 16], r1
    ADD    r1, r2, r3
    ADDI   r1, r2, 8
    LI     r1, 0x42
    JUMP   r3, label             # forward-only
    LOOP   r4, BODY:8            # body length 8 instr-words follows
    WAIT   0
    RET    r0
    MEMCPY r0, r2, r3, ASYNC|len=4096
    CAS    r0, r1, r2, r3        # rd, addr, expected, new
    CAA    r0, r1, r2            # rd, addr, addend
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from tiara_isa import (
    DEFAULT_MAX_DYNAMIC,
    INSTR_BYTES,
    INSTR_STORE_DEPTH,
    MEMCPY_FLAG_ASYNC,
    MEMCPY_FLAG_LEN_FROM_REG,
    MEMCPY_FLAG_STRIDED_GATHER,
    MEMCPY_FLAG_STRIDED_SCAT,
    NUM_REGS,
    Instr,
    Op,
    Sub,
    encode_word,
)


# ---------------------------------------------------------------------
# Token / line parsing
# ---------------------------------------------------------------------

_REG_RE   = re.compile(r"^r(\d+)$", re.IGNORECASE)
_HEX_RE   = re.compile(r"^0[xX][0-9a-fA-F_]+$")
_DEC_RE   = re.compile(r"^-?\d[\d_]*$")
_LABEL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class AsmError(Exception):
    def __init__(self, lineno: int, msg: str):
        super().__init__(f"line {lineno}: {msg}")
        self.lineno = lineno


def _parse_int(tok: str, consts: Dict[str, int], lineno: int) -> int:
    tok = tok.strip()
    if tok in consts:
        return consts[tok]
    if _HEX_RE.match(tok):
        return int(tok.replace("_", ""), 16)
    if _DEC_RE.match(tok):
        return int(tok.replace("_", ""))
    raise AsmError(lineno, f"expected integer, got {tok!r}")


def _parse_reg(tok: str, lineno: int) -> int:
    m = _REG_RE.match(tok.strip())
    if not m:
        raise AsmError(lineno, f"expected register, got {tok!r}")
    idx = int(m.group(1))
    if not 0 <= idx < NUM_REGS:
        raise AsmError(lineno, f"register r{idx} out of range")
    return idx


def _parse_mem_operand(tok: str, lineno: int) -> Tuple[int, int]:
    """Parse `[rN + imm]` or `[rN]` -> (reg, imm)."""
    s = tok.strip()
    if not (s.startswith("[") and s.endswith("]")):
        raise AsmError(lineno, f"expected [rN + imm], got {tok!r}")
    inner = s[1:-1].strip()
    if "+" in inner:
        a, b = inner.split("+", 1)
        return _parse_reg(a.strip(), lineno), _parse_int(b.strip(), {}, lineno)
    if "-" in inner and inner.lstrip().lower().startswith("r"):
        a, b = inner.split("-", 1)
        return _parse_reg(a.strip(), lineno), -_parse_int(b.strip(), {}, lineno)
    return _parse_reg(inner, lineno), 0


@dataclass
class _Pending:
    """An instruction whose immediate may reference a label."""
    instr: Instr
    label_ref: Optional[str]   # label whose offset goes into instr.imm40
    pc:        int             # word offset where this instr lives
    lineno:    int


# ---------------------------------------------------------------------
# Mnemonic dispatch
# ---------------------------------------------------------------------

def _mn_load(args, lineno):
    if len(args) != 2:
        raise AsmError(lineno, "LOAD rd, [rs1 + imm]")
    rd = _parse_reg(args[0], lineno)
    rs1, imm = _parse_mem_operand(args[1], lineno)
    return Instr(Op.LOAD, rd=rd, rs1=rs1, imm40=imm), None


def _mn_store(args, lineno):
    if len(args) != 2:
        raise AsmError(lineno, "STORE [rs1 + imm], rs2")
    rs1, imm = _parse_mem_operand(args[0], lineno)
    rs2 = _parse_reg(args[1], lineno)
    return Instr(Op.STORE, rs1=rs1, rs2=rs2, imm40=imm), None


def _mn_compute(sub: Sub, has_imm: bool):
    def go(args, lineno):
        if sub == Sub.LI:
            if len(args) != 2:
                raise AsmError(lineno, "LI rd, imm")
            rd = _parse_reg(args[0], lineno)
            imm = _parse_int(args[1], {}, lineno)
            return Instr(Op.COMPUTE, rd=rd, sub=int(sub), imm40=imm), None
        if has_imm:
            if len(args) != 3:
                raise AsmError(lineno, f"{sub.name} rd, rs1, imm")
            rd = _parse_reg(args[0], lineno)
            rs1 = _parse_reg(args[1], lineno)
            imm = _parse_int(args[2], {}, lineno)
            return Instr(Op.COMPUTE, rd=rd, rs1=rs1, sub=int(sub),
                         imm40=imm), None
        if len(args) != 3:
            raise AsmError(lineno, f"{sub.name} rd, rs1, rs2")
        rd  = _parse_reg(args[0], lineno)
        rs1 = _parse_reg(args[1], lineno)
        rs2 = _parse_reg(args[2], lineno)
        return Instr(Op.COMPUTE, rd=rd, rs1=rs1, rs2=rs2, sub=int(sub)), None
    return go


def _mn_jump(args, lineno):
    if len(args) != 2:
        raise AsmError(lineno, "JUMP cond_reg, label")
    rs1 = _parse_reg(args[0], lineno)
    target = args[1].strip()
    if not _LABEL_RE.match(target):
        raise AsmError(lineno, f"JUMP target must be a label, got {target!r}")
    return Instr(Op.JUMP, rs1=rs1), target


def _mn_loop(args, lineno):
    if len(args) != 2:
        raise AsmError(lineno, "LOOP count_reg, body_label")
    rs1 = _parse_reg(args[0], lineno)
    target = args[1].strip()
    if not _LABEL_RE.match(target):
        raise AsmError(lineno, f"LOOP body must be a label, got {target!r}")
    return Instr(Op.LOOP, rs1=rs1), target


def _mn_wait(args, lineno):
    if len(args) != 1:
        raise AsmError(lineno, "WAIT threshold")
    threshold = _parse_int(args[0], {}, lineno)
    return Instr(Op.WAIT, imm40=threshold), None


def _mn_ret(args, lineno):
    if len(args) > 1:
        raise AsmError(lineno, "RET [rN]")
    rs1 = _parse_reg(args[0], lineno) if args else 0
    return Instr(Op.RET, rs1=rs1), None


_MEMCPY_FLAGS = {
    "ASYNC":          MEMCPY_FLAG_ASYNC,
    "LEN_REG":        MEMCPY_FLAG_LEN_FROM_REG,
    "STRIDED_GATHER": MEMCPY_FLAG_STRIDED_GATHER,
    "STRIDED_SCAT":   MEMCPY_FLAG_STRIDED_SCAT,
}


def _mn_memcpy(args, lineno):
    """MEMCPY rd_status, rs_dst_addr, rs_src_addr, key=value, ..."""
    if len(args) < 3:
        raise AsmError(lineno, "MEMCPY rd, rs_dst, rs_src, [flags...]")
    rd     = _parse_reg(args[0], lineno)
    rs_dst = _parse_reg(args[1], lineno)
    rs_src = _parse_reg(args[2], lineno)
    flags = 0
    length = 0
    len_reg = 0
    dst_stride_reg = 0
    src_stride_reg = 0
    count_reg = 0
    for kv in args[3:]:
        kv = kv.strip()
        if "=" in kv:
            k, v = kv.split("=", 1)
            k = k.strip().upper()
            v = v.strip()
            if k == "LEN":
                length = _parse_int(v, {}, lineno)
            elif k == "LEN_REG":
                len_reg = _parse_reg(v, lineno)
                flags |= MEMCPY_FLAG_LEN_FROM_REG
            elif k == "DST_STRIDE":
                dst_stride_reg = _parse_reg(v, lineno)
                flags |= MEMCPY_FLAG_STRIDED_SCAT
            elif k == "SRC_STRIDE":
                src_stride_reg = _parse_reg(v, lineno)
                flags |= MEMCPY_FLAG_STRIDED_GATHER
            elif k == "COUNT":
                count_reg = _parse_reg(v, lineno)
            else:
                raise AsmError(lineno, f"unknown MEMCPY key {k!r}")
        else:
            tok = kv.upper()
            if tok in _MEMCPY_FLAGS:
                flags |= _MEMCPY_FLAGS[tok]
            else:
                raise AsmError(lineno, f"unknown MEMCPY flag {tok!r}")
    head = Instr(Op.MEMCPY, rd=rd, rs1=rs_dst, rs2=rs_src,
                 sub=flags, imm40=length)
    head.extra = Instr(Op.NOP, rd=len_reg, rs1=dst_stride_reg,
                       rs2=src_stride_reg, sub=count_reg)
    return head, None


def _mn_cas(args, lineno):
    """CAS rd, rs_addr, rs_expected, rs_new"""
    if len(args) != 4:
        raise AsmError(lineno, "CAS rd, rs_addr, rs_expected, rs_new")
    rd  = _parse_reg(args[0], lineno)
    a   = _parse_reg(args[1], lineno)
    e   = _parse_reg(args[2], lineno)
    n   = _parse_reg(args[3], lineno)
    head = Instr(Op.CAS, rd=rd, rs1=a, rs2=e)
    head.extra = Instr(Op.NOP, rd=n)
    return head, None


def _mn_caa(args, lineno):
    """CAA rd, rs_addr, rs_addend"""
    if len(args) != 3:
        raise AsmError(lineno, "CAA rd, rs_addr, rs_addend")
    rd  = _parse_reg(args[0], lineno)
    a   = _parse_reg(args[1], lineno)
    add = _parse_reg(args[2], lineno)
    head = Instr(Op.CAA, rd=rd, rs1=a, rs2=add)
    head.extra = Instr(Op.NOP)
    return head, None


_MNEMONICS = {
    "NOP":   lambda a, l: (Instr(Op.NOP), None),
    "LOAD":  _mn_load,
    "STORE": _mn_store,
    "JUMP":  _mn_jump,
    "LOOP":  _mn_loop,
    "WAIT":  _mn_wait,
    "RET":   _mn_ret,
    "MEMCPY": _mn_memcpy,
    "CAS":    _mn_cas,
    "CAA":    _mn_caa,
    # ALU
    "ADD":  _mn_compute(Sub.ADD,  False),
    "SUB":  _mn_compute(Sub.SUB,  False),
    "AND":  _mn_compute(Sub.AND,  False),
    "OR":   _mn_compute(Sub.OR,   False),
    "XOR":  _mn_compute(Sub.XOR,  False),
    "SHL":  _mn_compute(Sub.SHL,  False),
    "SHR":  _mn_compute(Sub.SHR,  False),
    "MUL":  _mn_compute(Sub.MUL,  False),
    "ADDI": _mn_compute(Sub.ADDI, True),
    "ANDI": _mn_compute(Sub.ANDI, True),
    "SHLI": _mn_compute(Sub.SHLI, True),
    "SHRI": _mn_compute(Sub.SHRI, True),
    "LI":   _mn_compute(Sub.LI,   True),
    "EQ":   _mn_compute(Sub.EQ,   False),
    "LT":   _mn_compute(Sub.LT,   False),
    "GE":   _mn_compute(Sub.GE,   False),
}


# ---------------------------------------------------------------------
# Assembler
# ---------------------------------------------------------------------

@dataclass
class Program:
    name:    str
    words:   List[int]
    labels:  Dict[str, int]    # label -> word offset
    args:    Dict[str, int]    # arg name -> register
    consts:  Dict[str, int]
    regions: Dict[str, int]
    instrs:  List[Instr]       # one entry per logical instruction

    def to_hex(self) -> str:
        return "\n".join(f"{w:016x}" for w in self.words) + "\n"

    def to_bin(self) -> bytes:
        out = bytearray()
        for w in self.words:
            out += w.to_bytes(8, "little")
        return bytes(out)


def assemble(source: str, name: str = "anon") -> Program:
    consts:  Dict[str, int] = {}
    args:    Dict[str, int] = {}
    regions: Dict[str, int] = {}
    pendings: List[_Pending] = []
    labels:  Dict[str, int] = {}

    pc = 0  # current word offset (counts both halves of two-word instrs)

    for raw_lineno, raw_line in enumerate(source.splitlines(), 1):
        line = raw_line.split("//", 1)[0].split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        # Label
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", line)
        if m:
            lbl = m.group(1)
            if lbl in labels:
                raise AsmError(raw_lineno, f"duplicate label {lbl!r}")
            labels[lbl] = pc
            line = m.group(2)
            if not line.strip():
                continue
        s = line.strip()
        # Directives
        if s.startswith("."):
            tok = s.split()
            d = tok[0].lower()
            if d == ".arg":
                if len(tok) != 3:
                    raise AsmError(raw_lineno, ".arg name reg")
                args[tok[1]] = _parse_reg(tok[2], raw_lineno)
            elif d == ".const":
                m2 = re.match(r"\.const\s+([A-Za-z_]\w*)\s*=\s*(.+)$", s)
                if not m2:
                    raise AsmError(raw_lineno, ".const NAME = expr")
                consts[m2.group(1)] = _parse_int(m2.group(2), consts, raw_lineno)
            elif d == ".region":
                if len(tok) != 3:
                    raise AsmError(raw_lineno, ".region name id")
                regions[tok[1]] = _parse_int(tok[2], consts, raw_lineno)
            else:
                raise AsmError(raw_lineno, f"unknown directive {d!r}")
            continue
        # Instruction
        head, *rest = re.split(r"\s+", s, maxsplit=1)
        head = head.upper()
        operand_str = rest[0] if rest else ""
        operands: List[str] = []
        if operand_str:
            depth = 0
            buf = ""
            for ch in operand_str:
                if ch == "[":
                    depth += 1; buf += ch
                elif ch == "]":
                    depth -= 1; buf += ch
                elif ch == "," and depth == 0:
                    operands.append(buf.strip()); buf = ""
                else:
                    buf += ch
            if buf.strip():
                operands.append(buf.strip())

        # Substitute consts in plain operands (does not affect [r+imm] which goes through _parse_int)
        operands = [consts[o] and str(consts[o]) if o in consts else o for o in operands]

        if head not in _MNEMONICS:
            raise AsmError(raw_lineno, f"unknown mnemonic {head!r}")
        instr, ref = _MNEMONICS[head](operands, raw_lineno)
        instr.src = raw_line.strip()
        pendings.append(_Pending(instr, ref, pc, raw_lineno))
        pc += instr.width

    if pc > INSTR_STORE_DEPTH:
        raise AsmError(0, f"program too large: {pc} words > {INSTR_STORE_DEPTH}")

    # Resolve label references
    instrs: List[Instr] = []
    words: List[int] = []
    for p in pendings:
        if p.label_ref is not None:
            if p.label_ref not in labels:
                raise AsmError(p.lineno, f"undefined label {p.label_ref!r}")
            target = labels[p.label_ref]
            offset = target - p.pc
            if p.instr.opcode == Op.JUMP:
                if offset <= 0:
                    raise AsmError(p.lineno,
                                   f"forward-only JUMP, but {p.label_ref!r} is "
                                   f"backward (delta {offset})")
                p.instr.imm40 = offset
            elif p.instr.opcode == Op.LOOP:
                # Body length = body_end_label - (loop_pc + 1)
                body_len = target - (p.pc + 1)
                if body_len <= 0:
                    raise AsmError(p.lineno,
                                   f"LOOP body label {p.label_ref!r} must be "
                                   f"after the LOOP")
                p.instr.imm40 = body_len
            else:
                p.instr.imm40 = offset
        for w in p.instr.encode():
            words.append(w)
        instrs.append(p.instr)

    return Program(
        name=name,
        words=words,
        labels=labels,
        args=args,
        consts=consts,
        regions=regions,
        instrs=instrs,
    )


def assemble_file(path: str | Path) -> Program:
    p = Path(path)
    return assemble(p.read_text(), name=p.stem)


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def _main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Tiara assembler")
    ap.add_argument("source",  help=".tasm source file")
    ap.add_argument("-o", "--output", help="output binary path")
    ap.add_argument("--hex",   action="store_true",
                    help="emit ASCII hex (one word per line) instead of binary")
    ap.add_argument("--listing", action="store_true",
                    help="print listing to stderr")
    args = ap.parse_args()
    prog = assemble_file(args.source)

    if args.listing:
        import sys
        offset = 0
        for instr in prog.instrs:
            words = instr.encode()
            for i, w in enumerate(words):
                tag = instr.src if i == 0 else ""
                print(f"  {offset:04x}: {w:016x}   {tag}", file=sys.stderr)
                offset += 1
        for label, off in sorted(prog.labels.items(), key=lambda kv: kv[1]):
            print(f"  label {label} = {off:04x}", file=sys.stderr)

    out = Path(args.output or args.source).with_suffix(
        ".hex" if args.hex else ".bin")
    if args.hex:
        out.write_text(prog.to_hex())
    else:
        out.write_bytes(prog.to_bin())
    print(f"wrote {out} ({len(prog.words)} words, {len(prog.words)*INSTR_BYTES} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
