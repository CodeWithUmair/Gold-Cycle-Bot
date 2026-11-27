//+------------------------------------------------------------------+
//| LIVE end-to-end test of the GoldCycle Expert on a DEMO account.  |
//| Sends real 0.01 lot orders through the EA by "pressing" its      |
//| panel buttons. The EA must run on the same chart with            |
//| InpTestHooks = true. Refuses to run on a real account.           |
//| Results: MQL5\Files\GoldCycle\live_results.txt + screenshots.    |
//| Restart check: put restart_open.txt in Files\GoldCycle and run   |
//| it (leaves one Single trade open), restart MetaTrader, then run  |
//| it again with restart_resume.txt instead.                        |
//+------------------------------------------------------------------+
#property copyright "GoldCycle"
#property version   "1.00"

#define MAGIC_CYCLE  8800501
#define MAGIC_SINGLE 8800502

int g_f = INVALID_HANDLE, g_pass = 0, g_fail = 0;

void Out(const string s)
  {
   Print(s);
   if(g_f != INVALID_HANDLE)
     {
      FileWriteString(g_f, TimeToString(TimeCurrent(), TIME_SECONDS) + "  " + s + "\r\n");
      FileFlush(g_f);
     }
  }
void Check(const bool ok, const string what)
  {
   if(ok) g_pass++; else g_fail++;
   Out((ok ? "PASS  " : "FAIL  ") + what);
  }
void Click(const string id) { EventChartCustom(0, 1, 0, 0, "GCP_b_" + id); Sleep(900); }
void Type(const string id, const string v) { EventChartCustom(0, 2, 0, 0, "GCP_e_" + id + "=" + v); Sleep(500); }
void Shot(const string name)
  {
   ChartRedraw();
   Sleep(1200);
   if(!ChartScreenShot(0, "GoldCycle\\" + name + ".png", 1400, 760, ALIGN_RIGHT))
      Out("screenshot " + name + " failed " + IntegerToString(GetLastError()));
  }
double Bid() { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double Ask() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }

// the position of one bot (0 = none)
ulong Pos(const long magic)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         return t;
     }
   return 0;
  }
int PosCount(const long magic)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == _Symbol)
         n++;
     }
   return n;
  }
ulong WaitPos(const long magic, const int seconds)
  {
   for(int i = 0; i < seconds * 10; i++)
     {
      ulong t = Pos(magic);
      if(t != 0) return t;
      Sleep(100);
     }
   return 0;
  }
bool WaitGone(const ulong ticket, const int seconds)
  {
   for(int i = 0; i < seconds * 10; i++)
     {
      if(!PositionSelectByTicket(ticket)) return true;
      Sleep(100);
     }
   return false;
  }

// what MetaTrader's history says about a closed position
bool History(const ulong id, double &open_price, double &close_price, long &reason, double &profit, long &open_ms, long &close_ms)
  {
   open_price = 0; close_price = 0; reason = -1; profit = 0; open_ms = 0; close_ms = 0;
   for(int k = 0; k < 50; k++)
     {
      if(HistorySelectByPosition(id) && HistoryDealsTotal() >= 2)
         break;
      Sleep(100);
     }
   if(!HistorySelectByPosition(id)) return false;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      profit += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
        { open_price = HistoryDealGetDouble(d, DEAL_PRICE); open_ms = HistoryDealGetInteger(d, DEAL_TIME_MSC); }
      else
        { close_price = HistoryDealGetDouble(d, DEAL_PRICE); reason = HistoryDealGetInteger(d, DEAL_REASON); close_ms = HistoryDealGetInteger(d, DEAL_TIME_MSC); }
     }
   return close_ms > 0;
  }

