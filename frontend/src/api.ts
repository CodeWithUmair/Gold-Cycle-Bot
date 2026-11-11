import type { Account, Candle, CycleRow, EngineSnapshot, Report, SymbolSpec, Tick, Validation } from './types'

let csrf = ''

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

async function req<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (method !== 'GET') headers['X-CSRF-Token'] = csrf
  const res = await fetch(path, {
    method,
    credentials: 'same-origin',
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!res.ok) {
    let detail = res.statusText
    try {
      const j = await res.json()
      detail = typeof j.detail === 'string' ? j.detail : JSON.stringify(j.detail)
    } catch {
      /* non-JSON error body: keep statusText */
    }
    throw new ApiError(res.status, detail)
  }
  return (await res.json()) as T
}

interface Me {
  username: string
  csrf: string
}

export interface StatusResponse {
  engine: EngineSnapshot
  account: Account | null
  tick: Tick | null
  broker: string
  dry_run: boolean
}

export interface SettingsResponse {
  symbol: string
  symbols: string[]
  symbols_error: string | null
  broker: string
  dry_run: boolean
  magic: number
  resume_on_restart: boolean
}

export interface TestConnectionResponse {
  ok: boolean
  error?: string
  account?: Account
  tick?: Tick
  spec?: SymbolSpec
}

const remember = (m: Me) => {
  csrf = m.csrf
  return m
}

export const api = {
  me: () => req<Me>('GET', '/api/auth/me').then(remember),
  login: (username: string, password: string) =>
    req<Me>('POST', '/api/auth/login', { username, password }).then(remember),
  logout: () => req<{ ok: boolean }>('POST', '/api/auth/logout'),

  status: () => req<StatusResponse>('GET', '/api/bot/status'),
  validate: (cfg: unknown) => req<Validation>('POST', '/api/bot/validate', cfg),
  arm: (cfg: unknown) => req<EngineSnapshot>('POST', '/api/bot/arm', cfg),
  stop: () => req<EngineSnapshot>('POST', '/api/bot/stop'),
  stopAfterCycle: () => req<EngineSnapshot>('POST', '/api/bot/stop-after-cycle'),
  closeAll: () => req<EngineSnapshot>('POST', '/api/bot/close-all'),
  resume: () => req<EngineSnapshot>('POST', '/api/bot/resume'),

  candles: (tf: string, count = 600) => req<Candle[]>('GET', `/api/candles?tf=${tf}&count=${count}`),
  cycles: (sessionId?: string | null) =>
    req<CycleRow[]>('GET', `/api/history/cycles${sessionId ? `?session_id=${sessionId}` : '?limit=50'}`),
  events: (limit = 200) =>
    req<{ ts: number; level: string; message: string }[]>('GET', `/api/history/events?limit=${limit}`),

  report: (since: number) => req<Report>('GET', `/api/reports/summary?since=${since}`),
  csvUrl: (since: number) => `/api/reports/cycles.csv?since=${since}`,

  settings: () => req<SettingsResponse>('GET', '/api/settings'),
  setSymbol: (symbol: string) => req<{ symbol: string }>('POST', '/api/settings/symbol', { symbol }),
  testConnection: () => req<TestConnectionResponse>('POST', '/api/settings/test-connection'),
}
