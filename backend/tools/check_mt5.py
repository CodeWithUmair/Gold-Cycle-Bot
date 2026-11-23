"""Connection test for the GoldCycle Manager: can this MetaTrader 5 log in to this account?

Reads GC_MT5_PATH / GC_MT5_LOGIN / GC_MT5_PASSWORD / GC_MT5_SERVER from the environment (never the command line, so
the password is not visible in the process list) and prints ONE json line:
  {"ok": true,  "login": 123, "server": "...", "demo": true, "balance": 1.0, "currency": "USD", "algo": true}
  {"ok": false, "code": -6, "error": "...", "hint": "plain-language advice"}
MetaTrader 5 stays open afterwards (shutdown() only detaches this script).
"""

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # backend/

from app.broker.mt5_errors import explain  # noqa: E402

WAIT_CONNECTED_S = 45


def fail(code: int, message: str) -> None:
    print(json.dumps({"ok": False, "code": code, "error": message, "hint": explain(code, message)}))


def main() -> None:
    try:
        import MetaTrader5 as mt5
    except ImportError:
        fail(-1, "the MetaTrader5 Python package is not installed")
        return
    kwargs: dict[str, object] = {"path": os.environ["GC_MT5_PATH"], "timeout": 90_000}
    login = os.environ.get("GC_MT5_LOGIN", "")
    if login:
        kwargs.update(login=int(login), server=os.environ.get("GC_MT5_SERVER", ""))
        if os.environ.get("GC_MT5_PASSWORD"):
            kwargs["password"] = os.environ["GC_MT5_PASSWORD"]
    if not mt5.initialize(**kwargs):  # type: ignore[arg-type]
        code, msg = mt5.last_error()
        fail(code, msg)
        return
    try:
        deadline = time.time() + WAIT_CONNECTED_S
        while time.time() < deadline:
            term, acc = mt5.terminal_info(), mt5.account_info()
            if term is not None and term.connected and acc is not None and (not login or acc.login == int(login)):
                print(
                    json.dumps(
                        {
                            "ok": True,
                            "login": acc.login,
                            "server": acc.server,
                            "demo": acc.trade_mode == 0,
                            "balance": acc.balance,
                            "currency": acc.currency,
                            "algo": bool(term.trade_allowed),
                        }
                    )
                )
                return
            time.sleep(1)
        fail(-6, "Authorization failed (the terminal never connected to the account)")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
