//|                                     CARTEL Sniper Gold System      |
//|                              Copy Trade + Dashboard Profissional   |
#property copyright "CARTEL Trading System"
#property version   "2.20"
#property description "Copy Trade com Dashboard Profissional"
#property strict

//| INPUTS - Configurações                                            |
input group "=== WEBHOOK ==="
input string   InpSymbolFilter = "XAU";                              // Filtro de Símbolo
input string   InpWebhookURL   = "http://127.0.0.1:8000/trade";      // URL do Webhook

input group "=== TREND FILTER ==="
input int      InpMAPeriod     = 100;                                // Período da MA
input ENUM_MA_METHOD InpMAMethod = MODE_SMA;                         // Método da MA
input ENUM_TIMEFRAMES InpMATimeframe = PERIOD_H1;                    // Timeframe da MA
input int      InpBufferPoints = 1000;                               // Buffer (pontos)

input group "=== GRID ==="
input double   InpInitialLot   = 0.01;                               // Lote Inicial (G1)
input double   InpLotMultiplier = 2.0;                               // Multiplicador de Lote
input int      InpGridDistance = 1000;                               // Distância do Grid (pontos)

input group "=== PAINEL ==="
input int      InpPanelX       = 10;                                 // Posição X do Painel
input int      InpPanelY       = 30;                                 // Posição Y do Painel
input color    InpColorBg      = C'20,20,30';                        // Cor de Fundo
input color    InpColorBorder  = C'50,50,70';                        // Cor da Borda
input color    InpColorText    = clrWhite;                           // Cor do Texto
input color    InpColorProfit  = clrLime;                            // Cor de Lucro
input color    InpColorLoss    = clrRed;                             // Cor de Perda
input color    InpColorNeutral = clrGold;                            // Cor Neutra

//| VARIÁVEIS GLOBAIS                                                 |
// Webhook
ulong    lastDealTicket = 0;
ulong    lastOrderTicket = 0;

// Tracking de conta
double   g_accountStartBalance = 0;    // Balance inicial da conta (quando criou)
double   g_maxEquity = 0;
double   g_maxDrawdown = 0;
double   g_currentDrawdown = 0;

// MA Handle
int      g_maHandle = INVALID_HANDLE;

// Painel
string   PREFIX = "SG_";
int      PANEL_WIDTH = 280;
int      PANEL_HEIGHT = 660;  // Altura completa
int      LINE_HEIGHT = 18;

// Estado
bool     g_isPaused = false;

// Estatísticas de Grid (por nível)
struct GridStats {
   int    count;      // Quantas vezes fechou nesse nível
   double profit;     // Lucro total
};

// Estrutura para agrupar ciclos de grid
struct GridCycle {
   datetime time;        // Timestamp do fechamento
   int      posCount;    // Quantas posições fecharam juntas
   double   profit;      // Lucro do ciclo
};

int OnInit()
{
   // Inicializa MA
   g_maHandle = iMA(_Symbol, InpMATimeframe, InpMAPeriod, 0, InpMAMethod, PRICE_CLOSE);
   if(g_maHandle == INVALID_HANDLE)
      return INIT_FAILED;
   
   // Busca balance inicial da conta (primeiro depósito)
   g_accountStartBalance = GetAccountStartBalance();
   
   // Inicializa tracking
   g_maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Cria painel
   CreatePanel();
   
   // Timer para atualizar painel
   EventSetMillisecondTimer(500);
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PREFIX);
   
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);
   
   EventKillTimer();
   Comment("");
}

//| Timer function - Atualiza painel + Sync                            |
void OnTimer()
{
   UpdatePanel();
   
   // Sync de posições a cada 1 segundo (usa GetTickCount64 para funcionar mesmo sem ticks)
   static ulong lastSync = 0;
   ulong now = GetTickCount64();
   if(now - lastSync >= 1000)  // 1000ms = 1 segundo
   {
      SendPositionSync();
      lastSync = now;
   }
}

//| Tick function                                                      |
void OnTick()
{
   // Atualiza Drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   if(equity > g_maxEquity)
      g_maxEquity = equity;
   
   // Drawdown atual
   if(g_maxEquity > 0)
      g_currentDrawdown = (g_maxEquity - equity) / g_maxEquity * 100;
   
   // Max Drawdown
   if(g_currentDrawdown > g_maxDrawdown)
      g_maxDrawdown = g_currentDrawdown;
}

//| OBTER BALANCE INICIAL DA CONTA                                    |
double GetAccountStartBalance()
{
   // Busca o primeiro depósito no histórico
   datetime startTime = 0;
   datetime endTime = TimeCurrent();
   
   if(!HistorySelect(startTime, endTime))
      return AccountInfoDouble(ACCOUNT_BALANCE);
   
   double firstDeposit = 0;
   int total = HistoryDealsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         if(type == DEAL_TYPE_BALANCE)
         {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit > 0)  // Depósito
            {
               firstDeposit = profit;
               break;
            }
         }
      }
   }
   
   return firstDeposit > 0 ? firstDeposit : AccountInfoDouble(ACCOUNT_BALANCE);
}

