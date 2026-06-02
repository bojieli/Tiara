import { useEffect, useRef, useState } from 'react';
import { assemble } from '../engine/asm';
import { VM, Memory, cyclesToUs } from '../engine/vm';
import { PRESETS } from '../data/operators';

const RTT_US = 2.5;
const N_NODES = 6;
const DEPTH = 5;

const graph = PRESETS.find((p) => p.id === 'graph_walk')!;

/** A self-running graph-traversal demo: watch Tiara chase pointers on the
 * NIC while one-sided RDMA pays a full round trip per hop. */
export default function HeroDemo() {
  const [cur, setCur] = useState(0); // current node index
  const [hop, setHop] = useState(0); // hops completed
  const [onNic, setOnNic] = useState(0); // µs
  const [mnemonic, setMnemonic] = useState('idle');
  const [done, setDone] = useState(false);
  const vmRef = useRef<VM | null>(null);

  function build() {
    const prog = assemble(graph.tasm, 'graph_walk');
    const mem = new Memory();
    for (const [a, w] of graph.seed([0n, BigInt(DEPTH)])) mem.store64(a, w);
    const vm = new VM(prog, [0n, BigInt(DEPTH)], mem);
    vmRef.current = vm;
    setCur(0);
    setHop(0);
    setOnNic(0);
    setDone(false);
    setMnemonic('dispatch');
  }

  useEffect(() => {
    build();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const id = setInterval(() => {
      const vm = vmRef.current;
      if (!vm) return;
      if (vm.halted) {
        setDone(true);
        // pause on the finished frame, then restart
        setTimeout(build, 1600);
        return;
      }
      const ev = vm.step();
      setMnemonic(ev.mnemonic);
      setOnNic(cyclesToUs(vm.cycles));
      // node index follows the address register r1 (current node)
      const addr = vm.regs[1];
      const idx = Number(addr / 16n);
      if (idx >= 0 && idx < N_NODES) setCur(idx);
      if (ev.mnemonic === 'LOAD' && ev.mem && !ev.mem.remote && ev.decoded.imm === 8n) setHop((h) => Math.min(h + 1, DEPTH));
    }, 420);
    return () => clearInterval(id);
  }, []);

  const rdmaUs = hop * RTT_US;
  const max = Math.max(rdmaUs, onNic, RTT_US);

  return (
    <div className="herodemo">
      <div className="hd-head">
        <span className="hd-tag">live</span>
        <span className="hd-title">graph traversal · depth {DEPTH}</span>
        <span className="hd-mn">{mnemonic}</span>
      </div>

      <div className="hd-chain">
        {Array.from({ length: N_NODES }).map((_, i) => (
          <div key={i} className="hd-node-wrap">
            <div className={`hd-node ${i === cur ? 'cur' : ''} ${i < cur ? 'visited' : ''}`}>
              <span className="hd-nidx">n{i}</span>
            </div>
            {i < N_NODES - 1 && <div className={`hd-edge ${i < cur ? 'lit' : ''}`} />}
          </div>
        ))}
      </div>

      <div className="hd-bars">
        <div className="hd-bar">
          <span className="hd-lab">one-sided RDMA</span>
          <div className="hd-track">
            <div className="hd-fill rdma" style={{ width: `${(rdmaUs / max) * 100}%` }} />
          </div>
          <span className="hd-val">
            {hop} RTT · {rdmaUs.toFixed(1)} µs
          </span>
        </div>
        <div className="hd-bar">
          <span className="hd-lab">Tiara on-NIC</span>
          <div className="hd-track">
            <div className="hd-fill tiara" style={{ width: `${(onNic / max) * 100}%` }} />
          </div>
          <span className="hd-val">
            1 RTT · {onNic.toFixed(1)} µs
          </span>
        </div>
      </div>

      <div className="hd-foot">
        {done ? (
          <span className="hd-done">
            ✓ {DEPTH} dependent hops resolved in <b>1</b> round trip — RDMA would need <b>{DEPTH}</b>.
          </span>
        ) : (
          <span>Each hop’s address is read from the previous node — the Indirection Wall.</span>
        )}
      </div>
    </div>
  );
}
