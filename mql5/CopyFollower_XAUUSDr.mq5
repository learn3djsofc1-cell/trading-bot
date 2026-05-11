#property strict
#property version   "1.00"
#property description "Follower EA for XAUUSDr copy trading from local Node.js relay."

#include <Trade/Trade.mqh>

input string InpRelayUrl          = "http://127.0.0.1:8787";
input string InpAuthToken         = "CHANGE_ME_LONG_RANDOM_TOKEN";
input string InpFollowerId        = "FOLLOWER_B";
input string InpSymbol            = "XAUUSDr";
input int    InpPollMs            = 200;
input int    InpRequestTimeout    = 1000;
input int    InpDeviationPoints   = 100;
input int    InpMaxSpreadPoints   = 300;
input long   InpFollowerMagic     = 26051101;
input bool   InpCopyPendingOrders = true;
input bool   InpCopyPartialClose  = true;
input bool   InpDryRun            = false;

struct TargetPosition
{
   string ticket;
   string type;
   double volume;
   double priceOpen;
   double sl;
   double tp;
};

struct TargetOrder
{
   string ticket;
   string type;
   double volume;
   double priceOpen;
   double sl;
   double tp;
   datetime expiration;
   double stopLimit;
};

CTrade trade;
string g_lastEventId = "";
TargetPosition g_positions[];
TargetOrder g_orders[];

