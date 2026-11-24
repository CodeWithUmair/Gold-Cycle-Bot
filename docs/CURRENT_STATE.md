# CURRENT STATE: read this first (new session / new machine)

**Last updated:** 2026-11-25 (end of Session 8, home laptop). Then read [../HANDOFF.md](../HANDOFF.md) (history) and
[../CLAUDE.md](../CLAUDE.md) (trading rules, source of truth).

## In one paragraph

GoldCycle executes a trader's gold (XAUUSD) levels on Exness MT5: open at a trigger price, attach TP/SL, and in Cycle
mode chain a two-order cycle. There are now **two implementations with the same rules**. On 2026-11-25 the client asked
for **the bot inside MetaTrader** (no web dashboard), so the **Expert Advisor in [../mql5/](../mql5/README.md) is the
current direction**. It was built, compiled and live-tested on demo the same day. The older Python bot + web dashboard
(`backend/`, `frontend/`, `scripts/`) still works and is kept; do not run both on one account at the same time.

## Start on a new machine

```powershell
git clone https://github.com/CodeWithUmair/Gold-Cycle-Bot.git    # or: git pull, inside an existing clone
cd Gold-Cycle-Bot
powershell -ExecutionPolicy Bypass -File mql5\build.ps1          # needs MetaTrader 5 installed and started once
```
`build.ps1` copies the sources into that MetaTrader's data folder, compiles (must say `0 errors, 0 warnings`), installs
the EA there and refreshes `mql5/release/GoldCycle.ex5`. Other install folder: `-Terminal "<folder>"`.
No `.env`, Python or Node is needed for the EA. The Python bot needs its own `.env` (not in git).

## The Expert Advisor: what exists

