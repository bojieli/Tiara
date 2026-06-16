import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { assemble, AsmError, Program } from '../engine/asm';
import { VM, Memory, VMState, StepEvent, cyclesToUs } from '../engine/vm';
import { verify, VerifyReport, Manifest } from '../engine/verifier';
import { compileC, CompileError } from '../engine/cc';
import { decodeWord, Op, splitAddr } from '../engine/isa';
import { PRESETS, PresetOperator } from '../data/operators';

const RTT_US = 2.5;

const STARTER_C = `// Restricted-C operator. Pointer args name their region via
// the  name_in_<region>_<size>  convention. Compile -> Tiara asm -> run.
uint64_t my_op(uint64_t* base_in_pool_0x80000000, uint64_t n) {
    uint64_t sum = 0;
    for (int i = 0; i < n; i++) {
        uint64_t v = base_in_pool_0x80000000[i];
        sum = sum + v;
    }
    return sum;
}
`;

function rdmaRoundTrips(id: string, args: bigint[]): { trips: number; label: string } {
  switch (id) {
    case 'graph_walk':
      return { trips: Number(args[1] || 0n), label: 'one hop per RTT' };
    case 'page_table_walk':
      return { trips: 4, label: '3 walk + 1 data' };
    case 'dist_lock':
      return { trips: 5, label: 'CAS + read + 2 writes + release' };
    case 'moe_expert':
      return { trips: 2, label: 'read table + gather' };
    case 'paged_attention':
      return { trips: 2, label: 'optimally batched' };
    default:
      return { trips: 0, label: '' };
  }
}

const hex = (v: bigint, pad = 0) => '0x' + (v < 0n ? (v & ((1n << 64n) - 1n)) : v).toString(16).padStart(pad, '0');

function addrLabel(addr: bigint): string {
  const { device, region, offset } = splitAddr(addr);
  const dev = device === 0 ? 'host' : `dev${device}`;
  return `${dev}:r${region}+${offset.toString()}`;
}

interface ListItem {
  index: number;
  pc: number;
  words: string[];
  mnemonic: string;
  src: string;
}

function buildListing(prog: Program): ListItem[] {
  const items: ListItem[] = [];
  let pc = 0;
  for (const instr of prog.instrs) {
    const words = instr.encode().map((w) => w.toString(16).padStart(16, '0'));
    const d = decodeWord(instr.encode()[0]);
    const mnemonic = instr.opcode === Op.COMPUTE ? subName(d.sub) : Op[instr.opcode];
    items.push({ index: items.length, pc, words, mnemonic, src: instr.src ?? '' });
    pc += instr.width;
  }
  return items;
}

function subName(sub: number): string {
  const names = ['ADD', 'SUB', 'AND', 'OR', 'XOR', 'SHL', 'SHR', 'MUL', 'ADDI', 'ANDI', 'SHLI', 'SHRI', 'LI', 'EQ', 'LT', 'GE'];
  return names[sub] ?? `COMPUTE.${sub}`;
}

