//+------------------------------------------------------------------+
//|                                                    GoldCycle.mq5 |
//| Auto TP/SL cycle + single trade Expert Advisor for gold.         |
//| The trader chooses where to trade; the bot only executes.        |
//| Attach to one XAUUSD chart. Panel: Cycle and Single run side by  |
//| side, each with its own magic number (Single = magic + 1).       |
//+------------------------------------------------------------------+
#property copyright   "GoldCycle"
#property version     "1.00"
#property description "Cycle (two-order cycle) and Single trades with TP/SL, stop price and safety limits."
#property description "Point = 1.00 of price. Turn on 'Algo Trading' and allow it for this expert."

#include <GoldCycle\Engine.mqh>
#include <GoldCycle\Panel.mqh>

input long   InpMagic           = 8800501; // Magic number (Single uses this + 1)
input double InpDefaultLot      = 0.01;    // Starting lot shown in the panel
input int    InpPanelX          = 10;      // Panel position X
input int    InpPanelY          = 20;      // Panel position Y
input bool   InpPopupAlerts     = true;    // Pop-up alert when the bot stops or has a problem
input bool   InpSounds          = true;    // Sound on fills
input bool   InpPushToPhone     = false;   // Send events to the MetaTrader phone app
input bool   InpResumeOnRestart = false;   // After a restart continue without asking "Resume?"
input bool   InpTestHooks       = false;   // Automated testing only - keep false

CMt5Broker g_broker;
CEngine    g_cycle;
CEngine    g_single;
CGcPanel   g_panel;
bool       g_loaded = false;
bool       g_autoPending = false;
long       g_login = 0;
double     g_today = 0;
ulong      g_todayAt = 0;
ulong      g_renderAt = 0;

string FileFor(const string what, const string ext)
  {
   return "GoldCycle\\" + what + "_" + IntegerToString(g_login) + "_" + _Symbol + "_" + IntegerToString(InpMagic) + ext;
  }

