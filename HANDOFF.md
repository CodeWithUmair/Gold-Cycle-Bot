# HANDOFF — GoldCycle Project Log

Read [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md) first, then this. It's the running history of the project: what exists, what happened in each
session, what was decided, and where the next session starts. Append a new session at the bottom
(template at the end). Never rewrite old sessions; they are the history.

## Project at a glance

| | |
|---|---|
| **What** | Python bot for MetaTrader 5 (Exness, gold) that **executes** the trader's levels: opens at a trigger price, attaches TP/SL, and in Cycle mode chains the next trade automatically until SL / stop price / manual stop. It never picks direction. |
| **Current direction (2026-11-25)** | **MetaTrader 5 Expert Advisor** in [mql5/](mql5/README.md) (the client wants the bot inside MT5). The Python bot below is kept. Status: [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md). |
| **Spec (source of truth)** | [CLAUDE.md](CLAUDE.md). Rules, client's worked examples, open questions. |
| **Stack** | FastAPI + asyncio engine + SQLite · official `MetaTrader5` package (Windows) · Vite/React/TS + Tailwind + lightweight-charts + framer-motion |
| **Where it runs** | Client's Windows VPS, next to a logged-in MT5 terminal. Dashboard on `http://127.0.0.1:8000` via RDP only. |
| **Status** | ✅ All 8 build phases from CLAUDE.md §11 done. ✅ Client's new cycle rules (ADR-0018, 2026-11-16) **live-tested with real orders on demo** (Session 2). ✅ Running on the client's VPS (DRY_RUN) with the ADR-0018 code. ⏳ Next: auto-start, full-session demo run with `DRY_RUN=false`, client answer Q5 (Session 2 → "NOT done yet"). |

### Document map

| File | Use it for |
|---|---|
| [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md) | **Start here**: what works now, what is tested, what to do next, how to test on a new machine |
| [mql5/README.md](mql5/README.md) | The Expert Advisor: install and use (for the trader), code map (for developers) |
| [README.md](README.md) | Python bot: install, run, VPS deploy, troubleshooting |
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
| **Buy/Sell now opens with no TP/SL** (client, after the VPS test): the form's TP/SL apply only to "Arm at trigger price"; the trader sets TP/SL on the open trade (chart drag / boxes). Replaces the earlier "both buttons use the form's TP/SL" | ✅ build | `ControlPanel.tsx` |
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

## Session 5 — 2026-11-21 — change a running cycle (and its open order's TP/SL)

### State before
Pulled `2789d85` (Session 4 pushed). 100/100 pytest. In Cycle the whole form was locked while running, and
`modify_levels` refused Cycle ("TP/SL can only be changed on a Single trade").

