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


def reentry_after_sl(cycle_entry: float, direction: Direction, gap: float | None) -> float:
    """§4.4: after order 2's SL the next cycle starts again from this cycle's entry,
    shifted by the gap in the trade direction (Q6, confirmed)."""
    return _r(cycle_entry + sign(direction) * points_to_price(gap or 0.0))


def beyond_stop(price: float, cfg: CycleConfig) -> bool:
    """True when `price` is at/past the stop price. The stop price is free (either side of the trigger):
    above the trigger it is hit when price rises to it, below the trigger when price falls to it."""
    if cfg.stop_price is None:
        return False
    side = 1 if cfg.stop_price > cfg.trigger_price else -1
    return side * (price - cfg.stop_price) >= -_EPS


def stop_reached(bid: float, ask: float, cfg: CycleConfig) -> bool:
    """§4.5, measured on the price the open trade closes at: bid for BUY, ask for SELL."""
    return beyond_stop(bid if cfg.direction == Direction.BUY else ask, cfg)


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
    """One planned order. CYCLE: leg 1 = entry + TP (no SL); leg 2 = at leg 1's TP, SL at leg 1's entry (no TP)."""

    cycle: int
    leg: int
    entry: float
    tp: float | None
    sl: float | None
    lot: float


def preview_ladder(cfg: CycleConfig, count: int = 5) -> list[PlannedCycle]:
    """The next `count` planned orders (§4.1). CYCLE: each cycle is order 1 then order 2; the next cycle
    assumes order 2 hit its SL and restarts at the cycle entry (+ gap). Stops at stop_price / max_cycles."""
    lot = lot_for_cycle(cfg.lot, cfg.lot_multiplier, 1)
    if cfg.mode == Mode.SINGLE:
        e, d = cfg.trigger_price, cfg.direction
        tp = None if cfg.tp_points is None else tp_price(e, d, cfg.tp_points)
        sl = None if cfg.sl_points is None else sl_price(e, d, cfg.sl_points)
        return [PlannedCycle(1, 1, e, tp, sl, lot)]
    out: list[PlannedCycle] = []
    entry, n = cfg.trigger_price, 1
    while len(out) < count and (cfg.max_cycles is None or n <= cfg.max_cycles):
        if n > 1 and beyond_stop(entry, cfg):
            break
        tp = tp_price(entry, cfg.direction, cfg.tp_pts)
        out.append(PlannedCycle(n, 1, entry, tp, None, lot))
        if len(out) == count or beyond_stop(tp, cfg):
            break
        out.append(PlannedCycle(n, 2, tp, None, entry, lot))
        entry, n = reentry_after_sl(entry, cfg.direction, cfg.cycle_gap), n + 1
    return out
