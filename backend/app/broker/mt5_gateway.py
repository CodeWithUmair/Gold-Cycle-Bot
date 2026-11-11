"""Real MetaTrader 5 broker. The ONLY module that calls `mt5.*` (CLAUDE.md §6).

The MetaTrader5 library is not thread-safe, so every call runs on one dedicated
worker thread (a single-thread executor). Async callers just await `_call(...)`.
"""

import asyncio
import logging
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from typing import Any, TypeVar

from app.broker.base import (
    AccountInfo,
    BrokerDisconnected,
    Candle,
    CloseInfo,
    DealReason,
    OrderResult,
    Position,
    SymbolSpec,
    Tick,
)
from app.config import Settings
from app.engine.models import Direction

log = logging.getLogger(__name__)
T = TypeVar("T")

try:
    import MetaTrader5 as mt5
except ImportError:  # non-Windows dev box
    mt5 = None

# Retcodes where retrying the same request cannot help.
FATAL_RETCODES = {
    10013,  # INVALID request
    10014,  # INVALID_VOLUME
    10015,  # INVALID_PRICE
    10016,  # INVALID_STOPS
    10017,  # TRADE_DISABLED
    10019,  # NO_MONEY
    10022,  # INVALID_EXPIRATION
    10026,  # AUTOTRADING disabled by server
    10027,  # AUTOTRADING disabled by client (Algo Trading button)
    10030,  # INVALID_FILL
    10040,  # LIMIT_POSITIONS
}
OK_RETCODES = {10008, 10009, 10010}  # PLACED, DONE, DONE_PARTIAL

TIMEFRAMES = {"M1": "TIMEFRAME_M1", "M5": "TIMEFRAME_M5", "M15": "TIMEFRAME_M15", "M30": "TIMEFRAME_M30",
              "H1": "TIMEFRAME_H1", "H4": "TIMEFRAME_H4", "D1": "TIMEFRAME_D1"}  # fmt: skip


