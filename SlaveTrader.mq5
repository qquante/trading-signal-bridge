//+------------------------------------------------------------------+
//|                                                  SlaveTrader.mq5 |
//|                                     CARTEL Sniper Gold System     |
//|                              Copy Trade + Dashboard Profissional   |
//+------------------------------------------------------------------+
#property copyright "CARTEL Trading System"
#property version   "2.20"
#property description "Copy Trade com Dashboard Profissional"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS - Configurações                                            |
//+------------------------------------------------------------------+
input group "=== IDENTIFICAÇÃO ==="
input string   InpAccountName  = "Slave1";                            // Nome desta conta (ex: Yoda, Alice)
input string   InpBroker       = "Default";                           // Nome do Broker

input group "=== SERVIDOR ==="
input string   InpServerIP     = "127.0.0.1";                         // IP do Servidor
input int      InpServerPort   = 9999;                                // Porta TCP
input string   InpSymbolFilter = "XAU";                               // Filtro de Símbolo

input group "=== LOTES ==="
input double   InpMasterLot    = 0.02;                                // Lote Base do Master
input double   InpSlaveLot     = 0.01;                                // Lote Base deste Slave

input group "=== TREND FILTER ==="
input int      InpMAPeriod     = 100;                                 // Período da MA
input ENUM_MA_METHOD InpMAMethod = MODE_SMA;                          // Método da MA
input ENUM_TIMEFRAMES InpMATimeframe = PERIOD_H1;                     // Timeframe da MA
input int      InpBufferPoints = 1000;                                // Buffer (pontos)

input group "=== GRID ==="
input double   InpInitialLot   = 0.01;                                // Lote Inicial (G1)
input double   InpLotMultiplier = 2.0;                                // Multiplicador de Lote
input int      InpGridDistance = 1000;                                // Distância do Grid (pontos)

input group "=== PAINEL ==="
input int      InpPanelX       = 10;                                  // Posição X do Painel
input int      InpPanelY       = 30;                                  // Posição Y do Painel
input color    InpColorBg      = C'20,20,30';                         // Cor de Fundo
input color    InpColorBorder  = C'50,50,70';                         // Cor da Borda
input color    InpColorText    = clrWhite;                            // Cor do Texto
input color    InpColorProfit  = clrLime;                             // Cor de Lucro
input color    InpColorLoss    = clrRed;                              // Cor de Perda
input color    InpColorNeutral = clrGold;                             // Cor Neutra

//+------------------------------------------------------------------+
//| VARIÁVEIS GLOBAIS                                                 |
//+------------------------------------------------------------------+
// Socket
int      g_socket = INVALID_HANDLE;
bool     g_connected = false;
string   g_buffer = "";
datetime g_lastReconnect = 0;

// Trade
CTrade   g_trade;

// Tracking de conta
double   g_accountStartBalance = 0;
double   g_maxEquity = 0;
double   g_maxDrawdown = 0;
double   g_currentDrawdown = 0;

// MA Handle
int      g_maHandle = INVALID_HANDLE;

// Painel
string   PREFIX = "SG_";
int      PANEL_WIDTH = 280;
int      PANEL_HEIGHT = 660;
int      LINE_HEIGHT = 18;

// Estado
bool     g_isPaused = false;
bool     g_identified = false;         // Se já enviou identificação ao servidor
double   g_profitToday = 0;            // Lucro do dia
double   g_balanceStartDay = 0;        // Balance no início do dia
datetime g_currentDay = 0;             // Dia atual para reset do profit

// Fechamentos pendentes (retry a cada 1 seg)
long     g_pendingCloses[];
int      g_pendingClosesCount = 0;

// Estatísticas de Grid
struct GridStats {
   int    count;
   double profit;
};

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Configura trade
   g_trade.SetExpertMagicNumber(123457);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Inicializa MA
   g_maHandle = iMA(_Symbol, InpMATimeframe, InpMAPeriod, 0, InpMAMethod, PRICE_CLOSE);
   
   // Busca balance inicial
   g_accountStartBalance = GetAccountStartBalance();
   
   // Inicializa tracking
   g_maxEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Cria painel
   CreatePanel();
   
   // Conecta ao servidor
   ConnectToServer();
   
   // Timer
   EventSetMillisecondTimer(10);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PREFIX);
   
   if(g_maHandle != INVALID_HANDLE)
      IndicatorRelease(g_maHandle);
   
   EventKillTimer();
   DisconnectFromServer();
   Comment("");
}

//+------------------------------------------------------------------+
//| Timer                                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Conexão TCP - usa GetTickCount64 (sempre atualiza, mesmo sem ticks)
   static ulong lastReconnectAttempt = 0;
   
   if(!g_connected)
   {
      if(GetTickCount64() - lastReconnectAttempt > 1000)  // 3 segundos
      {
         Print("🔄 Tentando reconectar ao servidor...");
         ConnectToServer();
         lastReconnectAttempt = GetTickCount64();
         
         if(g_connected)
            Print("✅ Conectado ao servidor!");
      }
   }
   else
   {
      ReadSocketData();
   }
   
   // Atualiza painel (a cada ~500ms)
   static ulong lastUpdate = 0;
   if(GetTickCount64() - lastUpdate > 500)
   {
      UpdatePanel();
      lastUpdate = GetTickCount64();
   }
   
   // Limpa locks antigos (a cada 5 minutos)
   static ulong lastCleanup = 0;
   if(GetTickCount64() - lastCleanup > 300000)
   {
      CleanupOldLocks();
      lastCleanup = GetTickCount64();
   }
   
   // Retry fechamentos pendentes (a cada 1 segundo)
   static ulong lastCloseRetry = 0;
   if(GetTickCount64() - lastCloseRetry > 1000)
   {
      ProcessPendingCloses();
      lastCloseRetry = GetTickCount64();
   }
   
   // Envia status ao servidor (a cada 5 segundos)
   static ulong lastStatusReport = 0;
   if(g_connected && g_identified && GetTickCount64() - lastStatusReport > 5000)
   {
      SendStatusReport();
      lastStatusReport = GetTickCount64();
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > g_maxEquity)
      g_maxEquity = equity;
   
   if(g_maxEquity > 0)
      g_currentDrawdown = (g_maxEquity - equity) / g_maxEquity * 100;
   
   if(g_currentDrawdown > g_maxDrawdown)
      g_maxDrawdown = g_currentDrawdown;
}

