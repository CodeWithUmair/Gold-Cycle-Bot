import { useEffect, useRef, useState } from 'react'
import type { Account, CycleRow, EngineSnapshot, LogEntry, Mode, PerMode, Tick } from '../types'

export interface SocketHandlers {
  onTick?: (t: Tick) => void
  onLog?: (l: LogEntry) => void
  onToast?: (l: LogEntry) => void
  onCycle?: (c: CycleRow) => void
  /** The server is back but no longer knows this login (session expired). */
  onAuthLost?: () => void
}

interface SocketState {
  wsConnected: boolean
  /** How many times the socket has connected: 1 = first load, more = it came back after a drop. */
  connectCount: number
  engines: PerMode<EngineSnapshot | null>
  account: Account | null
  tick: Tick | null
  floating: PerMode<number | null>
}

type Msg =
  | { type: 'tick'; data: Tick }
  | { type: 'state'; data: EngineSnapshot }
  | { type: 'account'; data: Account }
  | { type: 'floating'; data: { profit: number; mode: Mode } }
  | { type: 'log'; data: LogEntry }
  | { type: 'toast'; data: LogEntry }
  | { type: 'cycle'; data: CycleRow }

/** One websocket to the backend; reconnects with backoff. The server already throttles to ~10 msg/s. */
export function useSocket(enabled: boolean, handlers: SocketHandlers): SocketState {
  const [state, setState] = useState<SocketState>({
    wsConnected: false,
    connectCount: 0,
    engines: { CYCLE: null, SINGLE: null },
    account: null,
    tick: null,
    floating: { CYCLE: null, SINGLE: null },
  })
  const h = useRef(handlers)
  h.current = handlers

  useEffect(() => {
    if (!enabled) return
    let ws: WebSocket | null = null
    let closed = false
    let retry = 500
    let timer: number | undefined
    let ping: number | undefined

    const connect = () => {
      const proto = location.protocol === 'https:' ? 'wss' : 'ws'
      ws = new WebSocket(`${proto}://${location.host}/ws`)
      ws.onopen = () => {
        retry = 500
        setState((s) => ({ ...s, wsConnected: true, connectCount: s.connectCount + 1 }))
        ping = window.setInterval(() => ws?.readyState === WebSocket.OPEN && ws.send('ping'), 20000)
      }
      ws.onmessage = (ev) => {
        const m = JSON.parse(ev.data as string) as Msg
        switch (m.type) {
          case 'tick':
            h.current.onTick?.(m.data)
            setState((s) => ({ ...s, tick: m.data }))
            break
          case 'state':
            setState((s) => ({
              ...s,
              engines: { ...s.engines, [m.data.mode]: m.data },
              floating: { ...s.floating, [m.data.mode]: m.data.position ? m.data.position.profit : null },
            }))
            break
          case 'account':
            setState((s) => ({ ...s, account: m.data }))
            break
          case 'floating':
            setState((s) => ({ ...s, floating: { ...s.floating, [m.data.mode]: m.data.profit } }))
            break
          case 'log':
            h.current.onLog?.(m.data)
            break
          case 'toast':
            h.current.onToast?.(m.data)
            break
          case 'cycle':
            h.current.onCycle?.(m.data)
            break
        }
      }
      ws.onclose = () => {
        window.clearInterval(ping)
        setState((s) => ({ ...s, wsConnected: false }))
        if (closed) return
        // The bot restarted, or it is still starting. Ask whether this login is still valid: the answer
        // is a 401 (go to the login page), a network error (server still down: keep retrying) or OK.
        void fetch('/api/auth/me', { credentials: 'same-origin' })
          .then((r) => {
            if (r.status === 401) {
              closed = true
              h.current.onAuthLost?.()
            }
          })
          .catch(() => undefined) // server not up yet
          .finally(() => {
            if (closed) return
            timer = window.setTimeout(connect, retry)
            retry = Math.min(retry * 2, 3000)
          })
      }
    }
    connect()
    return () => {
      closed = true
      window.clearTimeout(timer)
      window.clearInterval(ping)
      ws?.close()
    }
  }, [enabled])

  return state
}
