import HeroDemo from '../components/HeroDemo';
import IsaReference from '../components/IsaReference';
import Chart from '../components/Chart';
import { CHARTS, PT_WALK } from '../data/eval';

export function Hero({ go }: { go: (id: string) => void }) {
  return (
    <header className="hero" id="top">
      <div className="hero-inner">
        <div className="hero-left">
          <div className="kicker">APNet 2026</div>
          <h1>
            Tiara: a programmable line-rate ISA for <span className="hl">remote memory access</span>
          </h1>
          <p className="lede">
            One-sided RDMA needs the exact remote address up front. When that address must first be{' '}
            <em>read from remote memory</em> — pointer chases, page-table walks, KV block tables — every level of
            indirection costs another sequential round trip. We call it the <strong>Indirection Wall</strong>.
          </p>
          <p className="lede">
            Tiara is a compact, statically verifiable instruction set that runs on the memory-side NIC. Its operators —
            pre-registered programs, like eBPF in the kernel — resolve indirection locally, collapsing multi-RTT
            dependent chains into a <strong>single round trip</strong>.
          </p>
          <div className="hero-cta">
            <button className="btn primary big" onClick={() => go('playground')}>
              ▶ Run the ISA in your browser
            </button>
            <button className="btn ghost big" onClick={() => go('evaluation')}>
              Explore the evaluation
            </button>
          </div>
          <div className="hero-stats">
            <Stat n="2.85×" l="lower graph-traversal latency vs RDMA" />
            <Stat n="6.1×" l="higher throughput than saturated RPC" />
            <Stat n="~3%" l="of a ConnectX-class NIC die (8 MPs)" />
          </div>
        </div>
        <div className="hero-right">
          <HeroDemo />
          <button className="hero-demo-link" onClick={() => go('playground')}>
            This is the real simulator → open the full playground
          </button>
        </div>
      </div>
    </header>
  );
}

function Stat({ n, l }: { n: string; l: string }) {
  return (
    <div className="stat">
      <span className="stat-n">{n}</span>
      <span className="stat-l">{l}</span>
    </div>
  );
}

export function Thesis() {
  return (
    <section className="section" id="thesis">
      <SectionHead n="01" title="The Indirection Wall" />
      <p className="section-lede">
        One-sided RDMA pays one RTT per indirection level, and those RTTs are <em>sequentially dependent</em>: the
        client cannot issue level <i>i+1</i> until level <i>i</i> returns. No batching or prefetching helps. Three
        patterns recur across systems and the AI stack:
      </p>
      <div className="cards-3">
        <Pattern
          icon="↪"
          title="Pointer chasing"
          body="Graph traversals and linked structures store each successor’s address in the current node. Every hop is a round trip — social-network analysis, knowledge graphs, graph-RAG."
        />
        <Pattern
          icon="⇲"
          title="Multi-level translation"
          body="Page tables and block-table lookups resolve addresses through k levels of indirection. vLLM PagedAttention and MoE expert tables are direct instances."
        />
        <Pattern
          icon="⇄"
          title="Conditional multi-host coordination"
          body="Distributed locks and log replication use atomic CAS on one node, then conditionally propagate to replicas — a chain of dependent operations across hosts."
        />
      </div>

      <div className="rtt-table-wrap">
        <h3>RTT cost of indirection across workloads</h3>
        <table className="rtt-table">
          <thead>
            <tr>
              <th>Workload</th>
              <th>Pattern</th>
              <th>RDMA</th>
              <th>Tiara</th>
            </tr>
          </thead>
          <tbody>
            <RttRow w="Graph traversal (depth d)" p="pointer chase" r="d RTTs" t="1 RTT" />
            <RttRow w="Page-table walk (3-level)" p="multi-level translation" r="3 + 1 RTTs" t="1 RTT" />
            <RttRow w="Distributed lock + replication" p="CAS + conditional writes" r="5 RTTs" t="2 RTTs" />
            <RttRow w="PagedAttention" p="table lookup + gather" r="160 / 2 RTTs" t="1 RTT" />
            <RttRow w="MoE expert loading" p="paged translation" r="2 RTTs" t="1 RTT" />
            <RttRow w="Sparse attention (NSA)" p="score-then-select" r="2 RTTs" t="1 RTT" />
          </tbody>
        </table>
        <p className="muted small">
          The cost is severe: latency grows as Depth × RTT and link utilization collapses between dependent accesses —
          the “killer microseconds” regime. A single LLaMA3-70B PagedAttention request can incur 160 sequential RTTs,
          leaving a 200 Gbps link idle 83% of the time.
        </p>
      </div>
    </section>
  );
}

function Pattern({ icon, title, body }: { icon: string; title: string; body: string }) {
  return (
    <div className="pattern card">
      <div className="pattern-icon">{icon}</div>
      <h4>{title}</h4>
      <p>{body}</p>
    </div>
  );
}
function RttRow({ w, p, r, t }: { w: string; p: string; r: string; t: string }) {
  return (
    <tr>
      <td>{w}</td>
      <td className="muted">{p}</td>
      <td className="rdma-cell">{r}</td>
      <td className="tiara-cell">{t}</td>
    </tr>
  );
}