//+------------------------------------------------------------------+
//| CONECTAR AO SERVIDOR                                              |
//+------------------------------------------------------------------+
void ConnectToServer()
{
   if(g_connected) return;
   
   g_socket = SocketCreate();
   if(g_socket == INVALID_HANDLE) return;
   
   if(!SocketConnect(g_socket, InpServerIP, InpServerPort, 1000))
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
      return;
   }
   
   g_connected = true;
   g_buffer = "";
   g_identified = false;
   
   // Envia identificação imediatamente
   SendIdentification();
}

//+------------------------------------------------------------------+
//| ENVIAR IDENTIFICAÇÃO AO SERVIDOR                                  |
//+------------------------------------------------------------------+
void SendIdentification()
{
   if(!g_connected || g_socket == INVALID_HANDLE) return;
   
   long accountNumber = AccountInfoInteger(ACCOUNT_LOGIN);
   
   string json = "{\"type\":\"identify\","
                 "\"name\":\"" + InpAccountName + "\","
                 "\"account\":" + IntegerToString(accountNumber) + ","
                 "\"broker\":\"" + InpBroker + "\"}\n";
   
   uchar data[];
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);  // Remove null terminator
   
   if(SocketSend(g_socket, data, ArraySize(data)) > 0)
   {
      g_identified = true;
      Print("📤 Identificação enviada: ", InpAccountName, " (Conta: ", accountNumber, ")");
   }
}

//+------------------------------------------------------------------+
//| ENVIAR STATUS PERIÓDICO AO SERVIDOR                               |
//+------------------------------------------------------------------+
void SendStatusReport()
{
   if(!g_connected || !g_identified || g_socket == INVALID_HANDLE) return;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int positions = CountMyPositions();
   
   // Calcula lucro do dia
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(g_currentDay != today)
   {
      g_currentDay = today;
      g_balanceStartDay = balance;
      g_profitToday = 0;
   }
   else
   {
      g_profitToday = balance - g_balanceStartDay;
   }
   
   string json = "{\"type\":\"status\","
                 "\"name\":\"" + InpAccountName + "\","
                 "\"equity\":" + DoubleToString(equity, 2) + ","
                 "\"balance\":" + DoubleToString(balance, 2) + ","
                 "\"positions\":" + IntegerToString(positions) + ","
                 "\"profit_today\":" + DoubleToString(g_profitToday, 2) + "}\n";
   
   uchar data[];
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);
   
   SocketSend(g_socket, data, ArraySize(data));
}

//+------------------------------------------------------------------+
//| ENVIAR CONFIRMAÇÃO DE TRADE                                       |
//+------------------------------------------------------------------+
void SendTradeConfirmation(string uuid, bool success, long slaveTicket, string errorMsg = "", double profit = 0)
{
   if(!g_connected || !g_identified || g_socket == INVALID_HANDLE) return;
   
   string json = "{\"type\":\"confirm\","
                 "\"name\":\"" + InpAccountName + "\","
                 "\"uuid\":\"" + uuid + "\","
                 "\"success\":" + (success ? "true" : "false") + ","
                 "\"ticket\":" + IntegerToString(slaveTicket) + ","
                 "\"error\":\"" + errorMsg + "\","
                 "\"profit\":" + DoubleToString(profit, 2) + "}\n";
   
   uchar data[];
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(data, ArraySize(data) - 1);
   
   if(SocketSend(g_socket, data, ArraySize(data)) > 0)
      Print("📤 Confirmação enviada: UUID=", uuid, " Success=", success);
}

//+------------------------------------------------------------------+
//| CONTA POSIÇÕES ABERTAS                                            |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         string sym = PositionGetString(POSITION_SYMBOL);
         if(MatchesSymbolFilter(sym))
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| DESCONECTAR                                                       |
//+------------------------------------------------------------------+
void DisconnectFromServer()
{
   if(g_socket != INVALID_HANDLE)
   {
      SocketClose(g_socket);
      g_socket = INVALID_HANDLE;
   }
   
   if(g_connected)
      Print("⚠️ Conexão perdida - reconectando em 3s...");
   
   g_connected = false;
}

//+------------------------------------------------------------------+
//| LER DADOS DO SOCKET                                               |
//+------------------------------------------------------------------+
void ReadSocketData()
{
   if(!g_connected || g_socket == INVALID_HANDLE) return;
   
   uint available = SocketIsReadable(g_socket);
   if(available == 0) return;
   
   uchar data[];
   ArrayResize(data, available);
   
   int received = SocketRead(g_socket, data, available, 1);
   if(received <= 0)
   {
      DisconnectFromServer();
      return;
   }
   
   g_buffer += CharArrayToString(data, 0, received, CP_UTF8);
   
   int pos;
   while((pos = StringFind(g_buffer, "\n")) >= 0)
   {
      string line = StringSubstr(g_buffer, 0, pos);
      g_buffer = StringSubstr(g_buffer, pos + 1);
      
      if(StringLen(line) > 0)
         ProcessMessage(line);
   }
}

//+------------------------------------------------------------------+
//| PROCESSAR MENSAGEM                                                |
//+------------------------------------------------------------------+
void ProcessMessage(string json)
{
   string type = GetJsonString(json, "type");
   
   if(type == "ping")
      return;
   
   if(type == "identified")
   {
      g_identified = true;
      Print("✅ Servidor confirmou identificação: ", InpAccountName);
      return;
   }
   
   if(type == "sync")
   {
      ProcessSyncMessage(json);
      return;
   }
   
   if(type == "trade")
      ProcessTradeSignal(json);
}

