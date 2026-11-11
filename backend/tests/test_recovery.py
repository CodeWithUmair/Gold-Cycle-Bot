"""Restart / crash recovery (CLAUDE.md §7)."""

from app.engine.models import BotState
from tests.helpers import Harness, run


def restart(h: Harness) -> Harness:
    """A new engine process: same database, same broker (the live MT5 account)."""
    h2 = Harness(repo=h.repo, sim=h.sim)
    h2.clock = h.clock
    h2.sim.now = lambda: h2.clock[0]
    return h2


def test_restart_in_position_waits_for_resume_then_reattaches() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=2)
        await h.px(4000)
        ticket = h.engine.position.ticket  # type: ignore[union-attr]

        h2 = restart(h)
        await h2.engine.recover(auto_resume=False)
        assert h2.engine.state == BotState.STOPPED and h2.engine.resumable
        await h2.px(4001)  # STOPPED: does nothing
        assert len(h2.sim.open_positions) == 1

        await h2.engine.resume()
        assert h2.engine.state == BotState.IN_POSITION and h2.engine.position.ticket == ticket  # type: ignore[union-attr]
        await h2.px(4003)
        assert h2.engine.state == BotState.ARMED and h2.engine.cycle_no == 2 and h2.engine.planned_entry == 4002
        assert len(h2.sim.open_positions) == 0

    run(scenario())


def test_restart_survives_second_restart_before_resume() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        h2 = restart(h)
        await h2.engine.recover(auto_resume=False)
        h3 = restart(h2)
        await h3.engine.recover(auto_resume=False)
        assert h3.engine.resumable
        await h3.engine.resume()
        assert h3.engine.state == BotState.IN_POSITION

    run(scenario())


def test_position_closed_on_tp_while_down_continues_chain() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm(cycle_gap=2)
        await h.px(4000)
        h.sim.set_price(4003)
        await h.sim.tick("XAUUSD")  # broker closes it on TP while the bot is down

        h2 = restart(h)
        await h2.engine.recover(auto_resume=True)
        assert h2.engine.state == BotState.ARMED and h2.engine.cycle_no == 2
        rows = h2.cycles()
        assert rows[0]["close_reason"] == "TP"

    run(scenario())


def test_position_closed_on_sl_while_down_stops() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)
        h.sim.set_price(3996)
        await h.sim.tick("XAUUSD")
        h2 = restart(h)
        await h2.engine.recover(auto_resume=True)
        assert h2.engine.state == BotState.STOPPED and h2.engine.stop_reason == "SL"

    run(scenario())


def test_restart_during_opening_never_duplicates() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.arm()
        await h.px(4000)  # filled...
        # ...but pretend we crashed before recording it: roll the session back to OPENING
        h.engine.position = None
        h.engine.cycles_opened = 0
        h.engine.state = BotState.OPENING
        h.engine._persist()

        h2 = restart(h)
        await h2.engine.recover(auto_resume=True)
        assert h2.engine.state == BotState.IN_POSITION
        assert len(h2.sim.open_positions) == 1

    run(scenario())


def test_no_unfinished_session_is_a_noop() -> None:
    async def scenario() -> None:
        h = Harness()
        await h.engine.recover(auto_resume=True)
        assert h.engine.state == BotState.IDLE

    run(scenario())