export default function Playground() {
  const [preset, setPreset] = useState<PresetOperator>(PRESETS[0]);
  const [mode, setMode] = useState<'asm' | 'c'>('asm');
  const [asmSrc, setAsmSrc] = useState(PRESETS[0].tasm);
  const [cSrc, setCSrc] = useState(PRESETS[0].cSource ?? STARTER_C);
  const [argStr, setArgStr] = useState<string[]>(PRESETS[0].defaultArgs.map((a) => a.toString()));
  const [program, setProgram] = useState<Program | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<VerifyReport | null>(null);
  const [snap, setSnap] = useState<VMState | null>(null);
  const [lastEvent, setLastEvent] = useState<StepEvent | null>(null);
  const [log, setLog] = useState<StepEvent[]>([]);
  const [running, setRunning] = useState(false);
  const [speed, setSpeed] = useState(6); // steps/sec exponent-ish
  const [finalResult, setFinalResult] = useState<bigint[] | null>(null);

  const vmRef = useRef<VM | null>(null);
  const memRef = useRef<Memory>(new Memory());

  const args = useMemo(() => parseArgs(argStr), [argStr]);

  // Load a preset.
  const loadPreset = useCallback((p: PresetOperator) => {
    setPreset(p);
    setMode('asm');
    setAsmSrc(p.tasm);
    setCSrc(p.cSource ?? STARTER_C);
    setArgStr(p.defaultArgs.map((a) => a.toString()));
    setProgram(null);
    setSnap(null);
    setLastEvent(null);
    setLog([]);
    setReport(null);
    setError(null);
    setRunning(false);
    setFinalResult(null);
    vmRef.current = null;
  }, []);

  const assembleAndLoad = useCallback(() => {
    setRunning(false);
    setError(null);
    try {
      const prog = assemble(asmSrc, preset.id);
      const mem = new Memory();
      for (const [addr, w] of preset.seed(args)) mem.store64(addr, w);
      memRef.current = mem;
      const vm = new VM(prog, args, mem);
      vmRef.current = vm;
      setProgram(prog);
      setSnap(vm.state());
      setLastEvent(null);
      setLog([]);
      setFinalResult(null);
      // run verifier too
      setReport(verify(prog, preset.manifest));
    } catch (e) {
      if (e instanceof AsmError) setError(`Assembler: ${e.message}`);
      else setError(`${(e as Error).message}`);
      setProgram(null);
      vmRef.current = null;
      setSnap(null);
    }
  }, [asmSrc, args, preset]);

  const doCompile = useCallback(() => {
    setError(null);
    try {
      const { tasm } = compileC(cSrc);
      setAsmSrc(tasm);
      setMode('asm');
    } catch (e) {
      if (e instanceof CompileError) setError(`Compiler: ${e.message}`);
      else setError(`${(e as Error).message}`);
    }
  }, [cSrc]);

  const stepOnce = useCallback(() => {
    const vm = vmRef.current;
    if (!vm || vm.halted) {
      setRunning(false);
      return;
    }
    const ev = vm.step();
    setSnap(vm.state());
    setLastEvent(ev);
    setLog((l) => [ev, ...l].slice(0, 40));
    if (vm.halted) {
      setRunning(false);
      setFinalResult(vm.result);
    }
  }, []);

  const reset = useCallback(() => {
    setRunning(false);
    const vm = vmRef.current;
    if (!vm) return;
    const mem = new Memory();
    for (const [addr, w] of preset.seed(args)) mem.store64(addr, w);
    memRef.current = mem;
    vm.mem = mem;
    vm.reset(args);
    setSnap(vm.state());
    setLastEvent(null);
    setLog([]);
    setFinalResult(null);
  }, [args, preset]);

  // auto-run
  useEffect(() => {
    if (!running) return;
    const ms = Math.max(20, 700 / speed);
    const id = setInterval(() => stepOnce(), ms);
    return () => clearInterval(id);
  }, [running, speed, stepOnce]);

  // initial load
  useEffect(() => {
    assembleAndLoad();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const listing = useMemo(() => (program ? buildListing(program) : []), [program]);
  const curInstrIndex = snap && program ? program.pcToInstr.get(snap.pc) ?? -1 : -1;

  const onNic = snap ? cyclesToUs(snap.cycles) : 0;
  const { trips, label } = rdmaRoundTrips(preset.id, args);
  const rdmaUs = trips * RTT_US;
  // Latency is only meaningful once the program has actually executed instructions.
  const hasRun = !!snap && snap.instrRetired > 0;

  const changed = new Set(lastEvent?.regWrites.map((w) => w.reg) ?? []);

  return (
    <div className="pg">
      {/* preset picker */}
      <div className="pg-presets">
        {PRESETS.map((p) => (
          <button key={p.id} className={`chip ${p.id === preset.id ? 'active' : ''}`} onClick={() => loadPreset(p)}>
            {p.title}
          </button>
        ))}
      </div>

      <p className="pg-desc">
        <strong>{preset.title}.</strong> {preset.description}
        <span className="pg-rtt">
          one-sided RDMA: <b>{preset.rdmaRtts}</b> → Tiara: <b>{preset.tiaraRtts}</b>
        </span>
      </p>

      <div className="pg-grid">
        {/* LEFT: editor */}
        <section className="pg-editor card">
          <div className="pg-tabs">
            <button className={mode === 'asm' ? 'on' : ''} onClick={() => setMode('asm')}>
              Tiara assembly
            </button>
            <button className={mode === 'c' ? 'on' : ''} onClick={() => setMode('c')} disabled={!preset.cSource && !cSrc}>
              Restricted C
            </button>
          </div>
          {mode === 'asm' ? (
            <textarea className="code" spellCheck={false} value={asmSrc} onChange={(e) => setAsmSrc(e.target.value)} />
          ) : (
            <>
              <textarea className="code" spellCheck={false} value={cSrc} onChange={(e) => setCSrc(e.target.value)} />
              <button className="btn primary wide" onClick={doCompile}>
                Compile C → Tiara assembly ▾
              </button>
            </>
          )}

          <div className="pg-args">
            <div className="pg-args-head">Arguments (r1–r8)</div>
            {preset.args.map((a) => (
              <label key={a.reg} className="arg-row" title={a.help}>
                <span className="arg-name">
                  r{a.reg} <em>{a.name}</em>
                </span>
                <input
                  value={argStr[a.reg - 1] ?? '0'}
                  onChange={(e) => {
                    const n = [...argStr];
                    n[a.reg - 1] = e.target.value;
                    setArgStr(n);
                  }}
                />
              </label>
            ))}
          </div>

          <div className="pg-controls">
            <button className="btn primary" onClick={assembleAndLoad}>
              Assemble &amp; load
            </button>
            <button className="btn" onClick={reset} disabled={!program}>
              Reset
            </button>
            <button className="btn" onClick={stepOnce} disabled={!program || snap?.halted}>
              Step ▸
            </button>
            <button className={`btn ${running ? 'warn' : 'go'}`} onClick={() => setRunning((r) => !r)} disabled={!program || snap?.halted}>
              {running ? '❚❚ Pause' : '▶ Run'}
            </button>
            <label className="speed">
              speed
              <input type="range" min={1} max={20} value={speed} onChange={(e) => setSpeed(Number(e.target.value))} />
            </label>
          </div>
          {error && <div className="pg-error">{error}</div>}
        </section>

        {/* MIDDLE: listing + state */}
        <section className="pg-exec">
          <div className="card listing">
            <h4>Instruction store {snap?.halted ? <span className="badge done">halted</span> : null}</h4>
            <div className="listing-body">
              {listing.length === 0 && <div className="muted">Assemble to populate the instruction store.</div>}
              {listing.map((it) => (
                <div key={it.index} className={`instr ${it.index === curInstrIndex ? 'current' : ''}`}>
                  <span className="pc">{it.pc.toString().padStart(2, '0')}</span>
                  <span className="enc">{it.words[0].slice(0, 8)}…</span>
                  <span className="mn">{it.mnemonic}</span>
                  <span className="srctxt">{it.src.replace(/^\s*/, '')}</span>
                </div>
              ))}
            </div>
          </div>

          <div className="card state">
            <h4>Architectural state</h4>
            <div className="state-meters">
              <Meter label="PC" value={snap ? snap.pc.toString() : '—'} />
              <Meter label="in-flight async" value={snap ? snap.inFlight.toString() : '—'} hot={!!snap && snap.inFlight > 0} />
              <Meter label="instr retired" value={snap ? snap.instrRetired.toString() : '—'} />
              <Meter label="loop depth" value={snap ? snap.loopStack.length.toString() : '—'} />
            </div>
            <div className="flags">
              flags:
              {(['Z', 'N', 'ERR', 'C'] as const).map((f) => (
                <span key={f} className={`flag ${snap?.flags[f] ? 'set' : ''}`}>
                  {f}
                </span>
              ))}
            </div>
            {snap && snap.loopStack.length > 0 && (
              <div className="loopstack">
                loop stack:
                {snap.loopStack.map((f, i) => (
                  <span key={i} className="lf">
                    [{f.startPc}–{f.endPc}) {f.remaining.toString()}/{f.count.toString()}
                  </span>
                ))}
              </div>
            )}
          </div>

          {/* latency comparison */}
          <div className="card latency">
            <h4>Latency: Tiara vs. one-sided RDMA</h4>
            {hasRun ? (
              <>
                <LatencyBar onNic={onNic} rdmaUs={rdmaUs} trips={trips} label={label} />
                <p className="muted small">
                  On-NIC execution latency is cycle-calibrated to the FPGA prototype (200 MHz; ~0.75 µs PCIe DMA per host
                  access). One-sided RDMA would need <b>{trips || '—'}</b> sequentially dependent round trips
                  {label ? ` (${label})` : ''}. Tiara collapses them into a single network round trip.
                </p>
              </>
            ) : (
              <p className="muted small latency-empty">
                Step or run the program to measure its on-NIC latency and compare it against one-sided RDMA.
              </p>
            )}
          </div>
        </section>

        {/* RIGHT: registers + memory + log */}
        <section className="pg-side">
          <div className="card regs">
            <h4>Register file</h4>
            <div className="reg-grid">
              {snap
                ? snap.regs.map((v, i) => (
                    <div key={i} className={`reg ${changed.has(i) ? 'changed' : ''} ${i === 0 ? 'zero' : ''} ${i >= 1 && i <= 8 ? 'arg' : ''}`}>
                      <span className="rn">r{i}</span>
                      <span className="rv">{hex(v)}</span>
                    </div>
                  ))
                : Array.from({ length: 16 }).map((_, i) => (
                    <div key={i} className="reg">
                      <span className="rn">r{i}</span>
                      <span className="rv">—</span>
                    </div>
                  ))}
            </div>
            {finalResult && (
              <div className="result">
                returned: r0–r3 ={' '}
                {finalResult.map((v, i) => (
                  <code key={i}>{hex(v)}</code>
                ))}
              </div>
            )}
          </div>

          <div className="card mem">
            <h4>Host DRAM {lastEvent?.mem ? <span className="badge mem-badge">{lastEvent.mem.kind}</span> : null}</h4>
            <MemoryView mem={memRef.current} active={lastEvent?.mem ?? null} tick={snap?.instrRetired ?? 0} />
          </div>

          <div className="card log">
            <h4>Execution trace</h4>
            <div className="log-body">
              {log.length === 0 && <div className="muted">Step or run to trace execution.</div>}
              {log.map((ev, i) => (
                <div key={i} className={`logline ${i === 0 ? 'fresh' : ''}`}>
                  <span className="lpc">{ev.pc.toString().padStart(2, '0')}</span>
                  <span className="lmn">{ev.mnemonic}</span>
                  {ev.regWrites.map((w) => (
                    <span key={w.reg} className="lw">
                      r{w.reg}←{hex(w.after)}
                    </span>
                  ))}
                  {ev.mem && (
                    <span className={`lmem ${ev.mem.remote ? 'remote' : ''}`}>
                      {ev.mem.kind} {addrLabel(ev.mem.addr)}
                    </span>
                  )}
                  <span className="lcyc">+{ev.cyclesDelta}c</span>
                  {ev.note && <span className="lnote">{ev.note}</span>}
                </div>
              ))}
            </div>
          </div>
        </section>
      </div>

      {/* verifier */}
      {report && (
        <div className={`card verifier ${report.ok ? 'ok' : 'bad'}`}>
          <h4>
            Static verifier {report.ok ? <span className="badge ok">PASS</span> : <span className="badge bad">REJECT</span>}
          </h4>
          <div className="verifier-stats">
            <span>{report.nInstructions} instructions</span>
            <span>static step bound: {report.staticStepBound}</span>
            <span>max in-flight async: {report.maxInflightAsync}</span>
          </div>
          {report.issues.length > 0 && (
            <ul className="issues">
              {report.issues.map((s, i) => (
                <li key={i}>{s}</li>
              ))}
            </ul>
          )}
          {report.notes.length > 0 && (
            <ul className="notes">
              {report.notes.map((s, i) => (
                <li key={i}>{s}</li>
              ))}
            </ul>
          )}
          <p className="muted small">
            The verifier proves termination (forward-only jumps + bounded loops) and that every memory access lands in a
            declared region — try deleting an <code>ANDI</code> mask after a <code>LOAD</code> and re-assembling to see it
            reject the opaque address.
          </p>
        </div>
      )}
    </div>
  );
}

function Meter({ label, value, hot }: { label: string; value: string; hot?: boolean }) {
  return (
    <div className={`meter ${hot ? 'hot' : ''}`}>
      <span className="meter-val">{value}</span>
      <span className="meter-label">{label}</span>
    </div>
  );
}

function LatencyBar({ onNic, rdmaUs, trips, label }: { onNic: number; rdmaUs: number; trips: number; label: string }) {
  const max = Math.max(onNic, rdmaUs, 1);
  const speedup = onNic > 0 ? rdmaUs / onNic : 0;
  return (
    <div className="latbars">
      <div className="latrow">
        <span className="latname">Tiara (on-NIC)</span>
        <div className="lattrack">
          <div className="latfill tiara" style={{ width: `${(onNic / max) * 100}%` }} />
        </div>
        <span className="latval">{onNic.toFixed(2)} µs</span>
      </div>
      <div className="latrow">
        <span className="latname">RDMA ({trips}×RTT)</span>
        <div className="lattrack">
          <div className="latfill rdma" style={{ width: `${(rdmaUs / max) * 100}%` }} />
        </div>
        <span className="latval">{rdmaUs.toFixed(2)} µs</span>
      </div>
      {speedup > 0 && rdmaUs > 0 && (
        <div className="speedup">
          {speedup >= 1 ? `${speedup.toFixed(1)}× lower on-NIC latency` : `${(1 / speedup).toFixed(1)}× — RPC/CPU territory`}
        </div>
      )}
    </div>
  );
}

function MemoryView({ mem, active, tick }: { mem: Memory; active: any; tick: number }) {
  const entries = useMemo(() => mem.entries(), [mem, tick]);
  const shown = entries.slice(0, 48);
  return (
    <div className="mem-body">
      {shown.length === 0 && <div className="muted">empty</div>}
      {shown.map(([addr, val]) => {
        const isActive = active && (active.addr === addr || active.src === addr);
        return (
          <div key={addr.toString()} className={`memrow ${isActive ? 'active' : ''}`}>
            <span className="maddr">{addrLabel(addr)}</span>
            <span className="mval">{hex(val)}</span>
          </div>
        );
      })}
      {entries.length > shown.length && <div className="muted small">…{entries.length - shown.length} more words</div>}
    </div>
  );
}

function parseArgs(argStr: string[]): bigint[] {
  const out: bigint[] = [];
  for (let i = 0; i < 8; i++) {
    const s = (argStr[i] ?? '0').trim();
    try {
      out.push(s === '' ? 0n : BigInt(s));
    } catch {
      out.push(0n);
    }
  }
  return out;
}
