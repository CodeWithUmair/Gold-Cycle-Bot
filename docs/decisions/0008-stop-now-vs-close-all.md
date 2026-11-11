# ADR-0008: "Stop now" leaves the trade; "Close all & stop" closes it

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §8 (buttons), §5 (kill switch)

## Context
The spec lists three stop buttons and doesn't say what "Stop now" does to an open trade.

## Decision
| Button | Open trade | Engine |
|---|---|---|
| Stop after this cycle | finishes at its own TP/SL | stops instead of starting the next cycle (if no cycle is in progress, it stops immediately) |
| Stop now | **left open** with its server-side TP/SL (stated in the log) | STOPPED `MANUAL_STOP` |
| Close all & stop (red, confirm modal, Ctrl+Shift+K) | every position with the bot's magic closed at market | STOPPED `KILL_SWITCH` |

Kill switch details: untracked magic positions get 3 close attempts each. The tracked one goes
through the pending-close loop (ADR-0005). If triggered while RESOLVING, it sets
`stop_after_cycle` so the just-closed cycle is still recorded. It also works when the bot is
already STOPPED (e.g. a position left after a restart).

## Consequences
"Stop now" is non-destructive and needs no confirmation. A bot position left open blocks the next
Arm (ADR-0009) until it closes or the kill switch is used.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `stop_now`, `request_stop_after_cycle`, `close_all_and_stop`
- Tests: `test_stop_now_leaves_position_with_server_side_tp_sl`, `test_stop_after_this_cycle`, `test_kill_switch_closes_and_stops`
