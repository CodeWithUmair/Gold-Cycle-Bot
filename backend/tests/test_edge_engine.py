"""Edge cases for the two-order cycle (CLAUDE.md §4) and Single mode, on the sim broker.

Harness defaults: BUY, trigger 4000, TP 3, gap 2, lot 0.01, start bid 3990, spread 0.2.
SELL triggers on bid; SELL TP/SL are evaluated by the broker on the ask (bid + 0.2).
"""

from datetime import date
from typing import Any

import pytest

from app.broker.base import CloseInfo
from app.engine.cycle_engine import EngineError
from app.engine.models import BotState, Direction, Mode
from tests.helpers import Harness, run


def rows(h: Harness) -> list[tuple[Any, ...]]:
    return [(r["cycle_no"], r["leg"], r["planned_entry"], r["tp"], r["sl"]) for r in h.cycles()]


def restart(h: Harness) -> Harness:
    h2 = Harness(repo=h.repo, sim=h.sim)
    h2.clock = h.clock
    h2.sim.now = lambda: h2.clock[0]
    return h2


def only_position(h: Harness) -> Any:
    (p,) = h.sim.open_positions.values()
    return p


# ---------------------------------------------------------------- SELL tables (§4.1)


def test_sell_gap_blank_three_cycles() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(direction=Direction.SELL, cycle_gap=None)
        for _ in range(3):
            await h.px(4000)  # Cn.1 SELL at 4000, TP 3997
            await h.px(3996.8)  # ask 3997 -> TP -> Cn.2 SELL at 3997, SL 4000
            await h.px(3999.8)  # ask 4000 -> SL -> next cycle armed at 4000
        assert rows(h) == [
            (1, 1, 4000, 3997, 0), (1, 2, 3997, 0, 4000),
            (2, 1, 4000, 3997, 0), (2, 2, 3997, 0, 4000),
            (3, 1, 4000, 3997, 0), (3, 2, 3997, 0, 4000),
        ]  # fmt: skip
        assert [r["close_reason"] for r in h.cycles()] == ["TP", "SL"] * 3
        assert h.engine.state == BotState.ARMED and (h.engine.cycle_no, h.engine.planned_entry) == (4, 4000)

    run(scenario())


def test_sell_gap_2_three_cycles() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(direction=Direction.SELL, cycle_gap=2)
        await h.px(4000, 3996.8, 3999.8)  # C1: 4000 TP 3997 / C1.2 3997 SL 4000 -> C2 armed 3998
        await h.px(3998, 3994.8, 3997.8)  # C2: 3998 TP 3995 / C2.2 3995 SL 3998 -> C3 armed 3996
        await h.px(3996, 3992.8, 3995.8)  # C3: 3996 TP 3993 / C3.2 3993 SL 3996 -> C4 armed 3994
        assert rows(h) == [
            (1, 1, 4000, 3997, 0), (1, 2, 3997, 0, 4000),
            (2, 1, 3998, 3995, 0), (2, 2, 3995, 0, 3998),
            (3, 1, 3996, 3993, 0), (3, 2, 3993, 0, 3996),
        ]  # fmt: skip
        assert h.engine.state == BotState.ARMED and h.engine.planned_entry == 3994

    run(scenario())


def test_price_already_past_trigger_waits_for_return() -> None:
    async def scenario() -> None:
        h = Harness(start=4005.0)  # BUY trigger 4000 is below the price at arm time
        await h.arm()
        await h.px(4003, 4001)
        assert h.engine.state == BotState.ARMED and not h.sim.open_positions
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


# ---------------------------------------------------------------- stop price (§4.5)


def test_buy_stop_above_trigger_hit_during_order_1() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(tp_points=20, stop_price=4010)
        await h.px(4000, 4010, 4010)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions and h.cycles()[0]["close_reason"] == "STOP_PRICE"

    run(scenario())


def test_buy_stop_below_trigger_hit_during_order_1_without_sl() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(stop_price=3995)
        await h.px(4000, 3995, 3995)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions

    run(scenario())