// a value from the EA's saved state file
string State(const string bot, const string key)
  {
   string name = "GoldCycle\\" + bot + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + _Symbol + "_" + IntegerToString(MAGIC_CYCLE) + ".state";
   int f = FileOpen(name, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(f == INVALID_HANDLE) return "";
   string v = "";
   while(!FileIsEnding(f))
     {
      string line = FileReadString(f);
      if(StringFind(line, key + "=") == 0) { v = StringSubstr(line, StringLen(key) + 1); break; }
     }
   FileClose(f);
   return v;
  }
string StateName(const string bot)
  {
   string s = State(bot, "state");
   if(s == "0") return "IDLE";
   if(s == "1") return "ARMED";
   if(s == "2") return "OPENING";
   if(s == "3") return "IN_POSITION";
   if(s == "4") return "RESOLVING";
   if(s == "5") return "STOPPED";
   return "?";
  }

void SingleTest()
  {
   Out("--- SINGLE: Buy now, type TP/SL, Close trade");
   Click("tab1");
   Type("lot", "0.01");
   Check(Pos(MAGIC_SINGLE) == 0, "no Single position before");
   Type("tp", ""); Type("sl", "");
   Click("buynow");
   ulong t = WaitPos(MAGIC_SINGLE, 15);
   Check(t != 0, "Buy now opened a position #" + IntegerToString((long)t));
   if(t == 0) return;
   PositionSelectByTicket(t);
   Out("position: price " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 3) + " tp " + DoubleToString(PositionGetDouble(POSITION_TP), 3)
       + " sl " + DoubleToString(PositionGetDouble(POSITION_SL), 3) + " comment '" + PositionGetString(POSITION_COMMENT) + "'");
   Check(PositionGetDouble(POSITION_TP) == 0 && PositionGetDouble(POSITION_SL) == 0, "Buy now with empty TP/SL boxes opens with none");
   Check(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && MathAbs(PositionGetDouble(POSITION_VOLUME) - 0.01) < 1e-9, "BUY 0.01");
   double tp = NormalizeDouble(Bid() + 25, 2), sl = NormalizeDouble(Bid() - 25, 2);
   Sleep(600);
   Type("otp", DoubleToString(tp, 2));
   Type("osl", DoubleToString(sl, 2));
   Sleep(1500);
   PositionSelectByTicket(t);
   Check(MathAbs(PositionGetDouble(POSITION_TP) - tp) < 0.01 && MathAbs(PositionGetDouble(POSITION_SL) - sl) < 0.01,
         "TP/SL set on the server position: " + DoubleToString(PositionGetDouble(POSITION_TP), 2) + " / " + DoubleToString(PositionGetDouble(POSITION_SL), 2));
   // the trader drags a line in MetaTrader: the bot must follow
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_SLTP; req.symbol = _Symbol; req.position = t; req.tp = NormalizeDouble(tp + 5, 2); req.sl = sl;
   bool sent = OrderSend(req, res);
   Sleep(1500);
   Check(sent && MathAbs(StringToDouble(State("single", "cur_tp")) - (tp + 5)) < 0.01, "bot follows a TP changed in MetaTrader");
   Shot("shot_single_open");
   Click("stopnow");
   Check(WaitGone(t, 15), "Close trade closed it");
   double op, cp, profit;
   long reason, oms, cms;
   bool h = History(t, op, cp, reason, profit, oms, cms);
   Check(h, "MetaTrader history has the open and close: " + DoubleToString(op, 3) + " -> " + DoubleToString(cp, 3) + " P/L " + DoubleToString(profit, 2));
   Sleep(1500);
   Check(StateName("single") == "IDLE", "Single back to IDLE (" + StateName("single") + ")");
  }

bool Levels(const ulong t, const double tp, const double sl)
  {
   if(!PositionSelectByTicket(t))
      return false;
   Out("server position: TP " + DoubleToString(PositionGetDouble(POSITION_TP), 3) + " SL " + DoubleToString(PositionGetDouble(POSITION_SL), 3));
   return MathAbs(PositionGetDouble(POSITION_TP) - tp) < 0.011 && MathAbs(PositionGetDouble(POSITION_SL) - sl) < 0.011;
  }

