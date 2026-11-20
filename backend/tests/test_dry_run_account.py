"""DRY_RUN top bar: the connected account's real balance/equity, plus the paper trades' P/L."""

from app.broker.sim_broker import SimBroker
from app.engine.models import Direction
from tests.helpers import run


def test_dry_run_account_starts_at_real_balance_and_moves_with_paper_trades() -> None:
    async def scenario() -> None:
        real = SimBroker(start_price=4000, spread=0.2, balance=5000)  # stands in for the MT5 account
        paper = SimBroker(feed=real, balance=10_000)  # the paper balance itself is never shown
        await paper.tick("XAUUSD")
        acc = await paper.account()
        assert (acc.balance, acc.equity) == (5000, 5000)

        res = await paper.open_market("XAUUSD", Direction.BUY, 0.01, 0, 0, 10, 1, "t")  # fills at ask 4000.2
        real.set_price(4001.2)
        await paper.tick("XAUUSD")
        acc = await paper.account()
        assert (acc.balance, round(acc.equity, 2)) == (5000, 5001)  # floating +1.00

        (p,) = await paper.positions("XAUUSD", 1)
        await paper.close_position(p, 10)
        acc = await paper.account()
        assert res.ok and (round(acc.balance, 2), round(acc.equity, 2)) == (5001, 5001)  # realized

    run(scenario())
