"""Change a running cycle (client, 2026-11-21): settings via update_config, the open order's TP/SL via modify_levels."""

import json

import pytest

from app.engine.cycle_engine import EngineError
from app.engine.models import BotState, Direction
from tests.helpers import Harness, make_cfg, run


def test_tp_change_moves_open_order_1_tp_and_order_2_follows() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)  # C1.1 open, TP 4003
        await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=5))
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (4005, 0) and h.cycles()[0]["tp"] == 4005
        await h.px(4003)  # old TP: nothing happens
        assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 1
        await h.px(4005)  # new TP -> C1.2 opens there, SL at C1.1's entry
        (p,) = h.sim.open_positions.values()
        assert (h.engine.leg, p.tp, p.sl) == (2, 0, 4000) and h.cycles()[1]["planned_entry"] == 4005
        assert any("TP pts 3 → 5" in m and "TP moved to 4005.00" in m for m in h.logs())

    run(scenario())


def test_tp_change_during_order_2_applies_to_next_cycle() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000, 4003)  # C1.2 open (no TP)
        await h.engine.update_config(make_cfg(cycle_gap=None, tp_points=4))
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (0, 4000)  # order 2 untouched
        await h.px(3999.5, 3999, 4000)  # C1.2 SL -> C2.1 armed at 4000 -> touch
        (p,) = h.sim.open_positions.values()
        assert (h.engine.cycle_no, h.engine.leg, p.tp) == (2, 1, 4004)

    run(scenario())


def test_gap_change_moves_the_waiting_reentry() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=2)
        await h.px(4000, 4003, 4000)  # C1.2 SL -> C2.1 armed at 4002
        assert h.engine.state == BotState.ARMED and h.engine.planned_entry == 4002
        await h.engine.update_config(make_cfg(cycle_gap=5))
        assert h.engine.planned_entry == 4005 and h.engine.snapshot()["trigger_level"] == 4005
        await h.px(4002)
        assert h.engine.state == BotState.ARMED  # old level: no entry
        await h.px(4005)
        assert h.engine.state == BotState.IN_POSITION and h.cycles()[-1]["planned_entry"] == 4005

    run(scenario())


def test_trigger_change_only_while_waiting_for_order_1() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(trigger_price=4000)
        await h.engine.update_config(make_cfg(trigger_price=3995))
        assert h.engine.planned_entry == 3995 and h.engine.snapshot()["trigger_level"] == 3995
        await h.px(3995)
        assert h.engine.state == BotState.IN_POSITION
        with pytest.raises(EngineError, match="trigger price can only change"):
            await h.engine.update_config(make_cfg(trigger_price=3990))

    run(scenario())


def test_rejected_changes_leave_the_cycle_untouched() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(stop_price=4010)
        await h.px(4000, 4001)  # C1.1 open, TP 4003
        with pytest.raises(EngineError, match="Direction"):
            await h.engine.update_config(make_cfg(direction=Direction.SELL, stop_price=4010))
        with pytest.raises(EngineError, match="stop price"):
            await h.engine.update_config(make_cfg(stop_price=4000.5))  # bid 4001 is already past it
        with pytest.raises(EngineError, match="must be above"):
            await h.engine.update_config(make_cfg(tp_points=0.1, stop_price=4010))  # TP 4000.1 is below the bid
        with pytest.raises(EngineError, match="Lot"):
            await h.engine.update_config(make_cfg(lot=0.015, stop_price=4010))
        assert h.engine.cfg and h.engine.cfg.stop_price == 4010 and h.engine.cfg.tp_points == 3
        (p,) = h.sim.open_positions.values()
        assert p.tp == 4003

    run(scenario())


def test_stop_price_lot_and_limits_apply_and_persist() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        await h.engine.update_config(make_cfg(cycle_gap=None, stop_price=4008, lot=0.02, max_cycles=1))
        row = h.repo.last_open_session()
        assert row and json.loads(row["config_json"])["stop_price"] == 4008  # restart uses the new settings
        await h.px(4003)  # C1.2 opens with the new lot
        (p,) = h.sim.open_positions.values()
        assert p.volume == 0.02
        await h.px(4008, 4008)  # new stop price closes it
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"

    run(scenario())


def test_no_changes_and_not_running() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        with pytest.raises(EngineError, match="No running cycle"):
            await h.engine.update_config(make_cfg())
        await h.arm()
        n = len(h.events)
        await h.engine.update_config(make_cfg())  # same settings: nothing logged
        assert len(h.events) == n

    run(scenario())


def test_modify_open_cycle_order_tp_sl() -> None:
    async def scenario() -> None:
        h = Harness(start=3995.0)
        await h.arm(cycle_gap=None)
        await h.px(4000)
        await h.engine.modify_levels(4004, 3990)  # move TP, add an SL to order 1
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (4004, 3990)
        await h.px(4004)  # C1.2 opens at the moved TP
        (p,) = h.sim.open_positions.values()
        assert h.engine.leg == 2 and h.cycles()[1]["planned_entry"] == 4004 and p.sl == 4000
        await h.engine.modify_levels(None, 4002)  # move order 2's SL up
        await h.px(4002, 4001, 4000)  # C1.2 SL -> next cycle still restarts at the cycle entry 4000
        assert (h.engine.cycle_no, h.engine.leg) == (2, 1)
        assert h.cycles()[-1]["planned_entry"] == 4000

    run(scenario())