// BUY now takes the TP / SL boxes, the open trade takes points, SELL now takes exact prices
void LevelsTest()
  {
   Out("--- SINGLE: Buy now with TP 6 / SL 4 points");
   Click("tab1");
   Type("lot", "0.01"); Type("tp", "6"); Type("sl", "4");
   Click("buynow");
   ulong t = WaitPos(MAGIC_SINGLE, 15);
   Check(t != 0, "Buy now with levels opened #" + IntegerToString((long)t));
   if(t != 0)
     {
      Sleep(2500);
      PositionSelectByTicket(t);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      Check(Levels(t, open + 6, open - 4), "TP is 6 above and SL 4 below the fill " + DoubleToString(open, 3));
      Click("opoints");
      Type("otp", "8"); Type("osl", "5");
      Sleep(1500);
      Check(Levels(t, open + 8, open - 5), "points typed on the open trade reach the server (TP 8, SL 5)");
      Shot("shot_points");
      Click("oprice");
      Click("stopnow");
      Check(WaitGone(t, 15), "Close trade closed it");
      Sleep(2000);
     }
   Out("--- SINGLE: Sell now with exact TP / SL prices");
   Click("unit");   // Points -> exact prices (clears both boxes)
   double tp = NormalizeDouble(Bid() - 20, 2), sl = NormalizeDouble(Bid() + 20, 2);
   Type("tp", DoubleToString(tp, 2)); Type("sl", DoubleToString(sl, 2));
   Click("sellnow");
   t = WaitPos(MAGIC_SINGLE, 15);
   Check(t != 0, "Sell now with prices opened #" + IntegerToString((long)t));
   if(t != 0)
     {
      Sleep(2500);
      Check(Levels(t, tp, sl) && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL, "SELL with TP " + DoubleToString(tp, 2) + " / SL " + DoubleToString(sl, 2));
      Click("stopnow");
      Check(WaitGone(t, 15), "Close trade closed it");
      Sleep(2000);
     }
   Click("unit");   // back to points

   Out("--- panel: Float / Dock");
   Click("float");
   Sleep(1500);
   Check(ChartGetInteger(0, CHART_IS_DOCKED) == 0, "Float pops the chart out of MetaTrader");
   Click("float");
   Sleep(1500);
   Check(ChartGetInteger(0, CHART_IS_DOCKED) != 0, "Dock puts it back");
  }

