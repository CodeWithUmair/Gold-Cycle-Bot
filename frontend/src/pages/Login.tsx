import { motion } from 'framer-motion'
import { useState, type FormEvent } from 'react'
import { api } from '../api'

export function Login({ onLogin }: { onLogin: () => void }) {
  const [username, setUsername] = useState('admin')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await api.login(username, password)
      onLogin()
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex h-full items-center justify-center p-4">
      <motion.form
        onSubmit={submit}
        initial={{ opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        className="w-full max-w-sm space-y-4 rounded-xl border border-line bg-panel p-6 shadow-2xl"
      >
        <div className="flex items-center gap-2.5">
          <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden>
            <circle cx="16" cy="16" r="11" fill="none" stroke="var(--color-gold)" strokeWidth="3.5" />
            <path d="M16 5 a11 11 0 0 1 11 11" fill="none" stroke="var(--color-up)" strokeWidth="3.5" strokeLinecap="round" />
          </svg>
          <h1 className="text-lg font-semibold">GoldCycle</h1>
        </div>
        <div>
          <label className="label">Username</label>
          <input className="field" autoComplete="username" value={username} onChange={(e) => setUsername(e.target.value)} />
        </div>
        <div>
          <label className="label">Password</label>
          <input className="field" type="password" autoComplete="current-password" autoFocus value={password} onChange={(e) => setPassword(e.target.value)} />
        </div>
        {error && <p className="rounded bg-down/10 px-2 py-1.5 text-xs text-down">{error}</p>}
        <button className="btn w-full bg-gold font-semibold text-black hover:bg-gold/90" disabled={busy || !password}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </motion.form>
    </div>
  )
}
