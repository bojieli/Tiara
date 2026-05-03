"""
Tiara ISA encoding primitives.

This module is the single source of truth for opcode and sub-opcode
numbering. RTL (rtl/include/tiara_pkg.svh) and the Verilator testbench
import constants generated from this file (see scripts/gen_isa_pkg.py).
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import List, Optional, Tuple


# --- opcodes ---------------------------------------------------------

class Op(IntEnum):
    NOP     = 0x00
    LOAD    = 0x01
    STORE   = 0x02
    JUMP    = 0x10
    LOOP    = 0x11
    WAIT    = 0x12
    RET     = 0x13
    COMPUTE = 0x20
    # Two-word opcodes (top bit set)
    MEMCPY  = 0x83
    CAS     = 0x84
    CAA     = 0x85


TWO_WORD_OPCODES = frozenset({Op.MEMCPY, Op.CAS, Op.CAA})


class Sub(IntEnum):
    """COMPUTE sub-opcodes."""
    ADD  = 0x0
    SUB  = 0x1
    AND  = 0x2
    OR   = 0x3
    XOR  = 0x4
    SHL  = 0x5
    SHR  = 0x6
    MUL  = 0x7
    ADDI = 0x8
    ANDI = 0x9
    SHLI = 0xA
    SHRI = 0xB
    LI   = 0xC
    EQ   = 0xD
    LT   = 0xE
    GE   = 0xF


# --- MEMCPY flag bits ------------------------------------------------

MEMCPY_FLAG_ASYNC          = 1 << 0
MEMCPY_FLAG_LEN_FROM_REG   = 1 << 1
MEMCPY_FLAG_STRIDED_GATHER = 1 << 2
MEMCPY_FLAG_STRIDED_SCAT   = 1 << 3


# --- limits ----------------------------------------------------------

NUM_REGS              = 16
INSTR_STORE_DEPTH     = 1024     # per-MP slots, in 64b words (each two-word op uses 2)
MAX_LOOP_NEST         = 8
MAX_INFLIGHT_PER_TASK = 32
DEFAULT_MAX_DYNAMIC   = 4096

ADDR_DEVICE_BITS  = 16
ADDR_REGION_BITS  = 16
ADDR_OFFSET_BITS  = 32

INSTR_BYTES = 8


# --- encoding --------------------------------------------------------

_OPCODE_SHIFT = 56
_RD_SHIFT     = 52
_RS1_SHIFT    = 48
_RS2_SHIFT    = 44
_SUB_SHIFT    = 40
_IMM_MASK     = (1 << 40) - 1


def _check_reg(name: str, idx: int) -> int:
    if not 0 <= idx < NUM_REGS:
        raise ValueError(f"{name} = {idx} is out of range [0, {NUM_REGS-1}]")
    return idx


def _check_imm40(value: int) -> int:
    """Convert a signed Python int to a 40-bit two's-complement field."""
    lo, hi = -(1 << 39), (1 << 40) - 1
    if not lo <= value <= hi:
        raise ValueError(f"imm40 = {value} does not fit in signed 40 bits")
    return value & _IMM_MASK


def encode_word(opcode: int, rd: int = 0, rs1: int = 0, rs2: int = 0,
                sub: int = 0, imm40: int = 0) -> int:
    """Pack a single 64-bit Tiara instruction word."""
    if not 0 <= opcode <= 0xFF:
        raise ValueError(f"opcode {opcode:#x} out of range")
    rd  = _check_reg("rd",  rd)
    rs1 = _check_reg("rs1", rs1)
    rs2 = _check_reg("rs2", rs2)
    if not 0 <= sub <= 0xF:
        raise ValueError(f"sub {sub:#x} out of range")
    imm = _check_imm40(imm40)
    return (
        (opcode & 0xFF) << _OPCODE_SHIFT |
        (rd    & 0xF)   << _RD_SHIFT     |
        (rs1   & 0xF)   << _RS1_SHIFT    |
        (rs2   & 0xF)   << _RS2_SHIFT    |
        (sub   & 0xF)   << _SUB_SHIFT    |
        imm
    )


def decode_word(word: int) -> Tuple[int, int, int, int, int, int]:
    """Unpack a 64-bit Tiara instruction word.  Returns (op, rd, rs1, rs2, sub, imm)."""
    op  = (word >> _OPCODE_SHIFT) & 0xFF
    rd  = (word >> _RD_SHIFT)     & 0xF
    rs1 = (word >> _RS1_SHIFT)    & 0xF
    rs2 = (word >> _RS2_SHIFT)    & 0xF
    sub = (word >> _SUB_SHIFT)    & 0xF
    imm = word & _IMM_MASK
    if imm & (1 << 39):
        imm -= (1 << 40)
    return op, rd, rs1, rs2, sub, imm


# --- assembled-instruction representation ---------------------------

@dataclass
class Instr:
    """One logical instruction, possibly two encoded words wide."""
    opcode: Op
    rd:     int = 0
    rs1:    int = 0
    rs2:    int = 0
    sub:    int = 0
    imm40:  int = 0
    extra:  Optional["Instr"] = None    # second word for MEMCPY/CAS/CAA
    label:  Optional[str] = None        # for diagnostics
    src:    Optional[str] = None

    @property
    def width(self) -> int:
        return 2 if self.opcode in TWO_WORD_OPCODES else 1

    def encode(self) -> List[int]:
        words = [encode_word(int(self.opcode), self.rd, self.rs1, self.rs2,
                             self.sub, self.imm40)]
        if self.opcode in TWO_WORD_OPCODES:
            if self.extra is None:
                raise AssertionError(f"two-word opcode {self.opcode!r} missing extra")
            words.append(encode_word(0, self.extra.rd, self.extra.rs1,
                                     self.extra.rs2, self.extra.sub,
                                     self.extra.imm40))
        return words


# --- unified address helpers ----------------------------------------

def make_addr(device: int, region: int, offset: int) -> int:
    if not 0 <= device < (1 << ADDR_DEVICE_BITS):
        raise ValueError(f"device {device} out of range")
    if not 0 <= region < (1 << ADDR_REGION_BITS):
        raise ValueError(f"region {region} out of range")
    if not 0 <= offset < (1 << ADDR_OFFSET_BITS):
        raise ValueError(f"offset {offset} out of range")
    return (device << (ADDR_REGION_BITS + ADDR_OFFSET_BITS)) | \
           (region << ADDR_OFFSET_BITS) | offset


def split_addr(addr: int) -> Tuple[int, int, int]:
    offset = addr & ((1 << ADDR_OFFSET_BITS) - 1)
    region = (addr >> ADDR_OFFSET_BITS) & ((1 << ADDR_REGION_BITS) - 1)
    device = (addr >> (ADDR_OFFSET_BITS + ADDR_REGION_BITS)) & \
             ((1 << ADDR_DEVICE_BITS) - 1)
    return device, region, offset
