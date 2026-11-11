# ADR-0013: DRY_RUN = paper fills on real MT5 prices

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §10.3

## Context
"Keep a DRY_RUN=true flag that logs intended orders without sending them." If orders were only
logged, the engine would never see a position, so it would sit in OPENING forever and the rest of
the chain could not be watched.

## Decision
`BROKER=mt5` + `DRY_RUN=true` → `SimBroker(feed=Mt5Gateway)`:
- Prices, candles, symbol spec and account identity come from MT5.
- Orders are logged (`[dry-run] ORDER …`) and filled virtually at the current ask/bid. TP/SL are
  evaluated on real ticks like a server would (BUY on bid, SELL on ask). P/L uses the contract size.
- The balance shown is a paper balance (starts at 10 000), not the real account's. Fixing that is
  in the backlog.
- `BROKER=sim` (no MT5) = the same SimBroker with a random-walk price feed, for development on any OS.

## Consequences
The whole cycle chain can be watched on live prices with zero risk. Paper fills have no
requotes/slippage beyond the spread, so the real demo run (DRY_RUN=false on a demo account) is
still required before live.

## Code / tests
- [sim_broker.py](../../backend/app/broker/sim_broker.py), [main.py](../../backend/app/main.py) `build_broker`