int OnInit()
{
   trade.SetExpertMagicNumber(InpFollowerMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   EventSetMillisecondTimer(MathMax(100, InpPollMs));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   string snapshot;
   if(!FetchSnapshot(snapshot)) return;
   string eventId = ParseSnapshot(snapshot);
   if(eventId == "") return;
   if(eventId == g_lastEventId) return;

   if(SymbolInfoInteger(InpSymbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
   {
      SendStatus("error", "Spread too high; snapshot skipped: " + eventId);
      return;
   }

   Reconcile();
   g_lastEventId = eventId;
   SendStatus("info", "Snapshot applied: " + eventId);
}

bool FetchSnapshot(string &snapshot)
{
   string headers = "Authorization: Bearer " + InpAuthToken + "\r\n";
   char data[];
   char result[];
   string resultHeaders;
   ResetLastError();
   int status = WebRequest("GET", InpRelayUrl + "/api/snapshot", headers, InpRequestTimeout, data, result, resultHeaders);
   if(status == 204) return false;
   if(status != 200)
   {
      Print("Follower snapshot GET failed. HTTP=", status, " error=", GetLastError(), " response=", CharArrayToString(result, 0, -1, CP_UTF8));
      return false;
   }
   snapshot = CharArrayToString(result, 0, -1, CP_UTF8);
   return true;
}

string ParseSnapshot(const string snapshot)
{
   ArrayResize(g_positions, 0);
   ArrayResize(g_orders, 0);
   string lines[];
   int count = StringSplit(snapshot, '\n', lines);
   if(count < 1) return "";

   string header[];
   if(StringSplit(Trim(lines[0]), '|', header) < 5 || header[0] != "SNAPSHOT") return "";
   string eventId = header[1];
   if(header[3] != InpSymbol) return "";

   for(int i = 1; i < count; i++)
   {
      string line = Trim(lines[i]);
      if(line == "") continue;
      string parts[];
      int n = StringSplit(line, '|', parts);
      if(n == 0) continue;
      if(parts[0] == "POSITION" && n >= 11)
      {
         int idx = ArraySize(g_positions);
         ArrayResize(g_positions, idx + 1);
         g_positions[idx].ticket = parts[1];
         g_positions[idx].type = parts[3];
         g_positions[idx].volume = StringToDouble(parts[4]);
         g_positions[idx].priceOpen = StringToDouble(parts[5]);
         g_positions[idx].sl = StringToDouble(parts[6]);
         g_positions[idx].tp = StringToDouble(parts[7]);
      }
      else if(parts[0] == "ORDER" && n >= 12 && InpCopyPendingOrders)
      {
         int idx = ArraySize(g_orders);
         ArrayResize(g_orders, idx + 1);
         g_orders[idx].ticket = parts[1];
         g_orders[idx].type = parts[3];
         g_orders[idx].volume = StringToDouble(parts[4]);
         g_orders[idx].priceOpen = StringToDouble(parts[5]);
         g_orders[idx].sl = StringToDouble(parts[6]);
         g_orders[idx].tp = StringToDouble(parts[7]);
         g_orders[idx].expiration = (datetime)StringToInteger(parts[10]);
         g_orders[idx].stopLimit = n >= 13 ? StringToDouble(parts[12]) : 0.0;
      }
   }
   return eventId;
}

void Reconcile()
{
   CloseRemovedPositions();
   DeleteRemovedOrders();
   SyncPositions();
   SyncOrders();
}

void SyncPositions()
{
   for(int i = 0; i < ArraySize(g_positions); i++)
   {
      TargetPosition target = g_positions[i];
      ulong followerTicket = FindCopiedPosition(target.ticket);
      if(followerTicket == 0)
      {
         OpenCopiedPosition(target);
      }
      else if(PositionSelectByTicket(followerTicket))
      {
         double currentVolume = PositionGetDouble(POSITION_VOLUME);
         if(InpCopyPartialClose && currentVolume > NormalizeVolume(target.volume))
            PartialClose(followerTicket, currentVolume - NormalizeVolume(target.volume));
         ModifyPositionIfNeeded(followerTicket, target.sl, target.tp);
      }
   }
}

void SyncOrders()
{
   if(!InpCopyPendingOrders) return;
   for(int i = 0; i < ArraySize(g_orders); i++)
   {
      TargetOrder target = g_orders[i];
      ulong followerTicket = FindCopiedOrder(target.ticket);
      if(followerTicket == 0) PlaceCopiedOrder(target);
      else ModifyOrderIfNeeded(followerTicket, target);
   }
}

void OpenCopiedPosition(const TargetPosition &target)
{
   double volume = NormalizeVolume(target.volume);
   string comment = CopyComment(target.ticket);
   if(InpDryRun)
   {
      Print("DRY RUN open ", target.type, " ", volume, " ", InpSymbol, " SL=", target.sl, " TP=", target.tp);
      return;
   }
   bool ok = false;
   if(target.type == "BUY") ok = trade.Buy(volume, InpSymbol, 0.0, NormalizePrice(target.sl), NormalizePrice(target.tp), comment);
   if(target.type == "SELL") ok = trade.Sell(volume, InpSymbol, 0.0, NormalizePrice(target.sl), NormalizePrice(target.tp), comment);
   if(!ok) SendStatus("error", "Open position failed for master " + target.ticket + ": " + trade.ResultRetcodeDescription());
}

void PlaceCopiedOrder(const TargetOrder &target)
{
   double volume = NormalizeVolume(target.volume);
   double price = NormalizePrice(target.priceOpen);
   double sl = NormalizePrice(target.sl);
   double tp = NormalizePrice(target.tp);
   string comment = CopyComment(target.ticket);
   ENUM_ORDER_TYPE_TIME typeTime = target.expiration > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
   if(InpDryRun)
   {
      Print("DRY RUN pending ", target.type, " ", volume, " @", price);
      return;
   }

   bool ok = false;
   if(target.type == "BUY_LIMIT") ok = trade.BuyLimit(volume, price, InpSymbol, sl, tp, typeTime, target.expiration, comment);
   if(target.type == "SELL_LIMIT") ok = trade.SellLimit(volume, price, InpSymbol, sl, tp, typeTime, target.expiration, comment);
   if(target.type == "BUY_STOP") ok = trade.BuyStop(volume, price, InpSymbol, sl, tp, typeTime, target.expiration, comment);
   if(target.type == "SELL_STOP") ok = trade.SellStop(volume, price, InpSymbol, sl, tp, typeTime, target.expiration, comment);
   if(target.type == "BUY_STOP_LIMIT") ok = trade.OrderOpen(InpSymbol, ORDER_TYPE_BUY_STOP_LIMIT, volume, NormalizePrice(target.stopLimit), price, sl, tp, typeTime, target.expiration, comment);
   if(target.type == "SELL_STOP_LIMIT") ok = trade.OrderOpen(InpSymbol, ORDER_TYPE_SELL_STOP_LIMIT, volume, NormalizePrice(target.stopLimit), price, sl, tp, typeTime, target.expiration, comment);
   if(!ok) SendStatus("error", "Pending order failed for master " + target.ticket + ": " + trade.ResultRetcodeDescription());
}

void ModifyPositionIfNeeded(const ulong ticket, const double sl, const double tp)
{
   if(!PositionSelectByTicket(ticket)) return;
   double currentSl = PositionGetDouble(POSITION_SL);
   double currentTp = PositionGetDouble(POSITION_TP);
   if(SamePrice(currentSl, sl) && SamePrice(currentTp, tp)) return;
   if(InpDryRun) { Print("DRY RUN modify position ", ticket); return; }
   if(!trade.PositionModify(ticket, NormalizePrice(sl), NormalizePrice(tp)))
      SendStatus("error", "Position modify failed " + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
}

void ModifyOrderIfNeeded(const ulong ticket, const TargetOrder &target)
{
   if(!OrderSelect(ticket)) return;
   if(SamePrice(OrderGetDouble(ORDER_PRICE_OPEN), target.priceOpen) && SamePrice(OrderGetDouble(ORDER_SL), target.sl) && SamePrice(OrderGetDouble(ORDER_TP), target.tp)) return;
   if(InpDryRun) { Print("DRY RUN modify order ", ticket); return; }
   if(!trade.OrderModify(ticket, NormalizePrice(target.priceOpen), NormalizePrice(target.sl), NormalizePrice(target.tp), target.expiration > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC, target.expiration))
      SendStatus("error", "Order modify failed " + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
}

void PartialClose(const ulong ticket, const double volumeToClose)
{
   double volume = NormalizeVolume(volumeToClose);
   if(volume <= 0.0) return;
   if(InpDryRun) { Print("DRY RUN partial close ", ticket, " volume=", volume); return; }
   if(!trade.PositionClosePartial(ticket, volume, InpDeviationPoints))
      SendStatus("error", "Partial close failed " + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
}

void CloseRemovedPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      string masterTicket = MasterTicketFromComment(PositionGetString(POSITION_COMMENT));
      if(masterTicket == "" || TargetPositionExists(masterTicket)) continue;
      if(InpDryRun) { Print("DRY RUN close removed position ", ticket); continue; }
      if(!trade.PositionClose(ticket, InpDeviationPoints))
         SendStatus("error", "Close removed position failed " + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
   }
}

void DeleteRemovedOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol) continue;
      string masterTicket = MasterTicketFromComment(OrderGetString(ORDER_COMMENT));
      if(masterTicket == "" || TargetOrderExists(masterTicket)) continue;
      if(InpDryRun) { Print("DRY RUN delete removed order ", ticket); continue; }
      if(!trade.OrderDelete(ticket))
         SendStatus("error", "Delete removed order failed " + IntegerToString((long)ticket) + ": " + trade.ResultRetcodeDescription());
   }
}

ulong FindCopiedPosition(const string masterTicket)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == InpSymbol && MasterTicketFromComment(PositionGetString(POSITION_COMMENT)) == masterTicket)
         return ticket;
   }
   return 0;
}

