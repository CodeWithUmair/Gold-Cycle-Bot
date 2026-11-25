"""Edge cases found on 2026-11-26 (first in the MQL5 version): a restart while order 2 is being opened, and a daily
loss limit hit by the other bot."""

import pytest

from app.broker.base import OrderResult
from app.engine.models import BotState, Direction, Mode
from tests.helpers import Harness, make_cfg, run


async def _order2_pending(h: Harness) -> None:
    """BUY cycle whose order 2 was rejected once: the engine is OPENING order 2."""
    await h.arm(cycle_gap=None)
    await h.px(4000)
    real = h.sim.open_market
    left = [1]

    async def reject_once(*a: object, **kw: object) -> OrderResult:
        if left[0]:
            left[0] -= 1
            return OrderResult(ok=False, retcode=10006, message="rejected")
        return await real(*a, **kw)  # type: ignore[arg-type]

    h.sim.open_market = reject_once  # type: ignore[method-assign]
    await h.px(4005)
    assert h.engine.state == BotState.OPENING and h.engine.leg == 2


def test_restart_while_opening_order_2_never_waits_for_a_touch() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order2_pending(h)
        h2 = Harness(repo=h.repo, sim=h.sim)
        h2.clock[0] = h.clock[0]
        await h2.engine.recover(auto_resume=False)
        await h2.engine.resume()
        assert h2.engine.state == BotState.OPENING  # not ARMED "waiting for price to return to the TP"
        await h2.px(4009)  # far from order 1's TP
        assert h2.engine.state == BotState.IN_POSITION and h2.engine.leg == 2
        (p,) = h2.sim.open_positions.values()
        assert (p.tp, p.sl) == (0, 4000)

    run(scenario())


def _second_engine(h: Harness) -> Harness:
    other = Harness(repo=h.repo, sim=h.sim)
    other.clock = h.clock
    other.engine.magic = h.engine.magic + 1
    other.engine.now = h.engine.now
    return other


def test_daily_loss_hit_by_the_other_bot_stops_a_waiting_cycle() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None, trigger_price=4010)  # cycle: no daily limit of its own, waiting
        single = _second_engine(h)
        await single.arm(mode=Mode.SINGLE, trigger_price=4001, tp_points=None, sl_points=None, daily_loss_limit=2)
        await single.px(4001)
        await single.px(3996, 3996, 3996)  # open loss counted on the next tick, then closed and recorded
        assert single.engine.state == BotState.STOPPED and single.engine.stop_reason == "DAILY_LOSS"
        await h.px(3996.5)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "DAILY_LOSS"
        await h.px(4010)
        assert not h.sim.open_positions

    run(scenario())


def test_daily_loss_hit_by_the_other_bot_closes_the_open_cycle_trade() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None, tp_points=30)
        single = _second_engine(h)
        await single.arm(mode=Mode.SINGLE, trigger_price=4000, tp_points=None, sl_points=None, daily_loss_limit=2)
        await h.px(4000)
        await single.px(4000)
        assert len(h.sim.open_positions) == 2
        await single.px(3996, 3996)
        await h.px(3996, 3996)
        assert not h.sim.open_positions
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "DAILY_LOSS"

    run(scenario())


def test_empty_trading_window_is_refused() -> None:
    with pytest.raises(ValueError, match="never trade"):
        make_cfg(trading_hours="09:00-09:00")


def test_no_order_2_once_the_daily_limit_is_hit() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None, direction=Direction.BUY)
        await h.px(4000)
        h.repo.set_setting("daily_loss_block", h.engine.today().isoformat())
        await h.px(4003.5, 4003.5, 4003.5)
        assert not h.sim.open_positions
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "DAILY_LOSS"
        assert [c["leg"] for c in h.cycles()] == [1]

    run(scenario())
