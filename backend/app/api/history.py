from typing import Any

from fastapi import APIRouter, Depends

from app.context import AppContext, get_ctx
from app.security import Session, current_session

router = APIRouter(prefix="/api/history", tags=["history"])


@router.get("/cycles")
async def cycles(
    session_id: str | None = None,
    limit: int = 200,
    ctx: AppContext = Depends(get_ctx),
    _: Session = Depends(current_session),
) -> list[dict[str, Any]]:
    return ctx.repo.cycles(session_id, min(limit, 1000))


@router.get("/sessions")
async def sessions(
    limit: int = 50, ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)
) -> list[dict[str, Any]]:
    return ctx.repo.sessions(min(limit, 500))


@router.get("/events")
async def events(
    limit: int = 200, ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)
) -> list[dict[str, Any]]:
    return ctx.repo.events(min(limit, 1000))
