"""Performance analytics over the cycle journal. Pure functions (no I/O) so they are testable."""

import json
from collections import defaultdict
from datetime import datetime
from typing import Any

WIN_REASONS = {"TP"}


def _session_summary(s: dict[str, Any], cycles: list[dict[str, Any]]) -> dict[str, Any]:
    cfg = json.loads(s["config_json"])
    closed = [c for c in cycles if c["close_reason"]]
    ended = s["ended_at"]
    return {
        "id": s["id"],
        "mode": s["mode"],
        "direction": s["direction"],
        "symbol": s["symbol"],
        "trigger_price": cfg.get("trigger_price"),
        "lot": cfg.get("lot"),
        "tp_points": cfg.get("tp_points"),
        "sl_points": cfg.get("sl_points"),
        "cycle_gap": cfg.get("cycle_gap"),
        "stop_price": cfg.get("stop_price"),
        "state": s["state"],
        "stop_reason": s["stop_reason"],
        "started_at": s["started_at"],
        "ended_at": ended,
        "duration_s": (ended - s["started_at"]) if ended else None,
        "cycles": len(cycles),
        "tp": sum(1 for c in closed if c["close_reason"] == "TP"),
        "sl": sum(1 for c in closed if c["close_reason"] == "SL"),
        "pnl": round(sum(c["pnl"] or 0 for c in closed), 2),
    }


def _streaks(pnls: list[float]) -> tuple[int, int]:
    best_w = best_l = cur_w = cur_l = 0
    for p in pnls:
        if p > 0:
            cur_w, cur_l = cur_w + 1, 0
        elif p < 0:
            cur_w, cur_l = 0, cur_l + 1
        else:
            cur_w = cur_l = 0
        best_w, best_l = max(best_w, cur_w), max(best_l, cur_l)
    return best_w, best_l


def build_report(cycles: list[dict[str, Any]], sessions: list[dict[str, Any]]) -> dict[str, Any]:
    """`cycles` and `sessions` are repo rows. Returns KPIs, equity curve, daily P/L, reasons, sessions."""
    closed = sorted((c for c in cycles if c["close_reason"]), key=lambda c: c["close_time"] or 0)
    pnls = [float(c["pnl"] or 0) for c in closed]
    wins = [p for p in pnls if p > 0]
    losses = [p for p in pnls if p < 0]
    gross_profit = sum(wins)
    gross_loss = sum(losses)
    net = gross_profit + gross_loss

    equity: list[dict[str, Any]] = []
    cum = peak = 0.0
    max_dd = 0.0
    for i, c in enumerate(closed, 1):
        cum += float(c["pnl"] or 0)
        peak = max(peak, cum)
        max_dd = max(max_dd, peak - cum)
        equity.append(
            {"n": i, "t": c["close_time"], "cum": round(cum, 2), "pnl": c["pnl"], "cycle_no": c["cycle_no"],
             "reason": c["close_reason"], "session_id": c["session_id"]}
        )  # fmt: skip

    daily: dict[str, dict[str, Any]] = defaultdict(lambda: {"pnl": 0.0, "cycles": 0, "wins": 0, "losses": 0})
    for c in closed:
        d = datetime.fromtimestamp(c["close_time"] or 0).date().isoformat()
        p = float(c["pnl"] or 0)
        daily[d]["pnl"] += p
        daily[d]["cycles"] += 1
        daily[d]["wins"] += p > 0
        daily[d]["losses"] += p < 0

    reasons: dict[str, dict[str, Any]] = defaultdict(lambda: {"count": 0, "pnl": 0.0})
    for c in closed:
        reasons[c["close_reason"]]["count"] += 1
        reasons[c["close_reason"]]["pnl"] += float(c["pnl"] or 0)

    slips = [float(c["slippage"]) for c in cycles if c["slippage"] is not None]
    durations = [c["close_time"] - c["open_time"] for c in closed if c["open_time"] and c["close_time"]]
    win_streak, loss_streak = _streaks(pnls)

    by_session: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for c in cycles:
        by_session[c["session_id"]].append(c)

    return {
        "kpis": {
            "sessions": len(sessions),
            "cycles": len(cycles),
            "closed": len(closed),
            "open": len(cycles) - len(closed),
            "wins": len(wins),
            "losses": len(losses),
            "win_rate": (len(wins) / len(closed)) if closed else None,
            "tp_count": sum(1 for c in closed if c["close_reason"] in WIN_REASONS),
            "sl_count": sum(1 for c in closed if c["close_reason"] == "SL"),
            "net_pnl": round(net, 2),
            "gross_profit": round(gross_profit, 2),
            "gross_loss": round(gross_loss, 2),
            "profit_factor": round(gross_profit / -gross_loss, 2) if gross_loss < 0 else None,
            "avg_win": round(gross_profit / len(wins), 2) if wins else None,
            "avg_loss": round(gross_loss / len(losses), 2) if losses else None,
            "expectancy": round(net / len(closed), 2) if closed else None,
            "best": round(max(pnls), 2) if pnls else None,
            "worst": round(min(pnls), 2) if pnls else None,
            "max_drawdown": round(max_dd, 2),
            "avg_slippage": round(sum(slips) / len(slips), 3) if slips else None,
            "max_slippage": round(max(slips), 3) if slips else None,
            "avg_duration_s": round(sum(durations) / len(durations), 1) if durations else None,
            "max_win_streak": win_streak,
            "max_loss_streak": loss_streak,
        },
        "equity": equity,
        "daily": [
            {"date": d, **{k: round(v, 2) if k == "pnl" else v for k, v in row.items()}}
            for d, row in sorted(daily.items())
        ],  # fmt: skip
        "reasons": sorted(
            ({"reason": r, "count": v["count"], "pnl": round(v["pnl"], 2)} for r, v in reasons.items()),
            key=lambda x: -x["count"],
        ),
        "sessions": [_session_summary(s, by_session.get(s["id"], [])) for s in sessions],
    }


CSV_COLUMNS = [
    "session_id", "cycle_no", "direction", "planned_entry", "fill_price", "slippage", "tp", "sl", "volume",
    "ticket", "open_time", "close_time", "close_price", "close_reason", "pnl",
]  # fmt: skip


def cycles_csv(cycles: list[dict[str, Any]]) -> str:
    def cell(k: str, v: Any) -> str:
        if v is None:
            return ""
        if k in ("open_time", "close_time"):
            return datetime.fromtimestamp(v).strftime("%Y-%m-%d %H:%M:%S")
        return str(v)

    lines = [",".join(CSV_COLUMNS)]
    for c in sorted(cycles, key=lambda c: (c["open_time"] or 0, c["id"])):
        lines.append(",".join(cell(k, c.get(k)) for k in CSV_COLUMNS))
    return "\n".join(lines) + "\n"
