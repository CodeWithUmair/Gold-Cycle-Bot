# GoldCycle Glossary (for developers, no trading background needed)

Every term used in this project, in plain language. Numbers are from the Exness demo account used in
Session 1 (symbol `XAUUSDm`, gold around $4,040). Rules live in [CLAUDE.md](CLAUDE.md); code in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## 1. Prices

**XAUUSD** — gold priced in US dollars, per ounce. Our broker names it differently per account type (see §6).

**Bid / Ask** — two prices at any moment. You **sell at the bid** and **buy at the ask**. The ask is always a bit higher.
The MT5 chart draws the **bid**, which is why the bot watches the bid for triggers by default (`trigger_price_side`).

**Spread** — `ask − bid`, the broker's built-in fee. On `XAUUSDm` it is about **0.24**. The bot refuses to open a trade while
the spread is wider than `max_spread_points` (default 0.6) and waits instead.

**Point (the client's)** — **1.00 of price.** 4000 → 4003 is **3 points**. TP, SL, gap, slippage and spread all use this
unit in the UI and the code ([levels.py](backend/app/engine/levels.py) `POINT_SIZE = 1.0`).

**Point (MT5's)** — the smallest price step, `symbol.point`. It is **0.001** on `XAUUSDm` (3 digits) and 0.01 on 2-digit
gold symbols. It only appears where MT5 demands it: `deviation` and stops/freeze levels. Never mix the two.

---

## 2. One trade

**Lot / volume** — trade size. Gold `contract_size` = 100 oz, so **0.01 lot = 1 oz → a 1.00 price move ≈ $1**.
The broker sets `volume_min` (0.01), `volume_step` (0.01) and `volume_max` (200). Lots that aren't a multiple of the step are rejected in the form.

**TP (Take Profit)** — the "I was right" exit price. **SL (Stop Loss)** — the "I was wrong" exit price.
Both are attached **to the position on the broker's server** in the same order request, so they still trigger if the bot or the VPS dies.

**BUY / SELL** — BUY profits when price goes up (TP above entry, SL below). SELL profits when price goes down (TP below, SL above).

**Planned entry vs fill** — *planned* is the level the trader asked for (e.g. 4000). *Fill* is the price the broker actually gave (e.g. 4000.24, because a BUY fills at the ask).
By default, all TP/SL/next-entry levels are computed from the **planned** price to keep the ladder clean (`level_anchor=planned`).

**Slippage** — fill minus planned, in points (positive = worse for you). Shown in the journal.
`max_slippage_points` (0.5) is the tolerance: if price has run further than that from the planned entry, the bot doesn't chase it and waits for another touch.

**Deviation** — the same tolerance in MT5's own units, sent with the order. It is `max_slippage_points ÷ symbol.point`, e.g. 0.5 / 0.001 = 500.

---

## 3. The bot's own words

**Trigger / "Market Position"** — the price where cycle 1 opens. The client's sheet calls it *Market Position*.

**Touch** — the bot records which side of the trigger the price is on when you arm, then fires when price **reaches** the level from that side.
If the price is exactly on the trigger at arm time it does **not** fire. It waits for price to move off and come back (a confirmed client rule).

**Cycle** — one trade from open to close. C1, C2, C3… Only **one trade is open at a time**.

**Cycle gap ("Cycle Gape" in the client's sheet)** — how far the next cycle's entry moves, in points.
- **Blank** → the next entry equals the previous TP. Price is already there, so the bot opens immediately.
- **Set** (e.g. 2) → next entry = previous entry ± 2. The bot waits for price to touch it (open question Q1).

**Stop price ("Stop bot cycle at position")** — a hard ceiling (BUY) or floor (SELL). When reached, the bot **closes the open trade at market** and stops.
It also stops if the *next* entry would be at or beyond the stop price.

**Client's worked BUY example** (tp 3, sl 3, gap 2):

| Cycle | Entry | TP | Next order | SL |
|---|---|---|---|---|
| C1 | 4000 | 4003 | 4003 | 4000 |
| C2 | 4002 | 4005 | 4005 | 4002 |
| C3 | 4004 | 4007 | 4007 | 4004 |

Read it as: C1 buys at 4000 with TP 4003. When TP hits, cycle 1 is done. The "Next order / SL" columns show that a
trade placed at 4003 would have its SL at 4000 (the previous entry). With gap 2, the next entry is 4002, so C2 waits
for a 1-point pullback.

**Modes** — **CYCLE** ("Part One" in the sheet) repeats trades up the ladder. **SINGLE** ("Part Two") is one trade, then back to IDLE.

**Kill switch / "Close all & stop"** — closes every position with the bot's magic number at market and stops. Hotkey Ctrl+Shift+K.
**Stop now** is different: it stops the bot but **leaves** an open trade running with its server-side TP/SL.

**DRY_RUN** — `.env` flag. Real MT5 prices, but orders are only logged and filled on paper inside `SimBroker`. Nothing reaches the broker.

### Bot states

| State | Meaning |
|---|---|
| `IDLE` | Nothing armed (also where a SINGLE trade ends) |
| `ARMED` | Waiting for price to touch the next entry |
| `OPENING` | Touched. Sending the order, or waiting for spread / trading hours / retry |
| `IN_POSITION` | Trade open with TP/SL on the server (may be "closing…" for stop price / kill switch / daily loss) |
| `RESOLVING` | Trade gone. Reading the close reason from deal history |
| `STOPPED` | Halted. Needs a new Arm, or **Resume** after a restart |

---

## 4. MT5 mechanics

**Magic number** — an ID stamped on every order (`MAGIC`, default 7700501). The bot **only ever touches positions carrying its magic number**,
so the trader's manual trades are safe.

**Order comment** — text on the order, max 31 chars. Ours is `GC|cycle=3|session=ab12cd34`; it lets the bot recognise its own trade after a crash.

**Market execution** — the broker fills at the current price; you can't pick the price. Exness gold works this way (`trade_exemode=2`).

**Filling mode** — what happens if the full size can't be filled at once:
**FOK** (fill-or-kill: all or nothing), **IOC** (immediate-or-cancel: partial OK), **RETURN** (rest stays as an order).
The symbol says which ones it allows. `XAUUSDm` allows FOK + IOC and rejects RETURN (retcode 10030). The gateway picks automatically.
Gotcha: the constant `ORDER_FILLING_FOK` equals **0**, so a log line saying "filling 0" means FOK, not "none".

**Hedging vs netting** — account types. *Hedging* allows several positions per symbol, each with its own ticket (our demo is hedging).
*Netting* merges everything into one position per symbol. The gateway finds the position ticket either way.

**Stops level / freeze level** — the minimum distance (in MT5 points) that TP/SL must keep from the current price, and the distance inside which
you can't modify an order. Both are 0 on `XAUUSDm`. The form rejects TP/SL that are too close.

**Deal reason** — why a deal happened, read from history after a close:
`TP`, `SL`, `CLIENT` (trader clicked close in desktop/mobile/web), `EXPERT` (an EA or API, e.g. us), `SO` (stop-out).
This is how the bot decides "next cycle" (TP) or "stop" (anything else).

**Stop-out** — the broker force-closes positions because margin ran out. The bot treats it as an error stop.

**Retcode** — MT5's result code for an order. `10009` = done. Some codes mean retrying is pointless (no money 10019, Algo Trading off 10027…) and the bot stops.
Others (requote, price changed…) are retried every second while price is still within slippage tolerance.

**Algo Trading button** — the toolbar button in the MT5 terminal. If it is off, every order fails with 10027. The top bar shows "Algo Trading off".

---

## 5. Safety limits

| Setting | Default | Plain meaning |
|---|---|---|
| `max_cycles` | unlimited | Stop after N cycles |
| `daily_loss_limit` | none | If today's realized + floating loss reaches this many dollars, close and refuse new arms until tomorrow |
| `max_spread_points` | 0.6 | Don't open into a wide spread; wait |
| `trading_hours` | none | e.g. `08:00-17:00` (VPS local time; may wrap midnight). Outside it, no new trades open |
| `max_slippage_points` | 0.5 | Don't chase a fill further than this from the planned entry |

---

## 6. Exness specifics

**Symbol suffixes** — gold has a different name per account type. Find it with `symbols_get("*XAU*USD*")`:

| Name | Seen on | Note |
|---|---|---|
| `XAUUSDm` | Standard demo used in Session 1 | 3 digits, spread ≈ 0.24, FOK/IOC |
| `XAUUSD247m` | Same account | **No quotes (bid = ask = 0)**. Don't use it; the gateway treats zero prices as "no price" |
| `XAUUSDc`, `XAUUSDz`, plain `XAUUSD` | Other account types (Cent, Zero, Raw/Pro…) | Auto-detect prefers `XAUUSD`, then `XAUUSDm`, `XAUUSDc`, `XAUUSDz` |

**Demo expiry** — Exness deletes inactive demo accounts. The terminal still *shows* the old account, but every connection fails:
Python gets `initialize failed: Terminal: Authorization failed (-6)` and the terminal log says
`authorization on <server> failed (Invalid account)`. The fix is to open a new demo in the terminal and tick **Save password**.

**Server time** — Exness MT5 server time is UTC, so candle times line up with the bot's own timestamps.
