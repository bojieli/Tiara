/**
 * Preset Tiara operators for the playground: source, manifest (for the
 * static verifier), default arguments, and a host-DRAM seed builder that
 * mirrors the evaluation harness so each operator actually resolves real
 * indirection when stepped.
 */
import type { Manifest } from '../engine/verifier';
import { makeAddr } from '../engine/isa';

import graphWalkTasm from './operators/graph_walk.tasm?raw';
import pageTableTasm from './operators/page_table_walk.tasm?raw';
import distLockTasm from './operators/dist_lock.tasm?raw';
import moeTasm from './operators/moe_expert.tasm?raw';
import pagedTasm from './operators/paged_attention.tasm?raw';

import graphWalkC from './examples/graph_walk.c?raw';
import atomicIncC from './examples/atomic_inc.c?raw';

export interface ArgSpec {
  name: string;
  reg: number;
  /** human description */
  help?: string;
}

export interface PresetOperator {
  id: string;
  title: string;
  /** one-line summary shown in the picker */
  blurb: string;
  /** longer explanation shown in the playground */
  description: string;
  /** RTT story: RDMA vs Tiara */
  rdmaRtts: string;
  tiaraRtts: string;
  tasm: string;
  cSource?: string;
  manifest: Manifest;
  args: ArgSpec[];
  defaultArgs: bigint[]; // r1..r8
  /** Build host-DRAM seed entries (absolute byte address -> 64-bit word). */
  seed: (args: bigint[]) => [bigint, bigint][];
}

// --- seed builders ---------------------------------------------------

function seedGraph(args: bigint[]): [bigint, bigint][] {
  const depth = Number(args[1] || 1n);
  const n = Math.max(depth + 4, 6);
  const out: [bigint, bigint][] = [];
  for (let i = 0; i < n; i++) {
    out.push([BigInt(i * 16), BigInt(0xdec0de00 + i)]); // data
    out.push([BigInt(i * 16 + 8), BigInt(i + 1 < n ? (i + 1) * 16 : 0)]); // next ptr
  }
  return out;
}

function seedPageTable(_args: bigint[]): [bigint, bigint][] {
  const L1 = 0,
    L2 = 4096,
    L3 = 8192,
    DATA = 12288;
  const out: [bigint, bigint][] = [];
  out.push([BigInt(L1 + 8), BigInt(L2)]); // L1[1] -> L2 base
  out.push([BigInt(L2 + 8), BigInt(L3)]); // L2[1] -> L3 base
  out.push([BigInt(L3 + 8), BigInt(DATA)]); // L3[1] -> data page
  for (let i = 0; i < 8; i++) out.push([BigInt(DATA + i * 8), BigInt(0xcafe00000000) + BigInt(i)]);
  return out;
}

function seedDistLock(_args: bigint[]): [bigint, bigint][] {
  // latch @ 0, state @ 8, both initially 0 (unlocked).
  return [
    [0n, 0n],
    [8n, 0n],
  ];
}

function seedMoe(args: bigint[]): [bigint, bigint][] {
  const nExp = Number(args[0] || 1n);
  const idsBase = Number(args[1] || 0n);
  const ttableBase = Number(args[2] || 0x1000n);
  const out: [bigint, bigint][] = [];
  for (let i = 0; i < nExp; i++) out.push([BigInt(idsBase + i * 8), BigInt(i)]); // expert ids
  for (let i = 0; i < Math.max(nExp, 8); i++) {
    out.push([BigInt(ttableBase + i * 8), BigInt(0x100000 + i * 8192)]); // id -> phys addr
  }
  return out;
}

function seedPaged(args: bigint[]): [bigint, bigint][] {
  const nblock = Number(args[1] || 4n);
  const bsize = Number(args[2] || 4096n);
  const btBase = Number(args[0] || 0n);
  const out: [bigint, bigint][] = [];
  // block table: entry i -> physical address of block i
  const dataBase = btBase + nblock * 8;
  for (let i = 0; i < nblock; i++) out.push([BigInt(btBase + i * 8), BigInt(dataBase + i * bsize)]);
  return out;
}

// --- manifests (mirror the shipped .toml files) ----------------------

const graphManifest: Manifest = {
  name: 'graph_walk',
  version: 1,
  maxDynamic: 1024,
  regions: [{ id: 0, device: 0, name: 'graph_pool', size: 0x80000000n }],
  arguments: [
    { name: 'start', reg: 1, lo: 0n, hi: 0x7ffffff8n, region: [0, 0] },
    { name: 'depth', reg: 2, lo: 0n, hi: 64n },
  ],
};