### What was done
| Item | Result | Files |
|---|---|---|
| **Edit a running cycle** (client): the Cycle form stays editable while running; **Apply changes** / **Discard** appear when it differs from the running config. `POST /api/bot/update` → `CycleEngine.update_config`. TP points → an open order 1's TP moves on the broker (entry + new TP), else the next order 1. Gap → while waiting to re-enter after order 2's SL the waiting level moves (prev entry + new gap), else from the next SL. Trigger → only while ARMED for an order 1 (re-armed there). Stop price / lot / max cycles / limits → from the next tick/order. Direction is locked. Refused: stop price already passed (would stop now), TP on the wrong side of the price, lot/stops-level errors; a refused change leaves everything as it was. New config saved to `sessions.config_json` (restart uses it). One log/toast lists the changes ("TP pts 3 → 5 …") | ✅ `tests/test_cycle_live_edit.py` (8) + API test | `cycle_engine.py`, `repo.py` (`update_session_config`), `api/bot.py`, `ControlPanel.tsx`, `Dashboard.tsx`, `api.ts` |
| **Open Cycle order's TP/SL**: same boxes + chart drag as Single (`/modify?mode=CYCLE`). Order 2 opens at order 1's TP as it is on the trade; the next cycle still restarts at the cycle entry (+ gap) whatever order 2's SL was moved to | ✅ test | `cycle_engine.py` (`modify_levels`, shared `_check_open_levels`), `PriceChart.tsx`, `ControlPanel.tsx` |
| Single open-trade TP/SL editing (boxes + drag) checked: unchanged, all its tests pass | ✅ | — |
| 🔴→fixed **Order 2 could be skipped or delayed** (client: "critical — order 2 must open at once when order 1 hits TP"). `_on_opening` ran order 1's gates on order 2 too: price > max slippage past the TP → back to ARMED "wait for a return to the TP" (in a fast market order 2 never opened); a broker rejection followed by a 1-pt move → same; spread > max spread → waited; trading-hours window closed → waited until the next day. Now order 2 skips all three gates and opens in the same step (levels still planned: entry = order 1's TP, SL = order 1's entry); a rejection is retried every second. Max spread / hours / slippage still guard order 1. Client chose "open anyway" for the spread case | ✅ `tests/test_order2_immediate.py` (13; 7 failed on the old code: jumps 0.8/3/25 BUY, 0.8/5 SELL, hours, reject + move) | `cycle_engine.py` (`_on_opening`), CLAUDE.md §4.3 |
| Frontend review (agent): an unapplied trigger edit got stuck when order 1 opened (field locked, Apply always 409). Now the field resets to the running trigger when it locks | ✅ build | `ControlPanel.tsx` |
| Edge-case test agents: live edits (21 tests: SELL paths, OPENING/RESOLVING/pending close, fill anchor, gap blank↔set, trigger at cycle > 1, stop vs re-entry, max cycles lowered, lot, daily loss, restart, order 2 TP/SL edits, no-op/rapid updates) | ✅ all pass, no bugs | `tests/test_edge_live_edit.py` |
| Engine regression agent (35 tests: SELL tables, stop price both sides in each order, max cycles, kill switch in each state, manual close, restart in each state, daily loss, spread, rejects, Single) | ✅ all pass | `tests/test_edge_engine.py` |
| **"Stop after this cycle" during order 1** (client choice): order 2 still opens at once on order 1's TP; the bot stops when order 2 closes (was: stopped after order 1, order 2 never opened). The kill switch while RESOLVING now uses `pending_close=KILL_SWITCH` (it used the stop-after-cycle flag, which would now open order 2) | ✅ tests | `cycle_engine.py`, ControlPanel tooltip |
| 🟡→fixed journal label: one jump through order 1's TP **and** the stop price → broker closed on TP, journal said STOP_PRICE. Journal now shows the broker's TP/SL reason; the flow still stops (no order 2) | ✅ test | `cycle_engine.py` (`_record_close`) |
| **"Last session" card removed from Cycle too** (client; Single lost it in Session 4). History stays in the journal / Reports; **Resume** button unchanged | ✅ build | `ControlPanel.tsx` |

Quality gates: **179/179 pytest**, mypy clean, ruff clean, `npm run build` (tsc) clean. The live-edit UI was tried by
the user locally on the simulator (market closed: Saturday). Not yet run on MT5 with real prices.

Local test setup used: MT5 terminal 474902598 @ Exness-MT5Trial15, bot started with `$env:BROKER='sim';
$env:SIM_START_PRICE='3540'` (env overrides `.env`, which still says `BROKER=mt5`). Local admin password changed by the
user's request (hash in the local `.env` only; VPS unchanged).

### Files changed
`backend/app/engine/cycle_engine.py`, `backend/app/storage/repo.py`, `backend/app/api/bot.py`,
`backend/tests/test_cycle_live_edit.py` (new), `backend/tests/{test_enter_now,test_api}.py`,
`frontend/src/{api.ts,pages/Dashboard.tsx,components/ControlPanel.tsx,components/PriceChart.tsx}`, `CLAUDE.md` §12,
`docs/ARCHITECTURE.md` (REST table), `HANDOFF.md`.

