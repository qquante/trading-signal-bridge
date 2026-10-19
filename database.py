"""
Database Module - SQLite para Copy Trade Control Center
Rastreia contas, trades, sinais e estatísticas
"""

import sqlite3
import asyncio
from datetime import datetime, timedelta
from typing import Optional, Dict, List, Any
from contextlib import contextmanager
import json
import uuid as uuid_lib

DATABASE_FILE = "trades.db"

# ====================================================
# INICIALIZAÇÃO DO BANCO
# ====================================================
def init_database():
    """Cria todas as tabelas necessárias"""
    conn = sqlite3.connect(DATABASE_FILE)
    cursor = conn.cursor()
    
    # Tabela de contas (slaves)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            account_number INTEGER,
            broker TEXT DEFAULT 'Default',
            lot_multiplier REAL DEFAULT 1.0,
            equity REAL DEFAULT 0,
            balance REAL DEFAULT 0,
            positions_count INTEGER DEFAULT 0,
            profit_today REAL DEFAULT 0,
            is_connected INTEGER DEFAULT 0,
            last_seen TIMESTAMP,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    # Tabela de sinais (do master)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT UNIQUE NOT NULL,
            master_ticket INTEGER NOT NULL,
            action TEXT NOT NULL,
            symbol TEXT NOT NULL,
            side TEXT,
            order_type TEXT,
            volume REAL,
            price REAL,
            sl REAL DEFAULT 0,
            tp REAL DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    
    # Tabela de trades (execuções nos slaves)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS trades (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            signal_uuid TEXT NOT NULL,
            master_ticket INTEGER,
            slave_ticket INTEGER,
            action TEXT NOT NULL,
            symbol TEXT,
            side TEXT,
            volume REAL,
            price REAL,
            profit REAL DEFAULT 0,
            status TEXT DEFAULT 'pending',
            error_message TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            confirmed_at TIMESTAMP,
            FOREIGN KEY (account_id) REFERENCES accounts(id),
            FOREIGN KEY (signal_uuid) REFERENCES signals(uuid)
        )
    """)
    
    # Tabela de estado do master (posições e ordens atuais)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS master_positions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            magic INTEGER NOT NULL,
            symbol TEXT NOT NULL,
            side TEXT NOT NULL,
            volume REAL NOT NULL,
            price REAL DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(magic)
        )
    """)
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS master_pending (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            magic INTEGER NOT NULL,
            symbol TEXT NOT NULL,
            order_type TEXT NOT NULL,
            side TEXT NOT NULL,
            volume REAL NOT NULL,
            price REAL DEFAULT 0,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(magic)
        )
    """)
    
    # Tabela de estatísticas diárias
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS daily_stats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            date DATE NOT NULL,
            profit REAL DEFAULT 0,
            equity_start REAL DEFAULT 0,
            equity_end REAL DEFAULT 0,
            trades_count INTEGER DEFAULT 0,
            wins INTEGER DEFAULT 0,
            losses INTEGER DEFAULT 0,
            FOREIGN KEY (account_id) REFERENCES accounts(id),
            UNIQUE(account_id, date)
        )
    """)
    
    # Índices para performance
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_signals_uuid ON signals(uuid)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_signals_ticket ON signals(master_ticket)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_trades_account ON trades(account_id)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_trades_signal ON trades(signal_uuid)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_daily_stats_account_date ON daily_stats(account_id, date)")
    
    conn.commit()
    conn.close()
    print("✅ Database inicializado")


@contextmanager
def get_db():
    """Context manager para conexão com o banco"""
    conn = sqlite3.connect(DATABASE_FILE)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# ====================================================
