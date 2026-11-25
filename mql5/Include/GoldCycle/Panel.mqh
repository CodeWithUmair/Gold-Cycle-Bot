//+------------------------------------------------------------------+
//| GoldCycle - the on-chart panel (replaces the web dashboard) and  |
//| the price lines. Draws and reads the form; the EA runs actions.  |
//+------------------------------------------------------------------+
#ifndef GC_PANEL_MQH
#define GC_PANEL_MQH

#include "Engine.mqh"

#define GC_UI   "GCP_"
#define GC_LINE "GCL_"
#define GC_LOG_MAX 40

#define C_BG     C'15,19,26'
#define C_PANEL  C'27,34,46'
#define C_BORDER C'48,58,74'
#define C_TEXT   C'222,228,237'
#define C_MUTED  C'135,147,166'
#define C_GOLD   C'227,179,65'
#define C_UP     C'30,166,114'
#define C_DOWN   C'229,83,75'
#define C_INFO   C'96,156,235'
#define C_WARN   C'235,165,60'

//--- what the trader typed (text, so a typo can be reported instead of silently becoming "none")
struct SDraft
  {
   int               dir;
   string            trigger, lot, tp, sl, gap, stop, maxc, dloss, mspread, mslip, hours;
   int               anchor;
   int               tside;
   bool              price_input;
   string            otp, osl;          // TP / SL boxes of the open trade
   double            seen_tp, seen_sl;  // engine values the boxes were last filled from
   ulong             seen_ticket;       // the trade those boxes belong to
  };

class CGcPanel
  {
private:
   string            m_used[];
   int               m_usedN;
   double            m_k;               // screen scale (DPI / 96)
   int               m_x, m_y;

   int               S(const int v) const { return (int)MathRound(v * m_k); }

   void              Use(const string name)
     {
      if(m_usedN >= ArraySize(m_used))
         ArrayResize(m_used, m_usedN + 64, 256);
      m_used[m_usedN++] = name;
     }
   bool              Make(const string name, const ENUM_OBJECT type)
     {
      Use(name);
      if(ObjectFind(0, name) >= 0)
         return false;
      ObjectCreate(0, name, type, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      return true;
     }
   void              Place(const string name, const int x, const int y, const int w = -1, const int h = -1)
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, m_x + S(x));
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, m_y + S(y));
      if(w >= 0)
        {
         ObjectSetInteger(0, name, OBJPROP_XSIZE, S(w));
         ObjectSetInteger(0, name, OBJPROP_YSIZE, S(h));
        }
     }
   void              Rect(const string id, const int x, const int y, const int w, const int h, const color bg, const color border)
     {
      string n = GC_UI + "r_" + id;
      Make(n, OBJ_RECTANGLE_LABEL);
      Place(n, x, y, w, h);
      ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_COLOR, border);
     }
   void              Text(const string id, const int x, const int y, const string text, const color c = C_TEXT, const int size = 9, const string font = "Segoe UI")
     {
      string n = GC_UI + "t_" + id;
      Make(n, OBJ_LABEL);
      Place(n, x, y);
      ObjectSetString(0, n, OBJPROP_TEXT, text == "" ? " " : StringSubstr(text, 0, 63));   // MT5 shows "Label" for ""
      ObjectSetString(0, n, OBJPROP_FONT, font);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
      ObjectSetInteger(0, n, OBJPROP_COLOR, c);
     }
   void              Button(const string id, const int x, const int y, const int w, const int h, const string text,
                            const color bg = C_PANEL, const color fg = C_TEXT, const color border = C_BORDER)
     {
      string n = GC_UI + "b_" + id;
      Make(n, OBJ_BUTTON);
      Place(n, x, y, w, h);
      ObjectSetString(0, n, OBJPROP_TEXT, text);
      ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI Semibold");
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, n, OBJPROP_COLOR, fg);
      ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, border);
      ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);   // the pressed state is reset by the click handler
     }
   // the text of an existing box is only overwritten when `force` (so typing is never lost to a refresh)
   void              Edit(const string id, const int x, const int y, const int w, const string value, const bool locked = false)
     {
      string n = GC_UI + "e_" + id;
      bool created = Make(n, OBJ_EDIT);
      // an existing box is left completely alone unless it moved or was locked / unlocked: re-setting its
      // properties on every refresh could interrupt typing
      bool changed = created || ObjectGetInteger(0, n, OBJPROP_YDISTANCE) != m_y + S(y)
                     || ObjectGetInteger(0, n, OBJPROP_XDISTANCE) != m_x + S(x)
                     || (ObjectGetInteger(0, n, OBJPROP_READONLY) != 0) != locked;
      if(changed)
        {
         Place(n, x, y, w, 20);
         ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, n, OBJPROP_COLOR, locked ? C_MUTED : C_TEXT);
         ObjectSetInteger(0, n, OBJPROP_BGCOLOR, locked ? C_BG : C_PANEL);
         ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, C_BORDER);
         ObjectSetInteger(0, n, OBJPROP_READONLY, locked);
         ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);
        }
      if(created || forceText || (locked && ObjectGetString(0, n, OBJPROP_TEXT) != value))
         ObjectSetString(0, n, OBJPROP_TEXT, value);
     }
   void              Sweep()   // remove widgets that were not drawn this time
     {
      for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
        {
         string n = ObjectName(0, i, 0, -1);
         if(StringFind(n, GC_UI) != 0)
            continue;
         bool used = false;
         for(int k = 0; k < m_usedN; k++)
            if(m_used[k] == n)
              {
               used = true;
               break;
              }
         if(!used)
            ObjectDelete(0, n);
        }
     }