const pageTableManifest: Manifest = {
  name: 'page_table_walk',
  version: 1,
  maxDynamic: 256,
  regions: [{ id: 0, device: 0, name: 'host_dram', size: 0x80000000n }],
  arguments: [
    { name: 'vaddr', reg: 1, lo: 0n, hi: 0xffffffffffffn },
    { name: 'l1', reg: 2, lo: 0n, hi: 0x10000000n, region: [0, 0] },
    { name: 'dst', reg: 3, lo: 0n, hi: 0x70000000n, region: [0, 0] },
  ],
};

const distLockManifest: Manifest = {
  name: 'dist_lock',
  version: 1,
  maxDynamic: 2048,
  regions: [
    { id: 0, device: 0, name: 'lock_state', size: 0x100000n },
    { id: 0, device: 1, name: 'replica1', size: 0x100000n },
    { id: 0, device: 2, name: 'replica2', size: 0x100000n },
  ],
  arguments: [
    { name: 'latch', reg: 1, lo: 0n, hi: 0xffffn, region: [0, 0] },
    { name: 'state', reg: 2, lo: 0n, hi: 0xffffn, region: [0, 0] },
    { name: 'newVal', reg: 3, lo: 0n, hi: 0xffffffffffffffffn },
    { name: 'rep1', reg: 4, lo: 0x0001000000000000n, hi: 0x0001000000000ff8n, region: [1, 0] },
    { name: 'rep2', reg: 5, lo: 0x0002000000000000n, hi: 0x0002000000000ff8n, region: [2, 0] },
    { name: 'retries', reg: 6, lo: 0n, hi: 64n },
  ],
};

const moeManifest: Manifest = {
  name: 'moe_expert',
  version: 1,
  maxDynamic: 4096,
  regions: [{ id: 0, device: 0, name: 'moe_pool', size: 0x80000000n }],
  arguments: [
    { name: 'n_exp', reg: 1, lo: 0n, hi: 64n },
    { name: 'ids', reg: 2, lo: 0n, hi: 0x7ffffff8n, region: [0, 0] },
    { name: 'ttable', reg: 3, lo: 0n, hi: 0x7ffffe00n, region: [0, 0] },
    { name: 'ex_size', reg: 4, lo: 0n, hi: 0x100000n },
    { name: 'dst', reg: 5, lo: 0n, hi: 0x7ffffff8n, region: [0, 0] },
  ],
};

const pagedManifest: Manifest = {
  name: 'paged_attention',
  version: 1,
  maxDynamic: 131072,
  regions: [{ id: 0, device: 0, name: 'host_dram', size: 0x80000000n }],
  arguments: [
    { name: 'btbase', reg: 1, lo: 0n, hi: 0x70000000n, region: [0, 0] },
    { name: 'nblock', reg: 2, lo: 0n, hi: 16384n },
    { name: 'bsize', reg: 3, lo: 0n, hi: 0x100000n },
    { name: 'dst', reg: 4, lo: 0n, hi: 0x70000000n, region: [0, 0] },
  ],
};

// --- presets ---------------------------------------------------------

