//+------------------------------------------------------------------+
//| GoldCycle - simulated broker for the test script. No real orders.|
//| Positions close server-side on TP/SL when the price is moved.    |
//+------------------------------------------------------------------+
#ifndef GC_SIMBROKER_MQH
#define GC_SIMBROKER_MQH

#include "Broker.mqh"

class CSimBroker : public CBroker
  {
public:
   double            bid;
   double            ask;
   double            spread;
   bool              online;
   string            blockReason;
   ulong             ms;
   int               localMin;
   int               day;
   ulong             nextTicket;
   SPos              open[];
   ulong             closedTicket[];
   SCloseInfo        closed[];
   int               closedDay[];
   long              closedMagic[];
   int               rejectOpens;       // reject the next N opens
   uint              rejectCode;
   bool              rejectFatal;
   int               rejectCloses;
   bool              rejectModify;
   bool              hideHistory;       // closing deal not in history yet
   int               opens;             // orders actually filled
   int               modifies;          // modify requests received
   int               stopsLevel;

                     CSimBroker() { Reset(4000); }

   void              Reset(const double price)
     {
      spread = 0.2; bid = price; ask = price + spread; online = true; blockReason = ""; ms = 100000; localMin = 600; day = 20000;
      nextTicket = 1000; rejectOpens = 0; rejectCode = 10006; rejectFatal = false; rejectCloses = 0; rejectModify = false;
      hideHistory = false; opens = 0; modifies = 0; stopsLevel = 0;
      ArrayResize(open, 0); ArrayResize(closedTicket, 0); ArrayResize(closed, 0); ArrayResize(closedDay, 0); ArrayResize(closedMagic, 0);
     }

   // move the market; every position whose TP or SL is reached closes like on the broker's server
   void              Price(const double new_bid, const double new_spread = -1)
     {
      if(new_spread >= 0)
         spread = new_spread;
      bid = new_bid;
      ask = new_bid + spread;
      ms += 1100;   // past the order retry throttle
      for(int i = ArraySize(open) - 1; i >= 0; i--)
        {
         double px = open[i].dir == GC_BUY ? bid : ask;
         int side = GcDirSign(open[i].dir);
         if(open[i].tp > 0 && side * (px - open[i].tp) >= -1e-9)
            CloseAt(i, DL_TP, open[i].tp);
         else if(open[i].sl > 0 && side * (open[i].sl - px) >= -1e-9)
            CloseAt(i, DL_SL, px);
        }
     }

   static int        GcDirSign(const int dir) { return dir == GC_BUY ? 1 : -1; }

   void              CloseAt(const int i, const int reason, const double price)
     {
      int n = ArraySize(closed);
      ArrayResize(closed, n + 1); ArrayResize(closedTicket, n + 1); ArrayResize(closedDay, n + 1); ArrayResize(closedMagic, n + 1);
      closedTicket[n] = open[i].ticket;
      closed[n].reason = reason;
      closed[n].price = price;
      closed[n].profit = NormalizeDouble(GcDirSign(open[i].dir) * (price - open[i].price_open) * open[i].volume * 100.0, 2);
      closed[n].time = D'2026.01.01 00:00:00';
      closedDay[n] = day;
      closedMagic[n] = open[i].magic;
      int last = ArraySize(open) - 1;
      for(int k = i; k < last; k++)
         open[k] = open[k + 1];
      ArrayResize(open, last);
     }

   bool              CloseManually(const ulong ticket)
     {
      for(int i = 0; i < ArraySize(open); i++)
         if(open[i].ticket == ticket)
           {
            CloseAt(i, DL_CLIENT, open[i].dir == GC_BUY ? bid : ask);
            return true;
           }
      return false;
     }

   // the trader drags TP / SL on the chart
   void              Drag(const ulong ticket, const double sl, const double tp)
     {
      for(int i = 0; i < ArraySize(open); i++)
         if(open[i].ticket == ticket)
           {
            open[i].sl = sl;
            open[i].tp = tp;
           }
     }

   // put a position on the account that the engine does not know about
   ulong             Inject(const int dir, const long magic, const string comment)
     {
      int n = ArraySize(open);
      ArrayResize(open, n + 1);
      open[n].ticket = ++nextTicket; open[n].dir = dir; open[n].volume = 0.01; open[n].price_open = dir == GC_BUY ? ask : bid;
      open[n].sl = 0; open[n].tp = 0; open[n].profit = 0; open[n].magic = magic; open[n].comment = comment; open[n].time = 0;
      return open[n].ticket;
     }

   virtual bool      Connected() override { return online; }
   virtual string    TradeBlockReason() override { return blockReason; }
   virtual bool      Tick(STick &t) override
     {
      if(!online || bid <= 0)
         return false;
      t.bid = bid; t.ask = ask; t.time = 0;
      return true;
     }
   virtual bool      Spec(SSpec &s) override
     {
      s.digits = 3; s.point = 0.001; s.vol_min = 0.01; s.vol_max = 200; s.vol_step = 0.01; s.stops_level = stopsLevel; s.freeze_level = 0;
      return true;
     }
   virtual int       Positions(const long magic, SPos &out[]) override
     {
      ArrayResize(out, 0);
      for(int i = 0; i < ArraySize(open); i++)
         if(open[i].magic == magic)
           {
            int n = ArraySize(out);
            ArrayResize(out, n + 1);
            out[n] = open[i];
            out[n].profit = NormalizeDouble(GcDirSign(open[i].dir) * ((open[i].dir == GC_BUY ? bid : ask) - open[i].price_open) * open[i].volume * 100.0, 2);
           }
      return ArraySize(out);
     }
   virtual void      OpenMarket(const int dir, const double volume, const double sl, const double tp, const int deviation,
                                const long magic, const string comment, SOrderResult &res) override
     {
      GcResetResult(res);
      if(rejectOpens > 0)
        {
         rejectOpens--;
         res.retcode = rejectCode; res.fatal = rejectFatal; res.message = "rejected";
         return;
        }
      ulong ticket = Inject(dir, magic, comment);
      int n = ArraySize(open) - 1;
      open[n].volume = volume; open[n].sl = sl; open[n].tp = tp;
      opens++;
      res.ok = true; res.retcode = 10009; res.ticket = ticket; res.price = open[n].price_open;
     }
   virtual void      ModifyPosition(const ulong ticket, const double sl, const double tp, SOrderResult &res) override
     {
      GcResetResult(res);
      modifies++;
      if(rejectModify)
        { res.retcode = 10016; res.message = "invalid stops"; return; }
      Drag(ticket, sl, tp);
      res.ok = true; res.retcode = 10009; res.ticket = ticket;
     }
   virtual void      ClosePosition(const SPos &p, const int deviation, SOrderResult &res) override
     {
      GcResetResult(res);
      if(rejectCloses > 0)
        { rejectCloses--; res.retcode = 10006; res.message = "rejected"; return; }
      for(int i = 0; i < ArraySize(open); i++)
         if(open[i].ticket == p.ticket)
           {
            CloseAt(i, DL_EXPERT, p.dir == GC_BUY ? bid : ask);
            res.ok = true; res.retcode = 10009; res.ticket = p.ticket;
            return;
           }
      res.retcode = 10036; res.message = "position already closed";
     }
   virtual bool      CloseInfo(const ulong ticket, SCloseInfo &info) override
     {
      if(hideHistory)
         return false;
      for(int i = 0; i < ArraySize(closed); i++)
         if(closedTicket[i] == ticket)
           {
            info = closed[i];
            return true;
           }
      return false;
     }
   virtual double    RealizedToday(const long magic1, const long magic2) override
     {
      double sum = 0;
      for(int i = 0; i < ArraySize(closed); i++)
         if(closedDay[i] == day && (closedMagic[i] == magic1 || closedMagic[i] == magic2))
            sum += closed[i].profit;
      return sum;
     }
   virtual ulong     Ms() override { return ms; }
   virtual datetime  Now() override { return D'2026.01.01 00:00:00' + (int)(ms / 1000); }
   virtual int       LocalMinutes() override { return localMin; }
   virtual int       Day() override { return day; }
   virtual void      Pause(const int delay) override { ms += delay; }
  };

#endif