class CEaSink : public CGcSink
  {
public:
   virtual void      Event(const string level, const string msg, const bool toast) override
     {
      Print("GoldCycle ", level, ": ", msg);
      g_panel.Log(level, msg);
      if(!toast)
         return;
      if(InpPopupAlerts && level != "info")
         Alert("GoldCycle: ", msg);
      else if(InpSounds)
         PlaySound("ok.wav");
      if(InpPushToPhone && !SendNotification(StringSubstr("GoldCycle " + _Symbol + ": " + msg, 0, 250)))
         Print("GoldCycle: phone notification not sent (set your MetaQuotes ID in Tools > Options > Notifications)");
     }
   virtual void      Closed(const SRow &r, const int mode, const string session) override
     {
      string name = FileFor("journal", ".csv");
      int f = FileOpen(name, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(f == INVALID_HANDLE)
        {
         Print("GoldCycle: journal file not written (is it open in Excel?) error ", GetLastError());
         return;
        }
      if(FileSize(f) == 0)
         FileWriteString(f, "open_time,close_time,bot,session,cycle,order,direction,lot,planned,fill,slippage,tp,sl,close_price,result,pnl,ticket\r\n");
      FileSeek(f, 0, SEEK_END);
      FileWriteString(f, TimeToString(r.open_time, TIME_DATE | TIME_SECONDS) + "," + TimeToString(r.close_time, TIME_DATE | TIME_SECONDS)
                      + "," + GcModeName(mode) + "," + session + "," + IntegerToString(r.cycle) + "," + IntegerToString(r.leg) + "," + GcDirName(r.dir)
                      + "," + GcNum(r.volume) + "," + DoubleToString(r.planned, _Digits) + "," + DoubleToString(r.fill, _Digits)
                      + "," + DoubleToString(r.slippage, 2) + "," + DoubleToString(r.tp, _Digits) + "," + DoubleToString(r.sl, _Digits)
                      + "," + DoubleToString(r.close_price, _Digits) + "," + GcReasonName(r.reason) + "," + DoubleToString(r.pnl, 2)
                      + "," + IntegerToString((long)r.ticket) + "\r\n");
      FileClose(f);
     }
   // the daily loss block is shared by both bots and survives restarts (terminal global variable)
   string            Key() { return "GC_block_" + IntegerToString(g_login) + "_" + IntegerToString(InpMagic); }
   virtual int       BlockDay() override { return GlobalVariableCheck(Key()) ? (int)GlobalVariableGet(Key()) : -1; }
   virtual void      SetBlockDay(const int day) override { GlobalVariableSet(Key(), day); }
  };

CEaSink g_sink;

//------------------------------------------------------------------ save / load
bool WriteLines(const string name, const string &lines[])
  {
   int f = FileOpen(name + ".tmp", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(f == INVALID_HANDLE)
     {
      Print("GoldCycle: could not save ", name, " error ", GetLastError());
      return false;
     }
   for(int i = 0; i < ArraySize(lines); i++)
      FileWriteString(f, lines[i] + "\r\n");
   FileClose(f);
   return FileMove(name + ".tmp", 0, name, FILE_REWRITE);
  }

bool ReadLines(const string name, string &lines[])
  {
   ArrayResize(lines, 0);
   if(!FileIsExist(name))
      return false;
   int f = FileOpen(name, FILE_READ | FILE_TXT | FILE_ANSI);
   if(f == INVALID_HANDLE)
      return false;
   while(!FileIsEnding(f))
      GcAdd(lines, FileReadString(f));
   FileClose(f);
   return true;
  }

// reason -1 = saved while running (a crash leaves it so: ask "Resume?")
void SaveState(CEngine &e, const int reason)
  {
   string lines[];
   e.Serialize(lines);
   GcAdd(lines, "saved_reason=" + IntegerToString(reason));
   GcAdd(lines, "saved_at=" + IntegerToString((long)TimeLocal()));
   WriteLines(FileFor(e.mode == GC_CYCLE ? "cycle" : "single", ".state"), lines);
   e.dirty = false;
  }

void LoadState(CEngine &e)
  {
   string lines[];
   if(!ReadLines(FileFor(e.mode == GC_CYCLE ? "cycle" : "single", ".state"), lines) || !e.Deserialize(lines))
      return;
   int reason = -1;
   long at = 0;
   for(int i = 0; i < ArraySize(lines); i++)
     {
      if(StringFind(lines[i], "saved_reason=") == 0)
         reason = (int)StringToInteger(StringSubstr(lines[i], 13));
      if(StringFind(lines[i], "saved_at=") == 0)
         at = StringToInteger(StringSubstr(lines[i], 9));
     }
   // a timeframe change, a settings change or a re-compile is not a restart: carry on without asking
   bool same_run = (reason == REASON_CHARTCHANGE || reason == REASON_PARAMETERS || reason == REASON_RECOMPILE || reason == REASON_TEMPLATE)
                   && (long)TimeLocal() - at < 120;
   bool auto_resume = same_run || InpResumeOnRestart;
   if(e.hasCfg)
      g_panel.SyncDraft(e.cfg);
   e.Recover(auto_resume);
   if(auto_resume && e.resumable)
      g_autoPending = true;
  }

void SaveForm()
  {
   string lines[];
   GcAdd(lines, "tab=" + IntegerToString(g_panel.tab));
   GcAdd(lines, "collapsed=" + IntegerToString(g_panel.collapsed));
   GcAdd(lines, "advanced=" + IntegerToString(g_panel.advanced));
   for(int i = 0; i < 2; i++)
     {
      SDraft d;
      d = g_panel.draft[i];
      GcAdd(lines, "form=" + IntegerToString(i) + "|" + IntegerToString(d.dir) + "|" + d.trigger + "|" + d.lot + "|" + d.tp + "|" + d.sl + "|" + d.gap
            + "|" + d.stop + "|" + d.maxc + "|" + d.dloss + "|" + d.mspread + "|" + d.mslip + "|" + d.hours + "|" + IntegerToString(d.anchor)
            + "|" + IntegerToString(d.tside) + "|" + IntegerToString(d.price_input));
     }
   WriteLines(FileFor("form", ".txt"), lines);
  }

void LoadForm()
  {
   string lines[];
   if(!ReadLines(FileFor("form", ".txt"), lines))
      return;
   for(int i = 0; i < ArraySize(lines); i++)
     {
      if(StringFind(lines[i], "tab=") == 0)
         g_panel.tab = (int)StringToInteger(StringSubstr(lines[i], 4));
      if(StringFind(lines[i], "collapsed=") == 0)
         g_panel.collapsed = StringToInteger(StringSubstr(lines[i], 10)) != 0;
      if(StringFind(lines[i], "advanced=") == 0)
         g_panel.advanced = StringToInteger(StringSubstr(lines[i], 9)) != 0;
      if(StringFind(lines[i], "form=") != 0)
         continue;
      string f[];
      if(StringSplit(StringSubstr(lines[i], 5), '|', f) != 16)
         continue;
      int m = (int)StringToInteger(f[0]);
      if(m < 0 || m > 1)
         continue;
      g_panel.draft[m].dir = (int)StringToInteger(f[1]); g_panel.draft[m].trigger = f[2]; g_panel.draft[m].lot = f[3]; g_panel.draft[m].tp = f[4];
      g_panel.draft[m].sl = f[5]; g_panel.draft[m].gap = f[6]; g_panel.draft[m].stop = f[7]; g_panel.draft[m].maxc = f[8]; g_panel.draft[m].dloss = f[9];
      g_panel.draft[m].mspread = f[10]; g_panel.draft[m].mslip = f[11]; g_panel.draft[m].hours = f[12];
      g_panel.draft[m].anchor = (int)StringToInteger(f[13]); g_panel.draft[m].tside = (int)StringToInteger(f[14]);
      g_panel.draft[m].price_input = StringToInteger(f[15]) != 0;
     }
   g_panel.forceText = true;
  }

// needs the account number (file names), so it waits until the terminal is logged in
void TryLoad()
  {
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(login <= 0)
      return;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Alert("GoldCycle needs a HEDGING account. This account is netting, where two bots and your own trades would be merged. The bot is removed.");
      ExpertRemove();
      return;
     }
   g_login = login;
   g_cycle.Init(GetPointer(g_broker), GetPointer(g_sink), GC_CYCLE, InpMagic, InpMagic + 1);
   g_single.Init(GetPointer(g_broker), GetPointer(g_sink), GC_SINGLE, InpMagic + 1, InpMagic);
   g_broker.Spec(g_cycle.spec);
   g_broker.Spec(g_single.spec);
   g_loaded = true;
   FolderCreate("GoldCycle");
   LoadForm();
   LoadState(g_cycle);
   LoadState(g_single);
   if(StringFind(_Symbol, "XAU") < 0)
      Alert("GoldCycle is on ", _Symbol, ". It is made for gold (XAUUSD): attach it to a gold chart.");
   g_sink.Event("info", "Ready on " + _Symbol + " (account " + IntegerToString(g_login) + ")", false);
  }

//------------------------------------------------------------------ run + draw
void Run()
  {
   if(g_loaded && AccountInfoInteger(ACCOUNT_LOGIN) != g_login)
     {
      g_loaded = false;   // account switched: load that account's own state
      g_autoPending = false;
     }
   if(!g_loaded)
     {
      TryLoad();
      return;
     }
   g_cycle.Step();
   g_single.Step();
   if(g_autoPending && g_broker.Connected())
     {
      string err = "";
      bool waiting = false;
      if(g_cycle.resumable && !g_cycle.Resume(err))
         waiting = true;
      if(g_single.resumable && !g_single.Resume(err))
         waiting = true;
      g_autoPending = waiting;
     }
   if(g_cycle.dirty)
      SaveState(g_cycle, -1);
   if(g_single.dirty)
      SaveState(g_single, -1);
  }

void Draw()
  {
   if(!g_loaded)
     {
      Comment("GoldCycle: waiting for the account to log in ...");
      return;
     }
   Comment("");
   ulong now = GetTickCount64();
   if(g_todayAt == 0 || now - g_todayAt > 3000)
     {
      g_today = g_broker.RealizedToday(InpMagic, InpMagic + 1);
      g_todayAt = now;
     }
   string warning = "";
   if(!g_broker.Connected())
      warning = "NOT CONNECTED to the broker: the bot is paused";
   else
      warning = g_broker.TradeBlockReason();
   g_panel.Render(GetPointer(g_cycle), GetPointer(g_single), _Symbol, warning, g_today);
   if(g_panel.tab == 0)
      g_panel.Lines(GetPointer(g_cycle));
   else
      g_panel.Lines(GetPointer(g_single));
   ChartRedraw();
   g_renderAt = now;
  }

//------------------------------------------------------------------ events
int OnInit()
  {
   string marker = "GCP_t_magic_" + IntegerToString(InpMagic);
   for(long ch = ChartFirst(); ch >= 0; ch = ChartNext(ch))
      if(ch != ChartID() && ChartSymbol(ch) == _Symbol && ObjectFind(ch, marker) >= 0)
        {
         Alert("GoldCycle already runs on another ", _Symbol, " chart. Use one chart only (or a different magic number).");
         return INIT_FAILED;
        }
   MathSrand((uint)GetTickCount());
   g_broker.SetSymbol(_Symbol);
   g_panel.Init(InpPanelX, InpPanelY, InpMagic, InpDefaultLot);
   g_loaded = false;
   g_autoPending = false;
   TryLoad();
   Draw();
   EventSetMillisecondTimer(200);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_loaded)
     {
      SaveState(g_cycle, reason);
      SaveState(g_single, reason);
      SaveForm();
      if((g_cycle.Active() || g_single.Active()) && (reason == REASON_REMOVE || reason == REASON_CHARTCLOSE || reason == REASON_CLOSE))
         Print("GoldCycle stopped while running. Open trades keep their TP/SL on the broker. Attach it again and press Resume.");
     }
   Comment("");
   g_panel.Remove();
  }

