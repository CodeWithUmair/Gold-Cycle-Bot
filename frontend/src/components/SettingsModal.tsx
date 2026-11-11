import { useEffect, useState } from 'react'
import { api, type SettingsResponse, type TestConnectionResponse } from '../api'
import { Modal } from './ui'

export function SettingsModal({ open, onClose, running }: { open: boolean; onClose: () => void; running: boolean }) {
  const [s, setS] = useState<SettingsResponse | null>(null)
  const [symbol, setSymbol] = useState('')
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [test, setTest] = useState<TestConnectionResponse | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!open) return
    setMsg(null)
    setTest(null)
    api
      .settings()
      .then((r) => {
        setS(r)
        setSymbol(r.symbol)
      })
      .catch((e: Error) => setMsg({ ok: false, text: e.message }))
  }, [open])

  const save = async () => {
    setBusy(true)
    try {
      const r = await api.setSymbol(symbol)
      setMsg({ ok: true, text: `Symbol set to ${r.symbol}` })
    } catch (e) {
      setMsg({ ok: false, text: (e as Error).message })
    } finally {
      setBusy(false)
    }
  }

  const runTest = async () => {
    setBusy(true)
    try {
      setTest(await api.testConnection())
    } catch (e) {
      setTest({ ok: false, error: (e as Error).message })
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal open={open} onClose={onClose}>
      <h3 className="mb-4 text-base font-semibold">Settings</h3>
      {s && (
        <div className="space-y-4 text-sm">
          <div>
            <label className="label">Gold symbol</label>
            <div className="flex gap-2">
              <select className="field" value={symbol} onChange={(e) => setSymbol(e.target.value)} disabled={running}>
                {s.symbols.map((x) => (
                  <option key={x}>{x}</option>
                ))}
              </select>
              <button className="btn shrink-0 bg-gold text-black hover:bg-gold/85" onClick={save} disabled={busy || running || symbol === s.symbol}>
                Save
              </button>
            </div>
            <p className="mt-1 text-xs text-faint">
              {running ? 'Stop the bot to change the symbol. ' : ''}Detected via *XAU*USD* on this account.
              {s.symbols_error ? ` (${s.symbols_error})` : ''}
            </p>
          </div>
          <dl className="num grid grid-cols-2 gap-y-1 text-xs">
            <dt className="text-muted">Broker</dt>
            <dd>{s.broker}{s.dry_run ? ' (dry run)' : ''}</dd>
            <dt className="text-muted">Magic number</dt>
            <dd>{s.magic}</dd>
            <dt className="text-muted">Resume on restart</dt>
            <dd>{s.resume_on_restart ? 'automatic' : 'ask'}</dd>
          </dl>
          <div>
            <button className="btn w-full border border-line hover:bg-panel-2" onClick={runTest} disabled={busy}>
              Test connection
            </button>
            {test && (
              <div className={`num mt-2 rounded p-2 text-xs ${test.ok ? 'bg-up/10 text-up' : 'bg-down/10 text-down'}`}>
                {test.ok && test.account && test.tick ? (
                  <>
                    Connected · {test.account.server} · {test.account.is_demo ? 'demo' : 'LIVE'} · {test.account.currency}{' '}
                    {test.account.balance.toFixed(2)} · bid {test.tick.bid} ask {test.tick.ask}
                    {!test.account.trade_allowed && <div className="text-warn">Algo Trading is disabled in the terminal</div>}
                  </>
                ) : (
                  <>Failed: {test.error ?? 'not connected'}</>
                )}
              </div>
            )}
          </div>
        </div>
      )}
      {msg && <p className={`mt-3 text-xs ${msg.ok ? 'text-up' : 'text-down'}`}>{msg.text}</p>}
      <div className="mt-5 flex justify-end">
        <button className="btn bg-panel-2 hover:bg-line" onClick={onClose}>
          Close
        </button>
      </div>
    </Modal>
  )
}