public:
   int               tab;               // 0 = Cycle, 1 = Single
   bool              collapsed;
   bool              advanced;
   bool              forceText;
   string            picking;           // field waiting for a click on the chart
   string            message;           // result of the last button
   color             messageColor;
   string            logText[];
   int               logColor[];
   SDraft            draft[2];
   long              magic;
   int               width, height;

                     CGcPanel()
     {
      tab = 0; collapsed = false; advanced = false; forceText = false; picking = ""; message = ""; messageColor = C_MUTED;
      m_k = 1; m_x = 10; m_y = 30; magic = 0; width = 650; height = 600; m_usedN = 0;
     }

   void              Init(const int x, const int y, const long magic_number, const double default_lot)
     {
      int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
      m_k = dpi > 0 ? dpi / 96.0 : 1.0;
      m_x = x; m_y = y; magic = magic_number;
      for(int i = 0; i < 2; i++)
        {
         draft[i].dir = GC_BUY; draft[i].trigger = ""; draft[i].lot = GcNum(default_lot); draft[i].tp = i == 0 ? "3" : "";
         draft[i].sl = ""; draft[i].gap = ""; draft[i].stop = ""; draft[i].maxc = ""; draft[i].dloss = ""; draft[i].mspread = "0.6";
         draft[i].mslip = "0.5"; draft[i].hours = ""; draft[i].anchor = ANCHOR_PLANNED; draft[i].tside = SIDE_BID;
         draft[i].price_input = false; draft[i].otp = ""; draft[i].osl = ""; draft[i].seen_tp = -1; draft[i].seen_sl = -1; draft[i].seen_ticket = 0;
        }
      ChartSetInteger(0, CHART_FOREGROUND, false);
      ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);
     }

   bool              Inside(const int x, const int y) const { return x >= m_x && x <= m_x + S(width) && y >= m_y && y <= m_y + S(height); }

   void              Log(const string level, const string msg)
     {
      int n = ArraySize(logText);
      if(n >= GC_LOG_MAX)
        {
         ArrayRemove(logText, 0, 1);
         ArrayRemove(logColor, 0, 1);
         n--;
        }
      ArrayResize(logText, n + 1);
      ArrayResize(logColor, n + 1);
      logText[n] = TimeToString(TimeLocal(), TIME_SECONDS) + " " + msg;
      logColor[n] = (int)(level == "error" ? C_DOWN : level == "warn" ? C_WARN : C_TEXT);
     }

   void              Message(const string msg, const color c) { message = msg; messageColor = c; }

   //--- turn the typed text into a config; every typo is listed
   void              BuildConfig(const int mode, const bool enter_now, SConfig &c, string &errors[])
     {
      SDraft d;
      d = draft[mode];
      ArrayResize(errors, 0);
      GcDefaultConfig(c, mode);
      c.dir = d.dir; c.anchor = d.anchor; c.trigger_side = d.tside; c.enter_now = enter_now;
      c.price_input = mode == GC_SINGLE && d.price_input;
      double v;
      if(!enter_now)   // "Buy / Sell now" uses the live price
        {
         c.trigger = Num(d.trigger, "Trigger price", errors);
         if(c.trigger <= 0)
            GcAdd(errors, "Enter the trigger price");
        }
      c.lot = Num(d.lot, "Lot", errors);
      if(c.lot <= 0)
         GcAdd(errors, "Enter the lot");
      if(!enter_now)   // "Buy / Sell now" opens without TP and SL
        {
         v = Num(d.tp, "TP", errors);
         if(c.price_input)
            c.tp_price = v;
         else
            c.tp_points = v;
         if(d.tp != "" && v <= 0)
            GcAdd(errors, "TP must be above 0 (or blank)");
         if(mode == GC_SINGLE)
           {
            v = Num(d.sl, "SL", errors);
            if(c.price_input)
               c.sl_price = v;
            else
               c.sl_points = v;
            if(d.sl != "" && v <= 0)
               GcAdd(errors, "SL must be above 0 (or blank)");
           }
        }
      else
         c.price_input = false;
      if(mode == GC_CYCLE)
        {
         c.gap = Num(d.gap, "Cycle gap", errors);
         c.stop_price = Limit(d.stop, "Stop price", errors);
         v = Num(d.maxc, "Max cycles", errors);
         if(d.maxc != "" && (v < 1 || MathAbs(v - MathRound(v)) > 1e-9))
            GcAdd(errors, "Max cycles must be a whole number, 1 or more");
         c.max_cycles = (int)v;
        }
      c.daily_loss = Limit(d.dloss, "Daily loss limit", errors);
      c.max_spread = Limit(d.mspread, "Max spread", errors);
      c.max_slippage = d.mslip == "" ? 0.5 : Num(d.mslip, "Max slippage", errors);
      c.hours = d.hours;
     }

   //--- fill the form from a running configuration
   void              SyncDraft(const SConfig &c)
     {
      int m = c.mode;
      draft[m].dir = c.dir; draft[m].trigger = GcNum(c.trigger); draft[m].lot = GcNum(c.lot);
      draft[m].price_input = c.price_input;
      double tp = c.price_input ? c.tp_price : c.tp_points, sl = c.price_input ? c.sl_price : c.sl_points;
      draft[m].tp = tp > 0 ? GcNum(tp) : "";
      draft[m].sl = sl > 0 ? GcNum(sl) : "";
      draft[m].gap = c.gap > 0 ? GcNum(c.gap) : "";
      draft[m].stop = c.stop_price > 0 ? GcNum(c.stop_price) : "";
      draft[m].maxc = (c.max_cycles > 0 && m == GC_CYCLE) ? IntegerToString(c.max_cycles) : "";
      draft[m].dloss = c.daily_loss > 0 ? GcNum(c.daily_loss) : "";
      draft[m].mspread = c.max_spread > 0 ? GcNum(c.max_spread) : "";
      draft[m].mslip = GcNum(c.max_slippage);
      draft[m].hours = c.hours; draft[m].anchor = c.anchor; draft[m].tside = c.trigger_side;
      forceText = true;
     }

   // does the form differ from the running cycle? (then "Apply changes" is offered)
   bool              Differs(CEngine *bot)
     {
      SConfig c;
      string errors[];
      BuildConfig(bot.mode, false, c, errors);
      if(ArraySize(errors) > 0)
         return true;
      if(GcNormalizeConfig(c) != "")
         return true;
      SConfig r;
      r = bot.cfg;
      return MathAbs(c.trigger - r.trigger) > GC_EPS || MathAbs(c.lot - r.lot) > GC_EPS || MathAbs(c.tp_points - r.tp_points) > GC_EPS
             || MathAbs(c.gap - r.gap) > GC_EPS || MathAbs(c.stop_price - r.stop_price) > GC_EPS || c.max_cycles != r.max_cycles
             || MathAbs(c.daily_loss - r.daily_loss) > GC_EPS || MathAbs(c.max_spread - r.max_spread) > GC_EPS
             || MathAbs(c.max_slippage - r.max_slippage) > GC_EPS || c.hours != r.hours || c.anchor != r.anchor || c.trigger_side != r.trigger_side;
     }

   void              Render(CEngine *cycle, CEngine *single, const string symbol, const string warning, const double today_pnl)
     {
      m_usedN = 0;
      CEngine *bot = tab == 0 ? cycle : single;
      width = 652;
      Text("magic_" + IntegerToString(magic), -2000, -2000, " ");   // marks this chart: one GoldCycle per symbol and magic
      height = collapsed ? 58 : 646;
      Rect("bg", 0, 0, width, height, C_BG, C_BORDER);
      Header(cycle, single, symbol, warning);
      if(!collapsed)
        {
         Form(bot);
         Info(bot, today_pnl);
        }
      Sweep();
      forceText = false;
     }

   void              Remove()
     {
      ObjectsDeleteAll(0, GC_UI);
      ObjectsDeleteAll(0, GC_LINE);
      ChartRedraw();
     }

   //--- price lines on the chart for the selected tab (the running trade, or the form before starting)
   void              Lines(CEngine *bot)
     {
      double trig = 0, entry = 0, tp = 0, sl = 0, next = 0, stop = 0;
      bool preview = false;
      if(bot.Active() || bot.hasPos)
        {
         trig = (bot.state == GCS_ARMED && bot.trigger.active) ? bot.trigger.level : 0;
         entry = bot.hasPos ? bot.pos.price_open : 0;
         tp = bot.hasPos ? bot.cur_tp : 0;
         sl = bot.hasPos ? bot.cur_sl : 0;
         next = bot.hasPos ? bot.NextPlannedEntry() : 0;
         stop = bot.hasCfg ? bot.cfg.stop_price : 0;
        }
      else
        {
         preview = true;
         SConfig c;
         string errors[];
         BuildConfig(bot.mode, false, c, errors);
         if(ArraySize(errors) == 0 && GcNormalizeConfig(c) == "")
           {
            trig = c.trigger;
            tp = c.tp_points > 0 ? GcTpPrice(c.trigger, c.dir, c.tp_points) : 0;
            sl = (c.mode == GC_SINGLE && c.sl_points > 0) ? GcSlPrice(c.trigger, c.dir, c.sl_points) : 0;
            stop = c.stop_price;
           }
        }
      Line("trigger", trig, C_INFO, STYLE_DASH, preview ? "trigger (not started)" : "trigger");
      Line("entry", entry, C_GOLD, STYLE_SOLID, "entry");
      Line("tp", tp, C_UP, preview ? STYLE_DOT : STYLE_SOLID, preview ? "TP (preview)" : "TP");
      Line("sl", sl, C_DOWN, preview ? STYLE_DOT : STYLE_SOLID, preview ? "SL (preview)" : "SL");
      Line("next", next, C_MUTED, STYLE_DOT, "next entry");
      Line("stop", stop, C_WARN, STYLE_DASHDOT, "stop price");
     }