// one cycle with a small TP; waits to see order 2 open at order 1's TP. Returns true if it was observed.
bool CycleAttempt(const int dir, const int wait_seconds)
  {
   int side = dir == 0 ? 1 : -1;
   Click("tab0");
   Click(dir == 0 ? "buy" : "sell");
   double trigger = NormalizeDouble(Bid() + side * 0.15, 2);
   Type("trigger", DoubleToString(trigger, 2));
   Type("lot", "0.01");
   Type("tp", "0.6");
   Type("gap", "");
   Type("stop", DoubleToString(trigger - side * 8.0, 2));
   if(ObjectFind(0, "GCP_e_maxc") < 0) Click("adv");
   Type("maxc", "1");
   Type("mspread", "1");
   Type("mslip", "1");
   Out("--- CYCLE " + (dir == 0 ? "BUY" : "SELL") + " trigger " + DoubleToString(trigger, 2) + " (bid " + DoubleToString(Bid(), 2) + "), TP 0.6, max 1 cycle");
   Shot("shot_cycle_form");
   Click("arm");
   Sleep(1000);
   string st = StateName("cycle");
   Check(st == "ARMED" || st == "OPENING" || st == "IN_POSITION", "cycle started (" + st + ")");
   ulong first = WaitPos(MAGIC_CYCLE, wait_seconds);
   if(first == 0)
     {
      Out("price did not touch the trigger in " + IntegerToString(wait_seconds) + " s");
      Click("killall");
      Sleep(1500);
      return false;
     }
   PositionSelectByTicket(first);
   double entry_fill = PositionGetDouble(POSITION_PRICE_OPEN), tp1 = PositionGetDouble(POSITION_TP);
   Check(PositionGetDouble(POSITION_SL) == 0 && MathAbs(tp1 - (trigger + side * 0.6)) < 0.011,
         "order 1: fill " + DoubleToString(entry_fill, 3) + ", TP " + DoubleToString(tp1, 2) + " = trigger + 0.6, no SL, comment '" + PositionGetString(POSITION_COMMENT) + "'");
   Shot("shot_cycle_order1");
   int max_positions = 1;
   ulong second = 0;
   for(int i = 0; i < wait_seconds * 10 && second == 0; i++)
     {
      max_positions = MathMax(max_positions, PosCount(MAGIC_CYCLE));
      ulong now = Pos(MAGIC_CYCLE);
      if(now != 0 && now != first) second = now;
      if(now == 0 && StateName("cycle") == "STOPPED") break;
      Sleep(100);
     }
   if(second == 0)
     {
      Out("order 1 did not reach its TP in time: using Close all");
      Click("killall");
      Check(WaitGone(first, 15), "Close all closed the open order");
      Sleep(1500);
      Check(StateName("cycle") == "STOPPED", "cycle stopped by Close all (" + StateName("cycle") + ")");
      return false;
     }
   PositionSelectByTicket(second);
   double sl2 = PositionGetDouble(POSITION_SL), tp2 = PositionGetDouble(POSITION_TP);
   double op, cp, profit;
   long reason, oms, cms;
   History(first, op, cp, reason, profit, oms, cms);
   long open2 = 0;
   if(PositionSelectByTicket(second)) open2 = PositionGetInteger(POSITION_TIME_MSC);
   Check(reason == DEAL_REASON_TP, "order 1 closed by the broker's TP at " + DoubleToString(cp, 3) + " (P/L " + DoubleToString(profit, 2) + ")");
   Check(open2 - cms >= 0 && open2 - cms < 3000, "order 2 opened " + IntegerToString(open2 - cms) + " ms after order 1's TP");
   Check(MathAbs(sl2 - trigger) < 0.011 && tp2 == 0, "order 2: SL " + DoubleToString(sl2, 2) + " = order 1's entry, no TP");
   Check(max_positions == 1, "never two cycle trades at once");
   Shot("shot_cycle_order2");
   return true;
  }

// leaves one Single trade open, so that a MetaTrader restart can be tested
void OpenForRestart()
  {
   Out("--- restart check, part 1: open one Single trade and leave it open");
   Click("tab1");
   Type("lot", "0.01");
   Click("buynow");
   ulong t = WaitPos(MAGIC_SINGLE, 15);
   Sleep(1500);
   Check(t != 0 && StateName("single") == "IN_POSITION", "Single trade open #" + IntegerToString((long)t));
  }

void ResumeAfterRestart()
  {
   Out("--- restart check, part 2: after a MetaTrader restart");
   Shot("shot_after_restart");
   if(State("cycle", "resumable") == "1")
     {
      string was = State("cycle", "pos.ticket");
      bool still = Pos(MAGIC_CYCLE) != 0;
      Click("tab0");
      Click("resume");
      Sleep(4000);
      Check(State("cycle", "resumable") == "0", "Cycle resumed: " + StateName("cycle") + " " + State("cycle", "stop_reason"));
      if(!still)
         Check(Pos(MAGIC_CYCLE) == 0, "trade #" + was + " that closed while the bot was off was read from history");
      Shot("shot_cycle_resumed");
     }
   ulong t = Pos(MAGIC_SINGLE);
   Check(t != 0, "the Single trade is still open on the broker #" + IntegerToString((long)t));
   if(t != 0)
     {
      Check(StateName("single") == "STOPPED" && State("single", "resumable") == "1", "the bot asks to Resume and does nothing by itself");
      Click("tab1");
      Click("resume");
      Sleep(3000);
      Check(StateName("single") == "IN_POSITION" && PosCount(MAGIC_SINGLE) == 1, "Resume reattaches the same trade, no duplicate (" + StateName("single") + ")");
      Shot("shot_resumed");
      Click("killall");
      Check(WaitGone(t, 15), "Close all closed it");
      Sleep(1500);
      Check(StateName("single") == "STOPPED", "stopped");
     }
   Check(Pos(MAGIC_CYCLE) == 0 && Pos(MAGIC_SINGLE) == 0, "no GoldCycle position left open");
   Shot("shot_end");
  }

