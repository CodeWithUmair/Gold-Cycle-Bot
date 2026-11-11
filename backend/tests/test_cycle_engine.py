"""Engine scenarios on the simulated broker (CLAUDE.md §10.2)."""

import pytest

from app.engine.cycle_engine import EngineError
from app.engine.models import BotState, Direction, Mode
from tests.helpers import Harness, run


def test_buy_tp_chain_x3_with_gap() -> None:
    async def scenario() -> None:
        h = Harness(start=3990)
        await h.arm(cycle_gap=2)
        await h.px(3995, 3999.9)
        assert h.engine.state == BotState.ARMED and not h.sim.open_positions
        await h.px(4000)  # C1 opens
        assert h.engine.state == BotState.IN_POSITION
        await h.px(4003)  # C1 TP -> C2 armed at 4002 (wait for pullback, Q1 default)
        assert h.engine.state == BotState.ARMED and h.engine.planned_entry == 4002
        await h.px(4002.5, 4002, 4005, 4004, 4007)
        rows = h.cycles()
        assert [r["planned_entry"] for r in rows] == [4000, 4002, 4004]
        assert [(r["tp"], r["sl"]) for r in rows] == [(4003, 3997), (4005, 3999), (4007, 4001)]
        assert [r["close_reason"] for r in rows] == ["TP", "TP", "TP"]
        assert all(r["pnl"] > 0 for r in rows)
        assert h.engine.state == BotState.ARMED and h.engine.cycle_no == 4 and h.engine.planned_entry == 4006
        assert h.engine.session_pnl == pytest.approx(sum(r["pnl"] for r in rows))

    run(scenario())


def test_sell_tp_chain_with_gap() -> None:
    async def scenario() -> None:
        h = Harness(start=4010)
        await h.arm(direction=Direction.SELL, cycle_gap=2)
        await h.px(4000, 3996.8, 3998, 3994.8, 3996, 3992.8)  # SELL TP checks ask (bid + 0.2)
        rows = h.cycles()
        assert [r["planned_entry"] for r in rows] == [4000, 3998, 3996]
        assert [(r["tp"], r["sl"]) for r in rows] == [(3997, 4003), (3995, 4001), (3993, 3999)]
        assert [r["close_reason"] for r in rows] == ["TP", "TP", "TP"]

    run(scenario())


def test_gap_blank_opens_next_cycle_immediately_from_tp() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None)
        await h.px(4000, 4003)  # C1 TP -> C2 opens at market right away
        assert h.engine.state == BotState.IN_POSITION and h.engine.cycle_no == 2
        c2 = h.cycles()[1]
        assert (c2["planned_entry"], c2["tp"], c2["sl"]) == (4003, 4006, 4000)
        assert c2["fill_price"] == pytest.approx(4003.2) and c2["slippage"] == pytest.approx(0.2)

    run(scenario())


def test_sl_hit_stops_bot() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000, 3998, 3997)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "SL"
        assert h.cycles()[0]["close_reason"] == "SL"
        assert any("C1 hit SL at 3997.00" in t and "bot stopped" in t for t in h.toasts())
        await h.px(4000, 4005)  # never re-enters
        assert not h.sim.open_positions and len(h.cycles()) == 1

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


def test_next_entry_beyond_stop_price_stops_chain() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=5, stop_price=4004)  # C2 would be 4005 >= 4004
        await h.px(4000, 4003)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert len(h.cycles()) == 1

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


def test_max_cycles() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=None, max_cycles=2)
        await h.px(4000, 4003, 4006)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MAX_CYCLES"
        assert len(h.cycles()) == 2

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
        assert (p.tp, p.sl) == (4003, 3997)
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
        assert (p.tp, p.sl) == (4003.2, 3997.2)

    run(scenario())
