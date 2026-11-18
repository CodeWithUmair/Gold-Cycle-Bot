"""Client's cycle rule (CLAUDE.md §4.1, confirmed 2026-11-18) as acceptance tests.

A cycle is two orders. Order 1: entry 4000, TP 4003, no SL. When it hits TP, order 2 opens at 4003
with SL 4000 (order 1's entry) and no TP. When order 2 hits its SL, the next cycle starts again at
4000 (+ gap in the trade direction).
"""

from datetime import time

import pytest

from app.broker.base import SymbolSpec, Tick
from app.engine import levels, risk
from app.engine.models import CycleConfig, Direction, Mode
from app.engine.trigger import TouchTrigger

# (cycle, order, entry, tp, sl)
BUY_GAP_BLANK = [(1, 1, 4000, 4003, None), (1, 2, 4003, None, 4000), (2, 1, 4000, 4003, None), (2, 2, 4003, None, 4000)]
BUY_GAP_2 = [(1, 1, 4000, 4003, None), (1, 2, 4003, None, 4000), (2, 1, 4002, 4005, None), (2, 2, 4005, None, 4002)]
SELL_GAP_2 = [(1, 1, 4000, 3997, None), (1, 2, 3997, None, 4000), (2, 1, 3998, 3995, None), (2, 2, 3995, None, 3998)]


def cfg(direction: Direction, gap: float | None, **kw: object) -> CycleConfig:
    base: dict[str, object] = dict(
        mode=Mode.CYCLE, direction=direction, trigger_price=4000, lot=0.01, tp_points=3, sl_points=3, cycle_gap=gap
    )
    base.update(kw)
    return CycleConfig.model_validate(base)


def rows(c: CycleConfig, count: int) -> list[tuple[int, int, float, float | None, float | None]]:
    return [(p.cycle, p.leg, p.entry, p.tp, p.sl) for p in levels.preview_ladder(c, count)]


@pytest.mark.parametrize(
    ("direction", "gap", "table"),
    [(Direction.BUY, None, BUY_GAP_BLANK), (Direction.BUY, 2, BUY_GAP_2), (Direction.SELL, 2, SELL_GAP_2)],
)
def test_client_two_order_cycle(
    direction: Direction, gap: float | None, table: list[tuple[int, int, float, float | None, float | None]]
) -> None:
    assert rows(cfg(direction, gap), 4) == table


def test_reentry_after_sl() -> None:
    # Blank gap: start again at the cycle entry. Gap: shifted in the trade direction (Q6, confirmed).
    assert levels.reentry_after_sl(4000, Direction.BUY, None) == 4000
    assert levels.reentry_after_sl(4000, Direction.BUY, 2) == 4002
    assert levels.reentry_after_sl(4000, Direction.SELL, 2) == 3998


def test_sl_points_not_used_in_cycle_mode_but_required_in_single() -> None:
    assert cfg(Direction.BUY, None, sl_points=5).sl_points is None
    assert rows(cfg(Direction.BUY, None, tp_points=5), 2) == [(1, 1, 4000, 4005, None), (1, 2, 4005, None, 4000)]
    with pytest.raises(ValueError):
        CycleConfig(mode=Mode.SINGLE, direction=Direction.BUY, trigger_price=4000, lot=0.01, tp_points=3)


def test_ladder_stops_before_stop_price() -> None:
    # gap 3: C2 starts at 4003; its TP 4006 is past the stop 4005, so order 2 of C2 never opens
    assert [r[2] for r in rows(cfg(Direction.BUY, 3, stop_price=4005), 6)] == [4000, 4003, 4003]


def test_ladder_respects_max_cycles_and_single_mode() -> None:
    assert len(levels.preview_ladder(cfg(Direction.BUY, 2, max_cycles=2), 10)) == 4
    single = CycleConfig(
        mode=Mode.SINGLE, direction=Direction.BUY, trigger_price=4000, lot=0.01, tp_points=4, sl_points=2
    )
    assert [(c.entry, c.tp, c.sl) for c in levels.preview_ladder(single, 5)] == [(4000, 4004, 3998)]


