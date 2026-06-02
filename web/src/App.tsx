import { useEffect, useState } from 'react';
import { Hero, Thesis, Architecture, Abstractions, Evaluation } from './sections/Sections';
import Playground from './playground/Playground';

const NAV = [
  { id: 'thesis', label: 'Thesis' },
  { id: 'architecture', label: 'Architecture' },
  { id: 'abstractions', label: 'ISA' },
  { id: 'playground', label: 'Playground' },
  { id: 'evaluation', label: 'Evaluation' },
];

export default function App() {
  const [active, setActive] = useState('top');

  const go = (id: string) => {
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  useEffect(() => {
    const ids = ['top', ...NAV.map((n) => n.id)];
    const obs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) if (e.isIntersecting) setActive(e.target.id);
      },
      { rootMargin: '-45% 0px -50% 0px' },
    );
    ids.forEach((id) => {
      const el = document.getElementById(id);
      if (el) obs.observe(el);
    });
    return () => obs.disconnect();
  }, []);

  return (
    <div className="app">
      <nav className="topnav">
        <button className="brand" onClick={() => go('top')}>
          Tiara
        </button>
        <div className="navlinks">
          {NAV.map((n) => (
            <button key={n.id} className={active === n.id ? 'on' : ''} onClick={() => go(n.id)}>
              {n.label}
            </button>
          ))}
        </div>
        <a className="repo" href="https://github.com/bojieli/Tiara" target="_blank" rel="noreferrer">
          GitHub ↗
        </a>
      </nav>

      <Hero go={go} />

      <main>
        <Thesis />
        <Architecture />
        <Abstractions />

        <section className="section playground-section" id="playground">
          <div className="section-head">
            <span className="section-n">04</span>
            <h2>Playground — write, compile, and run Tiara</h2>
          </div>
          <p className="section-lede">
            A faithful in-browser port of the Tiara toolchain: the assembler, restricted-C compiler, static verifier,
            and a cycle-calibrated simulator — all validated against the Python reference and the Verilator RTL. Pick an
            operator, step through it line by line, watch register-chained loads resolve indirection in host DRAM, and
            see the latency Tiara saves over one-sided RDMA. Then edit the code, or write your own.
          </p>
          <Playground />
        </section>

        <Evaluation />
      </main>

      <footer className="footer">
        <div>
          <strong>Tiara</strong> — A Programmable Line-Rate ISA for Remote Memory Access · APNet 2026
        </div>
        <div className="muted small">
          The in-browser assembler, compiler, verifier, and simulator are TypeScript ports of the open-source Tiara
          toolchain, validated byte-for-byte against the Python reference and the Verilator RTL. Evaluation data is the
          repository’s measured + analytical results.
        </div>
        <a href="https://github.com/bojieli/Tiara" target="_blank" rel="noreferrer">
          github.com/bojieli/Tiara ↗
        </a>
      </footer>
    </div>
  );
}
