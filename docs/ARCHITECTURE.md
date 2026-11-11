# GoldCycle — Architecture

> For developers / AI agents continuing the project. The **rules** (what the bot must do) live in
> [CLAUDE.md](../CLAUDE.md). This file describes **how the code implements them** as of Session 1 (2026-11-11).
> Trading words are explained in [GLOSSARY.md](../GLOSSARY.md).

## 1. Overview

GoldCycle is a single Python process on the client's Windows VPS. A FastAPI app (run by uvicorn) owns one
`CycleEngine` that polls the broker every ~100 ms and drives a state machine (arm → open on touch → server-side
TP/SL → resolve close → next cycle or stop). The engine only talks to a `Broker` interface; three broker modes exist
(real MT5, MT5 prices with paper orders = DRY_RUN, pure simulator). Every transition is persisted to SQLite and
pushed over a WebSocket to a React dashboard that the same process serves as static files.

```
uvicorn  ──  app.main:app  (FastAPI, binds 127.0.0.1:8000)
               │
               └─ lifespan()
                    ├─ Settings (.env)  →  setup_logging (logs/goldcycle.log, JSON, rotating)
                    ├─ Repo (SQLite: data/goldcycle.db)
                    ├─ build_broker()  →  Mt5Gateway | SimBroker(feed=Mt5Gateway) | SimBroker(random_walk)
                    ├─ pick_symbol()  →  CycleEngine(broker, repo, symbol, magic, emit=hub.publish)
                    └─ background tasks
                         ├─ engine.run(poll)        every 100 ms: step() → tick → state handler; 1 s: account()
                         ├─ hub.run()               every 100 ms: flush coalesced + queued events to all sockets
                         └─ _recover_when_connected  once connected: engine.recover(resume_on_restart)
               │
               ├─ REST  /api/auth · /api/bot · /api/settings · /api/candles · /api/history · /api/reports · /health
               ├─ WS    /ws   (tick, state, account, floating, log, toast, cycle)
               └─ StaticFiles "/"  →  frontend/dist  (React + lightweight-charts)
```

## 2. Module map

### Backend (`backend/app/`)

| File | Responsibility |
|---|---|
| [main.py](../backend/app/main.py) | App factory, lifespan (wiring, background tasks), `build_broker`, `pick_symbol`, `/health`, `/ws`, security headers, static mount, `python -m app.main` entry |
| [config.py](../backend/app/config.py) | `Settings` (pydantic-settings) read from `goldcycle/.env` or `backend/.env`; blank strings → `None` for MT5 creds/symbol |
| [logging_setup.py](../backend/app/logging_setup.py) | JSON rotating file log (5 MB × 10) + console |
| [context.py](../backend/app/context.py) | `AppContext` dataclass on `app.state.ctx` (settings, repo, broker, engine, hub, sessions, limiter) |
| [security.py](../backend/app/security.py) | argon2 hashing, in-memory `SessionStore`, `LoginLimiter`, `current_session` / `csrf_session` deps, `python -m app.security` hash CLI |
| [ws.py](../backend/app/ws.py) | `Hub`: publish (sync) + 100 ms flush loop with coalescing |
| [api/auth.py](../backend/app/api/auth.py) | login / logout / me |
| [api/bot.py](../backend/app/api/bot.py) | status, validate (+ preview ladder), arm, stop, stop-after-cycle, close-all, resume |
| [api/settings.py](../backend/app/api/settings.py) | settings, symbol change, test connection, candles |
| [api/history.py](../backend/app/api/history.py) | cycles, sessions, events |
| [broker/base.py](../backend/app/broker/base.py) | `Broker` Protocol + DTOs (`Tick`, `SymbolSpec`, `AccountInfo`, `Position`, `OrderResult`, `CloseInfo`, `Candle`), `DealReason`, `BrokerDisconnected`, `TIMEFRAME_SECONDS` |
| [broker/mt5_gateway.py](../backend/app/broker/mt5_gateway.py) | Real MT5. **Only file that calls `mt5.*`** |
| [broker/sim_broker.py](../backend/app/broker/sim_broker.py) | Simulator: scripted prices (tests), random walk (dev), or real feed + virtual orders (DRY_RUN) |
| [engine/models.py](../backend/app/engine/models.py) | Enums (`Direction`, `Mode`, `BotState`, `CloseReason`) + `CycleConfig` (validated user input) |
| [engine/levels.py](../backend/app/engine/levels.py) | Pure level math: `POINT_SIZE`, tp/sl, `cycle_sl`, `next_entry`, `stop_reached`, `preview_ladder`, rounding |
| [engine/trigger.py](../backend/app/engine/trigger.py) | `TouchTrigger` (side recorded at arm; never fires on arm) + `trigger_price(tick, side)` |
| [engine/risk.py](../backend/app/engine/risk.py) | Spread / slippage / trading-hours / daily-loss checks, `validate_config` (lot, stops level, warnings) |
| [engine/cycle_engine.py](../backend/app/engine/cycle_engine.py) | The state machine, actions, recovery, main loop |
| [storage/repo.py](../backend/app/storage/repo.py) | SQLite schema + queries (thread-locked single connection, WAL) |

