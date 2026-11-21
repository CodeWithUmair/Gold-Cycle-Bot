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
    r = client.post("/api/bot/stop?mode=CYCLE")
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
    assert [(c["cycle"], c["leg"], c["entry"]) for c in good["ladder"]] == [
        (1, 1, 4100), (1, 2, 4103), (2, 1, 4102), (2, 2, 4105), (3, 1, 4104),
    ]  # fmt: skip

    r = client.post("/api/bot/arm", json=cfg, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["state"] == "ARMED"
    assert client.post("/api/bot/arm", json=cfg, headers=h).status_code == 409  # already running

    with client.websocket_connect("ws://127.0.0.1/ws") as ws:
        first = ws.receive_json()
        assert first["type"] in {"state", "tick", "account"}

    # Single runs alongside the cycle, on its own engine (client, 2026-11-18)
    single = {**cfg, "mode": "SINGLE", "direction": "SELL", "cycle_gap": None}
    r = client.post("/api/bot/arm", json=single, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["mode"] == "SINGLE" and r.json()["state"] == "ARMED"
    engines = client.get("/api/bot/status").json()["engines"]
    assert engines["CYCLE"]["state"] == engines["SINGLE"]["state"] == "ARMED"

    r = client.post("/api/bot/stop?mode=CYCLE", headers=h)
    assert r.status_code == 200 and r.json()["state"] == "STOPPED"
    assert client.get("/api/bot/status").json()["engines"]["SINGLE"]["state"] == "ARMED"  # untouched
    assert client.post("/api/bot/close-all", headers=h).status_code == 200  # no mode = both
    assert client.get("/api/bot/status").json()["engines"]["SINGLE"]["state"] == "STOPPED"

    reasons = {x["mode"]: x["stop_reason"] for x in client.get("/api/history/sessions").json()}
    assert reasons == {"CYCLE": "MANUAL_STOP", "SINGLE": "KILL_SWITCH"}
    assert len(client.get("/api/candles?tf=M5&count=50").json()) > 0
    assert client.get("/api/settings").json()["symbols"] == ["XAUUSD"]


def test_ws_rejects_anonymous(client: TestClient) -> None:
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect), client.websocket_connect("ws://127.0.0.1/ws") as ws:
        ws.receive_json()


def test_single_without_tp_sl_and_non_finite_input(client: TestClient) -> None:
    h = {"X-CSRF-Token": login(client)}
    single = {"mode": "SINGLE", "direction": "BUY", "trigger_price": 4100, "lot": 0.01}
    v = client.post("/api/bot/validate", json=single).json()
    assert v["errors"] == [] and any("no TP and no SL" in w for w in v["warnings"])
    assert [(c["tp"], c["sl"]) for c in v["ladder"]] == [(None, None)]
    r = client.post("/api/bot/arm", json=single, headers=h)
    assert r.status_code == 200 and r.json()["state"] == "ARMED", r.text
    assert "TP none, SL none" in client.get("/api/history/events").json()[0]["message"]

    # Python's JSON parser accepts Infinity/NaN literals: they must be rejected, never armed
    raw = '{"mode": "SINGLE", "direction": "BUY", "trigger_price": 4100, "lot": 0.01, "tp_points": Infinity}'
    v = client.post("/api/bot/validate", content=raw, headers={"Content-Type": "application/json"}).json()
    assert v["errors"] and v["ladder"] == []
    raw = raw.replace("Infinity", "NaN")
    r = client.post("/api/bot/arm", content=raw, headers={**h, "Content-Type": "application/json"})
    assert r.status_code == 422


def test_buy_now_then_drag_tp_sl(client: TestClient) -> None:
    h = {"X-CSRF-Token": login(client)}
    buy = {"mode": "SINGLE", "direction": "BUY", "trigger_price": 1, "lot": 0.01, "enter_now": True}
    r = client.post("/api/bot/arm", json=buy, headers=h)
    assert r.status_code == 200 and r.json()["state"] == "IN_POSITION", r.text
    px = r.json()["planned_entry"]
    r = client.post("/api/bot/modify?mode=SINGLE", json={"tp": px + 5, "sl": px - 5}, headers=h)
    assert r.status_code == 200 and (r.json()["tp"], r.json()["sl"]) == (round(px + 5, 2), round(px - 5, 2)), r.text
    r = client.post("/api/bot/modify?mode=SINGLE", json={"tp": None, "sl": px - 5}, headers=h)  # remove TP
    assert r.status_code == 200 and r.json()["tp"] is None
    assert client.post("/api/bot/modify?mode=SINGLE", json={"tp": px - 5}, headers=h).status_code == 409  # wrong side
    assert client.post("/api/bot/modify?mode=CYCLE", json={"tp": px + 5}, headers=h).status_code == 409
    assert client.post("/api/bot/modify?mode=SINGLE", json={"tp": 0}, headers=h).status_code == 422
    assert client.post("/api/bot/modify?mode=SINGLE", json={"tp": px + 5}).status_code == 403  # CSRF


def test_update_running_cycle(client: TestClient) -> None:
    h = {"X-CSRF-Token": login(client)}
    cyc = {"mode": "CYCLE", "direction": "BUY", "trigger_price": 9000, "lot": 0.01, "tp_points": 3}
    assert client.post("/api/bot/update", json=cyc, headers=h).status_code == 409  # not running
    assert client.post("/api/bot/arm", json=cyc, headers=h).status_code == 200
    r = client.post("/api/bot/update", json={**cyc, "tp_points": 5, "cycle_gap": 2}, headers=h)
    assert r.status_code == 200 and r.json()["config"]["tp_points"] == 5 and r.json()["tp"] == 9005, r.text
    assert client.post("/api/bot/update", json={**cyc, "direction": "SELL"}, headers=h).status_code == 409
    assert client.post("/api/bot/update", json={**cyc, "tp_points": -1}, headers=h).status_code == 422
    assert client.post("/api/bot/update", json=cyc).status_code == 403  # CSRF