//+------------------------------------------------------------------+
//| PROCESSAR SYNC - Sincroniza posições com o Master                 |
//+------------------------------------------------------------------+
void ProcessSyncMessage(string json)
{
   // Arrays para armazenar posições do master
   long masterMagics[];
   string masterSides[];
   double masterVolumes[];
   int masterCount = 0;
   
   // Parse das posições do master do JSON
   // Formato: "positions":[{"magic":123,"side":"BUY","volume":0.01},...]
   string positionsStr = ExtractJsonArray(json, "positions");
   ParseMasterPositions(positionsStr, masterMagics, masterSides, masterVolumes, masterCount);
   
   // ═══════════════════════════════════════════════════════════════════
   // PASSO 1: FECHAR ÓRFÃS E DUPLICADAS
   // ═══════════════════════════════════════════════════════════════════
   
   // Array para rastrear quais magics já vimos (para detectar duplicatas)
   long seenMagics[];
   int seenCount = 0;
   ArrayResize(seenMagics, 100);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      long localMagic = PositionGetInteger(POSITION_MAGIC);
      
      // Verifica se este magic existe no master
      bool existsInMaster = false;
      for(int m = 0; m < masterCount; m++)
      {
         if(masterMagics[m] == localMagic)
         {
            existsInMaster = true;
            break;
         }
      }
      
      // Se não existe no master → ÓRFÃ, fechar imediatamente
      if(!existsInMaster)
      {
         Print("🗑️ SYNC: Fechando posição ÓRFÃ magic=", localMagic, " ticket=", ticket);
         g_trade.PositionClose(ticket);
         continue;
      }
      
      // Verifica se já vimos este magic (significa que é duplicata)
      bool isDuplicate = false;
      for(int s = 0; s < seenCount; s++)
      {
         if(seenMagics[s] == localMagic)
         {
            isDuplicate = true;
            break;
         }
      }
      
      if(isDuplicate)
      {
         // Já vimos este magic antes → esta é uma duplicata, fechar
         Print("🗑️ SYNC: Fechando posição DUPLICADA magic=", localMagic, " ticket=", ticket);
         g_trade.PositionClose(ticket);
      }
      else
      {
         // Primeira vez que vemos este magic → marcar como visto (manter esta posição)
         seenMagics[seenCount] = localMagic;
         seenCount++;
      }
   }
   
   // ═══════════════════════════════════════════════════════════════════
   // PASSO 2: ABRIR POSIÇÕES FALTANTES
   // ═══════════════════════════════════════════════════════════════════
   
   for(int m = 0; m < masterCount; m++)
   {
      long magic = masterMagics[m];
      string side = masterSides[m];
      double volume = masterVolumes[m];
      
      // Verifica se já existe posição local com este magic (versão silenciosa)
      if(HasPositionWithMagicSilent(magic))
         continue;
      
      // Não existe → ABRIR
      // Calcula volume proporcional
      double ratio = InpSlaveLot / InpMasterLot;
      double slaveVolume = NormalizeDouble(volume * ratio, 2);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      
      if(slaveVolume < minLot) slaveVolume = minLot;
      if(slaveVolume > maxLot) slaveVolume = maxLot;
      slaveVolume = MathFloor(slaveVolume / lotStep) * lotStep;
      
      g_trade.SetExpertMagicNumber((ulong)magic);
      
      Print("📈 SYNC: Abrindo posição FALTANTE magic=", magic, " ", side, " ", slaveVolume, " lots");
      
      if(side == "BUY")
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         g_trade.Buy(slaveVolume, _Symbol, ask, 0, 0, "SYNC");
      }
      else if(side == "SELL")
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         g_trade.Sell(slaveVolume, _Symbol, bid, 0, 0, "SYNC");
      }
   }
}

//+------------------------------------------------------------------+
//| CONTA POSIÇÕES COM DETERMINADO MAGIC                              |
//+------------------------------------------------------------------+
int CountPositionsWithMagic(long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| VERIFICA SE EXISTE POSIÇÃO COM MAGIC (versão silenciosa)          |
//+------------------------------------------------------------------+
bool HasPositionWithMagicSilent(long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| EXTRAI ARRAY JSON (retorna conteúdo entre [ ])                    |
//+------------------------------------------------------------------+
string ExtractJsonArray(string json, string key)
{
   string search = "\"" + key + "\":[";
   int start = StringFind(json, search);
   if(start < 0) return "";
   
   start += StringLen(search);
   int brackets = 1;
   int end = start;
   
   while(brackets > 0 && end < StringLen(json))
   {
      string c = StringSubstr(json, end, 1);
      if(c == "[") brackets++;
      if(c == "]") brackets--;
      end++;
   }
   
   return StringSubstr(json, start, end - start - 1);
}

//+------------------------------------------------------------------+
//| PARSE DAS POSIÇÕES DO MASTER                                      |
//+------------------------------------------------------------------+
void ParseMasterPositions(string positionsJson, long &magics[], string &sides[], 
                          double &volumes[], int &count)
{
   count = 0;
   if(StringLen(positionsJson) < 3) return;
   
   // Formato: {"magic":123,"side":"BUY","volume":0.01},{"magic":456,...}
   
   int maxPositions = 100;
   ArrayResize(magics, maxPositions);
   ArrayResize(sides, maxPositions);
   ArrayResize(volumes, maxPositions);
   
   int pos = 0;
   while(pos < StringLen(positionsJson) && count < maxPositions)
   {
      // Encontra próximo objeto
      int objStart = StringFind(positionsJson, "{", pos);
      if(objStart < 0) break;
      
      int objEnd = StringFind(positionsJson, "}", objStart);
      if(objEnd < 0) break;
      
      string obj = StringSubstr(positionsJson, objStart, objEnd - objStart + 1);
      
      // Extrai magic
      long magic = GetJsonLong(obj, "magic");
      string side = GetJsonString(obj, "side");
      double volume = GetJsonDouble(obj, "volume");
      
      if(magic > 0)
      {
         magics[count] = magic;
         sides[count] = side;
         volumes[count] = volume;
         count++;
      }
      
      pos = objEnd + 1;
   }
   
   // Redimensiona para tamanho real
   ArrayResize(magics, count);
   ArrayResize(sides, count);
   ArrayResize(volumes, count);
}

//+------------------------------------------------------------------+
//| LOCK ATÔMICO - Previne duplicação de ordens                       |
//+------------------------------------------------------------------+
bool TryProcessTicket(long ticket, string action)
{
   // Nome único para este ticket+action
   string lockName = "CT_" + action + "_" + IntegerToString(ticket);
   
   // Cria variável se não existe (valor inicial = 0 = livre)
   if(!GlobalVariableCheck(lockName))
      GlobalVariableSet(lockName, 0);
   
   // ATÔMICO: tenta setar de 0 para 1
   // TRUE = conseguiu lock (primeira execução)
   // FALSE = já bloqueado (duplicata)
   return GlobalVariableSetOnCondition(lockName, 1, 0);
}

//+------------------------------------------------------------------+
//| LIMPA LOCKS ANTIGOS - Evita acumular lixo                         |
//+------------------------------------------------------------------+
void CleanupOldLocks()
{
   int total = GlobalVariablesTotal();
   datetime expireTime = TimeCurrent() - 3600;  // 1 hora
   
   for(int i = total - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, "CT_") == 0)  // Só nossas variáveis
      {
         datetime varTime = GlobalVariableTime(name);
         if(varTime < expireTime)
            GlobalVariableDel(name);
      }
   }
}

