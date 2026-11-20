"""SINGLE mode: TP and SL are both optional (client, 2026-11-20). Any of: both, TP only, SL only, none."""

from typing import Any

import pytest

from app.broker.base import SymbolSpec, Tick
from app.engine import levels, risk
from app.engine.models import BotState, CycleConfig, Direction, Mode
from tests.helpers import Harness, run
from tests.test_recovery import restart


def single(**kw: Any) -> CycleConfig:
    base: dict[str, Any] = dict(mode=Mode.SINGLE, direction=Direction.BUY, trigger_price=4000, lot=0.01)
    base.update(kw)
    return CycleConfig.model_validate(base)


SPEC = SymbolSpec("XAUUSD", 2, 0.01, 0.01, 100, 0.01, 0, 0, 100)
TICK = Tick(3990.0, 3990.2, 0)


# ---------------------------------------------------------------- config


@pytest.mark.parametrize(
    ("tp", "sl", "want"),
    [(3, 2, (4003, 3998)), (3, None, (4003, None)), (None, 2, (None, 3998)), (None, None, (None, None))],
)
def test_points_any_combination(tp: float | None, sl: float | None, want: tuple[Any, Any]) -> None:
    (p,) = levels.preview_ladder(single(tp_points=tp, sl_points=sl), 5)
    assert (p.tp, p.sl) == want


@pytest.mark.parametrize(
    ("tp", "sl", "want"),
    [(4003, 3998, (3, 2)), (4003, None, (3, None)), (None, 3998, (None, 2)), (None, None, (None, None))],
)
def test_exact_prices_any_combination(tp: float | None, sl: float | None, want: tuple[Any, Any]) -> None:
    c = single(tp_sl_input="price", tp_price=tp, sl_price=sl, tp_points=99, sl_points=99)  # stale points ignored
    assert (c.tp_points, c.sl_points) == want
    (p,) = levels.preview_ladder(c, 5)
    assert (p.tp, p.sl) == (tp, sl)


@pytest.mark.parametrize(
    "kw",
    [
        dict(tp_sl_input="price", tp_price=3999),  # BUY TP below the trigger
        dict(tp_sl_input="price", tp_price=4000),  # TP on the trigger
        dict(tp_sl_input="price", sl_price=4001),  # BUY SL above the trigger
        dict(direction=Direction.SELL, tp_sl_input="price", tp_price=4001),
        dict(direction=Direction.SELL, tp_sl_input="price", sl_price=3999),
        dict(tp_points=0),
        dict(sl_points=-1),
        dict(tp_points=float("inf")),
        dict(sl_points=float("nan")),
        dict(direction=Direction.SELL, tp_points=4000),  # TP price would be 0
        dict(sl_points=5000),  # BUY SL price would be negative
    ],
)
def test_bad_tp_sl_rejected(kw: dict[str, Any]) -> None:
    with pytest.raises(ValueError):
        single(**kw)


def test_cycle_still_needs_tp() -> None:
    with pytest.raises(ValueError, match="tp_points"):
        CycleConfig(mode=Mode.CYCLE, direction=Direction.BUY, trigger_price=4000, lot=0.01)


def test_validation_warns_when_neither_is_set_and_never_crashes() -> None:
    errors, warnings = risk.validate_config(single(), SPEC, TICK)
    assert errors == [] and any("no TP and no SL" in w for w in warnings)
    for kw in (dict(tp_points=3), dict(sl_points=2)):
        errors, warnings = risk.validate_config(single(**kw), SPEC, TICK)
        assert errors == [] and not any("no TP and no SL" in w for w in warnings)


# ---------------------------------------------------------------- engine


def test_tp_only_closes_on_tp() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=3, sl_points=None)
        await h.px(4000, 3980)  # no SL: a big dip does not close it
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (4003, 0) and h.engine.state == BotState.IN_POSITION
        await h.px(4003)
        assert h.engine.state == BotState.IDLE and h.cycles()[0]["close_reason"] == "TP"

    run(scenario())