export const PRESETS: PresetOperator[] = [
  {
    id: 'graph_walk',
    title: 'Graph traversal',
    blurb: 'Depth-limited pointer chase through linked nodes.',
    description:
      'Each node stores its data at offset 0 and a pointer to the next node at offset 8. ' +
      'A bounded LOOP chases `depth` pointers; each iteration overwrites the address register ' +
      'with the loaded next-pointer (register-chained LOAD) and ANDI-masks it back into the ' +
      'graph_pool region so the verifier can prove the next access stays in bounds. With ' +
      'one-sided RDMA every hop is a separate round trip; Tiara resolves them all locally.',
    rdmaRtts: 'depth RTTs',
    tiaraRtts: '1 RTT',
    tasm: graphWalkTasm,
    cSource: graphWalkC,
    manifest: graphManifest,
    args: [
      { name: 'start', reg: 1, help: 'address of the start node (byte offset, device 0)' },
      { name: 'depth', reg: 2, help: 'number of hops to chase' },
    ],
    defaultArgs: [0n, 3n, 0n, 0n, 0n, 0n, 0n, 0n],
    seed: seedGraph,
  },
  {
    id: 'page_table_walk',
    title: 'Page-table walk',
    blurb: '3-level address translation in a single round-trip.',
    description:
      'Three chained LOADs resolve a 3-level page table — each LOAD uses the previous level’s ' +
      'loaded pointer as its base (the indirection wall). Index bits are extracted with ' +
      'SHRI/ANDI/SHLI, and each opaque loaded pointer is ANDI-masked into the page-table region ' +
      'before the next dereference. A final MEMCPY transfers the resolved 4 KiB page. ' +
      'RDMA needs 4 RTTs (3 walk + 1 data); Tiara needs 1.',
    rdmaRtts: '4 RTTs',
    tiaraRtts: '1 RTT',
    tasm: pageTableTasm,
    manifest: pageTableManifest,
    args: [
      { name: 'vaddr', reg: 1, help: 'virtual address to translate' },
      { name: 'l1', reg: 2, help: 'level-1 table base (device 0)' },
      { name: 'dst', reg: 3, help: 'destination for the resolved page' },
    ],
    // vaddr picks index 1 at every level: (1<<30)|(1<<21)|(1<<12)
    defaultArgs: [(1n << 30n) | (1n << 21n) | (1n << 12n), 0n, 0x10000n, 0n, 0n, 0n, 0n, 0n],
    seed: seedPageTable,
  },
  {
    id: 'dist_lock',
    title: 'Distributed lock',
    blurb: 'CAS-acquire + 2-replica replication across three hosts.',
    description:
      'Mirrors Figure 5 of the paper. The NIC acquires a latch via local CAS, updates the lock ' +
      'state, replicates it to two remote replicas via parallel async MEMCPY (unified addressing ' +
      'to device 1 and 2), waits for both ACKs, then releases. RDMA needs 5 sequential RTTs; ' +
      'Tiara collapses this to 2 (client→primary, then primary→replicas in parallel).',
    rdmaRtts: '5 RTTs',
    tiaraRtts: '2 RTTs',
    tasm: distLockTasm,
    manifest: distLockManifest,
    args: [
      { name: 'latch', reg: 1, help: 'latch address (local)' },
      { name: 'state', reg: 2, help: 'lock-state address (local)' },
      { name: 'newVal', reg: 3, help: 'value to write into state' },
      { name: 'rep1', reg: 4, help: 'replica 1 unified address (device 1)' },
      { name: 'rep2', reg: 5, help: 'replica 2 unified address (device 2)' },
      { name: 'retries', reg: 6, help: 'max CAS retries (client-driven)' },
    ],
    defaultArgs: [0n, 8n, 0xc0den, makeAddr(1, 0, 0), makeAddr(2, 0, 0), 16n, 0n, 0n],
    seed: seedDistLock,
  },
  {
    id: 'moe_expert',
    title: 'MoE expert gather',
    blurb: 'Expert-ID → physical-address translation, then weight gather.',
    description:
      'Disaggregated mixture-of-experts inference: a gating network produces expert IDs that must ' +
      'be translated through a small table to physical addresses before the weight slabs are ' +
      'gathered. Structurally identical to PagedAttention’s block-table walk. A LOOP resolves ' +
      'each ID via LOAD and issues an async MEMCPY for the weights, pipelining resolution with ' +
      'transfer.',
    rdmaRtts: '2 RTTs',
    tiaraRtts: '1 RTT',
    tasm: moeTasm,
    manifest: moeManifest,
    args: [
      { name: 'n_exp', reg: 1, help: 'number of experts to gate-select' },
      { name: 'ids', reg: 2, help: 'expert-id list base' },
      { name: 'ttable', reg: 3, help: 'translation table base' },
      { name: 'ex_size', reg: 4, help: 'bytes per expert slab' },
      { name: 'dst', reg: 5, help: 'gather destination base' },
    ],
    defaultArgs: [4n, 0n, 0x1000n, 8192n, 0x10000n, 0n, 0n, 0n],
    seed: seedMoe,
  },
  {
    id: 'paged_attention',
    title: 'PagedAttention gather',
    blurb: 'Resolve a vLLM block table and pipeline async KV reads.',
    description:
      'A memory node holds a vLLM-style paged KV cache. A block table maps logical block IDs to ' +
      'physical addresses. The operator loops over block IDs, resolves each via LOAD (ANDI-masked ' +
      'into the recv region), and issues an async MEMCPY for the KV block — overlapping address ' +
      'resolution with data transfer. WAIT drains all in-flight transfers before returning.',
    rdmaRtts: '160 / 2 RTTs',
    tiaraRtts: '1 RTT',
    tasm: pagedTasm,
    manifest: pagedManifest,
    args: [
      { name: 'btbase', reg: 1, help: 'block-table base' },
      { name: 'nblock', reg: 2, help: 'number of blocks to resolve' },
      { name: 'bsize', reg: 3, help: 'block size in bytes' },
      { name: 'dst', reg: 4, help: 'recv buffer base' },
    ],
    defaultArgs: [0n, 4n, 4096n, 0x100000n, 0n, 0n, 0n, 0n],
    seed: seedPaged,
  },
];

/** Standalone C examples for the compiler demo. */
export const C_EXAMPLES: { id: string; title: string; source: string }[] = [
  { id: 'graph_walk_c', title: 'graph_walk.c', source: graphWalkC },
  { id: 'atomic_inc_c', title: 'atomic_inc.c', source: atomicIncC },
];
