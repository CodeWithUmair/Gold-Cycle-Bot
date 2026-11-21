"""CRITICAL (client, 2026-11-21): when order 1 hits TP, order 2 must open at once, in the same engine step,
whatever the price did in between. Its levels stay at the planned point: entry = order 1's TP, SL = order 1's entry."""

from datetime import time

import pytest

from app.engine.models import BotState, Direction
from tests.helpers import Harness, run


async def _order1_open(h: Harness, **kw: object) -> None:
    await h.arm(cycle_gap=None, **kw)
    await h.px(4000 if kw.get("direction", Direction.BUY) == Direction.BUY else 4000)
    assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 1


@pytest.mark.parametrize("jump", [0.0, 0.3, 0.8, 3.0, 25.0])
def test_buy_order2_opens_in_the_same_step_even_after_a_price_jump(jump: float) -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h)
        await h.px(4003 + jump)  # ONE tick: order 1 TP (paper-closed at 4003) -> order 2 must be open now
        (p,) = h.sim.open_positions.values()
        assert h.engine.state == BotState.IN_POSITION and (h.engine.cycle_no, h.engine.leg) == (1, 2)
        assert (p.tp, p.sl) == (0, 4000)  # SL at order 1's entry, no TP
        o1, o2 = h.cycles()
        assert o1["close_reason"] == "TP" and o2["planned_entry"] == 4003  # planned at order 1's TP
        assert o2["open_time"] == o1["close_time"]  # same instant

    run(scenario())


@pytest.mark.parametrize("jump", [0.0, 0.8, 5.0])
def test_sell_order2_opens_in_the_same_step_even_after_a_price_jump(jump: float) -> None:
    async def scenario() -> None:
        h = Harness(start=4005.0)
        await h.arm(cycle_gap=None, direction=Direction.SELL)
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION
        await h.px(3996.8 - jump)  # ask = bid + 0.2 <= 3997: SELL TP
        (p,) = h.sim.open_positions.values()
        assert (h.engine.leg, p.direction, p.tp, p.sl) == (2, Direction.SELL, 0, 4000)
        assert h.cycles()[1]["planned_entry"] == 3997

    run(scenario())


def test_order2_ignores_trading_hours() -> None:
    """Hours only block NEW cycles (§5). Order 2 is the same cycle: it must not wait for tomorrow's window."""

    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h, trading_hours="08:00-17:00")
        h.engine.local_time = lambda: time(17, 30)  # window closed while order 1 was open
        await h.px(4003)
        assert h.engine.leg == 2 and h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_kill_switch_while_resolving_order1_tp_never_opens_order2() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h)
        real = h.sim.close_info
        held = [True]

        async def late(ticket: int):  # type: ignore[no-untyped-def]
            return None if held[0] else await real(ticket)

        h.sim.close_info = late  # type: ignore[method-assign]
        await h.px(4003)
        assert h.engine.state == BotState.RESOLVING
        await h.engine.close_all_and_stop()
        held[0] = False
        await h.px(4003.5, 4003.5)
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions and len(h.cycles()) == 1
        assert h.cycles()[0]["close_reason"] == "TP"  # the broker's real reason is journaled

    run(scenario())


def test_jump_through_tp_and_stop_price_journals_tp_and_stops() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h, stop_price=4002)
        await h.px(4003, 4003)
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions
        (row,) = h.cycles()
        assert row["close_reason"] == "TP" and row["pnl"] > 0

    run(scenario())


def test_order2_ignores_max_spread() -> None:
    """Client (2026-11-21): order 2 opens at once even if the spread is wider than max spread. Order 1 still waits."""

    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h, max_spread_points=0.6)
        h.sim.spread = 1.5
        await h.px(4003)
        (p,) = h.sim.open_positions.values()
        assert h.engine.leg == 2 and p.price_open == 4004.5 and p.sl == 4000

        h2 = Harness(start=3995.0, spread=1.5)  # order 1 (cycle entry) still respects it
        await h2.arm(cycle_gap=None, max_spread_points=0.6)
        await h2.px(4000)
        assert h2.engine.state == BotState.OPENING and not h2.sim.open_positions

    run(scenario())


def test_order2_rejected_by_broker_retries_every_second_never_rearms() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h)
        h.sim.reject_next = 2
        await h.px(4003)
        assert h.engine.state == BotState.OPENING and h.engine.leg == 2 and not h.sim.open_positions
        await h.px(4004)  # still retrying (not ARMED / waiting for a return to 4003)
        assert h.engine.state == BotState.OPENING
        await h.px(4005)
        (p,) = h.sim.open_positions.values()
        assert h.engine.state == BotState.IN_POSITION and p.sl == 4000 and h.cycles()[1]["planned_entry"] == 4003

    run(scenario())


def test_order2_tick_count_from_tp_to_open_is_zero_with_resolve_delay() -> None:
    """Live MT5: the closing deal can show up in history a tick after the position disappears. Order 2 must then
    open on that next tick, not later."""

    async def scenario() -> None:
        h = Harness(start=3995.0)
        await _order1_open(h)
        real = h.sim.close_info
        misses = [1]

        async def late(ticket: int):  # type: ignore[no-untyped-def]
            if misses[0]:
                misses[0] -= 1
                return None
            return await real(ticket)

        h.sim.close_info = late  # type: ignore[method-assign]
        await h.px(4003)
        assert h.engine.state == BotState.RESOLVING
        await h.px(4003.4)
        assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 2

    run(scenario())
