"""FastAPI app: REST + WebSocket + built frontend, one process (CLAUDE.md §6).

Run:  python -m app.main     (binds 127.0.0.1 by default — never expose publicly)
"""

import asyncio
import logging
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from typing import Any

import uvicorn
from fastapi import FastAPI, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles

from app.api import auth, bot, history, reports
from app.api import settings as settings_api
from app.broker.base import Broker
from app.broker.sim_broker import SimBroker
from app.config import Settings, get_settings
from app.context import AppContext
from app.engine.cycle_engine import CycleEngine
from app.logging_setup import setup_logging
from app.security import COOKIE_NAME, LoginLimiter, SessionStore
from app.storage.repo import Repo
from app.ws import Hub

log = logging.getLogger("goldcycle")


def build_broker(s: Settings) -> Broker:
    if s.broker == "mt5":
        from app.broker.mt5_gateway import Mt5Gateway

        gw = Mt5Gateway(s)
        if s.dry_run:
            log.warning("DRY_RUN: real MT5 prices, orders are only logged and paper-filled")
            return SimBroker(symbol=s.symbol or "XAUUSD", feed=gw)
        return gw
    return SimBroker(symbol=s.symbol or "XAUUSD", start_price=s.sim_start_price, spread=s.sim_spread, random_walk=True)


async def pick_symbol(s: Settings, repo: Repo, broker: Broker) -> str:
    if s.symbol:
        return s.symbol
    saved = repo.get_setting("symbol")
    if saved:
        return saved
    try:
        found = await broker.find_symbols()
    except Exception as e:
        log.error("symbol auto-detect failed: %s", e)
        found = []
    for pref in ("XAUUSD", "XAUUSDm", "XAUUSDc", "XAUUSDz"):
        if pref in found:
            return pref
    return found[0] if found else "XAUUSD"


async def _recover_when_connected(engine: CycleEngine, resume: bool, stop: asyncio.Event) -> None:
    while not stop.is_set():
        if engine.connected:
            try:
                if engine.spec is None:
                    await engine.load_symbol()
                await engine.recover(resume)
                return
            except Exception as e:
                log.exception("recovery failed")
                engine._alert(f"Recovery failed: {e}")  # noqa: SLF001 - surfaced to UI
        await asyncio.sleep(2)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    s = get_settings()
    setup_logging(s.log_dir)
    repo = Repo(s.db_path)
    broker = build_broker(s)
    hub = Hub()
    connected = True
    try:
        await broker.connect()
    except Exception as e:
        connected = False
        log.error("Broker connect failed: %s — will keep retrying", e)
    symbol = await pick_symbol(s, repo, broker) if connected else (s.symbol or repo.get_setting("symbol") or "XAUUSD")
    engine = CycleEngine(broker, repo, symbol, s.magic, emit=hub.publish)
    engine.connected = connected
    if connected:
        try:
            await engine.load_symbol()
        except Exception as e:
            log.error("Symbol %s failed to load: %s", symbol, e)
    log.info("GoldCycle up: broker=%s symbol=%s dry_run=%s", broker.name, symbol, s.dry_run)

    app.state.ctx = AppContext(
        settings=s,
        repo=repo,
        broker=broker,
        engine=engine,
        hub=hub,
        sessions=SessionStore(ttl_s=s.session_ttl_hours * 3600),
        limiter=LoginLimiter(),
    )
    stop = asyncio.Event()
    tasks = [
        asyncio.create_task(engine.run(s.poll_interval_ms / 1000, stop), name="engine"),
        asyncio.create_task(hub.run(stop), name="hub"),
        asyncio.create_task(_recover_when_connected(engine, s.resume_on_restart, stop), name="recover"),
    ]
    try:
        yield
    finally:
        stop.set()
        await asyncio.gather(*tasks, return_exceptions=True)
        try:
            await broker.shutdown()
        except Exception as e:
            log.warning("broker shutdown: %s", e)
        repo.close()


def create_app() -> FastAPI:
    app = FastAPI(title="GoldCycle", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def security_headers(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        resp = await call_next(request)
        resp.headers["X-Frame-Options"] = "DENY"
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["Referrer-Policy"] = "no-referrer"
        return resp

    @app.get("/health")
    async def health(request: Request) -> dict[str, Any]:
        ctx: AppContext = request.app.state.ctx
        return {"ok": True, "broker": ctx.broker.name, "connected": ctx.engine.connected, "state": ctx.engine.state}

    app.include_router(auth.router)
    app.include_router(bot.router)
    app.include_router(settings_api.router)
    app.include_router(history.router)
    app.include_router(reports.router)

    @app.websocket("/ws")
    async def ws_endpoint(websocket: WebSocket) -> None:
        ctx: AppContext = websocket.app.state.ctx
        if ctx.sessions.get(websocket.cookies.get(COOKIE_NAME)) is None:
            await websocket.close(code=4401)
            return
        await websocket.accept()
        await ctx.hub.add(websocket)
        await websocket.send_json({"type": "state", "data": ctx.engine.snapshot()})
        try:
            while True:
                await websocket.receive_text()  # client pings; we only push
        except WebSocketDisconnect:
            pass
        finally:
            ctx.hub.remove(websocket)

    dist = get_settings().frontend_dist
    if dist.exists():
        app.mount("/", StaticFiles(directory=dist, html=True), name="frontend")
    return app


app = create_app()


def main() -> None:
    s = get_settings()
    if s.host not in ("127.0.0.1", "localhost", "::1"):
        log.warning("HOST=%s: dashboard reachable from the network. Only do this behind Tailscale/VPN.", s.host)
    uvicorn.run("app.main:app", host=s.host, port=s.port, log_level="info", ws="websockets")


if __name__ == "__main__":
    main()