void OnTick() { Run(); }

void OnTimer()
  {
   Run();
   if(GetTickCount64() - g_renderAt >= 500)
      Draw();
  }

// a TP / SL fill arrives here at once: react in the same moment (order 2 opens immediately)
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && g_loaded)
     {
      Run();
      g_todayAt = 0;
      Draw();
     }
  }

bool Confirm(const string question)
  {
   if(InpTestHooks)
      return true;
   return MessageBox(question, "GoldCycle", MB_YESNO | MB_ICONQUESTION) == IDYES;
  }

void ShowHelp()
  {
   MessageBox("CYCLE\n1. Choose BUY or SELL, the trigger price, the lot and TP points (1 point = 1.00 of price).\n"
              + "2. Start. When the price touches the trigger, order 1 opens with a TP and no SL.\n"
              + "3. When order 1 hits TP, order 2 opens at once: SL at order 1's entry, no TP.\n"
              + "4. When order 2 hits its SL, the next cycle waits at the entry (plus the gap, if set).\n"
              + "It stops at the stop price, max cycles, daily loss limit, or when you stop it.\n\n"
              + "SINGLE\nOne trade at the trigger price, or BUY / SELL now. TP and SL are optional.\n\n"
              + "Open trade: type TP / SL and press Set, or drag the lines on the chart.\n"
              + "Order 1 has no SL: use a stop price and/or a daily loss limit.\n"
              + "Close all and stop: the red button, or Ctrl+Shift+K for both bots.", "GoldCycle: how it works", MB_OK | MB_ICONINFORMATION);
  }