def test_buy_stop_above_trigger_hit_during_order_2() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(stop_price=4010)
        await h.px(4000, 4003)  # C1.2 open, no TP
        assert h.engine.leg == 2
        await h.px(4010, 4010)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions and h.cycles()[-1]["close_reason"] == "STOP_PRICE"

    run(scenario())


def test_sell_stop_below_trigger_hit_during_order_2_on_ask() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(direction=Direction.SELL, stop_price=3990)
        await h.px(4000, 3996.8)  # C1.2 SELL open at 3997, SL 4000
        await h.px(3990)  # ask 3990.2: not yet
        assert h.engine.state == BotState.IN_POSITION
        await h.px(3989.8, 3989.8)  # ask 3990 -> stop
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions

    run(scenario())


def test_sell_stop_above_trigger_hit_during_order_1() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(direction=Direction.SELL, stop_price=4005)
        await h.px(4000, 4004.8, 4004.8)  # ask 4005
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions

    run(scenario())


def test_stop_reached_while_armed_for_reentry() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=2, stop_price=3998)
        await h.px(4000, 4003, 4000)  # C1.2 SL -> C2.1 armed at 4002
        assert h.engine.state == BotState.ARMED
        await h.px(3998)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions

    run(scenario())


def test_next_reentry_beyond_stop_price_stops_the_chain() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=5, stop_price=4004)
        await h.px(4000, 4003, 4000)  # C1.2 SL -> next entry 4005 is past the stop 4004
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_PRICE"
        assert not h.sim.open_positions and len(h.cycles()) == 2

    run(scenario())


def test_order_1_tp_beyond_stop_price_never_opens_order_2() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(stop_price=4002)  # TP 4003 is past the stop
        await h.px(4000, 4003, 4003)  # price jumps over both in one tick
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions
        assert len(h.cycles()) == 1

    run(scenario())


# ---------------------------------------------------------------- max cycles (counts cycles, not orders)


def test_max_cycles_1_still_runs_order_2() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(max_cycles=1, cycle_gap=None)
        await h.px(4000, 4003)
        assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 2
        await h.px(4000)  # C1.2 SL
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MAX_CYCLES"
        assert len(h.cycles()) == 2

    run(scenario())


def test_max_cycles_2_stops_after_four_orders() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(max_cycles=2, cycle_gap=None)
        await h.px(4000, 4003, 4000)  # C1 done, C2.1 armed
        assert h.engine.state == BotState.ARMED
        await h.px(3999, 4000, 4003, 4000)  # C2 done
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MAX_CYCLES"
        assert [(r[0], r[1]) for r in rows(h)] == [(1, 1), (1, 2), (2, 1), (2, 2)]

    run(scenario())


# ---------------------------------------------------------------- kill switch


@pytest.mark.parametrize("leg", [1, 2])
def test_kill_switch_with_an_open_order(leg: int) -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000, *([4003] if leg == 2 else []))
        assert h.engine.leg == leg
        await h.engine.close_all_and_stop()
        assert not h.sim.open_positions
        await h.px(4001)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "KILL_SWITCH"
        assert h.cycles()[-1]["close_reason"] == "KILL_SWITCH"
        await h.px(4000, 4003)
        assert not h.sim.open_positions  # never trades again

    run(scenario())


def test_kill_switch_while_armed() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.engine.close_all_and_stop()
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "KILL_SWITCH"
        await h.px(4000)
        assert not h.sim.open_positions

    run(scenario())


def test_kill_switch_while_resolving_does_not_open_order_2() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        real = h.sim.close_info

        async def not_yet(ticket: int) -> CloseInfo | None:
            return None  # closing deal not in history yet

        h.sim.close_info = not_yet  # type: ignore[method-assign]
        await h.px(4003)  # broker closes C1.1 on TP, engine waits for the deal
        assert h.engine.state == BotState.RESOLVING
        await h.engine.close_all_and_stop()
        h.sim.close_info = real  # type: ignore[method-assign]
        await h.px(4003)
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions
        assert h.cycles()[0]["close_reason"] == "TP"

    run(scenario())


