# GoldCycle — User Guide (dashboard walkthrough)

For the trader using the dashboard. No code needed. Open **http://127.0.0.1:8000** on the VPS
(or on your PC while testing) and sign in.

---

## 1. The one rule to remember

> **One session at a time.** You press **Arm** → a *session* starts → it runs one or many trades
> ("cycles") → it ends. Only after it has ended (badge shows **STOPPED** or **IDLE**) can you
> **Arm** a new one. The form is locked while a session runs.

```
  Edit form ──► ARM ──► ARMED ──► IN POSITION ──► (TP) ──► next cycle ──► … ──► STOPPED / IDLE
     ▲          (waiting for     (trade open,                                       │
     │           your price)      TP/SL on broker)                                  │
     └──────────────────────── change inputs, press ARM again ◄─────────────────────┘
```

---

## 2. Screen tour

| Area | What you see |
|---|---|
| **Top bar** | Logo + mode tag (**DRY RUN** = paper trades on real prices, **DEMO**, **LIVE** in red) · **Trading / Reports** switch · green dots = MT5 connected / dashboard live · Symbol, Bid/Ask, Spread, Balance, Equity · the **state badge** · ⚙ Settings · Log out |
| **Chart (left)** | Live gold candles (M1/M5/M15/H1/H4). Lines: blue dashed = **trigger**, gold = **entry**, green = **TP**, red = **SL**, grey dotted = **next cycle's entry**, amber = **stop price**. Arrows = cycle opened, circles = cycle closed. |
| **Cycle journal (bottom)** | One row per trade of the current session: planned entry, actual fill, slippage, TP, SL, result, P/L, duration. **Event log ›** opens the full text log. |
| **Control panel (right)** | Tabs **Cycle** / **Single**, the input form, the **Preview**, and the buttons. |

### The state badge

| Badge | Meaning |
|---|---|
| IDLE | Nothing running. Ready to Arm. |
| ARMED (pulsing blue) | Waiting for price to touch your trigger. No trade yet. |
| OPENING | Price touched; the bot is sending the order (or waiting for spread / trading hours). |
| IN POSITION (green) | A trade is open with TP and SL set on the broker's server. |
| RESOLVING | The trade just closed; the bot is reading *why* (TP, SL, manual…). |
| STOPPED (red) | The session ended (SL, stop price, you pressed stop…). Ready to Arm a new one. |

---

## 3. Running a **Cycle** session (Part One)

1. Click the **Cycle** tab.
2. Pick **BUY** or **SELL**.
3. **Market position (trigger price)**: the price where cycle 1 should open. **Bid** fills in the
   current price. The bot never enters at the moment you arm. It waits for price to *touch* this level.
4. **Lot**: same lot every cycle.
5. **TP points / SL points**: 1 point = 1.00 of price (4000 → 4003 = 3 points). The grey text
   under each box shows the actual price level.
6. **Cycle gap (pts)**:
   - *blank*: the next cycle starts right where the last TP hit (4000 → TP 4003 → next buy at 4003).
   - *a number, e.g. 2*: the next entry moves by 2 points each cycle (4000 → 4002 → 4004). The bot
     waits for price to touch it.
7. **Stop cycle at price** (optional): when price reaches it, the bot closes the open trade and stops.
8. Look at **Preview**: the next 5 cycles exactly as the bot will place them (if each hits TP).
   Red messages must be fixed; amber ones are just warnings.
9. Press **Arm cycle**.

What happens next, automatically:
- Price touches the trigger → **C1** opens with TP and SL already attached on the broker.
- **TP hit** → C1 complete → **C2** starts (at the TP, or at entry + gap) → C3 … and so on.
- **SL hit** → the session **stops**. No new cycle, no reverse.
- **Stop price reached** → the open trade is closed at market → session **stops**.
- **Max cycles** (Advanced) reached → session **stops**.

### Example (BUY, TP 3, SL 3, gap 2)

| Cycle | Entry | TP | SL |
|---|---|---|---|
| C1 | 4000 | 4003 | 3997 |
| C2 | 4002 | 4005 | 3999 |
| C3 | 4004 | 4007 | 4001 |

---

## 4. Running a **Single** trade (Part Two)

