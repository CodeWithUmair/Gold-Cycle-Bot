//+------------------------------------------------------------------+
//| GoldCycle engine tests: the client's rules on a simulated broker.|
//| Sends NO orders. Run it on any chart; results go to the Experts  |
//| log and MQL5\Files\GoldCycle\test_results.txt                    |
//+------------------------------------------------------------------+
#property copyright "GoldCycle"
#property version   "1.00"
#include <GoldCycle\Engine.mqh>
#include <GoldCycle\SimBroker.mqh>
#include <GoldCycle\Panel.mqh>

class CTestSink : public CGcSink
  {
public:
   int               block;
   string            last;
   int               closedRows;
   int               popups;          // pop-up alerts the trader would see for problems
   int               lines;           // log lines
                     CTestSink() { block = -1; last = ""; closedRows = 0; popups = 0; lines = 0; }
   virtual void      Event(const string level, const string msg, const bool toast) override
     {
      last = msg; lines++;
      if(toast && level == "error") popups++;
     }
   virtual void      Closed(const SRow &row, const int mode, const string session) override { closedRows++; }
   virtual int       BlockDay() override { return block; }
   virtual void      SetBlockDay(const int d) override { block = d; }
  };

int    g_pass = 0, g_fail = 0, g_file = INVALID_HANDLE;
string g_case = "";
CSimBroker *sim;
CTestSink  *sink;
CEngine    *e;

void Out(const string s)
  {
   Print(s);
   if(g_file != INVALID_HANDLE)
      FileWriteString(g_file, s + "\r\n");
  }
void Check(const bool ok, const string what)
  {
   if(ok)
      g_pass++;
   else
     {
      g_fail++;
      Out("FAIL [" + g_case + "] " + what + (sink != NULL ? "   | last: " + sink.last : ""));
     }
  }
bool Near(const double a, const double b) { return MathAbs(a - b) < 1e-6; }

void Fresh(const string name, const double price, const int mode = GC_CYCLE)
  {
   g_case = name;
   if(CheckPointer(e) == POINTER_DYNAMIC) delete e;
   if(CheckPointer(sim) == POINTER_DYNAMIC) delete sim;
   if(CheckPointer(sink) == POINTER_DYNAMIC) delete sink;
   sim = new CSimBroker();
   sim.Reset(price);
   sink = new CTestSink();
   e = new CEngine();
   e.Init(sim, sink, mode, mode == GC_CYCLE ? 100 : 101, mode == GC_CYCLE ? 101 : 100);
  }

SConfig Cfg(const int mode, const int dir, const double trigger, const double tp)
  {
   SConfig c;
   GcDefaultConfig(c, mode);
   c.dir = dir; c.trigger = trigger; c.tp_points = tp;
   return c;
  }
bool Arm(const SConfig &c)
  {
   string err = "";
   bool ok = e.Arm(c, err);
   if(!ok)
      sink.last = err;
   e.Step();
   return ok;
  }
void Move(const double bid, const double spread = -1) { sim.Price(bid, spread); e.Step(); }
void Wait(const int ms = 1100) { sim.ms += ms; e.Step(); }

//--- BUY cycle from below: arm at 4000 with the price at 3999, then touch it -> order 1 is open
void OpenBuyCycle(const double gap = 0)
  {
   SConfig c = Cfg(GC_CYCLE, GC_BUY, 4000, 3);
   c.gap = gap;
   Arm(c);
   Move(4000);
  }

//================================================================ pure rules
void TestRules()
  {
   g_case = "client table BUY, gap blank";
   SConfig c = Cfg(GC_CYCLE, GC_BUY, 4000, 3);
   SPlanned p[];
   GcPreview(c, 4, p);
   Check(ArraySize(p) == 4, "4 orders");
   Check(Near(p[0].entry, 4000) && Near(p[0].tp, 4003) && p[0].sl == 0, "C1.1");
   Check(Near(p[1].entry, 4003) && p[1].tp == 0 && Near(p[1].sl, 4000), "C1.2");
   Check(Near(p[2].entry, 4000) && Near(p[2].tp, 4003) && p[2].sl == 0 && p[2].cycle == 2, "C2.1");
   Check(Near(p[3].entry, 4003) && Near(p[3].sl, 4000), "C2.2");
   g_case = "client table SELL, gap 2";
   c = Cfg(GC_CYCLE, GC_SELL, 4000, 3); c.gap = 2;
   GcPreview(c, 4, p);
   Check(Near(p[0].tp, 3997) && Near(p[1].entry, 3997) && Near(p[1].sl, 4000), "C1");
   Check(Near(p[2].entry, 3998) && Near(p[2].tp, 3995) && Near(p[3].entry, 3995) && Near(p[3].sl, 3998), "C2");
   g_case = "client table BUY, gap 2";
   c = Cfg(GC_CYCLE, GC_BUY, 4000, 3); c.gap = 2;
   GcPreview(c, 4, p);
   Check(Near(p[2].entry, 4002) && Near(p[2].tp, 4005) && Near(p[3].sl, 4002), "C2");
   g_case = "preview limits";
   c = Cfg(GC_CYCLE, GC_BUY, 4000, 3); c.max_cycles = 1;
   GcPreview(c, 10, p);
   Check(ArraySize(p) == 2, "max cycles 1 = 2 orders");
   c.max_cycles = 0; c.stop_price = 4002;
   GcPreview(c, 10, p);
   Check(ArraySize(p) == 1, "stop below TP: only order 1");

   g_case = "number parser";
   double v; bool blank;
   Check(GcParse("", v, blank) && blank, "blank ok");
   Check(GcParse(" 3.5 ", v, blank) && !blank && Near(v, 3.5), "3.5");
   Check(GcParse("4000", v, blank) && Near(v, 4000), "4000");
   Check(!GcParse("abc", v, blank), "abc refused");
   Check(!GcParse("1..2", v, blank), "1..2 refused");
   Check(!GcParse("-3", v, blank), "negative refused");
   Check(!GcParse("3,5", v, blank), "comma refused");
   Check(!GcParse("1e5", v, blank), "exponent refused");

   g_case = "config rules";
   c = Cfg(GC_CYCLE, GC_BUY, 4000, 0);
   Check(GcNormalizeConfig(c) != "", "cycle needs TP");
   c = Cfg(GC_SINGLE, GC_BUY, 4000, 0);
   Check(GcNormalizeConfig(c) == "" && c.max_cycles == 1, "single without TP/SL ok");
   c = Cfg(GC_SINGLE, GC_BUY, 4000, 0); c.price_input = true; c.tp_price = 3990;
   Check(GcNormalizeConfig(c) != "", "BUY TP below trigger refused");
   c = Cfg(GC_SINGLE, GC_SELL, 4000, 0); c.price_input = true; c.tp_price = 3990; c.sl_price = 4005;
   Check(GcNormalizeConfig(c) == "" && Near(c.tp_points, 10) && Near(c.sl_points, 5), "SELL exact prices -> points");
   c = Cfg(GC_CYCLE, GC_BUY, 4000, 3); c.stop_price = 4000;
   Check(GcNormalizeConfig(c) != "", "stop = trigger refused");
   c.stop_price = 3990;
   Check(GcNormalizeConfig(c) == "", "BUY stop below trigger allowed");
   c.hours = "8:00-17:00";
   Check(GcNormalizeConfig(c) != "", "bad hours refused");
   c.hours = "22:00-06:00";
   Check(GcNormalizeConfig(c) == "", "good hours");
   c = Cfg(GC_CYCLE, GC_BUY, 4000, 3); c.enter_now = true;
   Check(GcNormalizeConfig(c) != "", "no Buy now in cycle");
   c = Cfg(GC_CYCLE, GC_SELL, 2, 3);
   Check(GcNormalizeConfig(c) != "", "TP below zero refused");

   g_case = "trading hours";
   Check(GcInTradingHours(600, ""), "no window");
   Check(GcInTradingHours(480, "08:00-17:00") && !GcInTradingHours(1020, "08:00-17:00"), "day window");
   Check(GcInTradingHours(1380, "22:00-06:00") && GcInTradingHours(60, "22:00-06:00") && !GcInTradingHours(600, "22:00-06:00"), "over midnight");

   g_case = "trigger";
   STrigger t;
   GcTriggerArm(t, 4000, 4000);
   Check(!GcTriggerUpdate(t, 4000), "on the level at arm: no fire");
   Check(!GcTriggerUpdate(t, 4001), "moves off: no fire");
   Check(GcTriggerUpdate(t, 4000), "returns: fire");
   GcTriggerArm(t, 4000, 3990);
   Check(!GcTriggerUpdate(t, 3999.9) && GcTriggerUpdate(t, 4000.3), "from below");
  }

