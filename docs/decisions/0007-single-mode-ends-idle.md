# ADR-0007: SINGLE ends in IDLE on TP or SL; CYCLE SL → STOPPED

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.4, §4.9

## Context
§4.9: SINGLE is the engine with `max_cycles = 1` and ends `RESOLVING → IDLE`. §4.4: SL → STOPPED.

## Decision
- SINGLE: TP **or** SL → IDLE, stop_reason `COMPLETE`, session ended. Both are the normal end of
  the one trade. Manual / stop-out / unknown → STOPPED.
- CYCLE: SL → STOPPED with toast "C{n} hit SL at {price}, bot stopped" (exact spec wording).
- SINGLE forces `max_cycles = 1`, `cycle_gap = None`, `stop_price = None` in the validator.

## Consequences
Both IDLE and STOPPED accept a new Arm. The difference is only how the badge reads.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `_finish_single`, `_on_resolving`
- Tests: `test_single_mode_returns_to_idle`, `test_sl_hit_stops_bot`
