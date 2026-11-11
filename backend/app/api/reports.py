from datetime import datetime
from typing import Any

from fastapi import APIRouter, Depends, Request
from fastapi.responses import Response

from app.context import AppContext, client_ip, get_ctx
from app.reports import build_report, cycles_csv
from app.security import Session, current_session

router = APIRouter(prefix="/api/reports", tags=["reports"])


@router.get("/summary")
async def summary(
    since: float = 0, ctx: AppContext = Depends(get_ctx), _: Session = Depends(current_session)
) -> dict[str, Any]:
    """Analytics for sessions started at/after `since` (epoch seconds; 0 = all time)."""
    return build_report(ctx.repo.cycles_since(since), ctx.repo.sessions_since(since))


@router.get("/cycles.csv")
async def export_csv(
    request: Request, since: float = 0, ctx: AppContext = Depends(get_ctx), s: Session = Depends(current_session)
) -> Response:
    ctx.repo.audit(s.username, client_ip(request), "export_csv", {"since": since})
    name = f"goldcycle-cycles-{datetime.now():%Y%m%d-%H%M}.csv"
    return Response(
        cycles_csv(ctx.repo.cycles_since(since)),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{name}"'},
    )
