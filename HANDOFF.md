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
| **Status** | ✅ All 8 build phases from CLAUDE.md §11 done. ✅ Client's new cycle rules (ADR-0018, 2026-11-16) **live-tested with real orders on demo** (Session 2). ✅ Running on the client's VPS (DRY_RUN) with the ADR-0018 code. ⏳ Next: auto-start, full-session demo run with `DRY_RUN=false`, client answer Q5 (Session 2 → "NOT done yet"). |

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
| Clearer typography: self-hosted Inter + JetBrains Mono, bigger small text; hand cursor on every clickable control | ✅ | `index.css`, `main.tsx` |
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
| CYCLE BUY gap blank, TP 0.6 / SL 2, stop +1.5, max 3 | ✅ partial: waited ~15 min for the touch → touched at 4044.35 (price jumped 0.22 over the 4044.13 level, inside the 0.5 tolerance) → filled 4044.59 (slip +0.46 = jump + 0.24 spread) → server TP 4044.73 / SL 4042.13. The test's 15-min wait expired 12 s after the fill, so the **TP→C2 chain and the stop-price close were not observed live** (both are covered by sim tests). |
| Kill switch on an open position | ✅ the C1 above was closed by `close_all_and_stop` on the real server → journal `KILL_SWITCH` −0.07 → STOPPED → **0 bot positions left**. (The separate kill scenario couldn't arm because C1 was still open; the bot correctly refused with "already running".) |

#### Finding #7 — 🟡 Small TPs get eaten by spread + slippage (seen live)
TP/SL come from the **planned** entry (spec §4.2). A BUY triggers on bid but fills at ask, and a fast
tick can jump past the level. Live: planned 4044.13 → fill 4044.59 → TP 4044.73 = only **0.14 pts** of
room on a 0.6-pt TP. **Fix:** the form now warns when `tp_points ≤ 2 × (spread + max_slippage)`.
**For the client:** keep TP comfortably above ~1 pt on XAUUSDm, or use `level_anchor=fill`.
The test script now uses TP 1.5 and kill-switches a timed-out cycle instead of colliding with the next scenario.

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
1. Observe the **TP→C2 chain and a stop-price close live** on demo (rerun `tools\live_demo_test.py cycle`,
   or run a DRY_RUN=false session from the dashboard). Everything else is live-verified.
2. Client answers Q5 → [BACKLOG B1](docs/BACKLOG.md). (Q1/Q2/Q6 answered 2026-11-16, cycle rules changed: [ADR-0018](docs/decisions/0018-cycle-rules-2026-11-16.md).)
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
| Q5 | Part Two TP/SL as points or exact prices? | points (toggle in Single tab) |

---

## Session 2 — 2026-11-11 → 2026-11-16 — local run, VPS install, live test of the new cycle rules

### State before
Session 1 left the bot fully built, plus a commit with the client's new rules ([ADR-0018](docs/decisions/0018-cycle-rules-2026-11-16.md),
`b18dd4e`, pulled this session): **after TP** the next trade opens at once at the previous TP with SL at the previous
entry; **after SL** the bot no longer stops but re-arms the losing trade at its entry (+ gap in the trade direction);
**SL is optional** in CYCLE mode. Session 1's open item "observe TP→C2 and a stop-price close live" was still open.

### What was done
| Item | Result | Files |
|---|---|---|
| Local setup on this PC (Python 3.14, Node 22): venv, `npm ci`, build, `.env` | ✅ 52/52 pytest, mypy clean (33 files), ruff clean, `npm run build` clean | `.env` (gitignored) |
| **Installed on the client's Windows VPS** (step-by-step with the user over RDP) | ✅ Running, connected to MT5, `DRY_RUN=true`; **updated to `b18dd4e`** on 2026-11-16 (`git pull` → `install.bat` → `start.bat`, re-login, WS accepted) | see "VPS state" below |
| Dry-run tests on live prices, old rules (2026-11-12) | ✅ TP chain C1→C2→C3, SL stop, stop-price close, kill switch, touch trigger. The SL-stop result is superseded by ADR-0018 | — |
| Pulled `b18dd4e` (ADR-0018) and reviewed the engine diff | ✅ Matches the ADR | — |
| **Live test of ADR-0018 with real orders** on Exness demo | ✅ All 4 scenarios pass, see below | `backend/tools/live_demo_test.py` (+ `chain slretry slgap nosl`) |
| Client explainer PDF (English, 2 pages) | ✅ Regenerated for ADR-0018: TP chain with SL at previous entry, SL retry table (gap blank / 2), optional SL, "set a limit" warning | `docs/GoldCycle-How-It-Works.pdf` (untracked) |
| Test docs | ✅ New scenarios listed | `docs/TESTING.md` §4 |

