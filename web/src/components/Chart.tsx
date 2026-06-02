import { useMemo, useRef, useState } from 'react';
import type { ChartSpec, Series } from '../data/eval';

interface Props {
  spec: ChartSpec;
  height?: number;
}

const PAD = { top: 16, right: 18, bottom: 44, left: 56 };

function niceTicks(min: number, max: number, count = 5): number[] {
  if (min === max) return [min];
  const span = max - min;
  const step0 = span / count;
  const mag = Math.pow(10, Math.floor(Math.log10(step0)));
  const norm = step0 / mag;
  const step = (norm >= 5 ? 5 : norm >= 2 ? 2 : 1) * mag;
  const start = Math.ceil(min / step) * step;
  const out: number[] = [];
  for (let v = start; v <= max + step * 1e-6; v += step) out.push(Number(v.toFixed(10)));
  return out;
}

function logTicks(min: number, max: number): number[] {
  const lo = Math.floor(Math.log10(min));
  const hi = Math.ceil(Math.log10(max));
  const out: number[] = [];
  for (let e = lo; e <= hi; e++) out.push(Math.pow(10, e));
  return out;
}

function fmt(v: number): string {
  if (v === 0) return '0';
  const a = Math.abs(v);
  if (a >= 1000) return v.toLocaleString(undefined, { maximumFractionDigits: 0 });
  if (a >= 1) return v.toLocaleString(undefined, { maximumFractionDigits: 2 });
  if (a >= 0.01) return v.toFixed(2);
  return v.toExponential(0);
}

