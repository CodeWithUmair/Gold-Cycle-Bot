import { MotionConfig } from 'framer-motion'
import { useEffect, useState } from 'react'
import { api } from './api'
import { Dashboard } from './pages/Dashboard'
import { Login } from './pages/Login'

export default function App() {
  const [authed, setAuthed] = useState<boolean | null>(null)

  useEffect(() => {
    api
      .me()
      .then(() => setAuthed(true))
      .catch(() => setAuthed(false))
  }, [])

  return (
    <MotionConfig reducedMotion="user">
      {authed === null ? null : authed ? (
        <Dashboard onLoggedOut={() => setAuthed(false)} />
      ) : (
        <Login onLogin={() => setAuthed(true)} />
      )}
    </MotionConfig>
  )
}
