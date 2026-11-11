"""SQLite persistence: sessions, cycles (journal), events, settings, audit (CLAUDE.md §7, §9)."""

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    mode TEXT NOT NULL,
    direction TEXT NOT NULL,
    symbol TEXT NOT NULL,
    config_json TEXT NOT NULL,
    state TEXT NOT NULL,
    runtime_json TEXT NOT NULL DEFAULT '{}',
    cycle_no INTEGER NOT NULL DEFAULT 0,
    pnl REAL NOT NULL DEFAULT 0,
    stop_reason TEXT,
    started_at REAL NOT NULL,
    ended_at REAL
);
CREATE TABLE IF NOT EXISTS cycles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    cycle_no INTEGER NOT NULL,
    direction TEXT NOT NULL,
    planned_entry REAL NOT NULL,
    fill_price REAL,
    slippage REAL,
    tp REAL NOT NULL,
    sl REAL NOT NULL,
    volume REAL NOT NULL,
    ticket INTEGER,
    open_time REAL,
    close_time REAL,
    close_price REAL,
    close_reason TEXT,
    pnl REAL
);
CREATE INDEX IF NOT EXISTS ix_cycles_session ON cycles(session_id);
CREATE INDEX IF NOT EXISTS ix_cycles_close ON cycles(close_time);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    session_id TEXT,
    level TEXT NOT NULL,
    from_state TEXT,
    to_state TEXT,
    message TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    username TEXT,
    ip TEXT,
    action TEXT NOT NULL,
    payload TEXT
);
"""


class Repo:
    def __init__(self, path: Path | str) -> None:
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.executescript(SCHEMA)

    def close(self) -> None:
        self._db.close()

    def _exec(self, sql: str, params: tuple[Any, ...] = ()) -> sqlite3.Cursor:
        with self._lock:
            return self._db.execute(sql, params)

    def _all(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(r) for r in self._db.execute(sql, params).fetchall()]

    # ---- sessions ----
    def create_session(self, sid: str, mode: str, direction: str, symbol: str, config_json: str, state: str) -> None:
        self._exec(
            "INSERT INTO sessions (id, mode, direction, symbol, config_json, state, started_at) VALUES (?,?,?,?,?,?,?)",
            (sid, mode, direction, symbol, config_json, state, time.time()),
        )

    def save_session(
        self, sid: str, state: str, runtime: dict[str, Any], cycle_no: int, pnl: float, stop_reason: str | None
    ) -> None:
        self._exec(
            "UPDATE sessions SET state=?, runtime_json=?, cycle_no=?, pnl=?, stop_reason=? WHERE id=?",
            (state, json.dumps(runtime), cycle_no, pnl, stop_reason, sid),
        )

    def end_session(self, sid: str) -> None:
        self._exec("UPDATE sessions SET ended_at=? WHERE id=? AND ended_at IS NULL", (time.time(), sid))

    def last_open_session(self) -> dict[str, Any] | None:
        rows = self._all("SELECT * FROM sessions WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1")
        return rows[0] if rows else None

    def sessions(self, limit: int = 50) -> list[dict[str, Any]]:
        return self._all("SELECT * FROM sessions ORDER BY started_at DESC LIMIT ?", (limit,))

    # ---- cycles ----
    def insert_cycle(self, **f: Any) -> int:
        cols = ", ".join(f)
        marks = ", ".join("?" for _ in f)
        cur = self._exec(f"INSERT INTO cycles ({cols}) VALUES ({marks})", tuple(f.values()))
        assert cur.lastrowid is not None
        return cur.lastrowid

    def update_cycle(self, cycle_id: int, **f: Any) -> None:
        sets = ", ".join(f"{k}=?" for k in f)
        self._exec(f"UPDATE cycles SET {sets} WHERE id=?", (*f.values(), cycle_id))

    def cycle(self, cycle_id: int) -> dict[str, Any] | None:
        rows = self._all("SELECT * FROM cycles WHERE id=?", (cycle_id,))
        return rows[0] if rows else None

    def cycles(self, session_id: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        if session_id:
            return self._all("SELECT * FROM cycles WHERE session_id=? ORDER BY id DESC LIMIT ?", (session_id, limit))
        return self._all("SELECT * FROM cycles ORDER BY id DESC LIMIT ?", (limit,))

    def cycles_since(self, ts: float) -> list[dict[str, Any]]:
        """Cycles of sessions started at/after ts (all if ts == 0)."""
        return self._all(
            "SELECT c.* FROM cycles c JOIN sessions s ON s.id = c.session_id WHERE s.started_at >= ? ORDER BY c.id",
            (ts,),
        )

    def sessions_since(self, ts: float) -> list[dict[str, Any]]:
        return self._all("SELECT * FROM sessions WHERE started_at >= ? ORDER BY started_at DESC", (ts,))

    def realized_pnl_since(self, ts: float) -> float:
        rows = self._all("SELECT COALESCE(SUM(pnl), 0) AS s FROM cycles WHERE close_time >= ?", (ts,))
        return float(rows[0]["s"])

    # ---- events / audit ----
    def add_event(
        self, session_id: str | None, level: str, message: str, from_state: str | None, to_state: str | None
    ) -> None:
        self._exec(
            "INSERT INTO events (ts, session_id, level, from_state, to_state, message) VALUES (?,?,?,?,?,?)",
            (time.time(), session_id, level, from_state, to_state, message),
        )

    def events(self, limit: int = 200) -> list[dict[str, Any]]:
        return self._all("SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,))

    def audit(self, username: str | None, ip: str | None, action: str, payload: Any = None) -> None:
        self._exec(
            "INSERT INTO audit (ts, username, ip, action, payload) VALUES (?,?,?,?,?)",
            (time.time(), username, ip, action, json.dumps(payload) if payload is not None else None),
        )

    # ---- settings ----
    def get_setting(self, key: str) -> str | None:
        rows = self._all("SELECT value FROM settings WHERE key=?", (key,))
        return rows[0]["value"] if rows else None

    def set_setting(self, key: str, value: str) -> None:
        self._exec(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )
