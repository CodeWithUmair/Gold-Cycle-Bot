import asyncio
from collections.abc import Coroutine
from datetime import time
from typing import Any

from app.broker.sim_broker import SimBroker
from app.engine.cycle_engine import CycleEngine
from app.engine.models import CycleConfig, Direction, Mode
from app.storage.repo import Repo

MAGIC = 777


def run(coro: Coroutine[Any, Any, Any]) -> Any:
    return asyncio.run(coro)


def make_cfg(**kw: Any) -> CycleConfig:
    base: dict[str, Any] = dict(
        mode=Mode.CYCLE, direction=Direction.BUY, trigger_price=4000, lot=0.01, tp_points=3, sl_points=3, cycle_gap=2
    )
    base.update(kw)
    return CycleConfig.model_validate(base)


class Harness:
    def __init__(
        self, start: float = 3990.0, spread: float = 0.2, repo: Repo | None = None, sim: SimBroker | None = None
    ):
        self.clock = [1_000_000.0]
        self.sim = sim or SimBroker(start_price=start, spread=spread)
        self.sim.now = lambda: self.clock[0]
        self.repo = repo or Repo(":memory:")
        self.events: list[tuple[str, dict[str, Any]]] = []
        self.engine = CycleEngine(
            self.sim,
            self.repo,
            "XAUUSD",
            MAGIC,
            emit=lambda k, p: self.events.append((k, p)),
            now=lambda: self.clock[0],
            local_time=lambda: time(12, 0),
        )

    async def arm(self, **kw: Any) -> None:
        await self.engine.load_symbol()
        await self.engine.arm(make_cfg(**kw))

    async def px(self, *bids: float) -> None:
        """Feed prices one tick each; advance the clock past the order-retry interval."""
        for b in bids:
            self.clock[0] += 1.5
            self.sim.set_price(b)
            await self.engine.step()

    def cycles(self) -> list[dict[str, Any]]:
        return list(reversed(self.repo.cycles(self.engine.session_id)))

    def logs(self) -> list[str]:
        return [p["msg"] for k, p in self.events if k == "log"]

    def toasts(self) -> list[str]:
        return [p["msg"] for k, p in self.events if k == "toast"]
