//+------------------------------------------------------------------+
//| GoldCycle - pure rules: levels, trigger, limits, validation.     |
//| No trading calls here, so the test script can check every rule.  |
//+------------------------------------------------------------------+
#ifndef GC_LOGIC_MQH
#define GC_LOGIC_MQH

#include "Types.mqh"

int    GcSign(const int dir) { return dir == GC_BUY ? 1 : -1; }
double GcR6(const double x) { return NormalizeDouble(x, 6); }   // kill float noise; real rounding at send time

//--- §4.2
double GcTpPrice(const double entry, const int dir, const double pts) { return GcR6(entry + GcSign(dir) * pts * GC_POINT_SIZE); }
double GcSlPrice(const double entry, const int dir, const double pts) { return GcR6(entry - GcSign(dir) * pts * GC_POINT_SIZE); }

//--- §4.4: after order 2's SL the next cycle starts at this cycle's entry, shifted by the gap in the trade direction
double GcReentryAfterSl(const double cycle_entry, const int dir, const double gap) { return GcR6(cycle_entry + GcSign(dir) * gap * GC_POINT_SIZE); }

//--- §4.5: the stop price is free. Above the trigger it is hit when price rises to it, below when price falls to it
bool GcBeyondStop(const double price, const SConfig &c)
  {
   if(c.stop_price <= 0)
      return false;
   int side = c.stop_price > c.trigger ? 1 : -1;
   return side * (price - c.stop_price) >= -GC_EPS;
  }
//--- measured on the price the open trade closes at: bid for BUY, ask for SELL
bool GcStopReached(const STick &t, const SConfig &c) { return GcBeyondStop(c.dir == GC_BUY ? t.bid : t.ask, c); }

double GcLotForCycle(const double lot, const double mult, const int cycle_no) { return lot * MathPow(mult, cycle_no - 1); }

double GcRoundVolume(const double volume, const double step)
  {
   if(step <= 0)
      return volume;
   return NormalizeDouble(MathRound(volume / step) * step, 8);
  }

//--- §4.6 trigger
double GcTriggerPrice(const STick &t, const int side)
  {
   if(side == SIDE_ASK)
      return t.ask;
   if(side == SIDE_MID)
      return (t.bid + t.ask) / 2.0;
   return t.bid;
  }

// Records which side of the level the price was on when armed, fires when price reaches the level from that side.
// Exactly on the level at arm time does NOT fire: wait for it to move off and come back.
struct STrigger
  {
   bool              active;
   double            level;
   int               side;   // 0 = unknown, 1 = armed above the level, -1 = below
  };

void GcTriggerSide(STrigger &tr, const double price)
  {
   if(price > tr.level + GC_EPS)
      tr.side = 1;
   else if(price < tr.level - GC_EPS)
      tr.side = -1;
  }
void GcTriggerArm(STrigger &tr, const double level, const double price)
  {
   tr.active = true; tr.level = level; tr.side = 0;
   GcTriggerSide(tr, price);
  }
bool GcTriggerUpdate(STrigger &tr, const double price)
  {
   if(tr.side == 0)
     {
      GcTriggerSide(tr, price);
      return false;
     }
   if(tr.side == 1)
      return price <= tr.level + GC_EPS;
   return price >= tr.level - GC_EPS;
  }

//--- §5 limits
double GcSpreadPoints(const STick &t) { return (t.ask - t.bid) / GC_POINT_SIZE; }
bool GcSpreadOk(const STick &t, const double max_spread) { return max_spread <= 0 || GcSpreadPoints(t) <= max_spread + GC_EPS; }
bool GcWithinSlippage(const double price, const double planned, const double max_slip) { return MathAbs(price - planned) / GC_POINT_SIZE <= max_slip + GC_EPS; }
bool GcDailyLossHit(const double pnl_today, const double limit) { return limit > 0 && pnl_today <= -limit + GC_EPS; }

//--- "HH:MM" -> minutes, -1 if not valid
int GcHm(const string s)
  {
   if(StringLen(s) != 5 || StringGetCharacter(s, 2) != ':')
      return -1;
   for(int i = 0; i < 5; i++)
     {
      if(i == 2)
         continue;
      ushort ch = StringGetCharacter(s, i);
      if(ch < '0' || ch > '9')
         return -1;
     }
   int h = (int)StringToInteger(StringSubstr(s, 0, 2));
   int m = (int)StringToInteger(StringSubstr(s, 3, 2));
   if(h > 23 || m > 59)
      return -1;
   return h * 60 + m;
  }
