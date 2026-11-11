"""Simulated broker: dev on any OS, engine tests, and DRY_RUN paper trading.

Price source, in priority order:
  * `feed`  — another Broker (DRY_RUN on MT5: real prices, virtual orders)
  * scripted — tests call `set_price()`
  * random walk — `random_walk=True` (dev dashboard without MT5)

TP/SL are evaluated server-side style on every `tick()` call:
BUY closes at TP when bid >= tp, at SL when bid <= sl; SELL uses ask.
"""

import itertools
import logging
import random
import time as _time

from app.broker.base import (
    TIMEFRAME_SECONDS,
    AccountInfo,
    Broker,
    BrokerDisconnected,
    Candle,
    CloseInfo,
    DealReason,
    OrderResult,
    Position,
    SymbolSpec,
    Tick,
)
from app.engine.models import Direction

log = logging.getLogger(__name__)

GOLD_SPEC = SymbolSpec(
    name="XAUUSD",
    digits=2,
    point=0.01,
    volume_min=0.01,
    volume_max=200.0,
    volume_step=0.01,
    stops_level=0,
    freeze_level=0,
    contract_size=100.0,
)


class SimBroker:
    def __init__(
        self,
        symbol: str = "XAUUSD",
        start_price: float = 4000.0,
        spread: float = 0.2,
        feed: Broker | None = None,
        random_walk: bool = False,
        spec: SymbolSpec | None = None,
        balance: float = 10_000.0,
    ) -> None:
        self.name = "dry-run" if feed is not None else "sim"
        self.symbol = symbol
        self.feed = feed
        self.random_walk = random_walk
        self.spec = spec or SymbolSpec(**{**GOLD_SPEC.__dict__, "name": symbol})
        self.bid = start_price
        self.ask = round(start_price + spread, 2)
        self.spread = spread
        self.balance = balance
        self.now = _time.time
        self.connected = True
        self.open_positions: dict[int, Position] = {}
        self.closed: dict[int, CloseInfo] = {}
        self.reject_next = 0  # test hook: reject the next N orders
        self.reject_close_next = 0  # test hook: reject the next N close orders
        self.history: list[Candle] = []
        self._tickets = itertools.count(1000)
        if random_walk and feed is None:
            self._seed_history()

    # ---- connection ----
    async def connect(self) -> None:
        if self.feed is not None:
            await self.feed.connect()
        self.connected = True

    async def reconnect(self) -> None:
        if self.feed is not None:
            await self.feed.reconnect()
        self.connected = True

    async def is_connected(self) -> bool:
        if self.feed is not None:
            return await self.feed.is_connected()
        return self.connected

    async def shutdown(self) -> None:
        if self.feed is not None:
            await self.feed.shutdown()

    def _check(self) -> None:
        if not self.connected:
            raise BrokerDisconnected("sim disconnected")

    # ---- market data ----
    async def find_symbols(self) -> list[str]:
        if self.feed is not None:
            return await self.feed.find_symbols()
        return [self.symbol]

    async def symbol_spec(self, symbol: str) -> SymbolSpec:
        if self.feed is not None:
            self.spec = await self.feed.symbol_spec(symbol)
        return self.spec

    def set_price(self, bid: float, ask: float | None = None) -> None:
        self.bid = bid
        self.ask = round(bid + self.spread, 6) if ask is None else ask

    async def tick(self, symbol: str) -> Tick:
        self._check()
        if self.feed is not None:
            t = await self.feed.tick(symbol)
            self.bid, self.ask = t.bid, t.ask
            ts = t.time
        else:
            if self.random_walk:
                self._walk()
            ts = self.now()
        self._update_candle(ts)
        self._evaluate_stops(ts)
        return Tick(self.bid, self.ask, ts)

    def _walk(self) -> None:
        step = random.gauss(0, 0.08)
        self.bid = round(max(1.0, self.bid + step), 2)
        self.ask = round(self.bid + self.spread, 2)

    def _seed_history(self) -> None:
        now = int(self.now()) // 60 * 60
        price = self.bid
        for i in range(500, 0, -1):
            o = price
            c = o + random.gauss(0, 1.2)
            h = max(o, c) + abs(random.gauss(0, 0.5))
            lo = min(o, c) - abs(random.gauss(0, 0.5))
            self.history.append(Candle(now - i * 60, round(o, 2), round(h, 2), round(lo, 2), round(c, 2)))
            price = c
        self.bid = round(price, 2)
        self.ask = round(price + self.spread, 2)

    def _update_candle(self, ts: float) -> None:
        if not self.random_walk:
            return
        minute = int(ts) // 60 * 60
        p = self.bid
        if self.history and self.history[-1].time == minute:
            c = self.history[-1]
            self.history[-1] = Candle(minute, c.open, max(c.high, p), min(c.low, p), p)
        else:
            self.history.append(Candle(minute, p, p, p, p))
            del self.history[:-5000]

    async def candles(self, symbol: str, timeframe: str, count: int) -> list[Candle]:
        if self.feed is not None:
            return await self.feed.candles(symbol, timeframe, count)
        secs = TIMEFRAME_SECONDS[timeframe]
        out: list[Candle] = []
        for c in self.history:
            t = c.time // secs * secs
            if out and out[-1].time == t:
                last = out[-1]
                out[-1] = Candle(t, last.open, max(last.high, c.high), min(last.low, c.low), c.close)
            else:
                out.append(Candle(t, c.open, c.high, c.low, c.close))
        return out[-count:]

    async def account(self) -> AccountInfo:
        self._check()
        floating = sum(p.profit for p in self.open_positions.values())
        if self.feed is not None:
            real = await self.feed.account()
            return AccountInfo(
                real.login, real.server, real.currency, self.balance, self.balance + floating, True, True
            )
        return AccountInfo(0, "SIM", "USD", self.balance, self.balance + floating, True, True)

    # ---- trading ----
    def _pnl(self, p: Position, close_price: float) -> float:
        s = 1 if p.direction == Direction.BUY else -1
        return round(s * (close_price - p.price_open) * p.volume * self.spec.contract_size, 2)

    def _evaluate_stops(self, ts: float) -> None:
        for p in list(self.open_positions.values()):
            if p.direction == Direction.BUY:
                px = self.bid
                hit_tp = p.tp > 0 and px >= p.tp
                hit_sl = p.sl > 0 and px <= p.sl
            else:
                px = self.ask
                hit_tp = p.tp > 0 and px <= p.tp
                hit_sl = p.sl > 0 and px >= p.sl
            if hit_sl:
                self._close(p, p.sl, DealReason.SL, ts)
            elif hit_tp:
                self._close(p, p.tp, DealReason.TP, ts)
            else:
                self.open_positions[p.ticket] = Position(**{**p.__dict__, "profit": self._pnl(p, px)})

    def _close(self, p: Position, price: float, reason: DealReason, ts: float) -> None:
        pnl = self._pnl(p, price)
        self.balance += pnl
        self.open_positions.pop(p.ticket, None)
        self.closed[p.ticket] = CloseInfo(reason, price, pnl, ts)
        log.info("[%s] closed #%s %s at %.2f pnl=%.2f", self.name, p.ticket, reason, price, pnl)

    def manual_close(self, ticket: int) -> None:
        """Test hook: the trader closes the position by hand in MT5."""
        p = self.open_positions[ticket]
        px = self.bid if p.direction == Direction.BUY else self.ask
        self._close(p, px, DealReason.CLIENT, self.now())

    async def positions(self, symbol: str, magic: int) -> list[Position]:
        self._check()
        return [p for p in self.open_positions.values() if p.symbol == symbol and p.magic == magic]

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
    ) -> OrderResult:
        self._check()
        log.info(
            "[%s] ORDER %s %s %.2f lots sl=%.2f tp=%.2f dev=%d magic=%d '%s'",
            self.name, direction, symbol, volume, sl, tp, deviation_points, magic, comment,
        )  # fmt: skip
        if self.reject_next > 0:
            self.reject_next -= 1
            return OrderResult(ok=False, retcode=10006, message="Request rejected (sim)")
        price = self.ask if direction == Direction.BUY else self.bid
        ticket = next(self._tickets)
        self.open_positions[ticket] = Position(
            ticket, symbol, direction, volume, price, sl, tp, 0.0, magic, comment, self.now()
        )
        return OrderResult(ok=True, retcode=10009, ticket=ticket, price=price)

    async def modify_position(self, symbol: str, ticket: int, sl: float, tp: float) -> OrderResult:
        self._check()
        p = self.open_positions.get(ticket)
        if p is None:
            return OrderResult(ok=False, retcode=10036, message="Position not found")
        self.open_positions[ticket] = Position(**{**p.__dict__, "sl": sl, "tp": tp})
        return OrderResult(ok=True, retcode=10009, ticket=ticket)

    async def close_position(self, position: Position, deviation_points: int) -> OrderResult:
        self._check()
        if self.reject_close_next > 0:
            self.reject_close_next -= 1
            return OrderResult(ok=False, retcode=10006, message="Close rejected (sim)")
        p = self.open_positions.get(position.ticket)
        if p is None:
            return OrderResult(ok=False, retcode=10036, message="Position not found")
        px = self.bid if p.direction == Direction.BUY else self.ask
        self._close(p, px, DealReason.EXPERT, self.now())
        return OrderResult(ok=True, retcode=10009, ticket=p.ticket, price=px)

    async def close_info(self, ticket: int) -> CloseInfo | None:
        self._check()
        return self.closed.get(ticket)
