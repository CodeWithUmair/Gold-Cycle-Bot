import { motion } from 'framer-motion'
import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError, api } from '../api'
import { ControlPanel, type Draft } from '../components/ControlPanel'
import { Journal } from '../components/Journal'
import { LogDrawer } from '../components/LogDrawer'
import { PriceChart } from '../components/PriceChart'
import { SettingsModal } from '../components/SettingsModal'
import { TopBar } from '../components/TopBar'
import { ConfirmModal, Toasts, type Toast } from '../components/ui'
import { useSocket } from '../hooks/useSocket'
import { Reports } from './Reports'
import { ACTIVE_STATES, MODES, type CycleRow, type EngineSnapshot, type LogEntry, type Mode, type PerMode, type Tick } from '../types'

let toastId = 0
const TAB_KEY = 'goldcycle.tab'

function savedTab(): Mode {
  try {
    return localStorage.getItem(TAB_KEY) === 'SINGLE' ? 'SINGLE' : 'CYCLE'
  } catch {
    return 'CYCLE' // storage unavailable
  }
}

export function Dashboard({ onLoggedOut }: { onLoggedOut: () => void }) {
  const [engines, setEngines] = useState<PerMode<EngineSnapshot | null>>({ CYCLE: null, SINGLE: null })
  const [tab, setTab] = useState<Mode>(savedTab)
  const [broker, setBroker] = useState('')
  const [dryRun, setDryRun] = useState(false)
  const [cycles, setCycles] = useState<CycleRow[]>([])
  const [logs, setLogs] = useState<LogEntry[]>([])
  const [toasts, setToasts] = useState<Toast[]>([])
  const [logOpen, setLogOpen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [killOpen, setKillOpen] = useState<Mode | 'ALL' | null>(null)
  const [view, setView] = useState<'trading' | 'reports'>('trading')
  // Pick TP/SL on the chart: which panel asked, and how to apply the clicked price to its form.
  const [pick, setPick] = useState<{ mode: Mode; field: 'tp' | 'sl'; apply: (price: number) => void } | null>(null)
  const [drafts, setDrafts] = useState<PerMode<Draft | null>>({ CYCLE: null, SINGLE: null })
  const tickRef = useRef<((t: Tick) => void) | null>(null)

  const toast = useCallback((l: LogEntry) => {
    const id = ++toastId
    setToasts((ts) => [...ts.slice(-4), { ...l, id }])
    window.setTimeout(() => setToasts((ts) => ts.filter((t) => t.id !== id)), l.level === 'error' ? 10000 : 5000)
  }, [])

  const ws = useSocket(true, {
    onTick: (t) => tickRef.current?.(t),
    onLog: (l) => setLogs((ls) => [l, ...ls].slice(0, 500)),
    onToast: toast,
    onCycle: (c) =>
      setCycles((rows) => {
        const i = rows.findIndex((r) => r.id === c.id)
        if (i >= 0) return rows.map((r) => (r.id === c.id ? c : r))
        return [c, ...rows]
      }),
  })

  useEffect(() => {
    setEngines((e) => ({ CYCLE: ws.engines.CYCLE ?? e.CYCLE, SINGLE: ws.engines.SINGLE ?? e.SINGLE }))
  }, [ws.engines])

  useEffect(() => {
    try {
      localStorage.setItem(TAB_KEY, tab)
    } catch {
      /* storage unavailable */
    }
  }, [tab])

  // chart, journal and top-bar symbol follow the selected tab's engine
  const engine = engines[tab]

  // initial load
  useEffect(() => {
    api
      .status()
      .then((s) => {
        setEngines((e) => ({ CYCLE: e.CYCLE ?? s.engines.CYCLE, SINGLE: e.SINGLE ?? s.engines.SINGLE }))
        setBroker(s.broker)
        setDryRun(s.dry_run)
      })
      .catch((e: Error) => toast({ ts: Date.now() / 1000, level: 'error', msg: e.message }))
    api
      .events(300)
      .then((ev) => setLogs(ev.map((x) => ({ ts: x.ts, level: x.level as LogEntry['level'], msg: x.message }))))
      .catch(() => undefined)
  }, [toast])

  // journal follows the current session
  const sessionId = engine?.session_id ?? null
  useEffect(() => {
    api
      .cycles(sessionId)
      .then(setCycles)
      .catch(() => undefined)
  }, [sessionId])

  // kill switch hotkey
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.ctrlKey && e.shiftKey && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        setKillOpen('ALL')
      }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [])

  const onAction = async (mode: Mode, name: 'arm' | 'stop' | 'stopAfterCycle' | 'resume', cfg?: unknown) => {
    try {
      const snap = name === 'arm' ? await api.arm(cfg) : await api[name](mode)
      setEngines((e) => ({ ...e, [snap.mode]: snap }))
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) return onLoggedOut()
      toast({ ts: Date.now() / 1000, level: 'error', msg: (e as Error).message })
    }
  }

  /** Open Single trade: new TP/SL from a chart drag or the × in the panel. Returns false if refused. */
  const modify = async (mode: Mode, tp: number | null, sl: number | null) => {
    try {
      const snap = await api.modify(mode, tp, sl)
      setEngines((e) => ({ ...e, [snap.mode]: snap }))
      return true
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) onLoggedOut()
      else toast({ ts: Date.now() / 1000, level: 'error', msg: (e as Error).message })
      return false
    }
  }

  const closeAll = async (target: Mode | 'ALL') => {
    try {
      await api.closeAll(target === 'ALL' ? undefined : target) // state arrives over the websocket
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) return onLoggedOut()
      toast({ ts: Date.now() / 1000, level: 'error', msg: (e as Error).message })
    }
  }

  const logout = async () => {
    await api.logout().catch(() => undefined)
    onLoggedOut()
  }

  const currency = ws.account?.currency ?? ''
  const running = MODES.some((m) => !!engines[m] && ACTIVE_STATES.includes(engines[m]!.state))
  const killTargets = killOpen === 'ALL' ? MODES : killOpen ? [killOpen] : []

  return (
    <motion.div className="flex h-full flex-col" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.3 }}>
      <TopBar
        engine={engine}
        engines={engines}
        account={ws.account}
        tick={ws.tick}
        wsConnected={ws.wsConnected}
        broker={broker}
        dryRun={dryRun}
        onSettings={() => setSettingsOpen(true)}
        onLogout={logout}
        view={view}
        onView={setView}
      />

      {view === 'reports' && (
        <div className="min-h-0 flex-1">
          <Reports currency={currency} />
        </div>
      )}

      {/* kept mounted while on Reports so the chart doesn't reload */}
      <div className={`min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(0,1fr)_380px] ${view === 'trading' ? 'grid' : 'hidden'}`}>
        <div className="flex min-h-0 flex-col">
          <motion.section
            className="min-h-[320px] flex-1 border-b border-line"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.05 }}
          >
            <PriceChart
              engine={engine}
              cycles={cycles}
              tickRef={tickRef}
              draft={drafts[tab]}
              pick={pick && pick.mode === tab ? pick.field : null}
              onPick={(price) => {
                pick?.apply(price)
                setPick(null)
              }}
              onCancelPick={() => setPick(null)}
              onModify={tab === 'SINGLE' ? (tp, sl) => modify('SINGLE', tp, sl) : undefined}
            />
          </motion.section>
          <motion.section className="h-64 shrink-0" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}>
            <Journal rows={cycles} mode={engine?.config?.mode} sessionPnl={engine?.session_pnl ?? 0} currency={currency} onOpenLog={() => setLogOpen(true)} />
          </motion.section>
        </div>
        <motion.aside
          className="flex min-h-0 flex-col border-l border-line bg-panel"
          initial={{ opacity: 0, x: 12 }}
          animate={{ opacity: 1, x: 0 }}
          transition={{ delay: 0.08 }}
        >
          {/* Cycle and Single are separate bots: both can run at once. Both panels stay mounted to keep their forms. */}
          <div className="flex border-b border-line">
            {MODES.map((m) => {
              const on = !!engines[m] && ACTIVE_STATES.includes(engines[m]!.state)
              return (
                <button
                  key={m}
                  onClick={() => setTab(m)}
                  className={`relative flex flex-1 items-center justify-center gap-2 py-2.5 text-sm font-medium transition-colors ${
                    tab === m ? 'text-text' : 'text-muted hover:text-text'
                  }`}
                >
                  {m === 'CYCLE' ? 'Cycle' : 'Single'}
                  {on && <span className="h-1.5 w-1.5 rounded-full bg-up" title={engines[m]!.state} />}
                  {tab === m && <motion.span layoutId="tab" className="absolute inset-x-6 bottom-0 h-0.5 rounded bg-gold" />}
                </button>
              )
            })}
          </div>
          {MODES.map((m) => (
            <div key={m} className={tab === m ? 'min-h-0 flex-1' : 'hidden'}>
              <ControlPanel
                mode={m}
                engine={engines[m]}
                tick={ws.tick}
                floating={ws.floating[m]}
                currency={currency}
                onAction={(name, cfg) => onAction(m, name, cfg)}
                onKill={() => setKillOpen(m)}
                picking={pick?.mode === m ? pick.field : null}
                onPick={(field, apply) => setPick((p) => (p?.mode === m && p.field === field ? null : { mode: m, field, apply }))}
                onDraft={(d) => setDrafts((ds) => ({ ...ds, [m]: d }))}
                onModify={m === 'SINGLE' ? (tp, sl) => modify(m, tp, sl) : undefined}
              />
            </div>
          ))}
        </motion.aside>
      </div>

      <LogDrawer open={logOpen} logs={logs} onClose={() => setLogOpen(false)} />
      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} running={running} />
      <ConfirmModal
        open={killOpen !== null}
        title={killOpen === 'ALL' ? 'Close all & stop both bots?' : `Close all & stop the ${killOpen === 'SINGLE' ? 'single' : 'cycle'} bot?`}
        danger
        confirmLabel="Close all & stop"
        body={
          <>
            Closes <b>every</b> open position of {killOpen === 'ALL' ? 'the cycle bot and the single bot' : 'this bot'} at
            market and stops it.
            {killTargets.map((m) => {
              const e = engines[m]
              return e?.position ? (
                <span key={m} className="mt-2 block">
                  {m === 'CYCLE' ? `Cycle open: C${e.cycle_no}.${e.leg}` : 'Single trade open:'} #{e.position.ticket} ({e.position.volume} lots)
                </span>
              ) : null
            })}
          </>
        }
        onConfirm={() => killOpen && closeAll(killOpen)}
        onClose={() => setKillOpen(null)}
      />
      <Toasts toasts={toasts} dismiss={(id) => setToasts((ts) => ts.filter((t) => t.id !== id))} />
    </motion.div>
  )
}
