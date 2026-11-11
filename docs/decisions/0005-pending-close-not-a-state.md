# ADR-0005: Bot-initiated close is a flag inside IN_POSITION, not a new state

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.5 (retry close every tick), §4.8, §5 (kill switch, daily loss)

## Context
Stop price, kill switch and daily loss all need "close this trade, retry until it's gone, then
stop". The spec's state list has no CLOSING state, and the UI badge only knows the spec's states.

## Decision
`engine.pending_close: CloseReason | None` (STOP_PRICE / KILL_SWITCH / DAILY_LOSS). While it is set
the state stays **IN_POSITION**, and `_on_in_position` sends a market close **every tick** until the
position is gone (alert toast at most every 5 s). Then the normal RESOLVING path records the cycle
with that reason and stops. `pending_close` is persisted, so a restart continues closing.

## Alternatives considered
- A CLOSING state: one more state in the UI, recovery and tests, with no behavioural gain.

## Consequences
The UI shows "Closing position (REASON)…" from `snapshot.pending_close`. Close reason in the
journal = the bot's reason, even if TP/SL hit at the same instant (P/L is still the broker's).

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `_try_close_tracked`, `_on_in_position`, `_classify`
- Tests: `test_stop_price_mid_cycle_closes_trade_and_stops` (2 rejected closes then success), `test_kill_switch_closes_and_stops`, `test_daily_loss_limit_closes_and_blocks_new_arms`
