#property strict
#property version   "1.00"
#property description "Master EA for near-real-time XAUUSDr copy trading via local Node.js relay."

input string InpRelayUrl       = "http://127.0.0.1:8787";
input string InpAuthToken      = "CHANGE_ME_LONG_RANDOM_TOKEN";
input string InpMasterId       = "MASTER_A";
input string InpSymbol         = "XAUUSDr";
input int    InpHeartbeatMs    = 500;
input int    InpRequestTimeout = 1000;

ulong g_lastSentHash = 0;
ulong g_eventCounter = 0;

int OnInit()
{
   if(_Symbol != InpSymbol)
      Print("Master EA is configured for ", InpSymbol, ". Current chart is ", _Symbol, "; this is OK if the broker offers the configured symbol.");
   EventSetMillisecondTimer(MathMax(100, InpHeartbeatMs));
   SendSnapshot("init");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   SendSnapshot("heartbeat");
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   SendSnapshot("trade");
}

void SendSnapshot(const string reason)
{
   string snapshot = BuildSnapshot(reason);
   ulong hash = HashString(snapshot);
   if(reason != "heartbeat" || hash != g_lastSentHash)
   {
      if(PostSnapshot(snapshot))
         g_lastSentHash = hash;
   }
}

string BuildSnapshot(const string reason)
{
   g_eventCounter++;
   long now = (long)GetMicrosecondCount() / 1000;
   string eventId = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "-" + IntegerToString((long)TimeCurrent()) + "-" + IntegerToString((long)g_eventCounter) + "-" + reason;
   string body = "SNAPSHOT|" + eventId + "|" + InpMasterId + "|" + InpSymbol + "|" + IntegerToString(now) + "\n";

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      string side = type == POSITION_TYPE_BUY ? "BUY" : "SELL";
      body += "POSITION|" + IntegerToString((long)ticket) + "|" + InpSymbol + "|" + side + "|" +
              DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "|" +
              DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits) + "|" +
              DoubleToString(PositionGetDouble(POSITION_SL), _Digits) + "|" +
              DoubleToString(PositionGetDouble(POSITION_TP), _Digits) + "|" +
              IntegerToString((long)PositionGetInteger(POSITION_MAGIC)) + "|" +
              Base64Url(PositionGetString(POSITION_COMMENT)) + "|" +
              IntegerToString((long)PositionGetInteger(POSITION_TIME_MSC)) + "\n";
   }

   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      string typeName = PendingTypeName(type);
      if(typeName == "") continue;

      body += "ORDER|" + IntegerToString((long)ticket) + "|" + InpSymbol + "|" + typeName + "|" +
              DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2) + "|" +
              DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits) + "|" +
              DoubleToString(OrderGetDouble(ORDER_SL), _Digits) + "|" +
              DoubleToString(OrderGetDouble(ORDER_TP), _Digits) + "|" +
              IntegerToString((long)OrderGetInteger(ORDER_MAGIC)) + "|" +
              Base64Url(OrderGetString(ORDER_COMMENT)) + "|" +
              IntegerToString((long)OrderGetInteger(ORDER_TIME_EXPIRATION)) + "|" +
              IntegerToString((long)OrderGetInteger(ORDER_TIME_SETUP_MSC)) + "|" +
              DoubleToString(OrderGetDouble(ORDER_PRICE_STOPLIMIT), _Digits) + "\n";
   }
   return body;
}

bool PostSnapshot(const string body)
{
   string headers = "Authorization: Bearer " + InpAuthToken + "\r\nContent-Type: text/plain; charset=utf-8\r\n";
   char data[];
   char result[];
   string resultHeaders;
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(ArraySize(data) > 0) ArrayResize(data, ArraySize(data) - 1);

   ResetLastError();
   int status = WebRequest("POST", InpRelayUrl + "/api/snapshot", headers, InpRequestTimeout, data, result, resultHeaders);
   if(status != 200)
   {
      Print("Master snapshot POST failed. HTTP=", status, " error=", GetLastError(), " response=", CharArrayToString(result, 0, -1, CP_UTF8));
      return false;
   }
   return true;
}

string PendingTypeName(const ENUM_ORDER_TYPE type)
{
   if(type == ORDER_TYPE_BUY_LIMIT) return "BUY_LIMIT";
   if(type == ORDER_TYPE_SELL_LIMIT) return "SELL_LIMIT";
   if(type == ORDER_TYPE_BUY_STOP) return "BUY_STOP";
   if(type == ORDER_TYPE_SELL_STOP) return "SELL_STOP";
   if(type == ORDER_TYPE_BUY_STOP_LIMIT) return "BUY_STOP_LIMIT";
   if(type == ORDER_TYPE_SELL_STOP_LIMIT) return "SELL_STOP_LIMIT";
   return "";
}

string Base64Url(const string value)
{
   char source[];
   uchar src[];
   uchar key[];
   uchar encoded[];
   StringToCharArray(value, source, 0, WHOLE_ARRAY, CP_UTF8);
   int size = ArraySize(source);
   if(size > 0) size--;
   ArrayResize(src, size);
   for(int i = 0; i < size; i++) src[i] = (uchar)source[i];
   CryptEncode(CRYPT_BASE64, src, key, encoded);
   string out = CharArrayToString(encoded);
   StringReplace(out, "+", "-");
   StringReplace(out, "/", "_");
   StringReplace(out, "=", "");
   return out;
}

ulong HashString(const string value)
{
   ulong hash = 1469598103934665603;
   for(int i = 0; i < StringLen(value); i++)
   {
      hash ^= (ushort)StringGetCharacter(value, i);
      hash *= 1099511628211;
   }
   return hash;
}
