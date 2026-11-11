import { AnimatePresence, motion } from 'framer-motion'
import { useEffect, useMemo, useState } from 'react'
import { api } from '../api'
import { ACTIVE_STATES, type CycleConfig, type Direction, type EngineSnapshot, type Mode, type Tick, type Validation } from '../types'
import { NumberTicker, fmt, fmtMoney, pnlColor } from './ui'

interface FormState {
  direction: Direction
  trigger: string
  lot: string
  tpSlInput: 'points' | 'price'
  tp: string
  sl: string
  tpPrice: string
  slPrice: string
  gap: string
  stop: string
  gapEntryMode: CycleConfig['gap_entry_mode']
  slMode: CycleConfig['sl_mode']
  levelAnchor: CycleConfig['level_anchor']
  triggerSide: CycleConfig['trigger_price_side']
  maxSlip: string
  maxSpread: string
  maxCycles: string
  dailyLoss: string
  hours: string
}

const DEFAULT_FORM: FormState = {
  direction: 'BUY',
  trigger: '',
  lot: '0.01',
  tpSlInput: 'points',
  tp: '3',
  sl: '3',
  tpPrice: '',
  slPrice: '',
  gap: '',
  stop: '',
  gapEntryMode: 'wait_for_touch',
  slMode: 'points',
  levelAnchor: 'planned',
  triggerSide: 'bid',
  maxSlip: '0.5',
  maxSpread: '0.6',
  maxCycles: '',
  dailyLoss: '',
  hours: '',
}

const STORE_KEY = 'goldcycle.form.v1'

const num = (s: string): number | null => {
  const t = s.trim()
  if (t === '') return null
  const n = Number(t)
  return Number.isFinite(n) ? n : NaN
}

function toConfig(mode: Mode, f: FormState): Record<string, unknown> {
  const priceInput = mode === 'SINGLE' && f.tpSlInput === 'price'
  return {
    mode,
    direction: f.direction,
    trigger_price: num(f.trigger),
    lot: num(f.lot),
    tp_sl_input: priceInput ? 'price' : 'points',
    tp_points: priceInput ? null : num(f.tp),
    sl_points: priceInput ? null : num(f.sl),
    tp_price: priceInput ? num(f.tpPrice) : null,
    sl_price: priceInput ? num(f.slPrice) : null,
    cycle_gap: mode === 'CYCLE' ? num(f.gap) : null,
    stop_price: mode === 'CYCLE' ? num(f.stop) : null,
    gap_entry_mode: f.gapEntryMode,
    sl_mode: f.slMode,
    level_anchor: f.levelAnchor,
    trigger_price_side: f.triggerSide,
    max_slippage_points: num(f.maxSlip) ?? 0.5,
    max_spread_points: num(f.maxSpread),
    max_cycles: mode === 'CYCLE' ? num(f.maxCycles) : null,
    daily_loss_limit: num(f.dailyLoss),
    trading_hours: f.hours.trim() || null,
  }
}

const s = (n: number | null | undefined) => (n === null || n === undefined ? '' : String(n))

function fromConfig(c: CycleConfig): FormState {
  return {
    direction: c.direction,
    trigger: s(c.trigger_price),
    lot: s(c.lot),
    tpSlInput: c.tp_sl_input,
    tp: s(c.tp_points),
    sl: s(c.sl_points),
    tpPrice: s(c.tp_price),
    slPrice: s(c.sl_price),
    gap: s(c.cycle_gap),
    stop: s(c.stop_price),
    gapEntryMode: c.gap_entry_mode,
    slMode: c.sl_mode,
    levelAnchor: c.level_anchor,
    triggerSide: c.trigger_price_side,
    maxSlip: s(c.max_slippage_points),
    maxSpread: s(c.max_spread_points),
    maxCycles: c.mode === 'CYCLE' ? s(c.max_cycles) : '',
    dailyLoss: s(c.daily_loss_limit),
    hours: c.trading_hours ?? '',
  }
}

function loadSaved(): { mode: Mode; form: FormState } {
  try {
    const raw = localStorage.getItem(STORE_KEY)
    if (raw) {
      const j = JSON.parse(raw)
      return { mode: j.mode === 'SINGLE' ? 'SINGLE' : 'CYCLE', form: { ...DEFAULT_FORM, ...j.form } }
    }
  } catch {
    /* storage unavailable: start from defaults */
  }
  return { mode: 'CYCLE', form: DEFAULT_FORM }
}