### ⚠️ NOT done yet — next session starts here
1. Update the VPS: **close any open bot trade first**, then in the bot's window Ctrl+C, and in PowerShell:
   `cd C:\Users\Administrator\Desktop\Bot; git pull; cmd /c scripts\install.bat; cmd /c scripts\start.bat`, Ctrl+F5 in
   Chrome, log in. When the market is open, watch one order 1 TP → order 2 on DRY_RUN (journal: C1.2 open_time = C1.1
   close_time).
2. Session 3/4 items still open (real-order demo run, `live_demo_test.py` rewrite).

### Decisions made
Client rule 2026-11-21 recorded in CLAUDE.md §12 (no ADR).

### Open items (client)
| # | Question | Current default |
|---|---|---|
| Q5 | Part Two TP/SL as points or exact prices? | both supported (toggle) |

---

## Session 6 — 2026-11-22 — one-command install, several accounts per VPS, "no trades in Exness"

### State before
Pulled: already at `167f326` (Session 5). Client asked: (1) a simple install for a non-developer (like dropping an EA
into MT5), (2) several MT5 accounts on one VPS, (3) "the bot takes trades but Exness has no record of them".

### What was done
| Item | Result | Files |
|---|---|---|
| **"No record in Exness"**: root cause = the VPS runs `DRY_RUN=true` (Session 2 "VPS state"): real prices, **no orders sent**, paper fills. Since Session 4 the top bar shows the real balance + paper P/L, so it looked real; the only hint was a small "DRY RUN" badge. Fix: full-width yellow **PRACTICE MODE** bar ("no orders are sent to Exness … will not appear in MT5 or Exness history"), and practice ↔ real is one Manager menu item. To get real trades: Manager → 4, Algo Trading on, remove the other EA (Session 2 Finding #5) | ✅ build | `Dashboard.tsx` |
| **Several accounts: one install + one profile per account** (user's choice): `GOLDCYCLE_ENV_FILE` points the app at `accounts\<name>\.env` (own `MT5_PATH`, login, port, magic, DB, logs). Unset = repo `.env` as before (old VPS install unchanged). Missing file → refuses to start (pydantic would silently fall back to the simulator) | ✅ `tests/test_accounts.py` | `config.py` |
| 🔴→fixed **Session cookie shared between dashboards**: browsers don't separate cookies by port, so logging into 8002 logged out 8001. Cookie is now `gc_session_<port>` | ✅ test | `security.py`, `api/auth.py`, `main.py` |
| Top bar shows the account number (server on hover) to tell the tabs apart | ✅ build | `TopBar.tsx` |
| **`scripts/setup.ps1`**: one line in an admin PowerShell (`irm … \| iex`, README). Installs Python 3.12 / Git 2.51 / Node 22 from the official URLs if missing (no winget: absent on Windows Server 2019/2022), clones to `C:\GoldCycle\app` (or pulls), runs `goldcycle.ps1 install` | ⚠️ parses on PS 5.1; **not run end-to-end** (needs the repo public + a clean machine) | `scripts/setup.ps1` |
| **`scripts/goldcycle.ps1` (GoldCycle Manager)**: menu + `install / add / list / start / stop / mode / update / open`. Add account: copies the Exness MT5 folder to `C:\GoldCycle\terminals\<name>`, asks login / password / server / practice-or-REAL / dashboard password, writes `.env` + `start.bat`, scheduled task `GoldCycle-<name>` (at logon, **no 3-day time limit**), desktop `.url`. Ports 8001+, magic `7700501 + (port-8000)*10`. `install` disables the old `GoldCycle` task so two bots never trade one account | ✅ tested locally (below) | `scripts/goldcycle.ps1` |
| README: "One-command install, several MT5 accounts" | ✅ | `README.md` |

Quality gates: **182/182 pytest**, mypy clean, ruff clean, `npm run build` clean.

### Live / local results (this PC, DRY_RUN, demo 474902598 @ Exness-MT5Trial15)
Two profiles in a scratch root, made by the Manager's own functions: acc1 → installed terminal, acc2 → a **copy** of it.
| Check | Result |
|---|---|
| `.env` round-trip incl. passwords with `'` `$` `#` and non-ASCII dashboard password | ✅ exact |
| Both bots up at once, own logs/DB, `MT5 connected: login=474902598` on each | ✅ |
| Login on 8001 and 8002 side by side (cookies `gc_session_8001` / `_8002`) | ✅ |
| Copied terminal logged into the account (user checked it) | ✅ connected, Algo Trading on, balance 496.10 |
| Scheduled task: logon trigger, limit `PT0S`, start via task → `/health` OK, Manager Stop | ✅ (task + desktop file removed after) |
| Stop leaves MT5 running | ✅ after fix (Finding #2) |

### Findings
#### Finding #1 — 🔴→fixed: PS 5.1 puts a BOM in front of text piped to python
The dashboard hash was made from `"\ufeff" + password` → login always failed. The password now goes through a
process-local env var (`GC_DASH_PW`), not a pipe and not the command line.
#### Finding #2 — 🟡→fixed: `taskkill /T` also closed MT5
`mt5.initialize(path=…)` starts the terminal as a **child of the bot**, so killing the bot's tree closed MT5. Stop now
kills the tree except `terminal64.exe`.
#### Finding #3 — 🟡 First start of a fresh terminal copy with no account: dashboard froze ~2 min
`IPC send failed (-10001)`, then no logs and no HTTP answer. Not reproduced after that (the copy got logged in, every
later start was fine; a thread test showed no GIL stall). Watch for it on the VPS when adding an account; if a new
dashboard doesn't load, check that account's MT5 window (login dialog / wrong server).
#### Finding #4 — ⚪ Old VPS task `GoldCycle` (made with `schtasks`) has the default 3-day limit
Task Scheduler would stop that bot after 72 h. The Manager's `install` disables it; the new tasks have no limit.

### ⚠️ NOT done yet — next session starts here
1. Commit + push, then **make the GitHub repo public** (user's choice; the one-liner needs it). History has no secrets
   (checked: no `.env`, passwords or tokens ever committed); HANDOFF has demo account numbers and VPS paths.
2. Run the one-liner on the VPS (or a clean Windows VM) once: it is not tested end-to-end. On the VPS: close any bot
   trade and the old bot window first; the installer disables the old `GoldCycle` task. The old folder
   `Desktop\Bot` can stay as a backup.
3. Add-account with a **real login/password** in a fresh copy is untested (here the terminal was logged in by hand).
4. Tell the client: practice mode = no trades in Exness; switch to real in the Manager (Algo Trading on, other EA off).
5. Session 3/4/5 items still open (real-order demo run, `live_demo_test.py` rewrite).

### Decisions made
One install + `accounts\<name>\` profiles (not one repo copy per account); installer copies the MT5 terminal per
account; repo goes public for the one-liner. No ADR.

### Open items (client)
| # | Question | Current default |
|---|---|---|
| Q5 | Part Two TP/SL as points or exact prices? | both supported (toggle) |

---

## Session 7 — 2026-11-24 — no more "right-click the CMD, restart, refresh the page" (client is non-technical)

### State before
Session 6 pushed (`698b604`) and installed on the VPS as account `gold-bot-umair` (REAL orders on demo 474902598).
The client's real pain: the bot's visible black window **freezes on any click** (title "Select …", QuickEdit,
Session 2 Finding #4), the fix was Esc/right-click + restart + refresh + log in again.

### What was done
| Item | Result | Files |
|---|---|---|
| **Bot runs hidden**: task → `wscript launch.vbs` → hidden `start.bat`. No window to click or close. `start.bat` is a restart loop (new python 6 s after any exit). Output → `accounts\<name>\logs\console.log` (overwritten per run) | ✅ local: started via the task, MT5 window still shows, python killed → back in 6 s | `scripts/goldcycle.ps1` (`Write-Launchers`, `Register-Account`) |
| **`repair` / `update` migrate old accounts** to the hidden launcher + new task (`Repair-Accounts`, also run by `install` and Manager "Update") | ✅ migrated the old-style test accounts | `goldcycle.ps1` |
| **Logins survive a bot restart**: sessions persisted in the account's DB (`settings.auth_sessions`), stored as SHA-256 of the cookie, expired/corrupt entries dropped | ✅ 2 tests + live (same cookie → 200 after the crash) | `security.py`, `main.py`, `tests/test_accounts.py` |
| **Dashboard reconnects by itself**: after a socket drop it asks `/api/auth/me`: 401 → login page, server still down → keeps retrying (≤3 s), OK → reconnects and reloads status/log/journal. Red bar "Connection to the bot lost. Reconnecting by itself …" | ✅ build (not clicked through in a browser) | `useSocket.ts`, `Dashboard.tsx` |
| Console **QuickEdit turned off** in the bot's own console (only matters when run visibly, e.g. old `start.bat`) | ✅ unit-free (needs a real console) | `main.py` |
| Manager: Start waits for `/health` and says "ready" or what to check; Add-account opens the dashboard; Stop also stops the task and kills parent before children | ✅ | `goldcycle.ps1` |

| **Add-account flow rewritten** (client: "don't ask stupid questions, give number choices"): no short name (the account number is the name), no practice/REAL question (accounts always send orders, `DRY_RUN=false`; practice kept only as CLI `mode`), account kind 1/2, server **number** (`Exness-MT5Real|Trial` + number, or a whole typed name), MT5 password (hidden), dashboard password (Enter = same as MT5 password, no repeat). Every choice is a number via `Read-Choice`; yes/no is `1) Yes 2) No` | ✅ simulated, see below | `goldcycle.ps1` |
| **Connection test before saving** (`Test-Mt5Connection` → `backend/tools/check_mt5.py`): logs the bot's MT5 copy in with the typed details, prints the account / balance / demo-or-real, or the reason in plain words (`app/broker/mt5_errors.py`). Failure → 1 try again / 2 retype / 3 cancel (nothing saved). The dashboard opens in the browser only when `connected` | ✅ | `goldcycle.ps1`, `check_mt5.py`, `mt5_errors.py`, `tests/test_mt5_errors.py` |
| **"MT5 not connected" now says why**: engine keeps `connect_error` (snapshot + `/health` `error`), red dashboard bar "The bot is not connected to MetaTrader 5 …  Reason: …", and Manager Start prints READY / NOT connected + reason | ✅ | `cycle_engine.py`, `main.py`, `types.ts`, `Dashboard.tsx` |
| Manager menu is now 1 start · 2 stop · 3 stop + MT5 · 4 restart · 5 add account · 6 open dashboard · 7 update · 0 exit (practice switch removed from the menu) | ✅ | `goldcycle.ps1`, README |

| **Algo Trading switched on automatically** (a fresh MT5 copy has it OFF and refuses every order): after the connection test, `Enable-AlgoTrading` closes the bot's terminal, sets `[Experts] Enabled=1, Account=0, Profile=0` in its data folder's `config\common.ini` (UTF-16, found through `origin.txt`), and the bot starts the terminal again. Falls back to "click Algo Trading" if the data folder isn't found | ✅ real run: `algo trading allowed=True` with no click | `goldcycle.ps1` (`Stop-Terminal`, `Enable-AlgoTrading`) |

| **`GoldCycle-Setup.bat`** (repo root): the file to send the client. Double-click → asks admin once (`net session` check + `Start-Process -Verb RunAs`) → runs the same `setup.ps1` one-liner. Root = `C:\GoldCycle` (no path for the client to set; `GOLDCYCLE_ROOT` was only my test override) or the existing install if GoldCycle is already on the PC; same file updates. Not tied to where the .bat is saved (a Desktop / Downloads folder is often OneDrive-synced). `.gitattributes`: `*.bat` kept CRLF | ⚠️ download command + admin check tested through `cmd`; **the UAC click and the full run were not** (needs a person) | `GoldCycle-Setup.bat`, `.gitattributes`, README |

Quality gates: **187/187 pytest**, mypy clean, ruff clean, `npm run build` clean.

### REAL end-to-end run on this PC (user's demo account 474902598 @ Exness-MT5Trial15, typed as a client would)
Fresh `git clone` in a scratch root, fresh MT5 copy, Manager `Install-All` with answers `2` / account number / `15` / password / dashboard password, **no stand-ins**:
connected on the first try (balance 496.10 USD) → Algo Trading switched on by the script → bot READY → dashboard login OK, `dry_run=False`, symbol XAUUSDm, one MT5 window (the bot's own copy).
**Then a real 0.01 BUY (Single, "Buy now") + Close trade through the bot's API, checked in MetaTrader's own records:** position #2852494912 BUY 0.01 XAUUSDm @ 3641.658, comment `GC|c=1.1|session=…`, magic = account magic+1; close deal OUT @ 3641.365, profit −0.29; bot journal `CLOSED`, pnl −0.29; 0 positions left. This is the "Exness has a record" check. Everything (tasks, shortcuts, MT5 copies, the typed password) was removed afterwards.

#### Finding — ⚪/🟡 "Buy now" in the first seconds after the daily break
Gold reopened 23:00 UTC; for ~3 s the broker answered `session closed (10044)` to orders while prices already streamed. The bot retried every second (correct), but the price had moved > 0.5 pt past the click price, so it fell back to "wait for a return to that price" (ARMED) and never filled (ADR-0003 behaviour, also applied to enter_now). A client pressing Buy-now at that moment sees an armed trade that doesn't open. Not changed; ask the client if Buy-now should ignore the slippage limit.
Gold's daily break is 22:00–23:00 server time (= UTC), quotes freeze (tick age grows) until then.

### Simulation on this PC (client-like, separate root `…\scratchpad\clientsim\GoldCycle`, fresh `git clone`)
- **A** `Install-All` with typos on purpose (kind `x`, login `abc`, server `zz zz`) → each re-asked; wrong password → "MetaTrader 5 refused the login …"; retry → same; cancel → **0 accounts, 0 tasks saved**. MT5's own answer was `Authorization failed (-6)` after 2 s, i.e. a fresh terminal copy reaches Exness and resolves `Exness-MT5Trial15`; only the credentials were refused. **This is what a wrong typed password/server looks like in MT5's Journal: "authorization … failed (Invalid account)".**
- **B** success path (stand-in: base terminal that remembers the demo login, because no password is stored here): connected, files + logon task + desktop `.url`, bot READY, dashboard login 200, `dry_run=False`, balance read; menu: invalid `9` → asked again, restart / stop / start all via numbers, browser-open requested.
- **C** wrong password in the account's `.env` → Start prints "running, but NOT connected … Reason: MT5 initialize failed: Terminal: Authorization failed (-6)"; `/health` and the dashboard status carry the same text.
- ~~Not tested: a successful login with a real typed password on a fresh copy~~ → done in the REAL run above. **Still not tested**: the red "not connected" banner in a real browser; the one-liner `irm … | iex` from GitHub on a clean machine.

#### Finding — 🔴→fixed: client laptop, MT5 `Process create failed ... terminal64.exe (-10003)`
First install on a client laptop (remote session that closed every ~5 min, so installs were interrupted and repeated): the bot ran but could not start its MetaTrader copy. Cause found by reproduction: `Copy-Item $base $dest -Recurse` puts the folder **inside** `$dest` when `$dest` already exists (half-finished earlier attempt), so `terminals\<name>\terminal64.exe` never exists. Fix: `Copy-Terminal` (robocopy, removes a nested leftover, checks terminal64.exe > 1 MB), `Test-TerminalCopy`, and **Update / Repair-Accounts rebuilds a missing or broken copy**. The raw MT5 error now carries a plain-language hint (`mt5_errors.explain` is used by the gateway too). Not seen on this PC; reproduced with a stand-in folder, not with his machine. If it still fails after Update: antivirus blocking `terminal64.exe` in `C:\GoldCycle\terminals`.
Also: `GoldCycle-Setup.bat` first version showed a bare "Access is denied." (cause not found; new version prints the reason + exit code and uses the full PowerShell path).
Defender: on the client laptop `Get-MpThreatDetection` showed 2 detections (ThreatID 2147852719) whose resource is the `powershell.exe -NoProfile -ExecutionPolicy Bypass -C...` command line of the first .bat (download + run in one command). Threat name not yet read (ask: `Get-MpThreat | fl ThreatName,SeverityID,IsActive`). The .bat now downloads setup.ps1 with curl.exe (PowerShell fallback) and runs it with `-File`; setup.ps1 exits 1 when run as a file and fails. Not verified against his Defender.

**Client laptop, after the rebuild:** the bot's MetaTrader started (no more -10003) but Exness answered `Authorization failed (-6)` for the account saved by the OLD add-account flow (typed server/password, never tested, or an expired demo). Add-account refuses an account that already exists, so there was no way to retype. New Manager item **8 = `Repair-AccountLogin`** (also `goldcycle.ps1 fix-login`): asks kind / server number / password again, tests the login for real (retry / retype / cancel), switches Algo Trading on, rewrites only `MT5_PASSWORD` and `MT5_SERVER` in the account's `.env` (`Set-EnvValue`, line by line so `$`/`\` in passwords survive), restarts the bot. Verified on this PC by reproducing the state (account saved with a wrong password, bot NOT connected -6), then wrong attempt → rejected, right attempt → READY, password with `@` and `!` intact, other lines untouched.
Leftovers seen on this PC after the user's own cleanup: tasks `GoldCycle-473027979` and `GoldCycle-474902598` (D:\gc-test no longer exists) and 3 Desktop shortcuts. `setup.ps1` finds the install root through these tasks, so a 'fresh' install would go to D:\gc-test again until the tasks are removed.

Start-Bot now ASKS when the saved login is refused (-6 / Authorization failed): `Type the password and server of account N again now? 1) Yes 2) No` and runs `Repair-AccountLogin` on yes (`-NoOffer` stops it asking again after the fix or a cancel). Verified with both answers on this PC (wrong saved password -> No: unchanged; Yes: fixed, READY).

Setup/update no longer ends on a dead-end 'Finished' (client screenshot: update ran, bot was stopped, nothing told him to start it): `setup.ps1` now opens the Manager menu right after install/update, and `Set-ManagerShortcut` makes sure the 'GoldCycle Manager' icon exists (refreshes an existing one, otherwise creates it on the SHARED Desktop so every Windows user sees it; Update calls it too). Tested the icon helper in temp folders (not run end to end on a client PC).

### ⚠️ NOT done yet — next session starts here
0. Push the above, then on the VPS run the one-liner from README (it updates the existing install). Then try **Manager → 5 (add account)** with the real demo/real credentials on this PC (`$env:GOLDCYCLE_ROOT='D:\gc-test'` first, so it stays in its own folder).
1. **Update the VPS once** (the old Manager script doesn't know `repair`): in an admin PowerShell,
   `cd $([Environment]::GetFolderPath('Desktop'))\GoldCycle\app; git pull; powershell -ExecutionPolicy Bypass -File scripts\goldcycle.ps1 update`.
   Close the visible bot window first (the update stops/starts the bot hidden). Then check: no black window, dashboard up.
2. The browser reconnect UI was only type-checked/built, not watched live: on the VPS, restart the bot (Manager) with a
   dashboard tab open and see the red bar then recovery without refresh.
3. After a crash restart the engine asks "Resume?" (`RESUME_ON_RESTART=false`, ADR-0010). Ask the client if he wants
   auto-resume (`RESUME_ON_RESTART=true` in the account's `.env`); not changed.
4. Live trading test with the market open (Session 6 list) and Session 3–5 items still open.

### Decisions made
Hidden launcher + restart loop instead of QuickEdit-only fixes. No ADR.

---

## Session 8 — 2026-11-25 — the bot inside MetaTrader 5 (Expert Advisor)

### State before
Python bot installed and READY on a client laptop (Session 7). The client then said he does not want the web
dashboard: he wants the bot **inside MT5**, like the two-file bot he had used before, with all the same settings,
Cycle and Single. This replaces the "Python + dashboard" delivery decision in CLAUDE.md.

### What was done
| Item | Result | Files |
|---|---|---|
| One Expert Advisor with an on-chart panel; Cycle and Single side by side (magic 8800501 / 8800502) | ✅ compiles 0 errors / 0 warnings | `mql5/Experts`, `mql5/Include` |
| Engine ported from `cycle_engine.py` (all client rules incl. order 2 at once, stop price, stop after cycle, live edit, kill switch, manual close, daily loss, duplicate guard, Resume after restart, TP/SL drag follow) | ✅ | `Engine.mqh`, `Logic.mqh` |
| Panel: all dashboard settings, validation (typos never become "none"), preview, status, journal, log, chart lines, Pick, buttons, help, Ctrl+Shift+K; journal CSV; popup / sound / phone alerts | ✅ screenshot `mql5/docs/panel.png` | `Panel.mqh`, `GoldCycle.mq5` |
| Simulated broker + engine test script run **inside MetaTrader** | ✅ **146 passed, 0 failed** | `SimBroker.mqh`, `Scripts/GoldCycle/GoldCycleTests.mq5` |
| Live end-to-end test script (demo only) driving the EA's buttons through a test hook (`InpTestHooks`) | ✅ **40 checks passed** | `Scripts/GoldCycle/GoldCycleLiveTest.mq5` |
| `mql5/build.ps1` (copy, compile, install into an MT5, refresh `release/GoldCycle.ex5`), client guide, status document for a new machine | ✅ build tested on a portable copy | `mql5/build.ps1`, `mql5/README.md`, `docs/CURRENT_STATE.md` |

### Findings
#### Finding #1 — ⚪ Test-only mistakes (engine was right)
First run 144/145: the test expected a "touch" 0.2 pts above the level after a jump. A history-delay test also had to
wait past the 3 s "just opened" guard.
#### Finding #2 — ⚪ PowerShell variable case
`$t` (loop target) overwrote `$T` (folder) in the first build script: variables ignore case.
#### Finding #3 — 🟡 Small TP, seen live again
Cycle BUY with TP 0.6: trigger 3555.75, filled 3556.291, TP 3556.35 (0.06 room). Planned-level rule; the panel warns.

### Live / demo results
Isolated portable MT5 copy, demo 474902598 @ Exness-MT5Trial15, XAUUSDm, 0.01 lot, 2026-11-24 23:43–23:55 UTC:
Single (Buy now, Set TP/SL, TP changed outside the bot, Close) +0.52; Cycle BUY order 1 → Close all −2.17; one attempt
never touched; Cycle SELL: order 1 TP +0.87 → **order 2 in 64 ms**, SL = order 1's entry; MetaTrader closed → server SL
closed order 2 −1.12 → restart: "Resume?" → resolved from history → MAX_CYCLES; restart with a Single trade open →
Resume reattached, no duplicate → Close all −0.51. Balance 495.81 → 493.40 (= sum). No position left open. The test
copy and every file holding the password were deleted afterwards.

### Files changed
`mql5/**` (new), `docs/CURRENT_STATE.md` (new), `HANDOFF.md`, `CLAUDE.md`, `README.md`, `.gitattributes`.

### ⚠️ NOT done yet — next session starts here
See [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md) → "NOT tested yet": install on the office laptop, run the manual
checklist (Apply changes, Stop after cycle, Stop now, Start at trigger, Pick, hotkey, timeframe switch were not
exercised live), other screen scaling, VPS, client feedback on the panel.

### Decisions made
Deliver an MQL5 Expert Advisor (client request). One EA for both modes. Python bot kept, not removed. No ADR.

### Open items (client)
See the table at the end of CURRENT_STATE.md.

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