class Mt5Gateway:
    name = "mt5"

    def __init__(self, settings: Settings) -> None:
        if mt5 is None:
            raise RuntimeError("MetaTrader5 package not available (Windows only). Use BROKER=sim.")
        self._s = settings
        self._ex = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mt5")
        self._filling: dict[str, int] = {}

    async def _call(self, fn: Callable[..., T], *args: Any) -> T:
        return await asyncio.get_running_loop().run_in_executor(self._ex, fn, *args)

    # ------------------------------------------------------------ connection (worker thread)

    def _init_sync(self) -> None:
        kwargs: dict[str, Any] = {}
        if self._s.mt5_path:
            kwargs["path"] = self._s.mt5_path
        if self._s.mt5_login:
            kwargs["login"] = self._s.mt5_login
            kwargs["server"] = self._s.mt5_server or ""
            if self._s.mt5_password:
                kwargs["password"] = self._s.mt5_password.get_secret_value()
        if not mt5.initialize(**kwargs):
            code, msg = mt5.last_error()
            raise BrokerDisconnected(f"MT5 initialize failed: {msg} ({code})")
        acc = mt5.account_info()
        log.info("MT5 connected: login=%s server=%s", getattr(acc, "login", "?"), getattr(acc, "server", "?"))

    def _connected_sync(self) -> bool:
        info = mt5.terminal_info()
        return bool(info and info.connected)

    def _require_sync(self) -> None:
        if not self._connected_sync():
            raise BrokerDisconnected("MT5 terminal not connected")

    async def connect(self) -> None:
        await self._call(self._init_sync)

    async def reconnect(self) -> None:
        def _re() -> None:
            mt5.shutdown()
            self._init_sync()

        await self._call(_re)

    async def is_connected(self) -> bool:
        return await self._call(self._connected_sync)

    async def shutdown(self) -> None:
        await self._call(mt5.shutdown)
        self._ex.shutdown(wait=False)

    # ------------------------------------------------------------ market data

    async def find_symbols(self) -> list[str]:
        def _find() -> list[str]:
            self._require_sync()
            syms = mt5.symbols_get("*XAU*USD*") or ()
            return sorted(s.name for s in syms)

        return await self._call(_find)

    async def symbol_spec(self, symbol: str) -> SymbolSpec:
        def _spec() -> SymbolSpec:
            self._require_sync()
            if not mt5.symbol_select(symbol, True):
                raise ValueError(f"Symbol {symbol} not available on this account")
            i = mt5.symbol_info(symbol)
            if i is None:
                raise ValueError(f"Symbol {symbol} not found")
            # filling_mode is a bitmask of SYMBOL_FILLING_FOK(1) / SYMBOL_FILLING_IOC(2)
            if i.filling_mode & 1:
                self._filling[symbol] = mt5.ORDER_FILLING_FOK
            elif i.filling_mode & 2:
                self._filling[symbol] = mt5.ORDER_FILLING_IOC
            else:
                self._filling[symbol] = mt5.ORDER_FILLING_RETURN
            return SymbolSpec(
                name=i.name,
                digits=i.digits,
                point=i.point,
                volume_min=i.volume_min,
                volume_max=i.volume_max,
                volume_step=i.volume_step,
                stops_level=i.trade_stops_level,
                freeze_level=i.trade_freeze_level,
                contract_size=i.trade_contract_size,
            )

        return await self._call(_spec)

    async def tick(self, symbol: str) -> Tick:
        def _tick() -> Tick:
            t = mt5.symbol_info_tick(symbol)
            if t is None:
                self._require_sync()
                code, msg = mt5.last_error()
                raise BrokerDisconnected(f"No tick for {symbol}: {msg} ({code})")
            if t.bid <= 0 or t.ask <= 0:
                raise BrokerDisconnected(f"{symbol} has no prices (bid={t.bid}, ask={t.ask}) — wrong symbol?")
            return Tick(bid=t.bid, ask=t.ask, time=t.time_msc / 1000.0)

        return await self._call(_tick)

    async def account(self) -> AccountInfo:
        def _acc() -> AccountInfo:
            a = mt5.account_info()
            term = mt5.terminal_info()
            if a is None or term is None:
                raise BrokerDisconnected("account_info unavailable")
            return AccountInfo(
                login=a.login,
                server=a.server,
                currency=a.currency,
                balance=a.balance,
                equity=a.equity,
                is_demo=a.trade_mode == mt5.ACCOUNT_TRADE_MODE_DEMO,
                trade_allowed=bool(a.trade_allowed and a.trade_expert and term.trade_allowed),
            )

        return await self._call(_acc)

    async def candles(self, symbol: str, timeframe: str, count: int) -> list[Candle]:
        def _c() -> list[Candle]:
            rates = mt5.copy_rates_from_pos(symbol, getattr(mt5, TIMEFRAMES[timeframe]), 0, count)
            if rates is None:
                self._require_sync()
                return []
            return [
                Candle(int(r["time"]), float(r["open"]), float(r["high"]), float(r["low"]), float(r["close"]))
                for r in rates
            ]

        return await self._call(_c)

    # ------------------------------------------------------------ trading

    def _to_position(self, p: Any) -> Position:
        return Position(
            ticket=p.ticket,
            symbol=p.symbol,
            direction=Direction.BUY if p.type == mt5.POSITION_TYPE_BUY else Direction.SELL,
            volume=p.volume,
            price_open=p.price_open,
            sl=p.sl,
            tp=p.tp,
            profit=p.profit + p.swap,
            magic=p.magic,
            comment=p.comment,
            time=float(p.time),
        )

    async def positions(self, symbol: str, magic: int) -> list[Position]:
        def _pos() -> list[Position]:
            ps = mt5.positions_get(symbol=symbol)
            if ps is None:
                self._require_sync()
                code, msg = mt5.last_error()
                if code != 1:  # 1 = RES_S_OK with no positions on some builds
                    log.warning("positions_get returned None: %s (%s)", msg, code)
                return []
            return [self._to_position(p) for p in ps if p.magic == magic]

        return await self._call(_pos)

    def _send_sync(self, request: dict[str, Any]) -> Any:
        res = mt5.order_send(request)
        if res is None:
            code, msg = mt5.last_error()
            return None, f"order_send returned None: {msg} ({code})"
        return res, res.comment

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
        def _open() -> OrderResult:
            self._require_sync()
            t = mt5.symbol_info_tick(symbol)
            if t is None:
                raise BrokerDisconnected("no tick")
            buy = direction == Direction.BUY
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": symbol,
                "volume": volume,
                "type": mt5.ORDER_TYPE_BUY if buy else mt5.ORDER_TYPE_SELL,
                "price": t.ask if buy else t.bid,
                "sl": sl,
                "tp": tp,
                "deviation": deviation_points,
                "magic": magic,
                "comment": comment[:31],
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": self._filling.get(symbol, mt5.ORDER_FILLING_IOC),
            }
            log.info("order_send %s", {k: v for k, v in request.items()})
            res, msg = self._send_sync(request)
            if res is None:
                return OrderResult(ok=False, retcode=-1, message=msg)
            if res.retcode not in OK_RETCODES:
                return OrderResult(ok=False, retcode=res.retcode, message=msg, fatal=res.retcode in FATAL_RETCODES)
            # Find the resulting position (hedging accounts: position ticket == order ticket).
            ticket, fill = None, res.price or None
            for p in mt5.positions_get(symbol=symbol) or ():
                if p.magic == magic and (p.ticket == res.order or p.identifier == res.order):
                    ticket, fill = p.ticket, p.price_open
                    break
            if ticket is None:
                deals = mt5.history_deals_get(ticket=res.deal) if res.deal else None
                if deals:
                    ticket = deals[0].position_id
            return OrderResult(ok=True, retcode=res.retcode, message=msg, ticket=ticket or res.order, price=fill)

        return await self._call(_open)

    async def modify_position(self, symbol: str, ticket: int, sl: float, tp: float) -> OrderResult:
        def _mod() -> OrderResult:
            self._require_sync()
            res, msg = self._send_sync(
                {"action": mt5.TRADE_ACTION_SLTP, "symbol": symbol, "position": ticket, "sl": sl, "tp": tp}
            )
            if res is None:
                return OrderResult(ok=False, retcode=-1, message=msg)
            return OrderResult(ok=res.retcode in OK_RETCODES, retcode=res.retcode, message=msg, ticket=ticket)

        return await self._call(_mod)

    async def close_position(self, position: Position, deviation_points: int) -> OrderResult:
        def _close() -> OrderResult:
            self._require_sync()
            t = mt5.symbol_info_tick(position.symbol)
            if t is None:
                raise BrokerDisconnected("no tick")
            buy = position.direction == Direction.BUY
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": position.symbol,
                "position": position.ticket,
                "volume": position.volume,
                "type": mt5.ORDER_TYPE_SELL if buy else mt5.ORDER_TYPE_BUY,
                "price": t.bid if buy else t.ask,
                "deviation": deviation_points,
                "magic": position.magic,
                "comment": "GC|close",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": self._filling.get(position.symbol, mt5.ORDER_FILLING_IOC),
            }
            log.info("close position #%s", position.ticket)
            res, msg = self._send_sync(request)
            if res is None:
                return OrderResult(ok=False, retcode=-1, message=msg)
            return OrderResult(
                ok=res.retcode in OK_RETCODES, retcode=res.retcode, message=msg, ticket=position.ticket, price=res.price
            )

        return await self._call(_close)

    async def close_info(self, ticket: int) -> CloseInfo | None:
        def _info() -> CloseInfo | None:
            self._require_sync()
            deals = mt5.history_deals_get(position=ticket)
            if not deals:
                return None
            outs = [d for d in deals if d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY)]
            if not outs:
                return None
            last = max(outs, key=lambda d: d.time_msc)
            reasons = {
                mt5.DEAL_REASON_TP: DealReason.TP,
                mt5.DEAL_REASON_SL: DealReason.SL,
                mt5.DEAL_REASON_SO: DealReason.STOP_OUT,
                mt5.DEAL_REASON_CLIENT: DealReason.CLIENT,
                mt5.DEAL_REASON_MOBILE: DealReason.CLIENT,
                mt5.DEAL_REASON_WEB: DealReason.CLIENT,
                mt5.DEAL_REASON_EXPERT: DealReason.EXPERT,
            }
            net = sum(d.profit + d.swap + d.commission + getattr(d, "fee", 0.0) for d in deals)
            return CloseInfo(
                reason=reasons.get(last.reason, DealReason.OTHER),
                price=last.price,
                profit=round(net, 2),
                time=last.time_msc / 1000.0,
            )

        return await self._call(_info)
