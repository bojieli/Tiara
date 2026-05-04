"""Tiara C compiler — restricted-C subset → Tiara assembly.

Implements paper §3.4: Tiara operators are written in a restricted C
subset (the SCoP subset of OpenCL C, minus features that don't survive
the Tiara verifier's termination + bounded-memory analysis), and a
compiler lowers each operator to a `.tasm` file consumable by the
existing assembler + verifier.

Subset accepted (intentionally narrow — these are the constructs that
map cleanly to the 22-instruction Tiara ISA):

* One `__kernel` (or plain) function as entry; arguments are 64-bit
  scalars or `__global uint64_t *` pointers.  Up to 8 args mapped to
  r1..r8 in declaration order.  Pointer args are tagged with a region
  via a `__attribute__((annotate("region:NAME[:SIZE]")))`.
* Local 64-bit scalars (uint64_t / int64_t).
* Expressions: `+`, `-`, `*`, `&`, `|`, `^`, `<<`, `>>`, `==`, `<`, `>=`.
* Pointer dereferences `p[expr]` where `p` is a region-tagged arg and
  `expr` is statically derivable (constant or scalar register).
* `for (int i = 0; i < N; i++)` where `N` is a compile-time constant or
  a kernel arg — lowers to `LOOP rN, body_label`.
* `if (cond) { ... }` with no else — lowers to forward `JUMP`.
* `return expr;` — lowers to placing `expr` in r1 and `RET r1`.
* `tiara_andi(x, mask)` builtin — lowers to `ANDI`, required for the
  verifier when `x` came from a `LOAD`.
* `tiara_memcpy(dst, src, len, async_flag)` — lowers to `MEMCPY`.
* `tiara_cas(addr, expected, new)` and `tiara_caa(addr, addend)` —
  atomics.
* `tiara_wait(threshold)` — drains async copies.

Anything outside this subset triggers a clean compile error.

Register allocator: linear-scan with 7 callee-saved registers
(r9..r15).  r0 is zero, r1..r8 are args (also live as scratches once the
arg is no longer needed), r9..r15 are the post-arg scratch pool.

Usage:
    tiara_cc.py kernel.c -o kernel.tasm
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import pycparser
import pycparser.c_ast as ca


# ---------------------------------------------------------------------
# IR
# ---------------------------------------------------------------------

@dataclass
class Op:
    """One emitted Tiara assembly line."""
    text: str

    def __str__(self) -> str:
        return self.text


@dataclass
class CompileError(Exception):
    msg:    str
    coord:  Optional[ca.Coord] = None

    def __str__(self) -> str:
        loc = f"{self.coord}: " if self.coord else ""
        return f"{loc}{self.msg}"


# ---------------------------------------------------------------------
# Symbol table — registers, args, regions
# ---------------------------------------------------------------------

@dataclass
class Symbol:
    name:    str
    reg:     int                # 1..15
    is_arg:  bool = False
    is_ptr:  bool = False
    region:  Optional[str] = None      # for pointer args


class SymTable:
    """Per-function symbol → register mapping with a tiny linear-scan
    allocator.  Args occupy r1..r8; locals get the next free in r9..r15.
    """
    SCRATCH_MIN = 9
    SCRATCH_MAX = 15

    def __init__(self) -> None:
        self.symbols: Dict[str, Symbol] = {}
        self.next_arg = 1
        self.scratch_used: List[bool] = [False] * (self.SCRATCH_MAX + 1)

    def add_arg(self, name: str, is_ptr: bool, region: Optional[str]) -> Symbol:
        if self.next_arg > 8:
            raise CompileError(f"too many arguments (>{8}): {name}")
        s = Symbol(name=name, reg=self.next_arg, is_arg=True,
                   is_ptr=is_ptr, region=region)
        self.symbols[name] = s
        self.next_arg += 1
        return s

    def add_local(self, name: str) -> Symbol:
        for r in range(self.SCRATCH_MIN, self.SCRATCH_MAX + 1):
            if not self.scratch_used[r]:
                self.scratch_used[r] = True
                s = Symbol(name=name, reg=r)
                self.symbols[name] = s
                return s
        raise CompileError(f"out of scratch registers binding {name!r}")

    def temp(self) -> int:
        for r in range(self.SCRATCH_MAX, self.SCRATCH_MIN - 1, -1):
            if not self.scratch_used[r]:
                self.scratch_used[r] = True
                return r
        raise CompileError("out of scratch registers (temporary)")

    def free(self, reg: int) -> None:
        if self.SCRATCH_MIN <= reg <= self.SCRATCH_MAX:
            self.scratch_used[reg] = False

    def get(self, name: str) -> Symbol:
        if name not in self.symbols:
            raise CompileError(f"unknown symbol {name!r}")
        return self.symbols[name]


# ---------------------------------------------------------------------
# Compiler
# ---------------------------------------------------------------------

@dataclass
class Region:
    name: str
    rid:  int
    size: int


class Compiler:
    BUILTINS = {
        "tiara_andi", "tiara_memcpy", "tiara_cas", "tiara_caa",
        "tiara_wait",
    }

    def __init__(self) -> None:
        self.lines:    List[str] = []
        self.sym       = SymTable()
        self.regions:  Dict[str, Region] = {}
        self.next_rid  = 0
        self.label_id  = 0
        self.fn_name:  str = ""
        # Track which registers came from a LOAD without an ANDI mask;
        # the verifier rejects those.  This map is local to a basic
        # block; we conservatively reset it at every label we emit.
        self.opaque:   Dict[int, bool] = {}

    # ----- public entry --------------------------------------------------

    def compile_file(self, path: Path) -> str:
        src = path.read_text()
        src = self._preprocess(src)
        ast = pycparser.CParser().parse(src, filename=str(path))
        self._walk_top(ast)
        return "\n".join(self.lines) + "\n"

    def _preprocess(self, src: str) -> str:
        """Strip C/C++ comments, OpenCL keywords, and preprocessor lines.

        pycparser requires preprocessed input.  We do not use libc / libcl
        headers in Tiara C — every type the compiler accepts is built-in
        (uint64_t, int) — so dropping `#include` and friends is safe.
        """
        import re
        # Remove block comments
        src = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
        # Remove line comments
        src = re.sub(r"//[^\n]*", "", src)
        # Remove preprocessor directives
        src = re.sub(r"^[ \t]*#[^\n]*", "", src, flags=re.MULTILINE)
        # Strip OpenCL-style keywords pycparser doesn't know.
        for kw in ("__kernel", "__global", "__local", "__constant",
                   "__private", "kernel"):
            src = re.sub(rf"\b{kw}\b", "", src)
        # Drop typedef lines for the standard fixed-width types — pycparser
        # accepts our use of these names directly when we predeclare them
        # via the always-injected prelude below.
        src = re.sub(r"^\s*typedef\b[^;]*;\s*$", "",
                     src, flags=re.MULTILINE)
        # Inject a prelude that names the types we accept.  pycparser
        # only knows the C99 builtins, so we typedef our integer aliases
        # to `unsigned long` (which it does know).
        prelude = (
            "typedef unsigned long uint64_t;\n"
            "typedef unsigned long int64_t;\n"
            "typedef unsigned long u64;\n"
            "typedef unsigned int  uint32_t;\n"
        )
        return prelude + src

    # ----- AST walk ------------------------------------------------------

    def _walk_top(self, ast: ca.FileAST) -> None:
        # Look for the unique function definition.
        funcs = [n for n in ast.ext if isinstance(n, ca.FuncDef)]
        if len(funcs) != 1:
            raise CompileError(
                f"expected exactly one function definition, found {len(funcs)}",
                coord=ast.coord)
        fn = funcs[0]
        self.fn_name = fn.decl.name
        self._lower_function(fn)

    def _lower_function(self, fn: ca.FuncDef) -> None:
        # Header comment for the listing.
        self.lines.append(f"// Auto-generated by tiara_cc from {self.fn_name}.c")
        self.lines.append("// Do not edit — recompile from C source.")
        self.lines.append("")

        # Process arg list.
        args_decl = fn.decl.type.args
        if args_decl is not None:
            for p in args_decl.params:
                self._declare_arg(p)

        # Region declarations and consts.
        for name, region in self.regions.items():
            self.lines.append(f"  .region {name} {region.rid}")
        # Argument bindings (.arg directives) for the assembler/verifier.
        for sym in self.sym.symbols.values():
            if sym.is_arg:
                self.lines.append(f"  .arg {sym.name} r{sym.reg}")
        if self.regions or any(s.is_arg for s in self.sym.symbols.values()):
            self.lines.append("")

        # Body.
        body = fn.body
        if not isinstance(body, ca.Compound) or body.block_items is None:
            raise CompileError("empty function body", coord=fn.coord)
        for stmt in body.block_items:
            self._lower_stmt(stmt)

        # Final fall-off: emit RET r0 if the user's last statement wasn't
        # a return.
        if not self.lines or "RET" not in self.lines[-1].upper():
            self.lines.append("  RET r0")

    # ----- declarations --------------------------------------------------

    def _declare_arg(self, p: ca.Decl) -> None:
        is_ptr = isinstance(p.type, ca.PtrDecl)
        # Region annotation comes from a __attribute__((annotate("region:NAME[:SIZE]"))).
        # pycparser doesn't store __attribute__ data, so we use a magic
        # sentinel: a function-style cast with a name like __region_NAME.
        # The simpler fallback is a naming convention: pointer args
        # named e.g. `mem_<region>_<size>` register region <region> with
        # size <size>.
        region: Optional[str] = None
        size: int = 1 << 30
        if is_ptr:
            mark = "_in_"
            if mark in p.name:
                rest = p.name.split(mark, 1)[1]
                # Naming convention: the last `_` separates the region
                # name from the size literal.  e.g.
                # `graph_pool_0x80000000` -> region=graph_pool size=0x80000000.
                if "_" in rest:
                    head, tail = rest.rsplit("_", 1)
                    try:
                        size = int(tail, 0)
                        region = head
                    except ValueError:
                        region = rest
                else:
                    region = rest
            else:
                region = p.name      # use arg name as region name
            if region not in self.regions:
                rid = self.next_rid
                self.next_rid += 1
                self.regions[region] = Region(name=region, rid=rid, size=size)
        self.sym.add_arg(p.name, is_ptr=is_ptr, region=region)

    # ----- statements ----------------------------------------------------

    def _lower_stmt(self, s: ca.Node) -> None:
        if isinstance(s, ca.Decl):
            return self._lower_decl(s)
        if isinstance(s, ca.Assignment):
            return self._lower_assignment(s)
        if isinstance(s, ca.For):
            return self._lower_for(s)
        if isinstance(s, ca.If):
            return self._lower_if(s)
        if isinstance(s, ca.Return):
            return self._lower_return(s)
        if isinstance(s, ca.FuncCall):
            self._lower_funccall(s)
            return
        if isinstance(s, ca.Compound):
            for x in s.block_items or []:
                self._lower_stmt(x)
            return
        if isinstance(s, ca.UnaryOp) and s.op in ("p++", "++", "p--", "--"):
            return self._lower_inc_dec(s)
        raise CompileError(f"unsupported statement {type(s).__name__}",
                           coord=s.coord)

    def _lower_decl(self, d: ca.Decl) -> None:
        if not isinstance(d.type, ca.TypeDecl):
            raise CompileError("only scalar locals supported", coord=d.coord)
        sym = self.sym.add_local(d.name)
        if d.init is not None:
            r = self._lower_expr(d.init)
            self.lines.append(f"  ADDI r{sym.reg}, r{r}, 0")
            self._maybe_free_temp(r)

    def _lower_assignment(self, a: ca.Assignment) -> None:
        if a.op != "=":
            # Compound op like += — fold to lhs = lhs <op> rhs.
            base = a.op[0]
            new = ca.BinaryOp(base, a.lvalue, a.rvalue, coord=a.coord)
            return self._lower_assignment(
                ca.Assignment("=", a.lvalue, new, coord=a.coord))

        if isinstance(a.lvalue, ca.ID):
            sym = self.sym.get(a.lvalue.name)
            r = self._lower_expr(a.rvalue)
            self.lines.append(f"  ADDI r{sym.reg}, r{r}, 0")
            self._maybe_free_temp(r)
            self.opaque.pop(sym.reg, None)
            return

        if isinstance(a.lvalue, ca.ArrayRef):
            # *(p + i) = expr  -> STORE [p + i*8], expr
            base, off = self._addr_components(a.lvalue)
            r = self._lower_expr(a.rvalue)
            self.lines.append(f"  STORE [r{base} + {off}], r{r}")
            self._maybe_free_temp(r)
            return

        raise CompileError(f"unsupported lvalue {type(a.lvalue).__name__}",
                           coord=a.coord)

    def _lower_inc_dec(self, u: ca.UnaryOp) -> None:
        sym = self.sym.get(u.expr.name)
        delta = 1 if u.op.endswith("++") else -1
        self.lines.append(f"  ADDI r{sym.reg}, r{sym.reg}, {delta}")

    def _lower_for(self, f: ca.For) -> None:
        # Recognise: for (int i = 0; i < N; i++) — lower to LOOP rN, body.
        # Init must be an int decl with a 0 initializer.
        # Cond: i < N.   Iter: i++.
        if not isinstance(f.init, ca.DeclList):
            raise CompileError("for-init must declare i", coord=f.coord)
        decls = f.init.decls
        if len(decls) != 1:
            raise CompileError("for-init must declare exactly one variable",
                               coord=f.coord)
        init_decl = decls[0]
        if init_decl.init is None or not self._is_const_zero(init_decl.init):
            raise CompileError("for-init must be `i = 0`", coord=f.coord)
        ind_sym = self.sym.add_local(init_decl.name)

        if not isinstance(f.cond, ca.BinaryOp) or f.cond.op != "<":
            raise CompileError("for-cond must be `i < N`", coord=f.coord)
        if not (isinstance(f.cond.left, ca.ID) and
                f.cond.left.name == init_decl.name):
            raise CompileError("for-cond must use the init variable",
                               coord=f.coord)

        # Bound: constant or arg
        bound_reg = self._lower_expr(f.cond.right)

        end_lbl = self._fresh("for_end")
        self.lines.append(f"  LOOP r{bound_reg}, {end_lbl}")
        # body
        if isinstance(f.stmt, ca.Compound):
            for x in f.stmt.block_items or []:
                self._lower_stmt(x)
        else:
            self._lower_stmt(f.stmt)
        # Loop bookkeeping (the LOOP opcode handles count internally; we
        # do not need to emit i++).
        self.lines.append(f"{end_lbl}:")
        # Reset opaque tracking — we cannot reason across the back-edge.
        self.opaque.clear()
        self._maybe_free_temp(bound_reg)
        self.sym.free(ind_sym.reg)
        del self.sym.symbols[init_decl.name]

    def _lower_if(self, i: ca.If) -> None:
        if i.iffalse is not None:
            raise CompileError("if-else not yet supported", coord=i.coord)
        # Compute cond into a register; JUMP if non-zero.
        # Tiara JUMP is forward-only and "non-zero".  We invert: emit
        # the negated condition to skip the body if the original
        # condition is FALSE.
        cond_reg = self._lower_cond_negated(i.cond)
        skip_lbl = self._fresh("if_skip")
        self.lines.append(f"  JUMP r{cond_reg}, {skip_lbl}")
        self._maybe_free_temp(cond_reg)
        self._lower_stmt(i.iftrue)
        self.lines.append(f"{skip_lbl}:")
        self.opaque.clear()

    def _lower_return(self, r: ca.Return) -> None:
        if r.expr is None:
            self.lines.append("  RET r0")
            return
        # If the return is a tuple (we don't support tuples in C; instead
        # the convention is to stash result1..result4 in r1..r4 before
        # `return r1;`).  For a scalar return: ensure value is in r1.
        rsrc = self._lower_expr(r.expr)
        if rsrc != 1:
            self.lines.append(f"  ADDI r1, r{rsrc}, 0")
        self.lines.append("  RET r1")
        self._maybe_free_temp(rsrc)

    # ----- expressions ---------------------------------------------------

    def _lower_expr(self, e: ca.Node) -> int:
        if isinstance(e, ca.Constant):
            v = self._parse_const(e)
            r = self.sym.temp()
            self.lines.append(f"  LI r{r}, {v}")
            return r
        if isinstance(e, ca.ID):
            return self.sym.get(e.name).reg
        if isinstance(e, ca.BinaryOp):
            return self._lower_binop(e)
        if isinstance(e, ca.UnaryOp):
            return self._lower_unop(e)
        if isinstance(e, ca.ArrayRef):
            base, off = self._addr_components(e)
            r = self.sym.temp()
            self.lines.append(f"  LOAD r{r}, [r{base} + {off}]")
            self.opaque[r] = True
            return r
        if isinstance(e, ca.FuncCall):
            return self._lower_funccall(e, want_value=True)
        if isinstance(e, ca.Cast):
            return self._lower_expr(e.expr)
        raise CompileError(f"unsupported expression {type(e).__name__}",
                           coord=e.coord)

    def _lower_binop(self, b: ca.BinaryOp) -> int:
        op_map_imm = {"+": "ADDI", "&": "ANDI", "<<": "SHLI", ">>": "SHRI"}
        op_map_reg = {
            "+": "ADD", "-": "SUB", "*": "MUL",
            "&": "AND", "|": "OR", "^": "XOR",
            "<<": "SHL", ">>": "SHR",
            "==": "EQ", "<": "LT", ">=": "GE",
        }
        # Try const-fold rhs into an immediate when supported.
        rhs_const = self._try_const(b.right)
        if rhs_const is not None and b.op in op_map_imm:
            ra = self._lower_expr(b.left)
            rd = self.sym.temp()
            mn = op_map_imm[b.op]
            self.lines.append(f"  {mn} r{rd}, r{ra}, {rhs_const}")
            if mn == "ANDI":
                # ANDI clears the opaque-LOAD flag for the result reg
                # (this is the verifier-mandated taming of LOAD outputs).
                self.opaque.pop(rd, None)
            self._maybe_free_temp(ra)
            return rd
        if b.op not in op_map_reg:
            raise CompileError(f"binary op {b.op!r} not supported",
                               coord=b.coord)
        ra = self._lower_expr(b.left)
        rb = self._lower_expr(b.right)
        rd = self.sym.temp()
        self.lines.append(f"  {op_map_reg[b.op]} r{rd}, r{ra}, r{rb}")
        self._maybe_free_temp(ra)
        self._maybe_free_temp(rb)
        return rd

    def _lower_unop(self, u: ca.UnaryOp) -> int:
        if u.op == "-":
            r = self._lower_expr(u.expr)
            rd = self.sym.temp()
            self.lines.append(f"  SUB r{rd}, r0, r{r}")
            self._maybe_free_temp(r)
            return rd
        if u.op == "!":
            r = self._lower_expr(u.expr)
            rd = self.sym.temp()
            self.lines.append(f"  EQ r{rd}, r{r}, r0")
            self._maybe_free_temp(r)
            return rd
        raise CompileError(f"unary op {u.op!r} not supported", coord=u.coord)

    def _lower_cond_negated(self, e: ca.Node) -> int:
        # Compute !e into a register.  The simplest path is just !(expr).
        if isinstance(e, ca.BinaryOp) and e.op == "==":
            ra = self._lower_expr(e.left)
            rb = self._lower_expr(e.right)
            rd = self.sym.temp()
            # !(a==b) = (a != b) — but Tiara has no NEQ; do EQ then XOR with 1.
            self.lines.append(f"  EQ r{rd}, r{ra}, r{rb}")
            tmp = self.sym.temp()
            self.lines.append(f"  LI r{tmp}, 1")
            self.lines.append(f"  XOR r{rd}, r{rd}, r{tmp}")
            self._maybe_free_temp(ra); self._maybe_free_temp(rb)
            self._maybe_free_temp(tmp)
            return rd
        # Generic: r = !expr
        r = self._lower_expr(e)
        rd = self.sym.temp()
        self.lines.append(f"  EQ r{rd}, r{r}, r0")
        self._maybe_free_temp(r)
        return rd

    def _lower_funccall(self, c: ca.FuncCall, want_value: bool = False) -> int:
        if not isinstance(c.name, ca.ID):
            raise CompileError("call target must be a name", coord=c.coord)
        name = c.name.name
        args = [] if c.args is None else c.args.exprs
        if name == "tiara_andi":
            if len(args) != 2:
                raise CompileError("tiara_andi(x, mask)", coord=c.coord)
            ra = self._lower_expr(args[0])
            mask = self._require_const(args[1])
            rd = self.sym.temp()
            self.lines.append(f"  ANDI r{rd}, r{ra}, 0x{mask:x}")
            self.opaque.pop(rd, None)
            self._maybe_free_temp(ra)
            return rd
        if name == "tiara_memcpy":
            if len(args) != 4:
                raise CompileError(
                    "tiara_memcpy(dst, src, len, async_flag)", coord=c.coord)
            rd = self._lower_expr(args[0])
            rs = self._lower_expr(args[1])
            ln = self._require_const(args[2])
            asyncf = self._require_const(args[3])
            tag = "ASYNC" if asyncf else ""
            self.lines.append(
                f"  MEMCPY r0, r{rd}, r{rs}, LEN={ln}{(', ' + tag) if tag else ''}")
            self._maybe_free_temp(rd); self._maybe_free_temp(rs)
            return 0
        if name == "tiara_cas":
            if len(args) != 3:
                raise CompileError("tiara_cas(addr, exp, new)", coord=c.coord)
            ra = self._lower_expr(args[0])
            re = self._lower_expr(args[1])
            rn = self._lower_expr(args[2])
            rd = self.sym.temp()
            self.lines.append(f"  CAS r{rd}, r{ra}, r{re}, r{rn}")
            self._maybe_free_temp(ra); self._maybe_free_temp(re); self._maybe_free_temp(rn)
            return rd
        if name == "tiara_caa":
            if len(args) != 2:
                raise CompileError("tiara_caa(addr, addend)", coord=c.coord)
            ra = self._lower_expr(args[0])
            rb = self._lower_expr(args[1])
            rd = self.sym.temp()
            self.lines.append(f"  CAA r{rd}, r{ra}, r{rb}")
            self._maybe_free_temp(ra); self._maybe_free_temp(rb)
            return rd
        if name == "tiara_wait":
            if len(args) != 1:
                raise CompileError("tiara_wait(threshold)", coord=c.coord)
            n = self._require_const(args[0])
            self.lines.append(f"  WAIT {n}")
            return 0
        if name == "tiara_set_result":
            # tiara_set_result(slot, val) — places val into r1..r4.
            if len(args) != 2:
                raise CompileError("tiara_set_result(slot, val)", coord=c.coord)
            slot = self._require_const(args[0])
            if not 1 <= slot <= 4:
                raise CompileError("result slot must be 1..4", coord=c.coord)
            r = self._lower_expr(args[1])
            self.lines.append(f"  ADDI r{slot}, r{r}, 0")
            self._maybe_free_temp(r)
            return 0
        raise CompileError(f"unknown function {name!r}", coord=c.coord)

    # ----- helpers -------------------------------------------------------

    def _addr_components(self, ar: ca.ArrayRef) -> Tuple[int, int]:
        """For p[i], return (base_reg, byte_imm).  Assumes 8-byte
        elements.  Pure constants are baked into the immediate; non-
        const indices are folded into the base via an ADD."""
        if not isinstance(ar.name, ca.ID):
            raise CompileError("array base must be a pointer name",
                               coord=ar.coord)
        sym = self.sym.get(ar.name.name)
        if not sym.is_ptr:
            raise CompileError(f"{sym.name!r} is not a pointer", coord=ar.coord)
        c = self._try_const(ar.subscript)
        if c is not None:
            return sym.reg, c * 8
        # Non-const: compute base + index*8 in a temp, return (temp, 0)
        ridx = self._lower_expr(ar.subscript)
        rscale = self.sym.temp()
        self.lines.append(f"  SHLI r{rscale}, r{ridx}, 3")
        rsum = self.sym.temp()
        self.lines.append(f"  ADD r{rsum}, r{sym.reg}, r{rscale}")
        self._maybe_free_temp(ridx)
        self.sym.free(rscale)
        return rsum, 0

    def _is_const_zero(self, e: ca.Node) -> bool:
        return isinstance(e, ca.Constant) and self._parse_const(e) == 0

    def _try_const(self, e: ca.Node) -> Optional[int]:
        if isinstance(e, ca.Constant):
            return self._parse_const(e)
        if isinstance(e, ca.UnaryOp) and e.op == "-":
            inner = self._try_const(e.expr)
            return -inner if inner is not None else None
        if isinstance(e, ca.Cast):
            return self._try_const(e.expr)
        return None

    def _require_const(self, e: ca.Node) -> int:
        v = self._try_const(e)
        if v is None:
            raise CompileError("constant required here", coord=e.coord)
        return v

    def _parse_const(self, e: ca.Constant) -> int:
        v = e.value
        if v.endswith(("u", "U", "l", "L", "ul", "UL", "ull", "ULL")):
            v = v.rstrip("uUlL")
        if v.startswith(("0x", "0X")):
            return int(v, 16)
        if v.startswith("0b"):
            return int(v, 2)
        return int(v, 10)

    def _maybe_free_temp(self, r: int) -> None:
        # Only free if this register isn't owned by a named symbol.
        for s in self.sym.symbols.values():
            if s.reg == r:
                return
        self.sym.free(r)
        self.opaque.pop(r, None)

    def _fresh(self, prefix: str) -> str:
        self.label_id += 1
        return f"{prefix}_{self.label_id}"


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="Tiara C compiler")
    ap.add_argument("source", help="restricted-C source (.c)")
    ap.add_argument("-o", "--output", help="output .tasm path")
    args = ap.parse_args(argv)

    src = Path(args.source)
    out_path = Path(args.output) if args.output else src.with_suffix(".tasm")
    try:
        c = Compiler()
        text = c.compile_file(src)
    except CompileError as e:
        print(f"tiara_cc: error: {e}", file=sys.stderr)
        return 2
    out_path.write_text(text)
    print(f"wrote {out_path} ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