private:
   double            Num(const string text, const string label, string &errors[])
     {
      double v;
      bool blank;
      if(!GcParse(text, v, blank))
        {
         GcAdd(errors, label + ": '" + text + "' is not a number");
         return 0;
        }
      return v;
     }

   // an optional limit: blank = none. "0" is refused, it must never silently mean "no limit"
   double            Limit(const string text, const string label, string &errors[])
     {
      double v = Num(text, label, errors);
      string t = text;
      StringTrimLeft(t);
      StringTrimRight(t);
      double parsed;
      bool blank;
      if(t != "" && GcParse(t, parsed, blank) && parsed <= 0)
         GcAdd(errors, label + " must be above 0 (or blank for none)");
      return v;
     }

   void              Line(const string id, const double price, const color c, const ENUM_LINE_STYLE style, const string label)
     {
      string n = GC_LINE + id;
      if(price <= 0)
        {
         ObjectDelete(0, n);
         return;
        }
      if(ObjectFind(0, n) < 0)
        {
         ObjectCreate(0, n, OBJ_HLINE, 0, 0, price);
         ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, n, OBJPROP_BACK, true);
        }
      ObjectSetDouble(0, n, OBJPROP_PRICE, price);
      ObjectSetInteger(0, n, OBJPROP_COLOR, c);
      ObjectSetInteger(0, n, OBJPROP_STYLE, style);
      ObjectSetString(0, n, OBJPROP_TEXT, label);
     }

   color             StateColor(const int s)
     {
      if(s == GCS_ARMED || s == GCS_OPENING)
         return C_INFO;
      if(s == GCS_IN_POSITION || s == GCS_RESOLVING)
         return C_UP;
      if(s == GCS_STOPPED)
         return C_WARN;
      return C_MUTED;
     }

   void              Header(CEngine *cycle, CEngine *single, const string symbol, const string warning)
     {
      Text("title", 12, 7, "GoldCycle", C_GOLD, 13, "Segoe UI Semibold");
      bool demo = AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO;
      Text("mode", 110, 11, demo ? "DEMO" : "REAL ACCOUNT", demo ? C_GOLD : C_DOWN, 9, "Segoe UI Semibold");
      Text("acct", 215, 11, "#" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "   " + symbol, C_TEXT);
      Text("money", 390, 11, "Balance " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "   Equity "
           + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), C_TEXT);
      Button("help", width - 62, 6, 24, 20, "?");
      Button("collapse", width - 32, 6, 24, 20, collapsed ? "+" : "-");
      string line = warning;
      color c = C_DOWN;
      if(line == "")
        {
         line = "Cycle: " + GcStateName(cycle.state) + "      Single: " + GcStateName(single.state);
         if(cycle.haveTick)
            line += "      Spread " + DoubleToString(GcSpreadPoints(cycle.lastTick), 2);
         c = C_MUTED;
        }
      Text("sub", 12, 34, line, c);
     }

   void              Form(CEngine *bot)
     {
      int m = bot.mode;
      SDraft d;
      d = draft[m];
      bool running = bot.Active();
      bool holding = bot.hasPos && (bot.state == GCS_IN_POSITION || bot.state == GCS_STOPPED || bot.state == GCS_RESOLVING);
      bool single_busy = m == GC_SINGLE && (running || holding);
      bool trigger_locked = m == GC_CYCLE && running && !(bot.state == GCS_ARMED && bot.leg == 1);
      if(trigger_locked && bot.hasCfg)   // a locked field shows the running value (an unapplied edit can't get stuck)
         draft[m].trigger = GcNum(bot.cfg.trigger);
      Button("tab0", 10, 58, 144, 24, "Cycle", tab == 0 ? C_GOLD : C_PANEL, tab == 0 ? clrBlack : C_TEXT);
      Button("tab1", 160, 58, 144, 24, "Single", tab == 1 ? C_GOLD : C_PANEL, tab == 1 ? clrBlack : C_TEXT);
      // a Single trade is open: show only what changes THIS trade (the form is for the next one)
      bool trade_only = m == GC_SINGLE && holding;
      int y = 88;
      if(!trade_only)
        {
         int dir = (running && bot.hasCfg) ? bot.cfg.dir : d.dir;
         bool dir_locked = running;
         Button("buy", 10, 88, 144, 26, "BUY", dir == GC_BUY ? C_UP : C_PANEL, dir == GC_BUY ? clrWhite : (dir_locked ? C_MUTED : C_TEXT));
         Button("sell", 160, 88, 144, 26, "SELL", dir == GC_SELL ? C_DOWN : C_PANEL, dir == GC_SELL ? clrWhite : (dir_locked ? C_MUTED : C_TEXT));
         y = 122;
         Text("l_trig", 10, y + 3, "Trigger price", C_MUTED);
         Edit("trigger", 108, y, 110, trigger_locked ? draft[m].trigger : d.trigger, trigger_locked);
         Button("bid", 224, y, 36, 20, "Bid");
         Button("pick_trigger", 264, y, 40, 20, picking == "trigger" ? "..." : "Pick", picking == "trigger" ? C_INFO : C_PANEL);
         y += 25;
         Text("l_lot", 10, y + 3, "Lot", C_MUTED);
         Edit("lot", 108, y, 110, d.lot);
         if(bot.spec.vol_step > 0)
            Text("h_lot", 224, y + 3, "step " + GcNum(bot.spec.vol_step), C_MUTED, 8);
         y += 25;
         if(m == GC_CYCLE)
           {
            Text("l_tp", 10, y + 3, "TP points", C_MUTED);
            Edit("tp", 108, y, 110, d.tp);
            Text("h_tp", 224, y + 3, "order 1", C_MUTED, 8);
            y += 25;
            Text("l_gap", 10, y + 3, "Cycle gap", C_MUTED);
            Edit("gap", 108, y, 110, d.gap);
            Text("h_gap", 224, y + 3, "blank = same", C_MUTED, 8);
            y += 25;
            Text("l_stop", 10, y + 3, "Stop price", C_MUTED);
            Edit("stop", 108, y, 110, d.stop);
            Button("pick_stop", 264, y, 40, 20, picking == "stop" ? "..." : "Pick", picking == "stop" ? C_INFO : C_PANEL);
            y += 25;
           }
         else
           {
            Text("l_unit", 10, y + 3, "TP / SL as", C_MUTED);
            Button("unit", 108, y, 110, 20, d.price_input ? "Exact prices" : "Points");
            Text("h_unit", 224, y + 3, "both optional", C_MUTED, 8);
            y += 25;
            Text("l_tp", 10, y + 3, d.price_input ? "TP price" : "TP points", C_MUTED);
            Edit("tp", 108, y, 110, d.tp);
            Button("pick_tp", 264, y, 40, 20, picking == "tp" ? "..." : "Pick", picking == "tp" ? C_INFO : C_PANEL);
            y += 25;
            Text("l_sl", 10, y + 3, d.price_input ? "SL price" : "SL points", C_MUTED);
            Edit("sl", 108, y, 110, d.sl);
            Button("pick_sl", 264, y, 40, 20, picking == "sl" ? "..." : "Pick", picking == "sl" ? C_INFO : C_PANEL);
            y += 25;
           }
         Button("adv", 10, y, 294, 20, advanced ? "Safety and advanced  (hide)" : "Safety and advanced  (show)", C_BG, C_MUTED);
         y += 25;
         if(advanced)
           {
            if(m == GC_CYCLE)
              {
               Text("l_maxc", 10, y + 3, "Max cycles", C_MUTED);
               Edit("maxc", 108, y, 50, d.maxc);
              }
            Text("l_dloss", 166, y + 3, "Daily loss", C_MUTED);
            Edit("dloss", 240, y, 64, d.dloss);
            y += 24;
            Text("l_mspread", 10, y + 3, "Max spread", C_MUTED);
            Edit("mspread", 108, y, 50, d.mspread);
            Text("l_mslip", 166, y + 3, "Max slip", C_MUTED);
            Edit("mslip", 240, y, 64, d.mslip);
            y += 24;
            Text("l_hours", 10, y + 3, "Trading hours", C_MUTED);
            Edit("hours", 108, y, 110, d.hours);
            Text("h_hours", 224, y + 3, "08:00-17:00", C_MUTED, 8);
            y += 24;
            Button("tside", 10, y, 144, 20, "Trigger on: " + (d.tside == SIDE_ASK ? "Ask" : d.tside == SIDE_MID ? "Mid" : "Bid"));
            Button("anchor", 160, y, 144, 20, "Levels from: " + (d.anchor == ANCHOR_FILL ? "Fill" : "Planned"));
            y += 25;
           }

        }
      else if(picking != "otp" && picking != "osl")
         picking = "";

      //--- the open trade's TP / SL, Cycle and Single (dragging the lines in MetaTrader works too)
      if(holding && bot.pending_close == CR_NONE && bot.state != GCS_RESOLVING)
        {
         // a new trade, or levels changed on the trade: show the real values (never a left-over from before)
         if(draft[m].seen_ticket != bot.pos.ticket || MathAbs(draft[m].seen_tp - bot.cur_tp) > GC_EPS || MathAbs(draft[m].seen_sl - bot.cur_sl) > GC_EPS)
           {
            draft[m].seen_ticket = bot.pos.ticket; draft[m].seen_tp = bot.cur_tp; draft[m].seen_sl = bot.cur_sl;
            draft[m].otp = bot.cur_tp > 0 ? DoubleToString(bot.cur_tp, 2) : "";
            draft[m].osl = bot.cur_sl > 0 ? DoubleToString(bot.cur_sl, 2) : "";
            ObjectSetString(0, GC_UI + "e_otp", OBJPROP_TEXT, draft[m].otp);
            ObjectSetString(0, GC_UI + "e_osl", OBJPROP_TEXT, draft[m].osl);
           }
         Text("h_trade", 10, y + 2, "Change THIS open trade   (empty = none)", C_GOLD, 9, "Segoe UI Semibold");
         y += 22;
         Text("l_otp", 10, y + 3, "TP price", C_UP);
         Edit("otp", 108, y, 110, draft[m].otp);
         Button("pick_otp", 224, y, 80, 20, picking == "otp" ? "click chart" : "Pick", picking == "otp" ? C_INFO : C_PANEL);
         y += 25;
         Text("l_osl", 10, y + 3, "SL price", C_DOWN);
         Edit("osl", 108, y, 110, draft[m].osl);
         Button("pick_osl", 224, y, 80, 20, picking == "osl" ? "click chart" : "Pick", picking == "osl" ? C_INFO : C_PANEL);
         y += 25;
         Button("setlv", 10, y, 294, 26, "Set TP / SL on this trade", C_UP, clrWhite);
         y += 32;
         if(trade_only)
           {
            Text("h_drag", 10, y, "You can also drag the TP / SL lines on the chart.", C_MUTED, 8);
            y += 20;
           }
        }

      //--- action buttons
      if(bot.resumable)
        {
         Button("resume", 10, y, 294, 30, "Resume", C_GOLD, clrBlack);
         y += 36;
        }
      if(m == GC_CYCLE)
        {
         if(!running)
           {
            Button("arm", 10, y, 294, 30, "Start cycle", C_GOLD, clrBlack);
            y += 36;
           }
         else
           {
            if(Differs(bot))
              {
               Button("apply", 10, y, 200, 28, "Apply changes", C_INFO, clrWhite);
               Button("discard", 216, y, 88, 28, "Discard");
               y += 34;
              }
            Button("after", 10, y, 144, 28, bot.stop_after ? "Stopping after..." : "Stop after cycle", bot.stop_after ? C_WARN : C_PANEL, bot.stop_after ? clrBlack : C_TEXT);
            Button("stopnow", 160, y, 144, 28, "Stop now");
            y += 34;
           }
        }
      else
        {
         if(!single_busy)
           {
            string bid = bot.haveTick ? DoubleToString(bot.lastTick.bid, 2) : "";
            string ask = bot.haveTick ? DoubleToString(bot.lastTick.ask, 2) : "";
            Button("sellnow", 10, y, 144, 34, "SELL now  " + bid, C_DOWN, clrWhite);
            Button("buynow", 160, y, 144, 34, "BUY now  " + ask, C_UP, clrWhite);
            y += 40;
            Button("arm", 10, y, 294, 28, "Start at trigger price", C_GOLD, clrBlack);
            y += 34;
           }
         else
           {
            bool open = bot.hasPos;
            Button("stopnow", 10, y, 294, 30, open ? "Close trade" : "Cancel", open ? C_GOLD : C_PANEL, open ? clrBlack : C_TEXT);
            y += 36;
           }
        }
      Button("killall", 10, y, 294, 28, "Close all and stop  (Ctrl+Shift+K = both)", C_BG, C_DOWN, C_DOWN);
      y += 34;

      //--- messages: last button result, then what is wrong with the form
      if(message != "")
        {
         Wrapped("msg", 10, y, message, messageColor, 48, 2);
         y += 32;
        }
      if(!running || m == GC_CYCLE)
        {
         SConfig c;
         string errors[], warnings[];
         BuildConfig(m, false, c, errors);
         if(ArraySize(errors) == 0)
           {
            string bad = GcNormalizeConfig(c);
            if(bad != "")
               GcAdd(errors, bad);
            else if(bot.spec.vol_step > 0)
               GcValidate(c, bot.spec, bot.lastTick, bot.haveTick && !running, errors, warnings);
           }
         int shown = 0;
         for(int i = 0; i < ArraySize(errors) && shown < 2 && y < 620; i++, shown++, y += 16)
            Text("err" + IntegerToString(i), 10, y, errors[i], C_DOWN, 8);
         for(int i = 0; i < ArraySize(warnings) && shown < 4 && y < 620; i++, shown++, y += 16)
            Text("warn" + IntegerToString(i), 10, y, warnings[i], C_WARN, 8);
        }
     }

   void              Wrapped(const string id, const int x, const int y, string text, const color c, const int chars, const int lines)
     {
      for(int i = 0; i < lines && text != ""; i++)
        {
         int cut = StringLen(text);
         if(cut > chars)
           {
            cut = chars;
            while(cut > 20 && StringGetCharacter(text, cut) != ' ')
               cut--;
           }
         Text(id + IntegerToString(i), x, y + 15 * i, StringSubstr(text, 0, cut), c, 8);
         text = StringSubstr(text, cut);
         StringTrimLeft(text);
        }
     }

   void              Info(CEngine *bot, const double today_pnl)
     {
      int x = 314, w = 328;
      //--- status
      Rect("status", x, 58, w, 132, C_PANEL, C_BORDER);
      Text("st", x + 10, 62, GcStateName(bot.state) + (bot.hasCfg && bot.state != GCS_IDLE ? "   " + bot.Label() : ""), StateColor(bot.state), 12, "Segoe UI Semibold");
      string l1 = "";
      if(bot.state == GCS_ARMED || bot.state == GCS_OPENING)
         l1 = bot.waiting;
      else if(bot.resumable)
         l1 = "Restarted while running. Press Resume.";
      else if(bot.state == GCS_STOPPED && bot.stop_reason != "")
         l1 = "Stopped: " + bot.stop_reason;
      else if(bot.pending_close != CR_NONE)
         l1 = "Closing position (" + GcReasonName(bot.pending_close) + ")...";
      Text("w", x + 10, 86, l1, C_INFO, 8);
      string p1 = "No open trade", p2 = "";
      if(bot.hasPos)
        {
         p1 = "#" + IntegerToString((long)bot.pos.ticket) + "  " + GcDirName(bot.pos.dir) + " " + GcNum(bot.pos.volume) + " @ " + DoubleToString(bot.pos.price_open, 2);
         p2 = "TP " + bot.Px(bot.cur_tp) + "    SL " + bot.Px(bot.cur_sl);
        }
      Text("p1", x + 10, 104, p1, bot.hasPos ? C_TEXT : C_MUTED);
      Text("p2", x + 10, 121, p2, C_TEXT);
      double next = bot.NextPlannedEntry();
      Text("nx", x + 10, 138, next > 0 ? "Next entry " + DoubleToString(next, 2) : "", C_MUTED);
      Text("pl_o", x + 10, 155, bot.hasPos ? "Open P/L " + Signed(bot.floating) : "", bot.floating >= 0 ? C_UP : C_DOWN, 10, "Segoe UI Semibold");
      Text("pl_s", x + 10, 172, "This session " + Signed(bot.session_pnl), bot.session_pnl >= 0 ? C_UP : C_DOWN);
      Text("pl_d", x + 170, 172, "Today " + Signed(today_pnl), today_pnl >= 0 ? C_UP : C_DOWN);

      //--- preview of the next orders
      Text("h_prev", x, 197, bot.mode == GC_CYCLE ? "Preview  (order 1 hits TP, order 2 hits SL, repeat)" : "Preview", C_MUTED, 8);
      Rect("prev", x, 212, w, 94, C_PANEL, C_BORDER);
      SConfig c;
      string errors[];
      BuildConfig(bot.mode, false, c, errors);
      if(bot.Active() && bot.hasCfg)
         c = bot.cfg;
      bool good = bot.Active() || (ArraySize(errors) == 0 && GcNormalizeConfig(c) == "");
      SPlanned plan[];
      if(good)
         GcPreview(c, 5, plan);
      Text("pv_head", x + 8, 215, "Order     Entry        TP           SL", C_MUTED, 8, "Consolas");
      for(int i = 0; i < ArraySize(plan); i++)
         Text("pv" + IntegerToString(i), x + 8, 230 + 14 * i,
              Pad(bot.mode == GC_CYCLE ? "C" + IntegerToString(plan[i].cycle) + "." + IntegerToString(plan[i].leg) : "Trade", 8)
              + Pad(DoubleToString(plan[i].entry, 2), 12) + Pad(plan[i].tp > 0 ? DoubleToString(plan[i].tp, 2) : "-", 12)
              + (plan[i].sl > 0 ? DoubleToString(plan[i].sl, 2) : "-"), C_TEXT, 8, "Consolas");

      //--- journal (this session, newest first)
      Text("h_j", x, 312, "Journal", C_MUTED, 8);
      Rect("jr", x, 327, w, 132, C_PANEL, C_BORDER);
      Text("j_head", x + 8, 330, "Order   Fill      Close     Result      P/L", C_MUTED, 8, "Consolas");
      int n = ArraySize(bot.rows);
      for(int i = 0; i < 8 && i < n; i++)
        {
         SRow r;
         r = bot.rows[n - 1 - i];
         string label = bot.mode == GC_CYCLE ? "C" + IntegerToString(r.cycle) + "." + IntegerToString(r.leg) : "Trade";
         bool open = r.close_time == 0;
         Text("j" + IntegerToString(i), x + 8, 345 + 14 * i,
              Pad(label, 8) + Pad(DoubleToString(r.fill, 2), 10) + Pad(open ? "..." : DoubleToString(r.close_price, 2), 10)
              + Pad(open ? "open" : GcReasonName(r.reason), 12) + (open ? "" : Signed(r.pnl)),
              open ? C_TEXT : (r.pnl >= 0 ? C_UP : C_DOWN), 8, "Consolas");
        }
      if(n == 0)
         Text("j_none", x + 8, 347, "No trades yet in this session.", C_MUTED, 8);

      //--- log (newest first). Everything is also in the Experts tab.
      Text("h_log", x, 465, "Log  (full text in the Experts tab)", C_MUTED, 8);
      Rect("log", x, 480, w, 138, C_PANEL, C_BORDER);
      int total = ArraySize(logText), line = 0;
      for(int i = total - 1; i >= 0 && line < 9; i--)
        {
         string t = logText[i];
         Text("g" + IntegerToString(line), x + 8, 483 + 14 * line, StringSubstr(t, 0, 58), (color)logColor[i], 8);
         line++;
         if(StringLen(t) > 58 && line < 9)
           {
            Text("g" + IntegerToString(line), x + 8, 483 + 14 * line, "    " + StringSubstr(t, 58, 58), (color)logColor[i], 8);
            line++;
           }
        }
     }

   static string     Signed(const double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2); }
   static string     Pad(string s, const int w)
     {
      while(StringLen(s) < w)
         s += " ";
      return s;
     }
  };

#endif
