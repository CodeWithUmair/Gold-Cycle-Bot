"""Client's cycle rule (CLAUDE.md §4.1, confirmed 2026-11-16) as acceptance tests.

C1 enters at 4000, TP 4003. On TP the next trade opens at 4003 (previous TP) with its SL at
4000 (previous entry). The gap only matters after an SL.
"""

from datetime import time

import pytest

from app.broker.base import SymbolSpec, Tick
from app.engine import levels, risk
from app.engine.models import CycleConfig, Direction, Mode
from app.engine.trigger import TouchTrigger

BUY_CHAIN = [(4000, 4003, 3997), (4003, 4006, 4000), (4006, 4009, 4003)]
SELL_CHAIN = [(4000, 3997, 4003), (3997, 3994, 4000), (3994, 3991, 3997)]


def cfg(direction: Direction, gap: float | None, **kw: object) -> CycleConfig:
    base: dict[str, object] = dict(
        mode=Mode.CYCLE, direction=direction, trigger_price=4000, lot=0.01, tp_points=3, sl_points=3, cycle_gap=gap
    )
    base.update(kw)
    return CycleConfig.model_validate(base)


@pytest.mark.parametrize("gap", [None, 2])
@pytest.mark.parametrize(("direction", "table"), [(Direction.BUY, BUY_CHAIN), (Direction.SELL, SELL_CHAIN)])
def test_client_cycle_continues_from_tp(
    direction: Direction, table: list[tuple[int, int, int]], gap: float | None
) -> None:
    # The gap does not move the chain on TP.
    ladder = levels.preview_ladder(cfg(direction, gap), 3)
    assert [(c.entry, c.tp, c.sl) for c in ladder] == table


def test_reentry_after_sl() -> None:
    # Blank gap: start again where the losing trade started. Gap: shifted in the trade direction (Q6, confirmed).
    assert levels.reentry_after_sl(4000, Direction.BUY, None) == 4000
    assert levels.reentry_after_sl(4000, Direction.BUY, 2) == 4002
    assert levels.reentry_after_sl(4000, Direction.SELL, 2) == 3998


def test_sl_optional_in_cycle_mode() -> None:
    ladder = levels.preview_ladder(cfg(Direction.BUY, None, sl_points=None), 3)
    assert [(c.entry, c.sl) for c in ladder] == [(4000, None), (4003, 4000), (4006, 4003)]
    assert [c.sl for c in levels.preview_ladder(cfg(Direction.BUY, None, sl_points=None, sl_mode="points"), 3)] == [
        None, None, None,
    ]  # fmt: skip
    with pytest.raises(ValueError):
        CycleConfig(mode=Mode.SINGLE, direction=Direction.BUY, trigger_price=4000, lot=0.01, tp_points=3)


def test_sl_mode_previous_entry_equals_points_for_3_3() -> None:
    a = levels.preview_ladder(cfg(Direction.BUY, None, sl_mode="points"), 4)
    b = levels.preview_ladder(cfg(Direction.BUY, None, sl_mode="previous_entry"), 4)
    assert [c.sl for c in a[1:]] == [c.sl for c in b[1:]]


def test_sl_mode_previous_entry_differs_when_tp_ne_sl() -> None:
    ladder = levels.preview_ladder(cfg(Direction.BUY, None, tp_points=5, sl_points=3, sl_mode="previous_entry"), 3)
    assert [(c.entry, c.sl) for c in ladder] == [(4000, 3997), (4005, 4000), (4010, 4005)]


def test_ladder_stops_before_stop_price() -> None:
    ladder = levels.preview_ladder(cfg(Direction.BUY, 2, stop_price=4007), 5)
    assert [c.entry for c in ladder] == [4000, 4003, 4006]


def test_ladder_respects_max_cycles_and_single_mode() -> None:
    assert len(levels.preview_ladder(cfg(Direction.BUY, 2, max_cycles=2), 5)) == 2
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
        cfg(Direction.BUY, 2, stop_price=3990)  # stop below a BUY trigger
    with pytest.raises(ValueError):
        cfg(Direction.SELL, 2, stop_price=4010)
    with pytest.raises(ValueError):
        cfg(Direction.BUY, 2, tp_points=0)
    with pytest.raises(ValueError):
        cfg(Direction.BUY, 2, trading_hours="25:00-26:00")


def test_stop_reached_uses_bid_for_buy_and_ask_for_sell() -> None:
    assert levels.stop_reached(4010.0, 4010.2, Direction.BUY, 4010)
    assert not levels.stop_reached(4009.9, 4010.1, Direction.BUY, 4010)
    assert levels.stop_reached(3989.8, 3990.0, Direction.SELL, 3990)
    assert not levels.stop_reached(3989.8, 3990.1, Direction.SELL, 3990)


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