// the buttons the main run does not press, with real demo orders. Ends with a timeframe switch while a trade is open
// (that removes this script; afterwards check that the bot carried on by itself).
void ButtonsTest()
  {
   Out("--- SINGLE: start at a far trigger, then Cancel");
   Click("tab1");
   Type("lot", "0.01");
   Type("trigger", DoubleToString(Bid() - 15, 2));
   Type("tp", ""); Type("sl", "");
   Click("arm");
   Check(StateName("single") == "ARMED" && Pos(MAGIC_SINGLE) == 0, "armed, waiting (" + StateName("single") + ")");
   Click("stopnow");
   Check(StateName("single") == "STOPPED" && Pos(MAGIC_SINGLE) == 0, "Cancel: stopped without a trade");

   Out("--- CYCLE: a typo must never start the bot");
   Click("tab0");
   Click("buy");
   Type("trigger", DoubleToString(Bid() - 15, 2));
   Type("lot", "0.01");
   Type("tp", "abc");
   Type("gap", ""); Type("stop", "");
   Click("arm");
   Check(StateName("cycle") != "ARMED" && StateName("cycle") != "OPENING" && Pos(MAGIC_CYCLE) == 0, "TP 'abc' refused (" + StateName("cycle") + ")");

   Out("--- CYCLE: change the trigger while waiting");
   Type("tp", "20");
   if(ObjectFind(0, "GCP_e_maxc") < 0) Click("adv");
   Type("maxc", "1"); Type("mspread", "1"); Type("mslip", "1"); Type("dloss", ""); Type("hours", "");
   Click("arm");
   Check(StateName("cycle") == "ARMED", "armed (" + StateName("cycle") + ")");
   double moved = NormalizeDouble(Bid() - 12, 2);
   Type("trigger", DoubleToString(moved, 2));
   Check(MathAbs(StringToDouble(State("cycle", "planned")) - moved) < 0.001 && Pos(MAGIC_CYCLE) == 0, "waiting level moved to " + DoubleToString(moved, 2));
   Click("stopnow");

   Out("--- CYCLE: open order 1, change TP live, Stop after cycle, Stop now, set TP/SL, Close all");
   ulong t = 0;
   double trig = 0;
   int side = 1;
   for(int attempt = 0; attempt < 4 && t == 0 && !IsStopped(); attempt++)
     {
      int dir = (Bid() >= iClose(_Symbol, PERIOD_M1, 2)) ? 0 : 1;
      if(attempt % 2 == 1) dir = 1 - dir;
      side = dir == 0 ? 1 : -1;
      Click(dir == 0 ? "buy" : "sell");
      trig = NormalizeDouble(Bid() + side * 0.05, 2);
      Type("trigger", DoubleToString(trig, 2));
      Type("tp", "20");
      Click("arm");
      t = WaitPos(MAGIC_CYCLE, 60);
      if(t == 0) Click("stopnow");
     }
   Check(t != 0, "order 1 open #" + IntegerToString((long)t));
   if(t != 0)
     {
      Sleep(1500);
      Type("tp", "25");
      Shot("shot_tp_typed");
      Sleep(1500);
      PositionSelectByTicket(t);
      Check(MathAbs(PositionGetDouble(POSITION_TP) - (trig + side * 25)) < 0.011, "typing a new TP moved it on the server to " + DoubleToString(PositionGetDouble(POSITION_TP), 2));
      Click("after");
      Check(State("cycle", "stop_after") == "1" && StateName("cycle") == "IN_POSITION", "Stop after cycle noted");
      Click("stopnow");
      Sleep(1000);
      Check(StateName("cycle") == "STOPPED" && PositionSelectByTicket(t), "Stop now: bot stopped, the trade stays open");
      double tp = NormalizeDouble(trig + side * 30, 2), sl = NormalizeDouble(trig - side * 30, 2);
      Type("otp", DoubleToString(tp, 2)); Type("osl", DoubleToString(sl, 2));
      Sleep(1500);
      PositionSelectByTicket(t);
      Check(MathAbs(PositionGetDouble(POSITION_TP) - tp) < 0.011 && MathAbs(PositionGetDouble(POSITION_SL) - sl) < 0.011, "TP/SL set on the left-open trade");
      Shot("shot_left_open");
      Click("killall");
      Check(WaitGone(t, 15), "Close all closed the left-open trade");
     }

   Out("--- timeframe switch while a Single trade is open");
   Click("tab1");
   Click("buynow");
   ulong one = WaitPos(MAGIC_SINGLE, 15);
   Check(one != 0, "Single trade open #" + IntegerToString((long)one));
   Out("RESULT (buttons, before the switch): " + IntegerToString(g_pass) + " passed, " + IntegerToString(g_fail) + " failed");
   if(g_f != INVALID_HANDLE) { FileClose(g_f); g_f = INVALID_HANDLE; }
   EventChartCustom(0, 3, PERIOD_M5, 0, "");
   Sleep(30000);   // the timeframe change removes this script
  }

