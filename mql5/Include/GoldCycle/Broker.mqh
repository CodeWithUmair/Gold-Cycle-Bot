//+------------------------------------------------------------------+
//| GoldCycle - the broker interface and the real MetaTrader one.    |
//| The engine only talks to CBroker (tests use CSimBroker).         |
//+------------------------------------------------------------------+
#ifndef GC_BROKER_MQH
#define GC_BROKER_MQH

#include "Types.mqh"

class CBroker
  {
public:
   virtual bool      Connected() = 0;
   virtual string    TradeBlockReason() = 0;          // "" = orders can be sent
   virtual bool      Tick(STick &t) = 0;              // false = no price
   virtual bool      Spec(SSpec &s) = 0;
   virtual int       Positions(const long magic, SPos &out[]) = 0;
   virtual void      OpenMarket(const int dir, const double volume, const double sl, const double tp, const int deviation,
                                const long magic, const string comment, SOrderResult &res) = 0;
   virtual void      ModifyPosition(const ulong ticket, const double sl, const double tp, SOrderResult &res) = 0;
   virtual void      ClosePosition(const SPos &p, const int deviation, SOrderResult &res) = 0;
   virtual bool      CloseInfo(const ulong ticket, SCloseInfo &info) = 0;   // false = not in history yet
   virtual double    RealizedToday(const long magic1, const long magic2) = 0;
   virtual ulong     Ms() = 0;                        // monotonic milliseconds
   virtual datetime  Now() = 0;
   virtual int       LocalMinutes() = 0;              // PC local time, minutes after midnight
   virtual int       Day() = 0;                       // broker day number
   virtual void      Pause(const int ms) = 0;
  };

