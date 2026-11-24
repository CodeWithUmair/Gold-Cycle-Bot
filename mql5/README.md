# GoldCycle Expert Advisor (the bot inside MetaTrader 5)

One file, `release/GoldCycle.ex5`. No Python, no web page, no installer. It runs inside MetaTrader 5 with a panel on
the gold chart, with the same trading rules as the dashboard bot.

## Install (once per MetaTrader)

1. In MetaTrader 5: **File > Open Data Folder**, then open `MQL5` > `Experts`.
2. Copy **GoldCycle.ex5** into that folder.
3. Back in MetaTrader: in the **Navigator** window, right-click **Expert Advisors > Refresh**. "GoldCycle" appears.
4. Open a **XAUUSD** chart (`XAUUSDm` on Exness Standard) and **drag GoldCycle onto it**.
5. In the window that opens, tab **Common**: tick **Allow Algo Trading**. Press **OK**.
6. Click the **Algo Trading** button at the top of MetaTrader so it turns **green**.

The panel appears at the top left of the chart. The chart needs to be about 700 pixels tall; the **-** button hides
the panel.

## Use

**Cycle tab** (two-order cycle): BUY or SELL, trigger price, lot, TP points (1 point = 1.00 of price), optional cycle gap
and stop price, then **Start cycle**.

1. Price touches the trigger: order 1 opens with a TP and **no SL**.
2. Order 1 hits TP: order 2 opens at once, **SL at order 1's entry**, no TP.
3. Order 2 hits SL: the next cycle waits at the entry (plus the gap, if set).

While it runs you can change fields and press **Apply changes** (the direction is fixed), **Stop after cycle**, **Stop now**
(an open trade stays open with its TP/SL) or **Close all and stop**.

**Single tab**: one trade. **BUY now / SELL now** (opens with no TP/SL), or **Start at trigger price** with optional TP
and SL, in points or exact prices. **Close trade** closes it.

**Open trade**: type TP / SL and press **Set**, or drag the TP/SL lines on the chart as usual in MetaTrader. The bot
follows your change. In a cycle, order 2 opens where order 1's TP actually is.

**Safety and advanced**: max cycles, daily loss limit, max spread, max slippage, trading hours (PC time), trigger on
Bid/Ask/Mid, levels from the planned price or the fill.

**Pick** puts the price you click on the chart into a field. **?** explains the rules. **Ctrl+Shift+K** closes
everything for both bots.

Cycle and Single run at the same time. Order 1 has no SL, so set a **stop price** and/or a **daily loss limit**.

## Good to know

- **MetaTrader must stay open** (on a PC or VPS that stays on) for the bot to work. TP and SL are on the broker's server,
  so an open trade stays protected even if MetaTrader closes.
- **After a restart** of MetaTrader the panel shows **Resume**: the bot does nothing until you press it. Changing the chart
  timeframe or the bot's settings does not stop it.
- Closing a bot trade **by hand** in MetaTrader stops that bot (it never fights you).
- **History**: MetaTrader's History tab, plus a spreadsheet file `MQL5\Files\GoldCycle\journal_<account>_<symbol>_<magic>.csv`.
- **Messages**: the panel's log and MetaTrader's **Experts** tab. Phone alerts: set `InpPushToPhone = true` in the bot's
  settings and enter your MetaQuotes ID in Tools > Options > Notifications.
- **Several accounts**: install MetaTrader once per account (separate folders), log each one in, and put the bot on
  each one's gold chart.
- Use **one chart per account** for this bot. It needs a **hedging** account (the usual Exness MT5 account).
- Do **not** run this and the old dashboard bot on the same account at the same time: both would trade.

## For developers

| Path | What |
|---|---|
| `Experts/GoldCycle/GoldCycle.mq5` | inputs, events, save / resume, alerts |
| `Include/GoldCycle/Engine.mqh` | state machine (port of `backend/app/engine/cycle_engine.py`) |
| `Include/GoldCycle/Logic.mqh` | levels, trigger, limits, validation |
| `Include/GoldCycle/Broker.mqh` | broker interface + MetaTrader implementation |
| `Include/GoldCycle/SimBroker.mqh` | simulated broker for tests |
| `Include/GoldCycle/Panel.mqh` | chart panel and price lines |
| `Scripts/GoldCycle/GoldCycleTests.mq5` | engine tests, no orders (results in `MQL5\Files\GoldCycle\test_results.txt`) |
| `Scripts/GoldCycle/GoldCycleLiveTest.mq5` | **demo only**: real 0.01 orders through the EA's buttons (EA with `InpTestHooks=true`) |

Compile: copy `Experts`, `Include`, `Scripts` into the terminal's `MQL5` folder and press F7 in MetaEditor.
