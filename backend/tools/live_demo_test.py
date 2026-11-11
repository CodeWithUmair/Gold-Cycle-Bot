"""Live engine test on the Exness DEMO account (0.01 lots). Refuses to run on a real account."""

import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # backend/

# Usage (from backend/):  .\.venv\Scripts\python.exe tools\live_demo_test.py single cycle kill

from app.broker.mt5_gateway import Mt5Gateway  # noqa: E402
from app.config import Settings  # noqa: E402
from app.engine.cycle_engine import CycleEngine  # noqa: E402
from app.engine.models import BotState, CycleConfig  # noqa: E402
from app.storage.repo import Repo  # noqa: E402

SYMBOL = "XAUUSDm"
MAGIC = 7799001
SCRATCH = Path(__file__).resolve().parent  # live_test.db is written next to this script (gitignored *.db)
T0 = time.time()


def emit(kind: str, p: dict) -> None:
    if kind in ("log",):
        print(f"  [{time.time() - T0:6.1f}s] {p['level'].upper():5} {p['msg']}", flush=True)


async def wait_until(engine: CycleEngine, pred, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        await asyncio.sleep(0.1)
    return False


async def main(which: list[str]) -> None:
    gw = Mt5Gateway(Settings(broker="mt5"))
    await gw.connect()
    acc = await gw.account()
    assert acc.is_demo, "REFUSING: not a demo account"
    print(f"Account {acc.server} demo={acc.is_demo} balance={acc.balance}")
    repo = Repo(SCRATCH / "live_test.db")
    engine = CycleEngine(gw, repo, SYMBOL, MAGIC, emit=emit)
    await engine.load_symbol()
    stop = asyncio.Event()
    loop_task = asyncio.create_task(engine.run(0.1, stop))
    await asyncio.sleep(0.5)

    async def bid() -> float:
        return (await gw.tick(SYMBOL)).bid

    try:
        if "single" in which:
            b = await bid()
            trig = round(b - 0.3, 2)
            print(f"\n=== SINGLE BUY: bid {b}, trigger {trig}, TP 1 / SL 1 ===")
            await engine.arm(
                CycleConfig(mode="SINGLE", direction="BUY", trigger_price=trig, lot=0.01, tp_points=1, sl_points=1)
            )
            ok = await wait_until(engine, lambda: engine.state == BotState.IN_POSITION, 300)
            if ok:
                ps = await gw.positions(SYMBOL, MAGIC)
                p = ps[0]
                print(f"  -> server-side on position #{p.ticket}: open {p.price_open} TP {p.tp} SL {p.sl}")
                print(f"     comment '{p.comment}'")
            ok = await wait_until(engine, lambda: engine.state in (BotState.IDLE, BotState.STOPPED), 600)
            print(f"  RESULT state={engine.state} reason={engine.stop_reason} pnl={engine.session_pnl}")

        if "cycle" in which:
            b = await bid()
            trig = round(b + 0.3, 2)
            print(
                f"\n=== CYCLE BUY gap blank: bid {b}, trigger {trig}, TP 0.6 / SL 2, stop {trig + 1.5:.2f}, max 3 ==="
            )
            await engine.arm(
                CycleConfig(
                    mode="CYCLE",
                    direction="BUY",
                    trigger_price=trig,
                    lot=0.01,
                    tp_points=0.6,
                    sl_points=2,
                    cycle_gap=None,
                    stop_price=round(trig + 1.5, 2),
                    max_cycles=3,
                )
            )
            await wait_until(engine, lambda: engine.state in (BotState.IDLE, BotState.STOPPED), 900)
            print(f"  RESULT state={engine.state} reason={engine.stop_reason} pnl={engine.session_pnl:.2f}")

        if "kill" in which:
            b = await bid()
            trig = round(b - 0.2, 2)
            print(f"\n=== KILL SWITCH: BUY single trigger {trig}, TP 10 / SL 10, then Close all & stop ===")
            await engine.arm(
                CycleConfig(mode="SINGLE", direction="BUY", trigger_price=trig, lot=0.01, tp_points=10, sl_points=10)
            )
            if await wait_until(engine, lambda: engine.state == BotState.IN_POSITION, 300):
                await asyncio.sleep(2)
                await engine.close_all_and_stop()
                await wait_until(engine, lambda: engine.state == BotState.STOPPED, 30)
            print(f"  RESULT state={engine.state} reason={engine.stop_reason} pnl={engine.session_pnl:.2f}")

        rows = list(reversed(repo.cycles(limit=20)))
        print("\nJOURNAL")
        for r in rows[-10:]:
            print(
                f"  C{r['cycle_no']} {r['direction']} planned {r['planned_entry']} fill {r['fill_price']} "
                f"slip {r['slippage']} TP {r['tp']} SL {r['sl']} -> {r['close_reason']} @ {r['close_price']} "
                f"pnl {r['pnl']} ticket {r['ticket']}"
            )
    finally:
        if engine.state in (BotState.ARMED, BotState.OPENING, BotState.IN_POSITION, BotState.RESOLVING):
            print("cleanup: kill switch")
            await engine.close_all_and_stop()
            await asyncio.sleep(2)
        left = await gw.positions(SYMBOL, MAGIC)
        print(f"open bot positions left: {len(left)}")
        stop.set()
        await loop_task
        await gw.shutdown()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or ["single", "cycle", "kill"]))
