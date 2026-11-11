import { AnimatePresence, motion } from 'framer-motion'
import type { LogEntry } from '../types'

const LEVEL_CLS = { info: 'text-muted', warn: 'text-warn', error: 'text-down' }

export function LogDrawer({ open, logs, onClose }: { open: boolean; logs: LogEntry[]; onClose: () => void }) {
  return (
    <AnimatePresence>
      {open && (
        <>
          <motion.div className="fixed inset-0 z-40 bg-black/30" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={onClose} />
          <motion.aside
            className="fixed top-0 right-0 bottom-0 z-40 flex w-[480px] max-w-full flex-col border-l border-line bg-panel shadow-2xl"
            initial={{ x: '100%' }}
            animate={{ x: 0 }}
            exit={{ x: '100%' }}
            transition={{ type: 'tween', duration: 0.22 }}
          >
            <div className="flex items-center border-b border-line px-4 py-3">
              <h2 className="text-sm font-medium">Event log</h2>
              <button className="ml-auto rounded px-2 py-1 text-muted hover:bg-panel-2 hover:text-text" onClick={onClose}>
                ✕
              </button>
            </div>
            <ul className="min-h-0 flex-1 space-y-0.5 overflow-y-auto p-3 text-xs">
              {logs.map((l, i) => (
                <li key={`${l.ts}-${i}`} className="flex gap-3 rounded px-2 py-1 hover:bg-panel-2">
                  <span className="num shrink-0 text-faint">{new Date(l.ts * 1000).toLocaleTimeString()}</span>
                  <span className={LEVEL_CLS[l.level] ?? 'text-muted'}>{l.msg}</span>
                </li>
              ))}
              {logs.length === 0 && <li className="p-4 text-center text-faint">No events yet.</li>}
            </ul>
          </motion.aside>
        </>
      )}
    </AnimatePresence>
  )
}
