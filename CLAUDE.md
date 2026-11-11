# CLAUDE.md — GoldCycle: MT5 Auto TP/SL Cycle Bot (XAUUSD)

> Put this file at the repo root. It is the single source of truth for this project.
> Read it fully before writing code. When something here is marked **OPEN QUESTION**, implement it as a config option with the stated default — do not block on it.

---

## 1. What we are building

A **Python trading bot for MetaTrader 5** (broker: **Exness**, symbol: **gold / XAUUSD**) with a **local web dashboard**.

The trader (client) decides *where* to trade. The bot's job is execution:
1. Watch the live price.
2. When price reaches the trader's level → open the trade automatically.
3. Attach TP and SL automatically.
4. In **Cycle mode**: when a trade closes, open the next trade automatically according to the cycle rules, until a stop price is reached or the trader stops it.

This is **not** a signal/strategy bot. It never decides direction on its own. It is an **automated TP/SL execution + cycle (ladder) engine**.

Two modes:

| Mode | Name in client's sheet | What it does |
|---|---|---|
| `SINGLE` | Part Two | One trade at a trigger price, TP/SL, then stop and wait for the next instruction. |
| `CYCLE` | Part One | Repeating chain of trades ("cycles") in one direction, moving the entry each cycle, until stop price / manual stop. |

---

## 2. Domain definitions (CONFIRMED with client)

- **Point = 1.00 of price.** `4000 → 4003` is **3 points**. This is NOT MT5's `symbol.point` (0.01 on gold). Internally: `price_delta = points * 1.0`. Keep a single constant/func `points_to_price(points)` so it can be changed in one place.
- **One trade open at a time.** A cycle's trade must be fully closed before the next cycle's trade opens. Never stack positions.
- **Cycle** = one trade from open to close. Example: Buy at 4000, TP 4003. When TP hits, cycle 1 is complete.
- Account: Exness MT5, Windows VPS already owned by client. Bot runs on that VPS.

---

## 3. Inputs (the "Bot Interface" from the client's sheet)

### CYCLE mode (Part One)
| Field | Type | Required | Notes |
|---|---|---|---|
| `trigger_price` | float | yes | "Market Position" — price where cycle 1 opens |
| `direction` | `BUY` \| `SELL` | yes | |
| `lot` | float | yes | Validate against `volume_min`, `volume_max`, `volume_step` |
| `tp_points` | float > 0 | yes | Can differ from SL (3, 4, 5, 6 …) |
| `sl_points` | float > 0 | yes | |
| `cycle_gap` | float ≥ 0 \| null | no | "Cycle Gape". Blank = continue from TP/SL price (see §4) |
| `stop_price` | float \| null | no | "Stop bot cycle at position" — bot stops cycling here |

### SINGLE mode (Part Two)
`trigger_price`, `direction`, `lot`, `tp_points`, `sl_points`. (TP/SL in points, same as cycle mode — **OPEN QUESTION Q5**: client may want exact prices; support both via a toggle `tp_sl_input: "points" | "price"`.)

---

## 4. Cycle engine — exact rules

### 4.1 Client's worked examples (use as acceptance tests)

BUY, tp=3, sl=3, gap=2:

| Cycle | Entry | TP | Next order | SL |
|---|---|---|---|---|
| C1 | 4000 | 4003 | 4003 | 4000 |
| C2 | 4002 | 4005 | 4005 | 4002 |
| C3 | 4004 | 4007 | 4007 | 4004 |

SELL, tp=3, sl=3, gap=2:

| Cycle | Entry | TP | Next order | SL |
|---|---|---|---|---|
| C1 | 4000 | 3997 | 3997 | 4000 |
| C2 | 3998 | 3995 | 3995 | 3998 |
| C3 | 3996 | 3993 | 3993 | 3996 |

Client's explanation of a cycle: *"C1 starts at 4000, TP 4003. When TP is reached, the new SL is set at 4000 — cycle 1 complete."* I.e. the next trade's SL sits at the previous entry.

### 4.2 Level computation (use PLANNED levels, not fill prices)

Keep the ladder clean: all TP/SL/next-entry levels are computed from the **planned** entry price, not the actual fill (fills slip by spread/slippage). Record the actual fill separately and show slippage in the UI.

```
sign = +1 for BUY, -1 for SELL
tp_price  = planned_entry + sign * tp_points
sl_price  = planned_entry - sign * sl_points
```

Config `level_anchor: "planned" | "fill"` (default `"planned"`).

### 4.3 Next entry after a cycle closes on TP

