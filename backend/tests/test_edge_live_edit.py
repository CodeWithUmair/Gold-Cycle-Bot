"""Edge cases for changing a running cycle (update_config, modify_levels in CYCLE), client 2026-11-21."""

from typing import Any

import pytest

from app.broker.base import DealReason
from app.engine.cycle_engine import EngineError
from app.engine.models import BotState, Direction
from tests.helpers import Harness, make_cfg, run

SELL = Direction.SELL


def spy_modify(h: Harness) -> list[tuple[Any, ...]]:
    calls: list[tuple[Any, ...]] = []
    real = h.sim.modify_position

    async def spy(symbol: str, ticket: int, sl: float, tp: float) -> Any:
        calls.append((ticket, sl, tp))
        return await real(symbol, ticket, sl, tp)

    h.sim.modify_position = spy  # type: ignore[method-assign]
    return calls


def restart(h: Harness) -> Harness:
    h2 = Harness(repo=h.repo, sim=h.sim)
    h2.clock = h.clock
    h2.sim.now = lambda: h2.clock[0]
    return h2


def pos(h: Harness) -> Any:
    (p,) = h.sim.open_positions.values()
    return p


# ---------------------------------------------------------------- SELL paths


def test_sell_tp_move_and_order_2_follows() -> None:
    async def scenario() -> None:
        h = Harness(start=4005.0)
        await h.arm(direction=SELL, cycle_gap=None)
        await h.px(4000)  # C1.1 SELL, TP 3997
        assert pos(h).tp == 3997
        await h.engine.update_config(make_cfg(direction=SELL, cycle_gap=None, tp_points=5))
        assert pos(h).tp == 3995 and h.cycles()[0]["tp"] == 3995
        await h.px(3996.8)  # ask 3997 = old TP: still open
        assert h.engine.leg == 1 and h.engine.state == BotState.IN_POSITION
        await h.px(3994.8)  # ask 3995 = new TP -> C1.2 at 3995, SL 4000
        p = pos(h)
        assert (h.engine.leg, p.tp, p.sl, h.cycles()[1]["planned_entry"]) == (2, 0, 4000, 3995)

    run(scenario())


def test_sell_tp_change_on_wrong_side_refused() -> None:
    async def scenario() -> None:
        h = Harness(start=4005.0)
        await h.arm(direction=SELL, cycle_gap=None)
        await h.px(4000, 3998)  # ask 3998.2
        with pytest.raises(EngineError, match="must be below"):
            await h.engine.update_config(make_cfg(direction=SELL, cycle_gap=None, tp_points=1.5))  # 3998.5 > ask
        assert pos(h).tp == 3997 and h.engine.cfg and h.engine.cfg.tp_points == 3

    run(scenario())


def test_sell_gap_change_moves_waiting_reentry() -> None:
    async def scenario() -> None:
        h = Harness(start=4005.0)
        await h.arm(direction=SELL, cycle_gap=2)
        await h.px(4000, 3996.8, 3999.8)  # C1.1 TP -> C1.2 at 3997 SL 4000 -> SL -> C2.1 at 3998
        assert h.engine.state == BotState.ARMED and h.engine.planned_entry == 3998
        await h.engine.update_config(make_cfg(direction=SELL, cycle_gap=5))
        assert h.engine.planned_entry == 3995 and h.engine.snapshot()["trigger_level"] == 3995
        await h.px(3998)
        assert h.engine.state == BotState.ARMED
        await h.px(3995)
        assert h.engine.state == BotState.IN_POSITION and h.cycles()[-1]["planned_entry"] == 3995

    run(scenario())


def test_sell_stop_price_both_sides() -> None:
    async def scenario() -> None:
        h = Harness(start=4005.0)
        await h.arm(direction=SELL, cycle_gap=None, stop_price=3990)
        await h.px(4000, 3998.5)  # ask 3998.7
        with pytest.raises(EngineError, match="stop price"):  # below trigger: reached when ask <= 3999
            await h.engine.update_config(make_cfg(direction=SELL, cycle_gap=None, stop_price=3999))
        await h.engine.update_config(make_cfg(direction=SELL, cycle_gap=None, stop_price=4002))  # above the trigger
        await h.px(4001)
        assert h.engine.state == BotState.IN_POSITION
        await h.px(4001.8, 4001.8)  # ask 4002 -> stop price -> close
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions

    run(scenario())


# ---------------------------------------------------------------- transient states


