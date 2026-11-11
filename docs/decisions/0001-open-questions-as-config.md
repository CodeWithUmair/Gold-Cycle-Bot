# ADR-0001: Open questions Q1/Q2/Q5 shipped as config switches with spec defaults

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.3, §3, §12

## Context
The client's sheet leaves three behaviours ambiguous. The spec says: implement each as a config
option with the stated default, do not block on it.

## Decision
| Q | Switch (CycleConfig field) | Default | Where in UI |
|---|---|---|---|
| Q1 — with a gap, wait for pullback or open at once? | `gap_entry_mode`: `wait_for_touch` \| `immediate` | `wait_for_touch` | Cycle tab → Advanced |
| Q2 — next SL = entry − sl_points, or previous entry? | `sl_mode`: `points` \| `previous_entry` | `points` | Cycle tab → Advanced |
| Q5 — Single TP/SL as points or prices? | `tp_sl_input`: `points` \| `price` | `points` | Single tab toggle |

Details:
- `previous_entry` falls back to points for C1 (no previous entry) and whenever the previous entry
  is not on the losing side of the new entry (e.g. gap 0).
- `price` input is only valid in SINGLE mode. The model converts prices to points
  (`|tp_price − trigger|`), so the engine only ever works in points.

## Alternatives considered
- Hard-code the "most likely" answer — rejected by the spec.

## Consequences
When the client answers, flip the default in `models.py` (and the form default in
`ControlPanel.tsx`), or delete the switch if it is no longer wanted. Write a new ADR.

## Code / tests
- [models.py](../../backend/app/engine/models.py) `CycleConfig._check`
- [levels.py](../../backend/app/engine/levels.py) `cycle_sl`, `opens_immediately`
- Tests: `test_sl_mode_previous_entry_*`, `test_single_mode_exact_prices`, `test_buy_tp_chain_x3_with_gap`