- **gap is blank/null** → next planned entry = previous TP price. Price is already there, so open immediately at market. (C1 TP 4003 → C2 entry 4003, TP 4006, SL 4000.)
- **gap is set** → next planned entry = previous planned entry + sign * gap. (4000 → 4002 → 4004.) Arm a trigger and open when price **touches** that level.

**CONFIRMED:** `cycle_gap` is a manual input set by the trader per session (any value, or blank). The UI must make it easy to set/change before arming.

> **OPEN QUESTION Q1:** In the gap example, C1 closes at TP 4003 but C2 enters at 4002, so C2 needs a 1-point pullback. Confirm that is intended. Implement as "wait for touch" (default). Add config `gap_entry_mode: "wait_for_touch" | "immediate"`.

> **OPEN QUESTION Q2:** SL of the next trade: `entry - sl_points` (default) or "previous cycle's entry" (`sl_mode: "points" | "previous_entry"`). With the client's 3/3 example both give the same number; they differ when tp ≠ sl. Implement both, default `"points"`.

### 4.4 When a cycle closes on SL

**CONFIRMED:** When SL is hit, **the bot stops.** No next cycle, no reversal. State → `STOPPED`, notify the trader (toast + log: "C{n} hit SL at {price}, bot stopped"), and wait for a new instruction. Do not build continue/reverse options.

### 4.5 Stop price

- BUY cycle: stop when price (bid) ≥ `stop_price`. SELL cycle: stop when price (ask) ≤ `stop_price`.
- On stop: **never open another cycle**; go to `STOPPED` and wait for the trader's next instruction.
- **CONFIRMED:** When price reaches `stop_price`, **close the open trade immediately** at market, then go `STOPPED`. Log the close reason as `STOP_PRICE`. If the close order is rejected, retry every tick until it closes, and alert the UI.
- Also stop the chain if the *next planned entry* would be beyond `stop_price`.

### 4.6 Trigger rule (when is the price "reached")

- Record price at arm time. If trigger is above current price → fire when price rises to ≥ trigger. If below → fire when price falls to ≤ trigger.
- BUY executes at ask, SELL at bid. Use **bid** for trigger detection by default (what the chart shows); config `trigger_price_side: "bid" | "ask" | "mid"`.
- **CONFIRMED:** If price is already past the trigger when the bot is armed, **do not enter.** Let it go and wait until price comes back and touches the trigger level, then start. No "enter now" option. Show "Waiting for price to return to {trigger}" in the UI.
- Add `max_slippage_points` (default 0.5). If the fill would slip beyond it, use MT5 `deviation`; if rejected, retry on the next tick while price is within tolerance, else log and wait for another touch.

### 4.7 Lot size

Same lot every cycle (no martingale). Keep a `lot_multiplier` config, default `1.0`, hidden from UI v1.

### 4.8 State machine

```
IDLE ──arm──▶ ARMED ──price touches trigger──▶ OPENING ──filled──▶ IN_POSITION
                                                   │                     │
                                                   └─rejected→ ARMED      │ position closed
                                                                         ▼
                                                                  RESOLVING (read deal reason: TP / SL / manual / stop-out)
                                                                         │
                         ┌──────────── TP: compute next entry ───────────┤
                         ▼                                               │ SL: stop
                   ARMED (next cycle) / OPENING (immediate)              │
                                                                         ▼
                                    STOPPED (SL hit, stop_price hit → close open trade, limits hit, manual stop, error)
```

- Every transition is persisted (see §7) and pushed to the UI.
- If a position is closed **manually** in MT5 by the trader → go `STOPPED` and notify. Never "fight" the trader.
- Cycle counter, per-cycle P/L, total session P/L tracked.

### 4.9 SINGLE mode

Same as CYCLE with `max_cycles = 1`: ARMED → OPENING → IN_POSITION → RESOLVING → IDLE. Reuse the same engine.

---

## 5. Safety limits (client didn't ask; build them, show in UI, all optional)

| Setting | Default | Behaviour |
|---|---|---|
| `max_cycles` | null (unlimited) | Stop after N cycles |
| `daily_loss_limit` (account currency) | null | Stop all + no new trades for the day |
| `max_spread_points` | 0.6 | Don't open if the current spread is wider; wait |
| `trading_hours` | null | Optional window; outside it → don't open new cycles |
| Kill switch | — | "Close all & stop" button + hotkey |

Also respect the broker's `trade_stops_level` / `trade_freeze_level`: if TP/SL are too close to the price, reject in the UI with a clear message before arming.

---

## 6. Tech stack & architecture

