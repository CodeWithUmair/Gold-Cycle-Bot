# Manual test: GoldCycle Expert Advisor (demo only)

About 45 minutes. Always **lot 0.01** on the **demo** account. "Price + 2" means 2.00 above the current Bid.
Gold is closed daily 22:00–23:00 UTC (**03:00–04:00 Pakistan time**) and at weekends: don't test then.

If a step fails: screenshot the panel **and** the Toolbox **Experts** tab, and note the step number.

## A. Setup

| # | Do | Expect | OK |
|---|---|---|---|
| A1 | Open MetaTrader 5 (Exness), logged in to the demo account | title shows the account, `Trial` server | ☐ |
| A2 | Market Watch → right-click **XAUUSDm** → Chart Window; timeframe M1; make the window tall | gold chart | ☐ |
| A3 | Navigator (Ctrl+N) → Expert Advisors → **GoldCycle** (right-click → Refresh if missing) → drag onto the chart | settings window | ☐ |
| A4 | Tab **Common**: tick **Allow Algo Trading** → OK. Toolbar **Algo Trading** = green | panel appears, **DEMO**, no red line | ☐ |

## B. Panel and typing (no trades). Most important: real typing was never tested

| # | Do | Expect | OK |
|---|---|---|---|
| B1 | Click the TP box, type slowly, wait 3 seconds, finish, press Enter | text is never wiped or jumps while typing | ☐ |
| B2 | Type `abc` in TP → Start cycle | red `TP: 'abc' is not a number`; nothing starts | ☐ |
| B3 | Type a new TP and click straight on another button **without** Enter | the new value is used (see the dotted TP line) | ☐ |
| B4 | Safety and advanced: Stop price `0`, then Max spread `0`, then hours `09:00-09:00` | each refused with a clear red message | ☐ |
| B6 | BUY, trigger 4000-style round price, TP 3 | dotted chart lines: trigger, TP = trigger+3 | ☐ |
| B7 | **?**, scroll, **Back to the bot**; then **-** and **+** | help page in the panel; panel folds and returns; nothing lost | ☐ |
| B8 | Switch toolbar Algo Trading **off** → Start cycle; switch it on again | red warning line; start refused with the reason | ☐ |
| B9 | Drag GoldCycle onto a **second** XAUUSDm chart | pop-up "already runs on another chart"; not added | ☐ |
| B10 | Drag the panel by its title; try to push it off the chart; switch M1 → M5 | panel follows the mouse, chart does not scroll, title stays visible, position kept | ☐ |
| B11 | Drag the chart itself, away from the panel | chart scrolls as usual | ☐ |
| B13 | Cycle tab with **Safety and advanced** open: roll the mouse wheel over the panel; drag the bar on its right | the form scrolls, the chart does not move, title, tabs and messages stay | ☐ |
| B12 | Press **Float**; drag that window outside MetaTrader; press **Dock** | chart + panel float as one window, then return | ☐ |

## C. Single tab (demo trades)

| # | Do | Expect | OK |
|---|---|---|---|
| C1 | TP and SL boxes empty → **BUY now** | one trade in Toolbox → Trade, comment `GC\|c=1.1\|s=…`, no TP/SL; also in the Exness app | ☐ |
| C1b | Close it; TP points `6`, SL points `3` → **BUY now** | trade opens with TP 6.00 above and SL 3.00 below its price; open-trade boxes are filled | ☐ |
| C2 | In MetaTrader drag a TP and an SL onto that trade | panel shows the same TP/SL within a second | ☐ |
| C3 | Under "Change THIS open trade" type a TP below the price (wrong side) → Enter | refused with a message; box and trade unchanged | ☐ |
| C4 | Valid TP, Enter; valid SL, Enter; then empty SL, Enter | each applied at once ("Applied"); SL removed | ☐ |
| C4b | Choose **Points**; TP `5`, Enter; SL `3`, Enter; then choose **Price** | TP is 5.00 and SL 3.00 from the entry; boxes switch to prices | ☐ |
| C5 | **Close trade** | closed; History tab shows the trade, panel "Session" shows the same P/L | ☐ |
| C6 | Trigger = price + 2, TP 3, SL 3 → **Start at trigger price** → **Cancel** | ARMED, then STOPPED, no trade | ☐ |
| C7 | **SELL now**, then close it by hand in MetaTrader (X on the trade) | pop-up; STOPPED `MANUAL_CLOSE`; bot opens nothing | ☐ |
| C8 | Trigger = price + 0.5, TP 1, SL 1 → Start, wait | opens on touch, closes on TP or SL, state IDLE | ☐ |

## D. Cycle tab (the main product)

Settings: BUY (or SELL if price is falling), lot 0.01, TP 1, Max cycles 2, Max spread 1, Max slip 1,
stop price 8 below the trigger (above it for SELL).

| # | Do | Expect | OK |
|---|---|---|---|
| D1 | Trigger = price + 0.3 → **Start cycle** | ARMED "waiting"; on touch C1.1 opens with TP, **no SL** | ☐ |
| D2 | While order 1 is open change TP points to 20 → Enter | TP line on the trade moves at once | ☐ |
| D3 | Change TP back to price near the market, Enter; wait for the TP | **order 2 opens immediately**, SL = order 1's entry, no TP; History: same second | ☐ |
| D4 | Wait for order 2's SL (or move its SL close to the price) | next cycle ARMED at the entry (+ gap) | ☐ |
| D5 | **Stop after cycle** in the next cycle | order 2 still opens; bot stops after it closes | ☐ |
| D6 | Start again; with a trade open switch M1 → M5 | stays IN POSITION, no new trade | ☐ |
| D7 | With a trade open close MetaTrader, reopen it | **Resume** button; nothing happens until pressed; then same trade number | ☐ |
| D8 | **Stop now** | bot STOPPED, trade stays with its TP/SL; typing TP/SL + Enter still works; **Close all** closes it | ☐ |
| D9 | Open a Single trade (BUY now) while a Cycle trade is open | two trades, each tab shows its own | ☐ |
| D10 | **Ctrl+Shift+K**: first answer No, press again, answer Yes | No keeps all; Yes closes both and stops both | ☐ |

## E. Limits and failures (do last)

| # | Do | Expect | OK |
|---|---|---|---|
| E1 | Cycle trade open: Stop price 0.5 from the price → Enter, wait | trade closed at once when reached; STOPPED `STOP_PRICE` | ☐ |
| E2 | Trading hours that exclude the current PC time → Start, let price touch | "outside trading hours, waiting"; no trade | ☐ |
| E3 | With a trade open, disconnect the internet 30 s, reconnect | red NOT CONNECTED, then continues; no duplicate trade | ☐ |
| E4 | Start the Cycle waiting at a far trigger. Single: Daily loss `0.10` → **BUY now** | Single closes, Cycle stops too, no new trades today. Today's earlier result counts, so it may trigger at once | ☐ |
| E5 | Undo the daily block: **F3** (Global Variables) → delete `GC_block_<account>_8800501` | bots can start again | ☐ |

When finished: check Toolbox → Trade is empty. The journal file is in File → Open Data Folder →
`MQL5\Files\GoldCycle\journal_….csv`.