### Live / demo results (real orders, 2026-11-16)
Account **474902598 "Gold Cycle Bot"**, Exness-MT5Trial15, demo, hedging, USD 500.70 → **496.10**. XAUUSDm, 0.01 lot,
magic 7799001. Command: `.\.venv\Scripts\python.exe tools\live_demo_test.py chain slretry slgap nosl`.
**Balance change −4.60 = sum of the 9 journal P/Ls exactly.** 0 bot positions left.

| Scenario | What happened (TP/SL read back from the **server position**) | Result |
|---|---|---|
| `chain` BUY TP 2 / SL 3, max 3 | C1 3868.93 (SL 3865.93) → **TP** +2.10 → C2 opened at once at **3870.93**, server SL **3868.93 = C1 entry** → **TP** +1.84 → C3 planned 3872.93: price had jumped to 3873.52 (> 0.5) → waited for another touch → filled, SL **3870.93 = C2 entry** → SL −2.14 → **not stopped by the SL**; stopped by MAX_CYCLES | ✅ |
| `slretry` BUY TP 4 / SL 1, gap blank, max 3 | C1 3870.49 SL → "C2 armed at 3870.49" → touch → **same** TP 3874.49 / SL 3869.49 → SL → C3 same again → SL → MAX_CYCLES | ✅ |
| `slgap` BUY TP 4 / SL 1, gap 1, max 2 | C1 3869.49 SL → "C2 armed at **3870.49**" (+1, BUY up) → touch ~14 min later → TP 3874.49 / SL 3869.49 → SL → MAX_CYCLES | ✅ |
| `nosl` BUY TP 5, SL blank | Server position **SL 0.0** (Exness accepts no SL), TP 3874.57 → kill switch closed it | ✅ |

### Findings
#### Finding #1 — 🟡 Fill slippage can be max_slippage + spread (seen live: +0.63 with max 0.5)
`slgap` C2: bid first seen at 3870.88, 0.39 past the 3870.49 level (inside 0.5) → BUY filled at the ask 3871.12 →
slip +0.63. This is by design ([ADR-0003](docs/decisions/0003-opening-retry-and-tolerance.md)): the tolerance is measured
on the trigger-side price (bid), and a BUY then pays the spread (~0.24). Not changed. If the client expects "0.5 max
on the fill", measure BUY on the ask → would need an ADR. Related: Session 1 Finding #7 (small TPs).

#### Finding #2 — 🟡 SL retry keeps losing in a one-way market; limits are the only brake
`slretry` lost 3 × ~1.1 in 4 minutes. This is ADR-0018 working as specified, but **live, the trader must set at least
one of max cycles / daily loss limit / stop price** (retries count as cycles). Say this clearly when handing over.

#### Finding #3 — 🔴→fixed by user: local MT5 was on a deleted demo
This PC's terminal was on 472611148 @ Exness-MT5Trial16 (`Invalid account` in the terminal log, `-6` in Python), same
as Session 1 Finding #1. The user pointed to 474902598 @ Trial15; `mt5.initialize()` attached to it.

#### Finding #4 — ⚪ VPS install snags (all solved, worth knowing for the next install)
- PowerShell **QuickEdit**: a click in the window shows "Select …" in the title and **pauses** the command (looked like
  Node/MT5 hangs). Press Esc; turn QuickEdit off in Properties.
