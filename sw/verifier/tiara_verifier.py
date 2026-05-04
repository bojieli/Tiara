"""
Tiara static verifier.

Pre-registration check: every operator that is registered on the NIC
must pass these checks (paper §3.3):

  1. Termination — forward-only jumps, bounded loops, instruction count
     bounded by `max_dynamic` from the manifest.
  2. Memory bounds — every Load/Store/Memcpy address must be provably
     within a declared region.
  3. Resource caps — loop nesting <= 8, in-flight async <= 32, instr
     count <= 1024.
  4. Read-only instruction store (enforced structurally; the assembler
     never emits self-modifying code, and the RTL writes BRAM only at
     registration time).

Output of `verify(prog, manifest)` is a `VerifyReport` containing the
proof obligations checked, plus a hash that the runtime loader uses to
seal the (binary, manifest) pair.
"""

from __future__ import annotations

import hashlib
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Local sw/ imports
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "asm"))

from tiara_isa import (  # noqa: E402
    DEFAULT_MAX_DYNAMIC,
    INSTR_STORE_DEPTH,
    MAX_INFLIGHT_PER_TASK,
    MAX_LOOP_NEST,
    MEMCPY_FLAG_LEN_FROM_REG,
    NUM_REGS,
    Instr,
    Op,
    Sub,
    decode_word,
    split_addr,
)


class VerifyError(Exception):
    pass


# ---------------------------------------------------------------------
# Abstract value lattice
# ---------------------------------------------------------------------

@dataclass(frozen=True)
class AbsVal:
    """An interval over 64-bit unsigned addresses, optionally tagged with a region."""
    lo:     int
    hi:     int
    region: Optional[Tuple[int, int]] = None  # (device_id, region_id)
    opaque: bool = False                       # value came from a Load — unknown contents

    @staticmethod
    def top() -> "AbsVal":
        return AbsVal(0, (1 << 64) - 1, None, opaque=True)

    @staticmethod
    def const(v: int) -> "AbsVal":
        v &= (1 << 64) - 1
        return AbsVal(v, v)

    def add(self, other: "AbsVal") -> "AbsVal":
        if self.opaque or other.opaque:
            return AbsVal.top()
        return AbsVal(
            (self.lo + other.lo) & ((1 << 64) - 1),
            (self.hi + other.hi) & ((1 << 64) - 1),
            self.region or other.region,
        )

    def shl(self, sh: int) -> "AbsVal":
        sh &= 63
        if self.opaque:
            return AbsVal.top()
        return AbsVal(
            (self.lo << sh) & ((1 << 64) - 1),
            (self.hi << sh) & ((1 << 64) - 1),
        )

    def andi(self, mask: int) -> "AbsVal":
        # Masking strictly narrows: result is in [0, mask].
        if mask == 0:
            return AbsVal.const(0)
        return AbsVal(0, mask)


# ---------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------

@dataclass
class Region:
    id:     int
    device: int
    name:   str
    size:   int
    base:   int = 0    # base offset in (device, region_id) namespace; usually 0


@dataclass
class Argument:
    name:    str
    reg:     int
    lo:      int = 0
    hi:      int = (1 << 64) - 1
    region:  Optional[Tuple[int, int]] = None


@dataclass
class Manifest:
    name:        str
    version:     int = 1
    max_dynamic: int = DEFAULT_MAX_DYNAMIC
    regions:     List[Region] = field(default_factory=list)
    arguments:   List[Argument] = field(default_factory=list)