ulong FindCopiedOrder(const string masterTicket)
{
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket != 0 && OrderSelect(ticket) && OrderGetString(ORDER_SYMBOL) == InpSymbol && MasterTicketFromComment(OrderGetString(ORDER_COMMENT)) == masterTicket)
         return ticket;
   }
   return 0;
}

bool TargetPositionExists(const string masterTicket)
{
   for(int i = 0; i < ArraySize(g_positions); i++) if(g_positions[i].ticket == masterTicket) return true;
   return false;
}

bool TargetOrderExists(const string masterTicket)
{
   for(int i = 0; i < ArraySize(g_orders); i++) if(g_orders[i].ticket == masterTicket) return true;
   return false;
}

string CopyComment(const string masterTicket)
{
   return "CP:" + masterTicket;
}

string MasterTicketFromComment(const string comment)
{
   if(StringFind(comment, "CP:") != 0) return "";
   return StringSubstr(comment, 3);
}

double NormalizeVolume(const double volume)
{
   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   double normalized = MathMax(minLot, MathMin(maxLot, volume));
   normalized = MathFloor(normalized / step + 0.0000001) * step;
   return NormalizeDouble(normalized, 2);
}

double NormalizePrice(const double price)
{
   if(price <= 0.0) return 0.0;
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

bool SamePrice(const double a, const double b)
{
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   return MathAbs(NormalizePrice(a) - NormalizePrice(b)) <= point / 2.0;
}

string Trim(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   return value;
}

void SendStatus(const string level, const string message)
{
   Print(level, ": ", message);
   string json = "{\"followerId\":\"" + InpFollowerId + "\",\"level\":\"" + level + "\",\"message\":\"" + JsonEscape(message) + "\"}";
   string headers = "Authorization: Bearer " + InpAuthToken + "\r\nContent-Type: application/json\r\n";
   char data[];
   char result[];
   string resultHeaders;
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(data) > 0) ArrayResize(data, ArraySize(data) - 1);
   WebRequest("POST", InpRelayUrl + "/api/follower-status", headers, InpRequestTimeout, data, result, resultHeaders);
}

string JsonEscape(string value)
{
   StringReplace(value, "\\", "\\\\");
   StringReplace(value, "\"", "\\\"");
   return value;
}