### Frontend (`frontend/src/`)

| File | Responsibility |
|---|---|
| [main.tsx](../frontend/src/main.tsx) / [App.tsx](../frontend/src/App.tsx) | Mount; `MotionConfig reducedMotion="user"`; auth gate via `GET /api/auth/me` |
| [api.ts](../frontend/src/api.ts) | Typed fetch wrapper; stores CSRF token from login/me and sends `X-CSRF-Token` on POST |
| [hooks/useSocket.ts](../frontend/src/hooks/useSocket.ts) | One WebSocket, exponential reconnect (0.5 → 8 s), 20 s ping, dispatches message kinds |
| [types.ts](../frontend/src/types.ts) | TS mirrors of backend payloads |
| [pages/Login.tsx](../frontend/src/pages/Login.tsx) | Login form |
| [pages/Dashboard.tsx](../frontend/src/pages/Dashboard.tsx) | Layout, state owner (engine, cycles, logs, toasts), actions, Ctrl+Shift+K |
| [components/TopBar.tsx](../frontend/src/components/TopBar.tsx) | Status dots, mode tag (DRY RUN / SIMULATOR / DEMO / LIVE), bid/ask/spread, balance/equity, state badge |
| [components/PriceChart.tsx](../frontend/src/components/PriceChart.tsx) | lightweight-charts v5 candles, timeframe switch, level lines, cycle markers |
| [components/ControlPanel.tsx](../frontend/src/components/ControlPanel.tsx) | Cycle/Single form, Advanced & safety, live validation, preview ladder, action buttons, running card |
| [components/Journal.tsx](../frontend/src/components/Journal.tsx) | Cycle journal table + session P/L |
| [components/LogDrawer.tsx](../frontend/src/components/LogDrawer.tsx) | Slide-in event log |
| [components/SettingsModal.tsx](../frontend/src/components/SettingsModal.tsx) | Symbol picker, test connection |
| [components/ui.tsx](../frontend/src/components/ui.tsx) | `NumberTicker`, `StateBadge`, `Dot`, `Toasts`, `Modal`, `ConfirmModal`, formatters |

## 3. Broker abstraction

`Broker` Protocol ([base.py](../backend/app/broker/base.py)) — everything is `async`:

| Group | Methods |
|---|---|
| Connection | `connect`, `reconnect`, `is_connected`, `shutdown` |
| Market data | `find_symbols`, `symbol_spec(symbol)`, `tick(symbol)`, `account`, `candles(symbol, tf, count)` |
| Trading | `positions(symbol, magic)`, `open_market(symbol, direction, volume, sl, tp, deviation_points, magic, comment)`, `modify_position`, `close_position(position, deviation_points)`, `close_info(ticket)` |

Any call may raise `BrokerDisconnected`; the engine pauses on it.

### Implementations — chosen by `build_broker()` in [main.py](../backend/app/main.py)

| `.env` | Broker object | `broker.name` | Prices | Orders |
|---|---|---|---|---|
| `BROKER=mt5`, `DRY_RUN=false` | `Mt5Gateway` | `mt5` | MT5 | **Real** (sent to the broker) |
| `BROKER=mt5`, `DRY_RUN=true` (default) | `SimBroker(feed=Mt5Gateway)` | `dry-run` | MT5 | Logged + paper-filled, TP/SL evaluated on real ticks; paper balance 10 000 |
| `BROKER=sim` | `SimBroker(random_walk=True)` | `sim` | Gaussian random walk from `SIM_START_PRICE` with 500 seeded M1 bars | Paper |

Tests use `SimBroker()` with scripted prices (`set_price`).

### Mt5Gateway rules ([mt5_gateway.py](../backend/app/broker/mt5_gateway.py))

