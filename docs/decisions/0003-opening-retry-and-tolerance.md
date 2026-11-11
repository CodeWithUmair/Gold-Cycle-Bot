# ADR-0003: OPENING retries while in tolerance, re-arms when out of tolerance

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.6 (max_slippage_points), §4.8 (rejected → ARMED), §5 (max_spread)

## Context
The state diagram says `OPENING —rejected→ ARMED`, while §4.6 says *retry on the next tick while
price is within tolerance, else log and wait for another touch*. Spread and trading-hours limits
also need a place to "wait".

## Decision
OPENING is a waiting state. On every tick, in this order:
1. If `|trigger-side price − planned entry| > max_slippage_points` → back to **ARMED** with a fresh
   touch trigger ("waiting for another touch").
2. If the spread is above `max_spread_points` → stay in OPENING and show why.
3. If outside `trading_hours` → stay in OPENING and show why.
4. Throttle: at most one order attempt per `ORDER_RETRY_S` (1 s).
5. Idempotency check (ADR-0009), then `order_send` with `deviation = max_slippage_points / symbol.point`.
6. Rejected + retryable → stay in OPENING (toast at most every 5 s). Rejected + fatal retcode
   (no money, invalid stops, Algo Trading off…) → **STOPPED** `ORDER_ERROR`.

## Alternatives considered
- Literal "rejected → ARMED": would need another touch after every requote. Gold requotes often.

## Consequences
A blank-gap cycle (open at market at the previous TP) opens immediately in normal conditions. If
price runs more than 0.5 pt away first, it falls back to waiting for a touch at the planned entry.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `_on_opening`
- Tests: `test_rejected_order_retries_then_rearms_when_price_leaves_tolerance`, `test_spread_too_wide_waits_then_opens`
