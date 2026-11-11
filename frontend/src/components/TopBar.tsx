import type { Account, EngineSnapshot, Tick } from '../types'
import { Dot, NumberTicker, StateBadge, fmt } from './ui'

interface Props {
  engine: EngineSnapshot | null
  account: Account | null
  tick: Tick | null
  wsConnected: boolean
  broker: string
  dryRun: boolean
  onSettings: () => void
  onLogout: () => void
  view: 'trading' | 'reports'
  onView: (v: 'trading' | 'reports') => void
}

export function TopBar({ engine, account, tick, wsConnected, broker, dryRun, onSettings, onLogout, view, onView }: Props) {
  const digits = engine?.spec?.digits ?? 2
  const spread = tick ? tick.ask - tick.bid : null
  const mode = dryRun ? 'DRY RUN' : broker === 'sim' ? 'SIMULATOR' : account?.is_demo ? 'DEMO' : account ? 'LIVE' : ''
  const modeCls =
    mode === 'LIVE' ? 'bg-down/15 text-down border-down/40' : 'bg-gold/10 text-gold border-gold/30'
  const cur = account?.currency ?? ''
  const money = (n: number) => n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })

  return (
    <header className="flex flex-wrap items-center gap-x-6 gap-y-2 border-b border-line bg-panel/80 px-4 py-2.5 backdrop-blur">
      <div className="flex items-center gap-2.5">
        <svg width="22" height="22" viewBox="0 0 32 32" aria-hidden>
          <circle cx="16" cy="16" r="11" fill="none" stroke="var(--color-gold)" strokeWidth="3.5" />
          <path d="M16 5 a11 11 0 0 1 11 11" fill="none" stroke="var(--color-up)" strokeWidth="3.5" strokeLinecap="round" />
        </svg>
        <span className="text-[15px] font-semibold tracking-tight">GoldCycle</span>
        {mode && <span className={`rounded border px-1.5 py-0.5 text-[10px] font-bold tracking-wider ${modeCls}`}>{mode}</span>}
      </div>

      <nav className="flex rounded-md border border-line p-0.5" aria-label="View">
        {(['trading', 'reports'] as const).map((v) => (
          <button
            key={v}
            onClick={() => onView(v)}
            className={`rounded px-3 py-1 text-xs font-medium capitalize transition-colors ${
              view === v ? 'bg-gold/15 text-gold' : 'text-muted hover:text-text'
            }`}
          >
            {v}
          </button>
        ))}
      </nav>

      <div className="flex items-center gap-3">
        <Dot ok={!!engine?.connected} label="MT5" title={engine?.connected ? 'Broker connected' : 'Broker disconnected'} />
        <Dot ok={wsConnected} label="Live" title="Dashboard websocket" />
        {account && !account.trade_allowed && (
          <span className="text-xs text-warn" title="Enable Algo Trading in the MT5 terminal">
            Algo Trading off
          </span>
        )}
      </div>

      <div className="flex items-baseline gap-5 text-sm">
        <Stat label="Symbol" value={<span className="num">{engine?.symbol ?? '—'}</span>} />
        <Stat
          label="Bid / Ask"
          value={
            <span className="num">
              {fmt(tick?.bid, digits)} <span className="text-faint">/</span> {fmt(tick?.ask, digits)}
            </span>
          }
        />
        <Stat label="Spread" value={<span className="num">{spread === null ? '—' : spread.toFixed(2)}</span>} />
        <Stat
          label="Balance"
          value={account ? <NumberTicker value={account.balance} format={(n) => `${money(n)} ${cur}`} /> : '—'}
        />
        <Stat
          label="Equity"
          value={account ? <NumberTicker value={account.equity} format={(n) => `${money(n)} ${cur}`} /> : '—'}
        />
      </div>

      <div className="ml-auto flex items-center gap-3">
        {engine && <StateBadge state={engine.state} />}
        <button className="btn px-2 py-1.5 text-muted hover:bg-panel-2 hover:text-text" onClick={onSettings} title="Settings">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </button>
        <button className="btn px-2 py-1.5 text-xs text-muted hover:bg-panel-2 hover:text-text" onClick={onLogout}>
          Log out
        </button>
      </div>
    </header>
  )
}

function Stat({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col leading-tight">
      <span className="text-[10px] tracking-wider text-faint uppercase">{label}</span>
      <span className="text-[13px]">{value}</span>
    </div>
  )
}