def test_single_mode_exact_prices() -> None:
    c = CycleConfig(
        mode=Mode.SINGLE, direction=Direction.SELL, trigger_price=4000, lot=0.01,
        tp_sl_input="price", tp_price=3995.5, sl_price=4002,
    )  # fmt: skip
    (p,) = levels.preview_ladder(c, 5)
    assert (p.tp, p.sl) == (3995.5, 4002)


def test_config_rejects_bad_input() -> None:
    with pytest.raises(ValueError):
        cfg(Direction.BUY, 2, stop_price=4000)  # stop on the trigger itself
    with pytest.raises(ValueError):
        cfg(Direction.BUY, 2, tp_points=0)
    with pytest.raises(ValueError):
        cfg(Direction.BUY, 2, trading_hours="25:00-26:00")


def test_stop_reached_uses_bid_for_buy_and_ask_for_sell() -> None:
    buy, sell = cfg(Direction.BUY, 2, stop_price=4010), cfg(Direction.SELL, 2, stop_price=3990)
    assert levels.stop_reached(4010.0, 4010.2, buy)
    assert not levels.stop_reached(4009.9, 4010.1, buy)
    assert levels.stop_reached(3989.8, 3990.0, sell)
    assert not levels.stop_reached(3989.8, 3990.1, sell)


def test_stop_price_is_free_on_either_side_of_the_trigger() -> None:
    buy_below = cfg(Direction.BUY, 2, stop_price=3990)  # BUY stop under the trigger: hit when bid falls to it
    assert not levels.stop_reached(3995.0, 3995.2, buy_below)
    assert levels.stop_reached(3990.0, 3990.2, buy_below)
    sell_above = cfg(Direction.SELL, 2, stop_price=4010)  # SELL stop over the trigger: hit when ask rises to it
    assert not levels.stop_reached(4005.0, 4005.2, sell_above)
    assert levels.stop_reached(4009.8, 4010.0, sell_above)
    assert [c.entry for c in levels.preview_ladder(buy_below, 3)] == [4000, 4003, 4002]  # never reaches the stop


def test_touch_trigger() -> None:
    up = TouchTrigger.arm(4000, 3995)
    assert not up.update(3999.9)
    assert up.update(4000)
    down = TouchTrigger.arm(4000, 4005)
    assert not down.update(4000.1)
    assert down.update(3999)
    at = TouchTrigger.arm(4000, 4000)  # exactly at the level: never fire on arm
    assert not at.update(4000)
    assert not at.update(4001)
    assert at.update(4000)


def test_trading_hours_window() -> None:
    assert risk.in_trading_hours(time(9, 0), "08:00-17:00")
    assert not risk.in_trading_hours(time(17, 0), "08:00-17:00")
    assert risk.in_trading_hours(time(23, 30), "22:00-02:00")
    assert risk.in_trading_hours(time(1, 0), "22:00-02:00")
    assert not risk.in_trading_hours(time(3, 0), "22:00-02:00")
    assert risk.in_trading_hours(time(3, 0), None)


def test_validate_config_against_symbol() -> None:
    spec = SymbolSpec("XAUUSD", 2, 0.01, 0.01, 100, 0.01, stops_level=500, freeze_level=0, contract_size=100)
    errors, _ = risk.validate_config(cfg(Direction.BUY, 2, lot=0.015), spec, None)
    assert any("lot step" in e for e in errors)
    assert any("broker minimum" in e for e in errors)  # 3 pts < 5 pts stops level
    errors, warnings = risk.validate_config(
        cfg(Direction.BUY, 2, tp_points=6, sl_points=6), spec, Tick(4000, 4000.2, 0)
    )
    assert errors == []
    assert any("return to 4000" in w for w in warnings)
    assert not any("TP 6 pts is small" in w for w in warnings)
    _, warnings = risk.validate_config(cfg(Direction.BUY, 2, tp_points=0.6), spec, Tick(4010, 4010.24, 0))
    assert any("TP 0.6 pts is small" in w for w in warnings)


def test_round_volume() -> None:
    assert levels.round_volume(0.0299999, 0.01) == 0.03
    assert levels.round_volume(1.25, 0.5) == 1.0