bool GcHoursValid(const string w) { return StringLen(w) == 11 && StringGetCharacter(w, 5) == '-' && GcHm(StringSubstr(w, 0, 5)) >= 0 && GcHm(StringSubstr(w, 6, 5)) >= 0; }
bool GcInTradingHours(const int now_min, const string window)
  {
   if(window == "")
      return true;
   int start = GcHm(StringSubstr(window, 0, 5)), end = GcHm(StringSubstr(window, 6, 5));
   if(start <= end)
      return now_min >= start && now_min < end;
   return now_min >= start || now_min < end;   // window wraps midnight
  }

string GcNum(const double v)   // shortest readable form: 4000, 4000.5, 0.01
  {
   string s = DoubleToString(v, 5);
   while(StringFind(s, ".") >= 0 && (StringGetCharacter(s, StringLen(s) - 1) == '0' || StringGetCharacter(s, StringLen(s) - 1) == '.'))
     {
      bool dot = StringGetCharacter(s, StringLen(s) - 1) == '.';
      s = StringSubstr(s, 0, StringLen(s) - 1);
      if(dot)
         break;
     }
   return s;
  }
string GcOpt(const double v) { return v > 0 ? GcNum(v) : "none"; }

//--- Strict number parser: a typo must never silently become "none" (it would arm a trade without a TP/SL).
//    Returns false when the text is not blank and not a plain non-negative number.
bool GcParse(string text, double &value, bool &blank)
  {
   StringTrimLeft(text);
   StringTrimRight(text);
   value = 0;
   blank = (text == "");
   if(blank)
      return true;
   int dots = 0, digits = 0;
   for(int i = 0; i < StringLen(text); i++)
     {
      ushort ch = StringGetCharacter(text, i);
      if(ch >= '0' && ch <= '9')
         digits++;
      else if(ch == '.')
         dots++;
      else
         return false;
     }
   if(digits == 0 || dots > 1 || digits > 12)
      return false;
   value = StringToDouble(text);
   return true;
  }

void GcAdd(string &list[], const string s)
  {
   int n = ArraySize(list);
   ArrayResize(list, n + 1);
   list[n] = s;
  }

//--- The config rules (the Python CycleConfig validator). Normalizes `c` in place. "" = ok, else the reason.
string GcNormalizeConfig(SConfig &c)
  {
   if(c.trigger <= 0)
      return "Enter the trigger price";
   if(c.lot <= 0)
      return "Enter the lot";
   if(c.mode == GC_CYCLE && c.price_input)
      return "Cycle takes TP in points";
   if(c.mode == GC_CYCLE && c.enter_now)
      return "Buy/Sell now is for Single trades only";
   int side = GcSign(c.dir);
   bool buy = c.dir == GC_BUY;
   if(c.price_input)
     {
      if(c.tp_price > 0 && side * (c.tp_price - c.trigger) <= 0)
         return GcDirName(c.dir) + " TP price must be " + (buy ? "above" : "below") + " the trigger price";
      if(c.sl_price > 0 && side * (c.trigger - c.sl_price) <= 0)
         return GcDirName(c.dir) + " SL price must be " + (buy ? "below" : "above") + " the trigger price";
      // the engine works in points: derive them from the exact prices
      c.tp_points = c.tp_price > 0 ? GcR6(MathAbs(c.tp_price - c.trigger)) : 0;
      c.sl_points = c.sl_price > 0 ? GcR6(MathAbs(c.trigger - c.sl_price)) : 0;
     }
   else if(c.mode == GC_CYCLE && c.tp_points <= 0)
      return "TP points is required in Cycle";
   if(c.mode == GC_SINGLE)
     {
      c.gap = 0; c.stop_price = 0; c.max_cycles = 1;
     }
   else
      c.sl_points = 0;
   if(c.tp_points > 0 && c.trigger + side * c.tp_points <= 0)
      return "TP " + GcNum(c.tp_points) + " pts puts the TP price at or below 0";
   if(c.sl_points > 0 && c.trigger - side * c.sl_points <= 0)
      return "SL " + GcNum(c.sl_points) + " pts puts the SL price at or below 0";
   if(c.mode == GC_CYCLE && c.stop_price > 0 && MathAbs(c.stop_price - c.trigger) < GC_EPS)
      return "Stop price can't equal the trigger price";
   StringTrimLeft(c.hours);
   StringTrimRight(c.hours);
   if(c.hours != "" && !GcHoursValid(c.hours))
      return "Trading hours must look like 08:00-17:30";
   if(c.max_slippage < 0)
      return "Max slippage can't be negative";
   if(c.lot_mult <= 0)
      return "Lot multiplier must be above 0";
   return "";
  }

