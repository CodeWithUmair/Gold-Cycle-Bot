# GoldCycle — MT5 auto TP/SL cycle bot (XAUUSD)

GoldCycle executes the trader's plan on MetaTrader 5 (Exness, gold). The trader chooses the level and direction. The bot waits for price to touch that level, then opens the trade with TP and SL set server-side. In **Cycle** mode, each TP starts the next trade along the ladder until the SL is hit, the stop price is reached, or the trader stops it. The bot never picks a direction itself.

The exact trading rules are in [CLAUDE.md](CLAUDE.md) §4, and that file is the source of truth.

- Backend: Python 3.11+, FastAPI, the official `MetaTrader5` package, SQLite.
- Frontend: Vite + React + TypeScript, built to static files and served by the backend. One process.
- The dashboard listens on **127.0.0.1 only**.

---

## Quick start (development, any OS, no MT5)

```bat
scripts\install.bat
cd backend
.venv\Scripts\python -m app.security        & REM paste the hash into .env
```

In `.env` set `BROKER=sim`, then run:

```bat
scripts\start.bat                           & REM http://127.0.0.1:8000
```

Frontend hot reload (optional): `cd frontend && npm run dev` serves http://127.0.0.1:5173 and proxies to the backend on :8000.

Tests:

```bat
cd backend
.venv\Scripts\python -m pytest
```

---

## VPS setup (Windows)

1. **Install** Python 3.11+ ("Add to PATH") and Node.js 20+.
2. **MT5 terminal (Exness):**
   - Log into the account and tick **Save password**.
   - Turn on the **Algo Trading** button in the toolbar. It must be green.
   - Under *Tools → Options → Expert Advisors*, tick **Allow algorithmic trading**.
   - Make the terminal start at boot. Either put a shortcut to `terminal64.exe` in `shell:startup` (with auto-logon for the VPS user), or create a Task Scheduler task "At log on".
3. **Copy** this folder to the VPS, e.g. `C:\goldcycle`, and run `scripts\install.bat`.
4. **Generate the admin password hash:**
   ```bat
   cd backend
   .venv\Scripts\python -m app.security
   ```
   Paste the `ADMIN_PASSWORD_HASH=...` line into `.env`.
5. **Edit `.env`:**
   - `BROKER=mt5`, `DRY_RUN=true`.
   - Leave `SYMBOL` blank to auto-detect. Exness Standard accounts use `XAUUSDm`; `XAUUSD247m` has no quotes.
