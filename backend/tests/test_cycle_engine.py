"""Engine scenarios on the simulated broker (CLAUDE.md §10.2)."""

import pytest

from app.engine.cycle_engine import CycleEngine, EngineError
from app.engine.models import BotState, Direction, Mode
from tests.helpers import MAGIC, Harness, make_cfg, run


def test_buy_two_order_cycle() -> None:
    """Client's example: order 1 at 4000 TP 4003 no SL; TP -> order 2 at 4003, SL 4000, no TP."""

    async def scenario() -> None:
        h = Harness(start=3990)
        await h.arm(cycle_gap=None)
        await h.px(3995, 3999.9)
        assert h.engine.state == BotState.ARMED and not h.sim.open_positions
        await h.px(4000)  # C1.1 opens
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (4003, 0)
        await h.px(3990)  # no SL on order 1: a dip does not close it
        assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 1
        await h.px(4003)  # C1.1 TP -> C1.2 opens at once
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (0, 4000) and h.engine.leg == 2 and h.engine.cycle_no == 1
        await h.px(4010, 4030)  # no TP on order 2: it keeps running
        assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 2
        rows = h.cycles()
        assert [(r["cycle_no"], r["leg"], r["planned_entry"], r["tp"], r["sl"]) for r in rows] == [
            (1, 1, 4000, 4003, 0),
            (1, 2, 4003, 0, 4000),
        ]
        assert rows[0]["close_reason"] == "TP" and rows[0]["pnl"] > 0
        assert "GC|c=1.2|session=" in p.comment

    run(scenario())


def test_sell_two_order_cycle_with_gap() -> None:
    async def scenario() -> None:
        h = Harness(start=4010)
        await h.arm(direction=Direction.SELL, cycle_gap=2)
        await h.px(4000, 3996.8)  # SELL TP checks ask (bid + 0.2): C1.1 TP -> C1.2 SELL at 3997, SL 4000
        await h.px(3999.8)  # ask 4000 -> C1.2 SL -> C2.1 armed at 4000 - 2
        assert h.engine.state == BotState.ARMED and h.engine.planned_entry == 3998 and h.engine.leg == 1
        await h.px(3998)
        rows = h.cycles()
        assert [(r["cycle_no"], r["leg"], r["planned_entry"], r["tp"], r["sl"]) for r in rows] == [
            (1, 1, 4000, 3997, 0),
            (1, 2, 3997, 0, 4000),
            (2, 1, 3998, 3995, 0),
        ]
        assert [r["close_reason"] for r in rows[:2]] == ["TP", "SL"]

    run(scenario())


def test_order_2_opens_immediately_at_order_1_tp() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None)
        await h.px(4000, 4003)  # C1.1 TP -> C1.2 opens at market right away
        assert h.engine.state == BotState.IN_POSITION and (h.engine.cycle_no, h.engine.leg) == (1, 2)
        c2 = h.cycles()[1]
        assert (c2["planned_entry"], c2["tp"], c2["sl"]) == (4003, 0, 4000)
        assert c2["fill_price"] == pytest.approx(4003.2) and c2["slippage"] == pytest.approx(0.2)

    run(scenario())


def test_order_2_sl_blank_gap_restarts_cycle_at_entry() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None)
        await h.px(4000, 4003, 3999.5)  # C1.2 SL at 4000
        assert h.cycles()[1]["close_reason"] == "SL"
        assert any("C1.2 hit SL at 4000.00" in t for t in h.toasts())
        assert h.engine.state == BotState.ARMED and (h.engine.cycle_no, h.engine.leg) == (2, 1)
        assert h.engine.planned_entry == 4000
        await h.px(3999)
        assert not h.sim.open_positions  # waits for price to come back to 4000
        await h.px(4000)
        c3 = h.cycles()[2]
        assert h.engine.state == BotState.IN_POSITION
        assert (c3["cycle_no"], c3["leg"], c3["planned_entry"], c3["tp"], c3["sl"]) == (2, 1, 4000, 4003, 0)

    run(scenario())


def test_order_2_sl_with_gap_restarts_from_entry_plus_gap() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=2)
        await h.px(4000, 4003, 4000)  # C1.2 SL -> C2.1 at 4000 + 2
        assert h.engine.state == BotState.ARMED and h.engine.planned_entry == 4002
        await h.px(4002)
        c3 = h.cycles()[2]
        assert (c3["planned_entry"], c3["tp"], c3["sl"]) == (4002, 4005, 0)
        await h.px(4005)  # C2.1 TP -> C2.2 at 4005, SL at C2's entry 4002
        c4 = h.cycles()[3]
        assert (c4["cycle_no"], c4["leg"], c4["planned_entry"], c4["tp"], c4["sl"]) == (2, 2, 4005, 0, 4002)

    run(scenario())


def test_sl_points_ignored_in_cycle_mode() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None, sl_points=5)  # order 1 never gets an SL in CYCLE mode
        await h.px(4000, 3990)
        assert h.engine.state == BotState.IN_POSITION
        (p,) = h.sim.open_positions.values()
        assert p.sl == 0

    run(scenario())


def test_stop_price_mid_cycle_closes_trade_and_stops() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None, stop_price=4005)
        await h.px(4000, 4003)  # C2 open at 4003, TP 4006
        h.sim.reject_close_next = 2  # first two close attempts rejected -> retried each tick
        await h.px(4005)
        assert h.engine.state == BotState.IN_POSITION and h.sim.open_positions
        await h.px(4005.1, 4005.2)  # 3rd attempt succeeds
        assert not h.sim.open_positions
        await h.px(4005.3)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert h.cycles()[1]["close_reason"] == "STOP_PRICE"
        assert any("rejected" in t for t in h.toasts())

    run(scenario())