//--- Broker-aware checks shown on the panel before arming.
void GcValidate(const SConfig &c, const SSpec &spec, const STick &tick, const bool have_tick, string &errors[], string &warnings[])
  {
   ArrayResize(errors, 0);
   ArrayResize(warnings, 0);
   if(c.lot < spec.vol_min - 1e-9)
      GcAdd(errors, "Lot " + GcNum(c.lot) + " is below the minimum " + GcNum(spec.vol_min));
   if(c.lot > spec.vol_max + 1e-9)
      GcAdd(errors, "Lot " + GcNum(c.lot) + " is above the maximum " + GcNum(spec.vol_max));
   if(spec.vol_step > 0 && MathAbs(c.lot / spec.vol_step - MathRound(c.lot / spec.vol_step)) > 1e-6)
      GcAdd(errors, "Lot " + GcNum(c.lot) + " is not a multiple of the lot step " + GcNum(spec.vol_step));
   double min_dist = MathMax(spec.stops_level, spec.freeze_level) * spec.point;
   if(min_dist > 0)
     {
      if(c.tp_points > 0 && c.tp_points * GC_POINT_SIZE < min_dist)
         GcAdd(errors, "TP " + GcNum(c.tp_points) + " pts is closer than the broker minimum of " + GcNum(min_dist) + " pts");
      if(c.sl_points > 0 && c.sl_points * GC_POINT_SIZE < min_dist)
         GcAdd(errors, "SL " + GcNum(c.sl_points) + " pts is closer than the broker minimum of " + GcNum(min_dist) + " pts");
     }
   if(c.tp_points <= 0 && c.sl_points <= 0)
      GcAdd(warnings, "No TP and no SL: the trade stays open until you close it");
   if(!have_tick)
      return;
   double cur = tick.bid;
   if(MathAbs(c.trigger - cur) > 200)
      GcAdd(warnings, "Trigger " + GcNum(c.trigger) + " is far from the current price " + DoubleToString(cur, 2));
   if(MathAbs(c.trigger - cur) < GC_EPS && !c.enter_now)
      GcAdd(warnings, "Price is exactly at the trigger: the bot waits for it to move off and return");
   if(!GcSpreadOk(tick, c.max_spread))
      GcAdd(warnings, "Spread " + DoubleToString(GcSpreadPoints(tick), 2) + " is wider than max " + GcNum(c.max_spread));
   double worst = GcSpreadPoints(tick) + c.max_slippage;
   if(c.tp_points > 0 && c.tp_points <= 2 * worst)
      GcAdd(warnings, "TP " + GcNum(c.tp_points) + " is small vs spread + slippage (" + DoubleToString(worst, 2) + " pts)");
   if(c.stop_price > 0 && GcStopReached(tick, c))
      GcAdd(warnings, "Price is already beyond the stop price");
  }

void GcAddPlanned(SPlanned &out[], const int cycle, const int leg, const double entry, const double tp, const double sl, const double lot)
  {
   int n = ArraySize(out);
   ArrayResize(out, n + 1);
   out[n].cycle = cycle; out[n].leg = leg; out[n].entry = entry; out[n].tp = tp; out[n].sl = sl; out[n].lot = lot;
  }

//--- §4.1 preview: the next `count` planned orders. A cycle is order 1 then order 2; the next one assumes order 2's SL.
void GcPreview(const SConfig &c, const int count, SPlanned &out[])
  {
   ArrayResize(out, 0);
   double lot = c.lot;
   if(c.mode == GC_SINGLE)
     {
      GcAddPlanned(out, 1, 1, c.trigger, c.tp_points > 0 ? GcTpPrice(c.trigger, c.dir, c.tp_points) : 0,
                   c.sl_points > 0 ? GcSlPrice(c.trigger, c.dir, c.sl_points) : 0, lot);
      return;
     }
   double entry = c.trigger;
   int n = 1;
   while(ArraySize(out) < count && (c.max_cycles <= 0 || n <= c.max_cycles))
     {
      if(n > 1 && GcBeyondStop(entry, c))
         break;
      double tp = GcTpPrice(entry, c.dir, c.tp_points);
      GcAddPlanned(out, n, 1, entry, tp, 0, lot);
      if(ArraySize(out) == count || GcBeyondStop(tp, c))
         break;
      GcAddPlanned(out, n, 2, tp, 0, entry, lot);
      entry = GcReentryAfterSl(entry, c.dir, c.gap);
      n++;
     }
  }

#endif
