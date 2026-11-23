"""Auth: argon2 password check, in-memory sessions, CSRF, login rate limit (CLAUDE.md §9).

Generate the admin password hash for .env with:
    python -m app.security
"""

import hashlib
import json
import logging
import secrets
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass, field

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import HTTPException, Request

CSRF_HEADER = "x-csrf-token"

log = logging.getLogger("goldcycle")


def cookie_name_for(port: int) -> str:
    # Browsers share cookies across ports, so each account's dashboard (8001, 8002, …) needs its own
    # cookie name, or logging into one logs the other tab out.
    return f"gc_session_{port}"


def cookie_name(request: Request) -> str:
    return cookie_name_for(request.app.state.ctx.settings.port)

_ph = PasswordHasher()


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    if not password_hash:
        return False
    try:
        return _ph.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False


@dataclass
class Session:
    username: str
    csrf: str
    expires: float


def _key(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()  # only hashes are stored, never the cookie value


@dataclass
class SessionStore:
    """Logins, keyed by token hash. `attach` makes them survive a restart, so a bot restart or update
    doesn't log the trader's open browser tab out."""

    ttl_s: float
    _sessions: dict[str, Session] = field(default_factory=dict)
    _save: Callable[[str], None] | None = None

    def attach(self, saved: str | None, save: Callable[[str], None]) -> None:
        self._save = save
        if saved:
            try:
                self._sessions = {k: Session(**v) for k, v in json.loads(saved).items()}
            except (ValueError, TypeError):
                log.warning("saved logins unreadable: everyone has to log in again")
        self._sessions = {k: s for k, s in self._sessions.items() if s.expires >= time.time()}

    def _persist(self) -> None:
        if self._save:
            self._save(json.dumps({k: asdict(s) for k, s in self._sessions.items()}))

    def create(self, username: str) -> tuple[str, Session]:
        token = secrets.token_urlsafe(32)
        s = Session(username, secrets.token_urlsafe(32), time.time() + self.ttl_s)
        self._sessions[_key(token)] = s
        self._persist()
        return token, s

    def get(self, token: str | None) -> Session | None:
        if not token:
            return None
        s = self._sessions.get(_key(token))
        if s is None or s.expires < time.time():
            if self._sessions.pop(_key(token), None) is not None:
                self._persist()
            return None
        return s

    def delete(self, token: str | None) -> None:
        if token and self._sessions.pop(_key(token), None) is not None:
            self._persist()


@dataclass
class LoginLimiter:
    """At most `max_failures` failed logins per IP per `window_s`."""

    max_failures: int = 5
    window_s: float = 300.0
    _fails: dict[str, list[float]] = field(default_factory=dict)

    def blocked(self, ip: str) -> bool:
        now = time.time()
        recent = [t for t in self._fails.get(ip, []) if now - t < self.window_s]
        self._fails[ip] = recent
        return len(recent) >= self.max_failures

    def fail(self, ip: str) -> None:
        self._fails.setdefault(ip, []).append(time.time())

    def reset(self, ip: str) -> None:
        self._fails.pop(ip, None)


def current_session(request: Request) -> Session:
    store: SessionStore = request.app.state.ctx.sessions
    s = store.get(request.cookies.get(cookie_name(request)))
    if s is None:
        raise HTTPException(401, "Not logged in")
    return s


def csrf_session(request: Request) -> Session:
    """For state-changing requests: valid session AND matching CSRF header."""
    s = current_session(request)
    sent = request.headers.get(CSRF_HEADER, "")
    if not secrets.compare_digest(sent, s.csrf):
        raise HTTPException(403, "CSRF token missing or invalid")
    return s


if __name__ == "__main__":
    import getpass

    pw = getpass.getpass("New admin password: ")
    if len(pw) < 10:
        raise SystemExit("Use at least 10 characters.")
    if pw != getpass.getpass("Repeat: "):
        raise SystemExit("Passwords do not match.")
    print("\nPut this line in your .env:\n")
    print(f"ADMIN_PASSWORD_HASH={hash_password(pw)}")
