from dataclasses import asdict
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app.broker.base import TIMEFRAME_SECONDS
from app.context import AppContext, client_ip, get_ctx
from app.engine.cycle_engine import EngineError
from app.security import Session, csrf_session, current_session

router = APIRouter(prefix="/api", tags=["settings"])


@router.get("/settings")
async def get_settings(ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)) -> dict[str, Any]:
    symbols: list[str] = []
    err: str | None = None
    try:
        symbols = await ctx.broker.find_symbols()
    except Exception as e:  # shown in the UI; the dropdown just falls back to the current symbol
        err = str(e)
    return {
        "symbol": ctx.engine.symbol,
        "symbols": symbols or [ctx.engine.symbol],
        "symbols_error": err,
        "broker": ctx.broker.name,
        "dry_run": ctx.settings.dry_run and ctx.settings.broker == "mt5",
        "magic": ctx.settings.magic,
        "resume_on_restart": ctx.settings.resume_on_restart,
    }


class SymbolBody(BaseModel):
    symbol: str = Field(min_length=1, max_length=32)


@router.post("/settings/symbol")
async def set_symbol(
    body: SymbolBody, request: Request, ctx: AppContext = Depends(get_ctx), s: Session = Depends(csrf_session)
) -> dict[str, Any]:
    ctx.repo.audit(s.username, client_ip(request), "set_symbol", body.symbol)
    try:
        await ctx.engine.set_symbol(body.symbol)
    except (EngineError, ValueError) as e:
        raise HTTPException(409, str(e)) from e
    ctx.repo.set_setting("symbol", body.symbol)
    return {"symbol": ctx.engine.symbol}


@router.post("/settings/test-connection")
async def test_connection(
    request: Request, ctx: AppContext = Depends(get_ctx), s: Session = Depends(csrf_session)
) -> dict[str, Any]:
    ctx.repo.audit(s.username, client_ip(request), "test_connection")
    try:
        connected = await ctx.broker.is_connected()
        acc = await ctx.broker.account()
        tick = await ctx.broker.tick(ctx.engine.symbol)
        spec = await ctx.broker.symbol_spec(ctx.engine.symbol)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    return {
        "ok": connected,
        "account": {k: v for k, v in asdict(acc).items()},
        "tick": asdict(tick),
        "spec": asdict(spec),
    }


@router.get("/candles")
async def candles(
    tf: str = "M1", count: int = 500, ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)
) -> list[dict[str, Any]]:
    if tf not in TIMEFRAME_SECONDS:
        raise HTTPException(422, f"timeframe must be one of {list(TIMEFRAME_SECONDS)}")
    count = max(10, min(count, 5000))
    try:
        return [asdict(c) for c in await ctx.broker.candles(ctx.engine.symbol, tf, count)]
    except Exception as e:
        raise HTTPException(503, f"Candles unavailable: {e}") from e