def test_update_while_opening_waiting_for_spread() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0, spread=1.0)
        await h.arm(cycle_gap=None, max_spread_points=0.6)
        await h.px(4000)
        assert h.engine.state == BotState.OPENING and not h.sim.open_positions
        await h.engine.update_config(make_cfg(cycle_gap=None, max_spread_points=0.6, tp_points=5))
        assert h.engine.state == BotState.OPENING
        await h.engine.update_config(make_cfg(cycle_gap=None, max_spread_points=2, tp_points=5))  # lets it open
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION and pos(h).tp == 4005

    run(scenario())


def test_update_while_resolving_order_2_opens_at_real_tp() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        p = pos(h)
        h.sim._close(p, p.tp, DealReason.TP, h.clock[0])
        info = h.sim.closed.pop(p.ticket)  # deal not in history yet
        await h.px(4003)
        assert h.engine.state == BotState.RESOLVING
        await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=5))
        h.sim.closed[p.ticket] = info
        await h.px(4003)
        assert h.engine.leg == 2 and h.cycles()[1]["planned_entry"] == 4003  # order 1's TP as it closed
        assert pos(h).sl == 4000

    run(scenario())


def test_tp_change_refused_while_closing() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None, stop_price=4002)
        await h.px(4000)
        h.sim.reject_close_next = 99
        await h.px(4002)  # stop price -> pending close, broker keeps refusing
        assert h.engine.pending_close == "STOP_PRICE"
        with pytest.raises(EngineError, match="being closed"):
            await h.engine.update_config(make_cfg(cycle_gap=None, stop_price=4002, tp_points=5))
        assert pos(h).tp == 4003

    run(scenario())


def test_tp_change_with_fill_anchor() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None, level_anchor="fill")
        await h.px(4000)  # fill 4000.2 -> TP 4003.2
        assert pos(h).tp == 4003.2
        await h.engine.update_config(make_cfg(cycle_gap=None, level_anchor="fill", tp_points=5))
        assert pos(h).tp == 4005.2

    run(scenario())


# ---------------------------------------------------------------- gap / trigger / stop / limits


def test_gap_value_to_blank_and_blank_to_value_while_waiting() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2)
        await h.px(4000, 4003, 4000)  # C2.1 armed at 4002
        await h.engine.update_config(make_cfg(cycle_gap=None))
        assert h.engine.planned_entry == 4000
        await h.engine.update_config(make_cfg(cycle_gap=3))
        assert h.engine.planned_entry == 4003 and h.engine.snapshot()["trigger_level"] == 4003

        g = Harness(start=3995.0)
        await g.arm(cycle_gap=None)
        await g.px(4000, 4003, 4000)  # C2.1 armed at 4000 (blank gap)
        assert g.engine.planned_entry == 4000
        await g.engine.update_config(make_cfg(cycle_gap=3))
        assert g.engine.planned_entry == 4003

    run(scenario())


def test_gap_change_in_cycle_1_does_not_move_trigger() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2)
        await h.engine.update_config(make_cfg(cycle_gap=5))
        assert h.engine.planned_entry == 4000 and h.engine.snapshot()["trigger_level"] == 4000
        await h.px(4000, 4003, 4000)  # after C1.2 SL the new gap is used
        assert h.engine.planned_entry == 4005

    run(scenario())


def test_trigger_change_in_later_cycle_while_armed() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2)
        await h.px(4000, 4003, 4000)  # C2.1 armed at 4002
        await h.engine.update_config(make_cfg(cycle_gap=2, trigger_price=3990))
        assert h.engine.planned_entry == 3990 and h.engine.snapshot()["trigger_level"] == 3990
        await h.px(3990)
        assert h.engine.state == BotState.IN_POSITION and pos(h).tp == 3993

    run(scenario())


def test_stop_moved_inside_the_waiting_entry() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2, stop_price=4010)
        await h.px(4000, 4003, 4000)  # C2.1 armed at 4002
        with pytest.raises(EngineError, match="beyond the stop"):
            await h.engine.update_config(make_cfg(cycle_gap=5, stop_price=4003))  # re-entry 4005 > stop
        assert h.engine.planned_entry == 4002
        await h.engine.update_config(make_cfg(cycle_gap=2, stop_price=4001))  # entry 4002 now beyond the stop
        await h.px(4001)  # price reaches the stop before the entry: stop, never open
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions

    run(scenario())


def test_max_cycles_lowered_below_current_cycle() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000, 4003, 4000, 3999, 4000)  # C2.1 open
        assert (h.engine.cycle_no, h.engine.leg, h.engine.state) == (2, 1, BotState.IN_POSITION)
        await h.engine.update_config(make_cfg(cycle_gap=None, max_cycles=1))
        await h.px(4003)  # C2 finishes: order 2 still opens
        assert h.engine.leg == 2 and h.engine.state == BotState.IN_POSITION
        await h.px(4000)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MAX_CYCLES"
        assert len(h.cycles()) == 4

    run(scenario())


