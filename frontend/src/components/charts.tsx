import { useEffect, useRef, useState } from 'react'
import type { DailyRow, EquityPoint } from '../types'
import { fmtMoney } from './ui'

// Chart mark colours, validated (dataviz validate_palette.js, dark, surface #10141c):
// lightness/chroma/contrast pass; CVD ΔE 6.2 is in the floor band, so polarity is ALSO encoded by
// position (above/below the zero line) and a signed value in every label/tooltip.
export const MARK = { gain: '#1ea672', loss: '#e5534b', line: '#e3b341', grid: '#1f2633', axis: '#5b6476' }

function useWidth<T extends HTMLElement>() {
  const ref = useRef<T>(null)
  const [w, setW] = useState(600)
  useEffect(() => {
    if (!ref.current) return
    const ro = new ResizeObserver(([e]) => setW(Math.max(200, e.contentRect.width)))
    ro.observe(ref.current)
    return () => ro.disconnect()
  }, [])
  return [ref, w] as const
}

function niceTicks(min: number, max: number, count = 4): number[] {
  if (min === max) return [min]
  const span = max - min
  const step0 = span / count
  const mag = 10 ** Math.floor(Math.log10(step0))
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => span / s <= count) ?? mag * 10
  const out: number[] = []
  for (let v = Math.ceil(min / step) * step; v <= max + 1e-9; v += step) out.push(Math.round(v * 100) / 100)
  return out
}

const PAD = { l: 56, r: 12, t: 12, b: 24 }

function Tooltip({ x, y, w, children }: { x: number; y: number; w: number; children: React.ReactNode }) {
  const left = Math.min(Math.max(x + 12, 0), w - 190)
  return (
    <div
      className="pointer-events-none absolute z-10 w-[180px] rounded-md border border-line bg-panel-2/95 px-2.5 py-2 text-xs shadow-xl"
      style={{ left, top: Math.max(0, y - 10) }}
    >
      {children}
    </div>
  )
}

