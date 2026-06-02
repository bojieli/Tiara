/**
 * Evaluation datasets parsed from the real eval/results/*.dat files
 * shipped in the Tiara repo (the same numbers plotted in the paper).
 */
import graphLatRaw from './eval/graph_traversal.dat?raw';
import graphTputRaw from './eval/graph_traversal_tput.dat?raw';
import ptWalkRaw from './eval/pt_walk.dat?raw';
import distLockRaw from './eval/dist_lock.dat?raw';
import moeRaw from './eval/moe.dat?raw';
import pagedRaw from './eval/paged_attention.dat?raw';
import crossoverRaw from './eval/crossover.dat?raw';

export interface Point {
  x: number;
  y: number;
}
export interface Series {
  name: string;
  color: string;
  points: Point[];
  /** highlight this series (Tiara) */
  emphasis?: boolean;
  dashed?: boolean;
}
export interface ChartSpec {
  id: string;
  title: string;
  caption: string;
  xLabel: string;
  yLabel: string;
  xType: 'linear' | 'log';
  yType: 'linear' | 'log';
  series: Series[];
  /** optional annotation: vertical marker x + label */
  marker?: { x: number; label: string };
}

function rows(raw: string): number[][] {
  return raw
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'))
    .map((l) => l.split(/\s+/).map(Number));
}

// Color palette — Tiara emphasized.
const C = {
  tiara: '#e0245e',
  rdma: '#2d6cdf',
  rpc: '#2aa775',
  rpc22: '#7bc4a4',
  redn: '#b06bd6',
  prism: '#e8943a',
  offload: '#2d6cdf',
};

function mkSeries(
  data: number[][],
  xCol: number,
  cols: { col: number; name: string; color: string; emphasis?: boolean; dashed?: boolean }[],
): Series[] {
  return cols.map((c) => ({
    name: c.name,
    color: c.color,
    emphasis: c.emphasis,
    dashed: c.dashed,
    points: data.map((r) => ({ x: r[xCol], y: r[c.col] })),
  }));
}

const graphLat = rows(graphLatRaw); // depth Tiara RDMA RPC RedN PRISM
const graphTput = rows(graphTputRaw); // depth Tiara RDMA RPC RPC22 RedN PRISM
const distLock = rows(distLockRaw); // clients Tiara RDMA RPC RedN
const moe = rows(moeRaw); // experts Tiara RDMA RPC
const paged = rows(pagedRaw); // block Tiara_us Tiara_GBps RDMA_us RDMA_GBps RPC_us RPC_GBps RedN_us RedN_GBps
const crossover = rows(crossoverRaw); // host_mem offload rdma

// pt_walk.dat rows: name latency tput. Parse with names.
const ptRows = ptWalkRaw
  .split('\n')
  .map((l) => l.trim())
  .filter((l) => l && !l.startsWith('#'))
  .map((l) => l.split(/\s+/));

export const PT_WALK = {
  systems: ptRows.map((r) => ({ name: r[0], latencyUs: Number(r[1]), tputMops: Number(r[2]) })),
};