# ACCOUNTS (Contas dos Slaves)
# ====================================================
def upsert_account(name: str, account_number: int = None, broker: str = "Default") -> int:
    """Cria ou atualiza uma conta"""
    with get_db() as conn:
        cursor = conn.cursor()
        
        # Tenta atualizar
        cursor.execute("""
            UPDATE accounts 
            SET account_number = COALESCE(?, account_number),
                broker = COALESCE(?, broker),
                is_connected = 1,
                last_seen = CURRENT_TIMESTAMP
            WHERE name = ?
        """, (account_number, broker, name))
        
        if cursor.rowcount == 0:
            # Não existe, cria novo
            cursor.execute("""
                INSERT INTO accounts (name, account_number, broker, is_connected, last_seen)
                VALUES (?, ?, ?, 1, CURRENT_TIMESTAMP)
            """, (name, account_number, broker))
        
        # Retorna o ID
        cursor.execute("SELECT id FROM accounts WHERE name = ?", (name,))
        return cursor.fetchone()[0]


def update_account_status(name: str, equity: float, balance: float, positions: int, profit_today: float):
    """Atualiza status de uma conta"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            UPDATE accounts 
            SET equity = ?,
                balance = ?,
                positions_count = ?,
                profit_today = ?,
                is_connected = 1,
                last_seen = CURRENT_TIMESTAMP
            WHERE name = ?
        """, (equity, balance, positions, profit_today, name))


def set_account_disconnected(name: str):
    """Marca conta como desconectada"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            UPDATE accounts SET is_connected = 0 WHERE name = ?
        """, (name,))


def get_all_accounts() -> List[Dict]:
    """Retorna todas as contas"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT * FROM accounts ORDER BY name
        """)
        rows = cursor.fetchall()
        return [dict(row) for row in rows]


def get_account_by_name(name: str) -> Optional[Dict]:
    """Busca conta por nome"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM accounts WHERE name = ?", (name,))
        row = cursor.fetchone()
        return dict(row) if row else None


# ====================================================
# SIGNALS (Sinais do Master)
# ====================================================
def create_signal(master_ticket: int, action: str, symbol: str, side: str = None,
                  order_type: str = None, volume: float = 0, price: float = 0,
                  sl: float = 0, tp: float = 0) -> str:
    """Cria um novo sinal e retorna o UUID"""
    signal_uuid = str(uuid_lib.uuid4())[:8]  # UUID curto para facilitar
    
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO signals (uuid, master_ticket, action, symbol, side, order_type, volume, price, sl, tp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (signal_uuid, master_ticket, action, symbol, side, order_type, volume, price, sl, tp))
    
    return signal_uuid


def get_signal_by_uuid(uuid: str) -> Optional[Dict]:
    """Busca sinal por UUID"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM signals WHERE uuid = ?", (uuid,))
        row = cursor.fetchone()
        return dict(row) if row else None


# ====================================================
# TRADES (Execuções nos Slaves)
# ====================================================
def create_trade(account_id: int, signal_uuid: str, master_ticket: int, action: str,
                 symbol: str = None, side: str = None, volume: float = 0, price: float = 0) -> int:
    """Registra um trade pendente"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO trades (account_id, signal_uuid, master_ticket, action, symbol, side, volume, price, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending')
        """, (account_id, signal_uuid, master_ticket, action, symbol, side, volume, price))
        return cursor.lastrowid


def confirm_trade(account_name: str, signal_uuid: str, success: bool, slave_ticket: int = None, 
                  error_message: str = None, profit: float = 0):
    """Confirma execução de um trade"""
    account = get_account_by_name(account_name)
    if not account:
        return
    
    with get_db() as conn:
        cursor = conn.cursor()
        status = 'executed' if success else 'failed'
        cursor.execute("""
            UPDATE trades 
            SET status = ?,
                slave_ticket = ?,
                error_message = ?,
                profit = ?,
                confirmed_at = CURRENT_TIMESTAMP
            WHERE account_id = ? AND signal_uuid = ?
        """, (status, slave_ticket, error_message, profit, account['id'], signal_uuid))


def get_pending_trades(account_id: int) -> List[Dict]:
    """Retorna trades pendentes de uma conta"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT t.*, s.* FROM trades t
            JOIN signals s ON t.signal_uuid = s.uuid
            WHERE t.account_id = ? AND t.status = 'pending'
            ORDER BY t.created_at
        """, (account_id,))
        rows = cursor.fetchall()
        return [dict(row) for row in rows]