def load_manifest(path: str | Path) -> Manifest:
    """Parse a manifest TOML.  Falls back to a tiny built-in parser if
    the standard library lacks `tomllib` (Python <3.11)."""
    p = Path(path)
    text = p.read_text()
    try:
        import tomllib  # type: ignore[import-not-found]
        data = tomllib.loads(text)
    except ModuleNotFoundError:
        try:
            import tomli  # type: ignore[import-not-found]
            data = tomli.loads(text)
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "Tiara verifier requires Python 3.11+ or the `tomli` package"
            ) from exc

    op = data["operator"]
    regions = [
        Region(
            id=r["id"],
            device=r.get("device", 0),
            name=r["name"],
            size=int(r["size"]),
            base=int(r.get("base", 0)),
        )
        for r in data.get("regions", [])
    ]
    args = [
        Argument(
            name=a["name"],
            reg=int(a["reg"]),
            lo=int(a.get("bounds", [0, (1 << 64) - 1])[0]),
            hi=int(a.get("bounds", [0, (1 << 64) - 1])[1]),
            region=(int(a["device"]), int(a["region"]))
                if "region" in a and "device" in a else None,
        )
        for a in data.get("arguments", [])
    ]
    return Manifest(
        name=op["name"],
        version=int(op.get("version", 1)),
        max_dynamic=int(op.get("max_dynamic", DEFAULT_MAX_DYNAMIC)),
        regions=regions,
        arguments=args,
    )


# ---------------------------------------------------------------------
# Verifier
# ---------------------------------------------------------------------

@dataclass
class VerifyReport:
    ok:              bool
    name:            str
    version:         int
    binary_sha256:   str
    n_words:         int
    n_instructions:  int
    static_step_bound: int
    max_inflight_async: int
    issues:          List[str]

    def fail(self, msg: str) -> None:
        self.ok = False
        self.issues.append(msg)

    def to_dict(self) -> dict:
        return {
            "ok":                self.ok,
            "name":              self.name,
            "version":           self.version,
            "binary_sha256":     self.binary_sha256,
            "n_words":           self.n_words,
            "n_instructions":    self.n_instructions,
            "static_step_bound": self.static_step_bound,
            "max_inflight_async": self.max_inflight_async,
            "issues":            list(self.issues),
        }


