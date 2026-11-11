"""Cycle engine: the state machine of CLAUDE.md §4.8. Depends only on broker/base.py.

One tick = one `step()`. All public actions and `step()` hold the same asyncio lock,
so a user action never interleaves with a half-processed tick.
"""

import asyncio
import json
import logging
import time
import uuid
from collections.abc import Callable
from dataclasses import asdict, dataclass
from datetime import date, datetime
from datetime import time as dtime
from typing import Any

from app.broker.base import Broker, BrokerDisconnected, CloseInfo, DealReason, OrderResult, Position, SymbolSpec, Tick
from app.engine import levels, risk
from app.engine.models import BotState, CloseReason, CycleConfig, Mode
from app.engine.trigger import TouchTrigger, trigger_price
from app.storage.repo import Repo

log = logging.getLogger("goldcycle.engine")

ORDER_RETRY_S = 1.0  # min gap between order attempts while OPENING
RESOLVE_TIMEOUT_S = 10.0  # wait this long for the closing deal to show up in history
ALERT_THROTTLE_S = 5.0
ACCOUNT_POLL_S = 1.0
DEFAULT_SLIPPAGE_POINTS = 0.5  # CycleConfig default; used by the kill switch when no session is loaded

ACTIVE = {BotState.ARMED, BotState.OPENING, BotState.IN_POSITION, BotState.RESOLVING}

Emit = Callable[[str, dict[str, Any]], None]


class EngineError(Exception):
    """User-facing rejection of an action (bad state, failed validation...)."""


@dataclass
class LivePosition:
    ticket: int
    fill_price: float
    tp: float
    sl: float
    volume: float
    open_time: float


def _noop_emit(kind: str, payload: dict[str, Any]) -> None:
    pass


