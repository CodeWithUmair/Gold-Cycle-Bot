import { AnimatePresence, motion } from 'framer-motion'
import { useEffect, useMemo, useState } from 'react'
import { api } from '../api'
import { ACTIVE_STATES, type CycleConfig, type Direction, type EngineSnapshot, type Mode, type Tick, type Validation } from '../types'
import { Modal, NumberTicker, fmt, fmtMoney, orderLabel, pnlColor } from './ui'

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
  levelAnchor: 'planned',
  triggerSide: 'bid',
  maxSlip: '0.5',
  maxSpread: '0.6',
  maxCycles: '',
  dailyLoss: '',
  hours: '',
}

const STORE_KEY = 'goldcycle.form.v3.' // + mode. v3: Cycle and Single have separate forms (both can run at once)
const OLD_STORE_KEY = 'goldcycle.form.v2' // the shared form before v3: seeds both

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
    sl_points: priceInput || mode === 'CYCLE' ? null : num(f.sl), // CYCLE: order 1 no SL, order 2 SL at entry
    tp_price: priceInput ? num(f.tpPrice) : null,
    sl_price: priceInput ? num(f.slPrice) : null,
    cycle_gap: mode === 'CYCLE' ? num(f.gap) : null,
    stop_price: mode === 'CYCLE' ? num(f.stop) : null,
    level_anchor: f.levelAnchor,
    trigger_price_side: f.triggerSide,
    max_slippage_points: num(f.maxSlip) ?? 0.5,
    max_spread_points: num(f.maxSpread),
    max_cycles: mode === 'CYCLE' ? num(f.maxCycles) : null,
    daily_loss_limit: num(f.dailyLoss),
    trading_hours: f.hours.trim() || null,
  }
}

const LABELS: Record<string, string> = {
  trigger_price: 'Trigger price', lot: 'Lot', tp_points: 'TP points', sl_points: 'SL points', tp_price: 'TP price',
  sl_price: 'SL price', cycle_gap: 'Cycle gap', stop_price: 'Stop price', max_slippage_points: 'Max slippage',
  max_spread_points: 'Max spread', max_cycles: 'Max cycles', daily_loss_limit: 'Daily loss limit',
}

/** Typo guard: num() gives NaN for text like "abc" or "1..5", and JSON turns NaN into null, which the server reads
 *  as "blank". For an optional TP/SL that would silently mean "no TP/SL", so block it here instead. */
const notNumbers = (cfg: Record<string, unknown>) =>
  Object.entries(cfg)
    .filter(([, x]) => typeof x === 'number' && Number.isNaN(x))
    .map(([k]) => `${LABELS[k] ?? k} is not a number`)

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
    levelAnchor: c.level_anchor,
    triggerSide: c.trigger_price_side,
    maxSlip: s(c.max_slippage_points),
    maxSpread: s(c.max_spread_points),
    maxCycles: c.mode === 'CYCLE' ? s(c.max_cycles) : '',
    dailyLoss: s(c.daily_loss_limit),
    hours: c.trading_hours ?? '',
  }
}

function loadSaved(mode: Mode): FormState {
  try {
    const raw = localStorage.getItem(STORE_KEY + mode)
    if (raw) return { ...DEFAULT_FORM, ...JSON.parse(raw) }
    const old = localStorage.getItem(OLD_STORE_KEY)
    if (old) return { ...DEFAULT_FORM, ...JSON.parse(old).form }
  } catch {
    /* storage unavailable: start from defaults */
  }
  return DEFAULT_FORM
}

interface Props {
  mode: Mode // this panel drives one engine; Cycle and Single each have their own
  engine: EngineSnapshot | null
  tick: Tick | null
  floating: number | null
  currency: string
  onAction: (name: 'arm' | 'stop' | 'stopAfterCycle' | 'resume', cfg?: unknown) => Promise<void>
  onKill: () => void
  picking?: 'tp' | 'sl' | null // this panel is waiting for a chart click
  onPick?: (field: 'tp' | 'sl', apply: (price: number) => void) => void
  onDraft?: (d: Draft | null) => void
  onModify?: (tp: number | null, sl: number | null) => Promise<boolean> // open Single trade: change TP/SL
}

