//+------------------------------------------------------------------+
//| GoldCycle - the on-chart panel (replaces the web dashboard) and  |
//| the price lines. A typed value is applied at once; the EA runs   |
//| the buttons. Drag the panel by its title; Float pops it out.     |
//+------------------------------------------------------------------+
#ifndef GC_PANEL_MQH
#define GC_PANEL_MQH

#include "Engine.mqh"

#define GC_UI   "GCP_"
#define GC_LINE "GCL_"
#define GC_HEAD 94    // title area: drag the panel by it
#define GC_BODY 222   // first row of the form, under the tabs and the status box

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
   bool              price_input;
   string            otp, osl;          // TP / SL boxes of the open trade
   double            seen_tp, seen_sl;  // engine values the boxes were last filled from
   ulong             seen_ticket;       // the trade those boxes belong to
  };

class CGcPanel
  {
private:
   string            m_used[];
   int               m_ux[], m_uy[];    // each widget's place inside the panel, for dragging
   ulong             m_movedAt;
   int               m_usedN;
   double            m_k;               // screen scale (DPI / 96)
   int               m_x, m_y;
   bool              m_down, m_drag, m_hold, m_scroll;   // mouse state while dragging
   int               m_dx, m_dy;
   int               m_cw, m_ch;          // chart size, read at each draw and when a drag starts

   int               S(const int v) const { return (int)MathRound(v * m_k); }

   // the chart must not scroll while the mouse works on the panel
   void              Hold(const bool hold)
     {
      if(hold == m_hold)
         return;
      if(hold)
         m_scroll = ChartGetInteger(0, CHART_MOUSE_SCROLL) != 0;
      ChartSetInteger(0, CHART_MOUSE_SCROLL, hold ? false : m_scroll);
      m_hold = hold;
     }
   void              ReadChartSize()   // slow (waits for the chart), so not on every mouse move
     {
      m_cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      m_ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
     }
   void              Clamp()   // keep the title on the chart, so it can always be grabbed
     {
      if(m_cw <= 0 || m_ch <= 0)
         return;
      m_x = (int)MathMax(0, MathMin(m_x, m_cw - S(width)));
      m_y = (int)MathMax(0, MathMin(m_y, m_ch - S(GC_HEAD)));
     }
   static bool       Keep(string &field, const string v)   // true = the value changed
     {
      if(field == v)
         return false;
      field = v;
      return true;
     }
   void              Use(const string name, const int x, const int y)
     {
      if(m_usedN >= ArraySize(m_used))
        {
         ArrayResize(m_used, m_usedN + 64, 256);
         ArrayResize(m_ux, m_usedN + 64, 256);
         ArrayResize(m_uy, m_usedN + 64, 256);
        }
      m_ux[m_usedN] = S(x);
      m_uy[m_usedN] = S(y);
      m_used[m_usedN++] = name;
     }
   // move what is already on the chart: redrawing the whole panel on every mouse move is jerky
   void              Shift()
     {
      for(int i = 0; i < m_usedN; i++)
        {
         ObjectSetInteger(0, m_used[i], OBJPROP_XDISTANCE, m_x + m_ux[i]);
         ObjectSetInteger(0, m_used[i], OBJPROP_YDISTANCE, m_y + m_uy[i]);
        }
      ChartRedraw();
     }
   bool              Make(const string name, const ENUM_OBJECT type, const int x, const int y)
     {
      Use(name, x, y);
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
      Make(n, OBJ_RECTANGLE_LABEL, x, y);
      Place(n, x, y, w, h);
      ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_COLOR, border);
     }
   void              Text(const string id, const int x, const int y, const string text, const color c = C_TEXT, const int size = 9, const string font = "Segoe UI")
     {
      string n = GC_UI + "t_" + id;
      Make(n, OBJ_LABEL, x, y);
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
      Make(n, OBJ_BUTTON, x, y);
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
      bool created = Make(n, OBJ_EDIT, x, y);
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
   bool              openPoints;        // open trade TP / SL typed as points from its entry, not as a price
   bool              forceText;
   string            message;           // result of the last button
   color             messageColor;
   SDraft            draft[2];
   long              magic;
   int               width, height;

                     CGcPanel()
     {
      tab = 0; collapsed = false; advanced = false; openPoints = false; forceText = false; message = ""; messageColor = C_MUTED;
      m_k = 1; m_x = 10; m_y = 30; magic = 0; width = 314; height = 600; m_usedN = 0;
      m_movedAt = 0; m_cw = 0; m_ch = 0; m_down = false; m_drag = false; m_hold = false; m_scroll = true; m_dx = 0; m_dy = 0;
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
         draft[i].mslip = "0.5"; draft[i].hours = "";
         draft[i].price_input = false; draft[i].otp = ""; draft[i].osl = ""; draft[i].seen_tp = -1; draft[i].seen_sl = -1; draft[i].seen_ticket = 0;
        }
      ChartSetInteger(0, CHART_FOREGROUND, false);
      ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);
      ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);   // for dragging
      m_down = false; m_drag = false;
     }

   bool              Inside(const int x, const int y) const { return x >= m_x && x <= m_x + S(width) && y >= m_y && y <= m_y + S(height); }

   int               X() const { return m_x; }
   int               Y() const { return m_y; }
   void              MoveTo(const int x, const int y) { m_x = x; m_y = y; }

   // being dragged right now (a full redraw would make it stutter)
   bool              Moving() const { return m_drag && GetTickCount64() - m_movedAt < 300; }

   //--- pop the chart (with the panel) out as its own window, which can be dragged anywhere, even to another
   //    screen. The panel can't leave a chart in MetaTrader, so the chart goes with it
   void              ToggleFloat()
     {
      bool docked = ChartGetInteger(0, CHART_IS_DOCKED) != 0;
      ChartSetInteger(0, CHART_IS_DOCKED, !docked);
      if(!docked)
         return;
      int screen = (int)TerminalInfoInteger(TERMINAL_SCREEN_HEIGHT);
      int bottom = 40 + S(790);
      if(screen > 200)
         bottom = (int)MathMin(bottom, screen - 60);
      ChartSetInteger(0, CHART_FLOAT_LEFT, 40);
      ChartSetInteger(0, CHART_FLOAT_TOP, 40);
      ChartSetInteger(0, CHART_FLOAT_RIGHT, 40 + S(width + 100));   // room for the price scale
      ChartSetInteger(0, CHART_FLOAT_BOTTOM, bottom);
      m_x = 0;
      m_y = 0;
     }

   //--- drag the panel by its title. true = it moved
   bool              Mouse(const int x, const int y, const bool down)
     {
      bool pressed = down && !m_down;
      m_down = down;
      if(!down || pressed)
         Hold(Inside(x, y));
      if(pressed && Inside(x, y) && y < m_y + S(GC_HEAD) && x < m_x + S(width - 116))   // not on the header buttons
        {
         ReadChartSize();
         m_drag = true;
         m_dx = x - m_x;
         m_dy = y - m_y;
        }
      if(!down)
         m_drag = false;
      if(!m_drag)
         return false;
      int old_x = m_x, old_y = m_y;
      m_x = x - m_dx;
      m_y = y - m_dy;
      Clamp();
      if(m_x == old_x && m_y == old_y)
         return false;
      m_movedAt = GetTickCount64();
      Shift();
      return true;
     }

   void              SetOpenPoints(const bool points)
     {
      openPoints = points;
      draft[0].seen_tp = -1;   // show the levels in the chosen unit
      draft[1].seen_tp = -1;
     }

   void              Message(const string msg, const color c) { message = msg; messageColor = c; }

   //--- turn the typed text into a config; every typo is listed
   void              BuildConfig(const int mode, const bool enter_now, SConfig &c, string &errors[])
     {
      SDraft d;
      d = draft[mode];
      ArrayResize(errors, 0);
      GcDefaultConfig(c, mode);
      c.dir = d.dir; c.enter_now = enter_now;
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
      if(enter_now && !c.price_input)
         c.anchor = ANCHOR_FILL;   // "Buy / Sell now": points count from the price actually received
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
      draft[m].hours = c.hours;
      forceText = true;
     }

   //--- a value was typed (Enter): store it and send it at once to the running cycle / the open trade.
   //    false = nothing changed. err != "" = refused, and the boxes go back to the values in effect
   bool              Typed(CEngine *bot, const string id, const string v, string &err)
     {
      int m = bot.mode;
      err = "";
      bool changed = false;
      if(id == "trigger") changed = Keep(draft[m].trigger, v);
      else if(id == "lot") changed = Keep(draft[m].lot, v);
      else if(id == "tp") changed = Keep(draft[m].tp, v);
      else if(id == "sl") changed = Keep(draft[m].sl, v);
      else if(id == "gap") changed = Keep(draft[m].gap, v);
      else if(id == "stop") changed = Keep(draft[m].stop, v);
      else if(id == "maxc") changed = Keep(draft[m].maxc, v);
      else if(id == "dloss") changed = Keep(draft[m].dloss, v);
      else if(id == "mspread") changed = Keep(draft[m].mspread, v);
      else if(id == "mslip") changed = Keep(draft[m].mslip, v);
      else if(id == "hours") changed = Keep(draft[m].hours, v);
      else if(id == "otp") changed = Keep(draft[m].otp, v);
      else if(id == "osl") changed = Keep(draft[m].osl, v);
      if(!changed)
         return false;
      if(id == "otp" || id == "osl")
         SendLevel(bot, id == "otp", v, err);
      else
         Apply(bot, err);
      return true;
     }

