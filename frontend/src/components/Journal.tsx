import { AnimatePresence, motion } from 'framer-motion'
import { useEffect, useState } from 'react'
import type { CycleRow } from '../types'
import { NumberTicker, fmt, fmtMoney, pnlColor } from './ui'

const dur = (s: number) => {
  if (s < 60) return `${Math.round(s)}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${Math.round(s % 60)}s`
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
}

const RESULT_CLS: Record<string, string> = {
  TP: 'bg-up/15 text-up',
  SL: 'bg-down/15 text-down',
}

export function Journal({ rows, sessionPnl, currency, onOpenLog }: { rows: CycleRow[]; sessionPnl: number; currency: string; onOpenLog: () => void }) {
  const [now, setNow] = useState(() => Date.now() / 1000)
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now() / 1000), 1000)
    return () => window.clearInterval(t)
  }, [])

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-4 border-b border-line px-4 py-2">
        <h2 className="text-sm font-medium">Cycle journal</h2>
        <span className="text-xs text-muted">
          Session P/L{' '}
          <span className={`text-sm ${pnlColor(sessionPnl)}`}>
            <NumberTicker value={sessionPnl} format={(n) => fmtMoney(n, currency)} />
          </span>
        </span>
        <button className="ml-auto rounded px-2 py-1 text-xs text-muted hover:bg-panel-2 hover:text-text" onClick={onOpenLog}>
          Event log ›
        </button>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        <table className="num w-full text-xs">
          <thead className="sticky top-0 bg-panel text-faint">
            <tr className="[&>th]:px-3 [&>th]:py-1.5 [&>th]:font-normal">
              <th className="text-left">#</th>
              <th className="text-left">Dir</th>
              <th className="text-right">Planned</th>
              <th className="text-right">Fill</th>
              <th className="text-right">Slip</th>
              <th className="text-right">TP</th>
              <th className="text-right">SL</th>
              <th className="text-left">Result</th>
              <th className="text-right">P/L</th>
              <th className="text-right">Duration</th>
            </tr>
          </thead>
          <tbody>
            <AnimatePresence initial={false}>
              {rows.map((r) => (
                <motion.tr
                  key={r.id}
                  layout
                  initial={{ opacity: 0, backgroundColor: 'rgba(227,179,65,0.12)' }}
                  animate={{ opacity: 1, backgroundColor: 'rgba(0,0,0,0)' }}
                  transition={{ duration: 0.8 }}
                  className="border-t border-line/60 [&>td]:px-3 [&>td]:py-1.5"
                >
                  <td className="text-muted">C{r.cycle_no}</td>
                  <td className={r.direction === 'BUY' ? 'text-up' : 'text-down'}>{r.direction}</td>
                  <td className="text-right">{fmt(r.planned_entry)}</td>
                  <td className="text-right">{fmt(r.fill_price, 3)}</td>
                  <td className={`text-right ${(r.slippage ?? 0) > 0 ? 'text-warn' : 'text-muted'}`}>{fmt(r.slippage)}</td>
                  <td className="text-right text-up/90">{fmt(r.tp)}</td>
                  <td className="text-right text-down/90">{fmt(r.sl)}</td>
                  <td>
                    {r.close_reason ? (
                      <span className={`rounded px-1.5 py-0.5 text-[10px] font-semibold ${RESULT_CLS[r.close_reason] ?? 'bg-warn/15 text-warn'}`}>
                        {r.close_reason.replaceAll('_', ' ')}
                      </span>
                    ) : (
                      <span className="text-info">open</span>
                    )}
                  </td>
                  <td className={`text-right ${pnlColor(r.pnl)}`}>{r.pnl === null ? '—' : fmtMoney(r.pnl)}</td>
                  <td className="text-right text-muted">
                    {r.open_time ? dur((r.close_time ?? now) - r.open_time) : '—'}
                  </td>
                </motion.tr>
              ))}
            </AnimatePresence>
          </tbody>
        </table>
        {rows.length === 0 && <p className="p-6 text-center text-xs text-faint">No cycles yet. Arm the bot to start.</p>}
      </div>
    </div>
  )
}