export function Architecture() {
  return (
    <section className="section" id="architecture">
      <SectionHead n="02" title="Architecture" />
      <p className="section-lede">
        The Tiara NIC adds an execution engine to a standard RDMA pipeline: incoming requests are routed by a task
        dispatcher to one of 8 lightweight memory processors (MPs), each a sequential scalar core that accesses host
        DRAM via PCIe DMA. Operators are verified on the host and loaded into per-MP instruction stores.
      </p>

      <div className="arch card">
        <div className="arch-row remote">Remote nodes</div>
        <div className="arch-nic">
          <div className="arch-nic-label">Tiara NIC</div>
          <div className="arch-block rdma">RDMA Engine</div>
          <div className="arch-block disp">Task Dispatcher · op_id → start_pc (O(1))</div>
          <div className="arch-mps">
            {[0, 1, 2, 7].map((i, k) => (
              <div key={i} className="arch-mp">
                <b>MP{i === 7 ? '₇' : `₍${i}₎`}</b>
                <span>16×64b regs</span>
                <span>ALU</span>
                <span>loop stack</span>
                <span>IStore</span>
                {k === 2 && <span className="arch-dots">…</span>}
              </div>
            ))}
          </div>
          <div className="arch-block dma">PCIe DMA Engine</div>
        </div>
        <div className="arch-host">
          <div className="arch-host-label">Host</div>
          <div className="arch-block dram">Host DRAM (memory regions)</div>
          <div className="arch-block cpu">Host CPU</div>
          <div className="arch-block cv">Compiler &amp; Verifier → register operators</div>
        </div>
      </div>

      <div className="cards-3">
        <InfoCard
          title="Sequential, in-order MPs"
          body="Each MP is an 11-state FSM — no cache, no branch prediction, no out-of-order. Register-chained loads are made correct by stalling fetch until writeback, committing a load in a single cycle. This hardware-native path drops per-hop cost below the software-dispatch floor of ARM/RISC-V cores."
        />
        <InfoCard
          title="Multi-tenant by static isolation"
          body="A 256-entry op_id → start_pc table routes any registered operator in O(1). Isolation is static: every operator is verified at registration to touch only its declared regions, so the runtime needs no per-access check and one tenant cannot reach another’s memory."
        />
        <InfoCard
          title="Tiny footprint"
          body="A single MP at 200 MHz costs 2.95K LUT + 1.69K FF + 2 BRAM + 10 DSP on a U50; 8 MPs occupy ~3% of a ConnectX-class NIC die. The whole point is a minimal ISA, not a general-purpose core."
        />
      </div>
    </section>
  );
}

function InfoCard({ title, body }: { title: string; body: string }) {
  return (
    <div className="card info">
      <h4>{title}</h4>
      <p>{body}</p>
    </div>
  );
}

export function Abstractions() {
  return (
    <section className="section" id="abstractions">
      <SectionHead n="03" title="Abstractions & instruction set" />
      <div className="cards-3">
        <InfoCard
          title="Operators & tasks"
          body="An operator is a small pre-registered program, registered once (and verified) like loading an eBPF program. A client invokes it with one message — operator ID + up to 8 register arguments — and the NIC spins up a task backed by a 16×64b register file, with no host CPU involvement."
        />
        <InfoCard
          title="Register-chained loads"
          body="The key enabler: a LOAD writes its result into a GPR that a subsequent LOAD can use as its address operand in the very next cycle. A multi-RTT pointer chase becomes a sequence of local memory accesses, each ~0.75 µs on the FPGA prototype instead of a full network RTT."
        />
        <InfoCard
          title="Async + Wait"
          body="MEMCPY executes asynchronously; WAIT(threshold) synchronizes. Threshold 0 drains all in-flight ops; threshold > 0 enables quorum-style sync. This also pipelines transfers — issuing KV block reads as block-table entries resolve, hiding address resolution behind data movement."
        />
      </div>
      <IsaReference />
    </section>
  );
}

export function Evaluation() {
  return (
    <section className="section" id="evaluation">
      <SectionHead n="05" title="Evaluation — explore the data" />
      <p className="section-lede">
        Tiara latencies are measured cycle-accurate by a Verilator model of the FPGA prototype (the same numbers the
        in-browser simulator reproduces). Baselines (RDMA, RPC, RedN, PRISM) are analytical models parameterized
        identically across workloads. Toggle series, hover for values, and compare. All numbers come straight from the
        repo’s <code>eval/results/*.dat</code> files.
      </p>
      <div className="charts-grid">
        {CHARTS.map((c) => (
          <Chart key={c.id} spec={c} />
        ))}
        <div className="chart card pt-summary">
          <div className="chart-head">
            <h4>Page-table walk — single round-trip translation</h4>
          </div>
          <table className="pt-table">
            <thead>
              <tr>
                <th>System</th>
                <th>Latency (µs)</th>
                <th>Throughput (Mops)</th>
              </tr>
            </thead>
            <tbody>
              {PT_WALK.systems.map((s) => (
                <tr key={s.name} className={s.name === 'Tiara' ? 'tiara-row' : ''}>
                  <td>{s.name}</td>
                  <td>{s.latencyUs.toFixed(2)}</td>
                  <td>{s.tputMops.toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="chart-caption">
            RDMA needs 4 RTTs (10.0 µs); Tiara resolves all three levels via PCIe in 1 RTT (3.75 µs) — a 62% latency
            reduction and 250× the throughput, since each translation is a single network message.
          </p>
        </div>
      </div>
    </section>
  );
}

function SectionHead({ n, title }: { n: string; title: string }) {
  return (
    <div className="section-head">
      <span className="section-n">{n}</span>
      <h2>{title}</h2>
    </div>
  );
}
