"""Touch detection (CLAUDE.md §4.6). No I/O.

At arm time we record which side of the level the price is on, then fire when the
price reaches the level from that side. If the price sits exactly on the level at arm
time we do NOT fire: we wait until it moves off and comes back (confirmed rule: never
enter on arm when the price is already at/past the trigger).
"""

from dataclasses import dataclass
from typing import Literal

from app.broker.base import Tick

Side = Literal["above", "below"]


def trigger_price(tick: Tick, side: str) -> float:
    if side == "ask":
        return tick.ask
    if side == "mid":
        return (tick.bid + tick.ask) / 2
    return tick.bid


@dataclass
class TouchTrigger:
    level: float
    side: Side | None  # where price was relative to level when armed

    @classmethod
    def arm(cls, level: float, price: float) -> "TouchTrigger":
        t = cls(level=level, side=None)
        t._set_side(price)
        return t

    def _set_side(self, price: float) -> None:
        if price > self.level:
            self.side = "above"
        elif price < self.level:
            self.side = "below"

    def update(self, price: float) -> bool:
        """Feed a price. Returns True when the level is touched."""
        if self.side is None:
            self._set_side(price)
            return False
        if self.side == "above":
            return price <= self.level
        return price >= self.level
