# HANDOFF — GoldCycle Project Log

Read this first. It's the running history of the project: what exists, what happened in each
session, what was decided, and where the next session starts. Append a new session at the bottom
(template at the end). Never rewrite old sessions; they are the history.

## Project at a glance

| | |
|---|---|
| **What** | Python bot for MetaTrader 5 (Exness, gold) that **executes** the trader's levels: opens at a trigger price, attaches TP/SL, and in Cycle mode chains the next trade automatically until SL / stop price / manual stop. It never picks direction. |
| **Spec (source of truth)** | [CLAUDE.md](CLAUDE.md). Rules, client's worked examples, open questions. |
| **Stack** | FastAPI + asyncio engine + SQLite · official `MetaTrader5` package (Windows) · Vite/React/TS + Tailwind + lightweight-charts + framer-motion |
| **Where it runs** | Client's Windows VPS, next to a logged-in MT5 terminal. Dashboard on `http://127.0.0.1:8000` via RDP only. |
| **Status** | ✅ All 8 build phases from CLAUDE.md §11 done. ✅ Live-tested on an Exness **demo**. ⏳ Waiting on client answers (Q1/Q2/Q5) and the full-session demo run before live. |

### Document map

| File | Use it for |
|---|---|
| [README.md](README.md) | Install, run, VPS deploy, troubleshooting |
| [GLOSSARY.md](GLOSSARY.md) | Trading + MT5 terms (client "point" vs MT5 point, magic, filling, deal reason…) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Module map, threading, state machine internals, DB schema, REST + WS reference |
| [docs/TESTING.md](docs/TESTING.md) | Test matrix vs spec §10, harness, live demo test procedure |
| [docs/decisions/](docs/decisions/README.md) | ADR-0001…0017: every design choice the spec left open, with reasons |
| [docs/BACKLOG.md](docs/BACKLOG.md) | Next work, known limitations, things not to build |
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | Dashboard walkthrough for the trader (+ a demo-video script) |

### Two other gold bots in this repo — don't confuse them
`d:\mine\Bots\gold_bot` and `d:\mine\Bots\aureum` are **signal/strategy** bots (they pick direction).
GoldCycle is an **execution** bot for a client who picks the levels. They share no code. The
repo-root `d:\mine\Bots\CLAUDE.md` is the original copy of this project's spec.

---

## Session 1 — 2026-11-11 — initial build, phases 1–8, first live demo test

### State before
An empty folder and the spec (CLAUDE.md). No code.

### What was built (in spec build order, each phase tested before the next)

| Phase | Result | Key files |
|---|---|---|
| 1 Scaffold, config, logging, Broker interface, sim broker, level math | ✅ client's §4.1 tables pass as tests | `config.py`, `logging_setup.py`, `broker/base.py`, `broker/sim_broker.py`, `engine/levels.py`, `engine/trigger.py`, `engine/risk.py`, `engine/models.py` |
| 2 Cycle engine state machine (SINGLE then CYCLE) | ✅ all §10.2 scenarios | `engine/cycle_engine.py` |
| 3 MT5 gateway | ✅ live-verified on demo (see findings) | `broker/mt5_gateway.py` |
| 4 Persistence + crash recovery | ✅ restart/resume tests | `storage/repo.py`, `cycle_engine.recover/resume` |
| 5 FastAPI REST + WebSocket | ✅ API tests + HTTP/WS smoke on sim | `main.py`, `api/*.py`, `ws.py`, `context.py` |
| 6 Frontend | ✅ type-checks, builds, served by FastAPI | `frontend/src/**` |
| 7 Auth / security | ✅ login, CSRF, rate limit, audit | `security.py`, `api/auth.py` |
| 8 VPS deploy | ✅ written, ⚠️ scripts not yet run on a VPS | `README.md`, `.env.example`, `scripts/*.bat` |

**Added later in the session, at the user's request (beyond the original spec):**

| Item | Result | Files |
|---|---|---|
| **Reports / analytics** view (top bar → Reports): KPI tiles (net P/L, win rate, profit factor, avg win/loss, expectancy, max drawdown, best/worst, streaks), cumulative P/L chart, daily P/L bars, close-reason breakdown, execution quality, sessions table that expands to cycles, range filter, CSV export | ✅ tested (`test_reports.py`) | `app/reports.py`, `app/api/reports.py`, `repo.cycles_since/sessions_since`, `frontend/src/pages/Reports.tsx`, `components/charts.tsx` |
| "How do I start another cycle?" guidance: How-it-works steps before the first session, a "Last session ended → edit and Arm" card, and a one-session-at-a-time note while running | ✅ | `ControlPanel.tsx` |
| User guide + demo-video script | ✅ | `docs/USER_GUIDE.md` |
| Chart colours for gain/loss validated with the dataviz palette validator (dark surface): `#1ea672` / `#e5534b`; colorblind ΔE 6.2, so polarity is also encoded by position + signed values | ✅ | `components/charts.tsx` |

Quality gates at end of session: **47/47 pytest**, **mypy --strict clean**, **ruff clean**,
`npm run build` clean (TS 7, Vite 8).

### Findings / problems hit (and how each was resolved)

#### Finding #1 — 🔴 MT5 "Authorization failed (-6)": the saved demo account was dead
`mt5.initialize()` failed even bare. The **terminal's own log** (`%APPDATA%\MetaQuotes\Terminal\<id>\logs\YYYYMMDD.log`)
said `authorization on Exness-MT5Trial16 failed (Invalid account)`. Exness had deleted the old
demo, but the terminal title still showed it. **Fix:** the user opened a new demo ("Gold Cycle Bot",
Exness-MT5Trial15, hedging, USD 500). **Lesson:** for -6, read the terminal log first; it's not a code bug.