def get_recent_trades(limit: int = 50) -> List[Dict]:
    """Retorna trades recentes de todas as contas"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT t.*, a.name as account_name 
            FROM trades t
            JOIN accounts a ON t.account_id = a.id
            ORDER BY t.created_at DESC
            LIMIT ?
        """, (limit,))
        rows = cursor.fetchall()
        return [dict(row) for row in rows]


# ====================================================
# DAILY STATS (Estatísticas Diárias)
# ====================================================
def update_daily_stats(account_id: int, profit: float = 0, equity: float = 0, is_trade: bool = False, is_win: bool = False):
    """Atualiza estatísticas diárias"""
    today = datetime.now().strftime('%Y-%m-%d')
    
    with get_db() as conn:
        cursor = conn.cursor()
        
        # Verifica se já existe registro para hoje
        cursor.execute("""
            SELECT id, trades_count, wins, losses, equity_start 
            FROM daily_stats 
            WHERE account_id = ? AND date = ?
        """, (account_id, today))
        
        row = cursor.fetchone()
        
        if row:
            # Atualiza existente
            trades_count = row['trades_count'] + (1 if is_trade else 0)
            wins = row['wins'] + (1 if is_trade and is_win else 0)
            losses = row['losses'] + (1 if is_trade and not is_win else 0)
            
            cursor.execute("""
                UPDATE daily_stats 
                SET profit = profit + ?,
                    equity_end = ?,
                    trades_count = ?,
                    wins = ?,
                    losses = ?
                WHERE id = ?
            """, (profit, equity, trades_count, wins, losses, row['id']))
        else:
            # Cria novo
            cursor.execute("""
                INSERT INTO daily_stats (account_id, date, profit, equity_start, equity_end, trades_count, wins, losses)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, (account_id, today, profit, equity, equity, 1 if is_trade else 0, 
                  1 if is_trade and is_win else 0, 1 if is_trade and not is_win else 0))


def get_account_stats(account_id: int) -> Dict:
    """Retorna estatísticas agregadas de uma conta"""
    today = datetime.now().strftime('%Y-%m-%d')
    week_ago = (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d')
    month_ago = (datetime.now() - timedelta(days=30)).strftime('%Y-%m-%d')
    
    with get_db() as conn:
        cursor = conn.cursor()
        
        # Profit hoje
        cursor.execute("""
            SELECT COALESCE(SUM(profit), 0) as profit, COALESCE(SUM(trades_count), 0) as trades
            FROM daily_stats WHERE account_id = ? AND date = ?
        """, (account_id, today))
        today_row = cursor.fetchone()
        
        # Profit semana
        cursor.execute("""
            SELECT COALESCE(SUM(profit), 0) as profit, COALESCE(SUM(trades_count), 0) as trades
            FROM daily_stats WHERE account_id = ? AND date >= ?
        """, (account_id, week_ago))
        week_row = cursor.fetchone()
        
        # Profit mês
        cursor.execute("""
            SELECT COALESCE(SUM(profit), 0) as profit, COALESCE(SUM(trades_count), 0) as trades
            FROM daily_stats WHERE account_id = ? AND date >= ?
        """, (account_id, month_ago))
        month_row = cursor.fetchone()
        
        # Profit total
        cursor.execute("""
            SELECT COALESCE(SUM(profit), 0) as profit, COALESCE(SUM(trades_count), 0) as trades,
                   COALESCE(SUM(wins), 0) as wins, COALESCE(SUM(losses), 0) as losses
            FROM daily_stats WHERE account_id = ?
        """, (account_id,))
        total_row = cursor.fetchone()
        
        return {
            'today': {'profit': today_row['profit'], 'trades': today_row['trades']},
            'week': {'profit': week_row['profit'], 'trades': week_row['trades']},
            'month': {'profit': month_row['profit'], 'trades': month_row['trades']},
            'total': {
                'profit': total_row['profit'], 
                'trades': total_row['trades'],
                'wins': total_row['wins'],
                'losses': total_row['losses']
            }
        }


def get_all_stats() -> Dict:
    """Retorna estatísticas de todas as contas"""
    accounts = get_all_accounts()
    result = {
        'accounts': [],
        'totals': {
            'today': 0,
            'week': 0,
            'month': 0,
            'total': 0,
            'connected': 0,
            'total_accounts': len(accounts)
        }
    }
    
    for acc in accounts:
        stats = get_account_stats(acc['id'])
        acc_data = {
            **acc,
            'stats': stats
        }
        result['accounts'].append(acc_data)
        
        result['totals']['today'] += stats['today']['profit']
        result['totals']['week'] += stats['week']['profit']
        result['totals']['month'] += stats['month']['profit']
        result['totals']['total'] += stats['total']['profit']
        if acc['is_connected']:
            result['totals']['connected'] += 1
    
    return result


# ====================================================
# UTILIDADES
# ====================================================
def check_duplicate_signal(account_name: str, master_ticket: int, action: str) -> bool:
    """Verifica se já existe um sinal igual confirmado para esta conta"""
    account = get_account_by_name(account_name)
    if not account:
        return False
    
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("""
            SELECT COUNT(*) as count FROM trades t
            JOIN signals s ON t.signal_uuid = s.uuid
            WHERE t.account_id = ? 
              AND s.master_ticket = ? 
              AND s.action = ?
              AND t.status = 'executed'
        """, (account['id'], master_ticket, action))
        row = cursor.fetchone()
        return row['count'] > 0


def cleanup_old_data(days: int = 90):
    """Remove dados antigos"""
    cutoff = (datetime.now() - timedelta(days=days)).strftime('%Y-%m-%d %H:%M:%S')
    
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM trades WHERE created_at < ?", (cutoff,))
        cursor.execute("DELETE FROM signals WHERE created_at < ?", (cutoff,))
        cursor.execute("DELETE FROM daily_stats WHERE date < ?", (cutoff[:10],))
        print(f"🗑️ Dados anteriores a {cutoff[:10]} removidos")


# ====================================================
# MASTER STATE (Posições e Ordens do Master)
# ====================================================
def update_master_positions(positions: List[Dict]):
    """Atualiza posições do master (substitui todas)"""
    with get_db() as conn:
        cursor = conn.cursor()
        
        # Limpa posições antigas
        cursor.execute("DELETE FROM master_positions")
        
        # Insere novas posições
        for pos in positions:
            cursor.execute("""
                INSERT INTO master_positions (magic, symbol, side, volume, price, updated_at)
                VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            """, (pos.get("magic"), pos.get("symbol", ""), pos.get("side", ""), 
                  pos.get("volume", 0), pos.get("price", 0)))


def update_master_pending(pending: List[Dict]):
    """Atualiza ordens pendentes do master (substitui todas)"""
    with get_db() as conn:
        cursor = conn.cursor()
        
        # Limpa ordens antigas
        cursor.execute("DELETE FROM master_pending")
        
        # Insere novas ordens
        for pend in pending:
            cursor.execute("""
                INSERT INTO master_pending (magic, symbol, order_type, side, volume, price, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            """, (pend.get("magic"), pend.get("symbol", ""), pend.get("type", ""), 
                  pend.get("side", ""), pend.get("volume", 0), pend.get("price", 0)))


def get_master_positions() -> List[Dict]:
    """Retorna posições atuais do master"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM master_positions ORDER BY magic")
        rows = cursor.fetchall()
        return [dict(row) for row in rows]


def get_master_pending() -> List[Dict]:
    """Retorna ordens pendentes do master"""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM master_pending ORDER BY magic")
        rows = cursor.fetchall()
        return [dict(row) for row in rows]


# Inicializa o banco ao importar
init_database()
