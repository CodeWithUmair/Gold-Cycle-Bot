"""Analytics math on a scripted session: two two-order cycles (TP, SL, TP, SL)."""

import pytest

from app.reports import build_report, cycles_csv
from tests.helpers import Harness, run


def test_report_kpis_from_real_engine_journal() -> None:
    async def scenario() -> Harness:
        h = Harness()
        await h.arm(cycle_gap=None, max_cycles=2)
        await h.px(4000, 4003, 3999.5)  # C1.1 TP, C1.2 opens at 4003 then SL at 4000
        await h.px(4000, 4003, 3999.5)  # C2 the same -> max cycles
        return h

    h = run(scenario())
    rep = build_report(h.repo.cycles_since(0), h.repo.sessions_since(0))
    k = rep["kpis"]
    assert (k["sessions"], k["cycles"], k["closed"], k["open"]) == (1, 4, 4, 0)
    assert (k["tp_count"], k["sl_count"], k["wins"], k["losses"]) == (2, 2, 2, 2)
    assert k["win_rate"] == pytest.approx(0.5)
    # 0.01 lot = $1 per point; BUY fills are at ask (bid + 0.2): TP +2.8, order 2 4003.2 -> SL 4000 = -3.2
    assert k["gross_profit"] == pytest.approx(5.6)
    assert k["gross_loss"] == pytest.approx(-6.4)
    assert k["net_pnl"] == pytest.approx(-0.8)
    assert k["profit_factor"] == pytest.approx(round(5.6 / 6.4, 2))
    assert k["max_drawdown"] == pytest.approx(3.6)  # peak +2.8 -> -0.8
    assert (k["max_win_streak"], k["max_loss_streak"]) == (1, 1)
    assert k["avg_slippage"] == pytest.approx(0.2)
    assert [e["cum"] for e in rep["equity"]] == pytest.approx([2.8, -0.4, 2.4, -0.8])
    assert {r["reason"]: r["count"] for r in rep["reasons"]} == {"TP": 2, "SL": 2}
    assert len(rep["daily"]) == 1 and rep["daily"][0]["cycles"] == 4
    s = rep["sessions"][0]
    assert (s["cycles"], s["tp"], s["sl"], s["stop_reason"], s["trigger_price"]) == (4, 2, 2, "MAX_CYCLES", 4000)

    csv = cycles_csv(h.repo.cycles_since(0))
    assert csv.splitlines()[0].startswith("session_id,cycle_no,leg,direction")
    assert len(csv.splitlines()) == 5


def test_empty_report() -> None:
    rep = build_report([], [])
    assert rep["kpis"]["win_rate"] is None and rep["kpis"]["net_pnl"] == 0
    assert rep["equity"] == [] and rep["sessions"] == []