interface Props {
  engine: EngineSnapshot | null
  tick: Tick | null
  floating: number | null
  currency: string
  onAction: (name: 'arm' | 'stop' | 'stopAfterCycle' | 'closeAll' | 'resume', cfg?: unknown) => Promise<void>
  onKill: () => void
}

export function ControlPanel({ engine, tick, floating, currency, onAction, onKill }: Props) {
  const saved = useMemo(loadSaved, [])
  const [mode, setMode] = useState<Mode>(saved.mode)
  const [f, setF] = useState<FormState>(saved.form)
  const [v, setV] = useState<Validation | null>(null)
  const [busy, setBusy] = useState(false)
  const [advanced, setAdvanced] = useState(false)

  const running = !!engine && ACTIVE_STATES.includes(engine.state)
  const digits = engine?.spec?.digits ?? 2
  const set = <K extends keyof FormState>(k: K, val: FormState[K]) => setF((p) => ({ ...p, [k]: val }))

  // When a session is running (e.g. page reloaded), show its config in the form.
  useEffect(() => {
    if (running && engine?.config) {
      setMode(engine.config.mode)
      setF(fromConfig(engine.config))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [engine?.session_id, running])

  useEffect(() => {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify({ mode, form: f }))
    } catch {
      /* storage unavailable */
    }
  }, [mode, f])

  const cfg = useMemo(() => toConfig(mode, f), [mode, f])
  useEffect(() => {
    if (cfg.trigger_price === null) {
      setV({ errors: ['Enter the trigger price'], warnings: [], ladder: [] })
      return
    }
    const t = window.setTimeout(() => {
      api
        .validate(cfg)
        .then(setV)
        .catch((e: Error) => setV({ errors: [e.message], warnings: [], ladder: [] }))
    }, 250)
    return () => window.clearTimeout(t)
  }, [cfg])

  const act = async (name: Parameters<Props['onAction']>[0], payload?: unknown) => {
    setBusy(true)
    try {
      await onAction(name, payload)
    } finally {
      setBusy(false)
    }
  }

  const canArm = !running && !!v && v.errors.length === 0 && !!engine?.connected && !engine?.daily_loss_block
  const first = v?.ladder[0]
  const priceMode = mode === 'SINGLE' && f.tpSlInput === 'price'
  const trig = num(f.trigger)

  return (
    <div className="flex h-full flex-col">
      {/* tabs */}
      <div className="flex border-b border-line">
        {(['CYCLE', 'SINGLE'] as Mode[]).map((m) => (
          <button
            key={m}
            disabled={running}
            onClick={() => setMode(m)}
            className={`relative flex-1 py-2.5 text-sm font-medium transition-colors disabled:cursor-not-allowed ${
              mode === m ? 'text-text' : 'text-muted hover:text-text'
            }`}
          >
            {m === 'CYCLE' ? 'Cycle' : 'Single'}
            {mode === m && <motion.span layoutId="tab" className="absolute inset-x-6 bottom-0 h-0.5 rounded bg-gold" />}
          </button>
        ))}
      </div>

      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
        <RunningCard engine={engine} floating={floating} currency={currency} digits={digits} mode={mode} />

        <fieldset disabled={running} className="space-y-3">
          {/* direction */}
          <div className="grid grid-cols-2 gap-2">
            {(['BUY', 'SELL'] as Direction[]).map((d) => (
              <button
                key={d}
                type="button"
                onClick={() => set('direction', d)}
                className={`btn border ${
                  f.direction === d
                    ? d === 'BUY'
                      ? 'border-up/60 bg-up/15 text-up'
                      : 'border-down/60 bg-down/15 text-down'
                    : 'border-line text-muted hover:bg-panel-2'
                }`}
              >
                {d}
              </button>
            ))}
          </div>

          <div>
            <label className="label">Market position (trigger price)</label>
            <div className="flex gap-2">
              <input className="field" inputMode="decimal" value={f.trigger} onChange={(e) => set('trigger', e.target.value)} placeholder="e.g. 4000" />
              <button
                type="button"
                className="btn shrink-0 border border-line px-2 text-xs text-muted hover:bg-panel-2 hover:text-text"
                onClick={() => tick && set('trigger', tick.bid.toFixed(digits))}
                title="Use current bid"
              >
                Bid
              </button>
            </div>
            {tick && trig !== null && !Number.isNaN(trig) && (
              <p className="mt-1 text-xs text-faint">
                {Math.abs(trig - tick.bid).toFixed(2)} pts {trig > tick.bid ? 'above' : trig < tick.bid ? 'below' : 'at'} bid
              </p>
            )}
          </div>

          <div>
            <label className="label">Lot</label>
            <input className="field" inputMode="decimal" value={f.lot} onChange={(e) => set('lot', e.target.value)} />
            {engine?.spec && (
              <p className="mt-1 text-xs text-faint">
                min {engine.spec.volume_min} · step {engine.spec.volume_step} · max {engine.spec.volume_max}
              </p>
            )}
          </div>

          {mode === 'SINGLE' && (
            <div className="flex gap-1 rounded-md bg-bg p-0.5 text-xs">
              {(['points', 'price'] as const).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => set('tpSlInput', k)}
                  className={`flex-1 rounded py-1 ${f.tpSlInput === k ? 'bg-panel-2 text-text' : 'text-muted'}`}
                >
                  TP/SL in {k}
                </button>
              ))}
            </div>
          )}

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="label text-up/80">{priceMode ? 'TP price' : 'TP points'}</label>
              <input
                className="field"
                inputMode="decimal"
                value={priceMode ? f.tpPrice : f.tp}
                onChange={(e) => set(priceMode ? 'tpPrice' : 'tp', e.target.value)}
              />
              <p className="num mt-1 text-xs text-faint">
                {first ? (priceMode ? `= ${Math.abs(first.tp - first.entry).toFixed(2)} pts` : `@ ${fmt(first.tp, 2)}`) : ' '}
              </p>
            </div>
            <div>
              <label className="label text-down/80">{priceMode ? 'SL price' : 'SL points'}</label>
              <input
                className="field"
                inputMode="decimal"
                value={priceMode ? f.slPrice : f.sl}
                onChange={(e) => set(priceMode ? 'slPrice' : 'sl', e.target.value)}
              />
              <p className="num mt-1 text-xs text-faint">
                {first ? (priceMode ? `= ${Math.abs(first.entry - first.sl).toFixed(2)} pts` : `@ ${fmt(first.sl, 2)}`) : ' '}
              </p>
            </div>
          </div>

          {mode === 'CYCLE' && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="label">Cycle gap (pts)</label>
                <input className="field" inputMode="decimal" value={f.gap} onChange={(e) => set('gap', e.target.value)} placeholder="blank = from TP" />
              </div>
              <div>
                <label className="label text-warn/80">Stop cycle at price</label>
                <input className="field" inputMode="decimal" value={f.stop} onChange={(e) => set('stop', e.target.value)} placeholder="optional" />
              </div>
            </div>
          )}

          <button type="button" onClick={() => setAdvanced((a) => !a)} className="flex items-center gap-1 text-xs text-muted hover:text-text">
            <motion.span animate={{ rotate: advanced ? 90 : 0 }} className="inline-block">
              ›
            </motion.span>
            Advanced & safety
          </button>
          <AnimatePresence initial={false}>
            {advanced && (
              <motion.div
                initial={{ height: 0, opacity: 0 }}
                animate={{ height: 'auto', opacity: 1 }}
                exit={{ height: 0, opacity: 0 }}
                className="overflow-hidden"
              >
                <div className="grid grid-cols-2 gap-3 rounded-lg border border-line bg-bg/50 p-3">
                  {mode === 'CYCLE' && (
                    <>
                      <Select label="Gap entry (Q1)" value={f.gapEntryMode} onChange={(x) => set('gapEntryMode', x)}
                        options={[['wait_for_touch', 'Wait for touch'], ['immediate', 'Immediate']]} />
                      <Select label="Next SL (Q2)" value={f.slMode} onChange={(x) => set('slMode', x)}
                        options={[['points', 'Entry − SL pts'], ['previous_entry', 'Previous entry']]} />
                    </>
                  )}
                  <Select label="Levels from" value={f.levelAnchor} onChange={(x) => set('levelAnchor', x)}
                    options={[['planned', 'Planned entry'], ['fill', 'Fill price']]} />
                  <Select label="Trigger on" value={f.triggerSide} onChange={(x) => set('triggerSide', x)}
                    options={[['bid', 'Bid'], ['ask', 'Ask'], ['mid', 'Mid']]} />
                  <Field label="Max slippage (pts)" value={f.maxSlip} onChange={(x) => set('maxSlip', x)} />
                  <Field label="Max spread (pts)" value={f.maxSpread} onChange={(x) => set('maxSpread', x)} placeholder="none" />
                  {mode === 'CYCLE' && <Field label="Max cycles" value={f.maxCycles} onChange={(x) => set('maxCycles', x)} placeholder="unlimited" />}
                  <Field label={`Daily loss limit (${currency || 'acc'})`} value={f.dailyLoss} onChange={(x) => set('dailyLoss', x)} placeholder="none" />
                  <Field label="Trading hours" value={f.hours} onChange={(x) => set('hours', x)} placeholder="08:00-17:00" />
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </fieldset>

        {/* validation */}
        {v && (v.errors.length > 0 || v.warnings.length > 0) && (
          <div className="space-y-1 text-xs">
            {v.errors.map((e) => (
              <p key={e} className="rounded bg-down/10 px-2 py-1 text-down">{e}</p>
            ))}
            {v.warnings.map((w) => (
              <p key={w} className="rounded bg-warn/10 px-2 py-1 text-warn">{w}</p>
            ))}
          </div>
        )}

        {/* preview ladder */}
        {v && v.ladder.length > 0 && (
          <div>
            <p className="label">Preview {mode === 'CYCLE' ? `· next ${v.ladder.length} cycles (if each hits TP)` : ''}</p>
            <table className="num w-full text-xs">
              <thead className="text-faint">
                <tr>
                  <th className="py-1 text-left font-normal">#</th>
                  <th className="text-right font-normal">Entry</th>
                  <th className="text-right font-normal">TP</th>
                  <th className="text-right font-normal">SL</th>
                </tr>
              </thead>
              <tbody>
                {v.ladder.map((c) => (
                  <tr key={c.cycle} className="border-t border-line/60">
                    <td className="py-1 text-muted">C{c.cycle}</td>
                    <td className="text-right">{c.entry.toFixed(2)}</td>
                    <td className="text-right text-up">{c.tp.toFixed(2)}</td>
                    <td className="text-right text-down">{c.sl.toFixed(2)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* actions */}
      <div className="space-y-2 border-t border-line p-4">
        {engine?.resumable && !running && (
          <button className="btn w-full bg-info/90 text-black hover:bg-info" disabled={busy} onClick={() => act('resume')}>
            Resume session {engine.session_id} (C{engine.cycle_no})
          </button>
        )}
        {!running ? (
          <button className="btn w-full bg-gold py-2.5 font-semibold text-black hover:bg-gold/90" disabled={!canArm || busy} onClick={() => act('arm', cfg)}>
            Arm {mode === 'CYCLE' ? 'cycle' : 'single trade'}
          </button>
        ) : (
          <div className="grid grid-cols-2 gap-2">
            <button
              className="btn border border-line hover:bg-panel-2"
              disabled={busy || engine?.stop_after_cycle}
              onClick={() => act('stopAfterCycle')}
              title="Let the current trade finish (TP/SL), then stop"
            >
              {engine?.stop_after_cycle ? 'Stopping after cycle…' : 'Stop after this cycle'}
            </button>
            <button
              className="btn border border-line hover:bg-panel-2"
              disabled={busy}
              onClick={() => act('stop')}
              title="Stop the bot now. An open trade stays open with its TP/SL on the broker server."
            >
              Stop now
            </button>
          </div>
        )}
        <button className="btn w-full border border-down/50 text-down hover:bg-down/15" disabled={busy} onClick={onKill} title="Ctrl+Shift+K">
          Close all & stop
        </button>
        {running && (
          <p className="text-center text-xs leading-snug text-faint">
            One session runs at a time. To start a different one, stop this session first — the form unlocks when the
            badge shows STOPPED or IDLE.
          </p>
        )}
      </div>
    </div>
  )
}

function HowItWorks({ mode }: { mode: Mode }) {
  const steps =
    mode === 'CYCLE'
      ? [
          ['Set the levels', 'Direction, trigger price, lot, TP/SL points, gap (blank = next cycle starts at the TP) and an optional stop price.'],
          ['Check the preview', 'The table below shows the next 5 cycles exactly as the bot will place them.'],
          ['Arm', 'The bot waits for price to touch the trigger, opens C1 with TP/SL, and chains C2, C3… after every TP.'],
          ['It ends by itself', 'On SL, stop price, or max cycles. Or press Stop. Then edit the form and Arm again for a new session.'],
        ]
      : [
          ['Set the trade', 'Direction, trigger price, lot and TP/SL (in points, or switch to exact prices).'],
          ['Arm', 'The bot waits for price to touch the trigger, opens one trade with TP/SL attached on the broker.'],
          ['Done', 'When TP or SL hits, the bot goes back to IDLE. Edit and Arm again for the next trade.'],
        ]
  return (
    <div className="rounded-lg border border-dashed border-line p-3">
      <p className="mb-2 text-xs font-medium tracking-wide text-muted uppercase">How a {mode === 'CYCLE' ? 'cycle session' : 'single trade'} works</p>
      <ol className="space-y-1.5 text-xs">
        {steps.map(([t, d], i) => (
          <li key={t} className="flex gap-2">
            <span className="num flex h-4 w-4 shrink-0 items-center justify-center rounded-full bg-gold/15 text-[11px] text-gold">{i + 1}</span>
            <span>
              <span className="text-text">{t}.</span> <span className="text-muted">{d}</span>
            </span>
          </li>
        ))}
      </ol>
    </div>
  )
}

function RunningCard({ engine, floating, currency, digits, mode }: { engine: EngineSnapshot | null; floating: number | null; currency: string; digits: number; mode: Mode }) {
  if (!engine || !engine.config || !engine.session_id) return <HowItWorks mode={mode} />
  const p = engine.position
  const ended = !ACTIVE_STATES.includes(engine.state)
  if (ended) {
    return (
      <motion.div initial={{ opacity: 0, y: -6 }} animate={{ opacity: 1, y: 0 }} className="space-y-2 rounded-lg border border-line bg-panel-2/60 p-3 text-sm">
        <div className="flex items-center justify-between">
          <span className="text-muted">
            Last session <span className="num text-text">{engine.session_id}</span> · {engine.config.mode} {engine.config.direction}
          </span>
          <span className={`num text-xs ${pnlColor(engine.session_pnl)}`}>{fmtMoney(engine.session_pnl, currency)}</span>
        </div>
        <p className="text-xs text-muted">
          Ended after C{engine.cycle_no}
          {engine.stop_reason ? ` — ${engine.stop_reason.replaceAll('_', ' ').toLowerCase()}` : ''}.
          {engine.resumable && <span className="text-info"> It was interrupted by a restart: you can Resume it below.</span>}
        </p>
        <p className="rounded bg-gold/10 px-2 py-1.5 text-xs text-gold">
          Start a new session: change the inputs below (or keep them) and press <b>Arm</b>. Full history is in <b>Reports</b>.
        </p>
      </motion.div>
    )
  }
  return (
    <motion.div
      initial={{ opacity: 0, y: -6 }}
      animate={{ opacity: 1, y: 0 }}
      className="space-y-2 rounded-lg border border-line bg-panel-2/60 p-3 text-sm"
    >
      <div className="flex items-center justify-between">
        <span className="text-muted">
          {engine.config.mode} {engine.config.direction} · <span className="text-text">C{engine.cycle_no}</span>
        </span>
        <span className="text-xs text-muted">
          Session P/L{' '}
          <span className={pnlColor(engine.session_pnl)}>
            <NumberTicker value={engine.session_pnl} format={(n) => fmtMoney(n, currency)} />
          </span>
        </span>
      </div>
      {engine.waiting && <p className="text-xs text-info">{engine.waiting}</p>}
      {engine.pending_close && <p className="text-xs text-warn">Closing position ({engine.pending_close})…</p>}
      {p && (
        <div className="num grid grid-cols-3 gap-2 text-xs">
          <Kv k="Fill" v={fmt(p.fill_price, digits)} />
          <Kv k="TP / SL" v={`${fmt(p.tp, 2)} / ${fmt(p.sl, 2)}`} />
          <Kv k="Floating" v={<span className={pnlColor(floating)}>{fmtMoney(floating, '')}</span>} />
        </div>
      )}
    </motion.div>
  )
}

function Kv({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div>
      <div className="text-[11px] text-faint uppercase">{k}</div>
      <div>{v}</div>
    </div>
  )
}

function Field({ label, value, onChange, placeholder }: { label: string; value: string; onChange: (v: string) => void; placeholder?: string }) {
  return (
    <div>
      <label className="label">{label}</label>
      <input className="field" value={value} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} />
    </div>
  )
}

function Select<T extends string>({ label, value, onChange, options }: { label: string; value: T; onChange: (v: T) => void; options: [T, string][] }) {
  return (
    <div>
      <label className="label">{label}</label>
      <select className="field" value={value} onChange={(e) => onChange(e.target.value as T)}>
        {options.map(([v, l]) => (
          <option key={v} value={v}>
            {l}
          </option>
        ))}
      </select>
    </div>
  )
}
