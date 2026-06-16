import HeroDemo from '../components/HeroDemo';
import IsaReference from '../components/IsaReference';
import IndirectionTimeline from '../components/IndirectionTimeline';
import Chart from '../components/Chart';
import { CHARTS, PT_WALK } from '../data/eval';

export function Hero({ go }: { go: (id: string) => void }) {
  return (
    <header className="hero" id="top">
      <div className="hero-inner">
        <div className="hero-left">
          <div className="kicker">arXiv preprint</div>
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
            <a className="btn ghost big" href="https://arxiv.org/abs/2606.13708" target="_blank" rel="noreferrer">
              Read the paper ↗
            </a>
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
        When the address you need is itself stored in remote memory, one-sided RDMA has to fetch it first — and every
        level of indirection becomes another <em>sequentially dependent</em> round trip. You can’t issue the next
        request until the previous one returns, so no batching or prefetching helps.
      </p>

      <div className="example-callout">
        <span className="example-tag">Worked example</span>
        <p>
          <strong>Walk a 9-hop path through a remote linked list.</strong> Each node stores the address of the next
          node, so the client can’t compute hop <i>i+1</i> until hop <i>i</i>’s data comes back. One-sided RDMA pays{' '}
          <b className="rdma-ink">9 sequential round trips</b>; Tiara resolves the whole chain on the memory-side NIC
          and answers in <b className="tiara-ink">a single round trip</b>.
        </p>
      </div>

      <IndirectionTimeline />

      <p className="muted small">
        The same pattern recurs across systems and the AI stack — page-table and block-table walks, distributed lock +
        replication, PagedAttention, MoE expert paging. The paper works through the full set of workloads and their RTT
        costs.
      </p>
    </section>
  );
}

export function Architecture() {
  return (
    <section className="section" id="architecture">
      <SectionHead n="02" title="Architecture" />

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
    </section>
  );
}

export function Abstractions() {
  return (
    <section className="section" id="abstractions">
      <SectionHead n="03" title="Abstractions & instruction set" />
      <p className="section-lede">
        A handful of instructions, registered and verified once like an eBPF program. The key primitive is the{' '}
        <strong>register-chained load</strong>: a <code>LOAD</code> writes a register that the next <code>LOAD</code> can
        use as its address — turning a multi-RTT pointer chase into local memory accesses.
      </p>
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