# ---------------------------------------------------------------- manual close in MT5


@pytest.mark.parametrize("leg", [1, 2])
def test_manual_close_stops_the_bot(leg: int) -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000, *([4003] if leg == 2 else []))
        h.sim.manual_close(only_position(h).ticket)
        await h.px(4001)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "MANUAL_CLOSE"
        assert h.cycles()[-1]["close_reason"] == "MANUAL"
        await h.px(4000, 4003)
        assert not h.sim.open_positions

    run(scenario())


# ---------------------------------------------------------------- restart / recovery (§7)


def test_restart_armed_cycle_1_then_opens_on_touch() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        h2 = restart(h)
        await h2.engine.recover(auto_resume=True)
        assert h2.engine.state == BotState.ARMED and h2.engine.planned_entry == 4000
        await h2.px(4000)
        assert h2.engine.state == BotState.IN_POSITION and len(h2.sim.open_positions) == 1

    run(scenario())


def test_restart_in_order_2_keeps_its_cycle_entry() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=2)
        await h.px(4000, 4003)  # C1.2 open, SL 4000
        h2 = restart(h)
        await h2.engine.recover(auto_resume=False)
        assert h2.engine.state == BotState.STOPPED and h2.engine.resumable
        await h2.engine.resume()
        assert h2.engine.state == BotState.IN_POSITION and (h2.engine.cycle_no, h2.engine.leg) == (1, 2)
        await h2.px(4000)  # C1.2 SL -> next cycle at C1 entry + gap
        assert h2.engine.state == BotState.ARMED and (h2.engine.cycle_no, h2.engine.planned_entry) == (2, 4002)
        assert len(h2.sim.open_positions) == 0

    run(scenario())


def test_restart_after_order_1_tp_while_down_opens_order_2_once() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        h.sim.set_price(4003)
        await h.sim.tick("XAUUSD")  # broker closes C1.1 on TP while the bot is down
        h2 = restart(h)
        await h2.engine.recover(auto_resume=False)
        await h2.engine.resume()
        p = only_position(h2)
        assert (h2.engine.leg, p.tp, p.sl) == (2, 0, 4000)
        await h2.px(4004, 4005)
        assert len(h2.sim.open_positions) == 1  # no duplicate

    run(scenario())


# ---------------------------------------------------------------- stop after this cycle / daily loss


def test_stop_after_cycle_requested_during_order_1() -> None:
    """Client (2026-11-21): a cycle is both orders. Order 2 still opens at once on order 1's TP; stop after it."""

    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        await h.engine.request_stop_after_cycle()
        await h.px(4003)
        (p,) = h.sim.open_positions.values()
        assert h.engine.state == BotState.IN_POSITION and h.engine.leg == 2 and p.sl == 4000
        await h.px(4000)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_AFTER_CYCLE"
        assert not h.sim.open_positions and len(h.cycles()) == 2 and h.engine.cycle_no == 1

    run(scenario())


def test_stop_after_cycle_requested_during_order_2() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000, 4003)
        await h.engine.request_stop_after_cycle()
        await h.px(4000)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "STOP_AFTER_CYCLE"
        assert not h.sim.open_positions

    run(scenario())


def test_daily_loss_limit_during_order_2_counts_order_1_profit() -> None:
    async def scenario() -> None:
        h = Harness()
        h.engine.today = lambda: date.fromtimestamp(1_000_000)  # the sim clock's day
        await h.arm(daily_loss_limit=0.25)
        await h.px(4000, 4003)  # C1.1 +2.80; C1.2 BUY filled at 4003.20, SL 4000
        await h.px(4001)  # floating -2.20, day +0.60
        assert h.engine.state == BotState.IN_POSITION
        await h.px(4000.1, 4000.1)  # floating -3.10, day -0.30 <= -0.25
        await h.px(4000.1)
        assert h.engine.state == BotState.STOPPED and h.engine.stop_reason == "DAILY_LOSS"
        assert not h.sim.open_positions and h.cycles()[-1]["close_reason"] == "DAILY_LOSS"
        with pytest.raises(EngineError, match="Daily loss"):
            await h.arm()

    run(scenario())


