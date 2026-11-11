"""Broker interface. The engine depends only on this module (CLAUDE.md §6)."""

from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

from app.engine.models import Direction


class BrokerDisconnected(Exception):
    """Raised by a broker call when the terminal/broker connection is down."""


class DealReason(StrEnum):
    TP = "TP"
    SL = "SL"
    CLIENT = "CLIENT"  # manual close (desktop / mobile / web)
    EXPERT = "EXPERT"  # closed by an EA / API call (us)
    STOP_OUT = "STOP_OUT"
    OTHER = "OTHER"


@dataclass(frozen=True)
class Tick:
    bid: float
    ask: float
    time: float  # epoch seconds (broker server time for MT5)


@dataclass(frozen=True)
class SymbolSpec:
    name: str
    digits: int
    point: float  # MT5 point (0.01 on gold) — NOT the client's point
    volume_min: float
    volume_max: float
    volume_step: float
    stops_level: int  # in MT5 points
    freeze_level: int  # in MT5 points
    contract_size: float


@dataclass(frozen=True)
class AccountInfo:
    login: int
    server: str
    currency: str
    balance: float
    equity: float
    is_demo: bool
    trade_allowed: bool  # account + terminal "Algo Trading" enabled


@dataclass(frozen=True)
class Position:
    ticket: int
    symbol: str
    direction: Direction
    volume: float
    price_open: float
    sl: float
    tp: float
    profit: float
    magic: int
    comment: str
    time: float


@dataclass(frozen=True)
class OrderResult:
    ok: bool
    retcode: int = 0
    message: str = ""
    ticket: int | None = None  # position ticket on open
    price: float | None = None  # fill price
    fatal: bool = False  # retrying will not help (no money, trading disabled, invalid stops...)


@dataclass(frozen=True)
class CloseInfo:
    reason: DealReason
    price: float
    profit: float  # net: profit + swap + commission for the whole position
    time: float


@dataclass(frozen=True)
class Candle:
    time: int
    open: float
    high: float
    low: float
    close: float


class Broker(Protocol):
    name: str

    async def connect(self) -> None: ...
    async def reconnect(self) -> None: ...
    async def is_connected(self) -> bool: ...
    async def shutdown(self) -> None: ...

    async def find_symbols(self) -> list[str]: ...
    async def symbol_spec(self, symbol: str) -> SymbolSpec: ...
    async def tick(self, symbol: str) -> Tick: ...
    async def account(self) -> AccountInfo: ...
    async def candles(self, symbol: str, timeframe: str, count: int) -> list[Candle]: ...

    async def positions(self, symbol: str, magic: int) -> list[Position]: ...
    async def open_market(
        self,
        symbol: str,
        direction: Direction,
        volume: float,
        sl: float,
        tp: float,
        deviation_points: int,
        magic: int,
        comment: str,
    ) -> OrderResult: ...
    async def modify_position(self, symbol: str, ticket: int, sl: float, tp: float) -> OrderResult: ...
    async def close_position(self, position: Position, deviation_points: int) -> OrderResult: ...
    async def close_info(self, ticket: int) -> CloseInfo | None: ...


TIMEFRAME_SECONDS = {"M1": 60, "M5": 300, "M15": 900, "M30": 1800, "H1": 3600, "H4": 14400, "D1": 86400}