6. **Run the tests:** `.venv\Scripts\python -m pytest` (from `backend\`).
7. **Go live in stages:**
   1. `DRY_RUN=true`: real prices, orders are only logged and paper-filled.
   2. `DRY_RUN=false` on the **demo** account for at least one full trading session.
   3. Only then switch the terminal to the live account.

### Run as a service (NSSM)

Download [NSSM](https://nssm.cc), put `nssm.exe` on PATH, then run as Administrator:

```bat
scripts\install_service.bat
```

The service auto-starts and restarts on exit. Its output goes to `logs\service.log`. Uninstall with:

```bat
nssm stop GoldCycle && nssm remove GoldCycle confirm
```

The MT5 Python API has to reach the running terminal. If the service can't attach, make it log on as the same Windows user that runs MT5 (`nssm set GoldCycle ObjectName .\User Password`). The other option is Task Scheduler running `scripts\start.bat` "At log on" for that user.

### Access

RDP into the VPS and open **http://127.0.0.1:8000**. For remote access, use Tailscale and keep `HOST` at 127.0.0.1 or set it to the Tailscale IP. **Never open the port publicly or set `HOST=0.0.0.0`.**

---

## Using the dashboard

| Control | What it does |
|---|---|
| **Cycle** tab | Part One: trigger price, direction, lot, TP/SL points, cycle gap (blank = continue from TP), stop price |
| **Single** tab | Part Two: one trade, then back to IDLE |
| Preview ladder | Next 5 planned cycles computed by the server from your inputs, shown before arming |
| **Arm** | Starts watching the trigger. If price is already past or at the trigger, the bot waits for it to come back and touch. |
| **Stop after this cycle** | The current trade runs to TP/SL, then the bot stops |
| **Stop now** | The bot stops managing. An open position **stays open with its server-side TP/SL**. |
| **Close all & stop** (red) | Kill switch: closes every bot position at market and stops. Hotkey **Ctrl+Shift+K**. |
| **Resume** | Shown after a restart (`RESUME_ON_RESTART=false`). Reattaches to the live position or resolves a trade that closed while the bot was down. |

Other parts of the page:
- **Chart lines:** trigger (dashed), entry, TP (green), SL (red), next entry (faint), stop price (amber).
- **Journal:** shows fill vs planned (slippage), result, and P/L per cycle.
- **Log drawer:** the full event history.

Fixed rules (confirmed with the client):
- SL hit → the bot stops.
- Stop price reached → the open trade closes immediately and the bot stops.
- Position closed by hand in MT5 → the bot stops.

### Safety limits (Advanced section, all optional)

| Setting | Default | Behaviour |
|---|---|---|
| `max_cycles` | off | Stop after N cycles |
| `daily_loss_limit` | off | Close the trade and stop; no new arms until tomorrow |
| `max_spread_points` | 0.6 | Don't open while the spread is wider; wait |
| `trading_hours` | off | e.g. `08:00-17:00` (VPS local time); outside it no new trade opens |
| `max_slippage_points` | 0.5 | Fill tolerance from the planned entry; beyond it, wait for another touch |

The broker's stops/freeze level is checked before arming. TP/SL that are too close are rejected in the form.

### Open questions: switches in the form

Q1 and Q2 are in the Cycle tab's Advanced section; Q5 is the "TP/SL in points | price" toggle on the Single tab.

| # | Question | Switch | Default |
|---|---|---|---|
| Q1 | With a gap, does the next cycle wait for a pullback or open immediately? | `gap_entry_mode` | `wait_for_touch` |
| Q2 | Next trade's SL: entry − SL points, or the previous entry? | `sl_mode` | `points` |
| Q5 | Single-mode TP/SL as points or exact prices? | `tp_sl_input` | `points` |

"Point" means 1.00 of price (4000 → 4003 = 3 points), not MT5's 0.01 point.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `MT5 initialize failed: Authorization failed (-6)` | The account in the terminal is invalid (e.g. an expired Exness demo) or not logged in. Log into a valid account with "Save password". The terminal log (*Journal* tab) shows the reason. |
| Order rejected `10027` | **Algo Trading** is off in the terminal. Turn it on. |
| Order rejected `10030` (unsupported filling) | The gateway picks FOK/IOC/RETURN from the symbol's `filling_mode`. Exness `XAUUSDm` takes FOK/IOC. Check that the right symbol is selected. |
| "has no prices (bid=0)" | Wrong symbol, e.g. `XAUUSD247m`. Pick `XAUUSDm` in Settings. |
| MT5 dot red, "engine paused" | The terminal is disconnected. The bot retries with backoff and sends no orders until it reconnects. |
| Can't log in / 429 | 5 failed logins per 5 min per IP. Wait, or check `ADMIN_PASSWORD_HASH`. |

Logs:
- `logs\goldcycle.log`: JSON lines, rotated.
- `logs\service.log`: service output.

Every state change and user action is also stored in `data\goldcycle.db`, in the `events` and `audit` tables.

---

## Layout

```
goldcycle/
├─ CLAUDE.md            spec / rules
├─ .env.example         copy to .env
├─ scripts/             install.bat, start.bat, install_service.bat
├─ backend/
│  ├─ app/
│  │  ├─ main.py        FastAPI app + engine loop, serves frontend/dist
│  │  ├─ config.py      settings from .env
│  │  ├─ api/           auth, bot, settings, history routes
│  │  ├─ ws.py          websocket hub (throttled ~10/s)
│  │  ├─ broker/        base.py (interface), mt5_gateway.py, sim_broker.py
│  │  ├─ engine/        models, levels (pure math), trigger, risk, cycle_engine
│  │  ├─ storage/       SQLite repo
│  │  └─ security.py    argon2, sessions, CSRF, rate limit
│  └─ tests/            levels (client tables), engine scenarios, recovery, API
└─ frontend/            Vite + React + TS dashboard
```
