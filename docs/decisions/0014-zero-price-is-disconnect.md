# ADR-0014: A zero/negative tick is treated as "no price"

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §6 rule 3 (symbol auto-detect)

## Context
On the test demo account `symbols_get("*XAU*USD*")` returned `XAUUSD247m` and `XAUUSDm`.
`XAUUSD247m` had `bid = ask = 0`. Fed into the engine, a SELL trigger would "touch" instantly at 0.

## Decision
`Mt5Gateway.tick()` raises `BrokerDisconnected("<symbol> has no prices … wrong symbol?")` when
bid ≤ 0 or ask ≤ 0. The engine pauses (no orders) and the UI shows MT5 as disconnected with the
message. Auto-detect prefers `XAUUSD`, `XAUUSDm`, `XAUUSDc`, `XAUUSDz` in that order.

## Consequences
Choosing a dead symbol in Settings shows up immediately as a disconnect, not a bad trade.

## Code
- [mt5_gateway.py](../../backend/app/broker/mt5_gateway.py) `tick`, [main.py](../../backend/app/main.py) `pick_symbol`