//| OBTER LUCRO REALIZADO HOJE (deals fechados)                       |
double GetTodayRealizedProfit()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime now = TimeCurrent();
   
   if(!HistorySelect(todayStart, now))
      return 0;
   
   double profit = 0;
   int total = HistoryDealsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(!MatchesSymbolFilter(symbol))
            continue;
         
         ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
         // Só conta fechamentos (OUT) e reversões (INOUT)
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
         {
            profit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
            profit += HistoryDealGetDouble(ticket, DEAL_SWAP);
            profit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         }
      }
   }
   
   return profit;
}

//| OBTER LUCRO TOTAL DA CONTA (desde o início)                       |
double GetTotalAccountProfit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double floating = GetFloatingPnL();
   double totalEquity = currentBalance + floating;
   
   // Lucro = Equity atual - Depósitos totais
   double deposits = GetTotalDeposits();
   
   return totalEquity - deposits;
}

//| OBTER TOTAL DE DEPÓSITOS                                          |
double GetTotalDeposits()
{
   datetime startTime = 0;
   datetime endTime = TimeCurrent();
   
   if(!HistorySelect(startTime, endTime))
      return g_accountStartBalance;
   
   double deposits = 0;
   double withdrawals = 0;
   int total = HistoryDealsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         if(type == DEAL_TYPE_BALANCE)
         {
            double amount = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(amount > 0)
               deposits += amount;
            else
               withdrawals += MathAbs(amount);
         }
      }
   }
   
   return deposits - withdrawals;
}

//| CONTAR DEALS DE HOJE                                              |
int GetTodayDealsCount()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime now = TimeCurrent();
   
   if(!HistorySelect(todayStart, now))
      return 0;
   
   int count = 0;
   int total = HistoryDealsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(!MatchesSymbolFilter(symbol))
            continue;
         
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
         // Conta entradas e saídas
         if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            count++;
      }
   }
   
   return count;
}

//| OBTER ESTATÍSTICAS DOS GRIDS HOJE (LÓGICA CORRETA)               |
//| G1 = Ciclo fechou com 1 posição                                   |
//| G2 = Ciclo fechou com 2 posições                                  |
//| G3 = Ciclo fechou com 3 posições                                  |
//| G4 = Ciclo fechou com 4 posições                                  |
//| G5 = Ciclo fechou com 5+ posições                                 |
//| Se fechou em G3, NÃO conta para G1, G2 (só o nível máximo)       |
void GetTodayGridStats(GridStats &g1, GridStats &g2, GridStats &g3, GridStats &g4, GridStats &g5)
{
   // Inicializa
   g1.count = 0; g1.profit = 0;
   g2.count = 0; g2.profit = 0;
   g3.count = 0; g3.profit = 0;
   g4.count = 0; g4.profit = 0;
   g5.count = 0; g5.profit = 0;
   
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime now = TimeCurrent();
   
   if(!HistorySelect(todayStart, now))
      return;
   
   int total = HistoryDealsTotal();
   
   // Arrays para armazenar fechamentos
   datetime closeTimes[];
   double   closeProfits[];
   int      closeCount = 0;
   
   ArrayResize(closeTimes, total);
   ArrayResize(closeProfits, total);
   
   // Coleta todos os fechamentos
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(!MatchesSymbolFilter(symbol))
            continue;
         
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
         // Só fechamentos
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
            continue;
         
         datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += HistoryDealGetDouble(ticket, DEAL_SWAP);
         profit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         
         closeTimes[closeCount] = dealTime;
         closeProfits[closeCount] = profit;
         closeCount++;
      }
   }
   
   if(closeCount == 0)
      return;
   
   // Agrupa fechamentos por timestamp (dentro de 10 segundos = mesmo ciclo)
   int timeWindow = 10;  // segundos
   
   int i = 0;
   while(i < closeCount)
   {
      datetime cycleStart = closeTimes[i];
      int cyclePositions = 0;
      double cycleProfit = 0;
      
      // Conta todas as posições que fecharam juntas (mesmo ciclo)
      while(i < closeCount && (closeTimes[i] - cycleStart) <= timeWindow)
      {
         cyclePositions++;
         cycleProfit += closeProfits[i];
         i++;
      }
      
      // Categoriza pelo número de posições no ciclo (= nível do grid)
      switch(cyclePositions)
      {
         case 1:  g1.count++; g1.profit += cycleProfit; break;
         case 2:  g2.count++; g2.profit += cycleProfit; break;
         case 3:  g3.count++; g3.profit += cycleProfit; break;
         case 4:  g4.count++; g4.profit += cycleProfit; break;
         default: g5.count++; g5.profit += cycleProfit; break;  // 5+
      }
   }
}