//+------------------------------------------------------------------+
//| PROCESSAR SINAL DE TRADE                                          |
//+------------------------------------------------------------------+
void ProcessTradeSignal(string json)
{
   string symbol = GetJsonString(json, "symbol");
   string action = GetJsonString(json, "action");
   string orderType = GetJsonString(json, "order_type");
   string side = GetJsonString(json, "side");
   double volume = GetJsonDouble(json, "volume");
   double price = GetJsonDouble(json, "price");
   long masterTicket = GetJsonLong(json, "ticket");
   string signalUuid = GetJsonString(json, "uuid");  // UUID do servidor
   
   Print("═══════════════════════════════════════════════════════════");
   Print("📨 SINAL [", signalUuid, "]: ", action, " ", side, " | Magic: ", masterTicket);
   Print("   Volume: ", volume, " | Price: ", price, " | Type: ", orderType);
   
   if(g_isPaused) 
   { 
      Print("⏸️ PAUSADO - ignorando"); 
      SendTradeConfirmation(signalUuid, false, 0, "EA pausado");
      return; 
   }
   if(!MatchesSymbolFilter(symbol)) 
   { 
      Print("🚫 Símbolo filtrado"); 
      SendTradeConfirmation(signalUuid, false, 0, "Simbolo filtrado");
      return; 
   }
   
   // ══════════════════════════════════════════════════════════════════
   // LOCK ATÔMICO - Se FALSE, significa que já está processando/processado
   // ══════════════════════════════════════════════════════════════════
   if(!TryProcessTicket(masterTicket, action))
   {
      Print("⏭️ IGNORADO - Ticket ", masterTicket, " já processado para ", action);
      Print("═══════════════════════════════════════════════════════════");
      SendTradeConfirmation(signalUuid, true, 0, "Ja processado anteriormente");
      return;
   }
   Print("🔒 Lock obtido para ticket ", masterTicket);
   
   // Calcula volume proporcional
   double ratio = InpSlaveLot / InpMasterLot;
   double slaveVolume = NormalizeDouble(volume * ratio, 2);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(slaveVolume < minLot) slaveVolume = minLot;
   if(slaveVolume > maxLot) slaveVolume = maxLot;
   slaveVolume = MathFloor(slaveVolume / lotStep) * lotStep;
   
   Print("   SlaveVolume: ", slaveVolume, " (ratio: ", ratio, ")");
   
   bool success = false;
   long slaveTicket = 0;
   string errorMsg = "";
   
   // === OPEN: Execução a mercado ===
   if(action == "OPEN")
   {
      bool hasPos = HasPositionWithMagic(masterTicket);
      Print("   HasPositionWithMagic(", masterTicket, ") = ", hasPos);
      
      if(hasPos)
      {
         Print("✅ IGNORADO - Posição já existe (pending disparou)");
         SendTradeConfirmation(signalUuid, true, 0, "Posicao ja existe");
         Print("═══════════════════════════════════════════════════════════");
         return;
      }
      
      // Cancela pending órfão se existir
      CancelPendingByMagic(masterTicket);
      
      g_trade.SetExpertMagicNumber((ulong)masterTicket);
      if(side == "BUY")
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         Print("🟢 EXECUTANDO BUY ", slaveVolume, " @ ", ask, " magic=", masterTicket);
         success = g_trade.Buy(slaveVolume, _Symbol, ask, 0, 0, "");
         slaveTicket = (long)g_trade.ResultOrder();
         Print("   Resultado: ", success ? "OK" : "FALHOU", " Code: ", g_trade.ResultRetcode(), " Ticket: ", slaveTicket);
         if(!success) errorMsg = "Buy falhou: " + IntegerToString(g_trade.ResultRetcode());
      }
      else if(side == "SELL")
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         Print("🔴 EXECUTANDO SELL ", slaveVolume, " @ ", bid, " magic=", masterTicket);
         success = g_trade.Sell(slaveVolume, _Symbol, bid, 0, 0, "");
         slaveTicket = (long)g_trade.ResultOrder();
         Print("   Resultado: ", success ? "OK" : "FALHOU", " Code: ", g_trade.ResultRetcode(), " Ticket: ", slaveTicket);
         if(!success) errorMsg = "Sell falhou: " + IntegerToString(g_trade.ResultRetcode());
      }
   }
   // === CLOSE: Fecha posições ===
   else if(action == "CLOSE")
   {
      Print("🔒 FECHANDO posição magic=", masterTicket);
      ClosePositionByMagic(masterTicket);
      success = true;  // Close é adicionado à fila de retry
   }
   // === NEW: Cria ordem pendente ===
   else if(action == "NEW")
   {
      bool hasPending = HasPendingWithMagic(masterTicket);
      bool hasPos = HasPositionWithMagic(masterTicket);
      Print("   HasPendingWithMagic(", masterTicket, ") = ", hasPending);
      Print("   HasPositionWithMagic(", masterTicket, ") = ", hasPos);
      
      if(hasPending)
      {
         Print("⏭️ IGNORADO - Pending já existe");
         SendTradeConfirmation(signalUuid, true, 0, "Pending ja existe");
         Print("═══════════════════════════════════════════════════════════");
         return;
      }
      if(hasPos)
      {
         Print("⏭️ IGNORADO - Posição já existe");
         SendTradeConfirmation(signalUuid, true, 0, "Posicao ja existe");
         Print("═══════════════════════════════════════════════════════════");
         return;
      }
      
      g_trade.SetExpertMagicNumber((ulong)masterTicket);
      Print("📝 CRIANDO PENDING ", orderType, " @ ", price, " magic=", masterTicket);
      
      if(orderType == "BUY_STOP")
         success = g_trade.BuyStop(slaveVolume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "");
      else if(orderType == "SELL_STOP")
         success = g_trade.SellStop(slaveVolume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "");
      else if(orderType == "BUY_LIMIT")
         success = g_trade.BuyLimit(slaveVolume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "");
      else if(orderType == "SELL_LIMIT")
         success = g_trade.SellLimit(slaveVolume, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "");
      
      slaveTicket = (long)g_trade.ResultOrder();
      Print("   Resultado: ", success ? "OK" : "FALHOU", " Code: ", g_trade.ResultRetcode(), " Ticket: ", slaveTicket);
      if(!success) errorMsg = "Pending falhou: " + IntegerToString(g_trade.ResultRetcode());
   }
   // === CANCEL: Cancela pendentes ===
   else if(action == "CANCEL")
   {
      Print("🗑️ CANCELANDO pending magic=", masterTicket);
      CancelPendingByMagic(masterTicket);
      success = true;
   }
   // === MODIFY: Modifica ordem pendente ===
   else if(action == "MODIFY")
   {
      Print("✏️ MODIFICANDO pending magic=", masterTicket, " → ", price);
      success = ModifyPendingByMagic(masterTicket, price);
      if(!success) errorMsg = "Modify falhou";
   }
   
   // Envia confirmação ao servidor
   SendTradeConfirmation(signalUuid, success, slaveTicket, errorMsg);
   
   Print("═══════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| FECHAR POSIÇÕES                                                   |
//+------------------------------------------------------------------+
void ClosePositions(string side)
{
   for(int attempt = 0; attempt < 3; attempt++)
   {
      bool allClosed = true;
      
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket == 0) continue;
         if(!PositionSelectByTicket(posTicket)) continue;
         
         string symbol = PositionGetString(POSITION_SYMBOL);
         if(!MatchesSymbolFilter(symbol)) continue;
         
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         bool shouldClose = false;
         
         if(side == "BUY" && type == POSITION_TYPE_BUY) shouldClose = true;
         else if(side == "SELL" && type == POSITION_TYPE_SELL) shouldClose = true;
         else if(side == "" || side == "ALL") shouldClose = true;
         
         if(shouldClose)
         {
            if(!g_trade.PositionClose(posTicket))
               allClosed = false;
         }
      }
      
      if(allClosed) break;
      Sleep(50);
   }
}

