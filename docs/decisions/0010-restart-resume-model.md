# ADR-0010: Restart → STOPPED + resumable; survives repeated restarts

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §7

## Context
On restart, either resume automatically (`RESUME_ON_RESTART=true`) or show "Resume?" (default).
The bot may be restarted again before anyone presses Resume.

## Decision
- Every transition persists `runtime_json` on the session row (cycle no, planned/anchor/prev entry,
  current TP/SL, position, cycle row id, P/L, flags).
- A session is "open" while `ended_at IS NULL`. `recover()` loads the newest open session:
  - Original state IDLE/STOPPED → end it, nothing to do.
  - Otherwise restore everything, set `resumable = True` and `resume_state = <state before restart>`
    (persisted). With auto-resume → `resume()`. Else STOPPED `RESTART` + "Resume?" toast/button.
  - Because `resume_state` is persisted, a second restart still knows the original state.
- `resume()`: tracked position still live → IN_POSITION. Tracked position gone → RESOLVING (TP
  continues the chain, SL stops). No tracked position → attach own-session position if any (ADR-0009),
  else re-arm a fresh touch trigger at the planned entry.
- Arming a new session while one is resumable ends the old one.
- `recover()` waits until the broker is connected (`_recover_when_connected` in main.py).

## Consequences
The trade itself is always protected by server-side TP/SL while the bot is down.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `recover`, `resume`, `_runtime`
- [main.py](../../backend/app/main.py) `_recover_when_connected`
- Tests: all of [test_recovery.py](../../backend/tests/test_recovery.py)
