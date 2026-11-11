import { useEffect, useRef, useState } from 'react'
import type { Account, CycleRow, EngineSnapshot, LogEntry, Tick } from '../types'

export interface SocketHandlers {
  onTick?: (t: Tick) => void
  onLog?: (l: LogEntry) => void
  onToast?: (l: LogEntry) => void
  onCycle?: (c: CycleRow) => void
}

interface SocketState {
  wsConnected: boolean
  engine: EngineSnapshot | null
  account: Account | null
  tick: Tick | null
  floating: number | null
}

type Msg =
  | { type: 'tick'; data: Tick }
  | { type: 'state'; data: EngineSnapshot }
  | { type: 'account'; data: Account }
  | { type: 'floating'; data: { profit: number } }
  | { type: 'log'; data: LogEntry }
  | { type: 'toast'; data: LogEntry }
  | { type: 'cycle'; data: CycleRow }

/** One websocket to the backend; reconnects with backoff. The server already throttles to ~10 msg/s. */
export function useSocket(enabled: boolean, handlers: SocketHandlers): SocketState {
  const [state, setState] = useState<SocketState>({
    wsConnected: false,
    engine: null,
    account: null,
    tick: null,
    floating: null,
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
        setState((s) => ({ ...s, wsConnected: true }))
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
              engine: m.data,
              floating: m.data.position ? m.data.position.profit : null,
            }))
            break
          case 'account':
            setState((s) => ({ ...s, account: m.data }))
            break
          case 'floating':
            setState((s) => ({ ...s, floating: m.data.profit }))
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
        if (!closed) {
          timer = window.setTimeout(connect, retry)
          retry = Math.min(retry * 2, 8000)
        }
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