- **Single thread:** every `mt5.*` call runs inside `ThreadPoolExecutor(max_workers=1)` via `_call()`. Never call `mt5` anywhere else.
- **Connect:** `mt5.initialize(path?, login?, password?, server?)`. With no credentials it attaches to whatever account the terminal is logged into. Failure → `BrokerDisconnected("MT5 initialize failed: …")`.
- **Connected?** `terminal_info().connected`. `reconnect()` = `shutdown()` + initialize again.
- **Filling mode** (per symbol, read in `symbol_spec`): `filling_mode & 1` → `ORDER_FILLING_FOK`, else `& 2` → `IOC`, else `RETURN`. Note `ORDER_FILLING_FOK == 0`, so a logged "filling 0" means FOK. On the Exness demo, `XAUUSDm` has `filling_mode=3` and the gateway picks FOK.
- **Zero prices:** `tick()` raises `BrokerDisconnected` when `bid <= 0` or `ask <= 0`. `XAUUSD247m` on Exness returns zeros, so picking that symbol makes the engine show "disconnected" instead of trading on 0.
- **Retcodes:** OK = `{10008, 10009, 10010}`. **FATAL** (engine goes `STOPPED` / `ORDER_ERROR`): 10013 invalid, 10014 volume, 10015 price, 10016 stops, 10017 trade disabled, 10019 no money, 10022 expiration, 10026/10027 autotrading disabled (server/terminal), 10030 filling, 10040 position limit. Everything else (requote, reject, price changed, timeout, market closed, `order_send` returning `None`…) is retryable.
- **Position ticket after `order_send`:** scan `positions_get(symbol)` for our magic with `ticket == result.order` or `identifier == result.order` (hedging: ticket == order). Fallback: `history_deals_get(ticket=result.deal)[0].position_id` (netting), then `result.order`. Fill price = position `price_open`, else `result.price`.
- **Close reason:** `close_info(ticket)` reads `history_deals_get(position=ticket)`. It takes the latest deal with `entry ∈ {OUT, OUT_BY}`, maps `deal.reason` (TP, SL, SO → STOP_OUT, CLIENT/MOBILE/WEB → CLIENT, EXPERT, else OTHER), and reports net P/L as the sum of profit + swap + commission + fee over **all** deals of the position.
- **Comment** is truncated to 31 chars (MT5 limit). Format: `GC|cycle=3|session=ab12cd34`. Closes use `GC|close`.
- **Candles:** `copy_rates_from_pos` (broker server time; Exness server time is UTC).

## 4. Engine ([cycle_engine.py](../backend/app/engine/cycle_engine.py))

### Constants

| Name | Value | Meaning |
|---|---|---|
| `ORDER_RETRY_S` | 1.0 s | Minimum gap between open attempts while `OPENING` |
| `RESOLVE_TIMEOUT_S` | 10 s | How long `RESOLVING` waits for the closing deal in history before giving up (reason `UNKNOWN`, P/L 0) |
| `ALERT_THROTTLE_S` | 5 s | Repeating errors (rejected order/close) are logged every tick but toasted at most once per 5 s |
| `ACCOUNT_POLL_S` | 1 s | Account (balance/equity) refresh in `run()` |
| `ACTIVE` | ARMED, OPENING, IN_POSITION, RESOLVING | States in which ticks are processed |

### Concurrency

`self.lock` (an `asyncio.Lock`) is held by `step()` and by every public action (`arm`, `stop_now`,
`request_stop_after_cycle`, `close_all_and_stop`, `resume`, `set_symbol`). A user click can never interleave
with a half-processed tick.

### Main loop: `run(poll_s, stop)`

1. If disconnected → `_try_reconnect()` (`broker.reconnect()`, reload symbol, toast "reconnected"). Backoff 1 → 2 → … → 30 s.
2. If connected → `step()`. Every 1 s it also calls `broker.account()` → `emit("account")`.
3. `BrokerDisconnected` → `_on_disconnect` (`connected=False`, error toast, **no new orders**). Any other exception → logged + `_alert("Engine error: …")`. The loop never dies.

`step()`: `tick()` → `emit("tick")` → if state ∈ ACTIVE → `_process(tick)`.

### `_process(tick)` order of checks

