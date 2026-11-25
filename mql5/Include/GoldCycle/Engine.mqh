//+------------------------------------------------------------------+
//| GoldCycle - the engine: one state machine per bot (Cycle,        |
//| Single). Port of backend/app/engine/cycle_engine.py.             |
//+------------------------------------------------------------------+
#ifndef GC_ENGINE_MQH
#define GC_ENGINE_MQH

#include "Types.mqh"
#include "Logic.mqh"
#include "Broker.mqh"

#define GC_MAX_ROWS 40

//--- what the engine reports to its owner (the EA or the test script)
class CGcSink
  {
public:
   virtual void      Event(const string level, const string msg, const bool toast) = 0;   // level: info / warn / error
   virtual void      Closed(const SRow &row, const int mode, const string session) {}
   virtual int       BlockDay() = 0;                 // daily loss block, shared by both bots
   virtual void      SetBlockDay(const int day) = 0;
  };

class CEngine
  {
private:
   CBroker          *m_b;
   CGcSink          *m_sink;
   ulong             m_lastAttempt;
   ulong             m_resolveStarted;
   ulong             m_lastWarnAt;
   ulong             m_lastPopAt;
   string            m_lastWarn;
   ulong             m_openedMs;
   int               m_curRow;

public:
   int               mode;
   long              magic;
   long              otherMagic;      // the other bot's magic (daily loss is account-wide)
   bool              dirty;           // state changed: the owner saves it

   int               state;
   bool              hasCfg;
   SConfig           cfg;
   string            sid;
   int               cycle_no;
   int               leg;             // CYCLE: 1 = entry + TP, no SL; 2 = at order 1's TP, SL at its entry, no TP
   double            planned;
   double            anchor;
   double            prev_entry;
   double            cur_tp;          // 0 = none
   double            cur_sl;          // 0 = none
   STrigger          trigger;
   bool              hasPos;
   SPos              pos;             // the tracked position (price_open = fill)
   int               cycles_opened;
   double            session_pnl;
   double            floating;
   bool              stop_after;
   int               pending_close;   // ENUM_GC_REASON, CR_NONE = nothing
   string            stop_reason;
   bool              resumable;
   int               resume_state;
   string            waiting;
   bool              connected;
   STick             lastTick;
   bool              haveTick;
   SSpec             spec;
   SRow              rows[];          // journal of the current session, oldest first

                     CEngine() { m_b = NULL; m_sink = NULL; }

   void              Init(CBroker *broker, CGcSink *owner, const int bot_mode, const long bot_magic, const long other)
     {
      m_b = broker; m_sink = owner; mode = bot_mode; magic = bot_magic; otherMagic = other;
      connected = true; haveTick = false; dirty = false;
      Reset();
     }

   void              Reset()
     {
      state = GCS_IDLE; hasCfg = false; GcDefaultConfig(cfg, mode); sid = ""; cycle_no = 0; leg = 1;
      planned = 0; anchor = 0; prev_entry = 0; cur_tp = 0; cur_sl = 0;
      trigger.active = false; trigger.level = 0; trigger.side = 0;
      hasPos = false; ZeroPos();
      cycles_opened = 0; session_pnl = 0; floating = 0; stop_after = false; pending_close = CR_NONE;
      stop_reason = ""; resumable = false; resume_state = GCS_IDLE; waiting = "";
      m_lastAttempt = 0; m_resolveStarted = 0; m_lastWarnAt = 0; m_lastPopAt = 0; m_lastWarn = ""; m_openedMs = 0; m_curRow = -1;
      ArrayResize(rows, 0);
     }

   void              ZeroPos()
     {
      pos.ticket = 0; pos.dir = 0; pos.volume = 0; pos.price_open = 0; pos.sl = 0; pos.tp = 0; pos.profit = 0;
      pos.magic = 0; pos.comment = ""; pos.time = 0;
     }

   bool              Active() const { return state == GCS_ARMED || state == GCS_OPENING || state == GCS_IN_POSITION || state == GCS_RESOLVING; }

   //--- "C3.1" in Cycle, "Trade" in Single
   string            Label() const { return (hasCfg && cfg.mode == GC_CYCLE) ? "C" + IntegerToString(cycle_no) + "." + IntegerToString(leg) : "Trade"; }

   int               Digits_() const { return spec.digits > 0 ? spec.digits : 2; }
   string            Px(const double p) const { return p <= 0 ? "none" : DoubleToString(p, 2); }
   double            Rp(const double p) const { return NormalizeDouble(p, Digits_()); }
   double            Rp0(const double p) const { return p <= 0 ? 0 : Rp(p); }

private:
   void              Say(const string msg, const string level = "info", const bool toast = false)
     {
      m_sink.Event(level, "[" + (mode == GC_CYCLE ? "Cycle" : "Single") + "] " + msg, toast);
     }
   // errors that repeat every second (rejected order or close): a new problem shows at once, the same one is
   // repeated rarely, so the screen is not flooded while the bot keeps retrying
   void              Warn_(const string msg)
     {
      ulong t = m_b.Ms();
      bool fresh = msg != m_lastWarn;
      if(!fresh && t - m_lastWarnAt < GC_WARN_REPEAT_MS)
         return;
      bool pop = fresh || t - m_lastPopAt >= GC_POPUP_REPEAT_MS;
      m_lastWarn = msg;
      m_lastWarnAt = t;
      if(pop)
         m_lastPopAt = t;
      Say(msg, "error", pop);
     }
   void              SetState(const int s, const string msg, const string level = "info", const bool toast = false)
     {
      state = s;
      if(s != GCS_ARMED)
         waiting = "";
      dirty = true;
      Say(msg, level, toast);
     }
   void              Stop(const string reason, const string msg, const string level = "info")
     {
      stop_reason = reason; trigger.active = false; pending_close = CR_NONE;
      SetState(GCS_STOPPED, msg, level, true);
     }
   void              FinishSingle(const string msg, const string level = "info")
     {
      stop_reason = "COMPLETE"; trigger.active = false;
      SetState(GCS_IDLE, msg, level, true);
     }
   string            Comment_() const { return "GC|c=" + IntegerToString(cycle_no) + "." + IntegerToString(leg) + "|s=" + sid; }
   bool              IsOurs(const SPos &p) const { return sid != "" && StringFind(p.comment, "s=" + sid) >= 0; }
   int               Deviation()
     {
      double slip = hasCfg ? cfg.max_slippage : 0.5;
      double point = spec.point > 0 ? spec.point : 0.001;
      return (int)MathMax(1.0, MathRound(slip * GC_POINT_SIZE / point));
     }
   // TP / SL of the current order; 0 = not set
   void              LevelsFor(const double entry, double &tp, double &sl) const
     {
      if(cfg.mode == GC_CYCLE && leg == 2)
        {
         tp = 0; sl = prev_entry;
         return;
        }
      tp = cfg.tp_points > 0 ? GcTpPrice(entry, cfg.dir, cfg.tp_points) : 0;
      sl = (cfg.mode == GC_CYCLE || cfg.sl_points <= 0) ? 0 : GcSlPrice(entry, cfg.dir, cfg.sl_points);
     }
   bool              FindPos(const ulong ticket, SPos &out)
     {
      SPos list[];
      int n = m_b.Positions(magic, list);
      for(int i = 0; i < n; i++)
         if(list[i].ticket == ticket)
           {
            out = list[i];
            return true;
           }
      return false;
     }
   void              AddRow(const SRow &r)
     {
      int n = ArraySize(rows);
      if(n >= GC_MAX_ROWS)
        {
         for(int i = 1; i < n; i++)
            rows[i - 1] = rows[i];
         n--;
        }
      ArrayResize(rows, n + 1);
      rows[n] = r;
      m_curRow = n;
     }

public:
   //--- next planned entry for the chart line; 0 = none
   double            NextPlannedEntry() const
     {
      if(!hasCfg || cfg.mode != GC_CYCLE || !Active() || planned <= 0)
         return 0;
      if(leg == 2)   // order 2 has no TP; after its SL the next cycle restarts at the cycle entry (+ gap)
         return GcReentryAfterSl(prev_entry > 0 ? prev_entry : planned, cfg.dir, cfg.gap);
      if(cur_tp > 0)
         return cur_tp;
      double tp, sl;
      LevelsFor(planned, tp, sl);
      return tp;
     }

   //------------------------------------------------------------------ actions
   bool              Arm(const SConfig &input_cfg, string &err)
     {
      SConfig c;
      c = input_cfg;
      if(c.mode != mode)
        { err = "Wrong bot for this configuration"; return false; }
      if(Active())
        { err = "Bot is already running: stop it first"; return false; }
      if(!m_b.Connected())
        { err = "MetaTrader is not connected"; return false; }
      string block = m_b.TradeBlockReason();
      if(block != "")
        { err = block; return false; }
      if(m_sink.BlockDay() == m_b.Day())
        { err = "Daily loss limit was hit today: no new trades until tomorrow"; return false; }
      if(!m_b.Spec(spec))
        { err = "Symbol information not available"; return false; }
      if(hasPos && hasCfg && !resumable)   // a trade left open earlier may have closed this very moment
        {
         SPos still;
         STick now_tick;
         if(!FindPos(pos.ticket, still) && m_b.Tick(now_tick))
           {
            m_resolveStarted = m_b.Ms();
            int r; string text; double px, pnl;
            if(RecordClose(now_tick, r, text, px, pnl))
               Say(text + " (closed after the bot stopped)", "info");
           }
        }
      SPos existing[];
      if(m_b.Positions(magic, existing) > 0)
        { err = "A bot position is still open (#" + IntegerToString((long)existing[0].ticket) + "). Close it before arming."; return false; }
      STick tick;
      if(!m_b.Tick(tick))
        { err = "No price available"; return false; }
      if(c.enter_now)   // plan from the live price, not the form's trigger
        {
         c.trigger = GcTriggerPrice(tick, c.trigger_side);
         string bad = GcNormalizeConfig(c);
         if(bad != "")
           { err = "Enter now at " + DoubleToString(c.trigger, 2) + ": " + bad; return false; }
        }
      else
        {
         string bad = GcNormalizeConfig(c);
         if(bad != "")
           { err = bad; return false; }
        }
      string errors[], warnings[];
      GcValidate(c, spec, tick, true, errors, warnings);
      if(ArraySize(errors) > 0)
        { err = errors[0]; return false; }

      Reset();
      cfg = c; hasCfg = true;
      sid = StringFormat("%04x%04x", MathRand(), (int)(m_b.Ms() % 65536));
      cycle_no = 1;
      planned = cfg.trigger;
      lastTick = tick; haveTick = true;
      string what = "lot " + GcNum(cfg.lot) + ", TP " + GcOpt(cfg.tp_points)
                    + (cfg.mode == GC_CYCLE ? ", order 1 no SL, order 2 SL at entry, gap " + (cfg.gap > 0 ? GcNum(cfg.gap) : "blank")
                       + ", stop " + GcOpt(cfg.stop_price) : ", SL " + GcOpt(cfg.sl_points));
      if(cfg.enter_now)
        {
         SetState(GCS_OPENING, GcModeName(cfg.mode) + " " + GcDirName(cfg.dir) + " now at market (~" + Px(cfg.trigger) + "), " + what);
         OnOpening(tick);
         return true;
        }
      ArmTrigger(tick);
      SetState(GCS_ARMED, GcModeName(cfg.mode) + " " + GcDirName(cfg.dir) + " armed: " + Label() + " at " + Px(cfg.trigger) + ", " + what, "info", true);
      return true;
     }

private:
   void              ArmTrigger(const STick &tick)
     {
      GcTriggerArm(trigger, planned, GcTriggerPrice(tick, cfg.trigger_side));
      UpdateWaiting();
     }
   void              UpdateWaiting()
     {
      if(!trigger.active)
         return;
      string verb = (trigger.side == 0 || cycle_no == 1) ? "return to" : "touch";
      waiting = "Waiting for price to " + verb + " " + Px(trigger.level);
     }

public:
   bool              StopNow(string &err)
     {
      bool single_open = hasCfg && cfg.mode == GC_SINGLE && hasPos;
      if(single_open && (state == GCS_IN_POSITION || state == GCS_STOPPED) && pending_close == CR_NONE)
        {
         // SINGLE: Stop = "Close trade" at market; retried every tick until it is closed
         pending_close = CR_CLOSED;
         Say("Closing " + Label() + " #" + IntegerToString((long)pos.ticket) + " at market", "info", true);
         TryCloseTracked();
         dirty = true;
         return true;
        }
      if(!Active())
        { err = "Bot is not running"; return false; }
      string note = hasPos ? "; position #" + IntegerToString((long)pos.ticket) + " stays open with its TP/SL on the broker" : "";
      Stop("MANUAL_STOP", "Stopped by trader" + note);
      return true;
     }

   bool              StopAfterCycle(string &err)
     {
      if(!Active())
        { err = "Bot is not running"; return false; }
      if(state == GCS_ARMED)
        {
         Stop("STOP_AFTER_CYCLE", "Stopped by trader (no cycle in progress)");
         return true;
        }
      stop_after = true;
      dirty = true;
      string when = Label() + " closes";
      if(hasCfg && cfg.mode == GC_CYCLE && leg == 1)
         when = "cycle " + IntegerToString(cycle_no) + " ends (order 2 still opens on order 1's TP)";
      Say("Will stop after " + when, "info", true);
      return true;
     }

private:
   // a TP/SL for the open trade must be on the right side of the price it closes at (+ broker stops/freeze level)
   bool              CheckOpenLevels(const double tp, const double sl, const STick &tick, string &err)
     {
      bool buy = cfg.dir == GC_BUY;
      int side = buy ? 1 : -1;
      double px = buy ? tick.bid : tick.ask;
      double gap = MathMax(spec.stops_level, spec.freeze_level) * spec.point;
      string note = gap > 0 ? " by at least " + GcNum(gap) + " pts" : "";
      if(tp > 0 && side * (tp - px) <= gap)
        { err = "TP " + Px(tp) + " must be " + (buy ? "above" : "below") + " the price " + Px(px) + note; return false; }
      if(sl > 0 && side * (px - sl) <= gap)
        { err = "SL " + Px(sl) + " must be " + (buy ? "below" : "above") + " the price " + Px(px) + note; return false; }
      return true;
     }
   void              UpdateRowLevels()
     {
      if(m_curRow >= 0 && m_curRow < ArraySize(rows))
        {
         rows[m_curRow].tp = cur_tp;
         rows[m_curRow].sl = cur_sl;
        }
     }
   // the trader dragged / removed TP or SL on the chart in MetaTrader: the trade is the truth
   void              SyncLevels(const SPos &live)
     {
      double tol = spec.point > 0 ? spec.point / 2 : 0.0001;
      if(MathAbs(live.tp - cur_tp) <= tol && MathAbs(live.sl - cur_sl) <= tol)
         return;
      cur_tp = live.tp; cur_sl = live.sl; pos.tp = live.tp; pos.sl = live.sl;
      UpdateRowLevels();
      dirty = true;
      Say(Label() + " #" + IntegerToString((long)pos.ticket) + " TP/SL changed on the trade: TP " + Px(cur_tp) + ", SL " + Px(cur_sl));
     }

public:
   //--- set, move or remove the open trade's TP/SL (0 = none)
   bool              ModifyLevels(double tp, double sl, string &err)
     {
      bool holding = state == GCS_IN_POSITION || state == GCS_STOPPED;
      if(!hasCfg || !hasPos || pending_close != CR_NONE || !holding)
        { err = "No open trade to change"; return false; }
      tp = Rp0(tp); sl = Rp0(sl);
      if(MathAbs(tp - cur_tp) < GC_EPS && MathAbs(sl - cur_sl) < GC_EPS)
         return true;   // MT5 rejects a change with no changes
      STick tick;
      if(!m_b.Tick(tick))
        { err = "No price available"; return false; }
      if(!CheckOpenLevels(tp, sl, tick, err))
         return false;
      SOrderResult res;
      m_b.ModifyPosition(pos.ticket, sl, tp, res);
      if(!res.ok)
        { err = "Broker refused the TP/SL change: " + res.message + " (" + IntegerToString((int)res.retcode) + ")"; return false; }
      cur_tp = tp; cur_sl = sl; pos.tp = tp; pos.sl = sl;
      UpdateRowLevels();
      dirty = true;
      Say(Label() + " #" + IntegerToString((long)pos.ticket) + " TP/SL changed: TP " + Px(tp) + ", SL " + Px(sl), "info", true);
      return true;
     }

private:
   void              Diff(string &list, const string label, const string a, const string b)
     {
      if(a != b)
         list += (list == "" ? "" : ", ") + label + " " + a + " -> " + b;
     }

public:
   //--- CYCLE: change a running cycle's settings without stopping it. Refused changes leave everything as it was.
   bool              UpdateConfig(const SConfig &input_cfg, string &err)
     {
      if(!hasCfg || cfg.mode != GC_CYCLE || !Active())
        { err = "No running cycle to change"; return false; }
      SConfig n;
      n = input_cfg;
      string bad = GcNormalizeConfig(n);
      if(bad != "")
        { err = bad; return false; }
      if(n.mode != GC_CYCLE)
        { err = "Wrong bot for this configuration"; return false; }
      if(n.dir != cfg.dir)
        { err = "Direction can't change on a running cycle: stop it and arm again"; return false; }
      string ch = "";
      Diff(ch, "trigger", GcNum(cfg.trigger), GcNum(n.trigger));
      Diff(ch, "lot", GcNum(cfg.lot), GcNum(n.lot));
      Diff(ch, "TP pts", GcOpt(cfg.tp_points), GcOpt(n.tp_points));
      Diff(ch, "gap", GcOpt(cfg.gap), GcOpt(n.gap));
      Diff(ch, "stop price", GcOpt(cfg.stop_price), GcOpt(n.stop_price));
      Diff(ch, "max cycles", GcOpt(cfg.max_cycles), GcOpt(n.max_cycles));
      Diff(ch, "daily loss limit", GcOpt(cfg.daily_loss), GcOpt(n.daily_loss));
      Diff(ch, "max spread", GcOpt(cfg.max_spread), GcOpt(n.max_spread));
      Diff(ch, "max slippage", GcNum(cfg.max_slippage), GcNum(n.max_slippage));
      Diff(ch, "trading hours", cfg.hours == "" ? "none" : cfg.hours, n.hours == "" ? "none" : n.hours);
      Diff(ch, "levels from", IntegerToString(cfg.anchor), IntegerToString(n.anchor));
      Diff(ch, "trigger on", IntegerToString(cfg.trigger_side), IntegerToString(n.trigger_side));
      if(ch == "")
         return true;
      bool waiting1 = state == GCS_ARMED && leg == 1;
      bool trigger_moved = MathAbs(n.trigger - cfg.trigger) > GC_EPS;
      if(trigger_moved && !waiting1)
        { err = "The trigger price can only change while the bot waits for order 1"; return false; }
      STick tick;
      if(!m_b.Tick(tick))
        { err = "No price available"; return false; }
      string errors[], warnings[];
      GcValidate(n, spec, tick, true, errors, warnings);
      if(ArraySize(errors) > 0)
        { err = errors[0]; return false; }
      bool stop_moved = MathAbs(n.stop_price - cfg.stop_price) > GC_EPS || trigger_moved;
      if(stop_moved && GcStopReached(tick, n))
        { err = "Price is already at/beyond the stop price " + GcNum(n.stop_price) + ". Use Stop now or Close all for that"; return false; }

      double rearm = 0;   // new level for the order 1 the bot is waiting for
      if(waiting1 && trigger_moved)
         rearm = n.trigger;
      else if(waiting1 && MathAbs(n.gap - cfg.gap) > GC_EPS && cycle_no > 1)
        {
         double d = GcSign(cfg.dir) * cfg.gap * GC_POINT_SIZE;   // planned = previous cycle entry + old gap
         rearm = GcReentryAfterSl(planned - d, n.dir, n.gap);
        }
      if(rearm > 0 && cycles_opened > 0 && GcBeyondStop(rearm, n))
        { err = "New entry " + Px(rearm) + " is at/beyond the stop price " + GcNum(n.stop_price); return false; }

      double new_tp = 0;   // open order 1's TP, moved on the broker
      if(MathAbs(n.tp_points - cfg.tp_points) > GC_EPS && state == GCS_IN_POSITION && leg == 1)
        {
         if(pending_close != CR_NONE)
           { err = Label() + " is being closed: TP can't change now"; return false; }
         new_tp = Rp(GcTpPrice(anchor, n.dir, n.tp_points));
         if(MathAbs(new_tp - cur_tp) < GC_EPS)
            new_tp = 0;
         else
           {
            if(!CheckOpenLevels(new_tp, 0, tick, err))
               return false;
            SOrderResult res;
            m_b.ModifyPosition(pos.ticket, cur_sl, new_tp, res);
            if(!res.ok)
              { err = "Broker refused the new TP " + Px(new_tp) + ": " + res.message; return false; }
           }
        }

      cfg = n;
      string note = "";
      if(new_tp > 0)
        {
         cur_tp = new_tp; pos.tp = new_tp;
         UpdateRowLevels();
         note = "; " + Label() + " TP moved to " + Px(new_tp);
        }
      if(rearm > 0)
        {
         planned = rearm;
         ArmTrigger(tick);
         note = "; " + Label() + " now waits at " + Px(rearm);
        }
      dirty = true;
      Say("Cycle settings changed: " + ch + note, "info", true);
      return true;
     }

   //--- kill switch: close every position of this bot, then stop
   void              CloseAllAndStop()
     {
      if(!m_b.Spec(spec))
        {
         Say("Close all: MetaTrader gave no symbol information. Close the trades by hand", "error", true);
         return;
        }
      SPos list[];
      int n = m_b.Positions(magic, list);
      ulong tracked = hasPos ? pos.ticket : 0;
      if(tracked != 0 && !Active())
         pending_close = CR_KILL_SWITCH;   // left open by "Stop now": journal it as KILL_SWITCH
      string failures = "";
      for(int i = 0; i < n; i++)
        {
         if(list[i].ticket == tracked && state == GCS_IN_POSITION)
            continue;   // closed (with retries) by the engine loop
         SOrderResult res;
         for(int a = 0; a < 3; a++)
           {
            m_b.ClosePosition(list[i], Deviation(), res);
            if(res.ok)
               break;
            if(a < 2)
               m_b.Pause(300);
           }
         if(!res.ok)
            failures += " #" + IntegerToString((long)list[i].ticket) + ": " + res.message;
        }
      if(failures != "")
         Say("Close all: could not close" + failures, "error", true);
      dirty = true;
      if(tracked != 0 && state == GCS_IN_POSITION)
        {
         pending_close = CR_KILL_SWITCH;
         Say("Close all: closing " + Label() + " #" + IntegerToString((long)tracked), "warn", true);
         TryCloseTracked();
        }
      else if(state == GCS_RESOLVING)
        {
         pending_close = CR_KILL_SWITCH;   // record the order that just closed, then stop
         Say("Close all: stopping after the closing " + Label() + " is recorded", "warn", true);
        }
      else if(Active())
         Stop("KILL_SWITCH", "Close all: bot positions closed, bot stopped", "warn");
      else
         Say("Close all: bot positions closed", "warn", true);
     }

   bool              Resume(string &err)
     {
      if(!resumable || !hasCfg)
        { err = "Nothing to resume"; return false; }
      STick tick;
      if(!m_b.Connected() || !m_b.Tick(tick) || !m_b.Spec(spec))
        { err = "MetaTrader is not connected yet"; return false; }
      lastTick = tick; haveTick = true;
      int target = resume_state;
      resumable = false; resume_state = GCS_IDLE; stop_reason = "";
      SPos list[];
      int n = m_b.Positions(magic, list);
      if(hasPos)
        {
         SPos live;
         if(FindPos(pos.ticket, live))
            SetState(GCS_IN_POSITION, "Resumed: reattached to " + Label() + " #" + IntegerToString((long)live.ticket), "info", true);
         else
           {
            m_resolveStarted = m_b.Ms();
            SetState(GCS_RESOLVING, "Resumed: " + Label() + " closed while the bot was off, reading the result", "info", true);
            OnResolving(tick);
           }
         return true;
        }
      for(int i = 0; i < n; i++)
         if(IsOurs(list[i]))   // the order went through just before the restart
           {
            Attach(list[i]);
            return true;
           }
      if(n > 0)
        {
         Stop("DUPLICATE_GUARD", "Another bot position #" + IntegerToString((long)list[0].ticket) + " is open: not resuming", "error");
         return true;
        }
      if(target == GCS_OPENING && cfg.mode == GC_CYCLE && leg == 2)
        {
         // order 2 never waits for a touch: carry on opening (the next step first checks the stop price and limits)
         m_lastAttempt = 0;
         SetState(GCS_OPENING, "Resumed: " + Label() + " opening at market now (SL " + Px(prev_entry) + ", no TP)", "info", true);
         return true;
        }
      ArmTrigger(tick);
      SetState(GCS_ARMED, "Resumed (" + GcStateName(target) + "): " + Label() + " armed at " + Px(planned), "info", true);
      return true;
     }

   //--- after loading a saved state: a running bot asks "Resume?" (or resumes at once)
   void              Recover(const bool auto_resume)
     {
      if(!hasCfg)
         return;
      int was = resumable ? resume_state : state;
      if(was == GCS_IDLE || was == GCS_STOPPED)
        {
         resumable = false;
         return;
        }
      resumable = true;
      resume_state = was;
      if(auto_resume)
        {
         string err = "";
         if(Resume(err))
            return;
         Say("Could not resume yet: " + err, "warn", true);
        }
      stop_reason = "RESTART";
      SetState(GCS_STOPPED, "Restarted while " + GcStateName(was) + " (" + Label() + "). Press Resume to continue", "warn", true);
     }

   //------------------------------------------------------------------ one tick
   void              Step()
     {
      STick tick;
      bool ok = m_b.Connected() && m_b.Tick(tick);
      if(!ok)
        {
         if(connected)
           {
            connected = false;
            Say("Disconnected from the broker: bot paused, no new orders", "error", true);
           }
         return;
        }
      if(!connected)
        {
         connected = true;
         Say("Connected again: checking positions", "info", true);
        }
      lastTick = tick; haveTick = true;
      if(!m_b.Spec(spec))
         return;
      if(Active())
         Process(tick);
      else if(hasPos && hasCfg && !resumable)
         WatchLeftOpen(tick);
     }

private:
   void              Process(const STick &tick)
     {
      if(cfg.daily_loss > 0 && pending_close == CR_NONE)
        {
         double open_now = 0;
         SPos list[];
         int n = m_b.Positions(magic, list);
         for(int i = 0; i < n; i++)
            open_now += list[i].profit;
         double today = m_b.RealizedToday(magic, otherMagic) + open_now;
         if(GcDailyLossHit(today, cfg.daily_loss))
           {
            m_sink.SetBlockDay(m_b.Day());
            string msg = "Daily loss limit " + GcNum(cfg.daily_loss) + " hit (today " + DoubleToString(today, 2) + ")";
            if(state == GCS_IN_POSITION)
              {
               pending_close = CR_DAILY_LOSS;
               Say(msg + ": closing " + Label(), "error", true);
              }
            else if(state != GCS_RESOLVING)
              {
               Stop("DAILY_LOSS", msg + ": bot stopped", "error");
               return;
              }
           }
        }
      // the limit may have been hit by the other bot: "stop all and no new trades for the day"
      if(pending_close == CR_NONE && m_sink.BlockDay() == m_b.Day())
        {
         if(state == GCS_IN_POSITION)
           {
            pending_close = CR_DAILY_LOSS;
            dirty = true;
            Say("Daily loss limit hit today: closing " + Label(), "error", true);
           }
         else if(state != GCS_RESOLVING)
           {
            Stop("DAILY_LOSS", "Daily loss limit hit today: bot stopped, no new trades until tomorrow", "error");
            return;
           }
        }
      if(cycles_opened > 0 && pending_close == CR_NONE && GcStopReached(tick, cfg))
        {
         if(state == GCS_IN_POSITION)
           {
            pending_close = CR_STOP_PRICE;
            dirty = true;
            Say("Stop price " + GcNum(cfg.stop_price) + " reached: closing " + Label(), "warn", true);
           }
         else if(state == GCS_ARMED || state == GCS_OPENING)
           {
            Stop("STOP_PRICE", "Stop price " + GcNum(cfg.stop_price) + " reached: bot stopped");
            return;
           }
        }
      if(state == GCS_ARMED)
         OnArmed(tick);
      else if(state == GCS_OPENING)
         OnOpening(tick);
      else if(state == GCS_IN_POSITION)
         OnInPosition(tick);
      else if(state == GCS_RESOLVING)
         OnResolving(tick);
     }

   void              OnArmed(const STick &tick)
     {
      double price = GcTriggerPrice(tick, cfg.trigger_side);
      if(GcTriggerUpdate(trigger, price))
        {
         SetState(GCS_OPENING, Label() + " trigger " + Px(trigger.level) + " touched (" + Px(price) + ")");
         trigger.active = false;
         OnOpening(tick);
        }
      else
         UpdateWaiting();
     }

   void              SetWaiting(const string msg)
     {
      if(waiting != msg)
        {
         waiting = msg;
         Say(Label() + ": " + msg, "warn");
        }
     }

   void              OnOpening(const STick &tick)
     {
      if(m_sink.BlockDay() == m_b.Day())
        {
         Stop("DAILY_LOSS", Label() + " not opened: the daily loss limit was hit today", "error");
         return;
        }
      double price = GcTriggerPrice(tick, cfg.trigger_side);
      // CYCLE order 2 (critical): opens at once when order 1 hits TP, whatever the price did (jump, wide spread,
      // trading hours). It never goes back to "wait for a touch". A rejected order is retried every second.
      bool order2 = cfg.mode == GC_CYCLE && leg == 2;
      if(!order2 && !GcWithinSlippage(price, planned, cfg.max_slippage))
        {
         ArmTrigger(tick);
         SetState(GCS_ARMED, Label() + ": price " + Px(price) + " is more than " + GcNum(cfg.max_slippage) + " pts from " + Px(planned) + ", waiting for another touch", "warn");
         return;
        }
      if(!order2 && !GcSpreadOk(tick, cfg.max_spread))
        {
         SetWaiting("spread wider than max " + GcNum(cfg.max_spread) + " pts, waiting to open");
         return;
        }
      if(!order2 && !GcInTradingHours(m_b.LocalMinutes(), cfg.hours))
        {
         SetWaiting("outside trading hours " + cfg.hours + ", waiting to open");
         return;
        }
      ulong now = m_b.Ms();
      if(m_lastAttempt != 0 && now - m_lastAttempt < GC_ORDER_RETRY_MS)
         return;
      m_lastAttempt = now;
      waiting = "";
      SPos existing[];   // never open while any position of this bot exists
      int n = m_b.Positions(magic, existing);
      if(n > 0)
        {
         for(int i = 0; i < n; i++)
            if(IsOurs(existing[i]))
              {
               Attach(existing[i]);
               return;
              }
         Stop("DUPLICATE_GUARD", "Bot position #" + IntegerToString((long)existing[0].ticket) + " already open: refusing to open another", "error");
         return;
        }
      double tp, sl;
      LevelsFor(planned, tp, sl);
      double volume = GcRoundVolume(GcLotForCycle(cfg.lot, cfg.lot_mult, cycle_no), spec.vol_step);
      SOrderResult res;
      m_b.OpenMarket(cfg.dir, volume, Rp0(sl), Rp0(tp), Deviation(), magic, Comment_(), res);
      if(res.ok && res.ticket != 0)
         OnFilled(res.ticket, res.price > 0 ? res.price : planned, tp, sl, volume);
      else if(res.fatal)
         Stop("ORDER_ERROR", Label() + " order failed: " + res.message + " (" + IntegerToString((int)res.retcode) + ")", "error");
      else
         Warn_(Label() + " order rejected: " + res.message + " (" + IntegerToString((int)res.retcode) + "), retrying");
     }

   double            Slip(const double fill) const { return NormalizeDouble(GcSign(cfg.dir) * (fill - planned) / GC_POINT_SIZE, 2); }

   void              NewRow(const ulong ticket, const double fill, const double volume, const double tp, const double sl, const datetime when)
     {
      SRow r;
      r.ticket = ticket; r.cycle = cycle_no; r.leg = leg; r.dir = cfg.dir; r.volume = volume; r.planned = planned;
      r.fill = fill; r.slippage = Slip(fill); r.tp = tp; r.sl = sl; r.open_time = when; r.close_time = 0;
      r.close_price = 0; r.reason = CR_NONE; r.pnl = 0;
      AddRow(r);
     }

   void              OnFilled(const ulong ticket, const double fill, double tp, double sl, const double volume)
     {
      anchor = planned;
      if(cfg.anchor == ANCHOR_FILL)
        {
         anchor = fill;
         double sent_tp = Rp0(tp), sent_sl = Rp0(sl);
         LevelsFor(fill, tp, sl);
         // skip when nothing moves: MT5 rejects a change with no changes
         if(MathAbs(Rp0(tp) - sent_tp) > GC_EPS || MathAbs(Rp0(sl) - sent_sl) > GC_EPS)
           {
            SOrderResult res;
            m_b.ModifyPosition(ticket, Rp0(sl), Rp0(tp), res);
            if(!res.ok)
              {
               Say(Label() + ": could not move TP/SL to fill-based levels (" + res.message + "); planned TP/SL stay on the trade", "error", true);
               anchor = planned;
               LevelsFor(planned, tp, sl);
              }
           }
        }
      cur_tp = Rp0(tp); cur_sl = Rp0(sl);
      hasPos = true; ZeroPos();
      pos.ticket = ticket; pos.dir = cfg.dir; pos.volume = volume; pos.price_open = fill; pos.tp = cur_tp; pos.sl = cur_sl;
      pos.magic = magic; pos.time = m_b.Now();
      m_openedMs = m_b.Ms();
      floating = 0;
      cycles_opened++;
      NewRow(ticket, fill, volume, cur_tp, cur_sl, pos.time);
      SetState(GCS_IN_POSITION, Label() + " filled " + GcDirName(cfg.dir) + " " + GcNum(volume) + " @ " + Px(fill) + " (planned " + Px(planned)
               + ", slip " + DoubleToString(Slip(fill), 2) + ") TP " + Px(cur_tp) + " SL " + Px(cur_sl), "info", true);
     }

   // adopt a live position of this session (order filled but the answer was lost / restart)
   void              Attach(const SPos &p)
     {
      anchor = planned;
      cur_tp = p.tp; cur_sl = p.sl;
      hasPos = true; pos = p;
      m_openedMs = m_b.Ms();
      cycles_opened++;
      NewRow(p.ticket, p.price_open, p.volume, p.tp, p.sl, p.time);
      SetState(GCS_IN_POSITION, Label() + ": attached to existing position #" + IntegerToString((long)p.ticket), "warn");
     }

   void              TryCloseTracked()
     {
      SPos live;
      if(!FindPos(pos.ticket, live))
         return;   // already gone: resolving picks it up
      SOrderResult res;
      m_b.ClosePosition(live, Deviation(), res);
      if(!res.ok)
         Warn_("Close of " + Label() + " #" + IntegerToString((long)live.ticket) + " (" + GcReasonName(pending_close) + ") rejected: " + res.message + ", retrying");
     }

   void              OnInPosition(const STick &tick)
     {
      SPos live;
      if(!FindPos(pos.ticket, live))
        {
         SCloseInfo peek;
         if(!m_b.CloseInfo(pos.ticket, peek) && m_b.Ms() - m_openedMs < 3000)
            return;   // just opened and not listed yet
         m_resolveStarted = m_b.Ms();
         SetState(GCS_RESOLVING, Label() + " #" + IntegerToString((long)pos.ticket) + " closed, reading the result");
         OnResolving(tick);
         return;
        }
      floating = live.profit;
      if(pending_close == CR_NONE)
         SyncLevels(live);
      else
         TryCloseTracked();
     }

   int               Classify(const bool have, const SCloseInfo &info) const
     {
      if(pending_close != CR_NONE)
         return pending_close;
      if(!have)
         return CR_UNKNOWN;
      if(info.reason == DL_TP)
         return CR_TP;
      if(info.reason == DL_SL)
         return CR_SL;
      if(info.reason == DL_CLIENT)
         return CR_MANUAL;
      if(info.reason == DL_STOP_OUT)
         return CR_STOP_OUT;
      double tol = MathMax(hasCfg ? cfg.max_slippage : 0.5, 0.5);   // closed by another program: infer from the price
      if(cur_tp > 0 && MathAbs(info.price - cur_tp) <= tol)
         return CR_TP;
      if(cur_sl > 0 && MathAbs(info.price - cur_sl) <= tol)
         return CR_SL;
      return CR_UNKNOWN;
     }

   // write the closed position's result to the journal. false = not in history yet (try next tick)
   bool              RecordClose(const STick &tick, int &reason, string &text, double &price, double &pnl)
     {
      SCloseInfo info;
      info.reason = DL_OTHER; info.price = 0; info.profit = 0; info.time = 0;
      bool have = m_b.CloseInfo(pos.ticket, info);
      if(!have && m_b.Ms() - m_resolveStarted < GC_RESOLVE_TIMEOUT_MS)
         return false;
      reason = Classify(have, info);   // drives what happens next (a requested close always wins)
      int shown = reason;   // journal what really closed it: TP/SL may have hit on the same tick the bot asked to close
      if(pending_close != CR_NONE && have && (info.reason == DL_TP || info.reason == DL_SL))
         shown = info.reason == DL_TP ? CR_TP : CR_SL;
      price = have ? info.price : (cfg.dir == GC_BUY ? tick.bid : tick.ask);
      pnl = have ? info.profit : 0;
      if(!have)
         Say(Label() + ": closing deal not found in history, P/L unknown", "error", true);
      if(m_curRow >= 0 && m_curRow < ArraySize(rows) && rows[m_curRow].ticket == pos.ticket)
        {
         rows[m_curRow].close_time = have ? info.time : m_b.Now();
         rows[m_curRow].close_price = price;
         rows[m_curRow].reason = shown;
         rows[m_curRow].pnl = pnl;
         m_sink.Closed(rows[m_curRow], mode, sid);
        }
      session_pnl += pnl;
      floating = 0;
      hasPos = false;
      pending_close = CR_NONE;
      dirty = true;
      text = Label() + " " + GcReasonName(shown) + (shown == reason ? "" : " (" + GcReasonName(reason) + ")") + " at " + Px(price) + " "
             + (pnl >= 0 ? "+" : "") + DoubleToString(pnl, 2);
      return true;
     }

   // stopped with a trade still open: never trades, only keeps its journal row honest when it closes later
   void              WatchLeftOpen(const STick &tick)
     {
      SPos live;
      if(FindPos(pos.ticket, live))
        {
         m_resolveStarted = 0;
         floating = live.profit;
         if(pending_close != CR_NONE)
            TryCloseTracked();
         else
            SyncLevels(live);
         return;
        }
      if(m_resolveStarted == 0)
         m_resolveStarted = m_b.Ms();
      int reason; string text; double price, pnl;
      if(RecordClose(tick, reason, text, price, pnl))
        {
         m_resolveStarted = 0;
         Say(text + " (closed after the bot stopped)", "info", true);
        }
     }

   void              OnResolving(const STick &tick)
     {
      SPos live;
      if(FindPos(pos.ticket, live))   // it was only missing for a moment
        {
         SetState(GCS_IN_POSITION, Label() + " #" + IntegerToString((long)pos.ticket) + " is still open");
         return;
        }
      int reason; string text; double price, pnl;
      if(!RecordClose(tick, reason, text, price, pnl))
         return;
      string n = Label();
      if(reason == CR_TP)
        {
         if(cfg.mode == GC_SINGLE)
            FinishSingle(text + ", single trade complete");
         else
           {
            Say(text, "info", true);
            StartNextCycle(tick, false);
           }
        }
      else if(reason == CR_SL)
        {
         if(cfg.mode == GC_SINGLE)
            FinishSingle(text + ", single trade complete", "warn");
         else
           {
            Say(n + " hit SL at " + Px(price) + " (" + DoubleToString(pnl, 2) + ")", "warn", true);
            StartNextCycle(tick, true);
           }
        }
      else if(reason == CR_MANUAL)
         Stop("MANUAL_CLOSE", n + " was closed manually in MetaTrader (" + DoubleToString(pnl, 2) + "): bot stopped", "warn");
      else if(reason == CR_CLOSED)
         FinishSingle(text + ", closed by trader");
      else if(reason == CR_STOP_PRICE || reason == CR_KILL_SWITCH || reason == CR_DAILY_LOSS)
         Stop(GcReasonName(reason), text + ": bot stopped", "warn");
      else
         Stop(GcReasonName(reason), text + ": unexpected close, bot stopped", "error");
     }

   // order 1 hit TP -> order 2 opens at once at that TP, SL at order 1's entry, no TP.
   // order 2 hit SL -> the cycle is over; the next one waits for price to touch the cycle entry (+ gap).
   void              StartNextCycle(const STick &tick, const bool after_sl)
     {
      string label = Label();
      int n = cycle_no;
      bool over = leg == 2 || after_sl;   // after_sl on order 1 = an SL someone added in MetaTrader
      if(stop_after && over)
        {
         // a cycle is both orders: "Stop after this cycle" during order 1 still opens order 2 and stops after it
         Stop("STOP_AFTER_CYCLE", "Stopped after " + label + " as requested");
         return;
        }
      double nxt;
      if(over)
        {
         if(cfg.max_cycles > 0 && n >= cfg.max_cycles)
           {
            Stop("MAX_CYCLES", "Max cycles (" + IntegerToString(cfg.max_cycles) + ") reached: bot stopped");
            return;
           }
         double cycle_entry = (leg == 2 && prev_entry > 0) ? prev_entry : anchor;
         nxt = GcReentryAfterSl(cycle_entry, cfg.dir, cfg.gap);
        }
      else
         nxt = cur_tp > 0 ? cur_tp : GcTpPrice(anchor, cfg.dir, cfg.tp_points);
      if(GcBeyondStop(nxt, cfg))
        {
         Stop("STOP_PRICE", "Next entry " + Px(nxt) + " is at/beyond stop price " + GcNum(cfg.stop_price) + ": bot stopped");
         return;
        }
      if(over)
        { cycle_no = n + 1; leg = 1; prev_entry = 0; }
      else
        { leg = 2; prev_entry = anchor; }
      planned = nxt; anchor = 0; cur_tp = 0; cur_sl = 0; m_curRow = -1; m_lastAttempt = 0;
      if(!over)
        {
         SetState(GCS_OPENING, Label() + " opening at market (planned " + Px(nxt) + ", SL " + Px(prev_entry) + ", no TP)");
         OnOpening(tick);
        }
      else
        {
         ArmTrigger(tick);
         SetState(GCS_ARMED, Label() + " armed at " + Px(nxt));
        }
     }

   //------------------------------------------------------------------ save / load
   void              Put(string &out[], const string k, const string v) { GcAdd(out, k + "=" + v); }
   void              PutD(string &out[], const string k, const double v) { Put(out, k, DoubleToString(v, 8)); }
   void              PutI(string &out[], const string k, const long v) { Put(out, k, IntegerToString(v)); }
   static string     Get(const string &src[], const string k, const string def = "")
     {
      for(int i = 0; i < ArraySize(src); i++)
         if(StringFind(src[i], k + "=") == 0)
            return StringSubstr(src[i], StringLen(k) + 1);
      return def;
     }
   static double     GetD(const string &src[], const string k) { return StringToDouble(Get(src, k, "0")); }
   static long       GetI(const string &src[], const string k) { return StringToInteger(Get(src, k, "0")); }

public:
   void              Serialize(string &out[])
     {
      ArrayResize(out, 0);
      PutI(out, "state", state); PutI(out, "hasCfg", hasCfg); Put(out, "sid", sid); PutI(out, "cycle_no", cycle_no); PutI(out, "leg", leg);
      PutD(out, "planned", planned); PutD(out, "anchor", anchor); PutD(out, "prev_entry", prev_entry);
      PutD(out, "cur_tp", cur_tp); PutD(out, "cur_sl", cur_sl);
      PutI(out, "hasPos", hasPos); PutI(out, "pos.ticket", (long)pos.ticket); PutI(out, "pos.dir", pos.dir); PutD(out, "pos.volume", pos.volume);
      PutD(out, "pos.price_open", pos.price_open); PutD(out, "pos.tp", pos.tp); PutD(out, "pos.sl", pos.sl); PutI(out, "pos.time", (long)pos.time);
      PutI(out, "cycles_opened", cycles_opened); PutD(out, "session_pnl", session_pnl); PutI(out, "stop_after", stop_after);
      PutI(out, "pending_close", pending_close); Put(out, "stop_reason", stop_reason); PutI(out, "resumable", resumable); PutI(out, "resume_state", resume_state);
      PutI(out, "cfg.mode", cfg.mode); PutI(out, "cfg.dir", cfg.dir); PutD(out, "cfg.trigger", cfg.trigger); PutD(out, "cfg.lot", cfg.lot);
      PutI(out, "cfg.price_input", cfg.price_input); PutD(out, "cfg.tp_points", cfg.tp_points); PutD(out, "cfg.sl_points", cfg.sl_points);
      PutD(out, "cfg.tp_price", cfg.tp_price); PutD(out, "cfg.sl_price", cfg.sl_price); PutD(out, "cfg.gap", cfg.gap);
      PutD(out, "cfg.stop_price", cfg.stop_price); PutI(out, "cfg.enter_now", cfg.enter_now); PutI(out, "cfg.anchor", cfg.anchor);
      PutI(out, "cfg.trigger_side", cfg.trigger_side); PutD(out, "cfg.max_slippage", cfg.max_slippage); PutI(out, "cfg.max_cycles", cfg.max_cycles);
      PutD(out, "cfg.daily_loss", cfg.daily_loss); PutD(out, "cfg.max_spread", cfg.max_spread); Put(out, "cfg.hours", cfg.hours); PutD(out, "cfg.lot_mult", cfg.lot_mult);
      PutI(out, "curRow", m_curRow);
      for(int i = 0; i < ArraySize(rows); i++)
        {
         SRow r;
         r = rows[i];
         Put(out, "row", IntegerToString((long)r.ticket) + "|" + IntegerToString(r.cycle) + "|" + IntegerToString(r.leg) + "|" + IntegerToString(r.dir)
             + "|" + DoubleToString(r.volume, 8) + "|" + DoubleToString(r.planned, 8) + "|" + DoubleToString(r.fill, 8) + "|" + DoubleToString(r.slippage, 8)
             + "|" + DoubleToString(r.tp, 8) + "|" + DoubleToString(r.sl, 8) + "|" + IntegerToString((long)r.open_time) + "|" + IntegerToString((long)r.close_time)
             + "|" + DoubleToString(r.close_price, 8) + "|" + IntegerToString(r.reason) + "|" + DoubleToString(r.pnl, 8));
        }
     }

   bool              Deserialize(const string &src[])
     {
      if(Get(src, "state") == "")
         return false;
      Reset();
      state = (int)GetI(src, "state"); hasCfg = GetI(src, "hasCfg") != 0; sid = Get(src, "sid"); cycle_no = (int)GetI(src, "cycle_no"); leg = (int)GetI(src, "leg");
      planned = GetD(src, "planned"); anchor = GetD(src, "anchor"); prev_entry = GetD(src, "prev_entry"); cur_tp = GetD(src, "cur_tp"); cur_sl = GetD(src, "cur_sl");
      hasPos = GetI(src, "hasPos") != 0; pos.ticket = (ulong)GetI(src, "pos.ticket"); pos.dir = (int)GetI(src, "pos.dir"); pos.volume = GetD(src, "pos.volume");
      pos.price_open = GetD(src, "pos.price_open"); pos.tp = GetD(src, "pos.tp"); pos.sl = GetD(src, "pos.sl"); pos.time = (datetime)GetI(src, "pos.time"); pos.magic = magic;
      cycles_opened = (int)GetI(src, "cycles_opened"); session_pnl = GetD(src, "session_pnl"); stop_after = GetI(src, "stop_after") != 0;
      pending_close = (int)GetI(src, "pending_close"); stop_reason = Get(src, "stop_reason"); resumable = GetI(src, "resumable") != 0; resume_state = (int)GetI(src, "resume_state");
      cfg.mode = (int)GetI(src, "cfg.mode"); cfg.dir = (int)GetI(src, "cfg.dir"); cfg.trigger = GetD(src, "cfg.trigger"); cfg.lot = GetD(src, "cfg.lot");
      cfg.price_input = GetI(src, "cfg.price_input") != 0; cfg.tp_points = GetD(src, "cfg.tp_points"); cfg.sl_points = GetD(src, "cfg.sl_points");
      cfg.tp_price = GetD(src, "cfg.tp_price"); cfg.sl_price = GetD(src, "cfg.sl_price"); cfg.gap = GetD(src, "cfg.gap"); cfg.stop_price = GetD(src, "cfg.stop_price");
      cfg.enter_now = GetI(src, "cfg.enter_now") != 0; cfg.anchor = (int)GetI(src, "cfg.anchor"); cfg.trigger_side = (int)GetI(src, "cfg.trigger_side");
      cfg.max_slippage = GetD(src, "cfg.max_slippage"); cfg.max_cycles = (int)GetI(src, "cfg.max_cycles"); cfg.daily_loss = GetD(src, "cfg.daily_loss");
      cfg.max_spread = GetD(src, "cfg.max_spread"); cfg.hours = Get(src, "cfg.hours"); cfg.lot_mult = GetD(src, "cfg.lot_mult");
      for(int i = 0; i < ArraySize(src); i++)
        {
         if(StringFind(src[i], "row=") != 0)
            continue;
         string f[];
         if(StringSplit(StringSubstr(src[i], 4), '|', f) != 15)
            continue;
         SRow r;
         r.ticket = (ulong)StringToInteger(f[0]); r.cycle = (int)StringToInteger(f[1]); r.leg = (int)StringToInteger(f[2]); r.dir = (int)StringToInteger(f[3]);
         r.volume = StringToDouble(f[4]); r.planned = StringToDouble(f[5]); r.fill = StringToDouble(f[6]); r.slippage = StringToDouble(f[7]);
         r.tp = StringToDouble(f[8]); r.sl = StringToDouble(f[9]); r.open_time = (datetime)StringToInteger(f[10]); r.close_time = (datetime)StringToInteger(f[11]);
         r.close_price = StringToDouble(f[12]); r.reason = (int)StringToInteger(f[13]); r.pnl = StringToDouble(f[14]);
         AddRow(r);
        }
      m_curRow = (int)GetI(src, "curRow");
      if(state == GCS_ARMED && planned > 0)
        {
         trigger.active = true; trigger.level = planned; trigger.side = 0;
        }
      return true;
     }
  };

#endif