export default function Chart({ spec, height = 320 }: Props) {
  const width = 560;
  const [hidden, setHidden] = useState<Set<string>>(new Set());
  const [hover, setHover] = useState<{ sx: number; items: { s: Series; p: { x: number; y: number } }[] } | null>(null);
  const svgRef = useRef<SVGSVGElement>(null);

  const active = spec.series.filter((s) => !hidden.has(s.name));

  const { xs, ys } = useMemo(() => {
    const xs: number[] = [];
    const ys: number[] = [];
    for (const s of active)
      for (const p of s.points) {
        xs.push(p.x);
        if (p.y > 0 || spec.yType === 'linear') ys.push(p.y);
      }
    return { xs, ys };
  }, [active, spec.yType]);

  const xMin = xs.length ? Math.min(...xs) : 0;
  const xMax = xs.length ? Math.max(...xs) : 1;
  let yMin = ys.length ? Math.min(...ys) : 0;
  let yMax = ys.length ? Math.max(...ys) : 1;
  if (spec.yType === 'linear') {
    yMin = Math.min(0, yMin);
    yMax = yMax * 1.08;
  } else {
    yMin = Math.max(yMin, Math.min(...ys.filter((y) => y > 0)) || 0.01);
    yMin = Math.pow(10, Math.floor(Math.log10(yMin)));
    yMax = Math.pow(10, Math.ceil(Math.log10(yMax)));
  }

  const plotW = width - PAD.left - PAD.right;
  const plotH = height - PAD.top - PAD.bottom;

  const sx = (x: number) => {
    if (spec.xType === 'log') {
      const lx = Math.log10(x);
      const lo = Math.log10(xMin);
      const hi = Math.log10(xMax);
      return PAD.left + ((lx - lo) / (hi - lo || 1)) * plotW;
    }
    return PAD.left + ((x - xMin) / (xMax - xMin || 1)) * plotW;
  };
  const sy = (y: number) => {
    if (spec.yType === 'log') {
      const ly = Math.log10(Math.max(y, yMin));
      const lo = Math.log10(yMin);
      const hi = Math.log10(yMax);
      return PAD.top + plotH - ((ly - lo) / (hi - lo || 1)) * plotH;
    }
    return PAD.top + plotH - ((y - yMin) / (yMax - yMin || 1)) * plotH;
  };

  const xTicks = spec.xType === 'log' ? logTicks(xMin, xMax) : niceTicks(xMin, xMax, 6);
  const yTicks = spec.yType === 'log' ? logTicks(yMin, yMax) : niceTicks(yMin, yMax, 5);

  const linePath = (s: Series) =>
    s.points
      .map((p, i) => `${i === 0 ? 'M' : 'L'} ${sx(p.x).toFixed(1)} ${sy(p.y).toFixed(1)}`)
      .join(' ');

  function onMove(e: React.MouseEvent) {
    const svg = svgRef.current;
    if (!svg) return;
    const pt = svg.getBoundingClientRect();
    const px = ((e.clientX - pt.left) / pt.width) * width;
    if (px < PAD.left || px > width - PAD.right) {
      setHover(null);
      return;
    }
    // nearest x among the union of data x's
    const allX = [...new Set(active.flatMap((s) => s.points.map((p) => p.x)))].sort((a, b) => a - b);
    let best = allX[0];
    let bd = Infinity;
    for (const x of allX) {
      const d = Math.abs(sx(x) - px);
      if (d < bd) {
        bd = d;
        best = x;
      }
    }
    const items = active
      .map((s) => ({ s, p: s.points.find((p) => p.x === best) }))
      .filter((it) => it.p) as { s: Series; p: { x: number; y: number } }[];
    if (items.length) setHover({ sx: sx(best), items });
  }

  return (
    <div className="chart">
      <div className="chart-head">
        <h4>{spec.title}</h4>
      </div>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${width} ${height}`}
        className="chart-svg"
        onMouseMove={onMove}
        onMouseLeave={() => setHover(null)}
        role="img"
        aria-label={spec.title}
      >
        {/* grid + y ticks */}
        {yTicks.map((t, i) => (
          <g key={`y${i}`}>
            <line x1={PAD.left} x2={width - PAD.right} y1={sy(t)} y2={sy(t)} className="grid" />
            <text x={PAD.left - 8} y={sy(t) + 3} className="tick" textAnchor="end">
              {fmt(t)}
            </text>
          </g>
        ))}
        {/* x ticks */}
        {xTicks.map((t, i) => (
          <g key={`x${i}`}>
            <line x1={sx(t)} x2={sx(t)} y1={PAD.top} y2={PAD.top + plotH} className="grid faint" />
            <text x={sx(t)} y={PAD.top + plotH + 16} className="tick" textAnchor="middle">
              {fmt(t)}
            </text>
          </g>
        ))}
        {/* axis labels */}
        <text x={PAD.left + plotW / 2} y={height - 6} className="axis-label" textAnchor="middle">
          {spec.xLabel}
        </text>
        <text
          x={14}
          y={PAD.top + plotH / 2}
          className="axis-label"
          textAnchor="middle"
          transform={`rotate(-90 14 ${PAD.top + plotH / 2})`}
        >
          {spec.yLabel}
        </text>

        {/* marker */}
        {spec.marker && spec.marker.x >= xMin && spec.marker.x <= xMax && (
          <g>
            <line x1={sx(spec.marker.x)} x2={sx(spec.marker.x)} y1={PAD.top} y2={PAD.top + plotH} className="marker-line" />
            <text x={sx(spec.marker.x) - 6} y={PAD.top + 12} className="marker-label" textAnchor="end">
              {spec.marker.label}
            </text>
          </g>
        )}

        {/* hover crosshair */}
        {hover && <line x1={hover.sx} x2={hover.sx} y1={PAD.top} y2={PAD.top + plotH} className="crosshair" />}

        {/* series */}
        {active.map((s) => (
          <g key={s.name}>
            <path
              d={linePath(s)}
              fill="none"
              stroke={s.color}
              strokeWidth={s.emphasis ? 3 : 1.8}
              strokeDasharray={s.dashed ? '5 4' : undefined}
              className={s.emphasis ? 'line emph' : 'line'}
            />
            {s.points.map((p, i) => (
              <circle key={i} cx={sx(p.x)} cy={sy(p.y)} r={s.emphasis ? 3 : 2.2} fill={s.color} />
            ))}
          </g>
        ))}

        {/* hover dots */}
        {hover &&
          hover.items.map((it) => (
            <circle key={it.s.name} cx={hover.sx} cy={sy(it.p.y)} r={4.5} fill={it.s.color} stroke="#fff" strokeWidth={1.5} />
          ))}
      </svg>

      {hover && (
        <div className="chart-tip" style={{ left: `${(hover.sx / width) * 100}%` }}>
          <div className="tip-x">
            {spec.xLabel.split(' ')[0]}: <b>{fmt(hover.items[0].p.x)}</b>
          </div>
          {hover.items
            .slice()
            .sort((a, b) => b.p.y - a.p.y)
            .map((it) => (
              <div key={it.s.name} className="tip-row">
                <span className="dot" style={{ background: it.s.color }} />
                {it.s.name}: <b>{fmt(it.p.y)}</b>
              </div>
            ))}
        </div>
      )}

      <div className="legend">
        {spec.series.map((s) => (
          <button
            key={s.name}
            className={`legend-item ${hidden.has(s.name) ? 'off' : ''}`}
            onClick={() => {
              const n = new Set(hidden);
              n.has(s.name) ? n.delete(s.name) : n.add(s.name);
              setHidden(n);
            }}
          >
            <span className="dot" style={{ background: s.color }} />
            {s.name}
            {s.emphasis ? ' ★' : ''}
          </button>
        ))}
      </div>
      <p className="chart-caption">{spec.caption}</p>
    </div>
  );
}
