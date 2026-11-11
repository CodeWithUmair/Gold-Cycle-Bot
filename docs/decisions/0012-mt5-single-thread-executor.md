# ADR-0012: MT5 calls go through a 1-worker ThreadPoolExecutor

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §6 critical MT5 rules 1, 2, 4, 8

## Context
The `MetaTrader5` package is not thread-safe and blocking. FastAPI and the engine are asyncio.

## Decision
`Mt5Gateway` owns `ThreadPoolExecutor(max_workers=1)`. Every public async method wraps a sync
closure via `run_in_executor`, so all `mt5.*` calls run on that one thread, in submission order.
Nothing outside `mt5_gateway.py` imports MetaTrader5.

Related choices in the same module:
- Filling mode from `symbol_info().filling_mode` bitmask: FOK if bit 1, else IOC if bit 2, else RETURN.
  (Note `ORDER_FILLING_FOK == 0`. A logged "filling 0" means FOK, not "none".)
- Retcodes 10008/10009/10010 = success. A fixed FATAL set (10013–10017, 10019, 10022, 10026, 10027,
  10030, 10040) stops the bot. Everything else is retried.
- After a fill, find the position ticket by matching `ticket`/`identifier` to `result.order`, else via
  the deal's `position_id` (works on hedging and netting).
- Disconnect = `terminal_info().connected` false or a failed tick → `BrokerDisconnected` → engine pauses,
  reconnects with backoff 1→30 s (`mt5.shutdown(); mt5.initialize()`), reloads symbol spec, resumes.

## Consequences
A slow MT5 call blocks the next one, which is fine at a 100 ms poll. Ticks, positions and orders are
naturally serialized, so there are no race conditions inside MT5.

## Code
- [mt5_gateway.py](../../backend/app/broker/mt5_gateway.py), [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `run`, `_try_reconnect`