def test_sl_only_closes_on_sl() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=None, sl_points=2)
        await h.px(4000, 4050)  # no TP: a big rally does not close it
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (0, 3998) and h.engine.state == BotState.IN_POSITION
        await h.px(3998)
        assert h.engine.state == BotState.IDLE and h.cycles()[0]["close_reason"] == "SL"

    run(scenario())


def test_no_tp_no_sl_stays_open_until_trader_closes_it() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=None, sl_points=None)
        await h.px(4000, 4100, 3900)
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (0, 0) and h.engine.state == BotState.IN_POSITION
        snap = h.engine.snapshot()
        assert (snap["tp"], snap["sl"]) == (None, None)
        await h.engine.close_all_and_stop()
        await h.px(3900)
        assert not h.sim.open_positions
        assert h.engine.state == BotState.STOPPED and h.cycles()[0]["close_reason"] == "KILL_SWITCH"

    run(scenario())


def test_no_tp_no_sl_manual_close_stops() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=None, sl_points=None)
        await h.px(4000)
        assert h.engine.position is not None
        h.sim.manual_close(h.engine.position.ticket)
        await h.px(4001)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MANUAL_CLOSE"

    run(scenario())


def test_no_tp_no_sl_daily_loss_limit_still_closes_it() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=None, sl_points=None, lot=1.0, daily_loss_limit=100)
        await h.px(4000, 3998, 3998, 3998)
        assert not h.sim.open_positions and h.engine.stop_reason == "DAILY_LOSS"

    run(scenario())


@pytest.mark.parametrize(("tp", "sl", "want"), [(None, None, (0, 0)), (3, None, (4003.2, 0)), (None, 2, (0, 3998.2))])
def test_fill_anchor_with_missing_levels(tp: float | None, sl: float | None, want: tuple[float, float]) -> None:
    async def scenario() -> None:
        h = Harness()
        calls: list[tuple[float, float]] = []
        real = h.sim.modify_position

        async def spy(symbol: str, ticket: int, sl: float, tp: float) -> Any:
            calls.append((sl, tp))
            return await real(symbol, ticket, sl, tp)

        h.sim.modify_position = spy  # type: ignore[method-assign]
        await h.arm(mode=Mode.SINGLE, tp_points=tp, sl_points=sl, level_anchor="fill")
        await h.px(4000)
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == want
        assert len(calls) == (0 if tp is None and sl is None else 1)  # MT5 rejects a no-change modify (10025)

    run(scenario())


def test_restart_reattaches_single_without_tp_sl() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=None, sl_points=None)
        await h.px(4000)
        h2 = restart(h)
        await h2.engine.recover(auto_resume=True)
        assert h2.engine.state == BotState.IN_POSITION
        assert (h2.engine.cur_tp, h2.engine.cur_sl) == (None, None)
        await h2.px(4100)
        assert h2.engine.state == BotState.IN_POSITION  # nothing to hit

    run(scenario())


def test_exact_price_sl_only_engine() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, direction=Direction.SELL, tp_sl_input="price", tp_points=None,
                    sl_points=None, tp_price=None, sl_price=4002.5, cycle_gap=None)  # fmt: skip
        h.sim.set_price(4010)
        await h.px(4000)
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (0, 4002.5)

    run(scenario())


def test_fill_anchor_cycle_order_2_sends_no_modify() -> None:
    async def scenario() -> None:
        h = Harness()
        calls: list[Any] = []
        real = h.sim.modify_position

        async def spy(symbol: str, ticket: int, sl: float, tp: float) -> Any:
            calls.append((sl, tp))
            return await real(symbol, ticket, sl, tp)

        h.sim.modify_position = spy  # type: ignore[method-assign]
        await h.arm(level_anchor="fill", cycle_gap=None)
        await h.px(4000)  # C1.1: TP moves to fill + 3 -> one modify
        await h.px(4003.2)  # C1.1 TP -> C1.2: SL stays at C1.1's entry, no TP -> nothing to modify
        assert h.engine.leg == 2 and len(calls) == 1

    run(scenario())
