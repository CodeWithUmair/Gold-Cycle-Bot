# GoldCycle — Testing

> How the bot is verified, what each test proves, and how to run the live demo test.
> Requirements come from [CLAUDE.md §10](../CLAUDE.md); architecture from [ARCHITECTURE.md](ARCHITECTURE.md).

## 1. Commands

| What | Where | Command |
|---|---|---|
| Unit + engine + recovery + API tests | `goldcycle\backend` | `.\.venv\Scripts\python.exe -m pytest -q` |
| Type check (strict) | `goldcycle\backend` | `.\.venv\Scripts\python.exe -m mypy app tests` |
| Lint | `goldcycle\backend` | `.\.venv\Scripts\python.exe -m ruff check app tests` (and `ruff format app tests`) |
| Frontend type check + build | `goldcycle\frontend` | `npm run build` (runs `tsc --noEmit` then `vite build` → `dist/`) |
| Live demo test (real orders, demo only) | `goldcycle\backend` | `.\.venv\Scripts\python.exe tools\live_demo_test.py single cycle kill` |

Config lives in [backend/pyproject.toml](../backend/pyproject.toml). mypy is `strict`. For `tests.*`, `comparison-overlap`
is disabled because assertions on `engine.state` narrow the type, while the state actually changes across `await`.

Status at end of Session 1: **45 passed**, mypy clean (30 files), ruff clean, frontend build clean.

## 2. Test matrix

### §10.1 Unit — [test_levels.py](../backend/tests/test_levels.py)

| Test | Proves |
|---|---|
| `test_client_tables_gap_2[BUY/SELL]` | Client's §4.1 tables exactly: entries, TPs, "next order" = TP, next order's SL = this entry |
| `test_gap_blank_buy_continues_from_tp` | Gap blank: C2 entry 4003, TP 4006, SL 4000 |
| `test_gap_blank_sell_continues_from_tp` | Same for SELL |
| `test_sl_mode_previous_entry_equals_points_for_3_3` | Q2: both SL modes agree when tp = sl = 3 |
| `test_sl_mode_previous_entry_differs_when_tp_ne_sl` | Q2: previous-entry SL with tp 5 / sl 3 |
| `test_ladder_stops_before_stop_price` | Preview stops at the stop price |
| `test_ladder_respects_max_cycles_and_single_mode` | max_cycles cap; SINGLE = 1 row |
| `test_single_mode_exact_prices` | Q5: price input → derived points → exact TP/SL |
| `test_config_rejects_bad_input` | Stop price on the wrong side, tp 0, bad trading hours |
| `test_stop_reached_uses_bid_for_buy_and_ask_for_sell` | §4.5 sides |
| `test_touch_trigger` | Touch from above/below; **at the level on arm never fires** until price moves off and returns |
| `test_trading_hours_window` | Normal + overnight windows |
| `test_validate_config_against_symbol` | Lot step, stops-level distance, "return to" warning |
| `test_round_volume` | Volume rounding to step |

### §10.2 Engine on `sim_broker` — [test_cycle_engine.py](../backend/tests/test_cycle_engine.py)

| §10.2 scenario | Test(s) |
|---|---|
| TP chain ×3 | `test_buy_tp_chain_x3_with_gap`, `test_sell_tp_chain_with_gap`, `test_gap_blank_opens_next_cycle_immediately_from_tp` |
| SL hit → bot stops | `test_sl_hit_stops_bot` |
| Stop price mid-cycle → trade closed + stop (incl. rejected close retried every tick) | `test_stop_price_mid_cycle_closes_trade_and_stops` |
| Next entry beyond stop price | `test_next_entry_beyond_stop_price_stops_chain` |
| Price already past trigger at arm → wait for return | `test_price_past_trigger_at_arm_waits_for_return`, `test_price_exactly_at_trigger_at_arm_does_not_enter` |
| Manual close | `test_manual_close_stops_bot` |
| Spread too wide | `test_spread_too_wide_waits_then_opens` |
| Rejected order | `test_rejected_order_retries_then_rearms_when_price_leaves_tolerance` |
| SINGLE mode → IDLE | `test_single_mode_returns_to_idle` |
| Stop after this cycle | `test_stop_after_this_cycle` |
| max_cycles | `test_max_cycles` |
| Kill switch | `test_kill_switch_closes_and_stops` |
| Stop now keeps server-side TP/SL; arm refused while a bot position is open | `test_stop_now_leaves_position_with_server_side_tp_sl` |
| Daily loss limit closes + blocks new arms today | `test_daily_loss_limit_closes_and_blocks_new_arms` |
| Disconnect pauses engine (no orders) | `test_disconnect_pauses_engine` |
| `level_anchor=fill` | `test_fill_anchor_moves_tp_sl_to_fill` |

### §10.2 "restart during IN_POSITION" + §7 — [test_recovery.py](../backend/tests/test_recovery.py)

| Test | Proves |
|---|---|
| `test_restart_in_position_waits_for_resume_then_reattaches` | `resume_on_restart=false` → STOPPED + resumable; ignores ticks; Resume reattaches the same ticket; chain continues |
| `test_restart_survives_second_restart_before_resume` | `resume_state` survives a second restart |
| `test_position_closed_on_tp_while_down_continues_chain` | Closed on TP while down → resolved from history → C2 armed |
| `test_position_closed_on_sl_while_down_stops` | Closed on SL while down → STOPPED `SL` |
| `test_restart_during_opening_never_duplicates` | Order filled but not recorded → attach, **no duplicate order** |
| `test_no_unfinished_session_is_a_noop` | Clean start |