### Backend (Python 3.11+)
- `MetaTrader5` (official pip package). **Windows only**, needs the MT5 terminal installed and logged in.
- `FastAPI` + `uvicorn` — REST + WebSocket.
- `pydantic` v2 — config/validation.
- `SQLite` (via `sqlmodel` or plain `sqlite3`) — state + trade journal.
- `structlog` or std `logging` with JSON + rotating file logs.
- `pytest` — tests.

### Frontend
- **Vite + React + TypeScript**, built to static files and served by FastAPI (single process on the VPS).
- **TradingView `lightweight-charts`** (open-source) — live candlestick chart.
- **Framer Motion** — subtle fade/slide animations.
- Tailwind CSS. Dark theme by default.

### Critical MT5 rules
1. **The MetaTrader5 lib is not thread-safe.** ONE dedicated thread/task (the `Mt5Gateway`) owns every `mt5.*` call. Everything else talks to it through a queue/async interface.
2. The lib has no streaming. Poll `symbol_info_tick` every ~100 ms (configurable), and `positions_get` / `history_deals_get` on change.
3. **Symbol auto-detect:** Exness gold can be `XAUUSD`, `XAUUSDm`, `XAUUSDc`, etc. depending on account type. Find via `symbols_get("*XAU*USD*")`, let the user confirm in settings.
4. **Filling mode:** read `symbol_info().filling_mode` and choose FOK/IOC/RETURN accordingly. Don't hardcode.
5. Every order uses a fixed **`magic` number** + `comment` like `GC|cycle=3|session=abc`. The bot only ever touches positions with its magic number.
6. **TP and SL are set server-side on the position** (in the order request), so the broker protects the trade even if the bot/VPS dies.
7. Detect the close reason via `history_deals_get(position=ticket)` → `deal.reason` (`DEAL_REASON_TP`, `DEAL_REASON_SL`, `DEAL_REASON_CLIENT`, `DEAL_REASON_SO` …).
8. Auto-reconnect: if `terminal_info()` fails or the connection drops → pause the engine (no new orders), retry with backoff, resync positions, resume.
9. Validate lot (`volume_min/max/step`), and round prices to `symbol.digits`.

### Folder structure
```
goldcycle/
├─ CLAUDE.md
├─ README.md                 # setup + VPS deploy steps
├─ .env.example
├─ backend/
│  ├─ app/
│  │  ├─ main.py             # FastAPI app, serves frontend build
│  │  ├─ config.py           # pydantic settings (.env)
│  │  ├─ api/                # routes: auth, bot, settings, history
│  │  ├─ ws.py               # websocket hub (ticks, candles, state, logs)
│  │  ├─ broker/
│  │  │  ├─ base.py          # Broker protocol (interface)
│  │  │  ├─ mt5_gateway.py   # real MT5, single-threaded owner
│  │  │  └─ sim_broker.py    # simulated broker for tests/dev on Mac/Linux
│  │  ├─ engine/
│  │  │  ├─ models.py        # CycleConfig, CycleState, enums
│  │  │  ├─ levels.py        # pure functions: tp/sl/next-entry math
│  │  │  ├─ trigger.py       # touch/cross detection
│  │  │  ├─ cycle_engine.py  # state machine
│  │  │  └─ risk.py          # safety limits
│  │  ├─ storage/            # sqlite repo, persistence, recovery
│  │  └─ security.py         # auth, hashing, sessions
│  └─ tests/
│     ├─ test_levels.py      # client's tables from §4.1 as tests
│     ├─ test_cycle_engine.py
│     └─ test_recovery.py
└─ frontend/
   └─ src/ (components, hooks/useSocket.ts, pages/Dashboard.tsx, …)
```

**Broker abstraction is mandatory.** `cycle_engine` depends only on `broker/base.py`. `sim_broker` lets us develop and test locally on any OS with a replayed or random-walk price feed. Only `mt5_gateway` needs Windows.

---

## 7. Persistence & crash recovery

- SQLite tables: `sessions`, `cycles` (planned entry, fill, tp, sl, open/close time, close reason, pnl, slippage), `events` (state transitions), `settings`.
- On startup: load the last session. If the state was `IN_POSITION`, find the live position by magic number and reattach. If it closed while the bot was down, resolve it from deal history and continue per the rules (or go `STOPPED` if `resume_on_restart=false`, default **false**: on restart, show "Resume?" in the UI).
- Never open a duplicate trade after a restart. Idempotency: before opening, check that no bot position exists for this session.

---

## 8. Dashboard UI