private:
   // a running cycle takes the form's values at once; when the bot is not running, Start uses them
   void              Apply(CEngine *bot, string &err)
     {
      err = "";
      if(!bot.Active())
         return;
      if(bot.mode == GC_SINGLE)
         err = "A waiting Single trade can't change: Cancel first";
      else
        {
         SConfig c;
         string errors[];
         BuildConfig(GC_CYCLE, false, c, errors);
         c.dir = bot.cfg.dir;
         if(ArraySize(errors) > 0)
            err = errors[0];
         else
            bot.UpdateConfig(c, err);
        }
      SyncDraft(bot.cfg);   // show what is really in effect
     }

   // +1 / -1: which way from the entry a TP (profit side) or an SL (loss side) counts its points
   static int        Side(CEngine *bot, const bool is_tp) { return (is_tp ? 1 : -1) * GcSign(bot.pos.dir); }

   // the open trade's TP / SL as its box shows it ("" = none)
   string            LevelText(CEngine *bot, const bool is_tp)
     {
      double level = is_tp ? bot.cur_tp : bot.cur_sl;
      if(level <= 0)
         return "";
      if(!openPoints)
         return DoubleToString(level, 2);
      double pts = NormalizeDouble(Side(bot, is_tp) * (level - bot.pos.price_open) / GC_POINT_SIZE, 2);
      return MathAbs(pts) < 0.005 ? "0" : GcNum(pts);
     }

   // the open trade: only the typed level changes, the other one stays exactly as it is on the trade
   void              SendLevel(CEngine *bot, const bool is_tp, string text, string &err)
     {
      // points may be negative: an SL of -2 sits 2 points on the profit side of the entry
      bool minus = openPoints && StringGetCharacter(text, 0) == '-';
      if(minus)
         text = StringSubstr(text, 1);
      double v;
      bool blank;
      if(!GcParse(text, v, blank) || (minus && blank))
         err = openPoints ? "TP / SL: type points, or leave it empty for none" : "TP / SL: type a price, or leave it empty for none";
      else
        {
         if(openPoints && !blank)
            v = GcR6(bot.pos.price_open + Side(bot, is_tp) * (minus ? -v : v) * GC_POINT_SIZE);
         if(openPoints && !blank && v <= 0)   // must never turn into "remove it"
            err = "TP / SL: that many points is below a price of 0";
         else
            bot.ModifyLevels(is_tp ? v : bot.cur_tp, is_tp ? bot.cur_sl : v, err);
        }
      draft[bot.mode].seen_tp = -1;   // redraw the boxes from the trade
     }

