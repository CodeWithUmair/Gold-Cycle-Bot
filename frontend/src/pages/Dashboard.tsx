import { motion } from 'framer-motion'
import { useCallback, useEffect, useRef, useState } from 'react'
import { ApiError, api } from '../api'
import { ControlPanel } from '../components/ControlPanel'
import { Journal } from '../components/Journal'
import { LogDrawer } from '../components/LogDrawer'
import { PriceChart } from '../components/PriceChart'
import { SettingsModal } from '../components/SettingsModal'
import { TopBar } from '../components/TopBar'
import { ConfirmModal, Toasts, type Toast } from '../components/ui'
import { useSocket } from '../hooks/useSocket'
import { Reports } from './Reports'
import { ACTIVE_STATES, type CycleRow, type EngineSnapshot, type LogEntry, type Tick } from '../types'

let toastId = 0

export function Dashboard({ onLoggedOut }: { onLoggedOut: () => void }) {
  const [engine, setEngine] = useState<EngineSnapshot | null>(null)
  const [broker, setBroker] = useState('')
  const [dryRun, setDryRun] = useState(false)
  const [cycles, setCycles] = useState<CycleRow[]>([])
  const [logs, setLogs] = useState<LogEntry[]>([])
  const [toasts, setToasts] = useState<Toast[]>([])
  const [logOpen, setLogOpen] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [killOpen, setKillOpen] = useState(false)
  const [view, setView] = useState<'trading' | 'reports'>('trading')
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
    if (ws.engine) setEngine(ws.engine)
  }, [ws.engine])

  // initial load
  useEffect(() => {
    api
      .status()
      .then((s) => {
        setEngine((e) => e ?? s.engine)
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
        setKillOpen(true)
      }
    }
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [])

  const onAction = async (name: 'arm' | 'stop' | 'stopAfterCycle' | 'closeAll' | 'resume', cfg?: unknown) => {
    try {
      const snap = name === 'arm' ? await api.arm(cfg) : await api[name]()
      setEngine(snap)
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
  const running = !!engine && ACTIVE_STATES.includes(engine.state)

  return (
    <motion.div className="flex h-full flex-col" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.3 }}>
      <TopBar
        engine={engine}
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
            <PriceChart engine={engine} cycles={cycles} tickRef={tickRef} />
          </motion.section>
          <motion.section className="h-64 shrink-0" initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}>
            <Journal rows={cycles} sessionPnl={engine?.session_pnl ?? 0} currency={currency} onOpenLog={() => setLogOpen(true)} />
          </motion.section>
        </div>
        <motion.aside
          className="min-h-0 border-l border-line bg-panel"
          initial={{ opacity: 0, x: 12 }}
          animate={{ opacity: 1, x: 0 }}
          transition={{ delay: 0.08 }}
        >
          <ControlPanel
            engine={engine}
            tick={ws.tick}
            floating={ws.floating}
            currency={currency}
            onAction={onAction}
            onKill={() => setKillOpen(true)}
          />
        </motion.aside>
      </div>

      <LogDrawer open={logOpen} logs={logs} onClose={() => setLogOpen(false)} />
      <SettingsModal open={settingsOpen} onClose={() => setSettingsOpen(false)} running={running} />
      <ConfirmModal
        open={killOpen}
        title="Close all & stop?"
        danger
        confirmLabel="Close all & stop"
        body={
          <>
            Closes <b>every</b> open position with the bot's magic number at market and stops the bot.
            {engine?.position && (
              <span className="mt-2 block">
                Open: C{engine.cycle_no} #{engine.position.ticket} ({engine.position.volume} lots)
              </span>
            )}
          </>
        }
        onConfirm={() => onAction('closeAll')}
        onClose={() => setKillOpen(false)}
      />
      <Toasts toasts={toasts} dismiss={(id) => setToasts((ts) => ts.filter((t) => t.id !== id))} />
    </motion.div>
  )
}