1. **Daily loss** (only if `daily_loss_limit` set and nothing is already closing): realized P/L since local midnight (`repo.realized_pnl_since`) + `self.floating`. If ≤ −limit: store `settings.daily_loss_block = today`. Then, if `IN_POSITION`, set `pending_close = DAILY_LOSS`; else if not `RESOLVING`, stop `DAILY_LOSS`.
2. **Stop price** (only after ≥ 1 cycle has filled this session, and nothing is already closing): `levels.stop_reached` (BUY: bid ≥ stop, SELL: ask ≤ stop). If `IN_POSITION`, set `pending_close = STOP_PRICE`; if `ARMED`/`OPENING`, stop `STOP_PRICE`. Not checked before C1 fills, so a far-away price at arm time does not stop the bot.
3. **State handler** — see the table below.

### States as implemented

| State | Handler | What happens | Exits |
|---|---|---|---|
| `IDLE` | — | Nothing. Initial state, and the end of a SINGLE session | `arm()` → ARMED |
| `ARMED` | `_on_armed` | `TouchTrigger.update(price on trigger_price_side)`; refreshes the `waiting` text | touch → OPENING (handled in the same tick) |
| `OPENING` | `_on_opening` | (a) price more than `max_slippage_points` from planned → re-arm a new trigger → ARMED ("wait for another touch"); (b) spread > max → wait; (c) outside `trading_hours` → wait; (d) throttle to 1 attempt/s; (e) **idempotency**: if any position with our magic exists → attach it if its comment has `session=<id>`, else stop `DUPLICATE_GUARD`; (f) `open_market` with planned TP/SL rounded to `spec.digits` and `deviation = max_slippage_points / spec.point` | filled → `_on_filled` → IN_POSITION; fatal → STOPPED `ORDER_ERROR`; retryable → stay (alert) |
| `IN_POSITION` | `_on_in_position` | Looks up our ticket in `positions()`. Updates `floating` (`emit("floating")`). If `pending_close` is set → `_try_close_tracked()` **every tick** until the broker accepts it | ticket gone → RESOLVING (handled in the same tick) |
| `RESOLVING` | `_on_resolving` | `close_info(ticket)`; retries each tick for up to 10 s. `_classify`: `pending_close` wins; else deal reason; OTHER/EXPERT is inferred from the close price within max(slippage, 0.5) of TP/SL; else UNKNOWN. Updates the journal row and session P/L | see routing below |
| `STOPPED` | — | Ticks are ignored. Can be `resumable` after a restart | `arm()`, `resume()` |

**Routing after a close (`_on_resolving`):**

| Close reason | CYCLE mode | SINGLE mode |
|---|---|---|
| TP | `_start_next_cycle` | IDLE (`COMPLETE`) |
| SL | STOPPED `SL` ("C{n} hit SL at …, bot stopped") | IDLE (`COMPLETE`) |
| MANUAL (closed in MT5) | STOPPED `MANUAL_CLOSE` | same |
| STOP_PRICE / KILL_SWITCH / DAILY_LOSS | STOPPED with that reason | same |
| STOP_OUT / UNKNOWN | STOPPED, error level | same |

**`_start_next_cycle`** checks, in order:
1. `stop_after_cycle` → STOPPED `STOP_AFTER_CYCLE`.
2. `max_cycles` reached → STOPPED `MAX_CYCLES`.
3. Compute `next_entry(anchor_entry, cur_tp, gap)`. If it is at/beyond the stop price → STOPPED `STOP_PRICE`.
4. Otherwise `cycle_no += 1`. If `opens_immediately` (gap blank, or `gap_entry_mode=immediate`) → OPENING (same tick). Else re-arm a trigger at the next entry → ARMED.

**Levels:** TP/SL come from the planned entry (`level_anchor=planned`). With `fill`, the engine calls `modify_position`
after the fill; if that fails it keeps the planned levels and toasts an error. `cycle_sl` with `sl_mode=previous_entry`
uses the previous cycle's anchor entry, falling back to points when that entry isn't on the losing side.

### Public actions

| Action | Behaviour |
|---|---|
| `arm(cfg)` | Refuses if: already active, disconnected, daily-loss block today, any magic position open, or `validate_config` errors. Ends a pending resumable session. Creates a session (8-hex id), C1 planned = trigger, `TouchTrigger.arm` |
| `stop_now()` | STOPPED `MANUAL_STOP`. **An open position is left open** with its server-side TP/SL |
| `request_stop_after_cycle()` | ARMED → stop immediately. Otherwise sets the `stop_after_cycle` flag |
| `close_all_and_stop()` | Kill switch. Closes every untracked magic position (3 attempts, 0.3 s apart). Tracked + IN_POSITION → `pending_close=KILL_SWITCH` (closed by the loop with retries). RESOLVING → `stop_after_cycle`. Other active → STOPPED `KILL_SWITCH`. Works while STOPPED/IDLE too, for leftovers |
| `resume()` | Only when `resumable`: reattaches a live position (IN_POSITION); resolves one that closed while down (RESOLVING → continues by the rules); adopts an own-session position (attach); refuses on a foreign magic position; otherwise re-arms at `planned_entry` |
| `set_symbol(symbol)` | Only when not active; reloads `SymbolSpec` |

