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

## One-command install, several MT5 accounts (for the trader)

**Easiest for a non-technical person: send him the file [GoldCycle-Setup.bat](GoldCycle-Setup.bat).** He saves it
anywhere (Desktop, Downloads, USB) and double-clicks it, clicks **Yes** when Windows asks for permission, and answers
the numbered questions. It installs to `C:\GoldCycle` (no folder to choose, every PC has a C: drive) or, if GoldCycle
is already on that PC, updates it where it is. If the e-mail / browser blocks a `.bat`, send it zipped.
The command below does exactly the same thing from PowerShell.

1. Install **Exness MetaTrader 5** once (normal installer) and log in to any account.
2. Right-click **PowerShell** → **Run as administrator**, paste this line and press Enter:

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/CodeWithUmair/Gold-Cycle-Bot/main/scripts/setup.ps1 | iex
   ```

   The same line works on any PC, from any folder, and also **updates**: if GoldCycle is already installed on that PC
   (wherever it was put) it updates that install instead of making a second one.

   While the repo is **private** (the line above then fails), on a machine where git is already logged in to GitHub:

   ```powershell
   git clone https://github.com/CodeWithUmair/Gold-Cycle-Bot.git C:\GoldCycle\app
   powershell -ExecutionPolicy Bypass -File C:\GoldCycle\app\scripts\goldcycle.ps1 install
   ```

   It installs Python / Git / Node if missing, downloads GoldCycle to `C:\GoldCycle\app`, builds it, and asks for
   the first account. Only what is needed, and every choice is a **number**:
   real or demo account (1 / 2) → MT5 account number → server number (the number at the end of the server name, e.g.
   `8` for `Exness-MT5Real8`; Enter if none) → MT5 password (hidden) → dashboard password (Enter = same as the MT5 password).
   It then **logs the bot's MetaTrader in and tells you the result before saving anything**: wrong number, password or
   server is explained in plain words and you can retry or retype. The dashboard opens only when it is connected.
3. A second MetaTrader window opens: it is the bot's own MT5 (a clean copy, no charts and no other expert advisors).
   Leave it open or minimize it. **Algo Trading** (needed to send orders) is switched on for you; only if the setup
   says it could not, click that button once so it turns green.

Each account gets its own MT5 copy (`C:\GoldCycle\terminals\<name>`), settings, database and logs
(`C:\GoldCycle\accounts\<name>`), and dashboard (`http://127.0.0.1:8001`, `8002`, …; desktop shortcut
"GoldCycle <name>", where `<name>` is the account number). Bots start by themselves when Windows logs on.

The bot runs **hidden**: there is no black window to click, freeze or close by mistake. If it crashes it starts
again by itself within ~6 seconds, and an open dashboard page reconnects without refreshing or logging in again
(if the bot was running a trade it asks "Resume?" once; the trade keeps its TP/SL on the broker meanwhile).
What the bot prints goes to `C:\GoldCycle\accounts\<name>\logs\console.log`.

Everything else: double-click the **GoldCycle Manager** desktop shortcut. It shows the accounts and asks what to do:
**1** start the bot (MT5 opens by itself) · **2** stop the bot · **3** stop the bot **and** MT5 · **4** restart
everything · **5** add an account · **6** open the dashboard · **7** update.
No shortcut? Run `powershell -ExecutionPolicy Bypass -File C:\GoldCycle\app\scripts\goldcycle.ps1` (use the folder
GoldCycle was installed in). `goldcycle.ps1 <command>` (`start`, `stop`, `stop-mt5`, `restart`, `update`, …) does the
same from a terminal. Open trades stay on Exness with their TP/SL while the bot is stopped.

Accounts always send orders (a demo account trades demo money). A test-only practice mode that sends no orders still
exists: `goldcycle.ps1 mode <account number>` (trades then show in the dashboard but **not** in MT5 / Exness history).

The manual setup below still works for a single install (it reads the repo's `.env`).

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
| **Cycle** tab | Part One: trigger price, direction, lot, TP points, SL points (optional), cycle gap (used after an SL), stop price |
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
- TP hit → the next trade opens at once at that TP, with its SL at the previous entry.
- SL hit → the bot does **not** stop. It waits for price to return to the losing trade's entry (+ gap, if set) and opens that trade again.
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

Q1 is obsolete; Q2 and Q6 are answered (2026-11-16, [ADR-0018](docs/decisions/0018-cycle-rules-2026-11-16.md)). The Q2 switch stays in the Cycle tab's Advanced section. Q5 is the "TP/SL in points | price" toggle on the Single tab. Q6: after an SL the gap moves the re-entry in the selected direction (BUY 4000 → 4002).

| # | Question | Switch | Default |
|---|---|---|---|
| Q2 | Next trade's SL: entry − SL points, or the previous entry? **Answered: previous entry.** | `sl_mode` | `previous_entry` |
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