void Report(const bool ok, const string err)
  {
   if(ok)
      g_panel.Message("", C_MUTED);
   else
     {
      g_panel.Message(err, C_DOWN);
      g_sink.Event("error", err, false);
     }
  }

void Click(const string id)
  {
   int m = g_panel.tab;
   CEngine *e = m == 0 ? GetPointer(g_cycle) : GetPointer(g_single);
   string err = "";
   string errors[];
   SConfig c;
   if(id == "help")
      ShowHelp();
   else if(id == "collapse")
      g_panel.collapsed = !g_panel.collapsed;
   else if(id == "tab0" || id == "tab1")
     {
      g_panel.tab = id == "tab1" ? 1 : 0;
      g_panel.picking = "";
      g_panel.Message("", C_MUTED);
      g_panel.forceText = true;
      ObjectsDeleteAll(0, "GCP_e_");
     }
   else if((id == "buy" || id == "sell") && !e.Active())
      g_panel.draft[m].dir = id == "buy" ? GC_BUY : GC_SELL;
   else if(id == "bid" && e.haveTick)
     {
      if(!(m == 0 && e.Active() && !(e.state == GCS_ARMED && e.leg == 1)))
        {
         g_panel.draft[m].trigger = DoubleToString(e.lastTick.bid, 2);
         g_panel.forceText = true;
        }
     }
   else if(StringFind(id, "pick_") == 0)
     {
      string field = StringSubstr(id, 5);
      g_panel.picking = g_panel.picking == field ? "" : field;
      if(g_panel.picking != "")
         g_panel.Message("Click on the chart at the price you want", C_INFO);
     }
   else if(id == "adv")
      g_panel.advanced = !g_panel.advanced;
   else if(id == "unit" && !e.Active())
     {
      g_panel.draft[m].price_input = !g_panel.draft[m].price_input;
      g_panel.draft[m].tp = "";
      g_panel.draft[m].sl = "";
      g_panel.forceText = true;
     }
   else if(id == "tside")
      g_panel.draft[m].tside = (g_panel.draft[m].tside + 1) % 3;
   else if(id == "anchor")
      g_panel.draft[m].anchor = g_panel.draft[m].anchor == ANCHOR_PLANNED ? ANCHOR_FILL : ANCHOR_PLANNED;
   else if(id == "arm" || id == "buynow" || id == "sellnow")
     {
      bool now = id != "arm";
      if(now)
         g_panel.draft[m].dir = id == "buynow" ? GC_BUY : GC_SELL;
      g_panel.BuildConfig(m, now, c, errors);
      if(ArraySize(errors) > 0)
         Report(false, errors[0]);
      else
        {
         bool ok = e.Arm(c, err);
         Report(ok, err);
        }
     }
   else if(id == "apply")
     {
      g_panel.BuildConfig(m, false, c, errors);
      if(ArraySize(errors) > 0)
         Report(false, errors[0]);
      else
        {
         c.dir = e.cfg.dir;
         bool ok = e.UpdateConfig(c, err);
         Report(ok, err);
         if(ok)
            g_panel.SyncDraft(e.cfg);
        }
     }
   else if(id == "discard")
     {
      g_panel.SyncDraft(e.cfg);
      g_panel.Message("", C_MUTED);
     }
   else if(id == "after")
     {
      bool ok = e.StopAfterCycle(err);
      Report(ok, err);
     }
   else if(id == "stopnow")
     {
      bool ok = e.StopNow(err);
      Report(ok, err);
     }
   else if(id == "resume")
     {
      bool ok = e.Resume(err);
      Report(ok, err);
      g_autoPending = false;
     }
   else if(id == "killall")
     {
      if(Confirm("Close all positions of the " + (m == 0 ? "Cycle" : "Single") + " bot now and stop it?"))
         e.CloseAllAndStop();
     }
   else if(id == "setlv")
     {
      double tp = 0, sl = 0;
      bool b1, b2;
      if(!GcParse(g_panel.draft[m].otp, tp, b1) || !GcParse(g_panel.draft[m].osl, sl, b2))
         Report(false, "TP / SL: type a price, or leave it empty for none");
      else
        {
         bool ok = e.ModifyLevels(tp, sl, err);
         Report(ok, err);
         if(!ok)
            g_panel.draft[m].seen_tp = -1;   // show the real values again
        }
     }
  }

