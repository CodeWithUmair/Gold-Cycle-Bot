# Backlog — next work, known limitations, parked ideas

Priority: 🔴 before going live · 🟡 should do · ⚪ nice to have / only if asked.
The spec rule still applies: **no features beyond CLAUDE.md without asking the client.**
When an item is done, move it to the session log in [HANDOFF.md](../HANDOFF.md) and delete it here.

## 🔴 Before going live

| # | Item | Notes |
|---|---|---|
| B1 | Get client answers to Q1, Q2, Q5 | Defaults are wait_for_touch / points / points ([ADR-0001](decisions/0001-open-questions-as-config.md)). Update CLAUDE.md §12 + write a new ADR. |
| B2 | Full trading session on the **Exness demo with DRY_RUN=false** on the client's VPS | Spec §10.3. Watch: requotes (retcode 10004/10020/10021), slippage column, spread waits, close-reason accuracy. |
| B3 | Confirm what "Point" means against the client's real numbers once more | `POINT_SIZE = 1.0` in [levels.py](../backend/app/engine/levels.py). XAUUSDm has 3 digits, so a "point" is 1000 MT5 points. |
| B4 | VPS install dry-run following README exactly | Python 3.11+ (dev machine ran 3.14), Node, NSSM, MT5 auto-login after reboot, `Algo Trading` button on. |
| B5 | Decide the default `max_spread_points` for the client's account type | Default 0.6 (spec). Live XAUUSDm spread on the test demo was ~0.22–0.24. Raw/Zero accounts are lower; Standard can widen at news. |
| B6 | Check the daily-loss day boundary with the client | Uses VPS local midnight ([ADR-0011](decisions/0011-daily-loss-definition.md)). |

## 🟡 Should do

| # | Item | Notes |
|---|---|---|
| B7 | DRY_RUN shows a paper balance (10 000) instead of the real account balance | [ADR-0013](decisions/0013-dry-run-as-paper-broker.md). Seed `SimBroker.balance` from the feed's real balance on connect. |
| B8 | Commission/fees not shown per cycle in the journal | `close_info` already nets them into P/L; split into a column if the client wants it. |
| B9 | Chart markers use engine wall-clock time; candles use broker server time | Exness server time is UTC so they line up. A broker with a GMT+2/3 server would show markers shifted. Fix: store tick time on open/close, or offset by `tick.time − now()`. |
| B10 | "Manual close" on hedging vs "closed by another EA" | Both are not TP/SL, so both stop the bot (safe). If the client runs other EAs, give GoldCycle a unique `MAGIC`. |
| B11 | Frontend bundle is 589 kB (189 kB gzip) | Fine on localhost. Code-split lightweight-charts if remote access is ever added. |
| B12 | Engine `step()` polls `positions_get` every tick while IN_POSITION | Spec says "on change". It's a cheap local IPC call; revisit only if CPU on the VPS is an issue. |
| B13 | Starlette TestClient deprecation warning (wants `httpx2`) | Harmless. Pin or switch when FastAPI's testclient moves. |
| B15 | Daily-loss check uses the floating P/L from the previous tick | `_process` checks before `_on_in_position` refreshes `floating` → one poll (~100 ms) late. Fix by refreshing floating first. |
| B16 | `recover()` restores the session's stored symbol, overriding `SYMBOL` in `.env` | Intentional (positions belong to that symbol), but log a warning when they differ. |
| B17 | `/api/auth/logout` has no session/CSRF check and isn't audited | Low impact (only deletes a cookie). Add `current_session` + audit. |
| B18 | C1 wait text always says "return to"; `snapshot()` reads SQLite for the daily block on every emit | Cosmetic / minor perf. |
| B14 | No frontend tests | Logic lives server-side (ADR-0015). Add a Playwright smoke test (login → arm in sim → see ARMED) if the UI grows. |

## ⚪ Parked (only if the client asks)

- Remote access via Tailscale (needs `secure=True` cookie behind HTTPS) — §9 "later".
- Martingale / `lot_multiplier` in the UI — hidden by spec §4.7 (backend field exists, default 1.0).
- Multiple symbols / multiple simultaneous sessions — the spec says one trade at a time.
- Telegram/email notifications.
- Continue/reverse after SL — **explicitly rejected** by the client (§4.4). Do not build.
- "Enter now" when price is past the trigger — **explicitly rejected** (§4.6). Do not build.
