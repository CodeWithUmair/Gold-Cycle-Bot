//+------------------------------------------------------------------+
//| GoldCycle - shared types                                         |
//| Same rules as the Python engine (CLAUDE.md §2-§5, §12).          |
//| "Point" = the client's point: 1.00 of price, NOT MT5's _Point.   |
//+------------------------------------------------------------------+
#ifndef GC_TYPES_MQH
#define GC_TYPES_MQH

#define GC_POINT_SIZE 1.0
#define GC_EPS 1e-9
#define GC_ORDER_RETRY_MS 1000   // min gap between order attempts while OPENING
#define GC_RESOLVE_TIMEOUT_MS 10000   // wait this long for the closing deal to show up in history
#define GC_ALERT_THROTTLE_MS 5000

enum ENUM_GC_DIR { GC_BUY = 0, GC_SELL = 1 };
enum ENUM_GC_MODE { GC_CYCLE = 0, GC_SINGLE = 1 };
enum ENUM_GC_STATE { GCS_IDLE = 0, GCS_ARMED = 1, GCS_OPENING = 2, GCS_IN_POSITION = 3, GCS_RESOLVING = 4, GCS_STOPPED = 5 };
enum ENUM_GC_REASON
  {
   CR_NONE = 0, CR_TP = 1, CR_SL = 2, CR_MANUAL = 3, CR_STOP_OUT = 4, CR_STOP_PRICE = 5,
   CR_KILL_SWITCH = 6, CR_DAILY_LOSS = 7, CR_CLOSED = 8, CR_UNKNOWN = 9
  };
enum ENUM_GC_DEAL { DL_TP = 0, DL_SL = 1, DL_CLIENT = 2, DL_STOP_OUT = 3, DL_EXPERT = 4, DL_OTHER = 5 };
enum ENUM_GC_ANCHOR { ANCHOR_PLANNED = 0, ANCHOR_FILL = 1 };
enum ENUM_GC_SIDE { SIDE_BID = 0, SIDE_ASK = 1, SIDE_MID = 2 };

//--- the trader's inputs. 0 (or "") means "not set" for every optional number.
struct SConfig
  {
   int               mode;
   int               dir;
   double            trigger;
   double            lot;
   bool              price_input;     // SINGLE: TP/SL typed as exact prices instead of points
   double            tp_points;
   double            sl_points;
   double            tp_price;
   double            sl_price;
   double            gap;             // CYCLE: only after order 2's SL. 0 = blank = same entry
   double            stop_price;      // CYCLE
   bool              enter_now;       // SINGLE: "Buy/Sell now at market"
   int               anchor;
   int               trigger_side;
   double            max_slippage;
   int               max_cycles;
   double            daily_loss;
   double            max_spread;      // 0 = no limit
   string            hours;           // "HH:MM-HH:MM" PC local time, may wrap midnight
   double            lot_mult;
  };

void GcDefaultConfig(SConfig &c, const int mode)
  {
   c.mode = mode; c.dir = GC_BUY; c.trigger = 0; c.lot = 0.01; c.price_input = false;
   c.tp_points = 0; c.sl_points = 0; c.tp_price = 0; c.sl_price = 0; c.gap = 0; c.stop_price = 0;
   c.enter_now = false; c.anchor = ANCHOR_PLANNED; c.trigger_side = SIDE_BID; c.max_slippage = 0.5;
   c.max_cycles = 0; c.daily_loss = 0; c.max_spread = 0.6; c.hours = ""; c.lot_mult = 1.0;
  }

struct STick
  {
   double            bid;
   double            ask;
   datetime          time;
  };

struct SSpec
  {
   int               digits;
   double            point;
   double            vol_min;
   double            vol_max;
   double            vol_step;
   int               stops_level;
   int               freeze_level;
  };

struct SPos
  {
   ulong             ticket;
   int               dir;
   double            volume;
   double            price_open;
   double            sl;          // 0 = none
   double            tp;          // 0 = none
   double            profit;
   long              magic;
   string            comment;
   datetime          time;
  };

struct SCloseInfo
  {
   int               reason;      // ENUM_GC_DEAL
   double            price;
   double            profit;      // net of swap, commission and fee, all deals of the position
   datetime          time;
  };

struct SOrderResult
  {
   bool              ok;
   bool              fatal;       // retrying the same request cannot help
   uint              retcode;
   string            message;
   ulong             ticket;
   double            price;
  };

void GcResetResult(SOrderResult &r)
  {
   r.ok = false; r.fatal = false; r.retcode = 0; r.message = ""; r.ticket = 0; r.price = 0;
  }

//--- one journal row = one order
struct SRow
  {
   ulong             ticket;
   int               cycle;
   int               leg;
   int               dir;
   double            volume;
   double            planned;
   double            fill;
   double            slippage;
   double            tp;
   double            sl;
   datetime          open_time;
   datetime          close_time;  // 0 = still open
   double            close_price;
   int               reason;      // ENUM_GC_REASON
   double            pnl;
  };

struct SPlanned
  {
   int               cycle;
   int               leg;
   double            entry;
   double            tp;
   double            sl;
   double            lot;
  };

string GcDirName(const int d) { return d == GC_BUY ? "BUY" : "SELL"; }
string GcModeName(const int m) { return m == GC_CYCLE ? "CYCLE" : "SINGLE"; }

string GcStateName(const int s)
  {
   switch(s)
     {
      case GCS_IDLE: return "IDLE";
      case GCS_ARMED: return "ARMED";
      case GCS_OPENING: return "OPENING";
      case GCS_IN_POSITION: return "IN POSITION";
      case GCS_RESOLVING: return "RESOLVING";
      case GCS_STOPPED: return "STOPPED";
     }
   return "?";
  }

string GcReasonName(const int r)
  {
   switch(r)
     {
      case CR_TP: return "TP";
      case CR_SL: return "SL";
      case CR_MANUAL: return "MANUAL";
      case CR_STOP_OUT: return "STOP_OUT";
      case CR_STOP_PRICE: return "STOP_PRICE";
      case CR_KILL_SWITCH: return "KILL_SWITCH";
      case CR_DAILY_LOSS: return "DAILY_LOSS";
      case CR_CLOSED: return "CLOSED";
      case CR_UNKNOWN: return "UNKNOWN";
     }
   return "";
  }

#endif
