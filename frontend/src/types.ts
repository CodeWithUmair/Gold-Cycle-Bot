export type BotState = 'IDLE' | 'ARMED' | 'OPENING' | 'IN_POSITION' | 'RESOLVING' | 'STOPPED'
export type Direction = 'BUY' | 'SELL'
export type Mode = 'CYCLE' | 'SINGLE'

export interface Tick {
  bid: number
  ask: number
  time: number
}

export interface Account {
  login: number
  server: string
  currency: string
  balance: number
  equity: number
  is_demo: boolean
  trade_allowed: boolean
}

export interface SymbolSpec {
  name: string
  digits: number
  point: number
  volume_min: number
  volume_max: number
  volume_step: number
  stops_level: number
  freeze_level: number
  contract_size: number
}

export interface CycleConfig {
  mode: Mode
  direction: Direction
  trigger_price: number
  lot: number
  tp_sl_input: 'points' | 'price'
  tp_points: number | null
  sl_points: number | null
  tp_price: number | null
  sl_price: number | null
  cycle_gap: number | null
  stop_price: number | null
  gap_entry_mode: 'wait_for_touch' | 'immediate'
  sl_mode: 'points' | 'previous_entry'
  level_anchor: 'planned' | 'fill'
  trigger_price_side: 'bid' | 'ask' | 'mid'
  max_slippage_points: number
  max_cycles: number | null
  daily_loss_limit: number | null
  max_spread_points: number | null
  trading_hours: string | null
}

export interface LivePosition {
  ticket: number
  fill_price: number
  tp: number
  sl: number
  volume: number
  open_time: number
  profit: number
}

export interface EngineSnapshot {
  state: BotState
  session_id: string | null
  symbol: string
  connected: boolean
  config: CycleConfig | null
  cycle_no: number
  trigger_level: number | null
  planned_entry: number | null
  tp: number | null
  sl: number | null
  next_entry: number | null
  stop_price: number | null
  position: LivePosition | null
  session_pnl: number
  waiting: string | null
  stop_reason: string | null
  resumable: boolean
  stop_after_cycle: boolean
  pending_close: string | null
  daily_loss_block: boolean
  spec: SymbolSpec | null
}

export interface CycleRow {
  id: number
  session_id: string
  cycle_no: number
  direction: Direction
  planned_entry: number
  fill_price: number | null
  slippage: number | null
  tp: number
  sl: number
  volume: number
  ticket: number | null
  open_time: number | null
  close_time: number | null
  close_price: number | null
  close_reason: string | null
  pnl: number | null
}

export interface LogEntry {
  ts: number
  level: 'info' | 'warn' | 'error'
  msg: string
}

export interface PlannedCycle {
  cycle: number
  entry: number
  tp: number
  sl: number
  lot: number
}

export interface Validation {
  errors: string[]
  warnings: string[]
  ladder: PlannedCycle[]
}

export interface Candle {
  time: number
  open: number
  high: number
  low: number
  close: number
}

export interface ReportKpis {
  sessions: number
  cycles: number
  closed: number
  open: number
  wins: number
  losses: number
  win_rate: number | null
  tp_count: number
  sl_count: number
  net_pnl: number
  gross_profit: number
  gross_loss: number
  profit_factor: number | null
  avg_win: number | null
  avg_loss: number | null
  expectancy: number | null
  best: number | null
  worst: number | null
  max_drawdown: number
  avg_slippage: number | null
  max_slippage: number | null
  avg_duration_s: number | null
  max_win_streak: number
  max_loss_streak: number
}

export interface EquityPoint {
  n: number
  t: number
  cum: number
  pnl: number
  cycle_no: number
  reason: string
  session_id: string
}

export interface DailyRow {
  date: string
  pnl: number
  cycles: number
  wins: number
  losses: number
}

export interface SessionSummary {
  id: string
  mode: Mode
  direction: Direction
  symbol: string
  trigger_price: number | null
  lot: number | null
  tp_points: number | null
  sl_points: number | null
  cycle_gap: number | null
  stop_price: number | null
  state: BotState
  stop_reason: string | null
  started_at: number
  ended_at: number | null
  duration_s: number | null
  cycles: number
  tp: number
  sl: number
  pnl: number
}

export interface Report {
  kpis: ReportKpis
  equity: EquityPoint[]
  daily: DailyRow[]
  reasons: { reason: string; count: number; pnl: number }[]
  sessions: SessionSummary[]
}

export const ACTIVE_STATES: BotState[] = ['ARMED', 'OPENING', 'IN_POSITION', 'RESOLVING']
