const RDMA = '#2d6cdf';
const TIARA = '#e0245e';
const INK = '#14171f';
const MUTED = '#8a92a6';
const LINE = '#d8deea';

const N = 9;
const xL = 96;
const xR = 924;
const slot = (xR - xL) / N;

function rdmaScenario() {
  const yC = 70;
  const yM = 146;
  const pts: string[] = [`${xL},${yC}`];
  const dots: { x: number; n: number }[] = [];
  for (let i = 0; i < N; i++) {
    const mid = xL + i * slot + slot * 0.5;
    const end = xL + (i + 1) * slot;
    pts.push(`${mid},${yM}`, `${end},${yC}`);
    dots.push({ x: mid, n: i + 1 });
  }
  return { yC, yM, line: pts.join(' '), dots };
}

export default function IndirectionTimeline() {
  const r = rdmaScenario();

  // Tiara: one request down, nine local PCIe loads, one response up — all within ~1 RTT.
  const tyC = 296;
  const tyM = 372;
  const tReqEnd = xL + 26;
  const tLocalStart = xL + 34;
  const tLocalEnd = xL + 104;
  const tRespStart = xL + 112;
  const tEnd = xL + 138;
  const locals = Array.from({ length: N }, (_, i) => tLocalStart + ((tLocalEnd - tLocalStart) / (N - 1)) * i);

  return (
    <figure className="timeline-fig card">
      <svg
        viewBox="0 0 960 420"
        role="img"
        aria-label="Timeline: one-sided RDMA needs nine sequential round trips, Tiara needs one"
      >
        {/* ---------- One-sided RDMA ---------- */}
        <text x={xL} y={30} className="tl-title" fill={INK}>
          One-sided RDMA — 9 sequential round trips
        </text>
        <text x={8} y={r.yC + 4} className="tl-lane" fill={MUTED}>Client</text>
        <text x={8} y={r.yM + 4} className="tl-lane" fill={MUTED}>Remote</text>
        <line x1={xL} y1={r.yC} x2={xR} y2={r.yC} stroke={LINE} strokeDasharray="3 4" />
        <line x1={xL} y1={r.yM} x2={xR} y2={r.yM} stroke={LINE} strokeDasharray="3 4" />
        <polyline points={r.line} fill="none" stroke={RDMA} strokeWidth={2.2} strokeLinejoin="round" />
        {r.dots.map((d) => (
          <g key={d.n}>
            <circle cx={d.x} cy={r.yM} r={11} fill="#fff" stroke={RDMA} strokeWidth={1.6} />
            <text x={d.x} y={r.yM + 4} className="tl-num" fill={RDMA}>{d.n}</text>
          </g>
        ))}
        <line x1={xL} y1={196} x2={xR} y2={196} stroke={RDMA} strokeWidth={1} />
        <line x1={xL} y1={190} x2={xL} y2={202} stroke={RDMA} strokeWidth={1} />
        <line x1={xR} y1={190} x2={xR} y2={202} stroke={RDMA} strokeWidth={1} />
        <text x={(xL + xR) / 2} y={216} className="tl-measure" fill={RDMA}>
          ≈ 9 × RTT · link sits idle between every hop
        </text>

        {/* ---------- Tiara ---------- */}
        <text x={xL} y={262} className="tl-title" fill={INK}>
          Tiara — one round trip, chain resolved on the NIC
        </text>
        <text x={8} y={tyC + 4} className="tl-lane" fill={MUTED}>Client</text>
        <text x={8} y={tyM + 4} className="tl-lane" fill={MUTED}>NIC+DRAM</text>
        <line x1={xL} y1={tyC} x2={xR} y2={tyC} stroke={LINE} strokeDasharray="3 4" />
        <line x1={xL} y1={tyM} x2={xR} y2={tyM} stroke={LINE} strokeDasharray="3 4" />
        <rect x={tEnd} y={tyC} width={xR - tEnd} height={tyM - tyC} fill="rgba(224,36,94,0.06)" />
        <text x={(tEnd + xR) / 2} y={(tyC + tyM) / 2 + 4} className="tl-saved" fill={TIARA}>
          latency saved — RDMA would still owe 8 more round trips
        </text>
        <polyline points={`${xL},${tyC} ${tReqEnd},${tyM}`} fill="none" stroke={TIARA} strokeWidth={2.2} />
        <line x1={tLocalStart} y1={tyM} x2={tLocalEnd} y2={tyM} stroke={TIARA} strokeWidth={2.2} />
        {locals.map((x, i) => (
          <circle key={i} cx={x} cy={tyM} r={3.2} fill={TIARA} />
        ))}
        <polyline points={`${tRespStart},${tyM} ${tEnd},${tyC}`} fill="none" stroke={TIARA} strokeWidth={2.2} />
        <text x={(tLocalStart + tLocalEnd) / 2} y={tyM - 12} className="tl-local" fill={MUTED}>
          9 local PCIe loads (~0.75 µs each)
        </text>
        <line x1={xL} y1={tyM + 22} x2={tEnd} y2={tyM + 22} stroke={TIARA} strokeWidth={1} />
        <line x1={xL} y1={tyM + 16} x2={xL} y2={tyM + 28} stroke={TIARA} strokeWidth={1} />
        <line x1={tEnd} y1={tyM + 16} x2={tEnd} y2={tyM + 28} stroke={TIARA} strokeWidth={1} />
        <text x={tEnd + 12} y={tyM + 26} className="tl-measure start" fill={TIARA}>≈ 1 × RTT</text>
      </svg>
      <figcaption className="muted small">
        Both lanes share the same time axis. RDMA can issue hop <i>i+1</i> only after hop <i>i</i> returns, so latency
        grows as depth × RTT. Tiara ships the operator once; the NIC chases all nine pointers locally over PCIe and
        replies in a single network round trip.
      </figcaption>
    </figure>
  );
}
