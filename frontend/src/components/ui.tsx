import { AnimatePresence, animate, motion, useReducedMotion } from 'framer-motion'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { BotState, LogEntry } from '../types'

export const fmt = (n: number | null | undefined, d = 2) =>
  n === null || n === undefined || Number.isNaN(n) ? '—' : n.toFixed(d)

export const fmtMoney = (n: number | null | undefined, cur = '') =>
  n === null || n === undefined ? '—' : `${n >= 0 ? '+' : '−'}${Math.abs(n).toFixed(2)}${cur ? ` ${cur}` : ''}`

export const pnlColor = (n: number | null | undefined) =>
  n === null || n === undefined || n === 0 ? 'text-muted' : n > 0 ? 'text-up' : 'text-down'

/** Animated number (P/L, balance). Jumps straight to the value when the user prefers reduced motion. */
export function NumberTicker({ value, format }: { value: number; format: (n: number) => string }) {
  const reduce = useReducedMotion()
  const [shown, setShown] = useState(value)
  const prev = useRef(value)
  useEffect(() => {
    if (reduce) {
      setShown(value)
      prev.current = value
      return
    }
    const c = animate(prev.current, value, { duration: 0.45, ease: 'easeOut', onUpdate: setShown })
    prev.current = value
    return () => c.stop()
  }, [value, reduce])
  return <span className="num">{format(shown)}</span>
}

const STATE_STYLE: Record<BotState, { label: string; cls: string; dot: string; pulse: boolean }> = {
  IDLE: { label: 'IDLE', cls: 'bg-panel-2 text-muted border-line', dot: 'bg-faint', pulse: false },
  ARMED: { label: 'ARMED', cls: 'bg-info/10 text-info border-info/30', dot: 'bg-info', pulse: true },
  OPENING: { label: 'OPENING', cls: 'bg-gold/10 text-gold border-gold/30', dot: 'bg-gold', pulse: true },
  IN_POSITION: { label: 'IN POSITION', cls: 'bg-up/10 text-up border-up/30', dot: 'bg-up', pulse: true },
  RESOLVING: { label: 'RESOLVING', cls: 'bg-gold/10 text-gold border-gold/30', dot: 'bg-gold', pulse: true },
  STOPPED: { label: 'STOPPED', cls: 'bg-down/10 text-down border-down/30', dot: 'bg-down', pulse: false },
}

export function StateBadge({ state }: { state: BotState }) {
  const s = STATE_STYLE[state]
  return (
    <AnimatePresence mode="wait" initial={false}>
      <motion.span
        key={state}
        initial={{ opacity: 0, y: -6, scale: 0.96 }}
        animate={{ opacity: 1, y: 0, scale: 1 }}
        exit={{ opacity: 0, y: 6, scale: 0.96 }}
        transition={{ duration: 0.18 }}
        className={`inline-flex items-center gap-2 rounded-full border px-3 py-1 text-xs font-semibold tracking-wider ${s.cls}`}
      >
        <span className="relative flex h-2 w-2">
          {s.pulse && (
            <span className={`absolute inline-flex h-full w-full animate-ping rounded-full opacity-60 motion-reduce:hidden ${s.dot}`} />
          )}
          <span className={`relative inline-flex h-2 w-2 rounded-full ${s.dot}`} />
        </span>
        {s.label}
      </motion.span>
    </AnimatePresence>
  )
}

export function Dot({ ok, label, title }: { ok: boolean; label: string; title?: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-xs text-muted" title={title}>
      <span className={`h-2 w-2 rounded-full ${ok ? 'bg-up shadow-[0_0_6px] shadow-up/60' : 'bg-down'}`} />
      {label}
    </span>
  )
}

export interface Toast extends LogEntry {
  id: number
}

export function Toasts({ toasts, dismiss }: { toasts: Toast[]; dismiss: (id: number) => void }) {
  const tone = { info: 'border-info/40', warn: 'border-warn/50', error: 'border-down/60' }
  const icon = { info: 'text-info', warn: 'text-warn', error: 'text-down' }
  return (
    <div className="pointer-events-none fixed top-16 right-4 z-50 flex w-96 max-w-[calc(100vw-2rem)] flex-col gap-2">
      <AnimatePresence initial={false}>
        {toasts.map((t) => (
          <motion.div
            key={t.id}
            layout
            initial={{ opacity: 0, x: 40 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0, x: 40 }}
            transition={{ duration: 0.2 }}
            onClick={() => dismiss(t.id)}
            className={`pointer-events-auto cursor-pointer rounded-lg border bg-panel-2/95 px-3.5 py-2.5 text-sm shadow-xl shadow-black/40 backdrop-blur ${tone[t.level]}`}
          >
            <span className={`mr-2 font-semibold uppercase text-[11px] tracking-wider ${icon[t.level]}`}>{t.level}</span>
            {t.msg}
          </motion.div>
        ))}
      </AnimatePresence>
    </div>
  )
}

export function Modal({ open, onClose, children }: { open: boolean; onClose: () => void; children: ReactNode }) {
  useEffect(() => {
    if (!open) return
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', k)
    return () => window.removeEventListener('keydown', k)
  }, [open, onClose])
  return (
    <AnimatePresence>
      {open && (
        <motion.div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          onMouseDown={onClose}
        >
          <motion.div
            className="w-full max-w-md rounded-xl border border-line bg-panel p-5 shadow-2xl"
            initial={{ scale: 0.95, y: 10 }}
            animate={{ scale: 1, y: 0 }}
            exit={{ scale: 0.95, y: 10 }}
            onMouseDown={(e) => e.stopPropagation()}
          >
            {children}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  )
}

export function ConfirmModal(props: {
  open: boolean
  title: string
  body: ReactNode
  confirmLabel: string
  danger?: boolean
  onConfirm: () => void
  onClose: () => void
}) {
  return (
    <Modal open={props.open} onClose={props.onClose}>
      <h3 className="mb-2 text-base font-semibold">{props.title}</h3>
      <div className="mb-5 text-sm text-muted">{props.body}</div>
      <div className="flex justify-end gap-2">
        <button className="btn bg-panel-2 hover:bg-line" onClick={props.onClose}>
          Cancel
        </button>
        <button
          autoFocus
          className={`btn ${props.danger ? 'bg-down text-white hover:bg-down/85' : 'bg-gold text-black hover:bg-gold/85'}`}
          onClick={() => {
            props.onConfirm()
            props.onClose()
          }}
        >
          {props.confirmLabel}
        </button>
      </div>
    </Modal>
  )
}
