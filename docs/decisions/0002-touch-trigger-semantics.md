# ADR-0002: Touch trigger — side recorded at arm, never fire on arm

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.6

## Context
§4.6 says: record the price at arm time; fire when price reaches the level from that side. It also
confirms: *if price is already past the trigger when armed, do not enter — wait for it to come back*.
"Past" is direction-ambiguous (is BUY @ 4000 with price at 4010 past it, or with price at 3990?).

## Decision
- `TouchTrigger.arm(level, price)` stores `side = above | below` (where the price is now).
  It fires when price reaches the level from that side (`<=` from above, `>=` from below).
  Whichever side price starts on, the bot waits for it to come back to the level. That covers
  "past" in both readings.
- If price is **exactly** on the level at arm time, `side = None`. The trigger fires only after
  price has moved off and come back. The bot never enters at the moment of arming.
- The same trigger is used for later cycles in `wait_for_touch` mode.
- The price used is `trigger_price_side` (bid by default, ask, or mid).
- UI text: C1 shows "Waiting for price to return to X"; later cycles show "…touch X".

## Alternatives considered
- Fire immediately when already at the level: violates the confirmed rule.
- Directional "past" logic (BUY past = price below): no evidence of which reading the client means.

## Consequences
A gap through the level (price jumps from 3999 to 4002) still fires. The slippage check
(ADR-0003) then decides whether to open.

## Code / tests
- [trigger.py](../../backend/app/engine/trigger.py)
- Tests: `test_touch_trigger`, `test_price_past_trigger_at_arm_waits_for_return`, `test_price_exactly_at_trigger_at_arm_does_not_enter`