//================================================================ cycle engine
void TestCycle()
  {
   Fresh("BUY gap blank: C1.1 -> TP -> C1.2 -> SL -> C2", 3999);
   Check(Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3)) && e.state == GCS_ARMED && sim.opens == 0, "armed, nothing opened");
   Move(4000);
   Check(e.state == GCS_IN_POSITION && sim.opens == 1 && Near(e.cur_tp, 4003) && e.cur_sl == 0, "C1.1 open: TP 4003, no SL");
   Check(sim.open[0].sl == 0 && Near(sim.open[0].tp, 4003), "TP is on the server");
   Move(4003.1);
   Check(sim.opens == 2 && e.leg == 2 && e.state == GCS_IN_POSITION, "C1.2 opened in the same step as the TP");
   Check(e.cur_tp == 0 && Near(e.cur_sl, 4000) && Near(e.planned, 4003), "C1.2: SL 4000, no TP, planned 4003");
   Move(3999.9);
   Check(e.state == GCS_ARMED && e.cycle_no == 2 && e.leg == 1 && Near(e.planned, 4000), "C2 armed at 4000");
   Move(4001); Move(4000);
   Check(sim.opens == 3 && Near(e.cur_tp, 4003) && e.cur_sl == 0 && e.Label() == "C2.1", "C2.1 opens on touch");
   Check(ArraySize(e.rows) == 3 && e.rows[0].reason == CR_TP && e.rows[1].reason == CR_SL && sink.closedRows == 2, "journal TP, SL");

   Fresh("SELL gap 2", 4001);
   SConfig c = Cfg(GC_CYCLE, GC_SELL, 4000, 3); c.gap = 2;
   Arm(c); Move(4000);
   Check(sim.opens == 1 && Near(e.cur_tp, 3997), "C1.1 TP 3997");
   Move(3996.8);
   Check(sim.opens == 2 && Near(e.cur_sl, 4000) && Near(e.planned, 3997), "C1.2 SL 4000");
   Move(3999.8);
   Check(e.state == GCS_ARMED && Near(e.planned, 3998), "C2 armed at 3998");
   Move(3998);
   Check(sim.opens == 3 && Near(e.cur_tp, 3995), "C2.1 TP 3995");

   Fresh("BUY gap 2", 3999);
   OpenBuyCycle(2);
   Move(4003.1); Move(3999.9);
   Check(Near(e.planned, 4002) && e.state == GCS_ARMED, "C2 armed at 4002");

   Fresh("order 2 opens even when price jumps far past the TP", 3999);
   OpenBuyCycle();
   Move(4030);
   Check(sim.opens == 2 && e.leg == 2 && Near(e.cur_sl, 4000), "opened at once");

   Fresh("order 2 ignores wide spread and trading hours", 3999);
   SConfig h = Cfg(GC_CYCLE, GC_BUY, 4000, 3); h.hours = "09:00-11:00";
   sim.localMin = 600;
   Arm(h); Move(4000);
   Check(sim.opens == 1, "C1.1 inside hours");
   sim.localMin = 1000;
   Move(4005, 3.0);
   Check(sim.opens == 2, "C1.2 opened anyway");

   Fresh("order 2 rejected: retried every second", 3999);
   OpenBuyCycle();
   sim.rejectOpens = 2;
   Move(4005);
   Check(e.state == GCS_OPENING && sim.opens == 1, "rejected, still opening");
   Move(4009);
   Check(e.state == GCS_OPENING, "second rejection");
   Move(4012);
   Check(sim.opens == 2 && e.state == GCS_IN_POSITION, "opened on the third try, no wait for a return");

   Fresh("retry throttle: not faster than 1 s", 3999);
   sim.rejectOpens = 1;
   OpenBuyCycle();
   e.Step(); e.Step();
   Check(sim.opens == 0, "no immediate retry");
   Wait();
   Check(sim.opens == 1, "retried after 1 s");

   Fresh("price already past the trigger at arm", 4005);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   Move(4006); Move(4003);
   Check(sim.opens == 0 && e.state == GCS_ARMED && StringFind(e.waiting, "return") >= 0, "waits for a return");
   Move(4000);
   Check(sim.opens == 1, "opens on the return");

   Fresh("spread too wide", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   Move(4000, 1.5);
   Check(sim.opens == 0 && e.state == GCS_OPENING && StringFind(e.waiting, "spread") >= 0, "waits");
   Move(4000.1, 0.2);
   Check(sim.opens == 1, "opens when narrow");

   Fresh("jump beyond max slippage: wait for another touch", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   Move(4002);
   Check(sim.opens == 0 && e.state == GCS_ARMED, "re-armed");
   Move(4000.2);
   Check(sim.opens == 0, "above the level is not a touch");
   Move(4000);
   Check(sim.opens == 1, "opens on the touch");

   Fresh("fatal order error stops the bot", 3999);
   sim.rejectOpens = 1; sim.rejectFatal = true; sim.rejectCode = 10019;
   OpenBuyCycle();
   Check(e.state == GCS_STOPPED && e.stop_reason == "ORDER_ERROR", "stopped");

   Fresh("stop price above (in order 2)", 3999);
   SConfig s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 4010;
   Arm(s); Move(4000); Move(4003.1);
   Move(4010);
   Wait();
   Check(e.state == GCS_STOPPED && e.stop_reason == "STOP_PRICE" && ArraySize(sim.open) == 0, "closed and stopped");
   Check(e.rows[1].reason == CR_STOP_PRICE, "journal STOP_PRICE");

   Fresh("stop price below trigger (BUY, order 1 has no SL)", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 3995;
   Arm(s);
   Check(e.state == GCS_ARMED, "ADR-0004: stop price does not cancel before the first fill");
   Move(3990); Move(4000);
   Check(sim.opens == 1, "filled");
   Move(3995);
   Wait();
   Check(e.state == GCS_STOPPED && ArraySize(sim.open) == 0 && e.stop_reason == "STOP_PRICE", "closed at stop");

   Fresh("stop close rejected: retried", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 3995;
   Arm(s); Move(4000);
   sim.rejectCloses = 3;
   Move(3994);
   Check(e.state == GCS_IN_POSITION && e.pending_close == CR_STOP_PRICE, "still open, pending");
   Wait(); Wait(); Wait(); Wait();
   Check(e.state == GCS_STOPPED && ArraySize(sim.open) == 0, "closed after retries");

   Fresh("one jump through TP and stop price", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 4010;
   Arm(s); Move(4000);
   sim.Price(4012); e.Step(); Wait();
   Check(sim.opens == 1 && e.state == GCS_STOPPED, "no order 2 past the stop price");

   Fresh("next entry beyond stop price", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 4003.05;
   Arm(s); Move(4000); Move(4003.0);
   Check(sim.opens == 2, "order 2 at 4003 is below the stop");

   Fresh("max cycles", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.max_cycles = 1;
   Arm(s); Move(4000); Move(4003.1); Move(3999.9);
   Check(e.state == GCS_STOPPED && e.stop_reason == "MAX_CYCLES" && sim.opens == 2, "stops after both orders");

   Fresh("stop after cycle pressed during order 1", 3999);
   OpenBuyCycle();
   string err = "";
   Check(e.StopAfterCycle(err), "accepted");
   Move(4003.1);
   Check(sim.opens == 2 && e.leg == 2, "order 2 still opens");
   Move(3999.9);
   Check(e.state == GCS_STOPPED && e.stop_reason == "STOP_AFTER_CYCLE", "stops after order 2");

   Fresh("stop after cycle while waiting", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   Check(e.StopAfterCycle(err) && e.state == GCS_STOPPED, "stops at once");

   Fresh("manual close in MT5", 3999);
   OpenBuyCycle();
   sim.CloseManually(e.pos.ticket); Wait();
   Check(e.state == GCS_STOPPED && e.stop_reason == "MANUAL_CLOSE" && sim.opens == 1, "stops, no fight");

   Fresh("daily loss limit", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.daily_loss = 2.0;
   Arm(s); Move(4000);
   Move(3997.0);
   Wait();
   Check(e.state == GCS_STOPPED && e.stop_reason == "DAILY_LOSS" && ArraySize(sim.open) == 0, "closed and stopped");
   Check(!e.Arm(s, err) && StringFind(err, "Daily loss") >= 0, "no new trades today");
   sim.day++;
   Check(e.Arm(s, err), "tomorrow allowed");

   Fresh("daily loss counted once while resolving", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.daily_loss = 5.0;
   Arm(s); Move(4000); Move(4003.1);
   Move(3999.9);
   Check(e.state == GCS_ARMED, "a loss of about 3.3 stays under the 5 limit");

   Fresh("close all while open", 3999);
   OpenBuyCycle();
   e.CloseAllAndStop(); e.Step(); Wait();
   Check(e.state == GCS_STOPPED && e.stop_reason == "KILL_SWITCH" && ArraySize(sim.open) == 0 && e.rows[0].reason == CR_KILL_SWITCH, "closed");

   Fresh("close all while armed", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   e.CloseAllAndStop();
   Check(e.state == GCS_STOPPED && sim.opens == 0, "stopped");

   Fresh("duplicate guard at arm", 3999);
   sim.Inject(GC_BUY, 100, "other");
   Check(!e.Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3), err) && StringFind(err, "still open") >= 0, "refused");

   Fresh("duplicate guard while armed", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   sim.Inject(GC_BUY, 100, "other");
   Move(4000);
   Check(e.state == GCS_STOPPED && e.stop_reason == "DUPLICATE_GUARD" && sim.opens == 0, "no second trade");

   Fresh("order filled but answer lost: attach", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   sim.Inject(GC_BUY, 100, "GC|c=1.1|s=" + e.sid);
   Move(4000);
   Check(e.state == GCS_IN_POSITION && sim.opens == 0, "attached, not duplicated");

   Fresh("algo trading off", 3999);
   sim.blockReason = "Algo Trading is OFF";
   Check(!e.Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3), err) && e.state == GCS_IDLE, "arm refused with reason");

   Fresh("lot and stops level validation", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.lot = 0.015;
   Check(!e.Arm(s, err), "lot step");
   sim.stopsLevel = 5000;
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3);
   Check(!e.Arm(s, err) && StringFind(err, "broker minimum") >= 0, "TP too close");

   Fresh("disconnect pauses, reconnect continues", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   sim.online = false; sim.Price(4000); e.Step();
   Check(sim.opens == 0 && !e.connected, "paused");
   sim.online = true; e.Step();
   Check(sim.opens == 1 && e.connected, "continues");

   Fresh("history late", 3999);
   OpenBuyCycle();
   sim.hideHistory = true;
   Move(4003.1); Wait(3000);
   Check(e.state == GCS_RESOLVING && sim.opens == 1, "waits for the deal");
   sim.hideHistory = false; Wait();
   Check(sim.opens == 2, "then continues");

   Fresh("history never arrives", 3999);
   OpenBuyCycle();
   sim.hideHistory = true;
   Move(4003.1); Wait(3000); Wait(11000);
   Check(e.state == GCS_STOPPED && sim.opens == 1, "stops as unknown");

   Fresh("Stop now leaves the trade; its later close is journaled", 3999);
   OpenBuyCycle();
   Check(e.StopNow(err) && e.state == GCS_STOPPED && ArraySize(sim.open) == 1, "left open");
   Move(4003.1);
   Check(sim.opens == 1 && !e.hasPos && e.rows[0].reason == CR_TP, "journaled, no new order");

   Fresh("close all after Stop now", 3999);
   OpenBuyCycle(); e.StopNow(err);
   e.CloseAllAndStop(); e.Step();
   Check(ArraySize(sim.open) == 0 && e.rows[0].reason == CR_KILL_SWITCH, "closed and journaled");

   Fresh("levels from fill", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.anchor = ANCHOR_FILL;
   Arm(s); Move(4000);
   Check(Near(e.cur_tp, 4003.2) && sim.modifies == 1, "TP from the fill 4000.2");
   Move(4003.3);
   Check(sim.opens == 2 && Near(e.cur_sl, 4000.2) && sim.modifies == 1, "order 2: SL = fill-based entry, no pointless modify");
  }

//================================================================ live changes
void TestLive()
  {
   string err = "";
   Fresh("live TP change moves the open order 1 TP", 3999);
   OpenBuyCycle();
   SConfig n = e.cfg; n.tp_points = 5;
   Check(e.UpdateConfig(n, err) && Near(e.cur_tp, 4005) && Near(sim.open[0].tp, 4005), "moved to 4005");
   Move(4003.5);
   Check(sim.opens == 1, "old TP no longer triggers");
   Move(4005.1);
   Check(sim.opens == 2 && Near(e.planned, 4005), "order 2 at the new TP");

   Fresh("live gap change while waiting to re-enter", 3999);
   OpenBuyCycle(1); Move(4003.1); Move(3999.9);
   Check(Near(e.planned, 4001), "waiting at 4001");
   n = e.cfg; n.gap = 4;
   Check(e.UpdateConfig(n, err) && Near(e.planned, 4004), "moved to 4004");

   Fresh("live trigger change", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   n = e.cfg; n.trigger = 4010;
   Check(e.UpdateConfig(n, err) && Near(e.planned, 4010), "while waiting for order 1");
   Move(4000);
   Check(sim.opens == 0, "old level gone");
   Move(4010);
   Check(sim.opens == 1, "new level");
   n = e.cfg; n.trigger = 4020;
   Check(!e.UpdateConfig(n, err), "refused while a trade is open");

   Fresh("live change refusals leave everything", 3999);
   OpenBuyCycle();
   n = e.cfg; n.dir = GC_SELL;
   Check(!e.UpdateConfig(n, err), "direction");
   n = e.cfg; n.stop_price = 3999;
   Move(3998);
   Check(!e.UpdateConfig(n, err) && e.cfg.stop_price == 0, "already passed stop price (below) refused");
   n = e.cfg; n.stop_price = 4001; n.tp_points = 9;
   double before = e.cur_tp;
   Move(4001.5);
   Check(!e.UpdateConfig(n, err) && Near(e.cur_tp, before), "passed stop price refused, TP untouched");
   n = e.cfg; n.lot = 0.015;
   Check(!e.UpdateConfig(n, err), "bad lot");

   Fresh("drag order 1 TP: order 2 opens there", 3999);
   OpenBuyCycle();
   sim.Drag(e.pos.ticket, 0, 4008); Wait();
   Check(Near(e.cur_tp, 4008), "bot follows the drag");
   Move(4008.1);
   Check(sim.opens == 2 && Near(e.planned, 4008) && Near(e.cur_sl, 4000), "order 2 at 4008");
   sim.Drag(e.pos.ticket, 4001, 0); Wait();
   Move(4000.9);
   Check(e.state == GCS_ARMED && Near(e.planned, 4000), "next cycle still at the cycle entry");

   Fresh("TP/SL boxes", 3999);
   OpenBuyCycle();
   Check(!e.ModifyLevels(3990, 0, err), "TP below price refused");
   Check(!e.ModifyLevels(4010, 4005, err), "SL above price refused");
   Check(e.ModifyLevels(4010, 3990, err) && Near(sim.open[0].sl, 3990), "set");
   Check(e.ModifyLevels(0, 0, err) && sim.open[0].tp == 0, "removed");
   sim.rejectModify = true;
   Check(!e.ModifyLevels(4011, 0, err) && e.cur_tp == 0, "broker refusal keeps state");
  }

//================================================================ single
void TestSingle()
  {
   string err = "";
   Fresh("single TP only", 3999, GC_SINGLE);
   Arm(Cfg(GC_SINGLE, GC_BUY, 4000, 3)); Move(4000);
   Check(e.state == GCS_IN_POSITION && Near(sim.open[0].tp, 4003) && sim.open[0].sl == 0, "open");
   Move(4003.1);
   Check(e.state == GCS_IDLE && sim.opens == 1 && e.Label() == "Trade", "complete, no next trade");

   Fresh("single SL only", 3999, GC_SINGLE);
   SConfig c = Cfg(GC_SINGLE, GC_BUY, 4000, 0); c.sl_points = 2;
   Arm(c); Move(4000); Move(3997.9);
   Check(e.state == GCS_IDLE && e.rows[0].reason == CR_SL, "SL closes it");

   Fresh("single no TP no SL, close trade", 3999, GC_SINGLE);
   Arm(Cfg(GC_SINGLE, GC_BUY, 4000, 0)); Move(4000); Move(4050);
   Check(e.state == GCS_IN_POSITION, "stays open");
   Check(e.StopNow(err), "Close trade");
   Wait();
   Check(e.state == GCS_IDLE && ArraySize(sim.open) == 0 && e.rows[0].reason == CR_CLOSED, "closed");

   Fresh("single cancel before fill", 3999, GC_SINGLE);
   Arm(Cfg(GC_SINGLE, GC_BUY, 4000, 3));
   Check(e.StopNow(err) && e.state == GCS_STOPPED && sim.opens == 0, "cancelled");

   Fresh("single exact prices SELL", 4001, GC_SINGLE);
   c = Cfg(GC_SINGLE, GC_SELL, 4000, 0); c.price_input = true; c.tp_price = 3990; c.sl_price = 4004;
   Arm(c); Move(4000);
   Check(Near(sim.open[0].tp, 3990) && Near(sim.open[0].sl, 4004), "levels");

   Fresh("buy now", 4123.4, GC_SINGLE);
   c = Cfg(GC_SINGLE, GC_BUY, 0, 0); c.enter_now = true;
   Check(e.Arm(c, err) && sim.opens == 1 && e.state == GCS_IN_POSITION && sim.open[0].tp == 0 && sim.open[0].sl == 0, "opens at once without TP/SL");

   Fresh("sell now with a wrong exact TP", 4000, GC_SINGLE);
   c = Cfg(GC_SINGLE, GC_SELL, 0, 0); c.enter_now = true; c.price_input = true; c.tp_price = 4010;
   Check(!e.Arm(c, err) && sim.opens == 0, "refused");

   Fresh("single with trade open: arm refused", 3999, GC_SINGLE);
   Arm(Cfg(GC_SINGLE, GC_BUY, 4000, 3)); Move(4000);
   Check(!e.Arm(Cfg(GC_SINGLE, GC_BUY, 4000, 3), err), "already running");

   // both bots side by side on one account
   Fresh("cycle and single together", 3999);
   CEngine *s = new CEngine();
   s.Init(sim, sink, GC_SINGLE, 101, 100);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   s.Arm(Cfg(GC_SINGLE, GC_BUY, 4000, 5), err);
   sim.Price(4000); e.Step(); s.Step();
   Check(ArraySize(sim.open) == 2 && e.state == GCS_IN_POSITION && s.state == GCS_IN_POSITION, "one trade each");
   e.CloseAllAndStop(); e.Step();
   Check(ArraySize(sim.open) == 1 && s.state == GCS_IN_POSITION, "close all of one bot only");
   delete s;
  }

//================================================================ restart
CEngine *Reload(const bool auto_resume)
  {
   string saved[];
   e.Serialize(saved);
   CEngine *n = new CEngine();
   n.Init(sim, sink, e.mode, e.magic, e.otherMagic);
   n.Deserialize(saved);
   n.Recover(auto_resume);
   delete e;
   return n;
  }

void TestRestart()
  {
   string err = "";
   Fresh("restart in position: Resume?", 3999);
   OpenBuyCycle();
   e = Reload(false);
   Check(e.state == GCS_STOPPED && e.resumable && e.hasPos, "asks to resume");
   e.Step();
   Check(e.state == GCS_STOPPED, "does nothing until Resume");
   Check(e.Resume(err) && e.state == GCS_IN_POSITION && sim.opens == 1, "reattached");
   Move(4003.1);
   Check(sim.opens == 2 && Near(e.cur_sl, 4000), "continues with order 2");

   Fresh("closed while the bot was off", 3999);
   OpenBuyCycle();
   string saved[];
   e.Serialize(saved);
   sim.Price(4004);
   CEngine *n = new CEngine();
   n.Init(sim, sink, GC_CYCLE, 100, 101);
   Check(n.Deserialize(saved), "loaded");
   n.Recover(false);
   n.Resume(err);
   Check(sim.opens == 2 && n.leg == 2 && n.state == GCS_IN_POSITION, "resolved from history, order 2 opened");
   delete e; e = n;

   Fresh("restart while armed, auto resume", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   e = Reload(true);
   Check(e.state == GCS_ARMED && !e.resumable, "armed again");
   Move(4000);
   Check(sim.opens == 1, "opens");

   Fresh("restart keeps the journal and settings", 3999);
   SConfig c = Cfg(GC_CYCLE, GC_BUY, 4000, 3); c.gap = 2; c.hours = "00:00-23:59"; c.stop_price = 4100; c.max_cycles = 7;
   Arm(c); Move(4000); Move(4003.1);
   e = Reload(false);
   Check(ArraySize(e.rows) == 2 && e.rows[0].reason == CR_TP && Near(e.cfg.gap, 2) && e.cfg.hours == "00:00-23:59" && e.cfg.max_cycles == 7
         && Near(e.prev_entry, 4000) && Near(e.session_pnl, e.rows[0].pnl), "restored");
   e = Reload(false);
   Check(e.resumable && e.resume_state == GCS_IN_POSITION, "restart twice still resumable");

   Fresh("restart while idle", 3999);
   e = Reload(false);
   Check(e.state == GCS_IDLE && !e.resumable, "stays idle");
  }

//================================================================ edge cases
int Index(const ulong ticket)
  {
   for(int i = 0; i < ArraySize(sim.open); i++)
      if(sim.open[i].ticket == ticket)
         return i;
   return -1;
  }

//--- BUY cycle whose order 2 was rejected once: the bot is OPENING order 2
void Order2Pending()
  {
   OpenBuyCycle();
   sim.rejectOpens = 1;
   Move(4005);
  }

void TestEdges()
  {
   string err = "";

   Fresh("restart while order 2 is still being opened: opens at once, never waits for a touch", 3999);
   Order2Pending();
   Check(e.state == GCS_OPENING && e.leg == 2, "precondition: opening order 2");
   e = Reload(false);
   Check(e.Resume(err), "resume");
   Check(e.state == GCS_OPENING, "still opening, not 'waiting for price' (state " + GcStateName(e.state) + ")");
   Move(4009);
   Check(sim.opens == 2 && e.state == GCS_IN_POSITION && Near(e.cur_sl, 4000), "order 2 opened far from the TP price");

   Fresh("timeframe switch while order 2 is still being opened", 3999);
   Order2Pending();
   e = Reload(true);
   Move(4009);
   Check(sim.opens == 2 && e.state == GCS_IN_POSITION, "order 2 opened after the automatic resume");

   Fresh("crash after order 1 was sent, before it was saved", 3999);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3));
   string armed[];
   e.Serialize(armed);
   Move(4000);
   CEngine *n = new CEngine();
   n.Init(sim, sink, GC_CYCLE, 100, 101);
   n.Deserialize(armed); n.Recover(false);
   Check(n.Resume(err) && n.state == GCS_IN_POSITION && sim.opens == 1, "attached to the trade, no second order");
   delete e; e = n;

   Fresh("crash after order 2 was sent, before it was saved", 3999);
   OpenBuyCycle();
   string inpos[];
   e.Serialize(inpos);
   Move(4003.1);
   n = new CEngine();
   n.Init(sim, sink, GC_CYCLE, 100, 101);
   n.Deserialize(inpos); n.Recover(false);
   n.Resume(err); sim.ms += 1100; n.Step();
   Check(sim.opens == 2 && ArraySize(sim.open) == 1 && n.state == GCS_IN_POSITION && n.leg == 2, "order 1 read from history, order 2 attached, no duplicate");
   delete e; e = n;

   Fresh("restart while a close is still being retried", 3999);
   SConfig s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 3995;
   Arm(s); Move(4000);
   sim.rejectCloses = 2;
   Move(3994);
   e = Reload(false);
   e.Resume(err); Wait(); Wait(); Wait();
   Check(ArraySize(sim.open) == 0 && e.state == GCS_STOPPED && e.stop_reason == "STOP_PRICE", "close finished after the restart");

   Fresh("daily loss hit by Single stops the Cycle bot too (it waits for a trigger)", 3999);
   CEngine *one = new CEngine();
   one.Init(sim, sink, GC_SINGLE, 101, 100);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4010, 3));
   SConfig c = Cfg(GC_SINGLE, GC_BUY, 4001, 0); c.daily_loss = 2;
   one.Arm(c, err); sim.Price(4001); one.Step(); e.Step();
   sim.Price(3997); one.Step(); sim.ms += 1100; one.Step(); e.Step();
   Check(one.state == GCS_STOPPED && one.stop_reason == "DAILY_LOSS", "single stopped");
   Check(e.state == GCS_STOPPED && e.stop_reason == "DAILY_LOSS", "cycle stopped as well (" + GcStateName(e.state) + ")");
   Move(4010);
   Check(ArraySize(sim.open) == 0, "no new trade today");
   delete one;

   Fresh("daily loss hit by Single closes the Cycle bot's open trade", 3999);
   one = new CEngine();
   one.Init(sim, sink, GC_SINGLE, 101, 100);
   Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 30));
   c = Cfg(GC_SINGLE, GC_BUY, 4000, 0); c.daily_loss = 2;
   one.Arm(c, err); sim.Price(4000); e.Step(); one.Step();
   sim.Price(3997); one.Step(); e.Step(); sim.ms += 1100; one.Step(); e.Step(); sim.ms += 1100; e.Step();
   Check(ArraySize(sim.open) == 0 && e.state == GCS_STOPPED && e.stop_reason == "DAILY_LOSS", "stop all (" + GcStateName(e.state) + ")");
   delete one;

   Fresh("no order 2 once the daily loss limit is hit", 3999);
   OpenBuyCycle();
   sink.SetBlockDay(sim.day);
   sim.Price(4003.1); e.Step(); sim.ms += 1100; e.Step(); sim.ms += 1100; e.Step();
   Check(sim.opens == 1 && e.state == GCS_STOPPED && e.stop_reason == "DAILY_LOSS", "stopped without order 2");

   Fresh("close all while an order is being retried", 3999);
   sim.rejectOpens = 100;
   OpenBuyCycle();
   e.CloseAllAndStop();
   sim.rejectOpens = 0; Wait(); Wait();
   Check(e.state == GCS_STOPPED && sim.opens == 0, "no order after the kill switch");

   Fresh("close all while reading order 1's result", 3999);
   OpenBuyCycle();
   sim.hideHistory = true;
   Move(4003.1); Wait(3000);
   e.CloseAllAndStop();
   sim.hideHistory = false; Wait(); Wait();
   Check(sim.opens == 1 && e.state == GCS_STOPPED && e.stop_reason == "KILL_SWITCH", "no order 2");

   Fresh("Stop now while an order is being retried", 3999);
   sim.rejectOpens = 100;
   OpenBuyCycle();
   Check(e.StopNow(err), "accepted");
   sim.rejectOpens = 0; Wait(); Wait();
   Check(sim.opens == 0 && e.state == GCS_STOPPED, "nothing opens later");

   Fresh("stop price reached while order 2 is being retried", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.stop_price = 4010;
   Arm(s); Move(4000);
   sim.rejectOpens = 100;
   Move(4003.1);
   sim.rejectOpens = 0; sim.Price(4011); e.Step(); Wait();
   Check(sim.opens == 1 && e.state == GCS_STOPPED && e.stop_reason == "STOP_PRICE", "stopped, order 2 not opened");

   Fresh("stop after cycle pressed during order 2", 3999);
   OpenBuyCycle(); Move(4003.1);
   e.StopAfterCycle(err); Move(3999.9);
   Check(e.state == GCS_STOPPED && e.stop_reason == "STOP_AFTER_CYCLE" && sim.opens == 2, "stops when order 2 closes");

   Fresh("trader adds a TP on order 2 and it hits", 3999);
   OpenBuyCycle(2); Move(4003.1);
   sim.Drag(e.pos.ticket, 4000, 4008); Wait();
   Move(4008.1);
   Check(e.state == GCS_ARMED && e.cycle_no == 2 && Near(e.planned, 4002), "cycle over, next at entry + gap");

   Fresh("trader adds an SL on order 1 and it hits", 3999);
   OpenBuyCycle(2);
   sim.Drag(e.pos.ticket, 3998, 4003); Wait();
   Move(3997.9);
   Check(e.state == GCS_ARMED && e.cycle_no == 2 && e.leg == 1 && Near(e.planned, 4002) && sim.opens == 1, "next cycle at entry + gap, no order 2");

   Fresh("broker stop-out", 3999);
   OpenBuyCycle();
   sim.CloseAt(Index(e.pos.ticket), DL_STOP_OUT, 3990); Wait();
   Check(e.state == GCS_STOPPED && e.stop_reason == "STOP_OUT" && sim.opens == 1, "stops");

   Fresh("closed by another program at the TP price", 3999);
   OpenBuyCycle();
   sim.CloseAt(Index(e.pos.ticket), DL_EXPERT, 4003); Wait();
   Check(sim.opens == 2, "treated as TP");

   Fresh("closed by another program elsewhere", 3999);
   OpenBuyCycle();
   sim.CloseAt(Index(e.pos.ticket), DL_EXPERT, 3980); Wait();
   Check(e.state == GCS_STOPPED && e.stop_reason == "UNKNOWN" && sim.opens == 1, "stops, never guesses");

   Fresh("TP hit while disconnected", 3999);
   OpenBuyCycle();
   sim.online = false; e.Step();
   sim.Price(4004);
   e.Step();
   Check(sim.opens == 1, "paused");
   sim.online = true; Wait();
   Check(sim.opens == 2 && e.leg == 2 && Near(e.cur_sl, 4000), "order 2 right after reconnecting");

   Fresh("trader closes part of the trade", 3999);
   SConfig big = Cfg(GC_CYCLE, GC_BUY, 4000, 3); big.lot = 0.1;
   Arm(big); Move(4000);
   sim.open[0].volume = 0.05; Wait();
   Check(e.state == GCS_IN_POSITION && sim.opens == 1, "keeps tracking the rest, no new order");

   Fresh("rejections do not flood the screen with pop-ups", 3999);
   sim.rejectOpens = 1000;
   OpenBuyCycle();
   int lines = sink.lines;
   for(int i = 0; i < 30; i++) Wait(1000);
   Check(sink.popups <= 2, "pop-ups in 30 s: " + IntegerToString(sink.popups));
   Check(sink.lines - lines <= 8, "log lines in 30 s: " + IntegerToString(sink.lines - lines));
   Check(e.state == GCS_OPENING, "still retrying");
   sim.rejectOpens = 0; Wait();
   Check(sim.opens == 1, "and it fills when the broker accepts");

   Fresh("lower max cycles while running", 3999);
   OpenBuyCycle(); Move(4003.1); Move(3999.9); Move(4001); Move(4000);
   Check(e.cycle_no == 2 && e.state == GCS_IN_POSITION, "in cycle 2");
   SConfig low = e.cfg; low.max_cycles = 1;
   Check(e.UpdateConfig(low, err), "accepted");
   Move(4003.1); Move(3999.9);
   Check(e.state == GCS_STOPPED && e.stop_reason == "MAX_CYCLES", "stops after this cycle");

   Fresh("more orders than the journal keeps", 3999);
   OpenBuyCycle();
   for(int i = 0; i < 25; i++) { Move(4003.1); Move(3999.9); Move(4001); Move(4000); }
   Check(ArraySize(e.rows) == 40 && sim.opens == 51, "40 rows kept, " + IntegerToString(sim.opens) + " orders");
   e = Reload(false);
   e.Resume(err);
   Move(4003.1);
   Check(e.rows[ArraySize(e.rows) - 2].reason == CR_TP && sim.opens == 52, "the right row is updated after a restart");

   Fresh("damaged state file", 3999);
   string junk[] = {"hello", "state", "=5", "row=1|2|3"};
   Check(!e.Deserialize(junk) && e.state == GCS_IDLE && !e.hasCfg, "ignored");

   Fresh("Start pressed just after a left-open trade closed", 3999);
   OpenBuyCycle(); e.StopNow(err);
   sim.Price(4003.1);
   int before = sink.closedRows;
   Check(e.Arm(Cfg(GC_CYCLE, GC_BUY, 4010, 3), err), "new session accepted");
   Check(sink.closedRows == before + 1, "the old trade is still written to the journal file");

   Fresh("arm while disconnected", 3999);
   sim.online = false;
   Check(!e.Arm(Cfg(GC_CYCLE, GC_BUY, 4000, 3), err) && e.state == GCS_IDLE, "refused");

   Fresh("SELL stop above the trigger", 4001);
   s = Cfg(GC_CYCLE, GC_SELL, 4000, 3); s.stop_price = 4006;
   Arm(s); Move(4000);
   Move(4005.8);
   Wait();
   Check(ArraySize(sim.open) == 0 && e.stop_reason == "STOP_PRICE", "measured on the ask (4006.0)");

   Fresh("trigger on ask", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.trigger_side = SIDE_ASK;
   Arm(s); Move(3999.8, 0.2);
   Check(sim.opens == 1, "ask 4000.0 touches");

   Fresh("max slippage 0 needs the exact price", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.max_slippage = 0;
   Arm(s); Move(4000.3);
   Check(sim.opens == 0, "0.3 past is refused");
   Move(4000);
   Check(sim.opens == 1, "exact touch opens");

   Fresh("trading hours open the window later", 3999);
   s = Cfg(GC_CYCLE, GC_BUY, 4000, 3); s.hours = "12:00-13:00"; sim.localMin = 600;
   Arm(s); Move(4000);
   Check(sim.opens == 0 && StringFind(e.waiting, "hours") >= 0, "waits");
   sim.localMin = 720; Move(4000.1);
   Check(sim.opens == 1, "opens inside the window");

  }

//================================================================ what the trader types into the panel
bool Bad(CGcPanel &p, const int mode, const string expect, const bool now = false)
  {
   SConfig c;
   string errors[];
   p.BuildConfig(mode, now, c, errors);
   string all = "";
   for(int i = 0; i < ArraySize(errors); i++) all += errors[i] + "; ";
   if(all == "") all = GcNormalizeConfig(c);
   sink.last = all;
   return StringFind(all, expect) >= 0;
  }
bool Good(CGcPanel &p, const int mode, const bool now = false)
  {
   SConfig c;
   string errors[];
   p.BuildConfig(mode, now, c, errors);
   // "Buy / Sell now": the engine fills in the live price before checking the rest
   string bad = ArraySize(errors) > 0 ? errors[0] : (now ? "" : GcNormalizeConfig(c));
   sink.last = bad;
   return bad == "";
  }

void TestPanel()
  {
   Fresh("panel input checks", 4000);
   CGcPanel p;
   p.Init(10, 20, 1, 0.01);
   Check(Bad(p, 0, "trigger price"), "empty trigger");
   p.draft[0].trigger = "4000";
   Check(Good(p, 0), "defaults + trigger are valid");
   p.draft[0].trigger = "4,000"; Check(Bad(p, 0, "not a number"), "comma");
   p.draft[0].trigger = "0"; Check(Bad(p, 0, "trigger price"), "zero trigger");
   p.draft[0].trigger = "4000";
   p.draft[0].lot = "0"; Check(Bad(p, 0, "lot"), "zero lot");
   p.draft[0].lot = "o.01"; Check(Bad(p, 0, "not a number"), "letter o in lot");
   p.draft[0].lot = "0.01";
   p.draft[0].tp = ""; Check(Bad(p, 0, "TP"), "cycle without TP");
   p.draft[0].tp = "0"; Check(Bad(p, 0, "TP"), "TP 0");
   p.draft[0].tp = "-3"; Check(Bad(p, 0, "not a number"), "negative TP");
   p.draft[0].tp = "3";
   p.draft[0].gap = "0"; Check(Good(p, 0), "gap 0 = same entry");
   p.draft[0].gap = "x"; Check(Bad(p, 0, "not a number"), "gap typo");
   p.draft[0].gap = "";
   p.draft[0].stop = "0"; Check(Bad(p, 0, "Stop price"), "stop 0 must not silently mean 'no stop'");
   p.draft[0].stop = "4000"; Check(Bad(p, 0, "equal"), "stop = trigger");
   p.draft[0].stop = "";
   p.draft[0].dloss = "0"; Check(Bad(p, 0, "Daily loss"), "daily loss 0 must not silently mean 'no limit'");
   p.draft[0].dloss = "";
   p.draft[0].mspread = "0"; Check(Bad(p, 0, "Max spread"), "max spread 0 must not silently mean 'no limit'");
   p.draft[0].mspread = ""; Check(Good(p, 0), "blank max spread = no limit");
   p.draft[0].maxc = "0"; Check(Bad(p, 0, "Max cycles"), "max cycles 0");
   p.draft[0].maxc = "2.5"; Check(Bad(p, 0, "Max cycles"), "max cycles 2.5");
   p.draft[0].maxc = "";
   p.draft[0].mslip = ""; Check(Good(p, 0), "blank slippage = default");
   p.draft[0].hours = "25:00-26:00"; Check(Bad(p, 0, "Trading hours"), "impossible hours");
   p.draft[0].hours = "9:00-17:00"; Check(Bad(p, 0, "Trading hours"), "missing zero");
   p.draft[0].hours = "09:00-09:00"; Check(Bad(p, 0, "Trading hours"), "empty window would never trade");
   p.draft[0].hours = " 08:00-17:00 "; Check(Good(p, 0), "spaces trimmed");

   p.draft[1].trigger = "abc"; p.draft[1].tp = "zz";
   Check(Bad(p, 1, "not a number", true), "Buy now never ignores a typo in TP");
   p.draft[1].tp = "";
   Check(Good(p, 1, true), "Buy now ignores the trigger box");
   p.draft[1].lot = ""; Check(Bad(p, 1, "lot", true), "Buy now still needs a lot");
   p.draft[1].lot = "0.01"; p.draft[1].trigger = "4000"; p.draft[1].tp = ""; p.draft[1].sl = "";
   Check(Good(p, 1), "single with neither TP nor SL");
   p.draft[1].sl = "0"; Check(Bad(p, 1, "SL"), "single SL 0");
   p.draft[1].sl = ""; p.draft[1].price_input = true; p.draft[1].dir = GC_BUY; p.draft[1].tp = "3990";
   Check(Bad(p, 1, "above"), "BUY exact TP below the trigger");
   p.draft[1].tp = "4010"; p.draft[1].sl = "4001"; Check(Bad(p, 1, "below"), "BUY exact SL above the trigger");
   p.draft[1].sl = "3990"; Check(Good(p, 1), "valid exact prices");

   SConfig run = Cfg(GC_CYCLE, GC_BUY, 4000, 3); run.gap = 2; run.stop_price = 3990; run.max_cycles = 3; run.hours = "08:00-17:00";
   Arm(run);
   p.SyncDraft(e.cfg);
   string err = "";
   Check(!p.Typed(e, "tp", "3", err), "Enter on an unchanged value does nothing");
   Check(p.Typed(e, "tp", "4", err) && err == "" && Near(e.cfg.tp_points, 4), "Enter applies to a running cycle: " + err);
   Check(p.Typed(e, "tp", "abc", err) && err != "" && Near(e.cfg.tp_points, 4) && p.draft[0].tp == "4", "a typo is refused and the box goes back");
   Check(p.Typed(e, "stop", "4000", err) && err != "" && Near(e.cfg.stop_price, 3990) && p.draft[0].stop == "3990", "a refused value changes nothing");

   CEngine *one = new CEngine();
   one.Init(sim, sink, GC_SINGLE, 101, 100);
   sim.Spec(one.spec);
   SConfig far = Cfg(GC_SINGLE, GC_BUY, 4010, 3);
   Check(one.Arm(far, err), "single waiting at its trigger");
   p.SyncDraft(one.cfg);
   Check(p.Typed(one, "lot", "0.02", err) && err != "" && p.draft[1].lot == "0.01" && Near(one.cfg.lot, 0.01), "a waiting Single trade can't be changed");
   delete one;
   p.Remove();
  }

//================================================================ Buy / Sell now takes the TP / SL boxes
bool Now(CGcPanel &p, const int dir, const string tp, const string sl, const bool exact = false)
  {
   Fresh("Buy / Sell now with TP / SL", 4000, GC_SINGLE);
   p.draft[1].dir = dir; p.draft[1].trigger = "abc"; p.draft[1].tp = tp; p.draft[1].sl = sl; p.draft[1].price_input = exact;
   SConfig c;
   string errors[], err = "";
   p.BuildConfig(GC_SINGLE, true, c, errors);
   if(ArraySize(errors) > 0 || !e.Arm(c, err))
      return false;
   e.Step();
   return e.hasPos;
  }

void TestBuyNow()
  {
   CGcPanel p;
   p.Init(10, 20, 1, 0.01);
   Check(Now(p, GC_BUY, "6", "3") && Near(sim.open[0].tp, e.pos.price_open + 6) && Near(sim.open[0].sl, e.pos.price_open - 3),
         "BUY now: TP 6 / SL 3 points from the fill");
   Check(Now(p, GC_SELL, "6", "") && Near(sim.open[0].tp, e.pos.price_open - 6) && sim.open[0].sl == 0, "SELL now: TP only");
   Check(Now(p, GC_SELL, "", "4") && sim.open[0].tp == 0 && Near(sim.open[0].sl, e.pos.price_open + 4), "SELL now: SL only");
   Check(Now(p, GC_BUY, "4010", "3990", true) && Near(sim.open[0].tp, 4010) && Near(sim.open[0].sl, 3990), "BUY now: exact prices as typed");
   Check(!Now(p, GC_BUY, "3990", "", true) && ArraySize(sim.open) == 0, "BUY now: TP on the wrong side opens nothing");
   Check(!Now(p, GC_BUY, "x", "") && ArraySize(sim.open) == 0, "BUY now: a typo opens nothing");
   Check(Now(p, GC_BUY, "", "") && sim.open[0].tp == 0 && sim.open[0].sl == 0, "BUY now: empty boxes = no TP / SL");
  }

//================================================================ dragging the panel
void TestDrag()
  {
   Fresh("drag the panel by its title", 4000);
   CEngine *one = new CEngine();
   one.Init(sim, sink, GC_SINGLE, 101, 100);
   sim.Spec(one.spec);
   bool scroll = ChartGetInteger(0, CHART_MOUSE_SCROLL) != 0;
   CGcPanel p;
   p.Init(10, 20, 1, 0.01);
   p.Render(e, one, _Symbol, "", 0);
   int wide = (int)MathRound(p.width * TerminalInfoInteger(TERMINAL_SCREEN_DPI) / 96.0);
   Check(!p.Mouse(30, 30, false) && ChartGetInteger(0, CHART_MOUSE_SCROLL) == 0, "mouse over the panel: the chart does not scroll");
   Check(!p.Mouse(30, 30, true), "pressed, not moved yet");
   Check(p.Mouse(130, 90, true) && p.X() == 110 && p.Y() == 80, "dragged by the title: " + IntegerToString(p.X()) + "," + IntegerToString(p.Y()));
   Check(ObjectGetInteger(0, "GCP_r_bg", OBJPROP_XDISTANCE) == 110 && ObjectGetInteger(0, "GCP_r_bg", OBJPROP_YDISTANCE) == 80, "the background follows at once");
   long moved_x = ObjectGetInteger(0, "GCP_e_lot", OBJPROP_XDISTANCE), moved_y = ObjectGetInteger(0, "GCP_e_lot", OBJPROP_YDISTANCE);
   p.Render(e, one, _Symbol, "", 0);
   Check(ObjectGetInteger(0, "GCP_e_lot", OBJPROP_XDISTANCE) == moved_x && ObjectGetInteger(0, "GCP_e_lot", OBJPROP_YDISTANCE) == moved_y,
         "moved boxes are exactly where a full redraw puts them");
   Check(!Shown("GCP_t_h_lot"), "no lot step text");
   p.Mouse(130, 90, false);
   Check(!p.Mouse(200, 200, false) && p.X() == 110, "released: it stays");
   p.Mouse(140, 380, false);
   p.Mouse(140, 380, true);
   Check(!p.Mouse(200, 400, true) && p.X() == 110, "pressing on the form does not drag");
   p.Mouse(200, 400, false);
   p.Mouse(p.X() + wide - 20, p.Y() + 10, false);
   p.Mouse(p.X() + wide - 20, p.Y() + 10, true);
   Check(!p.Mouse(300, 300, true) && p.X() == 110, "pressing on the - button does not drag");
   p.Mouse(300, 300, false);
   p.Mouse(130, 90, false);
   p.Mouse(130, 90, true);
   p.Mouse(-500, -500, true);
   Check(p.X() == 0 && p.Y() == 0, "can't be dragged off the chart");
   p.Mouse(-500, -500, false);
   Check((ChartGetInteger(0, CHART_MOUSE_SCROLL) != 0) == scroll, "mouse away: chart scrolling is restored");
   p.Render(e, one, _Symbol, "", 0);
   Check(Shown("GCP_b_float") && ChartGetInteger(0, CHART_IS_DOCKED) != 0, "Float button, chart docked");
   p.ToggleFloat();
   Sleep(1000);
   p.Render(e, one, _Symbol, "", 0);
   Check(ChartGetInteger(0, CHART_IS_DOCKED) == 0, "Float pops the chart out");
   Check(ChartGetInteger(0, CHART_WIDTH_IN_PIXELS) >= wide && p.X() == 0, "the window fits the panel: "
         + IntegerToString(ChartGetInteger(0, CHART_WIDTH_IN_PIXELS)) + " px for " + IntegerToString(wide));
   Check(ObjectGetString(0, "GCP_b_float", OBJPROP_TEXT) == "Dock", "button now says Dock");
   p.ToggleFloat();
   Sleep(1000);
   Check(ChartGetInteger(0, CHART_IS_DOCKED) != 0, "Dock puts it back");
   p.Remove();
   delete one;
  }

//================================================================ changing the open trade, as drawn on the panel
void Snap(const string name)
  {
   ChartRedraw();
   Sleep(700);
   ChartScreenShot(0, "GoldCycle\\" + name + ".png", 1000, 700, ALIGN_RIGHT);
  }
string Box(const string id) { return ObjectGetString(0, "GCP_e_" + id, OBJPROP_TEXT); }
bool Shown(const string name) { return ObjectFind(0, name) >= 0; }

void TestOpenTradePanel()
  {
   string err = "";
   Fresh("change TP / SL of an open trade, Cycle and Single", 3999);
   CEngine *one = new CEngine();
   one.Init(sim, sink, GC_SINGLE, 101, 100);
   sim.Spec(one.spec);
   CGcPanel v;
   v.Init(10, 20, 1, 0.01);
   OpenBuyCycle();
   v.SyncDraft(e.cfg);
   v.advanced = true;
   v.Render(e, one, _Symbol, "", 0);
   Check(Shown("GCP_e_otp") && !Shown("GCP_b_pick_otp") && !Shown("GCP_b_pick_trigger") && !Shown("GCP_b_bid") && Shown("GCP_e_trigger"), "cycle order 1: change-trade section and the form");
   Check(!Shown("GCP_b_setlv") && !Shown("GCP_b_apply") && !Shown("GCP_t_h_j") && !Shown("GCP_t_h_prev") && !Shown("GCP_t_h_log"),
         "no Set / Apply buttons, no journal, preview or log");
   Check(Shown("GCP_e_hours") && !Shown("GCP_b_tside") && !Shown("GCP_b_anchor"), "advanced: hours, no Trigger on / Levels from buttons");
   Check(Box("otp") == "4003.00" && Box("osl") == "", "boxes show order 1's TP, no SL: " + Box("otp") + " / " + Box("osl"));
   Snap("panel_cycle_advanced");
   Check(v.Typed(e, "otp", "4009", err) && err == "" && Near(sim.open[0].tp, 4009) && sim.open[0].sl == 0, "Enter in the TP box changes only the TP: " + err);
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(e, "osl", "3991", err) && err == "" && Near(sim.open[0].tp, 4009) && Near(sim.open[0].sl, 3991), "Enter in the SL box keeps the TP: " + err);
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(e, "otp", "3000", err) && err != "" && Near(sim.open[0].tp, 4009), "wrong side refused");
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("otp") == "4009.00", "the refused box shows the real TP again: " + Box("otp"));
   Check(v.Typed(e, "otp", "40x", err) && err != "" && Near(sim.open[0].tp, 4009), "typo refused");
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(e, "osl", "", err) && err == "" && sim.open[0].sl == 0, "empty box + Enter removes the SL");
   v.Render(e, one, _Symbol, "", 0);
   Check(e.ModifyLevels(4008, 3990, err) && Near(sim.open[0].tp, 4008) && Near(sim.open[0].sl, 3990), "order 1: TP and SL changed");
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("otp") == "4008.00" && Box("osl") == "3990.00", "boxes follow");
   Snap("panel_cycle_order1");
   Check(e.ModifyLevels(4003, 0, err), "SL removed again");
   Move(4003.1);
   v.Render(e, one, _Symbol, "", 0);
   Check(e.leg == 2 && Box("otp") == "" && Box("osl") == "4000.00", "order 2 shows its own SL, not order 1's values: " + Box("otp") + " / " + Box("osl"));
   Check(e.ModifyLevels(4020, 3995, err) && Near(sim.open[0].tp, 4020) && Near(sim.open[0].sl, 3995), "order 2: TP added, SL moved");

   SConfig c = Cfg(GC_SINGLE, GC_BUY, 0, 0);
   c.enter_now = true;
   Check(one.Arm(c, err), "single trade opened");
   v.tab = 1;
   v.Render(e, one, _Symbol, "", 0);
   Check(!Shown("GCP_b_setlv") && Shown("GCP_e_otp") && Shown("GCP_e_osl") && !Shown("GCP_b_pick_osl"), "single: TP / SL boxes, no Pick");
   Check(!Shown("GCP_e_tp") && !Shown("GCP_e_trigger") && !Shown("GCP_b_arm"), "single: the next-trade form is hidden");
   Check(Box("otp") == "" && Box("osl") == "", "no TP/SL yet");
   double bid = sim.bid;
   Check(one.ModifyLevels(bid + 10, bid - 10, err) && Near(sim.open[1].tp, bid + 10) && Near(sim.open[1].sl, bid - 10), "single: set on the trade");
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("otp") == DoubleToString(bid + 10, 2), "box follows");
   Snap("panel_single_open");
   Check(one.ModifyLevels(0, 0, err) && sim.open[1].tp == 0 && sim.open[1].sl == 0, "single: both removed");
   v.Render(e, one, _Symbol, "", 0);
   // typed but never sent, then a NEW trade: the old text must not be there
   v.draft[1].otp = "4100.00";
   ObjectSetString(0, "GCP_e_otp", OBJPROP_TEXT, "4100.00");
   one.StopNow(err); Wait(); one.Step(); sim.ms += 1100; one.Step();
   v.Render(e, one, _Symbol, "", 0);
   Check(Shown("GCP_e_trigger") && !Shown("GCP_e_otp"), "after closing: the form is back");
   Check(one.Arm(c, err), "next single trade");
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("otp") == "" && v.draft[1].otp == "", "no left-over TP from the previous trade: '" + Box("otp") + "'");

   // TP / SL typed as points from the entry: BUY first
   double in = one.pos.price_open;
   v.SetOpenPoints(true);
   v.Render(e, one, _Symbol, "", 0);
   Check(Shown("GCP_b_oprice") && Shown("GCP_b_opoints"), "Price / Points switch");
   Check(v.Typed(one, "otp", "5", err) && err == "" && Near(one.cur_tp, in + 5), "BUY: TP 5 points is 5.00 above the entry: " + err);
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("otp") == "5", "box shows points: " + Box("otp"));
   Check(v.Typed(one, "osl", "4", err) && err == "" && Near(one.cur_sl, in - 4) && Near(one.cur_tp, in + 5), "BUY: SL 4 points below, TP kept: " + err);
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(one, "osl", "99999", err) && err != "" && Near(one.cur_sl, in - 4), "points past price 0 refused, SL not removed");
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(one, "otp", "abc", err) && err != "" && Near(one.cur_tp, in + 5), "points typo refused");
   v.SetOpenPoints(false);
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("otp") == DoubleToString(in + 5, 2) && Box("osl") == DoubleToString(in - 4, 2), "back to prices: " + Box("otp"));
   v.SetOpenPoints(true);
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(one, "osl", "", err) && err == "" && one.cur_sl == 0, "empty removes it in points too");

   // SELL: the other way round, and a negative SL locks in profit
   one.StopNow(err); Wait(); one.Step(); sim.ms += 1100; one.Step();
   c.dir = GC_SELL;
   Check(one.Arm(c, err), "SELL single opened: " + err);
   in = one.pos.price_open;
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(one, "otp", "20", err) && err == "" && Near(one.cur_tp, in - 20), "SELL: TP points below the entry: " + err);
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(one, "osl", "3", err) && err == "" && Near(one.cur_sl, in + 3), "SELL: SL points above the entry: " + err);
   sim.Price(sim.bid - 5);
   one.Step();
   v.Render(e, one, _Symbol, "", 0);
   Check(v.Typed(one, "osl", "-1", err) && err == "" && Near(one.cur_sl, in - 1), "SELL: SL -1 is 1 point in profit: " + err);
   v.Render(e, one, _Symbol, "", 0);
   Check(Box("osl") == "-1", "box shows it: " + Box("osl"));
   Snap("panel_single_points");
   v.SetOpenPoints(false);
   v.Remove();
   delete one;
  }

void OnStart()
  {
   FolderCreate("GoldCycle");
   g_file = FileOpen("GoldCycle\\test_results.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   TestRules();
   TestCycle();
   TestLive();
   TestSingle();
   TestRestart();
   TestEdges();
   TestPanel();
   TestOpenTradePanel();
   TestDrag();
   TestBuyNow();
   Out("RESULT: " + IntegerToString(g_pass) + " passed, " + IntegerToString(g_fail) + " failed");
   if(g_file != INVALID_HANDLE)
      FileClose(g_file);
   if(CheckPointer(e) == POINTER_DYNAMIC) delete e;
   if(CheckPointer(sim) == POINTER_DYNAMIC) delete sim;
   if(CheckPointer(sink) == POINTER_DYNAMIC) delete sink;
   if(FileIsExist("GoldCycle\\autoclose.txt"))
      TerminalClose(0);
  }
//+------------------------------------------------------------------+
