import {
  CandlestickSeries,
  ColorType,
  CrosshairMode,
  LineStyle,
  createChart,
  createSeriesMarkers,
  type IChartApi,
  type IPriceLine,
  type ISeriesApi,
  type ISeriesMarkersPluginApi,
  type MouseEventParams,
  type SeriesMarker,
  type Time,
  type UTCTimestamp,
} from 'lightweight-charts'
import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import type { Draft } from './ControlPanel'
import { orderLabel } from './ui'
import type { CycleRow, EngineSnapshot, Tick } from '../types'

const TFS = ['M1', 'M5', 'M15', 'H1', 'H4'] as const
const TF_SECONDS: Record<string, number> = { M1: 60, M5: 300, M15: 900, H1: 3600, H4: 14400 }

const C = {
  up: '#26c281',
  down: '#ef5350',
  gold: '#e3b341',
  info: '#5aa9ff',
  warn: '#f5a524',
  muted: '#8791a5',
  grid: '#151a24',
}

interface Props {
  engine: EngineSnapshot | null
  cycles: CycleRow[]
  tickRef: React.MutableRefObject<((t: Tick) => void) | null>
  draft?: Draft | null // the form's levels before arming (faint lines)
  pick?: 'tp' | 'sl' | null // waiting for a click that sets this level
  onPick?: (price: number) => void
  onCancelPick?: () => void
  onModify?: (tp: number | null, sl: number | null) => Promise<boolean> // open trade (Single or Cycle): new TP/SL
}