`mql5/release/GoldCycle.ex5` is the single file the client installs (steps in [../mql5/README.md](../mql5/README.md)).
Panel on the chart ([screenshot](../mql5/docs/panel.png)): Cycle and Single tabs that run **at the same time**, all the
dashboard's settings, live validation, preview of the next orders, status, journal, log, chart lines, Pick-on-chart,
Start / Apply changes / Discard / Stop after cycle / Stop now / Buy-Sell now / Close trade / TP-SL Set / Resume /
Close all (+ Ctrl+Shift+K for both), `?` help. State is saved to `MQL5\Files\GoldCycle\`; after a restart it asks
"Resume?" (a timeframe or input change continues by itself). Journal CSV in the same folder. Magic 8800501 (Single
8800502), so it never touches the Python bot's trades (7700501…).

| Part | File |
|---|---|
| State machine (port of `cycle_engine.py`) | `mql5/Include/GoldCycle/Engine.mqh` |
| Rules / validation / preview | `Logic.mqh`, types in `Types.mqh` |
| MetaTrader broker / simulated broker | `Broker.mqh` / `SimBroker.mqh` |
| Panel and chart lines | `Panel.mqh` |
| Events, save/resume, alerts | `mql5/Experts/GoldCycle/GoldCycle.mq5` |

Differences from the Python bot: no Reports page (MetaTrader History + journal CSV); the daily loss limit counts the
**broker's day** (server midnight, UTC on Exness), trading hours use PC time; TP/SL dragging is MetaTrader's own and
the bot follows it; needs a hedging account; one chart per account.

## Tested (2026-11-25, home laptop, isolated MT5 copy, demo 474902598 @ Exness-MT5Trial15)

**Engine tests inside MetaTrader, simulated broker: 146 passed, 0 failed** (client's cycle tables BUY/SELL/gap, order 2
immediate on jumps / wide spread / closed hours / rejects, stop price both sides, max cycles, stop after cycle, spread,
slippage, price past trigger, manual close, daily loss, kill switch, duplicate guard, attach, live edits, TP/SL drag
and boxes, Single variants, restart/resume, disconnect, late history).

**Live, real 0.01 demo orders through the EA's own buttons: 40 checks passed, 0 failed.**

| What | Result |
|---|---|
| Single Buy now → TP/SL Set → TP changed by MetaTrader → Close trade | position and history correct, +0.52 |
| Cycle: order 1 TP not reached → Close all | closed, STOPPED, -2.17 |
| Cycle SELL: order 1 TP +0.87 → **order 2 opened 64 ms later**, SL = order 1's entry, no TP | passed |
| MetaTrader closed with order 2 open | broker's server-side SL closed it (-1.12); on restart "Resume?" → read from history → STOPPED MAX_CYCLES |
| MetaTrader restarted with a Single trade open | asks Resume, reattaches the same trade, no duplicate, Close all (-0.51) |

Balance 495.81 → 493.40 = exactly the sum of those five trades. No position left open.

## NOT tested yet: do this next

1. **Install on the office laptop** (`build.ps1`), attach to `XAUUSDm`, Algo Trading on, and click through by hand
   (checklist below). The live test pressed most buttons through a test hook, not with a mouse.
2. Never exercised live: **Apply changes**, **Stop after cycle**, **Stop now**, **Start at trigger price** (Single),
   **Pick** on chart, Ctrl+Shift+K, confirm pop-ups, `?`, collapse, timeframe switch (should keep running), daily loss
   limit, disconnect. (The engine side of these is covered by the 146 tests, except the panel/UI parts.)
3. Other screen sizes / Windows scaling (125–150 %): the panel needs about 700 px of chart height.
4. The client's VPS; a real (non-demo) account has never been used. Do a full demo session first.
5. Ask the client for the two files of his old ChatGPT bot if he wants the same field names.

### Manual checklist (demo, 0.01 lot)

| # | Do | Expect |
|---|---|---|
| 1 | Attach EA, Algo Trading on | panel, DEMO badge, no red warning line |
| 2 | Type `abc` in TP | red error, Start refused |
| 3 | Single: **BUY now** | trade in Toolbox > Trade, comment `GC\|c=1.1\|s=…`, no TP/SL |
| 4 | Drag the trade's TP/SL line, then type TP/SL + **Set** | panel and trade agree |
| 5 | **Close trade** | closed, journal row, History tab |
| 6 | Single: trigger slightly away, **Start at trigger price**, then **Cancel** | armed then stopped, no trade |
| 7 | Cycle: trigger near price, TP 1, Max cycles 1, stop price a few points away, **Start cycle** | C1.1 with TP, no SL; at TP, C1.2 at once with SL at the entry |
| 8 | While running change TP, **Apply changes** | order 1's TP moves |
| 9 | Switch M1 → M5 | bot keeps running |
| 10 | Close MetaTrader with a trade open, reopen | **Resume** button; nothing happens until pressed |
| 11 | Red **Close all and stop** | confirm box, everything closed |

## Running the automated tests again

- **Engine tests (no orders):** after `build.ps1`, drag script `GoldCycle > GoldCycleTests` onto any chart. Experts tab:
  `RESULT: 146 passed, 0 failed` (also in `MQL5\Files\GoldCycle\test_results.txt`).
- **Live test (demo only, real 0.01 orders, refuses real accounts):** attach the EA with input
  `InpTestHooks = true`, then run script `GoldCycleLiveTest` on the **same chart**. Results and screenshots in
  `MQL5\Files\GoldCycle\`. Restart check: create `restart_open.txt` there, run; restart MetaTrader; replace it with
  `restart_resume.txt`, run. Set `InpTestHooks` back to false afterwards.
- Unattended (what was used): start `terminal64.exe /config:run.ini` with `[Experts] Enabled=1, AllowLiveTrading=1` and
  `[StartUp] Expert=GoldCycle\GoldCycle`, `ExpertParameters=<preset in MQL5\Presets>`, `Script=GoldCycle\...`,
  `Symbol=XAUUSDm`, `Period=M1`; a file `autoclose.txt` in `Files\GoldCycle` makes the test scripts close MetaTrader.
  Use a separate (portable) copy of MetaTrader, and delete any ini that contains a password.

## Known issues / limits

- Chart line captions ("trigger", "TP", "stop price") sit under the panel on the left (the lines themselves are visible).
- Panel log wraps long messages mid-word; full text is in the Experts tab.
- Small TPs are eaten by spread + slippage (seen again live: order 1 filled 0.06 below its TP). The panel warns.
- Order 1 has no SL by the client's rule: always set a stop price and/or a daily loss limit.
- "Buy now" in the first seconds after the 23:00 UTC reopen can get "session closed" and then wait for the price to
  return (same rule as the Python bot). Open question for the client.
- No Strategy Tester run was done.

## Python bot (previous direction): where it stands

Working: one-command install (`GoldCycle-Setup.bat`), Manager menu (start / stop / restart / add account / fix login /
update), hidden self-restarting bot. Verified on a client laptop up to "READY and connected" (2026-11-24). 188 pytest
pass. Open: VPS update, full demo session, Defender detections on one laptop (see HANDOFF Session 7). On the home
laptop two leftover logon tasks (`GoldCycle-473027979`, `GoldCycle-474902598`, folder already deleted) remain.

## Working with this user and client

- The client is **not technical**: one file, few questions, choices as numbers, plain words, no developer steps.
- Test on **demo** only; real accounts only when the user says so. **No passwords in the repo** (it is **public**);
  ask the user for the demo password when a login is needed.
- Windows PowerShell 5.1 gotchas hit more than once: variable names ignore case (`$t` overwrites `$T`); `-ceq` vs
  `-eq`; `.bat` files must stay CRLF in git (`.gitattributes`).

## Open questions for the client

| # | Question | Current behaviour |
|---|---|---|
| 1 | Is the panel layout fine, or does he want the field names of his old ChatGPT bot? | panel as in the screenshot |
| 2 | Should "Buy/Sell now" ignore max slippage? | no |
| 3 | After a restart, continue without asking? | asks (`InpResumeOnRestart=false`) |
| 4 | (Q5) Single TP/SL as points or exact prices? | both (toggle) |