### `emit(kind, payload)` events (→ `Hub.publish`)

`tick` {bid, ask, time} · `state` (`snapshot()`) · `account` (AccountInfo) · `floating` {profit} ·
`log` {ts, level, msg} · `toast` {ts, level, msg} · `cycle` (journal row).

`snapshot()` fields: state, session_id, symbol, connected, config, cycle_no, trigger_level, planned_entry, tp, sl,
next_entry, stop_price, position (+profit), session_pnl, waiting, stop_reason, resumable, stop_after_cycle,
pending_close, daily_loss_block, spec.

## 5. Persistence ([repo.py](../backend/app/storage/repo.py))

One `sqlite3` connection (`check_same_thread=False`, guarded by a `threading.Lock`, WAL, autocommit). Default path `data/goldcycle.db`.

| Table | Columns |
|---|---|
| `sessions` | id (8 hex, PK), mode, direction, symbol, config_json, state, runtime_json, cycle_no, pnl, stop_reason, started_at, ended_at |
| `cycles` | id, session_id, cycle_no, direction, planned_entry, fill_price, slippage (pts, + = worse), tp, sl, volume, ticket, open_time, close_time, close_price, close_reason, pnl |
| `events` | id, ts, session_id, level, from_state, to_state, message — every `_set_state` and `_log` |
| `settings` | key, value — `symbol` (chosen in UI), `daily_loss_block` (ISO date) |
| `audit` | id, ts, username, ip, action, payload — every user action + login attempts |

**`runtime_json`** (written on every transition by `_persist`): cycle_no, planned_entry, anchor_entry, prev_entry,
cur_tp, cur_sl, position {ticket, fill_price, tp, sl, volume, open_time}, cycle_row_id, cycles_opened, session_pnl,
stop_after_cycle, pending_close, resumable, resume_state.

**Session lifecycle:** `ended_at` is set when a session reaches STOPPED (not resumable) or IDLE (single complete), or
when a new `arm()` replaces a resumable one. `last_open_session()` = newest row with `ended_at IS NULL`.

**Recovery** (`recover(auto_resume)`, called once the broker is connected):
1. Load the last open session; `resume_state` = runtime `resume_state` or the stored state.
2. If that state is IDLE/STOPPED, end the session and do nothing.
3. Otherwise restore cfg + runtime, set `resumable=True`. If `RESUME_ON_RESTART=true` → `resume()`. Else → STOPPED
   `RESTART` with a "Resume?" toast. `resume_state` stays persisted, so a second restart is still resumable.
4. The session's stored `symbol` replaces the configured one.

## 6. API reference

Auth: **S** = valid session cookie required (401 otherwise). **S+C** = session + `X-CSRF-Token` header (403 otherwise).

| Method | Path | Auth | Body / query | Returns |
|---|---|---|---|---|
| GET | `/health` | public | — | `{ok, broker, connected, state}` |
| POST | `/api/auth/login` | public, rate-limited | `{username, password}` | `{username, csrf}` + `gc_session` cookie; 401 wrong, 429 blocked, 503 no hash configured |
| POST | `/api/auth/logout` | — | — | `{ok}` (deletes session + cookie) |
| GET | `/api/auth/me` | S | — | `{username, csrf}` |
| GET | `/api/bot/status` | S | — | `{engine: snapshot, account, tick, broker, dry_run}` |
| POST | `/api/bot/validate` | S | raw config dict | `{errors[], warnings[], ladder[5]}` — always 200; pydantic errors become `errors` |
| POST | `/api/bot/arm` | S+C | raw config dict | snapshot; 422 invalid config, 409 `EngineError` |
| POST | `/api/bot/stop` | S+C | — | snapshot; 409 if not running |
| POST | `/api/bot/stop-after-cycle` | S+C | — | snapshot; 409 |
| POST | `/api/bot/close-all` | S+C | — | snapshot |
| POST | `/api/bot/resume` | S+C | — | snapshot; 409 "Nothing to resume" |
| GET | `/api/settings` | S | — | `{symbol, symbols, symbols_error, broker, dry_run, magic, resume_on_restart}` |
| POST | `/api/settings/symbol` | S+C | `{symbol}` | `{symbol}`; 409 while running / unknown symbol; saved to `settings.symbol` |
| POST | `/api/settings/test-connection` | S+C | — | `{ok, account, tick, spec}` or `{ok:false, error}` |
| GET | `/api/candles` | S | `tf` (M1…D1), `count` (10–5000) | `Candle[]`; 422 bad tf, 503 broker error |
| GET | `/api/history/cycles` | S | `session_id?`, `limit` (≤1000) | rows, newest first |
| GET | `/api/history/sessions` | S | `limit` (≤500) | rows |
| GET | `/api/history/events` | S | `limit` (≤1000) | rows |
| GET | `/api/reports/summary` | S | `since` (epoch s, 0 = all; filters by session start) | `{kpis, equity[], daily[], reasons[], sessions[]}` from [reports.py](../backend/app/reports.py) `build_report` |
| GET | `/api/reports/cycles.csv` | S | `since` | CSV download of cycles (audited as `export_csv`) |
| WS | `/ws` | session cookie | client sends `ping` text every 20 s (ignored) | server push only; closes **4401** without a session |

