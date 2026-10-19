"""
Webhook Server - Recebe sinais do MT5 e executa no Backpack
Com WebSocket para posições em tempo real
"""

import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
from datetime import datetime
import logging

from copy_trader import copy_trader
from config import WEBHOOK_HOST, WEBHOOK_PORT, LOG_LEVEL

# Configura logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# Lifecycle - inicia WebSocket no startup
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("🚀 Iniciando WebSocket...")
    await copy_trader.start_websocket()
    yield
    # Shutdown
    logger.info("🛑 Parando WebSocket...")
    copy_trader.stop_websocket()


app = FastAPI(title="Copy Trade Webhook Server", lifespan=lifespan)


# Modelo de dados do sinal
class TradeSignal(BaseModel):
    symbol: str
    action: str           # NEW, MODIFY, OPEN, CLOSE, CANCEL
    order_type: str       # SELL_STOP, BUY_STOP, MARKET, etc
    side: str             # BUY, SELL
    volume: float
    price: float
    ticket: int
    sl: Optional[float] = 0
    tp: Optional[float] = 0
    timestamp: int
    source: str = "MT5"


# Histórico de sinais
signals_history = []
executions_history = []


@app.get("/")
async def root():
    """Status do servidor"""
    status = copy_trader.get_status()
    return {
        "status": "online",
        "copy_enabled": status["enabled"],
        "backpack_lot": status["backpack_base_lot"],
        "position": status["state"]["position"],
        "total_quantity": status["state"]["total_quantity"],
        "cached_position": status["cached_position"],
        "ws_connected": status["ws_connected"],
        "signals_received": len(signals_history),
        "executions": len(executions_history)
    }


@app.post("/trade")
async def receive_trade(signal: TradeSignal):
    """
    Recebe sinais do MT5 e executa copy trade
    """
    
    # Log do sinal recebido
    print("=" * 50)
    print(f">>> {signal.action} {signal.side} <<<")
    print(f"Symbol:     {signal.symbol}")
    print(f"Type:       {signal.order_type}")
    print(f"Volume:     {signal.volume}")
    print(f"Price:      {signal.price}")
    print(f"Ticket:     {signal.ticket}")
    print("=" * 50)
    
    # Salva no histórico
    signal_data = {
        **signal.model_dump(),
        "received_at": datetime.now().isoformat()
    }
    signals_history.append(signal_data)
    
    # Mantém só últimos 100
    if len(signals_history) > 100:
        signals_history.pop(0)
    
    # Processa o sinal
    result = copy_trader.process_signal(signal.model_dump())
    
    if result:
        executions_history.append({
            "signal": signal_data,
            "result": result,
            "executed_at": datetime.now().isoformat()
        })
        
        # Mantém só últimos 50
        if len(executions_history) > 50:
            executions_history.pop(0)
        
        return {
            "status": "executed",
            "action": signal.action,
            "side": signal.side,
            "backpack_order": result.get("id")
        }
    
    return {
        "status": "ignored",
        "action": signal.action,
        "reason": "Not an execution event or disabled"
    }


@app.get("/signals")
async def get_signals():
    """Lista últimos sinais recebidos"""
    return {
        "count": len(signals_history),
        "signals": signals_history[-20:]
    }


@app.get("/executions")
async def get_executions():
    """Lista últimas execuções no Backpack"""
    return {
        "count": len(executions_history),
        "executions": executions_history[-20:]
    }


@app.get("/position")
async def get_position():
    """Retorna posição atual (do cache WebSocket)"""
    cached = copy_trader.get_real_position()
    state = copy_trader.state
    return {
        "cached": cached,
        "internal_state": state,
        "ws_connected": copy_trader.ws.running
    }


@app.get("/test")
async def test_connection():
    """Testa conexão com Backpack"""
    if copy_trader.test_connection():
        return {"status": "ok", "message": "Conexão com Backpack OK!"}
    else:
        raise HTTPException(status_code=500, detail="Erro de conexão com Backpack")


@app.get("/enable")
async def enable_copy():
    """Ativa copy trading"""
    copy_trader.enabled = True
    return {"status": "enabled"}


@app.get("/disable")
async def disable_copy():
    """Desativa copy trading"""
    copy_trader.enabled = False
    return {"status": "disabled"}


if __name__ == "__main__":
    import uvicorn
    
    print("=" * 60)
    print("  COPY TRADE WEBHOOK SERVER (with WebSocket)")
    print("=" * 60)
    print(f"  MT5 Base Lot:      {copy_trader.get_status()['mt5_base_lot']}")
    print(f"  Backpack Base Lot: {copy_trader.get_status()['backpack_base_lot']}")
    print(f"  Symbol:            {copy_trader.get_status()['symbol']}")
    print(f"  Copy Enabled:      {copy_trader.enabled}")
    print("=" * 60)
    print(f"  Server: http://{WEBHOOK_HOST}:{WEBHOOK_PORT}")
    print("=" * 60)
    
    # Testa conexão com Backpack
    print("\n🔌 Testando conexão com Backpack...")
    if copy_trader.test_connection():
        print("✅ Conexão REST OK!")
    else:
        print("⚠️  Erro de conexão - verifique as API keys no config.py")
    
    print("🔄 WebSocket será iniciado automaticamente...\n")
    
    uvicorn.run(app, host=WEBHOOK_HOST, port=WEBHOOK_PORT, log_level="info")
