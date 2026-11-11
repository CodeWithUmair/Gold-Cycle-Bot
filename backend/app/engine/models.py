"""Engine enums and the validated user configuration (the "Bot Interface", CLAUDE.md §3)."""

import re
from enum import StrEnum
from typing import Literal, Self

from pydantic import BaseModel, Field, model_validator


class Direction(StrEnum):
    BUY = "BUY"
    SELL = "SELL"


class Mode(StrEnum):
    SINGLE = "SINGLE"  # "Part Two"
    CYCLE = "CYCLE"  # "Part One"


class BotState(StrEnum):
    IDLE = "IDLE"
    ARMED = "ARMED"
    OPENING = "OPENING"
    IN_POSITION = "IN_POSITION"
    RESOLVING = "RESOLVING"
    STOPPED = "STOPPED"


class CloseReason(StrEnum):
    TP = "TP"
    SL = "SL"
    MANUAL = "MANUAL"  # closed by the trader in MT5
    STOP_OUT = "STOP_OUT"
    STOP_PRICE = "STOP_PRICE"  # bot closed it: stop price reached
    KILL_SWITCH = "KILL_SWITCH"  # bot closed it: "Close all & stop"
    DAILY_LOSS = "DAILY_LOSS"  # bot closed it: daily loss limit
    UNKNOWN = "UNKNOWN"


_HOURS_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$")


class CycleConfig(BaseModel):
    mode: Mode
    direction: Direction
    trigger_price: float = Field(gt=0)
    lot: float = Field(gt=0)

    # TP/SL. CYCLE mode always uses points. SINGLE mode may use exact prices (Q5).
    tp_sl_input: Literal["points", "price"] = "points"
    tp_points: float | None = Field(default=None, gt=0)
    sl_points: float | None = Field(default=None, gt=0)
    tp_price: float | None = Field(default=None, gt=0)
    sl_price: float | None = Field(default=None, gt=0)

    # CYCLE only
    cycle_gap: float | None = Field(default=None, ge=0)
    stop_price: float | None = Field(default=None, gt=0)
    gap_entry_mode: Literal["wait_for_touch", "immediate"] = "wait_for_touch"  # Q1
    sl_mode: Literal["points", "previous_entry"] = "points"  # Q2

    # execution
    level_anchor: Literal["planned", "fill"] = "planned"
    trigger_price_side: Literal["bid", "ask", "mid"] = "bid"
    max_slippage_points: float = Field(default=0.5, ge=0)

    # safety (all optional)
    max_cycles: int | None = Field(default=None, ge=1)
    daily_loss_limit: float | None = Field(default=None, gt=0)
    max_spread_points: float | None = Field(default=0.6, gt=0)
    trading_hours: str | None = None  # "HH:MM-HH:MM" in VPS local time, may wrap midnight
    lot_multiplier: float = Field(default=1.0, gt=0)  # hidden from UI v1

    @model_validator(mode="after")
    def _check(self) -> Self:
        if self.mode == Mode.CYCLE and self.tp_sl_input == "price":
            raise ValueError("CYCLE mode takes TP/SL in points")

        if self.tp_sl_input == "price":
            if self.tp_price is None or self.sl_price is None:
                raise ValueError("tp_price and sl_price are required when tp_sl_input='price'")
            buy = self.direction == Direction.BUY
            if buy and not (self.tp_price > self.trigger_price > self.sl_price):
                raise ValueError("BUY needs tp_price > trigger_price > sl_price")
            if not buy and not (self.tp_price < self.trigger_price < self.sl_price):
                raise ValueError("SELL needs tp_price < trigger_price < sl_price")
            # Engine only works in points: derive them from the exact prices.
            self.tp_points = round(abs(self.tp_price - self.trigger_price), 6)
            self.sl_points = round(abs(self.trigger_price - self.sl_price), 6)
        elif self.tp_points is None or self.sl_points is None:
            raise ValueError("tp_points and sl_points are required")

        if self.mode == Mode.SINGLE:
            self.cycle_gap = None
            self.stop_price = None
            self.max_cycles = 1
        elif self.stop_price is not None:
            if self.direction == Direction.BUY and self.stop_price <= self.trigger_price:
                raise ValueError("BUY cycle: stop_price must be above trigger_price")
            if self.direction == Direction.SELL and self.stop_price >= self.trigger_price:
                raise ValueError("SELL cycle: stop_price must be below trigger_price")

        if self.trading_hours is not None:
            self.trading_hours = self.trading_hours.strip() or None
        if self.trading_hours is not None and not _HOURS_RE.match(self.trading_hours):
            raise ValueError("trading_hours must look like 08:00-17:30")
        return self

    # Narrowed accessors (validated above)
    @property
    def tp_pts(self) -> float:
        assert self.tp_points is not None
        return self.tp_points

    @property
    def sl_pts(self) -> float:
        assert self.sl_points is not None
        return self.sl_points
