# CURRENT STATE: read this first (new session / new machine)

**Last updated:** 2026-11-27 (Session 10: panel changes, below; Session 9 notes follow). Then read [../HANDOFF.md](../HANDOFF.md) (history) and
[../CLAUDE.md](../CLAUDE.md) (trading rules, source of truth).

## Session 10 (2026-11-27): panel changes

- Panel: draggable by its title (position saved), one column, **journal / preview / log removed**, **Pick, Bid, Trigger-on and
  Levels-from buttons and the lot-step hint removed**, **Enter applies** a typed value to a running cycle or the open trade (no Apply / Discard /
  Set buttons), **Float / Dock** pops the chart out of MetaTrader. Dragging moves the objects instead of redrawing
  (one step 4.1 ms -> 0.1 ms in a test script). Engine unchanged.
- Open trade TP / SL can be typed as a **Price or as Points** from the entry. **BUY / SELL now uses the form's TP / SL**
  (before, it always opened with none).
- **Final test of this version: engine + panel tests 290 passed, 0 failed; live demo 474902598: 54 passed, 0 failed**
  (full 32, buttons 14, restart/resume 8), and the M1 -> M5 switch kept the trade IN POSITION. The test copy used magic
  8800601 / 8800602 (changed only in that copy) so the user's own bot could not see its trades; none left open.
- Client package: `mql5/release/GoldCycle.ex5` + `HOW-TO-INSTALL.txt` (zipped to the Desktop as `GoldCycle-Bot.zip`).
- Still only testable by hand: mouse dragging, Float + dragging the window out, the real Enter key (the live script
  types through the test hook): MANUAL_TEST B1, B3, B10-B12.
- Sections below that mention Pick / Set / Apply / preview / log describe the older panel.

## Right now (2026-11-26, about 03:00 local): where the manual test stood

**The user is part-way through the manual test** ([MANUAL_TEST.md](MANUAL_TEST.md)). Session 9 is committed and pushed.

| Item | State |
|---|---|
| MetaTrader 5 on the home laptop | installed bot is the latest build; demo 474902598 @ Exness-MT5Trial15, balance 495.88 after the last trade; a "MetaTrader 5 EXNESS" Desktop icon was added |
| Done by hand so far | attach, Allow Algo Trading, **Buy now**, MT5 restart -> "Resume", trade closed through the bot (+3.37) |
| Still to test by hand | typing in the boxes (part B), TP/SL on an open trade (new layout), the whole Cycle part D, limits part E |
| Package for the user's friend | Desktop `GoldCycle-for-friend.zip` = `mql5/release/GoldCycle.ex5` + `mql5/release/HOW-TO-INSTALL.txt` |
| **Decide** | remove the `InpTestHooks` input from the client build? (it was found switched on once on the user's chart; with it on, Close all does not ask for confirmation). Recommended, not yet approved |
| Waiting on the client | confirm: a daily loss hit by one bot also closes the other bot's open trade |
| Demo password | not stored in the repo; ask the user if a separate test copy of MT5 needs it |

How to help: one part of the checklist at a time, short steps with the expected result; read their screenshots. For
a failure ask for the step number, the panel and the **Experts** tab (or read the terminal's `MQL5\Logs` folder; the
log is written with a delay). After a code fix: engine tests in a separate portable MT5 copy, then `mql5uild.ps1`.
The running chart keeps the OLD build until MetaTrader is restarted (then "Resume"). Do not run the automated live test
on the same account while the user is testing by hand (same magic numbers). Gold pauses 03:00-04:00 local.

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

## Edge testing round (2026-11-26)

**Engine + panel tests inside MetaTrader: 242 passed, 0 failed** (Python: 193). The new tests found 7 real bugs, all
fixed (the first two also in the Python bot):

1. Restart / timeframe switch while order 2 was still being opened made it wait for a touch.
2. A daily loss limit hit by one bot did not stop the other; order 2 could still open.
3. `0` in stop price / daily loss / max spread silently meant "no limit".
4. A rejected order popped up an alert every 5 s.
5. Trading hours `09:00-09:00` accepted (never trades).
6. "Buy now" refused because of a typo in the unused trigger box.
7. Start right after a left-open trade closed lost its journal-file line.

**Live demo, buttons not pressed before: 14 passed** (Start at trigger, Cancel, typo refused, Apply changes, Stop
after cycle, Stop now, Set on a left-open trade, Close all), the M1→M5 switch reattached the open trade by itself,
and **restart/resume 8 passed**. Balance 493.40 → 492.51 = the two test trades. No position left open.

Later the same night (user's manual test): a section **"Change THIS open trade"** (TP/SL price boxes, Pick, Set) for
Cycle and Single; a Single trade open hides the next-trade form; typed-but-unsent TP/SL no longer reappear on the next
trade; red warning messages shortened to fit one line.

**Manual test (by a person, mouse and keyboard): [MANUAL_TEST.md](MANUAL_TEST.md)**: real typing, Pick, Ctrl+Shift+K,
confirm boxes, help, collapse, second-chart guard, disconnect and screen scaling are still only testable by hand.

## NOT tested yet: do this next

1. The manual test [MANUAL_TEST.md](MANUAL_TEST.md) (the fixed EA is installed in the home laptop's MetaTrader).
2. Daily loss limit and disconnect live; other screen scaling (125–150 %).
3. The client's VPS; a real (non-demo) account has never been used. Do a full demo session first.
4. Ask the client for the two files of his old ChatGPT bot if he wants the same field names.

## Running the automated tests again

- **Engine tests (no orders):** after `build.ps1`, drag script `GoldCycle > GoldCycleTests` onto any chart. Experts tab:
  `RESULT: 290 passed, 0 failed` (also in `MQL5\Files\GoldCycle\test_results.txt`).
- **Live test (demo only, real 0.01 orders, refuses real accounts):** attach the EA with input
  `InpTestHooks = true`, then run script `GoldCycleLiveTest` on the **same chart**. Results and screenshots in
  `MQL5\Files\GoldCycle\`. Restart check: create `restart_open.txt` there, run; restart MetaTrader; replace it with
  `restart_resume.txt`, run. `buttons.txt` runs the other buttons and ends with a timeframe switch (follow it with the
  restart check part 2). Set `InpTestHooks` back to false afterwards.
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
