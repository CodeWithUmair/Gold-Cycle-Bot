from dataclasses import asdict
from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, Request
from pydantic import ValidationError

from app.context import AppContext, client_ip, get_ctx
from app.engine import levels, risk
from app.engine.cycle_engine import EngineError
from app.engine.models import CycleConfig
from app.security import Session, csrf_session, current_session

router = APIRouter(prefix="/api/bot", tags=["bot"])


def _parse(raw: dict[str, Any]) -> tuple[CycleConfig | None, list[str]]:
    try:
        return CycleConfig.model_validate(raw), []
    except ValidationError as e:
        msgs = []
        for err in e.errors():
            loc = ".".join(str(x) for x in err["loc"])
            msg = str(err["msg"]).removeprefix("Value error, ")
            msgs.append(f"{loc}: {msg}" if loc else msg)
        return None, msgs


@router.get("/status")
async def status(ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)) -> dict[str, Any]:
    return {
        "engine": ctx.engine.snapshot(),
        "account": ctx.hub.latest("account"),
        "tick": ctx.hub.latest("tick"),
        "broker": ctx.broker.name,
        "dry_run": ctx.settings.dry_run and ctx.settings.broker == "mt5",
    }


@router.post("/validate")
async def validate(
    raw: dict[str, Any] = Body(...), ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)
) -> dict[str, Any]:
    """Live form validation + preview ladder. Never 4xx for bad input: the form shows the errors."""
    cfg, errors = _parse(raw)
    if cfg is None:
        return {"errors": errors, "warnings": [], "ladder": []}
    warnings: list[str] = []
    if ctx.engine.spec is not None:
        errors, warnings = risk.validate_config(cfg, ctx.engine.spec, ctx.engine.last_tick)
    else:
        warnings.append("Symbol info not loaded yet (broker disconnected?)")
    return {"errors": errors, "warnings": warnings, "ladder": [asdict(c) for c in levels.preview_ladder(cfg, 5)]}


async def _action(ctx: AppContext, request: Request, s: Session, name: str, payload: Any = None) -> None:
    ctx.repo.audit(s.username, client_ip(request), name, payload)


@router.post("/arm")
async def arm(
    request: Request,
    raw: dict[str, Any] = Body(...),
    ctx: AppContext = Depends(get_ctx),
    s: Session = Depends(csrf_session),
) -> dict[str, Any]:
    await _action(ctx, request, s, "arm", raw)
    cfg, errors = _parse(raw)
    if cfg is None:
        raise HTTPException(422, "; ".join(errors))
    try:
        await ctx.engine.arm(cfg)
    except EngineError as e:
        raise HTTPException(409, str(e)) from e
    return ctx.engine.snapshot()


async def _simple(name: str, request: Request, ctx: AppContext, s: Session) -> dict[str, Any]:
    await _action(ctx, request, s, name)
    fn = {
        "stop": ctx.engine.stop_now,
        "stop_after_cycle": ctx.engine.request_stop_after_cycle,
        "close_all": ctx.engine.close_all_and_stop,
        "resume": ctx.engine.resume,
    }[name]
    try:
        await fn()
    except EngineError as e:
        raise HTTPException(409, str(e)) from e
    return ctx.engine.snapshot()


@router.post("/stop")
async def stop(
    request: Request, ctx: AppContext = Depends(get_ctx), s: Session = Depends(csrf_session)
) -> dict[str, Any]:
    return await _simple("stop", request, ctx, s)


@router.post("/stop-after-cycle")
async def stop_after_cycle(
    request: Request, ctx: AppContext = Depends(get_ctx), s: Session = Depends(csrf_session)
) -> dict[str, Any]:
    return await _simple("stop_after_cycle", request, ctx, s)


@router.post("/close-all")
async def close_all(
    request: Request, ctx: AppContext = Depends(get_ctx), s: Session = Depends(csrf_session)
) -> dict[str, Any]:
    return await _simple("close_all", request, ctx, s)


@router.post("/resume")
async def resume(
    request: Request, ctx: AppContext = Depends(get_ctx), s: Session = Depends(csrf_session)
) -> dict[str, Any]:
    return await _simple("resume", request, ctx, s)