#### Finding #2 — 🟡 Exness gold symbol is `XAUUSDm`; `XAUUSD247m` has zero prices
Auto-detect (`*XAU*USD*`) returned both. The 24/7 variant had `bid=ask=0`. **Fix:**
[ADR-0014](docs/decisions/0014-zero-price-is-disconnect.md): a zero tick = "no price" (engine pauses).
Auto-detect prefers XAUUSD → XAUUSDm → XAUUSDc → XAUUSDz. The local `.env` pins `SYMBOL=XAUUSDm`.
Spec on this account: 3 digits, point 0.001, lot 0.01–200 step 0.01, stops/freeze level 0,
contract 100, market execution, filling bitmask 3 (FOK+IOC; RETURN rejected with 10030).

#### Finding #3 — ⚪ "filling 0" in a probe looked like a bug but wasn't
`ORDER_FILLING_FOK == 0`. The gateway was already choosing FOK. Documented in
[ADR-0012](docs/decisions/0012-mt5-single-thread-executor.md) so nobody "fixes" it.

#### Finding #4 — 🟡 Blank `MT5_LOGIN=` in `.env` crashed startup
pydantic can't parse `""` as int. **Fix:** `Settings._blank_is_none` turns blank optional fields into None.

#### Finding #5 — ⚪ Spec ambiguities resolved by design decisions
Touch semantics, rejected-order flow, stop price before the first fill, no CLOSING state, close-reason
inference, SINGLE end state, Stop now vs Close all, idempotency, restart model, daily-loss definition,
DRY_RUN meaning. Each one is an ADR in [docs/decisions/](docs/decisions/README.md) (0002–0011, 0013).

#### Finding #6 — ⚪ Test-only: Starlette TestClient WS connects to `ws://testserver`
Cookies set for `127.0.0.1` weren't sent, so the WS was rejected with 4401. Tests use the full URL
`ws://127.0.0.1/ws`. This was not an app bug.

### Live demo test (real orders, Exness demo, 0.01 lot, magic 7799001)
Script: [backend/tools/live_demo_test.py](backend/tools/live_demo_test.py) (refuses non-demo accounts).

| Scenario | Result |
|---|---|
| SINGLE BUY, trigger 4042.82, TP 1 / SL 1 | ✅ touched at 4042.80 → filled 4043.045 (slip +0.22 = spread, BUY fills at ask) → **server-side** TP 4043.82 / SL 4041.82 on the position → closed by broker, deal reason **TP** → +0.77 USD → IDLE `COMPLETE`. |
| CYCLE BUY gap blank, TP 0.6 / SL 2, stop +1.5, max 3 | ⏳ armed at 4044.13, waiting for price (result to be added below) |
| Kill switch on an open position | ⏳ pending |

### How to run everything
```powershell
# backend tests / checks
cd goldcycle\backend
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -m mypy app tests
.\.venv\Scripts\python.exe -m ruff check app tests
# frontend build (FastAPI serves frontend\dist)
cd ..\frontend; npm run build
# run the app (reads goldcycle\.env)
cd ..\backend; .\.venv\Scripts\python.exe -m app.main     # http://127.0.0.1:8000
# live demo order test (demo account only)
.\.venv\Scripts\python.exe tools\live_demo_test.py single cycle kill
```
Local dev `.env` (gitignored) at end of session: `BROKER=mt5`, `DRY_RUN=true`, `SYMBOL=XAUUSDm`,
an admin password hash for user `admin` (the password was given to the user in chat; regenerate with
`python -m app.security` if lost).

### ⚠️ NOT done yet — next session starts here
1. Record the CYCLE and kill-switch live results in the table above (or rerun the script).
2. Client answers Q1/Q2/Q5 → [BACKLOG B1](docs/BACKLOG.md).
3. Full-session demo run with `DRY_RUN=false` on the client's VPS → B2, B4.
4. DRY_RUN shows a paper balance, not the real one → B7.
5. Everything else: [docs/BACKLOG.md](docs/BACKLOG.md).

### Decisions made
ADR-0001 … ADR-0017, all **Accepted** 2026-11-11. Index: [docs/decisions/README.md](docs/decisions/README.md).
The most important ones for anyone changing the engine:
- Levels come from the **planned** entry; the fill is only recorded (spec §4.2). `level_anchor=fill` is the opt-in.
- Bot never enters at the moment of arming ([0002](docs/decisions/0002-touch-trigger-semantics.md)).
- Never opens while any bot-magic position exists ([0009](docs/decisions/0009-idempotency-and-attach.md)).
- No `mt5.*` outside `mt5_gateway.py`, one worker thread ([0012](docs/decisions/0012-mt5-single-thread-executor.md)).

### Open items (client)
| # | Question | Current default |
|---|---|---|
| Q1 | With a gap, after C1 TP at 4003, does C2 wait for a pullback to 4002 or open immediately? | wait_for_touch |
| Q2 | Next trade's SL: entry − sl_points, or the previous entry? | points |
| Q5 | Part Two TP/SL as points or exact prices? | points (toggle in Single tab) |

---

## Template for the next session

```markdown
## Session N — YYYY-MM-DD — <one-line goal>

### State before
What was true at the start (link the previous session's "NOT done yet").

### What was done
| Item | Result | Files |
|---|---|---|

### Findings
#### Finding #1 — 🔴/🟡/⚪ <title>
What happened, evidence, fix, lesson.

### Live / demo results
Scenario table, if any trading was done (account type, lot, magic).

### Files changed
### ⚠️ NOT done yet — next session starts here
### Decisions made
New ADRs (number + title). Superseded ADRs.
### Open items (client)
```