//+------------------------------------------------------------------+
//| VERIFICA SE EXISTE POSIÇÃO COM MAGIC (atômico)                    |
//+------------------------------------------------------------------+
bool HasPositionWithMagic(long magic)
{
   Print("   🔍 Buscando posição magic=", magic, " (Total: ", PositionsTotal(), ")");
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      
      Print("      Pos[", i, "]: ", sym, " magic=", posMagic, " ticket=", ticket);
      
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(posMagic == magic)
      {
         Print("      ✅ ENCONTRADO!");
         return true;
      }
   }
   Print("      ❌ Não encontrado");
   return false;
}

//+------------------------------------------------------------------+
//| VERIFICA SE EXISTE PENDING COM MAGIC                              |
//+------------------------------------------------------------------+
bool HasPendingWithMagic(long magic)
{
   Print("   🔍 Buscando pending magic=", magic, " (Total: ", OrdersTotal(), ")");
   
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      long ordMagic = OrderGetInteger(ORDER_MAGIC);
      
      Print("      Ord[", i, "]: ", sym, " magic=", ordMagic, " ticket=", ticket);
      
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(ordMagic == magic)
      {
         Print("      ✅ ENCONTRADO!");
         return true;
      }
   }
   Print("      ❌ Não encontrado");
   return false;
}

//+------------------------------------------------------------------+
//| MODIFICA PENDING POR MAGIC                                        |
//+------------------------------------------------------------------+
bool ModifyPendingByMagic(long magic, double price)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(OrderGetInteger(ORDER_MAGIC) == magic)
      {
         double currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         if(MathAbs(currentPrice - price) > 0.01)
            return g_trade.OrderModify(ticket, price, 0, 0, ORDER_TIME_GTC, 0);
         return true;  // Já está no preço correto
      }
   }
   return false;  // Não encontrou a ordem
}

//+------------------------------------------------------------------+
//| CANCELA PENDING POR MAGIC                                         |
//+------------------------------------------------------------------+
void CancelPendingByMagic(long magic)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(OrderGetInteger(ORDER_MAGIC) == magic)
      {
         g_trade.OrderDelete(ticket);
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| FECHA POSIÇÃO POR MAGIC                                           |
//+------------------------------------------------------------------+
void ClosePositionByMagic(long magic)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == magic)
      {
         if(g_trade.PositionClose(ticket))
            closed++;
      }
   }
   
   // Adiciona à fila de retry se não fechou ou para garantir
   AddPendingClose(magic);
   Print("📋 Magic ", magic, " adicionado à fila de retry (fechou ", closed, " posições)");
}

//+------------------------------------------------------------------+
//| ADICIONA MAGIC À FILA DE FECHAMENTO PENDENTE                      |
//+------------------------------------------------------------------+
void AddPendingClose(long magic)
{
   // Verifica se já está na fila
   for(int i = 0; i < g_pendingClosesCount; i++)
   {
      if(g_pendingCloses[i] == magic)
         return;  // Já está na fila
   }
   
   // Adiciona à fila
   g_pendingClosesCount++;
   ArrayResize(g_pendingCloses, g_pendingClosesCount);
   g_pendingCloses[g_pendingClosesCount - 1] = magic;
}

//+------------------------------------------------------------------+
//| REMOVE MAGIC DA FILA DE FECHAMENTO PENDENTE                       |
//+------------------------------------------------------------------+
void RemovePendingClose(long magic)
{
   for(int i = 0; i < g_pendingClosesCount; i++)
   {
      if(g_pendingCloses[i] == magic)
      {
         // Move últimos elementos para preencher o gap
         for(int j = i; j < g_pendingClosesCount - 1; j++)
            g_pendingCloses[j] = g_pendingCloses[j + 1];
         
         g_pendingClosesCount--;
         ArrayResize(g_pendingCloses, g_pendingClosesCount);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| VERIFICA SE EXISTE POSIÇÃO COM MAGIC                              |
//+------------------------------------------------------------------+
bool HasPositionWithMagicNumber(long magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!MatchesSymbolFilter(sym)) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| PROCESSA FECHAMENTOS PENDENTES (chamado a cada 1 seg)             |
//+------------------------------------------------------------------+
void ProcessPendingCloses()
{
   if(g_pendingClosesCount == 0) return;
   
   // Itera de trás pra frente para poder remover
   for(int i = g_pendingClosesCount - 1; i >= 0; i--)
   {
      long magic = g_pendingCloses[i];
      
      // Verifica se ainda existe posição com esse magic
      if(!HasPositionWithMagicNumber(magic))
      {
         Print("✅ Magic ", magic, " fechado com sucesso - removido da fila");
         RemovePendingClose(magic);
         continue;
      }
      
      // Ainda existe - tenta fechar novamente
      Print("🔄 Retry: Tentando fechar posições magic=", magic);
      int closed = 0;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         ulong ticket = PositionGetTicket(j);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;
         
         string sym = PositionGetString(POSITION_SYMBOL);
         if(!MatchesSymbolFilter(sym)) continue;
         
         if(PositionGetInteger(POSITION_MAGIC) == magic)
         {
            if(g_trade.PositionClose(ticket))
               closed++;
         }
      }
      Print("🔄 Retry fechou ", closed, " posições para magic=", magic);
   }
}

//+------------------------------------------------------------------+
//| FECHAR TODAS AS POSIÇÕES                                          |
//+------------------------------------------------------------------+
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
            g_trade.PositionClose(ticket);
         }
      }
   }
}