/** Open Single trade: type exact TP/SL prices and Set (blank = none). The chart drag does the same. */
function EditLevels({ tp, sl, digits, onModify }: { tp: number | null; sl: number | null; digits: number; onModify: NonNullable<Props['onModify']> }) {
  const str = (n: number | null) => (n === null ? '' : n.toFixed(digits))
  const [t, setT] = useState(str(tp))
  const [s, setS] = useState(str(sl))
  const [busy, setBusy] = useState(false)
  useEffect(() => setT(str(tp)), [tp]) // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => setS(str(sl)), [sl]) // eslint-disable-line react-hooks/exhaustive-deps
  const nt = num(t)
  const ns = num(s)
  const bad = Number.isNaN(nt) || Number.isNaN(ns) || (nt !== null && nt <= 0) || (ns !== null && ns <= 0)
  const same = nt === tp && ns === sl
  return (
    <form
      className="grid grid-cols-[1fr_1fr_auto] items-end gap-2"
      onSubmit={async (e) => {
        e.preventDefault()
        setBusy(true)
        await onModify(nt, ns)
        setBusy(false)
      }}
    >
      <div>
        <label className="label text-up/80">TP price</label>
        <input className="field py-1.5" inputMode="decimal" value={t} placeholder="none" onChange={(e) => setT(e.target.value)} />
      </div>
      <div>
        <label className="label text-down/80">SL price</label>
        <input className="field py-1.5" inputMode="decimal" value={s} placeholder="none" onChange={(e) => setS(e.target.value)} />
      </div>
      <button type="submit" className="btn bg-gold/90 py-1.5 text-black hover:bg-gold" disabled={busy || bad || same} title={bad ? 'Enter a price or leave blank for none' : 'Send the new TP/SL to the broker'}>
        Set
      </button>
    </form>
  )
}

export interface Draft {
  entry: number | null
  tp: number | null
  sl: number | null
}

function PickBtn({ on, what, onClick }: { on: boolean; what: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      title={`Pick the ${what} price on the chart`}
      aria-label={`Pick the ${what} price on the chart`}
      aria-pressed={on}
      className={`mb-1 flex items-center gap-1 rounded px-1 text-[11px] ${on ? 'bg-gold/20 text-gold' : 'text-faint hover:text-text'}`}
    >
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
        <circle cx="12" cy="12" r="8" />
        <path d="M12 2v4M12 18v4M2 12h4M18 12h4" strokeLinecap="round" />
      </svg>
      {on ? 'click chart…' : 'chart'}
    </button>
  )
}