void EndEdit(const string id)
  {
   int m = g_panel.tab;
   string v = ObjectGetString(0, "GCP_e_" + id, OBJPROP_TEXT);
   StringTrimLeft(v);
   StringTrimRight(v);
   StringReplace(v, "|", "");
   if(id == "trigger") g_panel.draft[m].trigger = v;
   else if(id == "lot") g_panel.draft[m].lot = v;
   else if(id == "tp") g_panel.draft[m].tp = v;
   else if(id == "sl") g_panel.draft[m].sl = v;
   else if(id == "gap") g_panel.draft[m].gap = v;
   else if(id == "stop") g_panel.draft[m].stop = v;
   else if(id == "maxc") g_panel.draft[m].maxc = v;
   else if(id == "dloss") g_panel.draft[m].dloss = v;
   else if(id == "mspread") g_panel.draft[m].mspread = v;
   else if(id == "mslip") g_panel.draft[m].mslip = v;
   else if(id == "hours") g_panel.draft[m].hours = v;
   else if(id == "otp") g_panel.draft[m].otp = v;
   else if(id == "osl") g_panel.draft[m].osl = v;
  }

// "Pick": the next click on the chart fills the field with that price
void Pick(const double price)
  {
   int m = g_panel.tab;
   string field = g_panel.picking;
   string text = DoubleToString(price, 2);
   if(field == "otp" || field == "osl")   // the open trade: fill the box, "Set" sends it
     {
      if(field == "otp")
         g_panel.draft[m].otp = text;
      else
         g_panel.draft[m].osl = text;
      g_panel.picking = "";
      g_panel.Message("Now press 'Set TP / SL on this trade'", C_INFO);
      g_panel.forceText = true;
      return;
     }
   if(field == "trigger")
      g_panel.draft[m].trigger = text;
   else if(field == "stop")
      g_panel.draft[m].stop = text;
   else
     {
      if(m == GC_SINGLE && !g_panel.draft[m].price_input)
        {
         g_panel.draft[m].price_input = true;
         g_panel.draft[m].tp = "";
         g_panel.draft[m].sl = "";
        }
      if(field == "tp")
         g_panel.draft[m].tp = text;
      else
         g_panel.draft[m].sl = text;
      double trig;
      bool blank;
      if(GcParse(g_panel.draft[m].trigger, trig, blank) && trig > 0 && !g_single.Active())
         g_panel.draft[m].dir = ((field == "tp") == (price > trig)) ? GC_BUY : GC_SELL;
     }
   g_panel.picking = "";
   g_panel.Message("", C_MUTED);
   g_panel.forceText = true;
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(!g_loaded)
      return;
   int ev = id;
   string name = sparam;
   if(InpTestHooks && id == CHARTEVENT_CUSTOM + 1)          // test script "clicks" a button
      ev = CHARTEVENT_OBJECT_CLICK;
   if(InpTestHooks && id == CHARTEVENT_CUSTOM + 2)          // test script "types" into a box: name=value
     {
      int eq = StringFind(sparam, "=");
      name = StringSubstr(sparam, 0, eq);
      ObjectSetString(0, name, OBJPROP_TEXT, StringSubstr(sparam, eq + 1));
      ev = CHARTEVENT_OBJECT_ENDEDIT;
     }
   if(InpTestHooks && id == CHARTEVENT_CUSTOM + 3)          // test script switches the chart timeframe
     {
      ChartSetSymbolPeriod(0, _Symbol, (ENUM_TIMEFRAMES)lparam);
      return;
     }
   if(ev == CHARTEVENT_OBJECT_CLICK && StringFind(name, "GCP_b_") == 0)
     {
      ObjectSetInteger(0, name, OBJPROP_STATE, false);
      Click(StringSubstr(name, 6));
     }
   else if(ev == CHARTEVENT_OBJECT_ENDEDIT && StringFind(name, "GCP_e_") == 0)
      EndEdit(StringSubstr(name, 6));
   else if(ev == CHARTEVENT_CLICK && g_panel.picking != "" && !g_panel.Inside((int)lparam, (int)dparam))
     {
      int sub;
      datetime t;
      double price;
      if(ChartXYToTimePrice(0, (int)lparam, (int)dparam, sub, t, price) && sub == 0 && price > 0)
         Pick(price);
     }
   else if(ev == CHARTEVENT_KEYDOWN && lparam == 'K' && TerminalInfoInteger(TERMINAL_KEYSTATE_CONTROL) < 0
           && TerminalInfoInteger(TERMINAL_KEYSTATE_SHIFT) < 0)
     {
      if(Confirm("Close ALL positions of both bots (Cycle and Single) now and stop them?"))
        {
         g_cycle.CloseAllAndStop();
         g_single.CloseAllAndStop();
        }
     }
   else
      return;
   Run();
   SaveForm();
   Draw();
  }
//+------------------------------------------------------------------+