//+------------------------------------------------------------------+
//| VERIFICA FILTRO DE SÍMBOLO                                        |
//+------------------------------------------------------------------+
bool MatchesSymbolFilter(string symbol)
{
   if(InpSymbolFilter == "") return true;
   
   string symbolLower = symbol;
   string filterLower = InpSymbolFilter;
   StringToLower(symbolLower);
   StringToLower(filterLower);
   
   return (StringFind(symbolLower, filterLower) >= 0);
}

//+------------------------------------------------------------------+
//| OBTER BALANCE INICIAL DA CONTA                                    |
//+------------------------------------------------------------------+
double GetAccountStartBalance()
{
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
            if(profit > 0)
            {
               firstDeposit = profit;
               break;
            }
         }
      }
   }
   
   return firstDeposit > 0 ? firstDeposit : AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
//| OBTER LUCRO REALIZADO HOJE                                        |
//+------------------------------------------------------------------+
double GetTodayRealizedProfit()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime now = TimeCurrent();
   
   if(!HistorySelect(todayStart, now)) return 0;
   
   double profit = 0;
   int total = HistoryDealsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(!MatchesSymbolFilter(symbol)) continue;
         
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
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

//+------------------------------------------------------------------+
//| OBTER LUCRO TOTAL DA CONTA                                        |
//+------------------------------------------------------------------+
double GetTotalAccountProfit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double floating = GetFloatingPnL();
   double totalEquity = currentBalance + floating;
   double deposits = GetTotalDeposits();
   
   return totalEquity - deposits;
}

//+------------------------------------------------------------------+
//| OBTER TOTAL DE DEPÓSITOS                                          |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| CONTAR DEALS DE HOJE                                              |
//+------------------------------------------------------------------+
int GetTodayDealsCount()
{
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime now = TimeCurrent();
   
   if(!HistorySelect(todayStart, now)) return 0;
   
   int count = 0;
   int total = HistoryDealsTotal();
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(!MatchesSymbolFilter(symbol)) continue;
         
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
         if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            count++;
      }
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| OBTER ESTATÍSTICAS DOS GRIDS HOJE                                 |
//+------------------------------------------------------------------+
void GetTodayGridStats(GridStats &g1, GridStats &g2, GridStats &g3, GridStats &g4, GridStats &g5)
{
   g1.count = 0; g1.profit = 0;
   g2.count = 0; g2.profit = 0;
   g3.count = 0; g3.profit = 0;
   g4.count = 0; g4.profit = 0;
   g5.count = 0; g5.profit = 0;
   
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime now = TimeCurrent();
   
   if(!HistorySelect(todayStart, now)) return;
   
   int total = HistoryDealsTotal();
   
   datetime closeTimes[];
   double closeProfits[];
   int closeCount = 0;
   
   ArrayResize(closeTimes, total);
   ArrayResize(closeProfits, total);
   
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
         if(!MatchesSymbolFilter(symbol)) continue;
         
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
         
         datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += HistoryDealGetDouble(ticket, DEAL_SWAP);
         profit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         
         closeTimes[closeCount] = dealTime;
         closeProfits[closeCount] = profit;
         closeCount++;
      }
   }
   
   if(closeCount == 0) return;
   
   int timeWindow = 10;
   int i = 0;
   
   while(i < closeCount)
   {
      datetime cycleStart = closeTimes[i];
      int cyclePositions = 0;
      double cycleProfit = 0;
      
      while(i < closeCount && (closeTimes[i] - cycleStart) <= timeWindow)
      {
         cyclePositions++;
         cycleProfit += closeProfits[i];
         i++;
      }
      
      switch(cyclePositions)
      {
         case 1:  g1.count++; g1.profit += cycleProfit; break;
         case 2:  g2.count++; g2.profit += cycleProfit; break;
         case 3:  g3.count++; g3.profit += cycleProfit; break;
         case 4:  g4.count++; g4.profit += cycleProfit; break;
         default: g5.count++; g5.profit += cycleProfit; break;
      }
   }
}

