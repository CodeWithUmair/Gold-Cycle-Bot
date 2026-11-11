# ADR-0017: WebSocket coalesces high-rate messages, 100 ms flush

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §8 ("throttle WS updates to ~10/s for ticks")

## Decision
The engine calls `hub.publish(kind, payload)` synchronously. `tick`, `state`, `account`, `floating`
keep only the **latest** value. `log`, `toast`, `cycle` are queued (cap 500). A sender task flushes
every 100 ms. New clients first receive the latest coalesced values plus a fresh state snapshot.
The frontend updates the chart through a ref callback (no React re-render per tick).

## Consequences
Measured: ~10 tick messages/s at the 100 ms engine poll. Log lines are never dropped (unless more
than 500 within 100 ms).

## Code
- [ws.py](../../backend/app/ws.py), [useSocket.ts](../../frontend/src/hooks/useSocket.ts), [PriceChart.tsx](../../frontend/src/components/PriceChart.tsx)
