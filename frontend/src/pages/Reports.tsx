import { AnimatePresence, motion } from 'framer-motion'
import { Fragment, useEffect, useState } from 'react'
import { api } from '../api'
import { DailyBars, EquityChart, MARK } from '../components/charts'
import { fmt, fmtMoney, pnlColor } from '../components/ui'
import type { CycleRow, Report, ReportKpis } from '../types'

const RANGES = [
  { key: 'today', label: 'Today' },
  { key: '7d', label: '7 days' },
  { key: '30d', label: '30 days' },
  { key: 'all', label: 'All time' },
] as const
type RangeKey = (typeof RANGES)[number]['key']

function sinceFor(k: RangeKey): number {
  const now = new Date()
  if (k === 'all') return 0
  if (k === 'today') return new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000
  return Date.now() / 1000 - (k === '7d' ? 7 : 30) * 86400
}

const dur = (s: number | null) => {
  if (s === null) return '—'
  if (s < 60) return `${Math.round(s)}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${Math.round(s % 60)}s`
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
}
const pct = (n: number | null) => (n === null ? '—' : `${(n * 100).toFixed(1)}%`)

export function Reports({ currency }: { currency: string }) {
  const [range, setRange] = useState<RangeKey>('all')
  const [rep, setRep] = useState<Report | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [open, setOpen] = useState<string | null>(null)
  const [openRows, setOpenRows] = useState<CycleRow[]>([])
  const since = sinceFor(range)

  const load = () =>
    api
      .report(sinceFor(range))
      .then((r) => {
        setRep(r)
        setError(null)
      })
      .catch((e: Error) => setError(e.message))

  useEffect(() => {
    load()
    const t = window.setInterval(load, 10000) // refresh while a session runs
    return () => window.clearInterval(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [range])

  const toggle = (id: string) => {
    if (open === id) return setOpen(null)
    setOpen(id)
    setOpenRows([])
    api.cycles(id).then((rows) => setOpenRows([...rows].reverse())).catch(() => undefined)
  }

  const k = rep?.kpis
  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto max-w-7xl space-y-5 p-5">
        {/* filters: one row above everything */}
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="mr-4 text-lg font-semibold">Performance report</h1>
          <div className="flex rounded-md border border-line p-0.5">
            {RANGES.map((r) => (
              <button
                key={r.key}
                onClick={() => setRange(r.key)}
                className={`rounded px-3 py-1 text-xs font-medium transition-colors ${
                  range === r.key ? 'bg-gold/15 text-gold' : 'text-muted hover:text-text'
                }`}
              >
                {r.label}
              </button>
            ))}
          </div>
          <a className="btn ml-auto border border-line text-xs text-muted hover:bg-panel-2 hover:text-text" href={api.csvUrl(since)}>
            Export cycles (CSV)
          </a>
        </div>
        {error && <p className="rounded bg-down/10 px-3 py-2 text-sm text-down">{error}</p>}

        {k && <KpiGrid k={k} currency={currency} />}

        {rep && (
          <div className="grid gap-4 lg:grid-cols-2">
            <Card title="Cumulative P/L" subtitle="Realized, after each closed cycle">
              <EquityChart points={rep.equity} currency={currency} />
            </Card>
            <Card title="Daily P/L" subtitle="Realized per day (VPS local date)">
              <DailyBars rows={rep.daily} currency={currency} />
            </Card>
          </div>
        )}

        {rep && (
          <div className="grid gap-4 lg:grid-cols-[1fr_2fr]">
            <Card title="Why cycles closed" subtitle="Count and P/L by close reason">
              <Reasons rows={rep.reasons} currency={currency} />
            </Card>
            <Card title="Execution quality" subtitle="Fill vs planned entry (BUY fills at ask, so the spread counts)">
              <div className="num grid grid-cols-2 gap-4 text-sm sm:grid-cols-4">
                <Mini label="Avg slippage" value={k?.avg_slippage === null ? '—' : `${fmt(k?.avg_slippage, 2)} pts`} />
                <Mini label="Max slippage" value={k?.max_slippage === null ? '—' : `${fmt(k?.max_slippage, 2)} pts`} />
                <Mini label="Avg cycle time" value={dur(k?.avg_duration_s ?? null)} />
                <Mini label="Open cycles" value={String(k?.open ?? 0)} />
              </div>
            </Card>
          </div>
        )}

        {rep && (
          <Card title="Sessions" subtitle="Each Arm starts a session. Click a row to see its cycles.">
            <div className="overflow-x-auto">
              <table className="num w-full text-xs">
                <thead className="text-faint">
                  <tr className="[&>th]:px-3 [&>th]:py-2 [&>th]:text-left [&>th]:font-normal">
                    <th>Started</th>
                    <th>Session</th>
                    <th>Mode</th>
                    <th>Trigger</th>
                    <th>Lot</th>
                    <th>TP / SL pts</th>
                    <th>Gap</th>
                    <th>Stop @</th>
                    <th>Cycles</th>
                    <th>TP / SL</th>
                    <th className="!text-right">P/L</th>
                    <th>Ended by</th>
                    <th>Duration</th>
                  </tr>
                </thead>
                <tbody>
                  {rep.sessions.map((s) => (
                    <Fragment key={s.id}>
                      <tr
                        onClick={() => toggle(s.id)}
                        className="cursor-pointer border-t border-line/60 hover:bg-panel-2 [&>td]:px-3 [&>td]:py-2"
                      >
                        <td className="text-muted">{new Date(s.started_at * 1000).toLocaleString()}</td>
                        <td>
                          <span className="mr-1 text-faint">{open === s.id ? '▾' : '▸'}</span>
                          {s.id}
                        </td>
                        <td>
                          {s.mode} <span className={s.direction === 'BUY' ? 'text-up' : 'text-down'}>{s.direction}</span>
                        </td>
                        <td>{fmt(s.trigger_price)}</td>
                        <td>{s.lot}</td>
                        <td>
                          {s.tp_points ?? '—'} / {s.sl_points ?? '—'}
                        </td>
                        <td>{s.mode === 'CYCLE' ? (s.cycle_gap ?? 'blank') : '—'}</td>
                        <td>{fmt(s.stop_price)}</td>
                        <td>{s.cycles}</td>
                        <td>
                          <span className="text-up">{s.tp}</span> / <span className="text-down">{s.sl}</span>
                        </td>
                        <td className={`text-right ${pnlColor(s.pnl)}`}>{fmtMoney(s.pnl)}</td>
                        <td className="text-muted">
                          {s.ended_at ? (s.stop_reason ?? '').replaceAll('_', ' ').toLowerCase() : <span className="text-info">running</span>}
                        </td>
                        <td className="text-muted">{dur(s.duration_s)}</td>
                      </tr>
                      <AnimatePresence initial={false}>
                        {open === s.id && (
                          <tr>
                            <td colSpan={13} className="p-0">
                              <motion.div initial={{ height: 0 }} animate={{ height: 'auto' }} exit={{ height: 0 }} className="overflow-hidden bg-bg/60">
                                <CycleTable rows={openRows} />
                              </motion.div>
                            </td>
                          </tr>
                        )}
                      </AnimatePresence>
                    </Fragment>
                  ))}
                </tbody>
              </table>
              {rep.sessions.length === 0 && <p className="p-6 text-center text-xs text-faint">No sessions in this range.</p>}
            </div>
          </Card>
        )}
      </div>
    </div>
  )
}

function KpiGrid({ k, currency }: { k: ReportKpis; currency: string }) {
  const tiles: { label: string; value: React.ReactNode; hint?: string; tone?: string }[] = [
    { label: 'Net P/L', value: fmtMoney(k.net_pnl, currency), tone: pnlColor(k.net_pnl), hint: `+${k.gross_profit.toFixed(2)} / ${k.gross_loss.toFixed(2)}` },
    { label: 'Win rate', value: pct(k.win_rate), hint: `${k.wins} won · ${k.losses} lost of ${k.closed} closed` },
    { label: 'Profit factor', value: k.profit_factor === null ? '—' : k.profit_factor.toFixed(2), hint: 'gross profit ÷ gross loss' },
    { label: 'Cycles', value: String(k.cycles), hint: `${k.tp_count} TP · ${k.sl_count} SL · ${k.sessions} sessions` },
    { label: 'Avg win / loss', value: `${fmt(k.avg_win)} / ${fmt(k.avg_loss)}`, hint: `expectancy ${fmtMoney(k.expectancy)} per cycle` },
    { label: 'Max drawdown', value: k.max_drawdown ? `−${k.max_drawdown.toFixed(2)}` : '0.00', hint: 'peak-to-trough, realized', tone: k.max_drawdown ? 'text-down' : '' },
    { label: 'Best / worst', value: `${fmtMoney(k.best)} / ${fmtMoney(k.worst)}`, hint: 'single cycle' },
    { label: 'Streaks', value: `${k.max_win_streak}W / ${k.max_loss_streak}L`, hint: 'longest in a row' },
  ]
  return (
    <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
      {tiles.map((t, i) => (
        <motion.div
          key={t.label}
          initial={{ opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: i * 0.03 }}
          className="rounded-lg border border-line bg-panel p-3.5"
        >
          <div className="text-xs tracking-wide text-muted uppercase">{t.label}</div>
          <div className={`num mt-1 text-xl font-semibold ${t.tone ?? ''}`}>{t.value}</div>
          {t.hint && <div className="mt-0.5 text-xs text-faint">{t.hint}</div>}
        </motion.div>
      ))}
    </div>
  )
}

function Card({ title, subtitle, children }: { title: string; subtitle?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg border border-line bg-panel p-4">
      <h2 className="text-sm font-medium">{title}</h2>
      {subtitle && <p className="mb-3 text-xs text-faint">{subtitle}</p>}
      {children}
    </section>
  )
}

function Mini({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[11px] text-faint uppercase">{label}</div>
      <div className="mt-0.5">{value}</div>
    </div>
  )
}

function Reasons({ rows, currency }: { rows: Report['reasons']; currency: string }) {
  if (rows.length === 0) return <p className="py-6 text-center text-xs text-faint">No closed cycles yet.</p>
  const max = Math.max(...rows.map((r) => r.count))
  return (
    <ul className="space-y-2.5">
      {rows.map((r) => (
        <li key={r.reason} className="text-xs">
          <div className="mb-1 flex justify-between">
            <span className="font-medium">{r.reason.replaceAll('_', ' ')}</span>
            <span className="num text-muted">
              {r.count} · <span className={pnlColor(r.pnl)}>{fmtMoney(r.pnl, currency)}</span>
            </span>
          </div>
          <div className="h-2 rounded-full bg-bg">
            <div
              className="h-2 rounded-full"
              style={{
                width: `${(r.count / max) * 100}%`,
                background: r.reason === 'TP' ? MARK.gain : r.reason === 'SL' ? MARK.loss : '#f5a524',
              }}
            />
          </div>
        </li>
      ))}
    </ul>
  )
}

function CycleTable({ rows }: { rows: CycleRow[] }) {
  if (rows.length === 0) return <p className="p-4 text-xs text-faint">Loading / no cycles.</p>
  return (
    <table className="num w-full text-xs">
      <thead className="text-faint">
        <tr className="[&>th]:px-3 [&>th]:py-1.5 [&>th]:text-right [&>th]:font-normal">
          <th className="!text-left">Cycle</th>
          <th>Planned</th>
          <th>Fill</th>
          <th>Slip</th>
          <th>TP</th>
          <th>SL</th>
          <th>Closed @</th>
          <th className="!text-left">Result</th>
          <th>P/L</th>
          <th>Opened</th>
          <th>Duration</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.id} className="border-t border-line/40 [&>td]:px-3 [&>td]:py-1.5 [&>td]:text-right">
            <td className="!text-left text-muted">C{r.cycle_no}</td>
            <td>{fmt(r.planned_entry)}</td>
            <td>{fmt(r.fill_price, 3)}</td>
            <td>{fmt(r.slippage)}</td>
            <td>{fmt(r.tp)}</td>
            <td>{fmt(r.sl)}</td>
            <td>{fmt(r.close_price, 3)}</td>
            <td className="!text-left">{r.close_reason ?? 'open'}</td>
            <td className={pnlColor(r.pnl)}>{r.pnl === null ? '—' : fmtMoney(r.pnl)}</td>
            <td className="text-muted">{r.open_time ? new Date(r.open_time * 1000).toLocaleTimeString() : '—'}</td>
            <td className="text-muted">{r.open_time && r.close_time ? dur(r.close_time - r.open_time) : '—'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