export function PriceChart({ engine, cycles, tickRef, draft, pick, onPick, onCancelPick, onModify }: Props) {
  const box = useRef<HTMLDivElement>(null)
  const chart = useRef<IChartApi | null>(null)
  const series = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const markers = useRef<ISeriesMarkersPluginApi<Time> | null>(null)
  const lines = useRef<IPriceLine[]>([])
  const roles = useRef<Partial<Record<'TP' | 'SL' | 'entry', { line: IPriceLine; price: number }>>>({})
  const [redraw, setRedraw] = useState(0)
  const last = useRef<{ time: number; open: number; high: number; low: number; close: number } | null>(null)
  const [tf, setTf] = useState<string>('M1')
  const [error, setError] = useState<string | null>(null)
  const digits = engine?.spec?.digits ?? 2
  const pickRef = useRef({ pick, onPick })
  pickRef.current = { pick, onPick }

  useEffect(() => {
    if (!pick) return
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onCancelPick?.()
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [pick, onCancelPick])

  // create chart once
  useEffect(() => {
    if (!box.current) return
    const c = createChart(box.current, {
      autoSize: true,
      layout: {
        background: { type: ColorType.Solid, color: 'transparent' },
        textColor: C.muted,
        fontFamily: 'JetBrains Mono Variable, Consolas, monospace',
        fontSize: 12,
        attributionLogo: false,
      },
      grid: { vertLines: { color: C.grid }, horzLines: { color: C.grid } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1f2633' },
      timeScale: { borderColor: '#1f2633', timeVisible: true, secondsVisible: false, rightOffset: 8 },
    })
    const s = c.addSeries(CandlestickSeries, {
      upColor: C.up,
      downColor: C.down,
      borderVisible: false,
      wickUpColor: C.up,
      wickDownColor: C.down,
    })
    chart.current = c
    series.current = s
    markers.current = createSeriesMarkers(s, [])
    const onClick = (p: MouseEventParams<Time>) => {
      if (!pickRef.current.pick || !p.point) return
      const price = s.coordinateToPrice(p.point.y)
      if (price !== null && price > 0) pickRef.current.onPick?.(price)
    }
    c.subscribeClick(onClick)
    return () => {
      c.unsubscribeClick(onClick)
      c.remove()
      chart.current = null
      series.current = null
      markers.current = null
      lines.current = []
    }
  }, [])

  useEffect(() => {
    series.current?.applyOptions({ priceFormat: { type: 'price', precision: digits, minMove: 1 / 10 ** digits } })
  }, [digits])

  // (re)load candles on timeframe / symbol change
  useEffect(() => {
    let cancelled = false
    api
      .candles(tf)
      .then((rows) => {
        if (cancelled || !series.current) return
        series.current.setData(rows.map((r) => ({ ...r, time: r.time as UTCTimestamp })))
        last.current = rows.length ? { ...rows[rows.length - 1] } : null
        chart.current?.timeScale().scrollToRealTime()
        setError(null)
      })
      .catch((e: Error) => !cancelled && setError(e.message))
    return () => {
      cancelled = true
    }
  }, [tf, engine?.symbol])

  // live ticks update the last bar (bid, like the MT5 chart)
  useEffect(() => {
    tickRef.current = (t: Tick) => {
      const s = series.current
      if (!s) return
      const secs = TF_SECONDS[tf]
      const bar = Math.floor(t.time / secs) * secs
      const p = t.bid
      const l = last.current
      if (l && bar < l.time) return
      if (l && bar === l.time) {
        l.high = Math.max(l.high, p)
        l.low = Math.min(l.low, p)
        l.close = p
      } else {
        last.current = { time: bar, open: p, high: p, low: p, close: p }
      }
      s.update({ ...last.current!, time: last.current!.time as UTCTimestamp })
    }
    return () => {
      tickRef.current = null
    }
  }, [tf, tickRef])

  // level lines
  const levelKey = JSON.stringify([
    engine?.state,
    engine?.trigger_level,
    engine?.position?.fill_price,
    engine?.tp,
    engine?.sl,
    engine?.next_entry,
    engine?.stop_price,
    draft,
    redraw,
  ])
  useEffect(() => {
    const s = series.current
    if (!s) return
    lines.current.forEach((l) => s.removePriceLine(l))
    lines.current = []
    roles.current = {}
    const add = (price: number | null | undefined, color: string, title: string, style: LineStyle, width = 1) => {
      if (price === null || price === undefined) return
      const l = s.createPriceLine({ price, color, title, lineStyle: style, lineWidth: width as 1, axisLabelVisible: true })
      lines.current.push(l)
      if (title === 'TP' || title === 'SL' || title === 'entry') roles.current[title] = { line: l, price }
    }
    if (!engine || ((engine.state === 'IDLE' || engine.state === 'STOPPED') && !engine.position)) {
      // not running: show the form's levels faintly, so TP/SL picked on the chart are visible before arming
      add(draft?.entry, `${C.info}99`, 'trigger?', LineStyle.Dashed)
      add(draft?.tp, `${C.up}99`, 'TP?', LineStyle.Dashed)
      add(draft?.sl, `${C.down}99`, 'SL?', LineStyle.Dashed)
      return
    }
    add(engine.trigger_level, C.info, 'trigger', LineStyle.Dashed)
    add(engine.position?.fill_price ?? (engine.state !== 'ARMED' ? engine.planned_entry : null), C.gold, 'entry', LineStyle.Solid, 2)
    add(engine.tp, C.up, 'TP', LineStyle.Solid)
    add(engine.sl, C.down, 'SL', LineStyle.Solid)
    if (engine.next_entry !== engine.trigger_level) add(engine.next_entry, '#8791a580', 'next', LineStyle.Dotted)
    add(engine.stop_price, C.warn, 'stop', LineStyle.LargeDashed, 2)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [levelKey])

  // Drag TP/SL of the open trade, like MT5/Exness: drag the TP or SL line to move it, or drag the entry line
  // toward profit to add a TP / toward loss to add an SL. The server checks the new level and sends it to the broker.
  const canDrag = !!onModify && !!engine?.position && !engine.pending_close // Single and Cycle (2026-11-21)
  const dragCtx = useRef({ canDrag, engine, onModify })
  dragCtx.current = { canDrag, engine, onModify }
  useEffect(() => {
    const el = box.current
    if (!el) return
    let drag: { role: 'TP' | 'SL' | 'entry'; ghost: IPriceLine | null; price: number } | null = null
    const yOf = (e: PointerEvent) => e.clientY - el.getBoundingClientRect().top
    const near = (y: number) => {
      const s = series.current
      if (!s || !dragCtx.current.canDrag) return null
      for (const role of ['TP', 'SL', 'entry'] as const) {
        const r = roles.current[role]
        const at = r ? s.priceToCoordinate(r.price) : null
        if (at !== null && Math.abs(at - y) <= 6) return role
      }
      return null
    }
    // entry dragged to `price`: TP if that's the profit side, else SL
    const entryTarget = (price: number) => {
      const { engine: e } = dragCtx.current
      const buy = e?.config?.direction === 'BUY'
      return (price > (e?.position?.fill_price ?? price)) === buy ? 'TP' : 'SL'
    }
    const down = (e: PointerEvent) => {
      if (e.button !== 0) return
      const role = near(yOf(e))
      if (!role) return
      e.preventDefault() // also stops the chart's own mouse handling (no pan while dragging a line)
      e.stopPropagation()
      chart.current?.applyOptions({ handleScroll: false, handleScale: false })
      el.setPointerCapture(e.pointerId)
      drag = { role, ghost: null, price: roles.current[role]!.price }
    }
    const move = (e: PointerEvent) => {
      const s = series.current
      if (!s) return
      if (!drag) {
        el.style.cursor = near(yOf(e)) ? 'ns-resize' : ''
        return
      }
      const price = s.coordinateToPrice(yOf(e))
      if (price === null) return
      drag.price = price
      if (drag.role === 'entry') {
        const t = entryTarget(price)
        const color = t === 'TP' ? C.up : C.down
        if (!drag.ghost) drag.ghost = s.createPriceLine({ price, color, title: t, lineStyle: LineStyle.Dashed, lineWidth: 1, axisLabelVisible: true })
        else drag.ghost.applyOptions({ price, color, title: t })
      } else {
        roles.current[drag.role]!.line.applyOptions({ price })
      }
    }
    const up = async () => {
      if (!drag) return
      const d = drag
      drag = null
      chart.current?.applyOptions({ handleScroll: true, handleScale: true })
      if (d.ghost) series.current?.removePriceLine(d.ghost)
      const { engine: e, onModify: mod } = dragCtx.current
      if (!e || !mod) return
      const role = d.role === 'entry' ? entryTarget(d.price) : d.role
      const p = Math.round(d.price * 10 ** digits) / 10 ** digits
      await mod(role === 'TP' ? p : e.tp, role === 'SL' ? p : e.sl)
      setRedraw((n) => n + 1) // redraw from the trade's real levels (also puts a refused drag back)
    }
    el.addEventListener('pointerdown', down, true)
    el.addEventListener('pointermove', move)
    el.addEventListener('pointerup', up)
    el.addEventListener('pointercancel', up)
    return () => {
      el.removeEventListener('pointerdown', down, true)
      el.removeEventListener('pointermove', move)
      el.removeEventListener('pointerup', up)
      el.removeEventListener('pointercancel', up)
    }
  }, [digits])

  // cycle open/close markers
  useEffect(() => {
    if (!markers.current) return
    const secs = TF_SECONDS[tf]
    const snap = (t: number) => (Math.floor(t / secs) * secs) as UTCTimestamp
    const ms: SeriesMarker<Time>[] = []
    for (const c of cycles) {
      if (c.open_time) {
        const buy = c.direction === 'BUY'
        ms.push({
          time: snap(c.open_time),
          position: buy ? 'belowBar' : 'aboveBar',
          shape: buy ? 'arrowUp' : 'arrowDown',
          color: buy ? C.up : C.down,
          text: orderLabel(c, engine?.config?.mode),
        })
      }
      if (c.close_time && c.close_reason) {
        ms.push({
          time: snap(c.close_time),
          position: 'aboveBar',
          shape: 'circle',
          color: c.close_reason === 'TP' ? C.up : c.close_reason === 'SL' ? C.down : C.warn,
          text: `${c.close_reason}`,
        })
      }
    }
    ms.sort((a, b) => (a.time as number) - (b.time as number))
    markers.current.setMarkers(ms)
  }, [cycles, tf])

  return (
    <div className="relative flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-1 border-b border-line px-3 py-1.5">
        {TFS.map((t) => (
          <button
            key={t}
            onClick={() => setTf(t)}
            className={`rounded px-2 py-0.5 text-xs font-medium transition-colors ${
              tf === t ? 'bg-gold/15 text-gold' : 'text-muted hover:bg-panel-2 hover:text-text'
            }`}
          >
            {t}
          </button>
        ))}
        {canDrag && (
          <span className="ml-3 rounded bg-gold/10 px-2 py-0.5 text-[11px] text-gold">
            Drag the TP/SL lines · drag the entry line to add TP or SL
          </span>
        )}
        <Legend />
      </div>
      <div ref={box} className={`min-h-0 flex-1 ${pick ? 'cursor-crosshair' : ''}`} />
      {pick && (
        <div className="absolute inset-x-0 top-12 mx-auto flex w-fit items-center gap-3 rounded bg-gold/15 px-3 py-1.5 text-xs text-gold">
          Click the chart to set the {pick === 'tp' ? 'TP' : 'SL'} price
          <button className="rounded px-1.5 text-muted hover:text-text" onClick={onCancelPick}>
            Cancel (Esc)
          </button>
        </div>
      )}
      {error && (
        <div className="absolute inset-x-0 top-12 mx-auto w-fit rounded bg-down/15 px-3 py-1.5 text-xs text-down">
          {error}
        </div>
      )}
    </div>
  )
}

function Legend() {
  const items: [string, string, string][] = [
    ['trigger', C.info, 'dashed'],
    ['entry', C.gold, 'solid'],
    ['TP', C.up, 'solid'],
    ['SL', C.down, 'solid'],
    ['next', C.muted, 'dotted'],
    ['stop', C.warn, 'dashed'],
  ]
  return (
    <div className="ml-auto hidden items-center gap-3 text-xs text-muted md:flex">
      {items.map(([l, c, s]) => (
        <span key={l} className="inline-flex items-center gap-1.5">
          <span className="w-4 border-t-2" style={{ borderColor: c, borderTopStyle: s as 'solid' }} />
          {l}
        </span>
      ))}
    </div>
  )
}
