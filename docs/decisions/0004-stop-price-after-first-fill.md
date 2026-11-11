# ADR-0004: Stop price only acts after the first fill

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.5

## Context
BUY stops when bid ≥ stop_price. If the trader arms BUY @ 4000 / stop 4010 while price is 4015
(waiting for a pullback), a literal check would stop the bot on the first tick, before it ever traded.

## Decision
- Validation: BUY needs `stop_price > trigger`, SELL needs `stop_price < trigger` (pydantic error otherwise).
- The live stop-price check runs only when `cycles_opened > 0`.
  - IN_POSITION → set `pending_close = STOP_PRICE`, close at market, retry every tick (ADR-0005).
  - ARMED / OPENING (between cycles) → STOPPED `STOP_PRICE`.
  - RESOLVING → not checked. The next state decides.
- Separately, when computing the next entry, if it is at or beyond the stop price → STOPPED (§4.5 last bullet).
- The form shows a warning if price is already beyond the stop at arm time.

## Consequences
Before C1 fills, the stop price has no effect. That matches "stop bot cycle at position": it ends a
running cycle chain and doesn't block the start.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `_process`, `_start_next_cycle`
- [levels.py](../../backend/app/engine/levels.py) `stop_reached`, `beyond_stop`
- Tests: `test_stop_price_mid_cycle_closes_trade_and_stops`, `test_next_entry_beyond_stop_price_stops_chain`