export function ControlPanel({ mode, engine, tick, floating, currency, onAction, onKill, picking, onPick, onDraft, onModify }: Props) {
  const [f, setF] = useState<FormState>(() => loadSaved(mode))
  const [v, setV] = useState<Validation | null>(null)
  const [busy, setBusy] = useState(false)
  const [advanced, setAdvanced] = useState(false)

  const running = !!engine && ACTIVE_STATES.includes(engine.state)
  const digits = engine?.spec?.digits ?? 2
  const set = <K extends keyof FormState>(k: K, val: FormState[K]) => setF((p) => ({ ...p, [k]: val }))

  // When a session is running (e.g. page reloaded), show its config in the form.
  useEffect(() => {
    if (running && engine?.config) {
      const c = engine.config
      // Buy/Sell now planned from the live price: keep the trader's own trigger (and direction toggle) in the form
      setF((p) => (c.enter_now ? { ...fromConfig(c), trigger: p.trigger, direction: p.direction } : fromConfig(c)))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [engine?.session_id, running])

  useEffect(() => {
    try {
      localStorage.setItem(STORE_KEY + mode, JSON.stringify(f))
    } catch {
      /* storage unavailable */
    }
  }, [mode, f])

  const cfg = useMemo(() => toConfig(mode, f), [mode, f])
  useEffect(() => {
    const bad = notNumbers(cfg)
    if (bad.length) {
      setV({ errors: bad, warnings: [], ladder: [] })
      return
    }
    if (cfg.trigger_price === null) {
      setV({ errors: [mode === 'SINGLE' ? 'Enter the trigger price to arm (or enter now at market)' : 'Enter the trigger price'], warnings: [], ladder: [] })
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

  // Single: a trade still open (even one left by an old "Stop now") blocks a new one until it's closed
  const holding = mode === 'SINGLE' && !!engine?.position
  const canArm = !running && !holding && !!v && v.errors.length === 0 && !!engine?.connected && !engine?.daily_loss_block
  const first = v?.ladder[0]
  const priceMode = mode === 'SINGLE' && f.tpSlInput === 'price'
  const trig = num(f.trigger)
  const [help, setHelp] = useState(false)
  // Enter now ignores the trigger price, so it doesn't need the (trigger-based) validation to pass: only real
  // numbers; the server re-checks everything against the live price.
  const nowCfg = { ...cfg, tp_sl_input: 'points', tp_points: null, sl_points: null, tp_price: null, sl_price: null, enter_now: true }
  const canEnterNow =
    mode === 'SINGLE' && !running && !holding && !!tick && !!engine?.connected && !engine?.daily_loss_block && notNumbers(nowCfg).length === 0 && cfg.lot !== null

  /** Pick TP/SL on the chart: switches to exact prices (converting the other field from points if needed). The
   *  picked level also sets the direction: a TP above the price (or an SL below it) means BUY, otherwise SELL. */
  const pickOnChart = (field: 'tp' | 'sl') =>
    onPick?.(field, (price) =>
      setF((p) => {
        const t = num(p.trigger)
        const ref = t !== null && !Number.isNaN(t) ? t : (tick?.bid ?? price)
        const direction: Direction = (field === 'tp') === price > ref ? 'BUY' : 'SELL'
        const sign = direction === 'BUY' ? 1 : -1
        const toPrice = (pts: string, side: number) => {
          const n = num(pts)
          return n === null || Number.isNaN(n) ? '' : (ref + side * n).toFixed(digits)
        }
        const base =
          p.tpSlInput === 'price' ? p : { ...p, tpSlInput: 'price' as const, tpPrice: toPrice(p.tp, sign), slPrice: toPrice(p.sl, -sign) }
        return { ...base, direction, [field === 'tp' ? 'tpPrice' : 'slPrice']: price.toFixed(digits) }
      }),
    )

  // Draft levels for the chart while the bot is not running (faint lines; picking on the chart updates them).
  const ok = (n: number | null) => (n === null || Number.isNaN(n) ? null : n)
  const draft: Draft | null = running
    ? null
    : first
      ? { entry: first.entry, tp: first.tp, sl: first.sl }
      : priceMode
        ? { entry: ok(trig), tp: ok(num(f.tpPrice)), sl: ok(num(f.slPrice)) }
        : null
  const draftKey = JSON.stringify(draft)
  useEffect(() => {
    onDraft?.(draft)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draftKey])

  return (
    <div className="flex h-full flex-col">
      <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
        <div className="flex justify-end">
          <button
            type="button"
            onClick={() => setHelp(true)}
            className="flex items-center gap-1.5 rounded px-1.5 py-1 text-xs text-muted hover:bg-panel-2 hover:text-text"
            aria-label={`How ${mode === 'CYCLE' ? 'a cycle session' : 'a single trade'} works`}
          >
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
              <circle cx="12" cy="12" r="10" />
              <path d="M12 16v-4M12 8h.01" strokeLinecap="round" />
            </svg>
            How it works
          </button>
        </div>
        <Modal open={help} onClose={() => setHelp(false)}>
          <HowItWorks mode={mode} />
          <div className="mt-4 flex justify-end">
            <button autoFocus className="btn bg-panel-2 hover:bg-line" onClick={() => setHelp(false)}>
              Got it
            </button>
          </div>
        </Modal>
        <RunningCard engine={engine} floating={floating} currency={currency} digits={digits} mode={mode} onModify={onModify} />

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

          <div className={`grid gap-3 ${mode === 'SINGLE' ? 'grid-cols-2' : 'grid-cols-1'}`}>
            <div>
              <div className="flex items-center justify-between">
                <label className="label text-up/80">
                  {priceMode ? 'TP price' : 'TP points'}
                  {mode === 'CYCLE' ? ' (order 1)' : ' (optional)'}
                </label>
                {mode === 'SINGLE' && <PickBtn on={picking === 'tp'} what="TP" onClick={() => pickOnChart('tp')} />}
              </div>
              <input
                className="field"
                inputMode="decimal"
                value={priceMode ? f.tpPrice : f.tp}
                onChange={(e) => set(priceMode ? 'tpPrice' : 'tp', e.target.value)}
                placeholder={mode === 'SINGLE' ? 'none' : undefined}
              />
              <p className="num mt-1 text-xs text-faint">
                {!first ? ' ' : first.tp === null ? 'no TP' : priceMode ? `= ${Math.abs(first.tp - first.entry).toFixed(2)} pts` : `@ ${fmt(first.tp, 2)}`}
                {mode === 'CYCLE' && first && ` · order 2 opens there with SL ${fmt(first.entry, 2)}, no TP`}
              </p>
            </div>
            {mode === 'SINGLE' && (
            <div>
              <div className="flex items-center justify-between">
                <label className="label text-down/80">{priceMode ? 'SL price' : 'SL points'} (optional)</label>
                <PickBtn on={picking === 'sl'} what="SL" onClick={() => pickOnChart('sl')} />
              </div>
              <input
                className="field"
                inputMode="decimal"
                value={priceMode ? f.slPrice : f.sl}
                onChange={(e) => set(priceMode ? 'slPrice' : 'sl', e.target.value)}
                placeholder="none"
              />
              <p className="num mt-1 text-xs text-faint">
                {!first ? ' ' : first.sl === null ? 'no SL' : priceMode ? `= ${Math.abs(first.entry - first.sl).toFixed(2)} pts` : `@ ${fmt(first.sl, 2)}`}
              </p>
            </div>
            )}
          </div>

          {mode === 'CYCLE' && (
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="label">Cycle gap (pts)</label>
                <input className="field" inputMode="decimal" value={f.gap} onChange={(e) => set('gap', e.target.value)} placeholder="after order 2 SL: blank = same entry" />
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
            <p className="label">Preview {mode === 'CYCLE' ? '· order 1 hits TP, then order 2 hits SL, repeat' : ''}</p>
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
                  <tr key={`${c.cycle}.${c.leg}`} className="border-t border-line/60">
                    <td className="py-1 text-muted">{orderLabel({ cycle_no: c.cycle, leg: c.leg }, mode)}</td>
                    <td className="text-right">{c.entry.toFixed(2)}</td>
                    <td className="text-right text-up">{fmt(c.tp, 2)}</td>
                    <td className="text-right text-down">{fmt(c.sl, 2)}</td>
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
            Resume session {engine.session_id}
            {mode === 'CYCLE' && ` (C${engine.cycle_no}.${engine.leg})`}
          </button>
        )}
        {!running && !holding ? (
          <>
            <button className="btn w-full bg-gold py-2.5 font-semibold text-black hover:bg-gold/90" disabled={!canArm || busy} onClick={() => act('arm', cfg)}>
              Arm {mode === 'CYCLE' ? 'cycle' : 'at trigger price'}
            </button>
            {mode === 'SINGLE' && (
              <div className="space-y-1.5 pt-1">
                <p className="text-center text-[11px] text-faint">Now at market, no TP/SL · set them after on the chart</p>
                {/* one click, like MT5/Exness: Sell at bid, Buy at ask. No TP/SL (client, 2026-11-20): the trader sets
                    them on the open trade (chart drag or the boxes); the form's TP/SL are only for "Arm at trigger". */}
                <div className="grid grid-cols-2 gap-2">
                  {(['SELL', 'BUY'] as Direction[]).map((d) => {
                    return (
                      <button
                        key={d}
                        className={`btn flex-col gap-0 py-1.5 leading-tight font-semibold text-white ${
                          d === 'BUY' ? 'bg-up/80 hover:bg-up' : 'bg-down/80 hover:bg-down'
                        }`}
                        disabled={!canEnterNow || busy}
                        onClick={() => act('arm', { ...nowCfg, direction: d, trigger_price: tick!.bid })}
                        title={`Open a ${d} now at market, no TP/SL (the trigger price is not used)`}
                      >
                        <span className="text-xs">{d === 'BUY' ? 'Buy' : 'Sell'}</span>
                        <span className="num text-[15px]">{fmt(tick ? (d === 'BUY' ? tick.ask : tick.bid) : null, digits)}</span>
                      </button>
                    )
                  })}
                </div>
              </div>
            )}
          </>
        ) : (
          <div className={`grid gap-2 ${mode === 'CYCLE' ? 'grid-cols-2' : 'grid-cols-1'}`}>
            {mode === 'CYCLE' && (
              <button
                className="btn border border-line hover:bg-panel-2"
                disabled={busy || engine?.stop_after_cycle}
                onClick={() => act('stopAfterCycle')}
                title="Let the current trade finish (TP/SL), then stop"
              >
                {engine?.stop_after_cycle ? 'Stopping after cycle…' : 'Stop after this cycle'}
              </button>
            )}
            {mode === 'SINGLE' ? (
              // Single: Stop closes the trade at market (client, 2026-11-20); before the fill it cancels the order
              <button
                className={`btn border py-2 font-semibold ${holding ? 'border-gold/60 text-gold hover:bg-gold/15' : 'border-line hover:bg-panel-2'}`}
                disabled={busy || !!engine?.pending_close}
                onClick={() => act('stop')}
                title={holding ? 'Close this trade now at market' : 'Cancel: stop waiting for the trigger'}
              >
                {engine?.pending_close ? 'Closing…' : holding ? 'Close trade' : 'Cancel'}
              </button>
            ) : (
              <button
                className="btn border border-line hover:bg-panel-2"
                disabled={busy}
                onClick={() => act('stop')}
                title="Stop the bot now. An open trade stays open with its TP/SL on the broker server."
              >
                Stop now
              </button>
            )}
          </div>
        )}
        <button className="btn w-full border border-down/50 text-down hover:bg-down/15" disabled={busy} onClick={onKill} title="Ctrl+Shift+K">
          Close all & stop
        </button>
        {running && mode === 'CYCLE' && (
          <p className="text-center text-xs leading-snug text-faint">
            The {mode === 'CYCLE' ? 'Single' : 'Cycle'} tab is a separate bot and can run at the same time. To change this{' '}
            {mode === 'CYCLE' ? 'cycle' : 'single trade'}, stop it first — the form unlocks at STOPPED or IDLE.
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
          ['Set the levels', 'Direction, trigger price, lot, TP points, gap (used after order 2\'s SL) and an optional stop price.'],
          ['Arm', 'The bot waits for price to touch the trigger and opens order 1 with a TP and no SL.'],
          ['Order 2', 'When order 1 hits TP, order 2 opens at once at that TP with its SL at order 1\'s entry and no TP. It runs until the SL, the stop price or Stop.'],
          ['Next cycle', 'When order 2 hits its SL, the bot waits for price to return to the cycle entry (+ gap, if set) and starts again with order 1.'],
          ['It ends by itself', 'On stop price, max cycles or the daily loss limit. Or press Stop. Then edit the form and Arm again for a new session.'],
        ]
      : [
          ['Set the trade', 'Direction, trigger price, lot, and TP and/or SL (in points or exact prices). Both are optional.'],
          ['Arm', 'The bot waits for price to touch the trigger, opens one trade with TP/SL attached on the broker.'],
          ['Done', 'When TP or SL hits, the bot goes back to IDLE. With neither set, the trade stays open until you close it.'],
        ]
  return (
    <div>
      <h3 className="mb-3 text-base font-semibold">How a {mode === 'CYCLE' ? 'cycle session' : 'single trade'} works</h3>
      <ol className="space-y-2 text-sm">
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

function RunningCard({ engine, floating, currency, digits, mode, onModify }: { engine: EngineSnapshot | null; floating: number | null; currency: string; digits: number; mode: Mode; onModify?: Props['onModify'] }) {
  if (!engine || !engine.config || !engine.session_id) return null // "How it works" is behind the info button
  const p = engine.position
  // Single: a trade left open by "Stop now" still shows here (its TP/SL can be changed); otherwise no card
  const ended = !ACTIVE_STATES.includes(engine.state) && !(mode === 'SINGLE' && p)
  // Single: TP/SL are edited in place (boxes below); the compact "TP / SL" column only for Cycle
  const editable = !!p && !!onModify && mode === 'SINGLE' && !engine.pending_close
  if (ended) {
    if (mode === 'SINGLE') return null // client: no "Last session" card in Single (history is in the journal/Reports)
    return (
      <motion.div initial={{ opacity: 0, y: -6 }} animate={{ opacity: 1, y: 0 }} className="space-y-2 rounded-lg border border-line bg-panel-2/60 p-3 text-sm">
        <div className="flex items-center justify-between">
          <span className="text-muted">
            Last session <span className="num text-text">{engine.session_id}</span> · {engine.config.mode} {engine.config.direction}
          </span>
          <span className={`num text-xs ${pnlColor(engine.session_pnl)}`}>{fmtMoney(engine.session_pnl, currency)}</span>
        </div>
        <p className="text-xs text-muted">
          {mode === 'CYCLE' ? `Ended after C${engine.cycle_no}.${engine.leg}` : 'Trade ended'}
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
          {engine.config.mode} {engine.config.direction} · <span className="text-text">{orderLabel(engine, engine.config.mode)}</span>
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
        <div className={`num grid gap-2 text-xs ${editable ? 'grid-cols-2' : 'grid-cols-3'}`}>
          <Kv k="Fill" v={fmt(p.fill_price, digits)} />
          {!editable && <Kv k="TP / SL" v={`${fmt(engine.tp, 2)} / ${fmt(engine.sl, 2)}`} />}
          <Kv k="Floating" v={<span className={pnlColor(floating)}>{fmtMoney(floating, '')}</span>} />
        </div>
      )}
      {editable && onModify && (
        <>
          <EditLevels tp={engine.tp} sl={engine.sl} digits={digits} onModify={onModify} />
          <p className="text-[11px] text-faint">Clear a box and Set to remove it. Or drag the TP/SL lines on the chart (drag the entry line to add one).</p>
        </>
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
