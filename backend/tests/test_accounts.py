"""Several accounts on one VPS: per-account .env (GOLDCYCLE_ENV_FILE) and a session cookie per port."""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.security import SessionStore, hash_password

PASSWORD = "correct-horse-battery"


def test_env_file_from_goldcycle_env_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    env = tmp_path / ".env"
    env.write_text(f"BROKER=mt5\nDRY_RUN=false\nPORT=8002\nMAGIC=7700521\nDB_PATH={tmp_path / 'a.db'}\n", "utf-8")
    monkeypatch.setenv("GOLDCYCLE_ENV_FILE", str(env))
    get_settings.cache_clear()
    try:
        s = get_settings()
        assert (s.broker, s.dry_run, s.port, s.magic, s.db_path) == ("mt5", False, 8002, 7700521, tmp_path / "a.db")
    finally:
        get_settings.cache_clear()


def test_missing_env_file_refuses_to_start(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GOLDCYCLE_ENV_FILE", str(tmp_path / "nope.env"))
    get_settings.cache_clear()
    try:
        with pytest.raises(SystemExit):
            get_settings()
    finally:
        get_settings.cache_clear()


def test_login_survives_restart_and_is_stored_hashed() -> None:
    saved: list[str] = []
    a = SessionStore(ttl_s=3600)
    a.attach(None, saved.append)
    token, s = a.create("admin")
    assert token not in saved[-1]  # only a hash is on disk

    b = SessionStore(ttl_s=3600)  # "restart": a new store loads what the old one saved
    b.attach(saved[-1], saved.append)
    got = b.get(token)
    assert got is not None and got.csrf == s.csrf
    b.delete(token)
    c = SessionStore(ttl_s=3600)
    c.attach(saved[-1], saved.append)
    assert c.get(token) is None


def test_expired_and_corrupt_saved_logins_are_dropped() -> None:
    a = SessionStore(ttl_s=-1)  # already expired
    saved: list[str] = []
    a.attach(None, saved.append)
    token, _ = a.create("admin")
    b = SessionStore(ttl_s=3600)
    b.attach(saved[-1], saved.append)
    assert b.get(token) is None
    b.attach("{not json", saved.append)  # corrupt: logged, nobody logged in, no crash
    assert b.get(token) is None


def test_session_cookie_is_per_port(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    s = Settings(
        _env_file=None,  # type: ignore[call-arg]
        broker="sim",
        port=8002,
        db_path=tmp_path / "t.db",
        log_dir=tmp_path / "logs",
        admin_password_hash=hash_password(PASSWORD),
        frontend_dist=tmp_path / "nodist",
    )
    monkeypatch.setattr("app.main.get_settings", lambda: s)
    from app.main import create_app

    with TestClient(create_app(), base_url="http://127.0.0.1") as c:
        r = c.post("/api/auth/login", json={"username": "admin", "password": PASSWORD})
        assert r.status_code == 200
        assert "gc_session_8002" in r.cookies
        # another account's dashboard (other port) leaves its own cookie behind: this one still works
        c.cookies.set("gc_session_8001", "someone-else")
        assert c.get("/api/auth/me").status_code == 200
        with c.websocket_connect("ws://127.0.0.1/ws") as ws:
            assert ws.receive_json()["type"] in ("state", "tick")  # accepted (a rejected socket closes 4401)
