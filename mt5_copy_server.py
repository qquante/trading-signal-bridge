"""
MT5 Copy Server - Control Center para Copy Trading
Gerencia múltiplas contas com tracking centralizado
"""

import asyncio
import json
from fastapi import FastAPI
from fastapi.responses import HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional, Dict, Set, List
from contextlib import asynccontextmanager
from datetime import datetime
import uvicorn
import os

# Import database
import database as db

# CONFIGURAÇÃO
HTTP_PORT = 8000        # Porta para receber webhooks do Master
TCP_PORT = 9999         # Porta TCP para Slaves conectarem
HOST = "0.0.0.0"        # Aceita conexões de qualquer IP

# ESTADO GLOBAL
# Mapeia writer -> info do slave
connected_slaves: Dict[asyncio.StreamWriter, dict] = {}

# Cache de sinais pendentes por conta (para retry)
pending_signals: Dict[str, Dict[str, dict]] = {}  # account_name -> {uuid: signal_data}

# Master status (atualizado pelo webhook)
master_status = {
    "equity": 0,
    "balance": 0,
    "positions": 0,
    "last_signal": None,
    "last_update": None
}

# TCP SERVER - Conexões dos Slaves
async def handle_slave(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """Gerencia conexão de um Slave com identificação"""
    addr = writer.get_extra_info('peername')
    slave_name = f"Unknown_{addr[0]}_{addr[1]}"
    
    # Adiciona com nome temporário
    connected_slaves[writer] = {
        "name": slave_name,
        "account": None,
        "addr": addr,
        "connected_at": datetime.now().isoformat(),
        "identified": False
    }
    
    print(f"🟢 CONEXÃO: {addr} (aguardando identificação...)")
    
    buffer = ""
    
    try:
        while True:
            try:
                # Lê dados com timeout
                data = await asyncio.wait_for(reader.read(4096), timeout=60.0)
                
                if not data:
                    break
                
                # Acumula no buffer
                buffer += data.decode('utf-8', errors='ignore')
                
                # Processa mensagens completas (terminadas em \n)
                while '\n' in buffer:
                    line, buffer = buffer.split('\n', 1)
                    line = line.strip()
                    
                    if line:
                        await process_slave_message(writer, line)
                        
            except asyncio.TimeoutError:
                # Envia heartbeat
                try:
                    writer.write(b'{"type":"ping"}\n')
                    await writer.drain()
                except:
                    break
                    
    except Exception as e:
        print(f"❌ Erro na conexão {slave_name}: {e}")
        
    finally:
        # Desconecta
        if writer in connected_slaves:
            info = connected_slaves[writer]
            slave_name = info.get("name", "Unknown")
            
            # Marca como desconectado no banco
            if info.get("identified"):
                db.set_account_disconnected(slave_name)
            
            del connected_slaves[writer]
            print(f"🔴 DESCONECTOU: {slave_name} (total: {len(connected_slaves)})")
        
        try:
            writer.close()
            await writer.wait_closed()
        except:
            pass


async def process_slave_message(writer: asyncio.StreamWriter, message: str):
    """Processa mensagem recebida de um slave"""
    try:
        data = json.loads(message)
        msg_type = data.get("type", "")
        
        if msg_type == "identify":
            # Slave se identificando
            name = data.get("name", "Unknown")
            account = data.get("account", 0)
            broker = data.get("broker", "Default")
            
            # Atualiza info local
            if writer in connected_slaves:
                connected_slaves[writer]["name"] = name
                connected_slaves[writer]["account"] = account
                connected_slaves[writer]["identified"] = True
            
            # Registra no banco
            db.upsert_account(name, account, broker)
            
            print(f"✅ IDENTIFICADO: {name} (Conta: {account}) - Total: {len(connected_slaves)}")
            
            # Envia confirmação
            response = json.dumps({"type": "identified", "status": "ok"}) + "\n"
            writer.write(response.encode())
            await writer.drain()
            
        elif msg_type == "status":
            # Status periódico do slave
            name = data.get("name", "")
            equity = data.get("equity", 0)
            balance = data.get("balance", 0)
            positions = data.get("positions", 0)
            profit_today = data.get("profit_today", 0)
            
            if name:
                db.update_account_status(name, equity, balance, positions, profit_today)
                
                # Atualiza cache local
                if writer in connected_slaves:
                    connected_slaves[writer]["equity"] = equity
                    connected_slaves[writer]["positions"] = positions
                    
        elif msg_type == "confirm":
            # Confirmação de execução de trade
            name = data.get("name", "")
            uuid = data.get("uuid", "")
            success = data.get("success", False)
            slave_ticket = data.get("ticket", 0)
            error = data.get("error", "")
            profit = data.get("profit", 0)
            
            if name and uuid:
                db.confirm_trade(name, uuid, success, slave_ticket, error, profit)
                
                # Remove dos pendentes
                if name in pending_signals and uuid in pending_signals[name]:
                    del pending_signals[name][uuid]
                
                status_emoji = "✅" if success else "❌"
                print(f"{status_emoji} CONFIRMADO: {name} | UUID: {uuid} | Ticket: {slave_ticket}")
                
    except json.JSONDecodeError:
        pass
    except Exception as e:
        print(f"❌ Erro processando mensagem: {e}")


async def broadcast_to_slaves(signal: dict, signal_uuid: str):
    """Envia sinal para TODOS os Slaves conectados com UUID"""
    if not connected_slaves:
        return 0
    
    # Adiciona UUID ao sinal
    signal["uuid"] = signal_uuid
    
    message = json.dumps(signal) + "\n"
    data = message.encode()
    
    sent = 0
    dead_slaves = set()
    
    for writer, info in connected_slaves.items():
        try:
            # Só envia para slaves identificados
            if not info.get("identified"):
                continue
                
            writer.write(data)
            await writer.drain()
            sent += 1
            
            slave_name = info.get("name", "Unknown")
            
            # Registra trade pendente no banco
            account = db.get_account_by_name(slave_name)
            if account:
                db.create_trade(
                    account_id=account["id"],
                    signal_uuid=signal_uuid,
                    master_ticket=signal.get("ticket", 0),
                    action=signal.get("action", ""),
                    symbol=signal.get("symbol", ""),
                    side=signal.get("side", ""),
                    volume=signal.get("volume", 0),
                    price=signal.get("price", 0)
                )
            
            # Adiciona aos pendentes locais
            if slave_name not in pending_signals:
                pending_signals[slave_name] = {}
            pending_signals[slave_name][signal_uuid] = {
                "signal": signal,
                "sent_at": datetime.now().isoformat()
            }
            
        except Exception as e:
            dead_slaves.add(writer)
    
    # Remove conexões mortas
    for writer in dead_slaves:
        if writer in connected_slaves:
            del connected_slaves[writer]
    
    return sent


async def start_tcp_server():
    """Inicia servidor TCP para Slaves"""
    server = await asyncio.start_server(handle_slave, HOST, TCP_PORT)
    print(f"📡 TCP Server iniciado em {HOST}:{TCP_PORT}")
    asyncio.create_task(server.serve_forever())


# HTTP SERVER - Webhooks do Master + API
@asynccontextmanager
async def lifespan(app: FastAPI):
    await start_tcp_server()
    yield

app = FastAPI(title="Copy Trade Control Center", lifespan=lifespan)


class TradeSignal(BaseModel):
    symbol: str
    action: str
    order_type: str
    side: str
    volume: float
    price: float
    ticket: int
    sl: Optional[float] = 0
    tp: Optional[float] = 0
    timestamp: int
    source: str = "MT5"
    # Opcional: info do master
    equity: Optional[float] = 0
    balance: Optional[float] = 0
    positions: Optional[int] = 0


class PositionInfo(BaseModel):
    magic: int
    side: str
    volume: float
    symbol: str
    price: float = 0


class PendingInfo(BaseModel):
    magic: int
    type: str
    side: str
    volume: float
    price: float
    symbol: str


class SyncData(BaseModel):
    type: str = "sync"
    positions: List[PositionInfo] = []
    pending: List[PendingInfo] = []
    timestamp: int = 0


# Estado do Master (posições e ordens atuais)
master_state = {
    "positions": [],
    "pending": [],
    "last_sync": None
}


async def broadcast_sync_to_slaves(sync_data: dict):
    """Envia sync para TODOS os Slaves - sem UUID, apenas estado"""
    if not connected_slaves:
        return 0
    
    sync_data["type"] = "sync"
    message = json.dumps(sync_data) + "\n"
    data = message.encode()
    
    sent = 0
    dead_slaves = set()
    
    for writer, info in connected_slaves.items():
        try:
            if not info.get("identified"):
                continue
            writer.write(data)
            await writer.drain()
            sent += 1
        except:
            dead_slaves.add(writer)
    
    for writer in dead_slaves:
        if writer in connected_slaves:
            del connected_slaves[writer]
    
    return sent


@app.post("/sync")
async def receive_sync(sync: SyncData):
    """Recebe estado atual do Master e retransmite para Slaves"""
    
    # Atualiza estado do master em memória
    master_state["positions"] = [p.model_dump() for p in sync.positions]
    master_state["pending"] = [p.model_dump() for p in sync.pending]
    master_state["last_sync"] = datetime.now().isoformat()
    
    # Salva no banco de dados
    db.update_master_positions(master_state["positions"])
    db.update_master_pending(master_state["pending"])
    
    # Atualiza contagem no status
    master_status["positions"] = len(sync.positions)
    master_status["last_update"] = datetime.now().isoformat()
    
    # Retransmite para slaves
    sync_dict = {
        "type": "sync",
        "positions": master_state["positions"],
        "pending": master_state["pending"],
        "timestamp": sync.timestamp
    }
    
    sent = await broadcast_sync_to_slaves(sync_dict)
    
    return {"status": "synced", "slaves": sent, "positions": len(sync.positions), "pending": len(sync.pending)}


@app.post("/trade")
async def receive_trade(signal: TradeSignal):
    """Recebe do Master e envia para Slaves com UUID"""
    
    # Atualiza status do master
    if signal.equity:
        master_status["equity"] = signal.equity
    if signal.balance:
        master_status["balance"] = signal.balance
    if signal.positions:
        master_status["positions"] = signal.positions
    master_status["last_signal"] = signal.action
    master_status["last_update"] = datetime.now().isoformat()
    
    # Cria UUID e registra no banco
    signal_uuid = db.create_signal(
        master_ticket=signal.ticket,
        action=signal.action,
        symbol=signal.symbol,
        side=signal.side,
        order_type=signal.order_type,
        volume=signal.volume,
        price=signal.price,
        sl=signal.sl,
        tp=signal.tp
    )
    
    print(f">>> SINAL [{signal_uuid}]: {signal.action} {signal.side} {signal.volume} lots @ {signal.price}")
    print(f"    Symbol: {signal.symbol} | Ticket: {signal.ticket}")
    
    # Converte para dict e envia
    signal_dict = signal.model_dump()
    signal_dict["type"] = "trade"
    
    sent = await broadcast_to_slaves(signal_dict, signal_uuid)
    
    print(f"    Enviado para {sent} slave(s)")
    print("-" * 50)
    
    return {"status": "sent", "uuid": signal_uuid, "slaves": sent}


@app.get("/")
async def root():
    """Status do servidor"""
    return {
        "status": "online",
        "slaves_connected": len([s for s in connected_slaves.values() if s.get("identified")]),
        "tcp_port": TCP_PORT,
        "http_port": HTTP_PORT,
        "master": master_status
    }


# API ENDPOINTS para Dashboard
@app.get("/api/accounts")
async def get_accounts():
    """Retorna todas as contas com status"""
    accounts = db.get_all_accounts()
    
    # Adiciona info de conexão em tempo real
    connected_names = {info["name"] for info in connected_slaves.values() if info.get("identified")}
    
    for acc in accounts:
        acc["is_connected"] = acc["name"] in connected_names
        acc["stats"] = db.get_account_stats(acc["id"])
    
    return {"accounts": accounts, "connected_count": len(connected_names)}


@app.get("/api/stats")
async def get_stats():
    """Retorna estatísticas agregadas"""
    stats = db.get_all_stats()
    stats["master"] = master_status
    stats["master_state"] = master_state
    stats["connected_slaves"] = [
        {
            "name": info["name"],
            "account": info.get("account"),
            "equity": info.get("equity", 0),
            "positions": info.get("positions", 0)
        }
        for info in connected_slaves.values()
        if info.get("identified")
    ]
    return stats


@app.get("/api/master")
async def get_master_state():
    """Retorna estado atual do master (posições e ordens)"""
    return {
        "status": master_status,
        "state": master_state
    }


@app.get("/api/trades")
async def get_trades(limit: int = 50):
    """Retorna trades recentes"""
    trades = db.get_recent_trades(limit)
    return {"trades": trades}


@app.get("/api/pending")
async def get_pending():
    """Retorna sinais pendentes de confirmação"""
    return {"pending": pending_signals}


@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard():
    """Serve o dashboard HTML"""
    dashboard_path = os.path.join(os.path.dirname(__file__), "dashboard.html")
    if os.path.exists(dashboard_path):
        with open(dashboard_path, "r", encoding="utf-8") as f:
            return HTMLResponse(content=f.read())
    return HTMLResponse(content="<h1>Dashboard não encontrado</h1><p>Crie o arquivo dashboard.html</p>")


# MAIN
if __name__ == "__main__":
    print("=" * 60)
    print("  COPY TRADE CONTROL CENTER")
    print("=" * 60)
    print(f"  HTTP (Master):    http://{HOST}:{HTTP_PORT}/trade")
    print(f"  TCP (Slaves):     {HOST}:{TCP_PORT}")
    print(f"  Dashboard:        http://{HOST}:{HTTP_PORT}/dashboard")
    print(f"  API Status:       http://{HOST}:{HTTP_PORT}/api/stats")
    print("=" * 60)
    print("  Aguardando conexões...")
    print("=" * 60)
    
    uvicorn.run(app, host=HOST, port=HTTP_PORT, log_level="warning")
