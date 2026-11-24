//+------------------------------------------------------------------+
//| GoldCycle engine tests: the client's rules on a simulated broker.|
//| Sends NO orders. Run it on any chart; results go to the Experts  |
//| log and MQL5\Files\GoldCycle\test_results.txt                    |
//+------------------------------------------------------------------+
#property copyright "GoldCycle"
#property version   "1.00"
#include <GoldCycle\Engine.mqh>
#include <GoldCycle\SimBroker.mqh>

class CTestSink : public CGcSink
  {
public:
   int               block;
   string            last;
   int               closedRows;
                     CTestSink() { block = -1; last = ""; closedRows = 0; }
   virtual void      Event(const string level, const string msg, const bool toast) override { last = msg; }
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

void OnStart()
  {
   FolderCreate("GoldCycle");
   g_file = FileOpen("GoldCycle\\test_results.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   TestRules();
   TestCycle();
   TestLive();
   TestSingle();
   TestRestart();
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
