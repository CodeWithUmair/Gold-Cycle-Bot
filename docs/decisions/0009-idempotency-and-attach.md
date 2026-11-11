# ADR-0009: Never open while any bot position exists; attach our own session's position

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §2 (one trade at a time), §6 rule 5, §7 (idempotency)

## Context
"Never stack positions" and "never open a duplicate after a restart". The dangerous case:
`order_send` times out or the process dies after the broker filled the order but before we recorded it.

## Decision
- Every order carries `magic` and comment `GC|cycle={n}|session={8-hex id}` (≤ 31 chars).
- **Arm** refuses if any position with our magic exists on the symbol.
- **Before every order attempt** (`_on_opening`): list magic positions.
  - One whose comment contains `session={our id}` → **attach** to it (record the cycle row from the
    position, go IN_POSITION). No new order.
  - Any other magic position → STOPPED `DUPLICATE_GUARD` (error toast).
- Resume after restart does the same check.

## Consequences
Running two GoldCycle instances with the same magic on one account will make them block each
other. Use different `MAGIC` values per instance. The live test script uses 7799001 for this reason.

## Code / tests
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `arm`, `_on_opening`, `_attach`, `resume`
- Tests: `test_restart_during_opening_never_duplicates`, `test_stop_now_leaves_position_with_server_side_tp_sl`
