from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from app.context import AppContext, client_ip, get_ctx
from app.security import COOKIE_NAME, Session, current_session, verify_password

router = APIRouter(prefix="/api/auth", tags=["auth"])


class LoginBody(BaseModel):
    username: str = Field(max_length=64)
    password: str = Field(max_length=256)


@router.post("/login")
async def login(
    body: LoginBody, request: Request, response: Response, ctx: AppContext = Depends(get_ctx)
) -> dict[str, Any]:
    ip = client_ip(request)
    if ctx.limiter.blocked(ip):
        ctx.repo.audit(body.username, ip, "login_blocked")
        raise HTTPException(429, "Too many failed logins. Try again in a few minutes.")
    if not ctx.settings.admin_password_hash:
        raise HTTPException(503, "ADMIN_PASSWORD_HASH is not set in .env (run: python -m app.security)")
    ok = body.username == ctx.settings.admin_username and verify_password(
        ctx.settings.admin_password_hash, body.password
    )
    if not ok:
        ctx.limiter.fail(ip)
        ctx.repo.audit(body.username, ip, "login_failed")
        raise HTTPException(401, "Wrong username or password")
    ctx.limiter.reset(ip)
    token, s = ctx.sessions.create(body.username)
    response.set_cookie(
        COOKIE_NAME,
        token,
        httponly=True,
        samesite="strict",
        secure=False,  # served on 127.0.0.1 over plain http
        max_age=ctx.settings.session_ttl_hours * 3600,
        path="/",
    )
    ctx.repo.audit(body.username, ip, "login")
    return {"username": s.username, "csrf": s.csrf}


@router.post("/logout")
async def logout(request: Request, response: Response, ctx: AppContext = Depends(get_ctx)) -> dict[str, bool]:
    ctx.sessions.delete(request.cookies.get(COOKIE_NAME))
    response.delete_cookie(COOKIE_NAME, path="/")
    return {"ok": True}


@router.get("/me")
async def me(s: Session = Depends(current_session)) -> dict[str, Any]:
    return {"username": s.username, "csrf": s.csrf}