export const CHARTS: ChartSpec[] = [
  {
    id: 'graph_lat',
    title: 'Graph traversal — latency vs. depth',
    caption:
      'RDMA grows linearly at depth × RTT. Tiara scales at 1 RTT + depth × 0.79 µs, reaching ' +
      '2.85× faster than RDMA at depth 10. RPC is flat (node-local DRAM) but burns a CPU core.',
    xLabel: 'traversal depth (hops)',
    yLabel: 'latency (µs)',
    xType: 'linear',
    yType: 'linear',
    series: mkSeries(graphLat, 0, [
      { col: 1, name: 'Tiara', color: C.tiara, emphasis: true },
      { col: 2, name: 'RDMA', color: C.rdma },
      { col: 3, name: 'RPC', color: C.rpc },
      { col: 4, name: 'RedN', color: C.redn },
      { col: 5, name: 'PRISM', color: C.prism },
    ]),
  },
  {
    id: 'graph_tput',
    title: 'Graph traversal — saturated throughput vs. depth',
    caption:
      'Throughput at saturation (8 MPs, log scale). Tiara reaches 29.5 Mops at depth 3 — 6.1× ' +
      'higher than RPC at its 22-core saturation point. RedN is ~65× below RDMA due to ' +
      'doorbell-ordering overhead.',
    xLabel: 'traversal depth (hops)',
    yLabel: 'throughput (Mops)',
    xType: 'linear',
    yType: 'log',
    series: mkSeries(graphTput, 0, [
      { col: 1, name: 'Tiara', color: C.tiara, emphasis: true },
      { col: 2, name: 'RDMA', color: C.rdma },
      { col: 3, name: 'RPC@16', color: C.rpc },
      { col: 4, name: 'RPC@22', color: C.rpc22, dashed: true },
      { col: 5, name: 'RedN', color: C.redn },
      { col: 6, name: 'PRISM', color: C.prism },
    ]),
  },
  {
    id: 'dist_lock',
    title: 'Distributed lock — latency vs. contention',
    caption:
      'Lock-acquire latency under 1–16 contending clients. Uncontended, Tiara collapses RDMA’s ' +
      '5 RTTs to 2. RPC degrades least (nanosecond CPU-local CAS retries) and overtakes Tiara ' +
      'beyond ~4 clients; RedN pays doorbell overhead per retry.',
    xLabel: 'contending clients',
    yLabel: 'latency (µs)',
    xType: 'linear',
    yType: 'linear',
    series: mkSeries(distLock, 0, [
      { col: 1, name: 'Tiara', color: C.tiara, emphasis: true },
      { col: 2, name: 'RDMA', color: C.rdma },
      { col: 3, name: 'RPC', color: C.rpc },
      { col: 4, name: 'RedN', color: C.redn },
    ]),
  },
  {
    id: 'moe',
    title: 'MoE expert gather — latency vs. experts',
    caption:
      'Fetching k expert-weight slabs (8 KB each) through a translation table. At 32 experts ' +
      'Tiara is 1.88× faster than RDMA and 2.93× faster than RPC; the gap grows with k as RPC’s ' +
      'per-expert dispatch dominates while Tiara stays pipelined via async MEMCPY.',
    xLabel: 'experts gathered',
    yLabel: 'latency (µs)',
    xType: 'linear',
    yType: 'linear',
    series: mkSeries(moe, 0, [
      { col: 1, name: 'Tiara', color: C.tiara, emphasis: true },
      { col: 2, name: 'RDMA', color: C.rdma },
      { col: 3, name: 'RPC', color: C.rpc },
    ]),
  },
  {
    id: 'paged',
    title: 'PagedAttention — effective throughput vs. block size',
    caption:
      'Fetching 8 MB of KV cache over 100 GbE while varying block size. Tiara saturates the ' +
      'effective line rate (~12 GB/s) at just 8 KB blocks — 2.8× batched RDMA — because its ' +
      'pipelined resolve-then-transfer model hides address resolution behind data transfer.',
    xLabel: 'KV block size (bytes)',
    yLabel: 'throughput (GB/s)',
    xType: 'log',
    yType: 'linear',
    series: mkSeries(paged, 0, [
      { col: 2, name: 'Tiara', color: C.tiara, emphasis: true },
      { col: 4, name: 'RDMA', color: C.rdma },
      { col: 6, name: 'RPC', color: C.rpc },
      { col: 8, name: 'RedN', color: C.redn },
    ]),
  },
  {
    id: 'crossover',
    title: 'Offload crossover — when NIC offload beats one-sided RDMA',
    caption:
      'Sweeping host-memory access latency at depth 3. SmartNIC offload only wins when a ' +
      'host-memory access is cheaper than a network RTT (2.5 µs). Tiara’s PCIe DMA at 0.75 µs ' +
      'sits well below the crossover; BlueField-2’s 1.7 µs internal-RDMA access sits above it.',
    xLabel: 'host-memory access latency (µs)',
    yLabel: 'latency (µs)',
    xType: 'linear',
    yType: 'linear',
    marker: { x: 2.5, label: 'crossover = RTT (2.5 µs)' },
    series: mkSeries(crossover, 0, [
      { col: 1, name: 'NIC offload', color: C.offload, emphasis: false },
      { col: 2, name: 'one-sided RDMA', color: C.rdma, dashed: true },
    ]),
  },
];

// expose paged second metric (latency) for a toggle if desired
export const PAGED_LATENCY = mkSeries(paged, 0, [
  { col: 1, name: 'Tiara', color: C.tiara, emphasis: true },
  { col: 3, name: 'RDMA', color: C.rdma },
  { col: 5, name: 'RPC', color: C.rpc },
  { col: 7, name: 'RedN', color: C.redn },
]);
