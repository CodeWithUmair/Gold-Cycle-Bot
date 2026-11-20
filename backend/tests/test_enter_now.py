"""SINGLE "Enter now" (client, 2026-11-20): open at market at once, levels planned from the live price."""

import pytest

from app.engine.cycle_engine import EngineError
from app.engine.models import BotState, CycleConfig, Direction, Mode
from tests.helpers import Harness, run


def test_enter_now_opens_at_once_from_the_live_price() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)  # bid 3990, ask 3990.2; the form's trigger (4000) is ignored
        await h.arm(mode=Mode.SINGLE, trigger_price=4000, enter_now=True, tp_points=3, sl_points=2)
        assert h.engine.state == BotState.IN_POSITION  # no tick, no touch needed
        (p,) = h.sim.open_positions.values()
        assert (p.price_open, p.tp, p.sl) == (3990.2, 3993, 3988)
        assert h.engine.planned_entry == 3990
        await h.px(3993)
        assert h.engine.state == BotState.IDLE and h.cycles()[0]["close_reason"] == "TP"

    run(scenario())


def test_enter_now_sell_with_exact_prices() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, direction=Direction.SELL, trigger_price=3990, enter_now=True,
                    tp_sl_input="price", tp_price=3980, sl_price=None, cycle_gap=None)  # fmt: skip
        (p,) = h.sim.open_positions.values()
        assert (p.direction, p.price_open, p.tp, p.sl) == (Direction.SELL, 3990, 3980, 0)

    run(scenario())


def test_enter_now_rejects_exact_tp_already_passed_by_the_live_price() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        h.sim.set_price(3996)  # price moved past the TP picked a moment ago
        with pytest.raises(EngineError, match="Enter now at 3996.00"):
            await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_sl_input="price", tp_price=3995)
        assert not h.sim.open_positions and h.engine.state == BotState.IDLE

    run(scenario())


def test_enter_now_waits_for_spread_then_opens() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0, spread=1.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=3, max_spread_points=0.6)
        assert h.engine.state == BotState.OPENING and not h.sim.open_positions
        h.sim.spread = 0.2
        await h.px(3990.1)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_enter_now_is_single_only() -> None:
    with pytest.raises(ValueError, match="Single"):
        CycleConfig(mode=Mode.CYCLE, direction=Direction.BUY, trigger_price=4000, lot=0.01, tp_points=3, enter_now=True)


def test_stop_now_then_close_all_records_the_trade() -> None:
    """Live bug (2026-11-20): Buy now -> Stop now -> Close all left the journal row open (P/L "—", duration ticking)."""

    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=None, sl_points=None)
        h.engine._stop("MANUAL_STOP", "left open")  # as the old Single Stop did (Cycle's Stop still does)
        await h.px(3991)
        await h.engine.close_all_and_stop()
        await h.px(3991)
        (row,) = h.cycles()
        assert row["close_reason"] == "KILL_SWITCH" and row["pnl"] is not None and row["close_time"] is not None
        assert h.engine.position is None and h.engine.state == BotState.STOPPED

    run(scenario())


def test_stop_now_then_broker_tp_records_the_trade_and_never_trades_again() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=3, sl_points=None)
        h.engine._stop("MANUAL_STOP", "left open")  # as the old Single Stop did (Cycle's Stop still does)
        await h.px(3995, 3990, 3990)  # TP hits on the broker while the bot is stopped
        (row,) = h.cycles()
        assert row["close_reason"] == "TP" and row["pnl"] > 0
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions
        assert h.engine.session_pnl == row["pnl"]

    run(scenario())


def test_drag_tp_onto_a_trade_entered_without_one() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=None, sl_points=None)
        await h.engine.modify_levels(3992, 3985)
        (p,) = h.sim.open_positions.values()
        assert (p.tp, p.sl) == (3992, 3985) and (h.cycles()[0]["tp"], h.cycles()[0]["sl"]) == (3992, 3985)
        await h.engine.modify_levels(3992, None)  # remove SL
        assert h.sim.open_positions[p.ticket].sl == 0 and h.engine.snapshot()["sl"] is None
        with pytest.raises(EngineError, match="must be above"):
            await h.engine.modify_levels(3989, None)  # BUY TP below the price
        await h.px(3992)
        assert h.engine.state == BotState.IDLE and h.cycles()[0]["close_reason"] == "TP"

    run(scenario())


def test_removing_planned_tp_is_not_shown_again() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=3, sl_points=None)
        await h.engine.modify_levels(None, None)
        assert (h.engine.snapshot()["tp"], h.engine.snapshot()["sl"]) == (None, None)
        await h.px(3993.5)
        assert h.engine.state == BotState.IN_POSITION  # the old TP is really gone

    run(scenario())


def test_modify_rejected_for_cycle_and_without_a_trade() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        with pytest.raises(EngineError):
            await h.engine.modify_levels(4000, None)
        await h.arm(cycle_gap=None, trigger_price=3990)
        await h.px(3989, 3990)
        assert h.engine.state == BotState.IN_POSITION
        with pytest.raises(EngineError, match="Single"):
            await h.engine.modify_levels(4000, None)

    run(scenario())


def test_single_stop_closes_the_trade_at_market() -> None:
    """Live (2026-11-20): Stop in Single left the trade open; the trader expects it to close."""

    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=None, sl_points=None)
        h.sim.reject_close_next = 1  # first close refused by the broker: retried on the next tick
        await h.engine.stop_now()
        assert h.sim.open_positions and h.engine.pending_close == "CLOSED"
        await h.px(3991, 3991)
        assert not h.sim.open_positions
        (row,) = h.cycles()
        assert row["close_reason"] == "CLOSED" and row["pnl"] is not None
        assert h.engine.state == BotState.IDLE  # ready for the next trade
        await h.arm(mode=Mode.SINGLE, trigger_price=3991, enter_now=True, tp_points=None, sl_points=None)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_single_stop_closes_a_trade_left_open() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=None, sl_points=None)
        h.engine._stop("MANUAL_STOP", "left open")
        h.sim.reject_close_next = 1
        await h.engine.stop_now()  # "Close trade" on the STOPPED engine
        await h.px(3991, 3991, 3991)
        assert not h.sim.open_positions and h.cycles()[0]["close_reason"] == "CLOSED"
        assert h.engine.position is None

    run(scenario())


def test_single_stop_while_waiting_cancels_and_cycle_stop_unchanged() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=4000, tp_points=3)
        await h.engine.stop_now()
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions

        c = Harness(start=3990.0)
        await c.arm(cycle_gap=None, trigger_price=3990)
        await c.px(3989, 3990)
        await c.engine.stop_now()  # Cycle: trade stays open with its server-side TP (unchanged)
        assert c.engine.state == BotState.STOPPED and c.sim.open_positions

    run(scenario())


def test_buy_now_shows_one_toast() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, trigger_price=3990, enter_now=True, tp_points=None, sl_points=None)
        assert len(h.toasts()) == 1 and "filled" in h.toasts()[0]

    run(scenario())