### WebSocket ([ws.py](../backend/app/ws.py))

Message shape: `{"type": kind, "data": payload}`.

| Kind | Delivery |
|---|---|
| `tick`, `state`, `account`, `floating` | **Coalesced:** only the latest value per kind is sent, at most every 100 ms (about 10/s whatever the poll rate) |
| `log`, `toast`, `cycle` | **Queued** in order (queue capped at 500), flushed every 100 ms |

On connect the hub sends the latest coalesced values, then the endpoint sends a fresh `state` snapshot.

## 7. Frontend

```
App (MotionConfig reducedMotion="user"; GET /api/auth/me)
├─ Login
└─ Dashboard              owns: engine, cycles, logs, toasts, modals
   ├─ TopBar
   ├─ PriceChart          tickRef callback updates the last bar without React re-render
   ├─ Journal
   ├─ ControlPanel        form → POST /api/bot/validate (debounced 250 ms) → errors/warnings/ladder
   │   └─ RunningCard
   ├─ LogDrawer · SettingsModal · ConfirmModal (kill) · Toasts
```

**Data flow:**
1. On mount: `GET /api/bot/status` and `/api/history/events`.
2. `useSocket` keeps `engine`, `account`, `tick`, `floating` live.
3. `cycle` messages upsert journal rows by id.
4. `/api/history/cycles?session_id=` is refetched whenever `engine.session_id` changes.
5. Action responses (snapshots) are applied immediately; the WS state then confirms them.

**Chart:**
- Candles come from `/api/candles`. Ticks update the current bar using the bid.
- Price lines appear only in ACTIVE states: trigger (blue dashed), entry (gold, = fill or planned), TP (green), SL (red), next planned entry (grey dotted, hidden when equal to the trigger), stop (amber).
- Markers: arrow at cycle open, circle at close (TP green / SL red / other amber), snapped to bar time.

**Other behaviour:**
- **localStorage:** only `goldcycle.form.v1` ({mode, form}) is stored, wrapped in try/catch. While a session runs, the form is replaced by the running config.
- **Hotkey:** Ctrl+Shift+K opens the "Close all & stop" confirm.

## 8. Security summary

| Control | Where |
|---|---|
| Bind 127.0.0.1 by default; warning logged for any other `HOST` | `main.main()` |
| Single admin user; argon2 hash in `.env` (`python -m app.security`) | [security.py](../backend/app/security.py), [auth.py](../backend/app/api/auth.py) |
| Session cookie `gc_session`: random 32-byte token, httpOnly, `SameSite=strict`, `secure=False` (plain http on localhost), max-age `SESSION_TTL_HOURS` | `auth.login` |
| Sessions live in memory: a server restart logs everyone out | `SessionStore` |
| CSRF: per-session token returned by login/me, required as `X-CSRF-Token` on every state-changing POST (constant-time compare) | `csrf_session` |
| Login rate limit: 5 failures per IP per 5 min → 429 | `LoginLimiter` |
| Headers: `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`; OpenAPI/docs disabled | `create_app` |
| Server-side validation of every input (`CycleConfig`, pydantic bodies) | api/* |
| Audit table: login, login_failed, login_blocked, arm (with payload), stop, stop_after_cycle, close_all, resume, set_symbol, test_connection | `repo.audit` |
| MT5 password is a `SecretStr`, read only from `.env`, never logged or sent to the UI | config / gateway |
