"""Engine enums and the validated user configuration (the "Bot Interface", CLAUDE.md §3)."""

import re
from enum import StrEnum
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator


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
    CLOSED = "CLOSED"  # bot closed it: trader pressed "Close trade" (Single)
    UNKNOWN = "UNKNOWN"


_HOURS_RE = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)-([01]\d|2[0-3]):([0-5]\d)$")


class CycleConfig(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)  # JSON accepts Infinity/NaN; never let them reach an order

    mode: Mode
    direction: Direction
    trigger_price: float = Field(gt=0)
    lot: float = Field(gt=0)

    # TP/SL. CYCLE mode always uses points and needs a TP. SINGLE mode may use exact prices (Q5), and both TP and
    # SL are optional there (client, 2026-11-20): both, TP only, SL only, or none.
    tp_sl_input: Literal["points", "price"] = "points"
    tp_points: float | None = Field(default=None, gt=0)
    sl_points: float | None = Field(default=None, gt=0)
    tp_price: float | None = Field(default=None, gt=0)
    sl_price: float | None = Field(default=None, gt=0)

    # CYCLE only. A cycle is two orders (§4.1): order 1 has TP and no SL, order 2 has SL (= order 1's entry) and
    # no TP, so sl_points is not used in CYCLE mode. cycle_gap shifts the restart after order 2's SL.
    cycle_gap: float | None = Field(default=None, ge=0)
    stop_price: float | None = Field(default=None, gt=0)

    # SINGLE only (client, 2026-11-20): "Enter now" opens at market at once. The engine replaces trigger_price with
    # the live price at arm time and re-validates exact TP/SL prices against it. Not for CYCLE: its trigger rule
    # (§4.6, never enter when price is already past the trigger) still holds there.
    enter_now: bool = False

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
        if self.mode == Mode.CYCLE and self.enter_now:
            raise ValueError("Enter now is for Single trades only")

        buy = self.direction == Direction.BUY
        side = 1 if buy else -1
        if self.tp_sl_input == "price":
            if self.tp_price is not None and side * (self.tp_price - self.trigger_price) <= 0:
                raise ValueError(f"{self.direction} TP price must be {'above' if buy else 'below'} the trigger price")
            if self.sl_price is not None and side * (self.trigger_price - self.sl_price) <= 0:
                raise ValueError(f"{self.direction} SL price must be {'below' if buy else 'above'} the trigger price")
            # Engine only works in points: derive them from the exact prices (blank price = none).
            self.tp_points = None if self.tp_price is None else round(abs(self.tp_price - self.trigger_price), 6)
            self.sl_points = None if self.sl_price is None else round(abs(self.trigger_price - self.sl_price), 6)
        elif self.tp_points is None and self.mode == Mode.CYCLE:
            raise ValueError("tp_points is required in CYCLE mode")

        if self.mode == Mode.SINGLE:
            self.cycle_gap = None
            self.stop_price = None
            self.max_cycles = 1
        else:
            self.sl_points = None
        # A huge SELL TP or BUY SL would put the level at/below 0: the broker can't take that.
        if self.tp_points is not None and self.trigger_price + side * self.tp_points <= 0:
            raise ValueError(f"TP {self.tp_points:g} pts puts the TP price at or below 0")
        if self.sl_points is not None and self.trigger_price - side * self.sl_points <= 0:
            raise ValueError(f"SL {self.sl_points:g} pts puts the SL price at or below 0")
        if self.mode == Mode.CYCLE and self.stop_price is not None and self.stop_price == self.trigger_price:
            # Any other value is allowed, above or below the trigger, for BUY and SELL (client, 2026-11-18).
            raise ValueError("stop_price can't equal trigger_price")

        if self.trading_hours is not None:
            self.trading_hours = self.trading_hours.strip() or None
        if self.trading_hours is not None and not _HOURS_RE.match(self.trading_hours):
            raise ValueError("trading_hours must look like 08:00-17:30")
        if self.trading_hours is not None and self.trading_hours[:5] == self.trading_hours[6:]:
            raise ValueError("trading_hours: start and end can't be the same (the bot would never trade)")
        return self

    # Narrowed accessor: CYCLE always has a TP (validated above). SINGLE code paths use tp_points (may be None).
    @property
    def tp_pts(self) -> float:
        assert self.tp_points is not None
        return self.tp_points