void OnStart()
  {
   FolderCreate("GoldCycle");
   string mode = FileIsExist("GoldCycle\\buttons.txt") ? "buttons" : FileIsExist("GoldCycle\\restart_open.txt") ? "open" : FileIsExist("GoldCycle\\restart_resume.txt") ? "resume" : "full";
   g_f = FileOpen(mode == "full" ? "GoldCycle\\live_results.txt" : "GoldCycle\\live_results_" + mode + ".txt",
                  FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   for(int i = 0; i < 600 && (AccountInfoInteger(ACCOUNT_LOGIN) == 0 || ObjectFind(0, "GCP_r_bg") < 0); i++)
      Sleep(100);
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE) != ACCOUNT_TRADE_MODE_DEMO)
     {
      Out("REFUSED: this is not a demo account");
      Finish();
      return;
     }
   Sleep(4000);
   long age = (long)(TimeTradeServer() - (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME));
   Out("account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + " demo, balance " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
       + ", " + _Symbol + " bid " + DoubleToString(Bid(), 3) + " spread " + DoubleToString(Ask() - Bid(), 3) + ", last price " + IntegerToString(age) + " s ago");
   Check(ObjectFind(0, "GCP_r_bg") >= 0, "the Expert's panel is on the chart");
   Check(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 && MQLInfoInteger(MQL_TRADE_ALLOWED) != 0, "Algo Trading allowed");
   if(age > 120 || ObjectFind(0, "GCP_r_bg") < 0)
     {
      Out(age > 120 ? "market looks closed: no orders sent" : "no panel: nothing to test");
      Finish();
      return;
     }
   if(mode == "buttons")
      ButtonsTest();
   else if(mode == "open")
      OpenForRestart();
   else if(mode == "resume")
      ResumeAfterRestart();
   else
     {
      Shot("shot_idle");
      SingleTest();
      LevelsTest();
      bool seen = false;
      for(int attempt = 0; attempt < 4 && !seen && !IsStopped(); attempt++)
        {
         // follow the last minutes' direction: a better chance that the small TP is reached
         double prev = iClose(_Symbol, PERIOD_M1, 3);
         int dir = (Bid() >= prev) ? 0 : 1;
         if(attempt % 2 == 1) dir = 1 - dir;
         seen = CycleAttempt(dir, 150);
        }
      Check(seen, "order 1 TP -> order 2 observed live");
      Click("tab0");
      Click("killall");   // never leave a test trade open
      Sleep(3000);
      Check(Pos(MAGIC_CYCLE) == 0 && Pos(MAGIC_SINGLE) == 0, "no GoldCycle position left open");
      Shot("shot_end");
     }
   Out("RESULT (" + mode + "): " + IntegerToString(g_pass) + " passed, " + IntegerToString(g_fail) + " failed, balance "
       + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Finish();
  }

void Finish()
  {
   if(g_f != INVALID_HANDLE) FileClose(g_f);
   if(FileIsExist("GoldCycle\\autoclose.txt"))
      TerminalClose(0);
  }
//+------------------------------------------------------------------+