Minimal, dark, smooth. Performance first: no heavy component libraries, and throttle WS updates to ~10/s for ticks.

**Layout (single page):**
- **Top bar:** connection status dot (MT5 / broker / WS), account balance, equity, symbol, spread, bot state badge (IDLE / ARMED / IN POSITION / STOPPED), animated on change.
- **Left (main): live chart** (lightweight-charts), M1 default with a timeframe switcher. Overlay horizontal lines: trigger (dashed), current entry, TP (green), SL (red), next planned entry (faint), stop price (amber). Markers for each cycle open/close.
- **Right panel, tabs "Cycle" | "Single":** the input form from §3, with live validation (stops level, lot step, TP/SL distance in points and price), and a **Preview ladder** showing the next 5 planned cycles computed from the inputs before arming. Buttons: **Arm**, **Stop after this cycle**, **Stop now**, **Close all & stop** (red, confirm modal).
- **Bottom: cycle journal table:** cycle #, dir, planned entry, fill, slippage, TP, SL, result (TP/SL/manual), P/L, duration. Running session P/L.
- **Log drawer:** human-readable event log ("C3 armed at 4004.00", "TP hit +$3.00").
- Toasts for fills, TP/SL hits, errors, disconnects.
- Fade/slide-in on load, number tickers for P/L, a pulse on the state badge. Respect `prefers-reduced-motion`.

---

## 9. Security

- The dashboard binds to **127.0.0.1 only** by default. The client uses it via RDP on the VPS. Optional remote access later via Tailscale. **Never expose the port publicly.**
- Login: single admin user, password hashed with argon2/bcrypt, httpOnly + SameSite=strict session cookie, login rate limit.
- MT5 login/password/server live in `.env` only (gitignored). Never sent to the frontend, never logged.
- All arm/stop/close actions are POST with CSRF protection; destructive actions need confirmation.
- Validate every input server-side with pydantic (never trust the UI).
- Audit log of every user action in SQLite.
- `.gitignore`: `.env`, `*.db`, `logs/`, `node_modules/`, `dist/`.

---

## 10. Testing

1. **Unit:** `levels.py` must reproduce the client's tables in §4.1 exactly (BUY + SELL, gap 2, and gap blank).
2. **Engine:** with `sim_broker`, scripted price paths: TP chain ×3, SL hit → bot stops, stop price mid-cycle → open trade closed + bot stops, price already past trigger at arm → no entry until it returns, manual close, spread too wide, rejected order, restart during IN_POSITION.
3. **Demo:** run on the Exness **demo** account on the VPS for at least a full trading session before live. Keep a `DRY_RUN=true` flag that logs intended orders without sending them.
4. A `/health` endpoint plus a simple "test connection" button in the UI.

---

## 11. Build order (ship each phase working)

1. Scaffold repo, config, logging, `Broker` interface, `sim_broker`, `levels.py` + tests.
2. `cycle_engine` state machine on `sim_broker` with full tests (SINGLE then CYCLE).
3. `mt5_gateway` (connect, symbol detect, tick polling, order send, deal reasons, reconnect).
4. Persistence + crash recovery.
5. FastAPI REST + WebSocket.
6. Frontend: chart + form + preview ladder + journal + controls.
7. Auth/security hardening.
8. Windows VPS deploy: README with Python + Node install, `npm run build`, run as a service via **NSSM** (or Task Scheduler at boot), MT5 terminal auto-start with auto-login.

---

## 12. Open questions to confirm with the client (track here, update when answered)

| # | Question | Current default |
|---|---|---|
| Q1 | With a gap set, after C1 TP at 4003, does C2 wait for a pullback to 4002, or open immediately? | wait_for_touch |
| Q2 | Next trade's SL: entry − sl_points, or the previous entry? | points |
| Q5 | Part Two TP/SL as points or exact prices? | points (toggle available) |

Confirmed:
- Point = 1.00 price; one trade at a time; Python; MT5; Exness; Windows VPS.
- Gap is a manual input set by the trader.
- SL hit → bot stops (no continue, no reverse).
- Stop price reached → close the open trade immediately, then stop.
- Price already past the trigger at arm time → don't enter; wait for price to come back to the trigger, then start.

---

## 13. Coding rules

- Type hints everywhere; `mypy`/`ruff` clean.
- Engine math in pure functions (no I/O) so it is fully testable.
- No `mt5.*` calls outside `mt5_gateway.py`.
- No silent excepts: every failure is logged and surfaced to the UI.
- Prices rounded to symbol digits before sending.
- Keep it simple. No features beyond this spec without asking.