1. **Single** tab → BUY/SELL → trigger price → lot.
2. TP/SL **in points** or switch to **in price** to type the exact TP and SL prices.
3. **Arm single trade**. When TP or SL hits, the badge goes back to **IDLE**. Arm again for the next one.

---

## 5. Starting another session — the part people get stuck on

| Situation | What to do |
|---|---|
| The session ended by itself (SL, stop price, max cycles, single trade done) | The panel shows **"Last session … ended"**. Change the inputs (or keep them) and press **Arm**. |
| A session is running and you want different settings | First end it: **Stop after this cycle** (let the open trade finish), **Stop now** (bot stops, open trade stays with its TP/SL), or **Close all & stop** (closes the trade now). Then edit and **Arm**. |
| "A bot position is still open" when you press Arm | You used **Stop now** and the old trade is still open. Wait for its TP/SL, or press **Close all & stop**. |
| The bot was restarted mid-session | The panel offers **Resume session …**. Press it to continue, or just Arm a new session. |

### The three stop buttons

| Button | Open trade | Bot |
|---|---|---|
| **Stop after this cycle** | finishes normally at TP/SL | stops instead of starting the next cycle |
| **Stop now** | stays open, protected by its TP/SL on the broker | stops immediately |
| **Close all & stop** (red, asks to confirm, **Ctrl+Shift+K**) | closed at market right now | stops immediately |

---

## 6. Advanced & safety (click "Advanced & safety" in the form)

| Setting | Default | What it does |
|---|---|---|
| Gap entry | Wait for touch | With a gap: wait for price to reach the next entry, or open immediately |
| Next SL | Entry − SL pts | Or put the next trade's SL at the previous entry |
| Levels from | Planned entry | TP/SL measured from your planned price (or from the actual fill) |
| Trigger on | Bid | Which price must touch the trigger (bid = what the MT5 chart shows) |
| Max slippage | 0.5 pts | If price ran further than this from the planned entry, don't chase; wait for another touch |
| Max spread | 0.6 pts | Don't open while the spread is wider; wait |
| Max cycles | unlimited | End the session after N cycles |
| Daily loss limit | none | Close everything and block new sessions for the rest of the day |
| Trading hours | none | e.g. `08:00-17:00`: only open new cycles inside this window |

---

## 7. Reports (top bar → **Reports**)

| Section | Shows |
|---|---|
| Range buttons | Today · 7 days · 30 days · All time · **Export cycles (CSV)** for Excel |
| KPI tiles | Net P/L, win rate, profit factor, cycle count (TP/SL), average win/loss, max drawdown, best/worst cycle, win/loss streaks |
| Cumulative P/L | Running total after each closed cycle. Hover for details. |
| Daily P/L | One bar per day, green above zero / red below. Hover for the day's cycles. |
| Why cycles closed | TP vs SL vs stop price vs manual vs kill switch, with count and P/L |
| Execution quality | Average/max slippage, average cycle time |
| Sessions | Every Arm = one row: settings used, cycles, TP/SL count, P/L, how it ended. **Click a row** to see each cycle. |

---

## 8. Suggested script for a demo video (≈ 5 min)

1. **Login** and point at the top bar: DRY RUN tag, green MT5 dot, live bid/ask.
2. **Chart**: switch M1 → M5 and back.
3. **Cycle tab**: BUY, click **Bid**, then add +0.5 to the trigger so it is just above the price.
   Lot 0.01, TP 1, SL 2, gap blank, stop price trigger + 4. Show the **Preview** updating as you type.
4. **Arm**. Show the badge turn **ARMED** and the blue dashed trigger line, plus "Waiting for price…".
5. Wait for the touch: badge **IN POSITION**, gold/green/red lines, toast, journal row.
6. After a TP: show the **next cycle** starting automatically (C2 row, new lines).
7. Press **Stop after this cycle** (or **Close all & stop** with its confirm box).
8. Show the **"Last session ended"** card, change one input, and **Arm** again. This is the
   "how to start another cycle" moment.
9. Open **Event log ›**, then **Reports**: KPI tiles, charts, click a session row, Export CSV.
10. Finish with ⚙ **Settings → Test connection**.

In **DRY RUN** nothing is sent to the broker, so it is safe to record on a live account.