//+------------------------------------------------------------------+
//| OBTER FLOATING PNL                                                |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| CRIAR PAINEL - IDÊNTICO AO SNIPERGOLD                             |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = InpPanelX;
   int y = InpPanelY;
   
   // Fundo principal
   CreateRectangle(PREFIX+"bg", x, y, PANEL_WIDTH, PANEL_HEIGHT, InpColorBg, InpColorBorder);
   
   // Header
   CreateRectangle(PREFIX+"header", x, y, PANEL_WIDTH, 28, C'30,30,45', InpColorBorder);
   CreateLabel(PREFIX+"title", x+10, y+6, "CARTEL SNIPER GOLD YODA", InpColorNeutral, 11, true);
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
   CreateLabel(PREFIX+"sec_grids", x+10, y, "═══ CICLOS GRID ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_deals", x+10, y, "Ordens Hoje", clrGray, 9, false);
   CreateLabel(PREFIX+"val_deals", x+PANEL_WIDTH-10, y, "0", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_g1", x+10, y, "G1 (1 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g1", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_g2", x+10, y, "G2 (2 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g2", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_g3", x+10, y, "G3 (3 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g3", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_g4", x+10, y, "G4 (4 pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g4", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_g5", x+10, y, "G5+(5+ pos)", clrGray, 9, false);
   CreateLabel(PREFIX+"val_g5", x+PANEL_WIDTH-10, y, "0x  |  $0.00", InpColorText, 9, false, true);
   
   y += LINE_HEIGHT + 3;
   CreateLine(PREFIX+"line5", x+5, y, PANEL_WIDTH-10, InpColorBorder);
   y += 6;
   
   // === SEÇÃO: POSIÇÕES ABERTAS ===
   CreateLabel(PREFIX+"sec_pos", x+10, y, "═══ POSIÇÕES ═══", clrDimGray, 8, false);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_buy", x+10, y, "BUY", InpColorProfit, 9, true);
   CreateLabel(PREFIX+"val_buy", x+PANEL_WIDTH-10, y, "0 x 0.00 | $0.00 | 0p", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_sell", x+10, y, "SELL", InpColorLoss, 9, true);
   CreateLabel(PREFIX+"val_sell", x+PANEL_WIDTH-10, y, "0 x 0.00 | $0.00 | 0p", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_avgprice", x+10, y, "Preço Médio", clrGray, 9, false);
   CreateLabel(PREFIX+"val_avgprice", x+PANEL_WIDTH-10, y, "---", InpColorText, 9, false, true);
   y += LINE_HEIGHT;
   
   CreateLabel(PREFIX+"lbl_nextbuy", x+10, y, "Próx Grid B", clrGray, 9, false);
   CreateLabel(PREFIX+"val_nextbuy", x+PANEL_WIDTH-10, y, "---", InpColorProfit, 9, false, true);
   y += LINE_HEIGHT;
   
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

//+------------------------------------------------------------------+
//| ATUALIZAR PAINEL                                                   |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   // Status
   string status = g_isPaused ? "PAUSADO" : "ATIVO";
   color statusColor = g_isPaused ? InpColorNeutral : InpColorProfit;
   ObjectSetString(0, PREFIX+"val_status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, PREFIX+"val_status", OBJPROP_COLOR, statusColor);
   
   // Webhook (na verdade é conexão TCP)
   string webhookStatus = g_connected ? "CONECTADO" : "ERRO";
   color webhookColor = g_connected ? InpColorProfit : InpColorLoss;
   ObjectSetString(0, PREFIX+"val_webhook", OBJPROP_TEXT, webhookStatus);
   ObjectSetInteger(0, PREFIX+"val_webhook", OBJPROP_COLOR, webhookColor);
   
   // === CONTA ===
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   ObjectSetString(0, PREFIX+"val_balance", OBJPROP_TEXT, DoubleToString(balance, 2) + " $");
   ObjectSetString(0, PREFIX+"val_equity", OBJPROP_TEXT, DoubleToString(equity, 2) + " $");
   ObjectSetString(0, PREFIX+"val_margin", OBJPROP_TEXT, DoubleToString(margin, 2) + " $");
   
   // === LUCROS ===
   double dailyReal = GetTodayRealizedProfit();
   string dailyRealStr = (dailyReal >= 0 ? "+" : "") + DoubleToString(dailyReal, 2) + " $";
   ObjectSetString(0, PREFIX+"val_dailyreal", OBJPROP_TEXT, dailyRealStr);
   ObjectSetInteger(0, PREFIX+"val_dailyreal", OBJPROP_COLOR, dailyReal >= 0 ? InpColorProfit : InpColorLoss);
   
   double floating = GetFloatingPnL();
   string floatStr = (floating >= 0 ? "+" : "") + DoubleToString(floating, 2) + " $";
   ObjectSetString(0, PREFIX+"val_floating", OBJPROP_TEXT, floatStr);
   ObjectSetInteger(0, PREFIX+"val_floating", OBJPROP_COLOR, floating >= 0 ? InpColorProfit : InpColorLoss);
   
   double todayTotal = dailyReal + floating;
   string todayTotalStr = (todayTotal >= 0 ? "+" : "") + DoubleToString(todayTotal, 2) + " $";
   ObjectSetString(0, PREFIX+"val_todaytotal", OBJPROP_TEXT, todayTotalStr);
   ObjectSetInteger(0, PREFIX+"val_todaytotal", OBJPROP_COLOR, todayTotal >= 0 ? InpColorProfit : InpColorLoss);
   
   double totalProfit = GetTotalAccountProfit();
   string totalStr = (totalProfit >= 0 ? "+" : "") + DoubleToString(totalProfit, 2) + " $";
   ObjectSetString(0, PREFIX+"val_totalprofit", OBJPROP_TEXT, totalStr);
   ObjectSetInteger(0, PREFIX+"val_totalprofit", OBJPROP_COLOR, totalProfit >= 0 ? InpColorProfit : InpColorLoss);
   
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

//+------------------------------------------------------------------+
//| ATUALIZAR INFO DE TREND                                           |
//+------------------------------------------------------------------+
void UpdateTrendInfo()
{
   if(g_maHandle == INVALID_HANDLE) return;
   
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

//+------------------------------------------------------------------+
//| ATUALIZAR ESTATÍSTICAS DOS GRIDS                                  |
//+------------------------------------------------------------------+
void UpdateGridStats()
{
   int dealsCount = GetTodayDealsCount();
   ObjectSetString(0, PREFIX+"val_deals", OBJPROP_TEXT, IntegerToString(dealsCount));
   
   GridStats g1, g2, g3, g4, g5;
   GetTodayGridStats(g1, g2, g3, g4, g5);
   
   string g1Str = IntegerToString(g1.count) + "x  |  " + (g1.profit >= 0 ? "+" : "") + DoubleToString(g1.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g1", OBJPROP_TEXT, g1Str);
   ObjectSetInteger(0, PREFIX+"val_g1", OBJPROP_COLOR, g1.count == 0 ? clrGray : (g1.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   string g2Str = IntegerToString(g2.count) + "x  |  " + (g2.profit >= 0 ? "+" : "") + DoubleToString(g2.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g2", OBJPROP_TEXT, g2Str);
   ObjectSetInteger(0, PREFIX+"val_g2", OBJPROP_COLOR, g2.count == 0 ? clrGray : (g2.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   string g3Str = IntegerToString(g3.count) + "x  |  " + (g3.profit >= 0 ? "+" : "") + DoubleToString(g3.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g3", OBJPROP_TEXT, g3Str);
   ObjectSetInteger(0, PREFIX+"val_g3", OBJPROP_COLOR, g3.count == 0 ? clrGray : (g3.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   string g4Str = IntegerToString(g4.count) + "x  |  " + (g4.profit >= 0 ? "+" : "") + DoubleToString(g4.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g4", OBJPROP_TEXT, g4Str);
   ObjectSetInteger(0, PREFIX+"val_g4", OBJPROP_COLOR, g4.count == 0 ? clrGray : (g4.profit >= 0 ? InpColorProfit : InpColorLoss));
   
   string g5Str = IntegerToString(g5.count) + "x  |  " + (g5.profit >= 0 ? "+" : "") + DoubleToString(g5.profit, 2) + "$";
   ObjectSetString(0, PREFIX+"val_g5", OBJPROP_TEXT, g5Str);
   ObjectSetInteger(0, PREFIX+"val_g5", OBJPROP_COLOR, g5.count == 0 ? clrGray : (g5.profit >= 0 ? InpColorProfit : InpColorLoss));
}

//+------------------------------------------------------------------+
//| ATUALIZAR INFO DE POSIÇÕES                                        |
//+------------------------------------------------------------------+
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
         if(!MatchesSymbolFilter(symbol)) continue;
         
         double lots = PositionGetDouble(POSITION_VOLUME);
         double profit = PositionGetDouble(POSITION_PROFIT);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            buyCount++;
            buyLots += lots;
            buyProfit += profit;
            buyTotalPrice += openPrice * lots;
            if(openPrice < lowestBuyPrice) lowestBuyPrice = openPrice;
         }
         else
         {
            sellCount++;
            sellLots += lots;
            sellProfit += profit;
            sellTotalPrice += openPrice * lots;
            if(openPrice > highestSellPrice) highestSellPrice = openPrice;
         }
      }
   }
   
   double avgBuyPrice = buyLots > 0 ? buyTotalPrice / buyLots : 0;
   double avgSellPrice = sellLots > 0 ? sellTotalPrice / sellLots : 0;
   int buyPoints = buyLots > 0 ? (int)((currentPrice - avgBuyPrice) / point) : 0;
   int sellPoints = sellLots > 0 ? (int)((avgSellPrice - currentPrice) / point) : 0;
   
   string buyProfitStr = (buyProfit >= 0 ? "+" : "") + DoubleToString(buyProfit, 0) + "$";
   string buyStr = IntegerToString(buyCount) + "x" + DoubleToString(buyLots, 2) + " | " + buyProfitStr + " | " + IntegerToString(buyPoints) + "p";
   ObjectSetString(0, PREFIX+"val_buy", OBJPROP_TEXT, buyStr);
   ObjectSetInteger(0, PREFIX+"val_buy", OBJPROP_COLOR, buyProfit >= 0 ? InpColorProfit : InpColorLoss);
   
   string sellProfitStr = (sellProfit >= 0 ? "+" : "") + DoubleToString(sellProfit, 0) + "$";
   string sellStr = IntegerToString(sellCount) + "x" + DoubleToString(sellLots, 2) + " | " + sellProfitStr + " | " + IntegerToString(sellPoints) + "p";
   ObjectSetString(0, PREFIX+"val_sell", OBJPROP_TEXT, sellStr);
   ObjectSetInteger(0, PREFIX+"val_sell", OBJPROP_COLOR, sellProfit >= 0 ? InpColorProfit : InpColorLoss);
   
   string avgPriceStr = "---";
   if(buyLots > 0 && sellLots > 0)
      avgPriceStr = "B:" + DoubleToString(avgBuyPrice, 2) + " S:" + DoubleToString(avgSellPrice, 2);
   else if(buyLots > 0)
      avgPriceStr = DoubleToString(avgBuyPrice, 2);
   else if(sellLots > 0)
      avgPriceStr = DoubleToString(avgSellPrice, 2);
   ObjectSetString(0, PREFIX+"val_avgprice", OBJPROP_TEXT, avgPriceStr);
   
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

//+------------------------------------------------------------------+
//| FUNÇÕES DE CRIAÇÃO DE OBJETOS                                     |
//+------------------------------------------------------------------+
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
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| CHART EVENT - Botões                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == PREFIX+"btn_pause")
      {
         g_isPaused = !g_isPaused;
         ObjectSetString(0, PREFIX+"btn_pause", OBJPROP_TEXT, g_isPaused ? "RETOMAR" : "PAUSAR");
         ObjectSetInteger(0, PREFIX+"btn_pause", OBJPROP_STATE, false);
      }
      else if(sparam == PREFIX+"btn_close")
      {
         CloseAllPositions();
         ObjectSetInteger(0, PREFIX+"btn_close", OBJPROP_STATE, false);
      }
   }
}

//+------------------------------------------------------------------+
//| PARSE JSON - String                                               |
//+------------------------------------------------------------------+
string GetJsonString(string json, string key)
{
   // Procura "key": ou "key" :
   string search = "\"" + key + "\"";
   int keyPos = StringFind(json, search);
   if(keyPos < 0) return "";
   
   // Avança para depois da chave
   int start = keyPos + StringLen(search);
   
   // Pula espaços e : 
   while(start < StringLen(json))
   {
      ushort c = StringGetCharacter(json, start);
      if(c == ':' || c == ' ' || c == '\t')
         start++;
      else
         break;
   }
   
   // Verifica se é string (começa com ")
   ushort firstChar = StringGetCharacter(json, start);
   if(firstChar == '"')
   {
      start++; // Pula o "
      int end = StringFind(json, "\"", start);
      if(end < 0) return "";
      return StringSubstr(json, start, end - start);
   }
   else
   {
      // Não é string, procura , ou }
      int endComma = StringFind(json, ",", start);
      int endBrace = StringFind(json, "}", start);
      int end = -1;
      
      if(endComma >= 0 && endBrace >= 0)
         end = MathMin(endComma, endBrace);
      else if(endComma >= 0)
         end = endComma;
      else if(endBrace >= 0)
         end = endBrace;
      else
         return "";
      
      string value = StringSubstr(json, start, end - start);
      StringTrimLeft(value);
      StringTrimRight(value);
      return value;
   }
}

//+------------------------------------------------------------------+
//| PARSE JSON - Double                                               |
//+------------------------------------------------------------------+
double GetJsonDouble(string json, string key)
{
   string value = GetJsonString(json, key);
   if(value == "") return 0;
   StringReplace(value, " ", "");
   return StringToDouble(value);
}

//+------------------------------------------------------------------+
//| PARSE JSON - Long                                                 |
//+------------------------------------------------------------------+
long GetJsonLong(string json, string key)
{
   string value = GetJsonString(json, key);
   if(value == "") return 0;
   StringReplace(value, " ", "");
   return StringToInteger(value);
}
//+------------------------------------------------------------------+
