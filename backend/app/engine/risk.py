"""Safety checks and pre-arm validation (CLAUDE.md §5). No I/O."""

from datetime import time

from app.broker.base import SymbolSpec, Tick
from app.engine import levels
from app.engine.models import CycleConfig


def spread_points(tick: Tick) -> float:
    return levels.price_to_points(tick.ask - tick.bid)


def spread_ok(tick: Tick, max_spread_points: float | None) -> bool:
    return max_spread_points is None or spread_points(tick) <= max_spread_points + 1e-9


def within_slippage(price: float, planned: float, max_slippage_points: float) -> bool:
    return abs(levels.price_to_points(price - planned)) <= max_slippage_points + 1e-9


def in_trading_hours(now: time, window: str | None) -> bool:
    if not window:
        return True
    start_s, end_s = window.split("-")
    start = time.fromisoformat(start_s)
    end = time.fromisoformat(end_s)
    t = now.replace(second=0, microsecond=0, tzinfo=None)
    if start <= end:
        return start <= t < end
    return t >= start or t < end  # window wraps midnight


def daily_loss_hit(pnl_today: float, limit: float | None) -> bool:
    return limit is not None and pnl_today <= -limit


def validate_lot(lot: float, spec: SymbolSpec) -> list[str]:
    errors = []
    if lot < spec.volume_min - 1e-9:
        errors.append(f"Lot {lot} is below the minimum {spec.volume_min}")
    if lot > spec.volume_max + 1e-9:
        errors.append(f"Lot {lot} is above the maximum {spec.volume_max}")
    steps = lot / spec.volume_step
    if abs(steps - round(steps)) > 1e-6:
        errors.append(f"Lot {lot} is not a multiple of the lot step {spec.volume_step}")
    return errors


def validate_config(cfg: CycleConfig, spec: SymbolSpec, tick: Tick | None) -> tuple[list[str], list[str]]:
    """Broker-aware checks shown in the UI before arming. Returns (errors, warnings)."""
    errors = validate_lot(cfg.lot, spec)
    warnings: list[str] = []

    # stops level / freeze level: TP and SL must be at least this far from the price
    min_dist_price = max(spec.stops_level, spec.freeze_level) * spec.point
    if min_dist_price > 0:
        min_pts = levels.price_to_points(min_dist_price)
        for name, pts in (("TP", cfg.tp_pts), ("SL", cfg.sl_pts)):
            if levels.points_to_price(pts) < min_dist_price:
                errors.append(f"{name} {pts} pts is closer than the broker minimum of {min_pts:g} pts")

    ladder = levels.preview_ladder(cfg, 2)
    if len(ladder) > 1 and cfg.sl_mode == "previous_entry":
        sl_dist = abs(ladder[1].entry - ladder[1].sl)
        if min_dist_price > 0 and sl_dist < min_dist_price:
            errors.append("SL at previous entry is closer than the broker minimum distance")

    if tick is not None:
        price = cfg.trigger_price
        cur = tick.bid
        if abs(price - cur) > 200:
            warnings.append(f"Trigger {price} is far from the current price {cur:.2f}")
        if price == cur:
            warnings.append(
                f"Price is exactly at the trigger; the bot waits for price to move off and return to {price}."
            )
        if not spread_ok(tick, cfg.max_spread_points):
            warnings.append(
                f"Current spread {spread_points(tick):.2f} pts is wider than max {cfg.max_spread_points} pts"
            )
        if cfg.stop_price is not None and levels.stop_reached(tick.bid, tick.ask, cfg.direction, cfg.stop_price):
            warnings.append("Price is already beyond the stop price")
    return errors, warnings
