"""Application settings, loaded from `.env` (repo root or backend/)."""

from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_DIR = Path(__file__).resolve().parent.parent
ROOT_DIR = BACKEND_DIR.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(ROOT_DIR / ".env", BACKEND_DIR / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- broker ---
    broker: Literal["mt5", "sim"] = "sim"
    # DRY_RUN: real prices (from MT5 when broker=mt5) but orders are only logged + paper-filled.
    dry_run: bool = True
    mt5_login: int | None = None
    mt5_password: SecretStr | None = None
    mt5_server: str | None = None
    mt5_path: str | None = None  # path to terminal64.exe (optional)
    symbol: str | None = None  # overrides auto-detect / saved choice
    magic: int = 7_700_501
    poll_interval_ms: int = 100

    # --- engine ---
    resume_on_restart: bool = False

    # --- web ---
    host: str = "127.0.0.1"
    port: int = 8000
    admin_username: str = "admin"
    admin_password_hash: str = ""
    session_ttl_hours: int = 12
    frontend_dist: Path = ROOT_DIR / "frontend" / "dist"

    # --- storage / logs ---
    db_path: Path = ROOT_DIR / "data" / "goldcycle.db"
    log_dir: Path = ROOT_DIR / "logs"

    # --- simulator (broker=sim) ---
    sim_start_price: float = 4000.0
    sim_spread: float = 0.2

    @field_validator("mt5_login", "mt5_password", "mt5_server", "mt5_path", "symbol", mode="before")
    @classmethod
    def _blank_is_none(cls, v: object) -> object:
        return None if isinstance(v, str) and not v.strip() else v


@lru_cache
def get_settings() -> Settings:
    return Settings()
