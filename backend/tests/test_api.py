"""API smoke test on the sim broker: auth, CSRF, validation, arm/stop, websocket."""

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.security import hash_password

PASSWORD = "correct-horse-battery"


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    s = Settings(
        _env_file=None,  # type: ignore[call-arg]  # never read the developer's .env in tests
        broker="sim",
        symbol=None,
        db_path=tmp_path / "t.db",
        log_dir=tmp_path / "logs",
        admin_password_hash=hash_password(PASSWORD),
        frontend_dist=tmp_path / "nodist",
    )
    monkeypatch.setattr("app.main.get_settings", lambda: s)
    get_settings.cache_clear()
    from app.main import create_app

    with TestClient(create_app(), base_url="http://127.0.0.1") as c:
        yield c


def login(c: TestClient) -> str:
    r = c.post("/api/auth/login", json={"username": "admin", "password": PASSWORD})
    assert r.status_code == 200, r.text
    csrf: str = r.json()["csrf"]
    return csrf


def test_health_is_public(client: TestClient) -> None:
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["broker"] == "sim"


def test_auth_required_and_rate_limited(client: TestClient) -> None:
    assert client.get("/api/bot/status").status_code == 401
    for _ in range(5):
        assert client.post("/api/auth/login", json={"username": "admin", "password": "nope"}).status_code == 401
    assert client.post("/api/auth/login", json={"username": "admin", "password": PASSWORD}).status_code == 429


def test_csrf_enforced_on_actions(client: TestClient) -> None:
    login(client)
    r = client.post("/api/bot/stop")
    assert r.status_code == 403


def test_validate_arm_stop_flow(client: TestClient) -> None:
    csrf = login(client)
    h = {"X-CSRF-Token": csrf}
    cfg = {"mode": "CYCLE", "direction": "BUY", "trigger_price": 4100, "lot": 0.01, "tp_points": 3, "sl_points": 3,
           "cycle_gap": 2}  # fmt: skip

    bad = client.post("/api/bot/validate", json={**cfg, "lot": 0.015, "tp_points": -1}).json()
    assert bad["errors"] and bad["ladder"] == []

    good = client.post("/api/bot/validate", json=cfg).json()
    assert good["errors"] == []
    assert [c["entry"] for c in good["ladder"]] == [4100, 4102, 4104, 4106, 4108]

    r = client.post("/api/bot/arm", json=cfg, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["state"] == "ARMED"
    assert client.post("/api/bot/arm", json=cfg, headers=h).status_code == 409  # already running

    with client.websocket_connect("ws://127.0.0.1/ws") as ws:
        first = ws.receive_json()
        assert first["type"] in {"state", "tick", "account"}

    r = client.post("/api/bot/stop", headers=h)
    assert r.status_code == 200 and r.json()["state"] == "STOPPED"

    assert client.get("/api/history/sessions").json()[0]["stop_reason"] == "MANUAL_STOP"
    assert len(client.get("/api/candles?tf=M5&count=50").json()) > 0
    assert client.get("/api/settings").json()["symbols"] == ["XAUUSD"]


def test_ws_rejects_anonymous(client: TestClient) -> None:
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect), client.websocket_connect("ws://127.0.0.1/ws") as ws:
        ws.receive_json()
