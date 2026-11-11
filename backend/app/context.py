"""Objects shared by the API routes (stored on app.state.ctx)."""

from dataclasses import dataclass

from fastapi import Request

from app.broker.base import Broker
from app.config import Settings
from app.engine.cycle_engine import CycleEngine
from app.security import LoginLimiter, SessionStore
from app.storage.repo import Repo
from app.ws import Hub


@dataclass
class AppContext:
    settings: Settings
    repo: Repo
    broker: Broker
    engine: CycleEngine
    hub: Hub
    sessions: SessionStore
    limiter: LoginLimiter


def get_ctx(request: Request) -> AppContext:
    ctx: AppContext = request.app.state.ctx
    return ctx


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "?"