public:
   void              Render(CEngine *cycle, CEngine *single, const string symbol, const string warning, const double today_pnl)
     {
      m_usedN = 0;
      CEngine *bot = tab == 0 ? cycle : single;
      ReadChartSize();
      Clamp();
      Text("magic_" + IntegerToString(magic), -2000, -2000, " ");   // marks this chart: one GoldCycle per symbol and magic
      if(collapsed)
         height = GC_HEAD;
      Rect("bg", 0, 0, width, height, C_BG, C_BORDER);
      Header(cycle, single, symbol, warning);
      if(!collapsed)
        {
         Status(bot, today_pnl);
         height = Form(bot) + 4;
         Rect("bg", 0, 0, width, height, C_BG, C_BORDER);
        }
      Sweep();
      forceText = false;
     }

   void              Remove()
     {
      Hold(false);
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
      Button("float", width - 110, 6, 44, 20, ChartGetInteger(0, CHART_IS_DOCKED) != 0 ? "Float" : "Dock");
      Button("help", width - 62, 6, 24, 20, "?");
      Button("collapse", width - 32, 6, 24, 20, collapsed ? "+" : "-");
      string line = "#" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "   " + symbol;
      if(cycle.haveTick)
         line += "   Spread " + DoubleToString(GcSpreadPoints(cycle.lastTick), 2);
      Text("acct", 12, 30, line);
      Text("money", 12, 47, "Balance " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "   Equity "
           + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
      if(warning != "")
         Wrapped("top", 12, 64, warning, C_DOWN, 50, 2);
      else
         Text("sub", 12, 64, "Cycle: " + GcStateName(cycle.state) + "      Single: " + GcStateName(single.state), C_MUTED);
     }

   int               Form(CEngine *bot)   // returns where it ends
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
      Button("tab0", 10, GC_HEAD, 144, 24, "Cycle", tab == 0 ? C_GOLD : C_PANEL, tab == 0 ? clrBlack : C_TEXT);
      Button("tab1", 160, GC_HEAD, 144, 24, "Single", tab == 1 ? C_GOLD : C_PANEL, tab == 1 ? clrBlack : C_TEXT);
      // a Single trade is open: show only what changes THIS trade (the form is for the next one)
      bool trade_only = m == GC_SINGLE && holding;
      int y = GC_BODY;
      if(!trade_only)
        {
         int dir = (running && bot.hasCfg) ? bot.cfg.dir : d.dir;
         bool dir_locked = running;
         Button("buy", 10, y, 144, 26, "BUY", dir == GC_BUY ? C_UP : C_PANEL, dir == GC_BUY ? clrWhite : (dir_locked ? C_MUTED : C_TEXT));
         Button("sell", 160, y, 144, 26, "SELL", dir == GC_SELL ? C_DOWN : C_PANEL, dir == GC_SELL ? clrWhite : (dir_locked ? C_MUTED : C_TEXT));
         y += 34;
         Text("l_trig", 10, y + 3, "Trigger price", C_MUTED);
         Edit("trigger", 108, y, 110, trigger_locked ? draft[m].trigger : d.trigger, trigger_locked);
         y += 25;
         Text("l_lot", 10, y + 3, "Lot", C_MUTED);
         Edit("lot", 108, y, 110, d.lot);
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
            y += 25;
            Text("l_sl", 10, y + 3, d.price_input ? "SL price" : "SL points", C_MUTED);
            Edit("sl", 108, y, 110, d.sl);
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
           }

        }

      //--- the open trade's TP / SL, Cycle and Single (dragging the lines in MetaTrader works too)
      if(holding && bot.pending_close == CR_NONE && bot.state != GCS_RESOLVING)
        {
         // a new trade, or levels changed on the trade: show the real values (never a left-over from before)
         if(draft[m].seen_ticket != bot.pos.ticket || MathAbs(draft[m].seen_tp - bot.cur_tp) > GC_EPS || MathAbs(draft[m].seen_sl - bot.cur_sl) > GC_EPS)
           {
            if(draft[m].seen_ticket != bot.pos.ticket)   // a new trade: drop a half-typed value meant for the old one
              {
               ObjectDelete(0, GC_UI + "e_otp");
               ObjectDelete(0, GC_UI + "e_osl");
              }
            draft[m].seen_ticket = bot.pos.ticket; draft[m].seen_tp = bot.cur_tp; draft[m].seen_sl = bot.cur_sl;
            draft[m].otp = LevelText(bot, true);
            draft[m].osl = LevelText(bot, false);
            ObjectSetString(0, GC_UI + "e_otp", OBJPROP_TEXT, draft[m].otp);
            ObjectSetString(0, GC_UI + "e_osl", OBJPROP_TEXT, draft[m].osl);
           }
         Text("h_trade", 10, y + 2, "Change THIS open trade   (empty = none)", C_GOLD, 9, "Segoe UI Semibold");
         y += 22;
         Text("l_ounit", 10, y + 3, "TP / SL as", C_MUTED);
         Button("oprice", 108, y, 96, 20, "Price", openPoints ? C_PANEL : C_GOLD, openPoints ? C_TEXT : clrBlack);
         Button("opoints", 208, y, 96, 20, "Points", openPoints ? C_GOLD : C_PANEL, openPoints ? clrBlack : C_TEXT);
         y += 25;
         Text("l_otp", 10, y + 3, openPoints ? "TP points" : "TP price", C_UP);
         Edit("otp", 108, y, 196, draft[m].otp);
         y += 25;
         Text("l_osl", 10, y + 3, openPoints ? "SL points" : "SL price", C_DOWN);
         Edit("osl", 108, y, 196, draft[m].osl);
         y += 25;
         Text("h_enter", 10, y, openPoints ? "Distance from entry " + DoubleToString(bot.pos.price_open, 2) + ". Press Enter to apply."
              : "Press Enter to apply, or drag the lines on the chart.", C_MUTED, 8);
         y += 20;
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

      //--- messages: last result, then what is wrong with the form
      if(message != "")
         y += 15 * Wrapped("msg", 10, y, message, messageColor, 50, 2) + 2;
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
         for(int i = 0; i < ArraySize(errors) && shown < 2; i++, shown++)
            y += 15 * Wrapped("err" + IntegerToString(i) + "_", 10, y, errors[i], C_DOWN, 50, 2) + 1;
         for(int i = 0; i < ArraySize(warnings) && shown < 3; i++, shown++)
            y += 15 * Wrapped("warn" + IntegerToString(i) + "_", 10, y, warnings[i], C_WARN, 50, 2) + 1;
        }
      return y;
     }

   int               Wrapped(const string id, const int x, const int y, string text, const color c, const int chars, const int lines)
     {
      int i = 0;
      for(; i < lines && text != ""; i++)
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
      return i;
     }

   void              Status(CEngine *bot, const double today_pnl)
     {
      int y = GC_HEAD + 30;
      Rect("status", 10, y, 294, 92, C_PANEL, C_BORDER);
      Text("st", 18, y + 4, GcStateName(bot.state) + (bot.hasCfg && bot.state != GCS_IDLE ? "   " + bot.Label() : ""), StateColor(bot.state), 12, "Segoe UI Semibold");
      string l1 = "";
      if(bot.state == GCS_ARMED || bot.state == GCS_OPENING)
         l1 = bot.waiting;
      else if(bot.resumable)
         l1 = "Restarted while running. Press Resume.";
      else if(bot.state == GCS_STOPPED && bot.stop_reason != "")
         l1 = "Stopped: " + bot.stop_reason;
      else if(bot.pending_close != CR_NONE)
         l1 = "Closing position (" + GcReasonName(bot.pending_close) + ")...";
      double next = bot.NextPlannedEntry();
      if(l1 == "" && next > 0)
         l1 = "Next entry " + DoubleToString(next, 2);
      Wrapped("w", 18, y + 27, l1, C_INFO, 48, bot.hasPos ? 1 : 2);
      if(bot.hasPos)
        {
         Text("p1", 18, y + 41, "#" + IntegerToString((long)bot.pos.ticket) + "  " + GcDirName(bot.pos.dir) + " " + GcNum(bot.pos.volume) + " @ " + DoubleToString(bot.pos.price_open, 2));
         Text("p2", 18, y + 56, "TP " + bot.Px(bot.cur_tp) + "    SL " + bot.Px(bot.cur_sl));
         Text("pl_o", 18, y + 73, "Open " + Signed(bot.floating), bot.floating >= 0 ? C_UP : C_DOWN, 9, "Segoe UI Semibold");
        }
      else
         Text("p1", 18, y + 56, "No open trade", C_MUTED);
      Text("pl_s", 108, y + 73, "Session " + Signed(bot.session_pnl), bot.session_pnl >= 0 ? C_UP : C_DOWN);
      Text("pl_d", 208, y + 73, "Today " + Signed(today_pnl), today_pnl >= 0 ? C_UP : C_DOWN);
     }

   static string     Signed(const double v) { return (v >= 0 ? "+" : "") + DoubleToString(v, 2); }
  };

#endif
