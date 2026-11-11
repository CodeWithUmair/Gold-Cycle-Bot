"""Pure level math (CLAUDE.md §4.2-4.5). No I/O.

"Point" here is the client's point: 1.00 of price (4000 -> 4003 is 3 points),
NOT MT5's `symbol.point`. Change POINT_SIZE to redefine it everywhere.
"""

from dataclasses import dataclass

from app.engine.models import CycleConfig, Direction, Mode

POINT_SIZE = 1.0
_EPS = 1e-9


def points_to_price(points: float) -> float:
    return points * POINT_SIZE


def price_to_points(price_delta: float) -> float:
    return price_delta / POINT_SIZE


def sign(direction: Direction) -> int:
    return 1 if direction == Direction.BUY else -1


def _r(x: float) -> float:
    # Kill float noise (4000.1 + 0.2 = 4000.3000000000002); real rounding to symbol digits happens at send time.
    return round(x, 6)


def tp_price(entry: float, direction: Direction, tp_points: float) -> float:
    return _r(entry + sign(direction) * points_to_price(tp_points))


def sl_price(entry: float, direction: Direction, sl_points: float) -> float:
    return _r(entry - sign(direction) * points_to_price(sl_points))


def cycle_sl(
    entry: float,
    direction: Direction,
    sl_points: float,
    sl_mode: str,
    previous_entry: float | None,
) -> float:
    """SL for a cycle. sl_mode='previous_entry' puts it at the previous cycle's entry (Q2),
    falling back to points when there is no previous entry or it isn't on the losing side."""
    if sl_mode == "previous_entry" and previous_entry is not None:
        if sign(direction) * (entry - previous_entry) > _EPS:
            return _r(previous_entry)
    return sl_price(entry, direction, sl_points)


def next_entry(prev_entry: float, prev_tp: float, direction: Direction, gap: float | None) -> float:
    """§4.3: blank gap -> continue from the previous TP; otherwise previous entry +/- gap."""
    if gap is None:
        return _r(prev_tp)
    return _r(prev_entry + sign(direction) * points_to_price(gap))


def opens_immediately(gap: float | None, gap_entry_mode: str) -> bool:
    """Blank gap: price is already at the next entry, open at market. With a gap: wait for a touch (Q1)."""
    return gap is None or gap_entry_mode == "immediate"


def beyond_stop(price: float, direction: Direction, stop_price: float | None) -> bool:
    """True when `price` is at/past the stop price in the cycle's direction."""
    if stop_price is None:
        return False
    return sign(direction) * (price - stop_price) >= -_EPS


def stop_reached(bid: float, ask: float, direction: Direction, stop_price: float | None) -> bool:
    """§4.5: BUY stops when bid >= stop; SELL stops when ask <= stop."""
    if stop_price is None:
        return False
    if direction == Direction.BUY:
        return bid >= stop_price - _EPS
    return ask <= stop_price + _EPS


def lot_for_cycle(lot: float, multiplier: float, cycle_no: int) -> float:
    return lot * multiplier ** (cycle_no - 1)


def round_price(price: float, digits: int) -> float:
    return round(price, digits)


def round_volume(volume: float, step: float) -> float:
    steps = round(volume / step)
    decimals = max(0, len(f"{step:.10f}".rstrip("0").split(".")[1]))
    return round(steps * step, decimals)


@dataclass(frozen=True)
class PlannedCycle:
    cycle: int
    entry: float
    tp: float
    sl: float
    lot: float


def preview_ladder(cfg: CycleConfig, count: int = 5) -> list[PlannedCycle]:
    """Next `count` planned cycles assuming every cycle closes on TP. Stops at stop_price / max_cycles."""
    out: list[PlannedCycle] = []
    entry = cfg.trigger_price
    prev_entry: float | None = None
    limit = 1 if cfg.mode == Mode.SINGLE else count
    if cfg.max_cycles is not None:
        limit = min(limit, cfg.max_cycles)
    for n in range(1, limit + 1):
        if n > 1 and beyond_stop(entry, cfg.direction, cfg.stop_price):
            break
        tp = tp_price(entry, cfg.direction, cfg.tp_pts)
        sl = cycle_sl(entry, cfg.direction, cfg.sl_pts, cfg.sl_mode, prev_entry)
        out.append(PlannedCycle(n, entry, tp, sl, lot_for_cycle(cfg.lot, cfg.lot_multiplier, n)))
        prev_entry, entry = entry, next_entry(entry, tp, cfg.direction, cfg.cycle_gap)
    return out