class CycleEngine:
    def __init__(
        self,
        broker: Broker,
        repo: Repo,
        symbol: str,
        magic: int,
        emit: Emit = _noop_emit,
        now: Callable[[], float] = time.time,
        local_time: Callable[[], dtime] = lambda: datetime.now().time(),
        today: Callable[[], date] = date.today,
    ) -> None:
        self.broker = broker
        self.repo = repo
        self.symbol = symbol
        self.magic = magic
        self.emit = emit
        self.now = now
        self.local_time = local_time
        self.today = today
        self.lock = asyncio.Lock()

        self.spec: SymbolSpec | None = None
        self.connected = True
        self.last_tick: Tick | None = None
        self._reset_session()

    def _reset_session(self) -> None:
        self.state = BotState.IDLE
        self.cfg: CycleConfig | None = None
        self.session_id: str | None = None
        self.cycle_no = 0
        self.planned_entry: float | None = None
        self.anchor_entry: float | None = None  # planned entry, or fill when level_anchor='fill'
        self.prev_entry: float | None = None
        self.cur_tp: float | None = None
        self.cur_sl: float | None = None
        self.trigger: TouchTrigger | None = None
        self.position: LivePosition | None = None
        self.cycle_row_id: int | None = None
        self.cycles_opened = 0
        self.session_pnl = 0.0
        self.floating = 0.0
        self.stop_after_cycle = False
        self.pending_close: CloseReason | None = None
        self.stop_reason: str | None = None
        self.resumable = False
        self.resume_state: BotState | None = None
        self.waiting: str | None = None
        self._last_order_attempt = 0.0
        self._resolve_started = 0.0
        self._last_alert = 0.0

    # ------------------------------------------------------------------ setup

    async def load_symbol(self, symbol: str | None = None) -> None:
        if symbol:
            self.symbol = symbol
        self.spec = await self.broker.symbol_spec(self.symbol)

    async def set_symbol(self, symbol: str) -> None:
        async with self.lock:
            if self.state in ACTIVE:
                raise EngineError("Stop the bot before changing the symbol")
            await self.load_symbol(symbol)
            self._emit_state()

    # ------------------------------------------------------------------ helpers

    def _log(self, msg: str, level: str = "info", toast: bool = False) -> None:
        getattr(log, "warning" if level == "warn" else level)(msg)
        self.repo.add_event(self.session_id, level, msg, None, None)
        payload = {"ts": self.now(), "level": level, "msg": msg}
        self.emit("log", payload)
        if toast:
            self.emit("toast", payload)

    def _alert(self, msg: str) -> None:
        """Error that repeats every tick (rejected close...): log each time, toast at most every few seconds."""
        t = self.now()
        self._log(msg, "error", toast=t - self._last_alert >= ALERT_THROTTLE_S)
        if t - self._last_alert >= ALERT_THROTTLE_S:
            self._last_alert = t

    def _runtime(self) -> dict[str, Any]:
        return {
            "cycle_no": self.cycle_no,
            "planned_entry": self.planned_entry,
            "anchor_entry": self.anchor_entry,
            "prev_entry": self.prev_entry,
            "cur_tp": self.cur_tp,
            "cur_sl": self.cur_sl,
            "position": asdict(self.position) if self.position else None,
            "cycle_row_id": self.cycle_row_id,
            "cycles_opened": self.cycles_opened,
            "session_pnl": self.session_pnl,
            "stop_after_cycle": self.stop_after_cycle,
            "pending_close": self.pending_close,
            "resumable": self.resumable,
            "resume_state": self.resume_state,
        }

    def _persist(self) -> None:
        if self.session_id:
            self.repo.save_session(
                self.session_id, self.state, self._runtime(), self.cycle_no, self.session_pnl, self.stop_reason
            )

    def _set_state(self, new: BotState, msg: str, level: str = "info", toast: bool = False) -> None:
        old = self.state
        self.state = new
        if new != BotState.ARMED:
            self.waiting = None
        self._persist()
        getattr(log, "warning" if level == "warn" else level)(msg)
        self.repo.add_event(self.session_id, level, msg, old, new)
        payload = {"ts": self.now(), "level": level, "msg": msg}
        self.emit("log", payload)
        if toast:
            self.emit("toast", payload)
        self._emit_state()

    def _emit_state(self) -> None:
        self.emit("state", self.snapshot())

    def _stop(self, reason: str, msg: str, level: str = "info") -> None:
        self.stop_reason = reason
        self.trigger = None
        self.pending_close = None
        self._set_state(BotState.STOPPED, msg, level, toast=True)
        if self.session_id and not self.resumable:
            self.repo.end_session(self.session_id)

    def _finish_single(self, msg: str, level: str = "info") -> None:
        self.stop_reason = "COMPLETE"
        self.trigger = None
        self._set_state(BotState.IDLE, msg, level, toast=True)
        if self.session_id:
            self.repo.end_session(self.session_id)

    def _comment(self) -> str:
        return f"GC|cycle={self.cycle_no}|session={self.session_id}"

    def _is_ours(self, p: Position) -> bool:
        return f"session={self.session_id}" in p.comment

    def _deviation(self) -> int:
        """MT5 `deviation` (in symbol points) for max_slippage_points (default 0.5 when no session config)."""
        assert self.spec
        slip = self.cfg.max_slippage_points if self.cfg else DEFAULT_SLIPPAGE_POINTS
        return max(1, round(levels.points_to_price(slip) / self.spec.point))

    def _levels_for(self, entry: float) -> tuple[float, float]:
        cfg = self.cfg
        assert cfg
        tp = levels.tp_price(entry, cfg.direction, cfg.tp_pts)
        sl = levels.cycle_sl(entry, cfg.direction, cfg.sl_pts, cfg.sl_mode, self.prev_entry)
        return tp, sl

    def _rp(self, price: float) -> float:
        assert self.spec
        return levels.round_price(price, self.spec.digits)

    def _start_of_day_ts(self) -> float:
        d = self.today()
        return datetime(d.year, d.month, d.day).timestamp()

    def _daily_block_active(self) -> bool:
        return self.repo.get_setting("daily_loss_block") == self.today().isoformat()

    def next_planned_entry(self) -> float | None:
        cfg = self.cfg
        if not cfg or cfg.mode != Mode.CYCLE or self.state not in ACTIVE:
            return None
        if self.anchor_entry is None or self.cur_tp is None:
            if self.planned_entry is None:
                return None
            tp, _ = self._levels_for(self.planned_entry)
            return levels.next_entry(self.planned_entry, tp, cfg.direction, cfg.cycle_gap)
        return levels.next_entry(self.anchor_entry, self.cur_tp, cfg.direction, cfg.cycle_gap)

    def snapshot(self) -> dict[str, Any]:
        cfg = self.cfg
        tp, sl = self.cur_tp, self.cur_sl
        if tp is None and self.planned_entry is not None and cfg:
            tp, sl = self._levels_for(self.planned_entry)
        return {
            "state": self.state,
            "session_id": self.session_id,
            "symbol": self.symbol,
            "connected": self.connected,
            "config": cfg.model_dump(mode="json") if cfg else None,
            "cycle_no": self.cycle_no,
            "trigger_level": self.trigger.level if self.trigger else None,
            "planned_entry": self.planned_entry,
            "tp": tp,
            "sl": sl,
            "next_entry": self.next_planned_entry(),
            "stop_price": cfg.stop_price if cfg else None,
            "position": {**asdict(self.position), "profit": self.floating} if self.position else None,
            "session_pnl": round(self.session_pnl, 2),
            "waiting": self.waiting,
            "stop_reason": self.stop_reason,
            "resumable": self.resumable,
            "stop_after_cycle": self.stop_after_cycle,
            "pending_close": self.pending_close,
            "daily_loss_block": self._daily_block_active(),
            "spec": asdict(self.spec) if self.spec else None,
        }

    # ------------------------------------------------------------------ actions

    async def arm(self, cfg: CycleConfig) -> None:
        async with self.lock:
            if self.state in ACTIVE:
                raise EngineError("Bot is already running — stop it first")
            if not self.connected:
                raise EngineError("Broker is disconnected")
            if self._daily_block_active():
                raise EngineError("Daily loss limit was hit today — no new trades until tomorrow")
            if self.spec is None:
                await self.load_symbol()
            assert self.spec
            existing = await self.broker.positions(self.symbol, self.magic)
            if existing:
                raise EngineError(f"A bot position is still open (#{existing[0].ticket}). Close it before arming.")
            tick = await self.broker.tick(self.symbol)
            errors, _ = risk.validate_config(cfg, self.spec, tick)
            if errors:
                raise EngineError("; ".join(errors))

            if self.session_id and self.resumable:
                self.repo.end_session(self.session_id)  # trader chose a fresh start over "Resume?"
            self._reset_session()
            self.cfg = cfg
            self.session_id = uuid.uuid4().hex[:8]
            self.repo.create_session(
                self.session_id, cfg.mode, cfg.direction, self.symbol, cfg.model_dump_json(), BotState.ARMED
            )
            self.cycle_no = 1
            self.planned_entry = cfg.trigger_price
            self._arm_trigger(tick)
            gap = "blank" if cfg.cycle_gap is None else f"{cfg.cycle_gap:g}"
            extra = f", gap {gap}, stop {cfg.stop_price or '—'}" if cfg.mode == Mode.CYCLE else ""
            self._set_state(
                BotState.ARMED,
                f"{cfg.mode} {cfg.direction} armed: C1 at {cfg.trigger_price:.2f}, lot {cfg.lot}, "
                f"TP {cfg.tp_pts:g} / SL {cfg.sl_pts:g} pts{extra}",
                toast=True,
            )

    def _arm_trigger(self, tick: Tick) -> None:
        assert self.cfg and self.planned_entry is not None
        self.trigger = TouchTrigger.arm(self.planned_entry, trigger_price(tick, self.cfg.trigger_price_side))
        self._update_waiting()

    def _update_waiting(self) -> None:
        if self.trigger is None:
            return
        verb = "return to" if self.trigger.side is None or self.cycle_no == 1 else "touch"
        self.waiting = f"Waiting for price to {verb} {self.trigger.level:.2f}"

    async def stop_now(self) -> None:
        async with self.lock:
            if self.state not in ACTIVE:
                raise EngineError("Bot is not running")
            note = ""
            if self.position:
                note = f"; position #{self.position.ticket} stays open with its server-side TP/SL"
            self._stop("MANUAL_STOP", f"Stopped by trader{note}")

    async def request_stop_after_cycle(self) -> None:
        async with self.lock:
            if self.state not in ACTIVE:
                raise EngineError("Bot is not running")
            if self.state == BotState.ARMED:
                self._stop("STOP_AFTER_CYCLE", "Stopped by trader (no cycle in progress)")
                return
            self.stop_after_cycle = True
            self._persist()
            self._log(f"Will stop after C{self.cycle_no} closes", toast=True)
            self._emit_state()

    async def close_all_and_stop(self) -> None:
        """Kill switch. Closes every position with our magic number, then stops."""
        async with self.lock:
            ps = await self.broker.positions(self.symbol, self.magic)
            tracked = self.position.ticket if self.position else None
            failures: list[str] = []
            for p in ps:
                if p.ticket == tracked and self.state == BotState.IN_POSITION:
                    continue  # closed (with retries) by the engine loop below
                res = await self._close_with_retries(p, attempts=3)
                if not res.ok:
                    failures.append(f"#{p.ticket}: {res.message} ({res.retcode})")
            if failures:
                self._log("Kill switch: could not close " + ", ".join(failures), "error", toast=True)
            if tracked is not None and self.state == BotState.IN_POSITION:
                self.pending_close = CloseReason.KILL_SWITCH
                self._log(f"Kill switch: closing C{self.cycle_no} #{tracked}", "warn", toast=True)
                await self._try_close_tracked()
                self._persist()
                self._emit_state()
            elif self.state == BotState.RESOLVING:
                self.stop_after_cycle = True  # record the cycle that just closed, then stop
                self._persist()
                self._log("Kill switch: stopping after the closing cycle is recorded", "warn", toast=True)
            elif self.state in ACTIVE:
                self._stop("KILL_SWITCH", "Kill switch: all bot positions closed, bot stopped", "warn")
            else:
                self._log("Kill switch: all bot positions closed", "warn", toast=True)

    async def _close_with_retries(self, p: Position, attempts: int) -> OrderResult:
        res = OrderResult(ok=False, message="not attempted")
        for i in range(attempts):
            if self.spec is None:
                await self.load_symbol()
            res = await self.broker.close_position(p, self._deviation())
            if res.ok:
                return res
            if i + 1 < attempts:
                await asyncio.sleep(0.3)
        return res

    async def resume(self) -> None:
        async with self.lock:
            if not self.resumable or self.cfg is None:
                raise EngineError("Nothing to resume")
            tick = await self.broker.tick(self.symbol)
            self.last_tick = tick
            target = self.resume_state or BotState.ARMED
            self.resumable = False
            self.resume_state = None
            self.stop_reason = None
            ps = await self.broker.positions(self.symbol, self.magic)

            if self.position:
                live = next((p for p in ps if p.ticket == self.position.ticket), None)
                if live:
                    self._set_state(
                        BotState.IN_POSITION, f"Resumed: reattached to C{self.cycle_no} #{live.ticket}", toast=True
                    )
                else:
                    self._resolve_started = self.now()
                    self._set_state(
                        BotState.RESOLVING,
                        f"Resumed: C{self.cycle_no} #{self.position.ticket} closed while the bot was down, resolving",
                        toast=True,
                    )
                    await self._on_resolving(tick)
                return

            mine = [p for p in ps if self._is_ours(p)]
            if mine:  # order went through just before the crash
                self._attach(mine[0])
                return
            if ps:
                self._stop("DUPLICATE_GUARD", f"Another bot position #{ps[0].ticket} is open — not resuming", "error")
                return
            self._arm_trigger(tick)
            self._set_state(
                BotState.ARMED,
                f"Resumed ({target}): C{self.cycle_no} armed at {self.planned_entry:.2f}",
                toast=True,
            )

    # ------------------------------------------------------------------ recovery

    async def recover(self, auto_resume: bool) -> None:
        """Load the last unfinished session after a restart (CLAUDE.md §7)."""
        row = self.repo.last_open_session()
        if row is None:
            return
        rt: dict[str, Any] = json.loads(row["runtime_json"] or "{}")
        state = BotState(row["state"])
        resume_state = BotState(rt["resume_state"]) if rt.get("resume_state") else state
        if resume_state in (BotState.IDLE, BotState.STOPPED):
            self.repo.end_session(row["id"])
            return

        self.cfg = CycleConfig.model_validate_json(row["config_json"])
        self.session_id = row["id"]
        self.symbol = row["symbol"]
        self.cycle_no = rt.get("cycle_no", 0)
        self.planned_entry = rt.get("planned_entry")
        self.anchor_entry = rt.get("anchor_entry")
        self.prev_entry = rt.get("prev_entry")
        self.cur_tp = rt.get("cur_tp")
        self.cur_sl = rt.get("cur_sl")
        self.position = LivePosition(**rt["position"]) if rt.get("position") else None
        self.cycle_row_id = rt.get("cycle_row_id")
        self.cycles_opened = rt.get("cycles_opened", 0)
        self.session_pnl = rt.get("session_pnl", 0.0)
        self.stop_after_cycle = rt.get("stop_after_cycle", False)
        self.pending_close = CloseReason(rt["pending_close"]) if rt.get("pending_close") else None
        self.resumable = True
        self.resume_state = resume_state
        await self.load_symbol()

        if auto_resume:
            self._log(f"Restarted while {resume_state}: resuming session {self.session_id}", "warn", toast=True)
            await self.resume()
        else:
            self.stop_reason = "RESTART"
            self._set_state(
                BotState.STOPPED,
                f"Bot restarted while {resume_state} (session {self.session_id}, C{self.cycle_no}). Resume?",
                "warn",
                toast=True,
            )

    # ------------------------------------------------------------------ main loop

    async def run(self, poll_s: float, stop: asyncio.Event) -> None:
        backoff = 1.0
        last_account = 0.0
        while not stop.is_set():
            try:
                if not self.connected:
                    await self._try_reconnect()
                if self.connected:
                    backoff = 1.0
                    await self.step()
                    if self.now() - last_account >= ACCOUNT_POLL_S:
                        last_account = self.now()
                        acc = await self.broker.account()
                        self.emit("account", asdict(acc))
            except BrokerDisconnected as e:
                await self._on_disconnect(e)
            except Exception as e:  # never let the loop die; surface it
                log.exception("engine loop error")
                self._alert(f"Engine error: {e}")
            delay = poll_s if self.connected else backoff
            if not self.connected:
                backoff = min(backoff * 2, 30.0)
            try:
                await asyncio.wait_for(stop.wait(), timeout=delay)
            except TimeoutError:
                pass

    async def _try_reconnect(self) -> None:
        try:
            await self.broker.reconnect()
            if await self.broker.is_connected():
                self.connected = True
                await self.load_symbol()
                self._log("Broker reconnected — resyncing positions", "info", toast=True)
                self._emit_state()
        except Exception as e:
            log.warning("reconnect failed: %s", e)

    async def _on_disconnect(self, e: Exception) -> None:
        if self.connected:
            self.connected = False
            self._log(f"Broker disconnected ({e}) — engine paused, no new orders", "error", toast=True)
            self._emit_state()

    async def step(self) -> None:
        async with self.lock:
            try:
                tick = await self.broker.tick(self.symbol)
            except BrokerDisconnected as e:
                await self._on_disconnect(e)
                return
            self.last_tick = tick
            self.emit("tick", {"bid": tick.bid, "ask": tick.ask, "time": tick.time})
            if self.state in ACTIVE:
                await self._process(tick)

    async def _process(self, tick: Tick) -> None:
        cfg = self.cfg
        assert cfg

        if cfg.daily_loss_limit is not None and self.pending_close is None:
            pnl_today = self.repo.realized_pnl_since(self._start_of_day_ts()) + self.floating
            if risk.daily_loss_hit(pnl_today, cfg.daily_loss_limit):
                self.repo.set_setting("daily_loss_block", self.today().isoformat())
                msg = f"Daily loss limit {cfg.daily_loss_limit} hit (today {pnl_today:+.2f})"
                if self.state == BotState.IN_POSITION:
                    self.pending_close = CloseReason.DAILY_LOSS
                    self._log(f"{msg} — closing C{self.cycle_no}", "error", toast=True)
                elif self.state != BotState.RESOLVING:
                    self._stop("DAILY_LOSS", f"{msg} — bot stopped", "error")
                    return

        if (
            self.cycles_opened > 0
            and self.pending_close is None
            and levels.stop_reached(tick.bid, tick.ask, cfg.direction, cfg.stop_price)
        ):
            if self.state == BotState.IN_POSITION:
                self.pending_close = CloseReason.STOP_PRICE
                self._log(f"Stop price {cfg.stop_price} reached — closing C{self.cycle_no}", "warn", toast=True)
            elif self.state in (BotState.ARMED, BotState.OPENING):
                self._stop("STOP_PRICE", f"Stop price {cfg.stop_price} reached — bot stopped")
                return

        if self.state == BotState.ARMED:
            await self._on_armed(tick)
        elif self.state == BotState.OPENING:
            await self._on_opening(tick)
        elif self.state == BotState.IN_POSITION:
            await self._on_in_position(tick)
        elif self.state == BotState.RESOLVING:
            await self._on_resolving(tick)

    # ------------------------------------------------------------------ states

    async def _on_armed(self, tick: Tick) -> None:
        assert self.cfg and self.trigger
        price = trigger_price(tick, self.cfg.trigger_price_side)
        if self.trigger.update(price):
            self._set_state(
                BotState.OPENING, f"C{self.cycle_no} trigger {self.trigger.level:.2f} touched ({price:.2f})"
            )
            self.trigger = None
            await self._on_opening(tick)
        else:
            before = self.waiting
            self._update_waiting()
            if self.waiting != before:
                self._emit_state()

    def _set_waiting(self, msg: str) -> None:
        if self.waiting != msg:
            self.waiting = msg
            self._log(f"C{self.cycle_no}: {msg}", "warn")
            self._emit_state()

    async def _on_opening(self, tick: Tick) -> None:
        cfg, spec = self.cfg, self.spec
        assert cfg and spec and self.planned_entry is not None
        planned = self.planned_entry
        price = trigger_price(tick, cfg.trigger_price_side)

        if not risk.within_slippage(price, planned, cfg.max_slippage_points):
            self._arm_trigger(tick)
            self._set_state(
                BotState.ARMED,
                f"C{self.cycle_no}: price {price:.2f} is more than {cfg.max_slippage_points:g} pts from "
                f"{planned:.2f} — waiting for another touch",
                "warn",
            )
            return
        if not risk.spread_ok(tick, cfg.max_spread_points):
            self._set_waiting(f"spread wider than max {cfg.max_spread_points:g} pts — waiting to open")
            return
        if not risk.in_trading_hours(self.local_time(), cfg.trading_hours):
            self._set_waiting(f"outside trading hours {cfg.trading_hours} — waiting to open")
            return
        if self.now() - self._last_order_attempt < ORDER_RETRY_S:
            return
        self._last_order_attempt = self.now()
        self.waiting = None

        # Idempotency: never open while any bot position exists.
        existing = await self.broker.positions(self.symbol, self.magic)
        if existing:
            mine = [p for p in existing if self._is_ours(p)]
            if mine:
                self._attach(mine[0])
            else:
                self._stop(
                    "DUPLICATE_GUARD",
                    f"Bot position #{existing[0].ticket} already open — refusing to open another",
                    "error",
                )
            return

        tp, sl = self._levels_for(planned)
        volume = levels.round_volume(levels.lot_for_cycle(cfg.lot, cfg.lot_multiplier, self.cycle_no), spec.volume_step)
        res = await self.broker.open_market(
            self.symbol,
            cfg.direction,
            volume,
            self._rp(sl),
            self._rp(tp),
            self._deviation(),
            self.magic,
            self._comment(),
        )
        if res.ok and res.ticket is not None:
            await self._on_filled(res.ticket, res.price or planned, tp, sl, volume)
        elif res.fatal:
            self._stop("ORDER_ERROR", f"C{self.cycle_no} order failed: {res.message} ({res.retcode})", "error")
        else:
            self._alert(f"C{self.cycle_no} order rejected: {res.message} ({res.retcode}) — retrying")

    async def _on_filled(self, ticket: int, fill: float, tp: float, sl: float, volume: float) -> None:
        cfg = self.cfg
        assert cfg and self.planned_entry is not None
        planned = self.planned_entry
        slip = round(levels.sign(cfg.direction) * levels.price_to_points(fill - planned), 2)
        self.anchor_entry = planned
        if cfg.level_anchor == "fill":
            self.anchor_entry = fill
            tp, sl = self._levels_for(fill)
            res = await self.broker.modify_position(self.symbol, ticket, self._rp(sl), self._rp(tp))
            if not res.ok:
                self._log(
                    f"C{self.cycle_no}: could not move TP/SL to fill-anchored levels ({res.message}); "
                    "planned TP/SL stay on the position",
                    "error",
                    toast=True,
                )
                self.anchor_entry = planned
                tp, sl = self._levels_for(planned)
        self.cur_tp, self.cur_sl = self._rp(tp), self._rp(sl)
        self.position = LivePosition(ticket, fill, self.cur_tp, self.cur_sl, volume, self.now())
        self.floating = 0.0
        self.cycles_opened += 1
        assert self.session_id
        self.cycle_row_id = self.repo.insert_cycle(
            session_id=self.session_id,
            cycle_no=self.cycle_no,
            direction=cfg.direction,
            planned_entry=planned,
            fill_price=fill,
            slippage=slip,
            tp=self.cur_tp,
            sl=self.cur_sl,
            volume=volume,
            ticket=ticket,
            open_time=self.now(),
        )
        self._emit_cycle()
        self._set_state(
            BotState.IN_POSITION,
            f"C{self.cycle_no} filled {cfg.direction} {volume} @ {fill:.2f} (planned {planned:.2f}, "
            f"slip {slip:+.2f}) TP {self.cur_tp:.2f} SL {self.cur_sl:.2f}",
            toast=True,
        )

    def _attach(self, p: Position) -> None:
        """Adopt a live position that belongs to this session (order filled but response lost / restart)."""
        cfg = self.cfg
        assert cfg and self.planned_entry is not None and self.session_id
        self.anchor_entry = self.planned_entry
        self.cur_tp, self.cur_sl = p.tp, p.sl
        self.position = LivePosition(p.ticket, p.price_open, p.tp, p.sl, p.volume, p.time)
        self.cycles_opened += 1
        slip = round(levels.sign(cfg.direction) * levels.price_to_points(p.price_open - self.planned_entry), 2)
        self.cycle_row_id = self.repo.insert_cycle(
            session_id=self.session_id, cycle_no=self.cycle_no, direction=cfg.direction,
            planned_entry=self.planned_entry, fill_price=p.price_open, slippage=slip, tp=p.tp, sl=p.sl,
            volume=p.volume, ticket=p.ticket, open_time=p.time,
        )  # fmt: skip
        self._emit_cycle()
        self._set_state(BotState.IN_POSITION, f"C{self.cycle_no}: attached to existing position #{p.ticket}", "warn")

    async def _try_close_tracked(self) -> bool:
        """Send a market close for the tracked position. Returns True if the broker accepted it."""
        assert self.position
        ps = await self.broker.positions(self.symbol, self.magic)
        live = next((p for p in ps if p.ticket == self.position.ticket), None)
        if live is None:
            return True  # already gone; RESOLVING picks it up
        res = await self.broker.close_position(live, self._deviation())
        if not res.ok:
            self._alert(
                f"Close of C{self.cycle_no} #{live.ticket} ({self.pending_close}) rejected: "
                f"{res.message} ({res.retcode}) — retrying every tick"
            )
        return res.ok

    async def _on_in_position(self, tick: Tick) -> None:
        assert self.position
        ps = await self.broker.positions(self.symbol, self.magic)
        live = next((p for p in ps if p.ticket == self.position.ticket), None)
        if live is None:
            self._resolve_started = self.now()
            self._set_state(BotState.RESOLVING, f"C{self.cycle_no} #{self.position.ticket} closed — resolving")
            await self._on_resolving(tick)
            return
        if live.profit != self.floating:
            self.floating = live.profit
            self.emit("floating", {"profit": live.profit})
        if self.pending_close is not None:
            await self._try_close_tracked()

    def _classify(self, info: CloseInfo | None) -> CloseReason:
        if self.pending_close is not None:
            return self.pending_close
        if info is None:
            return CloseReason.UNKNOWN
        mapping = {
            DealReason.TP: CloseReason.TP,
            DealReason.SL: CloseReason.SL,
            DealReason.CLIENT: CloseReason.MANUAL,
            DealReason.STOP_OUT: CloseReason.STOP_OUT,
        }
        if info.reason in mapping:
            return mapping[info.reason]
        # OTHER / EXPERT without us asking: infer from the close price
        tol = max(self.cfg.max_slippage_points if self.cfg else 0.5, 0.5)
        if self.cur_tp is not None and abs(info.price - self.cur_tp) <= tol:
            return CloseReason.TP
        if self.cur_sl is not None and abs(info.price - self.cur_sl) <= tol:
            return CloseReason.SL
        return CloseReason.UNKNOWN

    async def _on_resolving(self, tick: Tick) -> None:
        cfg = self.cfg
        assert cfg and self.position
        info = await self.broker.close_info(self.position.ticket)
        if info is None and self.now() - self._resolve_started < RESOLVE_TIMEOUT_S:
            return  # deal not in history yet; try next tick
        reason = self._classify(info)
        price = info.price if info else (tick.bid if cfg.direction == "BUY" else tick.ask)
        pnl = info.profit if info else 0.0
        if info is None:
            self._log(f"C{self.cycle_no}: closing deal not found in history; P/L unknown", "error", toast=True)
        n = self.cycle_no
        if self.cycle_row_id is not None:
            self.repo.update_cycle(
                self.cycle_row_id,
                close_time=info.time if info else self.now(),
                close_price=price,
                close_reason=reason,
                pnl=pnl,
            )
            self._emit_cycle()
        self.session_pnl += pnl
        self.floating = 0.0
        self.position = None
        self.pending_close = None
        result = f"C{n} {reason} at {price:.2f} {pnl:+.2f}"

        if reason == CloseReason.TP:
            if cfg.mode == Mode.SINGLE:
                self._finish_single(f"{result} — single trade complete")
            else:
                self._log(f"{result}", toast=True)
                await self._start_next_cycle(tick)
        elif reason == CloseReason.SL:
            if cfg.mode == Mode.SINGLE:
                self._finish_single(f"{result} — single trade complete", "warn")
            else:
                self._stop("SL", f"C{n} hit SL at {price:.2f} ({pnl:+.2f}), bot stopped", "warn")
        elif reason == CloseReason.MANUAL:
            self._stop("MANUAL_CLOSE", f"C{n} was closed manually in MT5 ({pnl:+.2f}) — bot stopped", "warn")
        elif reason in (CloseReason.STOP_PRICE, CloseReason.KILL_SWITCH, CloseReason.DAILY_LOSS):
            self._stop(reason, f"{result} — bot stopped", "warn")
        else:
            self._stop(reason, f"{result} — unexpected close, bot stopped", "error")

    async def _start_next_cycle(self, tick: Tick) -> None:
        cfg = self.cfg
        assert cfg and self.anchor_entry is not None and self.cur_tp is not None
        n = self.cycle_no
        if self.stop_after_cycle:
            self._stop("STOP_AFTER_CYCLE", f"Stopped after C{n} as requested")
            return
        if cfg.max_cycles is not None and n >= cfg.max_cycles:
            self._stop("MAX_CYCLES", f"Max cycles ({cfg.max_cycles}) reached — bot stopped")
            return
        nxt = levels.next_entry(self.anchor_entry, self.cur_tp, cfg.direction, cfg.cycle_gap)
        if levels.beyond_stop(nxt, cfg.direction, cfg.stop_price):
            self._stop("STOP_PRICE", f"Next entry {nxt:.2f} is at/beyond stop price {cfg.stop_price} — bot stopped")
            return
        self.prev_entry = self.anchor_entry
        self.cycle_no = n + 1
        self.planned_entry = nxt
        self.anchor_entry = None
        self.cur_tp = self.cur_sl = None
        self.cycle_row_id = None
        self._last_order_attempt = 0.0
        if levels.opens_immediately(cfg.cycle_gap, cfg.gap_entry_mode):
            self._set_state(BotState.OPENING, f"C{self.cycle_no} opening at market (planned {nxt:.2f})")
            await self._on_opening(tick)
        else:
            self._arm_trigger(tick)
            self._set_state(BotState.ARMED, f"C{self.cycle_no} armed at {nxt:.2f}")

    def _emit_cycle(self) -> None:
        if self.cycle_row_id is not None:
            row = self.repo.cycle(self.cycle_row_id)
            if row:
                self.emit("cycle", row)
