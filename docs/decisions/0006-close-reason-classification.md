# ADR-0006: Close reason — deal reason first, price inference second

- **Status:** Accepted
- **Date:** 2026-11-11
- **Spec refs:** CLAUDE.md §4.8 (RESOLVING), §6 rule 7

## Context
What happens next depends entirely on *why* a position closed (TP → next cycle, SL → stop,
manual → stop). MT5 gives `deal.reason`, but the closing deal can appear in history a moment after
the position disappears, and some closes come back as OTHER/EXPERT.

## Decision
In RESOLVING:
1. `close_info(ticket)` from `history_deals_get(position=ticket)`. The last OUT/OUT_BY deal gives
   reason and price. P/L = sum of profit + swap + commission + fee over **all** of the position's deals.
2. If no deal yet → retry each tick for up to `RESOLVE_TIMEOUT_S` (10 s), then UNKNOWN (P/L 0, error toast).
3. Mapping: TP→TP, SL→SL, CLIENT/MOBILE/WEB→MANUAL, SO→STOP_OUT. If the bot itself asked for the
   close (`pending_close`), that reason wins.
4. EXPERT/OTHER without a bot request → infer: within max(slippage, 0.5) pt of TP → TP, of SL → SL,
   else UNKNOWN.
5. Anything other than TP/SL (and the bot's own reasons) → STOPPED. The bot never fights the trader.

## Consequences
Another EA closing our position (same magic) would be read as TP/SL only if it happens near those
levels. Otherwise the bot stops, which is the safe failure.

## Code / tests
- [mt5_gateway.py](../../backend/app/broker/mt5_gateway.py) `close_info`
- [cycle_engine.py](../../backend/app/engine/cycle_engine.py) `_classify`, `_on_resolving`
- Tests: `test_manual_close_stops_bot`, `test_sl_hit_stops_bot`, `test_buy_tp_chain_x3_with_gap`