def test_buy_stop_price_below_trigger_closes_trade_and_stops() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None, sl_points=None, stop_price=3995)  # BUY, stop under the trigger
        await h.px(4000, 3998)
        assert h.engine.state == BotState.IN_POSITION
        await h.px(3995, 3995)
        assert not h.sim.open_positions
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"

    run(scenario())


def test_next_entry_beyond_stop_price_stops_chain() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=5, stop_price=4004.5)  # after C1.2's SL, C2 would start at 4005 >= 4004.5
        await h.px(4000, 4003, 4000)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert len(h.cycles()) == 2

    run(scenario())


def test_price_past_trigger_at_arm_waits_for_return() -> None:
    async def scenario() -> None:
        h = Harness(start=4010)
        await h.arm(cycle_gap=None)
        assert h.engine.waiting == "Waiting for price to return to 4000.00"
        await h.px(4008, 4001)
        assert h.engine.state == BotState.ARMED
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_price_exactly_at_trigger_at_arm_does_not_enter() -> None:
    async def scenario() -> None:
        h = Harness(start=4000)
        await h.arm()
        await h.px(4000, 4000, 4000.5)
        assert h.engine.state == BotState.ARMED
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_manual_close_stops_bot() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000, 4001)
        assert h.engine.position is not None
        h.sim.manual_close(h.engine.position.ticket)
        await h.px(4001)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MANUAL_CLOSE"
        assert h.cycles()[0]["close_reason"] == "MANUAL"

    run(scenario())


def test_spread_too_wide_waits_then_opens() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(max_spread_points=0.6)
        h.sim.spread = 1.0
        await h.px(4000, 4000.1)
        assert h.engine.state == BotState.OPENING and not h.sim.open_positions
        assert "spread" in (h.engine.waiting or "")
        h.sim.spread = 0.3
        await h.px(4000.2)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_rejected_order_retries_then_rearms_when_price_leaves_tolerance() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(max_slippage_points=0.5)
        h.sim.reject_next = 2
        await h.px(4000, 4000.3)
        assert h.engine.state == BotState.OPENING and not h.sim.open_positions
        await h.px(4000.9)  # out of tolerance -> back to ARMED, wait for another touch
        assert h.engine.state == BotState.ARMED
        await h.px(4000.5, 4000)  # touched again; both rejections used up -> fills
        assert h.engine.state == BotState.IN_POSITION
        assert len(h.cycles()) == 1

    run(scenario())


def test_single_mode_returns_to_idle() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=4, sl_points=2)
        await h.px(4000, 4004)
        assert h.engine.state == BotState.IDLE
        assert h.cycles()[0]["close_reason"] == "TP"
        assert h.repo.last_open_session() is None

    run(scenario())


def test_stop_after_this_cycle() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        await h.engine.request_stop_after_cycle()
        await h.px(4003)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_AFTER_CYCLE"

    run(scenario())


def test_max_cycles_counts_two_order_cycles() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None, max_cycles=2)
        await h.px(4000, 4003, 3999.5)  # cycle 1: TP, then SL
        await h.px(4000, 4003, 3999.5)  # cycle 2: TP, then SL -> max reached
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MAX_CYCLES"
        assert [(r["cycle_no"], r["leg"]) for r in h.cycles()] == [(1, 1), (1, 2), (2, 1), (2, 2)]

    run(scenario())


def test_kill_switch_closes_and_stops() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        await h.engine.close_all_and_stop()
        assert not h.sim.open_positions
        await h.px(4000.5)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "KILL_SWITCH"

    run(scenario())


def test_stop_now_leaves_position_with_server_side_tp_sl() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        await h.engine.stop_now()
        assert h.engine.state == BotState.STOPPED and len(h.sim.open_positions) == 1
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (4003, 0)  # order 1: TP only
        with pytest.raises(EngineError):
            await h.arm()  # a bot position is still open

    run(scenario())


def test_daily_loss_limit_closes_and_blocks_new_arms() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(lot=1.0, sl_points=5, daily_loss_limit=200)
        await h.px(4000, 3998)  # floating (3998 - 4000.2) * 100 = -220
        await h.px(3998, 3998)  # limit hit -> close sent; next tick resolves
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "DAILY_LOSS"
        assert not h.sim.open_positions
        with pytest.raises(EngineError, match="Daily loss"):
            await h.arm()

    run(scenario())


def test_disconnect_pauses_engine() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        h.sim.connected = False
        await h.px(4000)
        assert not h.engine.connected and h.engine.state == BotState.ARMED and not h.sim.open_positions
        with pytest.raises(EngineError):
            await h.engine.arm(h.engine.cfg)  # type: ignore[arg-type]

    run(scenario())


def test_fill_anchor_moves_tp_sl_to_fill() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(level_anchor="fill")
        await h.px(4000)
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (4003.2, 0)

    run(scenario())


def test_cycle_and_single_hold_positions_at_the_same_time() -> None:
    async def scenario() -> None:
        h = Harness()  # its engine runs CYCLE (magic 777)
        single = CycleEngine(h.sim, h.repo, "XAUUSD", MAGIC + 1, now=lambda: h.clock[0], mode=Mode.SINGLE)
        await single.load_symbol()
        await h.arm(cycle_gap=None)
        await single.arm(make_cfg(mode=Mode.SINGLE, direction=Direction.SELL, trigger_price=4001))
        with pytest.raises(EngineError):  # each engine only takes its own mode
            await single.arm(make_cfg())
        for b in (4000, 4001):
            h.clock[0] += 1.5
            h.sim.set_price(b)
            await h.engine.step()
            await single.step()
        assert h.engine.state == single.state == BotState.IN_POSITION
        assert sorted(p.magic for p in h.sim.open_positions.values()) == [MAGIC, MAGIC + 1]

    run(scenario())