class CMt5Broker : public CBroker
  {
private:
   string            m_symbol;

   ENUM_ORDER_TYPE_FILLING Filling()
     {
      long mode = SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((mode & SYMBOL_FILLING_FOK) != 0)
         return ORDER_FILLING_FOK;
      if((mode & SYMBOL_FILLING_IOC) != 0)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }

   static bool       OkCode(const uint c) { return c == TRADE_RETCODE_PLACED || c == TRADE_RETCODE_DONE || c == TRADE_RETCODE_DONE_PARTIAL; }
   static bool       FatalCode(const uint c)
     {
      switch((int)c)
        {
         case 10013: case 10014: case 10015: case 10016: case 10017: case 10019:
         case 10022: case 10026: case 10027: case 10030: case 10040:
            return true;
        }
      return false;
     }
   static string     CodeText(const uint c, const string comment)
     {
      switch((int)c)
        {
         case 10004: return "requote";
         case 10006: return "rejected";
         case 10012: return "request timed out";
         case 10015: return "invalid price";
         case 10016: return "invalid TP/SL";
         case 10017: return "trading disabled";
         case 10018: return "market closed";
         case 10019: return "not enough money";
         case 10021: return "no prices";
         case 10025: return "no changes";
         case 10026: return "auto trading disabled by the server";
         case 10027: return "Algo Trading is OFF in MetaTrader";
         case 10030: return "unsupported filling mode";
         case 10031: return "no connection";
         case 10044: return "session closed";
        }
      return comment == "" ? "error" : comment;
     }

   void              Send(MqlTradeRequest &req, MqlTradeResult &out, SOrderResult &res)
     {
      GcResetResult(res);
      ResetLastError();
      bool sent = OrderSend(req, out);
      res.retcode = out.retcode;
      if(out.retcode == 0)
        {
         int err = GetLastError();
         res.message = "order not sent (error " + IntegerToString(err) + ")";
         res.fatal = (err == 4752 || err == 4753);   // trading by Expert Advisors / account not allowed
         return;
        }
      res.ok = sent && OkCode(out.retcode);
      res.fatal = !res.ok && FatalCode(out.retcode);
      res.message = CodeText(out.retcode, out.comment);
     }

public:
                     CMt5Broker() { m_symbol = _Symbol; }
   void              SetSymbol(const string s) { m_symbol = s; }

   virtual bool      Connected() override { return MQLInfoInteger(MQL_TESTER) != 0 || TerminalInfoInteger(TERMINAL_CONNECTED) != 0; }

   virtual string    TradeBlockReason() override
     {
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)
         return "Algo Trading is OFF: click the 'Algo Trading' button at the top of MetaTrader (it must be green)";
      if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
         return "Trading is not allowed for this bot: open its settings (F7) and tick 'Allow Algo Trading'";
      if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0)
         return "This account cannot trade (investor password, or trading disabled by the broker)";
      if(AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0)
         return "The broker disabled automated trading on this account";
      return "";
     }

   virtual bool      Tick(STick &t) override
     {
      MqlTick q;
      if(!SymbolInfoTick(m_symbol, q) || q.bid <= 0 || q.ask <= 0)   // a zero price means "no price"
         return false;
      t.bid = q.bid; t.ask = q.ask; t.time = q.time;
      return true;
     }

   virtual bool      Spec(SSpec &s) override
     {
      s.digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      s.point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      s.vol_min = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      s.vol_max = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      s.vol_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      s.stops_level = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      s.freeze_level = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      return s.point > 0 && s.vol_step > 0;
     }

   virtual int       Positions(const long magic, SPos &out[]) override
     {
      ArrayResize(out, 0);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != m_symbol || PositionGetInteger(POSITION_MAGIC) != magic)
            continue;
         int n = ArraySize(out);
         ArrayResize(out, n + 1);
         out[n].ticket = ticket;
         out[n].dir = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? GC_BUY : GC_SELL;
         out[n].volume = PositionGetDouble(POSITION_VOLUME);
         out[n].price_open = PositionGetDouble(POSITION_PRICE_OPEN);
         out[n].sl = PositionGetDouble(POSITION_SL);
         out[n].tp = PositionGetDouble(POSITION_TP);
         out[n].profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         out[n].magic = magic;
         out[n].comment = PositionGetString(POSITION_COMMENT);
         out[n].time = (datetime)PositionGetInteger(POSITION_TIME);
        }
      return ArraySize(out);
     }

   virtual void      OpenMarket(const int dir, const double volume, const double sl, const double tp, const int deviation,
                                const long magic, const string comment, SOrderResult &res) override
     {
      MqlTradeRequest req = {};
      MqlTradeResult out = {};
      req.action = TRADE_ACTION_DEAL;
      req.symbol = m_symbol;
      req.volume = volume;
      req.type = dir == GC_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      req.price = SymbolInfoDouble(m_symbol, dir == GC_BUY ? SYMBOL_ASK : SYMBOL_BID);
      req.sl = sl;
      req.tp = tp;
      req.deviation = (ulong)deviation;
      req.magic = (ulong)magic;
      req.comment = StringSubstr(comment, 0, 31);
      req.type_filling = Filling();
      PrintFormat("GoldCycle order: %s %.2f %s at %.3f sl=%.3f tp=%.3f magic=%I64d", GcDirName(dir), volume, m_symbol, req.price, sl, tp, magic);
      Send(req, out, res);
      if(!res.ok)
         return;
      // the resulting position: on hedging accounts its id is the order ticket
      ulong id = out.order;
      if(out.deal > 0 && HistoryDealSelect(out.deal))
         id = (ulong)HistoryDealGetInteger(out.deal, DEAL_POSITION_ID);
      res.ticket = id;
      res.price = out.price;
      if(PositionSelectByTicket(id))
         res.price = PositionGetDouble(POSITION_PRICE_OPEN);
     }

   virtual void      ModifyPosition(const ulong ticket, const double sl, const double tp, SOrderResult &res) override
     {
      MqlTradeRequest req = {};
      MqlTradeResult out = {};
      req.action = TRADE_ACTION_SLTP;
      req.symbol = m_symbol;
      req.position = ticket;
      req.sl = sl;
      req.tp = tp;
      Send(req, out, res);
      res.ticket = ticket;
     }

   virtual void      ClosePosition(const SPos &p, const int deviation, SOrderResult &res) override
     {
      MqlTradeRequest req = {};
      MqlTradeResult out = {};
      req.action = TRADE_ACTION_DEAL;
      req.symbol = m_symbol;
      req.position = p.ticket;
      req.volume = p.volume;
      req.type = p.dir == GC_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = SymbolInfoDouble(m_symbol, p.dir == GC_BUY ? SYMBOL_BID : SYMBOL_ASK);
      req.deviation = (ulong)deviation;
      req.magic = (ulong)p.magic;
      req.comment = "GC|close";
      req.type_filling = Filling();
      PrintFormat("GoldCycle close position #%I64u", p.ticket);
      Send(req, out, res);
      res.ticket = p.ticket;
      res.price = out.price;
     }

   virtual bool      CloseInfo(const ulong ticket, SCloseInfo &info) override
     {
      if(!HistorySelectByPosition(ticket))
         return false;
      double net = 0;
      long last_ms = -1;
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
                + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
         long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
            continue;
         long ms = HistoryDealGetInteger(d, DEAL_TIME_MSC);
         if(ms < last_ms)
            continue;
         last_ms = ms;
         long reason = HistoryDealGetInteger(d, DEAL_REASON);
         if(reason == DEAL_REASON_TP)
            info.reason = DL_TP;
         else if(reason == DEAL_REASON_SL)
            info.reason = DL_SL;
         else if(reason == DEAL_REASON_SO)
            info.reason = DL_STOP_OUT;
         else if(reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB)
            info.reason = DL_CLIENT;
         else if(reason == DEAL_REASON_EXPERT)
            info.reason = DL_EXPERT;
         else
            info.reason = DL_OTHER;
         info.price = HistoryDealGetDouble(d, DEAL_PRICE);
         info.time = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
        }
      if(last_ms < 0)
         return false;
      info.profit = NormalizeDouble(net, 2);
      return true;
     }

   // Closed P/L of today (broker day) for positions opened by either bot magic, including manual closes of them.
   virtual double    RealizedToday(const long magic1, const long magic2) override
     {
      datetime now = TimeCurrent();
      datetime day = now - (now % 86400);
      if(!HistorySelect(day - 14 * 86400, now + 86400))
         return 0;
      int total = HistoryDealsTotal();
      long ours[];
      for(int i = 0; i < total; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         long m = HistoryDealGetInteger(d, DEAL_MAGIC);
         if(m != magic1 && m != magic2)
            continue;
         int n = ArraySize(ours);
         ArrayResize(ours, n + 1, 256);
         ours[n] = HistoryDealGetInteger(d, DEAL_POSITION_ID);
        }
      double sum = 0;
      for(int i = 0; i < total; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if((datetime)HistoryDealGetInteger(d, DEAL_TIME) < day)
            continue;
         long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
         for(int k = 0; k < ArraySize(ours); k++)
            if(ours[k] == pid)
              {
               sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
                      + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
               break;
              }
        }
      return sum;
     }

   virtual ulong     Ms() override { return MQLInfoInteger(MQL_TESTER) != 0 ? (ulong)TimeCurrent() * 1000 : GetTickCount64(); }
   virtual datetime  Now() override { return TimeCurrent(); }
   virtual int       LocalMinutes() override
     {
      MqlDateTime d;
      TimeToStruct(TimeLocal(), d);
      return d.hour * 60 + d.min;
     }
   virtual int       Day() override { return (int)(TimeCurrent() / 86400); }
   virtual void      Pause(const int ms) override { Sleep(ms); }
  };

#endif
