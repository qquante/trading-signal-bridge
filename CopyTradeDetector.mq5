//|                                    Copy Trade Detection System  |
//|                                    Detects trades on GOLD (XAU) |
#property copyright "CopyTrade System"
#property version   "2.00"
#property description "Detects trades on GOLD - Webhook only, no logs"
#property strict

input string   InpSymbolFilter = "Gold";       // Symbol filter (Gold, XAU, etc)
input string   InpWebhookURL   = "http://127.0.0.1:8000/trade";  // Webhook URL

ulong    lastDealTicket = 0;
ulong    lastOrderTicket = 0;

//| Check if symbol matches filter (case-insensitive)                  |
bool MatchesSymbolFilter(string symbol)
{
   if(InpSymbolFilter == "")
      return true;
   
   string symbolLower = symbol;
   string filterLower = InpSymbolFilter;
   StringToLower(symbolLower);
   StringToLower(filterLower);
   
   return (StringFind(symbolLower, filterLower) >= 0);
}

int OnInit()
{
   Comment("CopyTrade Detector ACTIVE\nMonitoring: ", InpSymbolFilter);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
}

//| SINGLE WEBHOOK FUNCTION - Sends ALL events                        |
void SendWebhook(string symbol, string action, string orderType, string side,
                 double volume, double price, ulong ticket, double sl, double tp)
{
   // Replace spaces with underscores in order type
   StringReplace(orderType, " ", "_");
   
   // Build JSON payload
   string json = StringFormat(
      "{" +
      "\"symbol\":\"%s\"," +
      "\"action\":\"%s\"," +
      "\"order_type\":\"%s\"," +
      "\"side\":\"%s\"," +
      "\"volume\":%.4f," +
      "\"price\":%.5f," +
      "\"ticket\":%I64u," +
      "\"sl\":%.5f," +
      "\"tp\":%.5f," +
      "\"timestamp\":%I64d," +
      "\"source\":\"MT5\"" +
      "}",
      symbol, action, orderType, side, volume, price, 
      ticket, sl, tp, (long)TimeCurrent()
   );
   
   // HTTP headers
   string headers = "Content-Type: application/json\r\n";
   
   // Response variables
   char postData[];
   char result[];
   string resultHeaders;
   
   // Convert JSON to char array
   StringToCharArray(json, postData, 0, StringLen(json), CP_UTF8);
   
   // Send POST request (500ms timeout for speed)
   int timeout = 500;
   WebRequest("POST", InpWebhookURL, headers, timeout, postData, result, resultHeaders);
}

//| TradeTransaction function - Called on EVERY trade event           |
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   //--- DEAL EXECUTED (OPEN/CLOSE position)
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      
      if(dealTicket == lastDealTicket)
         return;
      
      lastDealTicket = dealTicket;
      
      if(HistoryDealSelect(dealTicket))
      {
         string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
         
         if(MatchesSymbolFilter(symbol))
         {
            ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
            ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
            double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
            
            string action = "";
            string side = "";
            
            if(dealEntry == DEAL_ENTRY_IN)
            {
               action = "OPEN";
               side = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            }
            else if(dealEntry == DEAL_ENTRY_OUT)
            {
               action = "CLOSE";
               side = (dealType == DEAL_TYPE_BUY) ? "SELL" : "BUY";
            }
            else if(dealEntry == DEAL_ENTRY_INOUT)
            {
               action = "REVERSE";
               side = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            }
            else
            {
               return; // Skip balance operations
            }
            
            // Update chart
            Comment(StringFormat("CopyTrade Active\n%s %s %.2f @ %.2f", action, side, volume, price));
            
            // Send webhook
            SendWebhook(symbol, action, "MARKET", side, volume, price, dealTicket, 0, 0);
         }
      }
   }
   
   //--- NEW PENDING ORDER
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      ulong orderTicket = trans.order;
      if(OrderSelect(orderTicket))
      {
         string symbol = OrderGetString(ORDER_SYMBOL);
         if(MatchesSymbolFilter(symbol))
         {
            ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            
            // Skip market orders
            if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_SELL)
               return;
            
            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double price = OrderGetDouble(ORDER_PRICE_OPEN);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);
            
            string orderTypeName = GetOrderTypeName(orderType);
            string side = (StringFind(orderTypeName, "BUY") >= 0) ? "BUY" : "SELL";
            
            // Avoid duplicate
            if(orderTicket == lastOrderTicket)
               return;
            lastOrderTicket = orderTicket;
            
            // Update chart
            Comment(StringFormat("CopyTrade Active\nNEW %s %.2f @ %.2f", orderTypeName, volume, price));
            
            // Send webhook
            SendWebhook(symbol, "NEW", orderTypeName, side, volume, price, orderTicket, sl, tp);
         }
      }
   }
   
   //--- ORDER MODIFIED
   if(trans.type == TRADE_TRANSACTION_ORDER_UPDATE)
   {
      ulong orderTicket = trans.order;
      if(OrderSelect(orderTicket))
      {
         string symbol = OrderGetString(ORDER_SYMBOL);
         if(MatchesSymbolFilter(symbol))
         {
            ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            
            // Skip market orders
            if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_SELL)
               return;
            
            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double price = OrderGetDouble(ORDER_PRICE_OPEN);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);
            
            string orderTypeName = GetOrderTypeName(orderType);
            string side = (StringFind(orderTypeName, "BUY") >= 0) ? "BUY" : "SELL";
            
            // Update chart
            Comment(StringFormat("CopyTrade Active\nMODIFY %s %.2f @ %.2f", orderTypeName, volume, price));
            
            // Send webhook
            SendWebhook(symbol, "MODIFY", orderTypeName, side, volume, price, orderTicket, sl, tp);
         }
      }
   }
   
   //--- ORDER CANCELLED/DELETED
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      string symbol = trans.symbol;
      if(MatchesSymbolFilter(symbol))
      {
         // Update chart
         Comment(StringFormat("CopyTrade Active\nCANCEL Order #%I64u", trans.order));
         
         // Send webhook
         SendWebhook(symbol, "CANCEL", "PENDING", "", 0, 0, trans.order, 0, 0);
      }
   }
}

//| Get order type name                                                |
string GetOrderTypeName(ENUM_ORDER_TYPE orderType)
{
   switch(orderType)
   {
      case ORDER_TYPE_BUY_LIMIT:   return "BUY LIMIT";
      case ORDER_TYPE_SELL_LIMIT:  return "SELL LIMIT";
      case ORDER_TYPE_BUY_STOP:    return "BUY STOP";
      case ORDER_TYPE_SELL_STOP:   return "SELL STOP";
      case ORDER_TYPE_BUY_STOP_LIMIT:  return "BUY STOP LIMIT";
      case ORDER_TYPE_SELL_STOP_LIMIT: return "SELL STOP LIMIT";
      default: return "UNKNOWN";
   }
}

//| Tick function                                                      |
void OnTick()
{
   // Not needed
}