/** Cumulative realized P/L by closed cycle (x = cycle sequence, since many cycles can close in the same second). */
export function EquityChart({ points, currency, height = 220 }: { points: EquityPoint[]; currency: string; height?: number }) {
  const [ref, w] = useWidth<HTMLDivElement>()
  const [hover, setHover] = useState<number | null>(null)
  if (points.length === 0) return <Empty height={height} />

  const data = [{ n: 0, cum: 0 } as EquityPoint, ...points]
  const ys = data.map((p) => p.cum)
  const ticks = niceTicks(Math.min(0, ...ys), Math.max(0, ...ys))
  const yMin = Math.min(ticks[0], ...ys)
  const yMax = Math.max(ticks[ticks.length - 1], ...ys)
  const iw = w - PAD.l - PAD.r
  const ih = height - PAD.t - PAD.b
  const x = (n: number) => PAD.l + (n / Math.max(1, data.length - 1)) * iw
  const y = (v: number) => PAD.t + (1 - (v - yMin) / (yMax - yMin || 1)) * ih
  const path = data.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.cum).toFixed(1)}`).join('')
  const area = `${path}L${x(data.length - 1).toFixed(1)},${y(0).toFixed(1)}L${x(0).toFixed(1)},${y(0).toFixed(1)}Z`
  const hp = hover !== null ? data[hover] : null

  const onMove = (e: React.MouseEvent<SVGSVGElement>) => {
    const r = e.currentTarget.getBoundingClientRect()
    const i = Math.round(((e.clientX - r.left - PAD.l) / iw) * (data.length - 1))
    setHover(i >= 1 && i < data.length ? i : null)
  }

  return (
    <div ref={ref} className="relative">
      <svg width={w} height={height} onMouseMove={onMove} onMouseLeave={() => setHover(null)} role="img" aria-label="Cumulative P/L by cycle">
        <defs>
          <linearGradient id="eqfill" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0" stopColor={MARK.line} stopOpacity="0.22" />
            <stop offset="1" stopColor={MARK.line} stopOpacity="0" />
          </linearGradient>
        </defs>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={PAD.l} x2={w - PAD.r} y1={y(t)} y2={y(t)} stroke={MARK.grid} strokeDasharray={t === 0 ? undefined : '2 4'} />
            <text x={PAD.l - 8} y={y(t) + 3.5} textAnchor="end" fontSize="11" fill={MARK.axis} className="num">
              {t.toFixed(Math.abs(t) < 10 ? 2 : 0)}
            </text>
          </g>
        ))}
        <path d={area} fill="url(#eqfill)" />
        <path d={path} fill="none" stroke={MARK.line} strokeWidth="2" strokeLinejoin="round" />
        <text x={w - PAD.r} y={height - 6} textAnchor="end" fontSize="11" fill={MARK.axis}>
          cycle # →
        </text>
        {hp && (
          <g>
            <line x1={x(hover!)} x2={x(hover!)} y1={PAD.t} y2={PAD.t + ih} stroke={MARK.axis} strokeDasharray="3 3" />
            <circle cx={x(hover!)} cy={y(hp.cum)} r="4.5" fill={MARK.line} stroke="#10141c" strokeWidth="2" />
          </g>
        )}
      </svg>
      {hp && (
        <Tooltip x={x(hover!)} y={y(hp.cum)} w={w}>
          <div className="mb-1 text-muted">
            #{hp.n} · session {hp.session_id} · C{hp.cycle_no} · {hp.reason}
          </div>
          <div className="num flex justify-between">
            <span className="text-muted">cycle</span>
            <span className={hp.pnl >= 0 ? 'text-up' : 'text-down'}>{fmtMoney(hp.pnl)}</span>
          </div>
          <div className="num flex justify-between">
            <span className="text-muted">cumulative</span>
            <span className="text-text">{fmtMoney(hp.cum, currency)}</span>
          </div>
          <div className="text-faint">{new Date(hp.t * 1000).toLocaleString()}</div>
        </Tooltip>
      )}
    </div>
  )
}

/** Daily realized P/L, bars diverging from a zero baseline. */
export function DailyBars({ rows, currency, height = 220 }: { rows: DailyRow[]; currency: string; height?: number }) {
  const [ref, w] = useWidth<HTMLDivElement>()
  const [hover, setHover] = useState<number | null>(null)
  if (rows.length === 0) return <Empty height={height} />

  const vals = rows.map((r) => r.pnl)
  const ticks = niceTicks(Math.min(0, ...vals), Math.max(0, ...vals))
  const yMin = Math.min(ticks[0], ...vals)
  const yMax = Math.max(ticks[ticks.length - 1], ...vals)
  const iw = w - PAD.l - PAD.r
  const ih = height - PAD.t - PAD.b
  const y = (v: number) => PAD.t + (1 - (v - yMin) / (yMax - yMin || 1)) * ih
  const slot = iw / rows.length
  const bw = Math.max(3, Math.min(36, slot - 2)) // 2px surface gap between bars
  const labelEvery = Math.ceil(rows.length / Math.max(1, Math.floor(iw / 64)))
  const hr = hover !== null ? rows[hover] : null

  return (
    <div ref={ref} className="relative">
      <svg width={w} height={height} onMouseLeave={() => setHover(null)} role="img" aria-label="Daily P/L">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={PAD.l} x2={w - PAD.r} y1={y(t)} y2={y(t)} stroke={MARK.grid} strokeDasharray={t === 0 ? undefined : '2 4'} />
            <text x={PAD.l - 8} y={y(t) + 3.5} textAnchor="end" fontSize="11" fill={MARK.axis} className="num">
              {t.toFixed(Math.abs(t) < 10 ? 2 : 0)}
            </text>
          </g>
        ))}
        {rows.map((r, i) => {
          const cx = PAD.l + slot * i + slot / 2
          const top = r.pnl >= 0 ? y(r.pnl) : y(0)
          const h = Math.max(1, Math.abs(y(r.pnl) - y(0)))
          const rr = Math.min(4, bw / 2, h)
          // rounded at the data end, square at the baseline
          const d =
            r.pnl >= 0
              ? `M${cx - bw / 2},${top + h}V${top + rr}Q${cx - bw / 2},${top} ${cx - bw / 2 + rr},${top}H${cx + bw / 2 - rr}Q${cx + bw / 2},${top} ${cx + bw / 2},${top + rr}V${top + h}Z`
              : `M${cx - bw / 2},${top}V${top + h - rr}Q${cx - bw / 2},${top + h} ${cx - bw / 2 + rr},${top + h}H${cx + bw / 2 - rr}Q${cx + bw / 2},${top + h} ${cx + bw / 2},${top + h - rr}V${top}Z`
          return (
            <g key={r.date} onMouseEnter={() => setHover(i)}>
              <rect x={cx - slot / 2} y={PAD.t} width={slot} height={ih} fill="transparent" />
              <path d={d} fill={r.pnl >= 0 ? MARK.gain : MARK.loss} opacity={hover === null || hover === i ? 1 : 0.45} />
              {i % labelEvery === 0 && (
                <text x={cx} y={height - 6} textAnchor="middle" fontSize="11" fill={MARK.axis}>
                  {r.date.slice(5)}
                </text>
              )}
            </g>
          )
        })}
      </svg>
      {hr && (
        <Tooltip x={PAD.l + slot * hover! + slot / 2} y={y(Math.max(0, hr.pnl))} w={w}>
          <div className="mb-1 text-muted">{hr.date}</div>
          <div className="num flex justify-between">
            <span className="text-muted">P/L</span>
            <span className={hr.pnl >= 0 ? 'text-up' : 'text-down'}>{fmtMoney(hr.pnl, currency)}</span>
          </div>
          <div className="num flex justify-between">
            <span className="text-muted">cycles</span>
            <span>
              {hr.cycles} ({hr.wins}W / {hr.losses}L)
            </span>
          </div>
        </Tooltip>
      )}
    </div>
  )
}

function Empty({ height }: { height: number }) {
  return (
    <div className="flex items-center justify-center text-xs text-faint" style={{ height }}>
      No closed cycles in this range yet.
    </div>
  )
}