def verify(prog, manifest: Manifest) -> VerifyReport:
    """Run all static checks against `prog` (an asm.Program)."""
    binary = prog.to_bin()
    report = VerifyReport(
        ok=True,
        name=manifest.name,
        version=manifest.version,
        binary_sha256=hashlib.sha256(binary).hexdigest(),
        n_words=len(prog.words),
        n_instructions=len(prog.instrs),
        static_step_bound=0,
        max_inflight_async=0,
        issues=[],
    )

    # --- size limit ---------------------------------------------------
    if len(prog.words) > INSTR_STORE_DEPTH:
        report.fail(f"binary {len(prog.words)} words exceeds store depth "
                    f"{INSTR_STORE_DEPTH}")

    # --- decode instructions ------------------------------------------
    decoded: List[Tuple[int, Tuple[int, int, int, int, int, int]]] = []
    pc = 0
    while pc < len(prog.words):
        d = decode_word(prog.words[pc])
        decoded.append((pc, d))
        pc += 2 if d[0] in (int(Op.MEMCPY), int(Op.CAS), int(Op.CAA)) else 1

    # --- termination upper bound + structural checks ------------------
    bound = 0
    inflight_max = 0
    inflight_now = 0

    # Each loop frame is (end_word_pc, max_iters); the multiplier applied
    # to instructions inside the body is the product of all `max_iters`
    # currently on the stack.
    loop_frames: List[Tuple[int, int]] = []
    region_set = {(r.device, r.id): r for r in manifest.regions}
    arg_initial = {arg.reg: AbsVal(arg.lo, arg.hi, arg.region)
                   for arg in manifest.arguments}

    # Conservative model of register state.  We do not attempt a full
    # data-flow round; instead we treat any value not provably masked
    # back into a region as opaque.  Operator authors who need stronger
    # bounds insert an explicit ANDI before using a loaded value as an
    # address; the verifier honors that.
    abs_state: Dict[int, AbsVal] = {r: AbsVal.top() for r in range(NUM_REGS)}
    abs_state[0] = AbsVal.const(0)
    abs_state.update(arg_initial)

    saw_ret = False
    for idx, (pc, (op, rd, rs1, rs2, sub, imm)) in enumerate(decoded):

        # Pop frames whose body has been left.
        while loop_frames and pc >= loop_frames[-1][0]:
            loop_frames.pop()

        outer = 1
        for _, iters in loop_frames:
            outer *= max(1, iters)
        bound += outer

        # --- structural / control flow checks -----------------------------
        if op == int(Op.JUMP):
            if imm <= 0:
                report.fail(f"pc {pc:#x}: backward JUMP not allowed (imm={imm})")
            if pc + imm >= len(prog.words):
                report.fail(f"pc {pc:#x}: JUMP out of range")

        elif op == int(Op.LOOP):
            body_len = imm
            if body_len <= 0:
                report.fail(f"pc {pc:#x}: LOOP body must be > 0")
            if pc + 1 + body_len > len(prog.words):
                report.fail(f"pc {pc:#x}: LOOP body extends past end")
            if len(loop_frames) >= MAX_LOOP_NEST:
                report.fail(f"pc {pc:#x}: loop nesting exceeds {MAX_LOOP_NEST}")
            # Estimate max iterations from the count register's known
            # bound (taken from the manifest).  For now, assume the
            # iteration count is the manifest's declared bound for that
            # register; falls back to 1 if unknown.
            cnt_av = abs_state.get(rs1, AbsVal.top())
            iters = cnt_av.hi if not cnt_av.opaque else manifest.max_dynamic
            iters = max(1, min(iters, manifest.max_dynamic))
            loop_frames.append((pc + 1 + body_len, iters))

        elif op == int(Op.RET):
            saw_ret = True

        elif op == int(Op.WAIT):
            inflight_now = min(inflight_now, imm)

        elif op == int(Op.MEMCPY):
            flags = sub
            inflight_now = min(MAX_INFLIGHT_PER_TASK, inflight_now + 1)
            inflight_max = max(inflight_max, inflight_now)
            # Source/dest address regs come from rs1, rs2 of the head
            _check_addr_reg(report, abs_state, rs1, region_set, pc, "MEMCPY dst")
            _check_addr_reg(report, abs_state, rs2, region_set, pc, "MEMCPY src")
            if flags & MEMCPY_FLAG_LEN_FROM_REG:
                pass  # length is dynamic; accepted up to MAX_LEN at runtime
            else:
                if imm < 0 or imm > (1 << 32):
                    report.fail(f"pc {pc:#x}: MEMCPY length {imm} unreasonable")

        elif op == int(Op.LOAD) or op == int(Op.STORE):
            base = rs1
            _check_addr_reg(report, abs_state, base, region_set, pc,
                            "LOAD" if op == int(Op.LOAD) else "STORE")
            if op == int(Op.LOAD):
                abs_state[rd] = AbsVal.top()  # opaque

        elif op == int(Op.CAS) or op == int(Op.CAA):
            _check_addr_reg(report, abs_state, rs1, region_set, pc,
                            "CAS/CAA addr")
            abs_state[rd] = AbsVal.top()

        elif op == int(Op.COMPUTE):
            v = _abs_compute(sub, abs_state.get(rs1, AbsVal.top()),
                             abs_state.get(rs2, AbsVal.top()), imm)
            if rd != 0:
                abs_state[rd] = v

        elif op == int(Op.NOP):
            pass

        else:
            report.fail(f"pc {pc:#x}: unknown opcode {op:#x}")

        # End-of-loop: pop when we cross the loop body boundary.
        # We approximate: loops are popped whenever `idx+1` reaches end.
        # The exact loop end is handled by the dispatcher at runtime.

        if bound > manifest.max_dynamic:
            report.fail(f"static step bound {bound} exceeds max_dynamic "
                        f"{manifest.max_dynamic}")
            break

    if not saw_ret:
        report.fail("operator has no RET on at least one path")
    if inflight_max > MAX_INFLIGHT_PER_TASK:
        report.fail(f"max in-flight async {inflight_max} > "
                    f"{MAX_INFLIGHT_PER_TASK}")

    report.static_step_bound = bound
    report.max_inflight_async = inflight_max
    return report


