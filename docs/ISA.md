# Tiara Instruction Set Architecture

Tiara is a 64-bit fixed-width RISC-style ISA for executing pre-registered
operators on a memory-side NIC. Operators chain dependent dereferences
locally to collapse multi-RTT indirection chains into a single round-trip.

This document is the binary contract between the assembler (`sw/asm`),
verifier (`sw/verifier`), client library (`sw/client`), and RTL
(`rtl/tiara_nic`).

## Architectural state

Per executing **task**:

| State      | Width        | Notes                                                      |
|------------|--------------|------------------------------------------------------------|
| GPR[0..15] | 64 bit       | r0 reads as 0; writes to r0 are dropped                    |
| PC         | 12 bit       | Index into instruction store; resets to 0 on dispatch      |
| LR         | 4 bit        | Loop register (count) for innermost active loop            |
| Flags      | 4 bit        | Z, N, ERR, C — set by ALU and Memcpy                       |
| InFlight   | 6 bit        | Outstanding async Memcpy counter                           |
| LoopStack  | 8 deep       | (start_pc, end_pc, count) entries; max nest depth 8        |

Argument passing: r1..r8 receive the operator's incoming arguments; r1..r4
hold the return value. Register r0 is hard-wired to zero (writes are
dropped, reads return 0) per the RISC-V convention. Program counter
starts at 0 of the operator's instruction store slot.

## Address format (unified 64-bit)

```
 63                47 46              31 30                                0
+--------------------+------------------+----------------------------------+
|  device_id (16)    |  region_id (16)  |  offset (32)                     |
+--------------------+------------------+----------------------------------+
```

`device_id == 0` means the local Tiara host (host DRAM via PCIe DMA).
Non-zero device IDs are RDMA-attached peer hosts.

## Encoding

Instructions are 64 bits, little-endian on the wire and in BRAM.

```
 63    56 55  52 51  48 47  44 43  40 39                                  0
+--------+------+------+------+------+-------------------------------------+
| opcode | rd   | rs1  | rs2  | sub  | imm40 (sign-extended to 64 if used) |
+--------+------+------+------+------+-------------------------------------+
```

* `opcode` (8 b) — top-level instruction class
* `rd, rs1, rs2` — register indices (4 b each)
* `sub` — sub-opcode for ComputeOp (else 0)
* `imm40` — signed immediate; for `MEMCPY`, this is the length (bytes);
  for `JUMP`/`LOOP`, the relative target / loop body length;
  otherwise an arithmetic immediate.

Instructions that need more operands than the slots above (`MEMCPY`,
`CAS`) use a single follow-on word — the assembler emits two consecutive
64-bit words and the decoder concatenates them. This keeps the per-cycle
fetch unit single-ported. Decoder treats opcode bit 7 set as "two-word".

## Opcodes

| Opcode | Name      | Two-word | Semantics                                                   |
|--------|-----------|----------|-------------------------------------------------------------|
| 0x00   | NOP       | no       | No-op                                                       |
| 0x01   | LOAD      | no       | `rd = MEM64(rs1 + imm40)`                                   |
| 0x02   | STORE     | no       | `MEM64(rs1 + imm40) = rs2`                                  |
| 0x10   | JUMP      | no       | if `rs1 != 0`: `PC += imm40` (must be > 0)                  |
| 0x11   | LOOP      | no       | Push (PC, PC+imm40, rs1) on LoopStack; iterate body         |
| 0x12   | WAIT      | no       | Stall until `InFlight <= imm40`                             |
| 0x13   | RET       | no       | Return r0..r3 to caller; halt task                          |
| 0x20   | COMPUTE   | no       | Sub-opcode picks ALU op (see below)                         |
| 0x83   | MEMCPY    | yes      | Async bulk transfer; needs 5 operands                       |
| 0x84   | CAS       | yes      | Atomic cmp-and-swap                                         |
| 0x85   | CAA       | yes      | Atomic cmp-and-add                                          |

`COMPUTE` sub-opcodes (`sub` field):