def test_lot_change_applies_to_next_order_only() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        await h.engine.update_config(make_cfg(cycle_gap=None, lot=0.03))
        assert pos(h).volume == 0.01
        await h.px(4003)
        assert pos(h).volume == 0.03 and h.cycles()[1]["volume"] == 0.03

    run(scenario())


def test_daily_loss_limit_added_mid_position() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000, 3990)  # floating -10.20
        assert h.engine.state == BotState.IN_POSITION
        await h.engine.update_config(make_cfg(cycle_gap=None, daily_loss_limit=5))
        await h.px(3990, 3990)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "DAILY_LOSS"
        assert not h.sim.open_positions and h.cycles()[0]["close_reason"] == "DAILY_LOSS"

    run(scenario())


# ---------------------------------------------------------------- restart


def test_update_survives_restart() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=5, stop_price=4010))
        h2 = restart(h)
        await h2.engine.recover(auto_resume=False)
        assert h2.engine.cfg and (h2.engine.cfg.tp_points, h2.engine.cfg.stop_price) == (5, 4010)
        assert h2.engine.cur_tp == 4005
        await h2.engine.resume()
        await h2.px(4005)
        assert h2.engine.leg == 2 and h2.engine.planned_entry == 4005 and pos(h2).sl == 4000

    run(scenario())


# ---------------------------------------------------------------- modify_levels in CYCLE


def test_order_2_added_tp_hit_starts_next_cycle_at_entry_plus_gap() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2)
        await h.px(4000, 4003)  # C1.2 at 4003, SL 4000
        await h.engine.modify_levels(4006, 4001)
        assert (pos(h).tp, pos(h).sl) == (4006, 4001)
        await h.px(4006)
        assert h.cycles()[1]["close_reason"] == "TP"
        assert (h.engine.state, h.engine.cycle_no, h.engine.leg, h.engine.planned_entry) == (BotState.ARMED, 2, 1, 4002)

    run(scenario())


def test_order_2_moved_sl_hit_starts_next_cycle_at_entry_plus_gap() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2)
        await h.px(4000, 4005)  # C1.1 TP 4003 jumped: C1.2 planned 4003, price 4005 > 0.5 -> waits
        await h.px(4003)  # touched -> C1.2 opens
        assert h.engine.leg == 2 and h.engine.state == BotState.IN_POSITION
        await h.engine.modify_levels(None, 4002)
        await h.px(4002)
        assert h.cycles()[1]["close_reason"] == "SL"
        assert (h.engine.cycle_no, h.engine.leg, h.engine.planned_entry) == (2, 1, 4002)

    run(scenario())


def test_modify_left_open_cycle_position_after_stop() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        await h.engine.stop_now()  # Cycle Stop now: trade stays open
        assert h.engine.state == BotState.STOPPED and h.sim.open_positions
        with pytest.raises(EngineError, match="No running cycle"):
            await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=5))
        await h.engine.modify_levels(4005, 3995)
        assert (pos(h).tp, pos(h).sl) == (4005, 3995)
        await h.px(4005, 4005)
        assert not h.sim.open_positions and h.cycles()[0]["close_reason"] == "TP"
        assert h.engine.state == BotState.STOPPED and len(h.cycles()) == 1  # never trades again

    run(scenario())


# ---------------------------------------------------------------- no-ops / rapid updates


def test_identical_update_and_no_change_modify_send_nothing() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        calls = spy_modify(h)
        n = len(h.events)
        await h.engine.update_config(make_cfg(cycle_gap=None))
        await h.engine.modify_levels(4003, None)
        assert calls == [] and len(h.events) == n

        await h.engine.modify_levels(4005, None)  # dragged to 4005
        assert len(calls) == 1
        await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=5))  # same TP as the drag: no modify
        assert len(calls) == 1 and h.engine.cfg and h.engine.cfg.tp_points == 5

    run(scenario())


def test_rapid_updates_end_on_last_value() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        calls = spy_modify(h)
        for tp in (4, 5, 6, 3):
            await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=tp))
        assert [c[2] for c in calls] == [4004, 4005, 4006, 4003]
        assert pos(h).tp == 4003 and h.cycles()[0]["tp"] == 4003
        assert sum("Cycle settings changed" in m for m in h.logs()) == 4

    run(scenario())