### §10.4 + §9 API — [test_api.py](../backend/tests/test_api.py)

| Test | Proves |
|---|---|
| `test_health_is_public` | `/health` without login |
| `test_auth_required_and_rate_limited` | 401 without a session; 5 bad logins → 429 even with the right password |
| `test_csrf_enforced_on_actions` | POST without `X-CSRF-Token` → 403 |
| `test_validate_arm_stop_flow` | validate (errors + ladder), arm, 409 on double arm, WS receives data, stop, history, candles, settings |
| `test_ws_rejects_anonymous` | WS closes (4401) without a cookie |

TestClient quirk: `websocket_connect("/ws")` resolves to `ws://testserver`, so the cookie set for `127.0.0.1` isn't sent.
Always pass the full URL `ws://127.0.0.1/ws`.

## 3. The engine test harness ([tests/helpers.py](../backend/tests/helpers.py))

| Piece | What it does |
|---|---|
| `Harness(start, spread, repo?, sim?)` | Builds `SimBroker` + in-memory `Repo` + `CycleEngine` (symbol `XAUUSD`, magic 777) with a **fake clock** (`clock[0]`) shared by engine and sim, and `local_time` fixed at 12:00. Records every `emit` in `events` |
| `await h.arm(**cfg)` | Loads the symbol and arms `make_cfg(**cfg)`. Default config: CYCLE BUY trigger 4000, lot 0.01, tp 3, sl 3, gap 2 |
| `await h.px(*bids)` | For each bid: advance the clock **1.5 s** (past `ORDER_RETRY_S`), `sim.set_price(bid)` (ask = bid + spread), `engine.step()` |
| `h.cycles()` / `h.logs()` / `h.toasts()` | Journal rows (oldest first) / log messages / toast messages |
| `run(coro)` | `asyncio.run` wrapper. Tests are sync functions; no pytest-asyncio needed |

**SimBroker test hooks** ([sim_broker.py](../backend/app/broker/sim_broker.py)):

| Hook | Effect |
|---|---|
| `sim.reject_next = n` | Next n `open_market` calls return retcode 10006 (retryable) |
| `sim.reject_close_next = n` | Next n `close_position` calls are rejected |
| `sim.manual_close(ticket)` | Closes with deal reason `CLIENT` (trader closed it in MT5) |
| `sim.connected = False` | Every call raises `BrokerDisconnected` |
| `sim.spread = x` | Changes the spread for subsequent `set_price` |

The sim evaluates TP/SL inside `tick()` like the server does: BUY uses the bid (TP when bid ≥ tp, SL when bid ≤ sl),
SELL uses the ask. P/L = sign × Δprice × volume × 100.

**Restart in tests:** `restart(h)` in `test_recovery.py` builds a new `Harness` that reuses the same `repo` and `sim`,
acting as a new process against the same DB and the same live account.

## 4. Live demo test

Script: [backend/tools/live_demo_test.py](../backend/tools/live_demo_test.py). It drives the real `CycleEngine` + `Mt5Gateway`
against the MT5 terminal and **sends real orders**.

```powershell
cd goldcycle\backend
.\.venv\Scripts\python.exe tools\live_demo_test.py single cycle kill   # or any subset
```

| Property | Value |
|---|---|
| Safety | Asserts `account.is_demo`; refuses to run on a real account |
| Symbol / lot | `XAUUSDm`, 0.01 lot (1.00 price move ≈ $1) |
| Magic | `7799001` (different from the app's `7700501`, so it never touches dashboard positions) |
| DB | `backend/tools/live_test.db` (separate from `data/goldcycle.db`) |
| `single` | SINGLE BUY, trigger = bid − 0.3, TP 1 / SL 1; prints the server-side TP/SL on the position; waits for IDLE |
| `cycle` | CYCLE BUY gap blank, trigger = bid + 0.3, TP 0.6 / SL 2, stop = trigger + 1.5, max 3 cycles |
| `kill` | SINGLE BUY TP 10 / SL 10; once in position, calls `close_all_and_stop()` |
| Cleanup | In `finally`: kill switch if still active, prints leftover bot positions (should be 0) |

Requirements: MT5 terminal running and logged in (password saved), Algo Trading enabled, live market hours.
Each scenario waits up to 5–15 min for price to move.

### Results

See [HANDOFF.md](../HANDOFF.md) Session 1 for the latest live results.

## 5. Demo → live checklist (CLAUDE.md §10.3)

| Step | `.env` | Pass criteria |
|---|---|---|
| 1. Automated tests | — | pytest, mypy, ruff, `npm run build` all green |
| 2. Live demo script | demo account | `tools\live_demo_test.py single cycle kill` passes, 0 positions left |
| 3. Dry run on demo | `BROKER=mt5`, `DRY_RUN=true` | Dashboard shows real prices; arm/stop/kill behave; logged "[dry-run] ORDER" lines look right |
| 4. Real orders on demo, **one full trading session** | `DRY_RUN=false`, demo account | Journal matches the MT5 history tab (fills, TP/SL, reasons, P/L); restart mid-trade → Resume works; no duplicate positions |
| 5. Live | `DRY_RUN=false`, live account | Client confirms Q1/Q2/Q5; start with minimum lot; daily loss limit set |