# ---------------------------------------------------------------- spread / rejected orders


def test_spread_too_wide_at_trigger_waits_then_opens() -> None:
    async def scenario() -> None:
        h = Harness(spread=1.0)
        await h.arm(max_spread_points=0.6)
        await h.px(4000)
        assert h.engine.state == BotState.OPENING and not h.sim.open_positions
        assert h.engine.waiting and "spread" in h.engine.waiting
        h.sim.spread = 0.2
        await h.px(4000.1)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_rejected_order_retries_then_fills() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        h.sim.reject_next = 2
        await h.px(4000, 4000)
        assert h.engine.state == BotState.OPENING and not h.sim.open_positions
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION and len(h.sim.open_positions) == 1

    run(scenario())


def test_rejected_order_then_price_runs_away_rearms() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        h.sim.reject_next = 1
        await h.px(4000, 4001)  # rejected, then 1 pt away (> 0.5 slippage)
        assert h.engine.state == BotState.ARMED and not h.sim.open_positions
        await h.px(4000)
        assert h.engine.state == BotState.IN_POSITION

    run(scenario())


def test_rejected_order_2_retries_at_once() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        h.sim.reject_next = 1
        await h.px(4003)  # C1.1 TP, C1.2 rejected
        assert h.engine.state == BotState.OPENING and h.engine.leg == 2
        await h.px(4003.1)
        p = only_position(h)
        assert h.engine.state == BotState.IN_POSITION and p.sl == 4000

    run(scenario())


# ---------------------------------------------------------------- Single mode


@pytest.mark.parametrize(
    ("tp", "sl", "path", "reason"),
    [(3, None, (4003,), "TP"), (None, 3, (3997,), "SL")],
)
def test_single_at_trigger_tp_only_or_sl_only(
    tp: float | None, sl: float | None, path: tuple[float, ...], reason: str
) -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=tp, sl_points=sl)
        await h.px(4000)
        p = only_position(h)
        assert (p.tp, p.sl) == (4003 if tp else 0, 3997 if sl else 0)
        await h.px(*path)
        assert h.engine.state == BotState.IDLE and h.cycles()[0]["close_reason"] == reason

    run(scenario())


def test_single_no_tp_sl_stays_open_until_close_trade() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=None, sl_points=None)
        await h.px(4000, 4050, 3950)
        assert h.engine.state == BotState.IN_POSITION
        await h.engine.stop_now()  # "Close trade"
        await h.px(3950)
        assert h.engine.state == BotState.IDLE and not h.sim.open_positions
        assert h.cycles()[0]["close_reason"] == "CLOSED"

    run(scenario())


def test_single_stop_while_waiting_never_opens() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, tp_points=3, sl_points=3)
        await h.engine.stop_now()
        await h.px(4000)
        assert h.engine.state == BotState.STOPPED and not h.sim.open_positions

    run(scenario())


def test_single_enter_now_then_tp() -> None:
    async def scenario() -> None:
        h = Harness(start=3990.0)
        await h.arm(mode=Mode.SINGLE, enter_now=True, tp_points=2, sl_points=2)
        p = only_position(h)
        assert (p.tp, p.sl) == (3992, 3988)
        await h.px(3992)
        assert h.engine.state == BotState.IDLE

    run(scenario())


def test_one_session_per_engine() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(mode=Mode.SINGLE, enter_now=True, tp_points=None, sl_points=None)
        with pytest.raises(EngineError, match="already running"):
            await h.arm()  # same engine: one session at a time

    run(scenario())