| sub | Mnemonic | Operation                       |
|-----|----------|---------------------------------|
| 0x0 | ADD      | `rd = rs1 + rs2`                |
| 0x1 | SUB      | `rd = rs1 - rs2`                |
| 0x2 | AND      | `rd = rs1 & rs2`                |
| 0x3 | OR       | `rd = rs1 \| rs2`               |
| 0x4 | XOR      | `rd = rs1 ^ rs2`                |
| 0x5 | SHL      | `rd = rs1 << (rs2 & 63)`        |
| 0x6 | SHR      | `rd = rs1 >> (rs2 & 63)` (lsr)  |
| 0x7 | MUL      | `rd = (rs1 * rs2) & 2^64-1`     |
| 0x8 | ADDI     | `rd = rs1 + sign_ext(imm40)`    |
| 0x9 | ANDI     | `rd = rs1 & zero_ext(imm40)`    |
| 0xA | SHLI     | `rd = rs1 << (imm40 & 63)`      |
| 0xB | SHRI     | `rd = rs1 >> (imm40 & 63)`      |
| 0xC | LI       | `rd = sign_ext(imm40)`          |
| 0xD | EQ       | `rd = (rs1 == rs2) ? 1 : 0`     |
| 0xE | LT       | `rd = (rs1 < rs2)  ? 1 : 0`     |
| 0xF | GE       | `rd = (rs1 >= rs2) ? 1 : 0`     |

### MEMCPY layout (two words, 16 bytes total)

```
word0: opcode=0x83 | rd_status | rs1_dstAddr | rs2_srcAddr | sub=flags | imm40=length
word1: opcode=continue (0x00) | rd=lenReg | rs1=dstStrideReg | rs2=srcStrideReg | sub=count_reg | imm40=0
```

`flags` bits:
* `[0]` ASYNC — fire-and-forget; only completion increments `InFlight`
* `[1]` LEN_FROM_REG — length lives in `lenReg` instead of `imm40`
* `[2]` STRIDED_GATHER — source addr += `srcStrideReg` per `count_reg` blocks
* `[3]` STRIDED_SCATTER — dst addr += `dstStrideReg`

`rd_status` receives 0 on success, non-zero on RDMA timeout or remote NACK.
Unused fields (e.g., `count_reg` when not strided) must be `r0`.

### CAS / CAA layout

```
word0: opcode=0x84 | rd=resultReg | rs1=addrReg | rs2=expectedReg | sub=0 | imm40=0
word1: opcode=0x00 | rd=newReg    | rs1=0 | rs2=0 | sub=0 | imm40=0  // CAS only
```

CAA replaces `expectedReg` with the addend; `newReg` field is unused.

## Static verification (registration time)

The verifier is invoked before the operator is loaded into the NIC. It
must succeed for the operator to enter the instruction store.

1. **Termination.** Forward-only `JUMP` (imm40 > 0) and `LOOP(count_reg,
   body_len)` with a verifier-supplied bound on `count_reg` (taken from
   the registration manifest) yield a statically computable upper bound
   on dynamic instruction count. Default cap: 4096 dynamic instructions.

2. **Memory bounds.** Every `LOAD`/`STORE` and `MEMCPY` address must be
   provably within a region declared in the operator manifest. The
   verifier performs interval analysis over `(device_id, region_id)`
   pairs. Addresses reachable from arguments are taken from manifest
   parameter constraints; values produced by `LOAD` are unconstrained
   (treated as opaque) but must be passed through an `ANDI` that masks
   them into a registered region's offset width before being used as
   addresses.

3. **No mutable instruction storage.** Instructions live in BRAM that is
   write-only at registration time and read-only during execution.

4. **Resource caps.** Loop nesting `<= 8`; concurrent in-flight async
   ops `<= 32` per task; instructions per operator `<= 1024`.

A rejected operator never leaves the host — the NIC sees only verified
binaries.

## Operator manifest (TOML)

```toml
[operator]
name        = "page_table_walk"
version     = 1
max_dynamic = 256

[arguments]
# argument_index : (low_bound, high_bound)
0 = { name = "virt_addr",  bounds = [0, 0xFFFFFFFFFFFF] }
1 = { name = "l1_base",    bounds = [0, 0x1FFFFFFF],  region = 1 }
2 = { name = "data_dst",   bounds = [0, 0x7FFFFFFF],  region = 0 }

[[regions]]
id     = 0
device = 0     # local
name   = "client_recv_buffer"
size   = 0x80000000

[[regions]]
id     = 1
device = 0
name   = "page_tables"
size   = 0x20000000
```

The verifier consumes the manifest and the assembled binary, and emits a
signed package `(name, version, hash, binary, manifest)` that the host
loader presents to the NIC.
