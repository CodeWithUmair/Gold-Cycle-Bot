# ADR-0011: Daily loss = realized today (all sessions) + floating

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §5

## Context
"daily_loss_limit — stop all + no new trades for the day". The spec doesn't define what counts as
the day's loss or the day boundary.

## Decision
- `pnl_today = SUM(cycles.pnl WHERE close_time >= local midnight)` across **all** sessions
  + the current floating P/L. Checked every tick while active and `daily_loss_limit` is set.
- Hit → IN_POSITION: pending close DAILY_LOSS (ADR-0005). Otherwise → STOPPED `DAILY_LOSS`.
- Writes `settings.daily_loss_block = <today ISO date>`. `arm()` refuses while it equals today.
- Day boundary = **VPS local time** (same clock as `trading_hours`).

## Alternatives considered
- Account-equity based (start-of-day equity vs now): would count manual trades the bot didn't make.

## Consequences
Only the bot's own trades count. If the VPS timezone differs from the trader's, the reset happens
at VPS midnight. Note this for the client.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `_process`, `_daily_block_active`
- Tests: `test_daily_loss_limit_closes_and_blocks_new_arms`