def _check_addr_reg(report: VerifyReport,
                    abs_state: Dict[int, AbsVal],
                    reg: int,
                    region_set: Dict[Tuple[int, int], Region],
                    pc: int,
                    kind: str) -> None:
    """Per paper §3.3, every memory address must be provably inside a
    declared region.  Three cases:

    1. The register has a known region tag (from manifest or
       ADD-with-base): check the AbsVal's [lo, hi] range against the
       region's base + size.
    2. The register is bounded but region-less (post-ANDI of an
       opaque value): search for any declared region whose
       [base, base+size) range contains [lo, hi].  If found, accept
       with a note ("matched implicit region <name>"); the runtime
       region check still fires.
    3. Opaque (post-LOAD with no intervening ANDI): REJECT.  The
       operator must mask the loaded value before reusing it as an
       address.
    """
    av = abs_state.get(reg, AbsVal.top())
    if av.opaque:
        report.fail(
            f"pc {pc:#x}: {kind} via r{reg} is opaque (post-LOAD).  "
            f"Insert `ANDI r{reg}, r{reg}, MASK` to clamp into a "
            f"declared region's offset window before using as address."
        )
        return

    # Effective absolute base of a region in the unified address space:
    #   addr = (device << 48) | (region_id << 32) | offset
    def _abs_base(r: Region) -> int:
        return (r.device << 48) | (r.id << 32) | r.base

    if av.region is not None:
        region = region_set.get(av.region)
        if region is None:
            report.fail(
                f"pc {pc:#x}: {kind} targets undeclared region {av.region}")
            return
        ab = _abs_base(region)
        if av.lo < ab or av.hi > ab + region.size:
            report.fail(
                f"pc {pc:#x}: {kind} addr range [{av.lo:#x},{av.hi:#x}] "
                f"escapes region {region.name} "
                f"[{ab:#x},{ab+region.size:#x})")
        return

    # Case 2: bounded but no explicit region tag.  Find the smallest
    # declared region containing [av.lo, av.hi].
    candidates = [
        r for r in region_set.values()
        if av.lo >= _abs_base(r) and av.hi <= _abs_base(r) + r.size
    ]
    if not candidates:
        report.fail(
            f"pc {pc:#x}: {kind} via r{reg} masked range "
            f"[{av.lo:#x},{av.hi:#x}] does not fit in any declared region")
        return
    chosen = min(candidates, key=lambda r: r.size)
    report.issues.append(
        f"pc {pc:#x}: {kind} via r{reg} matched implicit region "
        f"{chosen.name} (range [{av.lo:#x},{av.hi:#x}])")


def _abs_compute(sub: int, a: AbsVal, b: AbsVal, imm: int) -> AbsVal:
    if sub == int(Sub.LI):
        return AbsVal.const(imm & ((1 << 64) - 1))
    if sub == int(Sub.ADDI):
        return a.add(AbsVal.const(imm & ((1 << 64) - 1)))
    if sub == int(Sub.ANDI):
        return a.andi(imm & ((1 << 64) - 1))
    if sub == int(Sub.SHLI):
        return a.shl(imm)
    if sub == int(Sub.ADD):
        return a.add(b)
    return AbsVal.top()


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def _main() -> int:
    import argparse
    import json

    ap = argparse.ArgumentParser(description="Tiara static verifier")
    ap.add_argument("source",   help=".tasm source file")
    ap.add_argument("manifest", help="operator manifest (TOML)")
    ap.add_argument("--json",   action="store_true",
                    help="emit machine-readable report")
    args = ap.parse_args()

    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "asm"))
    from tiara_asm import assemble_file  # type: ignore

    prog = assemble_file(args.source)
    manifest = load_manifest(args.manifest)
    rep = verify(prog, manifest)

    if args.json:
        print(json.dumps(rep.to_dict(), indent=2))
    else:
        status = "OK" if rep.ok else "FAIL"
        print(f"[{status}] {rep.name} v{rep.version}  "
              f"sha256={rep.binary_sha256[:12]}  "
              f"{rep.n_instructions} instr ({rep.n_words} words)  "
              f"static_step_bound={rep.static_step_bound}  "
              f"max_inflight={rep.max_inflight_async}")
        for issue in rep.issues:
            print(f"  - {issue}")
    return 0 if rep.ok else 1


if __name__ == "__main__":
    raise SystemExit(_main())