- A first `install.bat` run was interrupted → venv without pip ("No module named pip"). Fix: delete `backend\.venv`, rerun.
- Repo is private: clone with a **fine-grained read-only token for this repo only** (not a full GitHub login on the
  client's machine). Git Credential Manager stores it, so `git pull` works.
- Python 3.14 works: `MetaTrader5 5.0.6231` has a cp314 wheel.

#### Finding #5 — ⚪ Algo Trading was off in both terminals
Local: toggled on with Ctrl+E for the live test, then **back off**. VPS: off (DRY_RUN didn't need it). Must be on for
`DRY_RUN=false`. The VPS chart also has another EA attached (`Pending_Order_Repeater_Gape_Eight`): **remove it before
turning Algo Trading on**, or it trades the same account.

### VPS state (client's Windows Server, RDP, user `Administrator`)
| | |
|---|---|
| Bot folder | `C:\Users\Administrator\Desktop\Bot` (git clone of this repo, `main` at **`b18dd4e`**, ADR-0018 rules). Session 2's tool/doc changes reach it only after they are pushed + `git pull` |
| Installed | Python 3.14.0 (all users, PATH), Node 22.20.0, Git 2.51.0, VS Code |
| MT5 | Exness terminal, account **474462104** @ Exness-MT5Trial15 (demo, hedge) — a different demo from the local one |
| `.env` | `BROKER=mt5`, `DRY_RUN=true`, `SYMBOL=XAUUSDm`, admin hash set by the user (password known only to the user) |
| Runs | `cmd /c ...\scripts\start.bat` in a PowerShell window (verified: "MT5 connected: login=474462104", dashboard on 127.0.0.1:8000) |
| Auto-start | ✅ Created 2026-11-16: Startup shortcut `MT5.lnk` → `C:\Program Files\MetaTrader 5 EXNESS\terminal64.exe`, and scheduled task **`GoldCycle`** (`/SC ONLOGON` → `scripts\start.bat`). `schtasks /Run /TN GoldCycle` verified: the bot starts in its own `cmd.exe` window (don't close it). **A real reboot is not tested yet.** NSSM not used: a service can't reach the MT5 GUI session |

### Files changed
`backend/tools/live_demo_test.py` (new scenarios), `docs/TESTING.md` (§4), `HANDOFF.md`. Untracked:
`docs/GoldCycle-How-It-Works.pdf` (client explainer, ADR-0018 rules). Local `.env`: `BROKER=mt5`, `DRY_RUN=true`, `SYMBOL=XAUUSDm`.

### ⚠️ NOT done yet — next session starts here
1. ✅ Done 2026-11-16: VPS updated to `b18dd4e`. To update again later (RDP, PowerShell, Ctrl+C in the bot's window
   first): `cd C:\Users\Administrator\Desktop\Bot; git pull; cmd /c scripts\install.bat; cmd /c scripts\start.bat`,
   then **Ctrl+F5** in Chrome and log in again. Sessions are in memory, so an open tab logs `WebSocket /ws 403`
   until it logs in again. That's expected.
2. On the VPS: `cd backend; .\.venv\Scripts\python.exe tools\live_demo_test.py chain slretry slgap nosl` with Algo
   Trading **on** and the other EA **removed** (or skip this step and go to 3).
3. Auto-start is set up (Session 2 "VPS state"). Still to do: reboot the VPS once and check that MT5 and the bot come
   back by themselves after logon. Close RDP with X, never Sign out. To restart the bot by hand: `schtasks /Run /TN GoldCycle`.
4. Full trading session on the VPS demo with `DRY_RUN=false`, set limits (Finding #2) → BACKLOG B2, B4.
5. Client answer Q5 → BACKLOG B1. Still open from Session 1: B7 (DRY_RUN shows a paper balance).

### Decisions made
None new. ADR-0018 (pulled, written outside this session) is now live-verified.

### Open items (client)
| # | Question | Current default |
|---|---|---|
| Q5 | Part Two TP/SL as points or exact prices? | points (toggle in Single tab) |
| — | Is "max slippage 0.5" meant on the fill (incl. spread) or on the trigger price? (Finding #1) | trigger price (ADR-0003) |

---

## Session 3 — 2026-11-18 — free stop price, Cycle + Single side by side, two-order cycle

### State before
Session 2 "NOT done yet" unchanged. Client asked for two rule changes.

### What was done
| Item | Result | Files |
|---|---|---|
| **Stop price is free**: removed "BUY stop must be above trigger / SELL below". Stop above the trigger fires when price rises to it, below when it falls to it (bid for BUY, ask for SELL). Only stop == trigger is rejected | ✅ tests: either side, BUY stop below trigger closes the trade | `engine/models.py`, `engine/levels.py` (`beyond_stop`/`stop_reached` take the cfg), `risk.py`, `cycle_engine.py` |
| **Cycle and Single run at the same time**: two `CycleEngine`s (`mode=CYCLE` magic `MAGIC`, `mode=SINGLE` magic `MAGIC+1`), so each one's duplicate guard only sees its own trades. Sessions recover per mode. Logs are prefixed `[Cycle]` / `[Single]` | ✅ engine test (both positions open at once), API test (both armed, stop one, close-all both) | `main.py`, `context.py` (`engines`), `api/bot.py` (`?mode=` on stop / stop-after-cycle / resume / close-all; close-all without mode = both), `ws.py` (latest state per mode), `storage/repo.py` |
| UI: tabs switch between two always-mounted panels (separate saved forms), green dot on a running tab, two state badges in the top bar, chart + journal follow the selected tab. Ctrl+Shift+K closes **both**; the panel button closes that tab's bot | ✅ `tsc`, `npm run build` | `Dashboard.tsx`, `ControlPanel.tsx`, `TopBar.tsx`, `useSocket.ts`, `api.ts`, `types.ts` |
| Started MT5 (474902598 @ Exness-MT5Trial15) + bot locally, DRY_RUN | ✅ `/health` → both engines IDLE | — |
| **Two-order cycle** (client, replaces ADR-0018's ladder; CLAUDE.md §4.1): order 1 = entry + TP, no SL → on TP order 2 opens at once at that TP, SL = order 1's entry, no TP → after order 2's SL the next cycle re-arms at the entry (+ gap). `sl_points` and `sl_mode` dropped from CYCLE. Engine tracks `leg` (1/2, persisted, recovered); journal column `cycles.leg` (auto-migrated); comment `GC|c=3.2|session=…`; labels C3.1 / C3.2 | ✅ sim tests rewritten for the client's tables (BUY gap blank, BUY gap 2, SELL gap 2), stop price, max cycles, recovery, reports. Paper run on live prices: see below | `engine/levels.py`, `cycle_engine.py`, `models.py`, `risk.py`, `storage/repo.py`, `reports.py`, ControlPanel (no SL field in Cycle, preview shows both orders), Journal / Reports / chart labels |

Quality gates: **51/51 pytest** (old ladder tests replaced), mypy clean, ruff clean, frontend build clean.

### Findings
#### Finding #1 — ⚪ Daily loss limit is account-wide
`realized_pnl_since` sums both bots' cycles, and the daily block stops both. Intended (it's a loss limit on the account).

#### Finding #2 — 🟡 Magic number change for Single
Single trades now use `MAGIC+1`. A Single position opened **before** this update (with `MAGIC`) would be seen by the Cycle bot's guard. Close any open bot trade before updating the VPS.

#### Finding #3 — 🟡 Order 1 has no SL, order 2 has no TP
By design (client). Order 1 can sit in a loss with nothing closing it but the stop price, the daily loss limit or
Stop; order 2 can run in profit with only its SL (at the entry, i.e. break-even minus spread) and the stop price to
close it. Tell the trader to set a stop price and/or daily loss limit. A cycle that ends on order 2's SL nets about
minus the spread paid on both orders: order 1 wins TP − spread, order 2 (BUY fills at the ask) loses TP + spread.
Seen in the paper run below: +0.51 / −0.99 on TP 0.6.

### Live / demo results
Paper run (DRY_RUN fills) on **live** XAUUSDm prices, CYCLE BUY, TP 0.6, gap blank, max 2 cycles:

| Order | Planned | TP | SL | Result |
|---|---|---|---|---|
| C1.1 | 3758.83 | 3759.43 | none | TP +0.51 |
| C1.2 | 3759.43 (at once) | none | 3758.83 | SL −0.99 |
| C2.1 | 3758.83 (re-armed, touch) | 3759.43 | none | TP +0.11 |
| C2.2 | 3759.43 | none | 3758.83 | SL −1.00 → MAX_CYCLES |

Order comment on the position: `GC|c=1.2|session=83b1034d`. Real-order run on demo still to do.

### ⚠️ NOT done yet — next session starts here
1. Update the VPS (close bot trades first, Finding #2), then test both tabs on demo, Cycle with real orders.
2. `tools/live_demo_test.py` scenarios `chain slretry slgap nosl` were written for the ADR-0018 ladder; rewrite them for the two-order cycle before using them.
2. Session 2 items 2–5 still open.

### Decisions made
Client rules 2026-11-18 recorded in CLAUDE.md §4.5 and §12 (no separate ADR).

### Open items (client)
| # | Question | Current default |
|---|---|---|
| Q5 | Part Two TP/SL as points or exact prices? | points (toggle in Single tab) |

---

## Session 4 — 2026-11-19 → 2026-11-20 — VPS updated, optional TP/SL in Single

### State before
Session 3 pushed (`7b3aee2`, `986766a`). VPS still on `b18dd4e`.

### What was done
| Item | Result | Files |
|---|---|---|
| **VPS updated** to `986766a` (`git pull` → `install.bat` → `start.bat`) | ✅ MT5 connected 474462104, dashboard up. Hang was QuickEdit again (Session 2 Finding #4): title "Select …" pauses the console and the server blocks on its next log write, so the site keeps loading. Esc fixes it; turn QuickEdit off | — |
| **Single: TP and SL optional** (client): both / TP only / SL only / none, points or exact prices. Exact prices are checked per field (BUY TP above / SL below the trigger, SELL the reverse). Neither set → warning "stays open until you close it". CYCLE still requires TP | ✅ `tests/test_single_optional_tp_sl.py` (config combos, each engine case, kill switch, manual close, daily loss, restart reattach) + API test | `engine/models.py`, `levels.py`, `risk.py`, `cycle_engine.py`, `ControlPanel.tsx` |
| Edge-case hardening found on the way | ✅ tested | see Findings |
| **No cycle terms in Single** (client): "Stop after this cycle" only in the Cycle tab; Single journal/logs say "Trade" (not C1), "Trade journal", "Trade ended" | ✅ build | `ControlPanel.tsx`, `Journal.tsx`, `Dashboard.tsx`, `Reports.tsx`, `ui.tsx`, `cycle_engine.py` (`_c`) |
| **Live account balance** (client, "like Exness"): DRY_RUN top bar now shows the connected MT5 account's balance/equity (+ paper P/L on top) instead of the simulator's 10,000. Polled every 0.3 s (was 1 s); balance/equity flash green/red on change; new "Floating P/L" stat | ✅ `tests/test_dry_run_account.py` | `sim_broker.py`, `cycle_engine.py`, `TopBar.tsx`, `ui.tsx` |
| **"How it works" → ⓘ button + popup** (client) instead of the always-visible box. `Modal` now portals to `body` (a transformed ancestor traps `fixed`) | ✅ build | `ControlPanel.tsx`, `ui.tsx` |
| **Single "Buy/Sell now at market"** (client): two one-click buttons side by side, Sell (bid) and Buy (ask), like Exness, both with the form's TP/SL (shown above them). With exact prices the button whose direction doesn't fit is disabled with the reason as tooltip; picking a TP/SL on the chart also sets the direction. `CycleConfig.enter_now` (SINGLE only). On arm the engine replaces `trigger_price` with the live price (trigger side), re-validates exact TP/SL against it, goes straight to OPENING and opens on the same tick. Spread/hours limits still apply (waits in OPENING); if price then drifts past max slippage it falls back to "wait for price to return" like any trigger. §4.6's "no enter now" still holds for CYCLE | ✅ `tests/test_enter_now.py` (5) + live paper: SELL opened at once at 3585.01, TP/SL from that price | `models.py`, `risk.py`, `cycle_engine.py`, `ControlPanel.tsx` |
| **Pick TP/SL on the chart** (client, Single): "chart" button by TP/SL → click the chart → price goes into the field (switches to exact prices, converts the other field from points). Esc cancels. The form's trigger/TP/SL show as faint dashed lines before arming (both tabs) | ✅ build | `PriceChart.tsx`, `ControlPanel.tsx`, `Dashboard.tsx` |
| **Drag TP/SL of the open trade on the chart** (client, "like Exness", Single only): drag the TP/SL line to move it; drag the entry line toward profit = add TP, toward loss = add SL; × in the panel removes one. `POST /api/bot/modify?mode=SINGLE {tp, sl}` → `CycleEngine.modify_levels` checks side vs the closing price (+ stops/freeze level), `modify_position` on the broker, updates `cur_tp/cur_sl` + the journal row. Refused → toast, lines snap back. Also works for a trade left open by Stop now. Snapshot no longer re-derives TP/SL from the plan while a position is open (a removed TP came back) | ✅ engine + API tests | `cycle_engine.py`, `api/bot.py`, `PriceChart.tsx`, `ControlPanel.tsx`, `Dashboard.tsx`, `api.ts` |
| **Single "Last session" card removed** (client); the card still shows while a Single trade is open (incl. left open by Stop now) | ✅ build | `ControlPanel.tsx` |
| 🔴→fixed **Journal row stuck open after Stop now** (live, client screenshot): Buy now → Stop now → Close all left P/L "—" and the duration ticking. Root cause: a STOPPED engine stopped watching the position it left open, so any later close (broker TP/SL, Close all, MT5) was never recorded. Now `step()` watches it (`_watch_left_open`, journal only, never trades; skipped while "Resume?" is pending). Close all on it is journaled as KILL_SWITCH | ✅ 2 tests (fail on old code) | `cycle_engine.py` |
| Buy/Sell now no longer overwrites the form's trigger field with the entry price (caused "Price is exactly at the trigger") | ✅ build | `ControlPanel.tsx`, `types.ts` |

| 🔴→fixed **Single Stop left the trade open** (client): in SINGLE, Stop is now **Close trade** (at market, `CloseReason.CLOSED`, retried every tick if the broker refuses, then IDLE) and **Cancel** before the fill. Also closes a trade left open by the old Stop. Buy/Sell/Arm are hidden while a Single trade is open (no more "A bot position is still open" toasts). CYCLE's Stop now is unchanged (trade stays with its server-side TP/SL) | ✅ 3 tests | `cycle_engine.py`, `models.py`, `ControlPanel.tsx`, `Journal.tsx` |
| **Set TP/SL after Buy/Sell by typing** (client): TP/SL price boxes + Set in the open-trade card (blank = none), same `/modify` as the chart drag | ✅ build | `ControlPanel.tsx` |

Quality gates: **99/99 pytest**, mypy clean, ruff clean, frontend build clean.

### Findings
#### Finding #1 — 🔴→fixed: typo in an optional field silently became "none"
`num("abc")` is NaN and `JSON.stringify(NaN)` is `null`, so a typo in TP/SL would arm a trade **without** that TP/SL.
The form now lists every non-numeric field as an error and blocks Arm.

#### Finding #2 — 🔴→fixed: Infinity / NaN reached the config
Python's JSON parser accepts `Infinity`/`NaN`, and `Field(gt=0)` lets `inf` through. `CycleConfig` now has
`allow_inf_nan=False`. Also rejected: a TP/SL whose price would be ≤ 0 (huge SELL TP or BUY SL).

#### Finding #3 — 🟡→fixed: `level_anchor=fill` sent a no-change modify
With no TP/SL, or for CYCLE order 2 (SL fixed at order 1's entry), the bot still called `modify_position` with
the same values. Real MT5 answers 10025 (no changes) → a false "could not move TP/SL" error toast. Now skipped when
nothing changes (tests count the modify calls; the simulator would have accepted it).

#### Live / demo results
Paper run (DRY_RUN fills) on **live** XAUUSDm prices, SINGLE BUY 0.01:

| Case | Position TP / SL | Result |
|---|---|---|
| TP 0.5, SL blank | 3583.39 / 0.0 | TP +0.33 → IDLE |
| TP blank, SL 0.5 | 0.0 / 3582.86 | SL −0.51 → IDLE |
| both blank | 0.0 / 0.0 | stayed open 20 s, closed by kill switch → STOPPED |

#### Finding #4 — ⚪ Pre-existing, not changed: `level_anchor=fill` also moves exact-price TP/SL
In price mode the trader typed exact levels, but "Levels from: fill" re-derives them from the fill. Default is
`planned`, so it only matters if someone changes that. Ask before changing.

### Files changed
`backend/app/engine/{models,levels,risk,cycle_engine}.py`, `backend/tests/test_single_optional_tp_sl.py` (new),
`backend/tests/{test_api,test_levels}.py`, `frontend/src/components/ControlPanel.tsx`, `CLAUDE.md`, `HANDOFF.md`.

### ⚠️ NOT done yet — next session starts here
1. Push, then update the VPS again (same steps; turn QuickEdit off first).
2. Session 3 items still open (real-order demo run, `live_demo_test.py` rewrite).

### Decisions made
Client rule 2026-11-20 recorded in CLAUDE.md §3 / §12.

### Open items (client)
| # | Question | Current default |
|---|---|---|
| Q5 | Part Two TP/SL as points or exact prices? | both supported (toggle) |

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