//| CRIAR PAINEL                                                       |
void CreatePanel()
{
   int x = InpPanelX;
   int y = InpPanelY;
   
   // Fundo principal
   CreateRectangle(PREFIX+"bg", x, y, PANEL_WIDTH, PANEL_HEIGHT, InpColorBg, InpColorBorder);
   
   // Header
   CreateRectangle(PREFIX+"header", x, y, PANEL_WIDTH, 28, C'30,30,45', InpColorBorder);
   CreateLabel(PREFIX+"title", x+10, y+6, "CARTEL SNIPER GOLD", InpColorNeutral, 11, true);
   CreateLabel(PREFIX+"version", x+PANEL_WIDTH-45, y+9, "v2.20", clrGray, 8, false);
   
   y += 33;
   
   // === SEÇÃO: STATUS ===
   CreateLabel(PREFIX+"lbl_status", x+10, y, "Status", clrGray, 9, false);
   CreateLabel(PREFIX+"val_status", x+PANEL_WIDTH-10, y, "ATIVO", InpColorProfit, 9, true, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_symbol", x+10, y, "Símbolo", clrGray, 9, false);
   CreateLabel(PREFIX+"val_symbol", x+PANEL_WIDTH-10, y, _Symbol, InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_webhook", x+10, y, "Webhook", clrGray, 9, false);
   CreateLabel(PREFIX+"val_webhook", x+PANEL_WIDTH-10, y, "CONECTADO", InpColorProfit, 9, false, true);
   
   y += LINE_HEIGHT + 3;
   CreateLine(PREFIX+"line1", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 6;
   
   // === SEÇÃO: CONTA ===
   CreateLabel(PREFIX+"sec_conta", x+10, y, "═══ CONTA ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_balance", x+10, y, "Balance", clrGray, 9, false);
   CreateLabel(PREFIX+"val_balance", x+PANEL_WIDTH-10, y, "0.00 $", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_equity", x+10, y, "Equity", clrGray, 9, false);
   CreateLabel(PREFIX+"val_equity", x+PANEL_WIDTH-10, y, "0.00 $", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_margin", x+10, y, "Margem Livre", clrGray, 9, false);
   CreateLabel(PREFIX+"val_margin", x+PANEL_WIDTH-10, y, "0.00 $", InpColorText, 9, false, true);
   
   y += LINE_HEIGHT + 3;
   CreateLine(PREFIX+"line2", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 6;
   
   // === SEÇÃO: LUCROS ===
   CreateLabel(PREFIX+"sec_lucros", x+10, y, "═══ LUCROS ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_dailyreal", x+10, y, "Lucro Hoje (Real)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_dailyreal", x+PANEL_WIDTH-10, y, "+0.00 $", InpColorProfit, 9, true, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_floating", x+10, y, "Floating (Aberto)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_floating", x+PANEL_WIDTH-10, y, "0.00 $", InpColorText, 9, true, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_todaytotal", x+10, y, "Total Hoje", clrGray, 9, false);
   CreateLabel(PREFIX+"val_todaytotal", x+PANEL_WIDTH-10, y, "+0.00 $", InpColorProfit, 9, true, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_totalprofit", x+10, y, "Lucro Total Conta", clrGray, 9, false);
   CreateLabel(PREFIX+"val_totalprofit", x+PANEL_WIDTH-10, y, "+0.00 $", InpColorProfit, 9, true, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_maxdd", x+10, y, "Max Drawdown", clrGray, 9, false);
   CreateLabel(PREFIX+"val_maxdd", x+PANEL_WIDTH-10, y, "0.0%", InpColorNeutral, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_currentdd", x+10, y, "DD Atual", clrGray, 9, false);
   CreateLabel(PREFIX+"val_currentdd", x+PANEL_WIDTH-10, y, "0.0%", InpColorNeutral, 9, false, true);
   
   y += LINE_HEIGHT + 3;
   CreateLine(PREFIX+"line3", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 6;
   
   // === SEÇÃO: TREND ===
   CreateLabel(PREFIX+"sec_trend", x+10, y, "═══ TREND ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_trend", x+10, y, "Tendência", clrGray, 9, false);
   CreateLabel(PREFIX+"val_trend", x+PANEL_WIDTH-10, y, "---", InpColorNeutral, 9, true, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_trendchange", x+10, y, "Muda Trend @", clrGray, 9, false);
   CreateLabel(PREFIX+"val_trendchange", x+PANEL_WIDTH-10, y, "0.00", InpColorText, 9, false, true);
   
   y += LINE_HEIGHT + 3;
   CreateLine(PREFIX+"line4", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 6;
   
   // === SEÇÃO: GRIDS HOJE ===
   // G = Quantas posições precisou abrir antes de fechar
   CreateLabel(PREFIX+"sec_grids", x+10, y, "═══ CICLOS GRID ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_deals", x+10, y, "Ordens Hoje", clrGray, 9, false);
   CreateLabel(PREFIX+"val_deals", x+PANEL_WIDTH-10, y, "0", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // G1 = Fechou com 1 posição
   CreateLabel(PREFIX+"lbl_g1", x+10, y, "G1 (1 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g1", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // G2 = Fechou com 2 posições
   CreateLabel(PREFIX+"lbl_g2", x+10, y, "G2 (2 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g2", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // G3 = Fechou com 3 posições
   CreateLabel(PREFIX+"lbl_g3", x+10, y, "G3 (3 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g3", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // G4 = Fechou com 4 posições
   CreateLabel(PREFIX+"lbl_g4", x+10, y, "G4 (4 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g4", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // G5 = Fechou com 5+ posições
   CreateLabel(PREFIX+"lbl_g5", x+10, y, "G5+(5+ pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g5", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   
   y += LINE_HEIGHT + 3;
   CreateLine(PREFIX+"line5", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 6;
   
   // === SEÇÃO: POSIÇÕES ABERTAS ===
   CreateLabel(PREFIX+"sec_pos", x+10, y, "═══ POSIÇÕES ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   // BUY: count x lots | P&L | pts
   CreateLabel(PREFIX+"lbl_buy", x+10, y, "BUY", InpColorProfit, 9, true);
   CreateLabel(PREFIX+"val_buy", x+PANEL_WIDTH-10, y, "0 x 0.00 | $0.00 | 0p", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // SELL: count x lots | P&L | pts
   CreateLabel(PREFIX+"lbl_sell", x+10, y, "SELL", InpColorLoss, 9, true);
   CreateLabel(PREFIX+"val_sell", x+PANEL_WIDTH-10, y, "0 x 0.00 | $0.00 | 0p", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // Preço Médio das posições abertas
   CreateLabel(PREFIX+"lbl_avgprice", x+10, y, "Preço Médio", clrGray, 9, false);
   CreateLabel(PREFIX+"val_avgprice", x+PANEL_WIDTH-10, y, "---", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   // Próximo Grid BUY
   CreateLabel(PREFIX+"lbl_nextbuy", x+10, y, "Próx Grid B", clrGray, 9, false);
   CreateLabel(PREFIX+"val_nextbuy", x+PANEL_WIDTH-10, y, "---", InpColorProfit, 9, false, true);
   y += LINE_HEIGHT;
   
   // Próximo Grid SELL
   CreateLabel(PREFIX+"lbl_nextsell", x+10, y, "Próx Grid S", clrGray, 9, false);
   CreateLabel(PREFIX+"val_nextsell", x+PANEL_WIDTH-10, y, "---", InpColorLoss, 9, false, true);
   
   y += LINE_HEIGHT + 5;
   CreateLine(PREFIX+"line6", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 8;
   
   // Botões
   int btnWidth = (PANEL_WIDTH - 30) / 2;
   CreateButton(PREFIX+"btn_pause", x+10, y, btnWidth, 25, "PAUSAR", C'60,60,80', InpColorText);
   CreateButton(PREFIX+"btn_close", x+15+btnWidth, y, btnWidth, 25, "FECHAR TUDO", C'120,40,40', InpColorText);
   
   ChartRedraw();
}

//| ATUALIZAR PAINEL                                                   |
void UpdatePanel()
{
   // Status
   string status = g_isPaused ? "PAUSADO" : "ATIVO";
   color statusColor = g_isPaused ? InpColorNeutral : InpColorProfit;
   ObjectSetString(0, PREFIX+"val_status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, PREFIX+"val_status", OBJPROP_COLOR, statusColor);
   
   // === CONTA ===
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   ObjectSetString(0, PREFIX+"val_balance", OBJPROP_TEXT, DoubleToString(balance, 2) + " $");
   ObjectSetString(0, PREFIX+"val_equity", OBJPROP_TEXT, DoubleToString(equity, 2) + " $");
   ObjectSetString(0, PREFIX+"val_margin", OBJPROP_TEXT, DoubleToString(margin, 2) + " $");
   
   // === LUCROS ===
   // Lucro realizado hoje (deals fechados)
   double dailyReal = GetTodayRealizedProfit();
   string dailyRealStr = (dailyReal >= 0 ? "+" : "") + DoubleToString(dailyReal, 2) + " $";
   ObjectSetString(0, PREFIX+"val_dailyreal", OBJPROP_TEXT, dailyRealStr);
   ObjectSetInteger(0, PREFIX+"val_dailyreal", OBJPROP_COLOR, dailyReal >= 0 ? InpColorProfit : InpColorLoss);
   
   // Floating
   double floating = GetFloatingPnL();
   string floatStr = (floating >= 0 ? "+" : "") + DoubleToString(floating, 2) + " $";
   ObjectSetString(0, PREFIX+"val_floating", OBJPROP_TEXT, floatStr);
   ObjectSetInteger(0, PREFIX+"val_floating", OBJPROP_COLOR, floating >= 0 ? InpColorProfit : InpColorLoss);
   
   // Total hoje (realizado + floating)
   double todayTotal = dailyReal + floating;
   string todayTotalStr = (todayTotal >= 0 ? "+" : "") + DoubleToString(todayTotal, 2) + " $";
   ObjectSetString(0, PREFIX+"val_todaytotal", OBJPROP_TEXT, todayTotalStr);
   ObjectSetInteger(0, PREFIX+"val_todaytotal", OBJPROP_COLOR, todayTotal >= 0 ? InpColorProfit : InpColorLoss);
   
   // Lucro total da conta
   double totalProfit = GetTotalAccountProfit();
   string totalStr = (totalProfit >= 0 ? "+" : "") + DoubleToString(totalProfit, 2) + " $";
   ObjectSetString(0, PREFIX+"val_totalprofit", OBJPROP_TEXT, totalStr);
   ObjectSetInteger(0, PREFIX+"val_totalprofit", OBJPROP_COLOR, totalProfit >= 0 ? InpColorProfit : InpColorLoss);
   
   // Drawdowns
   ObjectSetString(0, PREFIX+"val_maxdd", OBJPROP_TEXT, DoubleToString(g_maxDrawdown, 2) + "%");
   ObjectSetInteger(0, PREFIX+"val_maxdd", OBJPROP_COLOR, g_maxDrawdown > 5 ? InpColorLoss : InpColorNeutral);
   
   ObjectSetString(0, PREFIX+"val_currentdd", OBJPROP_TEXT, DoubleToString(g_currentDrawdown, 2) + "%");
   ObjectSetInteger(0, PREFIX+"val_currentdd", OBJPROP_COLOR, g_currentDrawdown > 3 ? InpColorLoss : InpColorNeutral);
   
   // === TREND ===
   UpdateTrendInfo();
   
   // === GRIDS ===
   UpdateGridStats();
   
   // === POSIÇÕES ===
   UpdatePositionsInfo();
   
   ChartRedraw();
}

//| ATUALIZAR INFO DE TREND                                           |
void UpdateTrendInfo()
{
   double maValue[];
   ArraySetAsSeries(maValue, true);
   
   if(CopyBuffer(g_maHandle, 0, 0, 1, maValue) > 0)
   {
      double ma = maValue[0];
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double buffer = InpBufferPoints * point;
      
      string trend = "NEUTRO";
      color trendColor = InpColorNeutral;
      
      if(price > ma + buffer)
      {
         trend = "BULLISH";
         trendColor = InpColorProfit;
      }
      else if(price < ma - buffer)
      {
         trend = "BEARISH";
         trendColor = InpColorLoss;
      }
      
      ObjectSetString(0, PREFIX+"val_trend", OBJPROP_TEXT, trend);
      ObjectSetInteger(0, PREFIX+"val_trend", OBJPROP_COLOR, trendColor);
      
      ObjectSetString(0, PREFIX+"val_trendchange", OBJPROP_TEXT, DoubleToString(ma, 2));
   }
}

//| ATUALIZAR ESTATÍSTICAS DOS GRIDS                                  |
void UpdateGridStats()
{
   // Deals hoje
   int dealsCount = GetTodayDealsCount();
   ObjectSetString(0, PREFIX+"val_deals", OBJPROP_TEXT, IntegerToString(dealsCount));
   
   // Stats por grid (com lógica correta de ciclos)
   GridStats g1, g2, g3, g4, g5;
   GetTodayGridStats(g1, g2, g3, g4, g5);
   
   // G1 - Fechou com 1 posição
   string g1Str = IntegerToString(g1.count) + "x  |  " + (g1.profit >= 0 ? "+" : "") + DoubleToString(g1.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g1", OBJPROP_TEXT, g1Str);
   ObjectSetInteger(0, PREFIX+"val_g1", OBJPROP_COLOR, g1.count == 0 ? clrGray : (g1.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   // G2 - Fechou com 2 posições
   string g2Str = IntegerToString(g2.count) + "x  |  " + (g2.profit >= 0 ? "+" : "") + DoubleToString(g2.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g2", OBJPROP_TEXT, g2Str);
   ObjectSetInteger(0, PREFIX+"val_g2", OBJPROP_COLOR, g2.count == 0 ? clrGray : (g2.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   // G3 - Fechou com 3 posições
   string g3Str = IntegerToString(g3.count) + "x  |  " + (g3.profit >= 0 ? "+" : "") + DoubleToString(g3.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g3", OBJPROP_TEXT, g3Str);
   ObjectSetInteger(0, PREFIX+"val_g3", OBJPROP_COLOR, g3.count == 0 ? clrGray : (g3.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   // G4 - Fechou com 4 posições
   string g4Str = IntegerToString(g4.count) + "x  |  " + (g4.profit >= 0 ? "+" : "") + DoubleToString(g4.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g4", OBJPROP_TEXT, g4Str);
   ObjectSetInteger(0, PREFIX+"val_g4", OBJPROP_COLOR, g4.count == 0 ? clrGray : (g4.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   // G5+ - Fechou com 5+ posições
   string g5Str = IntegerToString(g5.count) + "x  |  " + (g5.profit >= 0 ? "+" : "") + DoubleToString(g5.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g5", OBJPROP_TEXT, g5Str);
   ObjectSetInteger(0, PREFIX+"val_g5", OBJPROP_COLOR, g5.count == 0 ? clrGray : (g5.profit >= 0 ? InpColorProfit : InpColorLoss));
}

//| ATUALIZAR INFO DE POSIÇÕES                                        |
void UpdatePositionsInfo()
{
   int buyCount = 0, sellCount = 0;
   double buyLots = 0, sellLots = 0;
   double buyProfit = 0, sellProfit = 0;
   double buyTotalPrice = 0, sellTotalPrice = 0;
   double lowestBuyPrice = 999999, highestSellPrice = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(!MatchesSymbolFilter(symbol))
            continue;
         
         double lots = PositionGetDouble(POSITION_VOLUME);
         double profit = PositionGetDouble(POSITION_PROFIT);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            buyCount++;
            buyLots += lots;
            buyProfit += profit;
            buyTotalPrice += openPrice * lots;
            if(openPrice < lowestBuyPrice)
               lowestBuyPrice = openPrice;
         }
         else
         {
            sellCount++;
            sellLots += lots;
            sellProfit += profit;
            sellTotalPrice += openPrice * lots;
            if(openPrice > highestSellPrice)
               highestSellPrice = openPrice;
         }
      }
   }
   
   // Calcula pontos
   double avgBuyPrice = buyLots > 0 ? buyTotalPrice / buyLots : 0;
   double avgSellPrice = sellLots > 0 ? sellTotalPrice / sellLots : 0;
   int buyPoints = buyLots > 0 ? (int)((currentPrice - avgBuyPrice) / point) : 0;
   int sellPoints = sellLots > 0 ? (int)((avgSellPrice - currentPrice) / point) : 0;
   
   // BUY: count x lots | P&L | pts
   string buyProfitStr = (buyProfit >= 0 ? "+" : "") + DoubleToString(buyProfit, 0) + "$";
   string buyStr = IntegerToString(buyCount) + "x" + DoubleToString(buyLots, 2) + " | " + buyProfitStr + " | " + IntegerToString(buyPoints) + "p";
   ObjectSetString(0, PREFIX+"val_buy", OBJPROP_TEXT, buyStr);
   ObjectSetInteger(0, PREFIX+"val_buy", OBJPROP_COLOR, buyProfit >= 0 ? InpColorProfit : InpColorLoss);
   
   // SELL: count x lots | P&L | pts
   string sellProfitStr = (sellProfit >= 0 ? "+" : "") + DoubleToString(sellProfit, 0) + "$";
   string sellStr = IntegerToString(sellCount) + "x" + DoubleToString(sellLots, 2) + " | " + sellProfitStr + " | " + IntegerToString(sellPoints) + "p";
   ObjectSetString(0, PREFIX+"val_sell", OBJPROP_TEXT, sellStr);
   ObjectSetInteger(0, PREFIX+"val_sell", OBJPROP_COLOR, sellProfit >= 0 ? InpColorProfit : InpColorLoss);
   
   // Preço Médio
   string avgPriceStr = "---";
   if(buyLots > 0 && sellLots > 0)
      avgPriceStr = "B:" + DoubleToString(avgBuyPrice, 2) + " S:" + DoubleToString(avgSellPrice, 2);
   else if(buyLots > 0)
      avgPriceStr = DoubleToString(avgBuyPrice, 2);
   else if(sellLots > 0)
      avgPriceStr = DoubleToString(avgSellPrice, 2);
   ObjectSetString(0, PREFIX+"val_avgprice", OBJPROP_TEXT, avgPriceStr);
   
   // Próximo Grid BUY (preço onde abre próximo buy)
   double gridDist = InpGridDistance * point;
   string nextBuyStr = "---";
   if(buyCount > 0 && lowestBuyPrice < 999999)
   {
      double nextBuyPrice = lowestBuyPrice - gridDist;
      nextBuyStr = DoubleToString(nextBuyPrice, 2);
   }
   else
   {
      nextBuyStr = "Aguardando";
   }
   ObjectSetString(0, PREFIX+"val_nextbuy", OBJPROP_TEXT, nextBuyStr);
   
   // Próximo Grid SELL (preço onde abre próximo sell)
   string nextSellStr = "---";
   if(sellCount > 0 && highestSellPrice > 0)
   {
      double nextSellPrice = highestSellPrice + gridDist;
      nextSellStr = DoubleToString(nextSellPrice, 2);
   }
   else
   {
      nextSellStr = "Aguardando";
   }
   ObjectSetString(0, PREFIX+"val_nextsell", OBJPROP_TEXT, nextSellStr);
}

//| OBTER NÍVEL DO GRID PELO LOTE (para próximo grid)                 |
int GetGridLevelFromLot(double lots)
{
   if(lots <= 0) return 0;
   
   double tolerance = 0.005;  // Tolerância para comparação
   
   double g1Lot = InpInitialLot;
   double g2Lot = g1Lot * InpLotMultiplier;
   double g3Lot = g2Lot * InpLotMultiplier;
   double g4Lot = g3Lot * InpLotMultiplier;
   double g5Lot = g4Lot * InpLotMultiplier;
   
   if(lots <= g1Lot + tolerance) return 1;
   if(lots <= g2Lot + tolerance) return 2;
   if(lots <= g3Lot + tolerance) return 3;
   if(lots <= g4Lot + tolerance) return 4;
   return 5;
}

//| OBTER FLOATING PNL                                                |
double GetFloatingPnL()
{
   double total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(MatchesSymbolFilter(symbol))
            total += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return total;
}

//| FUNÇÕES DE CRIAÇÃO DE OBJETOS                                     |
void CreateRectangle(string name, int x, int y, int width, int height, color bgColor, color borderColor)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, bool bold, bool alignRight = false)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, alignRight ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreateLine(string name, int x, int y, int width, color clr)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color textColor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//| EVENTO DE CLIQUE EM OBJETO                                        |
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == PREFIX+"btn_pause")
      {
         g_isPaused = !g_isPaused;
         string btnText = g_isPaused ? "CONTINUAR" : "PAUSAR";
         color btnColor = g_isPaused ? C'40,100,40' : C'60,60,80';
         ObjectSetString(0, PREFIX+"btn_pause", OBJPROP_TEXT, btnText);
         ObjectSetInteger(0, PREFIX+"btn_pause", OBJPROP_BGCOLOR, btnColor);
         ObjectSetInteger(0, PREFIX+"btn_pause", OBJPROP_STATE, false);
      }
      else if(sparam == PREFIX+"btn_close")
      {
         if(MessageBox("Fechar TODAS as posições de " + _Symbol + "?", "Confirmação", MB_YESNO | MB_ICONQUESTION) == IDYES)
         {
            CloseAllPositions();
         }
         ObjectSetInteger(0, PREFIX+"btn_close", OBJPROP_STATE, false);
      }
   }
}

//| FECHAR TODAS POSIÇÕES                                             |
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(MatchesSymbolFilter(symbol))
         {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            double lots = PositionGetDouble(POSITION_VOLUME);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            
            request.action = TRADE_ACTION_DEAL;
            request.position = ticket;
            request.symbol = symbol;
            request.volume = lots;
            request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            request.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
            request.deviation = 10;
            
            if(OrderSend(request, result)) { /* ok */ }
         }
      }
   }
}

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

//| WEBHOOK - Envia sinal para servidor                                |
void SendWebhook(string symbol, string action, string orderType, string side,
                 double volume, double price, ulong ticket, double sl, double tp)
{
   if(g_isPaused)
      return;
   
   StringReplace(orderType, " ", "_");
   
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
   
   string headers = "Content-Type: application/json\r\n";
   char postData[];
   char result[];
   string resultHeaders;
   
   StringToCharArray(json, postData, 0, StringLen(json), CP_UTF8);
   
   int timeout = 1000;
   int response = WebRequest("POST", InpWebhookURL, headers, timeout, postData, result, resultHeaders);
   
   if(response == 200)
   {
      ObjectSetString(0, PREFIX+"val_webhook", OBJPROP_TEXT, "CONECTADO");
      ObjectSetInteger(0, PREFIX+"val_webhook", OBJPROP_COLOR, InpColorProfit);
   }
   else
   {
      ObjectSetString(0, PREFIX+"val_webhook", OBJPROP_TEXT, "ERRO " + IntegerToString(response));
      ObjectSetInteger(0, PREFIX+"val_webhook", OBJPROP_COLOR, InpColorLoss);
   }
}

//| SYNC - Envia estado atual de posições e ordens                     |
void SendPositionSync()
{
   if(g_isPaused)
      return;
   
   // Coleta posições abertas
   string positions = "";
   int posCount = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic == 0) magic = (long)ticket;  // Usa ticket como magic se não tiver
      
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      string side = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      
      // Busca o order ticket original que abriu esta posição
      ulong posId = PositionGetInteger(POSITION_IDENTIFIER);
      long originalTicket = FindOriginalOrderTicket(posId);
      if(originalTicket > 0)
         magic = originalTicket;
      
      if(posCount > 0) positions += ",";
      positions += StringFormat("{\"magic\":%I64d,\"side\":\"%s\",\"volume\":%.4f,\"symbol\":\"%s\",\"price\":%.5f}",
                                magic, side, volume, sym, openPrice);
      posCount++;
   }
   
   // Coleta ordens pendentes
   string pending = "";
   int pendCount = 0;
   
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      long magic = OrderGetInteger(ORDER_MAGIC);
      if(magic == 0) magic = (long)ticket;
      
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      string typeName = GetOrderTypeName(orderType);
      string side = (StringFind(typeName, "BUY") >= 0) ? "BUY" : "SELL";
      double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      
      if(pendCount > 0) pending += ",";
      pending += StringFormat("{\"magic\":%I64d,\"type\":\"%s\",\"side\":\"%s\",\"volume\":%.4f,\"price\":%.5f,\"symbol\":\"%s\"}",
                              magic, typeName, side, volume, price, sym);
      pendCount++;
   }
   
   // Monta JSON completo
   string json = StringFormat(
      "{\"type\":\"sync\",\"positions\":[%s],\"pending\":[%s],\"timestamp\":%I64d}",
      positions, pending, (long)TimeCurrent()
   );
   
   // Envia para /sync endpoint
   string syncURL = InpWebhookURL;
   StringReplace(syncURL, "/trade", "/sync");
   
   string headers = "Content-Type: application/json\r\n";
   char postData[];
   char result[];
   string resultHeaders;
   
   StringToCharArray(json, postData, 0, StringLen(json), CP_UTF8);
   
   int timeout = 500;  // Timeout curto para não bloquear
   WebRequest("POST", syncURL, headers, timeout, postData, result, resultHeaders);
}

//| Busca o ORDER ticket original que abriu uma posição               |
long FindOriginalOrderTicket(ulong positionId)
{
   // Busca no histórico o deal de OPEN desta posição
   datetime startTime = 0;
   datetime endTime = TimeCurrent();
   
   if(!HistorySelect(startTime, endTime))
      return 0;
   
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong histDeal = HistoryDealGetTicket(i);
      if(histDeal > 0)
      {
         ulong histPos = HistoryDealGetInteger(histDeal, DEAL_POSITION_ID);
         if(histPos == positionId)
         {
            ENUM_DEAL_ENTRY histEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(histDeal, DEAL_ENTRY);
            if(histEntry == DEAL_ENTRY_IN)
            {
               // Encontrou o deal de abertura - retorna o order ticket
               return HistoryDealGetInteger(histDeal, DEAL_ORDER);
            }
         }
      }
   }
   return 0;
}

//| TradeTransaction function - Detecta trades                         |
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
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
            ulong ticketToSend = dealTicket;  // Default: usa o deal ticket
            
            if(dealEntry == DEAL_ENTRY_IN)
            {
               action = "OPEN";
               side = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
               
               // FIX: Se veio de pending order, usa o ORDER ticket original
               long orderTicket = HistoryDealGetInteger(dealTicket, DEAL_ORDER);
               if(orderTicket > 0)
                  ticketToSend = (ulong)orderTicket;
            }
            else if(dealEntry == DEAL_ENTRY_OUT)
            {
               action = "CLOSE";
               side = (dealType == DEAL_TYPE_BUY) ? "SELL" : "BUY";
               
               // FIX: Busca o ORDER ticket que ABRIU esta posição
               ulong positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
               long originalOrder = FindOriginalOrderTicket(positionId);
               if(originalOrder > 0)
                  ticketToSend = (ulong)originalOrder;
            }
            else if(dealEntry == DEAL_ENTRY_INOUT)
            {
               action = "REVERSE";
               side = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            }
            else
            {
               return;
            }
            
            SendWebhook(symbol, action, "MARKET", side, volume, price, ticketToSend, 0, 0);
         }
      }
   }
   
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      ulong orderTicket = trans.order;
      if(OrderSelect(orderTicket))
      {
         string symbol = OrderGetString(ORDER_SYMBOL);
         if(MatchesSymbolFilter(symbol))
         {
            ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            
            if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_SELL)
               return;
            
            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double price = OrderGetDouble(ORDER_PRICE_OPEN);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);
            
            string orderTypeName = GetOrderTypeName(orderType);
            string side = (StringFind(orderTypeName, "BUY") >= 0) ? "BUY" : "SELL";
            
            if(orderTicket == lastOrderTicket)
               return;
            lastOrderTicket = orderTicket;
            
            SendWebhook(symbol, "NEW", orderTypeName, side, volume, price, orderTicket, sl, tp);
         }
      }
   }
   
   if(trans.type == TRADE_TRANSACTION_ORDER_UPDATE)
   {
      ulong orderTicket = trans.order;
      if(OrderSelect(orderTicket))
      {
         string symbol = OrderGetString(ORDER_SYMBOL);
         if(MatchesSymbolFilter(symbol))
         {
            ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            
            if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_SELL)
               return;
            
            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double price = OrderGetDouble(ORDER_PRICE_OPEN);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);
            
            string orderTypeName = GetOrderTypeName(orderType);
            string side = (StringFind(orderTypeName, "BUY") >= 0) ? "BUY" : "SELL";
            
            SendWebhook(symbol, "MODIFY", orderTypeName, side, volume, price, orderTicket, sl, tp);
         }
      }
   }
   
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      string symbol = trans.symbol;
      if(MatchesSymbolFilter(symbol))
      {
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
