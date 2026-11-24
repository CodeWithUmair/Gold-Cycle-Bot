"""Plain-language explanations of MetaTrader5 `last_error()` codes, for a trader who is not a developer.

Pure (no MetaTrader5 import) so it is testable anywhere. Used by tools/check_mt5.py (the Manager's connection test).
"""

_AUTH = (
    "MetaTrader 5 refused the login. The account number, the password or the server is wrong. "
    "Use the TRADING password (not the investor / read-only one) and the exact server shown in your Exness account."
)
_NO_ANSWER = (
    "MetaTrader 5 did not answer in time. It may still be starting: wait a minute and try again. "
    "If it keeps happening, close the new MetaTrader 5 window and try again."
)

_BY_CODE: dict[int, str] = {
    -2: "The account number or server name is not valid. Check them and type them again.",
    -3: "MetaTrader 5 could not be started from the copied folder. Close every MetaTrader 5 window and try again.",
    -6: _AUTH,
    -10001: _NO_ANSWER,
    -10003: (
        "MetaTrader 5 could not be started from the bot's own copy. The copy may be missing, incomplete or blocked "
        "by an antivirus. In the GoldCycle Manager choose 7 (Update): it rebuilds a broken copy."
    ),
    -10005: _NO_ANSWER,
}


def explain(code: int, message: str) -> str:
    """Short advice for one MT5 error. Unknown codes keep MT5's own words so nothing is hidden."""
    if code in _BY_CODE:
        return _BY_CODE[code]
    if "auth" in message.lower():
        return _AUTH
    return f"MetaTrader 5 reported: {message} (code {code})."
